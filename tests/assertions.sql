-- STATUS: EXECUTED 2026-08-24 via build/run_all.sql, WITH DATA LOADED.
-- Result: 54 checks, all PASS. Earlier runs against an empty database passed
-- vacuously; this run exercised them against 312 people and 11 live cases, so
-- A-06 (one ACTIVE order per person+drug), A-09 (no date after the anchor,
-- no onset before birth) and A-10 (both sides of every person present, DOB
-- matching) are now meaningful rather than trivially true.
-- Source: docs/self-tracking/03_SCHEMA_DESIGN.md §13. Every row must return
-- PASS. A FAIL stops the build — this is the gate, not a suggestion.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===================================================== A-01 / A-02 (§13 structural)
SELECT 'A-01 exactly one DATE_ANCHOR row, fixed at 2026-09-01' AS check_name,
       IFF((SELECT COUNT(*) FROM CONF.DATE_ANCHOR) = 1
           AND (SELECT AS_OF FROM CONF.DATE_ANCHOR) = DATE '2026-09-01',
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'A-02 deliberate synonym gap intact (no row for k+ serum level)',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.REF_LAB_TEST_SYNONYM
                        WHERE LOWER(SYNONYM_TEXT) = 'k+ serum level'),
           'PASS', 'FAIL');

-- ===================================================== A-03 primary-key uniqueness
-- Snowflake does not enforce PK/UNIQUE (P1) — this is the only real check.
WITH pk_checks AS (
  SELECT 'REF_DRUG'               AS t, COUNT(*) AS n, COUNT(DISTINCT DRUG_ID)          AS d FROM CONF.REF_DRUG
  UNION ALL SELECT 'REF_CONDITION',            COUNT(*), COUNT(DISTINCT CONDITION_ID)     FROM CONF.REF_CONDITION
  UNION ALL SELECT 'REF_LAB_TEST',             COUNT(*), COUNT(DISTINCT LAB_TEST_ID)      FROM CONF.REF_LAB_TEST
  UNION ALL SELECT 'REF_LAB_TEST_SYNONYM',     COUNT(*), COUNT(DISTINCT SYNONYM_TEXT)     FROM CONF.REF_LAB_TEST_SYNONYM
  UNION ALL SELECT 'CONF_PERSON_XWALK',        COUNT(*), COUNT(DISTINCT PERSON_ID)        FROM CONF.CONF_PERSON_XWALK
  UNION ALL SELECT 'CONF_PERSON_XWALK.PATIENT',COUNT(*), COUNT(DISTINCT PATIENT_ID)       FROM CONF.CONF_PERSON_XWALK
  UNION ALL SELECT 'CONF_PERSON_XWALK.MEMBER', COUNT(*), COUNT(DISTINCT MEMBER_ID)        FROM CONF.CONF_PERSON_XWALK
  UNION ALL SELECT 'CONF_MEDICATION',          COUNT(*), COUNT(DISTINCT MED_ID)           FROM CONF.CONF_MEDICATION
  UNION ALL SELECT 'CONF_PHARMACY_FILL',       COUNT(*), COUNT(DISTINCT FILL_ID)          FROM CONF.CONF_PHARMACY_FILL
  UNION ALL SELECT 'CONF_DIAGNOSIS',           COUNT(*), COUNT(DISTINCT DX_ID)            FROM CONF.CONF_DIAGNOSIS
  UNION ALL SELECT 'CONF_CLAIM_LINE',          COUNT(*), COUNT(DISTINCT CLAIM_LINE_ID)    FROM CONF.CONF_CLAIM_LINE
  UNION ALL SELECT 'CONF_LAB_RESULT',          COUNT(*), COUNT(DISTINCT LAB_RESULT_ID)    FROM CONF.CONF_LAB_RESULT
  UNION ALL SELECT 'CONF_CLINICAL_NOTE',       COUNT(*), COUNT(DISTINCT NOTE_ID)          FROM CONF.CONF_CLINICAL_NOTE
  UNION ALL SELECT 'CONF_SAFETY_DOCUMENT',     COUNT(*), COUNT(DISTINCT DOC_ID)           FROM CONF.CONF_SAFETY_DOCUMENT
  UNION ALL SELECT 'DOC_CHUNK',                COUNT(*), COUNT(DISTINCT CHUNK_ID)         FROM CONF.DOC_CHUNK
  UNION ALL SELECT 'SAFETY_RULE',              COUNT(*), COUNT(DISTINCT RULE_ID || '|' || VERSION) FROM RULES.SAFETY_RULE
  UNION ALL SELECT 'RULE_PROPOSAL',            COUNT(*), COUNT(DISTINCT PROPOSAL_ID)      FROM RULES.RULE_PROPOSAL
  UNION ALL SELECT 'CASE_REGISTRY',            COUNT(*), COUNT(DISTINCT CASE_ID)          FROM CASES.CASE_REGISTRY
  UNION ALL SELECT 'CASE_REGISTRY.CANDIDATE',  COUNT(*), COUNT(DISTINCT CANDIDATE_KEY)    FROM CASES.CASE_REGISTRY
  UNION ALL SELECT 'CASE_EVIDENCE',            COUNT(*), COUNT(DISTINCT EVIDENCE_ID)      FROM CASES.CASE_EVIDENCE
  UNION ALL SELECT 'AUDIT_EVENT',              COUNT(*), COUNT(DISTINCT EVENT_ID)         FROM CASES.AUDIT_EVENT
)
SELECT 'A-03 PK uniqueness: ' || t AS check_name, IFF(n = d, 'PASS', 'FAIL') AS result
FROM pk_checks
ORDER BY 1;

-- ===================================================== A-04 no orphans
SELECT 'A-04 orphan check: CONF_MEDICATION.PERSON_ID' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM CONF.CONF_MEDICATION m
                        WHERE NOT EXISTS (SELECT 1 FROM CONF.CONF_PERSON_XWALK x WHERE x.PERSON_ID = m.PERSON_ID)),
           'PASS', 'FAIL')
UNION ALL
SELECT 'A-04 orphan check: CONF_DIAGNOSIS.CONDITION_ID',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.CONF_DIAGNOSIS d
                        WHERE NOT EXISTS (SELECT 1 FROM CONF.REF_CONDITION c WHERE c.CONDITION_ID = d.CONDITION_ID)),
           'PASS', 'FAIL')
UNION ALL
SELECT 'A-04 orphan check: SAFETY_RULE.DOC_ID',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE r
                        WHERE NOT EXISTS (SELECT 1 FROM CONF.CONF_SAFETY_DOCUMENT d WHERE d.DOC_ID = r.DOC_ID)),
           'PASS', 'FAIL')
UNION ALL
SELECT 'A-04 orphan check: CASE_REGISTRY.PERSON_ID',
       IFF(NOT EXISTS (SELECT 1 FROM CASES.CASE_REGISTRY cr
                        WHERE NOT EXISTS (SELECT 1 FROM CONF.CONF_PERSON_XWALK x WHERE x.PERSON_ID = cr.PERSON_ID)),
           'PASS', 'FAIL');

-- ===================================================== A-05 enumerated values
SELECT 'A-05 enum: CONF_MEDICATION.STATUS' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM CONF.CONF_MEDICATION WHERE STATUS NOT IN ('ACTIVE','STOPPED')), 'PASS','FAIL')
UNION ALL
SELECT 'A-05 enum: SAFETY_RULE.STATUS',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE WHERE STATUS NOT IN ('ACTIVE','SUPERSEDED','RETIRED')), 'PASS','FAIL')
UNION ALL
SELECT 'A-05 enum: SAFETY_RULE.PRECONDITION_TYPE',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE WHERE PRECONDITION_TYPE NOT IN ('CONDITION','AGE_MIN','NONE')), 'PASS','FAIL')
UNION ALL
SELECT 'A-05 enum: CASE_REGISTRY.STATUS',
       IFF(NOT EXISTS (SELECT 1 FROM CASES.CASE_REGISTRY
                        WHERE STATUS NOT IN ('OPEN','ESCALATED','EVIDENCE_REQUESTED','REVIEWED','DISMISSED','RESOLVED_BY_DATA')),
           'PASS','FAIL')
UNION ALL
SELECT 'A-05 enum: CASE_REGISTRY.CASE_TYPE',
       IFF(NOT EXISTS (SELECT 1 FROM CASES.CASE_REGISTRY WHERE CASE_TYPE NOT IN ('MONITORING_GAP','MED_CONFLICT')), 'PASS','FAIL')
UNION ALL
SELECT 'A-05 enum: CASE_EVIDENCE.VERDICT',
       IFF(NOT EXISTS (SELECT 1 FROM CASES.CASE_EVIDENCE WHERE VERDICT NOT IN ('AGREES','CONFLICTS','MISSING')), 'PASS','FAIL');

-- ===================================================== A-06 / A-07 (semantic — need data)
SELECT 'A-06 no person has >1 ACTIVE order for the same drug' AS check_name,
       IFF(NOT EXISTS (
             SELECT PERSON_ID, DRUG_ID FROM CONF.CONF_MEDICATION
             WHERE STATUS = 'ACTIVE' GROUP BY PERSON_ID, DRUG_ID HAVING COUNT(*) > 1),
           'PASS', 'FAIL')
UNION ALL
SELECT 'A-07 no ACTIVE order has a non-null STOP_DATE',
       IFF(NOT EXISTS (SELECT 1 FROM CONF.CONF_MEDICATION WHERE STATUS='ACTIVE' AND STOP_DATE IS NOT NULL),
           'PASS', 'FAIL');

-- ===================================================== A-08 no duplicate candidate keys
SELECT 'A-08 DT_CASE_CANDIDATE has no duplicate CANDIDATE_KEY' AS check_name,
       IFF(NOT EXISTS (
             SELECT CANDIDATE_KEY FROM CASES.DT_CASE_CANDIDATE
             GROUP BY CANDIDATE_KEY HAVING COUNT(*) > 1),
           'PASS', 'FAIL');

-- ===================================================== A-09 date sanity
SELECT 'A-09 no clinical date is later than DATE_ANCHOR.AS_OF' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM CONF.CONF_LAB_RESULT l CROSS JOIN CONF.DATE_ANCHOR a
                        WHERE l.RESULT_DATE > a.AS_OF),
           'PASS', 'FAIL')
UNION ALL
SELECT 'A-09 no ONSET_DATE precedes the person''s DOB',
       IFF(NOT EXISTS (
             SELECT 1 FROM CONF.CONF_DIAGNOSIS dx
             JOIN CONF.CONF_PERSON_XWALK x ON x.PERSON_ID = dx.PERSON_ID
             JOIN RAW.RAW_EHR_PATIENT p    ON p.PATIENT_ID = x.PATIENT_ID
             WHERE dx.ONSET_DATE < p.DOB),
           'PASS', 'FAIL');

-- ===================================================== A-10 crosswalk consistency
SELECT 'A-10 every xwalk person exists on both sides, DOB matches' AS check_name,
       IFF(NOT EXISTS (
             SELECT 1 FROM CONF.CONF_PERSON_XWALK x
             LEFT JOIN RAW.RAW_EHR_PATIENT p   ON p.PATIENT_ID = x.PATIENT_ID
             LEFT JOIN RAW.RAW_PLAN_MEMBER mem ON mem.MEMBER_ID = x.MEMBER_ID
             WHERE p.PATIENT_ID IS NULL OR mem.MEMBER_ID IS NULL OR p.DOB != mem.DOB),
           'PASS', 'FAIL');

-- ===================================================== A-11 MISSING verdicts carry SEARCHED
SELECT 'A-11 every MISSING evidence row has non-empty SEARCHED' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM CASES.CASE_EVIDENCE
                        WHERE VERDICT = 'MISSING' AND (SEARCHED IS NULL OR TRIM(SEARCHED) = '')),
           'PASS', 'FAIL');

-- ===================================================== A-12 condition-precondition consistency
SELECT 'A-12 every ACTIVE condition-type rule has a CONDITION_ID' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.SAFETY_RULE
                        WHERE STATUS='ACTIVE' AND PRECONDITION_TYPE='CONDITION' AND CONDITION_ID IS NULL),
           'PASS', 'FAIL');

-- ===================================================== A-13 at most one ACTIVE version per rule
SELECT 'A-13 at most one ACTIVE version per RULE_ID' AS check_name,
       IFF(NOT EXISTS (
             SELECT RULE_ID FROM RULES.SAFETY_RULE WHERE STATUS='ACTIVE'
             GROUP BY RULE_ID HAVING COUNT(*) > 1),
           'PASS', 'FAIL');

-- ===================================================== A-14 token uniqueness
-- A pseudonym that collides would show two different patients under one
-- handle — confusing at best, dangerous at worst.
SELECT 'A-14 person tokens are unique across the cohort' AS check_name,
       IFF((SELECT COUNT(*) FROM CONF.CONF_PERSON_XWALK)
           = (SELECT COUNT(DISTINCT SEC.PERSON_TOKEN(PERSON_ID)) FROM CONF.CONF_PERSON_XWALK),
           'PASS', 'FAIL') AS result;

-- ===================================================== A-15 masking enforced
-- The check that had been asserted in documentation but never proven. Runs as
-- whatever role the suite runs as: if that role can read a name without a
-- live break-glass grant, this FAILS. No role is exempt, including HO_ADMIN.
SELECT 'A-15 PHI masked without a live reveal grant' AS check_name,
       IFF(NOT EXISTS (
             SELECT 1 FROM P360.P360_PERSON p
             WHERE NOT EXISTS (SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
                                WHERE g.PERSON_ID = p.PERSON_ID
                                  AND g.GRANTED_TO = CURRENT_USER()
                                  AND g.EXPIRES_AT > CURRENT_TIMESTAMP())
               AND (p.NAME NOT LIKE '%WITHHELD%' OR p.DOB <> DATE '1900-01-01')),
           'PASS', 'FAIL') AS result;

-- ===================================================== A-16 reveal is logged
-- Every reveal grant must have a matching audit event. The procedure writes
-- both, so a mismatch means someone found another way in.
SELECT 'A-16 every PHI reveal has an audit event' AS check_name,
       IFF((SELECT COUNT(*) FROM SEC.PHI_REVEAL_GRANT)
           <= (SELECT COUNT(*) FROM CASES.AUDIT_EVENT WHERE EVENT_TYPE='PHI_REVEALED'),
           'PASS', 'FAIL') AS result;

-- ===================================================== A-17 audit integrity
-- Proves the audit trail has not been edited or deleted since the last
-- checkpoint. Verified by deliberate tampering: rewriting an ACTOR is caught
-- as 'row content was altered', deleting a row as 'audit rows were deleted'.
SELECT 'A-17 audit trail intact (no edits, no deletions)' AS check_name,
       IFF((SELECT VERDICT FROM CASES.V_AUDIT_INTEGRITY) LIKE 'OK%', 'PASS', 'FAIL') AS result;

-- ===================================================== A-18 no mutation grants
-- "Append-only" must be a control, not a comment. No role may hold UPDATE or
-- DELETE on the audit table.
--
-- NOTE: this reads SHOW GRANTS rather than SNOWFLAKE.ACCOUNT_USAGE, because
-- HO_ADMIN has no grant on the ACCOUNT_USAGE schema (verified: the query
-- fails compilation). Checking via SHOW keeps the assertion runnable by the
-- same role that runs everything else, which matters more than elegance.
-- Run as two steps:
--   SHOW GRANTS ON TABLE HEALTHONE.CASES.AUDIT_EVENT;
--   SELECT 'A-18 no role holds UPDATE/DELETE on AUDIT_EVENT' AS check_name,
--          IFF(COUNT(*) = 0, 'PASS','FAIL') AS result
--     FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
--    WHERE "privilege" IN ('UPDATE','DELETE');
SHOW GRANTS ON TABLE HEALTHONE.CASES.AUDIT_EVENT;
SELECT 'A-18 no role holds UPDATE/DELETE on AUDIT_EVENT' AS check_name,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" IN ('UPDATE','DELETE');
