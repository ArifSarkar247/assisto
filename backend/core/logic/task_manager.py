"""
task_manager.py — the deterministic engine behind the TASK MANAGER
(feature #21, SPEC v2.1, ADVANCED).

A lightweight projects + board module: the user owns PROJECTS, each project
owns TASKS. Every task has a title, description, assignee (a free-text name or
a Circle member), a due date, a priority, a status (todo / doing / done) and a
progress percentage (0..100). The board is three columns keyed by status; the
list view is one ordered list; both are driven by the pure helpers below.

This module is PURE: deterministic, no Django, no DB, no network, **no clock**
(every time-dependent function takes `now` as an argument so the OVERDUE flag
is honest and the tests can pin it), **no AI**. The view resolves the rows from
the two owner-scoped REST collections (see up_taskmgr_integration.md) and passes
plain dicts in and out. Mirrors app/lib/screens/task_manager_screen.dart so the
app and server agree on bucketing, ordering, overdue and progress.

Run self-tests (no DB):
    python3 -c "import core.logic.task_manager_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
STATUS_TODO = "todo"
STATUS_DOING = "doing"
STATUS_DONE = "done"
STATUSES = (STATUS_TODO, STATUS_DOING, STATUS_DONE)
# The board columns, in display order (left → right).
BOARD_COLUMNS = (STATUS_TODO, STATUS_DOING, STATUS_DONE)

PRIORITY_LOW = "low"
PRIORITY_NORMAL = "normal"
PRIORITY_HIGH = "high"
PRIORITY_URGENT = "urgent"
PRIORITIES = (PRIORITY_LOW, PRIORITY_NORMAL, PRIORITY_HIGH, PRIORITY_URGENT)

# Higher weight = sorts earlier. Urgent first, then high, normal, low.
_PRIORITY_WEIGHT = {
    PRIORITY_URGENT: 3,
    PRIORITY_HIGH: 2,
    PRIORITY_NORMAL: 1,
    PRIORITY_LOW: 0,
}

# A far-future sentinel so tasks with no due date sort AFTER dated ones (within
# the same priority band) rather than jumping to the top.
_NO_DUE = "9999-12-31T23:59:59"

# When a task becomes done its progress is pinned to 100; a fresh todo is 0.


def is_status(s):
    return s in STATUSES


def is_priority(p):
    return p in PRIORITIES


# ------------------------------------------------------------------ parsing

def _parse(dt):
    """Lenient ISO-8601 → datetime, or None. Accepts a trailing 'Z'. Never
    raises — a bad/empty value simply has no due date."""
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


def _clamp_percent(v):
    """Coerce any value to an int in 0..100. Garbage → 0."""
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return 0
    return 0 if n < 0 else (100 if n > 100 else n)


# ------------------------------------------------------------- normalization

def normalize_project(project):
    """Coerce an arbitrary dict into a clean project record. Never raises; the
    name is whitespace-collapsed (but preserved as typed otherwise)."""
    p = dict(project or {})
    name = " ".join(str(p.get("name") or "").split()).strip()
    return {
        "id": p.get("id"),
        "name": name,
        "description": str(p.get("description") or ""),
        "color": str(p.get("color") or ""),
    }


def validate_project(project):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    p = dict(project or {})
    problems = []
    if not str(p.get("name") or "").strip():
        problems.append("name_required")
    return problems


def normalize_task(task):
    """Coerce an arbitrary dict into a clean task record with safe defaults.

    Unknown status/priority fall back to the conservative baseline (todo /
    normal). `progress` is clamped to 0..100. A DONE task is pinned to 100; a
    TODO task with no recorded progress reads 0. Never raises; never invents a
    due date. `project_id` ties the task to its project."""
    t = dict(task or {})
    status = t.get("status")
    if status not in STATUSES:
        status = STATUS_TODO
    priority = t.get("priority")
    if priority not in PRIORITIES:
        priority = PRIORITY_NORMAL
    title = " ".join(str(t.get("title") or "").split()).strip()
    progress = _clamp_percent(t.get("progress"))
    # Keep progress honest against status: done ⇒ 100.
    if status == STATUS_DONE:
        progress = 100
    return {
        "id": t.get("id"),
        "project_id": t.get("project_id"),
        "title": title,
        "description": str(t.get("description") or ""),
        "assignee": " ".join(str(t.get("assignee") or "").split()).strip(),
        "status": status,
        "priority": priority,
        "due": (str(t.get("due")).strip() if t.get("due") else ""),
        "progress": progress,
    }


def validate_task(task):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    t = dict(task or {})
    problems = []
    if not str(t.get("title") or "").strip():
        problems.append("title_required")
    if t.get("status") is not None and t.get("status") not in STATUSES:
        problems.append("bad_status")
    if t.get("priority") is not None and t.get("priority") not in PRIORITIES:
        problems.append("bad_priority")
    if t.get("due") and _parse(t.get("due")) is None:
        problems.append("bad_due")
    if t.get("progress") is not None:
        try:
            n = int(round(float(t.get("progress"))))
            if n < 0 or n > 100:
                problems.append("bad_progress")
        except (TypeError, ValueError):
            problems.append("bad_progress")
    return problems


# ------------------------------------------------------------------- overdue

def is_overdue(task, now):
    """Honest overdue: True ONLY when the task is NOT done, has a real due date,
    and that due date is strictly before `now`. A done task is never overdue; a
    task with no/garbage due date is never overdue. `now` is supplied by the
    caller (no clock here)."""
    t = normalize_task(task)
    if t["status"] == STATUS_DONE:
        return False
    due = _parse(t["due"])
    if due is None:
        return False
    # Compare robustly: if one side is tz-aware and the other naive, align the
    # due date to `now`'s tzinfo so a trailing 'Z' (stripped to naive) still
    # compares honestly against an aware `now`. Never raises.
    if (due.tzinfo is None) != (now.tzinfo is None):
        if now.tzinfo is not None:
            due = due.replace(tzinfo=now.tzinfo)
        else:
            due = due.replace(tzinfo=None)
    return due < now


# ------------------------------------------------------------------- ordering

def _sort_key(task, now):
    """Deterministic ordering key. Within the active list: overdue first, then
    by priority weight (urgent→low), then by soonest due date, then title. Done
    tasks sort last. Stable + total."""
    t = normalize_task(task)
    done = 1 if t["status"] == STATUS_DONE else 0
    overdue = 0 if is_overdue(t, now) else 1  # overdue (0) sorts first
    weight = -_PRIORITY_WEIGHT.get(t["priority"], 1)
    due = _parse(t["due"])
    due_key = (due.isoformat() if due else _NO_DUE)
    return (done, overdue, weight, due_key, t["title"].lower())


def order_tasks(tasks, now):
    """Return a NEW list of normalized tasks in display order (the LIST view).
    Deterministic; never mutates the input. `now` drives overdue-first only."""
    normed = [normalize_task(t) for t in (tasks or [])]
    return sorted(normed, key=lambda t: _sort_key(t, now))


# ------------------------------------------------------------------- filtering

def _assignee_key(name):
    return " ".join(str(name or "").split()).strip().lower()


def filter_tasks(tasks, *, status=None, assignee=None):
    """Return a new normalized list keeping only tasks that match the filters.
    `status` (one of STATUSES) and `assignee` (case/space-insensitive exact
    match) are each optional; None/'' means 'no filter on that field'. An
    assignee of '' explicitly matches UNASSIGNED tasks is NOT supported here —
    pass None to skip; the UI offers 'unassigned' as a dedicated filter below."""
    want_status = status if status in STATUSES else None
    want_asg = _assignee_key(assignee) if assignee else None
    out = []
    for t in (tasks or []):
        nt = normalize_task(t)
        if want_status is not None and nt["status"] != want_status:
            continue
        if want_asg is not None and _assignee_key(nt["assignee"]) != want_asg:
            continue
        out.append(nt)
    return out


def filter_unassigned(tasks):
    """Only the tasks with no assignee (a dedicated filter the UI exposes)."""
    return [normalize_task(t) for t in (tasks or [])
            if not normalize_task(t)["assignee"]]


def assignees(tasks):
    """Sorted, de-duplicated list of distinct non-empty assignee display names
    across the tasks — powers the assignee filter dropdown. Case preserved from
    the first occurrence; sort is case-insensitive + stable."""
    seen = {}
    for t in (tasks or []):
        name = normalize_task(t)["assignee"]
        if name and name.lower() not in seen:
            seen[name.lower()] = name
    return [seen[k] for k in sorted(seen.keys())]


# ------------------------------------------------------------------- board

def board(tasks, now):
    """Bucket tasks into the three board columns, each ORDERED by the same key
    (overdue → priority → due → title). Returns:

        {"todo": [...], "doing": [...], "done": [...]}

    Deterministic; never mutates the input. The caller renders columns in
    BOARD_COLUMNS order. 'done' tasks naturally fall to the done column; the
    done-last tiebreak in the sort only matters inside a mixed list, so each
    column is internally ordered by priority/due/title."""
    cols = {c: [] for c in BOARD_COLUMNS}
    for t in (tasks or []):
        nt = normalize_task(t)
        cols.setdefault(nt["status"], cols[STATUS_TODO]).append(nt)
    for c in cols:
        cols[c] = sorted(cols[c], key=lambda t: _sort_key(t, now))
    return cols


def move_task(tasks, task_id, to_status):
    """Move a task to another column (status change). Moving to DONE pins
    progress to 100; moving OUT of done and leaving it at 100 drops it back to
    0 so the board doesn't read a done-looking bar on an active task. Unknown
    id or bad status → unchanged. Returns a new list; never mutates input."""
    if to_status not in STATUSES:
        return [normalize_task(t) for t in (tasks or [])]
    out = []
    for t in (tasks or []):
        nt = normalize_task(t)
        if nt["id"] == task_id:
            was_done = nt["status"] == STATUS_DONE
            nt["status"] = to_status
            if to_status == STATUS_DONE:
                nt["progress"] = 100
            elif was_done and nt["progress"] == 100:
                nt["progress"] = 0
            nt = normalize_task(nt)
        out.append(nt)
    return out


# -------------------------------------------------------------- mutations

def add_task(tasks, task):
    """Append a normalized task (no reordering here — call order_tasks/board to
    display). Returns a new list; never mutates the input."""
    return [normalize_task(t) for t in (tasks or [])] + [normalize_task(task)]


def edit_task(tasks, task_id, changes):
    """Return a new list with the matching task's editable fields updated from
    `changes`. Unknown id → unchanged. Done-vs-progress stays honest via
    normalize_task."""
    allowed = ("title", "description", "assignee", "status", "priority",
               "due", "progress", "project_id")
    out = []
    for t in (tasks or []):
        nt = normalize_task(t)
        if nt["id"] == task_id:
            merged = dict(nt)
            for k in allowed:
                if k in (changes or {}):
                    merged[k] = changes[k]
            nt = normalize_task(merged)
        out.append(nt)
    return out


def set_progress(tasks, task_id, percent):
    """Set a task's progress %. 100 ⇒ status done; <100 on a done task reopens
    it to doing (honest: a done task is 100). Unknown id → unchanged."""
    out = []
    pct = _clamp_percent(percent)
    for t in (tasks or []):
        nt = normalize_task(t)
        if nt["id"] == task_id:
            if pct >= 100:
                nt["status"] = STATUS_DONE
            elif nt["status"] == STATUS_DONE:
                nt["status"] = STATUS_DOING
            nt["progress"] = pct
            nt = normalize_task(nt)
        out.append(nt)
    return out


def delete_task(tasks, task_id):
    """Remove the matching task. Returns a new list; never mutates the input.
    (The UI raises a confirm gate before calling this.)"""
    return [normalize_task(t) for t in (tasks or [])
            if normalize_task(t)["id"] != task_id]


# -------------------------------------------------------------- progress

def progress_summary(tasks, now):
    """Deterministic rollup for a project header:

        {
          "total", "todo", "doing", "done", "overdue",
          "percent_done"   # floor(done/total*100); 0 when empty
        }

    Order-independent; honest on empty. `percent_done` counts DONE tasks (not
    the per-task progress bars) so it matches the visible done column."""
    todo = doing = done = overdue = 0
    normed = [normalize_task(t) for t in (tasks or [])]
    for t in normed:
        if t["status"] == STATUS_TODO:
            todo += 1
        elif t["status"] == STATUS_DOING:
            doing += 1
        elif t["status"] == STATUS_DONE:
            done += 1
        if is_overdue(t, now):
            overdue += 1
    total = len(normed)
    percent = (done * 100 // total) if total else 0
    return {"total": total, "todo": todo, "doing": doing, "done": done,
            "overdue": overdue, "percent_done": percent}


def project_rollups(projects, tasks, now):
    """Per-project summary for the projects list. Returns a NEW list of:

        {**normalized_project, "summary": progress_summary(...)}

    Tasks are grouped by project_id; a project with no tasks gets an honest
    all-zero summary. Projects keep their given order (deterministic)."""
    by_project = {}
    for t in (tasks or []):
        nt = normalize_task(t)
        by_project.setdefault(nt["project_id"], []).append(nt)
    out = []
    for p in (projects or []):
        np = normalize_project(p)
        out.append({**np,
                    "summary": progress_summary(by_project.get(np["id"], []), now)})
    return out
