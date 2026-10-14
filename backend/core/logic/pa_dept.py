"""
pa_dept.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · DEPARTMENTAL UPDATE roll-up (issue #117, SPEC v2.1 §14,
built to the §21 ADVANCED standard; CORPORATE tier).

WHAT THIS IS
------------
A departmental-status roll-up. The PA collects one UPDATE per department —
each with a department name, its lead, HIGHLIGHTS, BLOCKERS and a few METRICS —
and the engine ASSEMBLES a deterministic rolled-up SUMMARY across departments:
counts of departments reporting, total highlights / blockers, the departments
that are BLOCKED (have ≥1 blocker), and a per-department structured block.

    update = {department, lead, highlights[], blockers[], metrics[]}
    metric = {label, value}   (value passes through verbatim — never computed)

Nothing is fabricated: highlights/blockers/metrics are the owner's own words,
grouped, counted and ordered. The roll-up is a MOCK ("AI-generated — review")
because the STRUCTURE / counting is generated; the content is the owner's.

STRUCTURE IS LANGUAGE-AWARE
---------------------------
Fixed scaffolding (the "Highlights" / "Blockers" / "Metrics" headings, the
"N departments reporting" / "M blocked" roll-up labels) differs bn/en, so —
like pa_letters.py / pa_board.py — the engine returns a STRUCTURED result of
{role, text, phrase, num} lines using NEUTRAL phrase KEYS; the UI renders the
localised bn/en phrase. Owner text passes through verbatim; no translation.

METRICS ARE REPORTED, NEVER COMPUTED
------------------------------------
A metric's value is whatever the owner typed (e.g. "92%", "৳4.2L", "on track").
We never do arithmetic on it or infer a trend — reporting only. ৳ passes through.

KEY-GATED, HONEST
-----------------
Assembly needs NO key. An AI-SYNTHESISED narrative (prose weaving the updates
into an executive paragraph) is a DOCUMENTED key-gated seam:
`rollup(..., want_ai_synthesis=True)` sets `ai_required=True` and NEVER
fabricates prose — the deterministic structured roll-up is always produced; the
UI shows "connect an AI key for an AI-written synthesis".

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments. Hand-verified in
pa_dept_tests_snippets.py. Mirrored by app/lib/screens/pa/dept_update_screen.dart.
"""

# ------------------------------------------------------------------ vocabulary

ROLE_DEPT = "dept"              # a department header (name — lead)
ROLE_SECTION = "section"       # Highlights / Blockers / Metrics heading
ROLE_ITEM = "item"             # a bullet (highlight / blocker)
ROLE_METRIC = "metric"         # a "label: value" metric line
ROLE_ROLLUP = "rollup"         # a counted cross-department roll-up line
ROLE_NOTE = "note"             # a deterministic note (e.g. none reported)

# Neutral phrase KEYS the UI localises.
PHRASE_HIGHLIGHTS = "highlights"
PHRASE_BLOCKERS = "blockers"
PHRASE_METRICS = "metrics"
PHRASE_REPORTING = "reporting"        # "N departments reporting"
PHRASE_BLOCKED = "blocked"            # "M departments blocked"
PHRASE_CLEAR = "clear"                # "no blockers reported"
PHRASE_TOTAL_HL = "total_highlights"
PHRASE_TOTAL_BL = "total_blockers"
PHRASE_NONE = "none"                  # a section with no items
PHRASE_NO_LEAD = "no_lead"            # lead not named

# The honest marker key every roll-up carries.
MARKER_KEY = "ai_review"


# ------------------------------------------------------------------ helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _bullets(v):
    """Normalise highlights/blockers to a list of non-empty trimmed strings.
    Accepts a list or a newline-separated string. Deterministic."""
    if v is None:
        return []
    raw = v.replace("\r\n", "\n").split("\n") if isinstance(v, str) else list(v)
    out = []
    for p in raw:
        s = _clean(p)
        if s:
            out.append(s)
    return out


def _metrics(v):
    """Normalise metrics to a list of {label, value} with non-empty labels.
    Value passes through verbatim (never computed). Deterministic."""
    out = []
    for m in (v or []):
        if not isinstance(m, dict):
            continue
        label = _clean(m.get("label"))
        if not label:
            continue
        out.append({"label": label, "value": _clean(m.get("value"))})
    return out


def _line(role, text="", phrase="", num=0):
    return {"role": role, "text": text, "phrase": phrase, "num": num}


def _norm_update(u):
    """One raw update dict → a normalised dict. Deterministic; never crashes."""
    u = u if isinstance(u, dict) else {}
    return {
        "department": _clean(u.get("department")),
        "lead": _clean(u.get("lead")),
        "highlights": _bullets(u.get("highlights")),
        "blockers": _bullets(u.get("blockers")),
        "metrics": _metrics(u.get("metrics")),
    }


# ------------------------------------------------------------------ validate

def validate(updates=None):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    Need at least one update with a department name. An update that has a
    department name but no highlights AND no blockers is flagged `empty_update`
    so the owner knows it carries nothing (we still include it, honestly)."""
    problems = []
    norm = [_norm_update(u) for u in (updates or [])]
    named = [u for u in norm if u["department"]]
    if not named:
        problems.append("no_departments")
    for u in named:
        if not u["highlights"] and not u["blockers"] and not u["metrics"]:
            problems.append("empty_update")
            break
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------------ roll-up

def rollup(updates=None, want_ai_synthesis=False):
    """Assemble a cross-department roll-up. PURE — no clock, no AI.

    Returns a dict:
        counts (dict), lines (list, structured per-department + roll-up),
        problems, ai_required, mock, marker.

    `counts` = {departments, blocked, highlights, blockers}. The per-department
    structured block preserves input order (stable). Metrics report verbatim.

    Key-gated: `want_ai_synthesis=True` → `ai_required=True`; the deterministic
    structured roll-up is ALWAYS produced (we never fabricate an AI narrative)."""
    norm = [_norm_update(u) for u in (updates or [])]
    named = [u for u in norm if u["department"]]

    total_hl = sum(len(u["highlights"]) for u in named)
    total_bl = sum(len(u["blockers"]) for u in named)
    blocked = [u for u in named if u["blockers"]]
    counts = {
        "departments": len(named),
        "blocked": len(blocked),
        "highlights": total_hl,
        "blockers": total_bl,
    }

    lines = []

    # ---- top roll-up lines (counted)
    lines.append(_line(ROLE_ROLLUP, str(len(named)),
                       phrase=PHRASE_REPORTING, num=len(named)))
    if blocked:
        lines.append(_line(ROLE_ROLLUP, str(len(blocked)),
                           phrase=PHRASE_BLOCKED, num=len(blocked)))
    else:
        lines.append(_line(ROLE_ROLLUP, phrase=PHRASE_CLEAR))
    lines.append(_line(ROLE_ROLLUP, str(total_hl),
                       phrase=PHRASE_TOTAL_HL, num=total_hl))
    lines.append(_line(ROLE_ROLLUP, str(total_bl),
                       phrase=PHRASE_TOTAL_BL, num=total_bl))

    # ---- per-department structured blocks (input order preserved)
    for u in named:
        header = u["department"]
        lines.append(_line(ROLE_DEPT, header,
                           phrase="" if u["lead"] else PHRASE_NO_LEAD,
                           # text2 carried via a trailing " — lead" when present
                           ))
        if u["lead"]:
            # fold lead into the dept line text deterministically
            lines[-1]["text"] = header + " — " + u["lead"]

        lines.append(_line(ROLE_SECTION, phrase=PHRASE_HIGHLIGHTS,
                           num=len(u["highlights"])))
        if u["highlights"]:
            for h in u["highlights"]:
                lines.append(_line(ROLE_ITEM, h, phrase=PHRASE_HIGHLIGHTS))
        else:
            lines.append(_line(ROLE_NOTE, phrase=PHRASE_NONE))

        lines.append(_line(ROLE_SECTION, phrase=PHRASE_BLOCKERS,
                           num=len(u["blockers"])))
        if u["blockers"]:
            for b in u["blockers"]:
                lines.append(_line(ROLE_ITEM, b, phrase=PHRASE_BLOCKERS))
        else:
            lines.append(_line(ROLE_NOTE, phrase=PHRASE_NONE))

        if u["metrics"]:
            lines.append(_line(ROLE_SECTION, phrase=PHRASE_METRICS,
                               num=len(u["metrics"])))
            for m in u["metrics"]:
                lines.append(_line(ROLE_METRIC, m["value"], phrase="",
                                   # label in text via "label\tvalue"? keep clean:
                                   ))
                # store label + value deterministically: text="label: value"
                val = m["value"]
                lines[-1]["text"] = (m["label"] + ": " + val) if val else m["label"]

    return {
        "counts": counts,
        "lines": lines,
        "problems": validate(updates),
        "ai_required": bool(want_ai_synthesis),
        "mock": True,
        "marker": MARKER_KEY,
    }
