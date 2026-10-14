"""
money_tests_snippets.py — plain-assert test functions for the money module.

These are NOT a Django TestCase. The integrator folds them into core/tests.py
(either call them from a TestCase method, or paste the bodies into test_* methods).
Every function takes no args and raises AssertionError on failure. A tiny
run_all() lets you smoke them locally with:

    python3 -c "import core.logic.money_tests_snippets as m; m.run_all()"

They import only the two logic modules (no DB), so they are safe to run anywhere.
"""
from datetime import date
from decimal import Decimal

from core.logic import money_engine as E
from core.logic import money_parse as P


# ---------------------------------------------------------------------------
# money_parse
# ---------------------------------------------------------------------------

def test_parse_bkash_received():
    r = P.parse_sms(
        "You have received Tk 500.00 from 01712345678. Ref 12345. "
        "Fee Tk 0.00. Balance Tk 1,250.50. TrxID 9F2A1B3C",
        sender="bKash")
    assert r["channel"] == "bkash", r
    assert r["type"] == "credit", r
    assert r["amount"] == Decimal("500.00"), r
    assert r["balance"] == Decimal("1250.50"), r
    assert r["ref"] == "9F2A1B3C", r
    assert r["counterparty_number"] == "01712345678", r
    assert r["parsed"] is True


def test_parse_bkash_cashout_with_fee():
    r = P.parse_sms(
        "Cash Out Tk 1,000.00 to 01800000000 successful. Fee Tk 18.50. "
        "Balance Tk 812.33. TrxID ABCD1234", sender="bKash")
    assert r["type"] == "debit", r
    assert r["amount"] == Decimal("1000.00"), r  # not the fee or balance
    assert r["fee"] == Decimal("18.50"), r
    assert r["balance"] == Decimal("812.33"), r


def test_parse_amount_equals_balance():
    # P1: amount happens to equal the balance -> must still parse (by position).
    r = P.parse_sms(
        "You have received Tk 1,000.00 from 01712345678. "
        "Balance Tk 1,000.00. TrxID EQBAL1", sender="bKash")
    assert r["amount"] == Decimal("1000.00"), r
    assert r["balance"] == Decimal("1000.00"), r
    assert r["type"] == "credit", r
    assert r["parsed"] is True, r


def test_parse_amount_equals_fee():
    # P1: amount happens to equal the fee -> must still parse (by position).
    r = P.parse_sms(
        "Cash Out Tk 18.50 to 01800000000 successful. Fee Tk 18.50. "
        "Balance Tk 500.00. TrxID EQFEE1", sender="bKash")
    assert r["amount"] == Decimal("18.50"), r
    assert r["fee"] == Decimal("18.50"), r
    assert r["balance"] == Decimal("500.00"), r
    assert r["type"] == "debit", r
    assert r["parsed"] is True, r


def test_parse_received_is_income_not_sendmoney():
    # P4: an incoming credit with no other keyword must guess 'income'.
    r = P.parse_sms(
        "You have received Tk 500.00 from 01712345678. TrxID INCOME1",
        sender="bKash")
    assert r["type"] == "credit", r
    assert r["category_guess"] == "income", r


def test_parse_nagad_bangla_digits():
    r = P.parse_sms("Money Received. Amount: Tk ১,০০০.০০ TxnID: NGD999", sender="NAGAD")
    assert r["channel"] == "nagad", r
    assert r["amount"] == Decimal("1000.00"), r
    assert r["type"] == "credit", r


def test_parse_bank_debit():
    r = P.parse_sms(
        "Your A/C ...1234 debited BDT 2,500.00 at SHWAPNO on 12-OCT-26. "
        "Avl Bal BDT 48,210.00", sender="MyBank")
    assert r["channel"] == "bank", r
    assert r["type"] == "debit", r
    assert r["amount"] == Decimal("2500.00"), r
    assert r["balance"] == Decimal("48210.00"), r
    assert r["date"] == "2026-10-12", r
    assert r["counterparty"] == "SHWAPNO", r


def test_category_guess_food():
    r = P.parse_sms("Payment Tk 250.00 to Foodpanda. Balance Tk 500.00", sender="bKash")
    assert r["category_guess"] == "food", r
    assert r["category_confidence"] >= 0.5


def test_learn_from_correction():
    P._LEARNED_MEM.clear()
    # unknown merchant -> weak guess first
    first = P.parse_sms("Payment Tk 300.00 to ZORBA GROCERS. Balance Tk 100.00")
    assert first["category_guess"] in ("uncategorized", "shopping"), first
    P.learn_correction("ZORBA GROCERS", "food")
    again = P.parse_sms("Payment Tk 120.00 to ZORBA GROCERS. Balance Tk 90.00")
    assert again["category_guess"] == "food", again
    assert again["category_confidence"] >= 0.9


def test_dedupe_by_ref():
    a = P.parse_sms("Received Tk 500 from 01711111111 TrxID SAME1", sender="bKash")
    b = P.parse_sms("Received Tk 500 from 01711111111 TrxID SAME1", sender="bKash")
    fresh, dups = P.dedupe([a, b])
    assert len(fresh) == 1 and len(dups) == 1


def test_dedupe_keeps_distinct_refless():
    # P2: two genuinely-distinct ref-less txns (same channel+amount+date+party
    # +type, e.g. paying the same shop the same amount twice in one day) must
    # BOTH be kept — not collapsed.
    a = P.parse_sms("Payment Tk 100 to COFFEE SHOP. Balance Tk 900", sender="bKash")
    b = P.parse_sms("Payment Tk 100 to COFFEE SHOP. Balance Tk 800", sender="bKash")
    # force identical fingerprint inputs (ignore balance which isn't in the key)
    assert not a.get("ref") and not b.get("ref"), (a, b)
    fresh, dups = P.dedupe([a, b])
    assert len(fresh) == 2 and len(dups) == 0, (fresh, dups)


def test_unparseable_marked():
    r = P.parse_sms("Your OTP is 123456. Do not share.", sender="bKash")
    assert r["parsed"] is False


# ---------------------------------------------------------------------------
# money_engine — budgets + rollover
# ---------------------------------------------------------------------------

def test_budget_status():
    assert E.budget_status(1000, 500)[0] == "ok"
    assert E.budget_status(1000, 850)[0] == "near"
    assert E.budget_status(1000, 1200)[0] == "over"


def test_budget_rollover_carries_unused():
    r = E.budget_with_rollover(
        "food", 1000,
        {"2026-08": 600, "2026-09": 300, "2026-10": 0},
        ["2026-08", "2026-09", "2026-10"], rollover=True)
    m = r["months"]
    assert m[0]["effective_limit"] == Decimal("1000.00")
    # 400 unused carries to Sep -> 1400 effective
    assert m[1]["effective_limit"] == Decimal("1400.00"), m[1]
    # Sep spent 300 of 1400 -> 1100 carries -> Oct effective 2100
    assert m[2]["effective_limit"] == Decimal("2100.00"), m[2]


def test_budget_rollover_off():
    r = E.budget_with_rollover("food", 1000, {"2026-08": 200}, ["2026-08", "2026-09"],
                               rollover=False)
    assert r["months"][1]["effective_limit"] == Decimal("1000.00")


# ---------------------------------------------------------------------------
# money_engine — trends + net worth
# ---------------------------------------------------------------------------

def test_monthly_totals_and_mom():
    txns = [
        {"kind": "income", "amount": "25000", "date": "2026-09-01"},
        {"kind": "expense", "amount": "5000", "date": "2026-09-10"},
        {"kind": "income", "amount": "25000", "date": "2026-10-01"},
        {"kind": "expense", "amount": "8000", "date": "2026-10-05"},
    ]
    tot = E.monthly_totals(txns)
    assert tot["2026-09"]["net"] == Decimal("20000.00")
    assert tot["2026-10"]["net"] == Decimal("17000.00")
    series = E.month_over_month(txns, months_back=2, today=date(2026, 10, 15))
    assert series[-1]["delta"] == Decimal("-3000.00"), series


def test_category_trends():
    txns = [
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-10-02"},
        {"kind": "expense", "amount": "4000", "category": "food", "date": "2026-09-02"},
    ]
    r = E.category_trends(txns, "2026-10")
    food = next(c for c in r["categories"] if c["category"] == "food")
    assert food["delta"] == Decimal("2000.00") and food["up"] is True


def test_net_worth():
    accounts = [{"balance": "20000"}, {"balance": "5000"}]
    loans = [
        {"kind": "given", "amount": "3000", "repayments": [{"amount": "1000", "date": "2026-10-01"}]},
        {"kind": "taken", "amount": "4000", "repayments": []},
    ]
    nw = E.net_worth(accounts, loans)
    assert nw["assets"] == Decimal("25000.00")
    assert nw["receivable"] == Decimal("2000.00")  # 3000 - 1000 repaid
    assert nw["liabilities"] == Decimal("4000.00")
    assert nw["net_worth"] == Decimal("23000.00")


# ---------------------------------------------------------------------------
# money_engine — loans
# ---------------------------------------------------------------------------

def test_loan_partial_repayments():
    ln = {"kind": "given", "amount": "5000", "date": "2026-09-01",
          "repayments": [{"amount": "2000", "date": "2026-09-15"},
                         {"amount": "1000", "date": "2026-10-01"}]}
    r = E.loan_balance(ln)
    assert r["paid"] == Decimal("3000.00")
    assert r["balance"] == Decimal("2000.00")
    assert r["progress_pct"] == 60
    assert r["settled"] is False
    assert len(r["ledger"]) == 3  # principal + 2 repayments
    assert r["ledger"][-1]["balance"] == Decimal("2000.00")


def test_loan_overpay_settles():
    ln = {"kind": "taken", "amount": "1000", "repayments": [{"amount": "1000", "date": "2026-10-01"}]}
    r = E.loan_balance(ln)
    assert r["balance"] == Decimal("0.00") and r["settled"] is True


# ---------------------------------------------------------------------------
# money_engine — recurring
# ---------------------------------------------------------------------------

def test_recurring_monthly():
    dates = E.generate_recurring(
        {"freq": "monthly", "day_of_month": 1, "start": "2026-01-01"},
        "2026-01-01", "2026-03-31")
    assert dates == ["2026-01-01", "2026-02-01", "2026-03-01"], dates


def test_recurring_weekly_interval():
    dates = E.generate_recurring(
        {"freq": "weekly", "interval": 2, "start": "2026-10-01"},
        "2026-10-01", "2026-10-31")
    assert dates == ["2026-10-01", "2026-10-15", "2026-10-29"], dates


def test_recurring_month_end_clamp():
    dates = E.generate_recurring(
        {"freq": "monthly", "day_of_month": 31, "start": "2026-01-31"},
        "2026-01-01", "2026-03-31")
    # Feb clamps to 28
    assert dates == ["2026-01-31", "2026-02-28", "2026-03-31"], dates


# ---------------------------------------------------------------------------
# money_engine — splits
# ---------------------------------------------------------------------------

def test_split_equal_no_paisa_lost():
    rows = E.split_expense("100", 3, mode="equal")
    assert sum(r["amount"] for r in rows) == Decimal("100.00")
    # 33.33, 33.33, 33.34
    assert rows[-1]["amount"] == Decimal("33.34"), rows


def test_split_shares():
    rows = E.split_expense("1000", [{"name": "A", "weight": 1}, {"name": "B", "weight": 3}],
                           mode="shares")
    assert rows[0]["amount"] == Decimal("250.00")
    assert rows[1]["amount"] == Decimal("750.00")
    assert sum(r["amount"] for r in rows) == Decimal("1000.00")


def test_split_percent():
    rows = E.split_expense("200", [{"name": "A", "percent": 25}, {"name": "B", "percent": 75}],
                           mode="percent")
    assert rows[0]["amount"] == Decimal("50.00")
    assert sum(r["amount"] for r in rows) == Decimal("200.00")


# ---------------------------------------------------------------------------
# money_engine — monthly report
# ---------------------------------------------------------------------------

def test_monthly_report():
    txns = [
        {"kind": "income", "amount": "25000", "category": "salary", "date": "2026-10-01"},
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-10-05"},
        {"kind": "expense", "amount": "2000", "category": "transport", "date": "2026-10-07"},
    ]
    rep = E.monthly_report(txns, "2026-10",
                           budgets=[{"category": "food", "monthly_limit": "5000"}])
    assert rep["income"] == Decimal("25000.00")
    assert rep["expense"] == Decimal("8000.00")
    assert rep["net"] == Decimal("17000.00")
    assert rep["savings_rate"] == 68
    assert rep["budgets"][0]["state"] == "over"  # food 6000 > 5000
    assert rep["biggest_expense"]["category"] == "food"
    assert rep["txn_count"] == 3


def test_wrapped_not_enough_data():
    # New user with < min_txns real rows -> honest empty, no fabricated recap.
    txns = [
        {"kind": "expense", "amount": "100", "category": "food", "date": "2026-10-01"},
        {"kind": "expense", "amount": "200", "category": "food", "date": "2026-10-02"},
    ]
    w = E.monthly_wrapped(txns, "2026-10", min_txns=5)
    assert w["enough_data"] is False, w
    assert w["txn_count"] == 2, w
    assert "total_spent" not in w, w  # nothing fabricated


def test_wrapped_real_numbers():
    txns = [
        {"kind": "income", "amount": "30000", "category": "salary", "date": "2026-09-01"},
        {"kind": "expense", "amount": "4000", "category": "food", "date": "2026-09-05"},
        {"kind": "expense", "amount": "6000", "category": "food", "date": "2026-09-10"},
        {"kind": "expense", "amount": "3000", "category": "transport", "date": "2026-09-12"},
        {"kind": "expense", "amount": "2000", "category": "shopping", "date": "2026-09-15"},
        {"kind": "expense", "amount": "1000", "category": "mobile", "date": "2026-09-20"},
        # previous month for the trend comparison
        {"kind": "expense", "amount": "8000", "category": "food", "date": "2026-08-05"},
    ]
    w = E.monthly_wrapped(txns, "2026-09", min_txns=5)
    assert w["enough_data"] is True, w
    assert w["total_earned"] == "30000.00", w
    assert w["total_spent"] == "16000.00", w          # 4+6+3+2+1 k
    assert w["total_saved"] == "14000.00", w          # net
    assert w["savings_rate"] == 47, w                 # 14000/30000
    assert w["top_category"] == "food", w             # 10000 is the biggest slice
    assert w["top_category_amount"] == "10000.00", w
    assert w["biggest_expense"]["amount"] == "6000.00", w
    assert w["biggest_expense"]["category"] == "food", w
    # trend vs Aug (8000 spent) -> up 8000 = +100%
    assert w["spend_trend"]["up"] is True, w
    assert w["spend_trend"]["pct"] == 100, w
    assert w["spend_trend"]["has_previous"] is True, w
    assert w["category_count"] == 4, w
    assert w["busiest_day"]["date"] == "2026-09-10", w
    assert w["busiest_day"]["amount"] == "6000.00", w
    assert w["personality"] == "super_saver", w       # 47% savings rate


def test_wrapped_no_previous_month_is_honest():
    # First real month ever: no prior spend -> trend has_previous False, pct 0,
    # never a fabricated comparison.
    txns = [
        {"kind": "income", "amount": "10000", "date": "2026-07-01"},
        {"kind": "expense", "amount": "500", "category": "food", "date": "2026-07-02"},
        {"kind": "expense", "amount": "500", "category": "food", "date": "2026-07-03"},
        {"kind": "expense", "amount": "500", "category": "transport", "date": "2026-07-04"},
        {"kind": "expense", "amount": "500", "category": "food", "date": "2026-07-05"},
        {"kind": "expense", "amount": "500", "category": "food", "date": "2026-07-06"},
    ]
    w = E.monthly_wrapped(txns, "2026-07", min_txns=5)
    assert w["enough_data"] is True, w
    assert w["spend_trend"]["has_previous"] is False, w
    assert w["spend_trend"]["pct"] == 0, w
    # a fully past month: 31 days, spent on 5 distinct days -> 26 no-spend days
    assert w["no_spend_days"] == 26, w


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"OK — {len(fns)} money tests passed")
    return len(fns)
