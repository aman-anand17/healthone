"""Design system for HealthOne 360.

Snowflake brand palette, light surface. Kept in one module so the whole app
stays visually consistent and the CSS is editable in a single place.

Palette
    Snowflake Blue  #29B5E8   primary, interactive, brand
    Mid Blue        #11567F   headers, emphasis
    Ink             #0B2942   body text
    Slate           #5A7184   secondary text
    Surface alt     #F4F9FC   panels
    Border          #DCE8F0

Semantic (verdicts and priority) &mdash; chosen to stay legible on white and to read
correctly for the most common colour-vision deficiencies: the red/green pair is
separated by lightness as well as hue, and every colour is paired with an icon
and a text label, never used alone to carry meaning.
    AGREES     #0E7C5A  green
    CONFLICTS  #B45309  amber
    MISSING    #5A7184  slate
    HIGH       #B3261E  red
    MEDIUM     #B45309  amber
"""

CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

:root {
  --sf-blue:      #29B5E8;
  --sf-blue-dk:   #11567F;
  --sf-blue-soft: #E8F6FD;
  --ink:          #0B2942;
  --slate:        #5A7184;
  --slate-lt:     #8296A8;
  --surface:      #FFFFFF;
  --surface-alt:  #F4F9FC;
  --border:       #DCE8F0;
  --border-str:   #C3D6E4;
  --ok:           #0E7C5A;
  --ok-bg:        #E7F5EF;
  --warn:         #B45309;
  --warn-bg:      #FDF3E7;
  --miss:         #5A7184;
  --miss-bg:      #F1F5F8;
  --high:         #B3261E;
  --high-bg:      #FDECEA;
}

/* ---- trim the generic Streamlit chrome ----
   NOTE: do NOT set a height on stHeader and do not hide it. Streamlit renders
   its sidebar-expand control inside that header, and in some versions the
   header is empty until collapse happens &mdash; overriding its box made the sidebar
   unreopenable. Primary navigation therefore lives in the main content area
   (.ho-nav below) and never depends on the sidebar being open. */
#MainMenu, footer {display:none !important;}
[data-testid="stToolbar"] {display:none !important;}
[data-testid="stDecoration"] {display:none !important;}
header[data-testid="stHeader"] {background:transparent !important; box-shadow:none !important;}

/* whichever name this Streamlit build uses for the toggle, keep it usable */
[data-testid="stExpandSidebarButton"] button,
[data-testid="stSidebarCollapsedControl"] button,
[data-testid="collapsedControl"] button {
  background:var(--sf-blue-dk) !important; border-radius:7px !important;
  border:1px solid var(--sf-blue-dk) !important;
  box-shadow:0 2px 6px rgba(11,41,66,.22) !important;
}
[data-testid="stExpandSidebarButton"] svg,
[data-testid="stSidebarCollapsedControl"] svg,
[data-testid="collapsedControl"] svg {fill:#FFFFFF !important; color:#FFFFFF !important;}
[data-testid="stSidebarCollapseButton"] button {
  background:rgba(255,255,255,.14) !important; border:1px solid rgba(255,255,255,.28) !important;
  border-radius:7px !important;
}
[data-testid="stSidebarCollapseButton"] button:hover {background:rgba(255,255,255,.26) !important;}
[data-testid="stSidebarCollapseButton"] svg {fill:#FFFFFF !important;}

/* ---- primary nav (main area, always reachable) ---- */
.ho-nav {display:flex; gap:.22rem; border-bottom:2px solid var(--border);
  margin:0 0 1.25rem; flex-wrap:wrap;}
.ho-nav a {
  padding:.52rem 1.05rem; font-size:.875rem; font-weight:600; text-decoration:none;
  color:var(--slate) !important; border-bottom:3px solid transparent;
  margin-bottom:-2px; border-radius:6px 6px 0 0; transition:all .12s ease;
}
.ho-nav a:hover {color:var(--sf-blue-dk) !important; background:var(--sf-blue-soft);}
.ho-nav a.on {color:var(--sf-blue-dk) !important; border-bottom-color:var(--sf-blue);
  background:var(--sf-blue-soft);}

html, body, [class*="css"] {
  font-family:'Inter',-apple-system,'Segoe UI',sans-serif;
  color:var(--ink);
}
.stApp {background:var(--surface);}
.block-container {padding:1.1rem 2.2rem 4rem; max-width:1560px;}

/* ---- sidebar: fully suppressed ----
   The sidebar was removed (its collapse control could not be reliably
   reopened). Its old gradient styling was still painting a dark strip down
   the left edge, so the container is hidden outright rather than styled. */
[data-testid="stSidebar"], [data-testid="stSidebarNav"],
[data-testid="stSidebarContent"], [data-testid="stSidebarHeader"],
[data-testid="stSidebarCollapseButton"], [data-testid="stExpandSidebarButton"] {
  display:none !important; width:0 !important; visibility:hidden !important;
}

/* ---- typography ---- */
h1 {font-size:1.72rem !important; font-weight:700 !important; letter-spacing:-.02em;
    color:var(--ink) !important; margin-bottom:.15rem !important;}
h2 {font-size:1.18rem !important; font-weight:650 !important; color:var(--sf-blue-dk) !important;}
h3 {font-size:1rem !important; font-weight:650 !important; color:var(--sf-blue-dk) !important;}
h4 {font-size:.92rem !important; font-weight:650 !important; color:var(--ink) !important;}
p, li, .stMarkdown {font-size:.905rem; line-height:1.58;}

/* ---- brand bar ---- */
.ho-topbar {
  display:flex; align-items:center; justify-content:space-between;
  padding:.62rem 1.05rem; margin:-.3rem 0 1.35rem;
  background:var(--surface-alt); border:1px solid var(--border);
  border-left:4px solid var(--sf-blue); border-radius:9px;
}
.ho-brand {display:flex; align-items:baseline; gap:.62rem;}
.ho-brand-name {font-weight:700; font-size:1.02rem; letter-spacing:-.015em; color:var(--sf-blue-dk);}
.ho-brand-sub {font-size:.78rem; color:var(--slate);}
.ho-topmeta {display:flex; gap:1.6rem; align-items:center;}
.ho-topmeta .lbl {font-size:.62rem; letter-spacing:.09em; text-transform:uppercase;
  color:var(--slate-lt); font-weight:600; display:block; line-height:1.5;}
.ho-topmeta .val {font-size:.83rem; font-weight:600; color:var(--ink);}

/* ---- section label ---- */
.ho-eyebrow {
  font-size:.66rem; letter-spacing:.11em; text-transform:uppercase;
  color:var(--slate); font-weight:700; margin:1.5rem 0 .5rem;
}

/* ---- cards ---- */
.ho-card {
  background:var(--surface); border:1px solid var(--border);
  border-radius:10px; padding:1.02rem 1.15rem; margin-bottom:.8rem;
}
.ho-card-alt {background:var(--surface-alt);}

/* ---- queue table ---- */
.ho-tbl {width:100%; border-collapse:separate; border-spacing:0;
  border:1px solid var(--border); border-radius:10px; overflow:hidden;
  font-size:.875rem;}
.ho-tbl thead th {
  background:var(--surface-alt); text-align:left; padding:.62rem .85rem;
  font-size:.64rem; letter-spacing:.09em; text-transform:uppercase;
  color:var(--slate); font-weight:700; border-bottom:1px solid var(--border);
  white-space:nowrap;
}
.ho-tbl tbody td {padding:.72rem .85rem; border-bottom:1px solid #EDF3F8; vertical-align:middle;}
.ho-tbl tbody tr:last-child td {border-bottom:none;}
.ho-tbl tbody tr:hover {background:var(--sf-blue-soft);}
.ho-tbl a.ho-rowlink {color:var(--sf-blue-dk); font-weight:650; text-decoration:none;}
.ho-tbl a.ho-rowlink:hover {text-decoration:underline;}
.ho-name {font-weight:600; color:var(--ink);}
.ho-ids  {font-family:ui-monospace,'SF Mono',monospace; font-size:.735rem; color:var(--slate);}
.ho-trigger {color:var(--ink);}
.ho-mono {font-family:ui-monospace,'SF Mono',monospace; font-size:.76rem; color:var(--slate);}

/* ---- FORCE A LIGHT SURFACE ON EVERY WIDGET ----
   Snowsight renders the Streamlit iframe with a dark theme. This app is
   light-first, so widget internals inherited dark backgrounds and ended up
   dark-text-on-dark: the break-glass expander header and the note input were
   both unreadable in the deployed app while fine locally. Everything that can
   carry a background is pinned explicitly rather than inherited. */
.stApp, .main, .block-container,
[data-testid="stAppViewContainer"], [data-testid="stMain"] {
  background:#FFFFFF !important; color:var(--ink) !important;
}

/* expanders */
[data-testid="stExpander"] {
  background:#FFFFFF !important; border:1px solid var(--border) !important;
  border-radius:10px !important;
}
[data-testid="stExpander"] summary,
[data-testid="stExpander"] details > summary {
  background:var(--surface-alt) !important; color:var(--sf-blue-dk) !important;
  font-weight:650 !important; border-radius:9px 9px 0 0 !important;
}
[data-testid="stExpander"] summary:hover {background:var(--sf-blue-soft) !important;}
[data-testid="stExpander"] summary * ,
[data-testid="stExpander"] summary svg {color:var(--sf-blue-dk) !important; fill:var(--sf-blue-dk) !important;}
[data-testid="stExpander"] [data-testid="stExpanderDetails"] {
  background:#FFFFFF !important; color:var(--ink) !important;
}

/* text inputs, textareas, selects */
.stTextInput input, .stTextArea textarea, .stNumberInput input,
[data-baseweb="input"] input, [data-baseweb="textarea"] textarea {
  background:#FFFFFF !important; color:var(--ink) !important;
  border:1px solid var(--border-str) !important; border-radius:8px !important;
}
.stTextInput input::placeholder, .stTextArea textarea::placeholder {
  color:var(--slate-lt) !important; opacity:1 !important;
}
[data-baseweb="input"], [data-baseweb="textarea"], [data-baseweb="base-input"] {
  background:#FFFFFF !important;
}
[data-baseweb="select"] > div, [data-baseweb="select"] div[role="button"] {
  background:#FFFFFF !important; color:var(--ink) !important;
}
/* Every popover surface, belt and braces.
   .streamlit/config.toml pins the light theme, which is the real fix - this
   block is the belt. It exists because Streamlit renames and adds popover
   containers between releases, and an unstyled one shows up as a black
   dropdown against a white app. Listing them by BOTH the BaseWeb attribute and
   the Streamlit test id means a rename has to break two names, not one. */
[data-baseweb="popover"], [data-baseweb="menu"], [role="listbox"],
[data-baseweb="popover"] > div, [data-baseweb="menu"] > ul,
ul[role="listbox"], [data-testid="stSelectboxVirtualDropdown"],
[data-testid="stVirtualDropdown"], [data-testid="stMultiSelectVirtualDropdown"],
[data-testid="stTooltipContent"] {
  background:#FFFFFF !important; color:var(--ink) !important;
}
[data-testid="stTooltipContent"] {
  border:1px solid var(--border) !important; border-radius:8px !important;
}
[data-baseweb="menu"] li, [role="option"], [role="option"] * {
  background:transparent !important; color:var(--ink) !important;
}
[role="option"]:hover, [role="option"][aria-selected="true"] {
  background:var(--sf-blue-soft) !important;
}
/* The hover toolbar over dataframes is dark BY DESIGN in Streamlit's own CSS,
   which reads as a stray black box on a white card. */
[data-testid="stElementToolbar"] {
  background:var(--surface-alt) !important;
  border:1px solid var(--border) !important; border-radius:8px !important;
}
[data-testid="stElementToolbarButton"] svg,
[data-testid="stElementToolbar"] button svg {fill:var(--slate) !important;}
/* The typed-into part of a select, which is a separate node from the box. */
[data-baseweb="select"] input {
  background:transparent !important; color:var(--ink) !important;
}

/* captions, labels, markdown, metrics */
[data-testid="stCaptionContainer"], [data-testid="stCaptionContainer"] * {
  color:var(--slate) !important; font-size:.83rem !important; line-height:1.55 !important;
}
[data-testid="stMetricLabel"], [data-testid="stMetricLabel"] * {color:var(--slate) !important;}
[data-testid="stMetricValue"] {color:var(--ink) !important;}
[data-testid="stMarkdownContainer"] {color:var(--ink) !important;}
.stTextInput label, .stTextArea label, .stSelectbox label,
.stMultiSelect label, .stRadio label {color:var(--slate) !important;}

/* tabs - they previously ran together with no gap or padding */
[data-baseweb="tab-list"] {
  background:transparent !important; gap:.35rem !important;
  border-bottom:2px solid var(--border) !important; margin-bottom:1.1rem !important;
}
[data-baseweb="tab"] {
  color:var(--slate) !important; background:transparent !important;
  padding:.55rem 1.05rem !important; font-size:.875rem !important;
  font-weight:600 !important; border-radius:7px 7px 0 0 !important;
  white-space:nowrap !important;
}
[data-baseweb="tab"]:hover {
  color:var(--sf-blue-dk) !important; background:var(--sf-blue-soft) !important;
}
[data-baseweb="tab"][aria-selected="true"] {
  color:var(--sf-blue-dk) !important; background:var(--sf-blue-soft) !important;
}
[data-baseweb="tab-highlight"] {background:var(--sf-blue) !important; height:3px !important;}
[data-baseweb="tab-border"] {display:none !important;}

/* alerts keep readable text on their tinted grounds */
[data-testid="stAlert"] {color:var(--ink) !important;}
[data-testid="stAlert"] * {color:inherit !important;}

/* ---- queue rows (button-per-row layout) ---- */
.ho-qhead {display:flex; gap:.6rem; padding:.5rem .2rem; border-bottom:1px solid var(--border);
  font-size:.64rem; letter-spacing:.09em; text-transform:uppercase;
  color:var(--slate); font-weight:700;}
.ho-qhead span:nth-child(1){flex:1.5;} .ho-qhead span:nth-child(2){flex:1.3;}
.ho-qhead span:nth-child(3){flex:3.2;} .ho-qhead span:nth-child(4){flex:.9;}
.ho-qhead span:nth-child(5){flex:1.0;}
.ho-qrule {border-bottom:1px solid #EDF3F8; margin:.1rem 0 .1rem;}

/* ---- pills ---- */
.pill {display:inline-block; padding:.16rem .55rem; border-radius:20px;
  font-size:.665rem; font-weight:700; letter-spacing:.045em; text-transform:uppercase;
  white-space:nowrap; border:1px solid transparent;}
.pill-high {background:var(--high-bg); color:var(--high); border-color:#F3C9C5;}
.pill-med  {background:var(--warn-bg); color:var(--warn); border-color:#F0DBBE;}
.pill-ok   {background:var(--ok-bg);   color:var(--ok);   border-color:#BFE5D6;}
.pill-neut {background:var(--miss-bg); color:var(--miss); border-color:var(--border-str);}
.pill-blue {background:var(--sf-blue-soft); color:var(--sf-blue-dk); border-color:#B6E3F7;}

/* ---- citation chip ---- */
.chip {display:inline-flex; align-items:center; gap:.3rem;
  background:var(--surface-alt); border:1px solid var(--border-str);
  border-radius:5px; padding:.14rem .48rem; margin:.14rem .3rem .14rem 0;
  font-family:ui-monospace,'SF Mono',monospace; font-size:.715rem; color:var(--sf-blue-dk);
  font-weight:500;}
.chip-src {color:var(--slate); font-weight:700; font-size:.64rem; letter-spacing:.04em;}

/* ---- evidence cards ---- */
.ev {border:1px solid var(--border); border-left-width:4px; border-radius:9px;
  padding:.85rem 1.05rem; margin-bottom:.72rem; background:var(--surface);}
.ev-agrees    {border-left-color:var(--ok);}
.ev-conflicts {border-left-color:var(--warn);}
.ev-missing   {border-left-color:var(--miss); background:var(--miss-bg);}
.ev-head {display:flex; align-items:center; gap:.55rem; margin-bottom:.3rem;}
.ev-claim {font-weight:600; font-size:.93rem; color:var(--ink); line-height:1.45;}
.ev-note {font-size:.765rem; color:var(--slate); margin:.1rem 0 .55rem;}
.ev-src {border-left:2px solid var(--border-str); padding:.28rem 0 .28rem .68rem;
  margin:.34rem 0; font-size:.845rem; color:#20374B;}
.ev-cols {display:flex; gap:.9rem; flex-wrap:wrap;}
.ev-col {flex:1 1 210px; background:var(--surface-alt); border:1px solid var(--border);
  border-radius:7px; padding:.6rem .72rem;}
.ev-col-hd {font-size:.63rem; letter-spacing:.08em; text-transform:uppercase;
  font-weight:700; color:var(--warn); margin-bottom:.28rem;}

/* ---- key/value strip ---- */
.kv-strip {display:flex; gap:2rem; flex-wrap:wrap; padding:.9rem 1.15rem;
  background:var(--surface-alt); border:1px solid var(--border); border-radius:10px;}
.kv .k {font-size:.63rem; letter-spacing:.09em; text-transform:uppercase;
  color:var(--slate-lt); font-weight:700; display:block; margin-bottom:.1rem;}
.kv .v {font-size:.945rem; font-weight:600; color:var(--ink);}
.kv .v-sm {font-size:.78rem; font-weight:500; color:var(--slate);}

/* ---- metric tiles ---- */
.tiles {display:flex; gap:.72rem; flex-wrap:wrap;}
.tile {flex:1 1 130px; background:var(--surface); border:1px solid var(--border);
  border-radius:9px; padding:.72rem .85rem;}
.tile .n {font-size:1.42rem; font-weight:700; color:var(--sf-blue-dk); line-height:1.15;}
.tile .l {font-size:.66rem; letter-spacing:.07em; text-transform:uppercase;
  color:var(--slate); font-weight:600; margin-top:.12rem;}

/* ---- callout ---- */
.callout {border-radius:9px; padding:.72rem .95rem; font-size:.86rem;
  border:1px solid var(--border); background:var(--surface-alt); color:#20374B;}
.callout-blue {background:var(--sf-blue-soft); border-color:#B6E3F7; color:#0C4A6E;}
.callout-warn {background:var(--warn-bg); border-color:#F0DBBE; color:#7C3D06;}

/* ---- narrative ---- */
.narr {background:var(--sf-blue-soft); border:1px solid #B6E3F7; border-radius:10px;
  padding:1rem 1.15rem; font-size:.905rem; line-height:1.62; color:#0C4A6E;}

/* ---- buttons ---- */
.stButton > button {
  border-radius:8px !important; font-weight:600 !important; font-size:.845rem !important;
  padding:.46rem 1.05rem !important; letter-spacing:.005em;
  border:1px solid var(--border-str) !important; background:#FFFFFF !important;
  color:var(--sf-blue-dk) !important; box-shadow:0 1px 2px rgba(11,41,66,.05) !important;
  transition:all .14s ease !important;
  /* Uniform height and no wrapping. "Document intake" wrapped onto two lines
     and made that one nav button taller than the other five, so the whole row
     looked broken. Pinning the height means no future label can do it. */
  min-height:2.4rem; height:2.4rem;
  white-space:nowrap !important; overflow:hidden; text-overflow:ellipsis;
  display:inline-flex !important; align-items:center; justify-content:center;
}
.stButton > button:hover {
  border-color:var(--sf-blue) !important; background:var(--sf-blue-soft) !important;
  box-shadow:0 2px 7px rgba(41,181,232,.20) !important; transform:translateY(-1px);
}
.stButton > button:active {transform:translateY(0); box-shadow:none !important;}
.stButton > button[kind="primary"] {
  background:linear-gradient(135deg,#29B5E8 0%,#1583B8 100%) !important;
  border:1px solid #1583B8 !important; color:#FFFFFF !important;
  box-shadow:0 2px 8px rgba(21,131,184,.30) !important; font-weight:650 !important;
}
.stButton > button[kind="primary"]:hover {
  background:linear-gradient(135deg,#3FC2F0 0%,#1170A0 100%) !important;
  box-shadow:0 4px 13px rgba(21,131,184,.38) !important;
}
.stButton > button[kind="primary"]:active {
  background:linear-gradient(135deg,#1583B8 0%,#0F5F86 100%) !important;
}

/* ---- multiselect tags: default Streamlit cyan looks generic ---- */
[data-baseweb="tag"] {
  background:var(--sf-blue-soft) !important; border:1px solid #A5DCF4 !important;
  border-radius:5px !important;
}
[data-baseweb="tag"] span, [data-baseweb="tag"] div {
  color:var(--sf-blue-dk) !important; font-weight:600 !important; font-size:.775rem !important;
}
[data-baseweb="tag"] svg {fill:var(--sf-blue-dk) !important;}
[data-baseweb="select"] > div {
  border-radius:8px !important; border-color:var(--border-str) !important;
  background:#FFFFFF !important; min-height:2.4rem;
}
.stMultiSelect label, .stTextArea label, .stTextInput label {
  font-size:.66rem !important; letter-spacing:.09em !important; text-transform:uppercase;
  font-weight:700 !important; color:var(--slate) !important;
}

/* ---- links: Streamlit's default anchor colour overrides ours ---- */
.ho-tbl a.ho-rowlink, a.ho-rowlink:visited {color:var(--sf-blue-dk) !important;}
.ho-tbl a.ho-rowlink:hover {color:var(--sf-blue) !important;}

/* ---- inputs / expanders / tabs ---- */
[data-testid="stExpander"] {border:1px solid var(--border) !important;
  border-radius:9px !important; background:var(--surface);}
[data-testid="stExpander"] summary {font-size:.845rem; font-weight:600; color:var(--sf-blue-dk);}
.stTabs [data-baseweb="tab-list"] {gap:.3rem; border-bottom:1px solid var(--border);}
.stTabs [data-baseweb="tab"] {font-size:.87rem; font-weight:600; color:var(--slate);}
.stTabs [aria-selected="true"] {color:var(--sf-blue-dk) !important;}
.stTextArea textarea, .stTextInput input {
  border-radius:7px !important; border-color:var(--border-str) !important; font-size:.87rem;}
hr {margin:1.1rem 0; border-color:var(--border);}
</style>
"""


def pill(text, kind="neut"):
    return f'<span class="pill pill-{kind}">{text}</span>'


def priority_pill(p):
    return pill(p, "high" if p == "HIGH" else "med")


def chip(source, ident):
    return (f'<span class="chip"><span class="chip-src">{source}</span>{ident}</span>')


VERDICT = {
    "AGREES":    {"icon": "&#10003;", "cls": "agrees",    "pill": "ok",
                  "note": "More than one source supports this."},
    "CONFLICTS": {"icon": "!", "cls": "conflicts", "pill": "med",
                  "note": "Sources disagree. The system shows both and does not choose."},
    "MISSING":   {"icon": "&ndash;", "cls": "missing",   "pill": "neut",
                  "note": "Expected evidence was not found in the available records."},
}


# ---------------------------------------------------------------------------
# Corroboration figure
#
# Aman's objection, and he was right: "How can anything be 100% certain."
# Nothing here is. A bare percentage reads as a certainty claim however the
# caption is worded, so the figure leads with the COUNT of checks and the
# RATING, and the percentage survives only as the weighted-points detail.
#
# The form is a SEGMENTED METER, not a pie. A single ratio against a limit is
# a meter's job; a two-slice pie is the classic wrong answer to it. Segmenting
# it per check buys something a plain bar cannot: the meter and the checklist
# beneath it are the same nine things, so the picture is the evidence rather
# than a summary of it.
#
# The fill carries severity and the gaps are neutral track - deliberately NOT
# green-for-pass beside red-for-fail. Red and green are the pair deuteranopia
# collapses, so a pass/fail meter coloured that way is unreadable for roughly
# one man in twelve. Absence of fill carries the failure instead, and the
# labelled checklist underneath names every one of them in words.
# ---------------------------------------------------------------------------

RATING_STEPS = ("Contradicted", "Not corroborated", "Partly corroborated",
                "Fully corroborated")

# Severity of the FILL follows the rating, so one accent is on screen at a time.
_RATING_FILL = {4: "var(--ok)", 3: "var(--warn)", 2: "var(--high)", 1: "var(--high)"}


def corroboration_meter(checklist, rating_step, height=10):
    """One segment per check, width proportional to that check's weight.

    checklist entries are 'Y|N|S <weight> <label>' as published by
    RULES.V_PROPOSAL_CORROBORATION. A skipped check is drawn as a hatch rather
    than a colour: it is neither a pass nor a failure, and hue cannot say that.
    """
    fill = _RATING_FILL.get(rating_step, "var(--slate)")
    segs = []
    for entry in checklist or []:
        parts = str(entry).split(" ", 2)
        mark = parts[0] if parts else "S"
        try:
            weight = int(parts[1])
        except (IndexError, ValueError):
            weight = 1
        if mark == "Y":
            style = f"background:{fill};"
        elif mark == "N":
            style = "background:var(--border-str);"
        else:
            style = ("background:repeating-linear-gradient(45deg,"
                     "var(--border) 0 3px,var(--surface-alt) 3px 6px);")
        segs.append(f'<div style="flex:{weight} 1 0;{style}"></div>')
    return ('<div style="display:flex;gap:2px;height:%dpx;border-radius:%dpx;'
            'overflow:hidden;background:var(--surface-alt);">%s</div>'
            % (height, height // 2, "".join(segs)))


def rating_ladder(rating_step):
    """The four-step scale with this proposal's position marked.

    Shown as a scale rather than a lone badge because a label on its own gives
    a reviewer no sense of what the other outcomes even are - and "Fully
    corroborated" only means something once you can see it is the top of four.
    """
    fill = _RATING_FILL.get(rating_step, "var(--slate)")
    out = []
    for i, name in enumerate(RATING_STEPS, start=1):
        here = (i == rating_step)
        out.append(
            '<span style="display:inline-flex;align-items:center;gap:.3rem;'
            'font-size:.72rem;'
            + ('color:var(--ink);font-weight:650;'
               if here else 'color:var(--slate-lt);') + '">'
            + '<span style="width:7px;height:7px;border-radius:50%;background:'
            + (fill if here else 'var(--border-str)') + ';"></span>'
            + name + '</span>')
    return ('<div style="display:flex;flex-wrap:wrap;gap:.1rem .9rem;'
            'margin:.45rem 0 0;">' + "".join(out) + '</div>')
