"""
nearby_tests_snippets.py — plain-assert tests for core.logic.nearby (ADVANCED
curated layer). NOT a Django TestCase.

Smoke locally:
    cd backend && python3 -c "import core.logic.nearby_tests_snippets as t; t.run_all()"

Covers: haversine sanity, open/closed (24h + normal + past-midnight + unknown),
search filter/query/sort-by-distance, nearest-X emergency quick-access, and the
honesty invariants (source == "mock", no invented ratings).
"""
from core.logic import nearby as N

DHAKA = (23.7330, 90.4172)  # near Motijheel ATM


def test_haversine():
    assert N.haversine_m(23.73, 90.40, 23.73, 90.40) == 0
    d = N.haversine_m(23.7330, 90.4172, 23.7555, 90.3715)  # Motijheel -> Dhanmondi
    assert 4000 < d < 7000, d


def test_is_open():
    # 24h always open
    h1 = next(p for p in N.DATASET if p["id"] == "h1")
    assert N.is_open(h1, 3 * 60) is True
    # normal window 08:00-23:00 (p2)
    p2 = next(p for p in N.DATASET if p["id"] == "p2")
    assert N.is_open(p2, 9 * 60) is True
    assert N.is_open(p2, 2 * 60) is False
    # past-midnight 07:00-02:30 (r1)
    r1 = next(p for p in N.DATASET if p["id"] == "r1")
    assert N.is_open(r1, 1 * 60) is True    # 01:00 still open
    assert N.is_open(r1, 4 * 60) is False   # 04:00 closed
    # unknown hours -> None
    a1 = {"open24": False, "open_min": None, "close_min": None}
    assert N.is_open(a1, 600) is None


def test_search_filter_and_sort():
    res, src = N.search(category="pharmacy", lat=DHAKA[0], lon=DHAKA[1])
    assert src == "mock"
    assert res and all(p["cat"] == "pharmacy" for p in res)
    # sorted ascending by distance
    dists = [p["distance_m"] for p in res]
    assert dists == sorted(dists)
    # every result has a maps + directions deep link and no invented rating
    for p in res:
        assert p["maps"].startswith("https://www.google.com/maps/search/")
        assert "destination=" in p["directions"]
        assert p["rating"] is None


def test_search_query():
    res, _ = N.search(query="bkash", lat=DHAKA[0], lon=DHAKA[1])
    assert any("bKash" in p["name_en"] for p in res)
    # Bangla query matches too
    res_bn, _ = N.search(query="বিকাশ")
    assert any(p["id"] == "m1" for p in res_bn)


def test_no_location_still_lists():
    res, src = N.search(category="hospital")  # no lat/lon
    assert src == "mock" and res
    assert all(p["distance_m"] is None for p in res)
    assert all(p["open_now"] is None for p in res)  # no minute_of_day given


def test_nearest_emergency():
    h = N.nearest("hospital", DHAKA[0], DHAKA[1], minute_of_day=10)
    assert h is not None and h["cat"] == "hospital"
    # nearest requires a location
    assert N.nearest("police", None, None) is None
    # alias passthrough: unknown 'what' treated as a category
    assert N.nearest("mosque", DHAKA[0], DHAKA[1])["cat"] == "mosque"


def test_all_categories_present():
    cats = {p["cat"] for p in N.DATASET}
    for c in N.CATEGORIES:
        assert c in cats, f"missing category in dataset: {c}"


def run_all():
    fns = [v for k, v in globals().items() if k.startswith("test_")]
    for fn in fns:
        fn()
    print(f"nearby: {len(fns)} tests passed")


if __name__ == "__main__":
    run_all()
