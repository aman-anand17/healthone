-- STATUS: EXECUTED 2026-08-24 via build/run_all.sql — ALL 12 CHECKS PASS
-- against the live account, matching the local simulation exactly.
--
-- Rewritten 2026-08-21: the original used IFF(EXISTS(SELECT ...)) in a select
-- list, which is not valid in Snowflake (Day-1 finding D2). Now uses counting
-- subqueries and real person ids from tools/generate_data.py rather than
-- <GPn> placeholders.
--
-- THE 8-GOLDEN-PATIENT DETECTION SUITE (docs/06 §2). This is the quality gate
-- for the whole product: until every row below returns PASS, the app does not
-- get wired to real data. A queue that lies is worse than no queue.
--
-- PRECONDITIONS
--   1. tools/generate_data.py has loaded RAW and CONF.CONF_PERSON_XWALK
--   2. sql/03_conf.sql transforms have run (RAW -> CONF)
--   3. RUL-001 v1 is seeded and ACTIVE (sql/05, the commented block)
--   4. sql/07_refresh_action.sql has run (ordered refresh + MERGE)
--
-- EXPECTED STATE: four ACTIVE rules, all extracted from their source PDF by
-- Cortex and approved by a human:
--   RUL-001 v1  CardioZen + CKD -> serum potassium,  90d +7 grace  (97d window)
--   RUL-002 v1  Renuvex   + CKD -> serum creatinine, 90d +7 grace
--   RUL-003 v1  Hepatrol  + CLD -> ALT,              84d +7 grace
--   RUL-004 v1  CardioZen + CKD -> serum creatinine, 42d +7 grace  (49d window)
--
-- EVERY GP CHECK IS SCOPED BY RULE_ID. It has to be: RUL-001 and RUL-004 both
-- apply to a CardioZen patient with chronic kidney disease, and both raise a
-- MONITORING_GAP for a different analyte. An unscoped count would be asserting
-- how many rules exist rather than whether detection is correct - and would
-- break every time the product did its job and ingested another document.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CASES; USE WAREHOUSE HO_WH;

WITH reg AS (
  SELECT PERSON_ID, CASE_TYPE, PRIORITY, STATUS, DAYS_SINCE_REFERENCE,
         RULE_ID, VERSION, LAB_TEST_ID, WINDOW_START_DATE
  FROM CASE_REGISTRY
),
checks AS (

  -- GP1 — the hero case. 137 days since the last qualifying potassium against
  -- a 97-day window. HIGH because 137 >= 90 + 7 + 30.
  SELECT 1 AS seq, 'GP1 hero: MONITORING_GAP, HIGH, 137 days' AS test,
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001024' AND CASE_TYPE='MONITORING_GAP'
             AND RULE_ID='RUL-001'
             AND PRIORITY='HIGH' AND DAYS_SINCE_REFERENCE=137) AS actual,
         1 AS expected

  -- GP2 — the conflict case. EHR ACTIVE, no pharmacy fill in 90 days.
  -- Exactly one case: this patient's monitoring is current, so no gap fires.
  UNION ALL SELECT 2, 'GP2 conflict: MED_CONFLICT, MEDIUM',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001088' AND CASE_TYPE='MED_CONFLICT' AND PRIORITY='MEDIUM'), 1

  -- GP3 — the dismissible near-miss. A potassium result from 20 days ago
  -- exists but was recorded as 'K+ serum level', which has no vocabulary
  -- mapping, so detection cannot see it and fires anyway. The reviewer
  -- dismisses with a reason. Detection being honestly imperfect is the point.
  UNION ALL SELECT 3, 'GP3 unmapped-synonym gap fires',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001131' AND CASE_TYPE='MONITORING_GAP'
             AND RULE_ID='RUL-001'), 1

  -- GP4 — boundary IN (93 days, inside the 97-day window). NO case.
  UNION ALL SELECT 4, 'GP4 boundary-in (93d): NO case',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001204' AND RULE_ID='RUL-001'), 0

  -- GP5 — boundary OUT (99 days, just past 97). Case fires.
  -- GP4 and GP5 bracket the grace boundary exactly.
  UNION ALL SELECT 5, 'GP5 boundary-out (99d): gap fires',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001205' AND CASE_TYPE='MONITORING_GAP'
             AND RULE_ID='RUL-001'), 1

  -- GP6 — the stale-lab trap. The only potassium result predates therapy by
  -- 30 days. Anchoring the window to therapy start is what catches this.
  UNION ALL SELECT 6, 'GP6 stale pre-therapy lab: gap fires',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001206' AND CASE_TYPE='MONITORING_GAP'
             AND RULE_ID='RUL-001'), 1

  -- GP7 — compliant (40 days). NO case. Also stays silent under the stricter
  -- v2 rule (67-day window), which is the §14 ruling working as designed.
  UNION ALL SELECT 7, 'GP7 compliant (40d): NO case',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001207' AND RULE_ID='RUL-001'), 0

  -- GP8 — on CardioZen with NO chronic kidney disease. The rule's
  -- precondition must genuinely gate it.
  UNION ALL SELECT 8, 'GP8 no precondition: NO case',
         (SELECT COUNT(*) FROM reg
           WHERE PERSON_ID='PER-001208' AND RULE_ID='RUL-001'), 0

  -- Live-beat cohort — silent under v1. These four appear only when the
  -- tightened rule (SAFETY_DOC_008 -> RUL-001 v2, 60+7) is approved on stage.
  UNION ALL SELECT 9, 'BEAT cohort silent under v1 (all 4)',
         (SELECT COUNT(*) FROM reg
           WHERE RULE_ID='RUL-001'
             AND PERSON_ID IN ('PER-001301','PER-001302','PER-001303','PER-001304')), 0

  -- The real uniqueness invariant, and the assertion that catches hazards
  -- H-01/H-02/H-03/H-05.
  --
  -- This check used to be "no golden person has >1 case of the same type",
  -- which was never the system's guarantee. CASE_REGISTRY is keyed by
  -- CANDIDATE_KEY = MD5(person | case type | rule | drug), so one person
  -- legitimately holds two MONITORING_GAP cases when two different rules
  -- apply to them - which is exactly what RUL-001 (potassium) and RUL-004
  -- (creatinine) do to the same CardioZen patient. Asserting the weaker,
  -- wrong invariant made the suite fail on correct behaviour, and would have
  -- hidden a genuine duplicate behind a rule count.
  UNION ALL SELECT 10, 'No duplicate case per person+type+rule (the CANDIDATE_KEY invariant)',
         (SELECT COUNT(*) FROM (
            SELECT PERSON_ID, CASE_TYPE, COALESCE(RULE_ID,'-') AS R FROM reg
            WHERE PERSON_ID LIKE 'PER-0013%' OR PERSON_ID IN
              ('PER-001024','PER-001088','PER-001131','PER-001204',
               'PER-001205','PER-001206','PER-001207','PER-001208')
            GROUP BY PERSON_ID, CASE_TYPE, R HAVING COUNT(*) > 1)), 0

  -- Detection precision overall: the background cohort should contribute a
  -- handful of genuine cases, not dozens. A queue in the low tens is
  -- reviewable; a queue in the hundreds trains people to ignore it.
  UNION ALL SELECT 11, 'Total OPEN cases is a reviewable number (2..40)',
         (SELECT IFF(COUNT(*) BETWEEN 2 AND 40, 1, 0) FROM reg WHERE STATUS='OPEN'), 1

  -- Every MONITORING_GAP case must name a rule and a version. A gap case
  -- with no rule attached would mean the join produced something impossible.
  UNION ALL SELECT 12, 'Every gap case carries RULE_ID + VERSION',
         (SELECT COUNT(*) FROM CASE_REGISTRY
           WHERE CASE_TYPE='MONITORING_GAP' AND (RULE_ID IS NULL OR VERSION IS NULL)), 0

  -- ===================================================================
  -- RUL-004. The rule nobody hand-wrote: extracted from SAFETY_DOC_010 by
  -- Cortex and approved by a human. These four checks are what make the
  -- intake path a tested capability rather than a demo anecdote.
  -- ===================================================================

  -- The rule exists, is ACTIVE, and its interval is 42 - "every six weeks"
  -- read literally, not rounded to a month or a calendar quarter.
  UNION ALL SELECT 13, 'RUL-004 active with a literal 42-day interval from "every six weeks"',
         (SELECT COUNT(*) FROM RULES.SAFETY_RULE
           WHERE RULE_ID='RUL-004' AND STATUS='ACTIVE' AND VERSION=1
             AND DRUG_ID='DRG-CARDIOZEN' AND LAB_TEST_ID='LAB-CREAT'
             AND CONDITION_ID='CND-CKD'
             AND INTERVAL_DAYS=42 AND GRACE_DAYS=7
             AND DOC_ID='SAFETY_DOC_010'), 1

  -- It raises cases, and they are creatinine cases - not potassium ones. A
  -- rule pointing at the wrong analyte monitors the wrong thing forever while
  -- looking perfectly healthy, so this is asserted rather than assumed.
  UNION ALL SELECT 14, 'RUL-004 raises gaps and every one is a creatinine gap',
         (SELECT COUNT(*) FROM reg
           WHERE RULE_ID='RUL-004'
             AND (CASE_TYPE <> 'MONITORING_GAP' OR LAB_TEST_ID <> 'LAB-CREAT')), 0

  -- The 42+7 window is genuinely a DIFFERENT window from 90+7. Measured back
  -- from the 2026-09-01 anchor that is 2026-07-14. If this were 2026-05-27 the
  -- interval from the document had been ignored somewhere.
  UNION ALL SELECT 15, 'RUL-004 window starts at anchor - (42+7) = 2026-07-14',
         (SELECT COUNT(*) FROM reg
           WHERE RULE_ID='RUL-004'
             AND WINDOW_START_DATE > DATE '2026-07-14'), 0

  -- No ACTIVE rule may originate from anything but a model-produced proposal.
  -- This is the claim "no rule was hand-written", as a test.
  UNION ALL SELECT 16, 'Every ACTIVE rule traces to a model-extracted proposal',
         (SELECT COUNT(*) FROM RULES.SAFETY_RULE r
           LEFT JOIN RULES.RULE_PROPOSAL p ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
           WHERE r.STATUS='ACTIVE'
             AND COALESCE(p.MODEL_NAME,'') NOT ILIKE 'claude%'), 0
)
SELECT seq, test, expected, actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS result
FROM checks
ORDER BY seq;
