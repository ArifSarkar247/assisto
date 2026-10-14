"""
demand_map_tests_snippets.py — plain-assert tests for DEMAND MAP (#145, §21).
Pure stdlib, deterministic.
`python demand_map_tests_snippets.py` or import and call run_all().
"""
try:  # Django harness
    from core.logic import demand_map as D
except ImportError:  # standalone
    import demand_map as D  # noqa: E402


# --------------------------------------------------------------- normalize

def test_normalize_levels_and_score():
    assert D.normalize({"product": "Rice", "level": "surge"})["score"] == 4
    assert D.normalize({"product": "Rice", "level": "high"})["score"] == 3
    assert D.normalize({"product": "Rice", "level": "low"})["score"] == 1
    # junk/blank level -> medium (score 2)
    assert D.normalize({"product": "Rice", "level": "junk"})["level"] == "medium"
    assert D.normalize({"product": "Rice"})["score"] == 2


def test_normalize_trims():
    s = D.normalize({"product": "  Rice  ", "area": " Dhaka ", "period": "Jan"})
    assert s["product"] == "Rice" and s["area"] == "Dhaka"
    assert s["marker"] == D.MARKER_KEY


def test_band_thresholds():
    assert D._band(1.0) == "low"
    assert D._band(1.4) == "low"
    assert D._band(1.5) == "medium"
    assert D._band(2.4) == "medium"
    assert D._band(2.5) == "high"
    assert D._band(3.4) == "high"
    assert D._band(3.5) == "surge"
    assert D._band(4.0) == "surge"


# --------------------------------------------------------------- heat

def _rows():
    return [
        {"id": 1, "product": "Rice", "area": "Dhaka", "level": "surge"},
        {"id": 2, "product": "Rice", "area": "Dhaka", "level": "high"},
        {"id": 3, "product": "Rice", "area": "Ctg", "level": "medium"},
        {"id": 4, "product": "Oil", "area": "Dhaka", "level": "low"},
    ]


def test_heat_by_product():
    out = D.heat(_rows())
    assert out["signal_count"] == 4
    assert out["product_count"] == 2
    # Rice total = 4+3+2 = 9 ; Oil total = 1 -> Rice first
    rice = out["by_product"][0]
    assert rice["label"] == "Rice" and rice["total"] == 9 and rice["count"] == 3
    assert rice["avg"] == 3.0 and rice["band"] == "high"
    assert rice["top_level"] == "surge"
    assert out["hottest_product"] == "Rice"


def test_heat_by_area():
    out = D.heat(_rows())
    # Dhaka = 4+3+1 = 8 ; Ctg = 2 -> Dhaka first
    assert out["by_area"][0]["label"] == "Dhaka"
    assert out["by_area"][0]["total"] == 8
    assert out["hottest_area"] == "Dhaka"


def test_heat_grid_cells():
    out = D.heat(_rows())
    # cells: Rice·Dhaka(4+3=7), Rice·Ctg(2), Oil·Dhaka(1) -> sorted by total
    labels = [c["label"] for c in out["grid"]]
    assert labels[0] == "Rice  ·  Dhaka"
    assert out["grid"][0]["total"] == 7
    assert len(out["grid"]) == 3


def test_heat_empty():
    out = D.heat([])
    assert out["signal_count"] == 0
    assert out["by_product"] == [] and out["grid"] == []
    assert out["hottest_product"] is None and out["hottest_area"] is None
    assert out["trade_required"] is False


def test_heat_product_only_no_area():
    out = D.heat([{"product": "Rice", "level": "high"}])
    assert out["product_count"] == 1
    assert out["area_count"] == 0            # blank area makes no area bucket
    assert out["grid"] == []                 # grid needs both product+area


def test_heat_deterministic():
    assert D.heat(_rows()) == D.heat(_rows())


# --------------------------------------------------------------- seam

def test_trade_seam_honest_no_market_data():
    s = D.trade_seam(product="Rice", area="Dhaka", period="2026-01")
    assert s["trade_required"] is True
    assert s["mock"] is True
    assert s["signals"] == []                # NEVER fabricates market data
    assert s["integration"] == "trade_data"
    assert s["query_shape"]["product"] == "Rice"


# --------------------------------------------------------------- runner

def run_all():
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    return len(fns)


if __name__ == "__main__":
    n = run_all()
    print(f"demand_map: {n} tests passed")
