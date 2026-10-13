"""
safety.py — Assisto family-safety logic (no AI key; pure Python, deterministic,
unit-testable). Benchmarked against Life360 / bSafe.

What lives here (logic/state only — the sensor + push hooks are platform-gated
and clearly marked for the integrator):

  - SOS countdown: a configurable delay (default 5s) with cancel, so an
    accidental trigger can be stopped before contacts are alerted.
  - Accident/fall detection CONFIG: default 2-minute "are you OK?" window
    (clamped 30s-10min), loud-alarm + vibration flags, large "I'm OK" dismissal.
    NOTE: the actual accelerometer/fall sensor is a platform plugin the app
    wires in natively — this module only models the response state machine.
  - Safe-arrival check-in: user says "I'll arrive by <time>". If they don't
    tap "arrived / পৌঁছেছি" by then (plus a grace), family is alerted.
  - Place-based geofence check (optional lat/lng + radius) to auto-confirm
    arrival if the app has a location fix.

Everything is bilingual via pick(); strings the UI shows come from here in both
languages, or the app localises from these machine values.

Run self-tests:
    python3 -c "import core.logic.safety as s; print(s.sos_phase(3,0))"
"""
from datetime import datetime, timedelta
from math import radians, sin, cos, asin, sqrt


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# SOS countdown
# ---------------------------------------------------------------------------

SOS_COUNTDOWN_DEFAULT = 5     # seconds
SOS_COUNTDOWN_MIN = 0
SOS_COUNTDOWN_MAX = 30


def clamp_sos_countdown(seconds):
    """Clamp a user-chosen SOS countdown into the allowed range.
    0 == fire immediately (no delay)."""
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return SOS_COUNTDOWN_DEFAULT
    return max(SOS_COUNTDOWN_MIN, min(SOS_COUNTDOWN_MAX, s))


def sos_phase(countdown_seconds, elapsed_seconds, cancelled=False):
    """State of an in-progress SOS.

    Returns ('counting', remaining) while the countdown runs,
            ('cancelled', 0) if the user cancelled,
            ('fired', 0) once the countdown elapsed (contacts should be alerted).
    A countdown of 0 fires immediately.
    """
    if cancelled:
        return ("cancelled", 0)
    cd = clamp_sos_countdown(countdown_seconds)
    remaining = cd - int(elapsed_seconds)
    if remaining <= 0:
        return ("fired", 0)
    return ("counting", remaining)


def sos_alert_targets(contacts):
    """Order in which SOS contacts are notified: primary (first) then the rest.
    Skips entries without a phone. Returns a flat ordered list of dicts."""
    out = [c for c in (contacts or []) if (c or {}).get("phone", "").strip()]
    return out


# ---------------------------------------------------------------------------
# accident / fall detection config  (sensor itself is platform-gated)
# ---------------------------------------------------------------------------

FALL_WINDOW_DEFAULT = 120     # seconds the "are you OK?" prompt waits
FALL_WINDOW_MIN = 30
FALL_WINDOW_MAX = 600         # 10 minutes


def clamp_fall_window(seconds):
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return FALL_WINDOW_DEFAULT
    return max(FALL_WINDOW_MIN, min(FALL_WINDOW_MAX, s))


def default_fall_config():
    """Default accident/fall-detection settings the UI edits."""
    return {
        "enabled": False,            # off until the user turns it on (battery honesty)
        "window_seconds": FALL_WINDOW_DEFAULT,
        "loud_alarm": True,
        "vibration": True,
        # the real detector is a native sensor plugin; this flag tells the app
        # whether that platform hook is present.
        "sensor_available": False,
    }


def fall_prompt_phase(window_seconds, elapsed_seconds, im_ok=False):
    """After a suspected fall, a big 'I'm OK' button shows for `window_seconds`.

    Returns ('waiting', remaining) while counting down,
            ('ok', 0) if the user tapped I'm OK (no alert),
            ('alert', 0) if the window elapsed with no response (alert family).
    """
    if im_ok:
        return ("ok", 0)
    w = clamp_fall_window(window_seconds)
    remaining = w - int(elapsed_seconds)
    if remaining <= 0:
        return ("alert", 0)
    return ("waiting", remaining)


# ---------------------------------------------------------------------------
# safe-arrival check-in
# ---------------------------------------------------------------------------

ARRIVAL_GRACE_DEFAULT = 15    # minutes past the expected time before alerting


def parse_dt(v):
    """Accept an ISO string or datetime; return a datetime or None."""
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def checkin_status(expected_arrival, now=None, arrived=False, grace_minutes=ARRIVAL_GRACE_DEFAULT):
    """State of a safe-arrival check-in.

    expected_arrival: the time the user said they'd arrive by (iso/datetime).
    Returns one of:
      ('arrived', 0)                  user tapped 'arrived / পৌঁছেছি'
      ('on_time', minutes_left)       before the deadline
      ('grace', minutes_into_grace)   past deadline, still within grace window
      ('overdue', minutes_overdue)    past deadline + grace -> ALERT FAMILY
      ('unknown', 0)                  no/invalid expected time
    Minutes are integers (never negative).
    """
    if arrived:
        return ("arrived", 0)
    eta = parse_dt(expected_arrival)
    if eta is None:
        return ("unknown", 0)
    now = now or datetime.now()
    # make both naive or both aware for safe subtraction
    if (eta.tzinfo is None) != (now.tzinfo is None):
        eta = eta.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    grace = max(0, int(grace_minutes))
    delta_min = (now - eta).total_seconds() / 60.0
    if delta_min < 0:
        return ("on_time", int(round(-delta_min)))
    if delta_min <= grace:
        return ("grace", int(delta_min))
    return ("overdue", int(delta_min))


def should_alert_checkin(expected_arrival, now=None, arrived=False, grace_minutes=ARRIVAL_GRACE_DEFAULT):
    """True when family should be alerted that the person hasn't checked in."""
    state, _ = checkin_status(expected_arrival, now=now, arrived=arrived,
                              grace_minutes=grace_minutes)
    return state == "overdue"


# ---------------------------------------------------------------------------
# optional geofence (auto-confirm arrival when a location fix is available)
# ---------------------------------------------------------------------------

def haversine_m(lat1, lng1, lat2, lng2):
    """Great-circle distance in metres between two lat/lng points."""
    r = 6371000.0
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlmb = radians(lng2 - lng1)
    a = sin(dphi / 2) ** 2 + cos(p1) * cos(p2) * sin(dlmb / 2) ** 2
    return 2 * r * asin(sqrt(a))


def within_place(cur_lat, cur_lng, place_lat, place_lng, radius_m=150):
    """True if the current position is within `radius_m` of the destination —
    used to auto-mark 'arrived' without a manual tap. None coords => False."""
    if None in (cur_lat, cur_lng, place_lat, place_lng):
        return False
    return haversine_m(cur_lat, cur_lng, place_lat, place_lng) <= max(1, radius_m)


# ---------------------------------------------------------------------------
# family alert payloads (integrator pushes these; foreground-poll today)
# ---------------------------------------------------------------------------

def checkin_overdue_payload(person_name, place_name, minutes_overdue, lang="bn"):
    place = place_name or pick(lang, "গন্তব্য", "the destination")
    return {
        "kind": "checkin_overdue",
        "title": pick(lang, "পৌঁছানোর খবর আসেনি", "No safe-arrival check-in"),
        "body": pick(lang,
            f"{person_name} {place}-এ পৌঁছানোর কথা জানায়নি "
            f"(আনুমানিক {minutes_overdue} মিনিট দেরি)। খোঁজ নিন।",
            f"{person_name} hasn't confirmed arriving at {place} "
            f"(about {minutes_overdue} min late). Please check on them."),
    }


def fall_alert_payload(person_name, lang="bn"):
    return {
        "kind": "fall_alert",
        "title": pick(lang, "সম্ভাব্য দুর্ঘটনা/পতন", "Possible accident / fall"),
        "body": pick(lang,
            f"{person_name}-এর ফোনে সম্ভাব্য পতন শনাক্ত হয়েছে এবং সাড়া পাওয়া যায়নি। "
            f"দ্রুত যোগাযোগ করুন।",
            f"A possible fall was detected on {person_name}'s phone with no response. "
            f"Please contact them urgently."),
    }


def sos_payload(person_name, maps_link=None, lang="bn"):
    loc = ""
    if maps_link:
        loc = pick(lang, f" অবস্থান: {maps_link}", f" Location: {maps_link}")
    return {
        "kind": "sos",
        "title": pick(lang, "জরুরি SOS", "Emergency SOS"),
        "body": pick(lang,
            f"{person_name} SOS পাঠিয়েছেন — এখনই সাহায্য দরকার।{loc}",
            f"{person_name} triggered an SOS — they need help now.{loc}"),
    }
