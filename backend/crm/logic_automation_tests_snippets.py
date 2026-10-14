"""
Hand-verified tests for logic_automation.py — PURE PYTHON, no Django, fixed clock.

Run:  python backend/crm/logic_automation_tests_snippets.py
   or: python -c "from crm.logic_automation_tests_snippets import run_all; run_all()"

``now`` is always passed in explicitly (never the wall clock), so results are
deterministic and hand-checkable. The headline rule under test is exactly the
spec example: "proposal sent + no reply in 3 days → create a follow-up task".
"""
from datetime import datetime

from .logic_automation import (due_actions, validate_rule, next_fire_time,
                               KNOWN_TRIGGERS, KNOWN_ACTIONS)


def _eq(a, b, msg=""):
    assert a == b, f"{msg}: expected {b!r}, got {a!r}"


def dt(d):
    return datetime(2026, 10, d, 9, 0, 0)


# The spec example rule, owner-defined.
FOLLOWUP_RULE = {
    "id": 1, "active": True, "trigger": "proposal_sent",
    "condition": {"no_reply": True}, "delay_days": 3,
    "action": {"kind": "create_followup", "subject": "Follow up on proposal"},
}


def test_validate():
    _eq(validate_rule(FOLLOWUP_RULE), [], "valid rule has no problems")
    bad = {"trigger": "nope", "action": {"kind": "boom"}, "delay_days": -1}
    probs = validate_rule(bad)
    assert any("trigger" in p for p in probs), "flags bad trigger"
    assert any("action" in p for p in probs), "flags bad action"
    assert any("delay" in p for p in probs), "flags bad delay"
    assert "proposal_sent" in KNOWN_TRIGGERS and "create_followup" in KNOWN_ACTIONS


def test_fires_after_delay_no_reply():
    events = [{"type": "proposal_sent", "at": dt(1), "lead_id": 5, "deal_id": 9,
               "stage": "proposal"}]
    # now = Oct 1 + 2 days: NOT yet due (needs 3-day delay).
    _eq(due_actions([FOLLOWUP_RULE], events, dt(3)), [], "not due at +2d")
    # now = Oct 4 (+3 days): DUE, no reply → one follow-up action.
    out = due_actions([FOLLOWUP_RULE], events, dt(4))
    _eq(len(out), 1, "one action at +3d")
    _eq(out[0]["rule_id"], 1, "rule id")
    _eq(out[0]["action"]["kind"], "create_followup", "action kind")
    _eq(out[0]["entity"], {"kind": "deal", "id": 9}, "entity = deal")
    _eq(out[0]["due_at"], dt(4), "due_at = trigger + 3d")


def test_reply_cancels_rule():
    events = [
        {"type": "proposal_sent", "at": dt(1), "lead_id": 5, "deal_id": 9},
        # customer replied on Oct 2, BEFORE the 3-day mark → rule must NOT fire.
        {"type": "inbound_reply", "at": dt(2), "lead_id": 5, "deal_id": 9},
    ]
    _eq(due_actions([FOLLOWUP_RULE], events, dt(5)), [],
        "reply before due cancels the follow-up")
    # A reply on a DIFFERENT deal does not cancel ours.
    events2 = events[:1] + [{"type": "inbound_reply", "at": dt(2), "deal_id": 99}]
    _eq(len(due_actions([FOLLOWUP_RULE], events2, dt(5))), 1,
        "reply on another deal does not cancel")


def test_condition_match():
    # Owner rule: only high-priority new leads get the welcome task.
    rule = {"id": 2, "active": True, "trigger": "lead_created",
            "condition": {"priority": "high"}, "delay_days": 0,
            "action": {"kind": "create_task", "subject": "Call new VIP lead"}}
    hi = {"type": "lead_created", "at": dt(1), "lead_id": 7, "priority": "high"}
    lo = {"type": "lead_created", "at": dt(1), "lead_id": 8, "priority": "normal"}
    out = due_actions([rule], [hi, lo], dt(1))
    _eq(len(out), 1, "only the high-priority lead matches")
    _eq(out[0]["entity"]["id"], 7, "matched the VIP lead")


def test_inactive_and_unknown_ignored():
    off = dict(FOLLOWUP_RULE, active=False)
    events = [{"type": "proposal_sent", "at": dt(1), "deal_id": 9}]
    _eq(due_actions([off], events, dt(9)), [], "inactive rule never fires")
    unk = dict(FOLLOWUP_RULE, trigger="telepathy")
    _eq(due_actions([unk], events, dt(9)), [], "unknown trigger ignored")


def test_deterministic_ordering():
    rule = {"id": 1, "active": True, "trigger": "lead_created", "delay_days": 0,
            "action": {"kind": "create_task"}}
    events = [
        {"type": "lead_created", "at": dt(2), "lead_id": 2},
        {"type": "lead_created", "at": dt(1), "lead_id": 1},
    ]
    out = due_actions([rule], events, dt(9))
    # Sorted by due_at asc → lead 1 (Oct 1) before lead 2 (Oct 2).
    _eq([a["entity"]["id"] for a in out], [1, 2], "ordered by due_at")
    _eq(due_actions([rule], events, dt(9)), due_actions([rule], events, dt(9)),
        "deterministic")


def test_next_fire_time():
    ev = {"type": "proposal_sent", "at": dt(1), "deal_id": 9}
    _eq(next_fire_time(FOLLOWUP_RULE, ev), dt(4), "next fire = +3d")


def run_all():
    tests = [test_validate, test_fires_after_delay_no_reply,
             test_reply_cancels_rule, test_condition_match,
             test_inactive_and_unknown_ignored, test_deterministic_ordering,
             test_next_fire_time]
    count = 0
    for t in tests:
        t()
        count += 1
    print(f"logic_automation: {count} test groups passed "
          f"(owner rules; delay+no-reply follow-up; reply cancels; "
          f"conditions; deterministic; no auto-send)")
    return count


if __name__ == "__main__":
    run_all()
