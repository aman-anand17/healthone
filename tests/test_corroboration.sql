-- STATUS: DRAFT -- never executed.
-- ===========================================================================
-- ACCEPTANCE TEST: proposal corroboration must be able to FAIL.
--
-- Every one of the five real proposals comes back FULLY CORROBORATED, 4/4. That
-- is the correct answer and it is also exactly why this file has to exist: a
-- check that has never failed is not a check, it is decoration, and a reviewer
-- who sees "FULLY CORROBORATED" on every card learns to ignore the label.
--
-- So this injects deliberately broken proposals -- one per failure mode -- and
-- asserts the view catches each one and says which fact is wrong. The four
-- interesting ones:
--
--   C-03  a PARAPHRASED phrase. The model reports words that are not in the
--         document. This is the hallucination case that matters most, because
--         the phrase is what gets quoted back to the clinician as the
--         justification for the rule.
--   C-04  a CONTRADICTED interval. The phrase says "12-week intervals" and the
--         proposal says 90 days. Six days of silent drift in a monitoring
--         interval is a patient-safety change nobody authorised, and DECISIONS
--         C6 exists because of it.
--   C-05  a FABRICATED citation. The cited section does not exist.
--   C-07  cross-engine DISAGREEMENT is reported as such, not as a pass.
--
-- Self-cleaning: every injected row is removed at the end.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID LIKE 'PRP-CORR-%';

-- ===========================================================================
-- The real proposals: the checks agree with the documents.
-- ===========================================================================
SELECT 'C-01 every real proposal is FULLY CORROBORATED, 4 of 4 strong checks' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_CORROBORATION
                        WHERE CORROBORATION <> 'FULLY CORROBORATED'),
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'C-02 and each interval re-derives from its own quoted phrase',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_CORROBORATION
                        WHERE NOT CHK_INTERVAL_REDERIVED),
           'PASS', 'FAIL');

-- ===========================================================================
-- Inject one broken proposal per failure mode.
-- ===========================================================================
INSERT INTO RULES.RULE_PROPOSAL
  (PROPOSAL_ID, DOC_ID, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
   DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
   INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
   NEEDS_REVIEW, STATUS)
-- PARAPHRASED: plausible wording that is nowhere in SAFETY_DOC_007.
SELECT 'PRP-CORR-PARAPHRASE', 'SAFETY_DOC_007', 'claude-sonnet-5', 'v1', CURRENT_TIMESTAMP(),
       'CardioZen', 'condition', 'chronic kidney disease', 'serum potassium',
       90, 'potassium should be monitored on a quarterly basis thereafter',
       DATE '2026-03-01', 'section 3', FALSE, 'PROPOSED'
UNION ALL
-- CONTRADICTED: the phrase IS verbatim, but the number does not follow from it.
-- 12 weeks is 84 days; this claims 90.
SELECT 'PRP-CORR-BADMATH', 'SAFETY_DOC_006', 'claude-sonnet-5', 'v1', CURRENT_TIMESTAMP(),
       'Hepatrol', 'condition', 'chronic liver disease', 'ALT',
       90, 'ALT measured at 12-week intervals',
       DATE '2026-01-20', 'section 2', FALSE, 'PROPOSED'
UNION ALL
-- FABRICATED CITATION: SAFETY_DOC_007 has no section 9.
SELECT 'PRP-CORR-NOSECTION', 'SAFETY_DOC_007', 'claude-sonnet-5', 'v1', CURRENT_TIMESTAMP(),
       'CardioZen', 'condition', 'chronic kidney disease', 'serum potassium',
       90, 'checked at least every three months for the duration of therapy',
       DATE '2026-03-01', 'section 9', FALSE, 'PROPOSED'
UNION ALL
-- SELF-FLAGGED: verbatim and arithmetically sound, but the extractor was unsure.
SELECT 'PRP-CORR-FLAGGED', 'SAFETY_DOC_005', 'claude-sonnet-5', 'v1', CURRENT_TIMESTAMP(),
       'Renuvex', 'condition', 'chronic kidney disease', 'serum creatinine',
       90, 'serum creatinine measured quarterly while treatment continues',
       DATE '2026-02-14', 'section 3', TRUE, 'PROPOSED';

-- ===========================================================================
-- Each failure mode is caught, and named.
-- ===========================================================================
SELECT 'C-03 a PARAPHRASED phrase is caught: not verbatim, UNCORROBORATED' AS check_name,
       IFF((SELECT CORROBORATION FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE') = 'UNCORROBORATED'
       AND (SELECT NOT CHK_PHRASE_VERBATIM FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE'),
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'C-04 a CONTRADICTED interval is caught: 12 weeks re-derives to 84, not 90',
       IFF((SELECT CORROBORATION FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-BADMATH') = 'CONTRADICTED'
       AND (SELECT REDERIVED_DAYS FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-BADMATH') = 84,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-05 a FABRICATED citation is caught: no such section',
       IFF((SELECT CORROBORATION FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-NOSECTION') = 'UNCORROBORATED'
       AND (SELECT NOT CHK_SECTION_EXISTS FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-NOSECTION'),
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-06 a SELF-FLAGGED proposal does not reach FULLY CORROBORATED',
       IFF((SELECT CORROBORATION FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-FLAGGED') = 'PARTIALLY CORROBORATED',
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-07 cross-engine DISAGREEMENT is reported, not counted as a pass',
       IFF((SELECT NOT CHK_CROSS_ENGINE_AGREE FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-BADMATH'),
           'PASS', 'FAIL');

-- ===========================================================================
-- The FACTORS array is what a reviewer actually reads. It has to NAME the
-- problem, not merely score it down.
-- ===========================================================================
SELECT 'C-08 the paraphrase warning names the problem in words' AS check_name,
       IFF(ARRAY_TO_STRING((SELECT FACTORS FROM RULES.V_PROPOSAL_CORROBORATION
                             WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE'), ' | ')
           ILIKE '%NOT found in the cited section%', 'PASS', 'FAIL') AS result
UNION ALL
SELECT 'C-09 the contradiction warning states both numbers',
       IFF(ARRAY_TO_STRING((SELECT FACTORS FROM RULES.V_PROPOSAL_CORROBORATION
                             WHERE PROPOSAL_ID = 'PRP-CORR-BADMATH'), ' | ')
           ILIKE '%re-derives to 84%90%', 'PASS', 'FAIL')
UNION ALL
SELECT 'C-10 the self-flag warning repeats the extractor''s own reason',
       IFF(ARRAY_TO_STRING((SELECT FACTORS FROM RULES.V_PROPOSAL_CORROBORATION
                             WHERE PROPOSAL_ID = 'PRP-CORR-FLAGGED'), ' | ')
           ILIKE '%extractor flagged this itself%', 'PASS', 'FAIL');

-- ===========================================================================
-- INTERVAL_FROM_PHRASE on its own. Literal arithmetic, per DECISIONS C6.
-- ===========================================================================
SELECT 'C-11 12-week intervals -> 84, never 90' AS check_name,
       IFF(RULES.INTERVAL_FROM_PHRASE('ALT measured at 12-week intervals') = 84,
           'PASS', 'FAIL') AS result
UNION ALL
SELECT 'C-12 six weeks -> 42, never 45',
       IFF(RULES.INTERVAL_FROM_PHRASE('measured every six weeks for as long as treatment continues') = 42,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-13 quarterly -> 90',
       IFF(RULES.INTERVAL_FROM_PHRASE('serum creatinine measured quarterly') = 90,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-14 every three months -> 90',
       IFF(RULES.INTERVAL_FROM_PHRASE('checked at least every three months') = 90,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-15 every 60 days -> 60',
       IFF(RULES.INTERVAL_FROM_PHRASE('must be checked every 60 days') = 60,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-16 unrecognised wording returns NULL rather than guessing',
       IFF(RULES.INTERVAL_FROM_PHRASE('as clinically indicated') IS NULL,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-17 empty input returns NULL',
       IFF(RULES.INTERVAL_FROM_PHRASE('') IS NULL AND RULES.INTERVAL_FROM_PHRASE(NULL) IS NULL,
           'PASS', 'FAIL');

-- ===========================================================================
-- The numeric score. It must MOVE with the checks, or it is decoration with a
-- percent sign on it.
-- ===========================================================================
SELECT 'C-19 every real proposal scores 100% of applicable document checks' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_CORROBORATION
                        WHERE PROPOSAL_ID NOT LIKE 'PRP-CORR-%'
                          AND CORROBORATION_SCORE <> 100),
           'PASS', 'FAIL') AS result
UNION ALL
-- The first version of this asserted < 80 and FAILED at 85, which was the
-- SCORE being wrong rather than the expectation: with flat weights, losing the
-- one check that detects a fabricated quote cost only 15 points. The gate
-- checks now carry 10 apiece, so the number moves with the verdict.
SELECT 'C-20 a paraphrased phrase scores materially lower AND its band disqualifies it',
       IFF((SELECT CORROBORATION_SCORE FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE') < 80
       AND (SELECT CORROBORATION FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE') = 'UNCORROBORATED',
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-21 a fabricated citation scores lower still - it fails several checks at once',
       IFF((SELECT CORROBORATION_SCORE FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE PROPOSAL_ID = 'PRP-CORR-NOSECTION')
           < (SELECT CORROBORATION_SCORE FROM RULES.V_PROPOSAL_CORROBORATION
               WHERE PROPOSAL_ID = 'PRP-CORR-PARAPHRASE'), 'PASS', 'FAIL')
UNION ALL
SELECT 'C-22 the score is never NULL and never outside 0-100',
       IFF(NOT EXISTS (SELECT 1 FROM RULES.V_PROPOSAL_CORROBORATION
                        WHERE CORROBORATION_SCORE IS NULL
                           OR CORROBORATION_SCORE < 0
                           OR CORROBORATION_SCORE > 100),
           'PASS', 'FAIL');

-- ===========================================================================
-- Clean up. The injected proposals must never reach the demo.
-- ===========================================================================
DELETE FROM RULES.RULE_PROPOSAL WHERE PROPOSAL_ID LIKE 'PRP-CORR-%';

-- ---------------------------------------------------------------------------
-- The checklist. The percentage on the card is only defensible if a reviewer
-- can take it apart, so every check must be listed EVERY time - including the
-- ones that passed quietly, which the narrative FACTORS list deliberately
-- omits. If this ever shrinks, the score becomes an unexplained number.
-- ---------------------------------------------------------------------------
SELECT 'C-24 the checklist itemises all nine checks for every proposal' AS check_name,
       IFF((SELECT MIN(ARRAY_SIZE(CHECKLIST)) FROM RULES.V_PROPOSAL_CORROBORATION) = 9
       AND (SELECT MAX(ARRAY_SIZE(CHECKLIST)) FROM RULES.V_PROPOSAL_CORROBORATION) = 9,
           'PASS', 'FAIL') AS result
UNION ALL
-- Every line must carry a verdict the UI can render, and a weight, or the
-- arithmetic cannot be reproduced by hand from the card.
SELECT 'C-25 every checklist line is marked Y, N or S and carries its weight',
       IFF((SELECT COUNT(*) FROM RULES.V_PROPOSAL_CORROBORATION,
                 LATERAL FLATTEN(input => CHECKLIST) f
             WHERE NOT REGEXP_LIKE(f.value::STRING, '^[YNS] [0-9]{1,2} .+')) = 0,
           'PASS', 'FAIL')
UNION ALL
-- And the ticked weights must actually sum to the percentage shown. This is the
-- check that stops the score and its explanation drifting apart.
SELECT 'C-26 the ticked weights recompute the displayed percentage exactly',
       IFF((SELECT COUNT(*) FROM (
              SELECT c.CORROBORATION_SCORE AS shown,
                     ROUND(100.0 * SUM(IFF(LEFT(f.value::STRING,1)='Y',
                              SPLIT_PART(f.value::STRING,' ',2)::INT, 0))
                         / NULLIF(SUM(IFF(LEFT(f.value::STRING,1)='S', 0,
                              SPLIT_PART(f.value::STRING,' ',2)::INT)), 0), 0)::INT AS recomputed
                FROM RULES.V_PROPOSAL_CORROBORATION c,
                     LATERAL FLATTEN(input => c.CHECKLIST) f
               GROUP BY c.PROPOSAL_ID, c.CORROBORATION_SCORE)
             WHERE shown <> recomputed) = 0, 'PASS', 'FAIL')
UNION ALL
-- ---------------------------------------------------------------------------
-- The counts and the rating step. The app leads with "9 of 9 checks" rather
-- than "100%" because a bare percentage reads as a claim of CERTAINTY, which
-- nothing here is entitled to make. That only holds if the counts agree with
-- the checklist they claim to summarise.
-- ---------------------------------------------------------------------------
SELECT 'C-27 CHECKS_PASSED equals the ticks in the checklist it summarises' AS check_name,
       IFF((SELECT COUNT(*) FROM (
              SELECT c.PROPOSAL_ID, c.CHECKS_PASSED AS shown,
                     SUM(IFF(LEFT(f.value::STRING,1)='Y',1,0)) AS counted
                FROM RULES.V_PROPOSAL_CORROBORATION c,
                     LATERAL FLATTEN(input => c.CHECKLIST) f
               GROUP BY c.PROPOSAL_ID, c.CHECKS_PASSED)
             WHERE shown <> counted) = 0, 'PASS', 'FAIL') AS result
UNION ALL
SELECT 'C-28 CHECKS_APPLICABLE excludes exactly the skipped lines',
       IFF((SELECT COUNT(*) FROM (
              SELECT c.PROPOSAL_ID, c.CHECKS_APPLICABLE AS shown,
                     SUM(IFF(LEFT(f.value::STRING,1)='S',0,1)) AS counted
                FROM RULES.V_PROPOSAL_CORROBORATION c,
                     LATERAL FLATTEN(input => c.CHECKLIST) f
               GROUP BY c.PROPOSAL_ID, c.CHECKS_APPLICABLE)
             WHERE shown <> counted) = 0, 'PASS', 'FAIL')
UNION ALL
-- A rating step that disagrees with its own band would put the ladder marker in
-- one place and the words in another.
SELECT 'C-29 RATING_STEP agrees with the band, on the same four-step scale',
       IFF((SELECT COUNT(*) FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE RATING_STEP <> CASE CORROBORATION
                     WHEN 'CONTRADICTED' THEN 1
                     WHEN 'UNCORROBORATED' THEN 2
                     WHEN 'PARTIALLY CORROBORATED' THEN 3
                     WHEN 'FULLY CORROBORATED' THEN 4 END) = 0, 'PASS', 'FAIL')
UNION ALL
-- And the ladder must never render a marker outside its own four steps.
SELECT 'C-30 RATING_STEP is always within the published scale',
       IFF((SELECT COUNT(*) FROM RULES.V_PROPOSAL_CORROBORATION
             WHERE RATING_STEP IS NULL OR RATING_STEP NOT BETWEEN 1 AND 4) = 0,
           'PASS', 'FAIL')
UNION ALL
SELECT 'C-23 injected proposals removed; only the real ones remain' AS check_name,
       IFF(NOT EXISTS (SELECT 1 FROM RULES.RULE_PROPOSAL
                        WHERE PROPOSAL_ID LIKE 'PRP-CORR-%'),
           'PASS', 'FAIL') AS result;
