"""
qurbani_tests_snippets.py — plain-assert tests for the QURBANI planner (#190,
§20). Pure stdlib, deterministic. `python qurbani_tests_snippets.py` or import
and call run_all(). Every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import qurbani as Q
except ImportError:  # standalone
    import qurbani as Q  # noqa: E402


# --------------------------------------------------------------- money fmt

def test_to_poisha_rounds_and_handles_junk():
    assert Q.to_poisha("100") == 10000
    assert Q.to_poisha("1,250.50") == 125050
    assert Q.to_poisha("0.005") == 1          # round half up
    assert Q.to_poisha("abc") == 0
    assert Q.to_poisha(None) == 0


def test_fmt_poisha_taka_sign_and_grouping():
    assert Q.fmt_poisha(10000) == "৳100.00"
    assert Q.fmt_poisha(12505000) == "৳1,25,050.00"  # lakh grouping
    assert Q.fmt_poisha(-5000) == "-৳50.00"


# --------------------------------------------------------------- shares

def test_max_shares_small_vs_large():
    assert Q.max_shares("cow") == 7
    assert Q.max_shares("goat") == 1
    assert Q.max_shares("GOAT") == 1
    assert Q.max_shares("unknown") == 7  # default large


def test_cost_per_share_no_drift_display():
    # ৳70,000 cow, 7 shares -> ৳10,000 each
    assert Q.cost_per_share("70000", 7) == 1000000
    # 0 shares -> 0, not error
    assert Q.cost_per_share("70000", 0) == 0


def test_participant_costs_sum_exactly_to_taken_portion():
    # cow ৳70,001, 7 shares. 3 people take 1,2,1 = 4 shares.
    parts = [{"name": "A", "shares": 1},
             {"name": "B", "shares": 2},
             {"name": "C", "shares": 1}]
    rows = Q.participant_costs("70001", 7, parts)
    total_taken = sum(r["cost"] for r in rows)
    # 4/7 of 7000100 poisha, distributed with no drift
    taken_cost = Q._largest_remainder(7000100, [4, 3])[0]
    assert total_taken == taken_cost
    # B (2 shares) gets roughly double A (1 share)
    cost = {r["name"]: r["cost"] for r in rows}
    assert cost["B"] >= cost["A"]


def test_participant_costs_full_animal_sums_to_cost():
    parts = [{"name": f"P{i}", "shares": 1} for i in range(7)]
    rows = Q.participant_costs("70000", 7, parts)
    assert sum(r["cost"] for r in rows) == 7000000  # exactly the full cost


# --------------------------------------------------------------- validation

def test_validate_plan_codes():
    assert Q.validate_plan({"animal": "cow", "total_shares": 7,
                            "cost": "70000"}) == []
    assert "bad_animal" in Q.validate_plan({"animal": "tiger", "cost": "1"})
    assert "cost_required" in Q.validate_plan({"animal": "cow", "cost": "0"})
    assert "bad_total_shares" in Q.validate_plan(
        {"animal": "goat", "total_shares": 7, "cost": "5000"})


def test_validate_participant_codes():
    assert Q.validate_participant({"name": "A", "shares": 1}, 3) == []
    assert "name_required" in Q.validate_participant({"shares": 1}, 3)
    assert "shares_min_one" in Q.validate_participant({"name": "A", "shares": 0}, 3)
    assert "not_enough_shares" in Q.validate_participant(
        {"name": "A", "shares": 4}, 3)


# --------------------------------------------------------------- meat split

def test_distribute_meat_equal_thirds_sum_exactly():
    # 10,000 g equal thirds -> parts sum to exactly 10000
    parts = Q.distribute_meat(10000)
    assert sum(p["grams"] for p in parts) == 10000
    names = [p["part"] for p in parts]
    assert names == ["family", "relatives", "poor"]
    # largest-remainder: leftover 1g to first part
    assert parts[0]["grams"] == 3334
    assert parts[1]["grams"] == 3333
    assert parts[2]["grams"] == 3333


def test_distribute_meat_custom_weights_dict():
    parts = Q.distribute_meat(12000, {"family": 2, "relatives": 1, "poor": 1})
    g = {p["part"]: p["grams"] for p in parts}
    assert sum(g.values()) == 12000
    assert g["family"] == 6000
    assert g["relatives"] == 3000 and g["poor"] == 3000


def test_distribute_meat_zero():
    parts = Q.distribute_meat(0)
    assert sum(p["grams"] for p in parts) == 0


# --------------------------------------------------------------- checklist

def test_checklist_progress():
    p = Q.checklist_progress(["animal_chosen", "shares_filled"])
    assert p["total"] == len(Q.CHECKLIST_STEPS)
    assert p["done"] == 2
    assert p["complete"] is False
    full = Q.checklist_progress(list(Q.CHECKLIST_STEPS))
    assert full["complete"] is True and full["pct"] == 100
    # unknown keys ignored
    assert Q.checklist_progress(["nonsense"])["done"] == 0


# --------------------------------------------------------------- summary

def test_plan_summary_deterministic_and_honest():
    plan = {"animal": "cow", "total_shares": 7, "cost": "70000",
            "meat_kg": 120, "done": ["animal_chosen"]}
    parts = [{"name": "A", "shares": 2}, {"name": "B", "shares": 1}]
    a = Q.plan_summary(plan, parts, "en")
    b = Q.plan_summary(plan, parts, "en")
    assert a == b
    assert a["shares_taken"] == 3
    assert a["shares_free"] == 4
    assert a["full"] is False
    assert a["cost_per_share_display"] == "৳10,000.00"
    assert a["meat_total_kg_display"] == "120.00 kg"
    assert sum(p["grams"] for p in a["meat_plan"]) == 120000
    assert "bn" in a["note"] and "en" in a["note"]


def test_plan_summary_clamps_shares_to_animal_cap():
    # goat has max 1 share even if a bad total is stored
    plan = {"animal": "goat", "total_shares": 7, "cost": "8000"}
    s = Q.plan_summary(plan, [{"name": "A", "shares": 1}], "bn")
    assert s["total_shares"] == 1
    assert s["max_shares"] == 1
    assert s["full"] is True


def run_all():
    import sys
    g = globals()
    fns = [v for k, v in g.items() if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"qurbani: {len(fns)} tests passed")


if __name__ == "__main__":
    run_all()
