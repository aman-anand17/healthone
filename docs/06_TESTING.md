# 06 — Testing & Evaluation

Four suites, in dependency order. Each is small, asserts on IDs and fields
(never on prose), and doubles as CoCo *testing-lifecycle* evidence — run them
through CoCo, capture dated results into coco/validation/.

## 1. Extraction golden suite (FIRST; blocks all build work)

What: spike/ as shipped — 4 documents × 3 runs through AI_COMPLETE with the
strict-JSON prompt; `spike/validate.py` checks accuracy (field-exact vs
golden) AND stability (3 runs identical). Built-in traps: 12 weeks ⇒ 84;
distractor tests must not become rules.

Then extend with the production corpus (docs/04 §3): SAFETY_DOC_005–009
golden expectations, **including 009 ⇒ zero rules** (restraint assertion) and
008's shorter-interval supplement.

Pass: all fields exact, runs identical, zero rules from the distractor.
Fail policy: fix the prompt/schema, never the golden values; if stability
won't converge after two prompt iterations, the design adapts (heavier
approval emphasis) — documented, not hidden.

## 2. Detection golden suite (after schema + data load)

The 8 golden patients (docs/04 §2) ARE the test. One SQL script asserting,
after refresh, exactly:

    GP1 ⇒ MONITORING_GAP HIGH        GP5 ⇒ case fires
    GP2 ⇒ MED_CONFLICT MEDIUM        GP6 ⇒ case fires (stale-lab trap)
    GP3 ⇒ MONITORING_GAP fires       GP7 ⇒ NO case
    GP4 ⇒ NO case (grace)            GP8 ⇒ NO case (precondition gate)

plus a count check: no golden patient generates a duplicate or unexpected
second case. The negative assertions (GP4/7/8) matter more than the positive
ones — they are detection *precision*, the thing that prevents alert fatigue
(edge 8.7).

## 3. Reconciler & contract suite

For GP1, GP2, GP3: assert CASE_EVIDENCE contains the expected claim set with
expected verdicts and expected evidence_refs (by source_record_id), and every
MISSING row has a non-empty `searched`. Then assemble the full answer
contract for GP1 and diff its *shape* (keys, types, verdict enum) against
fixtures/answer_contract.json — the UI's guarantee.

## 4. Retrieval/Q&A eval (only if Tier-2 Q&A ships)

6–8 questions in eval_cases.yaml, each with expected evidence IDs (structured
rows and/or chunk_ids), ×3 runs, assertion = expected IDs present AND
identical set across runs. Include one out-of-scope question ("will this
patient be okay?") asserting the refusal sentence appears. Never assert on
answer wording beyond that sentence.

## 5. Demo rehearsal protocol (28–30 Aug)

- Full 5-minute run **3× consecutively without an error** on the demo account
  before recording. Any failure resets the count.
- Live beat staged: SAFETY_DOC_008 validated in testing then unloaded; second
  held-back doc + one pre-approved rule as fallbacks; queue-refresh path
  (button → REFRESH → MERGE) timed under 10 seconds on demo data.
- Kill-switch drill: if extraction misbehaves live, pivot line is rehearsed —
  "this is exactly why approval exists; here is one we validated earlier" —
  and the pre-approved fallback rule carries the beat.

## Ownership

Suites 1 & 4: Manisha (with Aman on prompt iteration). Suite 2 & 3: Aman.
Rehearsal: Nitin runs the clock, whole team present.
