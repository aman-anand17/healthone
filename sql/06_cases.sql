-- STATUS: EXECUTED 2026-08-21 via `snow sql -f`. DT_CASE_CANDIDATE compiled
-- AND executed cleanly (0 rows, no data loaded yet) on the first deploy —
-- the full detection predicate, the QUALIFY guard, both CTE branches, all
-- verified live. CASE_REGISTRY/CASE_EVIDENCE/AUDIT_EVENT created; all grants
-- applied. Rewritten against
-- docs/self-tracking/03_SCHEMA_DESIGN.md §10. THE core design nuance: the
-- dynamic table is stateless detection; CASE_REGISTRY is mutable lifecycle.
-- Dispositions survive refresh because they live only in the registry.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CASES; USE WAREHOUSE HO_WH;

-- ============================================================================
-- DT_CASE_CANDIDATE — grain: one row per open detection finding (§10.1).
-- SCHEDULER=DISABLE + REFRESH_MODE=FULL, same as all P360 tables — refresh
-- only via sql/07's ordered cascade.
--
-- Design question §14 (RESOLVED 2026-08-21, amends DECISIONS C3):
-- EFFECTIVE_DATE is NOT in the window GREATEST — it only gates whether the
-- rule applies at all. A new, stricter rule version does not retroactively
-- invalidate labs that were already acceptable; see the reasoning in the
-- schema doc §14.
--
-- CANDIDATE_KEY = (PERSON_ID, CASE_TYPE, RULE_ID, DRUG_ID). VERSION is
-- deliberately excluded (H-05) — including it would mint a new key on every
-- rule-version supersede and duplicate every open case mid-demo.
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE DT_CASE_CANDIDATE
  SCHEDULER = DISABLE
  REFRESH_MODE = FULL
  WAREHOUSE = HO_WH
AS
WITH anchor AS (
  SELECT AS_OF FROM CONF.DATE_ANCHOR
),
-- Pre-aggregate diagnoses (H-02): a duplicated diagnosis row must not
-- multiply the case. MIN(onset) is the earliest recorded onset.
dx_agg AS (
  SELECT PERSON_ID, CONDITION_ID, MIN(ONSET_DATE) AS ONSET_DATE
  FROM CONF.CONF_DIAGNOSIS
  GROUP BY PERSON_ID, CONDITION_ID
),
-- Pre-aggregate labs to their latest qualifying result per person+test.
-- Unmapped results (LAB_TEST_ID NULL) and future-dated results are excluded
-- before aggregation, not filtered after — an unidentifiable result must
-- never satisfy a safety requirement (H-07), and a mis-dated future result
-- must never mask a real gap (H-09).
lab_agg AS (
  SELECT l.PERSON_ID, l.LAB_TEST_ID, MAX(l.RESULT_DATE) AS LAST_RESULT_DATE
  FROM P360.P360_LAB_TIMELINE l
  CROSS JOIN anchor a
  WHERE l.LAB_TEST_ID IS NOT NULL
    AND l.RESULT_DATE <= a.AS_OF
  GROUP BY l.PERSON_ID, l.LAB_TEST_ID
),
-- ---------------------------------------------------------------- MONITORING_GAP
-- No correlated subquery, no NOT EXISTS (H-08): lab_agg holds the maximum
-- qualifying result date, so "no qualifying result in the window" is exactly
-- "that maximum is before window_start" (or there is no row at all). The
-- MAX also doubles as the "N days since last result" figure shown on screen.
gap AS (
  SELECT
    m.PERSON_ID,
    'MONITORING_GAP'                                    AS CASE_TYPE,
    r.RULE_ID,
    r.VERSION,
    m.DRUG_ID,
    r.LAB_TEST_ID,
    GREATEST(m.THERAPY_START_DATE, d.ONSET_DATE,
              a.AS_OF - (r.INTERVAL_DAYS + r.GRACE_DAYS)) AS WINDOW_START_DATE,
    'LAST_QUALIFYING_LAB'                                AS REFERENCE_EVENT_TYPE,
    l.LAST_RESULT_DATE                                   AS REFERENCE_EVENT_DATE,
    DATEDIFF('day', l.LAST_RESULT_DATE, a.AS_OF)          AS DAYS_SINCE_REFERENCE,
    r.INTERVAL_DAYS,
    r.GRACE_DAYS
  FROM RULES.SAFETY_RULE r
  CROSS JOIN anchor a
  JOIN P360.P360_ACTIVE_MEDICATION m ON m.DRUG_ID = r.DRUG_ID
  JOIN dx_agg d                      ON d.PERSON_ID = m.PERSON_ID
                                     AND d.CONDITION_ID = r.CONDITION_ID
  LEFT JOIN lab_agg l                ON l.PERSON_ID = m.PERSON_ID
                                     AND l.LAB_TEST_ID = r.LAB_TEST_ID
  WHERE r.STATUS = 'ACTIVE'
    AND r.PRECONDITION_TYPE = 'CONDITION'          -- age_min not implemented in v1
    AND r.EFFECTIVE_DATE <= a.AS_OF                -- gates applicability only (§14)
    AND COALESCE(l.LAST_RESULT_DATE, DATE '1900-01-01') <
        GREATEST(m.THERAPY_START_DATE, d.ONSET_DATE,
                  a.AS_OF - (r.INTERVAL_DAYS + r.GRACE_DAYS))
),
-- ---------------------------------------------------------------- MED_CONFLICT
-- Semi-join to monitored_drugs (H-03): a join here would fan out one
-- person+drug into one row per matching rule and produce duplicate keys.
-- "We don't create work for drugs nobody is monitoring" — without this
-- filter, the ~15% of the background cohort with ragged fill histories
-- floods the queue with MEDIUM-priority noise and buries the real case.
-- 90-day window (not 180, resolved 2026-08-21): three missed 30-day refill
-- cycles, and consistent with GP2's own 150-day scripted gap (180 days would
-- never have fired it).
monitored_drugs AS (
  SELECT DISTINCT DRUG_ID FROM RULES.SAFETY_RULE WHERE STATUS = 'ACTIVE'
),
conflict AS (
  SELECT
    m.PERSON_ID,
    'MED_CONFLICT'                                       AS CASE_TYPE,
    NULL::VARCHAR(40)                                    AS RULE_ID,
    NULL::NUMBER(4,0)                                     AS VERSION,
    m.DRUG_ID,
    NULL::VARCHAR(40)                                    AS LAB_TEST_ID,
    m.THERAPY_START_DATE                                 AS WINDOW_START_DATE,
    'LAST_PHARMACY_FILL'                                 AS REFERENCE_EVENT_TYPE,
    m.LAST_FILL_DATE                                     AS REFERENCE_EVENT_DATE,
    DATEDIFF('day', m.LAST_FILL_DATE, a.AS_OF)            AS DAYS_SINCE_REFERENCE,
    NULL::NUMBER(5,0)                                     AS INTERVAL_DAYS,
    NULL::NUMBER(5,0)                                     AS GRACE_DAYS
  FROM P360.P360_ACTIVE_MEDICATION m
  CROSS JOIN anchor a
  WHERE m.EHR_STATUS = 'ACTIVE'
    AND m.FILLS_LAST_90D = 0
    AND m.DRUG_ID IN (SELECT DRUG_ID FROM monitored_drugs)
),
combined AS (
  SELECT PERSON_ID, CASE_TYPE, RULE_ID, VERSION, DRUG_ID, LAB_TEST_ID,
         WINDOW_START_DATE, REFERENCE_EVENT_TYPE, REFERENCE_EVENT_DATE,
         DAYS_SINCE_REFERENCE, INTERVAL_DAYS, GRACE_DAYS
  FROM gap
  UNION ALL
  SELECT PERSON_ID, CASE_TYPE, RULE_ID, VERSION, DRUG_ID, LAB_TEST_ID,
         WINDOW_START_DATE, REFERENCE_EVENT_TYPE, REFERENCE_EVENT_DATE,
         DAYS_SINCE_REFERENCE, INTERVAL_DAYS, GRACE_DAYS
  FROM conflict
)
SELECT
  MD5(PERSON_ID || '|' || CASE_TYPE || '|' ||
      COALESCE(RULE_ID,'') || '|' || COALESCE(DRUG_ID,''))  AS CANDIDATE_KEY,
  PERSON_ID, CASE_TYPE, RULE_ID, VERSION, DRUG_ID, LAB_TEST_ID,
  WINDOW_START_DATE, REFERENCE_EVENT_TYPE, REFERENCE_EVENT_DATE, DAYS_SINCE_REFERENCE,
  -- Priority: graded for MONITORING_GAP (resolved 2026-08-21), flat MEDIUM
  -- for MED_CONFLICT. Exactly two levels; every factor is on screen (C8).
  CASE
    WHEN CASE_TYPE = 'MONITORING_GAP'
         AND (REFERENCE_EVENT_DATE IS NULL
              OR DAYS_SINCE_REFERENCE >= INTERVAL_DAYS + GRACE_DAYS + 30)
      THEN 'HIGH'
    WHEN CASE_TYPE = 'MONITORING_GAP' THEN 'MEDIUM'
    ELSE 'MEDIUM'
  END AS PRIORITY,
  CASE
    WHEN CASE_TYPE = 'MONITORING_GAP' THEN ARRAY_CONSTRUCT(
      IFF(REFERENCE_EVENT_DATE IS NULL,
          'No qualifying result was found in the available records',
          DAYS_SINCE_REFERENCE::STRING || ' days since last qualifying result'),
      'Rule requires monitoring every ' || INTERVAL_DAYS::STRING ||
        ' days (+' || GRACE_DAYS::STRING || ' grace)')
    ELSE ARRAY_CONSTRUCT(
      'EHR lists medication ACTIVE',
      'No pharmacy fill in the last 90 days')
  END AS PRIORITY_FACTORS
FROM combined
-- Defence in depth (§10.1): even with every upstream grain fix, this
-- guarantees CANDIDATE_KEY is unique before it ever reaches the MERGE in
-- sql/07. A duplicate reaching that MERGE aborts it with a duplicate-source
-- error — mid-demo. Assertion A-08 verifies this QUALIFY never actually has
-- to discard a row.
QUALIFY ROW_NUMBER() OVER (PARTITION BY CANDIDATE_KEY ORDER BY WINDOW_START_DATE DESC) = 1;

-- ============================================================================
-- CASE_REGISTRY — grain: one row per case, for its lifetime (§10.2). The
-- ONLY mutable table in the product. STATUS and DISPOSITION are kept
-- separate and mapped explicitly — the original draft wrote the disposition
-- code into both, which conflates "what the human chose" with "where the
-- case now sits in the workflow".
-- ============================================================================
CREATE OR REPLACE TABLE CASE_REGISTRY (
  CASE_ID               VARCHAR(60)  NOT NULL DEFAULT 'CAS-' || UUID_STRING(),
  CANDIDATE_KEY         VARCHAR(64)  NOT NULL,
  PERSON_ID             VARCHAR(40)  NOT NULL,
  CASE_TYPE             VARCHAR(30)  NOT NULL,
  RULE_ID               VARCHAR(40),
  VERSION               NUMBER(4,0),
  DRUG_ID               VARCHAR(40)  NOT NULL,
  LAB_TEST_ID           VARCHAR(40),
  PRIORITY              VARCHAR(10)  NOT NULL,
  PRIORITY_FACTORS      ARRAY        NOT NULL,
  WINDOW_START_DATE     DATE,
  REFERENCE_EVENT_TYPE  VARCHAR(30),
  REFERENCE_EVENT_DATE  DATE,
  DAYS_SINCE_REFERENCE  NUMBER(6,0),
  STATUS                VARCHAR(30)  NOT NULL DEFAULT 'OPEN',
  -- OPEN | ESCALATED | EVIDENCE_REQUESTED | REVIEWED | DISMISSED | RESOLVED_BY_DATA
  DISPOSITION           VARCHAR(40),
  -- ESCALATE_FOR_CLINICAL_REVIEW | REQUEST_ADDITIONAL_EVIDENCE |
  -- MARK_REVIEWED | DISMISS_WITH_REASON
  DISPOSITION_REASON    VARCHAR(1000),
  DISPOSED_BY           VARCHAR(60),
  DISPOSED_AT           TIMESTAMP_TZ,
  CREATED_AT            TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  LAST_REFRESHED_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (CASE_ID),
  UNIQUE (CANDIDATE_KEY)
);

-- ============================================================================
-- CASE_EVIDENCE — grain: one row per (case, claim); rebuilt idempotently by
-- the reconciler (§10.3). CLAIM_KEY gives tests a stable identity to assert
-- on instead of prose. Exactly three verdicts (C5) — CHANGED_OVER_TIME was
-- cut; rule versioning stays, period-effective evaluation does not.
-- ============================================================================
CREATE OR REPLACE TABLE CASE_EVIDENCE (
  EVIDENCE_ID    VARCHAR(60)   NOT NULL DEFAULT 'EVD-' || UUID_STRING(),
  CASE_ID        VARCHAR(60)   NOT NULL,
  CLAIM_KEY      VARCHAR(40)   NOT NULL,
  -- DRUG_ACTIVE | CONDITION_PRESENT | REQUIRED_LAB | MEDICATION_DISPENSING
  CLAIM_TEXT     VARCHAR(1000) NOT NULL,
  VERDICT        VARCHAR(20)   NOT NULL,   -- AGREES | CONFLICTS | MISSING
  EVIDENCE_REFS  ARRAY         NOT NULL,   -- [{type,source_system,source_record_id,detail}]
  SEARCHED       VARCHAR(1000),            -- REQUIRED when VERDICT='MISSING' (A-11)
  GENERATED_AT   TIMESTAMP_TZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (EVIDENCE_ID)
);

-- ============================================================================
-- AUDIT_EVENT — append-only (§10.4). EVENT_AT, not AT — AT is reserved for
-- time-travel syntax (H-14). Append-only is enforced by grants below, not
-- just convention: HO_REVIEWER gets INSERT/SELECT, never UPDATE/DELETE.
-- ============================================================================
CREATE OR REPLACE TABLE AUDIT_EVENT (
  EVENT_ID      VARCHAR(60)  NOT NULL DEFAULT 'AUD-' || UUID_STRING(),
  EVENT_TYPE    VARCHAR(40)  NOT NULL,
  -- DOC_INGESTED | RULE_PROPOSED | RULE_APPROVED | RULE_REJECTED |
  -- RULE_SUPERSEDED | RULE_RETIRED | CASE_CREATED | CASE_REFRESHED |
  -- CASE_RESOLVED_BY_DATA | CASE_DISPOSED | QUEUE_REFRESHED
  ACTOR         VARCHAR(60)  NOT NULL,
  EVENT_AT      TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  SUBJECT_TYPE  VARCHAR(30)  NOT NULL,   -- RULE | CASE | DOCUMENT | QUEUE
  SUBJECT_ID    VARCHAR(40)  NOT NULL,
  DETAIL        VARIANT,
  PRIMARY KEY (EVENT_ID)
);

-- ============================================================================
-- Grants — HO_REVIEWER can read everything here and write dispositions +
-- audit rows, never DELETE anything. HO_AUDITOR is read-only on all four.
-- ============================================================================
GRANT SELECT ON TABLE DT_CASE_CANDIDATE TO ROLE HO_REVIEWER;
GRANT SELECT, UPDATE ON TABLE CASE_REGISTRY TO ROLE HO_REVIEWER;
GRANT SELECT, INSERT ON TABLE CASE_EVIDENCE TO ROLE HO_REVIEWER;
GRANT SELECT, INSERT ON TABLE AUDIT_EVENT TO ROLE HO_REVIEWER;

GRANT SELECT ON TABLE DT_CASE_CANDIDATE TO ROLE HO_AUDITOR;
GRANT SELECT ON TABLE CASE_REGISTRY TO ROLE HO_AUDITOR;
GRANT SELECT ON TABLE CASE_EVIDENCE TO ROLE HO_AUDITOR;
GRANT SELECT ON TABLE AUDIT_EVENT TO ROLE HO_AUDITOR;
