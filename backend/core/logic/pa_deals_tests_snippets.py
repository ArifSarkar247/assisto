"""
pa_deals_tests_snippets.py — plain-assert tests for the PA brand-deal pipeline
(#121, §14). Pure stdlib. `python pa_deals_tests_snippets.py` or import and call
run_all(). Deterministic (overdue from a passed-in `now`; holds no money).
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_deals as D
except ImportError:  # standalone
    import pa_deals as D  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_defaults_and_stage_fallback():
    d = D.normalize_deal({"brand": "  Acme  ", "stage": "bogus", "value": "50000"})
    assert d["brand"] == "Acme"
    assert d["stage"] == D.STAGE_NEGOTIATING
    assert d["value"] == 50000


def test_normalize_deliverables_from_string_and_list():
    s = D.normalize_deal({"brand": "x", "deliverables": "Post, Reel\nStory"})
    assert s["deliverables"] == ["Post", "Reel", "Story"]
    li = D.normalize_deal({"brand": "x", "deliverables": ["  a ", "", "b"]})
    assert li["deliverables"] == ["a", "b"]


def test_money_coercion_never_negative():
    assert D.normalize_deal({"brand": "x", "value": -9})["value"] == 0
    assert D.normalize_deal({"brand": "x", "value": "junk"})["value"] == 0
    assert D.normalize_deal({"brand": "x", "value": 1500.5})["value"] == 1500.5


# --------------------------------------------------------------- validate
def test_validate_deal():
    assert D.validate_deal({"brand": "Acme"}) == []
    assert "brand_required" in D.validate_deal({"brand": "  "})
    assert "bad_deadline" in D.validate_deal({"brand": "x", "deadline": "nope"})


# --------------------------------------------------------------- ordering
def test_order_open_before_closed_then_deadline():
    deals = [
        {"id": 1, "brand": "a", "stage": "paid", "deadline": "2026-01-01"},
        {"id": 2, "brand": "b", "stage": "negotiating", "deadline": "2026-12-01"},
        {"id": 3, "brand": "c", "stage": "negotiating", "deadline": "2026-11-01"},
    ]
    out = D.order_deals(deals)
    assert [x["id"] for x in out] == [3, 2, 1]


def test_order_is_pure():
    deals = [{"id": 1, "brand": "a"}]
    D.order_deals(deals)
    assert deals == [{"id": 1, "brand": "a"}]


# --------------------------------------------------------------- overdue
def test_overdue_only_open_deals():
    past = {"brand": "x", "stage": "signed", "deadline": "2026-10-10"}
    assert D.is_overdue(past, NOW) is True
    # delivered/paid are closed — never overdue even if past
    closed = {"brand": "x", "stage": "delivered", "deadline": "2026-10-10"}
    assert D.is_overdue(closed, NOW) is False
    future = {"brand": "x", "stage": "signed", "deadline": "2026-12-01"}
    assert D.is_overdue(future, NOW) is False
    assert D.is_overdue({"brand": "x", "stage": "signed"}, NOW) is False


# --------------------------------------------------------------- pipeline
def test_pipeline_totals_and_weighting_and_overdue():
    deals = [
        {"id": 1, "brand": "A", "stage": "negotiating", "value": 100000,
         "deadline": "2026-10-10"},                       # overdue, weight .5
        {"id": 2, "brand": "B", "stage": "signed", "value": 200000,
         "deadline": "2026-12-01"},                       # weight .9
        {"id": 3, "brand": "C", "stage": "paid", "value": 50000},  # weight 1
    ]
    p = D.pipeline(deals, NOW)
    assert p["count"] == 3
    assert p["total_value"] == 350000
    # expected = 100000*.5 + 200000*.9 + 50000*1 = 50000+180000+50000 = 280000
    assert p["expected_value"] == 280000
    assert p["paid_value"] == 50000
    assert p["overdue_count"] == 1 and p["overdue"][0]["id"] == 1
    assert p["by_stage"]["signed"] == {"count": 1, "value": 200000}
    assert p["holds_money"] is False


def test_pipeline_empty():
    p = D.pipeline([], NOW)
    assert p["count"] == 0 and p["total_value"] == 0
    assert p["expected_value"] == 0 and p["overdue_count"] == 0


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_deals: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
