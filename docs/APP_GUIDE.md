# HealthOne 360 — the complete guide

**Read this before the app or the demo.** It is written for the whole team:
Part 1 needs no technical background at all, Part 2 explains the invented data,
Part 3 explains exactly where the AI is and what it is forbidden from doing, and
Parts 4–6 are for whoever has to maintain it.

Every medical term is explained the first time it appears. Every number in here
came from the live system, not from memory.

---

# Part 1 — What this is, for anyone

## The problem, in one story

A hospital safety committee meets and decides something important:

> *"Patients taking CardioZen who also have chronic kidney disease should have
> their serum potassium checked at least every three months."*

Two terms, plainly:

- **CardioZen** — an invented heart medicine. We made the name up (more on that
  in Part 2).
- **Serum potassium** — a routine blood test. Potassium is a mineral in the
  blood; if this drug pushes it too high or too low it becomes dangerous, so the
  committee wants it watched.

They publish that sentence in a PDF and email it round. **The knowledge now
exists.** And almost nothing happens.

Why not? Three reasons, and each one is a real obstacle:

**1. A sentence is not an instruction a computer can follow.** "At least every
three months" has to become "90 days" before any system can check it. And the
wording varies — "quarterly", "at 12-week intervals", "every six weeks". A
person has to read each one and decide what number it means. *(12 weeks is 84
days, not 90. That difference is six days of unmonitored patient, and it is the
kind of mistake a tired human makes at 5pm.)*

**2. The evidence is scattered across four systems that disagree.** To know
whether one patient is being monitored properly you must check:

| System | The question it answers |
|---|---|
| Hospital record (EHR) | Is the drug prescribed? Is the kidney condition recorded? |
| Pharmacy | Is the patient actually *collecting* the medicine? |
| Insurance claims | Was the condition confirmed by a specialist? |
| Laboratory | Was the blood test done, and when? |

These four do not agree with each other, and they identify the same human being
by different ID numbers.

**3. Nobody can show their work.** A reviewer spends 30–60 minutes clicking
between systems, reaches a conclusion, and leaves no record of what they
checked. Ask again in six months and the whole thing is repeated.

## What HealthOne 360 does about it

It carries that sentence from the PDF all the way to the specific patients who
are affected — and it shows its reasoning at every step.

```
   A PDF arrives                   ┌─────────────────────┐
   with a sentence       ────────► │  1. Read the PDF    │  AI
   in plain English                └─────────────────────┘
                                             │
                                             ▼
                                   ┌─────────────────────┐
                                   │  2. Draft a rule    │  AI
                                   │     from the words  │
                                   └─────────────────────┘
                                             │
                                             ▼
                                   ┌─────────────────────┐
                                   │  3. Check the draft │  NOT AI
                                   │     against the PDF │  (9 checks)
                                   └─────────────────────┘
                                             │
                                             ▼
                            ╔═════════════════════════════════╗
                            ║  4. A NAMED HUMAN APPROVES IT   ║
                            ║     Nothing proceeds without    ║
                            ║     this. This is the product.  ║
                            ╚═════════════════════════════════╝
                                             │
                                             ▼
                                   ┌─────────────────────┐
                                   │  5. Apply it to     │  NOT AI
                                   │     every patient   │  (plain arithmetic)
                                   └─────────────────────┘
                                             │
                                             ▼
                                   ┌─────────────────────┐
                                   │  6. A human decides │
                                   │     on each case    │
                                   └─────────────────────┘
```

The sentence to remember, because every design decision follows from it:

> **AI proposes → a human approves → ordinary arithmetic applies → a human
> decides.**

## Following one real patient all the way through

This is an actual case from the running system, not an example we invented for
the document.

**Step 1 — the document.** `SAFETY_DOC_007`, a PDF sitting in Snowflake,
section 3, contains: *"serum potassium should be checked at least every three
months for the duration of therapy."*

**Step 2 — the AI drafts a rule.** Snowflake Cortex reads that PDF and proposes:

| Field | Value |
|---|---|
| Drug | CardioZen |
| Condition | chronic kidney disease |
| Required test | serum potassium |
| Interval | **90 days** |
| Quoted from | *"checked at least every three months for the duration of therapy"* |

Note the last row. **The AI must quote the sentence it read.** It cannot just
hand over a number — it has to show where the number came from.

**Step 3 — nine checks test the draft.** No AI involved. Among them: does that
section actually exist in the document? Is that phrase *word for word* in it?
Does "three months" independently work out to 90 days? Does a completely
separate, non-AI extractor reach the same answer? All nine passed.

**Step 4 — a human approves.** A named reviewer clicks Approve. That approval,
with their name and the time, is written to a tamper-evident log. Until this
moment nothing could affect a single patient.

**Step 5 — arithmetic finds the affected patients.** Plain SQL, no AI: *who is
on CardioZen, has chronic kidney disease, and has no potassium result in the
last 90 days (+7 days' grace)?* One of the 33 answers is patient
**PT-579488** — the system shows a code, not a name, and we will come back to
why.

**Step 6 — what the reviewer sees.** Not a score. Not "87% risk". This:

> **309 days since the last qualifying result.**
> Rule requires every 90 days (+7 grace).

Both numbers are checkable by hand. Then the evidence, gathered from those four
disagreeing systems:

| Verdict | What it means here |
|---|---|
| ✅ **AGREES** | The kidney condition is in the hospital record *and* a specialist insurance claim. Two independent sources, same story. |
| ⚠️ **CONFLICTS** | The hospital says CardioZen is active. The pharmacy says nothing has been collected in 90 days. **The system shows both and refuses to pick.** |
| ❌ **MISSING** | No potassium result between 2026-05-27 and 2026-09-01. Said out loud as a finding — not left as an empty box. |

**That CONFLICTS row is the most important thing in the product.** A lazier
system would average the two, or trust the newer record, and tell the reviewer
"patient overdue". But if this patient quietly stopped taking the drug, the
monitoring rule may not apply at all. The honest answer is *"these two systems
disagree, and a human needs to resolve it."* So that is what it says.

Finally the reviewer records a decision — escalate, request more evidence, mark
reviewed, or dismiss with a reason — and that decision goes into the log too.

## Why the patient is called PT-579488

Patient names, dates of birth and hospital ID numbers are **hidden by default**,
and not by the app choosing to hide them. The protection is inside the database
itself, attached to those columns. Even if the application had a bug, it could
not display them.

A reviewer who genuinely needs the name clicks **Reveal patient identity**. That
unlocks it for that one case, and writes a log entry saying who looked and why.
This is called *break-glass* access: possible, deliberate, recorded.

---

# Part 2 — The data we invented, and why

**Everything in this system is made up.** No real patient, no real medicine, no
real safety guidance. That is a deliberate choice, not a limitation: this was
built on a free trial account for a hackathon, and using real medical records
would have been the actual problem.

## The invented medicines

| Name | Why it exists |
|---|---|
| **CardioZen** | A heart drug needing potassium monitoring |
| **Renuvex** | Needs kidney-function monitoring (serum creatinine) |
| **Hepatrol** | Needs liver monitoring (ALT, a liver enzyme) |

The names are invented on purpose. If we had used a real medicine, someone might
read our synthetic safety document and believe it — and misquoting real medical
guidance is genuinely harmful. Every document carries a disclaimer saying so.

## The people

**312 synthetic patients.** Most of them were generated randomly, which matters
more than it sounds: it means the cases in the queue *emerge from the data*
rather than being staged examples. That is why there are 33 cases and not one
carefully arranged demo.

**8 of the 312 are "golden patients"** — deliberately constructed so we know the
correct answer in advance. One is exactly one day inside the grace window; one
is exactly one day outside it. The automated tests assert those exact outcomes,
which is how we know the detection logic is right rather than merely plausible.

## The deliberate flaws

Real data is messy, so ours is too — on purpose:

- **7 lab results have test names the system does not recognise.** They exist,
  a human can see them, but the rule engine cannot count them. This creates
  cases a reviewer should *dismiss* — and a system that never produces a
  dismissible case is not being honest about reality.
- **The four systems disagree about some patients** (the CONFLICTS above). We
  built that in.
- **Two of the seven documents contain no monitoring rule at all.** The
  extraction correctly produces nothing from them. A pipeline that finds a rule
  in every document is broken.

## The documents

Seven safety documents, each as both a PDF (what the system actually reads) and
a markdown source. Two are distractors. One (`SAFETY_DOC_008`) deliberately
*revises* an earlier one — changing CardioZen potassium monitoring from 90 days
to 60 — so we can demonstrate that a new document supersedes an old rule rather
than silently conflicting with it.

## The fixed "today"

The system's idea of today is frozen at **2026-09-01**, stored in a table. Every
day-count is measured from there. Without this, "309 days overdue" would change
every morning and no test could ever assert an exact number.

---

# Part 3 — Where the AI actually is

This is the part people most want to know, and the part most easily
oversold. **Snowflake Cortex** is Snowflake's built-in AI. It runs *inside* the
database — no data is sent to an outside service, ever. There is no OpenAI key,
no external API call.

## The four places AI is used

| # | What it does | Cortex feature | Honest description |
|---|---|---|---|
| 1 | Reads the PDF | `AI_PARSE_DOCUMENT` | Turns a PDF into text **and section structure**. This is why we can say "section 3" rather than "somewhere in the document". |
| 2 | Drafts the rule | `AI_COMPLETE` with **claude-sonnet-5** | Reads a section and proposes drug + condition + test + interval, and must quote its source sentence. |
| 3 | Writes the case summary | `AI_COMPLETE` with **claude-sonnet-5** | Turns an evidence bundle into a readable paragraph. |
| 4 | Finds relevant passages | **Cortex Search** | Searches by *meaning*, not keywords — ask about "liver enzymes" and it finds the ALT requirement without that word appearing. |

## The four things AI is never allowed to do

This list is the product. Each of these is deliberately ordinary arithmetic:

1. **It never decides whether a case exists.** That is a date subtraction.
2. **It never sets an evidence verdict.** AGREES / CONFLICTS / MISSING are SQL
   comparisons.
3. **It never puts a rule into force.** Only a named human does.
4. **It never sees who the patient is.** The summary in step 3 is written from a
   bundle carrying a code like PT-579488 — no name, no date of birth, no
   hospital ID is ever sent to a model.

## How the summary is fenced, specifically

Step 3 is the only place a model writes prose a reviewer reads, so it is
constrained hard:

- SQL assembles the evidence **first** — the rule, the day counts, every
  verdict. The model receives that and **cannot change it.**
- Whether the case exists at all was already decided before the model was
  called.
- The text is cached against a fingerprint of the evidence, not a clock. Change
  a verdict and the summary regenerates; nothing goes stale silently.
- The screen names which engine wrote it, so a template is never displayed as
  if a model had written it.

## Why the nine checks matter more than the AI

A model can produce a confident, well-formatted rule that is simply wrong — the
interval misread, the phrase paraphrased, the section invented. So before any
human sees a draft, nine checks run against the document:

| Weight | Check |
|---|---|
| **10** | The cited section exists in the document |
| **10** | The quoted phrase is in it **word for word** |
| 4 | The interval independently re-derives from the phrase |
| 4 | A separate non-AI extractor reaches the same answer |
| 2 | The drug is named in that section |
| 2 | The test is named in that section |
| 2 | The test maps exactly to the approved vocabulary |
| 2 | The extractor did not flag its own output as doubtful |
| 1 | The interval is within a plausible 7–730 day range |

The two 10-weight checks are the **fabrication detectors**. If a model invents a
quote, that is the failure that matters most, and failing either one drops the
score sharply *and* flags the proposal as uncorroborated.

**The score is labelled "document checks passed", never "confidence".** It
measures the document, not the model's opinion of itself. All five proposals
currently score 9 of 9, which is honest — and we say openly that full marks mean
*every mechanical check passed*, which is **corroboration, not certainty**.
Whether the guidance is clinically right for a patient is not something any
check here can answer.

---

# Part 4 — For engineers: the data, layer by layer

Strictly one-directional. No layer reaches backwards.

```
RAW      exact mirror of source systems, never edited          10 tables
 │       EHR patients/diagnoses/med-orders/labs/notes;
 │       plan members/claims/pharmacy fills; documents
 ▼
CONF     cleaned, typed, and identity resolved                 16 tables
 │       CONF_PERSON_XWALK is where a hospital patient id
 │       and an insurance member id become one PERSON_ID
 ▼
P360     the "360-degree view", as 4 dynamic tables
 │       P360_PERSON, P360_LAB_TIMELINE,
 │       P360_MEDICATION_TIMELINE, P360_ACTIVE_MEDICATION
 ▼
RULES    proposals and versioned rules                          5 tables
CASES    candidates, registry, evidence, audit                  7 tables
SEC      masking, reveal grants, assignments                    4 tables
```

**Why dynamic tables for P360:** the 360 is *derived*, so it should be declared
once and recomputed, not maintained by hand.

**Why ordinary tables for CASE_REGISTRY:** case state is *mutable* — a reviewer
dispositions it — and mutable state must never live in something that gets
recomputed from scratch.

Live counts: **312 people · 291 lab results (7 unmapped) · 7 documents ·
43 document sections · 4 active rules · 5 proposals · 33 open cases ·
80 evidence rows.**

## Input → processing → output, as calls

```
INPUT    RAW.DOC_STAGE          PDFs on an encrypted internal stage
         RAW.* (10 tables)      6,819 CSV rows via PUT + COPY INTO

PROCESS  1  AI_PARSE_DOCUMENT          PDF → text + sections
         2  CONF.SP_CHUNK_DOCUMENT     → CONF.DOC_CHUNK, one row per section
         3  RULES.SP_EXTRACT_PROPOSALS → RULES.RULE_PROPOSAL   (AI_COMPLETE)
         4  RULES.V_PROPOSAL_RESOLVED  free text → governed ids, or a refusal
         5  RULES.V_PROPOSAL_CORROBORATION   the nine checks
         ── HUMAN: RULES.SP_APPROVE_PROPOSAL → RULES.SAFETY_RULE
         6  CASES.SP_RUN_PIPELINE      → CASE_REGISTRY + CASE_EVIDENCE

OUTPUT   33 open cases, 80 evidence rows, 4 rules, an append-only audit chain
```

Steps 1–5 can run unattended. **Nothing between step 5 and step 6 happens
without a person.**

## Adding a document to the running system

1. `PUT` the PDF to `@HEALTHONE.RAW.DOC_STAGE`
2. `ALTER STAGE … REFRESH` so the directory table sees it
3. Press **Run intake** (or call `SP_INGEST_EXTRACT_ALL`)
4. Approve or reject the proposal it produces

Idempotent: `COPY INTO` keeps its own load history, so re-running skips files
already ingested rather than duplicating them.

---

# Part 5 — Tab by tab

### Review queue
The worklist: one row per open case, with the sentence explaining why it was
raised and an Investigate button.
**Reads** `CASES.CASE_REGISTRY` + `P360.P360_PERSON`, with
`SEC.PERSON_TOKEN()` producing the pseudonym.
The queue **never fetches a name** — PHI you do not query cannot leak through a
screenshot or a log.

### Case detail
The screen a reviewer works. Pick any open case from the **Case** dropdown at
the top, or arrive via Investigate. The dropdown is the navigation: choosing
another case loads it in place.

| Section | Reads |
|---|---|
| Person strip (masked) | `P360_PERSON` |
| Reveal identity | `SEC.REQUEST_PHI_REVEAL` |
| Why this priority | `CASE_REGISTRY.PRIORITY_FACTORS` |
| Governing rule + citation | `RULES.SAFETY_RULE` |
| The quoted phrase → the number | `SAFETY_RULE.INTERVAL_SOURCE_PHRASE` |
| Monitoring window | `WINDOW_START_DATE`, `DAYS_SINCE_REFERENCE` |
| **Evidence** | `CASES.CASE_EVIDENCE` |
| Cited answer | `CASE_NARRATIVE` + `AI_COMPLETE` |
| Document retrieval | Cortex Search `CONF.DOC_SEARCH` |
| Lab / medication timelines | `P360_LAB_TIMELINE`, `P360_MEDICATION_TIMELINE` |
| Record your decision | `CASE_REGISTRY` + `AUDIT_EVENT` |

### Intake
Staging area, extraction engine, ingest log. Reads the stage's **directory
table**, so the screen shows what the account actually holds rather than a list
the app keeps. **Nothing here can put a rule into force** — it stops at
`PROPOSED`.
The engine is *configuration, not code*: `RULES.EXTRACTOR_CONFIG` stores the
backend and model as data, so "which engine produced this rule?" is a query.

### Rule library
The human gate. **Active library** and **Proposals awaiting approval**, with the
nine checks, the meter and the rating scale.
Rules are **immutable and versioned** — a correction is a new version, never an
edit. Any approved rule can be **paused** with a reason; the pause gate sits in
the case merge, not the dynamic table, so **pausing stops new cases and leaves
every open case untouched.**

### Operations
Four sub-tabs: run the pipeline, data quality and governance, search the corpus,
governed analytics (a real Snowflake **semantic view**).
The nightly task **ships suspended** and the screen says so — a task is the one
thing that can spend credits unattended.

### Audit trail
Every consequential action, append-only, each row hashed over its own content
plus the previous row's hash. No role holds UPDATE or DELETE.
**Honest limit:** this buys *detection*, not prevention — an account admin could
take ownership and recompute. Production would stream these events off-platform
to write-once storage.

---

# Part 6 — What is real, and what is not

| | |
|---|---|
| **Real** | Cortex reading actual PDFs; Claude extracting the rules; Cortex Search; the masking policies; the audit chain; the nine checks; detection arithmetic; 162 automated tests |
| **Invented** | Every patient, every lab result, all three drug names, all seven documents |
| **Simplified for a demo** | Refresh is a button, not a schedule (a demo cannot wait 60 seconds); "today" is frozen so tests can assert exact numbers; judges need a Snowflake login because Streamlit in Snowflake has no anonymous access |
| **Cut, and we say so** | Row-level access policies. **Column masking is attached and working** — do not conflate the two |

## Check any of it yourself

```sql
-- every active rule, the model that extracted it, the human who approved it
SELECT r.RULE_ID, r.VERSION, r.INTERVAL_DAYS, r.DOC_ID, r.APPROVED_BY,
       p.MODEL_NAME
  FROM HEALTHONE.RULES.SAFETY_RULE r
  LEFT JOIN HEALTHONE.RULES.RULE_PROPOSAL p
         ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
 WHERE r.STATUS = 'ACTIVE' ORDER BY r.RULE_ID;

-- the nine checks, per proposal
SELECT DOC_ID, CORROBORATION_SCORE, CORROBORATION,
       CHECKS_PASSED, CHECKS_APPLICABLE, CHECKLIST
  FROM HEALTHONE.RULES.V_PROPOSAL_CORROBORATION;

-- evidence for one case, with citations
SELECT VERDICT, CLAIM_TEXT, EVIDENCE_REFS, SEARCHED
  FROM HEALTHONE.CASES.CASE_EVIDENCE
 WHERE CASE_ID = '<CASE_ID>' ORDER BY VERDICT;

-- PHI protection lives on the column, not in the app
SELECT POLICY_KIND, POLICY_NAME, REF_COLUMN_NAME
  FROM TABLE(HEALTHONE.INFORMATION_SCHEMA.POLICY_REFERENCES(
         REF_ENTITY_NAME => 'HEALTHONE.P360.P360_PERSON',
         REF_ENTITY_DOMAIN => 'TABLE'));
```

**162 automated checks:** 47 assertions · 16 detection golden · 17 document
intake · 17 rule toggle · 29 corroboration · 36 app smoke.

---

# Glossary

**Medical**

| Term | Meaning |
|---|---|
| Serum potassium | A blood test for potassium levels. Some heart drugs disturb it dangerously. |
| Serum creatinine | A blood test showing how well the kidneys are filtering. |
| ALT | A liver enzyme. High levels suggest liver stress. |
| Chronic kidney disease (CKD) | Long-term reduced kidney function. |
| PHI | Protected Health Information — anything identifying a patient. |
| Pharmacovigilance | Monitoring medicines for safety problems after release. |

**Snowflake**

| Term | Meaning |
|---|---|
| Cortex | Snowflake's built-in AI. Runs inside the database; data never leaves. |
| Dynamic table | A table defined by a query, which Snowflake recomputes for you. |
| Internal stage | File storage inside Snowflake. Our PDFs live here. |
| Directory table | A queryable index of files on a stage — so "what is staged?" is SQL. |
| Masking policy | A rule attached to a *column* that hides its value from roles that should not see it. |
| Semantic view | A governed layer defining facts and dimensions, so business questions do not touch raw tables. |
| Streamlit in Snowflake | The app runs on a Snowflake warehouse, beside the data. |
| CoCo CLI / Cortex Code | Snowflake's agentic command-line tool. Drives the demo end to end. |
