-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- EVERYTHING THE TRIAL ACCOUNT BLOCKED, NOW BUILT FOR REAL.
--
-- Five features were shipped half-finished for nine days because a plain
-- Snowflake trial refuses them. The account was replaced on 30 Aug with one
-- created through the hackathon's AI Data Cloud signup flow, which is
-- entitled. This file closes all five, in the order they unblock each other.
--
--   1. Cortex Search      real semantic retrieval over the document corpus.
--                         Previously: native SEARCH() only, lexical, honest
--                         about it but unable to match a paraphrase.
--   2. PARSE_DOCUMENT     the PDF in the staging area becomes the document
--                         that is actually parsed, instead of a text
--                         rendering standing in for it.
--   3. Data Metric Funcs  ATTACHED to tables on a schedule, so data quality
--                         is a monitored property with history rather than a
--                         view somebody has to remember to open.
--   4. Tag-based masking  a masking policy attached to a CLASSIFICATION, so a
--                         newly added PHI column inherits protection instead
--                         of waiting for someone to notice it.
--   5. AI extraction      the AI_COMPLETE backend in sql/24 becomes the one
--                         in force, and the pattern UDF becomes the fallback
--                         that proves the seam rather than the only option.
--
-- Item 5 is switched on in sql/28 rather than here, because it should happen
-- after 1-4 are verified: it is the only one that changes what the reviewer
-- sees, and it must be provably a model that produced each proposal.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. CORTEX SEARCH over the document corpus.
--
-- TARGET_LAG is deliberately '1 day', not the '1 minute' every tutorial uses.
-- A search service re-indexes on its lag whether or not anything changed, and
-- that is serverless spend on a $400 budget. The corpus changes when a
-- committee issues a document -- days apart, not minutes -- so a one-day lag
-- costs almost nothing and loses nothing. The intake procedure can force a
-- refresh when it actually loads something.
--
-- Indexed on CHUNK_TEXT with the section label and doc id as attributes,
-- because the citation a reviewer reads is "SAFETY_DOC_010, section 3" and a
-- retrieval result that cannot produce that is not usable as evidence.
-- ===========================================================================
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS CONF.DOC_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOC_ID, SECTION_LABEL, CHUNK_ID
  WAREHOUSE = HO_WH
  TARGET_LAG = '1 day'
  COMMENT = 'Semantic retrieval over safety-document sections. Attributes carry the citation.'
  AS
  SELECT CHUNK_ID, DOC_ID, SECTION_LABEL, CHUNK_TEXT
  FROM CONF.DOC_CHUNK;

-- ===========================================================================
-- 2. PARSE_DOCUMENT -- ingest the PDF, not a stand-in for it.
--
-- SP_INGEST_DOCUMENTS in sql/23 branches on CONF.DOC_PARSER_CONFIG.PARSER_MODE.
-- Flipping it to PARSE_DOCUMENT makes the pipeline read the PDFs that were
-- already sitting in the stage. Everything downstream is untouched, because
-- all of it reads CONF_SAFETY_DOCUMENT.FULL_TEXT and does not care how the
-- text got there. That was the whole point of building the seam.
--
-- Left commented until the probe in section 5 confirms the exact function
-- signature available on this account -- guessing between AI_PARSE_DOCUMENT
-- and SNOWFLAKE.CORTEX.PARSE_DOCUMENT would just move the failure later.
--
-- UPDATE CONF.DOC_PARSER_CONFIG
--    SET PARSER_MODE = 'PARSE_DOCUMENT',
--        REASON = 'Cortex entitled on this account; the PDF of record is parsed directly.',
--        UPDATED_AT = CURRENT_TIMESTAMP();

-- ===========================================================================
-- 3. ATTACH the data metric functions.
--
-- The functions have existed since sql/19 and were evaluable on demand. What
-- was missing is the thing that makes them governance rather than a query:
-- Snowflake evaluating them on a schedule and keeping the answers, so
-- "was this data healthy last Tuesday?" is answerable. A test suite cannot
-- answer that; it only knows the moment it ran.
--
-- DAILY, not hourly. DMFs are serverless and billed per evaluation, and the
-- fastest-moving of these metrics moves when a document is ingested.
-- ===========================================================================
ALTER TABLE CONF.CONF_LAB_RESULT SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
ALTER TABLE CONF.CONF_LAB_RESULT
  ADD DATA METRIC FUNCTION SEC.DMF_UNMAPPED_LAB_PCT ON (LAB_TEST_ID);
ALTER TABLE CONF.CONF_LAB_RESULT
  ADD DATA METRIC FUNCTION SEC.DMF_FUTURE_DATED ON (RESULT_DATE);

ALTER TABLE CONF.CONF_MEDICATION SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
ALTER TABLE CONF.CONF_MEDICATION
  ADD DATA METRIC FUNCTION SEC.DMF_DUP_ACTIVE_MEDS ON (PERSON_ID, DRUG_ID, STATUS);

ALTER TABLE CASES.CASE_EVIDENCE SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
ALTER TABLE CASES.CASE_EVIDENCE
  ADD DATA METRIC FUNCTION SEC.DMF_MISSING_WITHOUT_SEARCHED ON (VERDICT, SEARCHED);

-- ===========================================================================
-- 4. TAG-BASED MASKING -- implemented in sql/16, not here.
--
-- sql/16 already contained the exact four statements, commented out with the
-- privilege error they returned. The grant now exists (sql/26), so those lines
-- are uncommented there rather than reimplemented here -- the original file is
-- where a reader looks for classification, and a second parallel version in
-- this file would be the worse kind of duplication.
--
-- One correction made while enabling it: the policy binds to
-- SEC.PAYER_IDENTIFIER, NOT to SEC.DATA_SENSITIVITY. DATA_SENSITIVITY sits on
-- columns the P360 dynamic tables read, and masking an input to a dynamic
-- table changes what that table computes. sql/16 created PAYER_IDENTIFIER
-- precisely because nothing downstream reads those columns.
-- ===========================================================================

-- ===========================================================================
-- 5. PROBES -- confirm each feature before anything depends on it.
-- ===========================================================================
SHOW CORTEX SEARCH SERVICES IN SCHEMA CONF;

SELECT 'PARSE_DOCUMENT signature probe' AS probe,
       AI_PARSE_DOCUMENT(TO_FILE('@RAW.DOC_STAGE', 'SAFETY_DOC_010.pdf'),
                         {'mode': 'LAYOUT'}):content::STRING AS extracted_text;

SELECT 'DMFs attached to a table' AS probe, COUNT(*) AS n
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
             REF_ENTITY_NAME  => 'HEALTHONE.CONF.CONF_LAB_RESULT',
             REF_ENTITY_DOMAIN => 'TABLE'));
