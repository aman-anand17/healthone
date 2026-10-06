# 05 — UI Specification (Streamlit in Snowflake, warehouse runtime)

Owner: Bikash. Build order: fixtures first (fixtures/answer_contract.json),
real queries later — a `get_case(case_id)` data-access function is the only
seam; day 1 it returns the fixture, day 7 it queries Snowflake, pages never
change. Keep styling minimal; clarity beats beauty in a 5-minute demo.

## Page 1 — Review Queue (landing)

The reviewer's worklist. Never a patient search box.

- Header: "Cases requiring review" + count of OPEN.
- **[Refresh queue] button** → runs the refresh action (ALTER DYNAMIC TABLE …
  REFRESH + MERGE; docs/03 §7) → st.toast with delta ("2 new cases"). This
  button IS the live-demo climax; make it prominent.
- Table (sortable): case_id · person (name, P-id/M-id) · case_type · trigger
  summary (first priority_factor) · priority badge (HIGH red / MEDIUM amber) ·
  created · status. Filter: status (default OPEN), case_type.
- Row click → Case Detail.
- Empty state: "No open cases. Approve a rule or refresh to evaluate."

## Page 2 — Case Detail (the product)

Layout top to bottom:

1. **Case header:** person context strip (name, age, P-id ↔ M-id, plan) —
   the one visible sentence of the identity crosswalk; case_type, priority
   **with all priority_factors listed** (transparent priority = a scoring
   criterion), status.
2. **Rule panel:** "Why this case exists" — drug, precondition, required test,
   `interval_source_phrase` → normalized `interval_days` (+grace), rule_id
   vN, approved_by/at, and a **source link** opening the document section
   (doc_id + source_passage from DOC_CHUNK) in an expander with the passage
   highlighted.
3. **Evidence panel — the differentiator.** One card per claim from
   CASE_EVIDENCE, grouped AGREES → CONFLICTS → MISSING:
   - AGREES (green): claim text + per-evidence source chips
     `[EHR · MED_10293]` `[PHARMACY · FILL_55102]`; chip click → expander with
     the source row rendered as fields (structured provenance — never raw SQL
     at a judge).
   - CONFLICTS (amber): the sources **side by side in columns** (EHR says /
     PHARMACY says / NOTE says), no adjudication language anywhere.
   - MISSING (grey): the verbatim negative-evidence sentence + a "Where we
     looked" line rendering the `searched` field. Absence as evidence.
4. **Timelines (cut-list item 3):** st.scatter_chart of P360_LAB_TIMELINE for
   the rule's test (visual gap) + medication events. Skip if time is short.
5. **Cited answer:** Tier-1 template narrative (assembled from rule + evidence
   fields) always shown. Below it, Tier-2 free-text input "Ask about this
   case" (cut-list item 1): fixed retrieval functions + Cortex Search →
   AI_COMPLETE; answers carry citation chips; out-of-scope questions return
   the evidence-doesn't-answer sentence verbatim.
6. **Disposition bar:** four buttons (ESCALATE_FOR_CLINICAL_REVIEW ·
   REQUEST_ADDITIONAL_EVIDENCE · MARK_REVIEWED · DISMISS_WITH_REASON).
   Dismiss/Escalate open a required-reason text box. Submit → update
   CASE_REGISTRY + insert AUDIT_EVENT → banner "Recorded by <role> at <ts>" →
   case leaves OPEN filter. GP3's dismissal here is demo beat 6.

## Page 3 — Rule Library & Approval

Two tabs.

- **Proposals:** table of RULE_PROPOSAL status=PROPOSED. Selecting one shows
  extracted fields LEFT, source passage RIGHT (highlighted), with
  `interval_source_phrase → interval_days` rendered as "every three months →
  90 days" (the human owns the interpretation — DECISIONS R3). If an ACTIVE
  rule exists for the same (drug, condition, test): warning panel with the
  existing rule + choice supersede / keep-both (edge 8.8). Buttons: Approve
  (vocabulary mapping must resolve; else error naming the unmapped term) /
  Reject (reason required). Approve → SAFETY_RULE v-next + audit.
- **Library:** all rules, all versions; status chips ACTIVE/SUPERSEDED/RETIRED;
  Retire button (reason) flags the rule's OPEN cases for re-review (edge 8.6).

Also on this page: **[Load new document]** file/stage picker → ingest + chunk +
extract → proposal appears. This plus Approve plus Queue-Refresh is the entire
live beat (demo beat 7): load SAFETY_DOC_008 → proposal → approve → refresh →
new cases.

## Page 4 — Audit (one screen, thirty demo seconds)

AUDIT_EVENT newest-first: actor · event · subject · when · detail. Filter by
case/rule id. Closing line lives here: "every decision is attributable and
reversible."

## Cross-cutting

- Role banner top-right (current role = HO_REVIEWER) — governance visibility.
- All timestamps rendered in one timezone; dates as YYYY-MM-DD.
- No free-form SQL anywhere in the app; all data access through the fixed
  function layer (DECISIONS A9).
- Every screen must render acceptably at projector resolution (test at
  1280×720; judges' rooms are cruel).
