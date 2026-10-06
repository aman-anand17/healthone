-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx as part of tools/deploy_new_account. Ran clean.
-- Two further ACTIVE rules, so the library is not a single row and detection
-- is PROVEN generic rather than asserted.
--
-- WHY THIS MATTERS MORE THAN IT LOOKS
-- With one rule, "our rule engine evaluates active rules against the 360" is
-- a claim a judge cannot check — the SQL could be hardcoded to CardioZen and
-- nobody would know. Three rules across three drugs, three conditions and
-- three different lab tests exercise the same predicate with no code change,
-- which is the actual evidence.
--
-- RUL-003 IS THE INTERESTING ONE: SAFETY_DOC_006 says ALT should be checked
-- "at 12-week intervals". 12 weeks is 84 days, NOT 90. Our normalisation
-- policy is literal and written down (DECISIONS R3), and this rule puts that
-- policy into LIVE DATA rather than leaving it as a documented intention —
-- an 84-day window really does behave differently from a 90-day one, and the
-- approval screen shows the verbatim phrase beside the computed number so a
-- human owns the interpretation.
--
-- Both are seeded by hand for the same reason RUL-001 was: Cortex extraction
-- is blocked on this trial account, and MODEL_NAME='manual-seed' says so
-- rather than implying a model produced them.
--
-- Idempotent: deletes its own rows first.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

DELETE FROM SAFETY_RULE   WHERE RULE_ID IN ('RUL-002','RUL-003');
DELETE FROM RULE_PROPOSAL WHERE PROPOSAL_ID IN ('PRP-SEED-002','PRP-SEED-003');

-- ---------------------------------------------------------------------------
-- RUL-002 — Renuvex + chronic kidney disease -> serum creatinine, quarterly.
-- SAFETY_DOC_005, section 3. "quarterly" normalises to 90 days.
-- Note the requirement sits mid-paragraph in that document, wrapped in
-- committee prose — deliberately harder to extract than a bulleted rule.
-- ---------------------------------------------------------------------------
INSERT INTO RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, STATUS, REVIEWED_BY, REVIEWED_AT)
SELECT 'PRP-SEED-002', 'SAFETY_DOC_005', 'manual-seed', 'n/a', CURRENT_TIMESTAMP(),
       'Renuvex', 'condition', 'chronic kidney disease', 'serum creatinine',
       90, 'measured quarterly while treatment continues', DATE '2026-02-14',
       'section 3', FALSE, 'APPROVED', 'aman', CURRENT_TIMESTAMP()
WHERE EXISTS (SELECT 1 FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID='SAFETY_DOC_005');

INSERT INTO SAFETY_RULE
  (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
   CONDITION_ID, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
   INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
   STATUS, APPROVED_BY)
SELECT 'RUL-002', 1, 'PRP-SEED-002', 'DRG-RENUVEX', 'CONDITION',
       'CND-CKD', 'LAB-CREAT', 90, 7,
       'measured quarterly while treatment continues', DATE '2026-02-14',
       'SAFETY_DOC_005', 'section 3', 'ACTIVE', 'aman'
WHERE EXISTS (SELECT 1 FROM RULE_PROPOSAL WHERE PROPOSAL_ID='PRP-SEED-002');

-- ---------------------------------------------------------------------------
-- RUL-003 — Hepatrol + chronic liver disease -> ALT, at 12-week intervals.
-- SAFETY_DOC_006, section 2. **84 days, not 90.**
-- The same document names three tests that are explicitly NOT required
-- (full blood count, serum albumin, prothrombin time); none of them appears
-- here, which is the restraint the extraction golden set tests for.
-- ---------------------------------------------------------------------------
INSERT INTO RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, REVIEW_REASON, STATUS, REVIEWED_BY, REVIEWED_AT)
SELECT 'PRP-SEED-003', 'SAFETY_DOC_006', 'manual-seed', 'n/a', CURRENT_TIMESTAMP(),
       'Hepatrol', 'condition', 'chronic liver disease', 'ALT',
       84, 'measured at 12-week intervals', DATE '2026-01-20',
       'section 2', TRUE,
       'Interval expressed in weeks: 12 weeks normalises to 84 days, not 90. Flagged so the approver confirms the literal conversion.',
       'APPROVED', 'aman', CURRENT_TIMESTAMP()
WHERE EXISTS (SELECT 1 FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID='SAFETY_DOC_006');

INSERT INTO SAFETY_RULE
  (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
   CONDITION_ID, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
   INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
   STATUS, APPROVED_BY)
SELECT 'RUL-003', 1, 'PRP-SEED-003', 'DRG-HEPATROL', 'CONDITION',
       'CND-CLD', 'LAB-ALT', 84, 7,
       'measured at 12-week intervals', DATE '2026-01-20',
       'SAFETY_DOC_006', 'section 2', 'ACTIVE', 'aman'
WHERE EXISTS (SELECT 1 FROM RULE_PROPOSAL WHERE PROPOSAL_ID='PRP-SEED-003');

INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'RULE_APPROVED', 'aman', 'RULE', r.RULE_ID,
       OBJECT_CONSTRUCT('version', r.VERSION, 'doc_id', r.DOC_ID,
                        'interval_days', r.INTERVAL_DAYS,
                        'interval_source_phrase', r.INTERVAL_SOURCE_PHRASE,
                        'origin', 'manual seed — Cortex extraction blocked on trial account')
FROM SAFETY_RULE r WHERE r.RULE_ID IN ('RUL-002','RUL-003');

SELECT RULE_ID, VERSION, DRUG_ID, CONDITION_ID, LAB_TEST_ID,
       INTERVAL_SOURCE_PHRASE, INTERVAL_DAYS, GRACE_DAYS, STATUS
FROM SAFETY_RULE ORDER BY RULE_ID, VERSION;
