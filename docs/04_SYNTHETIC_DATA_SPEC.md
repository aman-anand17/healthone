# 04 — Synthetic Data Specification

Owner: Manisha. Everything here is generated via CoCo (evidence into
coco/development/). Two data populations: a background cohort (realistic noise;
detection must work on people we never scripted) and eight golden patients
(every edge case pinned to a known person; they double as detection tests —
docs/06 §3).

## 1. Background cohort

~300 persons. Every person exists on BOTH sides (RAW_EHR_PATIENT and
RAW_PLAN_MEMBER) with consistent name/DOB; the generator emits the crosswalk
as it goes (deterministic by construction — DECISIONS A7).

Distributions (rough, not sacred):
- Age 25–90, skewed 55+. Sex ~50/50. 3 clinics, 2 plan codes.
- Conditions: CKD ~12%, hypothyroidism ~10%, chronic liver disease ~6%;
  onset dates 1–8 years back.
- Drugs: CardioZen ~6% of cohort (⅔ of those also CKD — the interesting
  overlap), Renuvex ~5%, Hepatrol ~4%. Start dates 3 months–3 years back.
  ~85% of ACTIVE meds have plausible fill chains (fills every 25–35 days);
  the rest have ragged fills — natural MED_CONFLICT candidates the reconciler
  should catch WITHOUT scripting.
- Labs: persons with a condition get the matching lab 1–6× per 18 months;
  ~70% of raw test_text uses canonical names, ~30% mapped synonyms, plus a
  small unmapped-variant sprinkle (P1131's mechanism appearing in the wild).
- Claims: 2–10 lines/person/year; condition-linked lines for diagnosed persons
  (the payer-side confirmation the hero finding uses).
- Notes: 0–4 per person; templated prose. For scripted conflict persons, the
  note contains a discontinuation sentence ("patient reports stopping
  CardioZen due to dizziness") — retrievable, citable.

Determinism: fixed RNG seed; regenerating must reproduce identical golden
outcomes.

## 2. The eight golden patients

All on CardioZen unless noted. Rule under test: R-001 v1 = CardioZen + CKD →
serum potassium every 90 days, grace 7, effective 2026-03-01
(SAFETY_DOC_007). "Today" = CONF.DATE_ANCHOR.as_of = **2026-09-01, fixed**;
the generator computes every date relative to the anchor, never the run date
(2026-08-20 D1/D6 — golden outcomes cannot drift between generation and demo).

| # | Person | Setup | Expected outcome |
|---|---|---|---|
| GP1 | P1024 | CKD onset 2025-11; CardioZen since 2026-02, healthy fills; last potassium today−137d | MONITORING_GAP, HIGH, "137 days since last result" — the hero case |
| GP2 | P1088 | EHR CardioZen ACTIVE; last fill today−150d; note documents stopping | MED_CONFLICT, MEDIUM; reconciler shows EHR vs PHARMACY vs NOTE side by side |
| GP3 | P1131 | CKD + CardioZen; potassium today−20d but raw text "K+ serum level" (unmapped synonym) | MONITORING_GAP fires; reviewer sees the result in raw lab timeline; DISMISS_WITH_REASON — the dismissible case |
| GP4 | boundary-in | last potassium today−93d (90+7 grace ⇒ inside) | NO case. Proves grace suppresses boundary flip-flop (edge 8.2) |
| GP5 | boundary-out | last potassium today−99d | Case fires. GP4+GP5 bracket the boundary |
| GP6 | stale-lab | potassium 30d BEFORE CardioZen start; none after | Case fires — pre-therapy lab must not count (edge 8.3, the GREATEST anchor) |
| GP7 | compliant | potassium today−40d, canonical name | NO case. Detection precision |
| GP8 | no-precondition | CardioZen, NO CKD; no recent potassium | NO case — rule's precondition gates it |

Plus for the live demo beat (2026-08-20 D7): 3–4 persons on CardioZen + CKD
whose last potassium is 75–90 days before the anchor — compliant under R-001
v1 (90+7) and firing the instant v2 (60+7, from SAFETY_DOC_008) is approved.
That cohort IS the "new cases appear" payload, invisible until approval.

## 3. Document corpus (v2 naming; supersedes spike corpus for production)

| Doc | Content | Purpose |
|---|---|---|
| SAFETY_DOC_005 | Renuvex + CKD → serum creatinine "quarterly"; requirement mid-paragraph | Phrasing variance; buried requirement |
| SAFETY_DOC_006 | Hepatrol + chronic liver disease → ALT "at 12-week intervals"; names two NOT-required tests | The 84-days trap + distractor tests |
| SAFETY_DOC_007 | **CardioZen + CKD → serum potassium "at least every three months"** | The hero rule; pre-approved before demo |
| SAFETY_DOC_008 | CardioZen + CKD → potassium every 60 days, published after 007 and worded as TIGHTENING it; approval creates R-001 v2, superseding v1 (2026-08-20 D7 — age_min version dead) | HELD BACK — the live demo document |
| SAFETY_DOC_009 | Distractor: adverse-event advisory, ZERO monitoring requirement | Extraction restraint (edge 8.5): correct output = no rule |

Authorship split on purpose: Manisha writes 005–007, **Nitin writes 008–009
independently without seeing the extraction prompt** — genuine wording
variance, not one author's tics.
*Amendment 2026-08-20 (solo build): the AI coding assistant authors all five. The
independent-wording property is LOST — recorded in PROGRESS as a known
limitation. Mitigation: each document in a different register (committee memo /
prescriber notice / bulletin), requirement sentences written prompt-blind.* Every document: HealthOne header, doc_id,
publication_date, section numbers (citations point at sections), and the
synthetic-data disclaimer block.

The original spike corpus (spike/docs, Cardiozan/TSH naming) stays as extra
extraction-test coverage; it never loads into the product tables.

## 4. Deliverables checklist (Manisha)

- [ ] Generator (Python via CoCo), seeded, date-relative; writes RAW_* loads
- [ ] Vocabulary seed rows incl. synonym table with deliberate gaps
- [ ] 8 golden patients embedded, assertions file for docs/06 §3
- [ ] SAFETY_DOC_005–007 + 009 staged; 008 validated then HELD BACK
- [ ] Golden extraction expectations for 005–009 (incl. 009 ⇒ zero rules)
