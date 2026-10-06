-- STATUS: EXECUTED 2026-08-21 via `snow sql -f` (account AVJJFQC-OM65092,
-- region AWS_AP_SOUTHEAST_7), except ONE grant (see note below) that needs
-- ACCOUNTADMIN. Part A ran manually in Snowsight 2026-08-20 as ACCOUNTADMIN.
-- Source of truth: docs/02_ARCHITECTURE.md §3, §5 (Cost guardrails).

-- ============================================================================
-- PART A — account-level setup. EXECUTED 2026-08-20 (verbatim, as run).
-- ============================================================================
-- USE ROLE ACCOUNTADMIN;
--
-- -- compute: smallest size, sleeps after 60s idle
-- CREATE WAREHOUSE IF NOT EXISTS HO_WH
--   WITH WAREHOUSE_SIZE = 'XSMALL'
--        AUTO_SUSPEND = 60
--        AUTO_RESUME  = TRUE
--        INITIALLY_SUSPENDED = TRUE;
--
-- -- roles: builder, app user, read-only auditor
-- CREATE ROLE IF NOT EXISTS HO_ADMIN;
-- CREATE ROLE IF NOT EXISTS HO_REVIEWER;
-- CREATE ROLE IF NOT EXISTS HO_AUDITOR;
--
-- -- HO_ADMIN needs to create the database and call the AI functions
-- GRANT CREATE DATABASE ON ACCOUNT TO ROLE HO_ADMIN;
-- GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_ADMIN;
-- GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_REVIEWER;
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE HO_ADMIN;
--
-- -- credit guardrail (docs/02 §5) — 60 credits/month, notify/suspend/kill
-- CREATE OR REPLACE RESOURCE MONITOR HO_BUDGET
--   WITH CREDIT_QUOTA = 60
--        FREQUENCY = 'MONTHLY'
--        START_TIMESTAMP = 'IMMEDIATELY'
--   TRIGGERS
--     ON 75  PERCENT DO NOTIFY
--     ON 90  PERCENT DO SUSPEND
--     ON 100 PERCENT DO SUSPEND_IMMEDIATE;
-- ALTER WAREHOUSE HO_WH SET RESOURCE_MONITOR = HO_BUDGET;
--
-- -- model entitlement probe (docs/08 §2) — result: see the project journal, pending
-- -- confirmation of exact output; cross-region inference was enabled below
-- -- because the direct-region probes did not answer.
-- USE ROLE HO_ADMIN; USE WAREHOUSE HO_WH;
-- SELECT AI_COMPLETE('claude-opus-5',   'Reply with the single word: ok');
-- SELECT AI_COMPLETE('claude-sonnet-5', 'Reply with the single word: ok');
-- SELECT AI_COMPLETE('claude-opus-4-8', 'Reply with the single word: ok');
--
-- USE ROLE ACCOUNTADMIN;
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
--
-- -- Aman: builds the data layer and runs deployments.
-- -- NOTE: password below was a literal placeholder in the executed script;
-- -- auth for CLI/build work now uses key-pair (RSA_PUBLIC_KEY), so it is not
-- -- security-sensitive, but rotate it in Snowsight when convenient.
-- CREATE USER IF NOT EXISTS AMAN
--   PASSWORD = '<strong-password-1>'
--   DEFAULT_ROLE = HO_ADMIN
--   DEFAULT_WAREHOUSE = HO_WH
--   MUST_CHANGE_PASSWORD = FALSE;
-- GRANT ROLE HO_ADMIN TO USER AMAN;                    -- D3, resolved
--
-- -- Still needed (run in Snowsight, once, by an account admin — not scripted
-- -- here because it registers a locally-generated public key):
-- -- ALTER USER AMAN SET RSA_PUBLIC_KEY='<see INSTALLATION.md / chat>';

-- ============================================================================
-- PART B — database + schema layer. NOT YET EXECUTED. Runs as HO_ADMIN
-- (already granted CREATE DATABASE ON ACCOUNT above) via `snow sql -f`.
-- ============================================================================
USE ROLE HO_ADMIN; USE WAREHOUSE HO_WH;

CREATE DATABASE IF NOT EXISTS HEALTHONE;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.RAW;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.CONF;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.P360;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.RULES;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.CASES;
CREATE SCHEMA IF NOT EXISTS HEALTHONE.APP;
-- HO_ADMIN owns what it creates (ALL privileges implicit) — no separate
-- GRANT ALL needed, unlike the original draft.

GRANT USAGE ON DATABASE HEALTHONE TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
-- SELECT/INSERT/UPDATE grants per table added in 05/06 after objects exist.

-- PENDING (2026-08-21): HO_ADMIN does not own HO_WH (ACCOUNTADMIN created it
-- in Part A) and has no grant option on it, so this fails as HO_ADMIN with
-- "Insufficient privileges". Run once, as ACCOUNTADMIN, in Snowsight:
--   GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_AUDITOR;
-- GRANT USAGE ON WAREHOUSE HO_WH  TO ROLE HO_AUDITOR;
GRANT USAGE ON DATABASE HEALTHONE TO ROLE HO_AUDITOR;
GRANT USAGE ON SCHEMA HEALTHONE.CASES TO ROLE HO_AUDITOR;

-- Governance demo beat: masking policy DEFINITION only (docs/02 §3, D4 —
-- 2026-08-20). Never applied to a join key. Applied to P360_PERSON.name /
-- .dob in sql/04_p360.sql, right after that table is created.
CREATE MASKING POLICY IF NOT EXISTS HEALTHONE.CONF.MASK_PERSON_NAME AS (v STRING)
  RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('HO_ADMIN','HO_REVIEWER') THEN v ELSE '***MASKED***' END;
