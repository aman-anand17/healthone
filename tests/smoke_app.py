#!/usr/bin/env python3
"""Call every data-access function against the live account and report failures.

WHY THIS EXISTS
Streamlit in Snowflake gives you one diagnostic for a broken page: a red box
that says an error occurred. Every runtime failure this project has hit -- a
NULL actor violating NOT NULL, a masking policy comparing against NULL, a
correlated subquery a view cannot evaluate, a procedure that was never created
because the file aborted three statements earlier -- was invisible until
someone clicked the exact button that touched it.

This runs every accessor in one pass, so the answer to "will the deployed app
work?" comes from calling the code rather than from clicking around.

It is READ-BIASED on purpose. Functions that change state (approve, reject,
reveal, run pipeline) are listed and skipped by default, because a smoke test
must not silently mutate the demo. Pass --mutate to include the safe subset.

Usage:
    python tests/smoke_app.py                 # read-only
    python tests/smoke_app.py --mutate        # include state-changing checks
    HO_CONNECTION=hackathon python tests/smoke_app.py   # against the old account
"""
from __future__ import annotations

import os
import sys
import traceback
from pathlib import Path

os.environ.setdefault("SNOWFLAKE_HOME", str(Path.home() / ".snowflake-ho360"))
os.environ.setdefault("HO_MODE", "local")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))

import data_access as da  # noqa: E402

PASS, FAIL, SKIP = [], [], []


def check(label, fn, expect=None):
    """expect: optional predicate on the result. A function that returns an
    empty list is not automatically a failure -- an empty queue is legitimate --
    so emptiness is only a failure where the caller says so."""
    try:
        val = fn()
    except Exception as exc:
        FAIL.append((label, f"{type(exc).__name__}: {exc}"))
        if os.environ.get("HO_SMOKE_TRACE"):
            traceback.print_exc()
        return None
    if expect is not None:
        try:
            ok, why = expect(val)
        except Exception as exc:
            FAIL.append((label, f"predicate raised {type(exc).__name__}: {exc}"))
            return val
        if not ok:
            FAIL.append((label, why))
            return val
    n = len(val) if isinstance(val, (list, dict)) else val
    PASS.append((label, n))
    return val


def nonempty(what):
    return lambda v: (bool(v), f"{what} came back empty")


def haskeys(*keys):
    """Assert every row carries these keys.

    This is the check that was missing when retrieval was rewritten. The UI
    reads these dicts with hard brackets inside f-strings, so a key that
    disappears from a SELECT list does not render blank - it raises KeyError
    and replaces the whole screen with a traceback. Asserting the shape here is
    the only cheap place to catch it.
    """
    def _check(rows):
        if not rows:
            return True, ""              # emptiness is nonempty()'s job
        row = rows[0] if isinstance(rows, list) else rows
        missing = [k for k in keys if k not in row]
        if missing:
            return False, ("missing key(s) the UI reads by name: "
                           + ", ".join(missing)
                           + "  |  returned: " + ", ".join(sorted(row)))
        return True, ""
    return _check


def both(*checks):
    """Apply several predicates to one result."""
    def _check(v):
        for c in checks:
            ok, why = c(v)
            if not ok:
                return False, why
        return True, ""
    return _check


def main():
    mutate = "--mutate" in sys.argv

    m = da.mode()
    print(f"mode={m}  connection={da.CONNECTION}  actor={da.actor()}")
    if m == "fixture":
        print("FATAL: could not reach Snowflake - every check below would be "
              "vacuous. Check HO_CONNECTION and that SNOWFLAKE_HOME points "
              "at the directory holding your connections.toml.")
        return 2

    # --- the queue and a case -------------------------------------------
    check("anchor_date", da.anchor_date, nonempty("anchor"))
    check("queue_counts", da.queue_counts, nonempty("queue counts"))
    cases = check("list_cases", lambda: da.list_cases(("OPEN",)),
                  nonempty("the OPEN case queue"))
    cid = cases[0]["CASE_ID"] if cases else None
    if cid:
        c = check("get_case", lambda: da.get_case(cid), nonempty("case detail"))
        check("case_bundle", lambda: da.case_bundle(cid), nonempty("case bundle"))
        check("narrative", lambda: da.narrative(cid), nonempty("narrative"))
        check("audit_trail(subject)", lambda: da.audit_trail(20, cid))
        pid = (c or {}).get("PERSON_ID")
        if pid:
            check("lab_timeline", lambda: da.lab_timeline(pid))
            check("medication_timeline", lambda: da.medication_timeline(pid))
            check("get_identity", lambda: da.get_identity(pid), nonempty("identity row"))
            check("active_reveal", lambda: da.active_reveal(pid))
            check("reveal_history", lambda: da.reveal_history(pid),
                  haskeys("PERSON_ID", "GRANTED_TO", "GRANTED_AT",
                          "REASON_CODE", "REASON_TEXT", "STATE"))
    else:
        SKIP.append(("case-detail checks", "no OPEN cases to inspect"))

    # --- rules and the intake path --------------------------------------
    check("list_rules", da.list_rules,
          both(nonempty("the rule library"),
               haskeys("RULE_ID", "VERSION", "DRUG_NAME", "CONDITION_NAME",
                       "REQUIRED_TEST", "INTERVAL_DAYS", "GRACE_DAYS",
                       "INTERVAL_SOURCE_PHRASE", "EFFECTIVE_DATE", "DOC_ID",
                       "SOURCE_PASSAGE", "STATUS", "APPROVED_BY", "OPEN_CASES",
                       "IS_ENABLED", "DISABLED_BY", "DISABLE_REASON",
                       "DISABLED_AT", "CORROBORATION_SCORE", "CORROBORATION",
                       "CHECKS_PASSED", "CHECKS_APPLICABLE")))
    check("list_proposals", lambda: da.list_proposals("PROPOSED"))
    check("resolved_proposals", lambda: da.resolved_proposals("PROPOSED"),
          haskeys("PROPOSAL_ID", "DOC_ID", "MODEL_NAME", "DRUG_TEXT",
                  "REQUIRED_TEST_TEXT", "PRECONDITION_VALUE", "INTERVAL_DAYS",
                  "INTERVAL_SOURCE_PHRASE", "SOURCE_PASSAGE", "NEEDS_REVIEW",
                  "REVIEW_REASON", "DRUG_ID", "LAB_TEST_ID", "CONDITION_ID",
                  "RESOLVE_STATUS", "BLOCKING_REASON", "SUPERSEDES_RULE_ID",
                  "CORROBORATION", "CORROBORATION_SCORE", "FACTORS", "CHECKLIST",
                  "CHECKS_PASSED", "CHECKS_APPLICABLE", "RATING_STEP",
                  "REDERIVED_DAYS", "STRONG_PASSED", "STRONG_APPLICABLE"))
    check("extractor_config", da.extractor_config, nonempty("extractor config"))
    check("parser_config", da.parser_config, nonempty("parser config"))
    check("stage_files", da.stage_files,
          both(nonempty("the staging area"),
               haskeys("RELATIVE_PATH", "DOC_ID", "EXTENSION", "FILE_BYTES",
                       "LAST_MODIFIED", "ROLE_IN_PIPELINE", "IS_PROMOTED",
                       "TITLE", "CHUNKS", "PROPOSALS", "ACTIVE_RULES")))
    check("ingest_log", lambda: da.ingest_log(10))
    check("document_section",
          lambda: da.document_section("SAFETY_DOC_007", "section 3"),
          nonempty("the cited section of SAFETY_DOC_007"))

    # --- retrieval and analytics ----------------------------------------
    # Whichever engine answers, the shape is the same. This is the exact
    # check that would have caught KeyError: 'HITS'.
    check("search_documents", lambda: da.search_documents("potassium monitoring", 5),
          both(nonempty("document search results for 'potassium monitoring'"),
               haskeys(*da.SEARCH_RESULT_KEYS)))
    check("search_documents (semantic phrasing hits the same shape)",
          lambda: da.search_documents("how often should liver enzymes be rechecked", 3),
          haskeys(*da.SEARCH_RESULT_KEYS))
    check("corpus_summary", da.corpus_summary, nonempty("corpus summary"))
    # Must be a key of da.SEMANTIC_QUESTIONS. Anything else returns [] by
    # design (the semantic-view grammar has no bind form, so only pre-declared
    # questions are ever interpolated) -- and an unrecognised question looked
    # exactly like a broken semantic view the first time this ran.
    check("ask_semantic", lambda: da.ask_semantic("Cases by type and priority"),
          nonempty("the semantic view answer for 'Cases by type and priority'"))
    check("SEMANTIC_QUESTIONS all answerable",
          lambda: {q: len(da.ask_semantic(q)) for q in da.SEMANTIC_QUESTIONS},
          lambda v: (all(n > 0 for n in v.values()),
                     "these declared questions returned nothing: "
                     + ", ".join(q for q, n in v.items() if n == 0)))

    # --- operations, governance, audit ----------------------------------
    check("pipeline_status", da.pipeline_status, nonempty("pipeline status"))
    check("pipeline_runs", lambda: da.pipeline_runs(5),
          haskeys("TRIGGERED_BY", "STARTED_AT", "SECONDS", "HAD_NEW_DATA",
                  "CASES_BEFORE", "CASES_AFTER", "EVIDENCE_ROWS", "OUTCOME"))
    # Lowercase on purpose: this dict mirrors SHOW TASKS output, which
    # Snowflake returns lowercase, and the UI reads it lowercase to match.
    check("schedule_state", da.schedule_state,
          both(nonempty("schedule state"), haskeys("state", "schedule")))
    check("session_diagnostic", da.session_diagnostic, nonempty("session diagnostic"))
    check("data_quality", da.data_quality,
          both(nonempty("data quality readings"),
               haskeys("METRIC", "VALUE", "UNIT", "THRESHOLD", "WHY")))
    check("phi_inventory", da.phi_inventory,
          both(nonempty("PHI inventory"),
               haskeys("SCH", "TBL", "COL", "SENSITIVITY", "SOURCE_SYSTEM",
                       "PROTECTION")))
    check("audit_integrity", da.audit_integrity, nonempty("audit integrity"))
    check("audit_trail", lambda: da.audit_trail(20),
          both(nonempty("audit trail"),
               haskeys("EVENT_TYPE", "ACTOR", "EVENT_AT", "SUBJECT_TYPE",
                       "SUBJECT_ID", "DETAIL")))
    check("cohort_stats", da.cohort_stats, nonempty("cohort stats"))

    # --- state-changing, opt-in only ------------------------------------
    if mutate:
        check("run_intake(force=False)", lambda: da.run_intake(False),
              lambda v: (v.get("ok") is True, f"intake failed: {v.get('error')}"))
        check("reconcile_evidence", da.reconcile_evidence)
    else:
        for lbl in ("run_intake", "reconcile_evidence", "run_pipeline",
                    "run_rule", "approve_proposal", "reject_proposal",
                    "request_reveal", "record_disposition", "set_schedule",
                    "set_extractor_backend", "extract_one"):
            SKIP.append((lbl, "state-changing; pass --mutate to include"))

    # --- the corroboration figure ----------------------------------------
    # Every live proposal currently passes every check, so the ONE rendering
    # that matters most - a failing meter - can never be seen on real data.
    # These check the figure against hand-built checklists instead, because a
    # meter that silently paints a failed check as a pass would be worse than
    # showing no meter at all.
    import theme

    _all_pass = ["Y 10 gate one", "Y 10 gate two", "Y 4 strong", "Y 4 strong",
                 "Y 2 med", "Y 2 med", "Y 2 med", "Y 2 med", "Y 1 weak"]
    _one_fail = ["Y 10 gate one", "N 10 gate two", "Y 4 strong", "S 4 skipped",
                 "Y 2 med", "Y 2 med", "Y 2 med", "Y 2 med", "Y 1 weak"]

    def _meter_marks(checklist, step):
        html = theme.corroboration_meter(checklist, step)
        return (html.count("<div style=\"flex:"), html)

    check("meter draws one segment per check",
          lambda: _meter_marks(_all_pass, 4)[0],
          lambda n: (n == 9, f"expected 9 segments, got {n}"))

    check("meter fill follows the rating, not the checks",
          lambda: theme.corroboration_meter(_all_pass, 4),
          lambda h: ("var(--ok)" in h and "var(--warn)" not in h,
                     "a fully corroborated meter should carry the ok fill only"))

    check("a failed check is drawn as track, never as fill",
          lambda: theme.corroboration_meter(_one_fail, 2),
          lambda h: (h.count("var(--border-str)") == 1
                     and "var(--high)" in h,
                     "the failed segment must be neutral track, and an "
                     "uncorroborated meter must carry the severity fill"))

    check("a skipped check is a hatch, so hue never has to say 'n/a'",
          lambda: theme.corroboration_meter(_one_fail, 2),
          lambda h: ("repeating-linear-gradient" in h,
                     "skipped checks must use the texture channel"))

    check("no red fill sits beside a green fill anywhere in the meter",
          lambda: [theme.corroboration_meter(_one_fail, st) for st in (1, 2, 3, 4)],
          lambda hs: (all(not ("var(--ok)" in h and "var(--high)" in h) for h in hs),
                      "red-beside-green is the pair deuteranopia collapses"))

    check("the ladder marks exactly one of its four steps",
          lambda: theme.rating_ladder(4),
          lambda h: (h.count("font-weight:650") == 1
                     and all(n in h for n in theme.RATING_STEPS),
                     "the ladder must show the whole scale with one position marked"))

    check("an unknown rating step marks nothing rather than guessing",
          lambda: theme.rating_ladder(0),
          lambda h: (h.count("font-weight:650") == 0,
                     "a missing rating must not silently highlight a step"))

    # --- report ----------------------------------------------------------
    print()
    for lbl, n in PASS:
        print(f"  PASS  {lbl:<28} -> {n}")
    for lbl, why in SKIP:
        print(f"  SKIP  {lbl:<28} -- {why}")
    for lbl, why in FAIL:
        print(f"  FAIL  {lbl:<28} -- {why}")
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed, {len(SKIP)} skipped")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
