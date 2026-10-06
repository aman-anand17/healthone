**HealthOne 360**

Patient Safety Case Investigator

*A governed Patient & Member 360 that turns written safety guidance into
investigated, evidence-cited cases*

Snowflake CoCo CLI Hackathon 2026 \| Team Product Story \| Version 2.0
(Final)

Aman · Bikash · Manisha · Nitin

**Contents**

**1. What We Are Building, In One Paragraph**

We are building a healthcare case-investigation assistant for a Clinical
Case Reviewer inside a large payvider organization (a group that runs
both hospitals and a health plan). The product converts human-written
safety guidance — for example, an FDA-style drug safety communication —
into a structured, human-approved monitoring rule; applies that rule to
a unified Patient & Member 360 built from clinical, claims, lab, and
pharmacy data; automatically raises review cases where the evidence
violates the rule; shows the reviewer every piece of supporting,
conflicting, and missing evidence with citations back to the source; and
records the reviewer's final decision. The AI proposes knowledge. A
human approves it. Deterministic checks apply it. A human decides the
outcome. Every step is traceable.

|                                                                                                                                                                                                                                  |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **The product in one sentence:** Safety guidance is already written down — our product is the missing pipeline that carries it from a PDF to the specific patients whose data violates it, with a human in control at both ends. |

**2. The Story: A Tuesday at HealthOne**

To understand the product, follow one case end to end. Everything below
is synthetic, but every step mirrors how this failure happens in real
healthcare organizations.

**2.1 The organization**

HealthOne Group is a fictional integrated healthcare enterprise. It runs
a network of hospitals and clinics (the provider side) and a health
insurance plan (the payer side). Because it is both, it legitimately
holds several categories of information about the same person: the
hospital side has clinical records, lab results, and physician notes;
the plan side has enrollment, claims, and pharmacy fill data. In the
industry this dual structure is called a payvider, and it is exactly the
setting where a combined Patient 360 (the provider view) and Member 360
(the payer view) can exist under one governance roof.

**2.2 The guidance nobody operationalized**

On a Tuesday morning, a new drug safety communication arrives. In plain
language it says: patients taking CardioZen (a synthetic cardiology
drug) who also have chronic kidney disease must have their serum
potassium checked at least every three months, because the combination
can cause dangerous potassium build-up.

In most organizations, here is what happens next: the document is
emailed to a safety committee, discussed in a meeting three weeks later,
someone files an IT ticket to build a report, the report is built two
months later against only the EHR (missing pharmacy and claims
evidence), and in the meantime every affected patient is invisibly at
risk. The knowledge existed on day one. It reached the data months
later, if ever. That gap — between written guidance and operational
surveillance — is the problem we are attacking.

**2.3 What happens at HealthOne instead**

At HealthOne, the document lands in the system. Within minutes, the AI
reads it and proposes a structured rule: drug = CardioZen; condition =
chronic kidney disease; required test = serum potassium; interval =
every 3 months, normalized to 90 days; source = SAFETY_DOC_007, with the
exact sentence it extracted from. The rule is not active yet — it sits
in a proposal queue.

Priya, a Clinical Case Reviewer, opens the proposal. She sees the
extracted fields side by side with the highlighted source passage. The
extraction looks right. She approves it. The rule becomes version 1,
status ACTIVE, stamped with her name and the timestamp.

The moment the rule activates, the system evaluates it against the
Patient & Member 360 — the unified, longitudinal view of every person
HealthOne serves. Three cases appear in Priya's review queue:

- **P1024 — HIGH priority.** On CardioZen, has CKD, and the last
  potassium result is 137 days old against a 90-day requirement. A clear
  potential monitoring gap.

- **P1088 — MEDIUM priority.** The EHR lists CardioZen as an active
  medication, but pharmacy data shows no fill in five months, and a
  clinical note mentions the patient reported stopping it. The sources
  disagree — an evidence conflict.

- **P1131 — LOW / informational.** On CardioZen with CKD, and a
  potassium result from 3 weeks ago is in range. Monitoring evidence
  found; nothing to chase.

Priya opens P1024. One screen shows her the patient's demographics and
coverage, the medication timeline, the lab timeline, the rule that
fired, and the evidence verdicts: the drug evidence AGREES across EHR
and pharmacy; the condition is confirmed in both diagnosis codes and
claims; the required lab is MISSING within the window. Every fact links
to its source row or source sentence. She asks the built-in assistant,
in plain language: "Why was this case flagged?" and gets a cited answer
assembled only from the evidence on screen. She selects a disposition:
Escalate for clinical review. The case closes with her name, her reason,
and a full trail.

Total elapsed time from guidance published to at-risk patients
identified and escalated: one morning. In the status quo: weeks to
months.

|                                                                                                                                                                                                                                                                                                                                                                                                        |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Why this story matters:** the harm we prevent is not exotic. Preventable medication-related harm costs the US system an estimated \$20–40 billion per year, and the monitoring-gap slice is the most preventable slice of all — because the required action is already written down. The failure is fragmentation, and fragmentation is a data problem. That is why this belongs on a data platform. |

**3. The Business Problem, Precisely Stated**

Three facts create the problem space:

- **1. Safety knowledge is unstructured.** Drug safety communications,
  label updates, and monitoring guidance arrive as prose documents. The
  same requirement may be phrased as "every three months", "quarterly",
  or "every 12 weeks". No system can act on prose.

- **2. Patient evidence is fragmented.** Whether a patient complies with
  a monitoring requirement is provable only by joining EHR (is the drug
  prescribed?), pharmacy (is it actually being filled?), diagnosis and
  claims (does the condition apply?), and labs (was the test done, and
  when?). These live in different systems with different identifiers.

- **3. Investigation is manual.** When a case does surface, a reviewer
  spends 30–60 minutes swivel-chairing across systems to assemble the
  evidence, with no record of what was checked or why a case was closed.

The consequences: preventable adverse drug events (patient harm plus
\$3,400–6,900 direct cost per event), liability exposure for
documented-but-unmonitored risks, failed quality measures (which for
health plans translate directly into lost quality-score revenue), and
reviewer teams drowning in low-context alerts they learn to ignore.

Our product exists because all three facts are addressable at once: AI
can structure the knowledge, a 360 data layer can unify the evidence,
and a workflow with citations can make investigation fast and
trustworthy.

**4. Who Uses It — and Who Does Not**

|                                                         |                                                                               |                                                                       |
|---------------------------------------------------------|-------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| **Persona**                                             | **Role in the product**                                                       | **What they see**                                                     |
| Clinical Case Reviewer (primary — Priya)                | Investigates cases, asks questions, records dispositions                      | Review queue, case detail with evidence and citations, assistant chat |
| Safety Rule Approver (can be the same person or senior) | Reviews AI-proposed rules against source passages; approves, rejects, retires | Rule proposal queue, rule library with versions                       |
| Safety / Quality Lead (secondary)                       | Monitors rule performance and queue health                                    | Dismissal-rate signals, audit trail                                   |

**Explicitly not the user: the patient.** This is not a patient-facing
chatbot, not a diagnosis tool, and not an autonomous clinical system.
The patient/member is the subject of the investigation. Every
consequential decision — activating a rule, closing a case — is made by
a qualified human. This is a deliberate safety and scope decision, not a
limitation.

**5. How the Product Works: The Loop**

|                                                                                                                                                                                                                                                       |
|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Safety document → AI-proposed rule → human approval → versioned rule library → evaluation against the Patient & Member 360 → review case with priority → evidence reconciliation → cited answers → human disposition → stored, auditable outcome.** |

**5.1 Step by step**

- **A — Ingest the document.** A safety communication (PDF/text) enters
  the document store and becomes searchable.

- **B — AI proposes a rule.** The system extracts a structured proposal:
  drug, condition, required test, raw interval phrase, normalized
  interval in days, effective date, source document ID, and the exact
  source passage. Nothing is active yet.

- **C — Human approves.** An approver compares fields against the
  highlighted source sentence. Approval creates rule version 1 with
  status ACTIVE. Rejection records a reason. Rules are immutable:
  corrections create a new version that supersedes the old.

- **D — The 360 is evaluated.** Active rules are checked,
  deterministically, against the unified person view: who is on the
  drug, who has the condition, and when the last qualifying test
  occurred.

- **E — Cases appear in a prioritized queue.** Each case carries a
  trigger ("potential monitoring gap", "conflicting medication
  evidence"), a transparent priority with its stated factor, and the
  rule version that generated it.

- **F — The reviewer investigates.** The case screen assembles the
  person context, timelines, evidence verdicts (see Section 7), and
  source citations. A built-in assistant answers questions strictly from
  the evidence bundle, with citations.

- **G — Human disposition.** Controlled outcomes: Escalate for clinical
  review · Request additional evidence · Mark reviewed · Dismiss with
  reason. Every disposition is an audit event: who, when, why.

**5.2 The governing principle**

**AI proposes → human approves → deterministic checks apply → human
decides.** The AI is used where language understanding is genuinely
needed (reading varied prose, explaining evidence). Everything that
determines whether a case exists is deterministic and testable. This is
intentional: in a safety context, we want the judgment calls made by
people and the arithmetic made by code — never the reverse.

**6. The Patient & Member 360 Layer**

The 360 is not a dashboard in our product — it is the governed data
foundation the whole loop stands on. It has four concrete parts:

- **Identity crosswalk.** Maps the hospital's patient ID and the plan's
  member ID to one person ID, so evidence from both sides joins
  correctly. (In our synthetic demo the match is deterministic; in
  production this seat is filled by an enterprise master-person index —
  the design leaves that seat explicitly.)

- **Person summary.** One row per person: demographics, coverage, active
  conditions, active medications, latest key labs, open case count.

- **Longitudinal timelines.** Medication events (prescriptions and
  fills) and lab events over time — the raw material for
  monitoring-window math and for the reviewer's visual understanding of
  the case.

- **Source registry.** Every fact in the 360 knows which source system
  and record it came from. Citations are only possible because
  provenance is kept, not reconstructed.

|                               |                                     |                                                                        |
|-------------------------------|-------------------------------------|------------------------------------------------------------------------|
| **Source**                    | **What it is**                      | **What it proves in a case**                                           |
| EHR / clinical records        | Provider-maintained clinical record | Drug prescribed, condition diagnosed, clinical context                 |
| Claims                        | Payer processing records            | Services actually delivered; utilization; condition confirmation       |
| Pharmacy fills                | Dispensing records                  | Drug actually being taken (or not) — the reality check on the EHR list |
| Lab results                   | Test results with dates and values  | Whether required monitoring happened, and when                         |
| Clinical documents            | Notes, discharge summaries          | Human context: e.g., patient reported stopping a drug                  |
| Safety / regulatory documents | Guidance, warnings, requirements    | The external knowledge that defines what "compliant" means             |

**Patient 360 answers "who is this person?" Our product answers "what
about this person needs human attention — and on what evidence?"** The
360 is the context; the investigation workflow is the product.

**7. Evidence Reconciliation: Our Differentiator**

Citations alone are table stakes. What makes a reviewer trust the system
is that it tells the truth about evidence quality. Every case classifies
its evidence into four verdicts:

|                   |                                                                  |                                                                                         |
|-------------------|------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| **Verdict**       | **Meaning**                                                      | **Example**                                                                             |
| AGREES            | Multiple sources support the same finding                        | EHR shows CardioZen prescribed; pharmacy shows regular fills                            |
| CONFLICTS         | Sources disagree; the system refuses to silently pick one        | EHR: medication active · Pharmacy: no fill in 150 days · Note: patient reports stopping |
| MISSING           | Expected evidence not found in the available data and window     | "No potassium result found in available records between 1 Mar and 18 Aug"               |
| CHANGED OVER TIME | The evidence or the rule itself changed across dates or versions | Guidance updated: interval tightened from 90 to 60 days in rule v2                      |

Two design commitments make this real rather than cosmetic:

- **Conflict types are engineered; conflict instances are data-driven.**
  We define each check explicitly (e.g., "EHR status ACTIVE with no
  pharmacy fill inside the expected window = medication conflict"). Any
  person whose data matches fires the check — including patients we
  never scripted. The AI does not decide what conflicts; it explains the
  verdicts our deterministic checks produce.

- **Negative evidence is worded with discipline.** The system says "no
  result was found in the available records and window" — never "the
  patient did not take the test." We claim only what our data shows.
  This single wording rule is the difference between an honest
  surveillance tool and a liability.

**8. Edge Cases: Where Products Like This Usually Break — and Our
Answers**

This section exists so every teammate can answer hard questions without
improvising. Each edge case states the trap and our designed behavior.

**8.1 The same requirement, worded three ways**

**The trap:** "Quarterly", "every three months", and "every 12 weeks"
look interchangeable — but 12 weeks is 84 days, not 90. A system that
silently treats them as equal is wrong; one that treats them as
different without saying so confuses reviewers.

**Our behavior:** We maintain an explicit, written normalization policy:
intervals normalize to days (quarterly = every 3 months = 90 days; every
12 weeks = 84 days). The approval screen always shows the raw phrase
next to the normalized value — e.g., "every 12 weeks → 84 days" — so the
human approving the rule sees, and owns, the interpretation. The
discrepancy becomes a visible feature, not a hidden bug.

**8.2 The boundary patient (day 90, day 91)**

**The trap:** A patient whose last lab is exactly at the interval
boundary flip-flops in and out of the queue with every data refresh,
training reviewers to ignore the queue.

**Our behavior:** Case detection applies a documented grace window
(e.g., interval + 7 days) before a gap case opens. Boundary noise is
suppressed; the grace value itself is part of the rule record, visible
and auditable.

**8.3 The lab that predates the drug**

**The trap:** A potassium test from before the patient ever started
CardioZen must not count as monitoring compliance — but a naive "any lab
within N days" query counts it.

**Our behavior:** The monitoring window is anchored to therapy: only
qualifying results dated on or after the later of (drug start, condition
onset, rule effective date) satisfy the rule. This is encoded in the
deterministic check and covered by a golden test patient.

**8.4 Sources that disagree about the medication itself**

**The trap:** EHR says the drug is active; pharmacy shows no fills; a
note says the patient stopped. Most systems silently trust one source —
and generate either a false alarm or false reassurance.

**Our behavior:** This is precisely what the CONFLICTS verdict is for.
The case is raised as "conflicting medication evidence" at MEDIUM
priority, all three sources are displayed side by side, and the human
decides. The system's job is to surface the disagreement, never to
adjudicate it invisibly.

**8.5 A document that contains no rule**

**The trap:** Not every safety communication contains an extractable
monitoring requirement. A system that always extracts something will
invent rules from noise.

**Our behavior:** The extraction step is allowed — expected — to return
"no rule proposed" for documents without actionable requirements. Our
test corpus deliberately includes one such distractor document, and the
correct behavior is restraint. Nothing enters the library without both
an extraction and an approval.

**8.6 A subtly wrong rule gets approved anyway**

**The trap:** The human approves a rule with a wrong interval or wrong
condition; false cases start generating at scale. Without a correction
path, "human-approved" becomes "human-blamed".

**Our behavior:** Rules are versioned and immutable. A correction is a
new version that supersedes the old; a retirement flips status to
RETIRED. Every case stores the rule ID and version that created it, so
retiring a rule automatically flags its open cases for re-evaluation
while leaving closed cases intact and auditable. Governance does not end
at approval — it has a full lifecycle: propose, approve, supersede,
retire, re-evaluate.

**8.7 Reviewers keep dismissing cases from one rule**

**The trap:** A noisy rule floods the queue; reviewers dismiss and
dismiss; alert fatigue sets in and real cases start being ignored — the
number-one failure mode of clinical decision support.

**Our behavior:** Dismissals carry structured reasons. When dismissals
with reason "false trigger" from a single rule cross a threshold, the
rule itself is flagged for re-review. The queue polices its own signal
quality: bad rules are detected by the same workflow they pollute.

**8.8 Two documents propose overlapping rules**

**The trap:** An FDA communication and an internal policy both cover
CardioZen + CKD with different intervals. Duplicated rules mean
duplicated cases and contradictory priorities.

**Our behavior:** At approval time, the system surfaces existing active
rules for the same drug + condition + test triple. The approver either
supersedes the old rule or consciously keeps both (e.g., different
populations), with the decision recorded. Where two active rules
genuinely apply, the stricter interval governs case detection and both
sources are cited.

**8.9 Guidance changes over time**

**The trap:** The regulator tightens the interval from 90 to 60 days.
Patients compliant under the old rule are suddenly non-compliant — and a
naive system either misses them or floods the queue retroactively.

**Our behavior:** The new interval arrives as rule v2 with its own
effective date; v1 is superseded. Case detection evaluates against the
version effective for the period in question, and the CHANGED-OVER-TIME
verdict shows the reviewer exactly what changed and when. No silent
retroactive judgment.

**8.10 Missing data is not non-compliance**

**The trap:** The lab feed for one clinic is delayed or absent. A gap
case fires; the patient was actually tested. The report is technically
wrong and clinically insulting.

**Our behavior:** Two protections: the disciplined negative-evidence
wording (Section 7) means the system only ever claims "not found in
available records"; and the disposition "Request additional evidence"
exists precisely for this — the reviewer records that the data, not the
patient, is the open question. In production, source-freshness metadata
would surface "lab feed last updated N days ago" on the case.

**8.11 The same human being, two identifiers**

**The trap:** The hospital knows P-88231; the plan knows M-40072. If
identity resolution fails, half the evidence is invisible and every
verdict is built on a partial person.

**Our behavior:** In the demo, the identity crosswalk is deterministic
over synthetic data — and we say so plainly. The design isolates
identity resolution in one governed table so that a production
deployment swaps in an enterprise master-person index without touching
anything downstream. We treat "who is this person" as a first-class,
replaceable component, not an assumption baked into joins.

**8.12 The assistant is asked something outside the evidence**

**The trap:** A reviewer asks the chat assistant a question the case
evidence cannot answer ("will this patient be okay?"). A generic chatbot
would improvise — reintroducing exactly the opaque-answer problem the
challenge forbids.

**Our behavior:** The assistant answers strictly from the case's
evidence bundle and the governed data layer, with citations, and is
instructed to say "the available evidence does not answer that" when it
does not. It never speculates clinically and never invents facts outside
the bundle.

**9. What We Are Deliberately NOT Building**

- A patient-facing diagnosis or advice chatbot.

- An autonomous treatment, prescribing, or test-ordering system.

- An opaque disease-prediction model or a mysterious risk score.

- A generic "upload PDF, ask questions" retrieval app.

- A static dashboard with no workflow and no disposition.

Each exclusion is a positioning strength: it keeps the human in charge,
keeps every output explainable, and keeps our scope achievable.

**10. Why This Is More Than RAG (and More Than a Dashboard)**

A retrieval-augmented chatbot finds a document and summarizes it. Our
loop converts the document into governed operational knowledge that acts
on data continuously: unstructured guidance → structured, versioned,
human-approved rule → automatic evaluation over a unified 360 →
prioritized cases → evidence verdicts → cited answers → recorded human
decisions. The AI's contribution is real but bounded — it reads varied
natural language and normalizes it, and it explains evidence — while
everything that decides whether a case exists is deterministic,
testable, and auditable. The result is not an answer to a question; it
is a closed, repeatable safety workflow.

**11. Why It Is Worth Paying For**

|                             |                                                                                                                      |                                                    |
|-----------------------------|----------------------------------------------------------------------------------------------------------------------|----------------------------------------------------|
| **Value lever**             | **Mechanism**                                                                                                        | **Conservative order of magnitude**                |
| A — Avoided harm            | Evidence-based surveillance prevents a slice of monitoring-related adverse drug events (\$3.4–6.9K direct cost each) | Low six figures / yr for a mid-size system (floor) |
| B — Reviewer productivity   | Assembled evidence bundle + verdicts cut a 30–60 min investigation to 10–15 min                                      | Thousands of reviewer-hours / yr recovered         |
| C — Speed to compliance     | Guidance-to-active-rule cycle: weeks/months → days                                                                   | Presented as time, deliberately unmonetized        |
| D — Quality revenue (payer) | Earlier medication-monitoring gap closure feeds quality measures tied to plan revenue                                | Largest lever at plan scale                        |

Cost side: the product runs entirely inside the data platform the
organization already operates — no data movement, no new vendor
platform, consumption-priced. The commercial ask is a 90-day pilot on
one drug–lab scenario, measured on levers B and C in the customer's own
data. Presenting measurement, not belief, is what makes the case
credible.

**12. How It Is Built — One-Page Overview**

Full technical design is a separate document. The shape, so the story is
grounded:

- **Everything lives in one Snowflake account.** Structured records,
  documents, the rule library, cases, audit events, and the app share
  one platform and one access-control model. No data leaves.

- **Layered data model.** Raw provider and payer data land separately
  (mirroring real governance boundaries) → conformed tables shaped like
  healthcare interoperability standards (FHIR resources) → the 360 layer
  built as auto-refreshing dynamic tables, including case detection
  itself.

- **Rule extraction** uses Snowflake's AI SQL functions with a strict
  output schema; proposals are just rows a human approves in the app.

- **Case detection is a dynamic table** joining active rules to the 360
  timelines — so when a rule is approved, new cases appear
  automatically, with no orchestration code. Our demo's most memorable
  moment is a native platform behavior.

- **The assistant is a Cortex Agent** with three tools: governed
  structured queries via a semantic view, document retrieval with
  citations via Cortex Search, and our deterministic evidence reconciler
  exposed as a custom tool.

- **The interface is Streamlit in Snowflake:** review queue, case
  detail, rule approval, and the assistant panel — running under the
  reviewer's own role.

- **CoCo CLI is our build accelerator** (schema scaffolding, semantic
  view generation, synthetic data, app drafting) — and demonstrating
  that is itself part of the hackathon story.

**13. The Demo Storyline**

- **Open on the problem (30s):** the Tuesday story — guidance exists,
  patients at risk, months of lag.

- **Show the queue (60s):** three live cases (gap / conflict /
  compliant), each with a transparent priority factor.

- **Investigate P1024 (90s):** 360 context, timelines, AGREES / MISSING
  verdicts, ask the assistant "why was this flagged?", cited answer,
  disposition recorded.

- **The memorable moment (90s):** introduce a document the system has
  never seen. The AI proposes the rule, we show the source passage,
  approve it live — and the queue visibly changes as new cases appear.
  Unstructured knowledge became governed surveillance in front of the
  judges.

- **Close on governance (30s):** versioned rules, audit trail, roles and
  masking — one screen, one sentence: "every decision here is
  attributable and reversible."

**Demo risk control:** the "fresh" document is fresh to the system, not
to us — validated in testing, held back from loading. A second held-back
document and one pre-approved rule are staged as fallbacks. The moment
that cannot fail — cases appearing after approval — is deterministic.

**14. Scope for the First Release**

**In scope:** synthetic patients/members with clinical, claims, lab, and
pharmacy fixtures; identity crosswalk; person 360 and timelines; 4–6
varied synthetic safety documents (including one distractor); rule
extraction with golden tests; approval with versioning; dynamic case
detection with grace windows; the two engineered conflict checks;
prioritized queue; evidence verdicts with citations; assistant over the
evidence bundle; controlled dispositions; append-only audit events.

**Out of scope (consciously):** real data, ML risk models, EHR
write-back, patient outreach, multi-agent orchestration, external
integrations.

**If time runs short, cut in this order:** assistant chat panel →
row-level access policy → lab timeline visualization. Never cut: rule
approval, dynamic case detection, the reconciler, citations.

**15. Team Ownership**

|            |                                                                         |                                                                                   |
|------------|-------------------------------------------------------------------------|-----------------------------------------------------------------------------------|
| **Person** | **Owns**                                                                | **First deliverable**                                                             |
| Aman       | Data architecture, rule/case model, extraction, reconciler, integration | Rule + case tables with versioning; extraction golden test                        |
| Bikash     | Streamlit workflow: queue, case detail, approval, assistant panel       | Queue + approval pages from fixture JSON (unblocked from data work)               |
| Manisha    | Synthetic data, document corpus, pipelines, golden test fixtures        | Patient fixtures incl. the 8 golden-test patients; 2 safety docs + the distractor |
| Nitin      | Business realism, workflow validation, edge-case narrative, pitch       | 2 safety docs (written independently for wording variety); demo script            |

**16. The 60-Second Pitch**

|                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| "Preventable medication harm costs tens of billions a year, and its most preventable slice — monitoring gaps — persists not because the knowledge is missing, but because it is trapped in PDFs while the evidence is scattered across EHR, claims, pharmacy, and labs. HealthOne 360 closes that loop. AI converts each new safety communication into a proposed rule; a human approves it; and a governed Patient & Member 360 immediately surfaces every person whose evidence violates it — with agreeing, conflicting, and missing evidence cited, and a reviewer making the final call. We are not replacing clinicians and we make no opaque predictions. We turn fragmented healthcare evidence into a transparent investigation workflow — and the time from 'guidance published' to 'our patients are screened against it' drops from weeks to one morning." |

**17. Glossary (Plain English)**

|                          |                                                                                                                    |
|--------------------------|--------------------------------------------------------------------------------------------------------------------|
| **Term**                 | **Meaning in this product**                                                                                        |
| Patient 360 / Member 360 | One unified, longitudinal view of a person, assembled from provider-side (patient) and payer-side (member) sources |
| Payvider                 | An organization that is both healthcare provider and health plan — why one roof can hold both data sides           |
| Safety communication     | A document (e.g., FDA-style) stating a warning or requirement, such as mandatory lab monitoring for a drug         |
| Rule                     | The structured, human-approved, versioned form of a requirement: drug + condition + required test + interval       |
| Case                     | A system-raised item saying "this person's evidence appears to violate an active rule — please investigate"        |
| Evidence verdict         | AGREES / CONFLICTS / MISSING / CHANGED-OVER-TIME — the honest classification of evidence quality                   |
| Disposition              | The reviewer's recorded final decision on a case, with reason                                                      |
| Golden test              | A fixed set of inputs with known correct outputs, used to prove extraction and case detection behave correctly     |
| Grace window             | Extra days beyond the interval before a gap case opens, to suppress boundary noise                                 |
| Adverse drug event (ADE) | Harm to a patient resulting from medication use — the outcome this product helps prevent                           |

*— End of product story. Next document: technical design (data model
DDL, semantic view, agent configuration, test plan). —*

---

## AMENDMENTS TO v2 (agreed after this document was written — these override the text above)

1. **P1131 in §2.3 is replaced.** Not a compliant "nothing to chase" patient —
   a queue slot must never hold a non-case (§8.7's own argument). P1131 = the
   dismissible near-miss: potassium result EXISTS but recorded under a variant
   test name, detection fired, reviewer dismisses with reason. Proves the human
   is load-bearing.
2. **Evidence verdicts: three, not four.** CHANGED-OVER-TIME is cut from v1
   (§7 table and §8.9's period-effective evaluation). Rule versioning stays.
3. **§11 value table: no uncited dollar figures.** Lead with levers B and C
   (demonstrable on stage); for avoided harm, state the mechanism and defer the
   number to the pilot.
4. **§12 architecture corrections:** SiS warehouse runtime cannot call the
   Cortex Agents API → assistant is Cortex Search + AI_COMPLETE orchestrated
   explicitly. Dynamic-table demo moment uses a manual REFRESH button (min lag
   60s). No FHIR conformance layer — resource-inspired names only. Cited answer
   is template-generated from the reconciler; free-text Q&A is an enhancement.
5. **Reusable CoCo skill restored:** .cortex/skills/patient-evidence-review +
   AGENTS.md at repo root, built week 1, used during development.
6. **Dates added:** submission 1 Sep; feature freeze 28 Aug; extraction spike
   before any other build work; CoCo artifacts captured as work happens
   (ownership: Aman).

Full rationale for each: docs/DECISIONS.md.
