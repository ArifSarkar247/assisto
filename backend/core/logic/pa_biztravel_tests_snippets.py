"""
pa_biztravel_tests_snippets.py — plain-assert tests for PA CORPORATE business
travel & events (#119, §14). Pure stdlib. `python pa_biztravel_tests_snippets.py`
or import and call run_all(). Deterministic (countdown from a passed-in `now`).
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_biztravel as T
except ImportError:  # standalone
    import pa_biztravel as T  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_event_defaults():
    e = T.normalize_event({"name": "  Annual   Sales Meet "})
    assert e["name"] == "Annual Sales Meet"
    assert e["date"] == "" and e["end"] == ""


def test_normalize_attendee_bad_mode_and_status_fall_back():
    a = T.normalize_attendee(
        {"name": "Mr X", "mode": "rocket", "status": "??", "cost": "abc"})
    assert a["mode"] == T.TRAVEL_LOCAL
    assert a["status"] == T.ARR_PENDING
    assert a["cost"] == 0.0


def test_normalize_attendee_cost_money():
    assert T.normalize_attendee({"name": "a", "cost": "12500.5"})["cost"] == 12500.5
    assert T.normalize_attendee({"name": "a", "cost": -3})["cost"] == 0.0


def test_normalize_budget_bad_category_falls_back():
    b = T.normalize_budget({"label": "x", "category": "space", "estimated": "100"})
    assert b["category"] == "other"
    assert b["estimated"] == 100.0


# --------------------------------------------------------------- validate
def test_validate_event():
    assert T.validate_event({"name": "Conf", "date": "2026-11-01",
                             "end": "2026-11-02"}) == []
    assert "name_required" in T.validate_event({"name": "  "})
    assert "end_before_date" in T.validate_event(
        {"name": "x", "date": "2026-11-05", "end": "2026-11-01"})
    assert "bad_date" in T.validate_event({"name": "x", "date": "nope"})


def test_validate_attendee_needs_name():
    assert T.validate_attendee({"name": "Jamal"}) == []
    assert "name_required" in T.validate_attendee({"name": ""})
    assert "bad_depart" in T.validate_attendee({"name": "a", "depart": "nope"})


# --------------------------------------------------------------- ordering
def test_order_agenda_chronological_undated_last():
    ag = [
        {"id": 1, "title": "closing", "at": ""},
        {"id": 2, "title": "lunch", "at": "2026-11-01T13:00"},
        {"id": 3, "title": "keynote", "at": "2026-11-01T09:00"},
    ]
    out = T.order_agenda(ag)
    assert [x["id"] for x in out] == [3, 2, 1]


def test_order_attendees_by_depart():
    a = [
        {"id": 1, "name": "late", "depart": "2026-10-31T20:00"},
        {"id": 2, "name": "early", "depart": "2026-10-31T06:00"},
        {"id": 3, "name": "undated"},
    ]
    out = T.order_attendees(a)
    assert [x["id"] for x in out] == [2, 1, 3]


def test_order_is_pure():
    ag = [{"id": 1, "title": "a"}]
    T.order_agenda(ag)
    assert ag == [{"id": 1, "title": "a"}]


# --------------------------------------------------------------- derived
def test_day_span():
    assert T.day_span({"date": "2026-11-01", "end": "2026-11-03"}) == 3
    assert T.day_span({"date": "2026-11-01"}) == 1            # single-day
    assert T.day_span({"date": "2026-11-05", "end": "2026-11-01"}) == 0
    assert T.day_span({"date": ""}) == 0


def test_countdown_honest():
    assert T.countdown({"date": "2026-10-20"}, NOW) == 6
    assert T.countdown({"date": "2026-10-14"}, NOW) == 0
    assert T.countdown({"date": "2026-10-10"}, NOW) == -4
    assert T.countdown({"date": ""}, NOW) is None


def test_attendee_rollup():
    atts = [
        {"name": "a", "status": "confirmed"},
        {"name": "b", "status": "pending"},
        {"name": "c", "status": "booked"},
        {"name": "d", "status": "pending"},
    ]
    r = T.attendee_rollup(atts)
    assert r["total"] == 4
    assert r["unarranged"] == 2
    assert r["confirmed"] == 1
    assert r["by_status"]["booked"] == 1


def test_checklist_progress():
    tasks = [{"label": "a", "done": True}, {"label": "b", "done": False},
             {"label": "c", "done": True}]
    assert T.checklist_progress(tasks) == {"total": 3, "done": 2, "percent": 66}
    assert T.checklist_progress([]) == {"total": 0, "done": 0, "percent": 0}


# --------------------------------------------------------------- budget
def test_budget_summary_estimated_vs_actual_and_variance():
    lines = [
        {"label": "Hall", "category": "venue", "estimated": 50000, "actual": 52000},
        {"label": "Food", "category": "catering", "estimated": 30000, "actual": 28000},
    ]
    atts = [{"name": "a", "cost": 12000}, {"name": "b", "cost": 8000}]
    s = T.budget_summary(lines, atts)
    assert s["estimated"] == 80000.0
    assert s["actual"] == 80000.0
    assert s["variance"] == 0.0
    assert s["over_budget"] is False
    assert s["attendee_travel_estimate"] == 20000.0
    assert s["grand_estimate"] == 100000.0
    assert s["by_category"]["venue"] == {"estimated": 50000.0, "actual": 52000.0}


def test_budget_summary_over_budget_flag():
    lines = [{"label": "x", "category": "other", "estimated": 100, "actual": 150}]
    s = T.budget_summary(lines)
    assert s["variance"] == 50.0 and s["over_budget"] is True


# --------------------------------------------------------------- summary
def test_event_summary_counts_and_books_nothing():
    s = T.event_summary(
        {"name": "Expo", "date": "2026-11-01", "end": "2026-11-02"},
        attendees=[{"id": 1, "name": "Kamal", "status": "confirmed", "cost": 5000}],
        agenda=[{"id": 2, "title": "Keynote", "at": "2026-11-01T10:00"}],
        budget=[{"label": "Booth", "category": "venue", "estimated": 20000,
                 "actual": 0}],
        tasks=[{"label": "Banner", "done": True}],
        now=NOW,
    )
    assert s["days"] == 2
    assert s["countdown"] == 18
    assert s["counts"]["attendees"] == 1
    assert s["counts"]["agenda"] == 1
    assert s["checklist"]["percent"] == 100
    assert s["budget"]["grand_estimate"] == 25000.0
    assert s["booking_required"] is False and s["mock"] is False


# --------------------------------------------------------------- seam
def test_booking_seam_is_honest_and_empty():
    r = T.booking_seam("5 seats Dhaka to Chittagong")
    assert r["required"] is True and r["mock"] is True
    assert r["results"] == []            # never fabricates a booking/price
    assert r["marker"] == T.BOOKING_MARKER_KEY
    assert r["query"] == "5 seats Dhaka to Chittagong"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_biztravel: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
