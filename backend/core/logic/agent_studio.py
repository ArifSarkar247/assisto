"""
agent_studio.py — the deterministic rule engine behind Assisto's Agent Studio
(SPEC v2.1 §21, ADVANCED). Agent Studio lets an ordinary user build their own
little "mini-agents": readable WHEN … IF … THEN automations — a time/schedule,
event, keyword or incoming-message trigger, optional conditions, and one or more
actions (remind / message / log / summarize / call-a-tool).

This module is PURE: no Django, no DB, no network, no AI, no clock of its own.
The HTTP / app layer hands it a list of plain automation dicts and an explicit
`now` (a timezone-naive local `datetime`); we decide, deterministically, which
automations are *due* and what actions should fire. The same logic is mirrored
on-device in Dart so "Test / Run now" and the run history behave identically
offline — this file is the single source of truth and the thing the tests pin.

The AI-flavoured action ("summarize") is intentionally NOT done here: a rule
engine must be deterministic and key-free. We only emit the *intent* to
summarize (the action descriptor), and mark `ai_required: True` on it. Whoever
executes the plan decides — with an AI key, summarize for real; without one,
show the honest mocked preview. Nothing in this file calls a model.

An automation dict understood here (unknown keys ignored; missing use defaults):

    {
      "id": "a1",
      "name": "Electricity bill reminder",
      "enabled": True,                 # disabled automations never fire
      "triggers": [                    # ANY trigger firing arms the automation
        {"type": "schedule", "at": "09:00", "days": [1,2,3,4,5,6,7]},
        {"type": "schedule", "at": "20:00", "day_of_month": 5},
        {"type": "event", "event": "bill_due"},
        {"type": "keyword", "keywords": ["electricity", "বিদ্যুৎ"]},
        {"type": "incoming", "from": "bkash"},
      ],
      "conditions": [                  # ALL must hold (AND) — empty ⇒ always true
        {"field": "amount", "op": ">=", "value": 500},
        {"field": "category", "op": "==", "value": "utility"},
      ],
      "match": "all",                  # "all" (AND, default) | "any" (OR)
      "actions": [                     # fired in order when due
        {"type": "remind", "text": "Pay the electricity bill"},
        {"type": "message", "to": "self", "text": "Bill due today"},
        {"type": "log", "text": "bill reminder fired"},
        {"type": "summarize", "source": "today"},     # ai_required
        {"type": "tool", "tool": "money.summary"},
      ],
      "last_fired": "2026-10-13T09:00:00",   # ISO, or None — dedupe guard
    }

Triggers (all evaluated against the passed-in `now` + optional `event` context):
  schedule  — fires at `at` "HH:MM" on the given `days` (ISO 1=Mon..7=Sun) and/or
              `day_of_month` (1..31, clamped to the month's last day). We fire
              inside a small window `[at, at+grace_minutes)` so a poll a few
              minutes late still catches it exactly once (last_fired dedupe).
  event     — fires when `ctx["event"]` equals the trigger's `event`.
  keyword   — fires when any keyword appears (case-insensitive substring) in
              `ctx["text"]`.
  incoming  — fires when `ctx["incoming_from"]` matches `from` (case-insensitive).

Everything is plain stdlib and hand-verified in agent_studio_tests_snippets.py.
"""

from datetime import datetime, date, time, timedelta

# ------------------------------------------------------------------ templates
# The gallery users start from. Kept here (not the UI) so the shapes the engine
# accepts and the shapes the gallery offers can never drift apart. Text is a
# neutral default the UI localises; the engine never reads `name`/`text`.

TEMPLATES = [
    {
        "key": "bill_reminder",
        "name": "Bill reminder",
        "triggers": [{"type": "schedule", "at": "09:00", "day_of_month": 1}],
        "conditions": [],
        "actions": [{"type": "remind", "text": "Pay the bill"}],
    },
    {
        "key": "daily_summary",
        "name": "Daily summary",
        "triggers": [{"type": "schedule", "at": "21:00",
                      "days": [1, 2, 3, 4, 5, 6, 7]}],
        "conditions": [],
        "actions": [{"type": "summarize", "source": "today"}],
    },
    {
        "key": "follow_up",
        "name": "Follow-up",
        "triggers": [{"type": "event", "event": "lead_created"}],
        "conditions": [],
        "actions": [{"type": "remind", "text": "Follow up"}],
    },
    {
        "key": "birthday_wish",
        "name": "Birthday wish",
        "triggers": [{"type": "event", "event": "birthday_today"}],
        "conditions": [],
        "actions": [{"type": "message", "to": "self", "text": "Send a wish"}],
    },
]

TRIGGER_TYPES = ("schedule", "event", "keyword", "incoming")
ACTION_TYPES = ("remind", "message", "log", "summarize", "tool")
CONDITION_OPS = ("==", "!=", ">", ">=", "<", "<=", "contains")
AI_ACTIONS = ("summarize",)  # honest: these need an AI key to really execute


# --------------------------------------------------------------- small helpers

def _parse_dt(value):
    """ISO datetime string → naive datetime, or None. Accepts a 'Z'/offset by
    dropping it (we work in local wall-clock only)."""
    if not value:
        return None
    if isinstance(value, datetime):
        return value.replace(tzinfo=None)
    s = str(value).strip().replace("Z", "")
    if "+" in s[10:]:
        s = s[:10] + s[10:].split("+", 1)[0]
    try:
        return datetime.fromisoformat(s).replace(tzinfo=None)
    except ValueError:
        try:
            return datetime.strptime(s[:16], "%Y-%m-%dT%H:%M")
        except ValueError:
            return None


def _parse_hm(value):
    """'HH:MM' → datetime.time, or None."""
    try:
        h, m = str(value).split(":", 1)
        h, m = int(h), int(m)
        if 0 <= h <= 23 and 0 <= m <= 59:
            return time(h, m)
    except (ValueError, AttributeError):
        pass
    return None


def _last_day_of_month(year, month):
    if month == 12:
        return 31
    return (date(year, month + 1, 1) - timedelta(days=1)).day


def _as_number(v):
    """Best-effort numeric coercion for conditions; None if not a number."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    try:
        return float(str(v).strip())
    except (ValueError, AttributeError):
        return None


# ------------------------------------------------------------- validation

def validate(auto):
    """Return a list of human-readable problem keys (empty ⇒ valid). The UI
    localises these; we only name the problem so the two stay in lockstep."""
    problems = []
    if not str(auto.get("name", "")).strip():
        problems.append("name_required")
    triggers = auto.get("triggers") or []
    if not triggers:
        problems.append("trigger_required")
    for tr in triggers:
        if tr.get("type") not in TRIGGER_TYPES:
            problems.append("bad_trigger")
        if tr.get("type") == "schedule" and not _parse_hm(tr.get("at")):
            problems.append("bad_time")
        if tr.get("type") == "keyword" and not (tr.get("keywords") or []):
            problems.append("keyword_required")
    actions = auto.get("actions") or []
    if not actions:
        problems.append("action_required")
    for ac in actions:
        if ac.get("type") not in ACTION_TYPES:
            problems.append("bad_action")
    for c in auto.get("conditions") or []:
        if c.get("op") not in CONDITION_OPS:
            problems.append("bad_condition")
    # de-dupe, keep order
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------- conditions

def eval_condition(cond, ctx):
    """One condition against the event context dict. Missing field ⇒ False
    (a condition can never pass on data we don't have)."""
    field = cond.get("field")
    op = cond.get("op")
    want = cond.get("value")
    if field not in (ctx or {}):
        return False
    got = ctx[field]
    if op == "==":
        return str(got) == str(want)
    if op == "!=":
        return str(got) != str(want)
    if op == "contains":
        return str(want).lower() in str(got).lower()
    gn, wn = _as_number(got), _as_number(want)
    if gn is None or wn is None:
        return False
    if op == ">":
        return gn > wn
    if op == ">=":
        return gn >= wn
    if op == "<":
        return gn < wn
    if op == "<=":
        return gn <= wn
    return False


def conditions_pass(auto, ctx):
    conds = auto.get("conditions") or []
    if not conds:
        return True
    results = [eval_condition(c, ctx) for c in conds]
    if (auto.get("match") or "all") == "any":
        return any(results)
    return all(results)


# ------------------------------------------------------------- triggers

def trigger_fires(trigger, now, ctx, grace_minutes=5):
    """True if this single trigger fires for the given `now` + context."""
    ttype = trigger.get("type")
    ctx = ctx or {}
    if ttype == "schedule":
        at = _parse_hm(trigger.get("at"))
        if at is None:
            return False
        days = trigger.get("days")
        if days and now.isoweekday() not in days:
            return False
        dom = trigger.get("day_of_month")
        if dom:
            dom = min(int(dom), _last_day_of_month(now.year, now.month))
            if now.day != dom:
                return False
        start = now.replace(hour=at.hour, minute=at.minute,
                            second=0, microsecond=0)
        end = start + timedelta(minutes=max(0, grace_minutes))
        return start <= now < end
    if ttype == "event":
        return bool(ctx.get("event")) and ctx.get("event") == trigger.get("event")
    if ttype == "keyword":
        text = str(ctx.get("text", "")).lower()
        kws = [str(k).lower() for k in (trigger.get("keywords") or [])]
        return any(k and k in text for k in kws)
    if ttype == "incoming":
        src = str(ctx.get("incoming_from", "")).lower()
        return bool(src) and src == str(trigger.get("from", "")).lower()
    return False


def _already_fired_this_window(auto, now, grace_minutes):
    """Dedupe guard: within the same grace window a schedule can only fire once.
    Event/keyword/incoming triggers carry their own natural de-dupe upstream, so
    we only guard schedules here (compare to the last_fired timestamp)."""
    last = _parse_dt(auto.get("last_fired"))
    if last is None:
        return False
    return (now - last) < timedelta(minutes=max(1, grace_minutes))


def is_due(auto, now, ctx=None, grace_minutes=5):
    """Deterministic: should this automation fire at `now`? Disabled ⇒ never.
    ANY trigger arming + ALL/ANY conditions passing ⇒ due. Schedule triggers
    respect the last_fired dedupe window so a late poll fires exactly once."""
    if not auto.get("enabled", True):
        return False
    triggers = auto.get("triggers") or []
    ctx = ctx or {}
    armed = False
    scheduled = False
    for tr in triggers:
        if trigger_fires(tr, now, ctx, grace_minutes):
            armed = True
            if tr.get("type") == "schedule":
                scheduled = True
    if not armed:
        return False
    if scheduled and _already_fired_this_window(auto, now, grace_minutes):
        return False
    return conditions_pass(auto, ctx)


# ------------------------------------------------------------- planning / run

def plan_actions(auto):
    """The ordered list of action descriptors to execute when due. AI actions
    are flagged `ai_required` so the executor can mock-or-real honestly; the
    engine itself never runs a model."""
    out = []
    for ac in auto.get("actions") or []:
        d = dict(ac)
        d["ai_required"] = ac.get("type") in AI_ACTIONS
        out.append(d)
    return out


def evaluate(automations, now, ctx=None, grace_minutes=5):
    """MAIN ENTRY. Given every automation + an explicit `now`, return the due
    ones with their action plans — deterministic, offline, no side effects.

        [{"id", "name", "actions": [descriptor, ...], "needs_ai": bool}, ...]

    The caller is responsible for actually performing the actions and for
    stamping `last_fired` on the ones it fires."""
    now = _parse_dt(now) if not isinstance(now, datetime) else now
    due = []
    for auto in automations or []:
        if is_due(auto, now, ctx, grace_minutes):
            actions = plan_actions(auto)
            due.append({
                "id": auto.get("id"),
                "name": auto.get("name"),
                "actions": actions,
                "needs_ai": any(a["ai_required"] for a in actions),
            })
    return due


def mark_fired(auto, now):
    """Return a copy of `auto` with `last_fired` stamped to `now` (ISO). Pure:
    the original is never mutated."""
    now = _parse_dt(now) if not isinstance(now, datetime) else now
    out = dict(auto)
    out["last_fired"] = now.replace(microsecond=0).isoformat()
    return out


def describe(auto):
    """A stable, language-neutral WHEN…IF…THEN skeleton the UI renders. We emit
    structured tokens (not prose) so the Dart side localises identically."""
    return {
        "when": [{"type": t.get("type"),
                  "at": t.get("at"),
                  "days": t.get("days"),
                  "day_of_month": t.get("day_of_month"),
                  "event": t.get("event"),
                  "keywords": t.get("keywords"),
                  "from": t.get("from")}
                 for t in (auto.get("triggers") or [])],
        "if": [{"field": c.get("field"), "op": c.get("op"),
                "value": c.get("value")}
               for c in (auto.get("conditions") or [])],
        "match": auto.get("match") or "all",
        "then": [{"type": a.get("type"),
                  "ai_required": a.get("type") in AI_ACTIONS}
                 for a in (auto.get("actions") or [])],
    }
