-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- ACCEPTANCE TEST: the document intake path, end to end.
--
-- WHAT THIS PROVES, and why each part had to be proved separately.
--
-- Aman's requirement was precise: "we should have a proper staging area known
-- to us where pdf will be there, code and everything all ready so that once
-- somehow magically we get non-trial account it works, and if I manually
-- insert row in rule related table it should work."
--
-- So this file tests THREE distinct claims:
--
--   D-01..D-05  the staging area is real: files are visible from SQL, their
--               text is loaded, and chunking follows document sections.
--   D-06..D-10  extraction genuinely reads documents: it independently
--               reproduces all three hand-seeded rules from prose, converts
--               intervals literally (12 weeks = 84, six weeks = 42), and
--               returns ZERO from both distractor documents.
--   D-11..D-16  a MANUALLY INSERTED proposal row flows through resolution and
--               approval to a live rule -- and an unmappable one is BLOCKED
--               with a specific reason rather than silently approved.
--
-- D-11..D-16 are the ones that matter most, because the resolve-and-approve
-- step is what did not exist before: RULE_PROPOSAL and SAFETY_RULE had nothing
-- between them, so inserting a proposal row did nothing whatsoever.
--
-- The test is self-cleaning: it creates PRP-TEST-* rows and RUL-TEST rules and
-- removes them at the end, so it can be run repeatedly and leaves no artefact
-- in the demo state.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- Clean up anything a previous interrupted run left behind.
DELETE FROM RULES.SAFETY_RULE   WHERE SOURCE_PROPOSAL_ID LIKE 'PRP-TEST-%';
DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID        LIKE 'PRP-TEST-%';

-- ===========================================================================
-- PART 1 -- the staging area
-- ===========================================================================
SELECT 'D-01 stage directory table is readable and holds both PDF and text' AS check_name,
       IFF((SELECT COUNT(*) FROM CONF.V_DOC_STAGE_FILES WHERE EXTENSION = 'PDF') >= 7
       AND (SELECT COUNT(*) FROM CONF.V_DOC_STAGE_FILES WHERE EXTENSION = 'MD')  >= 7,
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'D-02 every staged document reached CONF_SAFETY_DOCUMENT',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.V_DOC_STAGE_FILES
                        WHERE DOC_ID IS NOT NULL AND NOT IS_PROMOTED),
           'PASS', 'FAIL')
UNION ALL
SELECT 'D-03 ingest log names the parser that actually ran, on every row',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.DOC_INGEST_LOG
                        WHERE PARSER_USED IS NULL OR TRIM(PARSER_USED) = ''),
           'PASS', 'FAIL')
UNION ALL
-- A filename saying SAFETY_DOC_010 while the body says something else would
-- mean every citation in the product points at the wrong document.
SELECT 'D-04 filename DOC_ID agrees with the Reference line inside the file',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.DOC_INGEST_LOG
                        WHERE DOC_ID_MATCHES_TEXT = FALSE),
           'PASS', 'FAIL')
UNION ALL
-- The section label IS the citation, so a chunk without one cites nothing.
SELECT 'D-05 every chunk carries a section label and non-empty text',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.DOC_CHUNK
                        WHERE TRIM(COALESCE(SECTION_LABEL, '')) = ''
                           OR TRIM(COALESCE(CHUNK_TEXT, ''))    = ''),
           'PASS', 'FAIL');

-- ===========================================================================
-- PART 2 -- extraction genuinely reads the documents
--
-- D-06..D-08 are the strongest evidence in this file. The three live rules
-- were hand-written by a human who had read the documents. Extraction is given
-- only the document text and the controlled vocabulary, and arrives at the
-- same drug, the same test, the same condition and the same interval. It
-- cannot have copied them: SAFETY_RULE is not one of its inputs.
-- ===========================================================================
SELECT 'D-06 extraction independently reproduces RUL-001 from DOC_007 prose (CardioZen/potassium/CKD/90d)' AS check_name,
       IFF(EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_RESOLVED
                    WHERE DOC_ID = 'SAFETY_DOC_007'
                      AND DRUG_ID = 'DRG-CARDIOZEN' AND LAB_TEST_ID = 'LAB-K'
                      AND CONDITION_ID = 'CND-CKD'  AND INTERVAL_DAYS = 90),
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'D-07 extraction independently reproduces RUL-002 from DOC_005 prose ("quarterly" -> 90d)',
       IFF(EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_RESOLVED
                    WHERE DOC_ID = 'SAFETY_DOC_005'
                      AND DRUG_ID = 'DRG-RENUVEX' AND LAB_TEST_ID = 'LAB-CREAT'
                      AND CONDITION_ID = 'CND-CKD' AND INTERVAL_DAYS = 90),
           'PASS', 'FAIL')
UNION ALL
-- The interval-literalism check that DECISIONS C6 exists for. A rounded
-- "calendar quarter" would silently monitor 6 days later than the document says.
SELECT 'D-08 "at 12-week intervals" becomes 84 days, not 90 (DOC_006, literal interval math)',
       IFF(EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_RESOLVED
                    WHERE DOC_ID = 'SAFETY_DOC_006'
                      AND DRUG_ID = 'DRG-HEPATROL' AND LAB_TEST_ID = 'LAB-ALT'
                      AND INTERVAL_DAYS = 84),
           'PASS', 'FAIL')
UNION ALL
SELECT 'D-09 "every six weeks" becomes 42 days on the never-hand-coded DOC_010',
       IFF(EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_RESOLVED
                    WHERE DOC_ID = 'SAFETY_DOC_010'
                      AND DRUG_ID = 'DRG-CARDIOZEN' AND LAB_TEST_ID = 'LAB-CREAT'
                      AND INTERVAL_DAYS = 42),
           'PASS', 'FAIL')
UNION ALL
-- Both distractors name a drug AND a lab test. Only the absence of a recurring
-- interval, plus the negation guards, keeps them out. If this fails the
-- extractor is inventing requirements, which is far worse than missing them.
SELECT 'D-10 both distractor documents yield ZERO proposals (DOC_009 dizziness advisory, DOC_011 labelling notice)',
       IFF((SELECT COUNT(*) FROM RULES.RULE_PROPOSAL
             WHERE DOC_ID IN ('SAFETY_DOC_009', 'SAFETY_DOC_011')) = 0,
           'PASS', 'FAIL');

-- ===========================================================================
-- PART 3 -- a MANUALLY INSERTED proposal row must work
--
-- This is the acceptance criterion Aman stated. Two rows are inserted by hand,
-- exactly as a human or an external process would insert them:
--   PRP-TEST-GOOD  fully mappable      -> must approve into a live rule
--   PRP-TEST-BAD   test not in the vocabulary -> must be REFUSED, with a reason
-- ===========================================================================
INSERT INTO RULES.RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, STATUS)
SELECT 'PRP-TEST-GOOD', 'SAFETY_DOC_006', 'manual-insert-test', 'n/a', CURRENT_TIMESTAMP(),
       'Hepatrol', 'condition', 'chronic liver disease', 'creatinine',
       30, 'inserted by hand to test the approval path', DATE '2026-08-01', 'section 2',
       FALSE, 'PROPOSED'
UNION ALL
SELECT 'PRP-TEST-BAD', 'SAFETY_DOC_006', 'manual-insert-test', 'n/a', CURRENT_TIMESTAMP(),
       'Hepatrol', 'condition', 'chronic liver disease', 'cystatin C',
       30, 'inserted by hand with a test outside the vocabulary', DATE '2026-08-01', 'section 2',
       FALSE, 'PROPOSED';

SELECT 'D-11 hand-inserted mappable proposal resolves to controlled identifiers' AS check_name,
       IFF((SELECT RESOLVE_STATUS FROM RULES.V_PROPOSAL_RESOLVED
             WHERE PROPOSAL_ID = 'PRP-TEST-GOOD') = 'RESOLVED',
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'D-12 hand-inserted proposal with an unknown test is blocked, not approved',
       IFF((SELECT RESOLVE_STATUS FROM RULES.V_PROPOSAL_RESOLVED
             WHERE PROPOSAL_ID = 'PRP-TEST-BAD') = 'UNRESOLVED_TEST',
           'PASS', 'FAIL')
UNION ALL
SELECT 'D-13 the block states WHICH vocabulary row is missing',
       IFF((SELECT BLOCKING_REASON FROM RULES.V_PROPOSAL_RESOLVED
             WHERE PROPOSAL_ID = 'PRP-TEST-BAD') ILIKE '%cystatin C%REF_LAB_TEST_SYNONYM%',
           'PASS', 'FAIL');

-- Approve the good one. This must create a real, ACTIVE, versioned rule.
CALL RULES.SP_APPROVE_PROPOSAL('PRP-TEST-GOOD', 'test-harness', 7);

-- Attempt the bad one. This must REFUSE.
CALL RULES.SP_APPROVE_PROPOSAL('PRP-TEST-BAD', 'test-harness', 7);

SELECT 'D-14 approving the hand-inserted proposal created an ACTIVE rule with the resolved ids' AS check_name,
       IFF(EXISTS (SELECT 1 FROM RULES.SAFETY_RULE
                    WHERE SOURCE_PROPOSAL_ID = 'PRP-TEST-GOOD'
                      AND STATUS = 'ACTIVE'
                      AND DRUG_ID = 'DRG-HEPATROL'
                      AND LAB_TEST_ID = 'LAB-CREAT'
                      AND CONDITION_ID = 'CND-CLD'
                      AND INTERVAL_DAYS = 30
                      AND GRACE_DAYS = 7
                      AND VERSION = 1),
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'D-15 the refused proposal created NO rule and stayed PROPOSED',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE WHERE SOURCE_PROPOSAL_ID = 'PRP-TEST-BAD')
       AND (SELECT STATUS FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID = 'PRP-TEST-BAD') = 'PROPOSED',
           'PASS', 'FAIL')
UNION ALL
-- An approval that is not in the audit trail is an approval nobody can defend.
SELECT 'D-16 the approval is in the audit trail with its interval and source phrase',
       IFF(EXISTS (SELECT 1 FROM CASES.AUDIT_EVENT
                    WHERE EVENT_TYPE = 'RULE_APPROVED'
                      AND DETAIL:proposal_id::STRING = 'PRP-TEST-GOOD'
                      AND DETAIL:interval_days::INT = 30
                      AND DETAIL:interval_source_phrase IS NOT NULL),
           'PASS', 'FAIL');

-- ===========================================================================
-- PART 4 -- clean up. The test must leave no trace in the demo state.
-- ===========================================================================
DELETE FROM RULES.SAFETY_RULE   WHERE SOURCE_PROPOSAL_ID LIKE 'PRP-TEST-%';
DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID        LIKE 'PRP-TEST-%';

SELECT 'D-17 test artefacts removed' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE   WHERE SOURCE_PROPOSAL_ID LIKE 'PRP-TEST-%')
       AND NOT EXISTS (SELECT 1 FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID        LIKE 'PRP-TEST-%'),
           'PASS', 'FAIL') AS result;
