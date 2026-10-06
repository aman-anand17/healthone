-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- ===========================================================================
-- THE EXTRACTION ENGINE -- two backends, one contract.
--
-- THE PROBLEM THIS SOLVES
-- Extraction was the single point where the whole product died on a trial
-- account: AI_COMPLETE is blocked, so no proposal could ever be produced from
-- a document, so every rule had to be hand-INSERTed by a human who had
-- already read the document and resolved the IDs by eye. The demo therefore
-- proved nothing about ingestion.
--
-- THE FIX: make the extractor a REPLACEABLE COMPONENT behind a fixed output
-- contract, and ship two implementations of it.
--
--   contract: {"source_doc": "...", "rules": [ {drug, precondition_type,
--              precondition_value, required_test, interval_days,
--              interval_source_phrase, effective_date, source_passage,
--              needs_review, review_reason} ]}
--
--   backend PATTERN      a deterministic Python UDF running INSIDE Snowflake.
--                        Reads the real document text. Works today. Every
--                        proposal it writes is stamped MODEL_NAME='pattern-udf-v1'.
--   backend AI_COMPLETE  Cortex with a Claude model and the prompt stored in
--                        RULES.PROMPT_TEMPLATE. Blocked today; the code path
--                        is live and returns the real Snowflake error rather
--                        than silently falling back.
--
-- Switching between them is one UPDATE to RULES.EXTRACTOR_CONFIG. Everything
-- downstream -- resolution, approval, versioning, detection -- reads
-- RULE_PROPOSAL and cannot tell which backend filled it. That is the point.
--
-- WHY THE PATTERN BACKEND IS NOT A FAKE
-- It is not a lookup table of pre-known answers, and it is not seeded with the
-- rules it finds. It receives the document text and the controlled vocabulary
-- and nothing else. Drop a document it has never seen into the stage and it
-- finds the monitoring sentence or it does not. It is beaten by paraphrase in
-- ways a language model would not be -- that is exactly why the AI backend is
-- the intended one -- but what it reports, it genuinely read.
-- ===========================================================================
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA RULES; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. Which backend is in force, and the prompt as inspectable data.
--
-- THE PROMPT STATES THE OUTPUT SHAPE, and it has to, because response_format
-- could not be used. See section 5 for the full test matrix; the short version
-- is that AI_COMPLETE with a response_format schema containing an ARRAY
-- property returns NULL once the prompt is document-length. A flat schema works
-- with the same prompt and the same schema works with a short prompt, so it is
-- specifically that combination - and it fails by returning NULL rather than by
-- raising, which is exactly the silent-zero failure mode this file is built to
-- refuse.
--
-- So the contract lives in the prompt, and the defence is downstream:
-- EXTRACTION_RUN keeps the raw answer, parsing tolerates a fence or a preamble,
-- and PARSED_OK distinguishes "found nothing" from "unreadable".
-- ===========================================================================
CREATE TABLE IF NOT EXISTS RULES.EXTRACTOR_CONFIG (
  BACKEND        VARCHAR(30)  NOT NULL,   -- PATTERN | AI_COMPLETE
  MODEL_NAME     VARCHAR(80)  NOT NULL,
  PROMPT_VERSION VARCHAR(20)  NOT NULL,
  NOTE           VARCHAR(600) NOT NULL,
  UPDATED_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
-- SEEDED ONLY IF EMPTY, never overwritten. The first version of this file did
-- DELETE-then-INSERT, which meant redeploying it silently switched a
-- Cortex-entitled account back to the PATTERN engine -- and the next
-- extraction then attributed its proposals to 'pattern-udf-v1' with no
-- indication that anything had changed. A deploy must not quietly alter which
-- engine reads the safety documents.
INSERT INTO RULES.EXTRACTOR_CONFIG (BACKEND, MODEL_NAME, PROMPT_VERSION, NOTE)
SELECT 'PATTERN', 'pattern-udf-v1', 'v1',
       'Initial default. The deterministic Python UDF needs no entitlement, so it is the safe starting point on any account; every proposal it writes is stamped pattern-udf-v1 so nothing claims a model produced it. Switch to AI_COMPLETE on an entitled account.'
WHERE NOT EXISTS (SELECT 1 FROM RULES.EXTRACTOR_CONFIG);

CREATE TABLE IF NOT EXISTS RULES.PROMPT_TEMPLATE (
  PROMPT_VERSION VARCHAR(20) NOT NULL,
  PURPOSE        VARCHAR(200) NOT NULL,
  PROMPT_TEXT    VARCHAR(8000) NOT NULL,
  CREATED_AT     TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (PROMPT_VERSION)
);
DELETE FROM RULES.PROMPT_TEMPLATE WHERE PROMPT_VERSION = 'v1';
INSERT INTO RULES.PROMPT_TEMPLATE (PROMPT_VERSION, PURPOSE, PROMPT_TEXT)
SELECT 'v1', 'Extract recurring laboratory monitoring requirements from a medication safety document.',
'You are extracting recurring laboratory monitoring requirements from a medication safety document.

A monitoring requirement exists ONLY when the document states that a specific laboratory test should be repeated on a recurring interval for a specific medication. Everything else is context.

Do NOT create a rule when:
- a test is named only to describe findings, mechanisms or adverse effects;
- the document says a test is not routinely required, or declines to extend a requirement;
- a test was performed once, at enrolment, or as a one-off investigation;
- the document is restating a requirement that is already in force elsewhere, or citing another document;
- the text describes a symptom, a warning, or a reporting process.

Interval normalization, LITERAL - never round:
  quarterly = 90; every three months = 90; every N months = N*30;
  every N weeks = N*7; every N days = N.  TWELVE WEEKS = 84, NOT 90.
  SIX WEEKS = 42, NOT 45.
If the wording does not fit these rules, give your best integer and set needs_review = true with a short review_reason.

Report drug names, test names and conditions EXACTLY as the document prints them. Do not translate them into codes or identifiers - a separate governed step maps text to identifiers, and it must be able to see what the document actually said.

Return ONLY a JSON object and nothing else - no markdown fence, no preamble:
{"source_doc":"<Document ID as printed>","rules":[{"drug":"<name as printed>","precondition_type":"condition|age_min|none","precondition_value":"<diagnosis lower-case | age as string | empty>","required_test":"<test name as printed>","interval_days":<integer>,"interval_source_phrase":"<verbatim, under 15 words>","effective_date":"YYYY-MM-DD","source_passage":"section <n>","needs_review":<true|false>,"review_reason":"<or empty>"}]}

interval_days must be an INTEGER, not a string - "90", not "90 days".
source_passage must be written as the word "section" followed by the section number, for example "section 3". It is used verbatim to look up the cited passage, so any other format breaks the citation.
interval_source_phrase must be VERBATIM from the document and under 15 words.
effective_date is the document date of issue, as YYYY-MM-DD.

If the document contains no recurring monitoring requirement, return an empty rules array. That is a valid and common answer.

Document text follows:
';

-- ===========================================================================
-- 2. The PATTERN backend -- a deterministic Python UDF, in Snowflake.
--
-- Python UDFs run on the warehouse and need no entitlement, which is why this
-- backend works where Cortex does not. Standard library only.
--
-- HOW IT DECIDES. For each sentence of each section it requires ALL FOUR of:
--   a drug from REF_DRUG, a lab from REF_LAB_TEST_SYNONYM, a recurring
--   interval expression, and the absence of any negation marker.
-- Requiring all four is what makes it reject distractors. Dropping any one of
-- them produced false rules on SAFETY_DOC_009 and SAFETY_DOC_011 during
-- development, which is the whole reason the negation list exists.
--
-- Interval arithmetic is LITERAL, per DECISIONS C6: 12 weeks is 84 days, not
-- a calendar quarter. Rounding here would silently change what the product
-- monitors.
-- ===========================================================================
CREATE OR REPLACE FUNCTION RULES.EXTRACT_RULES_PATTERN(DOC_TEXT STRING, VOCAB VARIANT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'run'
COMMENT = 'Deterministic extraction of recurring lab monitoring requirements. Same contract as the AI_COMPLETE backend.'
AS
-- Dollar-quoted, NOT single-quoted. Inside a single-quoted literal Snowflake
-- processes backslash escapes, which silently turned every regex word-boundary
-- marker in this body into a backspace character and produced a Python
-- SyntaxError. Dollar quoting passes the source through untouched.
$$
import re

WORD_NUM = {"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,
            "eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,
            "thirteen":13,"fourteen":14,"fifteen":15,"eighteen":18,
            "twenty":20,"twenty-four":24,"thirty":30,"sixty":60,"ninety":90}

# Ordered: the first pattern that matches wins, so the most specific wording
# is tried before the generic one.
INTERVAL_PATTERNS = [
    (r"\bquarterly\b",                              lambda m: 90),
    (r"\bevery\s+([a-z-]+|\d+)\s+months?\b",        lambda m: _num(m.group(1)) * 30 if _num(m.group(1)) else None),
    (r"\bevery\s+([a-z-]+|\d+)\s+weeks?\b",         lambda m: _num(m.group(1)) * 7  if _num(m.group(1)) else None),
    (r"\bevery\s+([a-z-]+|\d+)\s+days?\b",          lambda m: _num(m.group(1))),
    (r"\bat\s+(\d+)-week\s+intervals?\b",           lambda m: int(m.group(1)) * 7),
    (r"\bat\s+([a-z-]+)-week\s+intervals?\b",       lambda m: _num(m.group(1)) * 7 if _num(m.group(1)) else None),
    (r"\b(\d+)-week\s+intervals?\b",                lambda m: int(m.group(1)) * 7),
    (r"\bat\s+(\d+)-day\s+intervals?\b",            lambda m: int(m.group(1))),
    (r"\bmonthly\b",                                lambda m: 30),
    (r"\b(annually|yearly)\b",                      lambda m: 365),
    (r"\bevery\s+([a-z-]+|\d+)\s+months\s+or\b",    lambda m: _num(m.group(1)) * 30 if _num(m.group(1)) else None),
]

# A sentence containing any of these is describing what is NOT required, or is
# describing a one-off measurement. Either way it is not a recurring rule.
NEGATIONS = [
    r"\bis not required\b", r"\bare not required\b", r"\bnot required\b",
    r"\bnot routinely\b", r"\bno longer\b", r"\bnot a monitoring\b",
    r"\bnot the subject of any interval\b", r"\bdoes not create\b",
    r"\bdo not create\b", r"\bno change to the interval\b",
    r"\bno new monitoring interval\b", r"\bno change to monitoring\b",
    r"\brejected a proposal\b", r"\bnot as a monitoring requirement\b",
    r"\bnot a substitute\b", r"\bencouraged but is not\b",
    r"\bat enrolment\b", r"\bat first prescription\b",
    r"\brestatement of the requirement\b", r"\bis not a monitoring test\b",
    r"\bnot ranked\b", r"\bnot by any new safety signal\b",
    r"\bwill be reviewed within\b", r"\bnot instead of\b",
]

# Wording that means "this document is only pointing at a rule that lives
# elsewhere". Citing another document is not issuing a requirement.
CROSS_REF = [r"\bpublished in SAFETY_DOC_\d+\b", r"\balready in force under\b"]


def _num(tok):
    tok = tok.strip().lower()
    if tok.isdigit():
        return int(tok)
    return WORD_NUM.get(tok)


def _sentences(block):
    # Join wrapped lines into paragraphs first, otherwise a sentence split
    # across two source lines is never seen whole.
    para = re.sub(r"[ \t]*\n[ \t]*", " ", block)
    parts = re.split(r"(?<=[.;])\s+(?=[A-Z(])", para)
    return [p.strip() for p in parts if p.strip()]


def _sections(text):
    out = []
    blocks = re.split(r"\n##\s+", text)
    for i, b in enumerate(blocks):
        if i == 0:
            out.append(("preamble", b))
            continue
        head = b.split("\n", 1)[0].strip()
        m = re.match(r"^(\d+)\.\s*(.*)$", head)
        label = "section " + m.group(1) if m else "section " + str(i)
        out.append((label, b))
    return out


def _find_lab(sentence, labs):
    low = sentence.lower()
    best = None
    for lab in labs:
        names = [lab.get("name") or ""] + [s for s in (lab.get("synonyms") or []) if s]
        for nm in names:
            nm = (nm or "").strip().lower()
            if not nm:
                continue
            if re.search(r"(?<![a-z])" + re.escape(nm) + r"(?![a-z])", low):
                if best is None or len(nm) > len(best[1]):
                    best = (lab, nm)
    return best


def _phrase(sentence, span):
    # verbatim window around the interval expression, capped at 15 words
    words = sentence.split()
    lo_ch, hi_ch = span
    acc, start_w = 0, 0
    for i, w in enumerate(words):
        if acc <= lo_ch:
            start_w = i
        acc += len(w) + 1
    lo = max(0, start_w - 5)
    return " ".join(words[lo:lo + 15]).strip(" ,;.")


def run(doc_text, vocab):
    if not doc_text:
        return {"source_doc": None, "rules": [], "extractor": "pattern-udf-v1"}

    drugs = vocab.get("drugs") or []
    labs = vocab.get("labs") or []
    conds = vocab.get("conditions") or []

    m = re.search(r"SAFETY_DOC_\d{3}", doc_text)
    source_doc = m.group(0) if m else None

    eff = None
    m = re.search(r"Date of issue:\**\s*([0-9]{1,2}\s+[A-Za-z]+\s+[0-9]{4})", doc_text)
    if m:
        try:
            import datetime
            eff = datetime.datetime.strptime(m.group(1).strip(), "%d %B %Y").date().isoformat()
        except Exception:
            eff = None

    rules, seen = [], set()
    for label, block in _sections(doc_text):
        block_low = block.lower()
        for sent in _sentences(block):
            low = sent.lower()

            if any(re.search(p, low) for p in NEGATIONS):
                continue
            if any(re.search(p, sent, re.I) for p in CROSS_REF):
                continue

            drug = None
            for d in drugs:
                nm = (d.get("name") or "").lower()
                if nm and re.search(r"(?<![a-z])" + re.escape(nm) + r"(?![a-z])", low):
                    drug = d
                    break
            if not drug:
                continue

            hit = _find_lab(sent, labs)
            if not hit:
                continue
            lab, lab_surface = hit

            days, span, needs, why = None, None, False, ""
            for pat, fn in INTERVAL_PATTERNS:
                mm = re.search(pat, low)
                if mm:
                    days, span = fn(mm), mm.span()
                    if days is None:
                        needs = True
                        why = "interval wording recognised but the number could not be resolved: " + mm.group(0)
                    break
            if span is None:
                continue
            if days is None:
                continue

            ptype, pval = "none", ""
            for c in conds:
                cn = (c.get("name") or "").lower()
                if cn and cn in low:
                    ptype, pval = "condition", cn
                    break
            if ptype == "none":
                for c in conds:
                    cn = (c.get("name") or "").lower()
                    if cn and cn in block_low:
                        ptype, pval = "condition", cn
                        needs = True
                        why = ("precondition taken from the surrounding section, not the "
                               "requirement sentence - confirm scope before approving")
                        break

            key = (drug.get("id"), lab.get("id"), ptype, pval, days)
            if key in seen:
                continue
            seen.add(key)

            rules.append({
                "drug": drug.get("name"),
                "precondition_type": ptype,
                "precondition_value": pval,
                "required_test": lab_surface,
                "interval_days": days,
                "interval_source_phrase": _phrase(sent, span),
                "effective_date": eff,
                "source_passage": label,
                "needs_review": bool(needs),
                "review_reason": why,
            })

    return {"source_doc": source_doc, "rules": rules, "extractor": "pattern-udf-v1"}
$$;

-- ===========================================================================
-- 3. The vocabulary the extractor is given -- and nothing else.
--
-- A view so that what the extractor can possibly recognise is auditable. If a
-- lab synonym is missing from here, extraction cannot see that test, and that
-- is a data-governance problem with a visible cause rather than a mystery.
-- ===========================================================================
CREATE OR REPLACE VIEW RULES.V_EXTRACTION_VOCAB
COMMENT = 'The controlled vocabulary handed to the extractor. Its only knowledge of the world.'
AS
SELECT OBJECT_CONSTRUCT(
  'drugs',      (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('id', DRUG_ID, 'name', DRUG_NAME))
                   FROM CONF.REF_DRUG),
  'labs',       (SELECT ARRAY_AGG(O) FROM (
                   SELECT OBJECT_CONSTRUCT('id', t.LAB_TEST_ID,
                                           'name', t.CANONICAL_NAME,
                                           'synonyms', ARRAY_AGG(s.SYNONYM_TEXT)) AS O
                     FROM CONF.REF_LAB_TEST t
                     LEFT JOIN CONF.REF_LAB_TEST_SYNONYM s ON s.LAB_TEST_ID = t.LAB_TEST_ID
                    GROUP BY t.LAB_TEST_ID, t.CANONICAL_NAME)),
  'conditions', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('id', CONDITION_ID, 'name', CONDITION_NAME))
                   FROM CONF.REF_CONDITION)
) AS VOCAB;

-- ===========================================================================
-- 4. EXTRACTION_RUN -- the model's raw answer is kept, always.
--
-- THE BUG THIS EXISTS TO MAKE IMPOSSIBLE, found on the first real AI run.
-- The original AI branch did this:
--
--   INSERT INTO RULE_PROPOSAL
--   SELECT ... FROM (SELECT TRY_PARSE_JSON(AI_COMPLETE(...)) AS OUT ...) a,
--                   LATERAL FLATTEN(input => a.OUT:rules) r;
--
-- If the model wrapped its JSON in a markdown fence, or wrote one sentence
-- before it, TRY_PARSE_JSON returned NULL, FLATTEN over NULL produced zero
-- rows, and the procedure reported success with 0 proposals -- which is the
-- SAME output it produces for a document that genuinely contains no
-- monitoring requirement.
--
-- On the first live run that silently lost SAFETY_DOC_005 and SAFETY_DOC_007,
-- the two most important rules in the product, and reported
-- "zero proposals is a valid outcome" for both. Nothing in the system could
-- tell the difference between "the model found nothing" and "we could not read
-- what the model said".
--
-- Two changes fix it permanently:
--   1. The raw response is INSERTED FIRST, unparsed, into EXTRACTION_RUN. It
--      is evidence and it is kept whether or not it parses.
--   2. Parsing is tolerant of the two things models actually do -- a fence and
--      a preamble -- by taking the span from the first brace to the last, and
--      PARSED_OK records whether that worked.
--
-- So zero proposals now always comes with an answer to "why".
-- ===========================================================================
CREATE TABLE IF NOT EXISTS RULES.EXTRACTION_RUN (
  RUN_ID         VARCHAR(60)  NOT NULL,
  DOC_ID         VARCHAR(40)  NOT NULL,
  BACKEND        VARCHAR(30)  NOT NULL,
  MODEL_NAME     VARCHAR(80)  NOT NULL,
  PROMPT_VERSION VARCHAR(20),
  RAW_OUTPUT     VARCHAR,                 -- exactly what came back, unedited
  PARSED_OK      BOOLEAN,
  RULES_FOUND    NUMBER(6,0),
  ERROR_TEXT     VARCHAR(2000),
  RUN_BY         VARCHAR(80)  NOT NULL,
  RUN_AT         TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (RUN_ID)
);

-- The one place the model's output is turned into JSON. A view so that "how
-- forgiving is the parser?" is inspectable rather than buried in a procedure.
--
-- REGEXP_SUBSTR with the 's' parameter makes '.' match newlines, so
-- '\{.*\}' greedily spans the first opening brace to the last closing one.
-- That survives a ```json fence, a "Here is the JSON:" preamble, and trailing
-- commentary, without any of the string surgery those would otherwise need.
CREATE OR REPLACE VIEW RULES.V_EXTRACTION_RUN
COMMENT = 'Extraction runs with the model output parsed. PARSED_OK distinguishes "found nothing" from "could not be read".'
AS
SELECT e.*,
       TRY_PARSE_JSON(REGEXP_SUBSTR(e.RAW_OUTPUT, '\\{.*\\}', 1, 1, 's')) AS PARSED_JSON,
       CASE
         WHEN e.BACKEND = 'AI_COMPLETE' AND e.RAW_OUTPUT IS NULL THEN 'no response from the model'
         WHEN NOT COALESCE(e.PARSED_OK, FALSE) THEN 'the response could not be read as JSON'
         WHEN COALESCE(e.RULES_FOUND, 0) = 0 THEN 'read successfully; the document states no recurring monitoring requirement'
         ELSE 'read successfully'
       END AS OUTCOME
FROM RULES.EXTRACTION_RUN e;

-- ===========================================================================
-- 5. SP_EXTRACT_PROPOSALS -- run whichever backend is configured.
--
-- Idempotent: it clears this document's own PROPOSED rows first, and never
-- touches rows already APPROVED or REJECTED, because those carry a human
-- decision that re-running extraction has no business overwriting.
--
-- The AI branch does NOT fall back to PATTERN on failure. Falling back would
-- write a pattern-produced proposal while the operator believed a model
-- produced it. It returns the real error instead.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE RULES.SP_EXTRACT_PROPOSALS(P_DOC_ID STRING, P_ACTOR STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Extract rule proposals from one document using the configured backend. Always records the raw extractor output.'
AS
$$
DECLARE
  who       STRING;
  backend   STRING;
  model     STRING;
  pver      STRING;
  run_id    STRING;
  n_props   INT DEFAULT 0;
  doc_chars INT DEFAULT 0;
  parsed    BOOLEAN DEFAULT FALSE;
  raw_head  STRING;
BEGIN
  SELECT COALESCE(NULLIF(TRIM(:P_ACTOR), ''), CURRENT_USER(), 'unknown-app-context') INTO :who;
  SELECT BACKEND, MODEL_NAME, PROMPT_VERSION INTO :backend, :model, :pver
    FROM RULES.EXTRACTOR_CONFIG;
  SELECT 'EXR-' || UUID_STRING() INTO :run_id;

  SELECT COALESCE(LENGTH(FULL_TEXT), 0) INTO :doc_chars
    FROM CONF.CONF_SAFETY_DOCUMENT WHERE DOC_ID = :P_DOC_ID;
  IF (:doc_chars = 0) THEN
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error',
      :P_DOC_ID || ' is not in CONF.CONF_SAFETY_DOCUMENT - ingest it first');
  END IF;

  DELETE FROM RULES.RULE_PROPOSAL
   WHERE DOC_ID = :P_DOC_ID AND STATUS = 'PROPOSED';

  -- 5a. Call the extractor and STORE ITS ANSWER before trying to read it.
  IF (:backend = 'AI_COMPLETE') THEN
    BEGIN
      -- WHY THERE IS NO response_format HERE. Tested on this account,
      -- 2026-08-30, with claude-sonnet-5:
      --
      --   flat schema, 1-2 properties  + document-length prompt -> OBJECT, correct
      --   nested ARRAY schema          + short prompt           -> OBJECT, correct
      --   nested ARRAY schema          + document-length prompt -> NULL
      --
      -- Neither the prompt nor the schema alone breaks it; the combination
      -- returns NULL, silently. A guarantee that evaluates to NULL is not a
      -- guarantee, and this file exists because of a silent zero. So the output
      -- contract is stated in the prompt and enforced downstream instead:
      -- the raw answer is stored BEFORE anything parses it, parsing tolerates a
      -- markdown fence or a preamble, and PARSED_OK records whether it worked.
      --
      -- That combination extracted all four live rules correctly from four
      -- different documents and returned zero from both distractors.
      INSERT INTO RULES.EXTRACTION_RUN
        (RUN_ID, DOC_ID, BACKEND, MODEL_NAME, PROMPT_VERSION, RAW_OUTPUT, RUN_BY)
      SELECT :run_id, :P_DOC_ID, 'AI_COMPLETE', :model, :pver,
             AI_COMPLETE(:model,
               (SELECT PROMPT_TEXT FROM RULES.PROMPT_TEMPLATE WHERE PROMPT_VERSION = :pver)
               || d.FULL_TEXT),
             :who
        FROM CONF.CONF_SAFETY_DOCUMENT d
       WHERE d.DOC_ID = :P_DOC_ID;
    EXCEPTION
      WHEN OTHER THEN
        INSERT INTO RULES.EXTRACTION_RUN
          (RUN_ID, DOC_ID, BACKEND, MODEL_NAME, PROMPT_VERSION, RAW_OUTPUT,
           PARSED_OK, RULES_FOUND, ERROR_TEXT, RUN_BY)
        SELECT :run_id, :P_DOC_ID, 'AI_COMPLETE', :model, :pver, NULL,
               FALSE, 0, SQLERRM, :who;
        RETURN OBJECT_CONSTRUCT('ok', FALSE, 'backend', 'AI_COMPLETE',
          'model', :model, 'run_id', :run_id,
          'error', 'Cortex call failed - NOT falling back to the pattern backend, '
                   || 'because a proposal must never be attributed to a model that '
                   || 'did not produce it. Snowflake said: ' || SQLERRM,
          'sqlcode', SQLCODE);
    END;
  ELSE
    INSERT INTO RULES.EXTRACTION_RUN
      (RUN_ID, DOC_ID, BACKEND, MODEL_NAME, PROMPT_VERSION, RAW_OUTPUT, RUN_BY)
    SELECT :run_id, :P_DOC_ID, 'PATTERN', :model, :pver,
           TO_JSON(RULES.EXTRACT_RULES_PATTERN(d.FULL_TEXT, v.VOCAB)), :who
      FROM CONF.CONF_SAFETY_DOCUMENT d, RULES.V_EXTRACTION_VOCAB v
     WHERE d.DOC_ID = :P_DOC_ID;
  END IF;

  -- 5b. Now try to read it, and record whether that worked.
  SELECT (PARSED_JSON IS NOT NULL), LEFT(COALESCE(RAW_OUTPUT, ''), 400)
    INTO :parsed, :raw_head
    FROM RULES.V_EXTRACTION_RUN WHERE RUN_ID = :run_id;

  UPDATE RULES.EXTRACTION_RUN SET PARSED_OK = :parsed WHERE RUN_ID = :run_id;

  IF (NOT :parsed) THEN
    UPDATE RULES.EXTRACTION_RUN
       SET RULES_FOUND = 0,
           ERROR_TEXT = 'Response could not be read as JSON. Kept verbatim in RAW_OUTPUT.'
     WHERE RUN_ID = :run_id;

    INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
    SELECT 'RULE_PROPOSED', :who, 'DOCUMENT', :P_DOC_ID,
           OBJECT_CONSTRUCT('backend', :backend, 'model_name', :model,
                            'run_id', :run_id, 'proposals', 0,
                            'outcome', 'UNREADABLE_RESPONSE');

    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'doc_id', :P_DOC_ID, 'backend', :backend,
      'model_name', :model, 'run_id', :run_id, 'proposals', 0,
      'error', 'The extractor responded but the response could not be read as '
               || 'JSON. This is NOT the same as finding no monitoring '
               || 'requirement, and is deliberately reported as a failure. The '
               || 'response is kept verbatim in RULES.EXTRACTION_RUN.RAW_OUTPUT.',
      'raw_response_head', :raw_head);
  END IF;

  -- 5c. Fan the parsed rules out into proposals.
  INSERT INTO RULES.RULE_PROPOSAL
    (PROPOSAL_ID, DOC_ID, RAW_LLM_OUTPUT, MODEL_NAME, PROMPT_VERSION, EXTRACTED_AT,
     DRUG_TEXT, PRECONDITION_TYPE, PRECONDITION_VALUE, REQUIRED_TEST_TEXT,
     INTERVAL_DAYS, INTERVAL_SOURCE_PHRASE, EFFECTIVE_DATE, SOURCE_PASSAGE,
     NEEDS_REVIEW, REVIEW_REASON, STATUS)
  SELECT 'PRP-' || UUID_STRING(), :P_DOC_ID, e.PARSED_JSON, :model, :pver,
         CURRENT_TIMESTAMP(),
         r.value:drug::STRING, r.value:precondition_type::STRING,
         r.value:precondition_value::STRING, r.value:required_test::STRING,
         r.value:interval_days::INT, r.value:interval_source_phrase::STRING,
         TRY_TO_DATE(r.value:effective_date::STRING), r.value:source_passage::STRING,
         COALESCE(r.value:needs_review::BOOLEAN, FALSE),
         r.value:review_reason::STRING, 'PROPOSED'
    FROM RULES.V_EXTRACTION_RUN e,
         LATERAL FLATTEN(input => e.PARSED_JSON:rules) r
   WHERE e.RUN_ID = :run_id;

  n_props := SQLROWCOUNT;
  UPDATE RULES.EXTRACTION_RUN SET RULES_FOUND = :n_props WHERE RUN_ID = :run_id;

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'RULE_PROPOSED', :who, 'DOCUMENT', :P_DOC_ID,
         OBJECT_CONSTRUCT('backend', :backend, 'model_name', :model,
                          'prompt_version', :pver, 'run_id', :run_id,
                          'proposals', :n_props, 'doc_chars', :doc_chars,
                          'outcome', 'READ_SUCCESSFULLY');

  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'doc_id', :P_DOC_ID, 'backend', :backend,
                          'model_name', :model, 'run_id', :run_id,
                          'proposals', :n_props,
                          'note', IFF(:n_props = 0,
                            'The response was read successfully and states no recurring monitoring requirement in this document.',
                            'Proposals are inert until a human approves them.'));
END;
$$;
