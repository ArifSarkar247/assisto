"""
pa_schedule_tests_snippets.py — plain-assert tests for core.logic.pa_schedule
(PA Secretary SCHEDULE control, §14 #103). NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.pa_schedule_tests_snippets as t; t.run_all()"
The engine is pure + deterministic, so every assert is hand-verified.
"""
from datetime import datetime, timedelta

try:  # Django harness
    from core.logic import pa_schedule as PS
except ImportError:  # standalone
    import pa_schedule as PS  # noqa: E402


def _slot(title, start, dur=30, **kw):
    d = {"title": title, "start": start, "duration_min": dur}
    d.update(kw)
    return d


# --------------------------------------------------------------- validation
def test_validate_requires_title_and_start():
    assert "title_required" in PS.validate_slot({"start": "2026-01-01T10:00"})
    assert "start_required" in PS.validate_slot({"title": "X"})
    assert PS.validate_slot({"title": "Board", "start": "2026-01-01T10:00"}) == []


def test_validate_bad_duration():
    assert "bad_duration" in PS.validate_slot(
        {"title": "X", "start": "2026-01-01T10:00", "duration_min": 0})
    assert "bad_duration" in PS.validate_slot(
        {"title": "X", "start": "2026-01-01T10:00", "duration_min": "nope"})


def test_normalise_cleans_and_clamps():
    ok, data = PS.normalise_slot(
        {"title": "  Call vendor ", "start": "2026-01-01T10:00",
         "duration_min": 2, "kind": "CALL", "people": ["A", "A", " ", "B"],
         "status": "weird"})
    assert ok
    assert data["title"] == "Call vendor"
    assert data["duration_min"] == PS.DURATION_MIN       # clamped up from 2
    assert data["kind"] == PS.KIND_CALL                  # lower-cased & valid
    assert data["people"] == ["A", "B"]                  # de-duped, trimmed
    assert data["status"] == PS.STATUS_CONFIRMED         # garbage -> default


def test_normalise_rejects_missing_fields():
    ok, err = PS.normalise_slot({"start": "2026-01-01T10:00"})
    assert not ok and err == "title_required"


def test_normalise_passes_through_id():
    ok, data = PS.normalise_slot(
        {"id": 42, "title": "X", "start": "2026-01-01T10:00"})
    assert ok and data["id"] == 42


# --------------------------------------------------------------- conflicts
def test_conflicts_detects_overlap_with_minutes():
    slots = [
        _slot("A", "2026-01-01T10:00", 60),   # 10:00-11:00
        _slot("B", "2026-01-01T10:30", 60),   # 10:30-11:30 -> 30m overlap
        _slot("C", "2026-01-01T12:00", 30),   # no clash
    ]
    cf = PS.conflicts(slots)
    assert len(cf) == 1
    assert cf[0] == {"a": 0, "b": 1, "overlap_min": 30}
    assert PS.has_conflicts(slots) is True
    assert PS.conflicting_indexes(slots) == [0, 1]


def test_back_to_back_is_not_a_conflict():
    slots = [_slot("A", "2026-01-01T10:00", 60),   # ends 11:00
             _slot("B", "2026-01-01T11:00", 60)]   # starts 11:00
    assert PS.conflicts(slots) == []


def test_cancelled_slots_never_conflict():
    slots = [_slot("A", "2026-01-01T10:00", 60),
             _slot("B", "2026-01-01T10:30", 60, status="cancelled")]
    assert PS.conflicts(slots) == []
    assert PS.has_conflicts(slots) is False


def test_conflict_indices_map_to_original_list():
    # out-of-order input; indices must point back at the given positions
    slots = [_slot("Late", "2026-01-01T15:00", 60),
             _slot("Early1", "2026-01-01T09:00", 60),
             _slot("Early2", "2026-01-01T09:30", 60)]
    cf = PS.conflicts(slots)
    assert cf == [{"a": 1, "b": 2, "overlap_min": 30}]


# --------------------------------------------------------------- agenda
def test_agenda_day_buckets_and_order():
    anchor = "2026-01-01T00:00"
    slots = [_slot("Noon", "2026-01-01T12:00"),
             _slot("Morning", "2026-01-01T09:00"),
             _slot("NextDay", "2026-01-02T09:00")]
    days = PS.agenda(slots, scope="day", anchor=anchor,
                     now=datetime(2026, 1, 1, 8, 0))
    assert len(days) == 1 and days[0]["date"] == "2026-01-01"
    titles = [it["slot"]["title"] for it in days[0]["items"]]
    assert titles == ["Morning", "Noon"]           # sorted by start
    assert [it["index"] for it in days[0]["items"]] == [1, 0]  # original indices


def test_agenda_week_spans_seven_days():
    # anchor Thu 2026-01-01; Monday of that ISO week is 2025-12-29
    anchor = "2026-01-01T12:00"
    slots = [_slot("Mon", "2025-12-29T09:00"),
             _slot("Sun", "2026-01-04T09:00"),
             _slot("OutOfWeek", "2026-01-05T09:00")]
    days = PS.agenda(slots, scope="week", anchor=anchor,
                     now=datetime(2026, 1, 1, 8, 0))
    dates = [d["date"] for d in days]
    assert "2025-12-29" in dates and "2026-01-04" in dates
    assert "2026-01-05" not in dates   # Monday is exclusive upper bound


def test_agenda_hides_cancelled_by_default():
    anchor = "2026-01-01T00:00"
    slots = [_slot("Live", "2026-01-01T09:00"),
             _slot("Dead", "2026-01-01T10:00", status="cancelled")]
    days = PS.agenda(slots, anchor=anchor, now=datetime(2026, 1, 1, 8, 0))
    assert [it["slot"]["title"] for it in days[0]["items"]] == ["Live"]
    days2 = PS.agenda(slots, anchor=anchor, now=datetime(2026, 1, 1, 8, 0),
                      include_cancelled=True)
    assert len(days2[0]["items"]) == 2


def test_agenda_empty_window_is_empty_not_fabricated():
    days = PS.agenda([_slot("Far", "2026-06-01T09:00")],
                     scope="day", anchor="2026-01-01T00:00",
                     now=datetime(2026, 1, 1, 8, 0))
    assert days == []


# --------------------------------------------------------------- next up
def test_next_up_future():
    now = datetime(2026, 1, 1, 8, 0)
    slots = [_slot("Later", "2026-01-01T14:00"),
             _slot("Soon", "2026-01-01T09:00", 60)]
    nu = PS.next_up(slots, now=now)
    assert nu["has_next"] and nu["slot"]["title"] == "Soon"
    assert nu["in_progress"] is False
    assert nu["minutes_until"] == 60
    assert nu["index"] == 1


def test_next_up_in_progress():
    now = datetime(2026, 1, 1, 9, 30)
    slots = [_slot("Now", "2026-01-01T09:00", 60)]  # 09:00-10:00
    nu = PS.next_up(slots, now=now)
    assert nu["has_next"] and nu["in_progress"] is True
    assert nu["minutes_until"] == 0


def test_next_up_skips_done_and_cancelled_and_past():
    now = datetime(2026, 1, 1, 12, 0)
    slots = [_slot("Past", "2026-01-01T08:00", 30),
             _slot("Done", "2026-01-01T15:00", status="done"),
             _slot("Cancelled", "2026-01-01T16:00", status="cancelled")]
    nu = PS.next_up(slots, now=now)
    assert nu["has_next"] is False and nu["slot"] is None
    assert nu["minutes_until"] is None


def test_next_up_empty_is_honest():
    nu = PS.next_up([], now=datetime(2026, 1, 1, 12, 0))
    assert nu == {"has_next": False, "index": None, "slot": None,
                  "in_progress": False, "minutes_until": None}


# --------------------------------------------------------------- summary
def test_day_summary_counts():
    now = datetime(2026, 1, 1, 8, 0)
    slots = [_slot("A", "2026-01-01T10:00", 60),
             _slot("B", "2026-01-01T10:30", 60),   # clashes with A
             _slot("C", "2026-01-01T13:00", 30)]
    s = PS.day_summary(slots, scope="day", anchor="2026-01-01T00:00", now=now)
    assert s["total"] == 3
    assert s["days"] == 1
    assert s["busiest_day"] == 3
    assert s["conflicts"] == 1


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_schedule: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
