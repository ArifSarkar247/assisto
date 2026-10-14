"""
pa_tasks.py — the deterministic engine behind PA SECRETARY MODE personal-task
oversight (issue #115, SPEC v2.1 §14, ADVANCED).

This is the PA's view of the OWNER's personal to-dos that the PA is overseeing:
a prioritized task list with status (todo / doing / done), due dates, an honest
OVERDUE flag computed from a passed-in `now`, add/edit/complete helpers, and a
progress summary. Delete is gated in the UI with a confirm; the engine just
removes.

Pure Python, deterministic, no Django, no DB, no network, **no clock** (every
time-dependent function takes `now` as an argument so overdue is honest and the
tests can pin it), **no AI**. Mirrors the conventions of the other pa_*/logic
modules. The view resolves tasks from the DB (see up_pa3_integration.md →
PATask) and passes plain dicts here.

ACCESS NOTE
-----------
Reading/managing these tasks is itself a delegated capability — the view must
first check `pa_delegate.can_access(stored_scopes, SCOPE_SEE_TASKS)` (and
SCOPE_MANAGE_TASKS for writes) against the DB-stored scopes before calling into
this module. This file assumes that gate already passed; it holds no secrets.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_tasks_tests_snippets as t; t.run_all()"
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
        # date-only fallback
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


# ------------------------------------------------------------- normalization

def normalize_task(task):
    """Coerce an arbitrary dict into a clean task record with safe defaults.
    Unknown status/priority fall back to the conservative baseline (todo /
    normal). Never raises; never invents a due date."""
    t = dict(task or {})
    status = t.get("status")
    if status not in STATUSES:
        status = STATUS_TODO
    priority = t.get("priority")
    if priority not in PRIORITIES:
        priority = PRIORITY_NORMAL
    title = " ".join(str(t.get("title") or "").split()).strip()
    return {
        "id": t.get("id"),
        "title": title,
        "status": status,
        "priority": priority,
        "due": (str(t.get("due")).strip() if t.get("due") else ""),
        "note": str(t.get("note") or ""),
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
    if t.get("due"):
        if _parse(t.get("due")) is None:
            problems.append("bad_due")
    return problems


# ------------------------------------------------------------------- overdue

def is_overdue(task, now):
    """Honest overdue: True ONLY when the task is NOT done, has a real due date,
    and that due date is strictly before `now`. A done task is never overdue; a
    task with no/garbage due date is never overdue. `now` is a datetime the
    caller supplies (no clock here)."""
    t = normalize_task(task)
    if t["status"] == STATUS_DONE:
        return False
    due = _parse(t["due"])
    if due is None:
        return False
    return due < now


# ------------------------------------------------------------------- ordering

def _sort_key(task, now):
    """Deterministic ordering key. Within the active list: overdue first, then
    by priority weight (urgent→low), then by soonest due date, then title. Done
    tasks sort last. Stable + total."""
    t = normalize_task(task)
    done = 1 if t["status"] == STATUS_DONE else 0
    overdue = 0 if is_overdue(t, now) else 1  # overdue (0) sorts before (1)
    weight = -_PRIORITY_WEIGHT.get(t["priority"], 1)  # higher weight → earlier
    due = _parse(t["due"])
    due_key = (due.isoformat() if due else _NO_DUE)
    return (done, overdue, weight, due_key, t["title"].lower())


def order_tasks(tasks, now):
    """Return a NEW list of normalized tasks in display order. Deterministic;
    never mutates the input. `now` drives the overdue-first grouping only."""
    normed = [normalize_task(t) for t in (tasks or [])]
    return sorted(normed, key=lambda t: _sort_key(t, now))


# -------------------------------------------------------------- mutations

def add_task(tasks, task):
    """Append a normalized task (no reordering here — call order_tasks to
    display). Returns a new list; never mutates the input."""
    return [normalize_task(t) for t in (tasks or [])] + [normalize_task(task)]


def edit_task(tasks, task_id, changes):
    """Return a new list with the matching task's fields updated from `changes`
    (only title/status/priority/due/note are applied). Unknown id → unchanged."""
    out = []
    allowed = ("title", "status", "priority", "due", "note")
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


def complete_task(tasks, task_id):
    """Mark the matching task done. Idempotent; unknown id → unchanged."""
    return edit_task(tasks, task_id, {"status": STATUS_DONE})


def delete_task(tasks, task_id):
    """Remove the matching task. Returns a new list; never mutates the input.
    (The UI raises a confirm gate before calling this.)"""
    return [normalize_task(t) for t in (tasks or [])
            if normalize_task(t)["id"] != task_id]


# -------------------------------------------------------------- progress

def progress_summary(tasks, now):
    """Deterministic rollup for the oversight header:

        {
          "total", "todo", "doing", "done", "overdue",
          "percent_done"  # 0..100 integer; 0 when there are no tasks
        }

    percent_done is floor(done/total*100). Order-independent; honest on empty."""
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
