-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- THE DOCUMENT STAGING AREA AND INGESTION PATH
--
-- WHY THIS FILE EXISTS
-- Until now every safety document reached the database because a Python
-- script on Aman's laptop turned it into an INSERT statement, and DOC_CHUNK
-- was a GENERATED .sql file. That means the ingestion path being demonstrated
-- was not the ingestion path that would ever run. This file replaces it with
-- the real one:
--
--   file lands in an internal stage
--     -> directory table sees it
--       -> COPY INTO lands the raw text (load history makes this idempotent)
--         -> MERGE promotes it to CONF.CONF_SAFETY_DOCUMENT
--           -> an in-database chunker writes CONF.DOC_CHUNK
--             -> extraction (sql/24) proposes rules
--               -> a human approves (sql/25) and detection picks them up
--
-- Nothing in that chain runs on a laptop. All of it is Snowflake objects.
--
-- THE ONE ENTITLEMENT-GATED LINK, NAMED HONESTLY
-- The documents a medicines-safety committee circulates are PDFs, and the
-- stage holds PDFs (staging/documents/*.pdf). Turning a PDF into text inside
-- Snowflake needs AI_PARSE_DOCUMENT / SNOWFLAKE.CORTEX.PARSE_DOCUMENT, which
-- is Cortex and therefore blocked on a trial account. So:
--
--   * The PDF is uploaded and IS the document of record. The directory table
--     lists it, sized and timestamped.
--   * PARSE_DOCUMENT is a LIVE BRANCH of SP_INGEST_DOCUMENTS, selected by
--     CONF.DOC_PARSER_CONFIG.PARSER_MODE. It is not commented-out aspiration.
--   * On an account without the entitlement, PARSER_MODE stays NATIVE_TEXT and
--     the pipeline ingests the plain-text rendering of the SAME document.
--   * CONF.DOC_INGEST_LOG records, per file, which of the two actually ran.
--
-- So the log never claims a parser ran that did not run, and moving between
-- the two is one UPDATE to CONF.DOC_PARSER_CONFIG. Nothing downstream changes,
-- because everything downstream reads CONF_SAFETY_DOCUMENT.FULL_TEXT.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. The stage.
--
-- Internal, server-side encrypted (SNOWFLAKE_SSE is a hard prerequisite for
-- TO_FILE and therefore for PARSE_DOCUMENT later -- a client-side encrypted
-- stage cannot be read by the parser). DIRECTORY = (ENABLE = TRUE) creates
-- the directory table, which is what makes "what is sitting in staging right
-- now" a SQL question rather than a filesystem question.
-- ===========================================================================
CREATE STAGE IF NOT EXISTS RAW.DOC_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY  = (ENABLE = TRUE, REFRESH_ON_CREATE = TRUE)
  COMMENT    = 'Safety document staging area. PDFs are documents of record; .md is the text rendering ingested until PARSE_DOCUMENT is entitled.';

-- Whole-file-as-one-row text format. FIELD_DELIMITER/RECORD_DELIMITER = NONE
-- is what stops the CSV reader from splitting a prose document into rows and
-- columns; without it a markdown file arrives as several hundred junk rows.
CREATE OR REPLACE FILE FORMAT RAW.FF_WHOLE_TEXT
  TYPE = CSV
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE
  TRIM_SPACE = FALSE
  SKIP_BLANK_LINES = FALSE
  REPLACE_INVALID_CHARACTERS = TRUE
  COMMENT = 'Reads an entire text file into a single VARCHAR column.';

-- ===========================================================================
-- 2. Landing table, ingest log, parser switch.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS RAW.RAW_DOC_FILE (
  SRC_FILE      VARCHAR(400) NOT NULL,
  FILE_TEXT     VARCHAR      NOT NULL,
  PARSER_USED   VARCHAR(60)  NOT NULL,
  LOAD_BATCH_ID VARCHAR(60)  NOT NULL,
  -- A work queue, not decoration. Snowflake Scripting will not substitute a
  -- scripting variable into a CURSOR query (it is prepared at declaration and
  -- fails with "Bind variable :run_id not set"), so the set of documents this
  -- run must chunk is carried in the DATA rather than in a variable. That also
  -- means an interrupted run leaves its unfinished work visible and re-runnable.
  NEEDS_CHUNK   BOOLEAN      NOT NULL DEFAULT FALSE,
  LOADED_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
-- Upgrade path for an account where RAW_DOC_FILE predates the queue column.
--
-- Wrapped in a scripting block that swallows the failure, and that wrapper is
-- not decoration. On a FRESH account the CREATE above already includes the
-- column and the bare ALTER returns "ambiguous column name 'NEEDS_CHUNK'" --
-- Snowflake's wording for "it is already there". `snow sql -f` ABORTS THE
-- WHOLE FILE on the first error, so the bare version silently prevented every
-- statement below it from being created: no chunker, no ingest procedure, and
-- a deploy log that looked like one harmless warning. Found by calling a
-- procedure that did not exist.
EXECUTE IMMEDIATE $$
BEGIN
  ALTER TABLE RAW.RAW_DOC_FILE ADD COLUMN NEEDS_CHUNK BOOLEAN NOT NULL DEFAULT FALSE;
  RETURN 'column added';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'already present: ' || SQLERRM;
END;
$$;

CREATE TABLE IF NOT EXISTS CONF.DOC_INGEST_LOG (
  INGEST_ID           VARCHAR(60)  NOT NULL,
  RUN_ID              VARCHAR(60)  NOT NULL,
  SRC_FILE            VARCHAR(400),
  DOC_ID              VARCHAR(40),
  PARSER_USED         VARCHAR(60)  NOT NULL,
  TEXT_CHARS          NUMBER(12,0),
  CHUNKS_WRITTEN      NUMBER(6,0)  DEFAULT 0,
  DOC_ID_MATCHES_TEXT BOOLEAN,
  STATUS              VARCHAR(30)  NOT NULL,
  MESSAGE             VARCHAR(1000),
  INGESTED_BY         VARCHAR(80)  NOT NULL,
  INGESTED_AT         TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (INGEST_ID)
);

-- Which parser the pipeline is allowed to use. One row. Flipping this is the
-- entire migration to a Cortex-entitled account.
CREATE TABLE IF NOT EXISTS CONF.DOC_PARSER_CONFIG (
  PARSER_MODE VARCHAR(30)  NOT NULL,   -- NATIVE_TEXT | PARSE_DOCUMENT
  REASON      VARCHAR(500) NOT NULL,
  UPDATED_AT  TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
DELETE FROM CONF.DOC_PARSER_CONFIG;
INSERT INTO CONF.DOC_PARSER_CONFIG (PARSER_MODE, REASON)
SELECT 'NATIVE_TEXT',
       'PARSE_DOCUMENT is a Cortex AI function and returns error 399258 "not available for trial accounts" on this account. Ingesting the text rendering of the same document until that entitlement exists.';

-- ===========================================================================
-- 3. What is in staging right now -- a SQL answer, from the directory table.
-- ===========================================================================
CREATE OR REPLACE VIEW CONF.V_DOC_STAGE_FILES
COMMENT = 'Every file in the staging area with its ingest state. Reads the stage directory table.'
AS
WITH files AS (
  SELECT RELATIVE_PATH,
         SIZE                                                AS FILE_BYTES,
         LAST_MODIFIED,
         UPPER(REGEXP_SUBSTR(RELATIVE_PATH, '[^.]+$'))       AS EXTENSION,
         REGEXP_SUBSTR(RELATIVE_PATH, 'SAFETY_DOC_[0-9]{3}') AS DOC_ID
  FROM DIRECTORY(@RAW.DOC_STAGE)
)
SELECT f.RELATIVE_PATH,
       f.DOC_ID,
       f.EXTENSION,
       f.FILE_BYTES,
       f.LAST_MODIFIED,
       CASE f.EXTENSION
         WHEN 'PDF' THEN 'document of record - needs PARSE_DOCUMENT (blocked)'
         WHEN 'MD'  THEN 'text rendering - ingested by COPY INTO'
         ELSE 'unrecognised - ignored by the ingest pattern'
       END                                                   AS ROLE_IN_PIPELINE,
       (d.DOC_ID IS NOT NULL)                                AS IS_PROMOTED,
       d.TITLE,
       d.PUBLICATION_DATE,
       (SELECT COUNT(*) FROM CONF.DOC_CHUNK k     WHERE k.DOC_ID = f.DOC_ID) AS CHUNKS,
       (SELECT COUNT(*) FROM RULES.RULE_PROPOSAL p WHERE p.DOC_ID = f.DOC_ID) AS PROPOSALS,
       (SELECT COUNT(*) FROM RULES.SAFETY_RULE r
         WHERE r.DOC_ID = f.DOC_ID AND r.STATUS = 'ACTIVE')  AS ACTIVE_RULES
FROM files f
LEFT JOIN CONF.CONF_SAFETY_DOCUMENT d ON d.DOC_ID = f.DOC_ID;

-- ===========================================================================
-- 4. THE PDF PARSER -- now a live branch, see section 6b.
--
-- History worth keeping, because it explains the shape of this file. On the
-- original trial account this section held the PARSE_DOCUMENT statement
-- commented out, with the error it returned:
--   399258 (0A000): AI function ... is not available for trial accounts.
-- The pipeline was built with the parser as a replaceable component precisely
-- so that this could stop being a comment without anything else moving. It
-- now lives in SP_INGEST_DOCUMENTS section 6b, selected by
-- CONF.DOC_PARSER_CONFIG.PARSER_MODE.
-- ===========================================================================

-- ===========================================================================
-- 4b. NORMALISE_DOC_TEXT -- the one transform between RAW and CONF.
--
-- WHY THIS IS NEEDED, discovered by running the real parser on the real PDF.
-- AI_PARSE_DOCUMENT in LAYOUT mode returns good markdown, but not the same
-- markdown the source was written in:
--
--   * every heading comes back as level 1, so "## 3. Monitoring requirement"
--     arrives as "# 3. Monitoring requirement". The chunker splits on level-2
--     headings, so without this the whole document became ONE chunk and every
--     citation degraded to "the document" instead of "section 3".
--   * page furniture is inlined. "Page 1 of 2 - SYNTHETIC DEMONSTRATION
--     DOCUMENT" appears in the text flow, which is noise in a chunk and noise
--     in a prompt.
--
-- RAW.RAW_DOC_FILE keeps the parser output verbatim -- that is the provenance
-- record, and it is never rewritten. This normalisation is applied on the way
-- into CONF, which is what a conformed layer is for.
--
-- Deliberately conservative: it renumbers heading LEVELS and removes page
-- furniture. It does not touch a single word of content, because the
-- INTERVAL_SOURCE_PHRASE quoted back to the reviewer has to be verbatim.
-- ===========================================================================
CREATE OR REPLACE FUNCTION CONF.NORMALISE_DOC_TEXT(T STRING)
RETURNS STRING
COMMENT = 'RAW to CONF text conformance: level headings consistently, drop page furniture. Never alters wording.'
AS
$$
  REGEXP_REPLACE(
    REGEXP_REPLACE(
      -- 1. page furniture: a whole line that is only a page counter
      REGEXP_REPLACE(T, '(^|\\n)Page [0-9]+ of [0-9]+[^\\n]*', '\\1'),
      -- 2. any heading level introducing a NUMBERED section becomes level 2,
      --    which is the level the chunker and the extractor both expect. An
      --    unnumbered heading (the document title) is left alone so it stays
      --    part of the preamble chunk.
      '(^|\\n)#{1,6}( [0-9]+\\.)', '\\1##\\2'),
    --    The replacement uses CHR(10), not a backslash-n escape: a
    --    REGEXP_REPLACE replacement string accepts backreferences and
    --    nothing else, and Snowflake rejects the escape outright with
    --    "Replace string could not be rewritten ... invalid escape
    --    sequence".
    -- 3. collapse runs of blank lines left behind by step 1
    '\\n{3,}', CHR(10) || CHR(10))
$$;

-- ===========================================================================
-- 5. The in-database chunker.
--
-- Splits FULL_TEXT on markdown section boundaries -- NOT on a fixed character
-- window -- because the section label is the citation the reviewer reads
-- ("SAFETY_DOC_010, section 3"). A 512-character window would cite nothing.
--
-- Deterministic: same text in, same chunk ids out. That is what lets the
-- golden tests assert on citations.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE CONF.SP_CHUNK_DOCUMENT(P_DOC_ID STRING)
RETURNS NUMBER
LANGUAGE SQL
COMMENT = 'Re-chunk one document at its section headings, replacing that document chunks.'
AS
$$
DECLARE
  n INT DEFAULT 0;
BEGIN
  DELETE FROM CONF.DOC_CHUNK WHERE DOC_ID = :P_DOC_ID;

  INSERT INTO CONF.DOC_CHUNK (CHUNK_ID, DOC_ID, CHUNK_INDEX, SECTION_LABEL, CHUNK_TEXT)
  WITH parts AS (
    -- the split consumed the '## ' marker; put it back so the chunk text is
    -- the verbatim section as it appears in the document
    SELECT s.INDEX AS IDX,
           IFF(s.INDEX = 1, s.VALUE, '## ' || s.VALUE) AS BODY
    FROM CONF.CONF_SAFETY_DOCUMENT d,
         LATERAL SPLIT_TO_TABLE(d.FULL_TEXT, '\n## ') s
    WHERE d.DOC_ID = :P_DOC_ID
  )
  SELECT 'CHK-' || RIGHT(:P_DOC_ID, 3) || '-' || LPAD(IDX, 3, '0'),
         :P_DOC_ID,
         IDX,
         CASE WHEN IDX = 1 THEN 'preamble - header and disclaimer'
              ELSE 'section '
                   || COALESCE(REGEXP_SUBSTR(BODY, '^## ([0-9]+)\\.', 1, 1, 'e', 1),
                               TO_VARCHAR(IDX - 1))
                   || ' - '
                   || TRIM(REGEXP_REPLACE(SPLIT_PART(BODY, '\n', 1),
                                          '^## [0-9]+\\.[ ]*|^## ', ''))
         END,
         LEFT(TRIM(BODY), 8000)
  FROM parts
  WHERE LENGTH(TRIM(BODY)) > 0;

  n := SQLROWCOUNT;
  RETURN :n;
END;
$$;

-- ===========================================================================
-- 6. SP_INGEST_DOCUMENTS -- the one entry point.
--
-- Idempotent by construction. COPY INTO keeps its own load history, so a file
-- already ingested is skipped without special-casing; only genuinely new or
-- changed files produce work. Re-running this is safe, and it is what the
-- app button and the scheduled task both call.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE CONF.SP_INGEST_DOCUMENTS(P_ACTOR STRING, P_FORCE BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refresh the stage, load new document text, promote, chunk, and log. Idempotent.'
AS
$$
DECLARE
  run_id    STRING;
  who       STRING;
  mode      STRING;
  files_new INT DEFAULT 0;
  docs_new  INT DEFAULT 0;
  chunks_n  INT DEFAULT 0;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context') INTO :who;
  SELECT 'ING-' || UUID_STRING() INTO :run_id;
  SELECT PARSER_MODE INTO :mode FROM CONF.DOC_PARSER_CONFIG;

  -- 6a. Make the directory table agree with the stage. Without this a file
  --     uploaded a second ago is invisible to DIRECTORY().
  ALTER STAGE RAW.DOC_STAGE REFRESH;

  -- 6b. Land raw text. TWO PARSERS, one switch, identical output.
  --
  --     PARSE_DOCUMENT reads the PDF that a committee would actually
  --     circulate. NATIVE_TEXT reads the plain-text rendering of the same
  --     document and exists because PARSE_DOCUMENT is a Cortex function and
  --     was unavailable on the original trial account. Both land in
  --     RAW_DOC_FILE with PARSER_USED naming which one ran, so the ingest log
  --     can never claim a parser was used that was not.
  --
  --     Everything after this point is identical for both, because all of it
  --     reads CONF_SAFETY_DOCUMENT.FULL_TEXT. That is the entire reason this
  --     is a seam rather than two pipelines.
  IF (:mode = 'PARSE_DOCUMENT') THEN
    INSERT INTO RAW.RAW_DOC_FILE
      (SRC_FILE, FILE_TEXT, PARSER_USED, LOAD_BATCH_ID, NEEDS_CHUNK)
    SELECT f.RELATIVE_PATH,
           AI_PARSE_DOCUMENT(TO_FILE('@RAW.DOC_STAGE', f.RELATIVE_PATH),
                             {'mode': 'LAYOUT'}):content::STRING,
           'AI_PARSE_DOCUMENT/LAYOUT', :run_id, TRUE
      FROM DIRECTORY(@RAW.DOC_STAGE) f
     WHERE UPPER(f.RELATIVE_PATH) LIKE '%.PDF';

  --     The batch id is stamped AFTERWARDS in the COPY branches rather than
  --     bound into the COPY. COPY INTO does not accept bind variables in its
  --     transform SELECT -- it fails with "Bind variable :run_id not set" --
  --     so those rows land marked PENDING and are claimed below.
  --     FORCE re-reads files already in the COPY load history, which is what
  --     you want after editing a document in place.
  ELSEIF (:P_FORCE) THEN
    COPY INTO RAW.RAW_DOC_FILE (SRC_FILE, FILE_TEXT, PARSER_USED, LOAD_BATCH_ID)
    FROM (SELECT METADATA$FILENAME, $1, 'native-text-copy', 'PENDING'
          FROM @RAW.DOC_STAGE)
    FILE_FORMAT = (FORMAT_NAME = RAW.FF_WHOLE_TEXT)
    PATTERN = '.*[.]md'
    ON_ERROR = ABORT_STATEMENT
    FORCE = TRUE;
  ELSE
    COPY INTO RAW.RAW_DOC_FILE (SRC_FILE, FILE_TEXT, PARSER_USED, LOAD_BATCH_ID)
    FROM (SELECT METADATA$FILENAME, $1, 'native-text-copy', 'PENDING'
          FROM @RAW.DOC_STAGE)
    FILE_FORMAT = (FORMAT_NAME = RAW.FF_WHOLE_TEXT)
    PATTERN = '.*[.]md'
    ON_ERROR = ABORT_STATEMENT;
  END IF;

  UPDATE RAW.RAW_DOC_FILE
     SET LOAD_BATCH_ID = :run_id, NEEDS_CHUNK = TRUE
   WHERE LOAD_BATCH_ID = 'PENDING';
  SELECT COUNT(*) INTO :files_new FROM RAW.RAW_DOC_FILE WHERE LOAD_BATCH_ID = :run_id;

  -- 6c. Promote to the conformed layer. DOC_ID comes from the filename and is
  --     cross-checked against the Reference: line in the body; a mismatch is
  --     recorded rather than silently trusted.
  MERGE INTO CONF.CONF_SAFETY_DOCUMENT t
  USING (
    SELECT DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT
    FROM (
      SELECT REGEXP_SUBSTR(SRC_FILE, 'SAFETY_DOC_[0-9]{3}') AS DOC_ID,

             -- TITLE: front matter first, then the first markdown heading.
             COALESCE(
               NULLIF(TRIM(REGEXP_SUBSTR(FILE_TEXT, 'TITLE:[ ]*(.*)', 1, 1, 'e', 1)), ''),
               NULLIF(TRIM(REGEXP_SUBSTR(FILE_TEXT, '^# (.*)$', 1, 1, 'me', 1)), ''),
               'Untitled safety document') AS TITLE,

             COALESCE(
               NULLIF(TRIM(REGEXP_SUBSTR(FILE_TEXT, 'PUBLISHER:[ ]*(.*)', 1, 1, 'e', 1)), ''),
               NULLIF(TRIM(REGEXP_SUBSTR(FILE_TEXT, 'Publisher:[*]{0,2}[ ]*(.*)', 1, 1, 'e', 1)), ''),
               'Regional Medicines Safety Committee') AS PUBLISHER,

             -- PUBLICATION_DATE: the ISO date the document declares, then any
             -- of the three prose labels the corpus actually uses ("Date of
             -- issue", "Date", "Dated"), then today.
             --
             -- CURRENT_DATE() last is a trap that already fired: documents 008
             -- and 009 do not say "Date of issue", so the single old regex
             -- missed, the COALESCE fell straight through, and every document
             -- reported the ingest date as its publication date. Reaching the
             -- default is now visible in DOC_INGEST_LOG rather than silent.
             COALESCE(
               TRY_TO_DATE(TRIM(REGEXP_SUBSTR(FILE_TEXT,
                 'PUBLICATION_DATE:[ ]*([0-9]{4}-[0-9]{2}-[0-9]{2})', 1, 1, 'e', 1)),
                 'YYYY-MM-DD'),
               TRY_TO_DATE(TRIM(REGEXP_SUBSTR(FILE_TEXT,
                 'Date of issue:[*]{0,2}[ ]*([0-9]{1,2} [A-Za-z]+ [0-9]{4})', 1, 1, 'e', 1)),
                 'DD MMMM YYYY'),
               TRY_TO_DATE(TRIM(REGEXP_SUBSTR(FILE_TEXT,
                 '[*]{0,2}Dated?:[*]{0,2}[ ]*([0-9]{1,2} [A-Za-z]+ [0-9]{4})', 1, 1, 'e', 1)),
                 'DD MMMM YYYY'),
               CURRENT_DATE()) AS PUBLICATION_DATE,

             COALESCE(
               NULLIF(TRIM(REGEXP_SUBSTR(FILE_TEXT, 'STATUS:[ ]*([A-Z]+)', 1, 1, 'e', 1)), ''),
               'ACTIVE') AS STATUS,
             CONF.NORMALISE_DOC_TEXT(FILE_TEXT) AS FULL_TEXT,
             ROW_NUMBER() OVER (
               PARTITION BY REGEXP_SUBSTR(SRC_FILE, 'SAFETY_DOC_[0-9]{3}')
               ORDER BY LOADED_AT DESC, LENGTH(FILE_TEXT) DESC) AS RN
      FROM RAW.RAW_DOC_FILE
      WHERE NEEDS_CHUNK
        AND REGEXP_SUBSTR(SRC_FILE, 'SAFETY_DOC_[0-9]{3}') IS NOT NULL
    )
    WHERE RN = 1
  ) s ON t.DOC_ID = s.DOC_ID
  WHEN MATCHED THEN UPDATE SET
    t.TITLE = s.TITLE, t.PUBLISHER = s.PUBLISHER,
    t.PUBLICATION_DATE = s.PUBLICATION_DATE, t.FULL_TEXT = s.FULL_TEXT,
    t.INGESTED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT, INGESTED_AT)
    VALUES (s.DOC_ID, s.TITLE, s.PUBLISHER, s.PUBLICATION_DATE, s.STATUS,
            s.FULL_TEXT, CURRENT_TIMESTAMP());

  docs_new := SQLROWCOUNT;

  -- 6d. Chunk every document touched by this batch, and log one row per file.
  LET cur CURSOR FOR
    SELECT DISTINCT REGEXP_SUBSTR(SRC_FILE, 'SAFETY_DOC_[0-9]{3}') AS D
      FROM RAW.RAW_DOC_FILE
     WHERE NEEDS_CHUNK
       AND REGEXP_SUBSTR(SRC_FILE, 'SAFETY_DOC_[0-9]{3}') IS NOT NULL;
  FOR rec IN cur DO
    LET dref STRING := rec.D;
    LET c INT := 0;
    CALL CONF.SP_CHUNK_DOCUMENT(:dref);
    SELECT COUNT(*) INTO :c FROM CONF.DOC_CHUNK WHERE DOC_ID = :dref;
    chunks_n := :chunks_n + :c;

    INSERT INTO CONF.DOC_INGEST_LOG
      (INGEST_ID, RUN_ID, SRC_FILE, DOC_ID, PARSER_USED, TEXT_CHARS,
       CHUNKS_WRITTEN, DOC_ID_MATCHES_TEXT, STATUS, MESSAGE, INGESTED_BY)
    SELECT 'IGL-' || UUID_STRING(), :run_id, f.SRC_FILE, :dref, f.PARSER_USED,
           LENGTH(f.FILE_TEXT), :c,
           (REGEXP_SUBSTR(f.FILE_TEXT, 'SAFETY_DOC_[0-9]{3}') = :dref),
           IFF(EXISTS (SELECT 1 FROM CONF.CONF_SAFETY_DOCUMENT d
                        WHERE d.DOC_ID = :dref
                          AND d.PUBLICATION_DATE = CURRENT_DATE()),
               'LOADED_NO_DECLARED_DATE', 'LOADED'),
           IFF(f.PARSER_USED = 'AI_PARSE_DOCUMENT/LAYOUT',
               'Text extracted from the PDF of record by Cortex PARSE_DOCUMENT in LAYOUT mode, then chunked at section boundaries.',
               'Text rendering ingested by COPY INTO and chunked at markdown section boundaries. The PDF of record is in the stage; set PARSER_MODE = PARSE_DOCUMENT to parse it directly.'),
           :who
    FROM RAW.RAW_DOC_FILE f
    WHERE f.NEEDS_CHUNK
      AND REGEXP_SUBSTR(f.SRC_FILE, 'SAFETY_DOC_[0-9]{3}') = :dref;
  END FOR;

  -- Queue drained. Anything still flagged means the loop above did not finish.
  UPDATE RAW.RAW_DOC_FILE SET NEEDS_CHUNK = FALSE WHERE NEEDS_CHUNK;

  -- 6e. Make what was just ingested searchable NOW.
  --
  -- CONF.DOC_SEARCH has TARGET_LAG = '1 day' on purpose: a Cortex Search
  -- service re-indexes on its lag whether or not anything changed, and that is
  -- serverless spend on a fixed budget. The corpus changes when a committee
  -- issues a document, which is days apart, so a one-day lag is right.
  --
  -- The consequence, learned the hard way: the service was created while
  -- DOC_CHUNK was still empty, so for a day it returned zero results for every
  -- query while looking perfectly healthy. A newly ingested document must be
  -- searchable immediately or the reviewer is reading a stale index.
  --
  -- Wrapped so a missing service is not fatal. On an account without the Cortex
  -- entitlement there is no service to refresh, and ingestion must still work --
  -- retrieval simply falls back to the lexical SEARCH() path, which the app
  -- labels.
  BEGIN
    ALTER CORTEX SEARCH SERVICE CONF.DOC_SEARCH REFRESH;
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'DOC_INGESTED', :who, 'INGEST_RUN', :run_id,
         OBJECT_CONSTRUCT('files_loaded', :files_new, 'docs_upserted', :docs_new,
                          'chunks_written', :chunks_n, 'parser_mode', :mode,
                          'forced', :P_FORCE);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'run_id', :run_id, 'parser_mode', :mode,
                          'files_loaded', :files_new, 'docs_upserted', :docs_new,
                          'chunks_written', :chunks_n);
END;
$$;
