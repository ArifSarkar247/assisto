"""aifinal (owner AI order 3 Nov 23:15, PART 5): action buttons under an AI
answer. Up to 3, ONLY from this fixed allow-list of real in-app actions —
the model never invents one (it is not even asked): the server picks them
with simple bilingual keyword rules over the user's message. The app shows
each as a button; nothing runs until the user taps AND confirms, and the
opened screen keeps its own plan / credit rules (Safe Journey, alarms,
CCTV plans, invoices) — tapping a button costs nothing by itself.

Owner switch: ai_levels.actions_on (Owner Admin -> AI answer levels), OFF
by default."""
import re

MAX_ACTIONS = 3
# id -> app route (core/screen_synonyms / app ChatNav) or a special handler
ALLOWED = {
    "safe_journey": "journey",      # start Safe Journey + share live location
    "dest_alarm": "dest_alarm",     # destination alarm (train / bus)
    "reminder": "reminders",
    "invoice": "new_invoice",       # only for a user with a business
    "cctv": "watchman",
    "call_999": "tel:999",          # emergency call (confirm first)
}

_RULES = (
    ("call_999", r"accident|ambulance|fire\b|bleeding|unconscious|heart attack|emergency|"
                 r"দুর্ঘটনা|অ্যাম্বুলেন্স|আগুন|রক্ত|অজ্ঞান|জরুরি|durghotona|agun|ambulance"),
    ("safe_journey", r"safe journey|going home|travel(?:ling)? alone|late night|share (?:my )?"
                     r"location|live location|reach(?:ed)? safely|night bus|"
                     r"নিরাপদ যাত্রা|লোকেশন|বাড়ি ফির|একা যাচ্ছি|রাতে|পৌঁছে|nirapod|location"),
    ("dest_alarm", r"wake me|destination alarm|my stop|station|train|bus stop|don'?t miss|"
                   r"স্টেশন|ট্রেন|ঘুমিয়ে|নামতে|stop e|station e"),
    ("reminder", r"remind|reminder|don'?t forget|alarm at|tomorrow at|"
                 r"মনে করিয়ে|রিমাইন্ডার|ভুলে না|mone koriye|reminder"),
    ("invoice", r"invoice|bill (?:a|my) customer|receipt for|ইনভয়েস|চালান|রসিদ|invoice"),
    ("cctv", r"cctv|camera|watchman|shop camera|home camera|ক্যামেরা|সিসিটিভি|camera"),
)
_COMPILED = tuple((aid, re.compile(rx, re.I)) for aid, rx in _RULES)


def enabled():
    try:
        from . import ai_levels_service as ALS
        return bool(ALS.cfg()[0].get("actions_on"))
    except Exception:  # noqa: BLE001
        return False


def _has_business(user):
    try:
        from .models import BusinessProfile
        return BusinessProfile.objects.filter(user=user).exists()
    except Exception:  # noqa: BLE001
        return False


def suggest(user, text):
    """Up to MAX_ACTIONS ids from ALLOWED for this message (order = rule
    order: an emergency call first). [] when the switch is off."""
    if not enabled():
        return []
    t = str(text or "")[:2000]
    out = []
    for aid, rx in _COMPILED:
        if aid not in ALLOWED or not rx.search(t):
            continue
        if aid == "invoice" and not _has_business(user):
            continue
        out.append({"id": aid, "route": ALLOWED[aid]})
        if len(out) >= MAX_ACTIONS:
            break
    return out
