"""
Voice-command intent mapping (deterministic, no AI, no network).

A "voice command" is a short utterance the user *speaks* to drive the app
(bn / Banglish / en). Speech-to-text happens on the device (key/engine gated —
see the Flutter side); this module takes the *transcript text* and decides what
the app should DO with it. It is pure text → structured intent, so it is easy to
unit-test and reuse from both the app (conceptually, mirrored on-device) and the
server (`/agent` can attach `voice` metadata to its reply).

Design:
  * Reuses the SAME canonical screen routes as `core.screen_synonyms` so "open X"
    lands on the exact same screen as typed chat (zero new vocabulary to learn).
  * Reuses the DATE/MONEY parsers conceptually: for a `reminder` command we hand
    the leftover text to `nlp_datetime.parse`; for an `expense` command we pull a
    number out the way `money_parse` does (digit-normalised, first currency
    token). We import them lazily so this module stays import-cheap and testable
    in isolation.
  * Deterministic: same transcript always yields the same intent. No AI call.
  * NEVER fabricates a transcript — that is the device's job and is gated; this
    module only ever receives text that the user actually said.

Public API:
    map_command(text, now=None) -> dict:
        {
          "intent":  one of INTENTS,
          "route":   canonical screen route or None,
          "title":   cleaned-up subject for display/confirmation (str),
          "args":    intent-specific payload (dict),
          "confirm": True  # the app MUST show a confirm step before acting
        }
        or None when the utterance is empty.

The caller (app) is expected to render "I understood: <...>" + a Confirm button
and only then perform the mapped action. `confirm` is always True for any intent
that mutates data or dials a number; it stays True for navigation too so the UX
is consistent (the app may auto-confirm pure navigation if it chooses).
"""

import re

# ---- intents the voice layer can recognise ---------------------------------
INTENT_OPEN = "open"          # navigate to a screen
INTENT_REMINDER = "reminder"  # add a reminder / alarm
INTENT_EXPENSE = "expense"    # log a spend / expense
INTENT_CALL = "call"          # call a family / circle member
INTENT_SOS = "sos"            # trigger emergency / SOS
INTENT_UNKNOWN = "unknown"    # understood speech, no actionable intent

INTENTS = (
    INTENT_OPEN, INTENT_REMINDER, INTENT_EXPENSE,
    INTENT_CALL, INTENT_SOS, INTENT_UNKNOWN,
)

# ---- trigger vocabularies (bn + Banglish + en), all lowercased -------------
# SOS is checked FIRST and wins over everything (safety-critical).
_SOS_WORDS = [
    "sos", "emergency", "help me", "save me", "danger",
    "বিপদ", "বাঁচাও", "সাহায্য করো", "জরুরি", "ইমার্জেন্সি",
    "bachao", "bipod", "shahajjo", "emergency",
]

# "call <someone>" — the circle/family dial intent.
_CALL_WORDS = [
    "call ", "phone ", "dial ", "ring ",
    "কল করো", "কল দাও", "ফোন করো", "ফোন দাও", "ফোন লাগাও",
    "call koro", "call dao", "phone koro", "phone dao",
]

# add-a-reminder.
_REMINDER_WORDS = [
    "remind me", "set a reminder", "set reminder", "set an alarm", "alarm",
    "মনে করিয়ে", "রিমাইন্ডার দাও", "রিমাইন্ডার সেট", "অ্যালার্ম দাও", "মনে রাখিস",
    "mone koriye", "reminder dao", "alarm dao",
]

# log-an-expense.
_EXPENSE_WORDS = [
    "i spent", "add expense", "log expense", "spent ", "expense of",
    "খরচ করেছি", "খরচ হয়েছে", "খরচ লেখো", "খরচ যোগ", "টাকা খরচ",
    "khoroch korechi", "khoroch holo", "expense add",
]

# explicit "open/show the screen" verbs (mirrors chatnav._openVerbs, bilingual).
_OPEN_VERBS = [
    "open ", "show ", "go to ", "take me to ", "view ", "see my ", "see ",
    "খোলো", "দেখাও", "যাও", "নিয়ে যাও", "খুলে দাও", "ওপেন করো",
    "kholo", "dekhao", "open koro",
]


def _lower(text):
    return (text or "").strip().lower()


def _has_any(low, words):
    return any(w in low for w in words)


def _matched_word(low, words):
    # longest trigger first: "call dao" must win over "call " (aieval)
    for w in sorted(words, key=len, reverse=True):
        if w in low:
            return w
    return None


# dative / connector words around a spoken name: "রহিমকে", "রহিম কে",
# "Rahim ke", "call to Rahim" -> the name alone (aieval).
_NAME_TAIL = re.compile(r"(?:\s*-?কে|\s+ke|\s+k)$", re.I)
_NAME_HEAD = re.compile(r"^(?:to|ke)\s+", re.I)


def _clean_name(who):
    w = (who or "").strip(" ,।.-")
    w = re.sub(r"\s+(?:please|plz|pls|now|ekhon|এখন)$", "", w, flags=re.I)
    prev = None
    while prev != w:
        prev = w
        w = _NAME_HEAD.sub("", w)
        w = _NAME_TAIL.sub("", w).strip(" ,।.-")
    return w


_REMINDER_NOUNS = ("রিমাইন্ডার", "reminder")


def _strip_trigger(text, trigger):
    """Remove the first occurrence of `trigger` (case-insensitive) from text."""
    if not trigger:
        return (text or "").strip()
    low = (text or "").lower()
    i = low.find(trigger)
    if i < 0:
        return (text or "").strip()
    out = text[:i] + text[i + len(trigger):]
    return out.strip(" ,।.-")


# ---- expense amount: digit-normalise + first currency token (money_parse-style)
def _first_amount(text):
    """
    Pull the first number out of the text the way money_parse does, after
    digit-normalising Bangla numerals. Returns (amount:int|float|None).
    """
    try:
        from .money_parse import normalize_digits
        norm = normalize_digits(text or "")
    except Exception:
        norm = text or ""
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)", norm)
    if not m:
        return None
    raw = m.group(1).replace(",", "")
    try:
        val = float(raw)
    except ValueError:
        return None
    return int(val) if val == int(val) else val


# ---- reminder when: hand the text to nlp_datetime (conceptual reuse) -------
def _reminder_when(text, now=None):
    """
    Returns a dict describing the parsed schedule, or an empty dict when the
    date parser finds nothing (the app then asks the user to pick a time).
    Never raises — a parser miss just means "no time understood yet".
    """
    try:
        from . import nlp_datetime
        parsed = nlp_datetime.parse(text or "", now=now)
    except Exception:
        return {}
    if not parsed:
        return {}
    # Keep only the JSON-friendly, display-relevant fields.
    out = {}
    for k in ("datetime", "date", "time", "recurrence", "confidence", "title"):
        if isinstance(parsed, dict) and parsed.get(k) is not None:
            v = parsed[k]
            out[k] = v.isoformat() if hasattr(v, "isoformat") else v
    return out


def _expense_date(text, now=None):
    """ISO date an expense refers to: past-biased (bare কাল = yesterday, পরশু =
    2 days ago), never in the future, today when no day word. Never raises."""
    try:
        from . import nlp_datetime
        return nlp_datetime.expense_date(text or "", now=now).isoformat()
    except Exception:
        return None


def _resolve_route(text):
    """Resolve a screen route via the shared synonym map (bn + en)."""
    try:
        from .. import screen_synonyms
        return screen_synonyms.resolve(text)
    except Exception:
        return None


def map_command(text, now=None):
    """Map a spoken transcript to a structured, confirmable intent. See module docstring."""
    if not text or not text.strip():
        return None
    low = _lower(text)

    # 1. SOS — safety first, beats everything.
    if _has_any(low, _SOS_WORDS):
        return {
            "intent": INTENT_SOS,
            "route": "emergency",
            "title": text.strip(),
            "args": {},
            "confirm": True,
        }

    # 2. call <someone> — unless it is a reminder ABOUT calling ("ammu ke call
    #    dite mone koriye dio" is a reminder, aieval)
    if _has_any(low, _CALL_WORDS) and not _has_any(low, _REMINDER_WORDS):
        trig = _matched_word(low, _CALL_WORDS)
        who = _clean_name(_strip_trigger(text, trig))
        return {
            "intent": INTENT_CALL,
            "route": "circle",
            "title": who or text.strip(),
            "args": {"name": who},
            "confirm": True,
        }

    # 3. add reminder ("... রিমাইন্ডার" with a date/time and no open verb is
    #    a new reminder, not "open the reminders screen" — aieval)
    if _has_any(low, _REMINDER_NOUNS) and not _has_any(low, _OPEN_VERBS) \
            and not _has_any(low, _REMINDER_WORDS) and _reminder_when(text, now=now).get("datetime"):
        body = _strip_trigger(text, _matched_word(low, _REMINDER_NOUNS))
        return {
            "intent": INTENT_REMINDER,
            "route": "reminders",
            "title": body or text.strip(),
            "args": {"text": body, "when": _reminder_when(text, now=now)},
            "confirm": True,
        }
    if _has_any(low, _REMINDER_WORDS):
        trig = _matched_word(low, _REMINDER_WORDS)
        body = _strip_trigger(text, trig)
        when = _reminder_when(text, now=now)
        return {
            "intent": INTENT_REMINDER,
            "route": "reminders",
            "title": body or text.strip(),
            "args": {"text": body, "when": when},
            "confirm": True,
        }

    # 4. log expense
    if _has_any(low, _EXPENSE_WORDS):
        trig = _matched_word(low, _EXPENSE_WORDS)
        body = _strip_trigger(text, trig)
        amount = _first_amount(text)
        return {
            "intent": INTENT_EXPENSE,
            "route": "money",
            "title": body or text.strip(),
            "args": {"amount": amount, "note": body, "date": _expense_date(text, now)},
            "confirm": True,
        }

    # 5. open/show a screen — requires an open-verb AND a known subject so a
    #    plain data-entry utterance isn't hijacked into navigation.
    if _has_any(low, _OPEN_VERBS):
        route = _resolve_route(text)
        if route:
            return {
                "intent": INTENT_OPEN,
                "route": route,
                "title": text.strip(),
                "args": {},
                "confirm": True,
            }

    # 6. a bare subject with no open-verb may still be navigation ("my money").
    route = _resolve_route(text)
    if route:
        return {
            "intent": INTENT_OPEN,
            "route": route,
            "title": text.strip(),
            "args": {},
            "confirm": True,
        }

    # Understood the speech, but nothing actionable.
    return {
        "intent": INTENT_UNKNOWN,
        "route": None,
        "title": text.strip(),
        "args": {},
        "confirm": True,
    }
