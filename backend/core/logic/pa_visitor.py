"""
pa_visitor.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · VISITOR / APPOINTMENT FILTER (issue #105, SPEC v2.1 §14,
built to the §21 ADVANCED standard).

WHAT THIS IS
------------
A personal assistant (the "PA") screens incoming visit / appointment requests
addressed to the owner. Each request sits in a QUEUE the owner triages:

    approve  → the owner agrees to the visit/appointment as asked.
    decline  → the owner says no.
    suggest  → the owner proposes a different time (reschedule-suggest); the
               visitor must still confirm, so this is NOT yet accepted.

The PA also tags each request's PRIORITY (vip / normal) and filters the queue
by STATUS and PRIORITY. The owner sees a clean, ordered list and acts on it.

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function here is a pure function of its arguments. Anything time-relative
(e.g. "is this appointment in the past?") takes an explicit `now` (an ISO-8601
string or epoch seconds) so the result is fully deterministic and the on-device
Dart mirror and the tests pin the exact same answers. There is no model call
and no key is ever required — triage is a human decision the owner makes; we
only compute the resulting state, the ordering and the honest counts.

CONSERVATIVE PRIVACY (visitor contact minimised)
-------------------------------------------------
Visitor contact information is deliberately MINIMISED. `public_view()` strips a
request down to what the owner needs to triage — name, reason, requested time,
priority, status — and NEVER exposes a raw phone/email. Instead it returns a
boolean `has_contact` and a masked hint (`contact_hint`, e.g. "·····3210") so
the owner knows a contact exists and can reach it through the app, without the
raw value fanning out into lists, logs or exports. The raw value stays on the
single detail record the integrator stores server-side.

Everything is plain stdlib and hand-verified in pa_visitor_tests_snippets.py.
"""

from datetime import datetime, timezone

# ------------------------------------------------------------------ constants

# A request's lifecycle status. `pending` is the only actionable inbox state;
# the three terminal-ish states are the outcome of a triage decision. `expired`
# is computed (see compute_status) when a *pending* request's requested time is
# already in the past relative to `now` — the owner never actioned it in time.
STATUS_PENDING = "pending"
STATUS_APPROVED = "approved"
STATUS_DECLINED = "declined"
STATUS_SUGGESTED = "suggested"   # reschedule-suggest sent; awaiting visitor
STATUS_EXPIRED = "expired"       # pending but the requested slot already passed

STATUSES = (
    STATUS_PENDING, STATUS_APPROVED, STATUS_DECLINED,
    STATUS_SUGGESTED, STATUS_EXPIRED,
)

# Statuses a stored record may legitimately HOLD. `expired` is derived, not
# stored — callers persist one of these four and let compute_status() derive
# expiry at read time.
STORED_STATUSES = (
    STATUS_PENDING, STATUS_APPROVED, STATUS_DECLINED, STATUS_SUGGESTED,
)

PRIORITY_VIP = "vip"
PRIORITY_NORMAL = "normal"
PRIORITIES = (PRIORITY_VIP, PRIORITY_NORMAL)

# The triage decisions the owner can take on a PENDING request, mapped to the
# stored status they produce. `suggest` additionally carries a proposed time.
TRIAGE_EVENTS = {
    "approve": STATUS_APPROVED,
    "decline": STATUS_DECLINED,
    "suggest": STATUS_SUGGESTED,
}

# Decisions the UI should put behind a confirm gate (destructive / committing).
# Approve commits the owner's calendar; decline is a hard no — both deserve a
# second tap. "suggest" opens a time picker instead, so it is not gated here.
CONFIRM_EVENTS = ("approve", "decline")

# Ordering weights. Lower sorts first. VIP outranks normal; within a priority,
# pending/suggested (needs attention) outrank settled rows; within that, the
# sooner the requested time the higher it sits.
_PRIORITY_RANK = {PRIORITY_VIP: 0, PRIORITY_NORMAL: 1}
_STATUS_RANK = {
    STATUS_PENDING: 0,
    STATUS_SUGGESTED: 1,
    STATUS_EXPIRED: 2,
    STATUS_APPROVED: 3,
    STATUS_DECLINED: 4,
}


# --------------------------------------------------------------- time helpers

def _to_epoch(value):
    """Coerce an ISO-8601 string or epoch (int/float) to epoch seconds (float),
    or None when it is missing / unparseable. Total and tolerant: a bad time
    must never raise — the UI treats None as 'no time set'."""
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    # tolerate a trailing Z and space-separated datetimes
    iso = s.replace("Z", "+00:00").replace(" ", "T", 1) if "T" not in s else \
        s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError:
        try:
            return float(s)  # maybe it was numeric-as-string
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


# --------------------------------------------------------------- validation

def validate(req):
    """Return a list of problem keys (empty ⇒ valid) for a request dict the UI
    is about to create. The UI localises each key. We require a name and a
    reason; a requested time is optional (a walk-in request may have none)."""
    problems = []
    if not str((req or {}).get("name") or "").strip():
        problems.append("name_required")
    if not str((req or {}).get("reason") or "").strip():
        problems.append("reason_required")
    pr = (req or {}).get("priority", PRIORITY_NORMAL)
    if pr not in PRIORITIES:
        problems.append("bad_priority")
    st = (req or {}).get("status", STATUS_PENDING)
    if st not in STORED_STATUSES:
        problems.append("bad_status")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


def validate_event(event):
    """Is `event` a triage action we accept? Returns the resulting stored
    status, or None if the event is unknown."""
    return TRIAGE_EVENTS.get(event)


def needs_confirm(event):
    """Should the UI gate this triage action behind a confirm dialog?"""
    return event in CONFIRM_EVENTS


# --------------------------------------------------------------- core logic

def compute_status(req, now):
    """The EFFECTIVE status of a request at time `now`.

    A record stores one of STORED_STATUSES. A *pending* record whose requested
    time has already passed is reported as `expired` — the owner never actioned
    it in time, so the UI can surface it honestly rather than pretending it is
    still live. Every other stored status is returned unchanged (an approved or
    suggested slot in the past is still approved/suggested — it happened / is
    awaiting the visitor, not 'expired')."""
    stored = (req or {}).get("status", STATUS_PENDING)
    if stored not in STORED_STATUSES:
        stored = STATUS_PENDING
    if stored != STATUS_PENDING:
        return stored
    when = _to_epoch((req or {}).get("requested_at"))
    now_e = _to_epoch(now)
    if when is not None and now_e is not None and when < now_e:
        return STATUS_EXPIRED
    return STATUS_PENDING


def triage(req, event, now, suggested_at=None):
    """Apply a triage decision to a PENDING request and return a NEW dict (the
    input is never mutated). Returns the updated record with its new stored
    status; on `suggest`, `requested_at` is replaced by `suggested_at` so the
    proposal becomes the new asked-for time the visitor must confirm.

    Raises nothing on a bad event — returns a record carrying a `problem` key so
    the caller stays total. Only a request that is currently pending/expired may
    be triaged; acting on an already-settled row is a no-op that reports
    `already_settled` so the UI can refuse honestly (avoids double-approve)."""
    new_status = validate_event(event)
    out = dict(req or {})
    if new_status is None:
        out["problem"] = "bad_event"
        return out
    effective = compute_status(req, now)
    if effective not in (STATUS_PENDING, STATUS_EXPIRED):
        out["problem"] = "already_settled"
        return out
    out.pop("problem", None)
    out["status"] = new_status
    if event == "suggest":
        sa = _to_epoch(suggested_at)
        if sa is None:
            out["problem"] = "suggest_needs_time"
            out["status"] = STATUS_PENDING
            return out
        out["requested_at"] = suggested_at
        out["suggested_at"] = suggested_at
    return out


def set_priority(req, priority):
    """Return a NEW record with its priority tag changed (vip ⇄ normal). A bad
    priority is ignored (record returned unchanged) so the UI never corrupts a
    row from a stray value."""
    out = dict(req or {})
    if priority in PRIORITIES:
        out["priority"] = priority
    return out


def _sort_key(req, now):
    pr = (req or {}).get("priority", PRIORITY_NORMAL)
    st = compute_status(req, now)
    when = _to_epoch((req or {}).get("requested_at"))
    # None times sort after real times within the same bucket (big sentinel).
    return (
        _PRIORITY_RANK.get(pr, 1),
        _STATUS_RANK.get(st, 9),
        when if when is not None else float("inf"),
        str((req or {}).get("name") or ""),
    )


def order_queue(requests, now):
    """Return a NEW list of requests ordered for the triage queue: VIP first,
    then the rows that still need attention (pending → suggested → expired)
    before settled ones, then soonest-requested first, then name as a stable
    tiebreak. Deterministic — the Dart mirror sorts identically."""
    return sorted(list(requests or []), key=lambda r: _sort_key(r, now))


def filter_queue(requests, now, status=None, priority=None):
    """Filter by effective status and/or priority, THEN order. `status`/
    `priority` may each be None (any), a single value, or an iterable of values.
    Unknown filter values match nothing (honest empty rather than a silent
    everything)."""
    def _norm(sel):
        if sel is None:
            return None
        if isinstance(sel, (list, tuple, set, frozenset)):
            return set(sel)
        return {sel}

    want_status = _norm(status)
    want_pri = _norm(priority)
    out = []
    for r in requests or []:
        if want_status is not None and compute_status(r, now) not in want_status:
            continue
        if want_pri is not None and (r or {}).get("priority", PRIORITY_NORMAL) \
                not in want_pri:
            continue
        out.append(r)
    return order_queue(out, now)


def counts(requests, now):
    """A summary the UI badges/segments from: per-status counts, a VIP count,
    and `needs_attention` (pending + suggested + expired). Deterministic."""
    by_status = {s: 0 for s in STATUSES}
    vip = 0
    for r in requests or []:
        st = compute_status(r, now)
        by_status[st] = by_status.get(st, 0) + 1
        if (r or {}).get("priority", PRIORITY_NORMAL) == PRIORITY_VIP:
            vip += 1
    needs = (by_status[STATUS_PENDING] + by_status[STATUS_SUGGESTED]
             + by_status[STATUS_EXPIRED])
    return {
        "total": sum(1 for _ in (requests or [])),
        "by_status": by_status,
        "vip": vip,
        "needs_attention": needs,
    }


# ------------------------------------------------------------- privacy view

def _mask_contact(raw):
    """Mask a phone/email down to a non-identifying hint. Keeps only the last 4
    characters, dot-padded, so the owner can recognise a contact exists without
    the full value leaking into lists/exports. Empty → empty."""
    s = str(raw or "").strip()
    if not s:
        return ""
    tail = s[-4:]
    return "·" * max(0, min(len(s) - len(tail), 5)) + tail


def public_view(req, now):
    """A privacy-minimised projection of a request for the queue list. Strips
    the raw contact: exposes only whether one exists and a masked hint. This is
    what list screens / exports should render — the raw phone/email stays on the
    single server-side detail record and is never fanned out here.

        {
          "id", "name", "reason", "priority",
          "status",          # EFFECTIVE status at `now`
          "requested_at",
          "has_contact": bool,
          "contact_hint": "·····3210" | "",
          "is_vip": bool,
        }
    """
    r = req or {}
    raw = r.get("contact") or r.get("phone") or r.get("email") or ""
    pr = r.get("priority", PRIORITY_NORMAL)
    return {
        "id": r.get("id"),
        "name": str(r.get("name") or "").strip(),
        "reason": str(r.get("reason") or "").strip(),
        "priority": pr,
        "status": compute_status(r, now),
        "requested_at": r.get("requested_at"),
        "has_contact": bool(str(raw).strip()),
        "contact_hint": _mask_contact(raw),
        "is_vip": pr == PRIORITY_VIP,
    }
