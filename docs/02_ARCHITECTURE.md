# 02 — Architecture, End to End

One Snowflake account holds everything: data, documents, rules, cases, audit,
LLM calls, and the app. The sentence to protect in every technical choice:
**"Every byte, every model call, every decision record lives inside one
Snowflake account."**

## 1. The flow

    SAFETY DOCUMENT (prose, staged + chunked)
        │  ingest task
        ▼
    AI_COMPLETE (Claude) — strict-JSON extraction          [the one AI step]
        │  rows land as PROPOSED
        ▼
    RULE_PROPOSAL ──(human approves in app)──► SAFETY_RULE (versioned, ACTIVE)
                                                    │
    RAW → CONF → P360 layers                        │
    (persons, meds, fills, dx, claims, labs)        ▼
                    └──────────────► DT_CASE_CANDIDATE (dynamic table = detection)
                                                    │  MERGE on refresh
                                                    ▼
                                             CASE_REGISTRY (mutable lifecycle)
                                                    │
                                             reconciler SQL → CASE_EVIDENCE
                                             (AGREES/CONFLICTS/MISSING + citations)
                                                    │
                                             Streamlit in Snowflake (warehouse runtime)
                                             queue → case detail → cited answer → disposition
                                                    │
                                             AUDIT_EVENT (append-only)

    Cortex Search service over DOC_CHUNK ──► passage retrieval for citations & Q&A
    AI_COMPLETE (Claude) ──────────────────► narrative explanation over evidence bundle
    Semantic view over P360 (stretch) ─────► governed structured Q&A

## 2. Components, each with its constraint and its reason

### 2.1 Document ingest + chunking
Documents land in a stage; a task parses them into `CONF_SAFETY_DOCUMENT`
(one row per document, full text + metadata) and `DOC_CHUNK` (one row per
section, ~500–1500 chars, keyed doc_id + section_label). Chunk at *section*
boundaries, not fixed windows — our citations are "SAFETY_DOC_007, section 3",
and the chunk key IS the citation.

### 2.2 Rule extraction (the one AI step)
`AI_COMPLETE('<claude-model>', PROMPT(...))` over the full document text (not
chunks — a rule's precondition and interval can sit in different paragraphs).
Strict JSON schema (spike/prompts/extraction_prompt.md). Output parsed into
`RULE_PROPOSAL` with status PROPOSED. **Runs at ingest, never live in the
demo.** Model: verify entitlement first —
`SELECT AI_COMPLETE('claude-opus-5','Reply with: ok');` — try candidates, pick
the most capable that answers, record a GA fallback in DECISIONS. Set
temperature to the minimum supported; determinism is worth more than flair.

### 2.3 Approval → rule library
The app shows extracted fields beside the highlighted source passage
(raw interval phrase → normalized days, per DECISIONS R3). Approve = INSERT
into `SAFETY_RULE` (version 1, ACTIVE, approver, timestamp) + UPDATE proposal
status + `AUDIT_EVENT`. Rules are immutable rows; corrections insert version
n+1 and flip the old row to SUPERSEDED. At approval time the app surfaces any
ACTIVE rule with the same (drug, condition, test) so overlap is a conscious
decision (DECISIONS R6).

### 2.4 Case detection (dynamic table) — the design nuance that matters
`DT_CASE_CANDIDATE` is a dynamic table joining ACTIVE rules to P360 timelines.
**Dynamic tables are query results — they cannot hold mutable state.** A
reviewer's disposition must not vanish on the next refresh. Therefore:

- `DT_CASE_CANDIDATE` (dynamic): pure detection, deterministic, no state.
- `CASE_REGISTRY` (regular table): the app's refresh action runs
  `ALTER DYNAMIC TABLE DT_CASE_CANDIDATE REFRESH;` then MERGEs candidates in —
  new candidate → new OPEN case; existing case → untouched; candidate gone +
  case OPEN → auto-annotated RESOLVED_BY_DATA. Dispositions update only
  CASE_REGISTRY.

Platform constraints honored (amended 2026-08-20 — see §5 + DAY1_DECISIONS):
ALL dynamic tables are created with `SCHEDULER = DISABLE` (no TARGET_LAG
anywhere — the two cannot be combined) and `REFRESH_MODE = FULL` declared
explicitly, because non-deterministic functions and subquery operators each
block incremental refresh and AUTO would silently downgrade. The refresh
button runs the ordered cascade in sql/07 (a manual refresh of a disabled
table does not cascade upstream). No stored procedures/external functions
inside DT definitions — the reconciler is a separate step, not embedded.
Every "today" in detection reads `CONF.DATE_ANCHOR.as_of` (one row,
2026-09-01, never moved) — determinism plus a demo date that cannot go stale.

Detection predicate (full SQL shape in docs/03 §6): person has ACTIVE drug ∧
precondition met ∧ **no qualifying test result** where qualifying means test
maps via vocabulary AND result_date ≥ anchor AND result_date ≥
DATE_ANCHOR.as_of − (interval + grace), with **anchor = GREATEST(drug_start,
condition_onset, rule_effective_date)** — this one GREATEST implements edge cases 8.2/8.3.

### 2.5 Evidence reconciler
Plain SQL over each registry case, producing `CASE_EVIDENCE` rows: claim text,
verdict (AGREES/CONFLICTS/MISSING), and per-claim citations (source table +
row id, or doc_id + section). Conflict TYPES are engineered
(e.g., EHR ACTIVE ∧ no fill in expected window ∧ optional note mention);
instances are data-driven — unscripted patients fire them too. MISSING rows
always carry the `searched` string. The LLM never assigns verdicts; it only
narrates them.

### 2.6 Cited answers
Two tiers. **Tier 1 (demo-critical): template.** The case narrative is
assembled from rule fields + evidence rows — deterministic, always works.
**Tier 2 (enhancement, first on the cut list): free-text Q&A** — explicit
Python orchestration: fixed evidence-retrieval functions + Cortex Search for
passages → bundle → AI_COMPLETE writes the answer with citations, instructed
to say "the available evidence does not answer that" when it doesn't. No
Cortex Agent: the Agents API is unavailable from SiS warehouse runtime, and
explicit orchestration is the *auditable tool selection* argument anyway.

### 2.7 Cortex Search service
Over `DOC_CHUNK.chunk_text`, ATTRIBUTES doc_id + section_label (+ status), so
results filter and cite by construction. Requires `ALTER TABLE DOC_CHUNK SET
CHANGE_TRACKING = TRUE` before CREATE. Own TARGET_LAG (e.g., 5 minutes) — and
note for the live-document beat: after loading the fresh doc, the service may
need its own manual refresh if we search it immediately; the beat's critical
path (extract → approve → detect) does not depend on Search at all, by design.

### 2.8 Semantic view (stretch — build only if core is green by 26 Aug)
`CREATE SEMANTIC VIEW` over P360 person/timeline/case tables (native object,
current recommended approach over YAML stages). Gives governed structured Q&A
and scores "semantic model authoring". It is an enhancement; nothing in the
demo's critical path uses it.

### 2.9 Streamlit in Snowflake — warehouse runtime
Four pages (docs/05). Warehouse runtime confirmed sufficient because nothing
calls the Agents API. The app runs under the reviewer role; the governance
demo beat is real RBAC, not a slide.

### 2.10 Audit
`AUDIT_EVENT` append-only: rule proposed/approved/superseded/retired, case
created/refreshed, disposition recorded — who, when, what, why. The closing
demo line ("every decision here is attributable and reversible") is a SELECT
over this table.

## 3. Schemas & roles (small on purpose)

DB `HEALTHONE`; schemas `RAW`, `CONF`, `P360`, `RULES`, `CASES`, `APP`.
Roles: `HO_ADMIN` (build), `HO_REVIEWER` (app runtime: read P360/RULES/CASES,
write dispositions + approvals via app), `HO_AUDITOR` (read-only, one demo
sentence). One masking policy on person name/DOB — applied on P360_PERSON
only, NEVER on join keys such as person_id (2026-08-20, D4) — for the
governance beat: cheap, real, visible. Row-level policy is on the cut list.

## 4. Failure modes and their designed answers

| Failure | Designed answer |
|---|---|
| Extraction unstable across runs | Approval gate is the mitigation (stated openly); golden spike catches it day 1; narrow schema/prompt before adapting design |
| Model entitlement changes | GA fallback model recorded; extraction re-runnable at ingest |
| DT refresh slow on stage | Manual REFRESH button; tiny demo data; rehearsed |
| Cortex Search index lag on fresh doc | Critical path avoids Search; manual service refresh if needed |
| Free-text Q&A misbehaves live | Tier-1 template answer is the demo; Q&A is optional garnish |
| A wrong rule gets approved | Versioning + supersede + open-case re-flag (edge 8.6) |
| Reviewer dismissals pile up on one rule | Dismissal reasons are structured; threshold flags the rule for re-review (edge 8.7) |

## 5. Cost guardrails (hard constraint, decided 2026-08-20 — DAY1_DECISIONS §3)

~$400 of trial credit funds the entire month. Every standing-compute decision
below is deliberate; do not relax any of them without a dated DECISIONS row.

1. **All dynamic tables: `SCHEDULER = DISABLE`** (and therefore no TARGET_LAG —
   the two cannot be combined). The original 60-second lag on
   DT_CASE_CANDIDATE would resume HO_WH every minute; Snowflake bills a 60s
   minimum per resume ≈ 24 credits/day ≈ ~290 credits over the build. All
   refresh is manual via the app button / sql/07.
2. **Manual refresh does not cascade upstream** of a disabled table, so sql/07
   refreshes in dependency order: P360_MEDICATION_TIMELINE →
   P360_LAB_TIMELINE → P360_ACTIVE_MEDICATION → P360_PERSON →
   DT_CASE_CANDIDATE → MERGE → RESOLVED_BY_DATA sweep.
3. **`REFRESH_MODE = FULL` declared explicitly** on every DT. Non-deterministic
   functions and subquery operators (EXISTS/IN/ANY/ALL) each block incremental
   refresh, so incremental was never reachable; AUTO would have silently
   downgraded. Declaring FULL makes the behavior a decision, not an accident.
4. **Resource monitor on HO_WH:** CREDIT_QUOTA = 60, MONTHLY; triggers 75%
   NOTIFY / 90% SUSPEND / 100% SUSPEND_IMMEDIATE (sql/00). Warehouse stays
   XSMALL, AUTO_SUSPEND = 60.
5. **Cortex Search service is not created until first needed (Day 3+)** — it
   carries a standing index cost. When created: TARGET_LAG = '1 day'; the
   document corpus is static.
