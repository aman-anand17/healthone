# End-to-end pipeline and table map

**The doc to have open next to Snowsight.** Every object in the database, where
its data comes from, what writes it, and the query that proves it. All row
counts queried live on **2026-08-30** from account `KUMZGAJ-OO64644`
(locator `PF13333`, AWS_US_EAST_2).

Total: **46 tables + 13 views across 6 data schemas**, plus `APP` for the
Streamlit object.

Start here in Snowsight: **Data → Databases → HEALTHONE**.

---

## 1. The whole pipeline on one page

```
                    ┌─────────────────────── DOCUMENT PATH ───────────────────────┐
  PDF file  ──PUT──▶ @RAW.DOC_STAGE ──AI_PARSE_DOCUMENT──▶ RAW.RAW_DOC_FILE
  (7 PDFs +          (directory table,     (Cortex, LAYOUT mode)   (21 rows, verbatim)
   7 text)            14 files)                                          │
                                                     CONF.NORMALISE_DOC_TEXT()
                                                                         │
                                            CONF.CONF_SAFETY_DOCUMENT (7) │
                                                     │                   │
                                        CONF.SP_CHUNK_DOCUMENT()         │
                                                     ▼                   │
                                            CONF.DOC_CHUNK (43)          │
                                              │           │              │
                                   Cortex Search      RULES.SP_EXTRACT_PROPOSALS
                                   CONF.DOC_SEARCH     (AI_COMPLETE, claude-sonnet-5)
                                                            │
                                            RULES.EXTRACTION_RUN (9)  ← raw model output
                                                            │
                                            RULES.RULE_PROPOSAL (5)   ← inert
                                                            │
                                        RULES.V_PROPOSAL_RESOLVED     ← text → IDs
                                                            │
                                   ══ HUMAN APPROVES ══  SP_APPROVE_PROPOSAL
                                                            ▼
                                            RULES.SAFETY_RULE (4)     ← versioned, immutable
                                                            │
  ┌──────────────── PATIENT PATH ────────────────┐          │
  9 CSVs ──PUT/COPY──▶ RAW.RAW_* (9 tables)      │          │
                          │                      │          │
              RAW → CONF transforms              │          │
                          ▼                      │          │
              CONF.CONF_* (8 tables) ────────────┘          │
              + CONF.REF_* vocabulary                       │
                          │                                 │
                          ▼                                 │
              P360.* 4 DYNAMIC TABLES ──────────────────────┤
              (PERSON, LAB_TIMELINE,                        │
               MEDICATION_TIMELINE,                         │
               ACTIVE_MEDICATION)                           │
                          │                                 │
                          └────────────┬────────────────────┘
                                       ▼
                          CASES.DT_CASE_CANDIDATE (33)  ← DYNAMIC TABLE: the detection
                                       │
                                    MERGE
                                       ▼
                          CASES.CASE_REGISTRY (33)
                                       │
                          SP_RECONCILE_EVIDENCE
                                       ▼
                          CASES.CASE_EVIDENCE (80)   ← AGREES / CONFLICTS / MISSING
                                       │
                          CASES.V_CASE_BUNDLE ──AI_COMPLETE──▶ CASES.CASE_NARRATIVE
                                       │
                                  STREAMLIT APP
                                       │
                          ══ HUMAN DECIDES ══ ▶ CASES.AUDIT_EVENT (39)
```

Two paths meet at exactly one place: `DT_CASE_CANDIDATE`, where an approved
rule is applied to a patient population. That join is the product.

---

## 2. Layer by layer, with provenance

### 2.1 `RAW` — landing zone (10 tables)

**Rule of this layer: nothing is ever rewritten.** RAW is the provenance record.
If you want to know what the parser actually returned, or what the CSV actually
said, it is here.

| Table | Rows | Where the data comes from | Written by |
|---|---|---|---|
| `RAW_EHR_PATIENT` | 312 | `build/data/raw_ehr_patient.csv` | `COPY INTO` (build/run_all.sql) |
| `RAW_PLAN_MEMBER` | 312 | `build/data/raw_plan_member.csv` | `COPY INTO` |
| `RAW_EHR_DIAGNOSIS` | 100 | `build/data/raw_ehr_diagnosis.csv` | `COPY INTO` |
| `RAW_EHR_MED_ORDER` | 62 | `build/data/raw_ehr_med_order.csv` | `COPY INTO` |
| `RAW_EHR_CLINICAL_NOTE` | 584 | `build/data/raw_ehr_clinical_note.csv` | `COPY INTO` |
| `RAW_LAB_RESULT` | 291 | `build/data/raw_lab_result.csv` | `COPY INTO` |
| `RAW_PLAN_CLAIM` | 3,738 | `build/data/raw_plan_claim.csv` | `COPY INTO` |
| `RAW_PLAN_PHARMACY_FILL` | 866 | `build/data/raw_plan_pharmacy_fill.csv` | `COPY INTO` |
| `RAW_DOC_FILE` | 21 | `@RAW.DOC_STAGE`, parsed by `AI_PARSE_DOCUMENT` | `CONF.SP_INGEST_DOCUMENTS` |
| `RAW_SAFETY_DOCUMENT` | 4 | **Legacy.** The original CSV document load. | `COPY INTO` |

**Who created the CSVs:** `tools/generate_data.py`, seed `20260901`, all dates
relative to the anchor. Fully synthetic, deterministic — same seed, same data.
The two source systems are deliberately *not* identical: the EHR and the payer
disagree about some patients, which is what makes `MED_CONFLICT` cases real
rather than staged.

**`RAW_SAFETY_DOCUMENT` is honestly legacy.** It holds 4 documents from the old
CSV path. The live document path is `RAW_DOC_FILE` ← the stage, which holds all
7. It is left in place rather than dropped because `sql/03` still reads it and
removing it is a change with no benefit on submission eve. **If you see 4 where
you expect 7, this is why.**

**Two stages:**

| Stage | Holds | Notes |
|---|---|---|
| `@RAW.HO_STAGE` | The 9 patient CSVs | Plain internal stage |
| `@RAW.DOC_STAGE` | 14 document files (7 PDF + 7 text) | Directory table enabled, `SNOWFLAKE_SSE` — both required for `AI_PARSE_DOCUMENT` |

Check in Snowsight: **Data → Databases → HEALTHONE → RAW → Stages**.

```sql
SELECT * FROM DIRECTORY(@HEALTHONE.RAW.DOC_STAGE) ORDER BY RELATIVE_PATH;
SELECT * FROM HEALTHONE.CONF.V_DOC_STAGE_FILES ORDER BY RELATIVE_PATH;
```

### 2.2 `CONF` — conformed layer (16 tables, 1 view)

**Rule of this layer: cleaned, typed, vocabulary-mapped — and it is where a
value can legitimately become NULL** because it could not be mapped.

| Table | Rows | Comes from | Notes |
|---|---|---|---|
| `DATE_ANCHOR` | 1 | Seeded | `2026-09-01`. Every "days overdue" is measured from here, so results are reproducible instead of drifting with the wall clock. |
| `REF_DRUG` | 3 | Seeded | CardioZen, Renuvex, Hepatrol — all invented. |
| `REF_CONDITION` | 3 | Seeded | CKD, CLD, hypothyroidism. |
| `REF_LAB_TEST` | 4 | Seeded | potassium, creatinine, ALT, TSH. |
| `REF_LAB_TEST_SYNONYM` | 9 | Seeded | The controlled vocabulary. **`'k+ serum level'` is deliberately absent.** |
| `CONF_PERSON_XWALK` | 312 | CSV | The identity spine: one `PERSON_ID` joining a `PATIENT_ID` (hospital) to a `MEMBER_ID` (insurer). |
| `CONF_LAB_RESULT` | 291 | `RAW_LAB_RESULT` | **7 rows have `LAB_TEST_ID = NULL`** — the vocabulary gap. `NUMBER(12,4)`, not FLOAT: a lab value must not drift in binary. |
| `CONF_MEDICATION` | 62 | `RAW_EHR_MED_ORDER` | Drug text mapped to `DRUG_ID`. |
| `CONF_DIAGNOSIS` | 100 | `RAW_EHR_DIAGNOSIS` | Condition text mapped to `CONDITION_ID`. |
| `CONF_CLAIM_LINE` | 3,738 | `RAW_PLAN_CLAIM` | Payer-side corroboration. |
| `CONF_PHARMACY_FILL` | 866 | `RAW_PLAN_PHARMACY_FILL` | Whether the drug is actually being collected. |
| `CONF_CLINICAL_NOTE` | 584 | `RAW_EHR_CLINICAL_NOTE` | Narrative context. |
| `CONF_SAFETY_DOCUMENT` | 7 | `RAW_DOC_FILE` via `NORMALISE_DOC_TEXT()` | One row per document. |
| `DOC_CHUNK` | 43 | `SP_CHUNK_DOCUMENT()` | One row per **section**. The section label IS the citation. |
| `DOC_INGEST_LOG` | 21 | `SP_INGEST_DOCUMENTS` | One row per file per run. `PARSER_USED` names the parser that actually ran. |
| `DOC_PARSER_CONFIG` | 1 | Seeded | `PARSE_DOCUMENT` \| `NATIVE_TEXT`. One row; flipping it switches the parser. |

The **7 unmapped labs are the single most important number in the system.**
They are real potassium results that cannot satisfy any rule because their test
name is not in the vocabulary. Patient `PER-001131` has a case *because of it*.
The product surfaces the number instead of hiding it, and assertion A-02
protects the gap from being helpfully "fixed".

```sql
-- the vocabulary gap, and what it costs
SELECT TEST_TEXT, COUNT(*) FROM HEALTHONE.CONF.CONF_LAB_RESULT c
JOIN HEALTHONE.RAW.RAW_LAB_RESULT r ON r.LAB_ID = c.LAB_RESULT_ID
WHERE c.LAB_TEST_ID IS NULL GROUP BY 1;
```

### 2.3 `P360` — the Patient & Member 360 (4 dynamic tables)

**All four are DYNAMIC TABLES with `SCHEDULER = DISABLE` and
`REFRESH_MODE = FULL`.** They refresh only when something calls
`ALTER DYNAMIC TABLE ... REFRESH`. That is a cost decision: an auto-refreshing
dynamic table bills whether or not the data changed, and this data changes when
someone loads a file.

| Dynamic table | Rows | Grain | Why it exists |
|---|---|---|---|
| `P360_PERSON` | 312 | One row per person | The unified patient. `NAME` and `DOB` carry masking policies here. |
| `P360_LAB_TIMELINE` | 291 | One row per lab result | Chronological, vocabulary-mapped. |
| `P360_MEDICATION_TIMELINE` | 935 | One row per medication event | Orders and fills interleaved. |
| `P360_ACTIVE_MEDICATION` | 55 | **One row per (person, drug)** | Therapy start = `MIN(START_DATE)`. |

`P360_ACTIVE_MEDICATION`'s grain is the subtle one. Two independent aggregates
(order-side and fill-side) are joined **after** grouping, not before. Joining
first multiplies rows and produces two candidates with one `CANDIDATE_KEY`,
which aborts the case `MERGE`. That is hazard H-01, and
`DMF_DUP_ACTIVE_MEDS` monitors for it daily.

Refresh order is **mandatory** — a manual refresh does not cascade upstream:

```sql
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_MEDICATION_TIMELINE REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_LAB_TIMELINE        REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_ACTIVE_MEDICATION   REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.P360.P360_PERSON              REFRESH;
ALTER DYNAMIC TABLE HEALTHONE.CASES.DT_CASE_CANDIDATE       REFRESH;
```

Also in `P360`: the **semantic view** `HEALTHONE_360` — 3 tables, 2
relationships, 7 dimensions, 4 metrics. In Snowsight it appears under
**P360 → Semantic Views**, not under Tables.

```sql
SHOW SEMANTIC VIEWS IN SCHEMA HEALTHONE.P360;
SELECT * FROM SEMANTIC_VIEW(HEALTHONE.P360.HEALTHONE_360
  METRICS cases.case_count DIMENSIONS cases.case_type, cases.priority);
```

### 2.4 `RULES` — proposals and governed rules (5 tables, 3 views)

| Object | Rows | Written by | Notes |
|---|---|---|---|
| `EXTRACTOR_CONFIG` | 1 | `sql/24` / the app | Which engine reads documents. Currently `AI_COMPLETE` / `claude-sonnet-5`. |
| `PROMPT_TEMPLATE` | 1 | `sql/24` | The extraction prompt **stored as data**, so what is sent to the model is inspectable. |
| `EXTRACTION_RUN` | 9 | `SP_EXTRACT_PROPOSALS` | The model's raw response, kept whether or not it parsed. `PARSED_OK` separates "found nothing" from "could not be read". |
| `RULE_PROPOSAL` | 5 | `SP_EXTRACT_PROPOSALS` | Candidate rules. **Inert** — nothing here affects detection. |
| `SAFETY_RULE` | 4 | `SP_APPROVE_PROPOSAL` | Governed, versioned, immutable. |
| `V_EXTRACTION_VOCAB` | view | — | The controlled vocabulary handed to the extractor. Its only knowledge of the world. |
| `V_EXTRACTION_RUN` | view | — | Runs with the response parsed + an `OUTCOME` sentence. |
| `V_PROPOSAL_RESOLVED` | view | — | Free text → governed IDs, plus `RESOLVE_STATUS` and `BLOCKING_REASON`. |

```sql
-- the whole lineage: document → proposal → rule, in one query
SELECT r.RULE_ID, r.VERSION, r.DOC_ID, r.SOURCE_PASSAGE,
       r.INTERVAL_SOURCE_PHRASE, r.INTERVAL_DAYS, r.GRACE_DAYS,
       p.MODEL_NAME, p.PROMPT_VERSION, r.APPROVED_BY, r.APPROVED_AT, r.STATUS
FROM HEALTHONE.RULES.SAFETY_RULE r
JOIN HEALTHONE.RULES.RULE_PROPOSAL p ON p.PROPOSAL_ID = r.SOURCE_PROPOSAL_ID
ORDER BY r.RULE_ID, r.VERSION;
```

### 2.5 `CASES` — detection, evidence, audit (7 tables, 5 views)

| Object | Rows | Written by | Notes |
|---|---|---|---|
| `DT_CASE_CANDIDATE` | 33 | **DYNAMIC TABLE** | Where detection happens. Read the definition — it is the product's core logic. |
| `CASE_REGISTRY` | 33 | `MERGE` from the candidate table | The durable queue. Keeps human decisions across refreshes. |
| `CASE_EVIDENCE` | 80 | `SP_RECONCILE_EVIDENCE` | 5 claim types per case, each AGREES / CONFLICTS / MISSING with citations. |
| `CASE_NARRATIVE` | 1 | `da.narrative()` | Cached prose, keyed by evidence fingerprint. `GENERATOR` names what wrote it. |
| `AUDIT_EVENT` | 39 | Every procedure | Append-only, hash-chained. |
| `AUDIT_CHECKPOINT` | 3 | `sql/11` | The sealed reference the integrity check compares against. |
| `PIPELINE_RUN_LOG` | 2 | `SP_RUN_PIPELINE` | Every run: trigger, duration, deltas. |
| `V_CASE_BUNDLE` | view | — | **The exact payload the AI receives.** |
| `V_CASE_FINGERPRINT` | view | — | Hash of the evidence, so a stale narrative cannot be shown. |
| `V_CASE_NARRATIVE_CURRENT` | view | — | Narrative + whether it is still current. |
| `V_AUDIT_INTEGRITY` | view | — | Recomputes the chain. |
| `V_PIPELINE_STATUS` | view | — | Whether a run is needed. |

**The detection logic, in words.** For each (person, active rule):

```
window_start = GREATEST( therapy start date,
                         condition onset date,
                         anchor - (interval_days + grace_days) )

a case exists when the last qualifying lab result date < window_start
                  (a person with NO result at all counts as 1900-01-01)
```

`GREATEST` of three dates is the part worth understanding. Without therapy start
you raise cases against people who only began the drug last week. Without
condition onset you raise cases for a period when the rule did not apply to
them. Without the anchor term the window is unbounded. Golden checks 4 and 5
bracket the grace boundary exactly — 93 days: no case; 99 days: case.

```sql
-- read the detection logic yourself
SELECT GET_DDL('TABLE','HEALTHONE.CASES.DT_CASE_CANDIDATE');
```

### 2.6 `SEC` — governance (4 tables, 4 views)

| Object | Rows | Notes |
|---|---|---|
| `PHI_REVEAL_REASON` | 4 | The closed list of reason codes. Free text alone is not a reason. |
| `PHI_REVEAL_GRANT` | 0 | Live break-glass grants. Empty = nobody is currently revealed. |
| `REVIEWER_ASSIGNMENT` | 3 | Which clinics a reviewer may see (row access policy). |
| `PHI_INVENTORY_SNAPSHOT` | 15 | Classified columns. A snapshot table because `INFORMATION_SCHEMA` needs session context the app does not have. |
| `V_PHI_INVENTORY` | view | "Where is the patient data, and is it protected?" |
| `V_DATA_QUALITY` | view | 6 readings, each with a threshold and a reason. |
| `V_ACTIVE_REVEAL` | view | Who is revealed right now. |
| `V_SESSION_DIAGNOSTIC` | view | What the current session can see. Built because a row policy once hid all 312 patients and nothing said so. |

Not tables, but in `SEC`: 6 masking policies, 1 row access policy, 2 object
tags, 4 data metric functions, `PERSON_TOKEN()`, `REQUEST_PHI_REVEAL()`.

In Snowsight these are under **HEALTHONE → SEC → Policies / Tags / Functions** —
*not* under Tables, which is why they look missing if you only expand Tables.

```sql
-- prove masking is attached, not just defined
SELECT POLICY_NAME, REF_COLUMN_NAME
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
  REF_ENTITY_NAME => 'HEALTHONE.P360.P360_PERSON', REF_ENTITY_DOMAIN => 'TABLE'));

-- prove it enforces
SELECT PERSON_ID, NAME, DOB, PATIENT_ID FROM HEALTHONE.P360.P360_PERSON LIMIT 3;
-- expect: *** NAME WITHHELD ***, 1900-01-01, P****
```

---

## 3. What runs when

| Trigger | What happens | Cost posture |
|---|---|---|
| **App: Run intake** | Stage refresh → parse → chunk → search refresh → extract | On demand |
| **App: Approve** | One `SAFETY_RULE` row + audit | Negligible |
| **App: Run this rule** | 5 dynamic table refreshes → MERGE → report delta | On demand |
| **App: Run pipeline** | Change-aware: 4 stream checks, exits early if nothing changed | On demand |
| **Task `T_HEALTHONE_PIPELINE`** | Same pipeline, `USING CRON 0 6 * * * UTC` | **SUSPENDED by default** |
| **Data metric functions** | 4 metrics, `USING CRON 30 6 * * * UTC` | Serverless, daily, cheap aggregates |
| **Cortex Search `DOC_SEARCH`** | Re-index | `TARGET_LAG = '1 day'` + forced refresh on ingest |
| **Dynamic tables** | Nothing on their own | `SCHEDULER = DISABLE` |
| **Warehouse `HO_WH`** | X-Small, `AUTO_SUSPEND = 60` | Sleeps after a minute idle |
| **Resource monitor `HO_BUDGET`** | 40 credits/month; notify 60/80, suspend 90, kill 100 | **1.1 credits used** |

Nothing in this system spends money while nobody is looking, except the daily
DMF evaluations and one search re-index. Verify:

```sql
SHOW TASKS IN DATABASE HEALTHONE;                    -- expect: suspended
SELECT "name","state" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SHOW RESOURCE MONITORS;                              -- expect: used_credits low
SELECT NAME, COUNT(*) FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
GROUP BY 1;                                          -- expect: only your manual runs
```

---

## 4. Where each thing on screen comes from

| On screen | Table / view | Function |
|---|---|---|
| Review queue rows | `CASES.CASE_REGISTRY` + `RULES.SAFETY_RULE` | `da.list_cases` |
| Pseudonym `PT-…****` | `SEC.PERSON_TOKEN()` | — |
| Case header, priority factors | `CASES.CASE_REGISTRY` | `da.get_case` |
| Evidence with verdicts | `CASES.CASE_EVIDENCE` | `da.get_case` |
| Narrative prose | `CASES.CASE_NARRATIVE` ← `AI_COMPLETE` | `da.narrative` |
| "What an AI would receive" | `CASES.V_CASE_BUNDLE` | `da.case_bundle` |
| Real name after break-glass | `P360.P360_PERSON` + `SEC.PHI_REVEAL_GRANT` | `da.get_identity` |
| Staging area list | `CONF.V_DOC_STAGE_FILES` ← `DIRECTORY(@RAW.DOC_STAGE)` | `da.stage_files` |
| Ingest log | `CONF.DOC_INGEST_LOG` | `da.ingest_log` |
| Extraction engine panel | `RULES.EXTRACTOR_CONFIG` + `PROMPT_TEMPLATE` | `da.extractor_config` |
| Proposals + blocking reasons | `RULES.V_PROPOSAL_RESOLVED` | `da.resolved_proposals` |
| Rule library | `RULES.SAFETY_RULE` | `da.list_rules` |
| Corpus search results | Cortex Search `CONF.DOC_SEARCH` | `da.search_documents` |
| Analytics answers | `P360.HEALTHONE_360` (semantic view) | `da.ask_semantic` |
| Data quality | `SEC.V_DATA_QUALITY` | `da.data_quality` |
| PHI inventory | `SEC.V_PHI_INVENTORY` | `da.phi_inventory` |
| Pipeline history | `CASES.PIPELINE_RUN_LOG` | `da.pipeline_runs` |
| Audit trail | `CASES.AUDIT_EVENT` | `da.audit_trail` |
| Integrity verdict | `CASES.V_AUDIT_INTEGRITY` | `da.audit_integrity` |
| Break-glass log | `SEC.PHI_REVEAL_GRANT` + audit | `da.reveal_history` |

Every one of these is a query in [app/data_access.py](../app/data_access.py).
There is **no hardcoded data anywhere in the app** except the five pre-declared
semantic-view questions and the fixture file used when no account is reachable.

---

## 5. Rebuilding from nothing

```bash
./tools/sfx sql -f sql/26_new_account_setup.sql   # ACCOUNTADMIN, once
./tools/deploy_new_account                        # everything else, ~5 min
./tools/sfx sql -f sql/28_ai_extraction_cutover.sql
```

Then verify:

```bash
./tools/sfx sql -f tests/assertions.sql            # 47/47
./tools/sfx sql -f tests/test_detection_golden.sql # 16/16
./tools/sfx sql -f tests/test_document_intake.sql  # 17/17
SNOWFLAKE_HOME="$HOME/.snowflake-ho360" python tests/smoke_app.py   # 28/28
```

`tools/deploy_new_account` exists because the account had to be replaced the day
before feature freeze, and "rebuild it by hand from the project journal" is not a
recovery plan. Building the new account from the files alone is also what
exposed the unattached masking policies — a defect nine days old that no amount
of reading would have found.

Last updated: 2026-08-30.
