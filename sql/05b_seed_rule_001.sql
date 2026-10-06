-- STATUS: EXECUTED 2026-08-24 via build/run_all.sql — ran clean against the account.
--
-- Seeds RUL-001 v1: CardioZen + chronic kidney disease -> serum potassium,
-- every 90 days, grace 7, effective 2026-03-01, from SAFETY_DOC_007 section 3.
--
-- WHY THIS IS SEEDED BY HAND RATHER THAN EXTRACTED:
-- The AI extraction step (sql/08) is blocked — every Cortex AI function is
-- disabled on this trial account. Seeding the hero rule manually keeps the
-- ENTIRE critical path (detection, reconciler, citations, disposition, the
-- app) working and demonstrable regardless of how that blocker resolves. The
-- proposal row is written too, with MODEL_NAME='manual-seed', so the lineage
-- document -> proposal -> rule is intact and honest about its own origin.
-- Nothing here pretends a model produced it.
--
-- Idempotent: DELETEs its own rows first, so it can be re-run.
-- Requires: SAFETY_DOC_007 present in CONF.CONF_SAFETY_DOCUMENT.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

DELETE FROM SAFETY_RULE   WHERE RULE_ID = 'RUL-001';
DELETE FROM RULE_PROPOSAL WHERE PROPOSAL_ID = 'PRP-SEED-001';

INSERT INTO RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, STATUS, REVIEWED_BY, REVIEWED_AT)
SELECT
  'PRP-SEED-001', 'SAFETY_DOC_007', 'manual-seed', 'n/a', CURRENT_TIMESTAMP(),
  'CardioZen', 'condition', 'chronic kidney disease', 'serum potassium',
  90, 'checked at least every three months', DATE '2026-03-01', 'section 3',
  FALSE, 'APPROVED', 'aman', CURRENT_TIMESTAMP()
WHERE EXISTS (SELECT 1 FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID = 'SAFETY_DOC_007');

INSERT INTO SAFETY_RULE
  (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
   CONDITION_ID, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
   INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
   STATUS, APPROVED_BY)
SELECT
  'RUL-001', 1, 'PRP-SEED-001', 'DRG-CARDIOZEN', 'CONDITION',
  'CND-CKD', 'LAB-K', 90, 7,
  'checked at least every three months', DATE '2026-03-01',
  'SAFETY_DOC_007', 'section 3', 'ACTIVE', 'aman'
WHERE EXISTS (SELECT 1 FROM RULE_PROPOSAL WHERE PROPOSAL_ID = 'PRP-SEED-001');

INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'RULE_APPROVED', 'aman', 'RULE', 'RUL-001',
       OBJECT_CONSTRUCT('version', 1, 'doc_id', 'SAFETY_DOC_007',
                        'interval_days', 90, 'grace_days', 7,
                        'origin', 'manual seed — Cortex extraction blocked on trial account')
WHERE EXISTS (SELECT 1 FROM SAFETY_RULE WHERE RULE_ID='RUL-001' AND VERSION=1);

SELECT RULE_ID, VERSION, DRUG_ID, CONDITION_ID, LAB_TEST_ID,
       INTERVAL_DAYS, GRACE_DAYS, EFFECTIVE_DATE, STATUS, APPROVED_BY
FROM SAFETY_RULE ORDER BY RULE_ID, VERSION;
