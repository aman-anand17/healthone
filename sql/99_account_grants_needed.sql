-- ============================================================================
-- ACCOUNT-LEVEL GRANTS STILL NEEDED
--
-- Run this ONCE as ACCOUNTADMIN in Snowsight. Everything here is a privilege
-- HO_ADMIN cannot grant itself, because each one is scoped to the ACCOUNT
-- rather than to an object HO_ADMIN owns.
--
-- Nothing in this file is required for the product to WORK today. Each grant
-- upgrades an already-working capability from "on demand" to "unattended", or
-- from "attached per column" to "attached per classification". The
-- corresponding SQL is written and left commented in the file named below, so
-- enabling a feature is: run the grant, uncomment the block, re-run the file.
--
-- Every one of these was discovered by attempting the operation and reading
-- the error, not by guessing.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- 1. Let the nightly pipeline schedule actually run.       (sql/18)
--
-- Without it: SP_RUN_PIPELINE works by direct call — which is what the app's
-- "Run pipeline now" button and the Operations page use — but
-- `ALTER TASK T_HEALTHONE_PIPELINE RESUME` fails, so the pipeline cannot run
-- unattended overnight.
--
-- Cost note: the task is DAILY at 06:00 UTC on the existing XSMALL warehouse
-- and exits early when no stream reports new data, so enabling it does not
-- introduce continuous spend. It also ships SUSPENDED; enabling the grant
-- does not start it. The Operations page has the on/off switch.
-- ----------------------------------------------------------------------------
GRANT EXECUTE TASK ON ACCOUNT TO ROLE HO_ADMIN;

-- ----------------------------------------------------------------------------
-- 2. Let data-quality metrics be evaluated on a schedule.  (sql/19)
--
-- Without it: SEC.V_DATA_QUALITY gives every reading on demand and the app
-- shows them live. What is missing is the scheduled evaluation and the
-- history in SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS — i.e. the
-- ability to answer "was this data healthy last Tuesday?".
-- ----------------------------------------------------------------------------
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE HO_ADMIN;

-- ----------------------------------------------------------------------------
-- 3. Let masking follow a CLASSIFICATION rather than a column.  (sql/16)
--
-- Without it: patient identity is still fully protected — masking policies are
-- attached directly to P360_PERSON and verified working (assertion A-15). What
-- is missing is tag-based assignment, where any column tagged PHI inherits
-- protection automatically, including columns that do not exist yet.
-- ----------------------------------------------------------------------------
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE HO_ADMIN;

-- ----------------------------------------------------------------------------
-- 4. Optional: let the app run as the reviewer role rather than the admin.
--
-- Today the app connects as AMAN/HO_ADMIN. HO_ADMIN is a build role, and it is
-- better hygiene for the reviewer workflow to run under HO_REVIEWER. PHI
-- masking already applies to HO_ADMIN as well, so this changes nothing about
-- protection — it makes the demo's role story cleaner, and lets the row access
-- policy (clinic scoping) be shown working.
-- ----------------------------------------------------------------------------
GRANT ROLE HO_REVIEWER TO USER AMAN;
GRANT ROLE HO_AUDITOR  TO USER AMAN;
GRANT USAGE ON WAREHOUSE HO_WH TO ROLE HO_AUDITOR;

-- ----------------------------------------------------------------------------
-- 5. NOT FIXABLE BY A GRANT — recorded so nobody retries it.
--
-- Cortex AI functions (AI_COMPLETE and the whole family) and Cortex Search
-- return error 399258 "not available for trial accounts". This was tested
-- AFTER `GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE HO_ADMIN` was applied: the
-- privilege landed (confirmed via SHOW GRANTS) and the error did not change by
-- one character. Cortex Search additionally needs EMBED_TEXT_768, blocked the
-- same way.
--
-- It is a trial-tier PRODUCT restriction. The only remedies are a payment
-- method on the account or a non-trial account. Do not spend more time on
-- grants for this.
-- ----------------------------------------------------------------------------

-- Verify what landed:
SHOW GRANTS TO ROLE HO_ADMIN;
