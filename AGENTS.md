# AGENTS.md — instructions for CoCo CLI and other agents in this repo

**Project:** HealthOne 360 / Patient Safety Case Investigator.
Snowflake CoCo CLI Hackathon 2026, GCC Edition.
Challenge: Patient & Member 360 + Clinical/Regulatory Document Copilot.

**What it is, in one line:** it turns prose drug-safety guidance into
human-approved, versioned monitoring rules, runs them deterministically over a
synthetic Patient & Member 360, and raises review cases with reconciled,
cited evidence.

**The principle that governs every change:**

> AI proposes → human approves → deterministic checks apply → human decides.

If a change would let a model decide that a case exists, or resolve a conflict
between two source systems, it is wrong regardless of how well it works.

---

## Read before generating anything

These are authoritative. Prefer them over inference from the code.

| Question | File |
|---|---|
| Settled decisions — **do not relitigate** | `docs/DECISIONS.md` |
| Architecture and platform constraints | `docs/02_ARCHITECTURE.md` |
| Exact tables, columns, keys; detection and reconciler logic | `docs/03_DATA_MODEL.md` |
| Synthetic data spec, incl. the 8 golden patients | `docs/04_SYNTHETIC_DATA_SPEC.md` |
| Streamlit pages and behaviour | `docs/05_UI_SPEC.md` |
| What "green" means | `docs/06_TESTING.md` |
| What is real vs. deliberately simplified | `docs/WALKTHROUGH_what_is_real.md` |
| What each tab does | `docs/APP_GUIDE.md` |

If a request conflicts with `docs/DECISIONS.md`: **stop and ask.**

---

## Running against the account

```bash
export SNOWFLAKE_HOME="$HOME/.snowflake-ho360"
HO_PROFILE=<profile> tools/sfx sql -q "..."
```

**Never read or write `~/.snowflake/`.** That is the CLI's default location and
may hold an unrelated credential belonging to the machine's owner. This project
keeps its own credentials in an isolated `SNOWFLAKE_HOME`, and `tools/sfx` pins
it. `tools/sfx` has no default profile and exits non-zero without `HO_PROFILE`
— an earlier version defaulted, and silently deployed to a dead account for a
while.

### CoCo CLI invocation, including two things that cost failed runs

```bash
cortex skill add .cortex/skills/patient-evidence-review
cortex exec -c <conn> --allowed "sql" --max-turns 10 "<task>"
```

- `--allowed "sql"` is **required** in `exec` mode. `exec` auto-rejects
  approval prompts, so the SQL tool is blocked unless it is named. The tool is
  called `sql`, not `sql_execute`.
- `SNOWFLAKE_HOME` must be exported **before** launching `cortex`; it reads
  `~/.snowflake/connections.toml` otherwise.

### The entry points — call these, do not reimplement them

| Procedure | Does |
|---|---|
| `RULES.SP_INGEST_EXTRACT_ALL(actor, refresh)` | Stage → `AI_PARSE_DOCUMENT` → chunk → `AI_COMPLETE` extraction. Stops at `PROPOSED`. |
| `RULES.SP_APPROVE_PROPOSAL(proposal_id, actor, grace_days)` | **The gate.** The only path that writes a `SAFETY_RULE`. |
| `RULES.SP_REJECT_PROPOSAL(proposal_id, actor, reason)` | Rejects, with the reason audited. |
| `RULES.SP_SET_RULE_ENABLED(rule_id, on, actor, reason)` | Pause/resume a rule without touching cases it already raised. |
| `RULES.SP_REFRESH_CORROBORATION()` | Recompute `RULES.CORROBORATION_SNAPSHOT`. |
| `CASES.SP_RUN_PIPELINE(trigger, refresh, actor)` | Refresh the 360, detect, reconcile evidence. |

Read corroboration from `RULES.CORROBORATION_SNAPSHOT`, **not** from
`RULES.V_PROPOSAL_CORROBORATION`. The view is the definition and the source of
truth, but it costs ~25s to read (a Python UDF plus regex per proposal) and the
app renders it on every page load. See `sql/37_corroboration_snapshot.sql` for
why a materialized view is impossible here.

---

## Do

- **Everything inside one Snowflake account.** No external APIs, ever.
- LLM is Cortex `AI_COMPLETE`. The model in production is **`claude-sonnet-5`**
  — probe entitlement before depending on any other, and record a GA fallback.
- Case detection is **deterministic SQL in a dynamic table**. Intermediates use
  `TARGET_LAG = DOWNSTREAM`; no stored procedures or external functions in a
  dynamic table definition. Mutable case state lives in `CASES.CASE_REGISTRY`,
  never in the dynamic table.
- Streamlit **in** Snowflake, WAREHOUSE runtime. No Cortex Agents API — it
  needs container runtime, which that runtime is not.
- **Interval arithmetic is literal.** Twelve weeks is 84 days, not 90. Six
  weeks is 42, not 45. Grace windows are explicit and separate.
- `as_of` comes from `CONF.DATE_ANCHOR` (one row, 2026-09-01). **Never
  `CURRENT_DATE`** — dynamic tables must stay deterministic.
- Negative evidence uses this wording verbatim: *"No <test> result was found in
  the available records between <start> and <end>."*
- Naming: `UPPER_SNAKE_CASE`, with `RAW_`/`CONF_`/`P360_`/`REF_` prefixes per
  `docs/03_DATA_MODEL.md`.
- Synthetic data only. The invented drugs are CardioZen, Renuvex, Hepatrol.
  Every generated document carries a disclaimer.
- Any claim added to a doc must be **executed first.** An earlier draft of the
  CoCo skill named four procedures that did not exist.

## Don't

- No external APIs. No ML risk scores. No opaque priority — priority must
  decompose into visible rule factors.
- No free-form generated SQL in the app. Fixed retrieval functions and the
  semantic view only.
- Never let anything but `SP_APPROVE_PROPOSAL` create a rule.
- Never resolve an evidence `CONFLICT` automatically, in SQL, in the app, or in
  a skill. Report both sides and name who to ask.
- No FHIR conformance layer. No speculative abstraction — smallest working
  vertical slice, always demoable.
- Never commit a credential. `CREATE USER ... PASSWORD` statements stay for a
  human to run by hand.

---

## Custom skills

- **`patient-evidence-review`** — `.cortex/skills/patient-evidence-review/SKILL.md`.
  Investigates one case end to end: the rule, the model that extracted it, the
  document phrase quoted verbatim, every evidence verdict with record ids. It
  is forbidden from resolving a `CONFLICT` on a reviewer's behalf.

Register it with `cortex skill add .cortex/skills/patient-evidence-review`.

## Session evidence

Output of real CoCo sessions is kept in `coco/<phase>/YYYY-MM-DD_topic.out`,
with a `README.md` per phase. **Nothing goes in `coco/` that did not come from
an actual CoCo session** — it is evidence, not a brochure. After completing a
task through CoCo, save the session output there the same day.
