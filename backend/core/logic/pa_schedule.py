"""
pa_schedule.py — Assisto PA (Personal Assistant / Secretary) SCHEDULE control
(SPEC v2.1 §14 #103, ADVANCED §21).

A PA/secretary manages the OWNER's calendar: a day/week agenda of appointments
and meetings, with add/edit/delete slots, HONEST overlap (conflict) detection,
and a "next up" summary. This is the PA's own organized surface — it does NOT
replace the owner's personal Meetings screen (core.logic.meetings) but it SPEAKS
THE SAME SLOT SHAPE so the two never drift and the integrator can back both with
one table if desired.

This module is PURE, exactly like meetings.py / social.py:
  - no Django, no DB, no network, **no AI**
  - no hidden clock: every time-dependent call takes an explicit ``now``
  - deterministic: identical inputs → identical output

What lives here (logic/state only; notifications are a platform hook):
  - normalise/validate a PA schedule slot (title, start, duration, …)
  - overlap/conflict detection that returns HONEST, human-pairable results
    (which slots clash, and by how long) — never a silent "all clear"
  - day / week agenda bucketing for the PA's calendar view
  - a "next up" summary (the very next active slot relative to ``now``, with a
    minutes-until countdown and whether it is already in progress)

Benchmarked against the behaviour of Google / Apple Calendar + Calendly.
Everything here is hand-verified in pa_schedule_tests_snippets.py.
"""
from datetime import datetime, timedelta


# ---------------------------------------------------------------------------
# small shared helpers (kept local so this module is import-light & total)
# ---------------------------------------------------------------------------

def parse_dt(v):
    """Accept an ISO string or datetime; return a datetime or None.

    Mirrors meetings.parse_dt so the two surfaces agree on parsing.
    """
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _naive(dt):
    """Drop tzinfo for naive/aware-safe comparison (we never invent an offset)."""
    return dt.replace(tzinfo=None) if (dt is not None and dt.tzinfo) else dt


# ---------------------------------------------------------------------------
# validation / normalisation
# ---------------------------------------------------------------------------

DURATION_DEFAULT_MIN = 30
DURATION_MIN = 5
DURATION_MAX = 24 * 60  # a full day

# Slot kinds the PA distinguishes in the agenda (UI colours/icons off this).
KIND_MEETING = "meeting"
KIND_APPOINTMENT = "appointment"
KIND_CALL = "call"
KIND_TASK = "task"
KIND_BLOCK = "block"  # a held/busy block (focus time, travel, lunch)
KINDS = (KIND_MEETING, KIND_APPOINTMENT, KIND_CALL, KIND_TASK, KIND_BLOCK)

# Lifecycle status (mirrors meetings.STATUS_*; a PA also "confirms" a slot).
STATUS_TENTATIVE = "tentative"
STATUS_CONFIRMED = "confirmed"
STATUS_DONE = "done"
STATUS_CANCELLED = "cancelled"
STATUSES = (STATUS_TENTATIVE, STATUS_CONFIRMED, STATUS_DONE, STATUS_CANCELLED)


def clamp_duration(minutes):
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        return DURATION_DEFAULT_MIN
    return max(DURATION_MIN, min(DURATION_MAX, m))


def clean_kind(v):
    v = str(v or KIND_MEETING).strip().lower()
    return v if v in KINDS else KIND_MEETING


def clean_status(v):
    v = str(v or STATUS_CONFIRMED).strip().lower()
    return v if v in STATUSES else STATUS_CONFIRMED


def clean_people(raw):
    """Attendee display names: keep non-empty, de-duplicated, order-stable."""
    out, seen = [], set()
    for c in (raw or []):
        name = str(c).strip()
        if not name or name in seen:
            continue
        seen.add(name)
        out.append(name)
    return out


def validate_slot(payload):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    Required: a non-empty title and a parseable start time. We validate rather
    than silently "fix" so the UI can point at the offending field honestly.
    """
    payload = payload or {}
    problems = []
    if not str(payload.get("title", "")).strip():
        problems.append("title_required")
    if parse_dt(payload.get("start")) is None:
        problems.append("start_required")
    # duration, if explicitly given, must be a positive number
    if "duration_min" in payload and payload.get("duration_min") is not None:
        try:
            if int(payload["duration_min"]) <= 0:
                problems.append("bad_duration")
        except (TypeError, ValueError):
            problems.append("bad_duration")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


def normalise_slot(payload):
    """Clean a raw PA slot dict into a stored shape.

    Returns (ok, data_or_error_key). ``error`` is a machine key the UI localises
    (the FIRST problem from validate_slot). On success returns the normalised
    slot. ``id`` is passed through untouched if present (the integrator's PK).
    """
    problems = validate_slot(payload)
    if problems:
        return False, problems[0]
    payload = payload or {}
    start = parse_dt(payload.get("start"))
    out = {
        "title": str(payload.get("title", "")).strip(),
        "kind": clean_kind(payload.get("kind")),
        "start": start.isoformat(),
        "duration_min": clamp_duration(
            payload.get("duration_min", DURATION_DEFAULT_MIN)),
        "place": str(payload.get("place", "")).strip(),
        "people": clean_people(payload.get("people")),
        "note": str(payload.get("note", "")).strip(),
        "status": clean_status(payload.get("status")),
    }
    if payload.get("id") is not None:
        out["id"] = payload["id"]
    return True, out


def end_of(slot):
    """End datetime of a slot (start + duration). None if start unparseable."""
    s = parse_dt(slot.get("start"))
    if s is None:
        return None
    return s + timedelta(minutes=clamp_duration(
        slot.get("duration_min", DURATION_DEFAULT_MIN)))


def is_active(slot):
    """A slot still 'counts' for agenda/conflicts unless cancelled."""
    return clean_status(slot.get("status")) != STATUS_CANCELLED


# ---------------------------------------------------------------------------
# conflict (overlap) detection — HONEST
# ---------------------------------------------------------------------------

def _interval(slot):
    s = parse_dt(slot.get("start"))
    if s is None:
        return None
    s = _naive(s)
    e = s + timedelta(minutes=clamp_duration(
        slot.get("duration_min", DURATION_DEFAULT_MIN)))
    return (s, e)


def conflicts(slots):
    """Pairs of ACTIVE slots whose time ranges overlap.

    Returns a sorted list of dicts::

        {"a": i, "b": j, "overlap_min": m}   # i < j, m > 0

    where i/j are indices into the GIVEN ``slots`` list (so the UI can map a
    clash straight back to the two cards the owner is looking at) and
    ``overlap_min`` is the honest number of minutes they collide — never a
    vague "there may be a conflict".

    Cancelled slots are ignored. Back-to-back touching (end == next start) is
    NOT a conflict. Naive/aware datetimes are compared safely.
    """
    items = []
    for idx, s in enumerate(slots or []):
        if not is_active(s):
            continue
        iv = _interval(s)
        if iv is None:
            continue
        items.append((idx, iv[0], iv[1]))
    items.sort(key=lambda x: x[1])
    out = []
    for p in range(len(items)):
        ip, sp, ep = items[p]
        for q in range(p + 1, len(items)):
            iq, sq, eq = items[q]
            if sq >= ep:
                break  # sorted by start; nothing later can overlap p
            if sp < eq and sq < ep:  # genuine overlap
                ov_start = max(sp, sq)
                ov_end = min(ep, eq)
                overlap_min = int((ov_end - ov_start).total_seconds() // 60)
                if overlap_min <= 0:
                    continue
                a, b = sorted((ip, iq))
                out.append({"a": a, "b": b, "overlap_min": overlap_min})
    out.sort(key=lambda d: (d["a"], d["b"]))
    return out


def conflicting_indexes(slots):
    """Flat set of indexes that participate in ANY conflict (for per-card
    'clash' badges). Convenience over conflicts()."""
    idxs = set()
    for c in conflicts(slots):
        idxs.add(c["a"])
        idxs.add(c["b"])
    return sorted(idxs)


def has_conflicts(slots):
    return bool(conflicts(slots))


# ---------------------------------------------------------------------------
# agenda bucketing (day / week)
# ---------------------------------------------------------------------------

def _window(scope, anchor):
    """Half-open [start, end) window for a scope around an anchor datetime."""
    if scope == "week":
        start = datetime(anchor.year, anchor.month, anchor.day) - \
            timedelta(days=anchor.weekday())  # Monday
        end = start + timedelta(days=7)
    else:  # day (default)
        start = datetime(anchor.year, anchor.month, anchor.day)
        end = start + timedelta(days=1)
    return start, end


def agenda(slots, scope="day", anchor=None, now=None, include_cancelled=False):
    """Group slots into day buckets for the PA's calendar view.

    scope: 'day' | 'week'. anchor: reference date (defaults to ``now``/today).
    Returns a sorted list of::

        {"date": "YYYY-MM-DD", "items": [{"slot": <slot>, "index": <i>}, ...]}

    only for days inside the window that actually have slots (honest empty —
    no fabricated placeholder rows). ``index`` is the slot's position in the
    ORIGINAL list so edit/delete map straight back. Items within a day are
    ordered by start, then by title for stable ties. Cancelled slots are hidden
    unless ``include_cancelled`` is True (the PA may want to see cancellations).
    """
    now = now or datetime.now()
    anchor = parse_dt(anchor) or now
    start, end = _window(scope, _naive(anchor))

    buckets = {}
    for idx, s in enumerate(slots or []):
        if not include_cancelled and not is_active(s):
            continue
        sd = parse_dt(s.get("start"))
        if sd is None:
            continue
        sd = _naive(sd)
        if not (start <= sd < end):
            continue
        key = sd.strftime("%Y-%m-%d")
        buckets.setdefault(key, []).append((sd, str(s.get("title", "")), idx, s))
    out = []
    for key in sorted(buckets):
        rows = sorted(buckets[key], key=lambda x: (x[0], x[1]))
        out.append({"date": key,
                    "items": [{"slot": s, "index": i} for _, _, i, s in rows]})
    return out


# ---------------------------------------------------------------------------
# "next up" summary
# ---------------------------------------------------------------------------

def next_up(slots, now=None):
    """The PA's "next up" summary relative to ``now``.

    Considers only ACTIVE (non-cancelled, non-done) slots. Returns a dict::

        {
          "has_next": bool,
          "index": <int or None>,       # into the given list
          "slot":  <slot or None>,
          "in_progress": bool,          # now is inside the slot's window
          "minutes_until": <int or None>  # 0 if in progress / already started
        }

    "Next" = the active slot whose END is still in the future, ordered by start;
    an in-progress slot (started, not ended) wins over a later one. If nothing
    qualifies, has_next=False (honest empty — the UI shows a calm "nothing next"
    state, never a fake entry).
    """
    now = _naive(now or datetime.now())
    cand = []
    for idx, s in enumerate(slots or []):
        st = clean_status(s.get("status"))
        if st in (STATUS_CANCELLED, STATUS_DONE):
            continue
        sd = parse_dt(s.get("start"))
        if sd is None:
            continue
        sd = _naive(sd)
        ed = sd + timedelta(minutes=clamp_duration(
            s.get("duration_min", DURATION_DEFAULT_MIN)))
        if ed <= now:
            continue  # already finished
        cand.append((sd, ed, idx, s))
    if not cand:
        return {"has_next": False, "index": None, "slot": None,
                "in_progress": False, "minutes_until": None}
    # earliest start wins; an in-progress slot naturally has the earliest start
    cand.sort(key=lambda x: (x[0], x[2]))
    sd, ed, idx, slot = cand[0]
    in_progress = sd <= now < ed
    minutes_until = 0 if in_progress or sd <= now else \
        int((sd - now).total_seconds() // 60)
    return {"has_next": True, "index": idx, "slot": slot,
            "in_progress": in_progress, "minutes_until": minutes_until}


# ---------------------------------------------------------------------------
# day summary (small deterministic counts for the agenda header)
# ---------------------------------------------------------------------------

def day_summary(slots, scope="day", anchor=None, now=None):
    """Counts for the agenda header: total active slots in the window, how many
    clash, and the busiest day's slot count. Pure derivation over agenda() +
    conflicts() so the header can never disagree with the list."""
    days = agenda(slots, scope=scope, anchor=anchor, now=now)
    total = sum(len(d["items"]) for d in days)
    busiest = max((len(d["items"]) for d in days), default=0)
    # conflicts over the WHOLE list (the clash badge is global, not windowed,
    # so a cross-midnight overlap still surfaces honestly).
    clashes = len(conflicts(slots))
    return {"total": total, "days": len(days), "busiest_day": busiest,
            "conflicts": clashes}
