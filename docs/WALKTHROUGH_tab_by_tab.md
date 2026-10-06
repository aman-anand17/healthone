# Tab-by-tab knowledge transfer — HealthOne 360

> **Read [07_WHAT_IS_REAL.md](WALKTHROUGH_what_is_real.md) first.** That document is
> the final tab-by-tab walkthrough and it adds the thing this one lacks: a
> per-feature verdict on what genuinely runs, what is real code fed invented
> data, what is deliberately demo-shaped, and what was never built - each
> claim checked against the account rather than remembered. This file remains
> the deeper reference on individual mechanisms.


**Written for Aman.** You have no medical background, so every clinical term is
explained the first time it appears: *term → what it means → why this product
needs it*. Nothing here is aspirational; every number was queried live from the
account on **2026-08-30** and every claim has a query you can run yourself.

**Account, app link and CLI profile:** see [`../README.md`](../README.md).
This walkthrough was written against an earlier account that has since
expired. The headline counts were re-verified against the current account
on 2026-10-06; the narrower figures in the text below were not.

---

## 0. The product in one paragraph, and the one rule that explains every design choice

A drug-safety committee writes a PDF saying, in prose, "patients on CardioZen
who have chronic kidney disease should have their potassium checked at least
every three months." Nobody can enforce a sentence. This product reads that
PDF with AI, turns the sentence into a **rule** a human approves, then runs
that rule deterministically over a patient population and raises a **case** for
every patient who appears to have missed the check — with the evidence, the
citation, and an audit trail.

The rule that explains everything:

> **AI proposes → a human approves → deterministic checks apply → a human decides.**

AI is used at exactly two points: reading a document, and writing prose about
findings. It never decides whether a case exists, never sets a verdict, and
never puts a rule into force. That boundary is why 47 assertions and 16
detection tests can exist at all — you cannot write a test against a
non-deterministic function.

### Clinical terms you need, once

| Term | What it means | Why the product needs it |
|---|---|---|
| **Lab result** | A measurement from a blood test, e.g. potassium = 4.2 mmol/L on a date. | The evidence that a required check happened. |
| **Serum potassium** | Potassium level in blood. Can rise dangerously in kidney disease. | The thing RUL-001 requires monitoring. |
| **Serum creatinine** | Waste product filtered by kidneys; rising creatinine = worsening kidney function. | RUL-002 and RUL-004 monitor it. |
| **ALT** | Alanine aminotransferase, a liver enzyme. Rises when the liver is stressed. | RUL-003 monitors it. |
| **Chronic kidney disease (CKD)** | Long-term reduced kidney function. | A *precondition*: the rule applies only to patients who have it. |
| **Chronic liver disease (CLD)** | Long-term liver damage. | Precondition for the Hepatrol rule. |
| **Monitoring interval** | How often a test must be repeated, e.g. every 90 days. | The arithmetic the whole product runs on. |
| **Grace period** | Extra days of tolerance before "late" becomes "a case". Ours is 7 days. | Stops the queue filling with patients who are one day late. |
| **Pharmacovigilance** | The discipline of watching medicines for harm after approval. | The job the product supports. |
| **PHI** | Protected Health Information — data identifying a patient. | What the masking layer hides. |
| **Break-glass** | Deliberately breaking a privacy control in an emergency, leaving a record. | How a reviewer sees a real name when they must. |

**All drugs are invented.** CardioZen, Renuvex and Hepatrol do not exist. All
312 patients are synthetic. Every document carries a disclaimer.

### What is in the account right now

| | |
|---|---|
| People | 312 |
| Lab results | 291 (7 deliberately unmapped — see Tab 5) |
| Medication orders | 62 |
| Diagnoses | 100 |
| Claim lines | 3,738 |
| Pharmacy fills | 866 |
| Clinical notes | 584 |
| Safety documents | 7 (14 files staged: 7 PDF + 7 text) |
| Document sections indexed | 43 |
| ACTIVE rules | 4 — all AI-extracted, human-approved |
| Rule proposals | 5 total, 1 awaiting a decision |
| Open cases | 33 (22 monitoring gaps + 11 medication conflicts) |
| Evidence rows | 80 |
| Audit events | 39 |
| Classified PHI columns | 15 |
| Database objects | 46 tables + 13 views across 6 data schemas (plus APP) |
| Credits used | 1.1 of 40 budgeted |

---

## 1. Navigation — how to move around

Six buttons across the top. **There is no sidebar** — it was removed because
Streamlit renamed the expand control between versions, so once collapsed inside
Snowsight it could not be reopened. Buttons cannot get into that state.

```
[ Review queue ] [ Case detail ] [ Intake ] [ Rule library ] [ Operations ] [ Audit trail ]
```

**Case detail only appears once you have opened a case** — a "Case detail"
button with no case selected would be a dead end.

Navigation uses `st.session_state`, **not** URL query parameters. This matters
and cost real time to find: query-parameter links work perfectly when Streamlit
serves its own URL, but Streamlit in Snowflake runs inside a Snowsight iframe
that strips them. Every "Investigate" link produced a blank page in the
deployed app while working locally. `goto()` in
[app/streamlit_app.py](../app/streamlit_app.py) is the single entry point for
navigation, so state can never half-change.

---

## 2. TAB 1 — Review queue

**Who it is for:** a Clinical Case Reviewer starting their day. Never a patient.

### What you see
A prioritised list of patients who appear to have missed a required check. Each
row shows a **pseudonym** (`PT-849509****`), the case type, a priority, the
governing rule, and how many days overdue. Above the list: counts by type. Below
it: a "What is in this dataset" panel.

### How to navigate
Each row has its own **Investigate** button → Case detail for that patient.

### What happens internally
`da.list_cases(("OPEN",))` → `CASES.CASE_REGISTRY` joined to
`RULES.SAFETY_RULE`, `CONF.REF_DRUG`, `CONF.REF_LAB_TEST` and
`SEC.PERSON_TOKEN()`.

Two case types:

- **MONITORING_GAP** — a required test has not been recorded inside the
  window. 22 open.
- **MED_CONFLICT** — the two source systems disagree about whether the patient
  is still on the drug: the hospital record says ACTIVE, the pharmacy has
  dispensed nothing for 90 days. 11 open. **The product does not decide who is
  right.** It shows both and lets the reviewer judge.

### Priority is not a model score
`PRIORITY_FACTORS` is a VARIANT column listing the actual reasons — days
overdue, whether the drug is confirmed active, whether the condition is
confirmed. HIGH means `days_overdue >= interval + grace + 30`. You can read the
arithmetic. There is deliberately **no ML score anywhere in this product**,
because "why is this patient at the top?" must have an answer a clinician can
argue with.

### Snowflake features used
Dynamic tables (`CASES.DT_CASE_CANDIDATE`), a SQL UDF (`SEC.PERSON_TOKEN`),
VARIANT columns, masking policies (the pseudonym is generated, the real name is
masked at the column).

### What could go wrong, and what guards it
- Queue in the hundreds → people stop reading it. Golden check 11 asserts the
  open count stays in a reviewable range (2–40).
- Duplicate cases → golden check 10 asserts the `CANDIDATE_KEY` uniqueness
  invariant `(person, case type, rule, drug)`.

---

## 3. TAB 2 — Case detail

**The most important screen in the product.** Everything else exists to make
this screen trustworthy.

### What you see, top to bottom
1. **Header** — pseudonym, priority, case type, days overdue.
2. **Why this case has this priority** — the factors, spelled out.
3. **Governing rule** — which rule, which version, the *verbatim phrase* from
   the document ("checked at least every three months") and the number it was
   converted to (90 days).
4. **Why this case exists** — the narrative. See below.
5. **Evidence** — the heart of it. Every claim with a verdict:
   - **AGREES** — more than one source supports it.
   - **CONFLICTS** — sources disagree. Both are shown. *The system does not
     adjudicate.*
   - **MISSING** — not found. Always accompanied by **what was searched**,
     because "we didn't find it" without "here is where we looked" is an
     unfalsifiable claim. Data-metric function `DMF_MISSING_WITHOUT_SEARCHED`
     asserts this can never be zero-argument.
6. **Cited answer** — the document passage behind the rule, expandable.
7. **Source document retrieval** — Cortex Search, seeded with this case's rule.
8. **Record your decision** — the disposition.

### The narrative, and who wrote it
Generated by **`claude-sonnet-5` via `AI_COMPLETE`**, from
`CASES.V_CASE_BUNDLE` — a view, so the exact payload the model receives is
queryable. It is reproduced in full in §3.1.

`CASES.CASE_NARRATIVE.GENERATOR` records what wrote each summary: a model name,
or `template` if the deterministic Python fallback did. **A template is never
displayed as a model.** The cache key is the evidence fingerprint, so changing
a verdict, a day count or a rule version forces regeneration — a stale
narrative cannot be shown. One line under the narrative names the generator;
the payload itself is documented in §3.1 below rather than shown on screen.

### 3.1 The AI payload — moved off the screen, documented here

This used to be an expander on the case screen dumping raw JSON. It was
removed: a Clinical Case Reviewer making a clinical judgement does not need a
developer artifact on that screen, and it made the page look unfinished. What
stays on screen is one sentence naming the generator, because prose with no
attribution is worse than no prose.

The payload lives here instead, and it is a **view** — `CASES.V_CASE_BUNDLE` —
so you can query it yourself at any time:

```sql
SELECT * FROM HEALTHONE.CASES.V_CASE_BUNDLE WHERE CASE_ID = '<a case id>';
```

This is a real bundle, for the hero case, exactly as `claude-sonnet-5` receives
it:

```json
{
  "person_token": "PT-849509****",
  "case_type": "MONITORING_GAP",
  "priority": "HIGH",
  "days_since_reference": 137,
  "window_start": "2026-05-27",
  "rule_id": "RUL-001",
  "version": 1,
  "drug": "CardioZen",
  "condition": "chronic kidney disease",
  "required_test": "serum potassium",
  "interval_days": 90,
  "grace_days": 7,
  "verbatim_phrase": "checked at least every three months for the duration of therapy",
  "citation": "SAFETY_DOC_007, section 3",
  "claims": [
    {
      "claim_key": "REQUIRED_LAB",
      "verdict": "MISSING",
      "claim": "No serum potassium result was found in the available records between 2026-05-27 and 2026-09-01.",
      "searched": "CONF_LAB_RESULT via P360_LAB_TIMELINE; test = serum potassium (LAB-K); person PER-001024; window 2026-05-27 to 2026-09-01 (later of therapy start, condition onset, and interval plus grace). Results whose recorded test name could not be mapped to the controlled vocabulary are EXCLUDED from this search and are shown separately in the lab timeline.",
      "citations": []
    },
    {
      "claim_key": "DRUG_ACTIVE",
      "verdict": "AGREES",
      "claim": "CardioZen is recorded as an active medication for this patient.",
      "citations": [
        {"type": "medication",    "source_system": "EHR",      "source_record_id": "ORD-000001", "detail": "CardioZen, status ACTIVE, therapy start 2026-02-02"},
        {"type": "pharmacy_fill", "source_system": "PHARMACY", "source_record_id": "FLL-000001", "detail": "Last fill dispensed 2026-08-04 (2 fill(s) in the last 90 days)"}
      ]
    },
    {
      "claim_key": "CONDITION_PRESENT",
      "verdict": "AGREES",
      "claim": "A diagnosis of chronic kidney disease is recorded for this patient.",
      "citations": [
        {"type": "diagnosis",  "source_system": "EHR",    "source_record_id": "DXR-000001", "detail": "Chronic Kidney Disease, onset 2024-11-10"},
        {"type": "claim_line", "source_system": "CLAIMS", "source_record_id": "CLA-000002", "detail": "Nephrology outpatient review, 2026-03-30 (2 condition-linked claim line(s))"}
      ]
    }
  ]
}
```

**Read the four things that matter about it.**

1. **Every value was decided before the model was called.** The verdicts, the
   137 days, the 2026-05-27 window, whether the case exists at all — all
   arithmetic and SQL comparisons. The model receives conclusions and writes
   prose about them. It cannot change one of them, which is why the 16 golden
   detection tests are possible.

2. **There is no identity in it.** `PT-849509****` is a salted hash, not a
   masked MRN. No name, no date of birth, no `PATIENT_ID`, no `MEMBER_ID`. The
   model is no more trusted with identity than the reviewer is. Note
   `PER-001024` does appear inside the `searched` string — that is the internal
   `PERSON_ID`, which is not identifying on its own and is there so the search
   claim is reproducible.

3. **`searched` is the most important field in the whole product.** A MISSING
   verdict without it is an unfalsifiable claim: "we didn't find it" means
   nothing unless you can see where it looked. It names the table, the test,
   the person, the window, how the window was derived, and — critically — that
   unmappable lab results were **excluded**. That last clause is the honest
   admission that a vocabulary gap makes detection blind, stated inside the
   evidence rather than in a footnote. `DMF_MISSING_WITHOUT_SEARCHED` monitors
   daily that this field is never empty.

4. **CONFLICTS is not resolved.** Where the EHR says a drug is active and
   pharmacy has dispensed nothing for 90 days, both citations appear and the
   verdict says the sources disagree. The product shows both and lets the
   reviewer judge. The model is instructed not to adjudicate either.

**Why the prompt is in the database and not in the code.** The narrative prompt
is in `app/data_access.py` as `NARRATIVE_PROMPT`, and the extraction prompt is a
row in `RULES.PROMPT_TEMPLATE` — visible on the Intake page and queryable. What
gets sent to a model should be inspectable without reading source code.

### Break-glass: seeing the real identity
Choose a reason code, type a justification, submit. `SEC.REQUEST_PHI_REVEAL`
writes the grant **and** the audit row in the same procedure — they cannot be
separated. The masking policies then return real values for that one patient
for 30 minutes. Everyone else stays `*** NAME WITHHELD ***`.

**Stated honestly:** the reveal is scoped per *patient* and time-limited, not
per *user*. `CURRENT_USER()` returns NULL inside Streamlit in Snowflake — the
app runs in a UDF sandbox with no session user — so a per-user predicate could
never match and break-glass silently never worked. The fix trades per-user
isolation for a working control. What remains enforced: nothing is visible
without a deliberate reason-coded request, scoped to one patient, logged
inseparably. Documented in [sql/22](../sql/22_fix_reveal_predicate.sql)
rather than buried.

### Snowflake features used
Conditional masking policies with two arguments (`(value, person_id)`), stored
procedures with `EXECUTE AS OWNER`, VARIANT/`OBJECT_CONSTRUCT`, `AI_COMPLETE`,
Cortex Search, views as prompt contracts.

---

## 4. TAB 3 — Document intake

**This tab is the answer to "where do the rules come from?"** It did not exist
until 30 Aug, and building it exposed the single worst defect in the project —
see §4.5.

### Sub-tab 3.1 — Staging area

**What you see:** every file Snowflake actually holds, read from the stage
**directory table** — not from a list the app keeps. 14 files: 7 PDFs (the
documents of record) and 7 text renderings.

**Run intake** does the whole path:

```
file in @RAW.DOC_STAGE
  → ALTER STAGE REFRESH            (directory table sees new files)
  → AI_PARSE_DOCUMENT(TO_FILE(...), {'mode':'LAYOUT'})
  → RAW.RAW_DOC_FILE               (verbatim parser output, never rewritten)
  → CONF.NORMALISE_DOC_TEXT()      (RAW → CONF conformance)
  → CONF.CONF_SAFETY_DOCUMENT      (MERGE, one row per document)
  → CONF.SP_CHUNK_DOCUMENT()       (split at section headings)
  → CONF.DOC_CHUNK                 (43 rows — the citable units)
  → ALTER CORTEX SEARCH SERVICE REFRESH
  → RULES.SP_EXTRACT_PROPOSALS()   (per document)
  → RULES.RULE_PROPOSAL            (inert until a human approves)
```

It is **idempotent**: `COPY INTO` keeps its own load history, so a file already
ingested is skipped rather than duplicated. Tick *Re-read unchanged files* after
editing a document in place.

**Why chunk at section headings and not fixed windows:** the section label *is*
the citation. "SAFETY_DOC_010, section 3" is what the reviewer reads. A
512-character window cites nothing.

**Why `NORMALISE_DOC_TEXT` exists** — found by running the real parser on the
real PDF. `AI_PARSE_DOCUMENT` returns good markdown but not the *same* markdown:
every heading comes back as level 1, so `## 3. Monitoring requirement` arrived
as `# 3. ...` and the chunker produced **one** chunk for the whole document,
degrading every citation to "the document". It also inlines page footers. The
function fixes heading levels and drops page furniture, and **never alters a
word of content** — the phrase quoted back to the reviewer must be verbatim.
RAW keeps the untouched parser output as the provenance record.

### Sub-tab 3.2 — Extraction engine

Two implementations behind **one output contract**. Everything downstream reads
`RULE_PROPOSAL` and cannot tell which filled it.

| Engine | What it is | Strength | Weakness |
|---|---|---|---|
| `AI_COMPLETE` | Cortex + `claude-sonnet-5`, prompt stored in `RULES.PROMPT_TEMPLATE` | Handles paraphrase | Needs entitlement |
| `PATTERN` | Deterministic Python UDF inside Snowflake | No entitlement, fully reproducible | Beaten by paraphrase |

`AI_COMPLETE` is in force. You can switch engines from this tab and re-run.

**The prompt is stored as data, not hidden in application code** — expand it and
read exactly what is sent.

**The pattern engine is not a fake.** It is given the document text and the
controlled vocabulary and nothing else; it is not seeded with the rules it
finds. For a sentence to become a proposal it needs a known drug, a known lab
test, a recurring interval, and no negation marker. Requiring all four is what
makes it return **zero** from a distractor document. It independently
reproduced all three original rules from prose.

**Extraction never silently falls back.** If the AI call fails you get the real
Snowflake error, because a proposal must never be attributed to a model that
did not produce it.

### Sub-tab 3.3 — Ingest log

One row per file per run. `PARSER_USED` names the parser that actually ran, so
the log can never claim a parser was used that was not.
`DOC_ID_MATCHES_TEXT` cross-checks the filename against the `Reference:` line
inside the file — a mismatch would mean every citation points at the wrong
document.

### 4.5 The worst bug in the project, and why this tab found it

The AI extractor's first live run produced proposals for 5 of 7 documents and
**silently lost SAFETY_DOC_005 and SAFETY_DOC_007 — the two hero rules.** The
code was:

```sql
SELECT ... FROM (SELECT TRY_PARSE_JSON(AI_COMPLETE(...)) AS OUT ...) a,
                LATERAL FLATTEN(input => a.OUT:rules) r;
```

If the model wrapped its JSON in a markdown fence, `TRY_PARSE_JSON` returned
NULL, `FLATTEN` over NULL produced zero rows, and the procedure reported
**success with 0 proposals** — the identical output to a document that genuinely
contains no requirement. Nothing in the system could tell "found nothing" from
"could not read the answer".

Fixed permanently: `RULES.EXTRACTION_RUN` stores the raw response **first**,
unparsed, and `PARSED_OK` records whether it could be read. Parsing now takes
the span from the first `{` to the last `}`, which survives a fence or a
preamble. Zero proposals now always comes with an answer to *why*.

### Snowflake features used
Internal stage with directory table and `SNOWFLAKE_SSE`, `COPY INTO` with
`METADATA$FILENAME` and load history, `AI_PARSE_DOCUMENT`, SQL UDF, Python UDF
(`RUNTIME_VERSION = '3.11'`, standard library only), `SPLIT_TO_TABLE`,
`MERGE`, Cortex Search service refresh, `AI_COMPLETE`, scripting cursors,
`EXECUTE IMMEDIATE` with exception handling.

---

## 5. TAB 4 — Rule library

### Sub-tab 4.1 — Active library

Four rules, each showing the drug, precondition, required test, the **verbatim
phrase** from the document, the interval it became, the citation, who approved
it, and how many open cases it currently causes.

| Rule | Drug + precondition → test | Interval | Source | Extracted by |
|---|---|---|---|---|
| RUL-001 | CardioZen + CKD → serum potassium | 90 d | DOC_007 §3 | claude-sonnet-5 |
| RUL-002 | Renuvex + CKD → serum creatinine | 90 d | DOC_005 §3 | claude-sonnet-5 |
| RUL-003 | Hepatrol + CLD → ALT | **84 d** | DOC_006 §2 | claude-sonnet-5 |
| RUL-004 | CardioZen + CKD → serum creatinine | **42 d** | DOC_010 §3 | claude-sonnet-5 |

**84 and 42 are the point.** The documents say "at 12-week intervals" and
"every six weeks". Interval arithmetic is **literal**: 12 × 7 = 84, not a
rounded calendar quarter; 6 × 7 = 42, not a month and a half. Rounding would
silently change what the product monitors. Golden checks 13 and 15 assert it.

**Run this rule** refreshes the 360 layer, re-evaluates one rule against every
person, and reports the delta. This makes causality visible: approve a rule,
run it, see exactly what it produced — recorded as a `RULE_EVALUATED` audit
event. Detection is **not** automatic, because every dynamic table is
`SCHEDULER = DISABLE` for cost.

**Rules are immutable.** A correction is a new version; nothing is edited in
place. Approving a change supersedes the prior version and records
`SUPERSEDED_BY_VERSION`.

### The on/off switch — a rule can be approved and paused at the same time

Each ACTIVE rule has an **In force** toggle, like an Outlook mail rule. This
exists because the documents themselves anticipate it — SAFETY_DOC_010 says
*"where a site cannot meet the six-week interval from existing capacity, the
site pharmacy lead should escalate to the Committee rather than allow the
interval to extend."* Until that escalation resolves, the rule is correct and
approved, and raising a case for every affected patient nightly is noise that
trains people to ignore the queue.

**Pausing affects NEW cases only. Existing cases are never touched.** Turning
off an Outlook rule does not un-file the mail it already filed. A case is a
statement that a specific patient appears to have missed a required test, and
that statement does not stop being true because a committee paused the rule.
A product that silently cleared 15 open patient cases because someone flipped a
switch would be actively dangerous.

Three design points worth understanding:

1. **It is a separate flag, not a new `STATUS`.** `STATUS` is the *governance*
   lifecycle (ACTIVE → SUPERSEDED → RETIRED) — what a human decided about the
   rule's authority. `IS_ENABLED` is *operational* — whether it currently makes
   work. Collapsing them would mean pausing looked like retiring in the audit
   trail, and worse: version-bump detection looks for an ACTIVE rule on the same
   (drug, condition, test) triple, so if pausing cleared ACTIVE, approving a
   revised interval would create a **second competing rule instead of a new
   version** and double every case.

2. **The gate is in the MERGE, not in the detection table.** `DT_CASE_CANDIDATE`
   keeps producing a candidate for a paused rule, because *the patient's gap
   still exists*. If the filter had gone into the dynamic table, those
   candidates would vanish and the "candidate no longer exists" sweep would mark
   every one of that rule's open cases `RESOLVED_BY_DATA` — asserting the gaps
   had **closed**. Gating at the merge means the sweep still sees them and
   leaves them alone, with no special case needed to protect them.

3. **A pause requires a reason, enforced in the procedure.** Not in the UI — so
   it holds for the CLI and any future caller too. `DISABLED_BY`, `DISABLED_AT`
   and `DISABLE_REASON` are recorded, and both transitions write
   `RULE_PAUSED` / `RULE_RESUMED` audit events. A rule silently switched off is
   indistinguishable from a rule nobody noticed was off.

`RULES.V_RULE_STATE` shows both states side by side, with an `EFFECTIVE_STATE`
column that reads *"IN FORCE - raising cases"*, *"APPROVED BUT PAUSED - raises
no NEW cases"*, or the governance status when it is no longer in force.

Check it yourself:

```sql
SELECT RULE_ID, VERSION, GOVERNANCE_STATUS, IS_ENABLED, EFFECTIVE_STATE, OPEN_CASES
FROM HEALTHONE.RULES.V_RULE_STATE ORDER BY RULE_ID;
```

**Tested by `tests/test_rule_toggle.sql` (17 checks).** The important ones pause
a rule that has 15 live cases, run the **full pipeline** while it is paused —
which is exactly where a naive implementation sweeps them away — and assert the
count is identical before and after.

### Sub-tab 4.2 — Proposals awaiting approval

One proposal is pending: **SAFETY_DOC_008 shortens the CardioZen potassium
interval from 90 days to 60.** It is left pending deliberately — approving it
live supersedes RUL-001 v1 with v2 and visibly changes the queue. That is the
demo beat; it should happen in front of an audience.

Each proposal shows the extracted text, the **resolved identifiers**, whether it
is approvable, and if not **exactly why**.

**Resolution is a separate, visible step, and that is deliberate.** The
extractor reports what the document says in the document's words. Mapping those
words onto governed identifiers is a different decision with a different failure
mode: an unmapped test name must **block** the rule loudly, because a rule with
the wrong `LAB_TEST_ID` monitors the wrong analyte forever while looking
perfectly healthy. `RULES.V_PROPOSAL_RESOLVED` computes `RESOLVE_STATUS` and
`BLOCKING_REASON`; the reviewer sees the mapping before approving it.

`RULES.SP_APPROVE_PROPOSAL` then decides on its own whether this is a **new
rule** or a **version bump** of an existing one, by looking for an ACTIVE rule
on the same (drug, condition, test) triple. Getting that wrong would double
every case.

### Corroboration: there IS a percentage, and it is a measurement

Every proposal carries a **percentage**, a **band**, and an itemised
**checklist**. You asked for a confidence score; what is on the screen is a
score, but it is not the *kind* of score you would get from asking the model how
sure it is, and that distinction is the whole section.

The number is **the share of deterministic document checks that passed**,
weighted. Every point of it traces to a specific verifiable fact about the
source text, and the card lists all nine checks with their weights so you can
add them up and reproduce the figure by hand. The label on screen says
"document checks passed" and never "AI confidence", because those are different
claims and only one of them was measured.

**Why not a model confidence score.** An LLM asked "how confident are you,
0-100?" emits a plausible-looking token, not a probability — its correlation
with correctness is unmeasured. Printing `0.92` beside a drug-safety rule
implies a *measured* ninety-two percent, which in a regulated setting on the
screen where a clinician decides is worse than printing nothing. Worse still, a
reviewer who sees 0.95 stops reading, and the human gate is the entire product.
It also breaks hard constraint 3: *no opaque predictions, no ML scores*.

**What it does instead.** It checks the model's claims against the source
document, using facts we compute ourselves:

| Check | Strength | What it catches |
|---|---|---|
| The quoted phrase appears **verbatim** in the cited section | strong | A paraphrased or invented justification — the phrase is what gets quoted to the clinician |
| The cited section **exists** | strong | A fabricated citation |
| The interval **re-derives** from the phrase alone (`RULES.INTERVAL_FROM_PHRASE`) | strong | "12-week intervals" recorded as 90 days instead of 84 — six days of silent drift nobody authorised |
| The **independent deterministic extractor** reaches the same rule | strong | Anything only one engine believes |
| Drug and test are named in the cited section | medium | A rule attached to the wrong passage |
| The test matched an exact governed synonym | medium | Loose vocabulary matching |
| The extractor did not flag itself | medium | Known uncertainty |
| The interval is 7–730 days | weak | Nonsense arithmetic |

The **cross-engine check is the strongest signal and it is free** — it is why
the two-backend design from `sql/24` earns its keep twice. The deterministic
Python UDF reads the same document with different logic and no knowledge of
what the model said. Two independent extractors agreeing is evidence a
statistician would accept; a model's self-assessment is not.

Bands: `FULLY CORROBORATED`, `PARTIALLY CORROBORATED`, `UNCORROBORATED` (the
phrase or the section is missing), `CONTRADICTED` (the arithmetic disagrees with
the words). The band exists only to sort attention — **the reviewer reads the
factors**, and every one is a fact they can go and check.

All five live proposals are `FULLY CORROBORATED`, 4 of 4 strong checks, with the
intervals re-deriving exactly to 90 / 84 / 90 / 60 / 42.

The corroboration is **snapshotted into the `RULE_APPROVED` audit event**,
because the view is computed live — once a document is re-ingested the evidence
as it stood at approval time is no longer recoverable, and "what did the
reviewer see when they approved this?" has a right answer.

**How the nine checks are weighted, and why it changed.** The first version
scored strong 3 / medium 2 / weak 1 and a new test immediately caught it as
wrong: a proposal whose quoted phrase was **not in the document at all** still
scored **85%**, because it had lost only one check of nine. But that one check
is the fabrication detector — the quoted phrase is what gets shown to a
clinician as the reason the rule exists, so if it is not in the source text,
nothing else about the proposal is reassuring.

So the two **gate** checks carry 10 apiece:

| Weight | Check | Kind |
|---|---|---|
| 10 | the cited section exists in the document | gate |
| 10 | the quoted phrase is verbatim in that section | gate |
| 4 | the interval re-derives from the phrase alone | strong |
| 4 | a second, independent extractor agrees | strong |
| 2 | the drug is named in the cited section | medium |
| 2 | the test is named in the cited section | medium |
| 2 | the test maps to a governed synonym exactly | medium |
| 2 | the extractor did not flag its own output | medium |
| 1 | the interval is inside the plausible 7-730 day range | weak |

Failing either gate now drops the number into the seventies or below **and**
sets the band to UNCORROBORATED, so the figure and the verdict point the same
way instead of arguing with each other. Two further details matter:

- **The colour follows the band, not the number.** A fabricated quote can never
  render green, whatever arithmetic it scrapes together.
- **Non-applicable checks leave the denominator**, they are not scored zero.
  Counting them against a proposal would punish correct-but-unusual wording and
  quietly push extraction toward bland phrasing.

**Why the checklist is always complete.** `FACTORS` is a narrative and stays
silent about checks that passed uneventfully, which is right for reading but
meant a 100% card showed three bullets and the percentage looked like it came
from nowhere. A score a reviewer cannot take apart gets either over-trusted or
ignored, and both are worse than no score. `CHECKLIST` therefore lists all nine
every time, `S` marking one skipped as not applicable.

**All five real proposals currently score 100%.** That is honest — these five
extractions are correct — but a badge that is always green teaches a reviewer
nothing, which is exactly why the evidence that the score *can* fall lives in
the test suite rather than in the seed data.

**Tested by `tests/test_corroboration.sql` (25 checks).** A check that has never
failed is decoration, so the test injects a deliberately broken proposal per
failure mode — a paraphrased phrase, an interval contradicting its own quote, a
section that does not exist, a self-flagged extraction — and asserts each is
caught *and named in words*. Four checks assert the **number** moves with the
checks rather than merely the badge, and three more assert the checklist is
complete, well-formed, and that its ticked weights **recompute the displayed
percentage exactly** — so the score and its explanation cannot drift apart.

```sql
SELECT DOC_ID, INTERVAL_DAYS, REDERIVED_DAYS,
       CORROBORATION_SCORE || '%' AS SCORE, CORROBORATION,
       STRONG_PASSED || '/' || STRONG_APPLICABLE AS STRONG, CHECKLIST, FACTORS
FROM HEALTHONE.RULES.V_PROPOSAL_CORROBORATION ORDER BY DOC_ID;
```

### The thing that was actually missing until 30 Aug
`RULE_PROPOSAL` existed. `SAFETY_RULE` existed. **There was nothing between
them.** All three original rules reached `SAFETY_RULE` as hand-typed INSERTs in
which a human had already read the document and worked out that "CardioZen"
means `DRG-CARDIOZEN`. Inserting a proposal row did *nothing*. The product's
central claim had no approve step. `sql/25` is that step, and
`tests/test_document_intake.sql` D-11…D-16 prove it: a hand-inserted row
approves into a live rule, and an unmappable one is refused with the missing
vocabulary row named.

---

## 6. TAB 5 — Operations

### Sub-tab 5.1 — Pipeline
Run the whole pipeline, turn the nightly schedule on or off, and see run
history. `CASES.SP_RUN_PIPELINE` is **change-aware**: with `force=false` it
checks four streams (`SYSTEM$STREAM_HAS_DATA`) and exits after a metadata check
if nothing changed. That is what makes a nightly schedule affordable.

Task `T_HEALTHONE_PIPELINE` runs `USING CRON 0 6 * * * UTC` and is
**suspended by default**. The maintenance switch on this tab resumes/suspends
it. Every run writes to `CASES.PIPELINE_RUN_LOG`.

### Sub-tab 5.2 — Data quality & governance
`SEC.V_DATA_QUALITY` — six readings, each with an explicit pass threshold and a
sentence on *why it matters for this product*. Four are also **Data Metric
Functions attached to tables** on a daily schedule, so data quality is a
monitored property with history, not a query someone remembers to run.

The most important reading is **unmapped lab results: 7**. That is
*deliberate*. `'k+ serum level'` is intentionally absent from
`CONF.REF_LAB_TEST_SYNONYM`, so seven real potassium results cannot satisfy any
rule. Patient PER-001131 has a case **because of it**. This is the P1131
mechanism: the product must be honest that vocabulary gaps make it blind, and
must surface the number rather than hide it. Assertion A-02 protects the gap
from being "fixed".

Also here: `SEC.V_PHI_INVENTORY` — 15 classified columns and whether each is
protected. This is the compliance answer to "where is the patient data?" that
column-by-column DDL cannot give you.

### Sub-tab 5.3 — Search the safety corpus
**Cortex Search** (`CONF.DOC_SEARCH`) over the 43 document sections.
Embedding-based, so it matches meaning: *"how often should liver enzymes be
rechecked"* returns DOC_006 §2 — the ALT requirement — with none of those words
present in the text.

Every result names the engine that found it. The lexical `SEARCH()` path is kept
as a labelled fallback, so the product degrades to worse-but-working rather than
to a blank page.

`TARGET_LAG` is **1 day**, not the 1 minute every tutorial uses: a search
service re-indexes on its lag whether or not anything changed, and that is
serverless spend. Intake forces a refresh when it actually loads something —
learned the hard way, because the service was created while `DOC_CHUNK` was
still empty and returned zero results for everything while looking healthy.

### Sub-tab 5.4 — Governed analytics
A real Snowflake **semantic view**, `P360.HEALTHONE_360`: 3 tables, 2
relationships, 7 dimensions, 4 metrics. Five pre-declared questions. The
generated SQL is printed under each answer.

Questions are pre-declared rather than free text because the semantic-view
grammar has no bind-parameter form — interpolating user text would be an
injection hole. Stated as a design choice, not hidden as a limitation.

---

## 7. TAB 6 — Audit trail

39 events: every rule proposal, approval, rejection, rule evaluation, pipeline
run, PHI reveal and disposition.

**Tamper-evident, and tested by attacking it.** Each row is hashed into a chain
(`sql/11`); `SEC.V_AUDIT_INTEGRITY` recomputes and compares against
`AUDIT_CHECKPOINT`. Rewriting an `ACTOR` is caught as *"row content was
altered"*; deleting a row as *"audit rows were deleted"*. Both were verified by
deliberately doing them.

**The honest limit, stated in the app itself:** an ACCOUNTADMIN could take
ownership and recompute the whole chain. This buys **detection, not
prevention**. The production next step is off-platform — stream these events to
write-once storage so the check compares against a copy the database cannot
reach.

Also on this tab: the **break-glass log** — who revealed which patient, when,
under what reason code, with what justification.

---

## 8. Appendix A — the seven schemas

| Schema | Holds | Objects |
|---|---|---|
| `RAW` | Landing zone. Verbatim source data and parser output, never rewritten. | 10 tables |
| `CONF` | Conformed layer. Cleaned, typed, vocabulary-mapped. Documents and chunks. | 16 tables, 1 view |
| `P360` | The Patient & Member 360 — four dynamic tables + the semantic view. | 4 dynamic tables |
| `RULES` | Proposals, versioned rules, extractor config, prompts, extraction runs. | 5 tables, 3 views |
| `CASES` | Detection, case registry, evidence, narratives, audit, pipeline log. | 7 tables, 5 views |
| `SEC` | Masking policies, row policies, reveal grants, tokens, DQ metrics, PHI inventory. | 4 tables, 4 views |
| `APP` | The Streamlit app and its stage. | — |

Layering is **medallion**: RAW → CONF → P360 → RULES/CASES. Each layer is
allowed to read only the one below it.

## 9. Appendix B — Snowflake features actually used

Dynamic tables (`SCHEDULER = DISABLE`, `REFRESH_MODE = FULL`) · streams +
`SYSTEM$STREAM_HAS_DATA` · tasks with CRON · stored procedures
(`EXECUTE AS OWNER`) · SQL UDFs · **Python UDFs** · conditional masking
policies (2-argument) · **tag-based masking** · row access policies · object
tags · **Data Metric Functions** (attached, scheduled) · **semantic views** ·
**Cortex Search** · **`AI_COMPLETE`** · **`AI_PARSE_DOCUMENT`** ·
cross-region inference · internal stages with directory tables · `COPY INTO`
with load history · resource monitors · Streamlit in Snowflake · `SEARCH()`
native full-text.

## 10. Appendix C — commands you will actually use

Run everything into a brand-new account:

```bash
./tools/sfx sql -f sql/26_new_account_setup.sql && ./tools/deploy_new_account
```

Check the app's data layer before trusting the deployed app:

```bash
SNOWFLAKE_HOME="$HOME/.snowflake-ho360" python tests/smoke_app.py
```

The three test suites:

```bash
./tools/sfx sql -f tests/assertions.sql && ./tools/sfx sql -f tests/test_detection_golden.sql && ./tools/sfx sql -f tests/test_document_intake.sql
```

Redeploy the app:

```bash
cd app && SNOWFLAKE_DEFAULT_CONNECTION_NAME=hackathon2 SNOWFLAKE_HOME="$HOME/.snowflake-ho360" snow streamlit deploy --replace
```

Prove no rule was hand-written:

```sql
SELECT r.RULE_ID, r.VERSION, p.MODEL_NAME, r.APPROVED_BY
FROM RULES.SAFETY_RULE r
JOIN RULES.RULE_PROPOSAL p ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
WHERE r.STATUS = 'ACTIVE';
```

## 11. Test results as of 2026-08-30

| Suite | Result | What it covers |
|---|---|---|
| `tests/assertions.sql` | **47 / 47 PASS** | Structural integrity, keys, dates, vocabulary, PHI masking enforced, audit chain intact |
| `tests/test_detection_golden.sql` | **16 / 16 PASS** | The 8 golden patients, grace boundaries, precondition gating, RUL-004, "no rule was hand-written" |
| `tests/test_document_intake.sql` | **17 / 17 PASS** | Staging area, extraction reads real documents, distractors yield zero, hand-inserted rows approve, unmappable rows are refused |
| `tests/test_rule_toggle.sql` | **17 / 17 PASS** | The per-rule on/off switch, and that pausing never touches an existing case |
| `tests/test_corroboration.sql` | **25 / 25 PASS** | Proposal corroboration, including that each check catches an injected bad proposal |
| `tests/smoke_app.py` | **29 / 29 PASS** | Every data-access function the app calls, plus the key set each returns |

**Total: 144 automated checks, all passing.**

## 12. What is still not true, stated plainly

1. **`coco/` is empty.** The hackathon is named after CoCo CLI and grades its
   use. Nothing has been placed there because nothing has come from a genuine
   CoCo session, and fabricating it would be the one unrecoverable mistake.
   This needs Aman.
2. **The document corpus is single-authored.** Seven documents written by one
   author to be extracted by this pipeline. They contain deliberate distractors
   and negations, and the two distractors correctly yield zero — but they are
   not a defence against real-world prose.
3. **Break-glass is per-patient, not per-user** (§3).
4. **The audit chain buys detection, not prevention** (§7).
5. **All data is synthetic**, all drugs invented, one anchor date
   (`2026-09-01`) so results are reproducible.

Last updated: 2026-08-30.
