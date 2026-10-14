"""
pa_tasks_tests_snippets.py — plain-assert tests for PA personal-task oversight
(#115, §14). Pure stdlib. `python pa_tasks_tests_snippets.py` or import and call
run_all(). Deterministic (overdue from a passed-in `now`) → hand-verified.
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_tasks as T
except ImportError:  # standalone
    import pa_tasks as T  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize

def test_normalize_defaults():
    t = T.normalize_task({"title": "  Call   bank "})
    assert t["title"] == "Call bank"
    assert t["status"] == T.STATUS_TODO
    assert t["priority"] == T.PRIORITY_NORMAL
    assert t["due"] == ""


def test_normalize_bad_enums_fall_back():
    t = T.normalize_task({"title": "x", "status": "weird", "priority": "mega"})
    assert t["status"] == T.STATUS_TODO
    assert t["priority"] == T.PRIORITY_NORMAL


# --------------------------------------------------------------- validate

def test_validate_ok_and_problems():
    assert T.validate_task({"title": "Pay rent", "due": "2026-10-20"}) == []
    assert "title_required" in T.validate_task({"title": "   "})
    assert "bad_status" in T.validate_task({"title": "x", "status": "nope"})
    assert "bad_priority" in T.validate_task(
        {"title": "x", "priority": "nope"})
    assert "bad_due" in T.validate_task({"title": "x", "due": "not-a-date"})


# --------------------------------------------------------------- overdue

def test_overdue_honest():
    past = {"title": "a", "due": "2026-10-10T09:00:00"}
    future = {"title": "b", "due": "2026-10-20T09:00:00"}
    assert T.is_overdue(past, NOW) is True
    assert T.is_overdue(future, NOW) is False


def test_done_is_never_overdue():
    past_done = {"title": "a", "due": "2026-10-10", "status": T.STATUS_DONE}
    assert T.is_overdue(past_done, NOW) is False


def test_no_or_bad_due_is_never_overdue():
    assert T.is_overdue({"title": "a"}, NOW) is False
    assert T.is_overdue({"title": "a", "due": "garbage"}, NOW) is False


def test_accepts_trailing_z():
    assert T.is_overdue({"title": "a", "due": "2026-10-10T09:00:00Z"},
                        NOW) is True


# --------------------------------------------------------------- ordering

def test_order_overdue_first_then_priority():
    tasks = [
        {"id": 1, "title": "low future", "priority": "low",
         "due": "2026-12-01"},
        {"id": 2, "title": "urgent future", "priority": "urgent",
         "due": "2026-12-01"},
        {"id": 3, "title": "overdue normal", "priority": "normal",
         "due": "2026-10-01"},
    ]
    out = T.order_tasks(tasks, NOW)
    # overdue sorts to the very top regardless of priority band
    assert out[0]["id"] == 3
    # among non-overdue, urgent beats low
    assert out[1]["id"] == 2
    assert out[2]["id"] == 1


def test_done_sorts_last():
    tasks = [
        {"id": 1, "title": "done urgent", "priority": "urgent",
         "status": "done"},
        {"id": 2, "title": "todo low", "priority": "low"},
    ]
    out = T.order_tasks(tasks, NOW)
    assert out[0]["id"] == 2
    assert out[1]["id"] == 1


def test_no_due_sorts_after_dated_same_priority():
    tasks = [
        {"id": 1, "title": "dated", "priority": "normal", "due": "2026-12-01"},
        {"id": 2, "title": "undated", "priority": "normal"},
    ]
    out = T.order_tasks(tasks, NOW)
    assert out[0]["id"] == 1
    assert out[1]["id"] == 2


def test_order_is_pure():
    tasks = [{"id": 1, "title": "a"}]
    T.order_tasks(tasks, NOW)
    assert tasks == [{"id": 1, "title": "a"}]  # untouched


# --------------------------------------------------------------- mutations

def test_add_task():
    out = T.add_task([], {"title": "New"})
    assert len(out) == 1 and out[0]["title"] == "New"


def test_edit_task():
    tasks = [{"id": 5, "title": "old", "status": "todo"}]
    out = T.edit_task(tasks, 5, {"title": "new", "status": "doing"})
    assert out[0]["title"] == "new" and out[0]["status"] == "doing"
    # unknown id → unchanged
    out2 = T.edit_task(tasks, 999, {"title": "nope"})
    assert out2[0]["title"] == "old"


def test_complete_task_idempotent():
    tasks = [{"id": 1, "title": "x", "status": "todo"}]
    once = T.complete_task(tasks, 1)
    twice = T.complete_task(once, 1)
    assert once[0]["status"] == T.STATUS_DONE
    assert twice[0]["status"] == T.STATUS_DONE


def test_delete_task_is_pure():
    tasks = [{"id": 1, "title": "a"}, {"id": 2, "title": "b"}]
    out = T.delete_task(tasks, 1)
    assert [x["id"] for x in out] == [2]
    assert len(tasks) == 2  # input untouched


# --------------------------------------------------------------- progress

def test_progress_summary():
    tasks = [
        {"id": 1, "title": "a", "status": "done"},
        {"id": 2, "title": "b", "status": "doing"},
        {"id": 3, "title": "c", "status": "todo", "due": "2026-10-01"},  # over
        {"id": 4, "title": "d", "status": "todo"},
    ]
    s = T.progress_summary(tasks, NOW)
    assert s["total"] == 4
    assert s["done"] == 1
    assert s["doing"] == 1
    assert s["todo"] == 2
    assert s["overdue"] == 1
    assert s["percent_done"] == 25  # floor(1/4*100)


def test_progress_summary_empty():
    s = T.progress_summary([], NOW)
    assert s["total"] == 0 and s["percent_done"] == 0


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_tasks: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
