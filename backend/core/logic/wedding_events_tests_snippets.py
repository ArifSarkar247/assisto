"""
wedding_events_tests_snippets.py — plain-assert tests for WEDDING & EVENTS
(#189, §20). Pure stdlib. `python wedding_events_tests_snippets.py` or import
and call run_all(). Deterministic; integer-poisha budget math reconciles
exactly. Holds no money.
"""

try:  # Django harness
    from core.logic import wedding_events as W
except ImportError:  # standalone
    import wedding_events as W  # noqa: E402


# --------------------------------------------------------------- poisha

def test_to_poisha_exact():
    assert W.to_poisha("1200.50") == 120050
    assert W.to_poisha(500) == 500          # already poisha
    assert W.to_poisha("1,00,000") == 10000000
    assert W.to_poisha(True) == 0
    assert W.to_poisha("junk") == 0


def test_fmt_poisha_sign_and_grouping():
    assert W.fmt_poisha(12345678900) == "৳12,34,56,789.00"
    assert W.fmt_poisha(-5000) == "-৳50.00"
    assert W.fmt_poisha(0) == "৳0.00"


# --------------------------------------------------------------- guests

def test_guest_summary_confirmed_vs_expected_heads():
    guests = [
        {"name": "A", "rsvp": "yes", "plus_ones": 1},   # 2 heads confirmed
        {"name": "B", "rsvp": "maybe", "plus_ones": 2},  # 3 heads expected only
        {"name": "C", "rsvp": "no"},
        {"name": "D"},                                   # invited (default)
    ]
    s = W.guest_summary(guests)
    assert s["counts"] == {"yes": 1, "no": 1, "maybe": 1, "invited": 1}
    assert s["confirmed_heads"] == 2
    assert s["expected_heads"] == 5         # 2 (yes) + 3 (maybe)
    assert s["pending"] == 2                # maybe + invited


def test_guest_summary_empty():
    s = W.guest_summary([])
    assert s["empty"] is True and s["confirmed_heads"] == 0


def test_validate_guest():
    guests = [{"name": "Karim"}]
    assert "name_required" in W.validate_guest("  ", guests)
    assert "duplicate_name" in W.validate_guest("karim", guests)
    assert W.validate_guest("Rahim", guests) == []


# --------------------------------------------------------------- budget

def test_budget_totals_and_variance():
    rows = [
        {"category": "venue", "estimated": "100000", "actual": "120000"},
        {"category": "food", "estimated": "200000", "actual": "180000"},
    ]
    b = W.budget_summary(rows, "en")
    assert b["total_estimated"] == 30000000   # 3,00,000 taka in poisha
    assert b["total_actual"] == 30000000
    assert b["total_variance"] == 0
    # venue over, food under
    venue = next(c for c in b["categories"] if c["category"] == "venue")
    assert venue["over"] is True and venue["variance"] == 2000000


def test_budget_over_warning_honest():
    rows = [{"category": "food", "estimated": "100000", "actual": "150000"}]
    b = W.budget_summary(rows, "en")
    assert b["over_budget"] is True
    assert b["over_amount"] == 5000000        # 50,000 taka over
    assert b["over_amount_display"] == "৳50,000.00"


def test_budget_within_no_warning():
    rows = [{"category": "decor", "estimated": "50000", "actual": "40000"}]
    b = W.budget_summary(rows, "en")
    assert b["over_budget"] is False and b["over_amount"] == 0


def test_budget_same_category_aggregates():
    rows = [{"category": "food", "estimated": "10000", "actual": "0"},
            {"category": "food", "estimated": "20000", "actual": "25000"}]
    b = W.budget_summary(rows, "en")
    assert len(b["categories"]) == 1
    assert b["categories"][0]["estimated"] == 3000000
    assert b["categories"][0]["actual"] == 2500000


def test_budget_freetext_category_echoed():
    b = W.budget_summary(
        [{"category": "Mehndi night", "estimated": "5000", "actual": "5000"}],
        "en")
    assert b["categories"][0]["label"] == "Mehndi night"


def test_budget_empty_honest():
    b = W.budget_summary([], "en")
    assert b["empty"] is True and b["over_budget"] is False
    assert "holds no money" in b["note"]["en"]


def test_budget_deterministic():
    rows = [{"category": "venue", "estimated": "999.99", "actual": "1000.01"}]
    assert W.budget_summary(rows, "en") == W.budget_summary(rows, "en")


# --------------------------------------------------------------- tasks

def test_task_overdue_honest():
    s = W.task_status({"title": "Book venue", "due_date": "2026-01-01"},
                      "2026-01-10")
    assert s["state"] == "overdue" and s["days"] == -9


def test_task_done_never_overdue():
    s = W.task_status(
        {"title": "x", "due_date": "2026-01-01", "done": True}, "2026-01-10")
    assert s["state"] == "done"


def test_task_no_due_never_overdue():
    assert W.task_status({"title": "x"}, "2026-01-10")["state"] == "no_due"


def test_task_board_partition():
    tasks = [
        {"id": 1, "title": "A", "due_date": "2026-01-01"},   # overdue
        {"id": 2, "title": "B", "due_date": "2026-01-10"},   # today
        {"id": 3, "title": "C", "due_date": "2026-02-01"},   # upcoming
        {"id": 4, "title": "D", "done": True},               # done
    ]
    b = W.task_board(tasks, "2026-01-10")
    assert b["counts"]["overdue"] == 1
    assert b["counts"]["due_today"] == 1
    assert b["counts"]["open"] == 3
    assert b["all"][0]["title"] == "A"       # overdue first


# --------------------------------------------------------------- countdown

def test_countdown_future_today_past():
    f = W.countdown("2026-12-25", "2026-12-01")
    assert f["state"] == "future" and f["days"] == 24
    t = W.countdown("2026-12-25", "2026-12-25")
    assert t["state"] == "today" and t["days"] == 0
    p = W.countdown("2026-12-25", "2026-12-28")
    assert p["state"] == "past" and p["days_ago"] == 3


def test_countdown_no_date_honest():
    c = W.countdown(None, "2026-12-01")
    assert c["state"] == "no_date" and c["days"] is None


def test_countdown_uses_passed_now_not_clock():
    a = W.countdown("2030-01-01", "2029-12-31")
    assert a["days"] == 1                     # reproducible regardless of today


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"wedding_events: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
