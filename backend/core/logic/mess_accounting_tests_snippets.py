"""
mess_accounting_tests_snippets.py — plain-assert tests for MESS & BACHELOR
ACCOUNTING (#182, §20). Pure stdlib. `python mess_accounting_tests_snippets.py`
or import and call run_all(). The engine is deterministic, so every assertion
is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import mess_accounting as M
except ImportError:  # standalone
    import mess_accounting as M  # noqa: E402


# --------------------------------------------------------------- poisha

def test_to_poisha_is_exact_integer():
    assert M.to_poisha("12.50") == 1250
    assert M.to_poisha("12.505") == 1251  # half-up on 3rd digit
    assert M.to_poisha(100) == 100  # already poisha
    assert M.to_poisha("1,200.00") == 120000
    assert M.to_poisha(True) == 0
    assert M.to_poisha("junk") == 0


def test_fmt_poisha_taka_sign_and_grouping():
    assert M.fmt_poisha(123456789) == "৳12,34,567.89"  # lakh grouping
    assert M.fmt_poisha(-5000) == "-৳50.00"
    assert M.fmt_poisha(0) == "৳0.00"


# --------------------------------------------------------------- meal rate

def test_meal_rate_simple():
    # 3000 taka bazar, 60 meals => 50 taka/meal = 5000 poisha
    members = [{"id": 1, "meals": 30}, {"id": 2, "meals": 30}]
    bazar = [{"amount": "3000"}]
    assert M.total_meals(members) == 60
    assert M.total_bazar(bazar) == 300000
    assert M.meal_rate_poisha(300000, 60) == 5000.0


def test_meal_rate_undefined_when_no_meals():
    assert M.meal_rate_poisha(300000, 0) == 0.0  # honest: not infinite


# --------------------------------------------------------------- exact split

def test_meal_cost_shares_sum_exactly_to_bazar():
    # 100.00 taka (10000 poisha) over 3 unequal meal counts -> exact, no drift
    members = [{"id": "a", "meals": 7}, {"id": "b", "meals": 11},
               {"id": "c", "meals": 13}]
    shares = M.meal_cost_shares(10000, members)
    assert sum(shares.values()) == 10000  # EXACT
    # proportional-ish, every poisha accounted for
    assert all(v >= 0 for v in shares.values())


def test_meal_cost_zero_meals_pays_zero():
    members = [{"id": "a", "meals": 0}, {"id": "b", "meals": 10}]
    shares = M.meal_cost_shares(5000, members)
    assert shares["a"] == 0
    assert shares["b"] == 5000


def test_half_meals_supported():
    members = [{"id": "a", "meals": 2.5}, {"id": "b", "meals": 2.5}]
    assert M.total_meals(members) == 5
    shares = M.meal_cost_shares(1000, members)
    assert shares["a"] == 500 and shares["b"] == 500


# --------------------------------------------------------------- deposits/charges

def test_deposits_and_charges_aggregate():
    dep = [{"member": 1, "amount": "500"}, {"member": 1, "amount": "200"},
           {"member": 2, "amount": "1000"}]
    d = M.deposits_by_member(dep)
    assert d[1] == 70000 and d[2] == 100000


def test_common_charges_split_equally_exact():
    members = [{"id": 1}, {"id": 2}, {"id": 3}]
    charges = [{"member": "common", "amount": "100"}]  # 10000 poisha / 3
    out = M.split_common_charges(charges, members)
    assert sum(out.values()) == 10000  # exact, remainder distributed
    assert sorted(out.values()) == [3333, 3333, 3334]


# --------------------------------------------------------------- summary

def test_monthly_summary_balances_and_reconciles():
    members = [{"id": 1, "name": "Karim", "meals": 30},
               {"id": 2, "name": "Rahim", "meals": 30}]
    bazar = [{"amount": "3000"}]  # 50 taka/meal
    deposits = [{"member": 1, "amount": "2000"}, {"member": 2, "amount": "1000"}]
    s = M.monthly_summary(members, bazar, deposits, lang="en")
    assert s["reconciles"] is True
    by = {r["id"]: r for r in s["members"]}
    # each ate 30 meals * 50 = 1500 taka cost
    assert by[1]["meal_cost"] == 150000
    assert by[2]["meal_cost"] == 150000
    # Karim deposited 2000, cost 1500 -> gets 500 back
    assert by[1]["balance"] == 50000 and by[1]["state"] == "gets_back"
    # Rahim deposited 1000, cost 1500 -> owes 500
    assert by[2]["balance"] == -50000 and by[2]["state"] == "owes"


def test_summary_shape_and_no_money_note():
    s = M.monthly_summary([{"id": 1, "name": "A", "meals": 1}],
                          [{"amount": "10"}], [], lang="bn")
    for k in ("meals_total", "bazar_total", "meal_rate", "meal_rate_display",
              "bazar_total_display", "members", "reconciles", "note"):
        assert k in s, k
    assert "bn" in s["note"] and "en" in s["note"]


def test_summary_is_deterministic():
    members = [{"id": "a", "meals": 7}, {"id": "b", "meals": 11},
               {"id": "c", "meals": 13}]
    bazar = [{"amount": "999.99"}]
    dep = [{"member": "a", "amount": "300"}]
    a = M.monthly_summary(members, bazar, dep, lang="en")
    b = M.monthly_summary(members, bazar, dep, lang="en")
    assert a == b


def test_empty_mess_is_honest():
    s = M.monthly_summary([], [], [], lang="en")
    assert s["meals_total"] == 0
    assert s["bazar_total"] == 0
    assert s["meal_rate"] == 0.0
    assert s["members"] == []
    assert s["reconciles"] is True


# --------------------------------------------------------------- validation

def test_validate_member():
    members = [{"name": "Karim"}]
    assert "name_required" in M.validate_member("  ", members)
    assert "duplicate_name" in M.validate_member("karim", members)  # case-insensitive
    assert M.validate_member("Rahim", members) == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"mess_accounting: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
