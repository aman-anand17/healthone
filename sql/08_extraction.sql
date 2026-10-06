-- ===========================================================================
-- STATUS: SUPERSEDED 2026-08-30 by sql/24 + sql/25. NEVER EXECUTED.
--
-- DO NOT RUN THIS FILE. It is kept for one reason: it contains the reasoning
-- that produced the extraction design, and deleting it would delete the
-- record of a decision.
--
-- WHAT REPLACED IT, AND WHY
-- This file was rewritten into a full implementation once Cortex was confirmed
-- working, but it was never executed against an account. sql/24 and sql/25
-- were then built, deployed, and covered by the 17 checks in
-- tests/test_document_intake.sql. Running two extraction implementations
-- against the same tables would be a governance defect in a product whose
-- central claim is that you can always tell what produced a rule, so this one
-- is retired rather than kept as an alternative.
--
--   EXTRACTION_CONFIG      -> RULES.EXTRACTOR_CONFIG      (sql/24)
--   SP_EXTRACT_RULES       -> RULES.SP_EXTRACT_PROPOSALS  (sql/24)
--   V_PROPOSAL_RESOLUTION  -> RULES.V_PROPOSAL_RESOLVED   (sql/25)
--   V_PROPOSAL_INBOX       -> RULES.V_PROPOSAL_RESOLVED   (sql/25)
--   (nothing here)         -> RULES.SP_APPROVE_PROPOSAL   (sql/25) <- the step
--                             that did not exist anywhere until sql/25
--
-- WHAT WAS CARRIED ACROSS FROM THIS FILE, because it was right and sql/24 was
-- wrong:
--   * response_format with a pinned JSON schema was ADOPTED into sql/24 and
--     then WITHDRAWN, because it does not work for this payload. Tested:
--     AI_COMPLETE with a schema containing an ARRAY property returns NULL once
--     the prompt is document-length, while a flat schema works with the same
--     prompt and the same schema works with a short prompt. It fails by
--     returning NULL, not by raising - the same silent-zero failure this file's
--     successor is built to refuse. The idea was right; the platform does not
--     support it here yet, and that is recorded rather than quietly dropped.
--   * temperature 0, for the reproducibility this whole product rests on.
--   * the interval-normalisation instruction, including TWELVE WEEKS = 84.
--
-- WHAT sql/24 ADDED that this file did not have:
--   * RULES.EXTRACTION_RUN - the raw model response is stored BEFORE anything
--     tries to read it, with PARSED_OK, so "found nothing" and "could not be
--     read" can never look the same again.
--   * a second, entitlement-free PATTERN backend behind the same output
--     contract, so the product is not dead on an un-entitled account.
-- ===========================================================================

-- ===== ORIGINAL CONTENT BELOW, FOR THE RECORD - DO NOT RUN =====
-- AI_COMPLETE is confirmed working (`claude-sonnet-5` returned "OK"), so this
-- file is no longer theoretical. It stays DRAFT until the project journal records an
-- `executed:` line against the new account.
--
-- WHAT THIS IS
-- The one genuinely-AI step in the product: prose safety guidance -> a
-- structured, inert rule PROPOSAL. Nothing here touches SAFETY_RULE, so
-- nothing here can affect a single patient. A proposal becomes a rule only
-- when a named human approves it (sql/13).
--
-- WHY THE PREVIOUS VERSION OF THIS FILE WOULD HAVE FAILED
-- Its INSERT column list omitted MODEL_NAME, PROMPT_VERSION and EXTRACTED_AT
-- — all three NOT NULL in RULES.RULE_PROPOSAL (sql/05). It also used a
-- `:target_doc_id` bind that has no binder when run via `snow sql -f`. Both
-- are fixed by making this a procedure with a real parameter.
--
-- FOUR THINGS THAT MAKE THE OUTPUT TRUSTWORTHY
-- 1. `response_format` pins a JSON schema, so the model cannot return prose,
--    markdown fences or a differently-shaped object. Malformed JSON stops
--    being a failure mode we have to defend against.
-- 2. `temperature: 0` — the project's whole thesis is reproducibility. A
--    non-deterministic extraction step would make the golden tests a lie.
-- 3. The model emits TEXT ('CardioZen', 'serum potassium'), never an internal
--    id. Text is resolved against the controlled vocabulary by SQL in
--    V_PROPOSAL_RESOLUTION below. A model that hallucinates a drug produces an
--    UNRESOLVED proposal that cannot be approved — it does not silently invent
--    a DRUG_ID.
-- 4. Re-running deletes only prior PROPOSED rows for the same
--    (doc, model, prompt_version). APPROVED and REJECTED proposals are
--    history and are never deleted.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

-- ============================================================================
-- EXTRACTION_CONFIG — ONE place that names the model.
-- CLAUDE.md hard constraint #1 requires the entitled model and a GA fallback
-- to be recorded. Recording them as data rather than as a literal buried in a
-- procedure body means "which model produced this rule?" is answerable by
-- query, and switching models is an UPDATE, not a redeploy.
-- ============================================================================
CREATE TABLE IF NOT EXISTS EXTRACTION_CONFIG (
  CONFIG_KEY    VARCHAR(60)  NOT NULL,
  CONFIG_VALUE  VARCHAR(200) NOT NULL,
  NOTE          VARCHAR(500),
  UPDATED_AT    TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (CONFIG_KEY)
);

DELETE FROM EXTRACTION_CONFIG;
INSERT INTO EXTRACTION_CONFIG (CONFIG_KEY, CONFIG_VALUE, NOTE) VALUES
  ('MODEL_NAME',      'claude-sonnet-5',
   'Verified working on this account 2026-08-30. Capable enough for prose->rule, cheap enough for a metered trial.'),
  ('FALLBACK_MODEL',  'claude-haiku-4-5',
   'GA fallback per CLAUDE.md constraint 1. Use if sonnet-5 is unavailable or credits run short.'),
  ('PROMPT_VERSION',  'v1',
   'Bump on ANY prompt edit. RULE_PROPOSAL.PROMPT_VERSION records which text produced a row.'),
  ('TEMPERATURE',     '0',
   'Determinism is not optional here — the golden suite pins expected output.');

-- ============================================================================
-- SP_EXTRACT_RULES(doc_id) — read one document, write zero or more PROPOSED
-- rows. Returns a JSON summary so the caller (app or CLI) can report honestly.
--
-- ZERO RULES IS A CORRECT ANSWER, NOT A FAILURE. SAFETY_DOC_009 is a
-- deliberate distractor: it names laboratory tests while stating no recurring
-- requirement. If this procedure returns rules_extracted = 0 for it, the
-- prompt is working. Do not "fix" the distractor.
-- ============================================================================
CREATE OR REPLACE PROCEDURE SP_EXTRACT_RULES(P_DOC_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Document -> AI_COMPLETE -> inert RULE_PROPOSAL rows. Never writes SAFETY_RULE.'
AS
$$
DECLARE
  v_model      VARCHAR;
  v_prompt_ver VARCHAR;
  v_temp       FLOAT;
  v_text       VARCHAR;
  v_raw        VARIANT;
  v_json       VARIANT;
  v_n          INT DEFAULT 0;
  v_review     INT DEFAULT 0;
BEGIN
  SELECT CONFIG_VALUE INTO :v_model      FROM EXTRACTION_CONFIG WHERE CONFIG_KEY = 'MODEL_NAME';
  SELECT CONFIG_VALUE INTO :v_prompt_ver FROM EXTRACTION_CONFIG WHERE CONFIG_KEY = 'PROMPT_VERSION';
  SELECT TO_DOUBLE(CONFIG_VALUE) INTO :v_temp FROM EXTRACTION_CONFIG WHERE CONFIG_KEY = 'TEMPERATURE';

  SELECT FULL_TEXT INTO :v_text
    FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID = :P_DOC_ID;

  IF (v_text IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'doc_id', :P_DOC_ID,
                            'error', 'No such document in CONF.CONF_SAFETY_DOCUMENT');
  END IF;

  -- --------------------------------------------------------------------------
  -- The extraction call.
  --
  -- The prompt is mostly NEGATIVE instruction, which is where extraction
  -- accuracy actually comes from. A safety document names lab tests in many
  -- roles: describing an adverse effect, reporting a one-off measurement at
  -- enrolment, explicitly declining to require routine testing. Only one of
  -- those is a recurring monitoring requirement. Without the exclusions the
  -- model returns a rule for every test it sees, and the queue fills with
  -- surveillance nobody asked for.
  --
  -- Interval arithmetic is stated LITERALLY and the model is told never to
  -- round, because "12 weeks" is 84 days and a model that helpfully rounds to
  -- 90 silently loses six days of patient safety margin. RUL-003 is exactly
  -- this case, and the UI shows the source phrase beside the number so a
  -- human owns the interpretation.
  -- --------------------------------------------------------------------------
  SELECT AI_COMPLETE(
    model  => :v_model,
    prompt => 'You are extracting recurring laboratory monitoring requirements from a medication safety document.

A monitoring requirement exists ONLY when the document states that a specific laboratory test should be repeated on a recurring interval for a specific medication. Everything else is context.

Do NOT create a rule when:
- a test is named only to describe findings, mechanisms or adverse effects;
- the document says a test is not routinely required, or declines to extend a requirement;
- a test was performed once, at enrolment, or as a one-off investigation;
- the text describes a symptom, a warning, or a reporting process.

Interval normalization, LITERAL — never round:
  quarterly = 90; every three months = 90; every N months = N*30;
  every N weeks = N*7; every N days = N.  TWELVE WEEKS = 84, NOT 90.
If the wording does not fit these rules, give your best integer and set
needs_review = true with a short review_reason.

Report drug names, test names and conditions EXACTLY as the document prints
them. Do not translate them into codes or identifiers.
source_passage must be the section number or heading the requirement came from.
interval_source_phrase must be VERBATIM from the document, under 15 words.
If the document contains no recurring monitoring requirement, return an empty
rules array.

Document text follows:
' || :v_text,
    model_parameters => OBJECT_CONSTRUCT('temperature', :v_temp, 'max_tokens', 4096),
    response_format  => {
      'type': 'json',
      'schema': {
        'type': 'object',
        'properties': {
          'source_doc': {'type': 'string'},
          'rules': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'drug':                   {'type': 'string'},
                'precondition_type':      {'type': 'string'},
                'precondition_value':     {'type': 'string'},
                'required_test':          {'type': 'string'},
                'interval_days':          {'type': 'number'},
                'interval_source_phrase': {'type': 'string'},
                'effective_date':         {'type': 'string'},
                'source_passage':         {'type': 'string'},
                'needs_review':           {'type': 'boolean'},
                'review_reason':          {'type': 'string'}
              },
              'required': ['drug', 'required_test', 'interval_days',
                           'interval_source_phrase', 'source_passage']
            }
          }
        },
        'required': ['source_doc', 'rules']
      }
    }
  ) INTO :v_raw;

  -- AI_COMPLETE with response_format returns structured output, but be
  -- defensive about whether it arrives as an OBJECT or as a JSON string —
  -- and strip markdown fences in the string case, in case a future model
  -- wraps its own valid JSON.
  IF (TYPEOF(:v_raw) = 'VARCHAR') THEN
    v_json := TRY_PARSE_JSON(
                REGEXP_REPLACE(:v_raw::STRING, '^\\s*```(json)?|```\\s*$', ''));
  ELSE
    v_json := :v_raw;
  END IF;

  IF (v_json IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'doc_id', :P_DOC_ID, 'model', :v_model,
                            'error', 'Model output was not parseable JSON',
                            'raw', TO_VARCHAR(:v_raw));
  END IF;

  -- Re-run hygiene: clear only our own un-reviewed output. A proposal a human
  -- has already APPROVED or REJECTED is a decision record, not a cache entry.
  DELETE FROM RULE_PROPOSAL
   WHERE DOC_ID = :P_DOC_ID
     AND MODEL_NAME = :v_model
     AND PROMPT_VERSION = :v_prompt_ver
     AND STATUS = 'PROPOSED';

  INSERT INTO RULE_PROPOSAL
    (PROPOSAL_ID, DOC_ID, RAW_LLM_OUTPUT, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
     DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
     INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
     NEEDS_REVIEW, REVIEW_REASON, STATUS)
  SELECT
    'PRP-' || UUID_STRING(),
    :P_DOC_ID,
    :v_json,
    :v_model,
    :v_prompt_ver,
    CURRENT_TIMESTAMP(),
    r.value:drug::STRING,
    LOWER(NULLIF(r.value:precondition_type::STRING, '')),
    LOWER(NULLIF(r.value:precondition_value::STRING, '')),
    r.value:required_test::STRING,
    r.value:interval_days::INT,
    r.value:interval_source_phrase::STRING,
    -- A model-supplied date that is not a date must not abort the run; fall
    -- back to the document's own publication date, which is the honest
    -- default for "when does this take effect".
    COALESCE(TRY_TO_DATE(r.value:effective_date::STRING),
             (SELECT PUBLICATION_DATE FROM CONF.CONF_SAFETY_DOCUMENT
               WHERE DOC_ID = :P_DOC_ID)),
    r.value:source_passage::STRING,
    COALESCE(r.value:needs_review::BOOLEAN, FALSE),
    NULLIF(r.value:review_reason::STRING, ''),
    'PROPOSED'
  FROM LATERAL FLATTEN(input => :v_json:rules) r;

  v_n := SQLROWCOUNT;

  SELECT COUNT(*) INTO :v_review
    FROM RULE_PROPOSAL
   WHERE DOC_ID = :P_DOC_ID AND MODEL_NAME = :v_model
     AND PROMPT_VERSION = :v_prompt_ver AND STATUS = 'PROPOSED'
     AND NEEDS_REVIEW = TRUE;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULES_EXTRACTED', CURRENT_USER(), 'DOCUMENT', :P_DOC_ID,
         OBJECT_CONSTRUCT('model', :v_model, 'prompt_version', :v_prompt_ver,
                          'temperature', :v_temp,
                          'rules_extracted', :v_n,
                          'flagged_needs_review', :v_review,
                          'note', 'Proposals are inert. No SAFETY_RULE row was written.');

  CALL CASES.SEAL_AUDIT_CHAIN();

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'doc_id', :P_DOC_ID, 'model', :v_model,
                          'prompt_version', :v_prompt_ver,
                          'rules_extracted', :v_n,
                          'flagged_needs_review', :v_review);
END;
$$;

-- ============================================================================
-- V_PROPOSAL_RESOLUTION — the approval gate, as a view.
--
-- The model returns TEXT. This resolves that text against the controlled
-- vocabulary and states, per proposal, whether it CAN be approved. A drug the
-- vocabulary does not know, or a test spelling nobody mapped, surfaces as
-- UNRESOLVED with the specific field named — it never becomes a rule.
--
-- This is the concrete answer to "what stops the model inventing a rule?":
-- a hallucinated drug has no DRUG_ID, so there is nothing to insert.
--
-- Lab-test matching intentionally reuses REF_LAB_TEST_SYNONYM, the SAME
-- vocabulary join that detection uses — so a spelling the extractor resolves
-- is exactly a spelling detection can act on. Two different matchers here
-- would let a rule be approved that detection could never evaluate.
-- ============================================================================
CREATE OR REPLACE VIEW V_PROPOSAL_RESOLUTION AS
SELECT
  p.PROPOSAL_ID,
  p.DOC_ID,
  p.STATUS,
  p.MODEL_NAME,
  p.PROMPT_VERSION,
  p.EXTRACTED_AT,
  p.DRUG_TEXT,
  d.DRUG_ID,
  p.PRECONDITION_TYPE,
  p.PRECONDITION_VALUE,
  c.CONDITION_ID,
  p.REQUIRED_TEST_TEXT,
  COALESCE(s.LAB_TEST_ID, t.LAB_TEST_ID) AS LAB_TEST_ID,
  p.INTERVAL_DAYS,
  p.INTERVAL_SOURCE_PHRASE,
  p.EFFECTIVE_DATE,
  p.SOURCE_PASSAGE,
  p.NEEDS_REVIEW,
  p.REVIEW_REASON,
  -- Every reason the proposal cannot be turned into a rule, named explicitly.
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(d.DRUG_ID IS NULL,
        'Unknown drug: ' || COALESCE(p.DRUG_TEXT, '(none given)'), NULL),
    IFF(COALESCE(s.LAB_TEST_ID, t.LAB_TEST_ID) IS NULL,
        'Unmapped lab test: ' || COALESCE(p.REQUIRED_TEST_TEXT, '(none given)'), NULL),
    IFF(p.PRECONDITION_TYPE = 'condition' AND c.CONDITION_ID IS NULL,
        'Unknown condition: ' || COALESCE(p.PRECONDITION_VALUE, '(none given)'), NULL),
    IFF(p.INTERVAL_DAYS IS NULL OR p.INTERVAL_DAYS <= 0,
        'Interval missing or not positive', NULL),
    -- age_min rules are representable but detection does not evaluate them
    -- (sql/06 filters PRECONDITION_TYPE = 'CONDITION'). Approving one would
    -- create a rule that silently never fires — worse than refusing it.
    IFF(p.PRECONDITION_TYPE = 'age_min',
        'age_min preconditions are not evaluated by detection in v1', NULL)
  )) AS BLOCKERS
FROM RULE_PROPOSAL p
LEFT JOIN CONF.REF_DRUG d
       ON LOWER(TRIM(d.DRUG_NAME)) = LOWER(TRIM(p.DRUG_TEXT))
LEFT JOIN CONF.REF_CONDITION c
       ON LOWER(TRIM(c.CONDITION_NAME)) = LOWER(TRIM(p.PRECONDITION_VALUE))
LEFT JOIN CONF.REF_LAB_TEST_SYNONYM s
       ON s.SYNONYM_TEXT = LOWER(TRIM(p.REQUIRED_TEST_TEXT))
LEFT JOIN CONF.REF_LAB_TEST t
       ON LOWER(TRIM(t.CANONICAL_NAME)) = LOWER(TRIM(p.REQUIRED_TEST_TEXT));

-- Convenience: the reviewer's inbox. Approvable proposals, worst-flagged first.
CREATE OR REPLACE VIEW V_PROPOSAL_INBOX AS
SELECT PROPOSAL_ID, DOC_ID, MODEL_NAME, DRUG_TEXT, REQUIRED_TEST_TEXT,
       PRECONDITION_VALUE, INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE,
       SOURCE_PASSAGE, NEEDS_REVIEW, REVIEW_REASON,
       DRUG_ID, CONDITION_ID, LAB_TEST_ID,
       ARRAY_SIZE(BLOCKERS) = 0 AS IS_APPROVABLE,
       BLOCKERS
FROM V_PROPOSAL_RESOLUTION
WHERE STATUS = 'PROPOSED'
ORDER BY IS_APPROVABLE, NEEDS_REVIEW DESC, EXTRACTED_AT DESC;

GRANT SELECT ON VIEW V_PROPOSAL_RESOLUTION TO ROLE HO_REVIEWER;
GRANT SELECT ON VIEW V_PROPOSAL_INBOX      TO ROLE HO_REVIEWER;
GRANT USAGE  ON PROCEDURE SP_EXTRACT_RULES(VARCHAR) TO ROLE HO_REVIEWER;

-- ============================================================================
-- VALIDATION — run these, do not just create the objects.
--
-- Expected, and each expectation is a real test of the prompt:
--   007  -> 1 rule,  serum potassium, 90 days, phrase mentions "three months"
--   005  -> 1 rule,  serum creatinine
--   006  -> 1 rule,  ALT, interval_days = 84  <-- the "12 weeks" trap
--   009  -> 0 rules                            <-- the distractor
-- A non-zero count for 009, or 90 for 006, means the prompt regressed.
-- ============================================================================
-- CALL SP_EXTRACT_RULES('SAFETY_DOC_007');
-- CALL SP_EXTRACT_RULES('SAFETY_DOC_005');
-- CALL SP_EXTRACT_RULES('SAFETY_DOC_006');
-- CALL SP_EXTRACT_RULES('SAFETY_DOC_009');
-- SELECT * FROM V_PROPOSAL_INBOX;
--
-- Compare the model against the hand-seeded rules already in SAFETY_RULE.
-- Agreement is the headline result; disagreement is the interesting one and
-- must be written into the project journal either way, not quietly re-prompted away.
-- SELECT r.RULE_ID, r.INTERVAL_DAYS AS human_days, v.INTERVAL_DAYS AS model_days,
--        r.INTERVAL_SOURCE_PHRASE AS human_phrase, v.INTERVAL_SOURCE_PHRASE AS model_phrase
--   FROM RULES.SAFETY_RULE r
--   JOIN V_PROPOSAL_RESOLUTION v
--     ON v.DOC_ID = r.DOC_ID AND v.LAB_TEST_ID = r.LAB_TEST_ID
--  WHERE r.STATUS = 'ACTIVE';
