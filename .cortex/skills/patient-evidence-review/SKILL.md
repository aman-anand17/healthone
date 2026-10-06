---
name: patient-evidence-review
description: >
  Investigate a HealthOne 360 safety case from the Snowflake CLI: read the
  evidence bundle for a case, interpret the AGREES / CONFLICTS / MISSING
  verdicts with their source citations, check the governing rule against the
  document sentence it came from, and record a disposition. Use when asked to
  look into a case, explain why a case exists, or decide what to do about one.
---

# Patient evidence review

A reusable skill for working HealthOne 360 cases through the CLI rather than
the app. Everything here is read-only except the final disposition, which is
deliberate and audited.

**Every object name and every command below was executed against the live
account before being written down.** The first draft of this file was written
from memory and named four procedures that do not exist - `SEARCH_DOCS`,
`SP_RECORD_DISPOSITION`, `V_CASE_QUEUE`, `SP_REQUEST_REVEAL`. A skill that
confidently calls a non-existent procedure is worse than no skill, because the
failure looks like a broken database rather than a wrong instruction.

## What you are looking at

A **case** says: this patient, on this drug, with this condition, is outside
the monitoring interval a named safety document requires. It was raised by SQL
arithmetic over dates - not by a model, not by a score. Your job is to read the
evidence and decide, not to re-derive whether the case is valid.

Three verdicts appear in `CASES.CASE_EVIDENCE`:

- **AGREES** - two or more independent sources support the fact.
- **CONFLICTS** - sources disagree. **Both are shown and neither wins.** Never
  resolve a conflict by preferring the newer or more convenient record; report
  that the sources disagree and let the reviewer weigh it.
- **MISSING** - expected evidence was not found. This is a finding, not an
  absence of information, and it is worded as a positive statement on purpose.

## Setup

```bash
export HO_PROFILE=hackathon5        # or a reviewer profile
```

Use `tools/sfx` for every call, never bare `snow`. The wrapper pins
`SNOWFLAKE_HOME` to a project-only directory, which is what keeps this project
away from unrelated Snowflake credentials on the machine. It exits with an
error if `HO_PROFILE` is unset - there is no default, because this project has
burned through five trial accounts and guessing which one you meant is a trap.

## The workflow

### 1. Find the work

There is no queue view; the queue is the registry joined to the 360.

```bash
tools/sfx sql -q "SELECT CASE_ID, CASE_TYPE, PRIORITY, PRIORITY_FACTORS,
                         RULE_ID, DAYS_SINCE_REFERENCE
                    FROM HEALTHONE.CASES.CASE_REGISTRY
                   WHERE STATUS = 'OPEN'
                   ORDER BY PRIORITY, DAYS_SINCE_REFERENCE DESC
                   LIMIT 10"
```

### 2. Read the bundle for one case

`CASES.V_CASE_BUNDLE` is a **view**, one row per case - not a table function.

```bash
tools/sfx sql -q "SELECT * FROM HEALTHONE.CASES.V_CASE_BUNDLE
                   WHERE CASE_ID = '<CASE_ID>'"
```

Read it in this order, because each part answers a different question:

| What to look at | The question it answers |
|---|---|
| `PRIORITY`, `PRIORITY_FACTORS` | Why is this urgent? Stated factors only - no score exists |
| `RULE_ID`, `VERSION` | Which rule, and which version of it |
| `INTERVAL_SOURCE_PHRASE` -> `INTERVAL_DAYS` | The document sentence, beside the number it became |
| `WINDOW_START_DATE`, `DAYS_SINCE_REFERENCE` | What period was evaluated, and how overdue |

Then the evidence itself:

```bash
tools/sfx sql -q "SELECT VERDICT, CLAIM_TEXT, EVIDENCE_REFS, SEARCHED
                    FROM HEALTHONE.CASES.CASE_EVIDENCE
                   WHERE CASE_ID = '<CASE_ID>'
                   ORDER BY VERDICT"
```

`CLAIM_TEXT` is the expected fact stated in words. `EVIDENCE_REFS` is a JSON
array of the source records behind that verdict, each carrying its system and
record id - that array is what lets you cite `ORD-000044` rather than say "the
EHR". `SEARCHED` records where the reconciler looked, which is what makes a
MISSING verdict meaningful rather than merely empty.

### 3. Check the rule against its own document

A case is only as good as the rule behind it:

```bash
tools/sfx sql -q "SELECT r.RULE_ID, r.VERSION, r.INTERVAL_DAYS, r.GRACE_DAYS,
                         r.INTERVAL_SOURCE_PHRASE, r.DOC_ID, r.SOURCE_PASSAGE,
                         r.APPROVED_BY, p.MODEL_NAME
                    FROM HEALTHONE.RULES.SAFETY_RULE r
                    LEFT JOIN HEALTHONE.RULES.RULE_PROPOSAL p
                           ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
                   WHERE r.RULE_ID = '<RULE_ID>' AND r.STATUS = 'ACTIVE'"
```

`MODEL_NAME` is on the PROPOSAL, not the rule - the rule records which proposal
it came from and the proposal records which engine produced it. That
indirection is deliberate: it makes "which model wrote this rule?" a join
rather than a field someone could overwrite.

Then read the section it cites, and check the phrase is really there:

```bash
tools/sfx sql -q "SELECT SECTION_LABEL, CHUNK_TEXT
                    FROM HEALTHONE.CONF.DOC_CHUNK
                   WHERE DOC_ID = '<DOC_ID>'
                   ORDER BY CHUNK_INDEX"
```

If the quoted phrase is not in the chunk text, **stop and say so**. That is a
rule whose justification does not exist, and it matters more than the case.

The nine deterministic checks that were run at approval time:

```bash
tools/sfx sql -q "SELECT DOC_ID, CORROBORATION_SCORE, CORROBORATION,
                         CHECKS_PASSED, CHECKS_APPLICABLE, CHECKLIST
                    FROM HEALTHONE.RULES.V_PROPOSAL_CORROBORATION"
```

### 4. Search the corpus for context

Cortex Search, through `SEARCH_PREVIEW` against the service:

```bash
tools/sfx sql -q "SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                    'HEALTHONE.CONF.DOC_SEARCH',
                    '{\"query\":\"<question>\",
                      \"columns\":[\"DOC_ID\",\"SECTION_LABEL\",\"CHUNK_TEXT\"],
                      \"limit\":5}')):results AS HITS"
```

If the service is unavailable the app falls back to Snowflake's lexical
`SEARCH()` and says so on screen. Quote which engine answered; do not assume
semantic retrieval ran.

### 5. Record the decision

There is no disposition procedure - it is two statements, and `STATUS` is
**derived** from the disposition rather than being the same value. The four
dispositions and the status each produces:

| Disposition | Resulting STATUS |
|---|---|
| `ESCALATE_FOR_CLINICAL_REVIEW` | `ESCALATED` |
| `REQUEST_ADDITIONAL_EVIDENCE` | `EVIDENCE_REQUESTED` |
| `MARK_REVIEWED` | `REVIEWED` |
| `DISMISS_WITH_REASON` | `DISMISSED` |

`ESCALATE_FOR_CLINICAL_REVIEW` and `DISMISS_WITH_REASON` **require** a reason.

```bash
tools/sfx sql -q "
UPDATE HEALTHONE.CASES.CASE_REGISTRY
   SET STATUS='EVIDENCE_REQUESTED', DISPOSITION='REQUEST_ADDITIONAL_EVIDENCE',
       DISPOSITION_REASON='<reason in a full sentence>',
       DISPOSED_BY='<actor>', DISPOSED_AT=CURRENT_TIMESTAMP()
 WHERE CASE_ID='<CASE_ID>';
INSERT INTO HEALTHONE.CASES.AUDIT_EVENT
  (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
SELECT 'CASE_DISPOSED', '<actor>', 'CASE', '<CASE_ID>',
       OBJECT_CONSTRUCT('disposition','REQUEST_ADDITIONAL_EVIDENCE',
                        'reason','<reason>','status','EVIDENCE_REQUESTED');"
```

Prefer doing this in the app, which enforces the reason requirement and the
status mapping for you. If you do it here, write **both** statements - a
disposition with no audit row is the one thing the audit trail exists to
prevent.

### Revealing a patient's identity

```bash
tools/sfx sql -q "CALL HEALTHONE.SEC.REQUEST_PHI_REVEAL(
                    '<PERSON_ID>', '<CASE_ID>', '<REASON_CODE>', '<reason>', '<actor>')"
```

Case-scoped, audited, and enforced by a masking policy on the column rather
than by the app. Do it only when the task genuinely requires identifying the
patient, and say that you did.

## Rules for this skill

1. **Never invent a verdict.** Every AGREES / CONFLICTS / MISSING comes from
   `CASE_EVIDENCE`. If the evidence does not say something, say that.
2. **Never resolve a CONFLICT.** Report both sources with their record ids.
   Choosing between them is a clinical judgement and not yours to make.
3. **Do not approve rules here.** Rule approval is a separate deliberate act
   (`RULES.SP_APPROVE_PROPOSAL`). This skill reviews cases.
4. **Quote, do not paraphrase, the document.** Use `INTERVAL_SOURCE_PHRASE`
   verbatim. Paraphrase is where meaning quietly changes - "every 12 weeks" is
   84 days, not 90.
5. **Verify an object exists before telling a user to call it.** See the note
   at the top of this file.

## What a good answer looks like

> Patient PT-579488 (identity withheld) is 309 days past a required serum
> potassium measurement. The governing rule is RUL-001, requiring monitoring
> every 90 days, extracted by claude-sonnet-5 from SAFETY_DOC_007 and approved
> by a named reviewer: *"serum potassium should be checked at least every three
> months for the duration of therapy."*
>
> The chronic kidney disease diagnosis **AGREES** across the EHR (DXR-000072)
> and a 2026-06-25 claim (CLA-002642). CardioZen status **CONFLICTS** - the EHR
> has it active from 2026-04-15 (ORD-000044) while pharmacy fills show the last
> dispense on 2026-04-28 and nothing in 90 days (FLL-000604). No potassium
> result was found in the required window (**MISSING**).
>
> The medication conflict is unresolved and material: if the patient stopped
> taking CardioZen, the monitoring requirement may not apply. I would record
> REQUEST_ADDITIONAL_EVIDENCE and ask whether therapy was discontinued, rather
> than escalate a gap that may not exist.

Note what that does: quotes the document, names every record id, leaves the
conflict unresolved, and recommends an action that follows from the uncertainty
instead of ignoring it.
