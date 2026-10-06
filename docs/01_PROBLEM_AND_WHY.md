# 01 — The Problem and the Why

This document is the connected reasoning behind the product. DECISIONS.md tells
you *what* was decided; this tells you *why*, as one argument. If a teammate or
judge asks "why did you do it that way?", the answer is in here.

## 1. The domain, from zero

You need exactly four healthcare ideas. Nothing else in this project requires
medical knowledge.

**A lab test** is a blood test. To us it is three fields: a test name, a date,
a numeric value.

**A chronic condition** (e.g., chronic kidney disease — CKD) is a long-term
diagnosis recorded once and then simply *true* about a patient. To us it is a
row in a diagnosis table with an onset date.

**A medication** can stress an organ over time. The safe way to prescribe some
drugs is therefore to re-check a specific lab on a schedule. Example logic: a
drug cleared by the kidneys, given to someone whose kidneys are already weak,
can accumulate — so check a kidney-related blood value every 90 days.

**A monitoring requirement** is that schedule, written as prose in a safety
document: *"patients taking Drug D who have Condition C should have Test T
checked every N days."* It is a sentence for humans that contains five
machine-checkable fields: drug, precondition, test, interval, effective date.

The car analogy that makes the whole product click: a monitoring requirement is
a service interval — "if you drive this model in dusty conditions, change the
filter every 5,000 km." Written in the manual, checkable by a computer, ignored
at your peril.

## 2. The failure we are attacking

Safety guidance is published continuously (regulators, drug manufacturers,
internal committees). In a typical organization the path from *guidance
published* to *our patients are actually checked against it* looks like:
document → email → committee meeting weeks later → IT ticket → a report built
months later against only one system → patients invisibly exposed in between.

Two structural causes:

1. **The knowledge is unstructured.** "Every three months", "quarterly", "at
   12-week intervals" — prose, not data. No system can act on it.
2. **The evidence is fragmented.** Proving one patient complies requires
   joining four systems: EHR (is the drug prescribed? is the condition
   diagnosed?), pharmacy (is the drug actually being collected?), claims (is
   the condition confirmed by care actually delivered?), labs (was the test
   done, and when?). Different systems, different identifiers.

And a third, human cause: when a case does surface, a reviewer spends 30–60
minutes swivel-chairing across systems, with no record of what was checked.

**The product thesis:** all three causes are addressable at once, on one data
platform. AI can structure the knowledge (it genuinely requires language
understanding — see §5). A governed 360 layer can unify the evidence. A
citation-first workflow can make the investigation fast and auditable.

## 3. Why a fictional payvider

HealthOne Group runs hospitals AND a health plan ("payvider"). This is not
world-building for fun — it is the one corporate structure where a single
organization *legitimately* holds both the clinical record (provider side) and
claims + pharmacy fills (payer side) about the same person, under one
governance roof. It makes "Patient 360 + Member 360, joined" plausible without
hand-waving about data sharing agreements. It also gives us the identity
problem honestly: the hospital knows P1024, the plan knows M8842, and someone
must assert they are the same human (see §8).

## 4. Why the hero is a monitoring gap (and not "why was this patient admitted?")

Our first idea was a generic investigation question. It died in review because
a judge can answer it with "so you joined admissions to notes — big deal." The
test we now apply to every feature: **is the finding impossible from any single
source?** The monitoring gap passes it four ways:

- The *rule* exists only because a **document** was understood (unstructured).
- The *drug* is proven active by **EHR + pharmacy agreeing** (two structured
  sources).
- The *condition* is confirmed by **diagnosis + claims** (two more).
- The *gap* is an **absence** in the lab table, computed against an interval
  that came from the document, anchored to dates from three other tables.

No single system, and no plain RAG pipeline, can produce that finding. That is
the entire differentiation argument, and every demo beat exists to make one
piece of it visible.

## 5. Why the AI step is real (and exactly one step)

The one genuinely hard AI task: turning varied prose into the same structured
rule, reliably. Our own document corpus proves the variance on purpose —
"every three months", "quarterly", "at 12-week intervals", each in different
document layouts, with distractor paragraphs naming lab tests that are
explicitly NOT requirements.

Two traps we designed against, because we fell into one of them:

- **12 weeks is 84 days, not 90.** The team assumed all three phrasings meant
  90. A system that silently rounds a number inside a safety rule is
  indefensible. The normalization policy is written, literal, and tested; the
  approval screen shows raw phrase → normalized value so the human owns the
  interpretation.
- **Restraint is a feature.** A document with no requirement must yield no
  rule. Extraction that always finds something is inventing obligations. The
  corpus includes a distractor document; the correct output is empty.

Everything downstream of extraction is deterministic SQL. This is the
architecture's moral center: **language understanding is the AI's job;
deciding whether a case exists is arithmetic's job.** If a judge asks "where
could the AI hallucinate a patient into the queue?" the answer is: nowhere —
the AI never touches case creation.

## 6. Why human approval sits between extraction and activation

Three reasons, in increasing order of importance:

1. **Demo determinism.** Extraction runs at ingest, not live on stage; the live
   beat is *approving* a fresh document, which is rehearsed and cannot
   hallucinate.
2. **It is what a regulated organization would demand.** "AI decides the rules"
   is unshippable in healthcare; "AI proposes, named human approves, versioned
   forever" is a governance story.
3. **It makes the architecture robust to its own weakest link.** If extraction
   turns out to be shaky, the product still works — the approval gate is the
   designed mitigation, stated openly, not an excuse invented after the fact.

## 7. Why three evidence verdicts, and why the queue contains a case to dismiss

Citations are table stakes; every RAG demo has footnotes. Our claim is
**evidence reconciliation**: the system tells the truth about evidence
*quality* — AGREES (sources corroborate), CONFLICTS (sources disagree and we
refuse to silently pick one), MISSING (expected evidence not found, with the
exact search stated). A fourth verdict (CHANGED-OVER-TIME) was cut: it drags
temporal rule resolution into the detection SQL — a week of work for one demo
line. Rule *versioning* stays; period-effective *evaluation* goes.

The dismissible case (P1131) is the most deliberate row in the demo queue. Its
potassium result exists but was recorded under an unmapped variant name, so
detection fired anyway. The reviewer sees the result, dismisses with a reason,
and three things are proven at once: detection is honest about being imperfect,
the human is load-bearing rather than decorative, and the disposition loop has
a purpose. A queue where every case is real makes the human ceremonial.

Negative evidence has one sacred wording: *"No serum potassium result was found
in the available records between X and Y"* — a claim about our data, never
about reality. This single sentence pattern is the difference between a
surveillance tool and a liability, and it appears with a `searched` field so
absence is evidence, not silence.

## 8. Why identity is one deterministic table

Real identity resolution (probabilistic person matching) is a product in
itself. Faking sophistication ("17 unmatched records!") without a resolution
workflow is theatre a domain judge will smell. Our position: a single
crosswalk table (patient_id ↔ member_id → person_id), deterministic over
synthetic data, stated plainly — and *isolated*, so a production deployment
swaps in an enterprise master-person index without touching anything
downstream. The identities are load-bearing in the hero finding (the condition
confirmation comes from the member side, the diagnosis from the patient side),
so the crosswalk earns its place in one demo sentence.

## 9. Why this stack (feature-for-a-reason, not feature-bingo)

| Choice | The problem it solves | The rejected alternative and why |
|---|---|---|
| Dynamic table for case detection | Cases appear when rules or data change, zero orchestration code | Tasks/streams: more moving parts, same result, worse demo story |
| Manual REFRESH button for the demo moment | Min target lag is 60s and chains compound — dead air on stage | Waiting for the scheduler: 60–120s of silence at the climax |
| AI_COMPLETE + Claude, from SQL | The one real AI step, inside the account | Cortex Agent: can't be called from SiS warehouse runtime; external API: destroys "no data leaves" |
| Explicit Python orchestration of Search + AI_COMPLETE | Auditable tool selection in a safety product | Agent routing: opaque, and unavailable anyway (above) |
| Cortex Search over document chunks | Passage-level citation of safety documents | Vector DIY: reinventing a managed service |
| Semantic view (stretch) | Governed structured Q&A without free generated SQL | Raw text-to-SQL: our biggest live-stability risk, avoided |
| Fixed evidence-retrieval functions | Deterministic follow-up answers + scores "custom tools" | Free-form SQL generation: unstable on stage |
| SiS warehouse runtime | Simplest thing that works in 12 days | Container runtime: compute pools + token plumbing, a spike we can't afford |

## 10. Why the value pitch refuses to name a dollar figure

Levers we demonstrate on stage: investigation time (30–60 min of
swivel-chairing → 10–15 min with the assembled bundle) and
guidance-to-surveillance latency (weeks → one morning). Both are arithmetic
from our own demo. For avoided harm we state the mechanism and defer the number
to a 90-day pilot measured in the customer's own data — because one judge who
knows the health-economics literature can unravel a fabricated figure and take
our credibility with it. Declining to invent a number *is* the credibility move.

## 11. What we are deliberately not building, and why each exclusion is strength

- Patient-facing anything → the challenge rejects it; scope stays safe.
- Autonomous ordering/prescribing → the human decides; we record decisions.
- ML risk scores → the challenge explicitly forbids opaque predictions; our
  priorities show their factors.
- Generic PDF-RAG → see §4; our finding is impossible for RAG alone.
- FHIR conformance layer → days of modeling for one sentence of credibility;
  resource-inspired *names* keep the sentence at zero cost.
- MCP / multi-agent / cross-surface → none solves a problem this product has;
  the brief's own principle is capability-for-a-reason. Say exactly that if
  asked.
