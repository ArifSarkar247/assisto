"""
finance_tests_snippets.py — plain-assert tests for the advanced finance toolkit.

NOT a Django TestCase. The integrator folds these into core/tests.py. Every
function takes no args and raises AssertionError on failure. Smoke them with:

    cd backend && python3 -c "import core.logic.finance_tests_snippets as t; t.run_all()"

Only imports core.finance (pure, no DB) so it is safe to run anywhere.
Numbers below are hand-verified against a calculator / known formulae.
"""
from decimal import Decimal

from core import finance as F


# ---------------------------------------------------------------------------
# EMI — reducing balance (bank standard)
# ---------------------------------------------------------------------------

def test_emi_reducing_known():
    # P=100000, 12% annual, 12 months. Standard EMI = 8884.88 (hand/well-known).
    r = F.emi_schedule("100000", "12", "12", mode="reducing")
    assert r["emi"] == "8884.88", r["emi"]
    assert len(r["schedule"]) == 12
    # First month interest = 100000 * 0.01 = 1000.00
    assert r["schedule"][0]["interest"] == "1000.00", r["schedule"][0]
    # Final balance clears to zero
    assert r["schedule"][-1]["balance"] == "0.00", r["schedule"][-1]
    # Total interest is positive and total = principal + interest
    assert Decimal(r["total"]) == Decimal("100000") + Decimal(r["interest"])


def test_emi_zero_rate():
    # 0% → pure principal / months, no interest.
    r = F.emi_schedule("12000", "0", "12", mode="reducing")
    assert r["emi"] == "1000.00", r["emi"]
    assert r["interest"] == "0.00", r["interest"]
    assert r["total"] == "12000.00", r["total"]


def test_emi_one_month():
    # 1 month → repay everything + one month interest.
    r = F.emi_schedule("10000", "12", "1", mode="reducing")
    assert len(r["schedule"]) == 1
    assert r["schedule"][0]["balance"] == "0.00"
    # interest = 10000 * 0.01 = 100
    assert r["schedule"][0]["interest"] == "100.00", r["schedule"][0]


def test_emi_flat_mode():
    # Flat: P=100000, 12% annual, 12 months (=1yr).
    # Total interest = 100000*0.12*1 = 12000. EMI = 112000/12 = 9333.33
    r = F.emi_schedule("100000", "12", "12", mode="flat")
    assert r["emi"] == "9333.33", r["emi"]
    # Flat interest always exceeds reducing interest for same inputs.
    red = F.emi_schedule("100000", "12", "12", mode="reducing")
    assert Decimal(r["interest"]) > Decimal(red["interest"])


def test_emi_huge_numbers():
    # 10 crore, 9%, 240 months — must not overflow / drift; balance clears.
    r = F.emi_schedule("100000000", "9", "240", mode="reducing")
    assert r["schedule"][-1]["balance"] == "0.00", r["schedule"][-1]
    assert Decimal(r["emi"]) > 0


# ---------------------------------------------------------------------------
# Rate compare
# ---------------------------------------------------------------------------

def test_rate_compare_picks_lower():
    r = F.rate_compare("100000", "12", "9", "12")
    assert r["cheaper"] == "a", r  # 9% cheaper than 12%
    assert Decimal(r["savings"]) > 0


# ---------------------------------------------------------------------------
# DPS / recurring savings
# ---------------------------------------------------------------------------

def test_dps_projection_basic():
    # 1000/mo, 12% annual, 12 months, deposit at start, monthly compounding.
    # Hand: annuity-due FV = 1000*((1.01^12-1)/0.01)*1.01 = 12809.33
    r = F.dps_projection("1000", "12", "12")
    assert r["invested"] == "12000.00", r["invested"]
    assert r["maturity"] == "12809.33", r["maturity"]
    assert Decimal(r["profit"]) == Decimal(r["maturity"]) - Decimal(r["invested"])


def test_dps_zero_rate():
    r = F.dps_projection("500", "0", "10")
    assert r["maturity"] == "5000.00", r["maturity"]
    assert r["profit"] == "0.00", r["profit"]


# ---------------------------------------------------------------------------
# Goal savings (solve monthly payment)
# ---------------------------------------------------------------------------

def test_goal_savings_zero_rate():
    # Need 120000 in 12 months from 0, no profit → 10000/mo.
    r = F.goal_savings("120000", "0", "0", "12")
    assert r["monthly"] == "10000.00", r["monthly"]


def test_goal_savings_already_reached():
    r = F.goal_savings("10000", "20000", "5", "12")
    assert r.get("reached_without_saving") is True, r
    assert r["monthly"] == "0"


# ---------------------------------------------------------------------------
# 50-30-20 budget
# ---------------------------------------------------------------------------

def test_budget_503020():
    r = F.budget_503020("50000")
    assert r["needs"] == "25000.00", r
    assert r["wants"] == "15000.00", r
    assert r["savings"] == "10000.00", r
    # No drift: parts sum to income.
    assert (Decimal(r["needs"]) + Decimal(r["wants"]) + Decimal(r["savings"])
            == Decimal("50000.00"))


def test_budget_odd_income_no_drift():
    r = F.budget_503020("10001")
    total = Decimal(r["needs"]) + Decimal(r["wants"]) + Decimal(r["savings"])
    assert total == Decimal("10001.00"), r


# ---------------------------------------------------------------------------
# Affordability
# ---------------------------------------------------------------------------

def test_affordability_yes():
    # free=30000, finance 100000 over 12mo @12% → EMI 8884.88 < 30000.
    r = F.affordability("50000", "20000", "100000", "0", "12", "12")
    assert r["affordable"] is True, r
    assert r["emi"] == "8884.88", r


def test_affordability_no():
    r = F.affordability("20000", "19000", "100000", "0", "12", "12")
    assert r["affordable"] is False, r


def test_affordability_lump_sum():
    # months<=1 → whole financed amount due at once.
    r = F.affordability("50000", "10000", "30000", "0", "1", "0")
    assert r["emi"] == "30000.00", r


# ---------------------------------------------------------------------------
# Break-even
# ---------------------------------------------------------------------------

def test_break_even_basic():
    # fixed 10000, price 100, cost 60 → margin 40 → 250 units.
    r = F.break_even("10000", "100", "60")
    assert r["units"] == 250, r
    assert r["revenue"] == "25000.00", r


def test_break_even_impossible():
    r = F.break_even("10000", "50", "60")  # negative margin
    assert r["impossible"] is True, r
    assert r["units"] is None


# ---------------------------------------------------------------------------
# ROI
# ---------------------------------------------------------------------------

def test_roi_basic():
    r = F.simple_roi("10000", "13000", "6")
    assert r["roi_pct"] == "30.00", r
    assert r["profit"] == "3000.00", r
    # annualised = 30 * 12 / 6 = 60
    assert r["annualised_pct"] == "60.00", r


# ---------------------------------------------------------------------------
# Currency / unit convert
# ---------------------------------------------------------------------------

def test_convert():
    r = F.convert_amount("100", "121.50")  # 100 USD @ 121.50 = 12150
    assert r["result"] == "12150.00", r


# ---------------------------------------------------------------------------
# Zakat (expanded)
# ---------------------------------------------------------------------------

def test_zakat_full():
    # cash 200000 + gold 100000 - debts 50000 = 250000 zakatable; 2.5% = 6250.
    r = F.zakat_full(cash="200000", gold_value="100000", debts="50000",
                     nisab="100000")
    assert r["zakatable"] == "250000.00", r
    assert r["zakat_due"] == "6250.00", r
    assert r["above_nisab"] is True


def test_zakat_below_nisab():
    r = F.zakat_full(cash="50000", nisab="100000")
    assert r["above_nisab"] is False, r
    assert r["zakat_due"] == "0.00", r


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"OK — {len(fns)} finance tests passed")
    return len(fns)
