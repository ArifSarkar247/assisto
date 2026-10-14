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


# ---------------------------------------------------------------------------
# verified BD emergency helpline directory  (item 12)
# Numbers VERIFIED 2026 against Daily Star / TBS / govt sources — see the
# emergency integration note. 999 is the primary national line (police + fire
# + ambulance, toll-free 24/7); the rest are specialist direct lines.
#   999  national emergency (police/fire/ambulance)
#   109  violence against women & children (MoWCA, toll-free)
#   333  government information service
#   102  fire service & civil defence
#   199  central ambulance coordination centre
#   100  police control room (999 is primary)
#   1090 disaster / weather warning (toll-free)
# ---------------------------------------------------------------------------

EMERGENCY_HELPLINES = [
    {"key": "national", "number": "999", "primary": True, "source": "999 (NTMC)",
     "bn": "জাতীয় জরুরি সেবা", "en": "National Emergency",
     "bn_note": "পুলিশ • ফায়ার • অ্যাম্বুলেন্স (টোল-ফ্রি, ২৪/৭)",
     "en_note": "Police • Fire • Ambulance (toll-free, 24/7)"},
    {"key": "women_child", "number": "109", "source": "MoWCA",
     "bn": "নারী ও শিশু নির্যাতন হেল্পলাইন", "en": "Women & Children Helpline",
     "bn_note": "নারী ও শিশু নির্যাতন (টোল-ফ্রি)",
     "en_note": "Violence against women & children (toll-free)"},
    {"key": "govt_info", "number": "333", "source": "a2i / Govt",
     "bn": "সরকারি তথ্যসেবা", "en": "Government Information",
     "bn_note": "সরকারি সেবা ও তথ্য", "en_note": "Government services & info"},
    {"key": "fire", "number": "102", "source": "Fire Service & Civil Defence",
     "bn": "ফায়ার সার্ভিস", "en": "Fire Service",
     "bn_note": "ফায়ার সার্ভিস ও সিভিল ডিফেন্স",
     "en_note": "Fire Service & Civil Defence"},
    {"key": "ambulance", "number": "199", "source": "Central Ambulance Coordination",
     "bn": "অ্যাম্বুলেন্স", "en": "Ambulance",
     "bn_note": "কেন্দ্রীয় অ্যাম্বুলেন্স সমন্বয় কেন্দ্র",
     "en_note": "Central Ambulance Coordination Centre"},
    {"key": "police", "number": "100", "source": "Bangladesh Police",
     "bn": "পুলিশ কন্ট্রোল রুম", "en": "Police Control Room",
     "bn_note": "৯৯৯-ই প্রধান জরুরি নম্বর", "en_note": "999 is the primary line"},
    {"key": "disaster", "number": "1090", "source": "BMD / DMD",
     "bn": "দুর্যোগ পূর্বাভাস", "en": "Disaster Warning",
     "bn_note": "আবহাওয়া ও দুর্যোগ (টোল-ফ্রি)",
     "en_note": "Weather & disaster (toll-free)"},
]


def emergency_helplines(lang="bn"):
    """Localised, verified BD helpline directory for the Emergency screen.
    Returns a flat list the UI renders as one-tap call rows. Primary (999)
    first. The app may also hard-code these; this is the single source."""
    out = []
    for h in EMERGENCY_HELPLINES:
        out.append({
            "key": h["key"],
            "number": h["number"],
            "primary": bool(h.get("primary")),
            "source": h.get("source", ""),
            "label": pick(lang, h["bn"], h["en"]),
            "note": pick(lang, h.get("bn_note", ""), h.get("en_note", "")),
        })
    return out


# ---------------------------------------------------------------------------
# first-aid quick cards  (source-named; NEVER a diagnosis — emergency -> 999)
# Steps are condensed from widely published first-aid guidance (Red Crescent /
# WHO). Each card names its source and repeats: this is not medical advice.
# ---------------------------------------------------------------------------

FIRST_AID_CARDS = [
    {"key": "bleeding", "source": "WHO / BDRCS",
     "bn_title": "ভারী রক্তক্ষরণ", "en_title": "Severe bleeding",
     "bn_steps": [
         "পরিষ্কার কাপড় দিয়ে ক্ষতস্থানে জোরে চাপ দিন।",
         "সম্ভব হলে আক্রান্ত অংশ হৃৎপিণ্ডের চেয়ে উঁচুতে রাখুন।",
         "চাপ ধরে রাখুন, কাপড় ভিজে গেলেও সরাবেন না—উপরে আরেকটি দিন।",
         "এখনই ৯৯৯-এ কল করুন।"],
     "en_steps": [
         "Press firmly on the wound with a clean cloth.",
         "Raise the injured part above heart level if you can.",
         "Keep pressing; if blood soaks through, add more cloth on top — don't remove it.",
         "Call 999 now."]},
    {"key": "choking", "source": "WHO / Red Cross",
     "bn_title": "গলায় কিছু আটকানো", "en_title": "Choking",
     "bn_steps": [
         "কাশতে উৎসাহ দিন; কথা বা শ্বাস না নিতে পারলে দ্রুত ব্যবস্থা নিন।",
         "পিঠের মাঝখানে হাতের গোড়া দিয়ে ৫ বার জোরে চাপড় দিন।",
         "তারপর পেটে (নাভির উপরে) ৫ বার ভিতর-উপরের দিকে চাপ দিন।",
         "ঠিক না হলে পালাক্রমে চালিয়ে যান ও ৯৯৯-এ কল করুন।"],
     "en_steps": [
         "Encourage coughing; act fast if they can't speak or breathe.",
         "Give 5 firm back blows between the shoulder blades.",
         "Then give 5 abdominal thrusts (above the navel, inward and up).",
         "Alternate until it clears; call 999."]},
    {"key": "burns", "source": "WHO",
     "bn_title": "পুড়ে যাওয়া", "en_title": "Burns",
     "bn_steps": [
         "কমপক্ষে ২০ মিনিট ঠান্ডা (বরফ নয়) পানির নিচে রাখুন।",
         "আংটি/ঘড়ি/টাইট কাপড় খুলে ফেলুন (ফোলার আগে)।",
         "পরিষ্কার, আঠা লাগে না এমন কিছু দিয়ে ঢাকুন। ফোস্কা ফাটাবেন না।",
         "বড়/গভীর পোড়া হলে ৯৯৯-এ কল করুন।"],
     "en_steps": [
         "Cool under running cool (not icy) water for at least 20 minutes.",
         "Remove rings/watch/tight clothing before swelling starts.",
         "Cover loosely with a clean non-stick cloth. Do not burst blisters.",
         "Call 999 for large or deep burns."]},
    {"key": "cpr", "source": "WHO / Red Cross",
     "bn_title": "সাড়া নেই / শ্বাস নেই (CPR)", "en_title": "Unresponsive / not breathing (CPR)",
     "bn_steps": [
         "সাড়া ও শ্বাস পরীক্ষা করুন; না থাকলে এখনই ৯৯৯-এ কল করুন।",
         "বুকের মাঝখানে হাত রেখে জোরে ও দ্রুত চাপ দিন (প্রতি মিনিটে ১০০–১২০ বার)।",
         "বুক প্রায় ৫ সেমি নামান, পুরোপুরি উঠতে দিন।",
         "সাহায্য বা প্রশিক্ষিত কেউ না আসা পর্যন্ত থামবেন না।"],
     "en_steps": [
         "Check response and breathing; if none, call 999 now.",
         "Push hard and fast in the centre of the chest (100–120 per minute).",
         "Press about 5 cm deep and let the chest fully rise.",
         "Don't stop until help or a trained person arrives."]},
    {"key": "faint", "source": "WHO",
     "bn_title": "অজ্ঞান / মাথা ঘোরা", "en_title": "Fainting / dizziness",
     "bn_steps": [
         "শুইয়ে দিয়ে দুই পা একটু উঁচু করুন।",
         "আঁটসাঁট কাপড় ঢিলা করুন, খোলা বাতাস দিন।",
         "জ্ঞান ফিরলে ধীরে উঠতে দিন; পানি দিন।",
         "দ্রুত না ফিরলে বা শ্বাসের সমস্যা হলে ৯৯৯-এ কল করুন।"],
     "en_steps": [
         "Lay them down and raise the legs a little.",
         "Loosen tight clothing and let in fresh air.",
         "When they come round, let them get up slowly; offer water.",
         "Call 999 if they don't recover quickly or struggle to breathe."]},
    {"key": "snakebite", "source": "WHO",
     "bn_title": "সাপের কামড়", "en_title": "Snakebite",
     "bn_steps": [
         "রোগীকে শান্ত ও স্থির রাখুন; আক্রান্ত অংশ নড়াচড়া কম করুন।",
         "কামড়ের স্থান হৃৎপিণ্ডের সমান বা নিচে রাখুন।",
         "কাটবেন না, চুষবেন না, বাঁধন দেবেন না—সময় নষ্ট করবেন না।",
         "এখনই ৯৯৯-এ কল করে হাসপাতালে নিন।"],
     "en_steps": [
         "Keep the person calm and still; move the limb as little as possible.",
         "Keep the bite at or below heart level.",
         "Do not cut, suck or tie a tourniquet — don't waste time.",
         "Call 999 and get to a hospital now."]},
]


def first_aid_cards(lang="bn"):
    """Localised first-aid quick cards. Never diagnoses; every card ends in
    'call 999'. Source-named so the UI can show attribution."""
    out = []
    for c in FIRST_AID_CARDS:
        out.append({
            "key": c["key"],
            "source": c.get("source", ""),
            "title": pick(lang, c["bn_title"], c["en_title"]),
            "steps": list(pick(lang, c["bn_steps"], c["en_steps"])),
        })
    return out


# ---------------------------------------------------------------------------
# emergency-card plain-text (for lock-screen share as text / image caption)
# ---------------------------------------------------------------------------

def emergency_card_text(card, lang="bn"):
    """Render the saved emergency card as a compact, shareable plain-text block.
    `card` is the dict the app stores (blood_group/allergies/medicines/
    conditions/contacts + optional doctor/insurance/nid/donor). Omits empty
    fields. Safe to put on a lock screen or paste to a responder."""
    card = card or {}

    def row(label_bn, label_en, val):
        v = (val or "").strip() if isinstance(val, str) else val
        if not v:
            return None
        return f"{pick(lang, label_bn, label_en)}: {v}"

    lines = [pick(lang, "জরুরি তথ্য কার্ড", "EMERGENCY CARD")]
    for ln in [
        row("নাম", "Name", card.get("name")),
        row("রক্তের গ্রুপ", "Blood group", card.get("blood_group")),
        row("অ্যালার্জি", "Allergies", card.get("allergies")),
        row("রোগ/অবস্থা", "Conditions", card.get("conditions")),
        row("ওষুধ", "Medicines", card.get("medicines")),
        row("ডাক্তার", "Doctor", card.get("doctor")),
        row("বীমা", "Insurance", card.get("insurance")),
        row("NID", "NID ref", card.get("nid")),
    ]:
        if ln:
            lines.append(ln)
    donor = card.get("organ_donor")
    if donor:
        lines.append(pick(lang, "অঙ্গদাতা: হ্যাঁ", "Organ donor: Yes"))
    contacts = [c for c in (card.get("contacts") or [])
                if (c or {}).get("phone", "").strip()]
    if contacts:
        lines.append(pick(lang, "জরুরি যোগাযোগ:", "Emergency contacts:"))
        for c in contacts:
            nm = (c.get("name") or "").strip()
            rel = (c.get("relation") or "").strip()
            ph = c.get("phone").strip()
            who = nm + (f" ({rel})" if rel else "")
            lines.append(f"  • {who}: {ph}" if who else f"  • {ph}")
    return "\n".join(lines)


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
