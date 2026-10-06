-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- THE MISSING MIDDLE: proposal -> resolved IDs -> approved, versioned rule.
--
-- WHAT WAS ACTUALLY BROKEN
-- RULES.RULE_PROPOSAL existed and RULES.SAFETY_RULE existed, and there was
-- NOTHING BETWEEN THEM. All three live rules reached SAFETY_RULE as hand-typed
-- INSERT statements in sql/05b and sql/12, in which a human had already read
-- the document and worked out that "CardioZen" means DRG-CARDIOZEN, "serum
-- potassium" means LAB-K and "chronic kidney disease" means CND-CKD.
--
-- Consequence: inserting a row into RULE_PROPOSAL did nothing at all. The
-- product's central claim -- AI proposes, a human approves, deterministic
-- checks apply -- had no approve step. This file is that step.
--
-- Two pieces:
--   V_PROPOSAL_RESOLVED   resolves the extractor's free text to controlled
--                         identifiers and says, per proposal, whether it is
--                         approvable and if not exactly why.
--   SP_APPROVE_PROPOSAL   writes the versioned SAFETY_RULE row, supersedes the
--                         prior version when one exists, records the audit
--                         event, and returns what it did.
--
-- WHY RESOLUTION IS A SEPARATE, VISIBLE STEP RATHER THAN PART OF EXTRACTION
-- The extractor -- model or UDF -- reports what the document says, in the
-- document's words. Mapping those words onto governed identifiers is a
-- data-governance decision with a different failure mode: an unmapped test
-- name must BLOCK a rule, loudly, because a rule with the wrong LAB_TEST_ID
-- monitors the wrong thing forever and looks entirely healthy while doing it.
-- Keeping resolution in a view means the reviewer sees the mapping before
-- approving it, and an unmappable proposal names the missing vocabulary row.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. V_PROPOSAL_RESOLVED
--
-- Scalar subqueries rather than joins, deliberately: a synonym table join can
-- fan a proposal into several rows, and a reviewer screen that shows one
-- proposal three times is worse than useless.
-- ===========================================================================
CREATE OR REPLACE VIEW RULES.V_PROPOSAL_RESOLVED
COMMENT = 'Rule proposals with free text resolved to controlled identifiers, plus an explicit approvability verdict.'
AS
-- Ranked LEFT JOINs, not correlated scalar subqueries. The obvious way to
-- write this -- (SELECT ... ORDER BY ... LIMIT 1) per column -- is rejected by
-- Snowflake inside a view ("Unsupported subquery type cannot be evaluated
-- inside VIEW object"). QUALIFY ROW_NUMBER() gives the same one-row-per-
-- proposal guarantee, which matters because a synonym join can otherwise fan
-- one proposal into several rows on the reviewer screen.
WITH p AS (SELECT * FROM RULES.RULE_PROPOSAL),

drug_m AS (
  SELECT p.PROPOSAL_ID, d.DRUG_ID
    FROM p
    JOIN CONF.REF_DRUG d
      ON LOWER(TRIM(p.DRUG_TEXT)) = LOWER(d.DRUG_NAME)
      OR LOWER(TRIM(p.DRUG_TEXT)) LIKE '%' || LOWER(d.DRUG_NAME) || '%'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY p.PROPOSAL_ID
                             ORDER BY LENGTH(d.DRUG_NAME) DESC) = 1
),

-- Governed synonym first, canonical name second. The document says
-- "potassium"; the vocabulary says LAB-K; that mapping is a governed decision.
lab_m AS (
  SELECT PROPOSAL_ID, LAB_TEST_ID FROM (
    SELECT p.PROPOSAL_ID, s.LAB_TEST_ID, 1 AS PRI
      FROM p JOIN CONF.REF_LAB_TEST_SYNONYM s
        ON LOWER(TRIM(p.REQUIRED_TEST_TEXT)) = LOWER(s.SYNONYM_TEXT)
    UNION ALL
    SELECT p.PROPOSAL_ID, t.LAB_TEST_ID, 2
      FROM p JOIN CONF.REF_LAB_TEST t
        ON LOWER(TRIM(p.REQUIRED_TEST_TEXT)) = LOWER(t.CANONICAL_NAME))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY PROPOSAL_ID ORDER BY PRI) = 1
),

cond_m AS (
  SELECT p.PROPOSAL_ID, c.CONDITION_ID
    FROM p JOIN CONF.REF_CONDITION c
      ON LOWER(TRIM(COALESCE(p.PRECONDITION_VALUE, ''))) = LOWER(c.CONDITION_NAME)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY p.PROPOSAL_ID ORDER BY c.CONDITION_ID) = 1
),

norm AS (
  SELECT p.*,
         dm.DRUG_ID                                                  AS R_DRUG_ID,
         lm.LAB_TEST_ID                                              AS R_LAB_TEST_ID,
         cm.CONDITION_ID                                             AS R_COND_ID,
         UPPER(COALESCE(NULLIF(TRIM(p.PRECONDITION_TYPE), ''), 'none')) AS R_PRECOND_TYPE,
         COALESCE(p.EFFECTIVE_DATE, d.PUBLICATION_DATE, CURRENT_DATE()) AS R_EFFECTIVE_DATE
    FROM p
    LEFT JOIN drug_m dm ON dm.PROPOSAL_ID = p.PROPOSAL_ID
    LEFT JOIN lab_m  lm ON lm.PROPOSAL_ID = p.PROPOSAL_ID
    LEFT JOIN cond_m cm ON cm.PROPOSAL_ID = p.PROPOSAL_ID
    LEFT JOIN CONF.CONF_SAFETY_DOCUMENT d ON d.DOC_ID = p.DOC_ID
),

-- Does an ACTIVE rule already cover this exact drug/condition/test triple? If
-- so, approving is a VERSION BUMP that supersedes it, not a second rule
-- competing with it. Getting this wrong would double every case.
sup AS (
  SELECT n.PROPOSAL_ID, r.RULE_ID, r.VERSION
    FROM norm n
    JOIN RULES.SAFETY_RULE r
      ON r.STATUS = 'ACTIVE'
     AND r.DRUG_ID = n.R_DRUG_ID
     AND r.LAB_TEST_ID = n.R_LAB_TEST_ID
     AND COALESCE(r.CONDITION_ID, '~') = COALESCE(n.R_COND_ID, '~')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY n.PROPOSAL_ID ORDER BY r.VERSION DESC) = 1
)

SELECT
  n.PROPOSAL_ID, n.DOC_ID, n.MODEL_NAME, n.PROMPT_VERSION, n.EXTRACTED_AT,
  n.DRUG_TEXT, n.REQUIRED_TEST_TEXT, n.PRECONDITION_VALUE,
  n.INTERVAL_DAYS, n.INTERVAL_SOURCE_PHRASE, n.SOURCE_PASSAGE,
  n.NEEDS_REVIEW, n.REVIEW_REASON, n.STATUS, n.REVIEWED_BY, n.REVIEWED_AT,
  n.R_DRUG_ID        AS DRUG_ID,
  n.R_LAB_TEST_ID    AS LAB_TEST_ID,
  n.R_COND_ID        AS CONDITION_ID,
  n.R_PRECOND_TYPE   AS PRECONDITION_TYPE,
  n.R_EFFECTIVE_DATE AS EFFECTIVE_DATE,

  -- The single most important column on this view. Ordered so the reviewer is
  -- told the FIRST thing that must be fixed, not a list of everything.
  CASE
    WHEN n.STATUS <> 'PROPOSED'                THEN 'ALREADY_' || n.STATUS
    WHEN n.R_DRUG_ID IS NULL                   THEN 'UNRESOLVED_DRUG'
    WHEN n.R_LAB_TEST_ID IS NULL               THEN 'UNRESOLVED_TEST'
    WHEN n.R_PRECOND_TYPE = 'CONDITION'
     AND n.R_COND_ID IS NULL                   THEN 'UNRESOLVED_CONDITION'
    WHEN n.INTERVAL_DAYS IS NULL
      OR n.INTERVAL_DAYS <= 0                  THEN 'INVALID_INTERVAL'
    WHEN n.INTERVAL_DAYS > 730                 THEN 'IMPLAUSIBLE_INTERVAL'
    ELSE 'RESOLVED'
  END                                          AS RESOLVE_STATUS,

  CASE
    WHEN n.STATUS <> 'PROPOSED' THEN
      'This proposal was already ' || LOWER(n.STATUS) || ' by '
      || COALESCE(n.REVIEWED_BY, 'an unrecorded reviewer') || '.'
    WHEN n.R_DRUG_ID IS NULL THEN
      'No drug in CONF.REF_DRUG matches "' || COALESCE(n.DRUG_TEXT, '(empty)')
      || '". Add the drug to the reference table before approving.'
    WHEN n.R_LAB_TEST_ID IS NULL THEN
      'No lab test matches "' || COALESCE(n.REQUIRED_TEST_TEXT, '(empty)')
      || '". Add it to CONF.REF_LAB_TEST_SYNONYM - approving with the wrong test '
      || 'would monitor the wrong analyte indefinitely.'
    WHEN n.R_PRECOND_TYPE = 'CONDITION' AND n.R_COND_ID IS NULL THEN
      'No condition matches "' || COALESCE(n.PRECONDITION_VALUE, '(empty)')
      || '". Approving would widen the rule to every patient on the drug.'
    WHEN n.INTERVAL_DAYS IS NULL OR n.INTERVAL_DAYS <= 0 THEN
      'The interval could not be read as a positive number of days.'
    WHEN n.INTERVAL_DAYS > 730 THEN
      'Interval of ' || n.INTERVAL_DAYS || ' days exceeds two years - check the '
      || 'source phrase before approving.'
    ELSE NULL
  END                                          AS BLOCKING_REASON,

  su.RULE_ID  AS SUPERSEDES_RULE_ID,
  su.VERSION  AS SUPERSEDES_VERSION
FROM norm n
LEFT JOIN sup su ON su.PROPOSAL_ID = n.PROPOSAL_ID;

-- ===========================================================================
-- 2. SP_APPROVE_PROPOSAL
--
-- The human decision point. Everything before it is inert; everything after it
-- is deterministic. Refuses rather than guesses.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RULES.SP_APPROVE_PROPOSAL(
  P_PROPOSAL_ID STRING,
  P_ACTOR       STRING,
  P_GRACE_DAYS  NUMBER)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Approve one rule proposal into a versioned SAFETY_RULE. Supersedes the prior version when one exists.'
EXECUTE AS OWNER
AS
$$
DECLARE
  who        STRING;
  st         STRING;
  reason     STRING;
  drug       STRING;
  lab        STRING;
  cond       STRING;
  ptype      STRING;
  ivl        INT;
  grace      INT;
  phrase     STRING;
  passage    STRING;
  docid      STRING;
  effdt      DATE;
  sup_rule   STRING;
  corrob     STRING;
  corrob_f   VARIANT;
  new_rule   STRING;
  new_ver    INT DEFAULT 1;
  next_n     INT;
  action     STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context') INTO :who;
  grace := COALESCE(:P_GRACE_DAYS, 7);

  SELECT RESOLVE_STATUS, BLOCKING_REASON, DRUG_ID, LAB_TEST_ID, CONDITION_ID,
         PRECONDITION_TYPE, INTERVAL_DAYS,
         COALESCE(NULLIF(TRIM(INTERVAL_SOURCE_PHRASE), ''), '(no source phrase recorded)'),
         COALESCE(NULLIF(TRIM(SOURCE_PASSAGE), ''), '(no section recorded)'),
         DOC_ID, EFFECTIVE_DATE, SUPERSEDES_RULE_ID
    INTO :st, :reason, :drug, :lab, :cond, :ptype, :ivl, :phrase, :passage,
         :docid, :effdt, :sup_rule
    FROM RULES.V_PROPOSAL_RESOLVED
   WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

  IF (:st IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error', 'no such proposal: ' || :P_PROPOSAL_ID);
  END IF;

  -- Snapshot the corroboration BEFORE anything is changed. "What did the
  -- evidence look like at the moment a human approved this?" is an audit
  -- question with a right answer, and the view is computed live - so once the
  -- document is re-ingested or the vocabulary changes, the answer as it stood
  -- today is no longer recoverable from the view. It has to be captured here.
  SELECT CORROBORATION, FACTORS INTO :corrob, :corrob_f
    FROM RULES.V_PROPOSAL_CORROBORATION
   WHERE PROPOSAL_ID = :P_PROPOSAL_ID;
  IF (:st <> 'RESOLVED') THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'resolve_status', :st, 'error', :reason);
  END IF;

  IF (:sup_rule IS NOT NULL) THEN
    -- version bump on an existing rule
    new_rule := :sup_rule;
    SELECT COALESCE(MAX(VERSION), 0) + 1 INTO :new_ver
      FROM RULES.SAFETY_RULE WHERE RULE_ID = :new_rule;
    action := 'SUPERSEDED_PRIOR_VERSION';
  ELSE
    -- brand new rule id, allocated from the highest existing numeric suffix
    SELECT COALESCE(MAX(TRY_TO_NUMBER(REGEXP_SUBSTR(RULE_ID, '[0-9]+$'))), 0) + 1
      INTO :next_n FROM RULES.SAFETY_RULE;
    new_rule := 'RUL-' || LPAD(TO_VARCHAR(:next_n), 3, '0');
    new_ver  := 1;
    action   := 'NEW_RULE';
  END IF;

  INSERT INTO RULES.SAFETY_RULE
    (RULE_ID, VERSION, SOURCE_PROPOSAL_ID, DRUG_ID, PRECONDITION_TYPE,
     CONDITION_ID, AGE_MIN, LAB_TEST_ID, INTERVAL_DAYS, GRACE_DAYS,
     INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, DOC_ID, SOURCE_PASSAGE,
     STATUS, APPROVED_BY, APPROVED_AT)
  SELECT :new_rule, :new_ver, :P_PROPOSAL_ID, :drug,
         IFF(:ptype = 'CONDITION', 'CONDITION', 'NONE'),
         :cond, NULL, :lab, :ivl, :grace, :phrase, :effdt, :docid, :passage,
         'ACTIVE', :who, CURRENT_TIMESTAMP();

  IF (:sup_rule IS NOT NULL) THEN
    UPDATE RULES.SAFETY_RULE
       SET STATUS = 'SUPERSEDED', SUPERSEDED_BY_VERSION = :new_ver
     WHERE RULE_ID = :new_rule AND VERSION < :new_ver AND STATUS = 'ACTIVE';
  END IF;

  UPDATE RULES.RULE_PROPOSAL
     SET STATUS = 'APPROVED', REVIEWED_BY = :who, REVIEWED_AT = CURRENT_TIMESTAMP()
   WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_APPROVED', :who, 'RULE', :new_rule,
         OBJECT_CONSTRUCT('version', :new_ver, 'proposal_id', :P_PROPOSAL_ID,
                          'doc_id', :docid, 'drug_id', :drug, 'lab_test_id', :lab,
                          'condition_id', :cond, 'interval_days', :ivl,
                          'grace_days', :grace, 'action', :action,
                          'interval_source_phrase', :phrase,
                          -- What the document actually corroborated at approval
                          -- time. Not a model's opinion of itself: every factor
                          -- is a computed fact about the source text.
                          'corroboration', :corrob,
                          'corroboration_factors', :corrob_f);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :new_rule, 'version', :new_ver,
                          'action', :action, 'drug_id', :drug, 'lab_test_id', :lab,
                          'condition_id', :cond, 'interval_days', :ivl,
                          'grace_days', :grace, 'effective_date', :effdt,
                          'corroboration', :corrob,
                          'next_step', 'run the rule to see which patients it raises');
END;
$$;

-- ===========================================================================
-- 3. SP_REJECT_PROPOSAL -- rejection is a recorded decision, not a delete.
--
-- A rejected proposal stays in the table with its reason. "Why is there no
-- rule for this document?" must have an answer, and deleting the row destroys
-- it.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RULES.SP_REJECT_PROPOSAL(
  P_PROPOSAL_ID STRING, P_ACTOR STRING, P_REASON STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Reject one rule proposal, keeping the row and the stated reason.'
AS
$$
DECLARE
  who STRING;
  st  STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context') INTO :who;
  SELECT STATUS INTO :st FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

  IF (:st IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error', 'no such proposal');
  END IF;
  IF (:st <> 'PROPOSED') THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error', 'already ' || :st);
  END IF;
  IF (NULLIF(TRIM(COALESCE(:P_REASON, '')), '') IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error', 'a rejection reason is required');
  END IF;

  UPDATE RULES.RULE_PROPOSAL
     SET STATUS = 'REJECTED', REVIEWED_BY = :who,
         REVIEWED_AT = CURRENT_TIMESTAMP(), REJECT_REASON = :P_REASON
   WHERE PROPOSAL_ID = :P_PROPOSAL_ID;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_REJECTED', :who, 'PROPOSAL', :P_PROPOSAL_ID,
         OBJECT_CONSTRUCT('reason', :P_REASON);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'proposal_id', :P_PROPOSAL_ID, 'status', 'REJECTED');
END;
$$;

-- ===========================================================================
-- 4. SP_INGEST_EXTRACT_ALL -- the whole intake path in one call.
--
-- What the app button and the scheduled task both call. Deliberately stops at
-- PROPOSED: nothing here approves anything. The human gate is the product.
--
-- The summary is read back from the tables rather than accumulated from each
-- CALL result. Threading RESULT_SCAN(LAST_QUERY_ID()) through a loop looked
-- tidier and was brittle -- one intervening statement and the summary silently
-- describes the wrong query. Counting the rows that actually landed cannot
-- drift from what happened.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RULES.SP_INGEST_EXTRACT_ALL(P_ACTOR STRING, P_FORCE BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Ingest every staged document, then extract proposals from each. Stops at PROPOSED - approval stays human.'
AS
$$
DECLARE
  who     STRING;
  n_docs  INT DEFAULT 0;
  n_props INT DEFAULT 0;
  n_chunk INT DEFAULT 0;
  backend STRING;
  per_doc VARIANT;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context') INTO :who;
  SELECT BACKEND INTO :backend FROM RULES.EXTRACTOR_CONFIG;

  CALL CONF.SP_INGEST_DOCUMENTS(:who, :P_FORCE);

  LET cur CURSOR FOR SELECT DOC_ID FROM CONF.CONF_SAFETY_DOCUMENT ORDER BY DOC_ID;
  FOR rec IN cur DO
    LET d STRING := rec.DOC_ID;
    CALL RULES.SP_EXTRACT_PROPOSALS(:d, :who);
  END FOR;

  SELECT COUNT(*) INTO :n_docs  FROM CONF.CONF_SAFETY_DOCUMENT;
  SELECT COUNT(*) INTO :n_chunk FROM CONF.DOC_CHUNK;
  SELECT COUNT(*) INTO :n_props FROM RULES.RULE_PROPOSAL WHERE STATUS = 'PROPOSED';

  SELECT ARRAY_AGG(O) INTO :per_doc FROM (
    SELECT OBJECT_CONSTRUCT(
             'doc_id', d.DOC_ID,
             'chunks', (SELECT COUNT(*) FROM CONF.DOC_CHUNK k WHERE k.DOC_ID = d.DOC_ID),
             'proposed', (SELECT COUNT(*) FROM RULES.RULE_PROPOSAL p
                           WHERE p.DOC_ID = d.DOC_ID AND p.STATUS = 'PROPOSED'),
             'approved', (SELECT COUNT(*) FROM RULES.RULE_PROPOSAL p
                           WHERE p.DOC_ID = d.DOC_ID AND p.STATUS = 'APPROVED')) AS O
      FROM CONF.CONF_SAFETY_DOCUMENT d ORDER BY d.DOC_ID);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'backend', :backend, 'documents', :n_docs,
                          'chunks', :n_chunk, 'proposals_pending', :n_props,
                          'per_document', :per_doc,
                          'next_step', 'review RULES.V_PROPOSAL_RESOLVED, then approve');
END;
$$;
