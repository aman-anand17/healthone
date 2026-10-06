"""HealthOne 360 - Patient Safety Case Investigator.

Streamlit in Snowflake (warehouse runtime). Page behaviour: docs/05_UI_SPEC.md.
Design system: app/theme.py (Snowflake palette, light surface).

Run locally:    streamlit run app/streamlit_app.py
Force fixtures: HO_MODE=fixture streamlit run app/streamlit_app.py

Navigation is driven by query parameters rather than a widget, so a case is a
real URL a reviewer can bookmark or paste to a colleague &mdash; and so the queue can
be a proper table with clickable rows instead of a grid of buttons.

All data access goes through data_access.py. No SQL here, and no free text ever
reaches a query (DECISIONS A9).
"""

import streamlit as st

import data_access as da
import theme

st.set_page_config(page_title="HealthOne 360 - Case Investigator",
                   page_icon="", layout="wide",
                   initial_sidebar_state="collapsed")
st.markdown(theme.CSS, unsafe_allow_html=True)

import json as _json

MODE = da.mode()
ANCHOR = da.anchor_date()

PAGES = {"queue": "Review queue", "case": "Case detail",
         "intake": "Intake", "rules": "Rule library",
         "explore": "Operations", "audit": "Audit trail"}

# NAVIGATION STATE
#
# This deliberately does NOT use st.query_params. Query-parameter navigation
# works when the app is served at its own URL, but Streamlit in Snowflake runs
# inside a Snowsight iframe where those parameters do not reach the app - so
# every link produced a blank page once deployed while working perfectly
# locally. Session state behaves identically in both runtimes.
if "page" not in st.session_state:
    st.session_state.page = "queue"
if "case_id" not in st.session_state:
    st.session_state.case_id = None


def goto(page_key, case_id=None):
    """Single entry point for navigation, so state can never half-change."""
    st.session_state.page = page_key
    if case_id is not None:
        st.session_state.case_id = case_id
    st.rerun()


page = st.session_state.page
if page not in PAGES:
    page = st.session_state.page = "queue"


def esc(v):
    """HTML-escape a value for interpolation into markup.

    NOTE: this escapes '&', so never pass an HTML entity through it - an entity
    would render literally as "&mdash;". Placeholders for missing data are
    therefore plain ASCII ('-'), not entities. This actually happened: the run
    history showed "&mdash;s" in the duration column.
    """
    return ("" if v is None else str(v)).replace("&", "&amp;").replace("<", "&lt;")


# ---------------------------------------------------------------------------
# NO SIDEBAR.
#
# Streamlit's sidebar could be collapsed but not reliably reopened - the
# control that reopens it is renamed between versions and, in some states,
# is not rendered at all, which stranded the user with no navigation. Rather
# than depend on a control that cannot be guaranteed, everything the sidebar
# held (navigation, identity, role, data source) now lives in the main column
# where it is always reachable.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Brand bar
# ---------------------------------------------------------------------------
counts = da.queue_counts()

# ACTIVE-rule count, resolved defensively.
#
# WHY NOT JUST CALL da.active_rule_count(): Streamlit in Snowflake keeps the
# app container warm (idle_auto_shutdown_time_seconds = 86400), and an imported
# module stays cached in that process. A deploy that adds a function to
# data_access.py AND a call to it in streamlit_app.py is therefore not atomic:
# the new page can run against the old module and die with AttributeError,
# which is exactly what happened on the deployed app.
#
# So the page never assumes a helper exists. It uses the fast path when the
# loaded module has it and falls back to the slow-but-always-present one when
# it does not. The fallback is 6s instead of 0.5s, which is a bad header and a
# working app - the right way round.
_arc = getattr(da, "active_rule_count", None)
if callable(_arc):
    _active_rules = _arc()
else:
    _active_rules = len([r for r in da.list_rules() if r.get("STATUS") == "ACTIVE"])
# .get with a default, not [MODE]. A bare subscript here would KeyError on any
# runtime not listed - which is exactly what adding the "cloud" mode would have
# done, taking down the header and therefore every single page.
_src = {"sis":     ("Snowflake &middot; in-account", "#0E7C5A"),
        "cloud":   ("Snowflake &middot; live connection", "#0E7C5A"),
        "local":   ("Snowflake &middot; CLI profile", "#0E7C5A"),
        "fixture": ("Fixture file &middot; no database", "#B45309"),
        }.get(MODE, (f"Unknown runtime ({esc(MODE)})", "#B45309"))
st.markdown(f"""
<div class="ho-topbar">
  <div class="ho-brand">
    <span class="ho-brand-name">&#10052; HealthOne 360</span>
    <span class="ho-brand-sub">Patient &amp; Member 360 &middot; synthetic data</span>
  </div>
  <div class="ho-topmeta">
    <div><span class="lbl">Signed in</span>
         <span class="val">Aman Anand</span></div>
    <div><span class="lbl">Role</span>
         <span class="val">HO_REVIEWER</span></div>
    <div><span class="lbl">Data source</span>
         <span class="val" style="color:{_src[1]};">&#9679; {_src[0]}</span></div>
    <div><span class="lbl">Evaluation date</span>
         <span class="val">{ANCHOR}</span></div>
    <div><span class="lbl">Open cases</span>
         <span class="val">{counts['OPEN']}</span></div>
    <div><span class="lbl">Active rules</span>
         <span class="val">{_active_rules}</span></div>
  </div>
</div>
""", unsafe_allow_html=True)

# Primary navigation. Buttons rather than <a href> links, because link-based
# navigation depends on query parameters that Snowsight's iframe strips.
# Every tab is always visible. Case detail used to be filtered out until a
# case had been selected, which meant the tab appeared and vanished depending
# on hidden state - indistinguishable from a broken app. It now carries its own
# case picker, so it is useful with nothing selected.
_visible = list(PAGES.items())
_ncols = st.columns(len(_visible) + 3)
for _i, (_k, _v) in enumerate(_visible):
    if _ncols[_i].button(_v, key=f"nav_{_k}", type=("primary" if _k == page else "secondary"),
                         use_container_width=True):
        goto(_k)
st.markdown('<div style="border-bottom:2px solid #DCE8F0;margin:.2rem 0 1.2rem;"></div>',
            unsafe_allow_html=True)


# ===========================================================================
# REVIEW QUEUE
# ===========================================================================
if page == "queue":
    a, b = st.columns([3.4, 1])
    a.markdown("# Cases requiring review")
    a.markdown(f'<div style="color:#5A7184;font-size:.885rem;margin-top:-.3rem;">'
               f'{counts["OPEN"]} open of {counts["TOTAL"]} total &middot; a worklist, '
               f'not a patient search</div>', unsafe_allow_html=True)
    b.write("")
    if b.button("&#8635;  Refresh queue", type="primary"):
        with st.spinner("Refreshing the 360 layer and re-evaluating active rules&hellip;"):
            delta = da.refresh_queue()
        if delta.get("note"):
            st.info(delta["note"])
        else:
            st.success(f"{delta['new']} new &middot; {delta['resolved']} resolved by data "
                       f"&middot; {delta['open_now']} open")

    f1, f2, _ = st.columns([1.3, 1.3, 2.4])
    show = f1.multiselect("Status", ["OPEN", "ESCALATED", "EVIDENCE_REQUESTED",
                                     "REVIEWED", "DISMISSED", "RESOLVED_BY_DATA"],
                          default=["OPEN"])
    types = f2.multiselect("Case type", ["MONITORING_GAP", "MED_CONFLICT"],
                           default=["MONITORING_GAP", "MED_CONFLICT"])

    cases = da.list_cases(statuses=show or ["OPEN"], case_types=types or None)

    if not cases:
        st.markdown('<div class="callout">No cases match this filter. Approve a '
                    'rule, or refresh to re-evaluate the active ones.</div>',
                    unsafe_allow_html=True)
    else:
        # One explicit button per row.
        #
        # Two earlier approaches failed and are worth recording so nobody
        # reintroduces them:
        #   1. <a href="?page=case&case=..."> links - query parameters do not
        #      reach the app inside Snowsight's iframe, so every link produced
        #      a blank page once deployed while working locally.
        #   2. st.dataframe(on_select=...) - the grid renders to a canvas, so
        #      row selection could not be verified end to end. Shipping an
        #      interaction I cannot test, twice burned, is not worth it.
        # A button is state, is unambiguous, and is verifiable.
        _kind = {"MONITORING_GAP": "Monitoring gap",
                 "MED_CONFLICT": "Medication conflict"}

        st.markdown('<div class="ho-qhead"><span>Person</span><span>Type</span>'
                    '<span>Why it was raised</span><span>Priority</span>'
                    '<span></span></div>', unsafe_allow_html=True)

        for _n, c in enumerate(cases):
            col = st.columns([1.5, 1.3, 3.2, 0.9, 1.0], vertical_alignment="center")
            col[0].markdown(
                f'<div class="ho-name">{esc(c.get("PERSON_TOKEN") or c["PERSON_ID"])}</div>'
                f'<div class="ho-ids">identity withheld</div>',
                unsafe_allow_html=True)
            col[1].markdown(
                f'<div class="ho-trigger">{_kind.get(c["CASE_TYPE"], c["CASE_TYPE"])}</div>'
                f'<div class="ho-mono">{esc(c["STATUS"])}</div>',
                unsafe_allow_html=True)
            col[2].markdown(
                f'<div class="ho-trigger">{esc(c["TRIGGER_TEXT"] or "-")}</div>'
                f'<div class="ho-mono">{esc(c["CASE_ID"][:12])}</div>',
                unsafe_allow_html=True)
            col[3].markdown(theme.priority_pill(c["PRIORITY"]),
                            unsafe_allow_html=True)
            if col[4].button("Investigate", key=f"inv_{c['CASE_ID']}",
                             use_container_width=True):
                goto("case", c["CASE_ID"])
            st.markdown('<div class="ho-qrule"></div>', unsafe_allow_html=True)

        st.caption("Sorted by priority, then by how overdue the patient is. "
                   "The hero case is not first - three unscripted background "
                   "patients are worse, which is what detection working on "
                   "unplanned data looks like.")

    s = da.cohort_stats()
    st.markdown('<div class="ho-eyebrow">What is in this dataset</div>',
                unsafe_allow_html=True)
    st.markdown(f"""
    <div class="tiles">
      <div class="tile"><div class="n">{s.get('PEOPLE', 0):,}</div>
           <div class="l">People</div></div>
      <div class="tile"><div class="n">{s.get('GAP', 0)}</div>
           <div class="l">Monitoring gaps</div></div>
      <div class="tile"><div class="n">{s.get('CONFLICT', 0)}</div>
           <div class="l">Medication conflicts</div></div>
      <div class="tile"><div class="n">{s.get('LABS', 0):,}</div>
           <div class="l">Lab results</div></div>
      <div class="tile"><div class="n">{s.get('UNMAPPED', 0)}</div>
           <div class="l">Unmapped tests</div></div>
    </div>""", unsafe_allow_html=True)
    st.markdown('<div class="callout" style="margin-top:.7rem;">'
                'Synthetic data; invented drug names. '
                '<strong>Unmapped tests</strong> are results whose test name is '
                'not in the controlled vocabulary, so the rule engine cannot '
                'count them &mdash; a reviewer can still see them on the case.'
                '</div>', unsafe_allow_html=True)

# ===========================================================================
# CASE DETAIL
# ===========================================================================
elif page == "case":
    # The picker IS the navigation for this page. Listing OPEN cases plus
    # whatever is currently selected means a case that has just been disposed
    # stays reachable in the same session rather than vanishing mid-review.
    _pick_rows = da.list_cases(statuses=("OPEN",))
    _opts = {}
    for _r in _pick_rows:
        _kind = ("Monitoring gap" if _r["CASE_TYPE"] == "MONITORING_GAP"
                 else "Medication conflict")
        _opts[f'{_r["PRIORITY"]}  ·  {_r["PERSON_TOKEN"]}  ·  {_kind}'
              f'  ·  {_r["CASE_ID"][:13]}'] = _r["CASE_ID"]

    cid = st.session_state.case_id
    if cid and cid not in _opts.values():
        _opts[f"(currently open)  ·  {cid[:13]}"] = cid

    if not _opts:
        st.markdown("# Case detail")
        st.markdown('<div class="callout">There are no open cases. Run the '
                    'pipeline from the Operations tab to raise some.</div>',
                    unsafe_allow_html=True)
        st.stop()

    _keys = list(_opts)
    _default = next((i for i, k in enumerate(_keys) if _opts[k] == cid), 0)
    _chosen = st.selectbox("Case", _keys, index=_default, key="case_picker",
                           help="Any open case. Selecting one loads it here, "
                                "so you can work the queue without going back.")
    if _opts[_chosen] != cid:
        goto("case", _opts[_chosen])
    cid = _opts[_chosen]

    c = da.get_case(cid)
    if not c:
        st.error(f"Case {cid} was not found.")
        st.stop()

    p = c["person"]
    r = c.get("rule_ref") or {}
    is_gap = c["case_type"] == "MONITORING_GAP"

    if st.button("Back to queue", key="back_queue"):
        goto("queue")
    st.markdown(f"# {'Monitoring gap' if is_gap else 'Medication conflict'}")
    st.markdown(theme.priority_pill(c["priority"]) + " " +
                theme.pill(c["status"], "blue") +
                f' <span class="ho-mono">{esc(c["case_id"])}</span>',
                unsafe_allow_html=True)

    # --- person strip -------------------------------------------------------
    # Pseudonym by default. The name is not fetched, let alone shown, unless
    # the reviewer breaks the glass below - minimum necessary applied to the
    # query, not just to the rendering.
    _revealed = da.active_reveal(c["person_id"])
    _ident = da.get_identity(c["person_id"]) if _revealed else {}

    # A row access policy once hid every patient here and the only symptom was
    # a blank field. A silent authorisation failure must never look like data.
    _diag = da.session_diagnostic()
    if _diag and not _diag.get("PERSONS_VISIBLE"):
        st.error(
            f"This session can see 0 patients, so person details below will be "
            f"empty. That is row-level access control, not missing data. "
            f"Session user **{_diag.get('SESSION_USER_NAME')}** "
            f"(role {_diag.get('SESSION_ROLE')}) has "
            f"{_diag.get('OWN_ASSIGNMENTS')} clinic assignment(s) in "
            f"SEC.REVIEWER_ASSIGNMENT and there are "
            f"{_diag.get('WILDCARD_ASSIGNMENTS')} wildcard rows.")
    _token = c.get("person_token") or c["person_id"]
    if _revealed and _ident.get("NAME"):
        _who = esc(_ident["NAME"])
        _sub = (f"{esc(_ident.get('PATIENT_ID') or '-')} &harr; "
                f"{esc(_ident.get('MEMBER_ID') or '-')} &middot; {esc(_token)} "
                "&middot; identity revealed, and this access is logged")
    elif _revealed:
        # Grant exists but no name came back - masking or row scoping is still
        # in force. Say which, rather than showing an empty box.
        _who = esc(_token)
        _sub = ("reveal granted, but the database returned no identity &mdash; "
                "row-level access or the masking policy is still in force for "
                "this session")
    else:
        _who = esc(_token)
        _sub = "pseudonym &middot; identity withheld until required"

    st.markdown(f"""
    <div class="kv-strip" style="margin-top:.9rem;">
      <div class="kv" style="flex:2;"><span class="k">Person</span>
        <span class="v">{_who}</span>
        <div class="v-sm">{_sub}</div></div>
      <div class="kv"><span class="k">Age band</span><span class="v">{esc(p.get('age_band'))}</span></div>
      <div class="kv"><span class="k">Sex</span><span class="v">{esc(p.get('sex'))}</span></div>
      <div class="kv"><span class="k">Clinic</span><span class="v">{esc(p.get('primary_clinic'))}</span></div>
      <div class="kv"><span class="k">Plan</span><span class="v">{esc(p.get('plan_code'))}</span></div>
      <div class="kv"><span class="k">Conditions</span><span class="v">{esc(p.get('active_condition_count'))}</span></div>
      <div class="kv"><span class="k">Active meds</span><span class="v">{esc(p.get('active_med_count'))}</span></div>
    </div>""", unsafe_allow_html=True)

    # --- break-glass identity reveal ---------------------------------------
    if _revealed:
        st.markdown('<div class="callout callout-warn">Identity is revealed for '
                    'this patient. The reveal, the reason and the timestamp are '
                    'recorded in the audit trail, and access expires '
                    'automatically after 30 minutes.</div>',
                    unsafe_allow_html=True)
    else:
        with st.expander("Reveal patient identity (recorded)"):
            st.caption("A reviewer does not need to know who the patient is to "
                       "judge whether a test is overdue. Identity is required "
                       "only to route a case to a treating clinician. Revealing "
                       "it is permitted, logged, and time-limited.")
            rc = st.selectbox("Reason", list(da.REVEAL_REASONS),
                              format_func=lambda k: da.REVEAL_REASONS[k],
                              key="reveal_reason")
            rt = st.text_input("Note (optional)", key="reveal_note",
                               placeholder="Anything a later auditor would want to know")
            if st.button("Break glass and reveal", type="primary", key="reveal_go"):
                st.warning(da.request_reveal(c["person_id"], c["case_id"], rc, rt))
                st.rerun()

    left, right = st.columns([1.45, 1])

    with left:
        st.markdown('<div class="ho-eyebrow">Why this case has this priority</div>',
                    unsafe_allow_html=True)
        st.markdown('<div class="ho-card">' + "".join(
            f'<div style="margin-bottom:.3rem;">&bull; {esc(f)}</div>'
            for f in c["priority_factors"]) +
            '<div class="ev-note" style="margin-top:.5rem;">Priority comes from these '
            'stated factors only &mdash; no score and no model. Everything that raised it '
            'is on this screen.</div></div>', unsafe_allow_html=True)

    with right:
        if r:
            st.markdown('<div class="ho-eyebrow">Governing rule</div>',
                        unsafe_allow_html=True)
            st.markdown(f"""
            <div class="ho-card ho-card-alt">
              <div style="font-weight:650;font-size:.95rem;color:#11567F;">
                {esc(r['rule_id'])} v{esc(r['version'])}
                {theme.pill(r.get('rule_status', ''), 'ok')}</div>
              <div class="ev-note">Approved by <strong>{esc(r['approved_by'])}</strong>
                   &middot; {esc(r.get('approved_at') or '')}</div>
              {theme.chip(r['source_doc'], r['source_passage'])}
              {theme.chip('EFFECTIVE', r.get('effective_date', ''))}
            </div>""", unsafe_allow_html=True)

    # --- rule panel
    if r:
        st.markdown('<div class="ho-eyebrow">Why this case exists</div>',
                    unsafe_allow_html=True)
        st.markdown(f"""
        <div class="ho-card">
          <div style="font-size:1.06rem;font-weight:650;color:#0B2942;margin-bottom:.4rem;">
            {esc(r['drug'])} &nbsp;+&nbsp; {esc(r['precondition_value'])}
            &nbsp;&rarr;&nbsp; {esc(r['required_test'])}</div>
          <div style="font-size:.95rem;">
            <span style="color:#5A7184;">&ldquo;{esc(r['interval_source_phrase'])}&rdquo;</span>
            &nbsp;&rarr;&nbsp;
            <strong style="color:#11567F;">{esc(r['interval_days'])} days</strong>
            <span style="color:#5A7184;">(+{esc(r['grace_days'])} days grace)</span></div>
          <div class="ev-note">The phrase as written in the document sits beside the
            number it was normalised to, so a human owns the interpretation rather
            than inheriting it.</div>
        </div>""", unsafe_allow_html=True)
        with st.expander(f"Read the source passage &mdash; {r['source_doc']}, {r['source_passage']}"):
            st.markdown(da.document_section(r["source_doc"], r["source_passage"]))
        if c.get("window_start_date"):
            st.markdown(f'<div class="callout callout-blue">Monitoring window '
                        f'evaluated from <strong>{esc(c["window_start_date"])}</strong> '
                        f'to <strong>{ANCHOR}</strong> &mdash; the later of therapy start, '
                        f'condition onset, and the interval plus grace. A result '
                        f'before that window cannot count as monitoring for this '
                        f'therapy.</div>', unsafe_allow_html=True)

    # --- evidence
    st.markdown('<div class="ho-eyebrow">Evidence</div>', unsafe_allow_html=True)
    if not c["claims"]:
        st.markdown('<div class="callout callout-warn">No evidence rows &mdash; the '
                    'reconciler has not run for this case.</div>',
                    unsafe_allow_html=True)

    for claim in c["claims"]:
        v = theme.VERDICT.get(claim["status"], theme.VERDICT["MISSING"])
        body = ""
        if claim["status"] == "CONFLICTS" and len(claim["evidence"]) > 1:
            cols = "".join(
                f'<div class="ev-col"><div class="ev-col-hd">{esc(ev["source"])} says</div>'
                f'<div style="font-size:.85rem;">{esc(ev["detail"])}</div>'
                f'{theme.chip(ev["source"], ev["id"])}</div>'
                for ev in claim["evidence"])
            body = f'<div class="ev-cols">{cols}</div>'
        elif claim["evidence"]:
            body = "".join(
                f'<div class="ev-src">{esc(ev["detail"])}<br>'
                f'{theme.chip(ev["source"], ev["id"])}</div>'
                for ev in claim["evidence"])

        st.markdown(f"""
        <div class="ev ev-{v['cls']}">
          <div class="ev-head">{theme.pill(claim['status'], v['pill'])}
            <span class="ev-claim">{esc(claim['text'])}</span></div>
          <div class="ev-note">{v['note']}</div>
          {body}
        </div>""", unsafe_allow_html=True)

        if claim["status"] == "MISSING" and claim.get("searched"):
            with st.expander("Where we looked"):
                st.markdown(claim["searched"])
                st.caption("This is a statement about our records - never a claim "
                           "about what happened to the patient.")

    # --- cited answer
    # --- cited answer, cached, with the generator named honestly -----------
    st.markdown('<div class="ho-eyebrow">Cited answer</div>', unsafe_allow_html=True)
    narr = da.narrative(c["case_id"])
    st.markdown(f'<div class="narr">{esc(narr.get("NARRATIVE") or c["finding"])}</div>',
                unsafe_allow_html=True)
    gen = narr.get("GENERATOR", "template")
    cached = narr.get("CACHED")
    st.markdown(
        f'<div class="ho-mono" style="color:#8296A8;margin-top:.4rem;">'
        f'generated by <b>{esc(gen)}</b>'
        f'{" &middot; served from cache" if cached else " &middot; freshly generated"}'
        f' &middot; cache key is the evidence fingerprint, so this text is '
        f'regenerated automatically if any verdict, day-count or rule version '
        f'changes</div>', unsafe_allow_html=True)

    # --- the AI seam: show the bundle the model receives, and label the ----
    # --- generator, so prose is never mistaken for a determination -------
    # The raw evidence bundle used to be dumped here as JSON. It is a
    # developer artifact, not something a Clinical Case Reviewer needs on the
    # screen where they make a clinical judgement - so it moved to
    # docs/self-tracking/05_TAB_BY_TAB_KT.md, and CASES.V_CASE_BUNDLE remains a
    # view anyone can query. What stays is the one sentence that makes the
    # narrative above trustworthy, because without it the prose is unattributed.
    _ai = da.ai_status()
    st.markdown(
        '<div class="callout" style="margin-top:.2rem;">'
        + ('<b>This summary was written by ' + esc(_ai.get("engine", ""))
           + '.</b> ' if _ai.get("available")
           else '<b>This summary was written by a deterministic template.</b> ')
        + 'Generated from a SQL-assembled evidence bundle the model cannot '
        'alter, carrying a pseudonym only.'
        '</div>', unsafe_allow_html=True)

    # --- document retrieval, scoped to this case ---------------------------
    st.markdown('<div class="ho-eyebrow">Source document retrieval</div>',
                unsafe_allow_html=True)
    st.caption("Cortex Search over the safety corpus, seeded with this "
               "case's rule. Each result names the engine that found it.")
    r0 = c.get("rule_ref") or {}
    seed = " ".join(str(x) for x in
                    [r0.get("required_test"), r0.get("drug")] if x) or "monitoring"
    dq = st.text_input("Search the corpus for this case",
                       value=seed, key=f"cq_{c['case_id'][:12]}")
    for h in (da.search_documents(dq, limit=4) if dq else []):
        st.markdown(f"""
        <div class="ho-card">
          <div style="display:flex;justify-content:space-between;
                      align-items:baseline;gap:1rem;flex-wrap:wrap;">
            <div style="font-weight:650;color:#11567F;font-size:.88rem;">
              {esc(h.get('DOC_ID'))} &middot; {esc(h.get('SECTION_LABEL'))}</div>
            <div class="ho-mono" style="white-space:nowrap;">
              {esc(h.get('ENGINE'))}</div>
          </div>
          <div style="font-size:.84rem;line-height:1.55;margin-top:.35rem;
                      white-space:pre-wrap;">{esc(h.get('CHUNK_TEXT') or '')[:450]}&hellip;</div>
        </div>""", unsafe_allow_html=True)
    st.caption("Assembled deterministically from the rule fields and the evidence "
               "rows above. No model sits in this path, so it cannot invent a fact.")

    # --- timelines
    t1, t2 = st.columns(2)
    with t1.expander("Laboratory timeline &mdash; every result, mapped or not"):
        labs = da.lab_timeline(c["person_id"])
        if not labs:
            st.caption("No results available.")
        for l in labs[:20]:
            tag = (theme.chip("TEST", l["LAB_TEST_ID"]) if l["LAB_TEST_ID"]
                   else theme.pill("UNMAPPED", "med"))
            st.markdown(f'<div class="ev-src"><strong>{esc(l["RESULT_DATE"])}</strong> &middot; '
                        f'&ldquo;{esc(l["RAW_TEST_TEXT"])}&rdquo; = <strong>{esc(l["RESULT_VALUE"])}'
                        f'</strong> {esc(l["UNITS"] or "")} {tag} '
                        f'{theme.chip("LAB", l["SOURCE_RECORD_ID"])}</div>',
                        unsafe_allow_html=True)
        if labs:
            st.caption("Results tagged UNMAPPED exist in the feed, but their test name "
                       "is absent from the controlled vocabulary, so the rule engine "
                       "cannot count them. A reviewer can see them; detection cannot. "
                       "That asymmetry is deliberate and is what makes some cases "
                       "correctly dismissible.")
    with t2.expander("Medication timeline"):
        meds = da.medication_timeline(c["person_id"])
        if not meds:
            st.caption("No medication events available.")
        for m in meds[:20]:
            st.markdown(f'<div class="ev-src"><strong>{esc(m["EVENT_DATE"])}</strong> &middot; '
                        f'{esc(m["EVENT_TYPE"])} &mdash; {esc(m["DETAIL"])} '
                        f'{theme.chip(m["SOURCE_SYSTEM"], m["SOURCE_RECORD_ID"])}</div>',
                        unsafe_allow_html=True)

    # --- disposition
    st.markdown('<div class="ho-eyebrow">Record your decision</div>',
                unsafe_allow_html=True)
    if c.get("disposition"):
        st.markdown(f'<div class="callout" style="background:#E7F5EF;'
                    f'border-color:#BFE5D6;color:#0E7C5A;">'
                    f'<strong>{esc(c["disposition"])}</strong> recorded by '
                    f'{esc(c["disposed_by"])} at {esc(c["disposed_at"])}.'
                    + (f'<div style="margin-top:.4rem;color:#20374B;">'
                       f'&ldquo;{esc(c["disposition_reason"])}&rdquo;</div>'
                       if c.get("disposition_reason") else "")
                    + '</div>', unsafe_allow_html=True)
    else:
        LABELS = {"ESCALATE_FOR_CLINICAL_REVIEW": "Escalate for clinical review",
                  "REQUEST_ADDITIONAL_EVIDENCE": "Request additional evidence",
                  "MARK_REVIEWED": "Mark reviewed",
                  "DISMISS_WITH_REASON": "Dismiss with reason"}
        cols = st.columns(4)
        for col, code in zip(cols, c["disposition_options"]):
            if col.button(LABELS[code], key=f"d{code}", use_container_width=True):
                st.session_state["pending"] = code
        pend = st.session_state.get("pending")
        if pend:
            needs = pend in ("DISMISS_WITH_REASON", "ESCALATE_FOR_CLINICAL_REVIEW")
            st.markdown(f'<div style="margin-top:.7rem;font-weight:650;'
                        f'color:#11567F;">{LABELS[pend]}</div>',
                        unsafe_allow_html=True)
            reason = st.text_area(
                "Reason" + (" &mdash; required" if needs else " &mdash; optional"),
                placeholder="e.g. Potassium was measured 20 days ago but recorded "
                            "under an unmapped test name, so this is not a genuine "
                            "monitoring gap. The vocabulary needs that synonym added.")
            x, y, _ = st.columns([1, 1, 3])
            if x.button("Record decision", type="primary", use_container_width=True):
                out = da.record_disposition(c["case_id"], pend, reason, "Aman Anand")
                if out.get("ok"):
                    st.session_state.pop("pending", None)
                    st.success(f"Recorded. This case is now {out.get('status', '&mdash;')}.")
                    st.rerun()
                else:
                    st.error(out.get("error", "Could not record the decision."))
            if y.button("Cancel", use_container_width=True):
                st.session_state.pop("pending", None)
                st.rerun()
        st.caption("Every disposition is stored with your name, the time and your "
                   "reason. The system records decisions; it never orders a test or "
                   "changes therapy.")

# ===========================================================================
# RULE LIBRARY
# ===========================================================================
elif page == "rules":
    st.markdown("# Rule library")
    st.markdown('<div style="color:#5A7184;font-size:.885rem;margin-top:-.3rem;">'
                'Rules are immutable and versioned. A correction is a new version; '
                'nothing is edited in place.</div>', unsafe_allow_html=True)

    t1, t2 = st.tabs(["Active library", "Proposals awaiting approval"])

    with t1:
        # --- run a rule on demand -------------------------------------------
        # Approving a rule does NOT change the queue by itself: detection is
        # not automatic (every dynamic table is SCHEDULER=DISABLE for cost).
        # This control makes the causality visible - rule in, cases out.
        st.markdown('<div class="ho-eyebrow">Evaluate a rule now</div>',
                    unsafe_allow_html=True)
        st.caption("Approving a rule changes nothing on its own. Running it "
                   "refreshes the 360 layer, re-evaluates that rule against "
                   "every person, and reports exactly what it produced &mdash; "
                   "recorded as a RULE_EVALUATED audit event.")
        rc1, rc2 = st.columns([1.2, 3])
        # Paused rules are excluded: running one returns a refusal explaining
        # why, which is correct but a pointless button to offer.
        _act = [r["RULE_ID"] for r in da.list_rules()
                if r["STATUS"] == "ACTIVE" and r.get("IS_ENABLED", True)]
        if _act:
            _pick = rc1.selectbox("Rule", _act, key="rr_pick")
            if rc1.button("&#9654;  Run this rule", type="primary", key="rr_go"):
                with st.spinner(f"Evaluating {_pick} across every person&hellip;"):
                    res = da.run_rule(_pick)
                if res.get("ok"):
                    rc2.success(
                        f"{res.get('rule_id')} v{res.get('version')} evaluated &mdash; "
                        f"{res.get('open_before')} open before, "
                        f"{res.get('open_after')} after "
                        f"({res.get('new_cases'):+d} new).")
                else:
                    rc2.error(res.get("error", "failed"))
        st.divider()

        rules = da.list_rules()
        if not rules:
            st.markdown('<div class="callout">No rules yet.</div>',
                        unsafe_allow_html=True)
        for rule in rules:
            st.markdown(f"""
            <div class="ho-card">
              <div style="display:flex;justify-content:space-between;gap:1rem;
                          align-items:flex-start;">
                <div style="flex:2;">
                  <div style="font-size:1.02rem;font-weight:650;color:#0B2942;">
                    {esc(rule['DRUG_NAME'])} + {esc(rule['CONDITION_NAME'])}
                    &rarr; {esc(rule['REQUIRED_TEST'])}</div>
                  <div style="font-size:.9rem;margin-top:.25rem;">
                    <span style="color:#5A7184;">&ldquo;{esc(rule['INTERVAL_SOURCE_PHRASE'])}&rdquo;</span>
                    &rarr; <strong style="color:#11567F;">{esc(rule['INTERVAL_DAYS'])} days</strong>
                    <span style="color:#5A7184;">(+{esc(rule['GRACE_DAYS'])} grace)</span></div>
                  <div style="margin-top:.45rem;">
                    {theme.chip(rule['DOC_ID'], rule['SOURCE_PASSAGE'])}
                    {theme.chip('EFFECTIVE', rule['EFFECTIVE_DATE'])}</div>
                </div>
                <div style="text-align:right;">
                  <div style="font-weight:650;color:#11567F;">
                    {esc(rule['RULE_ID'])} v{esc(rule['VERSION'])}</div>
                  <div style="margin:.25rem 0;">
                    {theme.pill(rule['STATUS'], 'ok' if rule['STATUS'] == 'ACTIVE' else 'neut')}</div>
                  <div class="ev-note">approved by {esc(rule['APPROVED_BY'])}</div>
                  {(
                    '<div class="ev-note" style="margin-top:.15rem;">'
                    + esc(rule.get('CHECKS_PASSED')) + ' of '
                    + esc(rule.get('CHECKS_APPLICABLE'))
                    + ' document checks passed at approval</div>'
                  ) if rule.get('CHECKS_APPLICABLE') is not None else ''}
                  <div style="font-size:1.3rem;font-weight:700;color:#11567F;">
                    {esc(rule.get('OPEN_CASES', 0))}</div>
                  <div class="l" style="font-size:.63rem;letter-spacing:.07em;
                       text-transform:uppercase;color:#5A7184;">open cases</div>
                </div>
              </div>
            </div>""", unsafe_allow_html=True)
            # --- the on/off switch -------------------------------------
            # Only for rules whose authority is current. A SUPERSEDED or RETIRED
            # rule has already stopped applying; offering a switch would imply
            # it could be turned back on, which is a different decision
            # (approving a new version) and a different screen.
            if rule["STATUS"] == "ACTIVE":
                _rid = rule["RULE_ID"]
                _on = bool(rule.get("IS_ENABLED", True))
                g1, g2 = st.columns([1.15, 3.4])
                _new = g1.toggle(
                    "In force", value=_on, key=f"en_{_rid}",
                    help="Pause a rule that is approved but should not raise "
                         "new cases yet. Existing cases are NOT affected - "
                         "pausing does not close a patient's monitoring gap.")
                _why = g2.text_input(
                    "Reason (required to pause)", key=f"enr_{_rid}",
                    placeholder="e.g. site cannot meet the interval; escalated "
                                "to the Committee",
                    label_visibility="collapsed" if _on else "visible")
                if _new != _on:
                    res = da.set_rule_enabled(_rid, _new, _why)
                    if res.get("ok"):
                        if res.get("changed"):
                            st.success(esc(res.get("note", "")))
                        else:
                            st.info(esc(res.get("note", "")))
                        st.rerun()
                    else:
                        # The toggle reverts by itself on the next rerun because
                        # its value comes from the database, not session state.
                        st.error(esc(res.get("error", "failed")))

                if not _on:
                    st.markdown(
                        '<div class="callout callout-warn">'
                        '<strong>Paused &mdash; raising no new cases.</strong> '
                        'Still APPROVED and ACTIVE: this is an operational '
                        'pause, not a withdrawal, so a revised interval would '
                        'still supersede it as a new version. '
                        + ('Paused by ' + esc(rule.get('DISABLED_BY') or '?')
                           + ' on ' + esc(rule.get('DISABLED_AT') or '?') + '. '
                           if rule.get('DISABLED_BY') else '')
                        + ('Reason: ' + esc(rule.get('DISABLE_REASON'))
                           if rule.get('DISABLE_REASON') else '')
                        + '<div style="margin-top:.4rem;">Its '
                        + esc(rule.get('OPEN_CASES', 0))
                        + ' existing open case(s) are unchanged and still need '
                        'review.</div></div>', unsafe_allow_html=True)

            with st.expander(f"Source passage &mdash; {rule['DOC_ID']}, {rule['SOURCE_PASSAGE']}"):
                st.markdown(da.document_section(rule["DOC_ID"], rule["SOURCE_PASSAGE"]))

    with t2:
        # This tab used to say "rule extraction is currently blocked" and show
        # nothing, because Cortex was unavailable AND there was no procedure
        # that could turn a proposal into a rule even if one existed. Both are
        # fixed: extraction has a backend that works without Cortex, and
        # SP_APPROVE_PROPOSAL is the approve step the product always claimed.
        cfg = da.extractor_config()
        st.markdown(
            '<div class="callout"><strong>Extraction engine:</strong> '
            f'<code>{esc(cfg.get("BACKEND", "?"))}</code> &mdash; model '
            f'<code>{esc(cfg.get("MODEL_NAME", "?"))}</code>. Every proposal below is '
            'stamped with the engine that produced it, so nothing can claim a model '
            'wrote something a template did. Switch engines on the '
            '<strong>Document intake</strong> page.</div>',
            unsafe_allow_html=True)

        props = da.resolved_proposals("PROPOSED")
        if not props:
            st.markdown(
                '<div class="callout">No proposals awaiting approval. Run intake on '
                'the <strong>Document intake</strong> page to extract from the staged '
                'documents.</div>', unsafe_allow_html=True)

        for pr in props:
            ok = pr["RESOLVE_STATUS"] == "RESOLVED"
            sup = pr.get("SUPERSEDES_RULE_ID")
            st.markdown(f"""
            <div class="ho-card">
              <div style="display:flex;justify-content:space-between;gap:1rem;">
                <div style="flex:2;">
                  <div style="font-size:1rem;font-weight:650;color:#0B2942;">
                    {esc(pr['DRUG_TEXT'])} + {esc(pr['PRECONDITION_VALUE'] or 'no precondition')}
                    &rarr; {esc(pr['REQUIRED_TEST_TEXT'])}</div>
                  <div style="font-size:.9rem;margin-top:.25rem;">
                    <span style="color:#5A7184;">&ldquo;{esc(pr['INTERVAL_SOURCE_PHRASE'])}&rdquo;</span>
                    &rarr; <strong style="color:#11567F;">{esc(pr['INTERVAL_DAYS'])} days</strong></div>
                  <div style="margin-top:.4rem;">
                    {theme.chip(pr['DOC_ID'], pr['SOURCE_PASSAGE'])}
                    {theme.chip('ENGINE', pr['MODEL_NAME'])}</div>
                  <div class="ev-note" style="margin-top:.45rem;">
                    resolves to
                    <code>{esc(pr['DRUG_ID'] or '?')}</code> /
                    <code>{esc(pr['LAB_TEST_ID'] or '?')}</code> /
                    <code>{esc(pr['CONDITION_ID'] or 'none')}</code></div>
                </div>
                <div style="text-align:right;min-width:150px;">
                  <div style="margin-bottom:.3rem;">
                    {theme.pill(pr['RESOLVE_STATUS'], 'neut' if ok else 'high')}</div>
                  <div class="ev-note">{esc('supersedes ' + sup if sup else 'new rule')}</div>
                </div>
              </div>
            </div>""", unsafe_allow_html=True)

            # --- what the DOCUMENT says about this proposal ---------------
            # Deliberately not a confidence score. An LLM's self-reported
            # certainty is uncalibrated, and printing "0.92" beside a
            # drug-safety rule invents a precision nobody measured while
            # encouraging a reviewer to stop reading. These are facts about the
            # source text, computed here, each one checkable by hand.
            _facts = pr.get("FACTORS")
            if isinstance(_facts, str):
                try:
                    _facts = _json.loads(_facts)
                except Exception:
                    _facts = []
            _bad = pr.get("CORROBORATION") in ("UNCORROBORATED", "CONTRADICTED")

            # The itemised arithmetic behind the percentage. A score a reviewer
            # cannot decompose gets either over-trusted or ignored, so every
            # check is listed with its verdict and its weight: add the weights
            # of the ticked lines, divide by the total of the applicable ones,
            # and you have recomputed the number on the card by hand.
            _chk = pr.get("CHECKLIST")
            if isinstance(_chk, str):
                try:
                    _chk = _json.loads(_chk)
                except Exception:
                    _chk = []
            _rows_html = ""
            for _c in (_chk or []):
                _mark, _wt, _label = (_c.split(" ", 2) + ["", ""])[:3]
                _sym, _col = {"Y": ("&#10003;", "#0E7C5A"),
                              "N": ("&#10007;", "#B42318")}.get(_mark, ("&ndash;", "#8A9BA8"))
                _rows_html += (
                    '<li style="list-style:none;margin:0;display:flex;gap:.45rem;'
                    'align-items:baseline;">'
                    f'<span style="color:{_col};font-weight:700;width:.9rem;">{_sym}</span>'
                    f'<span style="color:#5A7184;width:1.4rem;font-variant-numeric:tabular-nums;">'
                    + ('' if _mark == 'S' else esc(_wt)) + '</span>'
                    + f'<span>{esc(_label)}</span>'
                    + ('<span style="color:#8A9BA8;font-style:italic;">'
                       ' not applicable</span>' if _mark == 'S' else '')
                    + '</li>')

            _passed = pr.get("CHECKS_PASSED")
            _appl = pr.get("CHECKS_APPLICABLE")
            _step = pr.get("RATING_STEP") or 0

            # The caveat is the whole point of the wording. "9 of 9" is a
            # ceiling on the checks a machine can run, not on the truth, and a
            # reviewer who reads it as certainty has been misled by us rather
            # than by the model.
            if _appl and _passed == _appl:
                _headline = ("Every check that can be run mechanically passed. "
                             "That is corroboration, not certainty &mdash; these "
                             "checks confirm the document says what the proposal "
                             "claims, and say nothing about whether the guidance "
                             "itself is right for a patient.")
            else:
                _headline = ("Some checks did not pass. Read the failing lines "
                             "below before approving &mdash; each one names a "
                             "specific disagreement with the source text.")

            if _facts or _rows_html:
                st.markdown(
                    '<div class="callout' + (' callout-warn' if _bad else '') + '">'
                    '<div style="display:flex;justify-content:space-between;'
                    'align-items:baseline;gap:1rem;flex-wrap:wrap;">'
                    '<strong>Checked against the source document</strong>'
                    '<span style="font-size:.8rem;color:var(--slate);">'
                    + esc(_passed) + ' of ' + esc(_appl) + ' checks passed'
                    + ('' if pr.get('CORROBORATION_SCORE') is None else
                       ' &middot; ' + esc(pr.get('CORROBORATION_SCORE'))
                       + ' of 100 weighted points')
                    + '</span></div>'
                    + theme.corroboration_meter(_chk, _step)
                    + theme.rating_ladder(_step)
                    + '<div style="margin:.6rem 0 0;font-size:.85rem;'
                      'line-height:1.55;">' + _headline + '</div>'
                    + ('<ul style="margin:.55rem 0 0 0;padding:0;font-size:.82rem;'
                       'line-height:1.65;">' + _rows_html + '</ul>' if _rows_html else '')
                    + ('<ul style="margin:.55rem 0 0 1rem;padding:0;font-size:.85rem;'
                       'line-height:1.5;">'
                       + "".join('<li>' + esc(f) + '</li>' for f in _facts)
                       + '</ul>' if _facts else '')
                    + '</div>', unsafe_allow_html=True)

            if not ok:
                st.markdown('<div class="callout callout-warn">'
                            f'<strong>Cannot approve.</strong> {esc(pr["BLOCKING_REASON"] or "")}'
                            '</div>', unsafe_allow_html=True)
                continue

            if pr.get("NEEDS_REVIEW"):
                st.markdown('<div class="callout callout-warn">'
                            f'<strong>Flagged by the extractor.</strong> {esc(pr["REVIEW_REASON"] or "")}'
                            '</div>', unsafe_allow_html=True)

            pid = pr["PROPOSAL_ID"]
            with st.expander("Source passage this was read from"):
                st.markdown(da.document_section(pr["DOC_ID"], pr["SOURCE_PASSAGE"]))

            c1, c2, c3 = st.columns([1, 1.1, 2.4])
            grace = c1.number_input("Grace days", 0, 60, 7, key=f"g_{pid}",
                                    help="Days of tolerance beyond the stated "
                                         "interval before a gap becomes a case.")
            if c2.button("&#10003;  Approve", type="primary", key=f"ap_{pid}"):
                res = da.approve_proposal(pid, grace)
                if res.get("ok"):
                    verb = ("superseded the previous version of"
                            if res.get("action") == "SUPERSEDED_PRIOR_VERSION"
                            else "created")
                    st.success(f"Approved &mdash; {verb} "
                               f"{res.get('rule_id')} v{res.get('version')} "
                               f"({res.get('interval_days')} days "
                               f"+{res.get('grace_days')} grace). "
                               "Run it from the Active library tab to see which "
                               "patients it raises.")
                    st.rerun()
                else:
                    st.error(esc(res.get("error", "failed")))
            rej = c3.text_input("Reason, if rejecting", key=f"rr_{pid}",
                                placeholder="why this is not a monitoring requirement")
            if c3.button("Reject", key=f"rj_{pid}"):
                res = da.reject_proposal(pid, rej)
                if res.get("ok"):
                    st.warning("Rejected. The row and your reason are kept &mdash; "
                               "-why is there no rule for this document?- "
                               "must have an answer.")
                    st.rerun()
                else:
                    st.error(esc(res.get("error", "failed")))


# ===========================================================================
# DOCUMENT INTAKE - the staging area and the path out of it
#
# This page exists because the ingestion path being demonstrated was not the
# ingestion path that would ever run: documents reached the database as INSERT
# statements generated by a script on a laptop, and DOC_CHUNK was a checked-in
# .sql file. Now a file lands in an internal stage, a directory table sees it,
# COPY INTO lands the text, an in-database chunker splits it at its section
# headings, and extraction proposes rules. This page is that pipeline, visible.
# ===========================================================================
elif page == "intake":
    st.markdown("# Document intake")
    st.markdown('<div style="color:#5A7184;font-size:.885rem;margin-top:-.3rem;">'
                'The staging area, the extraction engine, and the ingest log. '
                'Nothing on this page can put a rule into force - it stops at '
                'PROPOSED, and approval lives in the Rule library.</div>',
                unsafe_allow_html=True)

    _files = da.stage_files()
    _cfg = da.extractor_config()
    _parser = da.parser_config()
    _props = da.resolved_proposals("PROPOSED")

    m = st.columns(5)
    m[0].metric("Files staged", len(_files))
    m[1].metric("Documents loaded",
                len({f["DOC_ID"] for f in _files if f.get("IS_PROMOTED")}))
    m[2].metric("Section chunks",
                sum(f["CHUNKS"] for f in _files if f["EXTENSION"] == "MD"))
    m[3].metric("Proposals pending", len(_props))
    m[4].metric("Blocked",
                sum(1 for p in _props if p["RESOLVE_STATUS"] != "RESOLVED"))

    t1, t2, t3 = st.tabs(["Staging area", "Extraction engine", "Ingest log"])

    # -----------------------------------------------------------------------
    with t1:
        st.markdown('<div class="ho-eyebrow">Run intake</div>', unsafe_allow_html=True)
        st.caption("Refreshes the stage directory table, loads any new document "
                   "text, re-chunks what changed, and runs extraction over every "
                   "document. Idempotent - COPY INTO keeps its own load history, "
                   "so a file already ingested is skipped rather than duplicated.")
        i1, i2, i3 = st.columns([1.3, 1.3, 2.4])
        _force = i2.checkbox("Re-read unchanged files", value=False, key="ik_force",
                             help="COPY INTO normally skips a file it has already "
                                  "loaded. Tick this after editing a document in "
                                  "place, when the filename has not changed.")
        if i1.button("Run intake", type="primary", key="ik_go"):
            with st.spinner("Ingesting the staging area..."):
                res = da.run_intake(bool(_force))
            if res.get("ok"):
                st.success(
                    "Intake complete on the " + str(res.get("backend")) +
                    " engine - " + str(res.get("documents")) + " documents, " +
                    str(res.get("chunks")) + " section chunks, " +
                    str(res.get("proposals_pending")) +
                    " proposals awaiting a human decision. Nothing is in force yet.")
                st.rerun()
            else:
                st.error(esc(res.get("error", "failed")))
        st.divider()

        st.markdown('<div class="ho-eyebrow">What is in the staging area</div>',
                    unsafe_allow_html=True)
        st.caption("Read from the stage DIRECTORY table, not from a list kept in "
                   "the app - so this is what Snowflake actually holds.")
        st.markdown(
            '<div class="callout">The stage holds the PDF of record. '
            'Parser in force: <code>'
            + esc(_parser.get("PARSER_MODE", "?")) + '</code>.</div>',
            unsafe_allow_html=True)

        for f in _files:
            if f["EXTENSION"] != "MD":
                continue
            pdf = next((x for x in _files
                        if x["DOC_ID"] == f["DOC_ID"] and x["EXTENSION"] == "PDF"), None)
            pdf_note = ""
            if pdf:
                pdf_note = (" &middot; " + esc(pdf["RELATIVE_PATH"]) + " ("
                            + esc(pdf["FILE_BYTES"]) + " bytes)")
            st.markdown(
                '<div class="ho-card">'
                '<div style="display:flex;justify-content:space-between;gap:1rem;">'
                '<div style="flex:2;">'
                '<div style="font-weight:650;color:#0B2942;">'
                + esc(f["DOC_ID"]) + " &mdash; "
                + esc(f["TITLE"] or "not yet loaded") + '</div>'
                '<div class="ev-note" style="margin-top:.3rem;">'
                + esc(f["RELATIVE_PATH"]) + " (" + esc(f["FILE_BYTES"])
                + " bytes)" + pdf_note + '</div>'
                '<div style="margin-top:.45rem;">'
                + theme.chip("CHUNKS", f["CHUNKS"])
                + theme.chip("PROPOSALS", f["PROPOSALS"])
                + theme.chip("ACTIVE RULES", f["ACTIVE_RULES"])
                + '</div></div>'
                '<div style="text-align:right;min-width:150px;">'
                + theme.pill("LOADED" if f["IS_PROMOTED"] else "NOT LOADED",
                             "ok" if f["IS_PROMOTED"] else "neut")
                + '<div class="ev-note" style="margin-top:.3rem;">'
                + esc(f["LAST_MODIFIED"]) + '</div></div></div></div>',
                unsafe_allow_html=True)
            if f["IS_PROMOTED"] and f["PROPOSALS"] == 0:
                st.caption(str(f["DOC_ID"]) + " produced no rule proposals. That is "
                           "a valid outcome - a document may carry no recurring "
                           "monitoring requirement at all.")

    # -----------------------------------------------------------------------
    with t2:
        st.markdown('<div class="ho-eyebrow">Which engine reads the documents</div>',
                    unsafe_allow_html=True)
        st.caption("Two implementations behind one output contract. Everything "
                   "downstream reads RULE_PROPOSAL and cannot tell which one "
                   "filled it - that is the point.")

        cur = _cfg.get("BACKEND", "PATTERN")
        st.markdown(
            '<div class="ho-card"><div style="font-weight:650;">In force: <code>'
            + esc(cur) + '</code> &mdash; model <code>'
            + esc(_cfg.get("MODEL_NAME", "?")) + '</code></div>'
            '<div class="ev-note" style="margin-top:.4rem;">'
            + esc(_cfg.get("NOTE", "")) + '</div></div>', unsafe_allow_html=True)

        e1, e2 = st.columns([1.4, 2.6])
        pick = e1.radio("Engine", ["PATTERN", "AI_COMPLETE"],
                        index=(0 if cur == "PATTERN" else 1), key="ek_pick")
        model = e1.text_input("Model",
                              value=("pattern-udf-v1" if pick == "PATTERN"
                                     else "claude-sonnet-5"), key="ek_model")
        if e1.button("Switch engine", key="ek_go"):
            res = da.set_extractor_backend(pick, model)
            if res.get("ok"):
                st.success("Extraction engine set to " + esc(pick)
                           + ". Re-run intake to extract with it.")
                st.rerun()
            else:
                st.error(esc(res.get("error", "failed")))

        e2.markdown(
            '<div class="callout">'
            '<strong>PATTERN</strong> is a deterministic Python UDF running inside '
            'Snowflake. It is given the document text and the controlled vocabulary '
            'and nothing else - it is not seeded with the rules it finds. For a '
            'sentence to become a proposal it must contain a known drug, a known '
            'lab test, a recurring interval, and no negation marker. Requiring all '
            'four is what makes it return zero from a distractor document.'
            '<div style="margin-top:.55rem;"><strong>AI_COMPLETE</strong> is Cortex '
            'with a Claude model and the prompt stored in '
            '<code>RULES.PROMPT_TEMPLATE</code> below. It handles paraphrase the '
            'pattern engine cannot.</div>'
            '<div style="margin-top:.55rem;">If the AI engine fails, extraction '
            '<strong>does not fall back</strong> to the pattern engine. It returns '
            'the real Snowflake error. Falling back would write a pattern-produced '
            'proposal while the operator believed a model produced it.</div>'
            '</div>', unsafe_allow_html=True)

        with st.expander("The exact prompt the AI engine sends (version "
                         + str(_cfg.get("PROMPT_VERSION", "?")) + ")"):
            st.caption("Stored as data in RULES.PROMPT_TEMPLATE, not hidden in "
                       "application code, so what would be sent to a model is "
                       "inspectable.")
            st.code(_cfg.get("PROMPT_TEXT") or "(no prompt stored)", language="text")

        st.divider()
        st.markdown('<div class="ho-eyebrow">Extract from one document</div>',
                    unsafe_allow_html=True)
        _docs = sorted({f["DOC_ID"] for f in _files
                        if f.get("IS_PROMOTED") and f["DOC_ID"]})
        if _docs:
            d1, d2 = st.columns([1.4, 2.6])
            dpick = d1.selectbox("Document", _docs, key="ex_pick")
            if d1.button("Extract", key="ex_go"):
                with st.spinner("Reading " + str(dpick) + "..."):
                    res = da.extract_one(dpick)
                if res.get("ok"):
                    d2.success(esc(dpick) + ": " + str(res.get("proposals"))
                               + " proposals from the " + esc(res.get("backend"))
                               + " engine. " + esc(res.get("note", "")))
                else:
                    d2.error(esc(res.get("error", "failed")))

    # -----------------------------------------------------------------------
    with t3:
        st.markdown('<div class="ho-eyebrow">Ingest log</div>', unsafe_allow_html=True)
        st.caption("One row per file per run. PARSER_USED names the parser that "
                   "actually ran, so the log can never claim a parser was used "
                   "that was not. DOC_ID_MATCHES_TEXT cross-checks the filename "
                   "against the Reference line inside the file - a mismatch would "
                   "mean every citation in the product points at the wrong "
                   "document.")
        rows = da.ingest_log(30)
        if rows:
            st.dataframe(rows, use_container_width=True, hide_index=True)
        else:
            st.markdown('<div class="callout">No ingest runs recorded yet.</div>',
                        unsafe_allow_html=True)


# ===========================================================================
# SEARCH & ANALYTICS - real Snowflake retrieval + the governed semantic layer
# ===========================================================================
elif page == "explore":
    st.markdown("# Operations")
    st.markdown('<div style="color:#5A7184;font-size:.885rem;margin-top:-.3rem;">'
                'Run the pipeline, schedule it, and see what it has been '
                'doing. Plus corpus retrieval and governed analytics.</div>',
                unsafe_allow_html=True)

    t0, tq, t1, t2 = st.tabs(["Pipeline", "Data quality & governance",
                              "Search the safety corpus", "Governed analytics"])

    # ---- pipeline control + observability ----------------------------------
    with t0:
        ps = da.pipeline_status()
        sc = da.schedule_state()
        running = str(sc.get("state", "")).lower() == "started"

        k = st.columns(5)
        k[0].metric("Open cases", ps.get("OPEN_CASES", "&mdash;"))
        k[1].metric("Evidence rows", ps.get("EVIDENCE_ROWS", "&mdash;"))
        k[2].metric("Active rules", ps.get("ACTIVE_RULES", "&mdash;"))
        k[3].metric("Pipeline runs", ps.get("TOTAL_RUNS", "&mdash;"))
        k[4].metric("Evaluation date", str(ps.get("EVALUATION_DATE", "&mdash;")))

        st.markdown(f"""
        <div class="ho-card ho-card-alt" style="border-left:4px solid
             {'#0E7C5A' if running else '#B45309'};">
          <div style="font-weight:650;font-size:.95rem;
                      color:{'#0E7C5A' if running else '#B45309'};">
            Nightly schedule: {esc(sc.get('state','UNKNOWN'))}
          </div>
          <div style="font-size:.83rem;color:#5A7184;margin-top:.25rem;">
            {esc(sc.get('schedule','-'))} on warehouse
            {esc(sc.get('warehouse','-'))}. Last run
            {esc(ps.get('LAST_RUN_AT') or 'never')} ({esc(ps.get('LAST_TRIGGER') or '-')}):
            {esc(ps.get('LAST_OUTCOME') or '-')}
          </div>
        </div>""", unsafe_allow_html=True)

        c1, c2, c3 = st.columns([1.1, 1.1, 2])
        if c1.button("&#9654;  Run pipeline now", type="primary", key="pipe_run"):
            with st.spinner("Refreshing the 360, re-evaluating rules, "
                            "rebuilding evidence&hellip;"):
                res = da.run_pipeline(force=True, triggered_by="MANUAL")
            if res.get("ok") and not res.get("skipped"):
                st.success(f"Completed. {res.get('open_before')} &rarr; "
                           f"{res.get('open_after')} open cases &middot; "
                           f"{res.get('evidence_rows')} evidence rows.")
            elif res.get("skipped"):
                st.info(f"Skipped &mdash; {res.get('reason')}. "
                        f"{res.get('open_cases')} open cases unchanged.")
            else:
                st.error(res.get("error", "failed"))
            st.rerun()

        if c2.button(("&#9208;  Pause schedule" if running else "&#9654;  Enable schedule"),
                     key="pipe_sched"):
            out = da.set_schedule(not running)
            if out.get("ok"):
                st.success(f"Schedule {out.get('state')}.")
            else:
                st.error(out.get("error", "failed"))
            st.rerun()

        c3.caption("The schedule is the maintenance switch: pause it during "
                   "data loads or a demo, resume it afterwards. It ships "
                   "SUSPENDED because a task is the one thing here that can "
                   "spend credits unattended &mdash; nightly, on the existing XSMALL "
                   "warehouse, and it exits early when no clinical data "
                   "changed.")

        st.markdown('<div class="ho-eyebrow">Run history</div>',
                    unsafe_allow_html=True)
        runs = da.pipeline_runs()
        if not runs:
            st.markdown('<div class="callout">No runs recorded yet.</div>',
                        unsafe_allow_html=True)
        else:
            rb = "".join(
                f"<tr><td class='ho-mono'>{esc(r['STARTED_AT'])}</td>"
                f"<td>{theme.pill(r['TRIGGERED_BY'], 'blue')}</td>"
                f"<td>{'yes' if r['HAD_NEW_DATA'] else 'no'}</td>"
                f"<td class='ho-mono'>{esc(r['CASES_BEFORE'])} &rarr; "
                f"{esc(r['CASES_AFTER'])}</td>"
                f"<td class='ho-mono'>{esc(r['EVIDENCE_ROWS'] if r['EVIDENCE_ROWS'] is not None else '-')}</td>"
                f"<td class='ho-mono'>{esc(r['SECONDS'] if r['SECONDS'] is not None else '-')}s</td>"
                f"<td style='font-size:.82rem;color:#5A7184;'>{esc(r['OUTCOME'])}</td>"
                f"</tr>" for r in runs)
            st.markdown(f"""<table class="ho-tbl"><thead><tr>
              <th>Started</th><th>Trigger</th><th>New data</th><th>Cases</th>
              <th>Evidence</th><th>Took</th><th>Outcome</th>
              </tr></thead><tbody>{rb}</tbody></table>""",
              unsafe_allow_html=True)

        st.markdown('<div class="callout callout-blue" style="margin-top:1rem;">'
                    '<b>How a case actually gets created.</b> New clinical data '
                    'lands in RAW &rarr; the conformance step maps it to '
                    'controlled vocabulary and the person crosswalk &rarr; the '
                    '360 dynamic tables rebuild &rarr; the detection query joins '
                    'every ACTIVE rule to every person and emits candidates '
                    '&rarr; a MERGE folds them into the case registry without '
                    'touching any reviewer decision &rarr; the reconciler '
                    'rebuilds evidence with citations. No step involves a human '
                    'or a model deciding that a case exists.</div>',
                    unsafe_allow_html=True)

    # ---- data quality + governance inventory -------------------------------
    with tq:
        st.markdown('<div class="ho-eyebrow">Data quality</div>',
                    unsafe_allow_html=True)
        st.caption("Monitored properties of the data, each with a stated "
                   "threshold. These complement the 47 build-gate assertions "
                   "in tests/: an assertion blocks a deploy, a metric tells "
                   "you whether the data is healthy right now. Snowflake Data "
                   "Metric Functions are defined for these and evaluate on a "
                   "schedule once EXECUTE DATA METRIC FUNCTION is granted.")
        dq = da.data_quality()
        if not dq:
            st.markdown('<div class="callout">No readings available.</div>',
                        unsafe_allow_html=True)
        else:
            for m in dq:
                ok = m["STATE"] == "OK"
                st.markdown(f"""
                <div class="ho-card" style="border-left:4px solid
                     {'#0E7C5A' if ok else '#B3261E'};">
                  <div style="display:flex;justify-content:space-between;
                              align-items:baseline;">
                    <div style="font-weight:650;font-size:.9rem;">{esc(m['METRIC'])}</div>
                    <div style="font-family:ui-monospace;font-size:.95rem;
                                font-weight:700;
                                color:{'#0E7C5A' if ok else '#B3261E'};">
                      {esc(m['VALUE'])} {esc(m['UNIT'])}
                      <span style="color:#8296A8;font-weight:400;font-size:.78rem;">
                        / threshold {esc(m['THRESHOLD'])}</span></div>
                  </div>
                  <div style="font-size:.81rem;color:#5A7184;margin-top:.3rem;">
                    {esc(m['WHY'])}</div>
                </div>""", unsafe_allow_html=True)

        st.markdown('<div class="ho-eyebrow">Where the patient data is, and '
                    'whether it is protected</div>', unsafe_allow_html=True)
        st.caption("Generated from Snowflake object tags. This is the question "
                   "a compliance reviewer actually asks, and column-by-column "
                   "DDL cannot answer it without someone reading all the SQL.")
        inv = da.phi_inventory()
        if inv:
            ib = "".join(
                f"<tr><td class='ho-mono'>{esc(r['SCH'])}.{esc(r['TBL'])}</td>"
                f"<td class='ho-mono'>{esc(r['COL'])}</td>"
                f"<td>{theme.pill(r['SENSITIVITY'] or '&mdash;', 'high' if r['SENSITIVITY']=='PHI' else 'med' if r['SENSITIVITY']=='QUASI_IDENTIFIER' else 'neut')}</td>"
                f"<td class='ho-mono'>{esc(r['SOURCE_SYSTEM'] or '-')}</td>"
                f"<td style='font-size:.82rem;'>{esc(r['PROTECTION'])}</td></tr>"
                for r in inv)
            st.markdown(f"""<table class="ho-tbl"><thead><tr>
              <th>Object</th><th>Column</th><th>Classification</th>
              <th>Source</th><th>Protection</th>
              </tr></thead><tbody>{ib}</tbody></table>""",
              unsafe_allow_html=True)

    # ---- document retrieval -------------------------------------------------
    with t1:
        st.markdown('<div class="ho-eyebrow">Document retrieval</div>',
                    unsafe_allow_html=True)
        st.caption("Cortex Search over document sections - embedding-based, so "
                   "it matches meaning rather than words. Results cite the "
                   "section they came from, because chunking follows real "
                   "headings rather than fixed character windows: the section "
                   "label is the citation. Each result names the engine that "
                   "found it.")
        q = st.text_input("Search the corpus", value="potassium every 60 days",
                          key="doc_q",
                          placeholder="e.g. ALT 12-week intervals, creatinine quarterly")
        hits = da.search_documents(q) if q else []
        if q and not hits:
            st.markdown('<div class="callout">No section matched. Retrieval '
                        'searches the safety corpus only &mdash; it will not answer '
                        'a question the documents do not address.</div>',
                        unsafe_allow_html=True)
        for h in hits:
            body = esc(h.get("CHUNK_TEXT") or "")[:600]
            st.markdown(f"""
            <div class="ho-card">
              <div style="display:flex;justify-content:space-between;
                          align-items:baseline;gap:1rem;flex-wrap:wrap;">
                <div style="font-weight:650;color:#11567F;font-size:.9rem;">
                  {esc(h.get('DOC_ID'))} &middot; {esc(h.get('SECTION_LABEL'))}</div>
                <div class="ho-mono" style="white-space:nowrap;">
                  #{esc(h.get('RANK'))} &middot; {esc(h.get('ENGINE'))}</div>
              </div>
              <div style="font-size:.79rem;color:#8296A8;margin:.15rem 0 .5rem;">
                   {esc(h.get('TITLE'))} &middot; published {esc(h.get('PUBLISHED'))}</div>
              <div style="font-size:.85rem;line-height:1.55;color:#0B2942;
                          white-space:pre-wrap;">{body}&hellip;</div>
            </div>""", unsafe_allow_html=True)

        st.markdown('<div class="ho-eyebrow">Corpus loaded</div>',
                    unsafe_allow_html=True)
        cs = da.corpus_summary()
        if cs:
            cb = "".join(
                f"<tr><td class='ho-mono'>{esc(c['DOC_ID'])}</td>"
                f"<td>{esc(c['TITLE'])[:70]}</td>"
                f"<td class='ho-mono'>{esc(c['PUBLISHED'])}</td>"
                f"<td>{esc(c['SECTIONS'])}</td></tr>" for c in cs)
            st.markdown(f"""<table class="ho-tbl"><thead><tr>
              <th>Document</th><th>Title</th><th>Published</th><th>Sections</th>
              </tr></thead><tbody>{cb}</tbody></table>""",
              unsafe_allow_html=True)

    # ---- semantic view ------------------------------------------------------
    with t2:
        st.markdown('<div class="ho-eyebrow">Governed analytics</div>',
                    unsafe_allow_html=True)
        st.caption("Answered from the semantic view P360.HEALTHONE_360, where "
                   "dimensions and metrics are declared once with synonyms. No "
                   "SQL is written per question and no free-form text-to-SQL "
                   "runs, so a metric cannot be computed two different ways by "
                   "two different people. This is also the object Cortex "
                   "Analyst consumes, so natural-language querying is a "
                   "switch-on rather than a rebuild.")
        qsel = st.selectbox("Question", list(da.SEMANTIC_QUESTIONS),
                            key="sem_q")
        rows = da.ask_semantic(qsel)
        if not rows:
            st.markdown('<div class="callout">No result.</div>',
                        unsafe_allow_html=True)
        else:
            cols = list(rows[0].keys())
            hdr = "".join(f"<th>{esc(c.replace('_',' ').title())}</th>" for c in cols)
            def _num(v):
                """Whole numbers print as integers; averages keep one place.

                Counts were rendering as "7.0 cases", which reads as a
                measurement rather than a count.
                """
                try:
                    f = float(v)
                except (TypeError, ValueError):
                    return v
                return int(f) if f == int(f) else round(f, 1)

            bd = "".join("<tr>" + "".join(
                    f"<td>{esc(_num(r[c]))}</td>" for c in cols)
                    + "</tr>" for r in rows)
            st.markdown(f'<table class="ho-tbl"><thead><tr>{hdr}</tr></thead>'
                        f'<tbody>{bd}</tbody></table>', unsafe_allow_html=True)
            st.markdown(f'<div class="ho-mono" style="margin-top:.6rem;color:#8296A8;">'
                        f'SELECT * FROM SEMANTIC_VIEW(HEALTHONE.P360.HEALTHONE_360 '
                        f'{esc(da.SEMANTIC_QUESTIONS[qsel])})</div>',
                        unsafe_allow_html=True)

    _eng = da.search_engine()
    st.caption("Retrieval engine in force: " + str(_eng.get('engine'))
               + ". How each tab works, and which tables it reads, is in "
                 "docs/APP_GUIDE.md.")


# ===========================================================================
# AUDIT
# ===========================================================================
else:
    st.markdown("# Audit trail")
    st.markdown('<div style="color:#5A7184;font-size:.885rem;margin-top:-.3rem;">'
                'Append-only. Rule approvals, queue refreshes and every reviewer '
                'decision &mdash; who, when, and why.</div>', unsafe_allow_html=True)

    rows = da.audit_trail(limit=200)
    if not rows:
        st.markdown('<div class="callout">No audit events yet.</div>',
                    unsafe_allow_html=True)
    else:
        body = "".join(f"""
          <tr>
            <td class="ho-mono">{esc(r['EVENT_AT'])}</td>
            <td>{theme.pill(r['EVENT_TYPE'], 'blue')}</td>
            <td class="ho-name">{esc(r['ACTOR'])}</td>
            <td class="ho-mono">{esc(r['SUBJECT_TYPE'])} {esc(r['SUBJECT_ID'])[:22]}</td>
            <td style="font-size:.82rem;color:#5A7184;">{esc((r.get('DETAIL') or '')[:150])}</td>
          </tr>""" for r in rows)
        st.markdown(f"""
        <table class="ho-tbl">
          <thead><tr><th>When</th><th>Event</th><th>Actor</th>
                     <th>Subject</th><th>Detail</th></tr></thead>
          <tbody>{body}</tbody>
        </table>""", unsafe_allow_html=True)

    # --- tamper evidence ----------------------------------------------------
    # "Append-only" used to be a comment in the DDL. It is now a control, and
    # this panel is the evidence: UPDATE/DELETE are revoked from every role,
    # each row carries a content hash, and a checkpoint commits to the whole
    # set so a deletion cannot pass unnoticed.
    ig = da.audit_integrity()
    intact = str(ig.get("VERDICT", "")).startswith("OK")
    st.markdown('<div class="ho-eyebrow" style="margin-top:1.5rem;">'
                'Tamper evidence</div>', unsafe_allow_html=True)
    st.markdown(f"""
    <div class="ho-card {'ho-card-alt' if intact else ''}"
         style="border-left:4px solid {'#0E7C5A' if intact else '#B3261E'};">
      <div style="font-weight:650;color:{'#0E7C5A' if intact else '#B3261E'};
                  font-size:.95rem;margin-bottom:.3rem;">
        {'&#10003;' if intact else '&#9888;'} {esc(ig.get('VERDICT'))}
      </div>
      <div style="font-size:.83rem;color:#5A7184;">
        {esc(ig.get('CURRENT_ROWS'))} events, {esc(ig.get('SEALED_ROWS'))} sealed at
        the last checkpoint, {esc(ig.get('ALTERED_ROWS'))} with a broken content hash.
      </div>
    </div>""", unsafe_allow_html=True)

    # --- identity access log ------------------------------------------------
    st.markdown('<div class="ho-eyebrow">Identity access (break-glass) log</div>',
                unsafe_allow_html=True)
    rv = da.reveal_history()
    if not rv:
        st.markdown('<div class="callout">No patient identity has been revealed. '
                    'Reviewers work from pseudonyms; a name is only retrieved '
                    'deliberately, and doing so appears here.</div>',
                    unsafe_allow_html=True)
    else:
        rb = "".join(f"""
          <tr><td class="ho-mono">{esc(r['GRANTED_AT'])}</td>
              <td class="ho-name">{esc(r['GRANTED_TO'])}</td>
              <td class="ho-mono">{esc(r['PERSON_ID'])}</td>
              <td>{theme.pill(r['REASON_CODE'], 'warn')}</td>
              <td>{theme.pill(r['STATE'], 'ok' if r['STATE']=='ACTIVE' else 'neut')}</td>
              <td style="font-size:.82rem;color:#5A7184;">{esc(r.get('REASON_TEXT'))}</td>
          </tr>""" for r in rv)
        st.markdown(f"""
        <table class="ho-tbl">
          <thead><tr><th>When</th><th>Who</th><th>Patient</th>
                     <th>Stated reason</th><th>State</th><th>Note</th></tr></thead>
          <tbody>{rb}</tbody>
        </table>""", unsafe_allow_html=True)

    st.markdown('<div class="callout callout-blue" style="margin-top:1rem;">'
                'Every decision here is attributable and reversible &mdash; and now '
                'provably unedited.</div>', unsafe_allow_html=True)
