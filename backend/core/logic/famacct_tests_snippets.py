"""
famacct_tests_snippets.py — plain-assert tests for the FAMILY ACCOUNTING engine
(#61, SPEC v2.1 §21). Not a Django TestCase; the integrator folds these into
core/tests.py (as FamAcctSnippetTests) or runs them standalone:

    python3 -c "import core.logic.famacct_tests_snippets as t; t.run_all()"

No DB, no I/O. The through-line of every test is the NO-FLOAT-DRIFT invariant:
shares always sum EXACTLY to the input poisha, and settle-up nets to zero.
"""
from core.logic import famacct_engine as F


# ---------------------------------------------------------------------------
# poisha coercion — never a float survives
# ---------------------------------------------------------------------------

def test_to_poisha_int_is_poisha():
    assert F.to_poisha(500) == 500           # already poisha
    assert F.to_poisha(0) == 0
    assert F.to_poisha(None) == 0
    assert F.to_poisha(True) == 0            # bool guard


def test_to_poisha_taka_strings():
    assert F.to_poisha("12.50") == 1250
    assert F.to_poisha("12.505") == 1251     # half-up on the 3rd digit
    assert F.to_poisha("1,250.50") == 125050
    assert F.to_poisha("100") == 10000       # bare taka string
    assert F.to_poisha("-7.25") == -725


def test_to_poisha_no_binary_float_noise():
    # 0.1 + 0.2 style sums would drift as floats; the string path is exact.
    assert F.to_poisha("0.10") + F.to_poisha("0.20") == F.to_poisha("0.30")


def test_fmt_poisha_lakh_grouping():
    assert F.fmt_poisha(125050) == "৳1,250.50"
    assert F.fmt_poisha(10000000) == "৳1,00,000.00"   # lakh comma style
    assert F.fmt_poisha(-50000) == "-৳500.00"


# ---------------------------------------------------------------------------
# splitting — exact sums, remainder distribution
# ---------------------------------------------------------------------------

def test_split_equal_exact_sum():
    rows = F.split_equal(1000, ["a", "b", "c"])  # 10.00 / 3
    assert sum(r["share"] for r in rows) == 1000
    assert [r["share"] for r in rows] == [334, 333, 333]  # remainder to first


def test_split_equal_no_members():
    assert F.split_equal(1000, []) == []


def test_split_shares_largest_remainder_sums_exact():
    parts = [{"member": "a", "weight": 1}, {"member": "b", "weight": 1},
             {"member": "c", "weight": 1}]
    rows = F.split_shares(1000, parts)
    assert sum(r["share"] for r in rows) == 1000
    parts2 = [{"member": "a", "weight": 2}, {"member": "b", "weight": 1}]
    rows2 = F.split_shares(301, parts2)  # 2:1 of 301 -> 201 + 100
    assert sum(r["share"] for r in rows2) == 301


def test_split_exact_sums_to_input():
    rows, total = F.split_exact([{"member": "a", "amount": "3.00"},
                                 {"member": "b", "amount": "2.50"}])
    assert total == 550
    assert sum(r["share"] for r in rows) == 550


# ---------------------------------------------------------------------------
# shared expense -> debts to the payer
# ---------------------------------------------------------------------------

def test_shared_expense_equal_debts_exclude_payer():
    e = F.shared_expense("dad", 900, ["dad", "mom", "kid"], mode="equal")
    assert e["total"] == 900
    assert sum(s["share"] for s in e["shares"]) == 900
    # payer owes nobody; the other two owe their shares to dad
    froms = {d["from"] for d in e["debts"]}
    assert "dad" not in froms
    assert len(e["debts"]) == 2


# ---------------------------------------------------------------------------
# settle-up — net to zero, minimal transfers, 'owes' message
# ---------------------------------------------------------------------------

def test_net_balances_sum_zero():
    exps = [
        F.shared_expense("dad", 90000, ["dad", "mom", "kid"]),   # 900.00
        F.shared_expense("mom", 30000, ["dad", "mom", "kid"]),   # 300.00
    ]
    net = F.net_balances(exps)
    assert sum(net.values()) == 0


def test_settle_up_reconciles_and_minimal():
    # dad pays 600 for dad+mom (300 each) -> mom owes dad 300.
    exps = [F.shared_expense("dad", 60000, ["dad", "mom"])]
    tx = F.settle_up(exps)
    assert tx == [{"from": "mom", "to": "dad", "amount": 30000}]


def test_settle_message_bilingual():
    en = F.settle_message("Dad", "Mom", 50000, lang="en")
    assert en == "Dad owes Mom ৳500.00"
    bn = F.settle_message("Dad", "Mom", 50000, lang="bn")
    assert "Dad" in bn and "৳500.00" in bn  # Bangla template, amount embedded


# ---------------------------------------------------------------------------
# budget pool
# ---------------------------------------------------------------------------

def test_pool_status():
    p = F.pool_status(100000, [{"member": "dad", "amount": 60000},
                               {"member": "mom", "amount": 20000}])
    assert p["collected"] == 80000
    assert p["remaining"] == 20000
    assert p["pct"] == 80
    assert p["state"] == "near"
    p2 = F.pool_status(100000, [{"member": "dad", "amount": 100000}])
    assert p2["state"] == "met" and p2["pct"] == 100


# ---------------------------------------------------------------------------
# per-member view + monthly summary
# ---------------------------------------------------------------------------

def test_member_view_and_summary():
    exps = [
        {**F.shared_expense("dad", 90000, ["dad", "mom", "kid"]),
         "category": "groceries"},
        {**F.shared_expense("mom", 60000, ["dad", "mom"]),
         "category": "rent"},
    ]
    mv = F.member_view("dad", exps)
    assert mv["paid"] == 90000
    summ = F.monthly_summary(exps)
    assert summ["total"] == 150000
    assert summ["by_category"]["groceries"] == 90000
    # per-member nets sum to zero
    assert sum(m["net"] for m in summ["members"]) == 0
    assert isinstance(summ["settlements"], list)


# ---------------------------------------------------------------------------
# privacy — shared-only visibility
# ---------------------------------------------------------------------------

def test_privacy_shared_only():
    private = {"payer": "dad", "shared": False,
               "shares": [{"member": "dad", "share": 5000}], "total": 5000}
    shared = F.shared_expense("dad", 9000, ["dad", "mom", "kid"])
    shared["shared"] = True
    # a private item is invisible to everyone but its owner
    assert F.visible_to_member(private, "mom") is False
    assert F.visible_to_member(private, "dad") is True
    # a shared item is visible to its participants, not to a stranger
    assert F.visible_to_member(shared, "mom") is True
    assert F.visible_to_member(shared, "stranger") is False
    ledger = [private, shared]
    assert F.filter_shared(ledger, "mom") == [shared]


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"famacct: {len(fns)} tests passed")
    return len(fns)
