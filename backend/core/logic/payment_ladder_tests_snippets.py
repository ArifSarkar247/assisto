"""
payment_ladder_tests_snippets.py — plain-assert tests for the payment / auto-pay
ladder engine. Pure stdlib. `python payment_ladder_tests_snippets.py` or import
and call run_all(). Every `now` is passed in explicitly so the engine is
deterministic and the escalation timing below is hand-verified.

Covered: escalation timing (which rung fires when), stop-on-payment, the
never-hold-money / no-auto-charge invariants, the key-gate that downgrades
`pay_key` → `pay_manual`, integer-poisha with no float drift, recurring roll.
"""

from datetime import date

try:  # Django test harness imports this as core.logic.payment_ladder_tests_snippets
    from core.logic import payment_ladder as L
except ImportError:  # standalone: `python payment_ladder_tests_snippets.py`
    import payment_ladder as L  # noqa: E402


# ---------------------------------------------------------------- fixtures

def _receivable(**over):
    d = {"id": 1, "kind": "receivable", "party": "Rahim",
         "amount_poisha": 60000, "paid_poisha": 0, "due_date": "2026-02-01"}
    d.update(over)
    return d


def _ladder(**over):
    lad = L.default_ladder("receivable")  # offsets 0/3/7/14
    lad.update(over)
    return lad


# ---------------------------------------------------------------- money

def test_to_poisha_no_float_drift():
    assert L.to_poisha({"amount": "600.00"}) == 60000
    assert L.to_poisha({"amount": "99.99"}) == 9999      # exact, no drift
    assert L.to_poisha({"amount": "0.10"}) == 10
    assert L.to_poisha({"amount_poisha": 123, "amount": "9.99"}) == 123  # prefers int
    assert sum(L.to_poisha({"amount": a}) for a in ("0.10", "0.20")) == 30


def test_outstanding_and_is_paid():
    assert L.outstanding_poisha(_receivable()) == 60000
    assert L.outstanding_poisha(_receivable(paid_poisha=20000)) == 40000
    assert L.outstanding_poisha(_receivable(paid_poisha=99999)) == 0   # clamped
    assert L.is_paid(_receivable(paid_poisha=60000)) is True
    assert L.is_paid(_receivable()) is False


# ---------------------------------------------------------------- escalation timing

def test_no_step_before_due():
    # due 1 Feb, now 31 Jan → nothing has fired yet.
    assert L.due_step(_receivable(), _ladder(), date(2026, 1, 31)) is None


def test_step1_on_due_date():
    s = L.due_step(_receivable(), _ladder(), date(2026, 2, 1))  # offset 0
    assert s["step"] == 1 and s["action"] == "remind_gentle", s
    assert s["channel"] == "in_app" and s["days_overdue"] == 0


def test_step2_between_3_and_7_days():
    s = L.due_step(_receivable(), _ladder(), date(2026, 2, 4))  # +3 .. <+7
    assert s["step"] == 2 and s["action"] == "remind_firm", s
    assert s["channel"] == "whatsapp_share" and s["days_overdue"] == 3
    # still step 2 at +6
    assert L.due_step(_receivable(), _ladder(), date(2026, 2, 6))["step"] == 2


def test_step3_final_notice_at_plus_7():
    s = L.due_step(_receivable(), _ladder(), date(2026, 2, 8))  # +7
    assert s["step"] == 3 and s["action"] == "final_notice", s
    assert s["channel"] == "sms" and s["is_final"] is False


def test_step4_escalate_and_is_final():
    s = L.due_step(_receivable(), _ladder(), date(2026, 3, 1))  # well past +14
    assert s["step"] == 4 and s["action"] == "escalate_owner", s
    assert s["is_final"] is True and s["days_overdue"] == 28


def test_highest_rung_supersedes_earlier():
    # at +10 both step1/2/3 have fired, but only step 3 is the current action.
    s = L.due_step(_receivable(), _ladder(), date(2026, 2, 11))
    assert s["step"] == 3, s


def test_next_step_lookahead():
    nx = L.next_step(_receivable(), _ladder(), date(2026, 2, 2))  # step1 fired
    assert nx["step"] == 2 and nx["days_until"] == 2, nx         # step2 at +3 = Feb4
    # after the last rung there is no next step
    assert L.next_step(_receivable(), _ladder(), date(2026, 3, 1)) is None


# ---------------------------------------------------------------- stop-on-payment

def test_stop_on_payment_silences_ladder():
    paid = _receivable(paid_poisha=60000)
    assert L.due_step(paid, _ladder(), date(2026, 3, 1)) is None
    assert L.next_step(paid, _ladder(), date(2026, 3, 1)) is None


def test_partial_payment_keeps_chasing():
    part = _receivable(paid_poisha=20000)  # still 40000 owed
    s = L.due_step(part, _ladder(), date(2026, 3, 1))
    assert s is not None and s["outstanding_poisha"] == 40000, s


def test_stop_on_payment_false_keeps_firing():
    paid = _receivable(paid_poisha=60000)
    lad = _ladder(stop_on_payment=False)
    assert L.due_step(paid, lad, date(2026, 3, 1))["step"] == 4


def test_paused_ladder_is_silent():
    assert L.due_step(_receivable(paused=True), _ladder(), date(2026, 3, 1)) is None


# ---------------------------------------------------------------- honesty gates

def test_never_holds_money_and_no_auto_charge():
    assert L.holds_money() is False
    assert L.charges_money() is False
    s = L.due_step(_receivable(), _ladder(), date(2026, 3, 1))
    assert s["holds_money"] is False and s["charges_money"] is False


def test_pay_key_gated_down_to_manual_without_key():
    # a payable ladder whose last step tries to pay via a key
    lad = {"kind": "payable", "stop_on_payment": True, "has_payment_key": False,
           "steps": [{"offset_days": 0, "action": "pay_key", "channel": "in_app"}]}
    debt = {"id": 2, "kind": "payable", "amount_poisha": 5000, "due_date": "2026-02-01"}
    s = L.due_step(debt, lad, date(2026, 2, 1))
    assert s["action"] == "pay_manual", s           # downgraded (no key)
    assert L.can_execute_pay(lad) is False
    # WITH a key, pay_key survives and execution is permitted
    lad["has_payment_key"] = True
    s2 = L.due_step(debt, lad, date(2026, 2, 1))
    assert s2["action"] == "pay_key" and L.can_execute_pay(lad) is True, s2


def test_resolve_pay_action_passthrough():
    lad = {"has_payment_key": False}
    assert L.resolve_pay_action("remind_firm", lad) == "remind_firm"
    assert L.resolve_pay_action("pay_key", lad) == "pay_manual"
    assert L.resolve_pay_action("pay_key", lad, has_key=True) == "pay_key"


# ---------------------------------------------------------------- payable / before-due

def test_payable_heads_up_before_due():
    debt = {"id": 3, "kind": "payable", "amount_poisha": 120000,
            "due_date": "2026-02-10"}
    lad = L.default_ladder("payable")  # offsets -3/0/3/7
    # 5 days before due → nothing yet (first step is -3)
    assert L.due_step(debt, lad, date(2026, 2, 5)) is None
    # exactly -3 → heads_up
    s = L.due_step(debt, lad, date(2026, 2, 7))
    assert s["step"] == 1 and s["action"] == "heads_up", s
    # on due date → due_today
    assert L.due_step(debt, lad, date(2026, 2, 10))["action"] == "due_today"


# ---------------------------------------------------------------- record payment

def test_record_payment_clamps_and_no_mutation():
    debt = _receivable(paid_poisha=10000)
    out = L.record_payment(debt, 1000000, now=date(2026, 2, 1))  # overpay
    assert out["paid_poisha"] == 60000                           # clamped to amount
    assert debt["paid_poisha"] == 10000                          # input untouched
    assert L.is_paid(out) is True


def test_mark_paid_full_settle():
    out = L.mark_paid(_receivable(paid_poisha=20000), now=date(2026, 2, 1))
    assert L.outstanding_poisha(out) == 0


def test_recurring_bill_rolls_forward_on_full_payment():
    bill = {"id": 4, "kind": "payable", "amount_poisha": 50000,
            "due_date": "2026-02-01", "recurring_days": 30}
    out = L.record_payment(bill, 50000, now=date(2026, 2, 3))
    assert out["due_date"] == "2026-03-03", out   # +30 past the payment date
    assert out["paid_poisha"] == 0                # fresh cycle


# ---------------------------------------------------------------- schedule / builder

def test_schedule_marks_past_due_upcoming():
    sch = L.schedule(_receivable(), _ladder(), now=date(2026, 2, 4))  # step2 current
    statuses = {s["step"]: s["status"] for s in sch}
    assert statuses == {1: "past", 2: "due", 3: "upcoming", 4: "upcoming"}, statuses
    # steps come out sorted by offset
    assert [s["offset_days"] for s in sch] == [0, 3, 7, 14]


def test_schedule_without_now_is_all_upcoming():
    sch = L.schedule(_receivable(), _ladder())
    assert all(s["status"] == "upcoming" for s in sch)


# ---------------------------------------------------------------- validation

def test_validate_ladder():
    assert L.validate_ladder(L.default_ladder("receivable")) == []
    assert "no_steps" in L.validate_ladder({"kind": "receivable", "steps": []})
    assert "bad_kind" in L.validate_ladder({"kind": "wat", "steps": [
        {"offset_days": 0}]})
    assert "duplicate_offset" in L.validate_ladder({"kind": "payable", "steps": [
        {"offset_days": 1}, {"offset_days": 1}]})
    assert "bad_channel" in L.validate_ladder({"kind": "payable", "steps": [
        {"offset_days": 1, "channel": "carrier_pigeon"}]})
    assert "no_auto_charge" in L.validate_ladder({"kind": "payable", "steps": [
        {"offset_days": 0, "action": "auto_charge"}]})


# ---------------------------------------------------------------- summary

def test_summarize_splits_and_sorts():
    r = _receivable(amount_poisha=60000, due_date="2026-02-01")   # due step
    p = {"id": 9, "kind": "payable", "amount_poisha": 20000, "paid_poisha": 5000,
         "due_date": "2026-02-01"}
    lad_r = _ladder()
    lad_p = L.default_ladder("payable")
    out = L.summarize([(r, lad_r), (p, lad_p)], now=date(2026, 2, 4))
    assert out["receivable_outstanding_poisha"] == 60000, out
    assert out["payable_outstanding_poisha"] == 15000, out
    assert out["net_poisha"] == 45000, out
    assert out["holds_money"] is False and out["charges_money"] is False
    assert out["action_count"] >= 1
    # action items sorted by fire_date ascending
    fds = [a["fire_date"] for a in out["action_items"]]
    assert fds == sorted(fds), fds


# ---------------------------------------------------------------- runner

def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"payment_ladder: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
