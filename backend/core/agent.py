"""
Assisto agent brain — turns a Bangla/English message into intents + actions.
Works WITHOUT an AI key (rule-based). When a key exists the view may enrich the
reply with AI, but parsing/execution here never requires it.

Safety: this only ever creates the user's OWN data (reminders, expenses, loans,
medicines, memory). Anything external/sensitive is NOT executed here — the view
returns an approval card instead (autonomy dial + audit log).
"""
import re
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation

from .i18n import pick

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _norm(s):
    return (s or "").translate(_BN_DIGITS)


def _amount(text):
    m = re.search(r"(\d[\d,]*\.?\d*)", _norm(text).replace(",", ""))
    if not m:
        return None
    try:
        return Decimal(m.group(1))
    except InvalidOperation:
        return None


def _time(text):
    """Very small time parser: সকাল/দুপুর/বিকেল/সন্ধ্যা/রাত + N টা, or HH:MM."""
    t = _norm(text)
    now = datetime.now()
    base = now
    if "কাল" in text or "tomorrow" in text.lower():
        base = now + timedelta(days=1)
    m = re.search(r"(\d{1,2}):(\d{2})", t)
    if m:
        return base.replace(hour=int(m.group(1)), minute=int(m.group(2)),
                            second=0, microsecond=0)
    m = re.search(r"(\d{1,2})\s*টা", t)
    if m:
        h = int(m.group(1))
        if any(w in text for w in ["বিকেল", "সন্ধ্যা", "রাত", "দুপুর"]) and h < 12:
            h += 12
        if "সকাল" in text and h == 12:
            h = 0
        return base.replace(hour=h % 24, minute=0, second=0, microsecond=0)
    return None


# intent keyword sets
_EXPENSE = ["খরচ", "দিলাম", "কিনলাম", "খরচা", "spent", "paid", "bought", "expense"]
_INCOME = ["আয়", "পেলাম", "বেতন", "ইনকাম", "income", "salary", "got paid", "received"]
_LOAN_GIVE = ["ধার দিলাম", "ধার দিছি", "দিলাম ধার", "lent", "ধার দিয়েছি"]
_LOAN_TAKE = ["ধার নিলাম", "ধার নিছি", "নিলাম ধার", "borrowed", "ধার নিয়েছি"]
_REMIND = ["মনে করিয়ে", "রিমাইন্ডার", "মনে করাও", "remind", "alarm", "অ্যালার্ম"]
_MEDICINE = ["ওষুধ", "medicine", "medication", "ওষূধ"]
_REMEMBER = ["মনে রাখো", "মনে রেখো", "remember", "মনে রাখবে"]
_QUERY_MONEY = ["কত টাকা", "ব্যালেন্স", "কত খরচ", "balance", "how much", "কত আছে"]
_QUERY_TODAY = ["আজ কী", "আজকে কী", "today", "briefing", "ব্রিফিং", "কী কী আছে"]
# --- voice assistant commands (P5) ---
_MUSIC = ["গান চালাও", "গান শোনাও", "গান বাজাও", "গান ছাড়ো", "play song", "play music", "play "]
_CALL = ["কল করো", "ফোন করো", "কল দাও", "ফোন দাও", "call ", "ডায়াল"]
_NAVIGATE = ["রাস্তা দেখাও", "নেভিগেট", "navigate", "কীভাবে যাব", "কিভাবে যাব", "যাওয়ার পথ", "directions"]
_NEARBY = ["কাছে", "কাছাকাছি", "আশেপাশে", "nearby", "near me", "কোথায়"]
_NEARBY_TYPES = {
    "restaurant": ["রেস্টুরেন্ট", "খাবার", "restaurant", "hotel খাবার"],
    "pharmacy": ["ফার্মেসি", "ওষুধের দোকান", "pharmacy", "medicine shop"],
    "atm": ["atm", "এটিএম", "টাকা তোলা"],
    "hospital": ["হাসপাতাল", "hospital", "clinic", "ক্লিনিক"],
    "lodging": ["হোটেল", "মোটেল", "hotel", "motel", "থাকার"],
}


def _has(text, words):
    low = text.lower()
    return any(w in text or w in low for w in words)


def parse(text, lang="bn"):
    """Return a dict describing the intent + extracted fields (no DB access).

    `lang` ('bn'|'en') only affects the language of user-facing fallback
    defaults (e.g. a reminder/medicine title when none could be extracted);
    it never changes intent routing or extraction logic.
    """
    text = (text or "").strip()
    if not text:
        return {"intent": "unknown"}

    from .logic import brain

    # A QUESTION is NEVER a capture (owner A3 bug: "Amar kno data ace naki??"
    # was being saved as a note). We detect it up front, but an EXPLICIT command
    # or capture below (call/remind/expense/…) still wins — those carry an action
    # verb, so e.g. "রহিম কে কল করো" is a call, not a question. Any text that is a
    # question and matches NO command/capture falls through to the `question`
    # return just before the ambiguous fallback.
    question = brain.is_question(text)

    # structured queries first (these answer, never save)
    if _has(text, _QUERY_TODAY):
        return {"intent": "query_today"}
    if _has(text, _QUERY_MONEY):
        return {"intent": "query_money"}

    # voice assistant commands (deep-links / app actions — never auto-send)
    if _has(text, _NEARBY):
        for ptype, words in _NEARBY_TYPES.items():
            if _has(text, words):
                return {"intent": "nearby", "place_type": ptype}
    if _has(text, _MUSIC):
        return {"intent": "music", "query": _strip(text, _MUSIC)}
    if _has(text, _NAVIGATE):
        return {"intent": "navigate", "place": _strip(text, _NAVIGATE + ["যাও", "to"])}
    # "remind me at 5 to call mum" is a REMINDER, not a call (a3-voice).
    if _has(text, _CALL) and not _has(text, _REMIND):
        return {"intent": "call", "name": _strip(text, _CALL + ["কে", "-কে", "to"])}

    # A QUESTION wins over keyword captures (reminder/medicine/memory): it is
    # ANSWERED by Brain, never saved. (Deep-link voice commands above keep
    # priority — they carry an explicit action verb, e.g. "রহিম কে কল করো".)
    if question:
        return {"intent": "question", "text": text}

    amt = _amount(text)

    if _has(text, _LOAN_GIVE) and amt is not None:
        return {"intent": "loan", "kind": "given", "amount": str(amt),
                "person": _person(text)}
    if _has(text, _LOAN_TAKE) and amt is not None:
        return {"intent": "loan", "kind": "taken", "amount": str(amt),
                "person": _person(text)}
    if _has(text, _INCOME) and amt is not None:
        return {"intent": "income", "amount": str(amt), "category": _category(text)}
    if _has(text, _EXPENSE) and amt is not None:
        return {"intent": "expense", "amount": str(amt), "category": _category(text)}
    if _has(text, _MEDICINE):
        return {"intent": "medicine", "name": _clean_med(text, lang), "due": _timestr(text)}
    if _has(text, _REMIND):
        return {"intent": "reminder", "title": _clean_remind(text, lang),
                "due": _timestr(text)}
    if _has(text, _REMEMBER) or brain.has_explicit_save(text):
        # explicit "mone rakho / save / note:" → a clear capture
        return {"intent": "memory", "title": _clean_remember(text)}
    # bare "<amount> <something>" → treat as expense
    if amt is not None:
        return {"intent": "expense", "amount": str(amt), "category": _category(text)}
    # Not a question, not a clear capture, not a known command → AMBIGUOUS.
    # We ANSWER (Brain) and offer a "Save as note" chip; we never silently save.
    return {"intent": "ambiguous", "text": text}


def play_safe(parsed, text, lang="bn"):
    """play-nomed: the Google Play build has no medicine schedules. A parsed
    'medicine' capture becomes a plain REMINDER with the user's own words as
    the title (e.g. "take medicine at 9" -> reminder "take medicine at 9", due 9:00).
    Every other intent is returned unchanged."""
    if (parsed or {}).get("intent") != "medicine":
        return parsed
    title = (re.sub(r"\s+", " ", text or "").strip(" ।,-")[:200]
             or pick(lang, "রিমাইন্ডার", "Reminder"))
    return {"intent": "reminder", "title": title, "due": parsed.get("due")}


def _timestr(text):
    t = _time(text)
    return t.isoformat() if t else None


def _person(text):
    m = re.search(r"([ঀ-৿\w]+)\s*(ভাই|আপা|কে|র কাছে|-কে)", text)
    return m.group(1) if m else ""


def _category(text):
    for c in ["খাবার", "খাওয়া", "যাতায়াত", "বাজার", "বিল", "রিচার্জ", "বাসা ভাড়া",
              "ওষুধ", "কাপড়", "food", "transport", "bill", "rent", "grocery"]:
        if c in text:
            return c
    return ""


def _strip(text, words):
    out = text
    for w in words:
        out = out.replace(w, "")
    return re.sub(r"\s+", " ", out).strip(" ।,-")


def _clean_remind(text, lang="bn"):
    return (_strip(text, _REMIND + ["আমাকে", "দিও", "দাও", "me", "to"])
            or pick(lang, "রিমাইন্ডার", "Reminder"))


def _clean_remember(text):
    return _strip(text, _REMEMBER) or text


def _clean_med(text, lang="bn"):
    return (_strip(text, _MEDICINE + ["যোগ করো", "add", "খাওয়ার"])
            or pick(lang, "ওষুধ", "Medicine"))
