-- STATUS: EXECUTED 2026-08-21 via `snow sql -f`. All 4 dynamic tables created;
-- both masking policies attached without error. NOT YET VERIFIED end-to-end:
-- testing as HO_AUDITOR needs `GRANT USAGE ON WAREHOUSE HO_WH TO ROLE
-- HO_AUDITOR` (still pending ACCOUNTADMIN — see the project journal). Schema/table
-- grants for that test are already in place. Rewritten against
-- docs/self-tracking/03_SCHEMA_DESIGN.md §8. ALL dynamic tables here use
-- SCHEDULER = DISABLE (no TARGET_LAG — illegal alongside it) + explicit
-- REFRESH_MODE = FULL. Verified live 2026-08-21: SCHEDULER=DISABLE is real
-- syntax, took effect (target_lag comes back blank), and REFRESH_MODE=FULL
-- is honored rather than silently downgraded by AUTO. Refresh is manual only
-- (sql/07), in dependency order, because a disabled table's refresh does not
-- cascade upstream.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA P360; USE WAREHOUSE HO_WH;

-- ============================================================================
-- P360_MEDICATION_TIMELINE — grain: one row per medication EVENT (§8.1).
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE P360_MEDICATION_TIMELINE
  SCHEDULER = DISABLE
  REFRESH_MODE = FULL
  WAREHOUSE = HO_WH
AS
  SELECT PERSON_ID, DRUG_ID, 'ORDER_START' AS EVENT_TYPE, START_DATE AS EVENT_DATE,
         STATUS AS DETAIL, SOURCE_SYSTEM, SOURCE_RECORD_ID
  FROM CONF.CONF_MEDICATION
  UNION ALL
  SELECT PERSON_ID, DRUG_ID, 'ORDER_STOP', STOP_DATE, STATUS, SOURCE_SYSTEM, SOURCE_RECORD_ID
  FROM CONF.CONF_MEDICATION
  WHERE STOP_DATE IS NOT NULL
  UNION ALL
  SELECT PERSON_ID, DRUG_ID, 'FILL', FILL_DATE,
         'days_supply=' || COALESCE(DAYS_SUPPLY::STRING, 'unknown'), SOURCE_SYSTEM, SOURCE_RECORD_ID
  FROM CONF.CONF_PHARMACY_FILL;

-- ============================================================================
-- P360_LAB_TIMELINE — grain: one row per lab result (§8.2). Pass-through,
-- INCLUDING unmapped rows (LAB_TEST_ID NULL) — the reviewer sees everything;
-- detection consumes only mapped rows. That asymmetry is deliberate.
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE P360_LAB_TIMELINE
  SCHEDULER = DISABLE
  REFRESH_MODE = FULL
  WAREHOUSE = HO_WH
AS
  SELECT PERSON_ID, LAB_TEST_ID, RAW_TEST_TEXT, RESULT_DATE, RESULT_VALUE, UNITS,
         SOURCE_SYSTEM, SOURCE_RECORD_ID
  FROM CONF.CONF_LAB_RESULT;

-- ============================================================================
-- P360_ACTIVE_MEDICATION — grain: EXACTLY one row per (PERSON_ID, DRUG_ID)
-- with at least one ACTIVE order (§8.3). This grain fixes H-01: the original
-- draft's grain was per-order, so two renewal orders for the same drug would
-- produce two candidate rows sharing one CANDIDATE_KEY downstream, and the
-- MERGE in sql/07 would abort with a duplicate-source error mid-demo.
--
-- Two INDEPENDENT aggregates, joined AFTER grouping (never join-then-group —
-- that is H-04: it would inflate FILLS_LAST_90D by the order count and
-- produce false MED_CONFLICT verdicts).
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE P360_ACTIVE_MEDICATION
  SCHEDULER = DISABLE
  REFRESH_MODE = FULL
  WAREHOUSE = HO_WH
AS
WITH med_agg AS (
  SELECT PERSON_ID, DRUG_ID,
         MIN(START_DATE)                    AS THERAPY_START_DATE,   -- see §8.3: MIN, not MAX
         MAX(START_DATE)                    AS LATEST_ORDER_START_DATE,
         COUNT(*)                           AS ACTIVE_ORDER_COUNT,
         ARRAY_AGG(SOURCE_RECORD_ID)         AS MED_SOURCE_RECORD_IDS
  FROM CONF.CONF_MEDICATION
  WHERE STATUS = 'ACTIVE'
  GROUP BY PERSON_ID, DRUG_ID
),
fill_agg AS (
  SELECT f.PERSON_ID, f.DRUG_ID,
         MAX(f.FILL_DATE)                                     AS LAST_FILL_DATE,
         COUNT_IF(f.FILL_DATE >= a.AS_OF - 90)                 AS FILLS_LAST_90D
  FROM CONF.CONF_PHARMACY_FILL f
  CROSS JOIN CONF.DATE_ANCHOR a
  GROUP BY f.PERSON_ID, f.DRUG_ID
)
SELECT m.PERSON_ID, m.DRUG_ID, m.THERAPY_START_DATE, m.LATEST_ORDER_START_DATE,
       m.ACTIVE_ORDER_COUNT, 'ACTIVE' AS EHR_STATUS, m.MED_SOURCE_RECORD_IDS,
       fl.LAST_FILL_DATE, COALESCE(fl.FILLS_LAST_90D, 0) AS FILLS_LAST_90D
FROM med_agg m
LEFT JOIN fill_agg fl ON fl.PERSON_ID = m.PERSON_ID AND fl.DRUG_ID = m.DRUG_ID;

-- ============================================================================
-- P360_PERSON — grain: one row per person (§8.4). AGE_YEARS uses explicit day
-- arithmetic / 365.25, never DATEDIFF('year', ...) — H-16: the year form is
-- off by one against a birthday that hasn't occurred yet this year, which
-- matters for any age_min rule. Counts come from pre-aggregated CTEs, never
-- correlated scalar subqueries (H-08). OPEN_CASE_COUNT is deliberately absent
-- — see the note at the end of this file.
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE P360_PERSON
  SCHEDULER = DISABLE
  REFRESH_MODE = FULL
  WAREHOUSE = HO_WH
AS
WITH cond_agg AS (
  SELECT PERSON_ID, COUNT(DISTINCT CONDITION_ID) AS ACTIVE_CONDITION_COUNT
  FROM CONF.CONF_DIAGNOSIS
  GROUP BY PERSON_ID
),
med_agg AS (
  SELECT PERSON_ID, COUNT(DISTINCT DRUG_ID) AS ACTIVE_MED_COUNT
  FROM P360_ACTIVE_MEDICATION
  GROUP BY PERSON_ID
)
SELECT
  x.PERSON_ID, x.PATIENT_ID, x.MEMBER_ID,
  p.NAME, p.DOB,
  FLOOR(DATEDIFF('day', p.DOB, a.AS_OF) / 365.25) AS AGE_YEARS,
  p.SEX, p.PRIMARY_CLINIC, mem.PLAN_CODE,
  COALESCE(cc.ACTIVE_CONDITION_COUNT, 0) AS ACTIVE_CONDITION_COUNT,
  COALESCE(mc.ACTIVE_MED_COUNT, 0)       AS ACTIVE_MED_COUNT
FROM CONF.CONF_PERSON_XWALK x
CROSS JOIN CONF.DATE_ANCHOR a
JOIN RAW.RAW_EHR_PATIENT p    ON p.PATIENT_ID = x.PATIENT_ID
JOIN RAW.RAW_PLAN_MEMBER mem  ON mem.MEMBER_ID = x.MEMBER_ID
LEFT JOIN cond_agg cc ON cc.PERSON_ID = x.PERSON_ID
LEFT JOIN med_agg mc  ON mc.PERSON_ID = x.PERSON_ID;

-- NOTE: OPEN_CASE_COUNT is not a column here. Adding it would make P360
-- depend on CASES, and CASES already depends on P360 (DT_CASE_CANDIDATE
-- reads P360_ACTIVE_MEDICATION / P360_LAB_TIMELINE) — a dependency cycle
-- Snowflake would reject outright. The app computes it from CASE_REGISTRY
-- at read time instead.

-- ============================================================================
-- Masking — applied here, on P360_PERSON, NEVER on a join key (H-10).
-- CONF.MASK_PERSON_NAME already exists (sql/00). A second policy is required
-- for DOB: a (v STRING)->STRING policy cannot attach to a DATE column — the
-- signature must match the column type.
-- ============================================================================
CREATE OR REPLACE MASKING POLICY CONF.MASK_PERSON_DOB AS (v DATE)
  RETURNS DATE ->
  CASE WHEN CURRENT_ROLE() IN ('HO_ADMIN','HO_REVIEWER') THEN v ELSE DATE '1900-01-01' END;

ALTER TABLE P360_PERSON MODIFY COLUMN NAME SET MASKING POLICY CONF.MASK_PERSON_NAME;
ALTER TABLE P360_PERSON MODIFY COLUMN DOB  SET MASKING POLICY CONF.MASK_PERSON_DOB;

-- ============================================================================
-- Verification — run these as HO_AUDITOR (not HO_ADMIN) to prove masking
-- actually propagates through a materialized dynamic table. Do not assume it
-- does; the design doc (03_SCHEMA_DESIGN §11) flags this as unverified until
-- checked. If HO_AUDITOR can still read NAME/DOB here, the policy attached
-- but is not being enforced through the DT refresh, and the fallback is a
-- secure view over P360_PERSON for that role instead.
-- ============================================================================
-- USE ROLE HO_AUDITOR; USE WAREHOUSE HO_WH;
-- SELECT PERSON_ID, NAME, DOB FROM HEALTHONE.P360.P360_PERSON LIMIT 5;
-- expect NAME = '***MASKED***', DOB = '1900-01-01' for every row.
