# sql/ — the whole account, as ordered scripts

Every object in the Snowflake account is created by a file in here. There is no
step that was clicked in a web console, which is why the account could be
rebuilt from scratch three times when trial accounts expired.

**You do not run these by hand.** `tools/deploy_new_account` runs them in
dependency order and is idempotent, so re-running it is safe:

```bash
HO_PROFILE=<profile> tools/sfx sql -f sql/26_new_account_setup.sql   # needs ACCOUNTADMIN
HO_SF=./tools/sfx HO_PROFILE=<profile> tools/deploy_new_account
```

Numbers are **chronological, not a priority order.** A file with a higher
number may fix or supersede a lower one — that history is left visible on
purpose rather than being squashed, because several of those fixes are the
interesting part of the design.

## Reading the STATUS header

Most files open with a `STATUS:` line, and it is the project's rule that it must
be true:

```
-- STATUS: EXECUTED 2026-10-06 against account <id> via tools/sfx. Ran clean.
-- STATUS: SUPERSEDED 2026-08-30 by sql/24 + sql/25. NEVER EXECUTED.
-- STATUS: DRAFT -- never executed.
```

A file stays `DRAFT` until a session records it actually running against an
account, and the claim has to be backed by something checkable — the objects it
creates, or the test suite that covers it. Current state: **32 EXECUTED, 4
SUPERSEDED, none DRAFT.** Six later files carry their provenance in the opening
comment block rather than on a `STATUS:` line.

Some headers name an account that has since expired. That is deliberate — it is
the account the file was executed against on that date, and three trial
accounts were lost during this build. The **current** account is the one in the
[README](../README.md).

## The layers, in build order

| Files | What they build |
|---|---|
| `00` | Database, schemas, roles, warehouse |
| `01` | `REF_*` — drug, condition, lab-test vocabularies and their synonyms |
| `02` | `RAW_*` — landing tables, in the shape four real source systems deliver |
| `03`, `03b` | `CONF_*` — conformance: vocabulary mapping and the identity crosswalk |
| `04` | `P360_*` — the Patient & Member 360, as dynamic tables |
| `05`, `05b`, `12` | The rule model, and the first seeded rules |
| `06`, `06b` | Case detection (`DT_CASE_CANDIDATE` → `CASE_REGISTRY`) and the evidence reconciler |
| `07`, `17`, `18` | On-demand refresh, rule runs, and the self-running task pipeline |
| `14`, `23`, `24` | Document intake: stage, `AI_PARSE_DOCUMENT`, chunking, the extraction engine |
| `27` | Cortex enablement, and the Cortex Search service over the document corpus |
| `10`, `16` | PHI protection: pseudonyms, masking policies, tags, break-glass |
| `11` | The hash-chained audit trail and its integrity view |
| `15` | The governed semantic view |
| `19` | Data metric functions — data quality as a monitored property |
| `25`, `31` | Proposal resolution, the approval gate, the per-rule on/off switch |
| `32`, `37` | The nine corroboration checks, and the snapshot the app reads |
| `26`, `29`, `30` | New-account bootstrap, RBAC, cost controls |
| `33`, `34` | Entitlement probes — run these **before** depending on Cortex |
| `36` | A read-only service user for sharing the app |
| `99` | Grants that need ACCOUNTADMIN, listed separately so they can be reviewed |

## Four files are superseded, and kept on purpose

They carry `STATUS: SUPERSEDED ... NEVER EXECUTED. Do not run.` in their first
line, and each names what replaced it. They are kept because they contain the
reasoning that produced a design, and deleting a file deletes the record of a
decision.

| File | Replaced by | Why it was superseded |
|---|---|---|
| `08_extraction.sql` | `24` + `25` | Written as a full extraction implementation, then never run — the engine was rebuilt once Cortex was confirmed working |
| `09_cortex_search.sql` | `27` | Written against an account where `EMBED_TEXT_768` was blocked. `27` creates the service for real |
| `13_approve_rule_v2.sql` | the product itself | Rehearsed the version-bump demo beat as a script. `SAFETY_DOC_008` now produces a real proposal that `SP_APPROVE_PROPOSAL` turns into `RUL-001` v2, so the beat is performed by the product instead |
| `13b_revert_to_v1.sql` | the product itself | Reset the stage after `13`. Leaving `SAFETY_DOC_008` as `PROPOSED` is the reset, so there is nothing to revert |

`tools/deploy_new_account` does not run any of them.

## Files whose names admit a fix, and what they fixed

Worth reading if you want to know where the sharp edges were. Four of these
five are the same root cause, and it is a good one.

**`CURRENT_USER()` returns NULL inside Streamlit in Snowflake.** The app runs in
a UDF sandbox with no session user. Everything worked from the CLI and broke
in-account, three separate ways:

| File | The defect |
|---|---|
| `20_sis_compat.sql` | Every procedure took its actor from `CURRENT_USER()`. In-account that was NULL, which violated `NOT NULL` on `AUDIT_EVENT.ACTOR` — so the audit trail refused writes |
| `21_fix_row_scope.sql` | The row access policy matched `CURRENT_USER()` against a reviewer-assignment table, so in-account it filtered **every** patient out. Worse than a blank screen: the case page computes an age band with a `CASE` whose `ELSE` is `'85+'`, so a NULL age from a data-access failure rendered as a plausible clinical value |
| `22_fix_reveal_predicate.sql` | The masking policies unmask only when a grant's `GRANTED_TO = CURRENT_USER()`. Against NULL that is never true, so break-glass **never unmasked anything** in the deployed app. `tests/assertions.sql` A-15 exists because of this |
| `28_ai_extraction_cutover.sql` | Not the same cause. `RUL-001/002/003` were hand-typed inserts labelled honestly as `MODEL_NAME='manual-seed'`. This replaces them with rules a model actually read out of a document and a human approved, without orphaning anything already approved |
| `37_corroboration_snapshot.sql` | The corroboration view costs ~25s to read. Explains why a materialized view is impossible here (view + UDF + non-deterministic) |

The lesson that generalised: **anything that works from the CLI must be
re-verified in-account.** A fix that is only proven in the place it was easy to
test is not proven.

## Input data

| Where | What |
|---|---|
| `tools/generate_data.py` | Generates the synthetic CSVs for `RAW_*`. 312 people, including 8 golden patients pinned to 8 detection edge cases |
| `corpus/*.md` | The safety documents in source form, human-readable |
| `staging/documents/*.pdf` | The same documents as PDFs. **These are the real input** — they are uploaded to an internal stage and read by `AI_PARSE_DOCUMENT`, so the pipeline parses a binary document rather than markdown it was handed |
