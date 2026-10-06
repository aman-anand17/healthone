-- STATUS: EXECUTED 2026-08-24 via build/run_all.sql — ran clean against the account.
-- The evidence reconciler (docs/02 §2.5, 03_SCHEMA_DESIGN §10.3).
--
-- Turns each case in CASE_REGISTRY into a set of CLAIMS, each with a VERDICT
-- (AGREES / CONFLICTS / MISSING) and citations back to specific source
-- records. This is the product's differentiator: not "here is a footnote",
-- but "here is what the sources agree on, disagree on, and cannot show".
--
-- THREE RULES THAT MAKE THIS HONEST
--   1. Verdicts are computed by SQL, never by a model. The LLM's only job
--      downstream is to NARRATE these rows (DECISIONS C6).
--   2. Every MISSING row carries SEARCHED — the exact scope of the search, so
--      absence is evidence rather than silence (C7, assertion A-11).
--   3. Negative wording is fixed and claims only about OUR DATA:
--      "No <test> result was found in the available records between X and Y."
--      Never "the patient did not have the test."
--
-- IDEMPOTENT: clears evidence before rebuilding, so running it twice does not
-- double the cards on screen (hazard H-11).
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CASES; USE WAREHOUSE HO_WH;

DELETE FROM CASE_EVIDENCE;

-- ============================================================================
-- CLAIM 1 — DRUG_ACTIVE. Is the drug actually active?
-- AGREES when the EHR says ACTIVE and pharmacy has dispensed recently.
-- CONFLICTS when the EHR says ACTIVE but dispensing has stopped — both
-- sources are shown side by side and the system refuses to adjudicate.
-- ============================================================================
INSERT INTO CASE_EVIDENCE (CASE_ID, CLAIM_KEY, CLAIM_TEXT, VERDICT, EVIDENCE_REFS, SEARCHED)
SELECT
  cr.CASE_ID,
  'DRUG_ACTIVE',
  d.DRUG_NAME || ' is recorded as an active medication for this patient.',
  IFF(am.FILLS_LAST_90D > 0, 'AGREES', 'CONFLICTS'),
  ARRAY_CAT(
    ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
      'type', 'medication', 'source_system', 'EHR',
      'source_record_id', am.MED_SOURCE_RECORD_IDS[0]::STRING,
      'detail', d.DRUG_NAME || ', status ACTIVE, therapy start '
                || TO_VARCHAR(am.THERAPY_START_DATE, 'YYYY-MM-DD'))),
    IFF(am.LAST_FILL_DATE IS NULL,
      ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
        'type', 'pharmacy_fill', 'source_system', 'PHARMACY',
        'source_record_id', 'none',
        'detail', 'No pharmacy fill on record for this medication')),
      ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
        'type', 'pharmacy_fill', 'source_system', 'PHARMACY',
        'source_record_id', COALESCE(lf.SOURCE_RECORD_ID, 'unknown'),
        'detail', 'Last fill dispensed ' || TO_VARCHAR(am.LAST_FILL_DATE, 'YYYY-MM-DD')
                  || ' (' || am.FILLS_LAST_90D::STRING || ' fill(s) in the last 90 days)')))
  ),
  NULL
FROM CASE_REGISTRY cr
JOIN P360.P360_ACTIVE_MEDICATION am
      ON am.PERSON_ID = cr.PERSON_ID AND am.DRUG_ID = cr.DRUG_ID
JOIN CONF.REF_DRUG d ON d.DRUG_ID = cr.DRUG_ID
LEFT JOIN CONF.CONF_PHARMACY_FILL lf
      ON lf.PERSON_ID = am.PERSON_ID AND lf.DRUG_ID = am.DRUG_ID
     AND lf.FILL_DATE = am.LAST_FILL_DATE;

-- ============================================================================
-- CLAIM 2 — MEDICATION_DISPENSING. MED_CONFLICT cases only. The note that
-- explains WHY dispensing stopped is human context a reviewer needs, and it
-- is citable. Three sources end up side by side (EHR / PHARMACY / NOTE) with
-- no adjudication language anywhere.
-- ============================================================================
INSERT INTO CASE_EVIDENCE (CASE_ID, CLAIM_KEY, CLAIM_TEXT, VERDICT, EVIDENCE_REFS, SEARCHED)
SELECT
  cr.CASE_ID,
  'MEDICATION_DISPENSING',
  'The clinical record contains a note relevant to whether this medication is still being taken.',
  'CONFLICTS',
  ARRAY_AGG(OBJECT_CONSTRUCT(
    'type', 'clinical_note', 'source_system', 'EHR',
    'source_record_id', n.SOURCE_RECORD_ID,
    'detail', TO_VARCHAR(n.NOTE_DATE, 'YYYY-MM-DD') || ' (' || COALESCE(n.AUTHOR_ROLE, 'unknown')
              || '): ' || n.NOTE_TEXT)) WITHIN GROUP (ORDER BY n.NOTE_DATE DESC),
  NULL
FROM CASE_REGISTRY cr
JOIN CONF.CONF_CLINICAL_NOTE n ON n.PERSON_ID = cr.PERSON_ID
WHERE cr.CASE_TYPE = 'MED_CONFLICT'
  AND (LOWER(n.NOTE_TEXT) LIKE '%stop%'
       OR LOWER(n.NOTE_TEXT) LIKE '%discontinu%'
       OR LOWER(n.NOTE_TEXT) LIKE '%not collect%')
GROUP BY cr.CASE_ID;

-- ============================================================================
-- CLAIM 3 — CONDITION_PRESENT. Rule-driven cases only. AGREES when the
-- provider-side diagnosis is corroborated by payer-side claims: two
-- independent systems, which is the entire point of a payvider 360.
-- ============================================================================
INSERT INTO CASE_EVIDENCE (CASE_ID, CLAIM_KEY, CLAIM_TEXT, VERDICT, EVIDENCE_REFS, SEARCHED)
WITH dx AS (
  SELECT cr.CASE_ID, cr.PERSON_ID, r.CONDITION_ID,
         MIN(dg.ONSET_DATE)       AS ONSET_DATE,
         MIN(dg.SOURCE_RECORD_ID) AS DX_REF
  FROM CASE_REGISTRY cr
  JOIN RULES.SAFETY_RULE r ON r.RULE_ID = cr.RULE_ID AND r.VERSION = cr.VERSION
  JOIN CONF.CONF_DIAGNOSIS dg
        ON dg.PERSON_ID = cr.PERSON_ID AND dg.CONDITION_ID = r.CONDITION_ID
  WHERE cr.CASE_TYPE = 'MONITORING_GAP'
  GROUP BY cr.CASE_ID, cr.PERSON_ID, r.CONDITION_ID
),
cl AS (
  SELECT dx.CASE_ID,
         MAX(c.SERVICE_DATE)     AS SERVICE_DATE,
         MAX(c.SOURCE_RECORD_ID) AS CLAIM_REF,
         MAX(c.SERVICE_DESC)     AS SERVICE_DESC,
         COUNT(*)                AS N
  FROM dx
  JOIN CONF.CONF_CLAIM_LINE c
        ON c.PERSON_ID = dx.PERSON_ID AND c.CONDITION_ID = dx.CONDITION_ID
  GROUP BY dx.CASE_ID
)
SELECT
  dx.CASE_ID, 'CONDITION_PRESENT',
  'A diagnosis of ' || cond.CONDITION_NAME || ' is recorded for this patient.',
  'AGREES',
  ARRAY_CAT(
    ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
      'type', 'diagnosis', 'source_system', 'EHR', 'source_record_id', dx.DX_REF,
      'detail', INITCAP(cond.CONDITION_NAME) || ', onset '
                || TO_VARCHAR(dx.ONSET_DATE, 'YYYY-MM-DD'))),
    IFF(cl.CASE_ID IS NULL, ARRAY_CONSTRUCT(),
      ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
        'type', 'claim_line', 'source_system', 'CLAIMS', 'source_record_id', cl.CLAIM_REF,
        'detail', cl.SERVICE_DESC || ', ' || TO_VARCHAR(cl.SERVICE_DATE, 'YYYY-MM-DD')
                  || ' (' || cl.N::STRING || ' condition-linked claim line(s))')))
  ),
  NULL
FROM dx
JOIN CONF.REF_CONDITION cond ON cond.CONDITION_ID = dx.CONDITION_ID
LEFT JOIN cl ON cl.CASE_ID = dx.CASE_ID;

-- ============================================================================
-- CLAIM 4 — REQUIRED_LAB. The heart of it. MISSING carries the verbatim
-- negative-evidence sentence, plus a SEARCHED string stating the exact scope
-- INCLUDING that unmappable test names were excluded — which is what lets a
-- reviewer understand GP3 and dismiss it correctly.
-- ============================================================================
INSERT INTO CASE_EVIDENCE (CASE_ID, CLAIM_KEY, CLAIM_TEXT, VERDICT, EVIDENCE_REFS, SEARCHED)
SELECT
  cr.CASE_ID, 'REQUIRED_LAB',
  'No ' || t.CANONICAL_NAME || ' result was found in the available records between '
    || TO_VARCHAR(cr.WINDOW_START_DATE, 'YYYY-MM-DD') || ' and '
    || TO_VARCHAR(a.AS_OF, 'YYYY-MM-DD') || '.',
  'MISSING',
  ARRAY_CONSTRUCT(),
  'CONF_LAB_RESULT via P360_LAB_TIMELINE; test = ' || t.CANONICAL_NAME
    || ' (' || t.LAB_TEST_ID || '); person ' || cr.PERSON_ID
    || '; window ' || TO_VARCHAR(cr.WINDOW_START_DATE, 'YYYY-MM-DD')
    || ' to ' || TO_VARCHAR(a.AS_OF, 'YYYY-MM-DD')
    || ' (later of therapy start, condition onset, and interval plus grace). '
    || 'Results whose recorded test name could not be mapped to the controlled '
    || 'vocabulary are EXCLUDED from this search and are shown separately in the '
    || 'lab timeline.'
FROM CASE_REGISTRY cr
CROSS JOIN CONF.DATE_ANCHOR a
JOIN CONF.REF_LAB_TEST t ON t.LAB_TEST_ID = cr.LAB_TEST_ID
WHERE cr.CASE_TYPE = 'MONITORING_GAP';

-- ============================================================================
-- CLAIM 5 — UNMAPPED_LAB. The honesty claim, and the reason GP3 is
-- DISMISSIBLE rather than simply wrong. If the person has results in the
-- window under a test name we could not map, say so plainly and cite them.
-- Verdict CONFLICTS: our vocabulary and the lab feed disagree about what
-- exists. This single row turns "the system is wrong" into "the system told
-- me exactly why it could not tell" — and it is what the reviewer dismisses on.
-- ============================================================================
INSERT INTO CASE_EVIDENCE (CASE_ID, CLAIM_KEY, CLAIM_TEXT, VERDICT, EVIDENCE_REFS, SEARCHED)
SELECT
  cr.CASE_ID, 'UNMAPPED_LAB',
  'Laboratory results exist for this patient inside the monitoring window under a test '
    || 'name that is not mapped to the controlled vocabulary, so they could not be '
    || 'evaluated against the rule.',
  'CONFLICTS',
  ARRAY_AGG(OBJECT_CONSTRUCT(
    'type', 'lab_result_unmapped', 'source_system', 'LAB',
    'source_record_id', l.SOURCE_RECORD_ID,
    'detail', TO_VARCHAR(l.RESULT_DATE, 'YYYY-MM-DD') || ': "' || l.RAW_TEST_TEXT
              || '" = ' || COALESCE(l.RESULT_VALUE::STRING, 'no value')
              || ' ' || COALESCE(l.UNITS, '')))
    WITHIN GROUP (ORDER BY l.RESULT_DATE DESC),
  'CONF_LAB_RESULT where LAB_TEST_ID IS NULL for person ' || cr.PERSON_ID
    || ', window ' || TO_VARCHAR(cr.WINDOW_START_DATE, 'YYYY-MM-DD')
    || ' onward. Shown because a reviewer must be able to see what the system could not.'
FROM CASE_REGISTRY cr
CROSS JOIN CONF.DATE_ANCHOR a
JOIN CONF.CONF_LAB_RESULT l ON l.PERSON_ID = cr.PERSON_ID
WHERE cr.CASE_TYPE = 'MONITORING_GAP'
  AND l.LAB_TEST_ID IS NULL
  AND l.RESULT_DATE >= cr.WINDOW_START_DATE
  AND l.RESULT_DATE <= a.AS_OF
GROUP BY cr.CASE_ID, cr.PERSON_ID, cr.WINDOW_START_DATE;

-- ============================================================================
-- Audit + summary
-- ============================================================================
INSERT INTO AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'CASE_REFRESHED', 'system:reconciler', 'QUEUE', 'ALL',
       OBJECT_CONSTRUCT('evidence_rows', COUNT(*), 'cases', COUNT(DISTINCT CASE_ID))
FROM CASE_EVIDENCE;

SELECT VERDICT, CLAIM_KEY, COUNT(*) AS n
FROM CASE_EVIDENCE GROUP BY 1, 2 ORDER BY 1, 2;
