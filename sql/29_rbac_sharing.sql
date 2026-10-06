-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- RBAC FOR SHARING THE APP WITH JUDGES AND TEAMMATES
--
-- READ THIS FIRST: WHAT "PUBLIC LINK" CAN AND CANNOT MEAN
-- Streamlit in Snowflake is served from inside Snowsight. There is no
-- anonymous access to it -- a viewer must sign in to a Snowflake account that
-- has been granted the app. That is not a configuration we have failed to
-- find; SiS has no public-URL mode. Anyone claiming otherwise is describing a
-- different product (Streamlit Community Cloud, or a Native App listing).
--
-- So "make the link public" resolves to exactly one workable thing:
--
--   grant the app to a role, grant that role to a login, and hand out the URL
--   plus that login.
--
-- This file does the whole grant side. It deliberately does NOT create a user
-- or set a password -- passwords must be chosen and entered by Aman, not
-- written into a file that goes to GitHub. Section 4 has the two statements to
-- run by hand.
--
-- WHY BOTHER WITH A REVIEWER ROLE AT ALL, rather than sharing ACCOUNTADMIN
-- Because the product's central governance claim is that a reviewer sees
-- masked patient data and must break the glass deliberately. Handing a judge
-- an ACCOUNTADMIN login would show them an app with every masking policy
-- effectively bypassed, and the demo would prove the opposite of what it
-- claims. HO_REVIEWER is the role the product is designed around, and it is
-- the role a judge should see it through.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. The app object and its schema.
-- ===========================================================================
GRANT USAGE ON DATABASE HEALTHONE            TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.APP          TO ROLE HO_REVIEWER;
GRANT USAGE ON STREAMLIT HEALTHONE.APP.HEALTHONE_360 TO ROLE HO_REVIEWER;
GRANT USAGE ON WAREHOUSE HO_WH               TO ROLE HO_REVIEWER;

-- ===========================================================================
-- 2. Read access to everything the app queries.
--
-- FUTURE GRANTS as well as current ones. Without the future grant, the next
-- table or view added to a schema is invisible to the reviewer and the app
-- fails on a page nobody thought to re-test -- which is precisely how the
-- masking defect and the missing procedure grant went unnoticed for days.
-- ===========================================================================
GRANT USAGE ON SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT USAGE ON SCHEMA HEALTHONE.RAW   TO ROLE HO_REVIEWER;

GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;

GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;

-- DYNAMIC TABLES ARE A SEPARATE OBJECT TYPE FOR GRANTS.
--
-- `GRANT SELECT ON ALL TABLES` does NOT cover them, and the entire P360 layer -
-- P360_PERSON, P360_LAB_TIMELINE, P360_MEDICATION_TIMELINE,
-- P360_ACTIVE_MEDICATION - plus CASES.DT_CASE_CANDIDATE are dynamic tables. So
-- a reviewer could read the case queue and not a single patient record:
--   Object 'HEALTHONE.P360.P360_PERSON' does not exist or not authorized.
--
-- WHY THIS SURVIVED AN EARLIER TEST THAT SHOULD HAVE CAUGHT IT. The role was
-- first exercised as user AMANANAND1701 with `USE ROLE HO_REVIEWER`, and that
-- user holds HO_ADMIN too with DEFAULT_SECONDARY_ROLES = ALL - so Snowflake
-- satisfied the read through the secondary role and 28/28 checks passed. It was
-- never a clean test of HO_REVIEWER. The first honest one was the public
-- service account, which holds nothing else.
--
-- Lesson worth keeping: to test a role, use a principal that has ONLY that role.
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA HEALTHONE.P360  TO ROLE HO_REVIEWER;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;

-- The document staging area is read to populate the intake screen, and the
-- reviewer must be able to read the corpus a citation points at.
GRANT READ ON STAGE HEALTHONE.RAW.DOC_STAGE TO ROLE HO_REVIEWER;

-- ===========================================================================
-- 3. WRITE access -- deliberately narrow.
--
-- A reviewer may: approve or reject a rule proposal, run a rule, run the
-- pipeline, request a PHI reveal, record a disposition, ingest documents.
-- A reviewer may NOT: write to any table directly. Every one of those actions
-- goes through a stored procedure that also writes the audit row, so the
-- action and its record cannot be separated. That is the entire point of
-- granting procedures instead of tables.
-- ===========================================================================
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL PROCEDURES IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT USAGE ON ALL FUNCTIONS  IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA HEALTHONE.CASES TO ROLE HO_REVIEWER;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA HEALTHONE.RULES TO ROLE HO_REVIEWER;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA HEALTHONE.SEC   TO ROLE HO_REVIEWER;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA HEALTHONE.CONF  TO ROLE HO_REVIEWER;

-- The two tables the app updates outside a procedure. Kept explicit and
-- minimal rather than granting INSERT across a schema.
GRANT INSERT, UPDATE ON TABLE HEALTHONE.CASES.CASE_NARRATIVE TO ROLE HO_REVIEWER;
GRANT UPDATE          ON TABLE HEALTHONE.RULES.EXTRACTOR_CONFIG TO ROLE HO_REVIEWER;

-- Cortex Search, and the entitlement the AI calls need.
-- The Cortex Search service only exists on a Cortex-entitled account (sql/27
-- creates it). On a trial account where every Cortex function is refused there
-- is nothing to grant on, and a bare GRANT here aborted the whole file - taking
-- with it every grant BELOW this line, which is how a reviewer ended up unable
-- to read the dynamic tables. Wrapped so a missing service costs this one
-- grant and nothing else. The app already falls back to native SEARCH() and
-- says so on screen, so the capability gap is visible without this grant.
EXECUTE IMMEDIATE $$
BEGIN
  GRANT USAGE ON CORTEX SEARCH SERVICE HEALTHONE.CONF.DOC_SEARCH TO ROLE HO_REVIEWER;
  RETURN 'granted usage on CONF.DOC_SEARCH';
EXCEPTION WHEN OTHER THEN
  RETURN 'SKIPPED: no Cortex Search service on this account (' || SQLERRM || ')';
END;
$$;
-- A semantic view is queried, not "used": USAGE is rejected with
-- "Invalid object type 'SEMANTIC_VIEW' for privilege 'USAGE'", and
-- GRANT SELECT ON ALL VIEWS does not cover it either -- it is its own object
-- type and needs naming explicitly.
GRANT SELECT ON SEMANTIC VIEW HEALTHONE.P360.HEALTHONE_360 TO ROLE HO_REVIEWER;

-- ===========================================================================
-- 4. THE TWO STATEMENTS TO RUN BY HAND, as ACCOUNTADMIN.
--
-- Not in this file, and not automated, because they involve a password. A
-- password committed to a repository is a password that has been disclosed,
-- and this repository is going to GitHub.
--
--   CREATE USER JUDGE_HO360
--     PASSWORD = '<choose one, do not reuse anything>'
--     DEFAULT_ROLE      = HO_REVIEWER
--     DEFAULT_WAREHOUSE = HO_WH
--     DEFAULT_NAMESPACE = HEALTHONE.APP
--     MUST_CHANGE_PASSWORD = FALSE
--     COMMENT = 'Read-mostly login for hackathon judges. Sees the app as a
--                Clinical Case Reviewer, with PHI masked.';
--   GRANT ROLE HO_REVIEWER TO USER JUDGE_HO360;
--
-- Then give out:
--   URL  https://app.snowflake.com/KUMZGAJ/oo64644/#/streamlit-apps/HEALTHONE.APP.HEALTHONE_360
--   user JUDGE_HO360
--   pass <the one you chose>
--
-- After the event: DROP USER JUDGE_HO360;
-- ===========================================================================

-- ===========================================================================
-- 5. Row scoping for the reviewer role.
--
-- CLINIC_SCOPE limits a reviewer to their assigned clinics. A judge assigned
-- to nothing would see ZERO patients and conclude the app is broken -- which
-- is exactly what happened once already and is why SEC.V_SESSION_DIAGNOSTIC
-- exists. The wildcard assignment is therefore deliberate and recorded.
-- ===========================================================================
-- The column is PRIMARY_CLINIC, and the rows already in this table are
-- assigned to user 'AMAN' -- the username on the ORIGINAL account. Neither
-- AMANANAND1701 nor a judge login matches it, so without the wildcard row the
-- policy filters all 312 patients and the app looks empty for everyone.
MERGE INTO SEC.REVIEWER_ASSIGNMENT t
USING (SELECT '*' AS USER_NAME, '*' AS PRIMARY_CLINIC) s
   ON t.USER_NAME = s.USER_NAME AND t.PRIMARY_CLINIC = s.PRIMARY_CLINIC
WHEN NOT MATCHED THEN INSERT (USER_NAME, PRIMARY_CLINIC)
     VALUES (s.USER_NAME, s.PRIMARY_CLINIC);

-- ===========================================================================
-- 6. Verify by asking, not by assuming.
-- ===========================================================================
SHOW GRANTS TO ROLE HO_REVIEWER;

SELECT 'HO_REVIEWER can see the app' AS check_name,
       COUNT(*) AS n
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "granted_on" = 'STREAMLIT';
