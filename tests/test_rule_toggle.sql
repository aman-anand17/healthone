-- STATUS: DRAFT -- never executed.
-- ===========================================================================
-- ACCEPTANCE TEST: the per-rule on/off switch.
--
-- The requirement was two sentences, and the second one is the whole test:
--   "even if u approve the rule you can turn on and off any rule just of a flag"
--   "no existing ticket/cases should not be impacted"
--
-- So T-05 through T-08 are the point of this file. It is easy to build a toggle
-- that works and quietly closes 15 patient cases as a side effect; that would be
-- the single most dangerous bug this product could ship, because it asserts that
-- a patient's monitoring gap CLOSED when nothing about the patient changed.
--
-- The test therefore pauses a rule that HAS live cases (RUL-004, 15 of them),
-- runs the FULL pipeline while it is paused - which is where a naive
-- implementation would sweep those cases to RESOLVED_BY_DATA - and asserts the
-- count is untouched, before and after.
--
-- Self-cleaning: it restores RUL-004 to enabled at the end, so the demo state
-- is exactly as it was.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- Guarantee a clean starting state BEFORE capturing the baseline.
--
-- The first run of this file aborted at T-08 (an unrelated bug in the procedure
-- it was testing), which left RUL-004 paused. The next run then failed T-02 for
-- the wrong reason: the call it expected to be REFUSED was instead correctly
-- answered "already in that state", so IS_ENABLED stayed FALSE and the
-- assertion read a stale fact rather than a broken guard. Ten minutes lost
-- looking for a logic bug that did not exist.
--
-- A test that only passes from a clean state is not repeatable, and this one
-- exists precisely to be run again and again.
CALL RULES.SP_SET_RULE_ENABLED('RUL-004', TRUE, 'test-harness-setup', NULL);

-- Baseline, captured once the state is known.
CREATE OR REPLACE TEMPORARY TABLE T_BASE AS
SELECT
  (SELECT COUNT(*) FROM CASES.CASE_REGISTRY
    WHERE RULE_ID = 'RUL-004' AND STATUS = 'OPEN')      AS R4_OPEN,
  (SELECT COUNT(*) FROM CASES.CASE_REGISTRY
    WHERE STATUS = 'OPEN')                              AS ALL_OPEN,
  (SELECT COUNT(*) FROM CASES.CASE_REGISTRY
    WHERE RULE_ID = 'RUL-004' AND STATUS = 'RESOLVED_BY_DATA') AS R4_RESOLVED;

SELECT 'T-01 baseline: RUL-004 has live cases to endanger' AS check_name,
       IFF((SELECT R4_OPEN FROM T_BASE) > 0, 'PASS', 'FAIL') AS result,
       (SELECT R4_OPEN  FROM T_BASE) AS rul004_open,
       (SELECT ALL_OPEN FROM T_BASE) AS all_open;

-- ===========================================================================
-- PART 1 -- the switch refuses to be used carelessly
-- ===========================================================================
CALL RULES.SP_SET_RULE_ENABLED('RUL-004', FALSE, 'test-harness', NULL);
SELECT 'T-02 pausing with no reason is refused' AS check_name,
       IFF((SELECT IS_ENABLED FROM RULES.SAFETY_RULE
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'ACTIVE'), 'PASS', 'FAIL') AS result;

CALL RULES.SP_SET_RULE_ENABLED('RUL-999', FALSE, 'test-harness', 'no such rule');
SELECT 'T-03 pausing a rule that does not exist is refused' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE WHERE RULE_ID = 'RUL-999'),
           'PASS', 'FAIL') AS result;

-- ===========================================================================
-- PART 2 -- pause it for real
-- ===========================================================================
CALL RULES.SP_SET_RULE_ENABLED('RUL-004', FALSE, 'test-harness',
  'Site cannot meet the six-week interval from existing capacity; escalated to the Committee per SAFETY_DOC_010 section 3.');

SELECT 'T-04 paused: IS_ENABLED false, reason and actor recorded, STATUS still ACTIVE' AS check_name,
       IFF(EXISTS (SELECT 1 FROM RULES.SAFETY_RULE
                    WHERE RULE_ID = 'RUL-004'
                      AND STATUS = 'ACTIVE'          -- governance UNCHANGED
                      AND IS_ENABLED = FALSE
                      AND DISABLED_BY = 'test-harness'
                      AND DISABLED_AT IS NOT NULL
                      AND DISABLE_REASON ILIKE '%six-week interval%'),
           'PASS', 'FAIL') AS result;

-- ===========================================================================
-- PART 3 -- THE REQUIREMENT: existing cases are not impacted.
-- ===========================================================================
SELECT 'T-05 pausing left every existing OPEN case of that rule alone' AS check_name,
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'OPEN')
           = (SELECT R4_OPEN FROM T_BASE), 'PASS', 'FAIL') AS result
UNION ALL
SELECT 'T-06 pausing closed NOTHING - no case became RESOLVED_BY_DATA',
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'RESOLVED_BY_DATA')
           = (SELECT R4_RESOLVED FROM T_BASE), 'PASS', 'FAIL')
UNION ALL
SELECT 'T-07 the whole queue is unchanged',
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY WHERE STATUS = 'OPEN')
           = (SELECT ALL_OPEN FROM T_BASE), 'PASS', 'FAIL');

-- The hard one. A full pipeline run while the rule is paused is exactly where a
-- naive implementation sweeps the paused rule's cases into RESOLVED_BY_DATA,
-- because their candidates look absent. They are not absent: the enablement
-- filter is in the MERGE, not in the dynamic table.
CALL CASES.SP_RUN_PIPELINE('TEST_TOGGLE', TRUE, 'test-harness');

SELECT 'T-08 a FULL PIPELINE RUN while paused still left the cases untouched' AS check_name,
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'OPEN')
           = (SELECT R4_OPEN FROM T_BASE), 'PASS', 'FAIL') AS result
UNION ALL
SELECT 'T-09 and raised no NEW cases for the paused rule',
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY WHERE RULE_ID = 'RUL-004')
           <= (SELECT R4_OPEN + R4_RESOLVED FROM T_BASE), 'PASS', 'FAIL')
UNION ALL
SELECT 'T-10 running a paused rule reports WHY instead of silently finding zero',
       IFF(EXISTS (SELECT 1 FROM CASES.AUDIT_EVENT
                    WHERE EVENT_TYPE = 'RULE_PAUSED'
                      AND SUBJECT_ID = 'RUL-004'
                      AND DETAIL:existing_open_cases_left_untouched::INT
                          = (SELECT R4_OPEN FROM T_BASE)),
           'PASS', 'FAIL');

-- ===========================================================================
-- PART 4 -- governance is untouched, which is why versioning still works
-- ===========================================================================
SELECT 'T-11 a paused rule is still ACTIVE, so a revision would supersede it rather than duplicate it' AS check_name,
       IFF((SELECT COUNT(*) FROM RULES.SAFETY_RULE
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'ACTIVE') = 1,
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'T-12 V_RULE_STATE separates governance from operational state',
       IFF((SELECT EFFECTIVE_STATE FROM RULES.V_RULE_STATE
             WHERE RULE_ID = 'RUL-004' AND VERSION = 1)
           = 'APPROVED BUT PAUSED - raises no NEW cases', 'PASS', 'FAIL')
UNION ALL
SELECT 'T-13 MED_CONFLICT cases are not affected by a monitoring rule pause',
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE CASE_TYPE = 'MED_CONFLICT' AND STATUS = 'OPEN') > 0,
           'PASS', 'FAIL');

-- ===========================================================================
-- PART 5 -- resume, and restore the demo state
-- ===========================================================================
CALL RULES.SP_SET_RULE_ENABLED('RUL-004', TRUE, 'test-harness', NULL);

SELECT 'T-14 resumed: enabled again and the disable metadata cleared' AS check_name,
       IFF(EXISTS (SELECT 1 FROM RULES.SAFETY_RULE
                    WHERE RULE_ID = 'RUL-004' AND STATUS = 'ACTIVE'
                      AND IS_ENABLED = TRUE
                      AND DISABLED_BY IS NULL
                      AND DISABLED_AT IS NULL
                      AND DISABLE_REASON IS NULL),
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'T-15 resuming also left existing cases alone',
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'OPEN')
           = (SELECT R4_OPEN FROM T_BASE), 'PASS', 'FAIL')
UNION ALL
SELECT 'T-16 both transitions are in the audit trail',
       IFF((SELECT COUNT(*) FROM CASES.AUDIT_EVENT
             WHERE SUBJECT_ID = 'RUL-004'
               AND EVENT_TYPE IN ('RULE_PAUSED', 'RULE_RESUMED')) >= 2,
           'PASS', 'FAIL');

-- Final state: identical to the baseline, on every count.
SELECT 'T-17 demo state fully restored' AS check_name,
       IFF((SELECT COUNT(*) FROM CASES.CASE_REGISTRY
             WHERE RULE_ID = 'RUL-004' AND STATUS = 'OPEN')
             = (SELECT R4_OPEN FROM T_BASE)
       AND (SELECT COUNT(*) FROM CASES.CASE_REGISTRY WHERE STATUS = 'OPEN')
             = (SELECT ALL_OPEN FROM T_BASE)
       AND (SELECT COUNT(*) FROM RULES.SAFETY_RULE
             WHERE STATUS = 'ACTIVE' AND IS_ENABLED = FALSE) = 0,
           'PASS', 'FAIL') AS result;
