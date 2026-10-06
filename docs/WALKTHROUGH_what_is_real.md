# HealthOne 360 — what each tab does, and what is actually real

Written for Aman, 31 Aug 2026, the night before submission. Two jobs:

1. **A KT of every tab** — what you see, what happens when you click, which
   tables it touches, which Snowflake feature does the work.
2. **An honest audit** — what genuinely runs, what is real code fed invented
   data, what is deliberately simplified for a demo, and what was never built.

If a judge asks "is this real?", the answer is in here and you can say it out
loud without checking with me first. Everything in the "real" column was
verified by querying the account today, not remembered.


## How to read the labels

| Label | Means |
|---|---|
| **REAL** | Runs on the Snowflake account. Covered by a test. Would behave identically on real data. |
| **REAL CODE / INVENTED DATA** | The code path is real and tested. The rows it reads are synthetic *on purpose* — this is a hackathon on a trial account and using real patient data would be the actual problem. |
| **DEMO-SHAPED** | Real, but deliberately simplified so a demo is watchable. The production gap is named. |
| **NOT BUILT** | Says so. No hedging. |

There is no fifth label for "mocked up in the UI with no backend", because
there is nothing in that category. Every number on every screen comes from a
query. That was the point of the fixture seam: the app can run on fixtures for
UI work, but the deployed app runs on the account and the header says which.

---

## The account, as queried today

These are facts, not claims. Each was returned by a `SHOW` or
`INFORMATION_SCHEMA` query while writing this document.

| Thing | Count | Detail |
|---|---|---|
| Dynamic tables | **5** | `P360_PERSON`, `P360_LAB_TIMELINE`, `P360_MEDICATION_TIMELINE`, `P360_ACTIVE_MEDICATION`, `CASES.DT_CASE_CANDIDATE` |
| Base tables | **46** | RAW 10 · CONF 16 · P360 4 (the dynamic tables) · RULES 5 · CASES 7 · SEC 4 |
| Views | **15** | CASES 5 · RULES 5 · SEC 4 · CONF 1 |
| Streams | **4** | `STR_LAB_RESULT`, `STR_MEDICATION`, `STR_DIAGNOSIS`, `STR_SAFETY_RULE` — all DELTA, none stale |
| Tasks | **1** | `CASES.T_HEALTHONE_PIPELINE`, `CRON 0 6 * * * UTC`, **state: suspended** |
| Masking policies attached | **4** | on `P360_PERSON`: `NAME`, `DOB`, `PATIENT_ID`, `MEMBER_ID` |
| Row access policies | **0** | none exist — see the honest gaps section |
| Object tags | **3** | `SEC.DATA_SENSITIVITY`, `SEC.PAYER_IDENTIFIER`, `SEC.SOURCE_SYSTEM_TAG` |
| Data metric functions attached | **2** | `DMF_FUTURE_DATED`, `DMF_UNMAPPED_LAB_PCT` on `CONF_LAB_RESULT` |
| Semantic views | **1** | `P360.HEALTHONE_360` |
| Cortex Search services | **1** | `DOC_SEARCH` over the document chunks |
| UDFs | **9** | 2 Python (`RULES`), 7 SQL (`SEC` 5, `CASES` 1, `CONF` 1) |
| Stored procedures | **17** | CASES 7 · RULES 6 · CONF 2 · SEC 2 |
| Automated checks | **162** | 47 assertions · 16 detection golden · 17 intake · 17 rule toggle · 29 corroboration · 36 app smoke |
| Credits consumed | **5.0** | against a 120-credit account cap |

Live data: **312 people · 291 lab results** (7 deliberately unmapped) **· 7
documents · 43 section chunks · 14 staged files · 4 active rules · 5 proposals
· 33 open cases · 80 evidence rows**.

---

## Tab 1 — Review queue

### What you see
A worklist. One row per open case: pseudonymised patient, case type, the
sentence explaining why it was raised, a priority, and an **Investigate**
button. Filters for status and case type. A **Refresh queue** button.

### What happens internally
The page reads `CASES.V_CASE_QUEUE`, a view over `CASE_REGISTRY` joined to
`P360_PERSON` and the rule that raised each case. Nothing is computed in
Python — the "why" sentence and the priority band are columns produced by SQL.

The counts in the page header (`OPEN CASES`, `ACTIVE RULES`) come from a
separate cached header query with a 45-second TTL, invalidated explicitly by
every writer in `data_access.py`, so an approval or a pause updates the header
immediately rather than after the cache expires.

**Refresh queue** does not recompute cases. It re-reads. Recomputation lives on
the Operations tab, deliberately — a reviewer refreshing their list should
never be able to change what is in it.

### Tables and features
`CASES.CASE_REGISTRY`, `CASES.V_CASE_QUEUE`, `P360.P360_PERSON` (dynamic
table), `RULES.SAFETY_RULE`. Masking policies apply here: the patient
identifier is masked *by the database*, so the app cannot leak it even if the
app is wrong.

### Real or not

| Element | Verdict |
|---|---|
| The 33 cases | **REAL CODE / INVENTED DATA.** Every case was produced by SQL evaluating an approved rule against the 360. None was inserted by hand. |
| Priority band | **REAL.** Derived from stated factors (days since last result, interval, grace). No model, no score. |
| The "why" sentence | **REAL.** Composed in SQL from the same factors. |
| Pseudonymisation | **REAL.** Column masking policy, verified attached today. |

---

## Tab 2 — Case detail

### What you see
The screen a reviewer actually works. Top to bottom: the case type and
priority; a person strip (age band, sex, clinic, plan, condition and med
counts); a **Reveal patient identity (recorded)** expander; **why this case
has this priority**; the **governing rule** with its citation; **why this case
exists** (the drug/condition/test triple and the quoted phrase beside the
number it became); the **monitoring window**; the **evidence** block; a
**cited answer**; **source document retrieval**; and the disposition control.

### What happens internally

**The evidence block is the heart of it.** `CASES.CASE_EVIDENCE` holds one row
per expected fact with a verdict of `AGREES`, `CONFLICTS` or `MISSING`,
produced by a reconciler procedure, not by a model. On the screenshot in the
deck:

- **AGREES** — the CKD diagnosis appears in both the EHR record (`DXR-000072`)
  and a 2026-06-25 specialist claim (`CLA-002642`).
- **CONFLICTS** — the EHR says CardioZen is `ACTIVE` from 2026-04-15
  (`ORD-000044`); pharmacy fills say the last dispense was 2026-04-28 with no
  fills in 90 days (`FLL-000604`). Both are shown side by side. **The system
  does not choose.**
- **MISSING** — "No serum potassium result was found in the available records
  between 2026-05-27 and 2026-09-01." Absence is written as a finding in a
  fixed verbatim pattern, never left as a blank cell.

**Reveal patient identity** calls `SEC.SP_REQUEST_REVEAL`, which writes an
audit event and grants a reveal scoped to that one case. The masking policy
reads that grant. Break-glass is enforced by the database, not by hiding a
button.

**The cited answer** is the one place a model writes prose for a reviewer, and
it is fenced hard:

- SQL assembles an evidence bundle first — the rule, the day counts, every
  verdict. The model receives it and **cannot alter it**.
- The bundle carries a pseudonym. **No name, no date of birth, no
  source-system id is ever sent to a model.**
- It is cached on the *evidence fingerprint*, not on a clock, so the text
  regenerates the moment a verdict, a day count or a rule version changes.
- Whether the case exists at all, and what each verdict is, were decided by
  arithmetic **before** any model was called.

**Source document retrieval** is Cortex Search over the corpus, seeded with
this case's rule, so the passage justifying the case is one click away. Each
result names the engine that found it; if Cortex Search is unavailable the app
falls back to Snowflake's lexical `SEARCH()` and *says so on screen* rather
than returning nothing.

### Tables and features
`CASE_REGISTRY`, `CASE_EVIDENCE`, `AUDIT_EVENT`, all four P360 dynamic tables,
`CONF.CONF_LAB_RESULT` / `CONF_MEDICATION` / `CONF_DIAGNOSIS` /
`CONF_CLAIM_LINE` / `CONF_PHARMACY_FILL` / `CONF_PERSON_XWALK`,
`RULES.SAFETY_RULE`, `CONF.DOC_CHUNK`. Features: masking policies, a SQL UDF
for the reveal check, `AI_COMPLETE`, Cortex Search, dynamic tables.

### Real or not

| Element | Verdict |
|---|---|
| Verdicts and citations | **REAL.** Computed by the reconciler in SQL, 16 golden-patient assertions cover it. |
| Record ids (`ORD-000044`, `FLL-000604`) | **REAL CODE / INVENTED DATA.** The ids are synthetic; the join that surfaces them is real. |
| Break-glass reveal | **REAL.** Policy-enforced and audited. |
| Cited answer | **REAL.** Live `AI_COMPLETE` on claude-sonnet-5, from a SQL-assembled bundle. |
| Cortex Search | **REAL.** Service `DOC_SEARCH` exists; the screenshot shows it labelled *semantic*. |
| Lab and medication timelines | **REAL — and this label was wrong before.** I first wrote "demo-shaped, not a clinical-grade chart", which implied a chart with something faked in it. There is no chart: both are lists queried per person from `P360_LAB_TIMELINE` and `P360_MEDICATION_TIMELINE`, each row carrying its own source record id. Nothing is hardcoded. The lab list deliberately shows results detection **cannot** count — those tagged `UNMAPPED`, whose test name is absent from the controlled vocabulary — which is what lets a reviewer correctly dismiss a case the engine had to raise. |

---

## Tab 3 — Intake

### What you see
Four counters (files staged, documents loaded, section chunks, proposals
pending, blocked) and three sub-tabs: **Staging area**, **Extraction engine**,
**Ingest log**. A **Run intake** button and a **Re-read unchanged files**
checkbox. Then one card per document with its chunk / proposal / active-rule
counts and load time.

### What happens internally
This is the pipeline that turns a PDF into a rule proposal:

1. **Stage.** PDFs live in `RAW.DOC_STAGE`, a Snowflake internal stage with
   server-side encryption and a **directory table**. The staging list is read
   from the directory table, so the screen shows what the account actually
   holds — not a list the app keeps.
2. **Parse.** `AI_PARSE_DOCUMENT` in `LAYOUT` mode turns the PDF into text and
   sections. The parser mode is a config row (`CONF.DOC_PARSER_CONFIG`), so the
   same code can run `COPY INTO` over plain text if Cortex is unavailable — and
   the page states which mode is live.
3. **Chunk.** `CONF.SP_CHUNK_DOCUMENT` splits on headings into
   `CONF.DOC_CHUNK`. Title and publication date are pulled from document front
   matter first, falling back through two date patterns to the ingest date.
4. **Extract.** `RULES.SP_EXTRACT_PROPOSALS` calls `AI_COMPLETE` per chunk. The
   raw model response is stored in `RULES.EXTRACTION_RUN` **before** parsing,
   with a `PARSED_OK` flag — because a silent JSON parse failure once looked
   exactly like "this document has no requirement" and quietly lost two
   documents.
5. **Resolve.** `RULES.V_PROPOSAL_RESOLVED` maps the model's free text
   ("potassium") onto governed vocabulary (`LAB-K`) and reports what it cannot
   resolve, rather than guessing.

**Idempotency:** `COPY INTO` keeps its own load history, so a file already
ingested is skipped, not duplicated. The checkbox exists to force a re-read.

**Nothing on this page can put a rule into force.** It stops at `PROPOSED`.
Approval lives on the Rule library, on purpose.

### Tables and features
`RAW.DOC_STAGE` (stage + directory table), `RAW.RAW_DOC_FILE`, `CONF.DOC_CHUNK`,
`CONF.DOC_INGEST_LOG`, `CONF.DOC_PARSER_CONFIG`, `CONF.V_DOC_STAGE_FILES`,
`RULES.EXTRACTOR_CONFIG`, `RULES.PROMPT_TEMPLATE`, `RULES.EXTRACTION_RUN`,
`RULES.RULE_PROPOSAL`. Features: internal stage, directory table,
`AI_PARSE_DOCUMENT`, `AI_COMPLETE`, `COPY INTO` + load history, a Python UDF,
stored procedures, `SPLIT_TO_TABLE`.

### Real or not

| Element | Verdict |
|---|---|
| The PDFs in the stage | **REAL CODE / INVENTED DATA.** Real PDFs, really staged, really parsed by Cortex. The drug names CardioZen, Renuvex and Hepatrol are invented and every document carries a disclaimer. |
| `AI_PARSE_DOCUMENT` | **REAL.** The PDF of record is parsed by Cortex, not substituted with a text file. |
| Rule extraction | **REAL.** All four active rules were extracted by claude-sonnet-5. **Zero were hand-written** — provable in one query. |
| Two distractor documents | **REAL.** `SAFETY_DOC_009` and `_011` correctly produce **no** proposals. A pipeline that finds a rule in everything is not working. |
| The second extractor | **REAL.** A pattern-based Python UDF runs independently, and its agreement is one of the nine corroboration checks. |

---

## Tab 4 — Rule library

### What you see
Two sub-tabs. **Active library**: one card per rule — the drug/condition/test
triple, the quoted phrase and the interval it became, the citation, the
effective date, who approved it, `N of M document checks passed at approval`,
open case count, an **In force** toggle with a reason box, and a **Source
passage** expander. **Proposals awaiting approval**: the extraction engine
banner, then one card per pending proposal with the corroboration figure, the
nine-check breakdown, grace days, and **Approve** / **Reject**.

### What happens internally

**Approval** calls `RULES.SP_APPROVE_PROPOSAL`, which inserts a new
`SAFETY_RULE` version (rules are immutable — a correction is a new version,
nothing is edited in place), snapshots the corroboration into the
`RULE_APPROVED` audit event, and supersedes the prior version where the
proposal says so. The corroboration is snapshotted because the view is computed
*live*: once a document is re-ingested, the evidence as it stood at approval
time is gone, and "what did the reviewer see when they approved this?" has a
right answer.

**The In force toggle** is the Outlook-rules idea you asked for. It calls
`RULES.SP_SET_RULE_ENABLED`, which needs a reason to pause. The important
design point is *where the gate sits*: in the `MERGE` that creates cases, not
in the dynamic table. That is what makes your constraint hold — **pausing a
rule stops new cases and leaves every open case exactly as it was.** A test
asserts it (`tests/test_rule_toggle.sql`, 17 checks) and the paused banner on
screen says how many open cases are unaffected.

Pausing is an **operational** switch, not a withdrawal: the rule stays
`APPROVED` and `ACTIVE`, so a revised interval still supersedes it as a new
version.

**The corroboration figure** — the part you pushed on twice. Nine deterministic
checks run against the source document *before* a reviewer sees the proposal:

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
| 1 | the interval is inside the plausible 7–730 day range | weak |

Read the section on the figure below before you demo it — the design answers a
specific objection you raised and the answer is the interesting part.

### Tables and features
`RULES.RULE_PROPOSAL`, `RULES.SAFETY_RULE`, `RULES.V_PROPOSAL_RESOLVED`,
`RULES.V_PROPOSAL_CORROBORATION`, `RULES.V_RULE_STATE`, `CASES.AUDIT_EVENT`,
`CONF.DOC_CHUNK`. Features: Python UDF (`INTERVAL_FROM_PHRASE`), stored
procedures, a stream on `SAFETY_RULE`, `MERGE` with multiple matched branches.

### Real or not

| Element | Verdict |
|---|---|
| Four active rules, AI-extracted | **REAL.** RUL-001 90d, RUL-002 90d, RUL-003 **84d**, RUL-004 **42d**. |
| Interval arithmetic | **REAL, and it matters.** 12 weeks = 84 days, six weeks = 42. Under 30-day-month arithmetic two of the four would be wrong (90 and 45). |
| Versioning and supersession | **REAL.** DOC_008 revises DOC_007's interval from 90 to 60 days and the pending proposal says `supersedes RUL-001`. |
| The In force toggle | **REAL.** 17 tests, including that a paused rule leaves open cases untouched. |
| The nine checks | **REAL.** Deterministic SQL plus a Python UDF, 29 tests. |
| Every real proposal scoring 9 of 9 | **TRUE, AND WORTH SAYING OUT LOUD.** See below. |

---

## The corroboration figure — read this before you demo it

You asked for a confidence score three times. What is on screen is a score, but
not the kind you would get by asking a model how sure it is. Both halves of
that sentence matter.

**Why not a model confidence score.** An LLM asked "how confident are you,
0–100?" emits a plausible-looking token, not a probability. Its correlation
with being correct is unmeasured. Printing `0.92` next to a drug-safety rule
implies a *measured* ninety-two percent, and a reviewer who sees 0.95 stops
reading — which destroys the only safety mechanism the product has.

**What the number is instead.** The share of the nine deterministic document
checks that passed, weighted. Every point traces to a verifiable fact about the
source text. The card lists all nine checks with their weights, so you can add
the ticks, divide by the applicable total, and reproduce the figure by hand. A
test asserts the ticked weights recompute the displayed percentage *exactly*,
so the number and its explanation cannot drift apart.

**Your objection — "how can anything be 100% certain" — was right, and it
changed the screen.** A bare `100%` reads as certainty however the caption is
worded. So the headline number is gone. The card now leads with **"9 of 9
checks passed"**, a **four-step rating scale** showing where this proposal sits
among the possible outcomes (Contradicted → Not corroborated → Partly
corroborated → Fully corroborated), and a sentence saying in words what full
marks does *not* mean:

> Every check that can be run mechanically passed. That is corroboration, not
> certainty — these checks confirm the document says what the proposal claims,
> and say nothing about whether the guidance itself is right for a patient.

The proportion moved into a **segmented meter**, one segment per check, width
proportional to weight — so the picture and the checklist beneath it are
literally the same nine things. It is a meter rather than the pie you asked
for because a single ratio against a limit is a meter's job; a two-slice pie is
the standard wrong answer to it. The fill carries severity and failures are
drawn as neutral track, never green-beside-red — that is the exact pair
deuteranopia collapses, so a pass/fail meter coloured that way is unreadable
for roughly one man in twelve.

**The weighting was wrong the first time and a test caught it.** With the
strong checks at 3 apiece, a proposal whose quoted phrase was **not in the
document at all** still scored 85% — it had lost only one check of nine. But
that one check is the fabrication detector: the quoted phrase is what gets
shown to a clinician as the reason the rule exists. The two gates now carry 10
each, so failing either drops the number *and* sets the band to
UNCORROBORATED, and the colour follows the verdict rather than the number.

**The caveat you must say in the demo.** All five real proposals currently
score 9 of 9. That is honest — these five extractions are correct — but a badge
that is always green teaches a reviewer nothing. The evidence that the score
*can* fall lives in the test suite, which plants a broken proposal per failure
mode: a paraphrased phrase, an interval contradicting its own quote, a citation
to a section that does not exist, a self-flagged extraction. Each is caught
*and named in words*. **Show that test output.** It is more persuasive than
five green cards.

---

## Tab 5 — Operations

### What you see
Four sub-tabs: **Pipeline**, **Data quality & governance**, **Search the safety
corpus**, **Governed analytics**. The Pipeline tab shows five counters, the
nightly schedule state, **Run pipeline now**, **Enable schedule**, **Run this
rule**, and a run history table with trigger, whether there was new data, the
case count before → after, evidence rows, duration and outcome.

### What happens internally
**Run pipeline now** calls `CASES.SP_RUN_PIPELINE`: refresh the dynamic tables,
`MERGE` candidates into `CASE_REGISTRY` (gated on rule enablement), reconcile
evidence, seal the audit chain. Every run is logged, which is why the history
shows real durations — 11–13 seconds — and honest outcomes including
`net case change 0 (1 rule(s) paused)`.

**The schedule** is task `T_HEALTHONE_PIPELINE`, `CRON 0 6 * * * UTC`. It ships
**suspended** and the screen says so, because a task is the one thing here that
can spend credits unattended. It exits early when no clinical data changed,
using `SYSTEM$STREAM_HAS_DATA` over the four streams.

**Data quality & governance** surfaces the two data metric functions attached
to `CONF_LAB_RESULT` — `DMF_FUTURE_DATED` and `DMF_UNMAPPED_LAB_PCT` — plus the
three object tags. The unmapped-lab metric is not decoration: 7 of the 291 lab
results have test names deliberately absent from the vocabulary, so the metric
has something real to report and the case screen shows those results separately
rather than silently dropping them.

**Governed analytics** queries the semantic view `P360.HEALTHONE_360`, so a
business question lands on a governed layer with defined facts and dimensions
rather than on raw tables.

### Real or not

| Element | Verdict |
|---|---|
| Pipeline runs and timings | **REAL.** Nine logged runs with real durations. |
| The nightly task | **REAL, DELIBERATELY SUSPENDED.** It exists with a real CRON; it is off to protect credits, and the UI says "suspended" rather than implying it runs. |
| Manual refresh button | **DEMO-SHAPED.** Dynamic tables have a 60-second minimum lag; a demo cannot wait, so refresh is a button. Production would let the lag do its job. |
| Streams / early exit | **REAL.** Four streams, `SYSTEM$STREAM_HAS_DATA` guard. |
| Data metric functions | **REAL.** Verified attached today. |
| Semantic view | **REAL.** Created 29 Aug, exists as `P360.HEALTHONE_360`. |
| Free-text assistant Q&A | **NOT BUILT.** First on the documented cut list. Retrieval and the cited answer cover the demo need. |

---

## Tab 6 — Audit trail

### What you see
An append-only log: when, event, actor, subject, detail. Rule approvals, rule
pauses, queue refreshes, pipeline runs, reveals, dispositions.

### What happens internally
`CASES.AUDIT_EVENT`, append-only, **hash-chained** — each row carries a hash
over its own content plus the previous row's hash, sealed by
`CASES.SEAL_AUDIT_CHAIN()`. The app can verify the chain in place, so tampering
shows up as a broken link rather than as nothing.

Note what the actor column shows: `AMANANAND1701` for real approvals and
pauses, `test-harness` for events written by the test suites, `system:task` for
scheduled runs. The log does not pretend the test events were human ones.

### Real or not

| Element | Verdict |
|---|---|
| The chain | **REAL.** Hashes computed in SQL, verifiable in the app. |
| Approvals recorded | **REAL.** Four rule approvals, each carrying its corroboration snapshot. |
| Actor attribution | **REAL, and honest.** Test-written events are labelled as such. |
| Tamper-evidence | **REAL but not tamper-*proof*.** A chain detects modification; it does not prevent someone with ACCOUNTADMIN from rewriting the table and re-sealing. Production would need an external anchor. |

---

---

## The full platform surface — every Snowflake and Cortex feature used

Aman asked for this explicitly, and he is right that it scores: a judge cannot
credit a feature they cannot see. **24 features**, each verified against the
account or against a real call site in the repo before it was allowed onto this
list or onto a slide.

### Cortex AI — 5

| Feature | Where it is used | Verdict |
|---|---|---|
| `AI_COMPLETE` (claude-sonnet-5) | Rule extraction from document chunks; the cited answer on a case | **REAL** |
| `AI_PARSE_DOCUMENT` (LAYOUT mode) | The PDF of record in `RAW.DOC_STAGE` → text and sections | **REAL** |
| Cortex Search service `DOC_SEARCH` | Semantic retrieval over the safety corpus, seeded with the case's rule | **REAL** |
| `EMBED_TEXT_768` (`snowflake-arctic-embed-m`) | The embedding model behind Cortex Search; entitlement probed explicitly in `sql/26` | **REAL** |
| Cross-region inference (`CORTEX_ENABLED_CROSS_REGION`) | Mandatory — every Claude model is cross-region only from this region | **REAL** |

### Governance and security — 7

| Feature | Where it is used | Verdict |
|---|---|---|
| Conditional masking policies (two-argument) | `NAME`, `DOB`, `PATIENT_ID`, `MEMBER_ID` on `P360_PERSON` — the second argument is the person id, which is how per-case break-glass works | **REAL** |
| **Tag-based masking** | A masking policy attached to a *tag*, so any column carrying that tag inherits protection. This is the one that answers "show me every column holding patient data and prove it is protected" — column-by-column attachment cannot | **REAL** |
| Object tags | `SEC.DATA_SENSITIVITY`, `SEC.PAYER_IDENTIFIER`, `SEC.SOURCE_SYSTEM_TAG` — data classification | **REAL** |
| Data metric functions | `DMF_FUTURE_DATED`, `DMF_UNMAPPED_LAB_PCT`, attached to `CONF_LAB_RESULT` | **REAL** |
| RBAC roles + key-pair service user | `HO_ADMIN` / `HO_REVIEWER`; the reviewer role was tested through `HO_PUBLIC_APP`, a service user holding *only* that role | **REAL** |
| Break-glass identity reveal | `SEC.SP_REQUEST_REVEAL` writes an audit event and grants a reveal scoped to one case; the masking policy reads that grant | **REAL** |
| Hash-chained audit trail (`SHA2`) | `CASES.AUDIT_EVENT` — per-row hash over content plus the previous hash, sealed by `SEAL_AUDIT_CHAIN()` | **REAL** (tamper-*evident*, not tamper-proof) |

### Data engineering — 7

| Feature | Where it is used | Verdict |
|---|---|---|
| Dynamic tables | 5 of them. `SCHEDULER = DISABLE` with explicit `REFRESH_MODE = FULL` — deliberate, so a demo refresh is instant and nothing recomputes unwatched | **REAL** |
| Streams | 4 (`STR_LAB_RESULT`, `STR_MEDICATION`, `STR_DIAGNOSIS`, `STR_SAFETY_RULE`), all DELTA | **REAL** |
| `SYSTEM$STREAM_HAS_DATA` | The nightly task exits early when no clinical data changed — the credit guard | **REAL** |
| Task + CRON | `T_HEALTHONE_PIPELINE`, `CRON 0 6 * * * UTC`. **Ships suspended** and the UI says so | **REAL, deliberately off** |
| Internal stage with `SNOWFLAKE_SSE` + directory table | `RAW.DOC_STAGE`. SSE is a hard prerequisite for `AI_PARSE_DOCUMENT`; the directory table is why the staging screen shows what the account actually holds | **REAL** |
| `COPY INTO` with load history | Idempotent ingest — a file already loaded is skipped, not duplicated | **REAL** |
| Python UDFs (runtime 3.11) + SQL UDFs | 2 Python (`INTERVAL_FROM_PHRASE`, `EXTRACT_RULES_PATTERN`) and 7 SQL. The interval UDF re-derives "12 weeks" to 84 days independently of the model | **REAL** |
| Stored procedures, `EXECUTE AS OWNER` | 17 of them — the pipeline, approval, reveal, ingest and extraction paths | **REAL** |

### Serving, analytics and cost — 5

| Feature | Where it is used | Verdict |
|---|---|---|
| Streamlit in Snowflake (warehouse runtime) | The entire app, deployed into the account | **REAL** |
| Semantic view | `P360.HEALTHONE_360` — the Governed analytics tab queries it with `SELECT * FROM SEMANTIC_VIEW(...)` | **REAL** |
| Native `SEARCH()` | Lexical fallback if Cortex Search is unavailable. Each result **names the engine that found it**, so a fallback is visible rather than silent | **REAL** |
| Resource monitors | `HO_ACCOUNT_CAP` at 120 credits account-wide, plus `HO_BUDGET` per warehouse; all warehouses XSMALL, auto-suspend 60s, 900s statement timeout | **REAL** |
| `ACCOUNT_USAGE` metering views | Credit spend read from `WAREHOUSE_METERING_HISTORY` and surfaced in the app | **REAL** |

### What is NOT used — say this before a judge finds it

| Feature | Status | Why |
|---|---|---|
| **Cortex Analyst** | **NOT USED.** | This is the one worth being precise about. The app answers business questions from the **semantic view** using `SELECT * FROM SEMANTIC_VIEW(...)` with pre-declared question specs. That is the semantic-view feature, *not* Cortex Analyst — Analyst is a separate REST service that takes a semantic model and does natural-language-to-SQL. We have exactly the input Analyst wants, so it is the cheapest genuine feature still available; it was not added because it needs `send_snow_api_request` plumbing from the app and untested plumbing on submission night is a worse risk than a missing feature. **Do not let anyone describe the Governed analytics tab as Analyst.** |
| Cortex Agents | **NOT USED.** | Documented constraint: it needs the container runtime, and the app is on the warehouse runtime. Ruled out on day one, not forgotten. |
| `AI_CLASSIFY`, `AI_FILTER`, `AI_AGG`, `AI_EXTRACT`, `AI_SENTIMENT` | **NOT USED.** | Grepped for; no call sites. They would be feature-padding — nothing in the product needs them, and a rule extractor that classifies for the sake of it is worse, not better. |
| Row access policies | **NOT USED, and never written.** | Second on the documented cut list. Column masking *is* attached and enforced — the two must not be conflated. |
| Time travel / cloning | **NOT USED.** | No call sites. Rule immutability is achieved by versioning rows, not by relying on retention. |
| Snowpark | **NOT USED.** | The app uses the Python connector locally and the SiS session in the account. Python logic lives in UDFs, where it is closer to the data. |
| Iceberg / external tables / Snowpipe | **NOT USED.** | One account, internal stage, no external object store in scope. |

### The honest framing for a judge

Twenty-four features is not the interesting number. The interesting claim is
that **every one of them is load-bearing**: remove the masking policies and PHI
leaks; remove the Python interval UDF and the corroboration check that catches
a hallucinated interval disappears; remove the directory table and the staging
screen becomes a list the app made up; remove the resource monitor and an
unattended task can empty the account. Nothing on that list is there to be
counted.

---

## The honest gaps — what a sharp judge would find

Say these before they ask. Each one is a deliberate decision with a reason, and
owning them is stronger than being caught.

1. **`coco/` is empty.** The CoCo-owned sessions — the data-model review,
   semantic view authoring in CoCo, test runs launched from CoCo, the reusable
   skill — are planned and have **not run**. Everything in the account was
   deployed and tested from a CLI session against one Snowflake account, which
   is real and reproducible from the repo, but it is not the same claim. The
   folder is empty rather than backfilled on purpose: an artifact written after
   the fact would prove nothing. **This is the single biggest scoring gap and
   the only one you can still close tonight.**

2. **Cortex Analyst is not used, and the Governed analytics tab is not it.**
   The tab queries the semantic view directly with `SEMANTIC_VIEW()` SQL. We
   have the exact input Analyst consumes, so this is the cheapest real feature
   still on the table — and it was left out because untested REST plumbing on
   submission night is the worse risk. If a judge asks whether you used
   Analyst, the answer is no, followed by the semantic view you did use.

3. **No row access policy exists.** Zero, confirmed by `SHOW ROW ACCESS
   POLICIES` today. It was second on the documented cut list and it was cut.
   Column masking *is* attached and working — do not conflate the two. If asked
   about row-level security, the answer is "column masking is enforced, row
   access was scoped out."

4. **All data is synthetic and the drugs are invented.** This is a feature, not
   an apology: the alternative on a trial account would have been real patient
   data. The 8 golden test patients exist precisely so the detection logic can
   be proven against known-correct answers.

5. **Every proposal scores 9 of 9.** Covered above. Show the test output that
   makes the score fall.

6. **The demo refreshes by button.** Dynamic table minimum lag is 60 seconds.
   Named, not hidden.

7. **The audit chain is tamper-evident, not tamper-proof.** Detection, not
   prevention.

8. **The app was once deployed a full session behind the repo.** Worth knowing
   because it is the failure mode most likely to bite you again: a change is
   not done until the deployed app carries it. `submission/SUBMISSION_CHECKLIST.md`
   now has the deploy step in it.

---

## What would have to change for real patients

Not asked for, but this is the question a judge with a healthcare background
will ask, and having an answer is worth more than another feature.

| Area | The gap |
|---|---|
| Vocabulary | Invented test names would become LOINC; drugs would become RxNorm. The mapping layer exists (`CONF.REF_LAB_TEST` plus `CONF.REF_LAB_TEST_SYNONYM`) — the content changes, not the design. |
| Identity | The crosswalk resolving patient and member ids to one person is synthetic. Real master-data management is a programme, not a table. |
| Clinical sign-off | Every rule would need a named clinical owner and a governance committee record. The approval mechanism is already there; the process around it is not. |
| Extraction validation | The nine checks test whether the *document supports the proposal*. They cannot test whether the guidance is clinically appropriate. That stays human, permanently. |
| Row-level security | Would become mandatory, not a cut item. |
| Audit anchoring | The hash chain would need anchoring outside the account. |
| Scale | Detection is set-based SQL over dynamic tables, so it scales with warehouse size. Extraction is per-chunk `AI_COMPLETE` and would need batching and a cost model. |

The honest summary: **the gap to production is real data, clinical governance
and identity management — not architecture.** The governance layer that usually
gets bolted on last is already here.

---

## One-paragraph version, if you only get thirty seconds

Safety guidance arrives as prose in a PDF. Cortex reads the PDF inside
Snowflake and proposes a monitoring rule, quoting the sentence it read. Nine
deterministic checks test that quote against the document before a human sees
it. A named reviewer approves; nothing becomes a rule without that. Detection
is then literal SQL over a Patient & Member 360 — no score, no model, no
ranking — and every case shows the factors that raised it, the rule, and the
sentence behind the rule. Evidence is reconciled as AGREES, CONFLICTS or
MISSING with citations, and the system never picks a winner. All of it runs in
one Snowflake account with 162 automated checks passing and five credits spent.
The data is synthetic; the machinery is not.
