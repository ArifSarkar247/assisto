"""
cost_estimator_tests_snippets.py — plain-assert tests for the COST / TIME
ESTIMATOR (#36, §8). Pure stdlib. `python cost_estimator_tests_snippets.py`
or import and call run_all(). The engine is deterministic (integer poisha),
so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import cost_estimator as E
except ImportError:  # standalone
    import cost_estimator as E  # noqa: E402


# --------------------------------------------------------------- money helpers

def test_to_poisha_rounds_and_floors_negatives():
    assert E.to_poisha("12.34") == 1234
    assert E.to_poisha(10) == 1000
    assert E.to_poisha("1,250.5") == 125050
    assert E.to_poisha(-5) == 0
    assert E.to_poisha("junk") == 0
    assert E.to_poisha("") == 0


def test_taka_str_formats_with_glyph():
    s = E.taka_str(125050)
    assert s.startswith("৳")
    assert "1,250.50" in s
    assert E.taka_str(0) == "৳0.00"


def test_minutes_human_breakdown():
    h = E.minutes_human(1500)  # 25h = 1 day 1h 0m
    assert h == {"days": 1, "hours": 1, "minutes": 0, "total_minutes": 1500}


# --------------------------------------------------------------- validation

def test_validate_no_components():
    assert "no_components" in E.validate([])


def test_validate_all_unnamed():
    comps = [{"qty": 1, "unit_cost": 10}]
    assert "all_unnamed" in E.validate(comps)


def test_validate_bad_contingency():
    comps = [{"name": "x", "qty": 1, "unit_cost": 10}]
    assert "bad_contingency" in E.validate(comps, contingency_pct=200)
    assert E.validate(comps, contingency_pct=10) == []


# --------------------------------------------------------------- component line

def test_component_line_multiplies():
    line = E.component_line({"name": "Bricks", "qty": 3,
                             "unit_cost": "12.50", "minutes": 20})
    assert line["cost_poisha"] == 3 * 1250
    assert line["time_minutes"] == 60
    assert line["qty"] == 3


def test_component_line_blanks_are_zero():
    line = E.component_line({"name": "TBD"})
    assert line["cost_poisha"] == 0
    assert line["time_minutes"] == 0


# --------------------------------------------------------------- estimate

def test_estimate_totals_no_drift():
    comps = [
        {"name": "Labour", "qty": 2, "unit_cost": "500.00", "minutes": 120},
        {"name": "Paint", "qty": 5, "unit_cost": "199.99", "minutes": 0},
    ]
    res = E.estimate(comps)
    # 2×50000 + 5×19999 = 100000 + 99995 = 199995 poisha
    assert res["subtotal_poisha"] == 199995
    assert res["total_poisha"] == 199995   # no contingency
    assert res["total_minutes"] == 240
    assert res["total_taka"] == "৳1,999.95"


def test_estimate_contingency_added():
    comps = [{"name": "Build", "qty": 1, "unit_cost": "1000.00", "minutes": 60}]
    res = E.estimate(comps, contingency_pct=10)
    assert res["subtotal_poisha"] == 100000
    assert res["contingency_poisha"] == 10000   # 10%
    assert res["total_poisha"] == 110000
    assert res["contingency_pct"] == 10


def test_estimate_band_brackets_total():
    comps = [{"name": "x", "qty": 1, "unit_cost": "1000.00", "minutes": 0}]
    res = E.estimate(comps)
    assert res["band"]["low_poisha"] <= res["total_poisha"]
    assert res["band"]["high_poisha"] >= res["total_poisha"]


def test_estimate_shape_and_honest_flags():
    res = E.estimate([{"name": "x", "qty": 1, "unit_cost": 10, "minutes": 5}])
    for k in ("lines", "subtotal_poisha", "contingency_pct",
              "contingency_poisha", "total_poisha", "total_taka",
              "total_minutes", "time_human", "band", "component_count",
              "ai_required", "mock", "disclaimer", "marker", "problems"):
        assert k in res, k
    assert res["ai_required"] is False
    assert res["mock"] is True
    assert res["disclaimer"] is True
    assert res["marker"] == E.MARKER_KEY
    assert res["problems"] == []


def test_estimate_is_deterministic():
    comps = [{"name": "a", "qty": 3, "unit_cost": "9.99", "minutes": 7}]
    assert E.estimate(comps, 15) == E.estimate(comps, 15)


# --------------------------------------------------------------- AI seam

def test_ai_estimate_plan_key_gated_and_heuristic():
    comps = [{"name": "A", "qty": 1, "unit_cost": "100.00", "minutes": 60},
             {"name": "B", "qty": 1, "unit_cost": "200.00", "minutes": 120}]
    plan = E.ai_estimate_plan("unknown extra work", comps)
    assert plan["ai_required"] is True
    assert plan["ai_integration"] == "anthropic"
    assert plan["mock"] is True
    assert plan["disclaimer"] is True
    assert plan["basis"] == "known_average"
    # avg unit = (10000 + 20000)//2 = 15000 ; band ±40%
    assert plan["rough"]["low_poisha"] == 9000
    assert plan["rough"]["high_poisha"] == 21000
    assert plan["rough"]["low_minutes"] == 54    # 90×0.6
    assert plan["rough"]["high_minutes"] == 126  # 90×1.4


def test_ai_estimate_plan_no_basis_when_empty():
    plan = E.ai_estimate_plan("mystery", [])
    assert plan["basis"] == "none"
    assert plan["rough"]["low_poisha"] == 0
    assert plan["ai_required"] is True


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"cost_estimator: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
