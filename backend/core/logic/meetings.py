"""
meetings.py — Assisto meetings/appointments logic (module-5 "Life").

Pure Python, deterministic, no AI key, unit-testable. Benchmarked against
Google Calendar / Apple Calendar / Calendly.

What lives here (logic/state only — notifications + Maps launch are platform
hooks the app wires):

  - normalise/validate an appointment payload (title, start, duration, place).
  - reminder offsets: produce the reminder fire-times for an appointment
    (default: 1 day + 1 hour + "leave now"), clamped & de-duplicated.
  - "Leave now / এখনই বের হন": given a travel-time estimate (best-effort,
    supplied by the app's Maps/dir API — we NEVER invent traffic), compute the
    moment the user should leave and whether that moment has arrived.
  - upcoming/agenda ordering and conflict (overlap) detection.
  - bilingual notification payloads via pick().

The travel-time itself is best-effort and provided by the caller; when it is
unknown we degrade gracefully (no "leave now", just the time reminders).
"""
from datetime import datetime, timedelta


def pick(lang, bn, en):
    return en if lang == "en" else bn


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


# ---------------------------------------------------------------------------
# validation / normalisation
# ---------------------------------------------------------------------------

DURATION_DEFAULT_MIN = 60
DURATION_MIN = 5
DURATION_MAX = 24 * 60  # a full day


def clamp_duration(minutes):
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        return DURATION_DEFAULT_MIN
    return max(DURATION_MIN, min(DURATION_MAX, m))


def normalise_appointment(payload):
    """Clean a raw appointment dict into a stored shape.

    Returns (ok, data_or_error). `error` is a machine key the UI localises.
    Required: a non-empty title and a parseable start time.
    """
    payload = payload or {}
    title = str(payload.get("title", "")).strip()
    if not title:
        return False, "title_required"
    start = parse_dt(payload.get("start"))
    if start is None:
        return False, "start_required"
    duration = clamp_duration(payload.get("duration_min", DURATION_DEFAULT_MIN))
    out = {
        "title": title,
        "start": start.isoformat(),
        "duration_min": duration,
        "place": str(payload.get("place", "")).strip(),
        "place_lat": payload.get("place_lat"),
        "place_lng": payload.get("place_lng"),
        "note": str(payload.get("note", "")).strip(),
    }
    return True, out


def end_time(start, duration_min):
    s = parse_dt(start)
    if s is None:
        return None
    return s + timedelta(minutes=clamp_duration(duration_min))


# ---------------------------------------------------------------------------
# reminder offsets
# ---------------------------------------------------------------------------

# Default "remind me before" offsets, in minutes before the start.
DEFAULT_REMINDER_OFFSETS = [24 * 60, 60]  # 1 day, 1 hour


def reminder_times(start, offsets_min=None, now=None):
    """Fire-times (datetimes) for an appointment's reminders.

    offsets_min: minutes-before-start; defaults to DEFAULT_REMINDER_OFFSETS.
    Drops offsets that are already in the past relative to `now` (so we don't
    schedule a reminder that should have fired). De-duplicated, sorted ascending.
    """
    s = parse_dt(start)
    if s is None:
        return []
    now = now or datetime.now()
    if (s.tzinfo is None) != (now.tzinfo is None):
        s = s.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    offsets = offsets_min if offsets_min is not None else DEFAULT_REMINDER_OFFSETS
    seen = set()
    out = []
    for off in offsets:
        try:
            o = max(0, int(off))
        except (TypeError, ValueError):
            continue
        t = s - timedelta(minutes=o)
        if t <= now:
            continue
        key = t.isoformat()
        if key in seen:
            continue
        seen.add(key)
        out.append(t)
    return sorted(out)


# ---------------------------------------------------------------------------
# "Leave now" — best-effort travel time (provided by caller, never invented)
# ---------------------------------------------------------------------------

LEAVE_BUFFER_DEFAULT_MIN = 5  # small cushion so you're not exactly on time


def leave_at(start, travel_minutes, buffer_min=LEAVE_BUFFER_DEFAULT_MIN):
    """When to leave = start - travel_time - buffer.

    travel_minutes is a best-effort estimate the app sourced from a Maps/
    directions API (or the user typed). None => we can't compute "leave now".
    Returns a datetime or None.
    """
    s = parse_dt(start)
    if s is None or travel_minutes is None:
        return None
    try:
        tv = max(0, int(travel_minutes))
    except (TypeError, ValueError):
        return None
    buf = max(0, int(buffer_min))
    return s - timedelta(minutes=tv + buf)


def leave_now_phase(start, travel_minutes, now=None,
                    buffer_min=LEAVE_BUFFER_DEFAULT_MIN):
    """State of the "leave now" nudge.

    Returns:
      ('unknown', 0)              no travel estimate -> no nudge
      ('later', minutes_until)    not time to leave yet
      ('leave_now', minutes_late) you should leave now (>=0 min past leave_at)
    Minutes are non-negative ints.
    """
    la = leave_at(start, travel_minutes, buffer_min=buffer_min)
    if la is None:
        return ("unknown", 0)
    now = now or datetime.now()
    if (la.tzinfo is None) != (now.tzinfo is None):
        la = la.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    delta_min = (la - now).total_seconds() / 60.0
    if delta_min > 0:
        return ("later", int(round(delta_min)))
    return ("leave_now", int(round(-delta_min)))


def maps_dir_url(place=None, lat=None, lng=None):
    """Google-Maps *directions* deep link to the appointment place.

    Prefers precise lat/lng; falls back to a place-name query. Returns None if
    we have nothing to route to. We only build the provider's own URL — we never
    fake travel time or a route.
    """
    if lat is not None and lng is not None:
        return f"https://www.google.com/maps/dir/?api=1&destination={lat},{lng}"
    if place:
        from urllib.parse import quote
        return ("https://www.google.com/maps/dir/?api=1&destination="
                + quote(str(place)))
    return None


# ---------------------------------------------------------------------------
# agenda ordering + conflict detection
# ---------------------------------------------------------------------------

def upcoming(appointments, now=None, within_days=None):
    """Future appointments sorted by start ascending.

    within_days: if set, only those starting within that many days.
    Items without a valid start are dropped.
    """
    now = now or datetime.now()
    out = []
    for a in (appointments or []):
        s = parse_dt(a.get("start"))
        if s is None:
            continue
        n = now
        if (s.tzinfo is None) != (n.tzinfo is None):
            s = s.replace(tzinfo=None)
            n = n.replace(tzinfo=None)
        if s < n:
            continue
        if within_days is not None and s > n + timedelta(days=within_days):
            continue
        out.append((s, a))
    out.sort(key=lambda x: x[0])
    return [a for _, a in out]


def _interval(a):
    s = parse_dt(a.get("start"))
    if s is None:
        return None
    e = s + timedelta(minutes=clamp_duration(a.get("duration_min",
                                                    DURATION_DEFAULT_MIN)))
    return (s, e)


def conflicts(appointments):
    """Pairs of appointments whose time ranges overlap.

    Returns a list of (i, j) index pairs (i < j) into the given list. Open-ended
    touching (end == next start) is NOT a conflict. Naive/aware mixed safely.
    """
    items = []
    for idx, a in enumerate(appointments or []):
        iv = _interval(a)
        if iv is None:
            continue
        s, e = iv
        if s.tzinfo is not None:
            s = s.replace(tzinfo=None)
            e = e.replace(tzinfo=None)
        items.append((idx, s, e))
    items.sort(key=lambda x: x[1])
    out = []
    for p in range(len(items)):
        ip, sp, ep = items[p]
        for q in range(p + 1, len(items)):
            iq, sq, eq = items[q]
            if sq >= ep:
                break  # sorted; no later item can overlap p
            # overlap when sq < ep and sp < eq
            if sp < eq and sq < ep:
                out.append(tuple(sorted((ip, iq))))
    return sorted(set(out))


# ---------------------------------------------------------------------------
# bilingual notification payloads
# ---------------------------------------------------------------------------

def reminder_payload(title, minutes_before, place="", lang="bn"):
    when = _humanize_before(minutes_before, lang)
    where = ""
    if place:
        where = pick(lang, f" — {place}", f" — {place}")
    return {
        "kind": "appointment_reminder",
        "title": pick(lang, "অ্যাপয়েন্টমেন্ট মনে করিয়ে দেওয়া", "Appointment reminder"),
        "body": pick(lang,
            f"{title}{where} {when} পরে।",
            f"{title}{where} in {when}."),
    }


def leave_now_payload(title, place="", travel_minutes=None, lang="bn"):
    tv = ""
    if travel_minutes is not None:
        tv = pick(lang,
                  f" (আনুমানিক {int(travel_minutes)} মিনিট পথ)",
                  f" (about {int(travel_minutes)} min away)")
    where = f" — {place}" if place else ""
    return {
        "kind": "appointment_leave_now",
        "title": pick(lang, "এখনই বের হন", "Leave now"),
        "body": pick(lang,
            f"{title}{where} এর জন্য এখন রওনা দিন{tv}।",
            f"Time to leave for {title}{where}{tv}."),
    }


def _humanize_before(minutes, lang):
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        m = 0
    if m >= 1440 and m % 1440 == 0:
        d = m // 1440
        return pick(lang, f"{d} দিন", f"{d} day" + ("s" if d != 1 else ""))
    if m >= 60 and m % 60 == 0:
        h = m // 60
        return pick(lang, f"{h} ঘণ্টা", f"{h} hour" + ("s" if h != 1 else ""))
    return pick(lang, f"{m} মিনিট", f"{m} min")
