-- STATUS: EXECUTED 2026-10-06 against account HHUAQYZ-KU03975 (locator KU03975, AWS_US_EAST_2) via
-- tools/sfx as part of tools/deploy_new_account. Ran clean. Verified by
-- INFORMATION_SCHEMA: RULES.SP_SET_RULE_ENABLED exists. Covered by the 17
-- checks in tests/test_rule_toggle.sql.
-- ===========================================================================
-- PER-RULE ON/OFF SWITCH -- approved, versioned, and independently pausable.
--
-- Aman's observation: Outlook lets you toggle an individual mail rule on and
-- off without deleting it. An approved safety rule needs the same, and the
-- reason is operational rather than cosmetic. SAFETY_DOC_010 says it out loud:
--
--   "Where a site cannot meet the six-week interval from existing capacity,
--    the site pharmacy lead should escalate to the Committee rather than allow
--    the interval to extend."
--
-- Until that escalation resolves, the rule is correct, approved and in force on
-- paper, and raising a case for every affected patient every night is noise
-- that trains people to ignore the queue. Other real reasons to pause: a
-- data-quality problem is manufacturing false cases; a newly approved rule is
-- being validated against a sample before it goes live.
--
-- ===========================================================================
-- THE SEMANTIC, and it is the whole design: PAUSING AFFECTS NEW WORK ONLY.
--
-- Turning off an Outlook rule does not un-file the mail it already filed.
-- Pausing a safety rule does not close, hide or alter a single existing case.
-- Every case already in the queue stays exactly as it is, with the same status
-- and the same evidence, and a reviewer still has to deal with it. All that
-- stops is the raising of NEW cases.
--
-- That is also the only defensible reading clinically. A case is a statement
-- that a specific patient appears to have missed a required test. That
-- statement does not stop being true because a committee paused the rule while
-- a site sorts out lab capacity, and a product that quietly cleared 22 open
-- patient cases because someone flipped a switch would be actively dangerous.
-- ===========================================================================
--
-- WHY THIS IS **NOT** A NEW `STATUS` VALUE ON THE RULE
-- `SAFETY_RULE.STATUS` is the GOVERNANCE lifecycle: ACTIVE -> SUPERSEDED ->
-- RETIRED. It records what a human decided about the rule's authority.
-- Enablement is an OPERATIONAL state: whether the rule is currently producing
-- new work. They are orthogonal, and collapsing them would break three things:
--
--   1. Pausing would look like retiring in the audit trail. "Why is there no
--      rule for this document?" would get the wrong answer.
--   2. Version-bump detection in RULES.V_PROPOSAL_RESOLVED looks for an ACTIVE
--      rule on the same (drug, condition, test) triple. If pausing cleared
--      ACTIVE, approving a revised interval would create a SECOND competing
--      rule instead of a new version -- and double every case.
--   3. RETIRED means "this requirement no longer exists". Paused means "it
--      exists and we are not acting on it yet". A regulator would care.
--
-- WHERE THE GATE IS APPLIED, and why that is what makes the above SAFE
-- DT_CASE_CANDIDATE is UNCHANGED. It keeps producing a candidate for every
-- ACTIVE rule, enabled or not, because the PATIENT'S GAP STILL EXISTS --
-- pausing a rule does not make a missed test disappear. The gate is applied at
-- the MERGE, which is exactly where a candidate becomes WORK.
--
-- This is load-bearing, not stylistic. Had the filter gone into the dynamic
-- table, the candidates for a paused rule would have vanished, and the
-- "candidate no longer exists" sweep would have marked all of that rule's open
-- cases RESOLVED_BY_DATA -- asserting that 22 patients' monitoring gaps had
-- CLOSED when nothing about any patient had changed. Gating at the merge means
-- the sweep still sees every candidate, so it leaves those cases alone without
-- needing a special case to protect them.
--
-- MED_CONFLICT is unaffected either way. A source-system disagreement -- the
-- EHR says the drug is active, the pharmacy has dispensed nothing for 90 days
-- -- is a data-quality signal that stands on its own, independent of any
-- interval requirement.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. The flag, and the record of who turned it off and why.
--
-- DEFAULT TRUE so every existing rule stays exactly as it was: this migration
-- changes no behaviour at all until somebody flips a switch.
--
-- DISABLE_REASON is not decorative -- SP_SET_RULE_ENABLED refuses a pause
-- without one. A rule silently switched off is indistinguishable from a rule
-- nobody noticed was off.
-- ===========================================================================
EXECUTE IMMEDIATE $$
BEGIN
  ALTER TABLE RULES.SAFETY_RULE ADD COLUMN
    IS_ENABLED     BOOLEAN NOT NULL DEFAULT TRUE;
  ALTER TABLE RULES.SAFETY_RULE ADD COLUMN
    DISABLED_BY    VARCHAR(60);
  ALTER TABLE RULES.SAFETY_RULE ADD COLUMN
    DISABLED_AT    TIMESTAMP_TZ;
  ALTER TABLE RULES.SAFETY_RULE ADD COLUMN
    DISABLE_REASON VARCHAR(500);
  RETURN 'columns added';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'already present: ' || SQLERRM;
END;
$$;

-- ===========================================================================
-- 2. SP_MERGE_CANDIDATES -- the merge, in ONE place.
--
-- Extracted because the identical MERGE plus disappearance logic was copied
-- into RUN_RULE and SP_RUN_PIPELINE, and a third and fourth time into the
-- superseded sql/17 and sql/18. Four copies of the rule that decides whether a
-- case is OPEN or RESOLVED is four chances for them to disagree about a
-- patient. One definition, two callers.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE CASES.SP_MERGE_CANDIDATES()
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Promote candidates from enabled rules into CASE_REGISTRY. Never alters an existing case because a rule was paused.'
AS
$$
DECLARE
  merged   INT DEFAULT 0;
  resolved INT DEFAULT 0;
BEGIN
  -- Only candidates from ENABLED rules become new work.
  --
  -- MED_CONFLICT rows carry RULE_ID = NULL and must still flow, which is what
  -- the OR handles -- a straight inner join would have silently dropped every
  -- conflict case in the account.
  --
  -- Note what this does NOT do: it does not touch rows for a paused rule at
  -- all. Those candidates are simply absent from the source, so MERGE neither
  -- matches nor inserts them, and the existing cases are left alone.
  MERGE INTO CASES.CASE_REGISTRY t
  USING (
    SELECT s.*
    FROM CASES.DT_CASE_CANDIDATE s
    LEFT JOIN RULES.SAFETY_RULE r
           ON r.RULE_ID = s.RULE_ID AND r.VERSION = s.VERSION
    WHERE s.RULE_ID IS NULL OR COALESCE(r.IS_ENABLED, TRUE)
  ) s ON t.CANDIDATE_KEY = s.CANDIDATE_KEY
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
  merged := SQLROWCOUNT;

  -- RESOLVED_BY_DATA means one thing only: the patient's gap actually closed,
  -- because the candidate is no longer produced by detection. It is measured
  -- against the UNFILTERED dynamic table, so a paused rule's candidates are
  -- still present and its open cases are never swept up here. That is the whole
  -- reason the enablement filter lives in the MERGE above and not in the
  -- dynamic table.
  UPDATE CASES.CASE_REGISTRY t
     SET STATUS = 'RESOLVED_BY_DATA', LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
   WHERE t.STATUS = 'OPEN'
     AND NOT EXISTS (SELECT 1 FROM CASES.DT_CASE_CANDIDATE s
                      WHERE s.CANDIDATE_KEY = t.CANDIDATE_KEY);
  resolved := SQLROWCOUNT;

  RETURN OBJECT_CONSTRUCT('merged', :merged, 'resolved_by_data', :resolved);
END;
$$;

-- ===========================================================================
-- 3. SP_SET_RULE_ENABLED -- the switch.
--
-- Refuses a pause with no reason. Touches no case, by design: see the header.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RULES.SP_SET_RULE_ENABLED(
  P_RULE_ID STRING,
  P_ENABLED BOOLEAN,
  P_ACTOR   STRING,
  P_REASON  STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pause or resume one ACTIVE rule. Affects only NEW cases; existing cases are never altered.'
AS
$$
DECLARE
  who      STRING;
  st       STRING;
  was      BOOLEAN;
  still_n  INT DEFAULT 0;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context')
    INTO :who;

  SELECT STATUS, IS_ENABLED INTO :st, :was
    FROM RULES.SAFETY_RULE
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';

  IF (:st IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error',
      'no ACTIVE version of ' || :P_RULE_ID
      || '. A SUPERSEDED or RETIRED rule cannot be paused or resumed - its '
      || 'authority has already ended, which is a different thing.');
  END IF;

  -- Pausing with no stated reason is how a rule ends up off for a month and
  -- nobody can say why.
  IF (NOT :P_ENABLED AND NULLIF(TRIM(COALESCE(:P_REASON, '')), '') IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error',
      'a reason is required to pause a rule');
  END IF;

  IF (:was = :P_ENABLED) THEN
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :P_RULE_ID,
      'is_enabled', :P_ENABLED, 'changed', FALSE,
      'note', 'already in that state - nothing done, and no audit event for a '
              || 'non-event');
  END IF;

  UPDATE RULES.SAFETY_RULE
     SET IS_ENABLED     = :P_ENABLED,
         DISABLED_BY    = IFF(:P_ENABLED, NULL, :who),
         DISABLED_AT    = IFF(:P_ENABLED, NULL, CURRENT_TIMESTAMP()),
         DISABLE_REASON = IFF(:P_ENABLED, NULL, :P_REASON)
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';

  -- NOT a no-op that was forgotten: there is deliberately no UPDATE against
  -- CASE_REGISTRY here. Existing cases are untouched. This count is reported so
  -- the caller can SEE that they were left alone rather than having to trust it.
  SELECT COUNT(*) INTO :still_n FROM CASES.CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT IFF(:P_ENABLED, 'RULE_RESUMED', 'RULE_PAUSED'), :who, 'RULE', :P_RULE_ID,
         OBJECT_CONSTRUCT('reason', :P_REASON,
                          'governance_status', :st,
                          'existing_open_cases_left_untouched', :still_n,
                          'note', 'Enablement is operational and affects NEW cases '
                                  || 'only. STATUS is unchanged and remains '
                                  || :st || '.');

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :P_RULE_ID,
                          'is_enabled', :P_ENABLED, 'changed', TRUE,
                          'governance_status', :st,
                          'existing_open_cases_left_untouched', :still_n,
                          'note', IFF(:P_ENABLED,
                            'Resumed. New cases will be raised on the next run.',
                            'Paused. No NEW cases will be raised. The '
                            || :still_n || ' case(s) already open are unchanged '
                            || 'and still need review - a paused rule does not '
                            || 'close a patient''s gap.'));
END;
$$;

-- ===========================================================================
-- 4. RUN_RULE -- supersedes sql/20's version. Now delegates the merge.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE CASES.RUN_RULE(P_RULE_ID STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refresh the 360 + detection, then report cases attributable to one rule.'
AS
$$
DECLARE
  before_n INT DEFAULT 0;
  after_n  INT DEFAULT 0;
  active_v INT DEFAULT NULL;
  enabled  BOOLEAN DEFAULT TRUE;
  who      STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context')
    INTO :who;

  SELECT COUNT(*) INTO :before_n FROM CASES.CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';
  SELECT MAX(VERSION) INTO :active_v FROM RULES.SAFETY_RULE
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';

  IF (:active_v IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE,
      'error', 'no ACTIVE version of ' || :P_RULE_ID || ' - approve it first');
  END IF;

  -- A paused rule says so plainly instead of running and returning zero, which
  -- would look identical to "this rule finds nothing".
  SELECT IS_ENABLED INTO :enabled FROM RULES.SAFETY_RULE
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';
  IF (NOT :enabled) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'rule_id', :P_RULE_ID,
      'version', :active_v, 'is_enabled', FALSE, 'open_cases', :before_n,
      'error', :P_RULE_ID || ' is APPROVED but PAUSED, so it raises no NEW '
               || 'cases. Resume it to evaluate it. Its governance status is '
               || 'still ACTIVE - pausing is operational, not a withdrawal - '
               || 'and its ' || :before_n || ' existing open case(s) are '
               || 'unaffected.');
  END IF;

  ALTER DYNAMIC TABLE P360.P360_MEDICATION_TIMELINE REFRESH;
  ALTER DYNAMIC TABLE P360.P360_LAB_TIMELINE        REFRESH;
  ALTER DYNAMIC TABLE P360.P360_ACTIVE_MEDICATION   REFRESH;
  ALTER DYNAMIC TABLE P360.P360_PERSON              REFRESH;
  ALTER DYNAMIC TABLE CASES.DT_CASE_CANDIDATE       REFRESH;

  CALL CASES.SP_MERGE_CANDIDATES();

  SELECT COUNT(*) INTO :after_n FROM CASES.CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_EVALUATED', :who, 'RULE', :P_RULE_ID,
         OBJECT_CONSTRUCT('version', :active_v, 'open_before', :before_n,
                          'open_after', :after_n, 'delta', :after_n - :before_n);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :P_RULE_ID, 'version', :active_v,
                          'is_enabled', TRUE,
                          'open_before', :before_n, 'open_after', :after_n,
                          'new_cases', :after_n - :before_n);
END;
$$;

-- ===========================================================================
-- 5. SP_RUN_PIPELINE -- supersedes sql/20's version. Also delegates the merge.
--
-- Structure copied from sql/20 rather than rewritten, after rewriting it from
-- memory invented a TRIGGERED_ACTOR column that does not exist and dropped the
-- SEAL_AUDIT_CHAIN call. The only intended changes are: the inline MERGE is
-- replaced by SP_MERGE_CANDIDATES, and the result reports how many rules are
-- currently paused.
--
-- Note the log pattern: INSERT the run row up front, UPDATE it on completion.
-- A run that crashes half way therefore leaves a row with a NULL FINISHED_AT,
-- which is visible. Writing one row at the end would leave no trace of it.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE CASES.SP_RUN_PIPELINE(
  P_TRIGGERED_BY STRING, P_FORCE BOOLEAN, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Full pipeline: refresh 360, detect, merge, reconcile, seal audit.'
AS
$$
DECLARE
  run_id   STRING;
  new_data BOOLEAN DEFAULT FALSE;
  before_n INT DEFAULT 0;
  after_n  INT DEFAULT 0;
  ev_n     INT DEFAULT 0;
  paused_r INT DEFAULT 0;
  who      STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context')
    INTO :who;
  SELECT 'RUN-' || UUID_STRING() INTO :run_id;
  SELECT COUNT(*) INTO :before_n FROM CASES.CASE_REGISTRY WHERE STATUS = 'OPEN';

  SELECT (SYSTEM$STREAM_HAS_DATA('CONF.STR_LAB_RESULT')
       OR SYSTEM$STREAM_HAS_DATA('CONF.STR_MEDICATION')
       OR SYSTEM$STREAM_HAS_DATA('CONF.STR_DIAGNOSIS')
       OR SYSTEM$STREAM_HAS_DATA('RULES.STR_SAFETY_RULE')) INTO :new_data;

  INSERT INTO CASES.PIPELINE_RUN_LOG
    (RUN_ID, TRIGGERED_BY, HAD_NEW_DATA, CASES_BEFORE)
  SELECT :run_id, :P_TRIGGERED_BY, :new_data, :before_n;

  IF (NOT :new_data AND NOT :P_FORCE) THEN
    UPDATE CASES.PIPELINE_RUN_LOG
       SET FINISHED_AT = CURRENT_TIMESTAMP(), CASES_AFTER = :before_n,
           EVIDENCE_ROWS = (SELECT COUNT(*) FROM CASES.CASE_EVIDENCE),
           OUTCOME = 'skipped - no new clinical data or rule change'
     WHERE RUN_ID = :run_id;
    RETURN OBJECT_CONSTRUCT('ok', TRUE, 'run_id', :run_id, 'skipped', TRUE,
                            'reason', 'no new data', 'open_cases', :before_n);
  END IF;

  ALTER DYNAMIC TABLE P360.P360_MEDICATION_TIMELINE REFRESH;
  ALTER DYNAMIC TABLE P360.P360_LAB_TIMELINE        REFRESH;
  ALTER DYNAMIC TABLE P360.P360_ACTIVE_MEDICATION   REFRESH;
  ALTER DYNAMIC TABLE P360.P360_PERSON              REFRESH;
  ALTER DYNAMIC TABLE CASES.DT_CASE_CANDIDATE       REFRESH;

  CALL CASES.SP_MERGE_CANDIDATES();
  CALL CASES.SP_RECONCILE_EVIDENCE();
  CALL CASES.SEAL_AUDIT_CHAIN();

  SELECT COUNT(*) INTO :after_n FROM CASES.CASE_REGISTRY WHERE STATUS = 'OPEN';
  SELECT COUNT(*) INTO :ev_n    FROM CASES.CASE_EVIDENCE;
  SELECT COUNT(*) INTO :paused_r FROM RULES.SAFETY_RULE
   WHERE STATUS = 'ACTIVE' AND IS_ENABLED = FALSE;

  UPDATE CASES.PIPELINE_RUN_LOG
     SET FINISHED_AT = CURRENT_TIMESTAMP(), CASES_AFTER = :after_n,
         EVIDENCE_ROWS = :ev_n,
         OUTCOME = 'completed - net case change ' || (:after_n - :before_n)::STRING
                   || IFF(:paused_r > 0,
                          ' (' || :paused_r::STRING || ' rule(s) paused)', '')
   WHERE RUN_ID = :run_id;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'QUEUE_REFRESHED', :who, 'QUEUE', 'ALL',
         OBJECT_CONSTRUCT('run_id', :run_id, 'triggered_by', :P_TRIGGERED_BY,
                          'open_before', :before_n, 'open_after', :after_n,
                          'evidence_rows', :ev_n, 'paused_rules', :paused_r);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'run_id', :run_id, 'skipped', FALSE,
                          'open_before', :before_n, 'open_after', :after_n,
                          'evidence_rows', :ev_n, 'paused_rules', :paused_r);
END;
$$;

-- ===========================================================================
-- 6. What a reviewer sees: governance and operational state, kept separate.
-- ===========================================================================
CREATE OR REPLACE VIEW RULES.V_RULE_STATE
COMMENT = 'Governance status and operational enablement, kept visibly separate.'
AS
SELECT r.RULE_ID, r.VERSION, r.STATUS AS GOVERNANCE_STATUS, r.IS_ENABLED,
       r.DISABLED_BY,
       TO_VARCHAR(r.DISABLED_AT, 'YYYY-MM-DD HH24:MI') AS DISABLED_AT,
       r.DISABLE_REASON,
       CASE
         WHEN r.STATUS <> 'ACTIVE' THEN r.STATUS || ' - no longer in force'
         WHEN NOT r.IS_ENABLED     THEN 'APPROVED BUT PAUSED - raises no NEW cases'
         ELSE 'IN FORCE - raising cases'
       END AS EFFECTIVE_STATE,
       (SELECT COUNT(*) FROM CASES.CASE_REGISTRY c
         WHERE c.RULE_ID = r.RULE_ID AND c.STATUS = 'OPEN') AS OPEN_CASES
FROM RULES.SAFETY_RULE r;

GRANT SELECT ON VIEW RULES.V_RULE_STATE TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE RULES.SP_SET_RULE_ENABLED(STRING, BOOLEAN, STRING, STRING)
  TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE CASES.SP_MERGE_CANDIDATES() TO ROLE HO_REVIEWER;

-- ===========================================================================
-- 7. Verify.
-- ===========================================================================
SELECT RULE_ID, VERSION, GOVERNANCE_STATUS, IS_ENABLED, EFFECTIVE_STATE, OPEN_CASES
FROM RULES.V_RULE_STATE ORDER BY RULE_ID, VERSION;
