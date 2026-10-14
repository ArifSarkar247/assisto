"""
pa_liaison.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · LIAISON & FOLLOW-UP tracker (issue #108, SPEC v2.1 §14,
built to the §21 ADVANCED standard).

WHAT THIS IS
------------
The PA chases external contacts/tasks on the owner's behalf: "ask the vendor for
a quote", "wait for the lawyer to reply", "confirm the venue". Each is a
FOLLOW-UP with a counterpart, a due date, a status and an optional nudge-reminder
schedule. The tracker shows a list ordered by urgency, an HONEST overdue
indicator, and lets the PA add / edit / complete items (delete behind a confirm).

STATUSES
    waiting → we have reached out; the ball is in the counterpart's court.
    replied → they came back; the owner/PA now owes the next move.
    done    → closed, nothing left to chase.

OVERDUE is computed, never stored: a follow-up that is still open (waiting or
replied) and whose due date is already in the past (relative to the passed-in
`now`) is overdue. `done` items are never overdue.

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments. Anything time-relative
takes an explicit `now` so results are deterministic and the on-device Dart
mirror and the tests pin identical answers. No model call, no key required —
status is a human fact the PA records; we compute urgency, overdue, the next
nudge time and the honest counts.

CONSERVATIVE PRIVACY
--------------------
`public_view()` minimises the counterpart's contact exactly like the visitor
filter: a boolean `has_contact` and a masked `contact_hint` rather than a raw
phone/email in every list row.

Everything is plain stdlib and hand-verified in pa_liaison_tests_snippets.py.
"""

from datetime import datetime, timezone, timedelta

# ------------------------------------------------------------------ constants

STATUS_WAITING = "waiting"
STATUS_REPLIED = "replied"
STATUS_DONE = "done"
STATUSES = (STATUS_WAITING, STATUS_REPLIED, STATUS_DONE)

# Statuses that are still OPEN (can be overdue, can be nudged).
OPEN_STATUSES = (STATUS_WAITING, STATUS_REPLIED)

# Legal status transitions. A done item can be re-opened to waiting/replied
# (the PA mistakenly closed it); anything open can move to any other status.
_TRANSITIONS = {
    STATUS_WAITING: {STATUS_WAITING, STATUS_REPLIED, STATUS_DONE},
    STATUS_REPLIED: {STATUS_WAITING, STATUS_REPLIED, STATUS_DONE},
    STATUS_DONE:    {STATUS_WAITING, STATUS_REPLIED, STATUS_DONE},
}

# Nudge cadences (whole days between reminders) the PA can configure. `off`
# disables nudging entirely (honest: no reminder will fire).
NUDGE_CADENCES = {
    "off": 0,
    "daily": 1,
    "every_3_days": 3,
    "weekly": 7,
}

# A follow-up counts as "due soon" within this many days of its due date — the
# UI highlights these amber before they tip into overdue (red).
DUE_SOON_DAYS = 2


# --------------------------------------------------------------- time helpers

def _to_epoch(value):
    """ISO-8601 string or epoch (int/float) → epoch seconds (float), or None if
    missing/unparseable. Total and tolerant: a bad value never raises."""
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    iso = s.replace("Z", "+00:00")
    if "T" not in iso and " " in iso:
        iso = iso.replace(" ", "T", 1)
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


_DAY = 86400.0


# --------------------------------------------------------------- validation

def validate(item):
    """Problem keys (empty ⇒ valid) for a follow-up the UI is about to save.
    We require a title and a counterpart; due date and nudge are optional."""
    problems = []
    it = item or {}
    if not str(it.get("title") or "").strip():
        problems.append("title_required")
    if not str(it.get("counterpart") or "").strip():
        problems.append("counterpart_required")
    st = it.get("status", STATUS_WAITING)
    if st not in STATUSES:
        problems.append("bad_status")
    nd = it.get("nudge", "off")
    if nd not in NUDGE_CADENCES:
        problems.append("bad_nudge")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


def can_transition(from_status, to_status):
    """Is moving from one status to another allowed?"""
    return to_status in _TRANSITIONS.get(from_status, set())


def set_status(item, to_status, now):
    """Return a NEW item with its status changed, if the transition is legal.
    On `done` we stamp `completed_at = now` (so reports can show when it closed)
    and clear any pending nudge; re-opening clears `completed_at`. An illegal /
    unknown target returns the item unchanged with a `problem` key."""
    it = dict(item or {})
    frm = it.get("status", STATUS_WAITING)
    if to_status not in STATUSES or not can_transition(frm, to_status):
        it["problem"] = "bad_transition"
        return it
    it.pop("problem", None)
    it["status"] = to_status
    if to_status == STATUS_DONE:
        it["completed_at"] = now
    else:
        it.pop("completed_at", None)
    return it


# --------------------------------------------------------------- core logic

def is_open(item):
    """True if the follow-up is still being chased (waiting/replied)."""
    return (item or {}).get("status", STATUS_WAITING) in OPEN_STATUSES


def is_overdue(item, now):
    """HONEST overdue: open AND its due date is strictly in the past at `now`.
    An item with no due date is never overdue (nothing to be late against). A
    done item is never overdue."""
    if not is_open(item):
        return False
    due = _to_epoch((item or {}).get("due_at"))
    now_e = _to_epoch(now)
    if due is None or now_e is None:
        return False
    return due < now_e


def days_until_due(item, now):
    """Whole days from `now` until the due date (negative ⇒ overdue by that many
    days). None when there is no due date or now is unknown. Uses floor toward
    the past so '1 hour overdue' reads as -1 (a full day late only at 24h would
    be misleading — we round so any lateness shows as at least -1)."""
    due = _to_epoch((item or {}).get("due_at"))
    now_e = _to_epoch(now)
    if due is None or now_e is None:
        return None
    import math
    delta = (due - now_e) / _DAY
    # future rounds down (2.9d → 2), past rounds down too (−0.1d → −1) so any
    # lateness is visible honestly.
    return math.floor(delta)


def urgency(item, now):
    """A coarse urgency bucket for colour-coding + ordering:
        'overdue'  — open and past due.
        'due_soon' — open, due within DUE_SOON_DAYS (inclusive, not yet past).
        'later'    — open, due further out OR no due date.
        'done'     — closed.
    Deterministic."""
    if not is_open(item):
        return "done"
    if is_overdue(item, now):
        return "overdue"
    d = days_until_due(item, now)
    if d is not None and 0 <= d <= DUE_SOON_DAYS:
        return "due_soon"
    return "later"


_URGENCY_RANK = {"overdue": 0, "due_soon": 1, "later": 2, "done": 3}
# Within "later", replied (we owe the move) outranks waiting (their court).
_STATUS_TIE = {STATUS_REPLIED: 0, STATUS_WAITING: 1, STATUS_DONE: 2}


def _sort_key(item, now):
    it = item or {}
    due = _to_epoch(it.get("due_at"))
    return (
        _URGENCY_RANK.get(urgency(it, now), 9),
        _STATUS_TIE.get(it.get("status", STATUS_WAITING), 9),
        due if due is not None else float("inf"),
        str(it.get("title") or ""),
    )


def order_list(items, now):
    """NEW list ordered by urgency (overdue → due_soon → later → done), then
    replied-before-waiting, then soonest due, then title. Deterministic."""
    return sorted(list(items or []), key=lambda it: _sort_key(it, now))


def filter_list(items, now, status=None, only_overdue=False):
    """Filter by status (None/any, single, or iterable) and/or overdue-only,
    then order. Unknown status values match nothing (honest empty)."""
    if status is None:
        want = None
    elif isinstance(status, (list, tuple, set, frozenset)):
        want = set(status)
    else:
        want = {status}
    out = []
    for it in items or []:
        if want is not None and (it or {}).get("status", STATUS_WAITING) not in want:
            continue
        if only_overdue and not is_overdue(it, now):
            continue
        out.append(it)
    return order_list(out, now)


def next_nudge_at(item, now):
    """When the next nudge-reminder should fire, as epoch seconds, or None.

    Nudging only applies to OPEN items with a configured cadence. The nudge
    clock is anchored on `last_nudged_at` if present, else on the due date, else
    on `now`; the next fire is anchor + cadence-days, advanced forward past
    `now` so a long-dormant item does not spam every missed slot at once — it
    fires once, next cadence step from now. Returns None when nudging is off or
    the item is closed (honest: no reminder)."""
    it = item or {}
    if not is_open(it):
        return None
    days = NUDGE_CADENCES.get(it.get("nudge", "off"), 0)
    if days <= 0:
        return None
    now_e = _to_epoch(now)
    if now_e is None:
        return None
    anchor = (_to_epoch(it.get("last_nudged_at"))
              or _to_epoch(it.get("due_at"))
              or now_e)
    step = days * _DAY
    nxt = anchor + step
    if nxt <= now_e:
        # advance to the first cadence step strictly after now (no backlog spam)
        missed = int((now_e - anchor) // step) + 1
        nxt = anchor + missed * step
    return nxt


def nudge_due(item, now):
    """True if a nudge is due to fire at or before `now` (open + cadence on +
    the clock has reached the next slot). The scheduler uses this to decide
    whether to emit a reminder right now."""
    it = item or {}
    if not is_open(it):
        return False
    days = NUDGE_CADENCES.get(it.get("nudge", "off"), 0)
    if days <= 0:
        return False
    now_e = _to_epoch(now)
    if now_e is None:
        return False
    anchor = (_to_epoch(it.get("last_nudged_at"))
              or _to_epoch(it.get("due_at"))
              or now_e)
    return (anchor + days * _DAY) <= now_e


def counts(items, now):
    """Summary the UI badges from: per-status counts, overdue total, due-soon
    total, and open total. Deterministic."""
    by_status = {s: 0 for s in STATUSES}
    overdue = due_soon = 0
    for it in items or []:
        st = (it or {}).get("status", STATUS_WAITING)
        if st not in by_status:
            st = STATUS_WAITING
        by_status[st] += 1
        u = urgency(it, now)
        if u == "overdue":
            overdue += 1
        elif u == "due_soon":
            due_soon += 1
    return {
        "total": sum(1 for _ in (items or [])),
        "by_status": by_status,
        "overdue": overdue,
        "due_soon": due_soon,
        "open": by_status[STATUS_WAITING] + by_status[STATUS_REPLIED],
    }


# ------------------------------------------------------------- privacy view

def _mask_contact(raw):
    """Mask a phone/email to a non-identifying hint (last 4 chars, dot-padded)."""
    s = str(raw or "").strip()
    if not s:
        return ""
    tail = s[-4:]
    return "·" * max(0, min(len(s) - len(tail), 5)) + tail


def public_view(item, now):
    """Privacy-minimised projection of a follow-up for the list.

        {
          "id", "title", "counterpart", "status",
          "due_at", "nudge",
          "urgency",          # overdue|due_soon|later|done
          "overdue": bool,
          "days_until_due": int|None,
          "has_contact": bool,
          "contact_hint": "·····3210" | "",
          "next_nudge_at": epoch|None,
        }
    """
    it = item or {}
    raw = it.get("contact") or it.get("phone") or it.get("email") or ""
    return {
        "id": it.get("id"),
        "title": str(it.get("title") or "").strip(),
        "counterpart": str(it.get("counterpart") or "").strip(),
        "status": it.get("status", STATUS_WAITING),
        "due_at": it.get("due_at"),
        "nudge": it.get("nudge", "off"),
        "urgency": urgency(it, now),
        "overdue": is_overdue(it, now),
        "days_until_due": days_until_due(it, now),
        "has_contact": bool(str(raw).strip()),
        "contact_hint": _mask_contact(raw),
        "next_nudge_at": next_nudge_at(it, now),
    }
