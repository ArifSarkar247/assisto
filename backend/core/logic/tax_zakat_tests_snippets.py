"""
tax_zakat_tests_snippets.py — plain-assert tests for core.logic.tax_zakat.
NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.tax_zakat_tests_snippets as t; t.run_all()"

Covers: slab math (source-noted NBR bands, never invented), tax-free threshold
per category, investment rebate (15% of lowest-of rule), minimum tax, TDS /
refund, zakat 2.5% + nisab floor, nisab from user-entered per-gram prices, and a
real-world end-to-end SCENARIO (§21 criterion 7).
"""
from decimal import Decimal

from core.logic import tax_zakat as T


# ---------------------------------------------------------------------------
# Slabs & thresholds
# ---------------------------------------------------------------------------

def test_below_threshold_zero_tax():
    r = T.slab_tax("300000", year="2025-2026", category="general")
    assert r["gross_tax"] == "0.00"
    assert r["taxable_above_threshold"] == "0.00"
    assert r["bands"] == []


def test_first_taxable_band_5pct():
    # 350,000 free + next 100,000 @ 5% → income 450,000 → tax 5,000.
    r = T.slab_tax("450000", year="2025-2026", category="general")
    assert r["gross_tax"] == "5000.00", r
    assert len(r["bands"]) == 1
    assert r["bands"][0]["rate_pct"] == "5.00"


def test_multi_band_progressive():
    # income 1,000,000, general (free 350k):
    #   above = 650,000
    #   100k@5% = 5,000 ; 400k@10% = 40,000 ; 150k@15% = 22,500
    #   total = 67,500
    r = T.slab_tax("1000000", year="2025-2026", category="general")
    assert r["gross_tax"] == "67500.00", r
    assert r["taxable_above_threshold"] == "650000.00"
    assert len(r["bands"]) == 3


def test_top_30pct_band():
    # Very high income hits the 30% balance band.
    r = T.slab_tax("10000000", year="2025-2026", category="general")
    # above = 9,650,000. Bands: 100k@5=5000, 400k@10=40000, 500k@15=75000,
    # 500k@20=100000, 2,000,000@25=500000, remaining 6,150,000@30=1,845,000
    # total = 2,565,000
    assert r["gross_tax"] == "2565000.00", r
    assert r["bands"][-1]["rate_pct"] == "30.00"


def test_female_senior_threshold():
    assert T.tax_free_threshold("female_senior") == Decimal("400000")
    assert T.tax_free_threshold("general") == Decimal("350000")
    assert T.tax_free_threshold("freedom_fighter") == Decimal("500000")
    # women: 400k free; income 500k → above 100k @5% = 5,000
    r = T.slab_tax("500000", category="female_senior")
    assert r["gross_tax"] == "5000.00", r


def test_disabled_dependent_extra_50k():
    assert T.tax_free_threshold("general", extra_disabled_dependent=True) == \
        Decimal("400000")


def test_slabs_are_source_noted():
    for key, y in T.TAX_YEARS.items():
        assert y["source"] and "NBR" in y["source"], key
        assert y["label"]


# ---------------------------------------------------------------------------
# Investment rebate (15% of lowest-of: actual, 30% income, 1 crore)
# ---------------------------------------------------------------------------

def test_rebate_limited_by_income_fraction():
    # income 1,000,000 → 30% = 300,000 cap. Invest 500,000 → allowable 300,000.
    r = T.investment_rebate("1000000", "500000")
    assert r["allowable_investment"] == "300000.00"
    assert r["rebate"] == "45000.00"  # 15% of 300,000
    assert r["rate_pct"] == "15.00"


def test_rebate_limited_by_actual_investment():
    # invest only 50,000 (< 30% of income) → allowable 50,000, rebate 7,500.
    r = T.investment_rebate("1000000", "50000")
    assert r["allowable_investment"] == "50000.00"
    assert r["rebate"] == "7500.00"


def test_rebate_crore_cap():
    # huge income & investment → capped at 1 crore allowable → 1,500,000 rebate.
    r = T.investment_rebate("100000000", "50000000")
    assert r["allowable_investment"] == "10000000.00"
    assert r["rebate"] == "1500000.00"


# ---------------------------------------------------------------------------
# Full estimate: rebate, minimum tax, TDS, refund
# ---------------------------------------------------------------------------

def test_estimate_applies_rebate():
    # income 1,000,000, invest 50,000 → gross 67,500, rebate 7,500 → 60,000.
    r = T.estimate_income_tax("1000000", eligible_investment="50000",
                              location="dhaka_ctg")
    assert r["gross_tax"] == "67500.00"
    assert r["rebate"] == "7500.00"
    assert r["tax_after_rebate"] == "60000.00"
    assert r["net_tax"] == "60000.00"
    assert r["payable"] == "60000.00"
    assert r["estimate"] is True
    assert "NBR" in r["source"]


def test_minimum_tax_floor():
    # Small taxable income above threshold but rebate wipes tax below the
    # location minimum → minimum tax applies.
    r = T.estimate_income_tax("460000", eligible_investment="200000",
                              location="dhaka_ctg")
    # above = 110,000 → 100k@5=5000 + 10k@10=1000 = 6,000 gross.
    # rebate: 30% of 460,000 = 138,000 cap; invest 200,000 → allowable 138,000
    #   → rebate 20,700 → after-rebate clamped to 0 → min tax 5,000 applies.
    assert r["gross_tax"] == "6000.00", r
    assert r["minimum_tax_applied"] is True
    assert r["net_tax"] == "5000.00"


def test_tds_produces_refund():
    r = T.estimate_income_tax("1000000", tds_paid="80000", location="dhaka_ctg")
    # net 67,500, tds 80,000 → payable 0, refund 12,500.
    assert r["payable"] == "0.00"
    assert r["refund"] == "12500.00"


def test_no_min_tax_when_below_threshold():
    r = T.estimate_income_tax("200000", location="dhaka_ctg")
    assert r["net_tax"] == "0.00"
    assert r["minimum_tax_applied"] is False
    assert r["payable"] == "0.00"


# ---------------------------------------------------------------------------
# Zakat
# ---------------------------------------------------------------------------

def test_zakat_2_5_percent():
    r = T.zakat(cash="1000000")
    assert r["zakat_due"] == "25000.00"  # 2.5%
    assert r["rate_pct"] == "2.50"
    assert r["above_nisab"] is True


def test_zakat_below_nisab_zero():
    r = T.zakat(cash="50000", nisab="100000")
    assert r["above_nisab"] is False
    assert r["zakat_due"] == "0.00"
    assert r["nisab_set"] is True


def test_zakat_net_of_debts():
    r = T.zakat(cash="200000", debts="50000", nisab="100000")
    assert r["zakatable"] == "150000.00"
    assert r["zakat_due"] == "3750.00"  # 2.5% of 150,000


def test_zakat_negative_wealth():
    r = T.zakat(cash="10000", debts="50000")
    assert r["zakatable"] == "0.00"
    assert r["zakat_due"] == "0.00"
    assert r["above_nisab"] is False


def test_nisab_from_user_prices():
    # gold 12,000/g → 87.48 * 12,000 = 1,049,760 ; silver 150/g → 612.36*150 = 91,854
    r = T.zakat_nisab(gold_price_per_gram="12000", silver_price_per_gram="150")
    assert r["gold_nisab"] == "1049760.00", r
    assert r["silver_nisab"] == "91854.00", r
    assert r["lower_nisab"] == "91854.00"  # silver is lower
    assert r["gold_grams"] == "87.48"
    assert r["silver_grams"] == "612.36"


def test_nisab_zero_when_no_price():
    r = T.zakat_nisab()
    assert r["gold_nisab"] == "0.00"
    assert r["lower_nisab"] == "0.00"


# ---------------------------------------------------------------------------
# Real-world SCENARIO (§21 criterion 7)
# ---------------------------------------------------------------------------

def test_scenario_salaried_dhaka_with_dps_and_tds():
    """A Dhaka salaried woman, taxable income 12,00,000, DPS+insurance eligible
    investment 3,00,000, employer deducted 40,000 TDS, AY 2025-26."""
    r = T.estimate_income_tax(
        "1200000", year="2025-2026", category="female_senior",
        eligible_investment="300000", tds_paid="40000", location="dhaka_ctg")
    # free 400,000 → above 800,000:
    #   100k@5=5000, 400k@10=40000, 300k@15=45000 → gross 90,000
    assert r["gross_tax"] == "90000.00", r
    # rebate: 30% of 1,200,000 = 360,000 cap; invest 300,000 → allowable 300,000
    #   → rebate 45,000 → after-rebate 45,000
    assert r["rebate"] == "45000.00"
    assert r["tax_after_rebate"] == "45000.00"
    assert r["net_tax"] == "45000.00"
    # TDS 40,000 → payable 5,000
    assert r["payable"] == "5000.00"
    assert r["refund"] == "0.00"


def test_scenario_zakat_full_buckets_with_silver_nisab():
    nis = T.zakat_nisab(silver_price_per_gram="150")["silver_nisab"]  # 91,854
    r = T.zakat(cash="300000", bank="500000", gold_value="400000",
                investments="200000", business_goods="100000",
                money_lent="50000", debts="150000", nisab=nis)
    # wealth = 300+500+400+200+100+50 - 150 = 1,400,000 (in k)
    assert r["zakatable"] == "1400000.00", r
    assert r["above_nisab"] is True
    assert r["zakat_due"] == "35000.00"  # 2.5%


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"tax_zakat: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
