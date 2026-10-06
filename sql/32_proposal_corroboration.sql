-- STATUS: EXECUTED 2026-10-06 against account HHUAQYZ-KU03975 (locator KU03975, AWS_US_EAST_2) via
-- tools/sfx as part of tools/deploy_new_account. Ran clean. Verified by
-- INFORMATION_SCHEMA: RULES.V_PROPOSAL_CORROBORATION and the
-- RULES.INTERVAL_FROM_PHRASE UDF both exist. Covered by the 29 checks in
-- tests/test_corroboration.sql.
-- ===========================================================================
-- CORROBORATION, NOT CONFIDENCE.
--
-- Aman asked for a confidence score on AI-proposed rules. The need is real --
-- not every proposal is equally safe to approve, and today a reviewer cannot
-- tell at a glance which ones deserve scrutiny. The MECHANISM is what this file
-- changes, and the reasoning matters more than the code.
--
-- WHY A MODEL-REPORTED CONFIDENCE NUMBER WOULD BE THE WRONG ANSWER HERE
--
--   1. It is not calibrated. An LLM asked "how confident are you, 0-100?"
--      emits a plausible-looking token, not a probability. Its correlation with
--      correctness is weak and unmeasured.
--   2. It manufactures false precision. Printing 0.92 beside a drug-safety
--      rule implies a MEASURED ninety-two percent. In a regulated setting, on
--      the screen where a clinician decides, that is worse than printing
--      nothing.
--   3. It attacks the human gate. A reviewer who sees 0.95 stops reading. The
--      entire product rests on the proposition that the human decision is the
--      valuable step; a number that encourages rubber-stamping optimises for
--      throughput at the cost of the only thing being sold.
--   4. CLAUDE.md hard constraint 3 forbids it outright: "No opaque
--      predictions, no ML scores; priority = visible rule factors."
--
-- WHAT THIS DOES INSTEAD
-- It CORROBORATES the model's claims against the source document using checks
-- we compute ourselves, and shows the reviewer which ones passed. Same shape as
-- PRIORITY_FACTORS on a case: a derived band, with every contributing factor
-- listed and individually checkable.
--
-- THERE **IS** A PERCENTAGE, and the position on that changed. The first
-- version of this file showed only a band and a factor list, on the reasoning
-- above. Aman asked for a number a second time, and he was right that "no
-- number at all" over-corrected: a reviewer scanning a queue of proposals needs
-- something sortable at a glance.
--
-- So CORROBORATION_SCORE exists - but it is a measurement, not an opinion. It
-- is the weighted share of DETERMINISTIC DOCUMENT CHECKS that passed, every
-- point of it traceable to a specific verifiable fact about the source text,
-- and any of it re-derivable by hand. That is a completely different object
-- from a model's self-assessment, and the app labels it as what it is:
-- "document checks passed", never "confidence". The four objections above still
-- stand against the thing they were aimed at; they were never objections to
-- measuring something real.
--
-- THE STRONGEST SIGNAL IS FREE, and it is why the two-backend architecture
-- from sql/24 turns out to earn its keep twice. The deterministic PATTERN UDF
-- is an INDEPENDENT extractor: it reads the same document with different logic
-- and no knowledge of what the model said. Two independent extractors agreeing
-- on drug, test, condition and interval is real evidence -- the kind a
-- statistician would accept and a model's self-assessment is not.
--
-- Deliberately NOT stored as a column on RULE_PROPOSAL. It is computed live, so
-- it can never go stale against a re-ingested document. It IS snapshotted into
-- the RULE_APPROVED audit event, because "what did the evidence look like at
-- the moment a human approved this?" is an audit question with a right answer.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. INTERVAL_FROM_PHRASE -- re-derive the number from the quoted words.
--
-- The single most valuable check in the file. The model reports both a verbatim
-- phrase and an integer; this derives the integer from the phrase INDEPENDENTLY
-- and compares. If the document says "12-week intervals" and the model said 90,
-- that is caught here -- and it is exactly the failure mode DECISIONS C6 exists
-- to prevent, because six days of silent drift in a monitoring interval is a
-- patient-safety change nobody authorised.
--
-- Literal arithmetic, same rules as the pattern extractor: 12 weeks is 84 days,
-- six weeks is 42, quarterly is 90. Never rounded to a calendar month.
--
-- Returns NULL when the wording is not recognised, which is NOT a failure -- it
-- means "this check has nothing to say", and the view reports it that way
-- rather than counting it against the proposal.
-- ===========================================================================
CREATE OR REPLACE FUNCTION RULES.INTERVAL_FROM_PHRASE(PHRASE STRING)
RETURNS NUMBER
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'run'
COMMENT = 'Independently re-derive interval days from a verbatim source phrase. NULL when the wording is not recognised.'
AS
$$
import re

WORD_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "eighteen": 18, "twenty": 20, "twenty-four": 24,
            "thirty": 30, "sixty": 60, "ninety": 90}


def _num(tok):
    tok = (tok or "").strip().lower()
    if tok.isdigit():
        return int(tok)
    return WORD_NUM.get(tok)


# Ordered: the most specific wording is tried first, so "at 12-week intervals"
# is not mis-read by a looser pattern.
PATTERNS = [
    (r"\bquarterly\b",                            lambda m: 90),
    (r"\bat\s+(\d+)-week\s+intervals?\b",         lambda m: int(m.group(1)) * 7),
    (r"\bat\s+([a-z-]+)-week\s+intervals?\b",     lambda m: (_num(m.group(1)) or 0) * 7 or None),
    (r"\b(\d+)-week\s+intervals?\b",              lambda m: int(m.group(1)) * 7),
    (r"\bat\s+(\d+)-day\s+intervals?\b",          lambda m: int(m.group(1))),
    (r"\bevery\s+([a-z-]+|\d+)\s+months?\b",      lambda m: (_num(m.group(1)) or 0) * 30 or None),
    (r"\bevery\s+([a-z-]+|\d+)\s+weeks?\b",       lambda m: (_num(m.group(1)) or 0) * 7 or None),
    (r"\bevery\s+([a-z-]+|\d+)\s+days?\b",        lambda m: _num(m.group(1))),
    (r"\b([a-z-]+|\d+)\s+months?\b",              lambda m: (_num(m.group(1)) or 0) * 30 or None),
    (r"\b([a-z-]+|\d+)\s+weeks?\b",               lambda m: (_num(m.group(1)) or 0) * 7 or None),
    (r"\bmonthly\b",                              lambda m: 30),
    (r"\b(annually|yearly)\b",                    lambda m: 365),
]


def run(phrase):
    if not phrase:
        return None
    low = phrase.lower()
    for pat, fn in PATTERNS:
        m = re.search(pat, low)
        if m:
            try:
                return fn(m)
            except Exception:
                return None
    return None
$$;

-- ===========================================================================
-- 2. V_PROPOSAL_CORROBORATION
--
-- One row per proposal. Every check is a fact about the document, computed
-- here, independent of anything the model asserted about itself.
-- ===========================================================================
CREATE OR REPLACE VIEW RULES.V_PROPOSAL_CORROBORATION
COMMENT = 'Corroborates each proposal against its source document. Derived band plus the visible factors behind it. Not a model confidence score.'
AS
WITH
-- The cited section, if it exists at all. SOURCE_PASSAGE is "section 3" and
-- SECTION_LABEL is "section 3 - Monitoring requirement", hence the prefix match.
cited AS (
  SELECT p.PROPOSAL_ID,
         MAX(k.CHUNK_TEXT) AS SECTION_TEXT
  FROM RULES.RULE_PROPOSAL p
  LEFT JOIN CONF.DOC_CHUNK k
         ON k.DOC_ID = p.DOC_ID
        AND k.SECTION_LABEL ILIKE p.SOURCE_PASSAGE || '%'
  GROUP BY p.PROPOSAL_ID
),

-- The INDEPENDENT extractor's view of the same documents. The pattern UDF has
-- no access to RULE_PROPOSAL and no knowledge of what the model said, which is
-- what makes agreement meaningful rather than circular.
pattern_rules AS (
  SELECT d.DOC_ID,
         LOWER(TRIM(r.value:drug::STRING))               AS P_DRUG,
         LOWER(TRIM(r.value:required_test::STRING))      AS P_TEST,
         LOWER(TRIM(COALESCE(r.value:precondition_value::STRING, ''))) AS P_COND,
         r.value:interval_days::INT                      AS P_DAYS
  FROM CONF.CONF_SAFETY_DOCUMENT d,
       RULES.V_EXTRACTION_VOCAB v,
       LATERAL FLATTEN(input =>
         RULES.EXTRACT_RULES_PATTERN(d.FULL_TEXT, v.VOCAB):rules) r
),

-- Resolve the independent extractor's test name through the SAME governed
-- vocabulary the proposal was resolved through, so the comparison is on
-- identifiers rather than on two spellings of the same analyte.
pattern_resolved AS (
  SELECT pr.DOC_ID, pr.P_DRUG, pr.P_COND, pr.P_DAYS,
         COALESCE(s.LAB_TEST_ID, t.LAB_TEST_ID) AS P_LAB_TEST_ID
  FROM pattern_rules pr
  LEFT JOIN CONF.REF_LAB_TEST_SYNONYM s ON LOWER(s.SYNONYM_TEXT) = pr.P_TEST
  LEFT JOIN CONF.REF_LAB_TEST t         ON LOWER(t.CANONICAL_NAME) = pr.P_TEST
),

base AS (
  SELECT
    v.PROPOSAL_ID, v.DOC_ID, v.MODEL_NAME, v.STATUS,
    v.DRUG_TEXT, v.REQUIRED_TEST_TEXT, v.PRECONDITION_VALUE,
    v.INTERVAL_DAYS, v.INTERVAL_SOURCE_PHRASE, v.SOURCE_PASSAGE,
    v.NEEDS_REVIEW, v.REVIEW_REASON,
    v.DRUG_ID, v.LAB_TEST_ID, v.CONDITION_ID, v.RESOLVE_STATUS,
    c.SECTION_TEXT,

    -- Was the proposal produced by the deterministic engine itself? If so,
    -- cross-engine agreement is meaningless -- it would be agreeing with
    -- itself -- and is reported as not applicable rather than as a pass.
    (v.MODEL_NAME ILIKE 'pattern%') AS SELF_IS_PATTERN,

    -- STRONG: the cited section exists.
    (c.SECTION_TEXT IS NOT NULL) AS CHK_SECTION_EXISTS,

    -- STRONG: the quoted phrase really appears in that section. Whitespace is
    -- collapsed on both sides because a PDF parser reflows lines, and a line
    -- break is not a difference in what the document says.
    (c.SECTION_TEXT IS NOT NULL
     AND POSITION(
           LOWER(REGEXP_REPLACE(TRIM(v.INTERVAL_SOURCE_PHRASE), '\\s+', ' '))
           IN LOWER(REGEXP_REPLACE(c.SECTION_TEXT, '\\s+', ' '))) > 0
    ) AS CHK_PHRASE_VERBATIM,

    -- STRONG: the interval re-derives from the phrase alone.
    RULES.INTERVAL_FROM_PHRASE(v.INTERVAL_SOURCE_PHRASE) AS REDERIVED_DAYS,

    -- MEDIUM: the drug and the test are actually named in the cited section.
    (c.SECTION_TEXT IS NOT NULL AND v.DRUG_TEXT IS NOT NULL
     AND POSITION(LOWER(v.DRUG_TEXT) IN LOWER(c.SECTION_TEXT)) > 0)
      AS CHK_DRUG_IN_SECTION,
    (c.SECTION_TEXT IS NOT NULL AND v.REQUIRED_TEST_TEXT IS NOT NULL
     AND POSITION(LOWER(v.REQUIRED_TEST_TEXT) IN LOWER(c.SECTION_TEXT)) > 0)
      AS CHK_TEST_IN_SECTION,

    -- MEDIUM: the test name matched a governed synonym exactly, rather than
    -- falling back to the canonical name.
    EXISTS (SELECT 1 FROM CONF.REF_LAB_TEST_SYNONYM s
             WHERE LOWER(s.SYNONYM_TEXT) = LOWER(TRIM(v.REQUIRED_TEST_TEXT)))
      AS CHK_VOCAB_EXACT,

    -- WEAK: a plausible monitoring interval. 7..730 days.
    (v.INTERVAL_DAYS BETWEEN 7 AND 730) AS CHK_INTERVAL_PLAUSIBLE,

    -- MEDIUM: the extractor did not flag it itself.
    (NOT COALESCE(v.NEEDS_REVIEW, FALSE)) AS CHK_NOT_FLAGGED
  FROM RULES.V_PROPOSAL_RESOLVED v
  LEFT JOIN cited c ON c.PROPOSAL_ID = v.PROPOSAL_ID
),

scored AS (
  SELECT b.*,
         (b.REDERIVED_DAYS IS NOT NULL AND b.REDERIVED_DAYS = b.INTERVAL_DAYS)
           AS CHK_INTERVAL_REDERIVED,
         (b.REDERIVED_DAYS IS NULL) AS REDERIVE_NOT_APPLICABLE,

         -- STRONG: the independent deterministic extractor reached the same
         -- rule from the same document.
         (NOT b.SELF_IS_PATTERN AND EXISTS (
            SELECT 1 FROM pattern_resolved pr
             WHERE pr.DOC_ID = b.DOC_ID
               AND pr.P_DAYS = b.INTERVAL_DAYS
               AND pr.P_LAB_TEST_ID = b.LAB_TEST_ID
               AND LOWER(TRIM(pr.P_DRUG)) = LOWER(TRIM(b.DRUG_TEXT))
         )) AS CHK_CROSS_ENGINE_AGREE
  FROM base b
)

SELECT
  s.PROPOSAL_ID, s.DOC_ID, s.MODEL_NAME, s.STATUS, s.SOURCE_PASSAGE,
  s.INTERVAL_DAYS, s.REDERIVED_DAYS, s.INTERVAL_SOURCE_PHRASE,
  s.CHK_SECTION_EXISTS, s.CHK_PHRASE_VERBATIM, s.CHK_INTERVAL_REDERIVED,
  s.CHK_CROSS_ENGINE_AGREE, s.CHK_DRUG_IN_SECTION, s.CHK_TEST_IN_SECTION,
  s.CHK_VOCAB_EXACT, s.CHK_INTERVAL_PLAUSIBLE, s.CHK_NOT_FLAGGED,
  s.SELF_IS_PATTERN, s.REDERIVE_NOT_APPLICABLE,

  -- How many of the four STRONG checks passed, and how many even applied.
  -- Reporting the denominator matters: three of three is not the same claim as
  -- three of four, and hiding that difference is how a score starts lying.
  (IFF(s.CHK_SECTION_EXISTS, 1, 0)
 + IFF(s.CHK_PHRASE_VERBATIM, 1, 0)
 + IFF(s.CHK_INTERVAL_REDERIVED, 1, 0)
 + IFF(s.CHK_CROSS_ENGINE_AGREE, 1, 0))              AS STRONG_PASSED,
  (2
 + IFF(s.REDERIVE_NOT_APPLICABLE, 0, 1)
 + IFF(s.SELF_IS_PATTERN, 0, 1))                     AS STRONG_APPLICABLE,

  -- ------------------------------------------------------------------------
  -- CORROBORATION_SCORE: percent of applicable DOCUMENT checks passed,
  -- weighted strong 3 / medium 2 / weak 1.
  --
  -- This is a real measurement, not a model's self-assessment. Every point
  -- traces to a verifiable fact about the source text, and the app labels it
  -- "document checks passed" rather than "confidence" for exactly that reason.
  --
  -- Non-applicable checks are excluded from the DENOMINATOR, not scored zero.
  -- Counting them against a proposal would penalise correct-but-unusual
  -- wording and push extraction toward bland phrasing.
  -- ------------------------------------------------------------------------
  -- WEIGHTS ARE NOT EQUAL, and the first version of this had them too flat.
  -- With strong checks at 3 apiece, a proposal whose quoted phrase was NOT IN
  -- THE DOCUMENT still scored 85% - it lost only one check of nine. But that
  -- one check is the fabrication detector: the phrase is what gets quoted to a
  -- clinician as the justification for the rule, so if it is not in the source
  -- text, nothing else about the proposal is reassuring.
  --
  -- The two GATE checks - the section exists, and the phrase is really in it -
  -- therefore carry 10 each. Failing either drops the score into the seventies
  -- or below AND sets the band to UNCORROBORATED, so the number and the verdict
  -- point the same way instead of arguing with each other.
  ROUND(100.0 * (
      IFF(s.CHK_SECTION_EXISTS,       10, 0)   -- gate
    + IFF(s.CHK_PHRASE_VERBATIM,      10, 0)   -- gate
    + IFF(s.CHK_INTERVAL_REDERIVED,    4, 0)
    + IFF(s.CHK_CROSS_ENGINE_AGREE,    4, 0)
    + IFF(s.CHK_DRUG_IN_SECTION,       2, 0)
    + IFF(s.CHK_TEST_IN_SECTION,       2, 0)
    + IFF(s.CHK_VOCAB_EXACT,           2, 0)
    + IFF(s.CHK_NOT_FLAGGED,           2, 0)
    + IFF(s.CHK_INTERVAL_PLAUSIBLE,    1, 0)
  ) / NULLIF(
      10 + 10                                          -- the two gates
    + IFF(s.REDERIVE_NOT_APPLICABLE,   0, 4)           -- re-derivation
    + IFF(s.SELF_IS_PATTERN,           0, 4)           -- cross-engine
    + 2 + 2 + 2 + 2 + 1, 0), 0)::INT   AS CORROBORATION_SCORE,

  -- Counts, so the app can say "9 of 9 checks" instead of "100%".
  --
  -- Aman's objection was exactly right: nothing here is 100% CERTAIN, and a bare
  -- percentage reads as a certainty claim even when the label underneath says
  -- otherwise. What the number honestly means is "every check we can run
  -- mechanically, passed" - a ceiling on the automated checks, not on the truth.
  -- So the app leads with the COUNT and the RATING, and the percentage survives
  -- only as a sortable field and as the weighted-points detail.
    IFF(s.CHK_SECTION_EXISTS, 1, 0)
  + IFF(s.CHK_PHRASE_VERBATIM, 1, 0)
  + IFF(s.REDERIVE_NOT_APPLICABLE, 0, IFF(s.CHK_INTERVAL_REDERIVED, 1, 0))
  + IFF(s.SELF_IS_PATTERN, 0, IFF(s.CHK_CROSS_ENGINE_AGREE, 1, 0))
  + IFF(s.CHK_DRUG_IN_SECTION, 1, 0)
  + IFF(s.CHK_TEST_IN_SECTION, 1, 0)
  + IFF(s.CHK_VOCAB_EXACT, 1, 0)
  + IFF(s.CHK_NOT_FLAGGED, 1, 0)
  + IFF(s.CHK_INTERVAL_PLAUSIBLE, 1, 0)              AS CHECKS_PASSED,

  9 - IFF(s.REDERIVE_NOT_APPLICABLE, 1, 0)
    - IFF(s.SELF_IS_PATTERN, 1, 0)                   AS CHECKS_APPLICABLE,

  -- Where this proposal sits on a four-step scale, worst to best. Published as a
  -- NUMBER so the app can draw the ladder without hardcoding the band order in
  -- two places, and so a new band cannot silently render as "off the scale".
  CASE
    WHEN NOT s.CHK_SECTION_EXISTS OR NOT s.CHK_PHRASE_VERBATIM THEN 2
    WHEN s.CHK_INTERVAL_REDERIVED = FALSE AND NOT s.REDERIVE_NOT_APPLICABLE THEN 1
    WHEN (IFF(s.CHK_SECTION_EXISTS, 1, 0) + IFF(s.CHK_PHRASE_VERBATIM, 1, 0)
        + IFF(s.CHK_INTERVAL_REDERIVED, 1, 0) + IFF(s.CHK_CROSS_ENGINE_AGREE, 1, 0))
         = (2 + IFF(s.REDERIVE_NOT_APPLICABLE, 0, 1) + IFF(s.SELF_IS_PATTERN, 0, 1))
         AND s.CHK_NOT_FLAGGED THEN 4
    ELSE 3
  END                                                AS RATING_STEP,

  CASE
    WHEN NOT s.CHK_SECTION_EXISTS OR NOT s.CHK_PHRASE_VERBATIM
      THEN 'UNCORROBORATED'
    WHEN s.CHK_INTERVAL_REDERIVED = FALSE AND NOT s.REDERIVE_NOT_APPLICABLE
      THEN 'CONTRADICTED'
    WHEN (IFF(s.CHK_SECTION_EXISTS, 1, 0) + IFF(s.CHK_PHRASE_VERBATIM, 1, 0)
        + IFF(s.CHK_INTERVAL_REDERIVED, 1, 0) + IFF(s.CHK_CROSS_ENGINE_AGREE, 1, 0))
         = (2 + IFF(s.REDERIVE_NOT_APPLICABLE, 0, 1) + IFF(s.SELF_IS_PATTERN, 0, 1))
         AND s.CHK_NOT_FLAGGED
      THEN 'FULLY CORROBORATED'
    ELSE 'PARTIALLY CORROBORATED'
  END                                                 AS CORROBORATION,

  -- The reviewer reads THIS, not a number. Every entry is a fact about the
  -- document that they can go and check for themselves.
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(s.CHK_PHRASE_VERBATIM,
        'The quoted phrase appears verbatim in ' || s.DOC_ID || ', ' || s.SOURCE_PASSAGE,
        'WARNING: the quoted phrase was NOT found in the cited section - the '
        || 'wording may be paraphrased, or the citation may be wrong'),
    IFF(NOT s.CHK_SECTION_EXISTS,
        'WARNING: no section matching "' || COALESCE(s.SOURCE_PASSAGE, '(none)')
        || '" exists in ' || s.DOC_ID, NULL),
    IFF(s.REDERIVE_NOT_APPLICABLE,
        'The interval wording is not one this check recognises, so the number '
        || 'could not be independently re-derived - read the phrase yourself',
        IFF(s.CHK_INTERVAL_REDERIVED,
            'Re-deriving the interval from the phrase alone gives '
            || s.REDERIVED_DAYS || ' days, matching',
            'CONTRADICTED: the phrase re-derives to ' || s.REDERIVED_DAYS
            || ' days but the proposal says ' || s.INTERVAL_DAYS)),
    IFF(s.SELF_IS_PATTERN,
        'Produced by the deterministic engine, so cross-engine agreement does '
        || 'not apply',
        IFF(s.CHK_CROSS_ENGINE_AGREE,
            'The independent deterministic extractor reached the same drug, '
            || 'test and interval from the same document',
            'The independent deterministic extractor did NOT reproduce this '
            || 'rule - not proof of error, but worth reading the section')),
    IFF(s.CHK_DRUG_IN_SECTION, NULL,
        'The drug is not named in the cited section'),
    IFF(s.CHK_TEST_IN_SECTION, NULL,
        'The test is not named in the cited section'),
    IFF(s.CHK_VOCAB_EXACT, NULL,
        'The test name matched the vocabulary loosely rather than by an exact '
        || 'governed synonym'),
    IFF(s.CHK_INTERVAL_PLAUSIBLE, NULL,
        'The interval is outside the plausible 7-730 day range'),
    IFF(s.CHK_NOT_FLAGGED, NULL,
        'The extractor flagged this itself: ' || COALESCE(s.REVIEW_REASON, '(no reason given)'))
  ))                                                  AS FACTORS,

  -- ------------------------------------------------------------------------
  -- CHECKLIST: all nine checks, ALWAYS, each with its verdict and its weight.
  --
  -- FACTORS above is a narrative and stays silent about checks that passed
  -- uneventfully - which is right for reading, but it means a proposal at 100%
  -- shows three bullets and the percentage looks like it came from nowhere. A
  -- number a reviewer cannot decompose is a number they either over-trust or
  -- ignore, and both are worse than no number.
  --
  -- So this column is the arithmetic, itemised: every check, whether it passed,
  -- and what it was worth. Add the weights of the Y lines, divide by the total
  -- of all applicable lines, and you get the percentage on the card by hand.
  -- 'S' marks a check skipped as not applicable - excluded from BOTH sides.
  -- ------------------------------------------------------------------------
  ARRAY_CONSTRUCT(
    IFF(s.CHK_SECTION_EXISTS, 'Y', 'N')
      || ' 10 the cited section exists in the document',
    IFF(s.CHK_PHRASE_VERBATIM, 'Y', 'N')
      || ' 10 the quoted phrase is verbatim in that section',
    IFF(s.REDERIVE_NOT_APPLICABLE, 'S', IFF(s.CHK_INTERVAL_REDERIVED, 'Y', 'N'))
      || ' 4 the interval re-derives from the phrase alone',
    IFF(s.SELF_IS_PATTERN, 'S', IFF(s.CHK_CROSS_ENGINE_AGREE, 'Y', 'N'))
      || ' 4 a second, independent extractor agrees',
    IFF(s.CHK_DRUG_IN_SECTION, 'Y', 'N')
      || ' 2 the drug is named in the cited section',
    IFF(s.CHK_TEST_IN_SECTION, 'Y', 'N')
      || ' 2 the test is named in the cited section',
    IFF(s.CHK_VOCAB_EXACT, 'Y', 'N')
      || ' 2 the test maps to a governed synonym exactly',
    IFF(s.CHK_NOT_FLAGGED, 'Y', 'N')
      || ' 2 the extractor did not flag its own output',
    IFF(s.CHK_INTERVAL_PLAUSIBLE, 'Y', 'N')
      || ' 1 the interval is inside the plausible 7-730 day range'
  )                                                   AS CHECKLIST
FROM scored s;

GRANT SELECT ON VIEW RULES.V_PROPOSAL_CORROBORATION TO ROLE HO_REVIEWER;

-- ===========================================================================
-- 3. Verify against the live proposals.
-- ===========================================================================
SELECT DOC_ID, INTERVAL_DAYS, REDERIVED_DAYS,
       CORROBORATION_SCORE || '%' AS SCORE, CORROBORATION,
       STRONG_PASSED || '/' || STRONG_APPLICABLE AS STRONG,
       CHK_PHRASE_VERBATIM AS VERBATIM,
       CHK_CROSS_ENGINE_AGREE AS CROSS_ENGINE
FROM RULES.V_PROPOSAL_CORROBORATION
ORDER BY DOC_ID;
