-- STATUS: SUPERSEDED 2026-08-30. NEVER EXECUTED. Do not run.
-- Replaced by: the live approval path. SAFETY_DOC_008 now produces a real PROPOSAL that
-- RULES.SP_APPROVE_PROPOSAL turns into RUL-001 v2, so the version-bump beat is
-- performed by the product rather than rehearsed by a script.
-- THE LIVE BEAT: a document the system has never seen becomes an active rule,
-- and the queue changes as a direct consequence.
--
-- This is the answer to "when a new rule is created, how is it applied?"
-- written as executable steps rather than prose.
--
-- SAFETY_DOC_008 (corpus/, deliberately held back from the normal load)
-- tightens the CardioZen + CKD potassium interval from three months to 60
-- days. Approving it creates RUL-001 **version 2** and supersedes version 1.
--
-- WHAT MAKES THIS WORK WITH NO CODE CHANGE
-- DT_CASE_CANDIDATE contains no rule-specific logic. It joins whatever rows
-- are ACTIVE in SAFETY_RULE to the P360 timelines. A new rule, or a new
-- version of one, is a DATA change — so the detection SQL never gets edited,
-- redeployed, or retested to add one. That property is the actual product.
--
-- Idempotent: re-running resets to v2 cleanly.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ---------------------------------------------------------------------------
-- STEP 1 — the document arrives (in the demo this is the [Load document]
-- action; here it is the same INSERT that action performs).
-- ---------------------------------------------------------------------------
DELETE FROM RAW.RAW_SAFETY_DOCUMENT  WHERE DOC_ID = 'SAFETY_DOC_008';
DELETE FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID = 'SAFETY_DOC_008';

INSERT INTO RAW.RAW_SAFETY_DOCUMENT
  (DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT, LOAD_BATCH_ID)
SELECT 'SAFETY_DOC_008',
       'Revision of Potassium Monitoring Interval for CardioZen in Chronic Kidney Disease',
       'HealthOne Group Medication Safety Committee',
       DATE '2026-08-15', 'ACTIVE',
       'MEMORANDUM. Subject: Shortening of the potassium monitoring interval. '
       || 'Section 2 — Revised requirement: For patients receiving CardioZen who '
       || 'have a recorded diagnosis of chronic kidney disease, serum potassium '
       || 'must be checked every 60 days for the duration of therapy. This '
       || 'replaces the three-month interval published in SAFETY_DOC_007 '
       || 'section 3. SYNTHETIC DOCUMENT — NOT REAL MEDICAL GUIDANCE.',
       'LIVE-BEAT';

INSERT INTO CONF.CONF_SAFETY_DOCUMENT
  (DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT)
SELECT DOC_ID, TITLE, PUBLISHER, PUBLICATION_DATE, STATUS, FULL_TEXT
FROM RAW.RAW_SAFETY_DOCUMENT WHERE DOC_ID = 'SAFETY_DOC_008';

-- ---------------------------------------------------------------------------
-- STEP 2 — a proposal appears.
--
-- In the intended design this row is written by AI_COMPLETE reading the
-- document (sql/08). Cortex is blocked on this trial account, so it is
-- written by hand and stamped MODEL_NAME='manual-seed' so nothing in the
-- system claims a model produced it. The row is INERT either way: a proposal
-- affects no patient until a human approves it.
-- ---------------------------------------------------------------------------
DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID = 'PRP-SEED-008';

INSERT INTO RULES.RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, REVIEW_REASON, STATUS)
SELECT 'PRP-SEED-008', 'SAFETY_DOC_008', 'manual-seed', 'n/a', CURRENT_TIMESTAMP(),
       'CardioZen', 'condition', 'chronic kidney disease', 'serum potassium',
       60, 'must be checked every 60 days', DATE '2026-08-15', 'section 2',
       TRUE,
       'Tightens an existing ACTIVE rule for the same drug, condition and test. The approver must decide supersede vs keep-both.',
       'PROPOSED';

-- ---------------------------------------------------------------------------
-- STEP 3 — the human approves. TWO writes, and the order matters.
--
-- Rules are immutable: v1 is not edited. It is marked SUPERSEDED and a new
-- immutable v2 row is inserted. Cases created under v1 keep pointing at v1,
-- so history stays interpretable.
-- ---------------------------------------------------------------------------
UPDATE RULES.SAFETY_RULE
   SET STATUS = 'SUPERSEDED', SUPERSEDED_BY_VERSION = 2
 WHERE RULE_ID = 'RUL-001' AND VERSION = 1;

DELETE FROM RULES.SAFETY_RULE WHERE RULE_ID = 'RUL-001' AND VERSION = 2;
INSERT INTO RULES.SAFETY_RULE
  (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
   CONDITION_ID, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
   INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
   STATUS, APPROVED_BY)
SELECT 'RUL-001', 2, 'PRP-SEED-008', 'DRG-CARDIOZEN', 'CONDITION',
       'CND-CKD', 'LAB-K', 60, 7,
       'must be checked every 60 days', DATE '2026-08-15',
       'SAFETY_DOC_008', 'section 2', 'ACTIVE', 'priya.r';

UPDATE RULES.RULE_PROPOSAL
   SET STATUS = 'APPROVED', REVIEWED_BY = 'priya.r', REVIEWED_AT = CURRENT_TIMESTAMP()
 WHERE PROPOSAL_ID = 'PRP-SEED-008';

INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'RULE_SUPERSEDED', 'priya.r', 'RULE', 'RUL-001',
       OBJECT_CONSTRUCT('from_version', 1, 'to_version', 2,
                        'old_interval_days', 90, 'new_interval_days', 60,
                        'doc_id', 'SAFETY_DOC_008',
                        'reason', 'Guidance tightened; v1 superseded, not edited');

SELECT RULE_ID, VERSION, INTERVAL_DAYS, GRACE_DAYS, EFFECTIVE_DATE, STATUS,
       SUPERSEDED_BY_VERSION, APPROVED_BY
FROM RULES.SAFETY_RULE WHERE RULE_ID = 'RUL-001' ORDER BY VERSION;

-- ---------------------------------------------------------------------------
-- STEP 4 — nothing has changed in the queue yet. Detection is not automatic:
-- every dynamic table is SCHEDULER = DISABLE (docs/02 §5, a cost guardrail),
-- so the queue only moves when someone runs the refresh cascade. In the app
-- that is the [Refresh queue] button. Run sql/07_refresh_action.sql next,
-- then sql/06b_reconciler.sql to rebuild the evidence.
-- ---------------------------------------------------------------------------
