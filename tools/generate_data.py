#!/usr/bin/env python3
"""
Synthetic data generator for HealthOne 360.

Spec: docs/04_SYNTHETIC_DATA_SPEC.md + docs/self-tracking/03_SCHEMA_DESIGN.md.

WHAT THIS PRODUCES
    build/data/*.csv        one file per RAW_ table
    build/load_raw.sql      stage + file format + COPY INTO statements
    build/put_commands.txt  the PUT commands to upload the CSVs

DESIGN RULES THAT ARE NOT NEGOTIABLE
    1. Every date is computed relative to ANCHOR (2026-09-01), never to the
       run date. Regenerating in December must reproduce identical output.
       This is why the demo cannot go stale and why the golden tests hold.
    2. Fixed RNG seed. Same seed -> byte-identical CSVs.
    3. Deterministic ids (PER-001024, not a UUID) so golden tests can name
       people and keep naming the same people after a regeneration.
    4. At most ONE ACTIVE medication order per (person, drug) — assertion
       A-06. Two would produce duplicate CANDIDATE_KEYs downstream and abort
       the MERGE mid-demo (hazard H-01).
    5. No clinical date after ANCHOR (A-09). No onset before date of birth.
    6. Every person exists on BOTH sides (patient + member) with the same
       name and DOB (A-10); the crosswalk is emitted from ground truth
       because the generator created both sides.

USAGE
    python tools/generate_data.py            # generate into build/
    python tools/generate_data.py --load     # generate, then load via snow CLI
"""

from __future__ import annotations

import argparse
import csv
import random
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ANCHOR = date(2026, 9, 1)          # must equal CONF.DATE_ANCHOR.AS_OF
SEED = 20260901
BATCH_ID = f"GEN-{SEED}"
CONNECTION = "hackathon"
STAGE = "HEALTHONE.RAW.HO_STAGE"

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build" / "data"
CORPUS = REPO / "corpus"

# Documents loaded during normal operation. SAFETY_DOC_008 is deliberately
# EXCLUDED — it is the held-back document introduced live on stage to show a
# new document becoming a governed rule (docs/HACKATHON.md demo beat 4).
DOCS_TO_LOAD = ["SAFETY_DOC_005", "SAFETY_DOC_006", "SAFETY_DOC_007", "SAFETY_DOC_009"]
DOCS_HELD_BACK = ["SAFETY_DOC_008"]

# Rule R-001 v1, seeded manually in sql/05 (never depends on extraction, which
# is blocked by the Cortex trial restriction). Used here only to reason about
# which people should and should not produce cases.
RULE_INTERVAL = 90
RULE_GRACE = 7
RULE_WINDOW = RULE_INTERVAL + RULE_GRACE            # 97 days
RULE_V2_WINDOW = 60 + 7                             # 67 days, after SAFETY_DOC_008

DRUGS = {
    "CardioZen": "DRG-CARDIOZEN",
    "Renuvex": "DRG-RENUVEX",
    "Hepatrol": "DRG-HEPATROL",
}
CONDITIONS = {
    "chronic kidney disease": "CND-CKD",
    "hypothyroidism": "CND-HYPOTHYROID",
    "chronic liver disease": "CND-CLD",
}

# Lab test spellings as they appear in the raw feed. "canonical" and "synonym"
# both map through CONF.REF_LAB_TEST / REF_LAB_TEST_SYNONYM. "unmapped" does
# NOT map, on purpose — see GP3 below.
LAB_TEXT = {
    "LAB-K": {
        "canonical": ["serum potassium"],
        "synonym": ["potassium, serum", "potassium"],
        "unmapped": ["K+ serum level"],
        "units": "mmol/L",
        "normal": (3.5, 5.2),
        "high": (5.3, 6.1),
    },
    "LAB-CREAT": {
        "canonical": ["serum creatinine"],
        "synonym": ["creatinine"],
        "unmapped": ["creat (serum)"],
        "units": "mg/dL",
        "normal": (0.6, 1.3),
        "high": (1.4, 3.0),
    },
    "LAB-TSH": {
        "canonical": ["TSH"],
        "synonym": ["thyroid stimulating hormone"],
        "unmapped": ["thyrotropin level"],
        "units": "mIU/L",
        "normal": (0.4, 4.0),
        "high": (4.1, 9.0),
    },
    "LAB-ALT": {
        "canonical": ["ALT"],
        "synonym": ["alanine aminotransferase"],
        "unmapped": ["ALT (SGPT) serum"],
        "units": "U/L",
        "normal": (10, 45),
        "high": (46, 140),
    },
}
CONDITION_LAB = {
    "CND-CKD": "LAB-K",
    "CND-HYPOTHYROID": "LAB-TSH",
    "CND-CLD": "LAB-ALT",
}

CLINICS = ["Northgate Clinic", "Riverside Clinic", "Eastfield Clinic"]
PLAN_CODES = ["HO-STANDARD", "HO-PLUS"]

FIRST_NAMES = [
    "Aisha", "Alan", "Amara", "Anders", "Beatrice", "Callum", "Camila", "Daniel",
    "Deepa", "Edith", "Elias", "Farida", "Fergus", "Gloria", "Hamish", "Hana",
    "Ibrahim", "Ingrid", "Jasper", "Joanna", "Kwame", "Lena", "Lucas", "Mabel",
    "Mateo", "Nadia", "Nikolai", "Olive", "Omar", "Priya", "Quentin", "Rosa",
    "Rupert", "Sanjay", "Sofia", "Tobias", "Ursula", "Vikram", "Wilma", "Yusuf",
]
LAST_NAMES = [
    "Abbott", "Bergstrom", "Castellano", "Devereux", "Eriksen", "Falconer",
    "Grimaldi", "Halvorsen", "Ibarra", "Jankowski", "Kaminski", "Lindqvist",
    "Mcallister", "Nakamura", "Oyelaran", "Pemberton", "Quintero", "Rasmussen",
    "Sandoval", "Thornbury", "Ueda", "Vasquez", "Whitlock", "Yamamoto", "Zielinski",
]

AUTHOR_ROLES = ["Nephrologist", "General Physician", "Clinical Pharmacist",
                "Hepatologist", "Endocrinologist"]


def d(days_before_anchor: int) -> date:
    """A date N days before the anchor. The only way dates are made here."""
    return ANCHOR - timedelta(days=days_before_anchor)


def iso(x: date | None) -> str:
    return "" if x is None else x.isoformat()


# ---------------------------------------------------------------------------
# Row accumulators — one list per RAW table, in CSV column order
# ---------------------------------------------------------------------------

class Tables:
    def __init__(self) -> None:
        self.patient: list[list] = []
        self.member: list[list] = []
        self.xwalk: list[list] = []      # not a RAW table; loaded to CONF directly
        self.diagnosis: list[list] = []
        self.med_order: list[list] = []
        self.note: list[list] = []
        self.lab: list[list] = []
        self.claim: list[list] = []
        self.fill: list[list] = []
        self.document: list[list] = []
        self._seq = {}

    def next_id(self, prefix: str) -> str:
        """Deterministic sequential id per prefix."""
        n = self._seq.get(prefix, 0) + 1
        self._seq[prefix] = n
        return f"{prefix}{n:06d}"


T = Tables()


def add_person(patient_id: str, member_id: str, name: str, dob: date,
               sex: str, clinic: str, plan: str, enrolled_days_ago: int) -> str:
    """Create both sides of one human plus the crosswalk row. Returns person_id."""
    T.patient.append([patient_id, name, iso(dob), sex, clinic, BATCH_ID])
    T.member.append([member_id, name, iso(dob), plan,
                     iso(d(enrolled_days_ago)), "", BATCH_ID])
    person_id = "PER-" + re.sub(r"\D", "", patient_id).zfill(6)
    T.xwalk.append([person_id, patient_id, member_id,
                    "DETERMINISTIC_SYNTHETIC", "1.00"])
    return person_id


def add_diagnosis(patient_id: str, condition_name: str,
                  onset_days_ago: int, recorded_days_ago: int | None = None) -> None:
    if recorded_days_ago is None:
        recorded_days_ago = max(0, onset_days_ago - 14)
    T.diagnosis.append([
        T.next_id("DXR-"), patient_id, condition_name,
        iso(d(onset_days_ago)), iso(d(recorded_days_ago)), BATCH_ID,
    ])


def add_med_order(patient_id: str, drug: str, status: str,
                  start_days_ago: int, stop_days_ago: int | None = None) -> str:
    """A-07: an ACTIVE order must never carry a stop date."""
    if status == "ACTIVE":
        stop_days_ago = None
    order_id = T.next_id("ORD-")
    T.med_order.append([
        order_id, patient_id, drug, status,
        iso(d(start_days_ago)),
        iso(d(stop_days_ago)) if stop_days_ago is not None else "",
        BATCH_ID,
    ])
    return order_id


def add_fills(member_id: str, drug: str, first_days_ago: int,
              last_days_ago: int, rng: random.Random, cadence: int = 30) -> None:
    """Fill chain from first to last, walking backwards from the last fill."""
    day = last_days_ago
    while day <= first_days_ago:
        T.fill.append([T.next_id("FLL-"), member_id, drug, iso(d(day)), "30", BATCH_ID])
        day += rng.randint(cadence - 3, cadence + 3)


def add_lab(patient_id: str, lab_test_id: str, days_ago: int,
            spelling: str, rng: random.Random, elevated: bool = False) -> None:
    cfg = LAB_TEXT[lab_test_id]
    text = rng.choice(cfg[spelling])
    lo, hi = cfg["high" if elevated else "normal"]
    value = round(rng.uniform(lo, hi), 2)
    T.lab.append([T.next_id("LBR-"), patient_id, text, iso(d(days_ago)),
                  f"{value}", cfg["units"], BATCH_ID])


def add_claim(member_id: str, days_ago: int, desc: str, dx_text: str,
              provider: str) -> None:
    T.claim.append([T.next_id("CLA-"), member_id, iso(d(days_ago)), desc,
                    dx_text, provider, BATCH_ID])


def add_note(patient_id: str, days_ago: int, role: str, text: str) -> None:
    T.note.append([T.next_id("NTE-"), patient_id, iso(d(days_ago)), role, text, BATCH_ID])


# ---------------------------------------------------------------------------
# The eight golden patients (docs/04 §2)
#
# Rule under test: R-001 v1 = CardioZen + CKD -> serum potassium every 90 days,
# grace 7, so the qualifying window starts 97 days before the anchor.
#
# Every golden patient gets a healthy recent fill chain UNLESS the test is
# about fills, so that no unintended MED_CONFLICT case appears. The golden
# suite asserts each person produces exactly ONE case (or none) — an
# accidental second case is a failure.
# ---------------------------------------------------------------------------

def build_golden(rng: random.Random) -> dict[str, str]:
    ids = {}

    # ---- GP1 / P1024 — the hero case. Gap of 137 days against a 97-day window.
    # Priority must come out HIGH: 137 >= 90 + 7 + 30.
    pid, mid = "P1024", "M8842"           # M8842 matches fixtures/answer_contract.json
    ids["GP1"] = add_person(pid, mid, "Priya Raghunathan", date(1957, 4, 12),
                            "F", CLINICS[0], PLAN_CODES[1], 2200)
    add_diagnosis(pid, "chronic kidney disease", 660)
    add_med_order(pid, "CardioZen", "ACTIVE", 211)
    add_fills(mid, "CardioZen", 211, 28, rng)
    add_lab(pid, "LAB-K", 137, "canonical", rng)          # the gap
    add_lab(pid, "LAB-K", 240, "canonical", rng)          # earlier, also stale
    add_lab(pid, "LAB-CREAT", 137, "canonical", rng, elevated=True)
    add_claim(mid, 155, "Nephrology outpatient review", "chronic kidney disease",
              "Northgate Renal Service")
    add_claim(mid, 320, "Nephrology outpatient review", "chronic kidney disease",
              "Northgate Renal Service")
    add_note(pid, 150, "Nephrologist",
             "Renal function stable. Continuing CardioZen at current dose. "
             "Advised routine bloods at next review.")

    # ---- GP2 / P1088 — the conflict case. EHR says ACTIVE, pharmacy has
    # dispensed nothing for 150 days, and a note records the patient stopping.
    # Given a RECENT potassium so the ONLY case is MED_CONFLICT: this patient's
    # monitoring is fine, the question is whether they are taking the drug.
    pid, mid = "P1088", "M8906"
    ids["GP2"] = add_person(pid, mid, "Tobias Lindqvist", date(1962, 9, 30),
                            "M", CLINICS[1], PLAN_CODES[0], 1900)
    add_diagnosis(pid, "chronic kidney disease", 520)
    add_med_order(pid, "CardioZen", "ACTIVE", 400)
    add_fills(mid, "CardioZen", 400, 150, rng)            # stops 150 days ago
    add_lab(pid, "LAB-K", 30, "canonical", rng)           # recent -> no gap case
    add_claim(mid, 200, "Nephrology outpatient review", "chronic kidney disease",
              "Riverside Renal Service")
    add_note(pid, 140, "Clinical Pharmacist",
             "Telephone review. Patient reports stopping CardioZen approximately "
             "four months ago due to dizziness. Has not collected recent "
             "prescriptions. Prescriber to review whether therapy should resume.")

    # ---- GP3 / P1131 — the dismissible near-miss. A potassium result exists
    # from 20 days ago, but the lab recorded it as "K+ serum level", a spelling
    # deliberately absent from REF_LAB_TEST_SYNONYM. The vocabulary join misses
    # it, so a gap case fires for a patient who WAS tested. The reviewer sees
    # the result in the raw timeline and dismisses with a reason.
    pid, mid = "P1131", "M8951"
    ids["GP3"] = add_person(pid, mid, "Amara Oyelaran", date(1949, 1, 22),
                            "F", CLINICS[2], PLAN_CODES[1], 2600)
    add_diagnosis(pid, "chronic kidney disease", 900)
    add_med_order(pid, "CardioZen", "ACTIVE", 300)
    add_fills(mid, "CardioZen", 300, 22, rng)
    add_lab(pid, "LAB-K", 20, "unmapped", rng)            # exists but unmappable
    add_claim(mid, 120, "Nephrology outpatient review", "chronic kidney disease",
              "Eastfield Renal Service")
    add_note(pid, 20, "General Physician",
             "Routine bloods taken today, results within expected range.")

    # ---- GP4 — boundary IN. Last potassium 93 days ago; window is 97 days,
    # so this patient is inside the grace period and must NOT produce a case.
    # GP4 and GP5 bracket the boundary exactly.
    pid, mid = "P1204", "M9004"
    ids["GP4"] = add_person(pid, mid, "Fergus Halvorsen", date(1953, 6, 8),
                            "M", CLINICS[0], PLAN_CODES[0], 2000)
    add_diagnosis(pid, "chronic kidney disease", 700)
    add_med_order(pid, "CardioZen", "ACTIVE", 400)
    add_fills(mid, "CardioZen", 400, 25, rng)
    add_lab(pid, "LAB-K", 93, "canonical", rng)
    add_claim(mid, 110, "Nephrology outpatient review", "chronic kidney disease",
              "Northgate Renal Service")

    # ---- GP5 — boundary OUT. Last potassium 99 days ago, just past 97.
    # Priority MEDIUM: 99 < 90 + 7 + 30, so this is recently overdue, not badly.
    pid, mid = "P1205", "M9005"
    ids["GP5"] = add_person(pid, mid, "Rosa Quintero", date(1951, 11, 3),
                            "F", CLINICS[1], PLAN_CODES[1], 2100)
    add_diagnosis(pid, "chronic kidney disease", 750)
    add_med_order(pid, "CardioZen", "ACTIVE", 420)
    add_fills(mid, "CardioZen", 420, 26, rng)
    add_lab(pid, "LAB-K", 99, "canonical", rng)
    add_claim(mid, 130, "Nephrology outpatient review", "chronic kidney disease",
              "Riverside Renal Service")

    # ---- GP6 — the stale-lab trap. A potassium result 30 days BEFORE therapy
    # started and none since. A naive "any result within N days" query would
    # count it. The window is anchored to therapy start, so it must not.
    pid, mid = "P1206", "M9006"
    ids["GP6"] = add_person(pid, mid, "Hamish Pemberton", date(1946, 2, 17),
                            "M", CLINICS[2], PLAN_CODES[0], 2400)
    add_diagnosis(pid, "chronic kidney disease", 800)
    add_med_order(pid, "CardioZen", "ACTIVE", 200)
    add_fills(mid, "CardioZen", 200, 24, rng)
    add_lab(pid, "LAB-K", 230, "canonical", rng)          # 30 days pre-therapy
    add_claim(mid, 210, "Nephrology outpatient review", "chronic kidney disease",
              "Eastfield Renal Service")

    # ---- GP7 — compliant. Potassium 40 days ago under a canonical name.
    # Must stay quiet under rule v1 AND under the stricter v2 (67-day window),
    # which is why the §14 ruling matters: effective_date does not reset the
    # clock on an already-acceptable result.
    pid, mid = "P1207", "M9007"
    ids["GP7"] = add_person(pid, mid, "Ingrid Bergstrom", date(1958, 8, 25),
                            "F", CLINICS[0], PLAN_CODES[1], 1800)
    add_diagnosis(pid, "chronic kidney disease", 600)
    add_med_order(pid, "CardioZen", "ACTIVE", 380)
    add_fills(mid, "CardioZen", 380, 20, rng)
    add_lab(pid, "LAB-K", 40, "canonical", rng)
    add_lab(pid, "LAB-K", 130, "synonym", rng)
    add_claim(mid, 60, "Nephrology outpatient review", "chronic kidney disease",
              "Northgate Renal Service")

    # ---- GP8 — precondition gate. On CardioZen with NO chronic kidney disease
    # and no recent potassium. The rule's precondition must genuinely gate it.
    pid, mid = "P1208", "M9008"
    ids["GP8"] = add_person(pid, mid, "Quentin Whitlock", date(1966, 12, 1),
                            "M", CLINICS[1], PLAN_CODES[0], 1500)
    add_diagnosis(pid, "hypothyroidism", 500)            # a condition, but not CKD
    add_med_order(pid, "CardioZen", "ACTIVE", 350)
    add_fills(mid, "CardioZen", 350, 27, rng)
    add_lab(pid, "LAB-TSH", 70, "canonical", rng)
    add_claim(mid, 80, "Endocrinology review", "hypothyroidism",
              "Riverside Endocrine Service")

    # ---- Live-beat cohort. On CardioZen with CKD, last potassium 75-90 days
    # ago: comfortably inside v1's 97-day window (invisible), and outside v2's
    # 67-day window (they appear the moment the tightened rule is approved).
    # This cohort IS the demo's climax and it is arithmetic, not scripting.
    beat = [
        ("P1301", "M9101", "Mabel Thornbury", date(1944, 5, 19), "F", 75),
        ("P1302", "M9102", "Sanjay Vasquez", date(1955, 3, 7), "M", 80),
        ("P1303", "M9103", "Olive Kaminski", date(1961, 10, 28), "F", 85),
        ("P1304", "M9104", "Elias Nakamura", date(1950, 7, 14), "M", 90),
    ]
    for i, (pid, mid, name, dob, sex, k_days) in enumerate(beat):
        ids[f"BEAT{i + 1}"] = add_person(pid, mid, name, dob, sex,
                                         CLINICS[i % 3], PLAN_CODES[i % 2], 1700)
        add_diagnosis(pid, "chronic kidney disease", 700)
        add_med_order(pid, "CardioZen", "ACTIVE", 400)
        add_fills(mid, "CardioZen", 400, 25, rng)
        add_lab(pid, "LAB-K", k_days, "canonical" if i % 2 == 0 else "synonym", rng)
        add_claim(mid, k_days + 20, "Nephrology outpatient review",
                  "chronic kidney disease", "Northgate Renal Service")

    return ids


# ---------------------------------------------------------------------------
# Background cohort — realistic noise. Detection must work on people nobody
# scripted, so these are generated from distributions, not hand-placed. Some
# WILL produce cases; that is the point (docs/04 §1).
# ---------------------------------------------------------------------------

RESERVED = {"P1024", "P1088", "P1131", "P1204", "P1205", "P1206", "P1207",
            "P1208", "P1301", "P1302", "P1303", "P1304"}


def build_background(rng: random.Random, n: int = 300) -> None:
    made = 0
    candidate = 1000
    while made < n:
        pid = f"P{candidate}"
        candidate += 1
        if pid in RESERVED:
            continue
        mid = f"M{7000 + made}"
        made += 1

        # Age 25-90, skewed toward 55+.
        age = rng.choice([rng.randint(25, 54), rng.randint(55, 90), rng.randint(55, 90)])
        dob = ANCHOR - timedelta(days=int(age * 365.25) + rng.randint(0, 364))
        sex = rng.choice(["F", "M"])
        name = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"
        clinic = rng.choice(CLINICS)
        plan = rng.choice(PLAN_CODES)
        add_person(pid, mid, name, dob, sex, clinic, plan, rng.randint(400, 2800))

        # Conditions. Onset 1-8 years back, never before birth.
        max_onset = min(int((ANCHOR - dob).days) - 365, 8 * 365)
        person_conditions = []
        for cond, prevalence in (("chronic kidney disease", 0.12),
                                 ("hypothyroidism", 0.10),
                                 ("chronic liver disease", 0.06)):
            if rng.random() < prevalence and max_onset > 400:
                onset = rng.randint(365, max_onset)
                add_diagnosis(pid, cond, onset)
                person_conditions.append((cond, onset))
                # A condition is sometimes recorded twice (different encounters).
                # Deliberate: proves the dx_agg pre-aggregation in
                # DT_CASE_CANDIDATE actually prevents duplicate cases (H-02).
                if rng.random() < 0.08:
                    add_diagnosis(pid, cond, onset - rng.randint(5, 60))

        has_ckd = any(c == "chronic kidney disease" for c, _ in person_conditions)

        # Medications. CardioZen ~6%, two thirds of those also CKD — the
        # interesting overlap. Renuvex ~5%, Hepatrol ~4%.
        drugs_for_person = []
        if rng.random() < (0.14 if has_ckd else 0.035):
            drugs_for_person.append("CardioZen")
        if rng.random() < 0.05:
            drugs_for_person.append("Renuvex")
        if rng.random() < 0.04:
            drugs_for_person.append("Hepatrol")

        for drug in drugs_for_person:
            start = rng.randint(90, 1095)                 # 3 months - 3 years
            # ~12% of orders are STOPPED rather than ACTIVE.
            if rng.random() < 0.12:
                add_med_order(pid, drug, "STOPPED", start, rng.randint(10, start - 10))
                continue
            add_med_order(pid, drug, "ACTIVE", start)
            # ~85% have a plausible fill chain reaching the present; the rest
            # are ragged and become natural MED_CONFLICT candidates without
            # being scripted.
            if rng.random() < 0.85:
                add_fills(mid, drug, start, rng.randint(10, 45), rng)
            else:
                add_fills(mid, drug, start, rng.randint(120, min(start, 400)), rng)

        # Labs. People with a condition get the matching test 1-6 times over
        # 18 months. ~70% canonical spelling, ~28% mapped synonym, ~2% an
        # unmapped variant — the P1131 mechanism occurring in the wild.
        for cond, onset in person_conditions:
            lab_id = CONDITION_LAB[CONDITIONS[cond]]
            # CardioZen + CKD patients are mostly monitored, so the background
            # contributes a handful of genuine gap cases rather than dozens.
            compliant = rng.random() < 0.6
            for _ in range(rng.randint(1, 6)):
                days = rng.randint(5, 90) if compliant else rng.randint(100, 540)
                roll = rng.random()
                spelling = "canonical" if roll < 0.70 else ("synonym" if roll < 0.98 else "unmapped")
                add_lab(pid, lab_id, min(days, onset), spelling, rng,
                        elevated=rng.random() < 0.15)

        # Claims, 2-10 per year over 2 years. Diagnosed people get
        # condition-linked lines — the payer-side confirmation the hero
        # finding relies on.
        for _ in range(rng.randint(4, 20)):
            days = rng.randint(1, 730)
            if person_conditions and rng.random() < 0.35:
                cond, onset = rng.choice(person_conditions)
                if days <= onset:
                    add_claim(mid, days, "Specialist outpatient review", cond,
                              f"{clinic} Specialist Service")
                    continue
            add_claim(mid, days, rng.choice([
                "General practice consultation", "Routine phlebotomy",
                "Physiotherapy session", "Diagnostic imaging",
                "Pharmacy dispensing fee", "Emergency department attendance",
            ]), rng.choice(["routine examination", "annual health check", ""]),
                f"{clinic} General Service")

        # Notes, 0-4 per person, templated prose.
        for _ in range(rng.randint(0, 4)):
            add_note(pid, rng.randint(5, 700), rng.choice(AUTHOR_ROLES),
                     rng.choice([
                         "Routine review. No new complaints. Continue current therapy.",
                         "Patient reports good adherence to medication. No adverse effects noted.",
                         "Discussed monitoring plan with patient. Bloods requested.",
                         "Blood pressure stable. Medication list reviewed and unchanged.",
                         "Follow-up arranged in three months.",
                     ]))


# ---------------------------------------------------------------------------
# Documents — read the authored corpus from corpus/*.md
# ---------------------------------------------------------------------------

def load_corpus() -> None:
    for doc_id in DOCS_TO_LOAD:
        path = CORPUS / f"{doc_id}.md"
        if not path.exists():
            sys.exit(f"ERROR: missing corpus file {path}")
        raw = path.read_text(encoding="utf-8")
        header, _, body = raw.partition("\n---\n")
        meta = {}
        for line in header.splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                meta[k.strip()] = v.strip()
        T.document.append([
            meta["DOC_ID"], meta["TITLE"], meta["PUBLISHER"],
            meta["PUBLICATION_DATE"], meta["STATUS"], body.strip(), BATCH_ID,
        ])


# ---------------------------------------------------------------------------
# CSV + load-script emission
#
# COLUMNS is the single source of truth: the CSV writer and the generated
# COPY INTO statement are both built from it, so they cannot drift apart.
# LOADED_AT is deliberately omitted everywhere — it takes its DEFAULT
# CURRENT_TIMESTAMP(), because it records when the load happened (real
# wall-clock time), not simulated clinical time.
# ---------------------------------------------------------------------------

SPECS = [
    ("raw_ehr_patient", "RAW.RAW_EHR_PATIENT",
     ["PATIENT_ID", "NAME", "DOB", "SEX", "PRIMARY_CLINIC", "LOAD_BATCH_ID"],
     lambda: T.patient),
    ("raw_plan_member", "RAW.RAW_PLAN_MEMBER",
     ["MEMBER_ID", "NAME", "DOB", "PLAN_CODE", "ENROLLED_FROM", "ENROLLED_TO", "LOAD_BATCH_ID"],
     lambda: T.member),
    ("raw_ehr_diagnosis", "RAW.RAW_EHR_DIAGNOSIS",
     ["DX_ID", "PATIENT_ID", "CONDITION_TEXT", "ONSET_DATE", "RECORDED_DATE", "LOAD_BATCH_ID"],
     lambda: T.diagnosis),
    ("raw_ehr_med_order", "RAW.RAW_EHR_MED_ORDER",
     ["ORDER_ID", "PATIENT_ID", "DRUG_TEXT", "STATUS", "START_DATE", "STOP_DATE", "LOAD_BATCH_ID"],
     lambda: T.med_order),
    ("raw_ehr_clinical_note", "RAW.RAW_EHR_CLINICAL_NOTE",
     ["NOTE_ID", "PATIENT_ID", "NOTE_DATE", "AUTHOR_ROLE", "NOTE_TEXT", "LOAD_BATCH_ID"],
     lambda: T.note),
    ("raw_lab_result", "RAW.RAW_LAB_RESULT",
     ["LAB_ID", "PATIENT_ID", "TEST_TEXT", "RESULT_DATE", "RESULT_VALUE", "UNITS", "LOAD_BATCH_ID"],
     lambda: T.lab),
    ("raw_plan_claim", "RAW.RAW_PLAN_CLAIM",
     ["CLAIM_ID", "MEMBER_ID", "SERVICE_DATE", "SERVICE_DESC", "DX_TEXT", "PROVIDER", "LOAD_BATCH_ID"],
     lambda: T.claim),
    ("raw_plan_pharmacy_fill", "RAW.RAW_PLAN_PHARMACY_FILL",
     ["FILL_ID", "MEMBER_ID", "DRUG_TEXT", "FILL_DATE", "DAYS_SUPPLY", "LOAD_BATCH_ID"],
     lambda: T.fill),
    ("raw_safety_document", "RAW.RAW_SAFETY_DOCUMENT",
     ["DOC_ID", "TITLE", "PUBLISHER", "PUBLICATION_DATE", "STATUS", "FULL_TEXT", "LOAD_BATCH_ID"],
     lambda: T.document),
    # Not a RAW table: the crosswalk is ground truth the generator owns, so it
    # loads straight to CONF rather than being derived by a fragile SQL match.
    ("conf_person_xwalk", "CONF.CONF_PERSON_XWALK",
     ["PERSON_ID", "PATIENT_ID", "MEMBER_ID", "MATCH_METHOD", "MATCH_CONFIDENCE"],
     lambda: T.xwalk),
]


def emit() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    for old in BUILD.glob("*.csv"):
        old.unlink()

    copy_stmts = [
        "-- GENERATED by tools/generate_data.py — do not edit by hand.",
        "USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;",
        "",
        "CREATE STAGE IF NOT EXISTS HEALTHONE.RAW.HO_STAGE;",
        "",
        "CREATE OR REPLACE FILE FORMAT HEALTHONE.RAW.HO_CSV",
        "  TYPE = CSV",
        "  FIELD_OPTIONALLY_ENCLOSED_BY = '\"'",
        "  SKIP_HEADER = 1",
        "  EMPTY_FIELD_AS_NULL = TRUE",
        "  NULL_IF = ('')",
        "  TRIM_SPACE = FALSE;",
        "",
    ]

    summary = []
    for filename, table, columns, getter in SPECS:
        rows = getter()
        path = BUILD / f"{filename}.csv"
        with path.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
            w.writerow(columns)
            w.writerows(rows)
        summary.append((table, len(rows)))

        selects = ", ".join(f"${i + 1}" for i in range(len(columns)))
        copy_stmts += [
            f"TRUNCATE TABLE IF EXISTS HEALTHONE.{table};",
            f"COPY INTO HEALTHONE.{table} ({', '.join(columns)})",
            f"  FROM (SELECT {selects} FROM @HEALTHONE.RAW.HO_STAGE/{filename}.csv.gz",
            f"        (FILE_FORMAT => HEALTHONE.RAW.HO_CSV))",
            "  ON_ERROR = ABORT_STATEMENT;",
            "",
        ]

    (REPO / "build" / "load_raw.sql").write_text("\n".join(copy_stmts), encoding="utf-8")

    puts = [f"PUT file://{(BUILD / f'{name}.csv').as_posix()} "
            f"@HEALTHONE.RAW.HO_STAGE AUTO_COMPRESS=TRUE OVERWRITE=TRUE;"
            for name, _, _, _ in SPECS]
    (REPO / "build" / "put_commands.sql").write_text("\n".join(puts) + "\n", encoding="utf-8")

    print(f"\nAnchor date: {ANCHOR}   seed: {SEED}   batch: {BATCH_ID}")
    print(f"Output: {BUILD}\n")
    width = max(len(t) for t, _ in summary)
    for table, n in summary:
        print(f"  {table:<{width}}  {n:>6,} rows")
    print(f"\n  {'TOTAL':<{width}}  {sum(n for _, n in summary):>6,} rows")
    print(f"\nHeld back (NOT loaded): {', '.join(DOCS_HELD_BACK)} — the live demo document.")
    print("\nNext:")
    print(f"  snow sql -c {CONNECTION} -f build/put_commands.sql")
    print(f"  snow sql -c {CONNECTION} -f build/load_raw.sql")
    print(f"  snow sql -c {CONNECTION} -f sql/03_conf.sql      # RAW -> CONF transforms")


def run_load() -> None:
    for script in ("build/put_commands.sql", "build/load_raw.sql", "sql/03_conf.sql"):
        print(f"\n=== snow sql -f {script}")
        result = subprocess.run(
            ["snow", "sql", "-c", CONNECTION, "-f", script],
            cwd=REPO, capture_output=True, text=True,
        )
        sys.stdout.write(result.stdout[-4000:])
        if result.returncode != 0:
            sys.stderr.write(result.stderr[-4000:])
            sys.exit(f"FAILED on {script} (exit {result.returncode})")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--load", action="store_true",
                    help="after generating, upload and COPY INTO via the snow CLI")
    args = ap.parse_args()

    rng = random.Random(SEED)
    golden = build_golden(rng)
    build_background(rng)
    load_corpus()
    emit()

    print("\nGolden patients:")
    for k, v in golden.items():
        print(f"  {k:<6} {v}")

    if args.load:
        run_load()


if __name__ == "__main__":
    main()
