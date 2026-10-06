-- STATUS: SUPERSEDED 2026-08-30. NEVER EXECUTED. Do not run.
-- Replaced by: the same path: leaving SAFETY_DOC_008 PROPOSED is the reset, so there is
-- nothing to revert.
--
-- WHY THIS EXISTS
-- sql/13 rehearses the live beat by approving RUL-001 v2. That is the right
-- END state for the demo's climax but the wrong START state: the golden suite
-- asserts the v1 baseline (check 9 — the beat cohort must be SILENT until the
-- new rule is approved on stage). Rehearse the beat, then reset the stage.
--
-- Idempotent.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

DELETE FROM RULES.SAFETY_RULE   WHERE RULE_ID = 'RUL-001' AND VERSION = 2;
DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID = 'PRP-SEED-008';

UPDATE RULES.SAFETY_RULE
   SET STATUS = 'ACTIVE', SUPERSEDED_BY_VERSION = NULL
 WHERE RULE_ID = 'RUL-001' AND VERSION = 1;

-- SAFETY_DOC_008 goes back to being held back: it must be unseen by the
-- system when the demo starts, or the live beat is not live.
DELETE FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID = 'SAFETY_DOC_008';
DELETE FROM RAW.RAW_SAFETY_DOCUMENT   WHERE DOC_ID = 'SAFETY_DOC_008';
DELETE FROM CONF.DOC_CHUNK            WHERE DOC_ID = 'SAFETY_DOC_008';

-- Cases raised only by v2 must not linger. Anything created under v2 is
-- removed; v1 cases and every human disposition are untouched.
DELETE FROM CASES.CASE_EVIDENCE
 WHERE CASE_ID IN (SELECT CASE_ID FROM CASES.CASE_REGISTRY
                    WHERE RULE_ID = 'RUL-001' AND VERSION = 2);
DELETE FROM CASES.CASE_REGISTRY WHERE RULE_ID = 'RUL-001' AND VERSION = 2;

SELECT RULE_ID, VERSION, INTERVAL_DAYS, STATUS FROM RULES.SAFETY_RULE ORDER BY 1,2;
