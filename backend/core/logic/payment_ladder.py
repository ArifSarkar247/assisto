"""
payment_ladder.py — pure deterministic engine for Assisto's PAYMENT / AUTO-PAY
LADDER module (SPEC v2.1 §21). No Django, no DB, no network, no AI, no clock of
its own: every function that needs "now" takes it as an argument, so the whole
module is a pure function of (debt + ladder config + now) → the due step/action.

WHAT A LADDER IS
----------------
An auto-escalating sequence of payment ACTIONS for two mirror-image cases:

  RECEIVABLE — money the user is OWED (a khata/tagada due). The ladder chases it:
      step 1  gentle reminder        (e.g. the day it falls due)
      step 2  firmer reminder        (+3 days)
      step 3  final notice           (+7 days)
      step 4  escalate               (+14 days: notify a co-owner / pause service)
    Each step has its own CHANNEL (in-app / whatsapp_share / own-SIM SMS) and the
    whole ladder STOPS the instant the debt is paid (stop-on-payment).

  PAYABLE — a bill / EMI the user OWES. The ladder reminds the user to pay:
      step 1  heads-up before due     (lead days before the due date)
      step 2  due today
      step 3  overdue reminder        (+N days)
      step 4  final / late-fee warning (+M days)
    Same channels; the user taps "mark paid" to stop it (and to roll a recurring
    bill forward to its next cycle).

HARD HONESTY RULES (enforced structurally, not just documented)
---------------------------------------------------------------
  * NEVER HOLD MONEY.  This engine computes reminders and share payloads only. It
    returns no balance it custodies; `holds_money()` is a constant `False`.
  * NO AUTO-CHARGE.  No step ever moves money on its own. `charges_money()` is a
    constant `False`. The strongest action an escalation step can emit is a
    reminder/notify/share/pause-service — see ACTIONS.
  * KEY-GATED PAYMENTS.  Actually *paying* a bill (for the payable case) requires
    the owner's own licensed payment key (bKash / Nagad / a licensed partner).
    Without a key the engine is honest: a "pay" action degrades to
    `pay_manual` (open the owner's own wallet app / share payment instructions),
    and `can_execute_pay(ladder, has_key)` is the single gate the UI/wire must
    respect. We never act as a wallet.

MONEY is INTEGER POISHA everywhere (1 taka = 100 poisha). Amounts arrive either as
integer poisha (`amount_poisha`, preferred) or as a taka string/Decimal from a
DRF DecimalField; `to_poisha` normalises both with NO float arithmetic, so a debt
that is summed / compared never drifts.

DATA SHAPES (unknown keys ignored; missing keys use safe defaults)
------------------------------------------------------------------
debt = {
    "id": 1,
    "kind": "receivable",          # receivable | payable
    "party": "Rahim Store",        # who owes you / whom you owe
    "amount_poisha": 60000,        # integer poisha  (or "amount": "600.00")
    "paid_poisha": 0,              # how much has been settled so far
    "due_date": "2026-02-01",      # ISO date the debt anchors on
    "recurring_days": 0,           # >0 ⇒ payable bill repeats every N days
    "paused": false,               # user snoozed this ladder
}

ladder = {
    "id": 10,
    "kind": "receivable",          # must match the debt kind
    "stop_on_payment": true,       # stop the instant fully paid (default true)
    "has_payment_key": false,      # owner has a licensed pay key (payable only)
    "steps": [
        {"offset_days": 0,  "action": "remind_gentle", "channel": "in_app"},
        {"offset_days": 3,  "action": "remind_firm",   "channel": "whatsapp_share"},
        {"offset_days": 7,  "action": "final_notice",  "channel": "sms"},
        {"offset_days": 14, "action": "escalate_owner","channel": "in_app"},
    ],
}

`offset_days` is measured from the debt's `due_date`: a RECEIVABLE step fires
`offset_days` AFTER the due date (0 = on the day, 3 = three days late …); a
PAYABLE "heads-up" step uses a NEGATIVE offset to fire BEFORE the due date.
"""

from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP

# ----------------------------------------------------------------- vocabulary

RECEIVABLE = "receivable"
PAYABLE = "payable"
KINDS = (RECEIVABLE, PAYABLE)

# Channels a step may use. We NEVER send on the user's behalf silently:
#   in_app         — a notification inside Assisto
#   whatsapp_share — opens WhatsApp with a prefilled message; the user taps Send
#   sms            — opens the user's OWN SMS app prefilled; the user taps Send
CHANNELS = ("in_app", "whatsapp_share", "sms")

# Every action is a REMINDER / SHARE / NOTIFY / PAUSE — never a money movement.
# `pay_manual` (payable) opens the owner's own wallet; it still moves no money
# through Assisto. `pay_key` is the ONLY action that touches a payment rail and
# it is gated on a licensed key (see can_execute_pay); without a key it is
# downgraded to `pay_manual` by resolve_pay_action().
RECEIVABLE_ACTIONS = (
    "remind_gentle",    # step 1 — polite nudge
    "remind_firm",      # step 2 — firmer
    "final_notice",     # step 3 — final notice before escalation
    "escalate_owner",   # step 4 — notify a co-owner / flag for follow-up
    "pause_service",    # step 4 alt — stop giving further credit/service
)
PAYABLE_ACTIONS = (
    "heads_up",         # before due — "your bill is coming"
    "due_today",        # on the due date
    "overdue",          # after due
    "final_warning",    # last reminder (possible late fee)
    "pay_manual",       # open the owner's OWN wallet / show instructions (no key)
    "pay_key",          # pay via a licensed key  (ONLY with has_payment_key)
)

# Actions that are purely informational reminders (safe without any key/consent).
_REMINDER_ACTIONS = frozenset({
    "remind_gentle", "remind_firm", "final_notice", "escalate_owner",
    "pause_service", "heads_up", "due_today", "overdue", "final_warning",
})


# ----------------------------------------------------------------- money

def to_poisha(obj, key_poisha="amount_poisha", key_taka="amount"):
    """Integer poisha from a dict. Prefers the integer `amount_poisha`; else
    parses the taka `amount` (string/Decimal/number) with NO float arithmetic."""
    if obj.get(key_poisha) is not None:
        try:
            return int(obj[key_poisha])
        except (TypeError, ValueError):
            return 0
    raw = obj.get(key_taka)
    if raw is None or raw == "":
        return 0
    try:
        taka = Decimal(str(raw))
    except Exception:
        return 0
    return int((taka * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def outstanding_poisha(debt):
    """What is still owed: amount minus anything already paid, floored at 0."""
    amount = to_poisha(debt)
    paid = to_poisha(debt, "paid_poisha", "paid")
    return max(0, amount - paid)


def is_paid(debt):
    """True once nothing is outstanding — the stop-on-payment condition."""
    return outstanding_poisha(debt) <= 0


# ----------------------------------------------------------------- honesty gates
# These are CONSTANTS, not config — the engine structurally cannot hold money
# or auto-charge, so these can never be flipped on by a caller.

def holds_money():
    """We are not a wallet. The engine never custodies a balance. Always False."""
    return False


def charges_money():
    """No step ever moves money on its own. No auto-charge, ever. Always False."""
    return False


def can_execute_pay(ladder, has_key=None):
    """Can a `pay_key` action actually run? Only when the owner has supplied a
    licensed payment key. `has_key` overrides the ladder flag when given.
    This is the single gate the UI/wire must honour before touching a rail."""
    if has_key is None:
        has_key = bool(ladder.get("has_payment_key", False))
    return bool(has_key)


def resolve_pay_action(action, ladder, has_key=None):
    """Downgrade a key-only `pay_key` to the honest `pay_manual` when no licensed
    key is present. Everything else passes through unchanged. This is how we stay
    honest: with no key, "pay" opens the owner's own wallet, moving no money
    through Assisto."""
    if action == "pay_key" and not can_execute_pay(ladder, has_key):
        return "pay_manual"
    return action


# ----------------------------------------------------------------- dates / steps

def _parse_date(value):
    """ISO 'YYYY-MM-DD' (or date/datetime) → date, else None."""
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _normalised_steps(ladder):
    """Steps sorted by offset_days ascending, each a clean dict with an index.
    Malformed steps (missing offset) are dropped. Channels/actions unknown to us
    are kept verbatim — the engine is tolerant; the wire validates on save."""
    raw = ladder.get("steps") or []
    out = []
    for i, s in enumerate(raw):
        if not isinstance(s, dict) or s.get("offset_days") is None:
            continue
        try:
            off = int(s["offset_days"])
        except (TypeError, ValueError):
            continue
        out.append({
            "index": i,
            "offset_days": off,
            "action": s.get("action", "remind_gentle"),
            "channel": s.get("channel", "in_app"),
        })
    out.sort(key=lambda x: (x["offset_days"], x["index"]))
    # Re-index after sorting so "step 1..N" is stable and 1-based for display.
    for n, s in enumerate(out):
        s["step"] = n + 1
    return out


def step_fire_date(due_date, offset_days):
    """The calendar date a step fires: due_date + offset_days (offset may be
    negative for payable heads-up steps). None if the due date is unparseable."""
    d = _parse_date(due_date)
    if d is None:
        return None
    return d + timedelta(days=int(offset_days))


# ----------------------------------------------------------------- the engine

def due_step(debt, ladder, now):
    """THE core function. Given a debt, its ladder, and `now` (a date), return the
    single step/action that is currently DUE — i.e. the highest step whose fire
    date has arrived — or None when nothing is due yet or the ladder is stopped.

    Rules, in order:
      1. stop-on-payment: if the debt is paid and the ladder stops on payment,
         return None (fully settled → ladder is silent). Never charges anyone.
      2. paused: a snoozed debt returns None.
      3. otherwise pick the LAST step whose fire date <= now. Earlier steps are
         superseded; only the current rung of the ladder is actionable.

    The returned dict is ready for the UI/wire:
      {
        "step": 3, "action": "final_notice", "channel": "sms",
        "fire_date": "2026-02-08", "days_overdue": 5,
        "outstanding_poisha": 60000, "is_final": True,
        "holds_money": False, "charges_money": False,
      }
    `action` is already resolved through the key gate, so a key-less ladder shows
    `pay_manual` instead of `pay_key`. Pure: `now` is never read from the clock.
    """
    now = _parse_date(now) or now
    if not isinstance(now, date):
        return None

    # 1 — stop-on-payment. Paid + stop_on_payment (default True) ⇒ silent.
    if is_paid(debt) and ladder.get("stop_on_payment", True):
        return None
    # 2 — snoozed.
    if debt.get("paused"):
        return None

    steps = _normalised_steps(ladder)
    if not steps:
        return None
    due = _parse_date(debt.get("due_date"))
    if due is None:
        return None

    current = None
    for s in steps:
        fire = due + timedelta(days=s["offset_days"])
        if fire <= now:
            current = (s, fire)
        else:
            break  # steps are sorted; nothing later can be due
    if current is None:
        return None

    s, fire = current
    action = resolve_pay_action(s["action"], ladder)
    return {
        "step": s["step"],
        "step_index": s["index"],
        "action": action,
        "channel": s["channel"],
        "fire_date": fire.isoformat(),
        "days_overdue": (now - due).days,
        "days_since_fire": (now - fire).days,
        "outstanding_poisha": outstanding_poisha(debt),
        "is_final": s["step"] == len(steps),
        "holds_money": holds_money(),
        "charges_money": charges_money(),
    }


def next_step(debt, ladder, now):
    """The NEXT step that has not yet fired (the one coming up), as
    {step, action, channel, fire_date, days_until} — or None if the ladder is
    exhausted / stopped. Lets the UI say 'next reminder in N days'."""
    now = _parse_date(now) or now
    if not isinstance(now, date):
        return None
    if is_paid(debt) and ladder.get("stop_on_payment", True):
        return None
    if debt.get("paused"):
        return None
    steps = _normalised_steps(ladder)
    due = _parse_date(debt.get("due_date"))
    if not steps or due is None:
        return None
    for s in steps:
        fire = due + timedelta(days=s["offset_days"])
        if fire > now:
            return {
                "step": s["step"],
                "action": resolve_pay_action(s["action"], ladder),
                "channel": s["channel"],
                "fire_date": fire.isoformat(),
                "days_until": (fire - now).days,
            }
    return None


def schedule(debt, ladder, now=None):
    """The whole ladder laid out as a timeline for the builder/preview UI: every
    step with its fire date and a status of past|due|upcoming relative to `now`
    (if given). Pure; does not fire anything. Pay actions are key-resolved."""
    steps = _normalised_steps(ladder)
    due = _parse_date(debt.get("due_date"))
    n = _parse_date(now) if now is not None else None
    cur = due_step(debt, ladder, now) if (n is not None) else None
    cur_index = cur["step_index"] if cur else None
    out = []
    for s in steps:
        fire = (due + timedelta(days=s["offset_days"])) if due else None
        if n is None or fire is None:
            status = "upcoming"
        elif s["index"] == cur_index:
            status = "due"
        elif fire <= n:
            status = "past"
        else:
            status = "upcoming"
        out.append({
            "step": s["step"],
            "action": resolve_pay_action(s["action"], ladder),
            "channel": s["channel"],
            "offset_days": s["offset_days"],
            "fire_date": fire.isoformat() if fire else None,
            "status": status,
        })
    return out


def record_payment(debt, amount_poisha, now=None):
    """Apply a payment to a debt and return a NEW debt dict (never mutates input).

    `paid_poisha` grows by the amount (clamped so it never exceeds the amount —
    we are tracking a debt, not banking an overpayment). If this clears a
    recurring payable bill, the due date rolls forward by `recurring_days` and
    paid_poisha resets so the next cycle starts fresh. This is bookkeeping only:
    it moves NO real money — a real payment happens outside, via the owner's own
    wallet or a licensed key."""
    out = dict(debt)
    amount = to_poisha(debt)
    paid = to_poisha(debt, "paid_poisha", "paid")
    try:
        add = max(0, int(amount_poisha))
    except (TypeError, ValueError):
        add = 0
    new_paid = min(amount, paid + add)
    out["paid_poisha"] = new_paid
    out.pop("paid", None)  # canonicalise onto the integer field
    out["amount_poisha"] = amount

    recurring = int(debt.get("recurring_days") or 0)
    if new_paid >= amount and amount > 0 and recurring > 0:
        base = _parse_date(debt.get("due_date"))
        anchor = _parse_date(now) or base
        if base is not None:
            nxt = base
            # roll strictly past the payment date so we never re-fire today
            guard = 0
            while anchor is not None and nxt <= anchor and guard < 3650:
                nxt = nxt + timedelta(days=recurring)
                guard += 1
            out["due_date"] = nxt.isoformat()
            out["paid_poisha"] = 0  # fresh cycle
    return out


def mark_paid(debt, now=None):
    """Settle the whole outstanding balance in one tap (the 'mark paid' button).
    Thin wrapper over record_payment for the common full-settle case."""
    return record_payment(debt, outstanding_poisha(debt), now=now)


# ----------------------------------------------------------------- templates

# A sensible default ladder per kind, offered in the builder's "quick start".
# Offsets are days from the due date (negative = before, for payable heads-up).
DEFAULT_RECEIVABLE_STEPS = [
    {"offset_days": 0,  "action": "remind_gentle",  "channel": "in_app"},
    {"offset_days": 3,  "action": "remind_firm",    "channel": "whatsapp_share"},
    {"offset_days": 7,  "action": "final_notice",   "channel": "sms"},
    {"offset_days": 14, "action": "escalate_owner", "channel": "in_app"},
]
DEFAULT_PAYABLE_STEPS = [
    {"offset_days": -3, "action": "heads_up",      "channel": "in_app"},
    {"offset_days": 0,  "action": "due_today",     "channel": "in_app"},
    {"offset_days": 3,  "action": "overdue",       "channel": "in_app"},
    {"offset_days": 7,  "action": "final_warning", "channel": "in_app"},
]


def default_ladder(kind):
    """A ready-to-edit default ladder config for a debt of the given kind."""
    kind = kind if kind in KINDS else RECEIVABLE
    steps = DEFAULT_RECEIVABLE_STEPS if kind == RECEIVABLE else DEFAULT_PAYABLE_STEPS
    return {
        "kind": kind,
        "stop_on_payment": True,
        "has_payment_key": False,
        "steps": [dict(s) for s in steps],
    }


def validate_ladder(ladder):
    """Return a list of human-readable problem CODES (empty ⇒ valid). The wire
    layer maps these to localised strings; the engine stays language-free."""
    problems = []
    kind = ladder.get("kind")
    if kind not in KINDS:
        problems.append("bad_kind")
    steps = ladder.get("steps") or []
    if not steps:
        problems.append("no_steps")
    offs = []
    for s in steps:
        if not isinstance(s, dict) or s.get("offset_days") is None:
            problems.append("bad_step")
            continue
        try:
            offs.append(int(s["offset_days"]))
        except (TypeError, ValueError):
            problems.append("bad_step")
            continue
        if s.get("channel") and s["channel"] not in CHANNELS:
            problems.append("bad_channel")
    if len(set(offs)) != len(offs):
        problems.append("duplicate_offset")
    # No step may claim to auto-charge — pay_key is allowed but only as a GATED
    # manual trigger; there is no "auto" action in the vocabulary, so nothing to
    # reject here. This check documents the invariant for future steps.
    for s in steps:
        if isinstance(s, dict) and s.get("action") in ("auto_charge", "auto_pay"):
            problems.append("no_auto_charge")
    # de-dup, stable order
    seen = []
    for p in problems:
        if p not in seen:
            seen.append(p)
    return seen


# ----------------------------------------------------------------- summary

def summarize(debts_with_ladders, now):
    """One-pass dashboard summary. Input is a list of (debt, ladder) pairs; output
    is the shape a view can serialise straight to JSON: counts, total outstanding
    split by kind, and the list of ACTION ITEMS due right now (highest rung per
    debt), soonest-fired first. Never holds/charges money."""
    now_d = _parse_date(now) or now
    receivable_out = 0
    payable_out = 0
    action_items = []
    for debt, ladder in debts_with_ladders:
        out = outstanding_poisha(debt)
        if debt.get("kind") == PAYABLE:
            payable_out += out
        else:
            receivable_out += out
        step = due_step(debt, ladder, now_d)
        if step is not None:
            action_items.append({
                "debt_id": debt.get("id"),
                "party": debt.get("party", ""),
                "kind": debt.get("kind", RECEIVABLE),
                **step,
            })
    action_items.sort(key=lambda x: (x.get("fire_date") or "", -x["days_overdue"]))
    return {
        "receivable_outstanding_poisha": receivable_out,
        "payable_outstanding_poisha": payable_out,
        "net_poisha": receivable_out - payable_out,
        "action_count": len(action_items),
        "action_items": action_items,
        "holds_money": holds_money(),
        "charges_money": charges_money(),
    }
