"""
OWNER AUTOMATION RULES (CRM spec #11) — PURE PYTHON, no Django imports.

The owner creates rules like:
    "proposal sent + no reply in 3 days → create a follow-up task"

A rule is an OWNER-DEFINED record. This module has NO hidden behaviour: it does
exactly what the owner's rule says, nothing more. The evaluator is deterministic
— it takes the events, the rules, and an explicit ``now`` (never the wall clock)
and returns the actions that are DUE. The views layer is what actually performs
the actions (create a task, send a draft, etc.); this module only decides what
should happen and when.

Rule schema (owner-defined):
  {
    "id": <int>,
    "active": true,
    "trigger": "proposal_sent" | "deal_stage_changed" | "lead_created" | ...,
    "condition": {                      # OPTIONAL, all must hold (AND)
        "no_reply": true,               # no inbound event since the trigger
        "stage": "proposal",            # trigger event's stage equals this
        "priority": "high",             # lead/deal priority equals this
        ... any field compared to the trigger event payload ...
    },
    "delay_days": 3,                    # fire this many days AFTER the trigger
    "action": {
        "kind": "create_task" | "create_followup" | "notify" | "draft_message",
        "subject": "...", "body": "...", "channel": "...", ...
    }
  }

Events (fed in from the Activity / audit timeline) are dicts:
  {"type": "proposal_sent", "at": <aware/naive datetime>, "lead_id": 5,
   "deal_id": 9, "stage": "proposal", "priority": "high", ...}
Plus inbound signals, e.g. {"type": "inbound_reply", "at": ..., "lead_id": 5}.

There is NO auto-send: a rule can only DRAFT a message or CREATE a task/notice.
The owner always reviews. Nothing here reaches a customer on its own.
"""
from __future__ import annotations

from datetime import timedelta


# Triggers the engine understands. Owner rules must use one of these; an unknown
# trigger is ignored (never guessed). The view can expose this list in the UI.
KNOWN_TRIGGERS = {
    "lead_created",
    "proposal_sent",
    "deal_stage_changed",
    "deal_won",
    "deal_lost",
    "no_activity",        # trigger event is the LAST activity on the entity
    "task_overdue",
}

# Actions a rule may request. All are review-first; none auto-send.
KNOWN_ACTIONS = {
    "create_task",
    "create_followup",
    "notify",
    "draft_message",
}

# Inbound/reply event types that count as "the customer replied" — used by the
# ``no_reply`` condition to cancel a rule if the customer already responded.
REPLY_TYPES = {"inbound_reply", "inbound_message", "reply", "whatsapp_in"}


def validate_rule(rule):
    """Return a list of human-readable problems with an owner-defined rule, or an
    empty list if it is well-formed. Pure validation — does not raise."""
    problems = []
    if rule.get("trigger") not in KNOWN_TRIGGERS:
        problems.append(f"unknown trigger: {rule.get('trigger')!r}")
    action = rule.get("action") or {}
    if action.get("kind") not in KNOWN_ACTIONS:
        problems.append(f"unknown action kind: {action.get('kind')!r}")
    delay = rule.get("delay_days", 0)
    if not isinstance(delay, (int, float)) or delay < 0:
        problems.append("delay_days must be a number >= 0")
    return problems


def _entity_key(ev):
    """Identify which record an event is about (deal preferred, else lead)."""
    if ev.get("deal_id") is not None:
        return ("deal", ev["deal_id"])
    if ev.get("lead_id") is not None:
        return ("lead", ev["lead_id"])
    return ("", None)


def _condition_holds(condition, trigger_ev, events, trigger_key):
    """Check a rule's condition against the trigger event + the full timeline.
    All keys are ANDed. Unknown keys fall back to an equality check against the
    trigger event payload (so the owner can match any field we surfaced)."""
    for key, want in (condition or {}).items():
        if key == "no_reply":
            # True → there must be NO reply event on the same entity AFTER the
            # trigger. (If want is False, this condition is a no-op.)
            if not want:
                continue
            t_at = trigger_ev.get("at")
            replied = any(
                e.get("type") in REPLY_TYPES
                and _entity_key(e) == trigger_key
                and e.get("at") is not None
                and (t_at is None or e["at"] > t_at)
                for e in events
            )
            if replied:
                return False
        else:
            if trigger_ev.get(key) != want:
                return False
    return True


def due_actions(rules, events, now):
    """Core evaluator. Deterministic given (rules, events, now).

    For every ACTIVE rule and every event matching the rule's trigger, fire the
    action once the delay has elapsed (``trigger.at + delay_days <= now``) AND
    the condition still holds (e.g. the customer hasn't replied yet). Returns an
    ordered list of due-action dicts:
      {"rule_id", "trigger_event", "entity", "due_at", "action"}

    No side effects: the caller performs/persists the actions and should record
    that it did so (e.g. a fired-marker) to stay idempotent across runs — this
    function intentionally has no memory, so it is pure and testable.
    """
    out = []
    # Index events by trigger type for a stable, deterministic pass.
    for rule in rules:
        if not rule.get("active", True):
            continue
        if rule.get("trigger") not in KNOWN_TRIGGERS:
            continue
        trig = rule["trigger"]
        delay = timedelta(days=float(rule.get("delay_days", 0) or 0))
        action = rule.get("action") or {}
        for ev in events:
            if ev.get("type") != trig:
                continue
            at = ev.get("at")
            if at is None:
                continue
            due_at = at + delay
            if due_at > now:
                continue  # not yet due
            key = _entity_key(ev)
            if not _condition_holds(rule.get("condition"), ev, events, key):
                continue
            out.append({
                "rule_id": rule.get("id"),
                "trigger_event": ev,
                "entity": {"kind": key[0], "id": key[1]},
                "due_at": due_at,
                "action": action,
            })
    # Deterministic order: by due_at, then rule id, then entity id.
    out.sort(key=lambda a: (
        a["due_at"],
        a["rule_id"] if a["rule_id"] is not None else -1,
        a["entity"]["id"] if a["entity"]["id"] is not None else -1,
    ))
    return out


def next_fire_time(rule, trigger_ev):
    """When a rule WOULD fire for a given trigger event (trigger.at + delay).
    Pure helper for a UI preview ("this will create a task on <date>")."""
    at = trigger_ev.get("at")
    if at is None:
        return None
    return at + timedelta(days=float(rule.get("delay_days", 0) or 0))
