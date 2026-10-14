"""
travel_planner_tests_snippets.py — plain-assert tests for the TRAVEL PLANNER
(#35, §21). Pure stdlib, deterministic (today is passed in; no clock, no AI, no
booking). `python travel_planner_tests_snippets.py` or import + run_all().
"""
try:  # Django harness
    from core.logic import travel_planner as V
except ImportError:  # standalone
    import travel_planner as V  # noqa: E402


# --------------------------------------------------------------- money

def test_to_poisha_and_fmt():
    assert V.to_poisha("1200") == 120000      # ৳1200.00
    assert V.to_poisha("1,250.50") == 125050
    assert V.to_poisha("abc") == 0
    assert V.to_poisha("-5") == 0             # negatives clamped
    assert V.to_poisha(None) == 0
    assert V.to_poisha(True) == 0
    assert V.fmt_bdt(125050) == "৳1,250.50"
    assert V.fmt_bdt(0) == "৳0.00"
    assert V.fmt_bdt(-5000) == "-৳50.00"


# --------------------------------------------------------------- dates

def test_trip_days():
    assert V.trip_days("2026-12-01", "2026-12-05") == 5   # inclusive
    assert V.trip_days("2026-12-01", "2026-12-01") == 1
    assert V.trip_days("2026-12-05", "2026-12-01") == 0   # end < start
    assert V.trip_days("", "2026-12-05") == 0
    assert V.trip_days("junk", "2026-12-05") == 0


def test_countdown_upcoming_ongoing_past():
    up = V.countdown("2026-12-01", "2026-12-05", "2026-11-20")
    assert up["status"] == V.STATUS_UPCOMING and up["days"] == 11
    assert up["total_days"] == 5
    # starts today -> ongoing, 5 days remaining (inclusive of today..05)
    today = V.countdown("2026-12-01", "2026-12-05", "2026-12-01")
    assert today["status"] == V.STATUS_ONGOING and today["days"] == 5
    on = V.countdown("2026-12-01", "2026-12-05", "2026-12-03")
    assert on["status"] == V.STATUS_ONGOING and on["days"] == 3  # incl today..05
    past = V.countdown("2026-12-01", "2026-12-05", "2026-12-10")
    assert past["status"] == V.STATUS_PAST and past["days"] == 5


# --------------------------------------------------------------- budget

def test_budget_summary_poisha_no_drift():
    rows = [
        {"category": "transport", "estimate": "1000", "actual": "900"},
        {"category": "transport", "estimate": "500.50", "actual": "0"},
        {"category": "food", "estimate": "2000", "actual": "2500"},
        {"category": "weird", "estimate": "100", "actual": "100"},
    ]
    s = V.budget_summary(rows)
    # transport folds the two rows
    tr = next(c for c in s["categories"] if c["category"] == "transport")
    assert tr["estimate"] == 150050 and tr["actual"] == 90000
    assert tr["remaining"] == 60050
    # known categories ordered before extras; 'weird' last
    assert s["categories"][-1]["category"] == "weird"
    assert s["total_estimate"] == 150050 + 200000 + 10000   # 360050
    assert s["total_actual"] == 90000 + 250000 + 10000       # 350000
    assert s["overspent"] is False         # actual (350000) < estimate (360050)
    assert s["remaining"] == 10050
    assert s["remaining_bdt"] == V.fmt_bdt(s["remaining"])

    # a genuinely overspent trip flags overspent=True
    over = V.budget_summary([{"category": "food", "estimate": "100",
                              "actual": "150"}])
    assert over["overspent"] is True and over["remaining"] == -5000


def test_budget_empty():
    s = V.budget_summary([])
    assert s["categories"] == []
    assert s["total_estimate"] == 0 and s["overspent"] is False


# --------------------------------------------------------------- packing

def test_packing_progress():
    items = [
        {"label": "Passport", "checked": True},
        {"label": "Charger", "checked": False},
        {"label": "  ", "checked": True},   # blank label ignored
        {"label": "Meds", "checked": True},
    ]
    p = V.packing_progress(items)
    assert p["total"] == 3 and p["checked"] == 2
    assert p["percent"] == 66               # floor(2*100/3)
    assert p["done"] is False
    allp = V.packing_progress([{"label": "x", "checked": True}])
    assert allp["done"] is True and allp["percent"] == 100
    assert V.packing_progress([])["total"] == 0


# --------------------------------------------------------------- itinerary

def test_itinerary_overview():
    days = [
        {"day": 1, "title": "Arrival",
         "activities": [{"what": "Check in"}, {"what": "Dinner"}, {"what": " "}]},
        {"day": 2, "title": "City", "activities": []},
    ]
    o = V.itinerary_overview(days)
    assert o["day_count"] == 2
    assert o["total_activities"] == 2       # blank 'what' ignored
    assert o["days"][0]["activity_count"] == 2
    assert o["days"][1]["activity_count"] == 0
    assert o["days"][0]["title"] == "Arrival"


# --------------------------------------------------------------- AI seam

def test_suggest_itinerary_no_key_honest():
    r = V.suggest_itinerary_request(
        {"destination": "Cox's Bazar", "start": "2026-12-01",
         "end": "2026-12-03"}, has_ai_key=False)
    assert r["ready"] is False
    assert r["ai_required"] is True
    assert r["marker"] == V.AI_MARKER
    assert r["provider_integration"] == "anthropic"
    assert r["suggestions"] == []           # NEVER fabricated
    assert r["inputs"]["days"] == 3


def test_suggest_itinerary_ready_with_key():
    r = V.suggest_itinerary_request(
        {"destination": "Sylhet", "start": "2026-12-01", "end": "2026-12-02"},
        has_ai_key=True)
    assert r["ready"] is True and r["marker"] == ""
    assert r["suggestions"] == []           # still never fabricated here


def test_suggest_itinerary_missing():
    r = V.suggest_itinerary_request({"destination": ""}, has_ai_key=True)
    assert r["ready"] is False
    assert "no_destination" in r["missing"]
    assert "no_dates" in r["missing"]


# --------------------------------------------------------------- booking seam

def test_booking_request_no_key_honest():
    r = V.booking_request({"kind": "flight", "query": "DAC-CXB 1 Dec"},
                          has_booking_key=False)
    assert r["ready"] is False
    assert r["marker"] == V.BOOKING_MARKER
    assert r["price"] is None               # NEVER fabricates a price
    assert r["availability"] is None
    assert r["confirmation"] is None        # never books / holds money


def test_booking_request_ready_but_still_no_price():
    r = V.booking_request({"kind": "hotel", "query": "Cox's Bazar 2 nights"},
                          has_booking_key=True)
    assert r["ready"] is True and r["marker"] == ""
    assert r["price"] is None               # module itself fabricates nothing
    assert r["confirmation"] is None


def run_all():
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    print(f"travel_planner: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
