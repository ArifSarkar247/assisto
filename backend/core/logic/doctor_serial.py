"""
doctor_serial.py — pure, deterministic DOCTOR APPOINTMENT TRACKER logic
(#187, SPEC v2.1 §20, built to the §21 "advanced" standard).

A personal appointment book for doctor visits. The user records each
appointment — doctor, specialty, hospital/chamber, date & time, the SERIAL
NUMBER the chamber gave them, a status, and notes — and the tracker splits them
into UPCOMING and PAST, flags which are due for a reminder, and never loses a
record. It is a TRACKER, not medical advice and not a booking engine.

HONEST, KEY-GATED LIVE BOOKING
------------------------------
Booking a live serial through a healthcare partner (so the chamber's queue and
your app stay in sync) requires a BOOKING-PARTNER integration key. That key is
absent, so this module NEVER fabricates a booking or a serial number — it
exposes a documented SEAM (`booking_seam`) that honestly reports
`{"required": True, "configured": False, ...}` and a MOCK request shape the
integrator can later route to a real partner. Serial numbers only ever come
from what the USER typed in from their own chamber slip. We do not invent one.

HEALTH COPY DISCIPLINE
----------------------
This holds appointment records only. It gives NO medical advice, NO diagnosis,
NO triage. Copy stays in the "keep track of your visit" register; the Dart layer
renders a standing note to that effect.

HARD RULES
----------
  * PURE: no Django, no DB, no network, no live clock, no AI. `now` is always
    PASSED IN (an ISO-8601 string or a datetime) so the Dart mirror is identical
    offline and tests pin it. We parse date/time deterministically.
  * CONSERVATIVE: a reminder is DUE only within a window before the appointment
    and only for still-upcoming, not-cancelled appointments. The actual sending
    of a reminder (push/SMS) is a DOCUMENTED SEAM, not wired here — this module
    computes "is it due", nothing fires.
  * Human-facing copy is bilingual {"bn","en"}; ZERO Bangla lives in .dart.

PERSISTENCE (generic per-user JSON collection; integrator wires
'doctor/appointments' into GENERIC_COLLECTIONS in core/views.py — list
precedent, no migration):
    doctor/appointments → [{id, doctor, specialty, place, date, time, serial,
                            status, notes, created}]
This module holds no rows; the view persists them.

Run self-tests (no DB):
    python3 -c "import core.logic.doctor_serial_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime, timedelta


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary

# Appointment lifecycle. Stable keys; the UI localises each. "booked" = a normal
# tracked appointment; "done" = visited; "cancelled" = will not happen; "missed"
# = date passed without being marked done (computed, not stored) — see classify.
STATUSES = ("booked", "done", "cancelled")

# Reminder window: an upcoming, still-active appointment is "reminder due" when
# it is this many hours (or fewer) away. Conservative default = 24h.
REMINDER_WINDOW_HOURS = 24

# The booking-partner integration slug the LIVE seam would need. Absent today;
# the integrator registers it in integrations.py when a partner is signed.
BOOKING_PARTNER_SLUG = "health_booking"

# Only these fields are read off a stored row. Anything else is ignored.
_FIELDS = ("id", "doctor", "specialty", "place", "date", "time", "serial",
           "status", "notes", "created")


# ----------------------------------------------------------------- helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _as_dt(value):
    """Parse a datetime from an ISO-8601 string or a date/datetime object.
    Returns a naive datetime, or None on junk. Deterministic (no clock)."""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.replace(tzinfo=None)
    if isinstance(value, date):
        return datetime(value.year, value.month, value.day)
    s = str(value).strip().replace("Z", "").replace("T", " ").strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    # last resort: a valid date-only prefix (e.g. "2026-10-14 extra junk")
    try:
        return datetime.strptime(s[:10], "%Y-%m-%d")
    except ValueError:
        return None


def _combine(date_str, time_str):
    """Combine a stored date ('YYYY-MM-DD') and optional time ('HH:MM') into a
    naive datetime. Missing time ⇒ 00:00 (start of day) so date-only rows sort
    and classify predictably. Junk date ⇒ None."""
    d = _as_dt(date_str)
    if d is None:
        return None
    t = _clean(time_str)
    if t:
        for fmt in ("%H:%M:%S", "%H:%M"):
            try:
                parsed = datetime.strptime(t, fmt)
                return d.replace(hour=parsed.hour, minute=parsed.minute,
                                 second=0, microsecond=0)
            except ValueError:
                continue
    return d.replace(hour=0, minute=0, second=0, microsecond=0)


# ----------------------------------------------------------------- validate

def validate(doctor, date_str, place="", time_str="", serial="", status="booked"):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    * doctor name is required.
    * a date is required and must parse.
    * time, when given, must parse.
    * status must be a known lifecycle value.
    """
    problems = []
    if not _clean(doctor):
        problems.append("empty_doctor")
    if not _clean(date_str):
        problems.append("empty_date")
    elif _as_dt(date_str) is None:
        problems.append("bad_date")
    t = _clean(time_str)
    if t:
        ok = False
        for fmt in ("%H:%M:%S", "%H:%M"):
            try:
                datetime.strptime(t, fmt)
                ok = True
                break
            except ValueError:
                continue
        if not ok:
            problems.append("bad_time")
    if status not in STATUSES:
        problems.append("bad_status")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- classify

def _display(row):
    """Project a stored row to a safe display dict (whitelisted fields)."""
    row = row or {}
    status = row.get("status")
    if status not in STATUSES:
        status = "booked"
    return {
        "id": row.get("id"),
        "doctor": _clean(row.get("doctor")),
        "specialty": _clean(row.get("specialty")),
        "place": _clean(row.get("place")),
        "date": _clean(row.get("date")),
        "time": _clean(row.get("time")),
        "serial": _clean(row.get("serial")),
        "status": status,
        "notes": _clean(row.get("notes")),
        "created": _clean(row.get("created")),
    }


def classify_one(row, now):
    """Return a view dict for one appointment, with derived fields:
      when        — combined datetime (naive) or None
      bucket      — 'upcoming' | 'past'
      derived     — 'booked' | 'done' | 'cancelled' | 'missed'
      reminder_due— bool (only for upcoming, active 'booked' within window)
      hours_until — float hours until the appointment (negative if past),
                    or None when undated.
    `now` is PASSED IN (ISO string or datetime). Deterministic."""
    p = _display(row)
    now_dt = _as_dt(now)
    when = _combine(p["date"], p["time"])
    hours_until = None
    if when is not None and now_dt is not None:
        hours_until = (when - now_dt).total_seconds() / 3600.0

    # bucket: cancelled rows and rows whose time has passed go to 'past';
    # everything dated in the future (or undated active) is 'upcoming'.
    if p["status"] == "cancelled":
        bucket, derived = "past", "cancelled"
    elif when is None:
        # undated active appointment: keep it visible in upcoming as a to-schedule
        bucket, derived = "upcoming", p["status"] if p["status"] != "booked" else "booked"
    elif hours_until is not None and hours_until < 0:
        # the moment has passed
        if p["status"] == "done":
            bucket, derived = "past", "done"
        else:
            bucket, derived = "past", "missed"
    else:
        bucket = "upcoming"
        derived = p["status"]  # booked or done (done-but-future is user's call)

    reminder_due = bool(
        bucket == "upcoming"
        and p["status"] == "booked"
        and hours_until is not None
        and 0 <= hours_until <= REMINDER_WINDOW_HOURS
    )
    p["when"] = when.strftime("%Y-%m-%d %H:%M") if when else ""
    p["bucket"] = bucket
    p["derived"] = derived
    p["reminder_due"] = reminder_due
    p["hours_until"] = round(hours_until, 2) if hours_until is not None else None
    return p


def organise(rows, now):
    """Split appointments into upcoming (soonest first) and past (most recent
    first), count reminders due, and roll up status counts. Deterministic.

    Returns {"upcoming":[...], "past":[...], "reminders_due":int,
    "counts":{status:int}, "total":int}. `now` is PASSED IN."""
    views = [classify_one(r, now) for r in (rows or [])]
    upcoming = [v for v in views if v["bucket"] == "upcoming"]
    past = [v for v in views if v["bucket"] == "past"]

    # upcoming: soonest first (undated → treated as far future so they trail
    # dated ones but stay visible); stable by id for ties.
    def _up_key(v):
        h = v["hours_until"]
        return (h if h is not None else float("inf"), v.get("id") or 0)

    def _past_key(v):
        h = v["hours_until"]
        # most recent past first → largest (least negative) hours_until first
        return (h if h is not None else float("-inf"), v.get("id") or 0)

    upcoming.sort(key=_up_key)
    past.sort(key=_past_key, reverse=True)

    counts = {s: 0 for s in STATUSES}
    counts["missed"] = 0
    for v in views:
        counts[v["derived"]] = counts.get(v["derived"], 0) + 1
    reminders_due = sum(1 for v in upcoming if v["reminder_due"])
    return {
        "upcoming": upcoming,
        "past": past,
        "reminders_due": reminders_due,
        "counts": counts,
        "total": len(views),
    }


# ----------------------------------------------------------------- seams

def booking_seam(configured=False):
    """Describe the LIVE serial-booking partner seam, HONESTLY.

    LIVE booking (reserve a real serial in a chamber's queue) needs a healthcare
    BOOKING PARTNER integration. Absent today ⇒ configured=False. We never
    fabricate a booking or a serial; the tracker works fully as a manual log.
    Returns the honest state + the MOCK request shape the integrator would POST.
    """
    return {
        "feature": "live_serial_booking",
        "required": True,
        "configured": bool(configured),
        "partner_slug": BOOKING_PARTNER_SLUG,
        "mock": not configured,
        # The request SHAPE the integrator wires to a real partner later. Nothing
        # here calls out; serials still only come from the user's own slip.
        "request_shape": {
            "doctor": "str", "place": "str", "date": "YYYY-MM-DD",
            "time": "HH:MM", "patient": "str", "phone": "str",
        },
        "never_fabricates": True,
    }


def reminder_seam():
    """Describe the reminder-SENDING seam, HONESTLY. This module only COMPUTES
    which appointments are reminder-due (see organise → reminders_due). Actually
    SENDING a reminder (push via Firebase, or SMS) is wired by the integrator to
    the existing messaging integrations; nothing fires from here."""
    return {
        "feature": "appointment_reminder",
        "computes_due": True,
        "sends": False,
        "window_hours": REMINDER_WINDOW_HOURS,
        "channels": ("push", "sms"),
        "wired": False,
    }


def specialty_label(lang, key):
    """Bilingual label for a few common specialty keys (self-test parity; the
    Dart layer has its own localised getters). Unknown ⇒ echoed verbatim."""
    labels = {
        "general": ("জেনারেল ফিজিশিয়ান", "General physician"),
        "medicine": ("মেডিসিন", "Medicine"),
        "cardiology": ("হৃদরোগ", "Cardiology"),
        "dental": ("দন্ত", "Dental"),
        "gyne": ("গাইনি", "Gynaecology"),
        "child": ("শিশু", "Child / paediatrics"),
        "ortho": ("অর্থোপেডিক্স", "Orthopaedics"),
        "skin": ("চর্ম", "Skin"),
        "eye": ("চক্ষু", "Eye"),
        "ent": ("নাক-কান-গলা", "ENT"),
        "other": ("অন্যান্য", "Other"),
    }
    if key in labels:
        bn, en = labels[key]
        return pick(lang, bn, en)
    return _clean(key)
