# Response to CoCo's data-model review, 6 Oct 2026

The raw session output is in `2026-10-06_data_model_review.out`. CoCo was given
the live account and asked for two strongest and two weakest design decisions,
with an explicit instruction not to flatter. It inspected the schemas itself.

This file records what we accepted, what we rejected, and the evidence for
each. A review nobody argues with was not a review.

---

## Accepted: dynamic tables all run FULL refresh with no scheduler

> "All dynamic tables run SCHEDULER=DISABLE with FULL refresh mode. There is no
> incremental refresh anywhere... With 33 rows this is invisible; at real scale
> this will be the first thing to break. The DATE_ANCHOR CROSS JOIN pattern
> also prevents Snowflake from ever electing incremental mode."

**Correct, and the diagnosis of the cause is sharper than our own note was.**

We chose `SCHEDULER = DISABLE` + `REFRESH_MODE = FULL` deliberately, for two
reasons recorded in `sql/04_p360.sql`: a demo cannot wait out a 60-second
minimum target lag, and nothing should consume credits unattended on a metered
trial. Both still hold.

What we had **not** written down is CoCo's second point: the `CROSS JOIN` to
`CONF.DATE_ANCHOR` is itself disqualifying for incremental refresh, because
every row depends on a single-row table that can change. So even if we removed
`SCHEDULER = DISABLE` tomorrow, we would not get incremental refresh — the
fixed-"today" design forecloses it.

That is a real architectural consequence of the demo-determinism choice, and it
belongs in the trade-off, not hidden behind a cost argument. Production would
replace `DATE_ANCHOR` with `CURRENT_DATE()` and accept non-reproducible tests,
or keep the anchor and accept full refresh. It cannot have both.

---

## Rejected on the design, accepted on the data: "no versioned rule history"

> "RULES schema has no versioned history table... If a rule is updated
> in-place, the previous version is lost... the absence of an immutable rule
> audit trail is a meaningful gap."

**Wrong about the design.** `SAFETY_RULE` is append-only and versioned by
construction: its grain is `(RULE_ID, VERSION)`, it carries
`SUPERSEDED_BY_VERSION`, `RETIRED_BY`, `RETIRED_AT` and `RETIRE_REASON`, and
`RULES.SP_APPROVE_PROPOSAL` **inserts a new version row** — it contains no
`UPDATE` against the rule's clinical fields. A correction is a new version;
nothing is edited in place. A separate `_HISTORY` table would duplicate what
the grain already guarantees.

**But CoCo could not have known that from the data, and that is on us.** At the
time of review the account held four rules, all at version 1:

```
RULE_ID  VERSION  STATUS  INTERVAL_DAYS  SUPERSEDED_BY_VERSION
RUL-001  1        ACTIVE  90             None
RUL-002  1        ACTIVE  90             None
RUL-003  1        ACTIVE  84             None
RUL-004  1        ACTIVE  42             None
```

Four rows, four distinct rule ids. Nothing on screen demonstrates versioning,
so an independent reviewer reasonably concluded it was absent. The mechanism is
covered by `tests/assertions.sql`, but a test is not a demo.

**Action taken:** this is a gap in the demonstration, not the schema. The
pending `SAFETY_DOC_008` proposal revises `RUL-001` from 90 days to 60 —
approving it produces `RUL-001 v2` with `v1` marked superseded and both rows
retained. That supersession is now called out in the demo script, because a
versioning claim nobody can see is a claim a reviewer is right to doubt.

---

## On the two strengths it named

It identified the medallion layering and — more usefully — the separation of
`DT_CASE_CANDIDATE` (derived, no side effects) from `CASE_REGISTRY` (mutable
workflow state), noting that detection can refresh without corrupting
in-flight reviews. That is exactly the reason for the split, and it was
inferred from the objects rather than from our documentation, which is the
strongest signal in the whole review that the structure communicates its own
intent.
