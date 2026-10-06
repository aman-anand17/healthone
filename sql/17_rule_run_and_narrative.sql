-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx as part of tools/deploy_new_account. Ran clean.
--
-- Closes three real gaps Aman identified:
--   1. "there should be an option to run the rule"  -> RUN_RULE procedure
--   2. evidence/narrative should not be recomputed  -> CASE_NARRATIVE cache
--   3. AI should see the data and explain it        -> V_CASE_BUNDLE, the exact
--      payload an LLM would receive, assembled deterministically
--
-- ===========================================================================
-- ON "AI SHOULD CREATE THE CASES" — the one design point worth defending
--
-- It shouldn't, and this is the product's strongest claim rather than a
-- limitation. If a model decided which patients have a monitoring gap:
--   * "how do you know it didn't invent a patient?" has no answer
--   * the same data could yield different queues on different runs
--   * the 12 golden tests become impossible — you cannot assert on a
--     non-deterministic function
--   * the challenge explicitly rejects opaque predictions
--
-- So the split is deliberate:
--   ARITHMETIC decides WHETHER a case exists and what the evidence verdicts
--   are. Testable, reproducible, auditable.
--   LANGUAGE explains WHY, in prose, over evidence it cannot alter, and
--   retrieves the document passage that justifies the rule.
--
-- That is where AI genuinely belongs, and V_CASE_BUNDLE below is the seam.
-- The bundle is built by SQL; the narrative is generated from it. Today the
-- generator is a deterministic template because AI_COMPLETE is blocked; the
-- CASE_NARRATIVE row records WHICH generator produced it, so nothing ever
-- claims a model wrote something a template did.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CASES; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. RUN_RULE — evaluate ONE rule on demand.
--
-- Until now the only control was a global "refresh queue", so a reviewer
-- could not see which rule caused which cases. This scopes the action and
-- reports the delta, which is what makes the causality visible: approve a
-- rule, run it, see exactly what it produced.
--
-- Detection itself is still the single shared dynamic table — this does NOT
-- fork per-rule logic. It refreshes the pipeline, merges, and then reports
-- only the rows attributable to the requested rule.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RUN_RULE(P_RULE_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refresh the 360 + detection, then report cases attributable to one rule.'
AS
$$
DECLARE
  before_n INT DEFAULT 0;
  after_n  INT DEFAULT 0;
  active_v INT DEFAULT NULL;
BEGIN
  SELECT COUNT(*) INTO :before_n FROM CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';

  SELECT MAX(VERSION) INTO :active_v FROM RULES.SAFETY_RULE
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';

  IF (active_v IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE,
      'error', 'no ACTIVE version of ' || :P_RULE_ID || ' — approve it first');
  END IF;

  -- Ordered refresh. Every dynamic table is SCHEDULER=DISABLE for cost, and a
  -- manual refresh does NOT cascade upstream, so the order is mandatory.
  ALTER DYNAMIC TABLE P360.P360_MEDICATION_TIMELINE REFRESH;
  ALTER DYNAMIC TABLE P360.P360_LAB_TIMELINE        REFRESH;
  ALTER DYNAMIC TABLE P360.P360_ACTIVE_MEDICATION   REFRESH;
  ALTER DYNAMIC TABLE P360.P360_PERSON              REFRESH;
  ALTER DYNAMIC TABLE CASES.DT_CASE_CANDIDATE       REFRESH;

  MERGE INTO CASE_REGISTRY t
  USING DT_CASE_CANDIDATE s ON t.CANDIDATE_KEY = s.CANDIDATE_KEY
  WHEN MATCHED THEN UPDATE SET
     t.VERSION = s.VERSION, t.PRIORITY = s.PRIORITY,
     t.PRIORITY_FACTORS = s.PRIORITY_FACTORS,
     t.WINDOW_START_DATE = s.WINDOW_START_DATE,
     t.REFERENCE_EVENT_TYPE = s.REFERENCE_EVENT_TYPE,
     t.REFERENCE_EVENT_DATE = s.REFERENCE_EVENT_DATE,
     t.DAYS_SINCE_REFERENCE = s.DAYS_SINCE_REFERENCE,
     t.LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
     (CANDIDATE_KEY, PERSON_ID, CASE_TYPE, RULE_ID, VERSION, DRUG_ID, LAB_TEST_ID,
      PRIORITY, PRIORITY_FACTORS, WINDOW_START_DATE, REFERENCE_EVENT_TYPE,
      REFERENCE_EVENT_DATE, DAYS_SINCE_REFERENCE, STATUS, LAST_REFRESHED_AT)
     VALUES
     (s.CANDIDATE_KEY, s.PERSON_ID, s.CASE_TYPE, s.RULE_ID, s.VERSION, s.DRUG_ID,
      s.LAB_TEST_ID, s.PRIORITY, s.PRIORITY_FACTORS, s.WINDOW_START_DATE,
      s.REFERENCE_EVENT_TYPE, s.REFERENCE_EVENT_DATE, s.DAYS_SINCE_REFERENCE,
      'OPEN', CURRENT_TIMESTAMP());

  UPDATE CASE_REGISTRY t
     SET STATUS = 'RESOLVED_BY_DATA', LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
   WHERE t.STATUS = 'OPEN'
     AND NOT EXISTS (SELECT 1 FROM DT_CASE_CANDIDATE s
                      WHERE s.CANDIDATE_KEY = t.CANDIDATE_KEY);

  SELECT COUNT(*) INTO :after_n FROM CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';

  INSERT INTO AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_EVALUATED', CURRENT_USER(), 'RULE', :P_RULE_ID,
         OBJECT_CONSTRUCT('version', :active_v, 'open_before', :before_n,
                          'open_after', :after_n, 'delta', :after_n - :before_n);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :P_RULE_ID, 'version', :active_v,
                          'open_before', :before_n, 'open_after', :after_n,
                          'new_cases', :after_n - :before_n);
END;
$$;

-- ===========================================================================
-- 2. V_CASE_BUNDLE — the evidence payload, assembled by SQL.
--
-- This is the object an LLM would be given: rule, patient context (pseudonym
-- only), every claim with its verdict and citations, and the source passage.
-- It exists as a view so the bundle is inspectable — a reviewer or a judge can
-- see EXACTLY what would be sent to a model, rather than trusting a prompt
-- assembled invisibly in application code.
-- ===========================================================================
CREATE OR REPLACE VIEW V_CASE_BUNDLE
COMMENT = 'The exact evidence bundle a narrative generator receives.'
AS
SELECT
  c.CASE_ID,
  SEC.PERSON_TOKEN(c.PERSON_ID)              AS PERSON_TOKEN,
  c.CASE_TYPE, c.PRIORITY, c.STATUS,
  c.DAYS_SINCE_REFERENCE, c.WINDOW_START_DATE,
  c.RULE_ID, c.VERSION,
  d.DRUG_NAME, cond.CONDITION_NAME, t.CANONICAL_NAME AS REQUIRED_TEST,
  r.INTERVAL_DAYS, r.GRACE_DAYS, r.INTERVAL_SOURCE_PHRASE,
  r.DOC_ID, r.SOURCE_PASSAGE,
  -- every claim, verdict and citation, as structured data
  (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
            'claim_key', e.CLAIM_KEY, 'verdict', e.VERDICT,
            'claim', e.CLAIM_TEXT, 'searched', e.SEARCHED,
            'citations', e.EVIDENCE_REFS))
     FROM CASE_EVIDENCE e WHERE e.CASE_ID = c.CASE_ID)   AS CLAIMS,
  -- the document section the rule came from, for grounding
  (SELECT MAX(k.CHUNK_TEXT) FROM CONF.DOC_CHUNK k
    WHERE k.DOC_ID = r.DOC_ID
      AND k.SECTION_LABEL ILIKE '%' || r.SOURCE_PASSAGE || '%') AS SOURCE_TEXT
FROM CASE_REGISTRY c
LEFT JOIN RULES.SAFETY_RULE r ON r.RULE_ID = c.RULE_ID AND r.VERSION = c.VERSION
LEFT JOIN CONF.REF_DRUG d      ON d.DRUG_ID = c.DRUG_ID
LEFT JOIN CONF.REF_CONDITION cond ON cond.CONDITION_ID = r.CONDITION_ID
LEFT JOIN CONF.REF_LAB_TEST t  ON t.LAB_TEST_ID = c.LAB_TEST_ID;

-- ===========================================================================
-- 3. CASE_NARRATIVE — generated once, then cached.
--
-- Aman's point: the explanation should not be recomputed on every page view.
-- It is keyed by CASE_ID plus EVIDENCE_FINGERPRINT, so it is reused while the
-- evidence is unchanged and regenerated automatically when the evidence moves
-- (a new rule version, a new lab result). GENERATOR records what produced it —
-- 'template' or a model name — so a template is never mistaken for a model.
-- ===========================================================================
CREATE OR REPLACE TABLE CASE_NARRATIVE (
  CASE_ID              VARCHAR(60)  NOT NULL,
  EVIDENCE_FINGERPRINT VARCHAR(64)  NOT NULL,
  NARRATIVE            VARCHAR      NOT NULL,
  GENERATOR            VARCHAR(60)  NOT NULL,
  GENERATED_AT         TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (CASE_ID)
);

-- Fingerprint of a case's evidence, as a VIEW rather than a UDF.
--
-- A scalar UDF was the obvious first choice and it does not work: Snowflake
-- rejects "Unsupported subquery type cannot be evaluated inside Function
-- object" when a SQL UDF containing subqueries is called per row from an
-- outer query. A set-based view computes the same value with a GROUP BY, is
-- faster, and joins cleanly to anything.
--
-- Changes whenever any claim, verdict, day-count or rule version changes —
-- which is exactly when a cached narrative has gone stale.
CREATE OR REPLACE VIEW V_CASE_FINGERPRINT
COMMENT = 'Per-case evidence fingerprint. Drives narrative cache invalidation.'
AS
SELECT c.CASE_ID,
       SHA2(COALESCE(LISTAGG(e.CLAIM_KEY || '|' || e.VERDICT || '|' ||
                             COALESCE(e.CLAIM_TEXT,''), '~')
                     WITHIN GROUP (ORDER BY e.CLAIM_KEY), 'no-evidence')
            || '|' || COALESCE(c.DAYS_SINCE_REFERENCE::STRING, 'x')
            || '|' || COALESCE(c.VERSION::STRING, 'x'), 256) AS EVIDENCE_FINGERPRINT
FROM CASE_REGISTRY c
LEFT JOIN CASE_EVIDENCE e ON e.CASE_ID = c.CASE_ID
GROUP BY c.CASE_ID, c.DAYS_SINCE_REFERENCE, c.VERSION;

-- A cached narrative is USABLE only while its fingerprint still matches.
CREATE OR REPLACE VIEW V_CASE_NARRATIVE_CURRENT
COMMENT = 'Cached narratives that are still valid for their current evidence.'
AS
SELECT n.CASE_ID, n.NARRATIVE, n.GENERATOR, n.GENERATED_AT,
       (n.EVIDENCE_FINGERPRINT = f.EVIDENCE_FINGERPRINT) AS IS_CURRENT
FROM CASE_NARRATIVE n
JOIN V_CASE_FINGERPRINT f ON f.CASE_ID = n.CASE_ID;

GRANT SELECT ON VIEW V_CASE_FINGERPRINT TO ROLE HO_REVIEWER;
GRANT SELECT ON VIEW V_CASE_NARRATIVE_CURRENT TO ROLE HO_REVIEWER;

GRANT SELECT ON VIEW V_CASE_BUNDLE TO ROLE HO_REVIEWER;
GRANT SELECT, INSERT, UPDATE ON TABLE CASE_NARRATIVE TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE RUN_RULE(STRING) TO ROLE HO_REVIEWER;

SELECT 'RUN_RULE + V_CASE_BUNDLE + CASE_NARRATIVE deployed' AS STATUS;
