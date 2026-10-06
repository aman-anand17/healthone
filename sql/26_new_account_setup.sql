-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- ACCOUNT-LEVEL SETUP FOR THE CORTEX-ENTITLED ACCOUNT
--
-- WHY THERE IS A SECOND ACCOUNT
-- The original account (AVJJFQC-OM65092, AWS_AP_SOUTHEAST_7) is a plain
-- Snowflake trial. Every Cortex AI function on it returns
--   399258 (0A000): AI function ... is not available for trial accounts.
-- which blocked extraction, Cortex Search, and PARSE_DOCUMENT, and also
-- blocked four account-level grants that governance features needed.
--
-- The hackathon organisers' 27 Aug mail carried a different signup link and one
-- instruction that turned out to be the whole problem: choose "AI Data Cloud",
-- NOT "Cortex Code CLI". An account created through the AI Data Cloud flow is
-- entitled. Verified on the new account before writing this file:
--   SELECT AI_COMPLETE('claude-sonnet-5', 'Reply with exactly: OK');  -> "OK"
--
-- New account: PF13333 (org KUMZGAJ, account name OO64644), AWS_US_EAST_2.
-- Reached from the CLI as tools/sfx, with its own key pair, still isolated
-- from ~/.snowflake/ so the JCI office credential remains unreachable.
--
-- RUN AS ACCOUNTADMIN. This is the only file that needs it.
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

-- ===========================================================================
-- 1. COST GUARDRAILS FIRST.
--
-- Deliberately before anything else. The $400 trial is the whole budget for
-- the submission, and the expensive mistakes in Snowflake are all things that
-- run when nobody is watching: an auto-refreshing dynamic table, a task on a
-- cron, a serverless data-metric schedule, a Cortex Search index rebuilding
-- on a short lag. Every one of those is disabled or long-lagged by default in
-- this build; the resource monitor is the backstop for the case where one is
-- switched on and forgotten.
-- ===========================================================================
CREATE WAREHOUSE IF NOT EXISTS HO_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
       AUTO_SUSPEND = 60          -- sleeps a minute after the last query
       AUTO_RESUME  = TRUE
       INITIALLY_SUSPENDED = TRUE;
ALTER WAREHOUSE HO_WH SET WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60;

CREATE OR REPLACE RESOURCE MONITOR HO_BUDGET
  WITH CREDIT_QUOTA = 40
       FREQUENCY = 'MONTHLY'
       START_TIMESTAMP = 'IMMEDIATELY'
  TRIGGERS
    ON 60  PERCENT DO NOTIFY
    ON 80  PERCENT DO NOTIFY
    ON 90  PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER WAREHOUSE HO_WH SET RESOURCE_MONITOR = HO_BUDGET;

-- The warehouses Snowflake provisions with a trial are not ours and are not
-- needed. Shrinking their idle window costs nothing and removes a way to
-- leak credits by accident.
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH SET AUTO_SUSPEND = 60;

-- ===========================================================================
-- 2. Roles. Same three as before: builder, app user, read-only auditor.
--
-- The auditor role exists so that "can someone who cannot change anything
-- still verify the audit trail?" has a demonstrable answer.
-- ===========================================================================
CREATE ROLE IF NOT EXISTS HO_ADMIN;
CREATE ROLE IF NOT EXISTS HO_REVIEWER;
CREATE ROLE IF NOT EXISTS HO_AUDITOR;

GRANT ROLE HO_ADMIN    TO ROLE ACCOUNTADMIN;
GRANT ROLE HO_REVIEWER TO ROLE HO_ADMIN;
GRANT ROLE HO_AUDITOR  TO ROLE HO_ADMIN;

-- The human running the build - resolved from the SESSION, not hardcoded.
--
-- This named AMANANAND1701 until the third account. A trial expires, a new
-- account arrives with a new username, and a hardcoded grant here means the
-- rebuild silently produces a database its owner cannot read. CURRENT_USER()
-- is the only correct answer: whoever is running this file is the human who
-- needs the roles. Quoted, because Snowflake usernames can contain characters
-- that an unquoted identifier rejects.
EXECUTE IMMEDIATE $$
BEGIN
  LET me STRING := CURRENT_USER();
  EXECUTE IMMEDIATE 'GRANT ROLE HO_ADMIN    TO USER "' || :me || '"';
  EXECUTE IMMEDIATE 'GRANT ROLE HO_REVIEWER TO USER "' || :me || '"';
  EXECUTE IMMEDIATE 'GRANT ROLE HO_AUDITOR  TO USER "' || :me || '"';
  RETURN 'roles granted to ' || :me;
END;
$$;

GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_ADMIN;
GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_REVIEWER;
GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_AUDITOR;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE HO_ADMIN;

-- ===========================================================================
-- 3. THE FOUR GRANTS THAT WERE PENDING FOR NINE DAYS.
--
-- Each of these was blocked on the old account because HO_ADMIN could not be
-- given an account-level privilege there, and each blocked a feature that had
-- to be shipped half-finished. They are listed with what they unblock, so it
-- is clear this is not a pile of privileges granted for comfort.
-- ===========================================================================

-- Unblocks: attaching Data Metric Functions to tables, so sql/19's data-quality
-- metrics become SCHEDULED monitors with history in
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS, instead of a view that only
-- answers when someone remembers to look.
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE HO_ADMIN;

-- Unblocks: tag-based masking in sql/16. Attaching a masking policy to a TAG
-- means a newly added column inherits protection from its classification
-- instead of from someone remembering to protect it. That is the difference
-- between governance and vigilance.
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE HO_ADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE HO_ADMIN;
GRANT APPLY TAG ON ACCOUNT TO ROLE HO_ADMIN;

-- Unblocks: everything Cortex. AI_COMPLETE for extraction and narrative,
-- EMBED_TEXT_768 for Cortex Search, PARSE_DOCUMENT for real PDF ingestion.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE HO_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE HO_REVIEWER;

-- Cross-region inference. us-east-2 is not one of the regions where every
-- Cortex model is hosted natively, so without this a model that exists in
-- us-east-1 is simply unavailable here. Setting ANY_REGION means the inference
-- request is routed to a region that has the model. Recorded explicitly
-- because it has a data-residency implication a reviewer is entitled to know
-- about: prompt text leaves the account's home region. Everything sent is
-- synthetic by construction (DECISIONS: fully synthetic data, invented drugs),
-- so there is no real patient information in any prompt.
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Streamlit in Snowflake: the grant is deliberately NOT here. It names a
-- schema, and the schema does not exist until sql/00 runs, so putting it in
-- this file made the file fail on its own last statement. tools/deploy_new_account
-- issues it as ACCOUNTADMIN immediately after sql/00.

-- ===========================================================================
-- 4. Prove the entitlement rather than assume it.
--
-- Three probes, one row each. If any of these fails, the AI backend must NOT
-- be switched on -- sql/24 refuses to fall back silently, and this is where
-- that decision is informed.
-- ===========================================================================
USE ROLE HO_ADMIN; USE WAREHOUSE HO_WH;

SELECT 'AI_COMPLETE claude-sonnet-5' AS probe,
       AI_COMPLETE('claude-sonnet-5', 'Reply with exactly: OK') AS result;

SELECT 'EMBED_TEXT_768 (prerequisite for Cortex Search)' AS probe,
       ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m',
                                                  'monitoring interval')) AS vector_dims;

SELECT 'CORTEX_ENABLED_CROSS_REGION' AS probe,
       SYSTEM$SHOW_ACTIVE_BEHAVIOR_CHANGE_BUNDLES() IS NOT NULL AS session_ok;
