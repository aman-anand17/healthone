-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx as part of tools/deploy_new_account. Ran clean.
-- FIX: the row access policy silently hid every patient in the deployed app.
--
-- WHAT HAPPENED
-- SEC.CLINIC_SCOPE allows a row only if SEC.REVIEWER_ASSIGNMENT has a row for
-- CURRENT_USER() and that clinic. REVIEWER_ASSIGNMENT listed only 'AMAN'.
-- From the CLI that is exactly right - 313 rows visible. But inside Streamlit
-- in Snowflake CURRENT_USER() is the SNOWSIGHT LOGIN, not AMAN, so the policy
-- filtered P360_PERSON to zero rows for anyone else.
--
-- The failure was worse than a blank field: the case page computes an age band
-- with a CASE expression whose ELSE branch is '85+'. A NULL age (no row) fell
-- into ELSE, so a data-access failure rendered as a plausible clinical value.
-- That is the most dangerous kind of bug in a product like this - it does not
-- look broken. The band now returns '-' for NULL, so absence looks like
-- absence.
--
-- THE FIX: a wildcard assignment. USER_NAME = '*' means "any authenticated
-- user", which is what a shared demo account needs. The scoping mechanism
-- stays completely real - delete the '*' rows and clinic restriction bites
-- immediately, which is how it should be demonstrated.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- Wildcard: any user, every clinic. Demo convenience, deliberately visible in
-- the data rather than hidden in the policy body.
DELETE FROM SEC.REVIEWER_ASSIGNMENT WHERE USER_NAME = '*';
INSERT INTO SEC.REVIEWER_ASSIGNMENT (USER_NAME, PRIMARY_CLINIC)
SELECT '*', c.CLINIC FROM (
  SELECT 'Northgate Clinic' AS CLINIC UNION ALL
  SELECT 'Riverside Clinic' UNION ALL
  SELECT 'Eastfield Clinic') c;

ALTER ROW ACCESS POLICY SEC.CLINIC_SCOPE SET BODY ->
  EXISTS (
    SELECT 1 FROM SEC.REVIEWER_ASSIGNMENT a
    WHERE a.PRIMARY_CLINIC = clinic
      AND (a.USER_NAME = CURRENT_USER() OR a.USER_NAME = '*')
  );

-- A view the app can show so this class of problem is never silent again:
-- it states plainly who the session is and whether they can see patients.
CREATE OR REPLACE VIEW SEC.V_SESSION_DIAGNOSTIC
COMMENT = 'Session identity and whether row scoping is currently permitting data.'
AS
SELECT
  CURRENT_USER()                                        AS SESSION_USER_NAME,
  CURRENT_ROLE()                                        AS SESSION_ROLE,
  (SELECT COUNT(*) FROM P360.P360_PERSON)               AS PERSONS_VISIBLE,
  (SELECT COUNT(*) FROM SEC.REVIEWER_ASSIGNMENT
    WHERE USER_NAME = CURRENT_USER())                    AS OWN_ASSIGNMENTS,
  (SELECT COUNT(*) FROM SEC.REVIEWER_ASSIGNMENT
    WHERE USER_NAME = '*')                               AS WILDCARD_ASSIGNMENTS,
  (SELECT COUNT(*) FROM SEC.PHI_REVEAL_GRANT
    WHERE GRANTED_TO = CURRENT_USER()
      AND EXPIRES_AT > CURRENT_TIMESTAMP())              AS ACTIVE_REVEALS;

GRANT SELECT ON VIEW SEC.V_SESSION_DIAGNOSTIC TO ROLE HO_REVIEWER;
GRANT SELECT ON VIEW SEC.V_SESSION_DIAGNOSTIC TO ROLE HO_AUDITOR;
GRANT SELECT ON VIEW SEC.V_SESSION_DIAGNOSTIC TO ROLE PUBLIC;
GRANT SELECT ON TABLE SEC.REVIEWER_ASSIGNMENT TO ROLE PUBLIC;

SELECT * FROM SEC.V_SESSION_DIAGNOSTIC;
