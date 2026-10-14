"""
unseen_tests_snippets.py — plain-assert tests for core.unseen (ADVANCED travel
companion). NOT a Django TestCase.

Smoke locally:
    cd backend && python3 -c "import core.logic.unseen_tests_snippets as t; t.run_all()"

Covers: filter by division/category/query, near-me distance sort, seasonal
window, trip-idea totals, bilingual parity, and the HONESTY invariants
(every destination sourced; costs flagged approx; no invented exact prices).
"""
from core import unseen as U

DHAKA = (23.7330, 90.4172)


def test_filter_division_and_category():
    syl = U.destinations("en", division="sylhet")
    assert syl and all(d["division"] == "sylhet" for d in syl)
    nat = U.destinations("en", dtype="nature")
    assert nat and all(d["type"] == "nature" for d in nat)
    # region back-compat (localized name, either language)
    syl2 = U.destinations("en", region="Sylhet")
    syl3 = U.destinations("bn", region="সিলেট")
    assert len(syl) == len(syl2) == len(syl3)


def test_query_search():
    assert U.destinations("en", query="nijhum")
    assert U.destinations("bn", query="সাজেক")  # bn name hit
    assert U.destinations("en", query="remakri")  # how-to-get / nearby hit
    assert U.destinations("en", query="zzzz-nope") == []


def test_near_me_sorted():
    near = U.near_me(DHAKA[0], DHAKA[1], "en")
    assert near and "distance_m" in near[0]
    dists = [d["distance_m"] for d in near]
    assert dists == sorted(dists), "near_me must be ascending by distance"
    assert U.near_me(DHAKA[0], DHAKA[1], "en", limit=3).__len__() == 3


def test_seasonal():
    # Nijhum Dwip (Nov-Feb) present in Dec, absent in Jul.
    dec = {d["slug"] for d in U.seasonal(12, "en")}
    jul = {d["slug"] for d in U.seasonal(7, "en")}
    assert "nijhum-dwip" in dec and "nijhum-dwip" not in jul
    # Ratargul (Jun-Sep) present in Jul.
    assert "ratargul" in jul


def test_trip_ideas_totals():
    trips = U.trip_ideas("en")
    assert trips
    for tr in trips:
        assert tr["stops"], tr["slug"]
        assert tr["cost_low"] == sum(s["cost_low"] for s in tr["stops"])
        assert tr["cost_high"] == sum(s["cost_high"] for s in tr["stops"])
        assert tr["cost_approx"] is True
        assert tr["cost_high"] >= tr["cost_low"]


def test_bilingual_parity():
    en = U.destinations("en")
    bn = U.destinations("bn")
    assert len(en) == len(bn)
    slugs_en = {d["slug"] for d in en}
    slugs_bn = {d["slug"] for d in bn}
    assert slugs_en == slugs_bn
    # names differ by language (not accidentally identical everywhere)
    assert any(a["name"] != b["name"] for a, b in zip(en, bn))


def test_divisions_and_categories():
    assert len(U.divisions("en")) == 8
    assert len(U.categories("en")) == 7
    ids = {c["id"] for c in U.categories("en")}
    assert {"nature", "historical", "beach", "hill", "religious",
            "island", "waterfall"} == ids


def test_honesty_invariants():
    c = U.companion("en")
    allowed = {"unseenbangladesh.com", "Wikivoyage / open data"}
    # every destination attributed to a real source
    assert all(d["source"] in allowed for d in c["destinations"])
    # costs are ranges flagged approx; never a single invented exact price
    for d in c["destinations"]:
        assert d["cost_approx"] is True
        assert d["cost_high"] >= d["cost_low"] > 0
    # attribution line names both the owner site and open data
    assert "unseenbangladesh.com" in c["attribution"]
    assert "approx" in c["attribution"].lower()


def run_all():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
    print(f"unseen: {len(tests)} tests passed")


_run = run_all
