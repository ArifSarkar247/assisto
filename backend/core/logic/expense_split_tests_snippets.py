"""
expense_split_tests_snippets.py — plain-assert tests for EXPENSE SPLITTING
(#183, §20). Pure stdlib. `python expense_split_tests_snippets.py` or import and
call run_all(). Deterministic; every assertion hand-verified against fixed
inputs.
"""

try:  # Django harness
    from core.logic import expense_split as S
except ImportError:  # standalone
    import expense_split as S  # noqa: E402


# --------------------------------------------------------------- poisha

def test_poisha_and_fmt():
    assert S.to_poisha("30.00") == 3000
    assert S.fmt_poisha(3000) == "৳30.00"
    assert S.fmt_poisha(-100) == "-৳1.00"


# --------------------------------------------------------------- splitting

def test_split_equal_sums_exactly():
    shares = S.split_equal(1000, ["a", "b", "c"])  # 10 taka / 3
    assert sum(s["share"] for s in shares) == 1000
    assert sorted(s["share"] for s in shares) == [333, 333, 334]


def test_split_shares_largest_remainder():
    shares = S.split_shares(1000, [{"member": "a", "weight": 1},
                                   {"member": "b", "weight": 2}])
    assert sum(s["share"] for s in shares) == 1000
    by = {s["member"]: s["share"] for s in shares}
    assert by["a"] == 333 and by["b"] == 667


def test_split_exact():
    rows, total = S.split_exact([{"member": "a", "amount": "10"},
                                 {"member": "b", "amount": "20"}])
    assert total == 3000
    assert {r["member"]: r["share"] for r in rows} == {"a": 1000, "b": 2000}


# --------------------------------------------------------------- one expense

def test_normalise_equal_default_participants_is_whole_group():
    n = S.normalise_expense({"payer": "a", "amount": "30"}, ["a", "b", "c"])
    assert n["total"] == 3000
    assert len(n["shares"]) == 3
    assert sum(s["share"] for s in n["shares"]) == 3000


def test_expense_debts_excludes_payer():
    n = S.normalise_expense({"payer": "a", "amount": "30"}, ["a", "b", "c"])
    debts = S.expense_debts(n)
    assert all(d["from"] != "a" for d in debts)
    assert all(d["to"] == "a" for d in debts)
    assert len(debts) == 2


# --------------------------------------------------------------- net balances

def test_net_balances_sum_to_zero():
    # a pays 30 for a,b,c equally; b pays 15 for b,c equally
    expenses = [
        {"payer": "a", "amount": "30", "mode": "equal",
         "participants": ["a", "b", "c"]},
        {"payer": "b", "amount": "15", "mode": "equal",
         "participants": ["b", "c"]},
    ]
    net = S.net_balances(expenses, ["a", "b", "c"])
    assert sum(net.values()) == 0  # EXACT
    # a paid 3000, share 1000 -> +2000
    assert net["a"] == 2000


def test_untouched_member_is_zero():
    net = S.net_balances([], ["a", "b"])
    assert net == {"a": 0, "b": 0}


# --------------------------------------------------------------- simplify

def test_simplify_minimal_transfers():
    # a paid 30 for 3 -> b owes a 10, c owes a 10
    expenses = [{"payer": "a", "amount": "30", "mode": "equal",
                 "participants": ["a", "b", "c"]}]
    tr = S.simplify_debts(expenses, ["a", "b", "c"])
    total_moved = sum(t["amount"] for t in tr)
    assert total_moved == 2000  # 10 + 10 taka
    assert all(t["to"] == "a" for t in tr)


def test_simplify_collapses_chains():
    # classic chain: a->b 10, b->c 10 should collapse to a->c 10
    expenses = [
        {"payer": "b", "amount": "10", "mode": "exact",
         "parts": [{"member": "a", "amount": "10"}]},
        {"payer": "c", "amount": "10", "mode": "exact",
         "parts": [{"member": "b", "amount": "10"}]},
    ]
    tr = S.simplify_debts(expenses, ["a", "b", "c"])
    # a owes net 10, c is owed net 10, b nets 0 -> single transfer a->c
    assert len(tr) == 1
    assert tr[0]["from"] == "a" and tr[0]["to"] == "c" and tr[0]["amount"] == 1000


def test_settlement_is_deterministic():
    expenses = [{"payer": "a", "amount": "30", "mode": "equal",
                 "participants": ["a", "b", "c"]}]
    assert S.simplify_debts(expenses, ["a", "b", "c"]) == \
        S.simplify_debts(expenses, ["a", "b", "c"])


# --------------------------------------------------------------- group summary

def test_group_summary_shape_and_reconciles():
    members = [{"id": "a", "name": "Ayesha"}, {"id": "b", "name": "Bashir"},
               {"id": "c", "name": "Chen"}]
    expenses = [{"payer": "a", "amount": "30", "mode": "equal",
                 "participants": ["a", "b", "c"]}]
    s = S.group_summary(members, expenses, lang="en")
    for k in ("total_spent", "total_spent_display", "members", "settlements",
              "reconciles", "note"):
        assert k in s, k
    assert s["reconciles"] is True
    assert s["total_spent"] == 3000
    # settlement text carries both names and the ৳ amount
    assert any("Ayesha" in st["text"]["en"] for st in s["settlements"])
    assert "bn" in s["note"] and "en" in s["note"]


def test_group_summary_member_states():
    members = [{"id": "a", "name": "A"}, {"id": "b", "name": "B"}]
    expenses = [{"payer": "a", "amount": "20", "mode": "equal",
                 "participants": ["a", "b"]}]
    s = S.group_summary(members, expenses, lang="en")
    by = {r["id"]: r for r in s["members"]}
    assert by["a"]["state"] == "is_owed" and by["a"]["net"] == 1000
    assert by["b"]["state"] == "owes" and by["b"]["net"] == -1000


# --------------------------------------------------------------- validation

def test_validate_expense():
    ids = ["a", "b"]
    assert "payer_not_in_group" in S.validate_expense({"payer": "z"}, ids)
    assert "amount_required" in S.validate_expense(
        {"payer": "a", "mode": "equal", "amount": "0"}, ids)
    assert "bad_mode" in S.validate_expense(
        {"payer": "a", "mode": "weird", "amount": "10"}, ids)
    assert S.validate_expense(
        {"payer": "a", "mode": "equal", "amount": "10",
         "participants": ["a", "b"]}, ids) == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"expense_split: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
