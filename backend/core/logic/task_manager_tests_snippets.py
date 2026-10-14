"""
task_manager_tests_snippets.py — pure self-tests for task_manager.
No Django, no DB, no network, no clock (NOW is pinned).  Run:
    python3 -c "import core.logic.task_manager_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timezone

from core.logic import task_manager as T

NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)
PAST = "2026-10-01T09:00:00Z"
FUTURE = "2026-12-01T09:00:00Z"


def _mk(id, **kw):
    kw.setdefault("title", f"Task {id}")
    kw["id"] = id
    return kw


# --------------------------------------------------------------- normalize

def test_normalize_task_defaults():
    t = T.normalize_task({"title": "  do   the   thing  "})
    assert t["title"] == "do the thing", "title whitespace-collapsed"
    assert t["status"] == T.STATUS_TODO, "unknown/absent status → todo"
    assert t["priority"] == T.PRIORITY_NORMAL, "absent priority → normal"
    assert t["progress"] == 0, "absent progress → 0"
    assert t["due"] == "" and t["assignee"] == "", "no due / no assignee"


def test_normalize_bad_values_fall_back():
    t = T.normalize_task({"title": "x", "status": "banana",
                          "priority": "meh", "progress": 999})
    assert t["status"] == T.STATUS_TODO, "bad status → todo"
    assert t["priority"] == T.PRIORITY_NORMAL, "bad priority → normal"
    assert t["progress"] == 100, "progress clamped to 100"


def test_normalize_done_pins_progress():
    t = T.normalize_task({"title": "x", "status": "done", "progress": 40})
    assert t["progress"] == 100, "done task reads 100% regardless of stored value"


def test_normalize_negative_progress_clamps():
    assert T.normalize_task({"title": "x", "progress": -5})["progress"] == 0


def test_normalize_project():
    p = T.normalize_project({"name": "  My   Plan ", "description": "d"})
    assert p["name"] == "My Plan" and p["description"] == "d"


# --------------------------------------------------------------- validate

def test_validate_task():
    assert T.validate_task({"title": "ok"}) == [], "valid task"
    assert "title_required" in T.validate_task({"title": "   "})
    assert "bad_status" in T.validate_task({"title": "x", "status": "nope"})
    assert "bad_priority" in T.validate_task({"title": "x", "priority": "nope"})
    assert "bad_due" in T.validate_task({"title": "x", "due": "not-a-date"})
    assert "bad_progress" in T.validate_task({"title": "x", "progress": 150})
    assert "bad_progress" in T.validate_task({"title": "x", "progress": "abc"})


def test_validate_project():
    assert T.validate_project({"name": "P"}) == []
    assert "name_required" in T.validate_project({"name": ""})


# --------------------------------------------------------------- overdue

def test_overdue_honest():
    assert T.is_overdue(_mk(1, due=PAST), NOW) is True, "past + not done → overdue"
    assert T.is_overdue(_mk(2, due=FUTURE), NOW) is False, "future → not overdue"
    assert T.is_overdue(_mk(3, due=PAST, status="done"), NOW) is False, \
        "done is never overdue"
    assert T.is_overdue(_mk(4), NOW) is False, "no due date → not overdue"
    assert T.is_overdue(_mk(5, due="garbage"), NOW) is False, "bad due → not overdue"


def test_overdue_strict_before():
    at_now = "2026-10-14T12:00:00Z"
    assert T.is_overdue(_mk(1, due=at_now), NOW) is False, "exactly now is not overdue"


# --------------------------------------------------------------- ordering

def test_order_overdue_then_priority():
    tasks = [
        _mk(1, priority="low", due=FUTURE),
        _mk(2, priority="urgent", due=FUTURE),
        _mk(3, priority="normal", due=PAST),   # overdue
        _mk(4, status="done", priority="urgent"),
    ]
    out = T.order_tasks(tasks, NOW)
    ids = [t["id"] for t in out]
    assert ids[0] == 3, "overdue sorts first"
    assert ids[-1] == 4, "done sorts last"
    assert ids.index(2) < ids.index(1), "urgent before low among non-overdue"


def test_order_does_not_mutate():
    src = [_mk(1), _mk(2)]
    T.order_tasks(src, NOW)
    assert [t["id"] for t in src] == [1, 2], "input list untouched"


# --------------------------------------------------------------- filter

def test_filter_status_and_assignee():
    tasks = [
        _mk(1, status="todo", assignee="Karim"),
        _mk(2, status="doing", assignee="karim"),   # case-insensitive match
        _mk(3, status="done", assignee="Rahim"),
    ]
    assert [t["id"] for t in T.filter_tasks(tasks, status="doing")] == [2]
    got = [t["id"] for t in T.filter_tasks(tasks, assignee="KARIM")]
    assert got == [1, 2], "assignee match is case/space-insensitive"
    assert len(T.filter_tasks(tasks, status="nope")) == 3, \
        "bad status filter is ignored (no filter)"


def test_filter_unassigned_and_assignees_list():
    tasks = [_mk(1, assignee="Karim"), _mk(2), _mk(3, assignee="Ayesha")]
    assert [t["id"] for t in T.filter_unassigned(tasks)] == [2]
    assert T.assignees(tasks) == ["Ayesha", "Karim"], "distinct, sorted ci"


# --------------------------------------------------------------- board

def test_board_buckets_and_orders():
    tasks = [
        _mk(1, status="todo", priority="low"),
        _mk(2, status="todo", priority="urgent"),
        _mk(3, status="doing"),
        _mk(4, status="done"),
    ]
    b = T.board(tasks, NOW)
    assert set(b.keys()) == set(T.BOARD_COLUMNS)
    assert [t["id"] for t in b["todo"]] == [2, 1], "urgent before low in todo col"
    assert [t["id"] for t in b["doing"]] == [3]
    assert [t["id"] for t in b["done"]] == [4]


def test_move_task_to_done_and_back():
    tasks = [_mk(1, status="todo", progress=20)]
    done = T.move_task(tasks, 1, "done")
    assert done[0]["status"] == "done" and done[0]["progress"] == 100
    back = T.move_task(done, 1, "doing")
    assert back[0]["status"] == "doing" and back[0]["progress"] == 0, \
        "leaving done at 100% resets the bar to 0 so it isn't misleading"


def test_move_bad_status_noop():
    tasks = [_mk(1, status="todo")]
    assert T.move_task(tasks, 1, "banana")[0]["status"] == "todo"
    assert T.move_task(tasks, 999, "done")[0]["status"] == "todo", "unknown id noop"


# --------------------------------------------------------------- mutations

def test_add_edit_delete():
    tasks = T.add_task([], _mk(1, title="first"))
    assert len(tasks) == 1
    tasks = T.add_task(tasks, _mk(2, title="second"))
    tasks = T.edit_task(tasks, 1, {"title": "renamed", "priority": "high"})
    t1 = [t for t in tasks if t["id"] == 1][0]
    assert t1["title"] == "renamed" and t1["priority"] == "high"
    tasks = T.delete_task(tasks, 2)
    assert [t["id"] for t in tasks] == [1], "delete removes only the target"


def test_set_progress_crosses_done_boundary():
    tasks = [_mk(1, status="doing", progress=30)]
    tasks = T.set_progress(tasks, 1, 100)
    assert tasks[0]["status"] == "done", "100% auto-completes"
    tasks = T.set_progress(tasks, 1, 50)
    assert tasks[0]["status"] == "doing" and tasks[0]["progress"] == 50, \
        "dropping below 100 reopens a done task"


# --------------------------------------------------------------- summary

def test_progress_summary():
    tasks = [
        _mk(1, status="todo", due=PAST),    # overdue
        _mk(2, status="doing"),
        _mk(3, status="done"),
        _mk(4, status="done"),
    ]
    s = T.progress_summary(tasks, NOW)
    assert s["total"] == 4 and s["todo"] == 1 and s["doing"] == 1
    assert s["done"] == 2 and s["overdue"] == 1
    assert s["percent_done"] == 50, "floor(2/4*100)"


def test_progress_summary_empty_honest():
    s = T.progress_summary([], NOW)
    assert s["total"] == 0 and s["percent_done"] == 0 and s["overdue"] == 0


def test_project_rollups():
    projects = [{"id": 10, "name": "A"}, {"id": 20, "name": "B"}]
    tasks = [
        _mk(1, project_id=10, status="done"),
        _mk(2, project_id=10, status="todo"),
        _mk(3, project_id=20, status="done"),
    ]
    out = T.project_rollups(projects, tasks, NOW)
    assert out[0]["name"] == "A" and out[0]["summary"]["percent_done"] == 50
    assert out[1]["name"] == "B" and out[1]["summary"]["percent_done"] == 100
    # a project with no tasks reads an honest zero
    empty = T.project_rollups([{"id": 30, "name": "C"}], [], NOW)
    assert empty[0]["summary"]["total"] == 0


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"task_manager: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
