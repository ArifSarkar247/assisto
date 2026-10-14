"""
price_radar_tests_snippets.py — plain-assert tests for MARKET PRICE RADAR
(#34, §21). Pure stdlib, deterministic. `python price_radar_tests_snippets.py`
or import and call run_all().
"""
try:  # Django harness
    from core.logic import price_radar as R
except ImportError:  # standalone
    import price_radar as R  # noqa: E402


# --------------------------------------------------------------- money

def test_to_minor_and_fmt():
    assert R.to_minor("42.50") == 4250
    assert R.to_minor("1,250") == 125000
    assert R.to_minor("abc") == 0
    assert R.to_minor(None) == 0
    assert R.fmt_bdt(4250) == "৳42.50"
    assert R.fmt_bdt(125000) == "৳1,250.00"
    assert R.fmt_bdt(-500) == "-৳5.00"


def test_pct_change():
    assert R._pct_change(1000, 1200) == 20.0
    assert R._pct_change(1000, 900) == -10.0
    assert R._pct_change(0, 500) == 0.0
    assert R._pct_change(None, 500) == 0.0
    assert R._pct_change(300, 350) == 16.7   # 16.666 -> 16.7


# --------------------------------------------------------------- keys

def test_item_key_case_and_unit():
    (lc1, u1), shown1 = R.item_key("Rice", "KG")
    (lc2, u2), shown2 = R.item_key("rice", "kg")
    assert (lc1, u1) == (lc2, u2) == ("rice", "kg")
    assert shown1 == "Rice"            # original casing preserved for display
    (_, u3), _ = R.item_key("x", "weird")
    assert u3 == "other"               # unknown unit normalised


# --------------------------------------------------------------- item_trend

def test_item_trend_single_log_no_trend():
    t = R.item_trend([{"price": "50", "date": "2026-01-01"}])
    assert t["count"] == 1
    assert t["has_trend"] is False
    assert t["latest"] == 5000
    assert t["change"] is None and t["change_pct"] is None


def test_item_trend_empty():
    assert R.item_trend([])["count"] == 0
    assert R.item_trend([{"price": "0"}])["count"] == 0  # non-positive dropped


def test_item_trend_stats():
    logs = [
        {"price": "40", "date": "2026-01-01", "market": "A"},
        {"price": "60", "date": "2026-01-03", "market": "B"},
        {"price": "50", "date": "2026-01-02", "market": "C"},
    ]
    t = R.item_trend(logs)
    assert t["count"] == 3
    assert t["has_trend"] is True
    # sorted by date: 40 (01), 50 (02), 60 (03) -> latest 60, prev 50
    assert t["latest"] == 6000 and t["latest_market"] == "B"
    assert t["previous"] == 5000
    assert t["change"] == 1000 and t["change_pct"] == 20.0 and t["up"] is True
    assert t["high"] == 6000 and t["low"] == 4000
    assert t["avg"] == 5000           # (40+50+60)/3 = 50.00
    assert t["first"] == 4000
    assert t["high_display"] == "৳60.00" and t["avg_display"] == "৳50.00"


def test_item_trend_price_down():
    logs = [{"price": "100", "date": "2026-02-01"},
            {"price": "80", "date": "2026-02-05"}]
    t = R.item_trend(logs)
    assert t["change"] == -2000 and t["change_pct"] == -20.0
    assert t["down"] is True and t["up"] is False


# --------------------------------------------------------------- radar

def test_radar_groups_by_name_and_unit():
    logs = [
        {"item": "Rice", "unit": "kg", "price": "50", "date": "2026-01-01"},
        {"item": "rice", "unit": "kg", "price": "55", "date": "2026-01-10"},
        {"item": "Oil", "unit": "litre", "price": "180", "date": "2026-01-05"},
    ]
    out = R.radar(logs)
    assert out["item_count"] == 2
    assert out["log_count"] == 3
    assert out["live_required"] is False
    names = {i["item"] for i in out["items"]}
    assert names == {"Rice", "Oil"}
    rice = next(i for i in out["items"] if i["item"] == "Rice")
    assert rice["count"] == 2 and rice["latest"] == 5500
    assert rice["change_pct"] == 10.0
    assert rice["mixed_units"] is False


def test_radar_mixed_units_flag():
    logs = [
        {"item": "Rice", "unit": "kg", "price": "50", "date": "2026-01-01"},
        {"item": "Rice", "unit": "bag", "price": "2500", "date": "2026-01-02"},
    ]
    out = R.radar(logs)
    assert out["item_count"] == 2
    for i in out["items"]:
        assert i["mixed_units"] is True


def test_radar_empty():
    out = R.radar([])
    assert out["item_count"] == 0 and out["log_count"] == 0
    assert out["items"] == []
    assert out["live_required"] is False


def test_radar_deterministic():
    logs = [{"item": "Egg", "unit": "dozen", "price": "150", "date": "2026-01-01"}]
    assert R.radar(logs) == R.radar(logs)


# --------------------------------------------------------------- feed seam

def test_feed_seam_honest_no_prices():
    s = R.feed_seam(item="Rice", market="Karwan Bazar")
    assert s["live_required"] is True
    assert s["mock"] is True
    assert s["prices"] == []           # NEVER fabricates a live quote
    assert s["integration"] == "price_feed"
    assert s["query_shape"]["item"] == "Rice"


# --------------------------------------------------------------- runner

def run_all():
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    return len(fns)


if __name__ == "__main__":
    n = run_all()
    print(f"price_radar: {n} tests passed")
