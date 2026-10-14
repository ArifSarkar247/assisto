"""
pa_biztravel.py — the deterministic engine behind PA SECRETARY MODE CORPORATE
BUSINESS TRAVEL & EVENTS (issue #119, SPEC v2.1 §14, ADVANCED).

This is the COMPANY / TEAM counterpart to the personal boss-trip builder
(#112, pa_travel.py). It is deliberately DISTINCT: an EVENT (name, date, venue)
with MANY ATTENDEES, per-attendee TRAVEL arrangements, a shared AGENDA, a
BUDGET (estimated vs actual, ৳), a LOGISTICS CHECKLIST and a countdown. Where
#112 is one person's itinerary, #119 is multi-attendee delegate coordination.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**,
**no live booking**. Every time-dependent function takes `now` as an argument so
results are honest and the tests can pin them. Mirrors the conventions of the
other pa_*/logic modules.

HONEST, KEY-GATED — LIVE BOOKING SEAM (NEVER FABRICATES)
--------------------------------------------------------
Live booking (searching real flights/hotels, holding a real price/PNR) needs a
licensed BOOKING provider this engine does not bundle. So `booking_seam()`
HONESTLY returns `{required: True, mock: True, ...}` — the UI shows a "connect a
booking key" card and NOTHING is ever booked. We NEVER invent a flight number, a
price, or a confirmation. Every ৳ figure that appears anywhere is only a value
the PA typed as a MANUAL estimate; the engine holds no money and settles nothing.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_biztravel_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Per-attendee travel mode (neutral English seed keys; the UI localises them).
TRAVEL_FLIGHT = "flight"
TRAVEL_TRAIN = "train"
TRAVEL_CAR = "car"
TRAVEL_BUS = "bus"
TRAVEL_LAUNCH = "launch"   # river launch / ferry — common in Bangladesh
TRAVEL_LOCAL = "local"     # already local / arranges own transport
TRAVEL_MODES = (TRAVEL_FLIGHT, TRAVEL_TRAIN, TRAVEL_CAR, TRAVEL_BUS,
                TRAVEL_LAUNCH, TRAVEL_LOCAL)

# Per-attendee arrangement status (coordination state the PA tracks by hand).
ARR_PENDING = "pending"
ARR_BOOKED = "booked"       # the PA recorded a ref the attendee/agent booked
ARR_CONFIRMED = "confirmed"
ARR_CANCELLED = "cancelled"
ARR_STATES = (ARR_PENDING, ARR_BOOKED, ARR_CONFIRMED, ARR_CANCELLED)

# Budget line categories (neutral seeds; UI localises). Used only to group.
BUDGET_CATS = ("travel", "venue", "lodging", "catering", "materials", "other")

# The honest marker key the live-booking seam carries. The UI renders the
# localised "connect a booking key — nothing is booked here" copy from this.
BOOKING_MARKER_KEY = "booking_seam"


# ------------------------------------------------------------------ parsing

def _parse(dt):
    """Lenient ISO-8601 → datetime, or None. Accepts a trailing 'Z'. Never
    raises — a bad/empty value simply has no time."""
    if not dt:
        return None
    s = str(dt).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _money(v):
    """Coerce a typed ৳ amount to a non-negative float, 0 on junk. The engine
    only ever ADDS values the PA typed; it never fabricates a price."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return 0.0
    if f != f or f in (float("inf"), float("-inf")):  # NaN / inf guard
        return 0.0
    return round(f, 2) if f > 0 else 0.0


# ------------------------------------------------------------- normalization

def normalize_event(event):
    """Coerce a dict into a clean corporate-event header. Never raises; never
    invents a date."""
    e = dict(event or {})
    return {
        "id": e.get("id"),
        "name": _clean(e.get("name")),
        "date": (str(e.get("date")).strip() if e.get("date") else ""),
        "end": (str(e.get("end")).strip() if e.get("end") else ""),
        "venue": _clean(e.get("venue")),
        "city": _clean(e.get("city")),
        "note": str(e.get("note") or ""),
    }


def normalize_attendee(att):
    """Coerce a dict into a clean attendee + their per-person travel. Unknown
    mode falls back to 'local'; unknown status to 'pending'. `cost` is a MANUAL
    estimate the PA typed (never ours)."""
    a = dict(att or {})
    mode = a.get("mode")
    if mode not in TRAVEL_MODES:
        mode = TRAVEL_LOCAL
    status = a.get("status")
    if status not in ARR_STATES:
        status = ARR_PENDING
    return {
        "id": a.get("id"),
        "event_id": a.get("event_id"),
        "name": _clean(a.get("name")),
        "role": _clean(a.get("role")),
        "mode": mode,
        "from_place": _clean(a.get("from_place")),
        "depart": (str(a.get("depart")).strip() if a.get("depart") else ""),
        "ref": _clean(a.get("ref")),      # PNR / ticket no the PA typed
        "status": status,
        "cost": _money(a.get("cost")),    # manual ৳ estimate; engine holds none
        "note": str(a.get("note") or ""),
    }


def normalize_agenda(item):
    """Coerce a dict into a clean agenda line (a session at the event)."""
    x = dict(item or {})
    return {
        "id": x.get("id"),
        "event_id": x.get("event_id"),
        "title": _clean(x.get("title")),
        "at": (str(x.get("at")).strip() if x.get("at") else ""),
        "speaker": _clean(x.get("speaker")),
        "note": str(x.get("note") or ""),
    }


def normalize_budget(line):
    """Coerce a dict into a clean budget line. `estimated`/`actual` are MANUAL
    ৳ values the PA typed; category falls back to 'other'."""
    x = dict(line or {})
    cat = x.get("category")
    if cat not in BUDGET_CATS:
        cat = "other"
    return {
        "id": x.get("id"),
        "event_id": x.get("event_id"),
        "label": _clean(x.get("label")),
        "category": cat,
        "estimated": _money(x.get("estimated")),
        "actual": _money(x.get("actual")),
    }


def normalize_task(task):
    """Coerce a dict into a clean logistics checklist item."""
    x = dict(task or {})
    return {
        "id": x.get("id"),
        "event_id": x.get("event_id"),
        "label": _clean(x.get("label")),
        "done": bool(x.get("done")),
    }


# ------------------------------------------------------------------- validate

def validate_event(event):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.
    A name is required; date/end must parse if present; end must not precede
    date."""
    e = normalize_event(event)
    problems = []
    if not e["name"]:
        problems.append("name_required")
    date = _parse(e["date"]) if e["date"] else None
    end = _parse(e["end"]) if e["end"] else None
    if e["date"] and date is None:
        problems.append("bad_date")
    if e["end"] and end is None:
        problems.append("bad_end")
    if date and end and end < date:
        problems.append("end_before_date")
    return problems


def validate_attendee(att):
    """An attendee needs a name (mode/status are always coerced valid)."""
    a = normalize_attendee(att)
    problems = []
    if not a["name"]:
        problems.append("name_required")
    if a["depart"] and _parse(a["depart"]) is None:
        problems.append("bad_depart")
    return problems


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"


def _event_key(ev, time_field):
    """Deterministic chronological key. Undated events sort AFTER dated ones;
    ties break on a label then id for stability."""
    t = _parse(ev.get(time_field))
    key_time = t.isoformat() if t else _FAR
    label = (ev.get("title") or ev.get("name") or "")
    return (key_time, str(label).lower(), str(ev.get("id") or ""))


def order_agenda(items):
    """New list of normalized agenda lines in chronological (at) order."""
    normed = [normalize_agenda(x) for x in (items or [])]
    return sorted(normed, key=lambda x: _event_key(x, "at"))


def order_attendees(atts):
    """Attendees ordered by departure time then name — so the coordination
    view is stable. Undated departures sort last."""
    normed = [normalize_attendee(x) for x in (atts or [])]
    return sorted(normed, key=lambda x: _event_key(x, "depart"))


# ---------------------------------------------------------------- derived

def day_span(event):
    """Inclusive whole-day count between date and end (≥1 when both parse,
    else 0). Deterministic — no clock. A single-day event is 1."""
    e = normalize_event(event)
    start = _parse(e["date"])
    end = _parse(e["end"])
    if not start:
        return 0
    if not end:
        return 1
    if end < start:
        return 0
    return (end.date() - start.date()).days + 1


def countdown(event, now):
    """Whole days from `now` (a datetime the caller supplies) until the event.
        >0  → days until the event
         0  → the event is today
        <0  → already happened / in progress
    Returns None when there's no valid event date."""
    e = normalize_event(event)
    date = _parse(e["date"])
    if not date:
        return None
    return (date.date() - now.date()).days


def attendee_rollup(attendees):
    """Deterministic coordination roll-up over attendees:
        total + a per-status count (pending/booked/confirmed/cancelled) +
        `unarranged` (pending) so the UI can nudge the PA. Order-independent."""
    normed = [normalize_attendee(x) for x in (attendees or [])]
    by_status = {s: 0 for s in ARR_STATES}
    for a in normed:
        by_status[a["status"]] += 1
    return {
        "total": len(normed),
        "by_status": by_status,
        "unarranged": by_status[ARR_PENDING],
        "confirmed": by_status[ARR_CONFIRMED],
    }


def budget_summary(lines, attendees=None):
    """Deterministic ৳ roll-up: estimated vs actual totals, variance
    (actual − estimated), per-category estimated/actual, plus the sum of the
    MANUAL per-attendee travel estimates. Holds NO money; sums only typed
    values; never prices anything itself.

    `variance > 0` means over the estimate; `< 0` under. All values rounded to
    2 decimals so the ৳ display is stable."""
    normed = [normalize_budget(x) for x in (lines or [])]
    est = round(sum(x["estimated"] for x in normed), 2)
    act = round(sum(x["actual"] for x in normed), 2)
    by_cat = {}
    for x in normed:
        c = by_cat.setdefault(x["category"], {"estimated": 0.0, "actual": 0.0})
        c["estimated"] = round(c["estimated"] + x["estimated"], 2)
        c["actual"] = round(c["actual"] + x["actual"], 2)
    travel_est = round(
        sum(normalize_attendee(a)["cost"] for a in (attendees or [])), 2)
    return {
        "estimated": est,
        "actual": act,
        "variance": round(act - est, 2),
        "over_budget": act > est,
        "by_category": by_cat,
        "attendee_travel_estimate": travel_est,
        "grand_estimate": round(est + travel_est, 2),
        # honest: every figure is a value the PA typed; nothing is priced here.
        "mock": False,
    }


def checklist_progress(tasks):
    """{"total", "done", "percent"} — percent is floor(done/total*100), 0 on
    empty. Order-independent, deterministic."""
    normed = [normalize_task(x) for x in (tasks or [])]
    total = len(normed)
    done = sum(1 for x in normed if x["done"])
    percent = (done * 100 // total) if total else 0
    return {"total": total, "done": done, "percent": percent}


# ---------------------------------------------------------------- summary

def event_summary(event, attendees=None, agenda=None, budget=None,
                  tasks=None, now=None):
    """A deterministic, printable event roll-up — pure structure the UI renders
    (no prose generated here). Ordered agenda/attendees + counts + budget +
    checklist so the printable view is identical every time. `now` (optional)
    feeds the countdown. Holds NO price and books NOTHING."""
    e = normalize_event(event)
    oa = order_attendees(attendees)
    oag = order_agenda(agenda)
    roll = attendee_rollup(attendees)
    bud = budget_summary(budget, attendees)
    chk = checklist_progress(tasks)
    cd = countdown(e, now) if now is not None else None
    return {
        "event": e,
        "days": day_span(e),
        "countdown": cd,
        "attendees": oa,
        "agenda": oag,
        "attendee_rollup": roll,
        "budget": bud,
        "checklist": chk,
        "counts": {
            "attendees": roll["total"],
            "agenda": len(oag),
            "budget_lines": len(bud["by_category"]),
            "tasks": chk["total"],
        },
        # honest: this summary is hand-built; nothing is booked or priced here.
        "mock": False,
        "booking_required": False,
    }


# ------------------------------------------------------- live-booking seam

def booking_seam(query=None):
    """DOCUMENTED key-gated seam for LIVE group booking (flights/hotels/venue).

    Honest MOCK: never searches, never prices, never books. Returns the shape
    the integrator wires to a real booking provider when a `booking` key is
    present. Until then the UI shows a "connect a booking key" card and the PA
    coordinates by hand. We NEVER fabricate a flight, price or PNR.
    """
    return {
        "action": "book",
        "query": _clean(query),
        "results": [],          # honest: empty — no provider, nothing invented
        "required": True,       # a booking key is required for a real search
        "mock": True,
        "marker": BOOKING_MARKER_KEY,
    }
