-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- CUTOVER: every live rule becomes one a model read out of a document and a
-- human approved.
--
-- WHAT THIS REPLACES, and why it matters more than it sounds
-- Until now RUL-001, RUL-002 and RUL-003 were hand-typed INSERT statements
-- (sql/05b, sql/12). They were labelled honestly -- MODEL_NAME='manual-seed',
-- an audit row saying so -- but the product's headline claim is
--
--     AI proposes  ->  a human approves  ->  deterministic checks apply
--
-- and the first arrow was a person with a keyboard. Cortex is entitled on this
-- account, and sql/25 supplied the approve step that never existed, so the
-- claim can now simply be true.
--
-- After this file runs, every ACTIVE rule has:
--   * a SOURCE_PROPOSAL_ID pointing at a proposal
--   * that proposal stamped MODEL_NAME='claude-sonnet-5' with the prompt
--     version that produced it
--   * RAW_LLM_OUTPUT holding the model's actual JSON, kept, not discarded
--   * an APPROVED_BY naming the human, and a RULE_APPROVED audit event
--     carrying the interval and the verbatim source phrase
--
-- WHY THE APPROVAL ORDER IS FIXED
-- SP_APPROVE_PROPOSAL allocates a new rule id as max(existing)+1, so the order
-- in which proposals are approved determines the identifiers. The golden
-- detection suite asserts on RUL-001..RUL-003 by name. Approving in document
-- order below reproduces exactly those identifiers, so the tests keep their
-- meaning instead of being loosened to accommodate the change.
--
-- SAFE TO RE-RUN. It clears the rules and the rule-derived cases first, and
-- SP_RUN_PIPELINE rebuilds every case from DT_CASE_CANDIDATE afterwards.
-- Nothing here touches the 313 people or their clinical data.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. Clear the hand-seeded rules and everything derived from them.
--
-- CASE_EVIDENCE and CASE_NARRATIVE go first: they are children of
-- CASE_REGISTRY, and Snowflake does not enforce the foreign key, so leaving
-- them would leave evidence rows pointing at cases that no longer exist --
-- exactly the kind of orphan the data-quality metrics are there to catch.
-- ===========================================================================
DELETE FROM CASES.CASE_NARRATIVE;
DELETE FROM CASES.CASE_EVIDENCE;
DELETE FROM CASES.CASE_REGISTRY;
DELETE FROM RULES.SAFETY_RULE;
DELETE FROM RULES.RULE_PROPOSAL;

-- AUDIT_EVENT is deliberately NOT cleared. It is append-only and
-- tamper-evident (sql/11 hashes each row into a chain); deleting from it to
-- tidy up would be the single most dishonest thing this build could do. The
-- history of the hand-seeded rules stays visible, which is correct: it
-- happened.
INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'RULE_RETIRED', 'aman.anand', 'RULE', 'ALL-MANUAL-SEEDS',
       OBJECT_CONSTRUCT(
         'reason', 'Superseded by model-extracted, human-approved rules now that Cortex is entitled',
         'previous_origin', 'hand-typed INSERT in sql/05b and sql/12, MODEL_NAME=manual-seed',
         'replaced_by', 'AI_COMPLETE extraction via RULES.SP_EXTRACT_PROPOSALS + human approval via RULES.SP_APPROVE_PROPOSAL');

-- ===========================================================================
-- 2. Put the AI backend in force.
-- ===========================================================================
UPDATE RULES.EXTRACTOR_CONFIG
   SET BACKEND = 'AI_COMPLETE',
       MODEL_NAME = 'claude-sonnet-5',
       PROMPT_VERSION = 'v1',
       NOTE = 'Cortex AI_COMPLETE is entitled on this account (AI Data Cloud signup flow). Extraction reads the document with a Claude model using the prompt in RULES.PROMPT_TEMPLATE. The deterministic pattern UDF remains available and is what makes this a swappable component rather than a dependency.',
       UPDATED_AT = CURRENT_TIMESTAMP();

UPDATE CONF.DOC_PARSER_CONFIG
   SET PARSER_MODE = 'PARSE_DOCUMENT',
       REASON = 'Cortex is entitled on this account, so the PDF of record in RAW.DOC_STAGE is parsed directly by AI_PARSE_DOCUMENT in LAYOUT mode rather than a plain-text rendering standing in for it.',
       UPDATED_AT = CURRENT_TIMESTAMP();

-- ===========================================================================
-- 3. Ingest and extract. Stops at PROPOSED -- nothing is in force yet.
-- ===========================================================================
CALL RULES.SP_INGEST_EXTRACT_ALL('aman.anand', TRUE);

-- What the model actually said, before anyone approves anything.
SELECT DOC_ID, DRUG_TEXT, REQUIRED_TEST_TEXT, PRECONDITION_VALUE,
       INTERVAL_DAYS, SOURCE_PASSAGE, RESOLVE_STATUS,
       COALESCE(BLOCKING_REASON, '') AS BLOCKING_REASON,
       INTERVAL_SOURCE_PHRASE
FROM RULES.V_PROPOSAL_RESOLVED
WHERE STATUS = 'PROPOSED'
ORDER BY DOC_ID, INTERVAL_DAYS;

-- ===========================================================================
-- 4. Human approval, in document order so the rule identifiers are stable.
--
-- Each SET is keyed on the resolved identifiers AND the expected interval, not
-- on "the first proposal from this document". If the model returned something
-- different, the SET yields NULL and the approval fails loudly here rather
-- than quietly putting the wrong rule into force.
-- ===========================================================================

-- RUL-001: CardioZen + chronic kidney disease -> serum potassium, 90 days.
--          DOC_007 section 3: "checked at least every three months"
SET p1 = (SELECT PROPOSAL_ID FROM RULES.V_PROPOSAL_RESOLVED
           WHERE STATUS='PROPOSED' AND DOC_ID='SAFETY_DOC_007'
             AND DRUG_ID='DRG-CARDIOZEN' AND LAB_TEST_ID='LAB-K'
             AND CONDITION_ID='CND-CKD' AND INTERVAL_DAYS=90 LIMIT 1);
CALL RULES.SP_APPROVE_PROPOSAL($p1, 'aman.anand', 7);

-- RUL-002: Renuvex + chronic kidney disease -> serum creatinine, 90 days.
--          DOC_005 section 3: "measured quarterly"
SET p2 = (SELECT PROPOSAL_ID FROM RULES.V_PROPOSAL_RESOLVED
           WHERE STATUS='PROPOSED' AND DOC_ID='SAFETY_DOC_005'
             AND DRUG_ID='DRG-RENUVEX' AND LAB_TEST_ID='LAB-CREAT'
             AND CONDITION_ID='CND-CKD' AND INTERVAL_DAYS=90 LIMIT 1);
CALL RULES.SP_APPROVE_PROPOSAL($p2, 'aman.anand', 7);

-- RUL-003: Hepatrol + chronic liver disease -> ALT, 84 days.
--          DOC_006 section 2: "at 12-week intervals". 84, not 90. The
--          document says so explicitly and the interval math is literal.
SET p3 = (SELECT PROPOSAL_ID FROM RULES.V_PROPOSAL_RESOLVED
           WHERE STATUS='PROPOSED' AND DOC_ID='SAFETY_DOC_006'
             AND DRUG_ID='DRG-HEPATROL' AND LAB_TEST_ID='LAB-ALT'
             AND INTERVAL_DAYS=84 LIMIT 1);
CALL RULES.SP_APPROVE_PROPOSAL($p3, 'aman.anand', 7);

-- RUL-004: CardioZen + chronic kidney disease -> serum creatinine, 42 days.
--          DOC_010 section 3: "measured every six weeks". This document was
--          never hand-coded anywhere; it exists to prove the intake path
--          produces a rule nobody wrote by hand.
SET p4 = (SELECT PROPOSAL_ID FROM RULES.V_PROPOSAL_RESOLVED
           WHERE STATUS='PROPOSED' AND DOC_ID='SAFETY_DOC_010'
             AND DRUG_ID='DRG-CARDIOZEN' AND LAB_TEST_ID='LAB-CREAT'
             AND CONDITION_ID='CND-CKD' AND INTERVAL_DAYS=42 LIMIT 1);
CALL RULES.SP_APPROVE_PROPOSAL($p4, 'aman.anand', 7);

-- SAFETY_DOC_008 is left PROPOSED on purpose. It shortens the CardioZen
-- potassium interval from 90 days to 60, and approving it supersedes RUL-001
-- v1 with v2 and changes the queue. That is the live demo beat: it should be
-- performed in front of the audience, not pre-applied.

-- ===========================================================================
-- 5. Now run the pipeline, and see what the approved rules produce.
-- ===========================================================================
CALL CASES.SP_RUN_PIPELINE('AI_CUTOVER', TRUE, 'aman.anand');

SELECT r.RULE_ID, r.VERSION, d.DRUG_NAME, t.CANONICAL_NAME AS TEST,
       r.INTERVAL_DAYS, r.GRACE_DAYS, r.DOC_ID, r.SOURCE_PASSAGE,
       p.MODEL_NAME, r.APPROVED_BY, r.STATUS,
       (SELECT COUNT(*) FROM CASES.CASE_REGISTRY c
         WHERE c.RULE_ID = r.RULE_ID AND c.STATUS = 'OPEN') AS OPEN_CASES
FROM RULES.SAFETY_RULE r
JOIN RULES.RULE_PROPOSAL p ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
JOIN CONF.REF_DRUG d ON d.DRUG_ID = r.DRUG_ID
JOIN CONF.REF_LAB_TEST t ON t.LAB_TEST_ID = r.LAB_TEST_ID
ORDER BY r.RULE_ID, r.VERSION;

-- The claim that no rule is hand-made any more, as a query rather than a
-- sentence in a README.
SELECT 'Rules whose origin is NOT a model-produced proposal' AS check_name,
       COUNT(*) AS n
FROM RULES.SAFETY_RULE r
JOIN RULES.RULE_PROPOSAL p ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
WHERE r.STATUS = 'ACTIVE' AND p.MODEL_NAME NOT ILIKE 'claude%';
