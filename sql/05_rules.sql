-- STATUS: EXECUTED 2026-08-21 via `snow sql -f`. Both tables created. RUL-001
-- seed (commented below) still pending SAFETY_DOC_007 / data load.
-- Rewritten against
-- docs/self-tracking/03_SCHEMA_DESIGN.md §9. Rules are immutable rows;
-- corrections insert version n+1 and flip the old row to SUPERSEDED.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

-- ============================================================================
-- RULE_PROPOSAL — grain: one row per candidate rule extracted from one
-- document by one extraction run (§9.1). Inert until approved; nothing here
-- affects detection. MODEL_NAME/PROMPT_VERSION exist so "which model said
-- this" is an audit question with an actual answer.
-- ============================================================================
CREATE OR REPLACE TABLE RULE_PROPOSAL (
  PROPOSAL_ID              VARCHAR(60)  NOT NULL,
  DOC_ID                   VARCHAR(40)  NOT NULL,
  RAW_LLM_OUTPUT           VARIANT,
  MODEL_NAME               VARCHAR(80)  NOT NULL,
  PROMPT_VERSION           VARCHAR(20)  NOT NULL,
  EXTRACTED_AT             TIMESTAMP_TZ NOT NULL,
  DRUG_TEXT                VARCHAR(200),
  PRECONDITION_TYPE        VARCHAR(30),   -- raw model output, lower case
  PRECONDITION_VALUE       VARCHAR(200),
  REQUIRED_TEST_TEXT       VARCHAR(160),
  INTERVAL_DAYS            NUMBER(5,0),
  INTERVAL_SOURCE_PHRASE   VARCHAR(300),  -- verbatim from the document
  EFFECTIVE_DATE           DATE,
  SOURCE_PASSAGE           VARCHAR(4000),
  NEEDS_REVIEW             BOOLEAN      NOT NULL DEFAULT FALSE,
  REVIEW_REASON            VARCHAR(500),
  STATUS                   VARCHAR(20)  NOT NULL DEFAULT 'PROPOSED',  -- PROPOSED|APPROVED|REJECTED
  REVIEWED_BY              VARCHAR(60),
  REVIEWED_AT              TIMESTAMP_TZ,
  REJECT_REASON            VARCHAR(500),
  CREATED_AT               TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (PROPOSAL_ID)
);

-- ============================================================================
-- SAFETY_RULE — grain: one row per (RULE_ID, VERSION); immutable except the
-- SUPERSEDED/RETIRED transition (§9.2). SOURCE_PROPOSAL_ID gives full
-- lineage: document -> proposal -> rule.
-- ============================================================================
CREATE OR REPLACE TABLE SAFETY_RULE (
  RULE_ID                  VARCHAR(40)  NOT NULL,
  VERSION                  NUMBER(4,0)  NOT NULL,
  SOURCE_PROPOSAL_ID       VARCHAR(60)  NOT NULL,
  DRUG_ID                  VARCHAR(40)  NOT NULL,
  PRECONDITION_TYPE        VARCHAR(20)  NOT NULL,  -- CONDITION | AGE_MIN | NONE
  CONDITION_ID             VARCHAR(40),             -- required when type=CONDITION
  AGE_MIN                  NUMBER(3,0),             -- required when type=AGE_MIN (not implemented in v1 detection)
  LAB_TEST_ID              VARCHAR(40)  NOT NULL,
  INTERVAL_DAYS            NUMBER(5,0)  NOT NULL,
  GRACE_DAYS               NUMBER(5,0)  NOT NULL DEFAULT 7,
  INTERVAL_SOURCE_PHRASE   VARCHAR(300) NOT NULL,
  EFFECTIVE_DATE           DATE         NOT NULL,
  DOC_ID                   VARCHAR(40)  NOT NULL,
  SOURCE_PASSAGE           VARCHAR(4000) NOT NULL,
  STATUS                   VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE|SUPERSEDED|RETIRED
  APPROVED_BY              VARCHAR(60)  NOT NULL,
  APPROVED_AT              TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  SUPERSEDED_BY_VERSION    NUMBER(4,0),
  RETIRED_BY               VARCHAR(60),
  RETIRED_AT               TIMESTAMP_TZ,
  RETIRE_REASON            VARCHAR(500),
  PRIMARY KEY (RULE_ID, VERSION)
);

-- ============================================================================
-- Manual seed of RUL-001 v1 — deliberately NOT dependent on extraction
-- (which is blocked by the Cortex trial restriction; see the project journal). This
-- keeps the whole critical path — detection, reconciler, app, disposition —
-- unblocked regardless of how that issue resolves. Requires SAFETY_DOC_007
-- to exist in CONF.CONF_SAFETY_DOCUMENT first (loaded by the generator) —
-- run this AFTER data load, not now. Left here, commented, as the exact
-- statement to run then.
-- ============================================================================
-- INSERT INTO RULE_PROPOSAL
--   (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
--    DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
--    INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
--    NEEDS_REVIEW, STATUS, REVIEWED_BY, REVIEWED_AT)
-- VALUES
--   ('PRP-SEED-001', 'SAFETY_DOC_007', 'manual-seed', 'n/a', CURRENT_TIMESTAMP(),
--    'CardioZen', 'condition', 'chronic kidney disease', 'serum potassium',
--    90, 'checked at least every three months', DATE '2026-03-01', 'section 3',
--    FALSE, 'APPROVED', 'aman', CURRENT_TIMESTAMP());
--
-- INSERT INTO SAFETY_RULE
--   (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
--    CONDITION_ID, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
--    INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
--    STATUS, APPROVED_BY)
-- VALUES
--   ('RUL-001', 1, 'PRP-SEED-001', 'DRG-CARDIOZEN', 'CONDITION',
--    'CND-CKD', 'LAB-K', 90, 7,
--    'checked at least every three months', DATE '2026-03-01', 'SAFETY_DOC_007', 'section 3',
--    'ACTIVE', 'aman');
