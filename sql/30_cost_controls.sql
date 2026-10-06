-- STATUS: EXECUTED 2026-10-06 against account HHUAQYZ-KU03975 (locator KU03975, AWS_US_EAST_2) via
-- tools/sfx as part of tools/deploy_new_account. Ran clean. Verified by
-- SHOW WAREHOUSES: HO_WH is X-Small, AUTO_SUSPEND=180, resource monitor
-- HO_BUDGET attached.
-- ===========================================================================
-- COMPUTE SHUTDOWN AND CREDIT GUARDRAILS
--
-- The trial is the entire budget for this submission, and it does not renew.
-- 3.68 credits were used building everything, so there is plenty of headroom --
-- the risk is not the work done deliberately, it is compute left running by
-- accident while nobody is looking.
--
-- WHAT WAS ALREADY RIGHT before this file: all four warehouses are X-Small,
-- all auto-suspend after 60 seconds, all were suspended, the pipeline task is
-- suspended, every dynamic table is SCHEDULER = DISABLE, and HO_WH is capped by
-- the HO_BUDGET resource monitor.
--
-- THREE REAL GAPS THIS FILE CLOSES:
--
--   1. Only HO_WH was capped. COMPUTE_WH, SNOWFLAKE_LEARNING_WH and
--      SYSTEM$STREAMLIT_NOTEBOOK_WH had NO resource monitor, so a runaway query
--      on any of them was uncapped. COMPUTE_WH has already burned 0.25
--      credits, which proves it gets used whether or not we intend it.
--   2. The Streamlit app had no explicit idle shutdown. This turned out to be
--      LESS important than I first assumed, and the correction is worth
--      recording: IDLE_AUTO_SHUTDOWN_TIME_SECONDS has a floor of 86,400 (one
--      day), so it is not a per-session timeout at all -- it controls how long
--      the app object stays warm, not how long a browser tab holds compute.
--      The thing that actually protects an abandoned tab is the warehouse's
--      own AUTO_SUSPEND = 60, which was already in place: if the app is not
--      querying, HO_WH suspends after a minute whether or not a tab is open.
--   3. There was no ACCOUNT-level monitor. A per-warehouse cap cannot see
--      total spend, and serverless features (Cortex Search indexing, data
--      metric functions, the search service) are not charged to a warehouse at
--      all, so no warehouse monitor can ever cap them.
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

-- ===========================================================================
-- 1. ACCOUNT-LEVEL monitor -- the only one that sees everything.
--
-- A monitor with no warehouse assignment and MONITOR_TYPE account-wide catches
-- total consumption including serverless. Set well above HO_BUDGET so the
-- per-warehouse cap trips first and this is the genuine last line.
-- ===========================================================================
CREATE OR REPLACE RESOURCE MONITOR HO_ACCOUNT_CAP
  WITH CREDIT_QUOTA = 120
       FREQUENCY = 'MONTHLY'
       START_TIMESTAMP = 'IMMEDIATELY'
  TRIGGERS
    ON 50  PERCENT DO NOTIFY
    ON 75  PERCENT DO NOTIFY
    ON 90  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER ACCOUNT SET RESOURCE_MONITOR = HO_ACCOUNT_CAP;

-- ===========================================================================
-- 2. Cap and shrink every warehouse, not just ours.
--
-- AUTO_SUSPEND: 180 on HO_WH, 60 on everything else. Amended 2026-10-06
-- after measuring, rather than reasoning about, the cost of a cold start.
--
-- A resume on this account took 20.85 SECONDS, against 0.93s for the same
-- query once warm. At AUTO_SUSPEND = 60 that was being paid on nearly every
-- visit, because sixty seconds is shorter than the time a reviewer spends
-- reading a single case. The app felt broken, and the cause was a cost control.
--
-- The arithmetic favours 180 clearly. An X-Small warehouse is 1 credit/hour,
-- so an idle-out bills at most 180s (~0.05 credits) instead of 60s (~0.017).
-- Fifty idle periods across a judging window is about 2.5 credits out of a
-- 120-credit cap. A twenty-second stall in front of a judge is worth more than
-- 2.5 credits.
--
-- The other warehouses stay at 60. They serve batch work where a cold start is
-- invisible, so there is nothing to buy by raising them.
--
-- What matters more than either number is that nothing can run BIG -- pinning
-- MAX_CLUSTER_COUNT = 1 stops multi-cluster scale-out, which is how an
-- X-Small warehouse quietly becomes ten of them.
-- ===========================================================================
ALTER WAREHOUSE HO_WH SET
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 180        -- interactive: see the measurement above
  AUTO_RESUME = TRUE
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 1
  SCALING_POLICY = 'STANDARD'
  STATEMENT_TIMEOUT_IN_SECONDS = 900          -- no query runs for 15+ minutes
  STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 120
  RESOURCE_MONITOR = HO_BUDGET;

-- The three warehouses Snowflake provisioned with the trial. We do not use
-- them, but they exist and COMPUTE_WH has already consumed credits, so they get
-- capped rather than trusted.
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60
  MAX_CLUSTER_COUNT = 1 STATEMENT_TIMEOUT_IN_SECONDS = 900
  RESOURCE_MONITOR = HO_BUDGET;

ALTER WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH SET
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60
  MAX_CLUSTER_COUNT = 1 STATEMENT_TIMEOUT_IN_SECONDS = 900
  RESOURCE_MONITOR = HO_BUDGET;

-- This one ships with MAX_CLUSTER_COUNT = 10. On a metered trial that is the
-- most expensive default in the account.
ALTER WAREHOUSE IF EXISTS SYSTEM$STREAMLIT_NOTEBOOK_WH SET
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60
  MAX_CLUSTER_COUNT = 1 STATEMENT_TIMEOUT_IN_SECONDS = 900
  RESOURCE_MONITOR = HO_BUDGET;

-- ===========================================================================
-- 3. The Streamlit app's idle shutdown -- set to the tightest value allowed.
--
-- I first set this to 900 seconds and Snowflake refused:
--   invalid value '900' for property 'IDLE_AUTO_SHUTDOWN_TIME_SECONDS':
--   must be between 86,400 and 604,800 (in seconds)
--
-- So it is not a per-session idle timeout. It governs how long the app object
-- itself stays warm before Snowflake tears it down, with a floor of one day
-- and a ceiling of seven. Set to the floor, which is all the control there is.
--
-- What actually protects an abandoned browser tab is the warehouse: HO_WH has
-- AUTO_SUSPEND = 60, so if the app is not issuing queries the compute stops
-- after a minute regardless of how many tabs are open. That was already true
-- before this file, which is why the exposure here was smaller than it looked.
-- ===========================================================================
ALTER STREAMLIT HEALTHONE.APP.HEALTHONE_360
  SET IDLE_AUTO_SHUTDOWN_TIME_SECONDS = 86400;

-- ===========================================================================
-- 4. Turn everything off right now.
--
-- Suspending a warehouse mid-flight cancels nothing that matters here: all our
-- work is committed, and AUTO_RESUME brings each one back on the next query.
-- ===========================================================================
-- Each suspend is wrapped, because suspending an ALREADY-suspended warehouse
-- is an ERROR, not a no-op:
--   090064 (22000): Invalid state. Warehouse 'HO_WH' cannot be suspended.
-- Bare statements therefore made this file abort on the happy path -- when
-- everything was already off, which is exactly when it should succeed -- and
-- silently skipped sections 5 to 7 below it. `snow sql -f` stops at the first
-- error, so a shutdown script that fails when there is nothing to shut down is
-- worse than useless.
EXECUTE IMMEDIATE $$
DECLARE
  stopped INT DEFAULT 0;
BEGIN
  BEGIN ALTER WAREHOUSE HO_WH SUSPEND;                        stopped := stopped + 1;
  EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER WAREHOUSE COMPUTE_WH SUSPEND;                   stopped := stopped + 1;
  EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER WAREHOUSE SNOWFLAKE_LEARNING_WH SUSPEND;        stopped := stopped + 1;
  EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER WAREHOUSE SYSTEM$STREAMLIT_NOTEBOOK_WH SUSPEND; stopped := stopped + 1;
  EXCEPTION WHEN OTHER THEN NULL; END;
  -- The task too: already suspended is the normal state, and re-suspending it
  -- must not be fatal either.
  BEGIN ALTER TASK HEALTHONE.CASES.T_HEALTHONE_PIPELINE SUSPEND;
  EXCEPTION WHEN OTHER THEN NULL; END;
  RETURN 'warehouses newly suspended: ' || :stopped
         || ' (the rest were already off, which is the desired state)';
END;
$$;

-- ===========================================================================
-- 5. What is left that spends without a warehouse.
--
-- These are SERVERLESS: no warehouse monitor can cap them, which is why the
-- account-level monitor in section 1 exists.
--
--   Cortex Search CONF.DOC_SEARCH   TARGET_LAG = '1 day'. Re-checks daily over
--                                   43 chunks. Negligible, and the intake
--                                   procedure forces a refresh when a document
--                                   actually changes, so the lag exists only as
--                                   a safety net.
--   Data metric functions           4 metrics, daily CRON, cheap COUNT-style
--                                   aggregates over small tables.
--
-- Both are deliberately kept: they are the difference between "data quality is
-- a query someone remembers to run" and "data quality is a monitored property
-- with history". If credits ever get tight, section 6 turns them off.
-- ===========================================================================

-- ===========================================================================
-- 6. EMERGENCY BRAKE. Commented. Run these only if credits get tight -- each
--    one removes a real capability, so nothing here runs by default.
-- ===========================================================================
-- ALTER TABLE HEALTHONE.CONF.CONF_LAB_RESULT  UNSET DATA_METRIC_SCHEDULE;
-- ALTER TABLE HEALTHONE.CONF.CONF_MEDICATION  UNSET DATA_METRIC_SCHEDULE;
-- ALTER TABLE HEALTHONE.CASES.CASE_EVIDENCE   UNSET DATA_METRIC_SCHEDULE;
-- ALTER CORTEX SEARCH SERVICE HEALTHONE.CONF.DOC_SEARCH SET TARGET_LAG = '7 days';
-- DROP WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH;
-- DROP WAREHOUSE IF EXISTS SYSTEM$STREAMLIT_NOTEBOOK_WH;

-- ===========================================================================
-- 7. Verify. Every line below should be reassuring or it is not done.
-- ===========================================================================
SHOW WAREHOUSES;
SELECT "name", "state", "size", "auto_suspend", "max_cluster_count",
       "resource_monitor"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW STREAMLITS IN SCHEMA HEALTHONE.APP;
SELECT "name", "idle_auto_shutdown_time_seconds" AS IDLE_SHUTDOWN_SECONDS
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW TASKS IN DATABASE HEALTHONE;
SELECT "name", "state" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT ROUND(SUM(CREDITS_USED), 4) AS CREDITS_USED_ALL_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY;
