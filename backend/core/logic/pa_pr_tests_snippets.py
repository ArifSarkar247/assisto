"""
pa_pr_tests_snippets.py — plain-assert tests for the PA PR & press tracker
(#122, §14). Pure stdlib. Deterministic (split from a passed-in `now`).
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_pr as P
except ImportError:  # standalone
    import pa_pr as P  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_coverage_fallbacks():
    c = P.normalize_coverage({"outlet": " Prothom Alo ", "type": "x",
                              "sentiment": "meh"})
    assert c["outlet"] == "Prothom Alo"
    assert c["type"] == P.TYPE_ONLINE
    assert c["sentiment"] == P.SENT_NEUTRAL


def test_normalize_interview():
    m = P.normalize_interview({"outlet": "  ATN  ", "topic": " new film "})
    assert m["outlet"] == "ATN" and m["topic"] == "new film"


# --------------------------------------------------------------- validate
def test_validate_coverage():
    assert P.validate_coverage({"outlet": "Daily Star"}) == []
    assert "outlet_required" in P.validate_coverage({"outlet": " "})
    assert "bad_date" in P.validate_coverage({"outlet": "x", "date": "nope"})


def test_validate_interview():
    assert P.validate_interview({"outlet": "RJ"}) == []
    assert "bad_at" in P.validate_interview({"outlet": "x", "at": "nope"})


# --------------------------------------------------------------- ordering
def test_order_coverage_newest_first_undated_last():
    items = [
        {"id": 1, "outlet": "a", "date": "2026-01-01"},
        {"id": 2, "outlet": "b", "date": "2026-10-01"},
        {"id": 3, "outlet": "c", "date": ""},
    ]
    out = P.order_coverage(items)
    assert [x["id"] for x in out] == [2, 1, 3]


def test_order_interviews_soonest_first():
    items = [
        {"id": 1, "outlet": "a", "at": "2026-12-01T10:00"},
        {"id": 2, "outlet": "b", "at": "2026-11-01T10:00"},
    ]
    out = P.order_interviews(items)
    assert [x["id"] for x in out] == [2, 1]


# --------------------------------------------------------------- rollup
def test_coverage_rollup_counts_and_net():
    items = [
        {"outlet": "a", "type": "tv", "sentiment": "positive"},
        {"outlet": "b", "type": "tv", "sentiment": "negative"},
        {"outlet": "c", "type": "print", "sentiment": "positive"},
        {"outlet": "d", "type": "online", "sentiment": "neutral"},
    ]
    r = P.coverage_rollup(items)
    assert r["count"] == 4
    assert r["by_type"]["tv"] == 2 and r["by_type"]["print"] == 1
    assert r["by_sentiment"]["positive"] == 2
    assert r["net_sentiment"] == 1  # 2 positive - 1 negative
    assert P.coverage_rollup([])["count"] == 0


# --------------------------------------------------------------- split
def test_split_interviews_upcoming_vs_past():
    items = [
        {"id": 1, "outlet": "a", "at": "2026-11-01T10:00"},  # future
        {"id": 2, "outlet": "b", "at": "2026-10-01T10:00"},  # past
        {"id": 3, "outlet": "c", "at": ""},                   # undated → upcoming
    ]
    s = P.split_interviews(items, NOW)
    assert s["upcoming_count"] == 2
    assert s["past_count"] == 1 and s["past"][0]["id"] == 2
    ids = {m["id"] for m in s["upcoming"]}
    assert ids == {1, 3}


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_pr: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
