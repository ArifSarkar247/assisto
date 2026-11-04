"""wakeword (4 Nov) — the AI router behind "Hey Assisto" / Assisto Voice.

The phone's own bilingual parser (app/lib/voice/voice_intents.dart) handles
the common phrasings offline. When it does not understand a command, the app
asks this router: ONE cheap model call turns the words into exactly one of a
FIXED list of real phone actions, with its slots. The model never runs
anything and can never invent an action: anything outside the list, or any
malformed answer, becomes {"action": "none"} and the app falls back to the
normal Assisto agent. Every outgoing action still needs the user's tap /
spoken "yes" on the phone's confirm card.

POST /api/v1/voice/route {text, lang} ->
  {"action": "call"|"whatsapp"|"circle_message"|"alarm"|"reminder"|
              "care_call"|"safe_journey"|"navigate"|"none",
   "target"?, "message"?, "time"? ("HH:MM", 24 h), "day"? ("today"|"tomorrow"),
   "place"?, "reason"? (only for none)}
"""
import json
import re

from django.core.cache import cache
from django.utils import timezone

ACTIONS = ("call", "whatsapp", "circle_message", "alarm", "reminder",
           "care_call", "safe_journey", "navigate")
DAILY_CAP = 80  # router calls per user per day (cheap model; abuse guard)
MAX_TEXT = 300

TASK = (
    "You route ONE spoken phone command (Bangla, Banglish or English) to ONE action of a fixed list. "
    "Reply with ONE JSON object only, no prose. Keys: action, target, message, time, day, place.\n"
    "Actions:\n"
    "- call: phone call to a person. target = the person as said (e.g. 'Ma', 'Rahim bhai').\n"
    "- whatsapp: WhatsApp message. target = person, message = the text to send.\n"
    "- circle_message: write in Assisto My Circle (family/friends chat in this app). target = person, message = text.\n"
    "- alarm: alarm clock. time = HH:MM 24 h, day = today|tomorrow.\n"
    "- reminder: reminder. message = what to remember, time = HH:MM 24 h or empty, day = today|tomorrow.\n"
    "- care_call: Assisto Care Call (a scheduled check-in call for an elderly or sick family member). target = person, time optional.\n"
    "- safe_journey: start Assisto Safe Journey (share live location until arrival). place = destination or empty.\n"
    "- navigate: directions in Google Maps. place = destination.\n"
    "- none: anything else (questions, chat, other apps, unclear).\n"
    "Rules: never guess a phone number; keep the user's own words for message (same language); "
    "'sokal' = morning, 'bikal' = afternoon, 'rat' = night (pick a sensible 24 h time); "
    "'kal' after a time means tomorrow. Empty string for unknown keys."
)

_TIME = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")


def _s(v, n):
    v = " ".join(str(v or "").split())
    return v[:n]


def _first_json(text):
    """The first {...} object in the model text, or None."""
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def validate(d):
    """Model output -> safe route dict (fixed actions + bounded slots only)."""
    if not isinstance(d, dict):
        return {"action": "none", "reason": "bad_output"}
    a = str(d.get("action") or "").strip().lower()
    if a not in ACTIONS:
        return {"action": "none", "reason": "not_an_action"}
    out = {"action": a}
    target = _s(d.get("target"), 60)
    message = _s(d.get("message"), 500)
    place = _s(d.get("place"), 120)
    t = _s(d.get("time"), 5)
    day = _s(d.get("day"), 10).lower()
    if target:
        out["target"] = target
    if message:
        out["message"] = message
    if place:
        out["place"] = place
    if _TIME.match(t):
        h, m = t.split(":")
        out["time"] = f"{int(h):02d}:{m}"
    if day in ("today", "tomorrow"):
        out["day"] = day
    # an action without the slot it cannot work without is not an action
    if a in ("call", "whatsapp", "circle_message", "care_call") and "target" not in out:
        return {"action": "none", "reason": "missing_target"}
    if a == "navigate" and "place" not in out:
        return {"action": "none", "reason": "missing_place"}
    if a == "alarm" and "time" not in out:
        return {"action": "none", "reason": "missing_time"}
    if a == "reminder" and "message" not in out:
        return {"action": "none", "reason": "missing_message"}
    return out


def _cap_key(user):
    return f"va_route_n:{user.pk}:{timezone.localdate().isoformat()}"


def route(user, text, lang="bn"):
    from . import ai
    text = _s(text, MAX_TEXT)
    if not text:
        return {"action": "none", "reason": "empty"}
    k = _cap_key(user)
    used = cache.get(k, 0)
    if used >= DAILY_CAP:
        return {"action": "none", "reason": "daily_limit"}
    cache.set(k, used + 1, 60 * 60 * 26)
    try:
        out, _cost = ai.generate(task=TASK, data=text, tier="cheap", max_tokens=160,
                                 feature="voice_route", user=user, task_class="cheap",
                                 pii=True)
    except ai.AIUnavailable as e:
        return {"action": "none", "reason": getattr(e, "reason", "no_key") or "no_key"}
    except Exception:  # noqa: BLE001 — a provider hiccup never breaks the voice screen
        return {"action": "none", "reason": "error"}
    return validate(_first_json(out))
