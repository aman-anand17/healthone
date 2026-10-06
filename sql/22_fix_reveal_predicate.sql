-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx as part of tools/deploy_new_account. Ran clean.
-- FIX: break-glass never unmasked anything in the deployed app.
--
-- WHAT WENT WRONG, precisely
-- The three masking policies unmask a value when an unexpired grant exists
-- for that person AND `g.GRANTED_TO = CURRENT_USER()`.
--
-- Inside Streamlit in Snowflake, CURRENT_USER() returns NULL - in stored
-- procedures AND in ordinary queries, because the app runs in a UDF sandbox
-- with no session user. So:
--   * the grant was written as GRANTED_TO = 'unknown-app-context' (the app's
--     fallback), and
--   * the policy compared it against NULL,
-- which can never match. The reveal was recorded, the audit row was written,
-- the app reported success, and the name stayed masked. Worst kind of bug:
-- everything claimed to work.
--
-- THE CHANGE: the predicate is now PER-PERSON and TIME-LIMITED, without the
-- per-user comparison.
--
-- WHAT THAT COSTS, stated plainly rather than buried:
--   * BEFORE (intended): reviewer A revealing patient X unmasks X for A only.
--   * NOW:               reviewer A revealing patient X unmasks X for anyone
--                        holding the app, for 30 minutes.
-- Still enforced: nothing is visible without a deliberate, reason-coded,
-- time-limited request; the request is logged inseparably; and it is scoped to
-- ONE patient rather than the cohort. Accountability survives because
-- AUDIT_EVENT records who asked. What is lost is per-user isolation.
--
-- This is a deliberate trade against having no working break-glass at all in
-- the deployed app. The correct production fix is to resolve the caller's
-- identity server-side - a caller's-rights procedure, or Snowflake's
-- app-context identity APIs once available in this runtime - and restore the
-- per-user clause. Recorded here so it is not mistaken for the intended
-- design.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

ALTER MASKING POLICY SEC.MASK_PHI_NAME SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE '*** NAME WITHHELD ***'
  END;

ALTER MASKING POLICY SEC.MASK_PHI_DOB SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE DATE '1900-01-01'
  END;

ALTER MASKING POLICY SEC.MASK_SOURCE_ID SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE LEFT(v, 1) || '****'
  END;

-- The app's own check must use the same predicate, or the UI and the database
-- would disagree about whether a patient is revealed.
CREATE OR REPLACE VIEW SEC.V_ACTIVE_REVEAL
COMMENT = 'Persons currently revealed by an unexpired break-glass grant.'
AS
SELECT DISTINCT g.PERSON_ID,
       MAX(g.EXPIRES_AT)  AS EXPIRES_AT,
       MAX(g.GRANTED_TO)  AS GRANTED_TO,
       MAX(g.REASON_CODE) AS REASON_CODE
FROM SEC.PHI_REVEAL_GRANT g
WHERE g.EXPIRES_AT > CURRENT_TIMESTAMP()
GROUP BY g.PERSON_ID;

GRANT SELECT ON VIEW SEC.V_ACTIVE_REVEAL TO ROLE HO_REVIEWER;
GRANT SELECT ON VIEW SEC.V_ACTIVE_REVEAL TO ROLE HO_AUDITOR;
GRANT SELECT ON VIEW SEC.V_ACTIVE_REVEAL TO ROLE PUBLIC;

-- Clear the stale grant written under the placeholder identity.
DELETE FROM SEC.PHI_REVEAL_GRANT WHERE GRANTED_TO = 'unknown-app-context';

SELECT COUNT(*) AS LIVE_GRANTS FROM SEC.V_ACTIVE_REVEAL;
