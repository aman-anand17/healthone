-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- NATIVE DATA QUALITY with Snowflake Data Metric Functions (DMFs).
--
-- WHY THIS EXISTS ALONGSIDE tests/assertions.sql
-- The 47 assertions in tests/ are hand-rolled SQL that someone has to
-- remember to run. That is a test suite, and a test suite only tells you
-- about the moment it ran. DMFs are different in kind: they ATTACH to a
-- table, Snowflake evaluates them on a schedule, and the results land in a
-- system view — so data quality becomes a monitored property of the data
-- rather than something a human periodically checks.
--
-- The two are complementary and both are kept:
--   tests/assertions.sql   a gate. Blocks a deploy. Run by a person or CI.
--   DMFs (this file)       a monitor. Runs itself. Answers "was this data
--                          healthy last Tuesday?" — which a test cannot.
--
-- WHAT IS MEASURED, and why each one matters for THIS product:
--   1. unmapped lab rate   — the P1131 mechanism. If this climbs, detection
--                            is going blind to more results and the queue is
--                            filling with false gaps. The single most
--                            important operational number in the system.
--   2. orphan case rate    — a case pointing at a person who does not exist
--                            means the crosswalk or a join is broken.
--   3. missing-searched    — a MISSING verdict with no `searched` string is
--                            an unfalsifiable claim. Must always be zero.
--   4. future-dated labs   — a result dated after the evaluation date would
--                            silently satisfy a monitoring requirement.
--   5. duplicate active meds — the H-01 hazard that would abort the MERGE.
--
-- COST: DMFs are serverless and billed per evaluation. The schedule is
-- therefore DAILY, and the functions are deliberately cheap COUNT-style
-- aggregates over small tables (docs/02 §5).
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA SEC; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. The metric functions.
--
-- A DMF receives the table as an argument and returns one NUMBER. Keeping
-- them as rates rather than raw counts means a threshold is meaningful
-- regardless of how much data has been loaded.
-- ===========================================================================

CREATE OR REPLACE DATA METRIC FUNCTION SEC.DMF_UNMAPPED_LAB_PCT(
  t TABLE(LAB_TEST_ID STRING))
RETURNS NUMBER
COMMENT = 'Percent of lab results whose test name did not map to the controlled vocabulary. Rising = detection going blind.'
AS
$$
  SELECT IFF(COUNT(*) = 0, 0,
             ROUND(100.0 * COUNT_IF(LAB_TEST_ID IS NULL) / COUNT(*), 2))
  FROM t
$$;

CREATE OR REPLACE DATA METRIC FUNCTION SEC.DMF_MISSING_WITHOUT_SEARCHED(
  t TABLE(VERDICT STRING, SEARCHED STRING))
RETURNS NUMBER
COMMENT = 'Count of MISSING verdicts with no searched string. An unfalsifiable claim. Must be 0.'
AS
$$
  SELECT COUNT_IF(VERDICT = 'MISSING' AND (SEARCHED IS NULL OR TRIM(SEARCHED) = ''))
  FROM t
$$;

CREATE OR REPLACE DATA METRIC FUNCTION SEC.DMF_FUTURE_DATED(
  t TABLE(RESULT_DATE DATE))
RETURNS NUMBER
COMMENT = 'Count of clinical results dated after the evaluation anchor. Would silently satisfy a rule.'
AS
$$
  SELECT COUNT_IF(RESULT_DATE > (SELECT AS_OF FROM HEALTHONE.CONF.DATE_ANCHOR))
  FROM t
$$;

CREATE OR REPLACE DATA METRIC FUNCTION SEC.DMF_DUP_ACTIVE_MEDS(
  t TABLE(PERSON_ID STRING, DRUG_ID STRING, STATUS STRING))
RETURNS NUMBER
COMMENT = 'People with more than one ACTIVE order for the same drug. Hazard H-01: would abort the case MERGE.'
AS
$$
  SELECT COUNT(*) FROM (
    SELECT PERSON_ID, DRUG_ID FROM t
    WHERE STATUS = 'ACTIVE'
    GROUP BY PERSON_ID, DRUG_ID
    HAVING COUNT(*) > 1)
$$;

-- ===========================================================================
-- 2. Attach them — BLOCKED, and fixable with one grant.
--
-- The functions above CREATE fine. Attaching one to a table is an
-- account-level operation, so it needs a privilege HO_ADMIN does not hold:
--
--   Attempted : ALTER TABLE CONF.CONF_LAB_RESULT ADD DATA METRIC FUNCTION ...
--   Result    : "Insufficient privileges to operate on table
--                'CONF_LAB_RESULT'. Your primary role HO_ADMIN ... must have
--                EXECUTE DATA METRIC FUNCTION granted on ACCOUNT HF31719."
--
-- Run ONCE as ACCOUNTADMIN, then uncomment the block below:
--   GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE HO_ADMIN;
--
-- Until then §3's view gives the same readings on demand — what is missing is
-- only the unattended SCHEDULED evaluation and the history in
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS.
--
-- ALTER TABLE CONF.CONF_LAB_RESULT SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
-- ALTER TABLE CONF.CONF_LAB_RESULT
--   ADD DATA METRIC FUNCTION SEC.DMF_UNMAPPED_LAB_PCT ON (LAB_TEST_ID);
-- ALTER TABLE CONF.CONF_LAB_RESULT
--   ADD DATA METRIC FUNCTION SEC.DMF_FUTURE_DATED ON (RESULT_DATE);
--
-- ALTER TABLE CONF.CONF_MEDICATION SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
-- ALTER TABLE CONF.CONF_MEDICATION
--   ADD DATA METRIC FUNCTION SEC.DMF_DUP_ACTIVE_MEDS ON (PERSON_ID, DRUG_ID, STATUS);
--
-- ALTER TABLE CASES.CASE_EVIDENCE SET DATA_METRIC_SCHEDULE = 'USING CRON 30 6 * * * UTC';
-- ALTER TABLE CASES.CASE_EVIDENCE
--   ADD DATA METRIC FUNCTION SEC.DMF_MISSING_WITHOUT_SEARCHED ON (VERDICT, SEARCHED);

-- ===========================================================================
-- 3. Evaluate on demand too, so the app can show a current reading rather
--    than waiting for the next scheduled evaluation.
-- ===========================================================================
CREATE OR REPLACE VIEW SEC.V_DATA_QUALITY
COMMENT = 'Current data-quality readings with an explicit pass threshold each.'
AS
SELECT 'Unmapped lab results'          AS METRIC,
       (SELECT ROUND(100.0 * COUNT_IF(LAB_TEST_ID IS NULL) / NULLIF(COUNT(*),0), 2)
          FROM CONF.CONF_LAB_RESULT)   AS VALUE,
       '%'                             AS UNIT,
       10                              AS THRESHOLD,
       'Results whose test name did not map to the vocabulary. These cannot satisfy a rule, so a rising number means more false monitoring gaps.' AS WHY
UNION ALL
SELECT 'MISSING verdicts with no search statement',
       (SELECT COUNT(*) FROM CASES.CASE_EVIDENCE
         WHERE VERDICT='MISSING' AND (SEARCHED IS NULL OR TRIM(SEARCHED)='')),
       'rows', 0,
       'A MISSING claim without a stated search is unfalsifiable. Must be zero.'
UNION ALL
SELECT 'Clinical results dated after the evaluation date',
       (SELECT COUNT(*) FROM CONF.CONF_LAB_RESULT l CROSS JOIN CONF.DATE_ANCHOR a
         WHERE l.RESULT_DATE > a.AS_OF),
       'rows', 0,
       'A future-dated result would silently satisfy a monitoring requirement.'
UNION ALL
SELECT 'Duplicate ACTIVE orders per person and drug',
       (SELECT COUNT(*) FROM (SELECT PERSON_ID, DRUG_ID FROM CONF.CONF_MEDICATION
                               WHERE STATUS='ACTIVE' GROUP BY 1,2 HAVING COUNT(*)>1)),
       'rows', 0,
       'Hazard H-01: duplicates produce two candidates with one key and abort the case MERGE.'
UNION ALL
SELECT 'Cases pointing at an unknown person',
       (SELECT COUNT(*) FROM CASES.CASE_REGISTRY c
         WHERE NOT EXISTS (SELECT 1 FROM CONF.CONF_PERSON_XWALK x
                            WHERE x.PERSON_ID = c.PERSON_ID)),
       'rows', 0,
       'Would mean the identity crosswalk or a join is broken.'
UNION ALL
SELECT 'Open cases',
       (SELECT COUNT(*) FROM CASES.CASE_REGISTRY WHERE STATUS='OPEN'),
       'cases', 60,
       'Not a defect, a workload signal. A queue in the hundreds trains reviewers to ignore it.';

GRANT SELECT ON VIEW SEC.V_DATA_QUALITY TO ROLE HO_REVIEWER;
GRANT SELECT ON VIEW SEC.V_DATA_QUALITY TO ROLE HO_AUDITOR;

SELECT * FROM SEC.V_DATA_QUALITY;
