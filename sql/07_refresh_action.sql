-- STATUS: EXECUTED 2026-08-21 via `snow sql -f` — full sequence ran clean
-- end to end (0 rows throughout, no data loaded yet; MERGE and the resolve
-- sweep both compiled and ran with 0 inserted/updated). Rewritten against
-- docs/self-tracking/03_SCHEMA_DESIGN.md §10.2. This is what the app's
-- [Refresh queue] button runs.
--
-- WHY THE ORDER MATTERS: every dynamic table here has SCHEDULER = DISABLE
-- (docs/02 §5 — cost guardrail). A manual refresh of a disabled table does
-- NOT cascade to its own upstream sources. Refreshing DT_CASE_CANDIDATE
-- alone would evaluate rules against STALE P360 timelines and produce a
-- confidently wrong queue (H-12). The five REFRESH statements below must run
-- in this exact order: each table's sources must be current before it is
-- refreshed.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- Step 1 — refresh P360, upstream to downstream.
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_MEDICATION_TIMELINE REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_LAB_TIMELINE        REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_ACTIVE_MEDICATION   REFRESH;  -- reads CONF only, order vs LAB_TIMELINE doesn't matter, but must precede P360_PERSON
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_PERSON              REFRESH;  -- reads P360_ACTIVE_MEDICATION for ACTIVE_MED_COUNT

-- Step 2 — refresh detection, now that its sources are current.
ALTER DYNAMIC TABLE HEALTHONE.CASES.DT_CASE_CANDIDATE REFRESH;

-- Step 3 — reconcile candidates into the mutable registry. Only STATUS/
-- disposition columns are excluded from the update — a disposition must
-- never be overwritten by a refresh.
MERGE INTO HEALTHONE.CASES.CASE_REGISTRY t
USING HEALTHONE.CASES.DT_CASE_CANDIDATE s
   ON t.CANDIDATE_KEY = s.CANDIDATE_KEY
WHEN MATCHED THEN UPDATE SET
   t.VERSION              = s.VERSION,
   t.PRIORITY             = s.PRIORITY,
   t.PRIORITY_FACTORS     = s.PRIORITY_FACTORS,
   t.WINDOW_START_DATE    = s.WINDOW_START_DATE,
   t.REFERENCE_EVENT_TYPE = s.REFERENCE_EVENT_TYPE,
   t.REFERENCE_EVENT_DATE = s.REFERENCE_EVENT_DATE,
   t.DAYS_SINCE_REFERENCE = s.DAYS_SINCE_REFERENCE,
   t.LAST_REFRESHED_AT    = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
   (CANDIDATE_KEY, PERSON_ID, CASE_TYPE, RULE_ID, VERSION, DRUG_ID, LAB_TEST_ID,
    PRIORITY, PRIORITY_FACTORS, WINDOW_START_DATE, REFERENCE_EVENT_TYPE,
    REFERENCE_EVENT_DATE, DAYS_SINCE_REFERENCE, STATUS, LAST_REFRESHED_AT)
   VALUES
   (s.CANDIDATE_KEY, s.PERSON_ID, s.CASE_TYPE, s.RULE_ID, s.VERSION, s.DRUG_ID, s.LAB_TEST_ID,
    s.PRIORITY, s.PRIORITY_FACTORS, s.WINDOW_START_DATE, s.REFERENCE_EVENT_TYPE,
    s.REFERENCE_EVENT_DATE, s.DAYS_SINCE_REFERENCE, 'OPEN', CURRENT_TIMESTAMP());

-- Step 4 — candidates that disappeared close themselves honestly. Only OPEN
-- cases are eligible: a DISMISSED case must stay dismissed even if its
-- candidate reappears identically (the reviewer already ruled on it).
UPDATE HEALTHONE.CASES.CASE_REGISTRY t
   SET STATUS = 'RESOLVED_BY_DATA', LAST_REFRESHED_AT = CURRENT_TIMESTAMP()
 WHERE t.STATUS = 'OPEN'
   AND NOT EXISTS (
     SELECT 1 FROM HEALTHONE.CASES.DT_CASE_CANDIDATE s
     WHERE s.CANDIDATE_KEY = t.CANDIDATE_KEY
   );

-- The app also inserts AUDIT_EVENT rows for QUEUE_REFRESHED, and for each
-- CASE_CREATED / CASE_RESOLVED_BY_DATA this refresh produced (app/data_access.py).
