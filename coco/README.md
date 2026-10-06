# CoCo CLI session evidence

Real output from Cortex Code CLI (`cortex`) v1.1.104 run against the live
Snowflake account, captured the same day it ran.

**This folder was empty until 6 October 2026, and that was deliberate.** The
rule held throughout the build was: nothing goes in here that did not come out
of a CoCo session. For five weeks CoCo could not be installed — the first three
hackathon accounts had no Cortex entitlement, and a fourth was refused on the
trial tier — so the folder stayed empty rather than being filled with
plausible-looking transcripts. An artifact written after the fact proves
nothing, and a reviewer who finds one stops believing the rest.

## How these were produced

```powershell
$env:SNOWFLAKE_HOME = "$HOME\.snowflake-ho360"   # not optional - see below
$exe = "$env:LOCALAPPDATA\cortex\<version>\cortex.exe"

& $exe exec -c hackathon5 --allowed "sql" --max-turns 16 --no-history "<task>"
```

`SNOWFLAKE_HOME` is set **first and always**. CoCo reads
`~/.snowflake/connections.toml` by default, which on the build machine holds an
unrelated corporate credential. Pinning it to the project's own directory means
CoCo sees only the five disposable hackathon profiles — verified with
`cortex connections list`, which returned those five and nothing else.

`--allowed "sql"` is required: in `exec` mode interactive approvals are
auto-rejected, so the built-in SQL tool is blocked unless named explicitly.
That cost two failed runs to discover and is written here so nobody repeats it.

## What is in each file

### `planning/2026-10-06_data_model_review.out`

CoCo given the live account and asked, as an independent data architect, for the
two strongest and two weakest design decisions, with an explicit instruction not
to flatter. It inspected the schemas itself.

**Read `planning/2026-10-06_data_model_review_RESPONSE.md` alongside it.** One
of its two criticisms was correct and sharper than our own note — the
`CROSS JOIN` to `DATE_ANCHOR` forecloses incremental refresh regardless of the
scheduler setting, which we had not written down. The other was wrong about the
schema but fair about the demo data, and the response says so with the query
output that settles it. A review nobody argues with was not a review.

### `development/2026-10-06_pipeline_run.out`

CoCo driving the full document pipeline in one session: count the stage
directory, call `SP_INGEST_EXTRACT_ALL`, list the resolved proposals, call
`SP_RUN_PIPELINE`. It reported backend `AI_COMPLETE`, 7 documents, 43 chunks,
5 pending proposals including the `SAFETY_DOC_008` 60-day supersession, then
33 open cases and 80 evidence rows — every figure matching the counts verified
independently through the Snowflake CLI.

Worth noting: its closing line reminds itself to save the artifact to
`coco/<phase>/`. That instruction comes from `AGENTS.md` in the repository root,
so CoCo is reading and following the project's own agent guidance.

### `validation/2026-10-06_skill_case_review.out`

The project's own skill, `patient-evidence-review`, used end to end. CoCo loaded
the skill, picked the highest-priority open case, named the governing rule and
the model that extracted it, quoted the document phrase verbatim, and listed
each evidence verdict with its real record ids — then recommended a disposition
with a reason rather than just classifying.

### `skills/`

The skill itself lives at `.cortex/skills/patient-evidence-review/SKILL.md`,
where CoCo discovers it. Registered with:

```powershell
& $exe skill add ".cortex/skills/patient-evidence-review"
& $exe skill list        # confirms it under [EXTERNAL]
```

Every object name and query in that skill was **executed** against the account
before being written down. The first draft, written from memory, named four
procedures that do not exist; a skill that confidently calls a missing procedure
looks like a broken database rather than a wrong instruction.
