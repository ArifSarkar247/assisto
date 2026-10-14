"""
spending_advice_tests_snippets.py — plain-assert tests for AI SPENDING ADVICE
(#51, §21). Pure stdlib, deterministic. `python spending_advice_tests_snippets.py`
or import and call run_all().
"""
try:  # Django harness
    from core.logic import spending_advice as S
except ImportError:  # standalone
    import spending_advice as S  # noqa: E402


# --------------------------------------------------------------- money

def test_to_minor():
    assert S.to_minor("42.50") == 4250
    assert S.to_minor("1,250.50") == 125050
    assert S.to_minor(100) == 100            # int is already minor units
    assert S.to_minor("100") == 10000         # string is major -> *100
    assert S.to_minor("abc") == 0
    assert S.to_minor(None) == 0
    assert S.to_minor("") == 0
    assert S.to_minor(True) == 0


def test_fmt_bdt():
    assert S.fmt_bdt(125050) == "৳1,250.50"
    assert S.fmt_bdt(0) == "৳0.00"
    assert S.fmt_bdt(-4250) == "-৳42.50"
    assert S.fmt_bdt(1234567) == "৳12,345.67"


def test_pct_half_up():
    assert S._pct(50, 100) == 50
    assert S._pct(1, 3) == 33
    assert S._pct(2, 3) == 67
    assert S._pct(5, 0) == 0


# --------------------------------------------------------------- normalise

def test_normalise_aggregates_and_sorts():
    rows = [
        {"category": "food", "amount": "100"},
        {"category": "food", "amount": "50"},
        {"category": "transport", "amount": "200"},
    ]
    out = S.normalise_categories(rows)
    assert out[0]["category"] == "transport" and out[0]["spent"] == 20000
    assert out[1]["category"] == "food" and out[1]["spent"] == 15000


def test_normalise_keeps_budget_only_rows():
    rows = [{"category": "rent", "amount": "0", "budget": "500"}]
    out = S.normalise_categories(rows)
    assert len(out) == 1 and out[0]["budget"] == 50000 and out[0]["spent"] == 0


def test_normalise_drops_empty():
    assert S.normalise_categories([{"category": "x", "amount": "0"}]) == []
    assert S.normalise_categories([]) == []


# --------------------------------------------------------------- analyse

def test_analyse_not_enough_data():
    r = S.analyse([])
    assert r["enough_data"] is False
    assert r["advice"] is False
    assert r["observations"] == []
    assert r["total_spent"] == 0


def test_analyse_never_advice_and_has_disclaimer():
    r = S.analyse([{"category": "food", "amount": "100"}])
    assert r["advice"] is False
    assert r["ai_required"] is False
    assert r["disclaimer_key"] == S.DISCLAIMER_KEY
    assert r["marker"] == S.MARKER_KEY


def test_analyse_shares_and_top():
    rows = [
        {"category": "food", "amount": "600"},
        {"category": "transport", "amount": "400"},
    ]
    r = S.analyse(rows)
    assert r["enough_data"] is True
    assert r["total_spent"] == 100000
    assert r["total_spent_display"] == "৳1,000.00"
    assert r["categories"][0]["category"] == "food"
    assert r["categories"][0]["share_pct"] == 60
    assert r["categories"][1]["share_pct"] == 40
    # first observation is the top category fact
    assert r["observations"][0]["key"] == "top_category"
    assert r["observations"][0]["params"]["category"] == "food"
    assert r["observations"][0]["params"]["pct"] == 60


def test_analyse_big_share_flag():
    rows = [{"category": "food", "amount": "900"},
            {"category": "misc", "amount": "100"}]
    r = S.analyse(rows)
    assert r["categories"][0]["big_share"] is True
    keys = [o["key"] for o in r["observations"]]
    assert "big_share" in keys


def test_analyse_month_over_month():
    cur = [{"category": "food", "amount": "1200"}]
    prev = {"food": "1000"}
    r = S.analyse(cur, previous=prev)
    assert r["previous_total"] == 100000
    assert r["total_delta"] == 20000       # +200.00
    assert r["total_delta_pct"] == 20       # +20%
    assert r["total_up"] is True
    keys = [o["key"] for o in r["observations"]]
    assert "total_mom_up" in keys


def test_analyse_mom_down():
    cur = [{"category": "food", "amount": "800"}]
    prev = {"food": "1000"}
    r = S.analyse(cur, previous=prev)
    assert r["total_delta"] == -20000
    assert r["total_up"] is False
    keys = [o["key"] for o in r["observations"]]
    assert "total_mom_down" in keys


def test_analyse_overspend_flag_vs_budget():
    rows = [{"category": "food", "amount": "1200", "budget": "1000"}]
    r = S.analyse(rows)
    assert len(r["overspend"]) == 1
    o = r["overspend"][0]
    assert o["over_budget"] is True
    assert o["over_by"] == 20000
    assert o["over_by_display"] == "৳200.00"
    keys = [ob["key"] for ob in r["observations"]]
    assert "over_budget" in keys


def test_analyse_under_budget_not_flagged():
    rows = [{"category": "food", "amount": "800", "budget": "1000"}]
    r = S.analyse(rows)
    assert r["overspend"] == []
    assert r["categories"][0]["over_budget"] is False


def test_analyse_savings_pointer_last():
    r = S.analyse([{"category": "food", "amount": "500"}])
    assert r["observations"][-1]["key"] == "savings_pointer"


def test_analyse_no_prev_gives_none_deltas():
    r = S.analyse([{"category": "food", "amount": "500"}])
    assert r["categories"][0]["delta"] is None
    assert r["categories"][0]["delta_pct"] is None
    assert r["total_delta"] is None


def test_analyse_deterministic():
    rows = [{"category": "food", "amount": "600"},
            {"category": "transport", "amount": "400"}]
    assert S.analyse(rows) == S.analyse(rows)


# --------------------------------------------------------------- AI seam

def test_ai_seam_is_honest_and_key_gated():
    s = S.ai_seam([{"category": "food", "amount": "500"}])
    assert s["ai_required"] is True
    assert s["mock"] is True
    assert s["integration"] == "anthropic"
    assert s["prompt_shape"]["tier"] == "cheap"
    assert "invent amounts" in s["prompt_shape"]["must_not"]
    # the mock body is the deterministic analysis, never a fabricated narrative
    assert s["mock_result"]["advice"] is False
    assert s["mock_result"]["enough_data"] is True


# --------------------------------------------------------------- runner

def run_all():
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    return len(fns)


if __name__ == "__main__":
    n = run_all()
    print(f"spending_advice: {n} tests passed")
