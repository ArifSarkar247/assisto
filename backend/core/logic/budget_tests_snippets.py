"""
budget_tests_snippets.py — plain-assert tests for the BUDGET engine (#50).

NOT a Django TestCase. The integrator folds these into core/tests.py (call them
from a TestCase method, or paste the bodies into test_*). Each takes no args and
raises AssertionError on failure. Smoke them locally with:

    python3 -c "import core.logic.budget_tests_snippets as b; b.run_all()"

Imports only core.logic.budget (no DB), so safe to run anywhere. Every assertion
pins integer-poisha behaviour: no float drift, spend-from-real-transactions,
over-budget alerts, rollover carry, 50-30-20, insights, goal link, next plan.
"""
from decimal import Decimal

from core.logic import budget as B


# ---------------------------------------------------------------------------
# integer-poisha boundary — NO FLOAT DRIFT
# ---------------------------------------------------------------------------

def test_poisha_no_float_drift():
    # 19.99 would be 1998.9999... as a binary float *100 -> must be 1999.
    assert B.to_poisha(19.99) == 1999
    assert B.to_poisha("19.99") == 1999
    assert B.to_poisha(Decimal("19.99")) == 1999
    assert B.to_poisha(20) == 2000
    assert B.to_poisha(None) == 0 and B.to_poisha("junk") == 0
    assert B.from_poisha(1999) == Decimal("19.99")


def test_poisha_sum_exact():
    # summing 0.01 a hundred times must be exactly 1.00, not 0.9999999
    total = 0
    for _ in range(100):
        total += B.to_poisha("0.01")
    assert total == 100
    assert B.from_poisha(total) == Decimal("1.00")


# ---------------------------------------------------------------------------
# spent-vs-budget FROM REAL TRANSACTIONS
# ---------------------------------------------------------------------------

def test_spent_by_category_real_expenses_only():
    txns = [
        {"kind": "expense", "amount": "600", "category": "food", "date": "2026-10-02"},
        {"kind": "expense", "amount": "400", "category": "food", "date": "2026-10-09"},
        {"kind": "income", "amount": "25000", "category": "salary", "date": "2026-10-01"},
        {"kind": "transfer", "amount": "1000", "category": "food", "date": "2026-10-03"},
        {"kind": "expense", "amount": "300", "category": "food", "date": "2026-09-30"},  # prev month
    ]
    s = B.spent_by_category(txns, "2026-10")
    # only the two October EXPENSE rows count: income/transfer/prev-month excluded
    assert s == {"food": 100000}, s
    assert B.from_poisha(s["food"]) == Decimal("1000.00")


def test_spent_uncategorized_rollup():
    txns = [{"kind": "expense", "amount": "50", "date": "2026-10-01"}]
    assert B.spent_by_category(txns, "2026-10") == {"uncategorized": 5000}


# ---------------------------------------------------------------------------
# over-budget alert + honest states
# ---------------------------------------------------------------------------

def test_budget_line_states():
    assert B.budget_line("food", 1000, 500)["state"] == "ok"
    assert B.budget_line("food", 1000, 850)["state"] == "near"
    over = B.budget_line("food", 1000, 1200)
    assert over["state"] == "over"
    assert over["pct"] == 120  # NOT clamped
    assert over["bar_pct"] == 100  # clamped for the bar
    assert over["over_by"] == Decimal("200.00")
    assert B.budget_line("food", 0, 500)["state"] == "none"  # no limit set


def test_month_budget_spent_from_txns_and_alert():
    budgets = [
        {"category": "food", "monthly_limit": "5000"},
        {"category": "transport", "monthly_limit": "2000"},
    ]
    txns = [
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-10-05"},
        {"kind": "expense", "amount": "800", "category": "transport", "date": "2026-10-06"},
        {"kind": "expense", "amount": "900", "category": "shopping", "date": "2026-10-07"},  # unbudgeted
    ]
    r = B.month_budget(budgets, txns, "2026-10")
    food = next(l for l in r["lines"] if l["category"] == "food")
    assert food["spent"] == Decimal("6000.00")  # from the real txn, not invented
    assert food["state"] == "over" and food["over_by"] == Decimal("1000.00")
    assert r["any_over"] is True and r["over_count"] == 1
    # over sorts first
    assert r["lines"][0]["category"] == "food"
    # unbudgeted real spend surfaced honestly
    assert r["totals"]["unbudgeted_spent"] == Decimal("900.00")
    assert r["totals"]["spent"] == Decimal("6800.00")  # food+transport only in totals


# ---------------------------------------------------------------------------
# rollover
# ---------------------------------------------------------------------------

def test_rollover_carries_unused():
    r = B.rollover_series(
        "food", 1000,
        {"2026-08": 600, "2026-09": 300, "2026-10": 0},
        ["2026-08", "2026-09", "2026-10"], rollover=True)
    m = r["months"]
    assert m[0]["effective_limit"] == Decimal("1000.00")
    assert m[1]["effective_limit"] == Decimal("1400.00"), m[1]  # 400 carried
    assert m[2]["effective_limit"] == Decimal("2100.00"), m[2]  # 1100 carried
    assert r["carry_forward"] == Decimal("2100.00")


def test_rollover_off_no_carry():
    r = B.rollover_series("food", 1000, {"2026-08": 200}, ["2026-08", "2026-09"],
                          rollover=False)
    assert r["months"][1]["effective_limit"] == Decimal("1000.00")
    assert r["carry_forward"] == Decimal("0.00")


def test_rollover_overspend_no_negative_carry():
    r = B.rollover_series("food", 1000, {"2026-08": 1500, "2026-09": 0},
                          ["2026-08", "2026-09"], rollover=True)
    assert r["months"][0]["state"] == "over"
    # overspend does not create negative carry; Sep is back to the base limit
    assert r["months"][1]["effective_limit"] == Decimal("1000.00")


# ---------------------------------------------------------------------------
# 50-30-20 template — exact split, no poisha lost
# ---------------------------------------------------------------------------

def test_template_50_30_20_exact():
    r = B.template_50_30_20("10000")
    amts = [b["amount"] for b in r["buckets"]]
    assert amts == [Decimal("5000.00"), Decimal("3000.00"), Decimal("2000.00")]
    assert sum(amts) == Decimal("10000.00")


def test_template_residue_absorbed():
    # 10001 -> 50% 5000.50, 30% 3000.30, savings takes residue -> sums exact
    r = B.template_50_30_20("10001")
    amts = [b["amount"] for b in r["buckets"]]
    assert sum(amts) == Decimal("10001.00"), amts
    assert r["savings_amount"] == amts[2]


# ---------------------------------------------------------------------------
# insights
# ---------------------------------------------------------------------------

def test_insights_over_ranked():
    budgets = [
        {"category": "food", "monthly_limit": "5000"},
        {"category": "transport", "monthly_limit": "1000"},
    ]
    txns = [
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-10-01"},
        {"kind": "expense", "amount": "2000", "category": "transport", "date": "2026-10-02"},
    ]
    r = B.month_budget(budgets, txns, "2026-10")
    ins = B.insights(r)
    # transport is 200% (100% over) -> ranked before food (120% -> 20% over)
    assert ins[0]["code"] == "over" and ins[0]["category"] == "transport"
    assert ins[0]["pct"] == 100
    assert ins[1]["category"] == "food" and ins[1]["pct"] == 20


def test_insights_on_track_positive():
    budgets = [{"category": "food", "monthly_limit": "5000"}]
    txns = [{"kind": "expense", "amount": "1000", "category": "food", "date": "2026-10-01"}]
    ins = B.insights(B.month_budget(budgets, txns, "2026-10"))
    assert len(ins) == 1 and ins[0]["code"] == "on_track"


# ---------------------------------------------------------------------------
# savings-goal link
# ---------------------------------------------------------------------------

def test_goal_contribution_from_underspend():
    budgets = [{"category": "food", "monthly_limit": "5000"}]
    txns = [{"kind": "expense", "amount": "3000", "category": "food", "date": "2026-10-01"}]
    r = B.month_budget(budgets, txns, "2026-10")  # 2000 remaining
    g = B.goal_contribution(r, {"target_amount": "10000", "saved_amount": "7000"})
    assert g["contribution"] == Decimal("2000.00")
    assert g["new_saved"] == Decimal("9000.00")
    assert g["progress_pct"] == 90 and g["reached"] is False


def test_goal_over_budget_contributes_nothing():
    budgets = [{"category": "food", "monthly_limit": "1000"}]
    txns = [{"kind": "expense", "amount": "3000", "category": "food", "date": "2026-10-01"}]
    r = B.month_budget(budgets, txns, "2026-10")  # overspent -> negative remaining
    g = B.goal_contribution(r, {"target_amount": "10000", "saved_amount": "7000"})
    assert g["contribution"] == Decimal("0.00")
    assert g["new_saved"] == Decimal("7000.00")


# ---------------------------------------------------------------------------
# next-month plan from real history
# ---------------------------------------------------------------------------

def test_next_month_plan_avg_plus_buffer():
    txns = [
        {"kind": "expense", "amount": "4000", "category": "food", "date": "2026-08-01"},
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-09-01"},
    ]
    r = B.next_month_plan(txns, ["2026-08", "2026-09"], buffer_pct=10)
    food = next(s for s in r["suggestions"] if s["category"] == "food")
    # avg = 5000, +10% buffer -> 5500
    assert food["avg_spent"] == Decimal("5000.00")
    assert food["suggested_limit"] == Decimal("5500.00")


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"OK — {len(fns)} budget tests passed")
    return len(fns)
