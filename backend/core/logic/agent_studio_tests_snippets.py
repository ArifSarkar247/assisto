"""
agent_studio_tests_snippets.py — plain-assert tests for the Agent Studio rule
engine. Pure stdlib. `python agent_studio_tests_snippets.py` or import and call
run_all(). Every `now` is passed in explicitly so the engine is deterministic
and the assertions are hand-verified below.
"""

from datetime import datetime

try:  # Django test harness imports this as core.logic.agent_studio_tests_snippets
    from core.logic import agent_studio as A
except ImportError:  # standalone: `python agent_studio_tests_snippets.py`
    import agent_studio as A  # noqa: E402


def _dt(s):
    return datetime.fromisoformat(s)


# ------------------------------------------------------------- schedule trigger

def test_schedule_fires_inside_grace_window():
    tr = {"type": "schedule", "at": "09:00", "days": [1, 2, 3, 4, 5, 6, 7]}
    # exactly on time
    assert A.trigger_fires(tr, _dt("2026-10-14T09:00:00"), {})
    # 4 minutes late (grace 5) still catches it
    assert A.trigger_fires(tr, _dt("2026-10-14T09:04:00"), {})
    # 5 minutes late → window closed (end is exclusive)
    assert not A.trigger_fires(tr, _dt("2026-10-14T09:05:00"), {})
    # a minute early → not yet
    assert not A.trigger_fires(tr, _dt("2026-10-14T08:59:00"), {})


def test_schedule_respects_weekdays():
    tr = {"type": "schedule", "at": "09:00", "days": [1, 2, 3, 4, 5]}  # Mon-Fri
    # 2026-10-14 is a Wednesday (isoweekday 3)
    assert A.trigger_fires(tr, _dt("2026-10-14T09:00:00"), {})
    # 2026-10-17 is a Saturday (isoweekday 6) → excluded
    assert not A.trigger_fires(tr, _dt("2026-10-17T09:00:00"), {})


def test_schedule_day_of_month_clamps_to_month_end():
    tr = {"type": "schedule", "at": "09:00", "day_of_month": 31}
    # November has 30 days → clamps to the 30th
    assert A.trigger_fires(tr, _dt("2026-11-30T09:00:00"), {})
    assert not A.trigger_fires(tr, _dt("2026-11-29T09:00:00"), {})
    # February 2026 (28 days) → clamps to 28th
    assert A.trigger_fires(tr, _dt("2026-02-28T09:00:00"), {})


def test_schedule_bad_time_never_fires():
    assert not A.trigger_fires({"type": "schedule", "at": "99:99"},
                               _dt("2026-10-14T09:00:00"), {})
    assert not A.trigger_fires({"type": "schedule"},
                               _dt("2026-10-14T09:00:00"), {})


# ------------------------------------------------- event / keyword / incoming

def test_event_trigger():
    tr = {"type": "event", "event": "lead_created"}
    assert A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                           {"event": "lead_created"})
    assert not A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                               {"event": "bill_due"})
    assert not A.trigger_fires(tr, _dt("2026-10-14T12:00:00"), {})


def test_keyword_trigger_case_insensitive_bilingual():
    tr = {"type": "keyword", "keywords": ["electricity", "বিদ্যুৎ"]}
    assert A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                           {"text": "ELECTRICITY bill is due"})
    assert A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                           {"text": "আজ বিদ্যুৎ বিল"})
    assert not A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                               {"text": "water bill"})


def test_incoming_trigger():
    tr = {"type": "incoming", "from": "bkash"}
    assert A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                           {"incoming_from": "bKash"})
    assert not A.trigger_fires(tr, _dt("2026-10-14T12:00:00"),
                               {"incoming_from": "nagad"})
    assert not A.trigger_fires(tr, _dt("2026-10-14T12:00:00"), {})


# ------------------------------------------------------------- conditions

def test_condition_numeric_ops():
    ctx = {"amount": 650}
    assert A.eval_condition({"field": "amount", "op": ">=", "value": 500}, ctx)
    assert not A.eval_condition({"field": "amount", "op": ">", "value": 650}, ctx)
    assert A.eval_condition({"field": "amount", "op": "<=", "value": 650}, ctx)
    # string amount coerces
    assert A.eval_condition({"field": "amount", "op": ">", "value": "100"},
                            {"amount": "650.50"})


def test_condition_equality_and_contains():
    ctx = {"category": "utility", "text": "Electricity bill"}
    assert A.eval_condition({"field": "category", "op": "==", "value": "utility"}, ctx)
    assert A.eval_condition({"field": "category", "op": "!=", "value": "food"}, ctx)
    assert A.eval_condition({"field": "text", "op": "contains", "value": "bill"}, ctx)
    assert not A.eval_condition({"field": "text", "op": "contains", "value": "water"}, ctx)


def test_condition_missing_field_is_false():
    assert not A.eval_condition({"field": "amount", "op": ">", "value": 1}, {})


def test_conditions_all_vs_any():
    auto_all = {"conditions": [{"field": "a", "op": "==", "value": "1"},
                               {"field": "b", "op": "==", "value": "2"}],
                "match": "all"}
    assert A.conditions_pass(auto_all, {"a": "1", "b": "2"})
    assert not A.conditions_pass(auto_all, {"a": "1", "b": "X"})
    auto_any = dict(auto_all, match="any")
    assert A.conditions_pass(auto_any, {"a": "1", "b": "X"})
    assert not A.conditions_pass(auto_any, {"a": "X", "b": "X"})
    # empty conditions ⇒ always true
    assert A.conditions_pass({"conditions": []}, {})


# ------------------------------------------------------------- is_due / evaluate

def _bill_auto(**over):
    base = {
        "id": "a1",
        "name": "Bill reminder",
        "enabled": True,
        "triggers": [{"type": "schedule", "at": "09:00", "day_of_month": 5}],
        "conditions": [{"field": "amount", "op": ">=", "value": 500}],
        "actions": [{"type": "remind", "text": "Pay bill"}],
        "last_fired": None,
    }
    base.update(over)
    return base


def test_is_due_disabled_never_fires():
    a = _bill_auto(enabled=False)
    assert not A.is_due(a, _dt("2026-10-05T09:00:00"), {"amount": 999})


def test_is_due_requires_condition():
    a = _bill_auto()
    now = _dt("2026-10-05T09:00:00")
    assert A.is_due(a, now, {"amount": 600})      # trigger + condition
    assert not A.is_due(a, now, {"amount": 100})  # condition fails
    assert not A.is_due(a, _dt("2026-10-06T09:00:00"), {"amount": 600})  # wrong day


def test_is_due_dedupe_within_window():
    a = _bill_auto(last_fired="2026-10-05T09:00:00")
    # polled again 2 min later — already fired this window
    assert not A.is_due(a, _dt("2026-10-05T09:02:00"), {"amount": 600})
    # a fresh day's window is independent
    fresh = _bill_auto(last_fired="2026-09-05T09:00:00")
    assert A.is_due(fresh, _dt("2026-10-05T09:00:00"), {"amount": 600})


def test_evaluate_returns_due_with_plan_and_needs_ai():
    autos = [
        _bill_auto(),  # schedule+condition
        {"id": "a2", "name": "Daily summary", "enabled": True,
         "triggers": [{"type": "schedule", "at": "09:00",
                       "days": [1, 2, 3, 4, 5, 6, 7]}],
         "actions": [{"type": "summarize", "source": "today"}]},
        {"id": "a3", "name": "Off", "enabled": False,
         "triggers": [{"type": "schedule", "at": "09:00",
                       "days": [1, 2, 3, 4, 5, 6, 7]}],
         "actions": [{"type": "log", "text": "x"}]},
    ]
    due = A.evaluate(autos, "2026-10-05T09:00:00", {"amount": 600})
    ids = [d["id"] for d in due]
    assert ids == ["a1", "a2"], ids           # a3 disabled
    a1 = next(d for d in due if d["id"] == "a1")
    a2 = next(d for d in due if d["id"] == "a2")
    assert a1["needs_ai"] is False
    assert a2["needs_ai"] is True             # summarize is AI
    assert a1["actions"][0]["type"] == "remind"


def test_evaluate_event_trigger_no_schedule_no_dedupe():
    a = {"id": "e1", "name": "Follow-up", "enabled": True,
         "triggers": [{"type": "event", "event": "lead_created"}],
         "actions": [{"type": "remind", "text": "Follow up"}],
         "last_fired": "2026-10-14T11:59:00"}  # recent, but event has no dedupe
    due = A.evaluate([a], "2026-10-14T12:00:00", {"event": "lead_created"})
    assert [d["id"] for d in due] == ["e1"]


# ------------------------------------------------------------- plan / mark / ai

def test_plan_actions_flags_ai():
    a = {"actions": [{"type": "remind"}, {"type": "summarize"},
                     {"type": "tool", "tool": "money.summary"}]}
    plan = A.plan_actions(a)
    assert [p["ai_required"] for p in plan] == [False, True, False]
    # summarize is the only AI action in the catalog
    assert A.AI_ACTIONS == ("summarize",)


def test_mark_fired_is_pure():
    a = _bill_auto()
    stamped = A.mark_fired(a, _dt("2026-10-05T09:00:00"))
    assert stamped["last_fired"] == "2026-10-05T09:00:00"
    assert a["last_fired"] is None  # original untouched


# ------------------------------------------------------------- validation

def test_validate_catches_empty_and_bad():
    assert A.validate({}) == ["name_required", "trigger_required", "action_required"]
    bad = {"name": "x",
           "triggers": [{"type": "schedule", "at": "bad"},
                        {"type": "keyword", "keywords": []}],
           "actions": [{"type": "nope"}],
           "conditions": [{"field": "a", "op": "~~", "value": 1}]}
    probs = A.validate(bad)
    assert "bad_time" in probs
    assert "keyword_required" in probs
    assert "bad_action" in probs
    assert "bad_condition" in probs


def test_validate_passes_good():
    good = {"name": "Bill",
            "triggers": [{"type": "schedule", "at": "09:00", "day_of_month": 5}],
            "actions": [{"type": "remind", "text": "pay"}],
            "conditions": [{"field": "amount", "op": ">=", "value": 500}]}
    assert A.validate(good) == []


# ------------------------------------------------------------- templates / describe

def test_templates_are_valid_and_present():
    keys = {t["key"] for t in A.TEMPLATES}
    assert {"bill_reminder", "daily_summary", "follow_up", "birthday_wish"} <= keys
    for t in A.TEMPLATES:
        assert A.validate(t) == [], (t["key"], A.validate(t))


def test_describe_structured_when_if_then():
    a = _bill_auto()
    d = A.describe(a)
    assert d["when"][0]["type"] == "schedule"
    assert d["when"][0]["at"] == "09:00"
    assert d["if"][0] == {"field": "amount", "op": ">=", "value": 500}
    assert d["match"] == "all"
    assert d["then"][0] == {"type": "remind", "ai_required": False}


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"agent_studio: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
