-- STATUS: EXECUTED 2026-08-21 via `snow sql -f`. All 9 tables created,
-- CHANGE_TRACKING confirmed ON for DOC_CHUNK. Transforms ran against empty
-- RAW tables (0 rows inserted, as expected) — re-run after the generator
-- loads RAW. Built against docs/self-tracking/03_SCHEMA_DESIGN.md §7.
-- Provenance columns are sacred:
-- citations exist because provenance is KEPT, not reconstructed (docs/01 §7).
--
-- This file has two parts: CREATE TABLE (run any time) and RAW->CONF
-- transform INSERTs (safe to run before data is loaded — they will insert
-- zero rows against empty RAW tables, which validates the SQL for real
-- without requiring the generator to exist yet). Re-run transforms after
-- tools/generate_data.py loads RAW.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CONF; USE WAREHOUSE HO_WH;

-- ============================================================================
-- CONF_PERSON_XWALK — the isolated identity seat (docs/01 §8, DECISIONS A7).
-- NOT derived by a SQL transform: real identity resolution (probabilistic
-- person matching) is a product in itself, and faking it with a fragile
-- name/DOB SQL match would be worse than admitting we didn't build it. The
-- generator has ground truth (it created both sides of each person) and
-- writes this table directly. A production deployment swaps in an enterprise
-- master-person index without touching anything downstream (§7.1).
-- NO masking policy here, and none ever — see H-10: masking a join key
-- breaks every downstream join for the masked role. Masking lives on
-- P360_PERSON.NAME / .DOB only (sql/04).
-- ============================================================================
CREATE OR REPLACE TABLE CONF_PERSON_XWALK (
  PERSON_ID          VARCHAR(40)  NOT NULL,
  PATIENT_ID         VARCHAR(40)  NOT NULL,
  MEMBER_ID          VARCHAR(40)  NOT NULL,
  MATCH_METHOD       VARCHAR(40)  NOT NULL DEFAULT 'DETERMINISTIC_SYNTHETIC',
  MATCH_CONFIDENCE   NUMBER(3,2)  NOT NULL DEFAULT 1.00,
  PRIMARY KEY (PERSON_ID),
  UNIQUE (PATIENT_ID),
  UNIQUE (MEMBER_ID)
);
-- Populated by tools/generate_data.py, not by a transform below.

-- ============================================================================
-- CONF_MEDICATION — grain: one row per hospital medication ORDER (§7.2).
-- Rows whose DRUG_TEXT maps to nothing are NOT loaded: the rule engine only
-- speaks controlled vocabulary (DECISIONS R4).
-- ============================================================================
CREATE OR REPLACE TABLE CONF_MEDICATION (
  MED_ID             VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  DRUG_ID            VARCHAR(40)  NOT NULL,
  STATUS             VARCHAR(20)  NOT NULL,
  START_DATE         DATE         NOT NULL,
  STOP_DATE          DATE,
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'EHR',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (MED_ID)
);
INSERT INTO CONF_MEDICATION
  (MED_ID, PERSON_ID, DRUG_ID, STATUS, START_DATE, STOP_DATE,
   SOURCE_SYSTEM, SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'MED-' || m.ORDER_ID, x.PERSON_ID, d.DRUG_ID, m.STATUS, m.START_DATE, m.STOP_DATE,
       'EHR', m.ORDER_ID, m.LOAD_BATCH_ID
FROM RAW.RAW_EHR_MED_ORDER m
JOIN CONF_PERSON_XWALK x ON x.PATIENT_ID = m.PATIENT_ID
JOIN REF_DRUG d           ON LOWER(TRIM(m.DRUG_TEXT)) = LOWER(d.DRUG_NAME);

-- ============================================================================
-- CONF_PHARMACY_FILL — grain: one row per dispensing event (§7.3).
-- ============================================================================
CREATE OR REPLACE TABLE CONF_PHARMACY_FILL (
  FILL_ID            VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  DRUG_ID            VARCHAR(40)  NOT NULL,
  FILL_DATE          DATE         NOT NULL,
  DAYS_SUPPLY        NUMBER(4,0),
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'PHARMACY',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (FILL_ID)
);
INSERT INTO CONF_PHARMACY_FILL
  (FILL_ID, PERSON_ID, DRUG_ID, FILL_DATE, DAYS_SUPPLY,
   SOURCE_SYSTEM, SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'FIL-' || f.FILL_ID, x.PERSON_ID, d.DRUG_ID, f.FILL_DATE, f.DAYS_SUPPLY,
       'PHARMACY', f.FILL_ID, f.LOAD_BATCH_ID
FROM RAW.RAW_PLAN_PHARMACY_FILL f
JOIN CONF_PERSON_XWALK x ON x.MEMBER_ID = f.MEMBER_ID
JOIN REF_DRUG d           ON LOWER(TRIM(f.DRUG_TEXT)) = LOWER(d.DRUG_NAME);

-- ============================================================================
-- CONF_DIAGNOSIS — grain: one row per RECORDED diagnosis event, deliberately
-- NOT deduplicated to one per person+condition (§7.4). Every consumer must
-- aggregate (MIN(ONSET_DATE)) before using this — see H-02.
-- ============================================================================
CREATE OR REPLACE TABLE CONF_DIAGNOSIS (
  DX_ID              VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  CONDITION_ID       VARCHAR(40)  NOT NULL,
  ONSET_DATE         DATE         NOT NULL,
  RECORDED_DATE      DATE         NOT NULL,
  IS_ONSET_IMPUTED   BOOLEAN      NOT NULL DEFAULT FALSE,
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'EHR',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (DX_ID)
);
INSERT INTO CONF_DIAGNOSIS
  (DX_ID, PERSON_ID, CONDITION_ID, ONSET_DATE, RECORDED_DATE, IS_ONSET_IMPUTED,
   SOURCE_SYSTEM, SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'DX-' || dx.DX_ID, x.PERSON_ID, c.CONDITION_ID,
       COALESCE(dx.ONSET_DATE, dx.RECORDED_DATE) AS ONSET_DATE,
       dx.RECORDED_DATE,
       (dx.ONSET_DATE IS NULL) AS IS_ONSET_IMPUTED,
       'EHR', dx.DX_ID, dx.LOAD_BATCH_ID
FROM RAW.RAW_EHR_DIAGNOSIS dx
JOIN CONF_PERSON_XWALK x ON x.PATIENT_ID = dx.PATIENT_ID
JOIN REF_CONDITION c      ON LOWER(TRIM(dx.CONDITION_TEXT)) = LOWER(c.CONDITION_NAME);

-- ============================================================================
-- CONF_CLAIM_LINE — grain: one row per claim line (§7.5). CONDITION_ID is
-- nullable by design: most claim lines are not condition-confirming evidence.
-- ============================================================================
CREATE OR REPLACE TABLE CONF_CLAIM_LINE (
  CLAIM_LINE_ID      VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  SERVICE_DATE       DATE         NOT NULL,
  CONDITION_ID       VARCHAR(40),
  SERVICE_DESC       VARCHAR(200) NOT NULL,
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'CLAIMS',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (CLAIM_LINE_ID)
);
INSERT INTO CONF_CLAIM_LINE
  (CLAIM_LINE_ID, PERSON_ID, SERVICE_DATE, CONDITION_ID, SERVICE_DESC,
   SOURCE_SYSTEM, SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'CLM-' || cl.CLAIM_ID, x.PERSON_ID, cl.SERVICE_DATE, c.CONDITION_ID, cl.SERVICE_DESC,
       'CLAIMS', cl.CLAIM_ID, cl.LOAD_BATCH_ID
FROM RAW.RAW_PLAN_CLAIM cl
JOIN CONF_PERSON_XWALK x     ON x.MEMBER_ID = cl.MEMBER_ID
LEFT JOIN REF_CONDITION c    ON LOWER(TRIM(cl.DX_TEXT)) = LOWER(c.CONDITION_NAME);

-- ============================================================================
-- CONF_LAB_RESULT — grain: one row per lab result (§7.6).
-- LAB_TEST_ID NULL means the test name did not map — kept, NOT dropped
-- (P1131/GP3's entire mechanism). Canonical name matches first, then
-- synonym table; anything left unmapped stays NULL.
-- ============================================================================
CREATE OR REPLACE TABLE CONF_LAB_RESULT (
  LAB_RESULT_ID      VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  LAB_TEST_ID        VARCHAR(40),
  RAW_TEST_TEXT      VARCHAR(160) NOT NULL,
  RESULT_DATE        DATE         NOT NULL,
  RESULT_VALUE       NUMBER(12,4),
  UNITS              VARCHAR(20),
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'LAB',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (LAB_RESULT_ID)
);
INSERT INTO CONF_LAB_RESULT
  (LAB_RESULT_ID, PERSON_ID, LAB_TEST_ID, RAW_TEST_TEXT, RESULT_DATE, RESULT_VALUE,
   UNITS, SOURCE_SYSTEM, SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'LAB-' || lr.LAB_ID, x.PERSON_ID,
       COALESCE(canon.LAB_TEST_ID, syn.LAB_TEST_ID),   -- NULL if neither matched
       lr.TEST_TEXT, lr.RESULT_DATE, lr.RESULT_VALUE, lr.UNITS,
       'LAB', lr.LAB_ID, lr.LOAD_BATCH_ID
FROM RAW.RAW_LAB_RESULT lr
JOIN CONF_PERSON_XWALK x            ON x.PATIENT_ID = lr.PATIENT_ID
LEFT JOIN REF_LAB_TEST canon        ON LOWER(TRIM(lr.TEST_TEXT)) = LOWER(canon.CANONICAL_NAME)
LEFT JOIN REF_LAB_TEST_SYNONYM syn  ON LOWER(TRIM(lr.TEST_TEXT)) = syn.SYNONYM_TEXT;

-- ============================================================================
-- CONF_CLINICAL_NOTE — grain: one row per note (§7.7).
-- ============================================================================
CREATE OR REPLACE TABLE CONF_CLINICAL_NOTE (
  NOTE_ID            VARCHAR(60)  NOT NULL,
  PERSON_ID          VARCHAR(40)  NOT NULL,
  NOTE_DATE          DATE         NOT NULL,
  AUTHOR_ROLE        VARCHAR(60),
  NOTE_TEXT          VARCHAR      NOT NULL,
  SOURCE_SYSTEM      VARCHAR(20)  NOT NULL DEFAULT 'EHR',
  SOURCE_RECORD_ID   VARCHAR(40)  NOT NULL,
  LOAD_BATCH_ID      VARCHAR(40),
  LOADED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (NOTE_ID)
);
INSERT INTO CONF_CLINICAL_NOTE
  (NOTE_ID, PERSON_ID, NOTE_DATE, AUTHOR_ROLE, NOTE_TEXT, SOURCE_SYSTEM,
   SOURCE_RECORD_ID, LOAD_BATCH_ID)
SELECT 'NOT-' || n.NOTE_ID, x.PERSON_ID, n.NOTE_DATE, n.AUTHOR_ROLE, n.NOTE_TEXT,
       'EHR', n.NOTE_ID, n.LOAD_BATCH_ID
FROM RAW.RAW_EHR_CLINICAL_NOTE n
JOIN CONF_PERSON_XWALK x ON x.PATIENT_ID = n.PATIENT_ID;

-- ============================================================================
-- CONF_SAFETY_DOCUMENT — grain: one row per document (§7.8).
-- ============================================================================
CREATE OR REPLACE TABLE CONF_SAFETY_DOCUMENT (
  DOC_ID             VARCHAR(40)  NOT NULL,
  TITLE              VARCHAR(300) NOT NULL,
  PUBLISHER          VARCHAR(160) NOT NULL,
  PUBLICATION_DATE   DATE         NOT NULL,
  STATUS             VARCHAR(30)  NOT NULL,
  FULL_TEXT          VARCHAR      NOT NULL,
  INGESTED_AT        TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (DOC_ID)
);
INSERT INTO CONF_SAFETY_DOCUMENT (DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT)
SELECT DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT
FROM RAW.RAW_SAFETY_DOCUMENT;

-- ============================================================================
-- DOC_CHUNK — grain: one row per document SECTION (§7.9). Chunk at section
-- boundaries, never fixed character windows — the section label IS the
-- citation ("SAFETY_DOC_007, section 3"). Section splitting is text
-- processing, not a SQL transform: populated by the ingest script (not yet
-- written) from CONF_SAFETY_DOCUMENT.FULL_TEXT. Table created now so
-- CHANGE_TRACKING can be enabled ahead of the Cortex Search service (still
-- blocked — see the project journal).
-- ============================================================================
CREATE OR REPLACE TABLE DOC_CHUNK (
  CHUNK_ID       VARCHAR(60)   NOT NULL,
  DOC_ID         VARCHAR(40)   NOT NULL,
  CHUNK_INDEX    NUMBER(5,0)   NOT NULL,
  SECTION_LABEL  VARCHAR(120)  NOT NULL,
  CHUNK_TEXT     VARCHAR(8000) NOT NULL,
  PRIMARY KEY (CHUNK_ID)
);
ALTER TABLE DOC_CHUNK SET CHANGE_TRACKING = TRUE;  -- Cortex Search prerequisite

-- ============================================================================
-- Sanity queries
-- ============================================================================
-- SELECT COUNT(*) FROM CONF_PERSON_XWALK;   -- 0 until generator runs
-- SELECT COUNT(*) FROM CONF_MEDICATION;     -- 0 until generator runs
-- SELECT COUNT(*) FROM CONF_LAB_RESULT WHERE LAB_TEST_ID IS NULL;  -- unmapped, expected > 0 once loaded
