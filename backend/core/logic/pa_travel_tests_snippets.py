"""
pa_travel_tests_snippets.py — plain-assert tests for PA boss-trip travel &
itinerary (#112, §14). Pure stdlib. `python pa_travel_tests_snippets.py` or
import and call run_all(). Deterministic (countdown from a passed-in `now`).
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_travel as T
except ImportError:  # standalone
    import pa_travel as T  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_trip_defaults():
    t = T.normalize_trip({"title": "  Dhaka   trip "})
    assert t["title"] == "Dhaka trip"
    assert t["start"] == "" and t["end"] == ""


def test_normalize_leg_bad_mode_falls_back():
    leg = T.normalize_leg({"mode": "teleport", "from_place": "A", "to_place": "B"})
    assert leg["mode"] == T.LEG_CAR
    assert leg["from_place"] == "A" and leg["to_place"] == "B"


def test_normalize_pack_checked_coerced_bool():
    assert T.normalize_pack({"label": "Passport", "checked": 1})["checked"] is True
    assert T.normalize_pack({"label": "x"})["checked"] is False


# --------------------------------------------------------------- validate
def test_validate_trip():
    assert T.validate_trip({"title": "Trip", "start": "2026-11-01",
                            "end": "2026-11-03"}) == []
    assert "title_required" in T.validate_trip({"title": "  "})
    assert "end_before_start" in T.validate_trip(
        {"title": "x", "start": "2026-11-05", "end": "2026-11-01"})
    assert "bad_start" in T.validate_trip({"title": "x", "start": "nope"})


def test_validate_leg_needs_from_and_to():
    assert T.validate_leg({"from_place": "A", "to_place": "B"}) == []
    p = T.validate_leg({"from_place": "", "to_place": ""})
    assert "from_required" in p and "to_required" in p


# --------------------------------------------------------------- ordering
def test_order_legs_chronological_undated_last():
    legs = [
        {"id": 1, "from_place": "a", "to_place": "b", "depart": ""},
        {"id": 2, "from_place": "c", "to_place": "d", "depart": "2026-11-01T08:00"},
        {"id": 3, "from_place": "e", "to_place": "f", "depart": "2026-10-20T06:00"},
    ]
    out = T.order_legs(legs)
    assert [x["id"] for x in out] == [3, 2, 1]


def test_order_legs_is_pure():
    legs = [{"id": 1, "from_place": "a", "to_place": "b"}]
    T.order_legs(legs)
    assert legs == [{"id": 1, "from_place": "a", "to_place": "b"}]


def test_order_meetings_chronological():
    ms = [
        {"id": 1, "title": "late", "at": "2026-11-02T15:00"},
        {"id": 2, "title": "early", "at": "2026-11-02T09:00"},
    ]
    out = T.order_meetings(ms)
    assert [x["id"] for x in out] == [2, 1]


# --------------------------------------------------------------- derived
def test_day_span_inclusive():
    assert T.day_span({"start": "2026-11-01", "end": "2026-11-03"}) == 3
    assert T.day_span({"start": "2026-11-01", "end": "2026-11-01"}) == 1
    assert T.day_span({"start": "2026-11-05", "end": "2026-11-01"}) == 0
    assert T.day_span({"start": "", "end": ""}) == 0


def test_countdown_honest():
    assert T.countdown({"start": "2026-10-20"}, NOW) == 6
    assert T.countdown({"start": "2026-10-14"}, NOW) == 0
    assert T.countdown({"start": "2026-10-10"}, NOW) == -4
    assert T.countdown({"start": ""}, NOW) is None


def test_packing_progress():
    items = [
        {"label": "a", "checked": True},
        {"label": "b", "checked": False},
        {"label": "c", "checked": True},
        {"label": "d", "checked": False},
    ]
    p = T.packing_progress(items)
    assert p == {"total": 4, "checked": 2, "percent": 50}
    assert T.packing_progress([]) == {"total": 0, "checked": 0, "percent": 0}


# --------------------------------------------------------------- summary
def test_itinerary_summary_counts_and_books_nothing():
    s = T.itinerary_summary(
        {"title": "Chittagong", "start": "2026-11-01", "end": "2026-11-02"},
        legs=[{"id": 1, "from_place": "DAC", "to_place": "CGP",
               "depart": "2026-11-01T07:00"}],
        stays=[{"id": 2, "name": "Hotel"}],
        meetings=[{"id": 3, "title": "Board", "at": "2026-11-01T11:00"}],
        packing=[{"label": "Passport", "checked": True}],
    )
    assert s["days"] == 2
    assert s["counts"] == {"legs": 1, "stays": 1, "meetings": 1, "packing": 1}
    assert s["packing"]["percent"] == 100
    assert s["booking_required"] is False and s["mock"] is False


# --------------------------------------------------------------- seam
def test_booking_seam_is_honest_and_empty():
    r = T.booking_seam("Dhaka to Cox's Bazar")
    assert r["required"] is True and r["mock"] is True
    assert r["results"] == []            # never fabricates a booking/price
    assert r["marker"] == T.BOOKING_MARKER_KEY
    assert r["query"] == "Dhaka to Cox's Bazar"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_travel: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
