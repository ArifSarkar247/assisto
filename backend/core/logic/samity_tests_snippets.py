"""
samity_tests_snippets.py — plain-assert tests for the SAMITY / COMMITTEE tracker
(#184, §20, built to §21 ADVANCED). Pure stdlib. Run standalone
(`python samity_tests_snippets.py`) or import and call run_all(). The engine is
deterministic + holds no money, so every assertion is hand-verified.
"""

try:  # Django harness: core.logic.samity_tests_snippets
    from core.logic import samity as S
except ImportError:  # standalone
    import samity as S  # noqa: E402


def _samity():
    return {
        "id": 1, "name": "Office Samity", "amount_poisha": 50000,
        "period": "monthly",
        "members": [
            {"id": 3, "name": "Karim", "payout_order": 2, "active": True},
            {"id": 1, "name": "Rahim", "payout_order": 1, "active": True},
            {"id": 2, "name": "Sumi", "payout_order": 3, "active": True},
        ],
    }


# ----------------------------------------------------------------- honesty
def test_never_holds_or_charges_money():
    assert S.holds_money() is False
    assert S.charges_money() is False
    ov = S.overview(_samity(), [], [])
    assert ov["holds_money"] is False and ov["charges_money"] is False


# ----------------------------------------------------------------- amounts
def test_to_poisha_no_float_drift():
    assert S.to_poisha("500") == 50000
    assert S.to_poisha("500.50") == 50050
    assert S.to_poisha("0.1") == 10
    assert S.to_poisha("garbage") == 0
    assert S.to_poisha(None) == 0


def test_amount_poisha_preferred_over_taka():
    s = {"amount_poisha": 12345, "amount": "999"}
    assert S._member_amount(s) == 12345
    assert S._member_amount({"amount": "12.34"}) == 1234


# ----------------------------------------------------------------- members
def test_active_members_sorted_by_payout_order_then_id():
    mem = S.active_members(_samity())
    assert [m["name"] for m in mem] == ["Rahim", "Karim", "Sumi"]


def test_inactive_members_excluded():
    s = _samity()
    s["members"].append({"id": 9, "name": "Old", "payout_order": 4,
                         "active": False})
    assert all(m["name"] != "Old" for m in S.active_members(s))


def test_rotation_is_deterministic_and_one_per_member():
    rot = S.rotation(_samity())
    assert [r["cycle"] for r in rot] == [1, 2, 3]
    assert [r["name"] for r in rot] == ["Rahim", "Karim", "Sumi"]
    assert S.rotation(_samity()) == rot  # same inputs → same output
    assert S.total_cycles(_samity()) == 3


def test_recipient_for_cycle_and_out_of_range():
    assert S.recipient_for_cycle(_samity(), 1)["name"] == "Rahim"
    assert S.recipient_for_cycle(_samity(), 3)["name"] == "Sumi"
    assert S.recipient_for_cycle(_samity(), 0) is None
    assert S.recipient_for_cycle(_samity(), 4) is None


# ----------------------------------------------------------------- validate
def test_validate_ok_and_each_problem():
    assert S.validate(_samity()) == []
    assert "name_required" in S.validate({**_samity(), "name": "  "})
    assert "amount_required" in S.validate({**_samity(), "amount_poisha": 0})
    assert "bad_period" in S.validate({**_samity(), "period": "daily"})
    assert "need_two_members" in S.validate(
        {**_samity(), "members": [{"id": 1, "name": "A", "active": True}]})


# ----------------------------------------------- per-cycle contributions
def test_cycle_status_reconciles_expected_collected_pending():
    contribs = [
        {"member_id": 1, "cycle": 1, "paid": True},
        {"member_id": 3, "cycle": 1, "paid_poisha": 20000},  # partial
        # Sumi (id 2) has not paid
    ]
    cs = S.cycle_status(_samity(), contribs, 1)
    assert cs["expected_poisha"] == 150000      # 3 members * 50000
    assert cs["collected_poisha"] == 70000      # 50000 + 20000 + 0
    assert cs["pending_poisha"] == 80000
    assert cs["expected_poisha"] == cs["collected_poisha"] + cs["pending_poisha"]
    assert cs["paid_count"] == 1                # only Rahim fully paid
    assert cs["pending_count"] == 2


def test_cycle_status_partial_not_counted_as_paid():
    contribs = [{"member_id": 1, "cycle": 1, "paid_poisha": 49999}]
    cs = S.cycle_status(_samity(), contribs, 1)
    rahim = [m for m in cs["members"] if m["member_id"] == 1][0]
    assert rahim["paid"] is False
    assert rahim["due_poisha"] == 1


def test_overpay_clamped_to_contribution():
    contribs = [{"member_id": 1, "cycle": 1, "paid_poisha": 99999}]
    cs = S.cycle_status(_samity(), contribs, 1)
    rahim = [m for m in cs["members"] if m["member_id"] == 1][0]
    assert rahim["paid_poisha"] == 50000  # never exceeds the per-member amount


# --------------------------------------------------------------- payouts
def test_payout_status_scheduled_vs_recorded():
    contribs = [{"member_id": mid, "cycle": 1, "paid": True}
                for mid in (1, 2, 3)]
    payouts = [{"cycle": 1, "member_id": 1, "handed_over": True}]
    ps = S.payout_status(_samity(), contribs, payouts, 1)
    assert ps["scheduled"]["name"] == "Rahim"
    assert ps["recorded_member_id"] == 1
    assert ps["handed_over"] is True
    assert ps["fully_collected"] is True
    assert ps["payable_poisha"] == 150000


def test_next_turn_skips_already_received_then_round_complete():
    payouts = [{"cycle": 1, "member_id": 1, "handed_over": True}]
    nxt = S.next_turn(_samity(), payouts)
    assert nxt["name"] == "Karim"
    all_done = [{"cycle": i + 1, "member_id": mid, "handed_over": True}
                for i, mid in enumerate((1, 3, 2))]
    assert S.next_turn(_samity(), all_done) is None  # honest round-complete


# --------------------------------------------------------------- overview
def test_overview_totals_and_received_ids():
    contribs = []
    for cy in (1, 2):
        for mid in (1, 2, 3):
            contribs.append({"member_id": mid, "cycle": cy, "paid": True})
    payouts = [
        {"cycle": 1, "member_id": 1, "handed_over": True},
        {"cycle": 2, "member_id": 3, "handed_over": True},
    ]
    ov = S.overview(_samity(), contribs, payouts)
    assert ov["total_cycles"] == 3
    assert ov["total_expected_poisha"] == 50000 * 3 * 3  # per*members*cycles
    assert ov["total_collected_poisha"] == 50000 * 3 * 2  # 2 cycles fully paid
    assert ov["total_pending_poisha"] == 50000 * 3 * 1
    assert ov["payouts_done"] == 2
    assert sorted(ov["received_member_ids"]) == [1, 3]
    assert ov["problems"] == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"samity: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
