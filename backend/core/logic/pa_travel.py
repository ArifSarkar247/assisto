"""
pa_travel.py — the deterministic engine behind PA SECRETARY MODE boss-trip
TRAVEL & ITINERARY builder (issue #112, SPEC v2.1 §14, ADVANCED).

The PA builds the BOSS's trip itinerary entirely by hand, offline, with NO key:
a trip (title + start/end dates), ordered LEGS (flight / train / car with from→to
and depart/arrive times), STAYS (hotel + check-in/out), MEETINGS on the road,
and a packing / prep CHECKLIST. It produces a deterministic printable itinerary
SUMMARY and a day-count / countdown — every time-dependent function takes `now`
(or dates) as an argument so the result is honest and the tests can pin it.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**,
**no live booking**. Mirrors the conventions of the other pa_*/logic modules.

HONEST, KEY-GATED — LIVE BOOKING SEAM (NEVER FABRICATES)
--------------------------------------------------------
Live booking (searching real flights/hotels and holding a real price/PNR) needs
a licensed BOOKING provider this engine does not bundle. So `booking_seam()`
HONESTLY returns `{required: True, mock: True, ...}` — the UI shows a "connect a
booking key" card and NOTHING is ever booked. We NEVER invent a flight number, a
price, or a confirmation. Prices that appear anywhere are only values the PA
typed as a manual estimate; the engine holds no money.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_travel_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Leg modes (neutral English seed keys; the UI localises them).
LEG_FLIGHT = "flight"
LEG_TRAIN = "train"
LEG_CAR = "car"
LEG_BUS = "bus"
LEG_LAUNCH = "launch"  # river launch / ferry — common in Bangladesh
LEG_MODES = (LEG_FLIGHT, LEG_TRAIN, LEG_CAR, LEG_BUS, LEG_LAUNCH)

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


# ------------------------------------------------------------- normalization

def normalize_trip(trip):
    """Coerce a dict into a clean trip header. Never raises; never invents
    dates."""
    t = dict(trip or {})
    return {
        "id": t.get("id"),
        "title": _clean(t.get("title")),
        "start": (str(t.get("start")).strip() if t.get("start") else ""),
        "end": (str(t.get("end")).strip() if t.get("end") else ""),
        "note": str(t.get("note") or ""),
    }


def normalize_leg(leg):
    """Coerce a dict into a clean travel leg. Unknown mode falls back to car."""
    x = dict(leg or {})
    mode = x.get("mode")
    if mode not in LEG_MODES:
        mode = LEG_CAR
    return {
        "id": x.get("id"),
        "trip_id": x.get("trip_id"),
        "mode": mode,
        "from_place": _clean(x.get("from_place")),
        "to_place": _clean(x.get("to_place")),
        "depart": (str(x.get("depart")).strip() if x.get("depart") else ""),
        "arrive": (str(x.get("arrive")).strip() if x.get("arrive") else ""),
        "ref": _clean(x.get("ref")),  # PNR / ticket no the PA typed (never ours)
        "note": str(x.get("note") or ""),
    }


def normalize_stay(stay):
    """Coerce a dict into a clean stay (hotel/guesthouse)."""
    x = dict(stay or {})
    return {
        "id": x.get("id"),
        "trip_id": x.get("trip_id"),
        "name": _clean(x.get("name")),
        "address": _clean(x.get("address")),
        "check_in": (str(x.get("check_in")).strip() if x.get("check_in") else ""),
        "check_out": (str(x.get("check_out")).strip() if x.get("check_out") else ""),
        "note": str(x.get("note") or ""),
    }


def normalize_meeting(meeting):
    """Coerce a dict into a clean on-the-road meeting."""
    x = dict(meeting or {})
    return {
        "id": x.get("id"),
        "trip_id": x.get("trip_id"),
        "title": _clean(x.get("title")),
        "place": _clean(x.get("place")),
        "at": (str(x.get("at")).strip() if x.get("at") else ""),
        "with_whom": _clean(x.get("with_whom")),
        "note": str(x.get("note") or ""),
    }


def normalize_pack(item):
    """Coerce a dict into a clean packing / prep checklist item."""
    x = dict(item or {})
    return {
        "id": x.get("id"),
        "trip_id": x.get("trip_id"),
        "label": _clean(x.get("label")),
        "checked": bool(x.get("checked")),
    }


# ------------------------------------------------------------------- validate

def validate_trip(trip):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.
    A title is required; start/end must parse if present; end must not be
    before start."""
    t = normalize_trip(trip)
    problems = []
    if not t["title"]:
        problems.append("title_required")
    start = _parse(t["start"]) if t["start"] else None
    end = _parse(t["end"]) if t["end"] else None
    if t["start"] and start is None:
        problems.append("bad_start")
    if t["end"] and end is None:
        problems.append("bad_end")
    if start and end and end < start:
        problems.append("end_before_start")
    return problems


def validate_leg(leg):
    """A leg needs a mode (always coerced valid) + a from and a to place."""
    x = normalize_leg(leg)
    problems = []
    if not x["from_place"]:
        problems.append("from_required")
    if not x["to_place"]:
        problems.append("to_required")
    if x["depart"] and _parse(x["depart"]) is None:
        problems.append("bad_depart")
    if x["arrive"] and _parse(x["arrive"]) is None:
        problems.append("bad_arrive")
    return problems


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"


def _event_key(ev, time_field):
    """Deterministic chronological key for legs/stays/meetings. Undated events
    sort AFTER dated ones; ties break on title-ish text then id for stability."""
    t = _parse(ev.get(time_field))
    key_time = t.isoformat() if t else _FAR
    label = (ev.get("title") or ev.get("name") or ev.get("from_place") or "")
    return (key_time, str(label).lower(), str(ev.get("id") or ""))


def order_legs(legs):
    """New list of normalized legs in chronological (depart) order."""
    normed = [normalize_leg(x) for x in (legs or [])]
    return sorted(normed, key=lambda x: _event_key(x, "depart"))


def order_meetings(meetings):
    normed = [normalize_meeting(x) for x in (meetings or [])]
    return sorted(normed, key=lambda x: _event_key(x, "at"))


def order_stays(stays):
    normed = [normalize_stay(x) for x in (stays or [])]
    return sorted(normed, key=lambda x: _event_key(x, "check_in"))


# ---------------------------------------------------------------- derived

def day_span(trip):
    """Inclusive whole-day count between start and end (≥1 when both parse,
    else 0). Deterministic — no clock. A single-day trip is 1."""
    t = normalize_trip(trip)
    start = _parse(t["start"])
    end = _parse(t["end"])
    if not start or not end or end < start:
        return 0
    return (end.date() - start.date()).days + 1


def countdown(trip, now):
    """Whole days from `now` (a datetime the caller supplies) until the trip
    starts. Negative/zero handled honestly:
        >0  → days until departure
         0  → starts today
        <0  → already started / past
    Returns None when there's no valid start date."""
    t = normalize_trip(trip)
    start = _parse(t["start"])
    if not start:
        return None
    return (start.date() - now.date()).days


def packing_progress(items):
    """{"total", "checked", "percent"} — percent is floor(checked/total*100),
    0 on empty. Order-independent, deterministic."""
    normed = [normalize_pack(x) for x in (items or [])]
    total = len(normed)
    checked = sum(1 for x in normed if x["checked"])
    percent = (checked * 100 // total) if total else 0
    return {"total": total, "checked": checked, "percent": percent}


# ---------------------------------------------------------------- summary

def itinerary_summary(trip, legs=None, stays=None, meetings=None, packing=None):
    """A deterministic, printable itinerary roll-up — pure structure the UI
    renders (no prose generated here). Counts + ordered events so the printable
    view is identical every time. Holds NO price and books NOTHING."""
    t = normalize_trip(trip)
    ol = order_legs(legs)
    ost = order_stays(stays)
    om = order_meetings(meetings)
    pack = packing_progress(packing)
    return {
        "trip": t,
        "days": day_span(t),
        "legs": ol,
        "stays": ost,
        "meetings": om,
        "packing": pack,
        "counts": {
            "legs": len(ol),
            "stays": len(ost),
            "meetings": len(om),
            "packing": pack["total"],
        },
        # honest: this summary is hand-built; nothing is booked or priced here.
        "mock": False,
        "booking_required": False,
    }


# ------------------------------------------------------- live-booking seam

def booking_seam(query=None):
    """DOCUMENTED key-gated seam for LIVE booking (flights/hotels/trains).

    Honest MOCK: never searches, never prices, never books. Returns the shape
    the integrator wires to a real booking provider when a `booking` key is
    present. Until then the UI shows a "connect a booking key" card and the PA
    builds the itinerary by hand. We NEVER fabricate a flight, price or PNR.
    """
    return {
        "action": "book",
        "query": _clean(query),
        "results": [],          # honest: empty — no provider, nothing invented
        "required": True,       # a booking key is required for a real search
        "mock": True,
        "marker": BOOKING_MARKER_KEY,
    }
