"""
cctv_ai_check.py — PURE rules for the AI check of an alert snapshot
(agent/cctvaicheck, owner CCTV order B: "AI check of the alert snapshot
only with a monthly AI cost cap per account"; audit W4 B3/B4).

POLICY (safety first): the alert is ALWAYS delivered first, exactly as
before. The AI only ADDS a label afterwards:
  * person / vehicle / animal seen -> "AI: মানুষ দেখা গেছে ৯২%"
  * nothing seen, AI fairly sure    -> "সম্ভবত ভুল সতর্কতা (AI কিছু দেখেনি)"
    (the owner uses it to tune zones; the alert is NOT hidden)
  * no key / switched off / over the monthly allowance / timeout / bad
    reply / provider too dear       -> an honest "AI যাচাই হয়নি — <why>"
Only the ONE still is sent — never video, never audio. The prompt asks for
a class + confidence and nothing else: no identification, no faces, no
accusation. Any reply carrying identity / accusation words is thrown away.
"""
import json
import re

CLASSES = ("person", "vehicle", "animal", "none")

# alert types that are about something in front of the camera (camera
# health / cash-register maths are not "is there a person?" questions)
CHECK_TYPES = ("person_detected", "zone_intrusion", "line_crossing", "camera_alarm",
               "motion", "after_hours", "loitering", "hand_in_cash_zone")

# "none" at or above this confidence -> "probably a false alarm"; below it
# the AI is unsure and we say so instead (never a strong claim on a weak read)
LIKELY_FALSE_MIN = 0.6
MAX_AGE_MIN = 30          # older alerts are not checked (the label would be late)
PER_TICK = 4              # checks per minute tick (bounded, like descriptions)
TIMEOUT_S = 20
MAX_TOKENS = 60
IMAGE_MAX_PX = 512        # the still is shrunk before sending: fewer tokens, cost

SYSTEM = (
    "You check ONE still photo from a home or shop security camera. Answer ONLY "
    "with compact JSON: {\"object\": \"person\"|\"vehicle\"|\"animal\"|\"none\", "
    "\"confidence\": 0-100}. 'object' is the main moving thing visible: person, "
    "vehicle (car, motorbike, rickshaw, cycle, van) or animal (dog, cat, cow, "
    "goat, bird); 'none' when no person, vehicle or animal is visible (empty "
    "scene, light change, shadow, rain, insect, leaves). Do NOT describe or "
    "identify anyone, do not mention faces, age, gender, religion or ethnicity, "
    "never say thief, criminal or suspicious. No other words.")
QUESTION = "Which one is visible: person, vehicle, animal or none? JSON only."

_BAD = re.compile(r"(চোর|ডাকাত|অপরাধী|সন্দেহজনক|thief|criminal|robber|burglar|"
                  r"suspicious|intruder|face|named?\b|\bhindu\b|\bmuslim\b|হিন্দু|মুসলিম)",
                  re.I)

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")

LABEL_BN = {"person": "মানুষ", "vehicle": "গাড়ি", "animal": "প্রাণী"}
LABEL_EN = {"person": "Person", "vehicle": "Vehicle", "animal": "Animal"}

# why the AI did NOT check — bn, en
NOT_CHECKED = {
    "no_key": ("AI যাচাই হয়নি — AI চাবি যুক্ত নেই", "AI not checked — no AI key connected"),
    "off": ("AI যাচাই বন্ধ (আপনি বন্ধ রেখেছেন)", "AI check off (you turned it off)"),
    "cap": ("AI যাচাই হয়নি — এই মাসের AI সীমা শেষ", "AI not checked — this month's AI allowance is used up"),
    "failed": ("AI যাচাই হয়নি — AI সময়মতো উত্তর দেয়নি", "AI not checked — the AI did not answer in time"),
    "no_photo": ("AI যাচাই হয়নি — ছবি নেই", "AI not checked — no photo"),
    "cost": ("AI যাচাই হয়নি — AI-র খরচ সীমার বেশি", "AI not checked — the AI costs more than the plan allows"),
    "pending": ("AI যাচাই চলছে…", "AI check in progress…"),
}


def bn_digits(s):
    return str(s).translate(_BN_DIGITS)


def parse_reply(text):
    """-> {"cls", "conf"} (conf 0..1) or None when unusable / unsafe."""
    if not isinstance(text, str) or not text.strip():
        return None
    if _BAD.search(text):
        return None
    m = re.search(r"\{.*?\}", text, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except (ValueError, TypeError):
        return None
    if not isinstance(d, dict):
        return None
    cls = str(d.get("object", "")).strip().lower()
    if cls not in CLASSES:
        return None
    try:
        conf = float(d.get("confidence"))
    except (TypeError, ValueError):
        return None
    if conf != conf:                       # NaN
        return None
    if conf > 1.0:
        conf = conf / 100.0
    conf = max(0.0, min(1.0, conf))
    return {"cls": cls, "conf": round(conf, 2)}


def result_of(parsed):
    """The stored signals["ai_check"] for a parsed answer."""
    likely_false = parsed["cls"] == "none" and parsed["conf"] >= LIKELY_FALSE_MIN
    return {"state": "done", "cls": parsed["cls"], "conf": parsed["conf"],
            "likely_false": likely_false}


def label(ai, lang="bn"):
    """The viewer-language payload for an alert: {state, cls, conf, likely_false,
    text}. `ai` is signals["ai_check"] (or a {"state": <reason>} stand-in)."""
    li = 0 if lang == "bn" else 1
    ai = ai if isinstance(ai, dict) else {}
    state = ai.get("state") or "no_key"
    out = {"state": state, "cls": None, "conf": None, "likely_false": False, "text": ""}
    if state != "done":
        out["state"] = state if state in NOT_CHECKED else "failed"
        out["text"] = NOT_CHECKED[out["state"]][li]
        return out
    cls = ai.get("cls")
    pct = int(round(float(ai.get("conf") or 0) * 100))
    p = bn_digits(pct) if li == 0 else str(pct)
    out.update(cls=cls, conf=ai.get("conf"), likely_false=bool(ai.get("likely_false")))
    if cls in LABEL_BN:
        out["text"] = ("AI: %s দেখা গেছে %s%%" % (LABEL_BN[cls], p) if li == 0
                       else "AI: %s seen %s%%" % (LABEL_EN[cls], p))
    elif out["likely_false"]:
        out["text"] = ("সম্ভবত ভুল সতর্কতা (AI কিছু দেখেনি, %s%% নিশ্চিত)" % p if li == 0
                       else "Probably a false alarm (AI saw nothing, %s%% sure)" % p)
    else:
        out["text"] = ("AI নিশ্চিত নয় — নিজে ছবিটা দেখুন" if li == 0
                       else "AI is not sure — please look at the photo")
    return out


def camera_switch(zone_config, key_ready):
    """Per-camera "AI দিয়ে যাচাই": the owner's explicit choice wins; unset =
    ON only when a vision key exists."""
    zc = zone_config if isinstance(zone_config, dict) else {}
    v = zc.get("ai_check")
    if isinstance(v, bool):
        return v and key_ready
    return bool(key_ready)


def check_cost_usd(provider_cost_usd, plan_check_usd):
    """What one check costs us: the provider's own per-image price when the
    owner set one, else the profit table's assumption. Returns (cost, ok):
    ok False = the provider is dearer than the plan allows (40% rule)."""
    try:
        prov = max(0.0, float(provider_cost_usd or 0))
    except (TypeError, ValueError):
        prov = 0.0
    plan = max(0.0, float(plan_check_usd or 0))
    if prov <= 0:
        return plan, True
    return prov, prov <= plan + 1e-12
