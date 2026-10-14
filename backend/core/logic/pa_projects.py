"""
pa_projects.py — the deterministic engine behind PA SECRETARY MODE CORPORATE
PROJECT TRACKING (issue #120, SPEC v2.1 §14, ADVANCED).

The PA tracks the projects the BOSS oversees: PROJECTS (name, owner, status,
% complete, due date), per-project MILESTONES (title, date, status), RISKS /
ISSUES (severity + status), and a deterministic PORTFOLIO roll-up (on-track /
at-risk / overdue counts). "Overdue" is always computed from a passed-in `now`
so the result is honest and the tests can pin it.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.
Mirrors the conventions of the other pa_*/logic modules.

MANUAL-FIRST, HONEST AI SEAM (NEVER FABRICATES)
-----------------------------------------------
Everything here is entered and rolled up by hand — no model is ever called.
A narrative "status synthesis" (turning the manual fields into a crisp prose
update for the boss) needs a real model, so `status_synthesis_seam()` HONESTLY
returns `{required: True, mock: True, text: ""}` — the UI shows a "connect an AI
key" card and we NEVER fabricate a status narrative. The request shape mirrors
`core.ai.generate` so the integrator can wire the real path later; the pure
`portfolio_summary` below is always available key-free.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_projects_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Project status (neutral English seed keys; the UI localises them).
ST_PLANNED = "planned"
ST_ACTIVE = "active"
ST_ON_HOLD = "on_hold"
ST_DONE = "done"
ST_CANCELLED = "cancelled"
PROJECT_STATES = (ST_PLANNED, ST_ACTIVE, ST_ON_HOLD, ST_DONE, ST_CANCELLED)

# A status is "open" (still counts toward the portfolio health) unless it is
# finished or dropped.
_CLOSED_STATES = (ST_DONE, ST_CANCELLED)

# Milestone status.
MS_PENDING = "pending"
MS_DONE = "done"
MS_MISSED = "missed"
MILESTONE_STATES = (MS_PENDING, MS_DONE, MS_MISSED)

# Risk severity + status.
RISK_LOW = "low"
RISK_MED = "med"
RISK_HIGH = "high"
RISK_SEVERITIES = (RISK_LOW, RISK_MED, RISK_HIGH)
RISK_OPEN = "open"
RISK_CLOSED = "closed"
RISK_STATES = (RISK_OPEN, RISK_CLOSED)

# Portfolio health buckets a project can fall into (one each, mutually
# exclusive; see classify_project).
HEALTH_DONE = "done"
HEALTH_OVERDUE = "overdue"     # open + due date already passed `now`
HEALTH_AT_RISK = "at_risk"     # open + has an open high risk OR a missed MS
HEALTH_ON_TRACK = "on_track"   # open + everything else

# The honest marker key the AI status-synthesis seam carries.
AI_MARKER_KEY = "ai_review"


# ------------------------------------------------------------------ parsing

def _parse(dt):
    """Lenient ISO-8601 → datetime, or None. Accepts a trailing 'Z'. Never
    raises."""
    if not dt:
        return None
    s = str(dt).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _pct(v):
    """Clamp a % value to the inclusive 0..100 integer range; junk → 0."""
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return 0
    return max(0, min(100, n))


# ------------------------------------------------------------- normalization

def normalize_project(project):
    """Coerce a dict into a clean project header. Unknown status → 'planned';
    percent clamped to 0..100. Never raises; never invents a due date."""
    p = dict(project or {})
    status = p.get("status")
    if status not in PROJECT_STATES:
        status = ST_PLANNED
    return {
        "id": p.get("id"),
        "name": _clean(p.get("name")),
        "owner": _clean(p.get("owner")),
        "status": status,
        "percent": _pct(p.get("percent")),
        "due": (str(p.get("due")).strip() if p.get("due") else ""),
        "note": str(p.get("note") or ""),
    }


def normalize_milestone(ms):
    """Coerce a dict into a clean milestone. Unknown status → 'pending'."""
    x = dict(ms or {})
    status = x.get("status")
    if status not in MILESTONE_STATES:
        status = MS_PENDING
    return {
        "id": x.get("id"),
        "project_id": x.get("project_id"),
        "title": _clean(x.get("title")),
        "date": (str(x.get("date")).strip() if x.get("date") else ""),
        "status": status,
        "note": str(x.get("note") or ""),
    }


def normalize_risk(risk):
    """Coerce a dict into a clean risk/issue. Unknown severity → 'med';
    unknown status → 'open'."""
    x = dict(risk or {})
    sev = x.get("severity")
    if sev not in RISK_SEVERITIES:
        sev = RISK_MED
    status = x.get("status")
    if status not in RISK_STATES:
        status = RISK_OPEN
    return {
        "id": x.get("id"),
        "project_id": x.get("project_id"),
        "label": _clean(x.get("label")),
        "severity": sev,
        "status": status,
        "note": str(x.get("note") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_project(project):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.
    A name is required; due must parse if present."""
    p = normalize_project(project)
    problems = []
    if not p["name"]:
        problems.append("name_required")
    if p["due"] and _parse(p["due"]) is None:
        problems.append("bad_due")
    return problems


def validate_milestone(ms):
    """A milestone needs a title; date must parse if present."""
    x = normalize_milestone(ms)
    problems = []
    if not x["title"]:
        problems.append("title_required")
    if x["date"] and _parse(x["date"]) is None:
        problems.append("bad_date")
    return problems


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"


def _date_key(ev, field):
    t = _parse(ev.get(field))
    key_time = t.isoformat() if t else _FAR
    label = (ev.get("title") or ev.get("name") or "")
    return (key_time, str(label).lower(), str(ev.get("id") or ""))


def order_milestones(items):
    """New list of normalized milestones in chronological (date) order; undated
    last."""
    normed = [normalize_milestone(x) for x in (items or [])]
    return sorted(normed, key=lambda x: _date_key(x, "date"))


# ---------------------------------------------------------------- derived

def is_open(project):
    """True while the project still counts toward portfolio health (not done /
    cancelled)."""
    return normalize_project(project)["status"] not in _CLOSED_STATES


def is_overdue(project, now):
    """True when an OPEN project's due date is strictly before `now`'s date.
    Deterministic — `now` is passed in. Closed projects are never overdue; a
    project with no due date is never overdue."""
    p = normalize_project(project)
    if not is_open(p):
        return False
    due = _parse(p["due"])
    if not due:
        return False
    return due.date() < now.date()


def days_to_due(project, now):
    """Whole days from `now` until due (negative when past). None if no due."""
    p = normalize_project(project)
    due = _parse(p["due"])
    if not due:
        return None
    return (due.date() - now.date()).days


def milestone_progress(milestones):
    """{"total", "done", "missed", "pending", "percent"} over a project's
    milestones. percent = floor(done/total*100). Order-independent."""
    normed = [normalize_milestone(x) for x in (milestones or [])]
    total = len(normed)
    done = sum(1 for x in normed if x["status"] == MS_DONE)
    missed = sum(1 for x in normed if x["status"] == MS_MISSED)
    pending = total - done - missed
    percent = (done * 100 // total) if total else 0
    return {"total": total, "done": done, "missed": missed,
            "pending": pending, "percent": percent}


def classify_project(project, now, milestones=None, risks=None):
    """Put a project in exactly ONE portfolio-health bucket (deterministic):

        done      — status is done
        overdue   — open + due date already passed `now`
        at_risk   — open, not overdue, but has an OPEN HIGH risk OR a MISSED
                    milestone (a concrete warning signal)
        on_track  — open and none of the above

    A CANCELLED project is treated as closed → 'done' bucket is reserved for
    actually-finished work, so cancelled returns 'done' only if status==done;
    cancelled projects fall out of the open set and are reported as 'done'
    bucket? No — they are closed and NOT counted as healthy; see
    portfolio_summary which counts them separately as `closed`."""
    p = normalize_project(project)
    if p["status"] == ST_DONE:
        return HEALTH_DONE
    if p["status"] == ST_CANCELLED:
        return ST_CANCELLED
    if is_overdue(p, now):
        return HEALTH_OVERDUE
    open_high = any(
        normalize_risk(r)["status"] == RISK_OPEN and
        normalize_risk(r)["severity"] == RISK_HIGH
        for r in (risks or []))
    any_missed = any(
        normalize_milestone(m)["status"] == MS_MISSED
        for m in (milestones or []))
    if open_high or any_missed:
        return HEALTH_AT_RISK
    return HEALTH_ON_TRACK


# ---------------------------------------------------------------- portfolio

def portfolio_summary(projects, now, milestones=None, risks=None):
    """Deterministic portfolio roll-up the boss reads at a glance.

    `projects` is the list of project dicts. `milestones` / `risks` are the
    FLAT lists across all projects (each tagged with `project_id`); we index
    them per project so the classification is correct. `now` drives overdue.

    Returns counts per health bucket + `open` (still running) + `closed`
    (done + cancelled) + `overdue` + `at_risk` + `on_track` + `done` +
    `cancelled`, a weighted average `percent` across OPEN projects (0 when
    none), and the per-project classification list (ordered: overdue first,
    then at_risk, then on_track, then done/cancelled — each group by due date).
    Pure, order-independent for the counts."""
    ms_by = {}
    for m in (milestones or []):
        ms_by.setdefault(m.get("project_id"), []).append(m)
    rk_by = {}
    for r in (risks or []):
        rk_by.setdefault(r.get("project_id"), []).append(r)

    counts = {HEALTH_ON_TRACK: 0, HEALTH_AT_RISK: 0, HEALTH_OVERDUE: 0,
              HEALTH_DONE: 0, ST_CANCELLED: 0}
    items = []
    open_pcts = []
    for proj in (projects or []):
        p = normalize_project(proj)
        bucket = classify_project(p, now, ms_by.get(p["id"]), rk_by.get(p["id"]))
        counts[bucket] += 1
        if is_open(p):
            open_pcts.append(p["percent"])
        items.append({
            "id": p["id"],
            "name": p["name"],
            "owner": p["owner"],
            "status": p["status"],
            "percent": p["percent"],
            "due": p["due"],
            "health": bucket,
            "days_to_due": days_to_due(p, now),
            "overdue": bucket == HEALTH_OVERDUE,
        })

    open_count = counts[HEALTH_ON_TRACK] + counts[HEALTH_AT_RISK] + \
        counts[HEALTH_OVERDUE]
    closed_count = counts[HEALTH_DONE] + counts[ST_CANCELLED]
    avg_pct = (sum(open_pcts) // len(open_pcts)) if open_pcts else 0

    # stable display order: worst health first
    order = {HEALTH_OVERDUE: 0, HEALTH_AT_RISK: 1, HEALTH_ON_TRACK: 2,
             HEALTH_DONE: 3, ST_CANCELLED: 4}
    items_sorted = sorted(
        items,
        key=lambda it: (order.get(it["health"], 9),
                        _parse(it["due"]).isoformat() if _parse(it["due"])
                        else _FAR,
                        str(it["name"]).lower(), str(it["id"] or "")))

    return {
        "total": len(projects or []),
        "open": open_count,
        "closed": closed_count,
        "on_track": counts[HEALTH_ON_TRACK],
        "at_risk": counts[HEALTH_AT_RISK],
        "overdue": counts[HEALTH_OVERDUE],
        "done": counts[HEALTH_DONE],
        "cancelled": counts[ST_CANCELLED],
        "avg_percent": avg_pct,
        "projects": items_sorted,
        "mock": False,
    }


# ------------------------------------------------------- AI synthesis seam

def status_synthesis_seam(project=None, milestones=None, risks=None):
    """DOCUMENTED key-gated seam for AI STATUS SYNTHESIS — turning the manual
    fields into a crisp prose update for the boss.

    Honest MOCK: never calls a model, never fabricates a narrative. Returns the
    request SHAPE the integrator wires to `core.ai.generate` when an `anthropic`
    key is present (the `facts` block is exactly the deterministic data the real
    model would summarise — no interpretation here). Until then the UI shows a
    "connect an AI key" card and the boss reads the deterministic roll-up.
    """
    p = normalize_project(project) if project else {}
    return {
        "action": "status_synthesis",
        "facts": {
            "project": p,
            "milestones": [normalize_milestone(m) for m in (milestones or [])],
            "risks": [normalize_risk(r) for r in (risks or [])],
        },
        "text": "",             # honest: empty — no model, nothing invented
        "required": True,       # an AI key is required for a real narrative
        "ai_required": True,
        "mock": True,
        "marker": AI_MARKER_KEY,
    }
