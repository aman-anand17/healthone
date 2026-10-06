# 03 — Data Model

Naming: UPPER_SNAKE_CASE; layer prefixes RAW_ / CONF_ / P360_ / (RULES and
CASES schemas carry no prefix); REF_ for controlled vocabulary. All PKs are
surrogate VARCHAR ids with readable prefixes (PER-, MED-, RUL-, CAS-…). Types
shown as Snowflake types. This document is the source of truth CoCo builds
DDL from — hand it sections, not vibes.

## 1. Layers and why

- **RAW** — one schema, tables mirroring source systems, loaded as-is from the
  synthetic generator. Mirrors real governance boundaries (provider vs payer
  sources kept in separate table families) without multi-DB ceremony.
- **CONF** — typed, deduplicated, controlled-vocabulary-mapped. Every CONF row
  keeps `source_system` + `source_record_id`: **citations exist because
  provenance is kept, not reconstructed.**
- **P360** — dynamic tables: the unified person view and timelines.
- **RULES / CASES** — the product's own state. Mostly regular tables because
  they are mutable or append-only (see 02_ARCHITECTURE §2.4).

## 2. Controlled vocabulary (CONF schema)

    REF_DRUG            drug_id PK, drug_name, drug_class, is_synthetic BOOLEAN DEFAULT TRUE
    REF_CONDITION       condition_id PK, condition_name, description
    REF_LAB_TEST        lab_test_id PK, canonical_name, loinc_like_code, units
    REF_LAB_TEST_SYNONYM synonym_text PK, lab_test_id FK NULLABLE
                        -- the P1131 mechanism lives here: the variant string
                        -- "K+ serum level" exists in RAW lab data but has NO
                        -- mapping row, so the qualifying-test join misses it,
                        -- the gap case fires, and the reviewer dismisses with
                        -- reason. Dismissal doubles as a vocabulary-improvement
                        -- story if a judge asks "then what?"

Seed: 3 drugs (CardioZen, Renuvex, Hepatrol), 3 conditions (chronic kidney
disease, hypothyroidism, chronic liver disease), 4 lab tests (serum potassium,
TSH, ALT, serum creatinine) + synonyms.

## 3. RAW layer (as generated; minimal typing)

Provider-side family:

    RAW_EHR_PATIENT        patient_id, name, dob, sex, primary_clinic
    RAW_EHR_DIAGNOSIS      dx_id, patient_id, condition_text, onset_date, recorded_date
    RAW_EHR_MED_ORDER      order_id, patient_id, drug_text, status(ACTIVE|STOPPED), start_date, stop_date NULL
    RAW_EHR_CLINICAL_NOTE  note_id, patient_id, note_date, author_role, note_text
    RAW_LAB_RESULT         lab_id, patient_id, test_text, result_date, result_value, units

Payer-side family:

    RAW_PLAN_MEMBER        member_id, name, dob, plan_code, enrolled_from, enrolled_to NULL
    RAW_PLAN_CLAIM         claim_id, member_id, service_date, service_desc, dx_text, provider
    RAW_PLAN_PHARMACY_FILL fill_id, member_id, drug_text, fill_date, days_supply

Documents:

    RAW_SAFETY_DOCUMENT    doc_id, title, publisher, publication_date, status, full_text

## 4. CONF layer

    CONF_PERSON_XWALK   person_id PK, patient_id UNIQUE, member_id UNIQUE, match_method='DETERMINISTIC_SYNTHETIC'
                        -- the isolated identity seat (01_PROBLEM_AND_WHY §8)
                        -- NO masking here or on any join key (2026-08-20 D4);
                        -- masking lives on P360_PERSON name/dob only

    DATE_ANCHOR         as_of DATE — exactly ONE row, 2026-09-01, never moved.
                        -- Every "today" in detection/refresh reads this, never
                        -- CURRENT_DATE: keeps dynamic tables deterministic and
                        -- the demo date stable (2026-08-20 D1/D6). Generator
                        -- computes all dates relative to it.

    CONF_MEDICATION     med_id PK, person_id FK, drug_id FK(REF_DRUG), status, start_date, stop_date,
                        source_system('EHR'), source_record_id
    CONF_PHARMACY_FILL  fill_id PK, person_id, drug_id, fill_date, days_supply,
                        source_system('PHARMACY'), source_record_id
    CONF_DIAGNOSIS      dx_id PK, person_id, condition_id FK, onset_date,
                        source_system('EHR'), source_record_id
    CONF_CLAIM_LINE     claim_line_id PK, person_id, service_date, condition_id NULL, service_desc,
                        source_system('CLAIMS'), source_record_id
    CONF_LAB_RESULT     lab_result_id PK, person_id, lab_test_id FK NULL, raw_test_text,
                        result_date, result_value, units, source_system('LAB'), source_record_id
                        -- lab_test_id NULL ⇔ synonym unmapped (P1131 fires here)
    CONF_CLINICAL_NOTE  note_id PK, person_id, note_date, author_role, note_text, source_record_id
    CONF_SAFETY_DOCUMENT doc_id PK, title, publisher, publication_date, status, full_text
    DOC_CHUNK           chunk_id PK, doc_id FK, section_label, chunk_text
                        -- CHANGE_TRACKING = TRUE (Cortex Search prerequisite)

## 5. P360 layer (dynamic tables; ALL with SCHEDULER=DISABLE + REFRESH_MODE=FULL
##    — no TARGET_LAG anywhere; manual ordered refresh via sql/07; docs/02 §5)

    P360_PERSON         person_id, patient_id, member_id, name, dob, sex, plan_code,
                        active_condition_count, active_med_count, open_case_count
    P360_MEDICATION_TIMELINE  person_id, drug_id, event_type('ORDER_START'|'ORDER_STOP'|'FILL'),
                        event_date, detail, source_system, source_record_id
    P360_LAB_TIMELINE   person_id, lab_test_id, raw_test_text, result_date, result_value, units,
                        source_system, source_record_id
    P360_ACTIVE_MEDICATION (helper) person_id, drug_id, start_date, ehr_status,
                        last_fill_date, fills_last_180d

## 6. RULES schema

    RULE_PROPOSAL   proposal_id PK, doc_id FK, raw_llm_output VARIANT,
                    drug_text, precondition_type, precondition_value, required_test_text,
                    interval_days INT, interval_source_phrase, effective_date,
                    source_passage, needs_review BOOLEAN, review_reason,
                    status('PROPOSED'|'APPROVED'|'REJECTED'), reviewed_by, reviewed_at,
                    created_at
                    -- raw_llm_output kept as VARIANT: debuggability + honesty

    SAFETY_RULE     rule_id, version INT, PK(rule_id,version),
                    drug_id FK, precondition_type('condition'|'age_min'|'none'),
                    condition_id FK NULL, age_min INT NULL,
                    lab_test_id FK, interval_days INT, grace_days INT DEFAULT 7,
                    interval_source_phrase, effective_date,
                    doc_id FK, source_passage,
                    status('ACTIVE'|'SUPERSEDED'|'RETIRED'),
                    approved_by, approved_at, superseded_by_version INT NULL
                    -- immutable rows; corrections insert version n+1

Approval maps proposal free-text → vocabulary FKs. Unmappable text ⇒ cannot
approve until vocabulary is extended (deliberate: rules only speak vocabulary).

## 7. CASES schema

    DT_CASE_CANDIDATE (DYNAMIC TABLE — detection only, no state;
                       SCHEDULER=DISABLE, REFRESH_MODE=FULL per docs/02 §5)
        candidate_key = HASH(person_id, rule_id, case_type),
        -- version is PAYLOAD, not part of the key (2026-08-20): a v1→v2
        -- supersede must update open cases in place, never duplicate them.
        person_id, rule_id, version, case_type('MONITORING_GAP'|'MED_CONFLICT'),
        priority('HIGH'|'MEDIUM'), priority_factors ARRAY,
        anchor_date, last_qualifying_result_date NULL, days_since_last INT NULL

    Detection predicate (MONITORING_GAP), the heart of the product:

        FROM SAFETY_RULE r
        JOIN P360_ACTIVE_MEDICATION m   ON m.drug_id = r.drug_id
        JOIN CONF_DIAGNOSIS d           ON d.person_id = m.person_id
                                        AND d.condition_id = r.condition_id
        WHERE r.status = 'ACTIVE' AND r.precondition_type = 'condition'
          AND NOT EXISTS (
              SELECT 1 FROM P360_LAB_TIMELINE l
              WHERE l.person_id = m.person_id
                AND l.lab_test_id = r.lab_test_id            -- vocabulary join
                AND l.result_date >= GREATEST(m.start_date,   -- edge 8.3
                                              d.onset_date,
                                              r.effective_date)
                AND l.result_date >= a.as_of
                                     - (r.interval_days + r.grace_days)  -- edge 8.2
          )
        -- a = CONF.DATE_ANCHOR, cross-joined; NEVER CURRENT_DATE inside a DT
        -- (2026-08-20 D1). last_qualifying_result_date comes from a
        -- pre-aggregated LEFT JOIN, not a correlated scalar subquery.

    MED_CONFLICT candidate: P360_ACTIVE_MEDICATION with ehr_status='ACTIVE'
    AND fills_last_180d = 0 (window = expected refill cadence), MEDIUM priority,
    AND drug_id ∈ (drugs named by an ACTIVE rule) — we don't create work for
    drugs nobody is monitoring (2026-08-20 D5).

    CASE_REGISTRY (regular table — lifecycle state)
        case_id PK, candidate_key UNIQUE, person_id, rule_id, version, case_type,
        priority, priority_factors ARRAY,
        status('OPEN'|'ESCALATED'|'EVIDENCE_REQUESTED'|'REVIEWED'|'DISMISSED'|'RESOLVED_BY_DATA'),
        disposition NULL, disposition_reason NULL, disposed_by NULL, disposed_at NULL,
        created_at, last_refreshed_at

    Refresh action (app button): ALTER DYNAMIC TABLE ... REFRESH; then MERGE
    candidates→registry (new: INSERT OPEN / present: touch last_refreshed_at /
    absent & OPEN: status=RESOLVED_BY_DATA + audit row).

    CASE_EVIDENCE   evidence_id PK, case_id FK, claim_text,
                    verdict('AGREES'|'CONFLICTS'|'MISSING'),
                    evidence_refs ARRAY OF OBJECT(type, source_system, source_record_id, detail),
                    searched VARCHAR NULL   -- REQUIRED when verdict='MISSING'

    AUDIT_EVENT     event_id PK, event_type, actor, at TIMESTAMP_TZ, subject_type,
                    subject_id, detail VARIANT   -- append-only; never UPDATE/DELETE

## 8. Contract mapping

fixtures/answer_contract.json assembles from: CASE_REGISTRY (case fields,
priority, disposition) + SAFETY_RULE (rule_ref incl. interval_source_phrase,
source_passage) + CASE_EVIDENCE (claims, verdicts, refs, searched) +
CONF_PERSON_XWALK (ids) + AUDIT_EVENT (audit tail). If the contract and this
model ever disagree, the contract wins for UI purposes — then fix the model
and record the change in DECISIONS.

## 9. Deliberate simplifications (say them, don't hide them)

Single account/schema-set rather than genuinely separate provider/payer
systems (boundaries mirrored by table families + provenance columns). No SCD2
history on CONF (timelines carry the history we need). No real code systems
(ICD/LOINC) — vocabulary tables play that role; loinc_like_code exists so the
seat is visible. Person matching deterministic by construction (§4 XWALK).
Each is one honest sentence in judge Q&A, and each saved a day we didn't have.
