"""
Hand-verified tests for logic_team.py — PURE PYTHON, no Django, no DB, no clock.

Run directly:  python backend/crm/logic_team_tests_snippets.py
or from a shell: python -c "from crm.logic_team_tests_snippets import run_all; run_all()"

Every assertion is checked by hand in the comment next to it. Commission has NO
baked numbers — all tests FEED the rate/tiers in as owner config, and the
"no config" cases assert the explicit OWNER_MUST_SET placeholder.
"""
from decimal import Decimal

from .logic_team import (round_robin_pick, route_by_rules, target_progress,
                         commission, leaderboard, OWNER_MUST_SET)


def _eq(a, b, msg=""):
    assert a == b, f"{msg}: expected {b!r}, got {a!r}"


def test_round_robin():
    members = [10, 20, 30]
    # cursor 0 → start AFTER index 0 → index1 (id 20). Hand: next after 0 is 1.
    r = round_robin_pick(members, cursor=0, count=1)
    _eq(r["picks"], [20], "rr first pick"); _eq(r["cursor"], 1, "rr cursor")
    # Continue from cursor 1 → index2 (id 30).
    r = round_robin_pick(members, cursor=1, count=1)
    _eq(r["picks"], [30], "rr second")
    # From cursor 2 → wraps to index0 (id 10). Fair wrap-around.
    r = round_robin_pick(members, cursor=2, count=1)
    _eq(r["picks"], [10], "rr wrap")
    # Batch of 3 from cursor 2: 10,20,30 (full fair round).
    r = round_robin_pick(members, cursor=2, count=3)
    _eq(r["picks"], [10, 20, 30], "rr batch")
    _eq(r["cursor"], 2, "rr batch cursor back to 2")
    # Skip id 20 (on leave): from cursor 0 we step over 20 to 30.
    r = round_robin_pick(members, cursor=0, count=1, skip_ids=[20])
    _eq(r["picks"], [30], "rr skip")
    # Empty roster is safe.
    _eq(round_robin_pick([], cursor=5)["picks"], [], "rr empty")
    # All skipped → no picks, cursor unchanged.
    _eq(round_robin_pick(members, cursor=0, skip_ids=[10, 20, 30])["picks"], [],
        "rr all skipped")
    # Deterministic: same inputs → same output.
    _eq(round_robin_pick(members, 0, 2), round_robin_pick(members, 0, 2), "rr det")


def test_router():
    rules = [
        {"id": 1, "order": 1, "match_industry": "rmg", "assign_to": 7},
        {"id": 2, "order": 2, "match_source": "whatsapp", "assign_to": 8},
        {"id": 3, "order": 3, "min_company_size": 100, "assign_to": 9,
         "territory": 4},
        {"id": 9, "order": 0, "active": False, "match_industry": "rmg",
         "assign_to": 99},  # inactive, would win on order but skipped
    ]
    # rmg lead → rule 1 (rule 9 inactive even though order 0).
    r = route_by_rules(rules, industry="rmg")
    _eq(r["assign_to"], 7, "router rmg"); _eq(r["matched_rule"], 1, "router id")
    # non-rmg whatsapp → rule 2.
    r = route_by_rules(rules, industry="other", source="whatsapp")
    _eq(r["assign_to"], 8, "router wa")
    # big company, no earlier match → rule 3 w/ territory.
    r = route_by_rules(rules, industry="other", source="manual", company_size=500)
    _eq(r["assign_to"], 9, "router size"); _eq(r["territory"], 4, "router terr")
    # small company, no match → fall through.
    r = route_by_rules(rules, industry="other", source="manual", company_size=5)
    _eq(r["assign_to"], None, "router miss")
    _eq(r["reason"], "no_rule_matched", "router miss reason")
    # region match (normalised case/space).
    rr = [{"id": 1, "match_region": "Dhaka", "assign_to": 3}]
    _eq(route_by_rules(rr, region="  dhaka ")["assign_to"], 3, "router region")


def test_target_progress():
    # Owner set 1,000,000; won 250,000 → 25.0%.
    r = target_progress(1000000, 250000)
    _eq(r["pct"], 25.0, "target pct"); _eq(r["target_set"], True, "target set")
    _eq(r["remaining"], "750000.00", "target remaining")
    _eq(r["attained"], False, "target not attained")
    # Hit target.
    r = target_progress(1000000, 1000000)
    _eq(r["attained"], True, "target attained")
    # NO target set → explicit placeholder, no fake 0%.
    r = target_progress(0, 500000)
    _eq(r["target_set"], False, "no target set")
    _eq(r["pct"], None, "no target pct"); _eq(r["note"], OWNER_MUST_SET, "note")
    # Pace: halfway through month (day 15 of 30), won 600k of 1M target.
    r = target_progress(1000000, 600000, day_of_period=15, days_in_period=30)
    _eq(r["expected_by_now"], "500000.00", "pace expected")
    _eq(r["on_pace"], True, "pace ahead")       # 600k >= 500k
    _eq(r["pace_gap"], "100000.00", "pace gap")  # +100k ahead
    # deals target.
    r = target_progress(0, 0, deals_target=10, deals_won=4)
    _eq(r["deals_pct"], 40.0, "deals pct"); _eq(r["target_set"], True, "deals set")


def test_commission():
    # --- NO config → placeholder, zero payout (NO baked rate) ---
    r = commission(1000000, None)
    _eq(r["config_set"], False, "comm no config"); _eq(r["payout"], "0.00", "comm zero")
    _eq(r["note"], OWNER_MUST_SET, "comm placeholder")
    _eq(commission(1000000, {"kind": "none"})["config_set"], False, "comm none")
    # --- flat % (owner supplies 5%) ---
    r = commission(1000000, {"kind": "flat", "flat_pct": 5})
    _eq(r["payout"], "50000.00", "comm flat")  # 5% of 1,000,000 = 50,000
    _eq(r["config_set"], True, "comm flat set")
    # flat with 0% → treated as unset (owner must set a real rate).
    _eq(commission(1000000, {"kind": "flat", "flat_pct": 0})["config_set"],
        False, "comm flat zero unset")
    # --- tiered (marginal): 2% up to 500k, 5% above. On 1,000,000:
    #     500k@2% = 10,000 + 500k@5% = 25,000 = 35,000 ---
    cfg = {"kind": "tiered", "tiers": [{"upto": 500000, "pct": 2},
                                       {"upto": None, "pct": 5}]}
    r = commission(1000000, cfg)
    _eq(r["payout"], "35000.00", "comm tiered")
    _eq(len(r["breakdown"]), 2, "comm tiered bands")
    # tiered but won below first ceiling: 300k all @2% = 6,000.
    _eq(commission(300000, cfg)["payout"], "6000.00", "comm tiered low")
    # empty tiers → unset.
    _eq(commission(1000000, {"kind": "tiered", "tiers": []})["config_set"],
        False, "comm tiered empty unset")
    # --- per-deal bonus on top: flat 5% + 1,000/deal * 3 deals ---
    r = commission(1000000, {"kind": "flat", "flat_pct": 5,
                             "per_deal_bonus": 1000}, deals_won=3)
    _eq(r["payout"], "53000.00", "comm bonus")  # 50,000 + 3,000


def test_leaderboard():
    rows = [
        {"member_id": 1, "name": "A", "calls": 10, "meetings": 2, "proposals": 1,
         "deals_won": 1},
        {"member_id": 2, "name": "B", "calls": 5, "meetings": 5, "proposals": 2,
         "deals_won": 2},
        {"member_id": 3, "name": "C", "calls": 5, "meetings": 5, "proposals": 2,
         "deals_won": 2},
    ]
    # default weights: calls1 meet3 prop5 won10.
    # A = 10 + 6 + 5 + 10 = 31
    # B = 5 + 15 + 10 + 20 = 50 ; C identical = 50 (tie)
    lb = leaderboard(rows)
    _eq(lb[0]["member_id"], 2, "lb top is B (lower id on tie)")
    _eq(lb[0]["score"], 50, "lb B score")
    _eq(lb[0]["rank"], 1, "lb B rank")
    _eq(lb[1]["member_id"], 3, "lb C second")
    _eq(lb[1]["rank"], 1, "lb tie shares rank 1")
    _eq(lb[2]["member_id"], 1, "lb A last")
    _eq(lb[2]["rank"], 3, "lb dense rank jumps to 3 after a tie")
    # owner custom weights (only count calls) → A(10) beats B/C(5).
    lb = leaderboard(rows, weights={"calls": 1})
    _eq(lb[0]["member_id"], 1, "lb custom weights A top")
    # deterministic.
    _eq(leaderboard(rows), leaderboard(rows), "lb deterministic")


def run_all():
    tests = [test_round_robin, test_router, test_target_progress,
             test_commission, test_leaderboard]
    count = 0
    for t in tests:
        t()
        count += 1
    print(f"logic_team: {count} test groups passed "
          f"(round-robin, router, targets, commission[config-driven], leaderboard)")
    return count


if __name__ == "__main__":
    run_all()
