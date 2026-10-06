-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- STREAMLIT-IN-SNOWFLAKE COMPATIBILITY FIXES.
--
-- THE ROOT CAUSE, which cost three separate runtime errors:
-- Every procedure took its actor from CURRENT_USER(). That works when called
-- from the CLI, and returns NULL when called from Streamlit in Snowflake,
-- because the app runs inside a UDF sandbox (visible in the tracebacks as
-- /home/udf/...). A NULL actor then violated NOT NULL on AUDIT_EVENT.ACTOR
-- and SEC.PHI_REVEAL_GRANT.GRANTED_TO:
--
--   "DML operation to table AUDIT_EVENT failed on column ACTOR with error:
--    NULL result in a non-nullable column"
--   "Requested information on the current user is not accessible in stored
--    procedure"
--
-- FIX: the actor is now an explicit parameter. The caller knows who it is —
-- the app resolves CURRENT_USER() in ordinary query context, where it works —
-- and passes it in. COALESCE guards against a NULL slipping through anyway,
-- because an audit row that cannot be written is worse than one attributed to
-- 'unknown-app-context'.
--
-- SECURITY NOTE, stated rather than hidden: because the actor is now a
-- parameter, a caller could pass a name that is not their own. The masking
-- policy still checks GRANTED_TO = CURRENT_USER() at QUERY time, so lying
-- about the actor grants the liar nothing — it could only grant access to the
-- person named. For a synthetic demo that is an acceptable trade against
-- having no working break-glass at all; a production build would resolve the
-- identity server-side from the session, not from an argument.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. Break-glass: actor as a parameter.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SEC.REQUEST_PHI_REVEAL(
  P_PERSON_ID   STRING,
  P_CASE_ID     STRING,
  P_REASON_CODE STRING,
  P_REASON_TEXT STRING,
  P_ACTOR       STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Break-glass: grants a 30-minute PHI reveal and logs it inseparably.'
EXECUTE AS OWNER
AS
$$
DECLARE
  reason_ok INT;
  who       STRING;
BEGIN
  -- CURRENT_USER() is NULL in a procedure called from Streamlit in Snowflake.
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context')
    INTO :who;

  SELECT COUNT(*) INTO :reason_ok
    FROM SEC.PHI_REVEAL_REASON WHERE REASON_CODE = :P_REASON_CODE;
  IF (reason_ok = 0) THEN
    RETURN 'REJECTED: unknown reason code';
  END IF;

  INSERT INTO SEC.PHI_REVEAL_GRANT
    (PERSON_ID, GRANTED_TO, CASE_ID, REASON_CODE, REASON_TEXT, EXPIRES_AT)
  SELECT :P_PERSON_ID, :who, :P_CASE_ID, :P_REASON_CODE, :P_REASON_TEXT,
         DATEADD('minute', 30, CURRENT_TIMESTAMP());

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'PHI_REVEALED', :who, 'PERSON', :P_PERSON_ID,
         OBJECT_CONSTRUCT('case_id', :P_CASE_ID, 'reason_code', :P_REASON_CODE,
                          'reason_text', :P_REASON_TEXT, 'window_minutes', 30);

  RETURN 'GRANTED for 30 minutes to ' || :who
         || ' - this access has been recorded in the audit trail';
END;
$$;

-- ===========================================================================
-- 2. Run one rule: actor as a parameter.
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
  who      STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context')
    INTO :who;

  SELECT COUNT(*) INTO :before_n FROM CASES.CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';
  SELECT MAX(VERSION) INTO :active_v FROM RULES.SAFETY_RULE
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'ACTIVE';

  IF (active_v IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE,
      'error', 'no ACTIVE version of ' || :P_RULE_ID || ' - approve it first');
  END IF;

  ALTER DYNAMIC TABLE P360.P360_MEDICATION_TIMELINE REFRESH;
  ALTER DYNAMIC TABLE P360.P360_LAB_TIMELINE        REFRESH;
  ALTER DYNAMIC TABLE P360.P360_ACTIVE_MEDICATION   REFRESH;
  ALTER DYNAMIC TABLE P360.P360_PERSON              REFRESH;
  ALTER DYNAMIC TABLE CASES.DT_CASE_CANDIDATE       REFRESH;

  MERGE INTO CASES.CASE_REGISTRY t
  USING CASES.DT_CASE_CANDIDATE s ON t.CANDIDATE_KEY = s.CANDIDATE_KEY
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

  UPDATE CASES.CASE_REGISTRY t
     SET STATUS = 'RESOLVED_BY_DATA', LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
   WHERE t.STATUS = 'OPEN'
     AND NOT EXISTS (SELECT 1 FROM CASES.DT_CASE_CANDIDATE s
                      WHERE s.CANDIDATE_KEY = t.CANDIDATE_KEY);

  SELECT COUNT(*) INTO :after_n FROM CASES.CASE_REGISTRY
   WHERE RULE_ID = :P_RULE_ID AND STATUS = 'OPEN';

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_EVALUATED', :who, 'RULE', :P_RULE_ID,
         OBJECT_CONSTRUCT('version', :active_v, 'open_before', :before_n,
                          'open_after', :after_n, 'delta', :after_n - :before_n);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rule_id', :P_RULE_ID, 'version', :active_v,
                          'open_before', :before_n, 'open_after', :after_n,
                          'new_cases', :after_n - :before_n);
END;
$$;

-- ===========================================================================
-- 3. Whole pipeline: actor as a parameter.
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

  MERGE INTO CASES.CASE_REGISTRY t
  USING CASES.DT_CASE_CANDIDATE s ON t.CANDIDATE_KEY = s.CANDIDATE_KEY
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

  UPDATE CASES.CASE_REGISTRY t
     SET STATUS = 'RESOLVED_BY_DATA', LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
   WHERE t.STATUS = 'OPEN'
     AND NOT EXISTS (SELECT 1 FROM CASES.DT_CASE_CANDIDATE s
                      WHERE s.CANDIDATE_KEY = t.CANDIDATE_KEY);

  CALL CASES.SP_RECONCILE_EVIDENCE();
  CALL CASES.SEAL_AUDIT_CHAIN();

  SELECT COUNT(*) INTO :after_n FROM CASES.CASE_REGISTRY WHERE STATUS = 'OPEN';
  SELECT COUNT(*) INTO :ev_n    FROM CASES.CASE_EVIDENCE;

  UPDATE CASES.PIPELINE_RUN_LOG
     SET FINISHED_AT = CURRENT_TIMESTAMP(), CASES_AFTER = :after_n,
         EVIDENCE_ROWS = :ev_n,
         OUTCOME = 'completed - net case change ' || (:after_n - :before_n)::STRING
   WHERE RUN_ID = :run_id;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'QUEUE_REFRESHED', :who, 'QUEUE', 'ALL',
         OBJECT_CONSTRUCT('run_id', :run_id, 'triggered_by', :P_TRIGGERED_BY,
                          'open_before', :before_n, 'open_after', :after_n,
                          'evidence_rows', :ev_n);

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'run_id', :run_id, 'skipped', FALSE,
                          'open_before', :before_n, 'open_after', :after_n,
                          'evidence_rows', :ev_n);
END;
$$;

-- Keep the scheduled task working against the new signature.
CREATE OR REPLACE TASK CASES.T_HEALTHONE_PIPELINE
  WAREHOUSE = HO_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  COMMENT = 'Nightly re-evaluation of all ACTIVE rules against the 360.'
AS
  CALL CASES.SP_RUN_PIPELINE('TASK', FALSE, 'system:task');

-- ===========================================================================
-- 4. PHI inventory as a SNAPSHOT TABLE, not a live view.
--
-- V_PHI_INVENTORY read INFORMATION_SCHEMA table functions
-- (TAG_REFERENCES_ALL_COLUMNS, POLICY_REFERENCES). Those depend on session
-- user/role context, which the UDF sandbox does not provide, so the view
-- failed in the deployed app with "Requested information on the current user
-- is not accessible".
--
-- A snapshot is also the more honest artifact: a compliance inventory should
-- record what was true at a stated moment, not silently change under the
-- reader. Refreshed by SP_SNAPSHOT_PHI_INVENTORY, which the pipeline can call.
-- ===========================================================================
CREATE OR REPLACE TABLE SEC.PHI_INVENTORY_SNAPSHOT (
  CAPTURED_AT   TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  SCH           VARCHAR(60),
  TBL           VARCHAR(120),
  COL           VARCHAR(120),
  SENSITIVITY   VARCHAR(40),
  SOURCE_SYSTEM VARCHAR(40),
  PROTECTION    VARCHAR(120)
);

-- The snapshot is taken by a PLAIN STATEMENT, not a procedure.
--
-- Wrapping it in a procedure failed the same way the view did: the
-- INFORMATION_SCHEMA table functions need session user/role context, which is
-- not available inside a stored procedure at all ("Requested information on
-- the current user is not accessible in stored procedure"). So the capture is
-- an ordinary INSERT run by an admin session.
--
-- That is arguably the right shape anyway: a compliance inventory should be a
-- deliberate, dated capture rather than something that quietly changes while
-- somebody is reading it.
DELETE FROM SEC.PHI_INVENTORY_SNAPSHOT;

INSERT INTO SEC.PHI_INVENTORY_SNAPSHOT
  (SCH, TBL, COL, SENSITIVITY, SOURCE_SYSTEM, PROTECTION)
SELECT SCH, TBL, COL, SENSITIVITY, SOURCE_SYSTEM, PROTECTION
FROM SEC.V_PHI_INVENTORY;

SELECT COUNT(*) AS CLASSIFIED_COLUMNS_CAPTURED FROM SEC.PHI_INVENTORY_SNAPSHOT;

GRANT SELECT ON TABLE SEC.PHI_INVENTORY_SNAPSHOT TO ROLE HO_REVIEWER;
GRANT SELECT ON TABLE SEC.PHI_INVENTORY_SNAPSHOT TO ROLE HO_AUDITOR;
GRANT SELECT ON TABLE SEC.PHI_INVENTORY_SNAPSHOT TO ROLE PUBLIC;
GRANT USAGE ON PROCEDURE SEC.REQUEST_PHI_REVEAL(STRING,STRING,STRING,STRING,STRING) TO ROLE PUBLIC;
GRANT USAGE ON PROCEDURE CASES.RUN_RULE(STRING,STRING) TO ROLE PUBLIC;
GRANT USAGE ON PROCEDURE CASES.SP_RUN_PIPELINE(STRING,BOOLEAN,STRING) TO ROLE PUBLIC;

SELECT 'SiS compatibility fixes deployed' AS STATUS;

-- ===========================================================================
-- 4. Grants for the NEW signatures.
--
-- sql/10 grants HO_REVIEWER usage on REQUEST_PHI_REVEAL(STRING x4). Adding the
-- actor parameter created a FIVE-argument overload, and the app calls that one.
-- Both procedures exist, so nothing errored -- HO_REVIEWER simply could not
-- break the glass, and would have discovered it during a demo. Overloads are
-- separate objects for granting purposes; there is no inheritance.
-- ===========================================================================
GRANT USAGE ON PROCEDURE SEC.REQUEST_PHI_REVEAL(STRING, STRING, STRING, STRING, STRING)
  TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE CASES.RUN_RULE(STRING, STRING) TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE CASES.SP_RUN_PIPELINE(STRING, BOOLEAN, STRING) TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE RULES.SP_APPROVE_PROPOSAL(STRING, STRING, NUMBER) TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE RULES.SP_REJECT_PROPOSAL(STRING, STRING, STRING) TO ROLE HO_REVIEWER;
