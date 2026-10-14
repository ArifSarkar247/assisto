"""
pa_lifestyle.py — the deterministic engine behind PA SECRETARY MODE (celebrity
tier) PERSONAL LIFESTYLE MANAGER (issue #125, SPEC v2.1 §14, ADVANCED).

A public-figure's PA keeps the principal's personal lifestyle in order by hand,
offline, with NO key: APPOINTMENTS (salon / gym / wellness / stylist / spa /
other — place, date/time), standing PREFERENCES (free notes the principal keeps,
e.g. "no nuts", "prefers morning gym"), daily ROUTINES (recurring items with a
time-of-day slot) and a reminders seam. This engine orders appointments,
splits them into upcoming vs past from a passed-in `now`, groups routines by
slot and tallies preferences.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.

PRIVACY — CONSERVATIVE
----------------------
This holds a public figure's PRIVATE lifestyle data. It therefore stays a
DEVICE-side organiser: it stores only what the PA typed, returns plain structure,
and never shares, publishes, geolocates or enriches anything. The reminders seam
(`reminder_seam()`) is a DOCUMENTED, key-gated hook — it NEVER sends a reminder
itself and never fabricates one; wiring a push/SMS provider is a later, opt-in
step. Nothing here leaves the device on its own.

Mirrors the conventions of the other pa_*/logic modules.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_lifestyle_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Appointment categories (neutral English seed keys; the UI localises them).
CAT_SALON = "salon"
CAT_GYM = "gym"
CAT_WELLNESS = "wellness"
CAT_STYLIST = "stylist"
CAT_SPA = "spa"
CAT_OTHER = "other"
APPT_CATEGORIES = (CAT_SALON, CAT_GYM, CAT_WELLNESS, CAT_STYLIST, CAT_SPA,
                   CAT_OTHER)

# Daily-routine time slots (morning / afternoon / evening / night).
SLOT_MORNING = "morning"
SLOT_AFTERNOON = "afternoon"
SLOT_EVENING = "evening"
SLOT_NIGHT = "night"
ROUTINE_SLOTS = (SLOT_MORNING, SLOT_AFTERNOON, SLOT_EVENING, SLOT_NIGHT)
_SLOT_RANK = {s: i for i, s in enumerate(ROUTINE_SLOTS)}

# The honest marker key the reminders seam carries. The UI renders the localised
# "reminders are a later, opt-in step" copy from this. It NEVER sends anything.
REMINDER_MARKER_KEY = "lifestyle_reminder_seam"


# ------------------------------------------------------------------ parsing

def _parse(dt):
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

def normalize_appt(appt):
    """Coerce a dict into a clean appointment. Unknown category → other. Never
    raises; never invents a place or a time."""
    x = dict(appt or {})
    cat = x.get("category")
    if cat not in APPT_CATEGORIES:
        cat = CAT_OTHER
    return {
        "id": x.get("id"),
        "category": cat,
        "title": _clean(x.get("title")),
        "place": _clean(x.get("place")),
        "at": (str(x.get("at")).strip() if x.get("at") else ""),
        "note": str(x.get("note") or ""),
    }


def normalize_pref(pref):
    """Coerce a dict into a clean standing preference. `topic` groups it (e.g.
    diet / wardrobe / travel); `text` is the principal's own note."""
    x = dict(pref or {})
    return {
        "id": x.get("id"),
        "topic": _clean(x.get("topic")) or "general",
        "text": str(x.get("text") or "").strip(),
    }


def normalize_routine(routine):
    """Coerce a dict into a clean daily-routine item. Unknown slot → morning."""
    x = dict(routine or {})
    slot = x.get("slot")
    if slot not in ROUTINE_SLOTS:
        slot = SLOT_MORNING
    return {
        "id": x.get("id"),
        "slot": slot,
        "label": _clean(x.get("label")),
        "time": _clean(x.get("time")),  # optional HH:MM the PA typed
    }


# ------------------------------------------------------------------- validate

def validate_appt(appt):
    """An appointment needs a title; at must parse if present."""
    x = normalize_appt(appt)
    problems = []
    if not x["title"]:
        problems.append("title_required")
    if x["at"] and _parse(x["at"]) is None:
        problems.append("bad_at")
    return problems


def validate_pref(pref):
    """A preference needs some text."""
    x = normalize_pref(pref)
    return [] if x["text"] else ["text_required"]


def validate_routine(routine):
    """A routine needs a label."""
    x = normalize_routine(routine)
    return [] if x["label"] else ["label_required"]


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"


def order_appts(appts):
    """Appointments chronological (soonest first); undated last. Stable."""
    normed = [normalize_appt(x) for x in (appts or [])]

    def key(a):
        d = _parse(a["at"])
        return (d.isoformat() if d else _FAR, a["title"].lower(),
                str(a.get("id") or ""))
    return sorted(normed, key=key)


# ---------------------------------------------------------------- derived

def split_appts(appts, now):
    """Split appointments into UPCOMING (at >= now, or undated) and PAST
    (at < now) from a passed-in `now`. Deterministic — no clock."""
    ordered = order_appts(appts)
    upcoming, past = [], []
    for a in ordered:
        at = _parse(a["at"])
        if at is None or at >= now:
            upcoming.append(a)
        else:
            past.append(a)
    return {
        "upcoming": upcoming,
        "past": past,
        "upcoming_count": len(upcoming),
        "past_count": len(past),
    }


def group_routines(routines):
    """Group daily-routine items by slot, slots in day order. Returns an ordered
    list of {"slot", "items"} so the UI renders a stable morning→night timeline.
    Within a slot: by typed time (untimed last), then label."""
    normed = [normalize_routine(x) for x in (routines or [])]
    buckets = {s: [] for s in ROUTINE_SLOTS}
    for r in normed:
        buckets[r["slot"]].append(r)

    def item_key(r):
        t = r["time"]
        return (t == "", t, r["label"].lower(), str(r.get("id") or ""))
    return [
        {"slot": s, "items": sorted(buckets[s], key=item_key)}
        for s in ROUTINE_SLOTS
    ]


def prefs_by_topic(prefs):
    """Group preferences by topic (alphabetical topics). Returns an ordered list
    of {"topic", "items"} + a total count. Deterministic."""
    normed = [normalize_pref(x) for x in (prefs or []) if normalize_pref(x)["text"]]
    topics = {}
    for p in normed:
        topics.setdefault(p["topic"], []).append(p)
    out = []
    for topic in sorted(topics, key=lambda s: s.lower()):
        items = sorted(topics[topic], key=lambda p: (p["text"].lower(),
                                                      str(p.get("id") or "")))
        out.append({"topic": topic, "items": items})
    return {"groups": out, "count": len(normed)}


# ------------------------------------------------------------- reminder seam

def reminder_seam(appt=None):
    """DOCUMENTED, opt-in key-gated seam for lifestyle reminders.

    Honest MOCK: never sends a reminder, never fabricates one, never leaves the
    device. Returns the shape the integrator wires to a push/SMS provider when
    the owner opts in. Until then the lifestyle manager is a private, on-device
    organiser only. Conservative by design — a public figure's private life.
    """
    a = normalize_appt(appt) if appt else None
    return {
        "action": "remind",
        "appt_id": (a["id"] if a else None),
        "scheduled": [],       # honest: empty — nothing is scheduled or sent
        "required": True,      # an opt-in reminder provider is required
        "mock": True,
        "marker": REMINDER_MARKER_KEY,
    }
