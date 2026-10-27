"""
nlp_datetime.py — deterministic natural-language date/time/recurrence parser for
Assisto reminders. Bangla + English + Banglish ("আম্মুকে কাল ডাক্তার দেখাতে নিয়ে যাও",
"next Friday 5pm", "প্রতি শুক্রবার সকাল ৮টা", "৩ দিন পর", "আগামী মাসের ৫ তারিখ").

NO external libraries, NO Django, NO network, NO AI — pure stdlib so it is
fully testable offline and runs the same on device-mirrored logic and the server.

Public API
----------
parse(text, now=None, lang=None) -> dict:
    {
      "datetime":        ISO8601 str | None  (next concrete occurrence, local naive),
      "date_only":       bool                 (True when no explicit clock time; a
                                               sensible default time was applied),
      "recurrence_rule": dict | None          (see below),
      "clean_title":     str                  (input with the parsed date/time words
                                               stripped — a good reminder title),
      "matched":         [str, ...]           (phrases we consumed, for UI preview),
      "confidence":      float 0..1,
      "lang":            "bn" | "en",
      "past":            bool                 (the phrase talks about the PAST:
                                               a past-tense verb, গতকাল/yesterday,
                                               "N দিন আগে", or a resolved date
                                               before today),
      "needs_time":      bool                 (True when the phrase said "today"
                                               with no clock and it is already too
                                               late for a sensible slot — the caller
                                               should ask the user for a time),
    }

parse(..., prefer_past=True) is the EXPENSE / money-log mode: an ambiguous
day word (bare কাল, পরশু, a weekday, "N তারিখ", dd/mm) resolves backwards
unless the phrase carries an explicit future marker (দিও/দাও/করব/remind…),
because expenses are logged after the fact. expense_date(text, now) wraps it
and also clamps to <= today.

Missing-time rule (documented, mirrored in the Dart parser):
  * A date with no clock time gets DEFAULT_HOUR:DEFAULT_MIN (09:00).
  * EXCEPTION — "আজ/আজকে/today" (or any one-off resolving to today), not recurring, not past
    tense, no clock AND no day-part word: if 09:00 has already passed, we use the
    NEXT FULL HOUR (10:20 -> 11:00, 10:00 -> 11:00). If that would fall past
    23:00 (i.e. it is already 23:00 or later) we use 23:59 today and set
    needs_time=True so the caller asks. A day-part word ("আজ সকালে") keeps its
    own hour.

"কাল" is ambiguous in Bangla (yesterday OR tomorrow). We read it as YESTERDAY
when the sentence has a past-tense verb (করেছি, গিয়েছিলাম, কিনলাম, গেল, korechi,
gelam…) and no future/imperative marker; otherwise TOMORROW. গতকাল/yesterday
are always yesterday; আগামীকাল/tomorrow always tomorrow. পরশু + past tense =
2 days ago. "কাল" is only matched as a standalone word (not inside সকাল/বিকাল).

Time words: সাড়ে N (N:30), সোয়া N (N:15), পৌনে N ((N-1):45), দেড়টা (1:30),
আড়াইটা (2:30), and Bangla number words (এক…একত্রিশ) before টা/টায়/তারিখ/দিন/
সপ্তাহ/মাস/ঘণ্টা/মিনিট. "মাসের শেষে"/"end of month" = last day of this month
(next month's if it is the last day and the given time, or 23:00, has passed); "প্রতি মাসের শেষে" = monthly, day 31
(the engine clamps to the month length).

recurrence_rule dict:
    {"freq": "daily"|"weekly"|"monthly"|"yearly",
     "interval": int,                 # every N (default 1)
     "weekday": int|None,             # 0=Mon .. 6=Sun  (weekly)
     "day_of_month": int|None,        # 1..31           (monthly / yearly)
     "month": int|None,               # 1..12           (yearly)
     "time": "HH:MM"|None}            # clock for each occurrence

The caller (reminders_engine) turns recurrence_rule + an anchor datetime into
concrete next-occurrence / overdue / expansion.
"""

import re
from datetime import datetime, date, time, timedelta

# ---------------------------------------------------------------- digits
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def normalize_digits(s):
    """Bangla digits → ASCII. Safe on None."""
    return (s or "").translate(_BN_DIGITS)


# ---------------------------------------------------------------- vocab
# Weekdays: Monday=0 .. Sunday=6 (Python weekday()).
_WEEKDAYS = {
    # english
    "monday": 0, "mon": 0, "tuesday": 1, "tue": 1, "tues": 1,
    "wednesday": 2, "wed": 2, "thursday": 3, "thu": 3, "thurs": 3,
    "friday": 4, "fri": 4, "saturday": 5, "sat": 5, "sunday": 6, "sun": 6,
    # bangla
    "সোমবার": 0, "সোম": 0, "মঙ্গলবার": 1, "মঙ্গল": 1, "বুধবার": 2, "বুধ": 2,
    "বৃহস্পতিবার": 3, "বৃহস্পতি": 3, "বিষ্যুদবার": 3,
    "শুক্রবার": 4, "শুক্র": 4, "জুম্মা": 4, "জুমা": 4,
    "শনিবার": 5, "শনি": 5, "রবিবার": 6, "রবি": 6,
    # banglish
    "shukrobar": 4, "shombar": 0, "mongolbar": 1, "budhbar": 2,
    "brihoshpotibar": 3, "shonibar": 5, "robibar": 6,
}

_MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    # bangla gregorian month names (common usage)
    "জানুয়ারি": 1, "ফেব্রুয়ারি": 2, "মার্চ": 3, "এপ্রিল": 4, "মে": 5, "জুন": 6,
    "জুলাই": 7, "আগস্ট": 8, "সেপ্টেম্বর": 9, "অক্টোবর": 10, "নভেম্বর": 11, "ডিসেম্বর": 12,
}

# Day-part → default hour (24h) when the user gives a part but no clock.
_DAYPART = {
    "সকাল": 8, "ভোর": 6, "দুপুর": 13, "বিকাল": 16, "বিকেল": 16,
    "সন্ধ্যা": 18, "সন্ধ্যে": 18, "রাত": 21, "রাতে": 21, "মধ্যরাত": 0,
    "morning": 8, "noon": 12, "afternoon": 15, "evening": 18,
    "night": 21, "midnight": 0, "dawn": 6,
    # Banglish (aieval: "kal sokal 8tay" used to lose its time)
    "sokal": 8, "sokale": 8, "bhor": 6, "dupur": 13, "dupure": 13, "bikel": 16,
    "bikale": 16, "bikele": 16, "bikal": 16, "sondha": 18, "shondha": 18,
    "sondhay": 18, "sondhar": 18, "raat": 21, "rat": 21, "raate": 21,
}
# which parts mean PM for a bare hour like "৮টা"
_PM_PARTS = {"দুপুর", "বিকাল", "বিকেল", "সন্ধ্যা", "সন্ধ্যে", "রাত", "রাতে",
             "afternoon", "evening", "night", "noon",
             "dupur", "dupure", "bikel", "bikale", "bikele", "bikal", "sondha", "shondha",
             "sondhay", "sondhar", "raat", "rat", "raate"}
_NIGHT_PARTS = {"রাত", "রাতে", "night", "raat", "rat", "raate"}
_BL_PARTS = {"sokal", "sokale", "bhor", "dupur", "dupure", "bikel", "bikale", "bikele",
             "bikal", "sondha", "shondha", "sondhay", "sondhar", "raat", "rat", "raate"}
# Banglish clock: "8tay" / "8 tae" / "8tar" always; a bare "8ta" only next to
# a day-part word ("sokal 8ta") — "2ta dim" is a count, not a time.
_BL_TIME_RX = re.compile(r"(?<!\d)(\d{1,2})\s*(?:tay|tae|tai|tar)\b", re.I)
_BL_TIME_TA_RX = re.compile(r"(?<!\d)(\d{1,2})\s*ta\b", re.I)

_FREQ_WORDS = {
    "daily": ("daily", "everyday", "every day", "প্রতিদিন", "রোজ", "protidin"),
    "weekly": ("weekly", "প্রতি সপ্তাহ", "সাপ্তাহিক", "proti soptah"),
    "monthly": ("monthly", "প্রতি মাস", "মাসিক", "proti mash"),
    "yearly": ("yearly", "annually", "every year", "প্রতি বছর", "বার্ষিক", "proti bochor"),
}

# ---------------------------------------------------------------- bangla script helpers
_BN = "ঀ-৿"            # Bangla block, used for "standalone word" look-arounds
_NB = rf"(?<![{_BN}])"            # not preceded by a Bangla letter/sign
_NA = rf"(?![{_BN}])"             # not followed by a Bangla letter/sign


def _fold(s):
    """Fold decomposed nukta letters (য+়, ড+়, ঢ+়) to their precomposed forms."""
    return (s.replace("\u09af\u09bc", "\u09df").replace("\u09a1\u09bc", "\u09dc")
            .replace("\u09a2\u09bc", "\u09dd"))


def _nk(word):
    """Regex for a Bangla word that matches both the precomposed and the
    decomposed (base + nukta) spellings of য়/ড়/ঢ় — keyboards/STT emit either."""
    out = re.escape(_fold(word))
    for pre, dec in (("\u09df", "\u09af\u09bc"), ("\u09dc", "\u09a1\u09bc"),
                     ("\u09dd", "\u09a2\u09bc")):
        out = out.replace(pre, f"(?:{pre}|{dec})")
    return out


# Bangla number words 1..31 (common spellings). Longest-first when matching.
_BN_NUMBER_WORDS = {
    "এক": 1, "দুই": 2, "দু": 2, "তিন": 3, "চার": 4, "পাঁচ": 5, "ছয়": 6, "ছয়": 6,
    "ছ": 6, "সাত": 7, "আট": 8, "নয়": 9, "নয়": 9, "দশ": 10, "এগারো": 11, "এগার": 11,
    "বারো": 12, "বার": 12, "তেরো": 13, "তের": 13, "চোদ্দ": 14, "চৌদ্দ": 14,
    "পনেরো": 15, "পনের": 15, "ষোলো": 16, "ষোল": 16, "সতেরো": 17, "সতের": 17,
    "আঠারো": 18, "আঠার": 18, "উনিশ": 19, "বিশ": 20, "কুড়ি": 20, "একুশ": 21,
    "বাইশ": 22, "তেইশ": 23, "চব্বিশ": 24, "পঁচিশ": 25, "ছাব্বিশ": 26, "সাতাশ": 27,
    "আঠাশ": 28, "উনত্রিশ": 29, "ত্রিশ": 30, "একত্রিশ": 31,
}
_NUM_ALT = "|".join(_nk(w) for w in sorted(_BN_NUMBER_WORDS, key=len, reverse=True))
_TA = "টা"
_TAY = _nk("টায়")
_UNIT_AFTER_NUM = "(?:তারিখ|দিন|সপ্তাহ|মাস|ঘণ্টা|ঘন্টা|মিনিট)"


def _num_value(tok):
    if tok.isdigit():
        return int(tok)
    for w, v in _BN_NUMBER_WORDS.items():
        if re.fullmatch(_nk(w), tok):
            return v
    return None


_DAYPART_ALT = "সকাল|ভোর|দুপুর|বিকাল|বিকেল|সন্ধ্যা|সন্ধ্যে|রাত"
_HALF_RX = re.compile(
    rf"{_NB}(সাড়ে|{_nk('সাড়ে')}|সোয়া|{_nk('সোয়া')}|পৌনে)\s*(\d{{1,2}}|{_NUM_ALT})"
    rf"\s*(?:{_TAY}|{_TA}(?:\s*বাজে)?|বাজে){_NA}")
_DER_RX = re.compile(rf"{_NB}({_nk('দেড়')}|{_nk('আড়াই')})\s*(?:{_TAY}|{_TA}){_NA}")
_NUM_UNIT_RX = re.compile(rf"{_NB}({_NUM_ALT})\s*({_UNIT_AFTER_NUM})")
_NUM_TAY_RX = re.compile(rf"{_NB}({_NUM_ALT})\s*({_TAY}|{_TA}\s*বাজে)")
_NUM_PART_TA_RX = re.compile(
    rf"((?:{_DAYPART_ALT})(?:ে|র)?\s+)({_NUM_ALT})\s*{_TA}")


def _preprocess(norm):
    """Rewrite Bangla time phrases / number words to digit forms the regexes
    understand. Only touches clearly date/time contexts (a bare "একটা" or
    "সাড়ে পাঁচ হাজার" is left alone)."""
    def half(m):
        word, n = m.group(1), _num_value(m.group(2))
        if not n or n > 12:
            return m.group(0)
        if word.startswith("প"):          # পৌনে N -> (N-1):45
            h, mi = (n - 1) or 12, 45
        elif word.startswith("সো"):       # সোয়া N -> N:15
            h, mi = n, 15
        else:                              # সাড়ে N -> N:30
            h, mi = n, 30
        return f"{h}:{mi:02d}"

    out = _HALF_RX.sub(half, norm)
    # দেড়টা / আড়াইটা are afternoon in everyday speech (13:30 / 14:30) unless
    # the sentence says রাত / ভোর (then 01:30 / 02:30).
    late = bool(re.search("রাত|ভোর|night", out))
    out = _DER_RX.sub(
        lambda m: ("1:30" if late else "13:30") if m.group(1).startswith("দ")
        else ("2:30" if late else "14:30"), out)
    out = _NUM_UNIT_RX.sub(lambda m: f"{_num_value(m.group(1))} {m.group(2)}", out)
    out = _NUM_TAY_RX.sub(lambda m: f"{_num_value(m.group(1))}{m.group(2)}", out)
    out = _NUM_PART_TA_RX.sub(lambda m: f"{m.group(1)}{_num_value(m.group(2))}{_TA}", out)
    return out


# ---------------------------------------------------------------- tense
# Past-tense verb endings (standard + colloquial). Matched per token.
_PAST_TOKEN_RX = re.compile(
    r"(?:েছি(?:লাম|লে|লেন|ল|লো|স)?|েছে(?:ন)?|লাম|ছিল|ছিলো|ছিলাম|ছিলেন|ছিলে)$")
# -ল / -লো / -লেন / -লি past only on a whitelist of common verb stems (so চাল,
# তেল, সকাল, ফল … never count).
_PAST_STEM_RX = re.compile(
    r"^(?:কর|গে|দি|নি|খে|এ|কিন|পে|হ|বল|দেখ|পাঠা|ফেল|আস|ভর|তু|রাখ|কাট|শুন|পড়|"
    r"পড়|ঘুর|চল|ফির|উঠ|ঘুমা|বসা|ছাড়|ছাড়|হারা|পাঠি)(?:ল|লো|লেন|লি)$")
_PAST_TOKENS_EXTRA = {"দিছি", "নিছি", "খাইছি", "গেছি", "পাইছি", "আইছি", "করছিলাম",
                      "হইছে", "গেছিলাম"}
_PAST_EXCLUDE = {"সালাম", "ইসলাম", "কালাম", "গোলাম", "বেছে", "আছি", "আছে",
                 "আছেন", "সকাল", "বিকাল", "কাল"}
_PAST_EN_RX = re.compile(
    r"^[a-z]+(?:echi|esi|eche|echilam|esilam|chilam|silam|chilo|silo|chilen|lam)$")
_PAST_EN_EXTRA = {"korsi", "khaisi", "disi", "nisi", "gesi", "gelo", "korlo", "dilo",
                  "khelo", "kinlo", "pelo", "holo", "korse", "gese", "khaise", "hoise",
                  "spent", "paid", "bought", "went", "was", "did", "yesterday"}
_PAST_EN_EXCLUDE = {"salam", "islam", "kalam", "golam"}
# Future / imperative markers — a reminder ("কাল মনে করিয়ে দিও") is tomorrow.
_FUTURE_PHRASES = ("মনে করিয়ে", "মনে করাও", "মনে করাবে", "রিমাইন্ড", "remind",
                   "will ", "going to")
_FUTURE_TOKENS = {
    "দিও", "দাও", "দিয়ো", "দিয়ো", "দিবেন", "দেবেন", "করো", "করুন", "কোরো", "যেও",
    "এসো", "আসো", "নিও", "খেও", "করব", "করবো", "যাব", "যাবো", "দেব", "দেবো", "দিব",
    "দিবো", "খাব", "খাবো", "কিনব", "কিনবো", "নেব", "নেবো", "নিব", "পাব", "আসব",
    "আসবো", "ফিরব", "দেখব", "বলব", "পাঠাব", "হবে", "যাবে", "করবে", "আসবে", "দেবে",
    "দিবে", "থাকবে", "থাকব", "শুরু", "korbo", "jabo", "dibo", "debo", "khabo",
    "kinbo", "nibo", "asbo", "hobe", "jabe", "korbe", "dio", "dao", "koro",
}

_FUTURE_TOKENS_F = {_fold(t) for t in _FUTURE_TOKENS}
_PAST_TOKENS_EXTRA = {_fold(t) for t in _PAST_TOKENS_EXTRA}
_PAST_EXCLUDE = {_fold(t) for t in _PAST_EXCLUDE}


def _tokens(low):
    return [t for t in re.split(r"[\s,।!?.;:\-]+", low) if t]


def has_future_marker(text):
    low = _fold(normalize_digits(text).lower())
    if any(_fold(p) in low for p in _FUTURE_PHRASES):
        return True
    return any(t in _FUTURE_TOKENS_F for t in _tokens(low))


def is_past_tense(text):
    """True when the sentence uses a past-tense verb (Bangla or Banglish) and has
    no future / imperative marker. Pure heuristic, deterministic."""
    low = _fold(normalize_digits(text).lower())
    if has_future_marker(low):
        return False
    for t in _tokens(low):
        if t in _PAST_EXCLUDE or t in _PAST_EN_EXCLUDE:
            continue
        if t in _PAST_TOKENS_EXTRA or t in _PAST_EN_EXTRA:
            return True
        if _PAST_TOKEN_RX.search(t) or _PAST_STEM_RX.match(t):
            return True
        if t.isascii() and _PAST_EN_RX.match(t):
            return True
    return False


# default reminder clock when only a date is known. NOTE: for "today" with no
# clock, once 09:00 has passed we use the next full hour instead (see the
# "Missing-time rule" in the module docstring).
DEFAULT_HOUR = 9
DEFAULT_MIN = 0


def _mk_rule(freq, interval=1, weekday=None, day_of_month=None, month=None, tod=None):
    return {"freq": freq, "interval": interval, "weekday": weekday,
            "day_of_month": day_of_month, "month": month, "time": tod}


# ---------------------------------------------------------------- time parse
_TIME_RX = re.compile(
    r"(?<!\d)(\d{1,2})\s*[:.]\s*(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?"           # 5:30pm / 17.00
    r"|(?<!\d)(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)"                            # 5pm
    r"|(?<!\d)(\d{1,2})\s*টা(?!কা)(?:য়|য়)?(?:\s*(\d{1,2})\s*মিনিট)?"      # ৮টা(য়) / ৮টা ৩০ মিনিট (never ৫০ টাকা)
    r"|(\d{1,2})\s*ঘটিকা",
    re.IGNORECASE,
)


def _extract_time(text, daypart_hint=None):
    """Return ((hour,minute), matched_span_text) or (None, None)."""
    m = _TIME_RX.search(text)
    if not m:
        m = _BL_TIME_RX.search(text) or (
            _BL_TIME_TA_RX.search(text) if daypart_hint and daypart_hint.isascii() else None)
        if not m:
            return None, None
        hour = int(m.group(1))
        if hour > 24:
            return None, None
        if daypart_hint in _PM_PARTS and 1 <= hour <= 11 and not (
                daypart_hint in _NIGHT_PARTS and hour < 6):
            hour += 12
        elif daypart_hint in ("সকাল", "ভোর", "morning", "dawn", "sokal", "sokale", "bhor") \
                and hour == 12:
            hour = 0
        return (max(0, min(23, hour)), 0), m.group(0)
    g = m.groups()
    hour = minute = None
    ampm = None
    if g[0] is not None:            # H:MM [am/pm]
        hour, minute = int(g[0]), int(g[1])
        ampm = (g[2] or "").lower()
    elif g[3] is not None:          # H am/pm
        hour, minute, ampm = int(g[3]), 0, (g[4] or "").lower()
    elif g[5] is not None:          # Bangla NটাM মিনিট
        hour = int(g[5])
        minute = int(g[6]) if g[6] else 0
        if hour > 24:               # "৫০টা ডিম" is a count, not a clock
            return None, None
    elif g[7] is not None:          # ঘটিকা
        hour, minute = int(g[7]), 0

    if hour is None:
        return None, None
    ampm = ampm or ""
    # am/pm handling
    if ampm.startswith("p"):
        if hour < 12:
            hour += 12
    elif ampm.startswith("a"):
        if hour == 12:
            hour = 0
    else:
        # no am/pm → use daypart hint for bare hours (Bangla "৮টা" + "রাত")
        # (রাত/night: only 6..11 are evening hours — "রাত ১টা" is 01:00)
        night = daypart_hint in _NIGHT_PARTS
        if daypart_hint in _PM_PARTS and 1 <= hour <= 11 and not (night and hour < 6):
            hour += 12
        elif daypart_hint in ("সকাল", "ভোর", "morning", "dawn") and hour == 12:
            hour = 0
    hour = max(0, min(23, hour))
    minute = max(0, min(59, minute))
    return (hour, minute), m.group(0)


def _find_daypart(text):
    for word, hr in _DAYPART.items():
        if word in _BL_PARTS:
            # Banglish: whole word only ("rat" never inside "karate")
            if re.search(r"(?<![a-z])" + re.escape(word) + r"(?![a-z])", text):
                return word, hr
        elif word in text:
            return word, hr
    return None, None


# ---------------------------------------------------------------- helpers
def _add_months(d, n):
    """Add n calendar months to a date, clamping the day to month length."""
    m = d.month - 1 + n
    y = d.year + m // 12
    m = m % 12 + 1
    day = min(d.day, _days_in_month(y, m))
    return date(y, m, day)


def _days_in_month(y, m):
    if m == 12:
        nxt = date(y + 1, 1, 1)
    else:
        nxt = date(y, m + 1, 1)
    return (nxt - date(y, m, 1)).days


def _next_weekday(from_date, weekday, allow_today=False):
    delta = (weekday - from_date.weekday()) % 7
    if delta == 0 and not allow_today:
        delta = 7
    return from_date + timedelta(days=delta)


def _combine(d, hm):
    h, mi = hm if hm else (DEFAULT_HOUR, DEFAULT_MIN)
    return datetime(d.year, d.month, d.day, h, mi)


def _detect_lang(text):
    return "bn" if re.search(r"[ঀ-৿]", text) else "en"


# ---------------------------------------------------------------- main
def parse(text, now=None, lang=None, prefer_past=False):
    now = now or datetime.now()
    raw = text or ""
    lang = lang or _detect_lang(raw)
    norm = _preprocess(normalize_digits(raw))
    low = norm.lower()
    matched = []
    confidence = 0.0
    future = has_future_marker(low)
    past = is_past_tense(low) or (prefer_past and not future)

    daypart_word, daypart_hr = _find_daypart(low)
    tod, tod_span = _extract_time(norm, daypart_hint=daypart_word)
    # the day-part word plus its case ending ("সকালে", "রাতের") is stripped from
    # the title too, so "কাল সকালে মিটিং" -> "মিটিং" (no dangling "ে").
    dp_span = None
    if daypart_word:
        dm = re.search(re.escape(daypart_word) + r"(?:ের|ে|র)?", low)
        dp_span = dm.group(0) if dm else daypart_word
    if tod_span:
        matched.append(tod_span.strip())
        if dp_span:
            matched.append(dp_span)
        confidence += 0.35
    elif daypart_word:
        tod = (daypart_hr, 0)
        matched.append(dp_span)
        confidence += 0.15

    tod_str = f"{tod[0]:02d}:{tod[1]:02d}" if tod else None
    date_only = tod_span is None

    recurrence = None
    base_date = None

    # ---- recurrence: weekly by weekday ("প্রতি শুক্রবার", "every friday") ----
    every_rx = re.search(
        r"(?:প্রতি|every|each|প্রতিটি)\s+([^\s,।]+)", low)
    if every_rx:
        token = every_rx.group(1)
        if token in _WEEKDAYS:
            wd = _WEEKDAYS[token]
            recurrence = _mk_rule("weekly", weekday=wd, tod=tod_str)
            base_date = _next_weekday(now.date(), wd, allow_today=True)
            matched.append(every_rx.group(0))
            confidence = max(confidence, 0.6) + 0.3
        elif token in ("দিন", "day"):
            recurrence = _mk_rule("daily", tod=tod_str)
            base_date = now.date()
            matched.append(every_rx.group(0))
            confidence = max(confidence, 0.6) + 0.3

    # ---- recurrence: "প্রতি মাসের শেষে" / "every month end" -> monthly day 31 ----
    if recurrence is None:
        merx = re.search(_MONTH_END_EVERY_RX, low)
        if merx:
            recurrence = _mk_rule("monthly", day_of_month=31, tod=tod_str)
            base_date = _month_end(now.date())
            matched.append(merx.group(0))
            confidence = 0.9

    # ---- recurrence: "প্রতি মাসের ৫ তারিখ" / "every month on the 5th" ----
    if recurrence is None:
        mrx = re.search(
            r"(?:প্রতি\s*মাসের?|every\s+month(?:\s+on)?(?:\s+the)?)\s*(\d{1,2})"
            r"\s*(?:তারিখ|তারিখে|st|nd|rd|th)?", low)
        if mrx:
            dom = int(mrx.group(1))
            recurrence = _mk_rule("monthly", day_of_month=dom, tod=tod_str)
            base_date = _next_dom(now.date(), dom)
            matched.append(mrx.group(0))
            confidence = 0.9

    # ---- recurrence: plain freq words (daily/weekly/monthly/yearly) ----
    if recurrence is None:
        for freq, words in _FREQ_WORDS.items():
            if any(w in low for w in words):
                recurrence = _mk_rule(freq, tod=tod_str)
                base_date = now.date()
                hit = next(w for w in words if w in low)
                matched.append(hit)
                confidence = max(confidence, 0.75)
                break

    # ---- one-off relative dates (only if not already recurrence-anchored) ----
    if base_date is None:
        base_date, span, conf = _relative_date(low, now, past)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- explicit "N তারিখ" of this/next month, or "আগামী মাসের ৫ তারিখ" ----
    if base_date is None:
        base_date, span, conf = _month_date(low, now, past)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- bare weekday ("next friday", "শুক্রবার") one-off ----
    if base_date is None:
        base_date, span, conf = _bare_weekday(low, now, past)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- explicit dd/mm[/yy] ----
    if base_date is None:
        base_date, span, conf = _explicit_date(norm, now, past)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # If we have a time but no date → assume today (or tomorrow if already past;
    # for a past-tense sentence: today, or yesterday if that time is still ahead).
    if base_date is None and tod is not None:
        cand = _combine(now.date(), tod)
        if past:
            base_date = now.date() if cand <= now else now.date() - timedelta(days=1)
        elif cand <= now:
            base_date = now.date() + timedelta(days=1)
        else:
            base_date = now.date()
        confidence = max(confidence, 0.5)

    result_dt = None
    needs_time = False
    if base_date is not None:
        dt = _combine(base_date, tod)
        month_end = _month_end_hit(matched) and recurrence is None and not past
        # "মাসের শেষে" when today is the last day and that moment already passed
        # -> next month's last day.
        if month_end and dt <= now and (tod is not None or now.hour >= 23):
            nxt = _month_end(_add_months(date(now.year, now.month, 1), 1))
            dt = _combine(nxt, tod)
        # Missing-time rule (see module docstring): "today" with no clock and no
        # day-part never lands on a moment that already passed.
        if (tod is None and recurrence is None and not past
                and dt.date() == now.date() and dt <= now):
            if now.hour + 1 <= 23:
                dt = datetime(now.year, now.month, now.day, now.hour + 1, 0)
            else:
                dt = datetime(now.year, now.month, now.day, 23, 59)
                needs_time = True
        result_dt = dt

    confidence = round(min(confidence, 1.0), 2)
    clean = _clean_title(raw, matched, pre=norm)
    is_past = bool(past and (result_dt is None or result_dt.date() <= now.date())) \
        or bool(result_dt is not None and result_dt.date() < now.date())

    return {
        "datetime": result_dt.replace(microsecond=0).isoformat() if result_dt else None,
        "date_only": date_only,
        "recurrence_rule": recurrence,
        "clean_title": clean,
        "matched": [m for m in matched if m],
        "confidence": confidence,
        "lang": lang,
        "past": is_past,
        "needs_time": needs_time,
    }


def expense_date(text, now=None):
    """Date an expense/income log refers to (money voice + chat expense).
    Past-biased: bare কাল = yesterday, পরশু = 2 days ago, a weekday = the most
    recent one, unless an explicit future word is used; never later than today
    (a money log is always "already happened"). No date words -> today."""
    now = now or datetime.now()
    try:
        r = parse(text or "", now=now, prefer_past=True)
    except Exception:
        return now.date()
    if not r.get("datetime") or r.get("recurrence_rule"):
        return now.date()
    d = datetime.fromisoformat(r["datetime"]).date()
    return min(d, now.date())


def day_offset(text, now=None):
    """Signed day offset (-2..+2, or None) a short phrase refers to via
    আজ/কাল/গতকাল/পরশু/tomorrow/yesterday — used by the rule-based chat agent."""
    now = now or datetime.now()
    low = _preprocess(normalize_digits(text or "")).lower()
    d, span, _ = _relative_date(low, now, is_past_tense(low))
    if d is None or span is None:
        return None
    off = (d - now.date()).days
    return off if -2 <= off <= 2 else None


def _month_end(d):
    return date(d.year, d.month, _days_in_month(d.year, d.month))


_MONTH_END_EVERY_RX = (r"(?:প্রতি\s*মাসের?\s*শেষ(?:ে|\s*দিন(?:ে)?)?"
                       r"|every\s+month\s*end|(?:at\s+the\s+)?end\s+of\s+every\s+month)")
_MONTH_END_RX = (r"(?:(?:এই\s*)?মাসের?\s*শেষ(?:ে|\s*দিন(?:ে)?)?"
                 r"|(?:at\s+the\s+)?end\s+of\s+(?:the\s+|this\s+)?month|month[\s-]end)")


def _month_end_hit(matched):
    return any(m and re.fullmatch(_MONTH_END_RX, m.lower()) for m in matched)


def _next_dom(from_date, dom):
    """Next date whose day-of-month is dom (this month if still ahead, else next)."""
    dom = max(1, min(31, dom))
    y, m = from_date.year, from_date.month
    d = min(dom, _days_in_month(y, m))
    cand = date(y, m, d)
    if cand < from_date:
        cand = _add_months(date(y, m, 1), 1)
        d = min(dom, _days_in_month(cand.year, cand.month))
        cand = date(cand.year, cand.month, d)
    return cand


# ---------------------------------------------------------------- relative
_KAL_RX = rf"{_NB}কাল(?:কে|কেই|কের|ই)?{_NA}"
_AJ_RX = rf"{_NB}আজ(?:কে|কেই|কের|ই)?{_NA}"


def _relative_date(low, now, past=False):
    today = now.date()
    # yesterday — always past
    m = re.search(r"গতকাল(?:কে|কের|ই)?|গত\s+কাল|\byesterday\b|\bgotokal\b|\bgotokaal\b", low)
    if m:
        return today - timedelta(days=1), m.group(0), 0.85
    # day before yesterday — "গত পরশু" / "day before yesterday"
    m = re.search(r"গত\s*পরশু|day before yesterday", low)
    if m:
        return today - timedelta(days=2), m.group(0), 0.85
    # day after tomorrow (contains "tomorrow", so test it first — aieval)
    m = re.search(r"day after tomorrow", low)
    if m:
        return today + timedelta(days=2), m.group(0), 0.85
    # explicit tomorrow (আগামীকাল contains কাল, so test it first)
    m = re.search(r"আগামী\s*কাল(?:কে|ই)?|আগামি\s*কাল|\btomorrow\b", low)
    if m:
        return today + timedelta(days=1), m.group(0), 0.85
    # bare কাল / kal: yesterday in a past-tense sentence, tomorrow otherwise.
    # Standalone word only — never the কাল inside সকাল / বিকাল / আজকাল.
    m = re.search(_KAL_RX, low) or re.search(r"\bkalke\b|\bkal\b", low)
    if m:
        delta = -1 if past else 1
        return today + timedelta(days=delta), m.group(0), 0.85
    # today
    m = re.search(_AJ_RX, low) or re.search(r"\btoday\b|\bajke\b|\baj\b", low)
    if m:
        return today, m.group(0), 0.8
    # day after tomorrow (পরশু = 2 days ago in a past-tense sentence)
    m = re.search(r"day after tomorrow", low)
    if m:
        return today + timedelta(days=2), m.group(0), 0.85
    m = re.search(r"পরশু(?:দিন)?", low)
    if m:
        return today + timedelta(days=-2 if past else 2), m.group(0), 0.85
    # "N দিন আগে" / "N days ago"
    m = re.search(r"(\d{1,3})\s*দিন\s*আগে", low) or re.search(r"(\d{1,3})\s*days?\s+ago", low)
    if m:
        return today - timedelta(days=int(m.group(1))), m.group(0), 0.85
    m = re.search(r"(\d{1,3})\s*সপ্তাহ\s*আগে", low) or re.search(r"(\d{1,3})\s*weeks?\s+ago", low)
    if m:
        return today - timedelta(weeks=int(m.group(1))), m.group(0), 0.85
    m = re.search(r"(\d{1,3})\s*মাস\s*আগে", low) or re.search(r"(\d{1,3})\s*months?\s+ago", low)
    if m:
        return _add_months(today, -int(m.group(1))), m.group(0), 0.8
    # "N দিন পর" / "in N days" / "after N days"
    m = re.search(r"(\d{1,3})\s*(?:দিন)\s*(?:পর|পরে)", low) \
        or re.search(r"(?:in|after)\s+(\d{1,3})\s*days?", low)
    if m:
        return today + timedelta(days=int(m.group(1))), m.group(0), 0.85
    # "N সপ্তাহ পর" / "in N weeks"
    m = re.search(r"(\d{1,3})\s*(?:সপ্তাহ)\s*(?:পর|পরে)", low) \
        or re.search(r"(?:in|after)\s+(\d{1,3})\s*weeks?", low)
    if m:
        return today + timedelta(weeks=int(m.group(1))), m.group(0), 0.85
    # "N মাস পর" / "in N months"
    m = re.search(r"(\d{1,3})\s*(?:মাস)\s*(?:পর|পরে)", low) \
        or re.search(r"(?:in|after)\s+(\d{1,3})\s*months?", low)
    if m:
        return _add_months(today, int(m.group(1))), m.group(0), 0.8
    # "আগামী সপ্তাহ" / "next week"
    if re.search(r"আগামী\s*সপ্তাহ|next\s+week", low):
        return today + timedelta(days=7), _first_hit(low, ["আগামী সপ্তাহ", "next week"]), 0.7
    # "মাসের শেষে" / "end of the month"
    m = re.search(_MONTH_END_RX, low)
    if m:
        return _month_end(today), m.group(0), 0.8
    return None, None, 0.0


def _month_date(low, now, past=False):
    """'আগামী মাসের ৫ তারিখ' (next month, day 5), 'এই মাসের ২০ তারিখ', or
    '৫ তারিখ' alone (this month or next if past)."""
    # next month, day N
    m = re.search(r"আগামী\s*মাসের?\s*(\d{1,2})\s*তারিখ", low) \
        or re.search(r"next\s+month(?:\s+on)?(?:\s+the)?\s*(\d{1,2})", low)
    if m:
        dom = int(m.group(1))
        nm = _add_months(date(now.year, now.month, 1), 1)
        d = min(dom, _days_in_month(nm.year, nm.month))
        return date(nm.year, nm.month, d), m.group(0), 0.9
    # this month, day N
    m = re.search(r"(?:এই|চলতি)\s*মাসের?\s*(\d{1,2})\s*তারিখ", low)
    if m:
        dom = int(m.group(1))
        d = min(dom, _days_in_month(now.year, now.month))
        return date(now.year, now.month, d), m.group(0), 0.85
    # "<month name> N" / "N <month name>"
    m = re.search(r"([a-zঀ-৿]+)\s+(\d{1,2})(?:\s*তারিখ)?", low)
    if m and m.group(1) in _MONTHS:
        mo = _MONTHS[m.group(1)]
        dom = int(m.group(2))
        y = now.year + (1 if (mo, dom) < (now.month, now.day) else 0)
        d = min(dom, _days_in_month(y, mo))
        return date(y, mo, d), m.group(0), 0.85
    m = re.search(r"(\d{1,2})\s*(?:তারিখ\s*)?([a-zঀ-৿]+)", low)
    if m and m.group(2) in _MONTHS:
        mo = _MONTHS[m.group(2)]
        dom = int(m.group(1))
        y = now.year + (1 if (mo, dom) < (now.month, now.day) else 0)
        d = min(dom, _days_in_month(y, mo))
        return date(y, mo, d), m.group(0), 0.85
    # bare "N তারিখ" (past tense: this month's, or last month's if still ahead)
    m = re.search(r"(\d{1,2})\s*তারিখ(?:ে)?", low)
    if m:
        dom = int(m.group(1))
        if past:
            return _prev_dom(now.date(), dom), m.group(0), 0.7
        return _next_dom(now.date(), dom), m.group(0), 0.7
    return None, None, 0.0


def _prev_dom(from_date, dom):
    """Most recent date (<= from_date) whose day-of-month is dom."""
    dom = max(1, min(31, dom))
    y, m = from_date.year, from_date.month
    cand = date(y, m, min(dom, _days_in_month(y, m)))
    if cand > from_date:
        pm = _add_months(date(y, m, 1), -1)
        cand = date(pm.year, pm.month, min(dom, _days_in_month(pm.year, pm.month)))
    return cand


def _bare_weekday(low, now, past=False):
    """'next friday', 'শুক্রবার', 'এই শুক্রবার' — one-off, not preceded by প্রতি/every."""
    for token, wd in _WEEKDAYS.items():
        # whole-word for ascii; substring ok for bangla script
        if token.isascii():
            if not re.search(rf"\b{re.escape(token)}\b", low):
                continue
        elif token not in low:
            continue
        # skip if part of a recurrence phrase (handled earlier)
        if re.search(rf"(?:প্রতি|every|each)\s+{re.escape(token)}", low):
            return None, None, 0.0
        if past:   # "শুক্রবার গিয়েছিলাম" -> the most recent past Friday
            back = (now.date().weekday() - wd) % 7 or 7
            return now.date() - timedelta(days=back), token, 0.65
        d = _next_weekday(now.date(), wd, allow_today=False)
        # "this friday" -> next occurrence (never today)
        return d, token, 0.65
    return None, None, 0.0


_DMY_RX = re.compile(r"(?<!\d)(\d{1,2})[/\-.](\d{1,2})(?:[/\-.](\d{2,4}))?(?!\d)")


def _explicit_date(norm, now, past=False):
    m = _DMY_RX.search(norm)
    if not m:
        return None, None, 0.0
    d, mo = int(m.group(1)), int(m.group(2))
    y = m.group(3)
    if y:
        y = int(y)
        if y < 100:
            y += 2000
    else:
        y = now.year
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return None, None, 0.0
    d = min(d, _days_in_month(y, mo))
    cand = date(y, mo, d)
    if not m.group(3) and past and cand > now.date():
        cand = date(y - 1, mo, min(d, _days_in_month(y - 1, mo)))
    elif not m.group(3) and not past and cand < now.date():
        cand = date(y + 1, mo, min(d, _days_in_month(y + 1, mo)))
    return cand, m.group(0), 0.8


def _first_hit(low, options):
    for o in options:
        if o in low:
            return o
    return options[0]


# ---------------------------------------------------------------- title clean
_FILLER = [
    "আমাকে", "মনে করিয়ে দাও", "মনে করিয়ে দিও", "মনে করাও", "রিমাইন্ডার দাও",
    "remind me to", "remind me", "reminder to", "set a reminder to",
    "set reminder", "please", "একটা রিমাইন্ডার", "নিও",
]


def _clean_title(raw, matched, pre=None):
    out = pre if pre is not None else normalize_digits(raw)
    # strip consumed date/time phrases
    for phrase in sorted([m for m in matched if m], key=len, reverse=True):
        idx = out.lower().find(phrase.lower())
        if idx >= 0:
            out = out[:idx] + out[idx + len(phrase):]
    for f in _FILLER:
        out = re.sub(re.escape(f), "", out, flags=re.IGNORECASE)
    # tidy leftover connectors/punct
    out = re.sub(r"\s+", " ", out)
    out = out.strip(" ,।-:;।")
    # drop dangling connectors left where a date/time phrase was removed, e.g.
    #   "pay bill on 25/12" -> "pay bill on " -> "pay bill"
    #   "call mom at 5pm"   -> "call mom at "  -> "call mom"
    #   "২৫ তারিখে বিল দাও" -> "তারিখে বিল দাও" -> "বিল দাও"
    # English connectors are whole-word; Bangla particles may hang with/without space.
    _EN_CONN = r"(?:at|on|by|to)"
    _BN_CONN = r"(?:এ|তে|তারিখে|তারিখ)"
    prev = None
    while prev != out:
        prev = out
        out = re.sub(rf"\s+{_EN_CONN}$", "", out, flags=re.IGNORECASE)
        out = re.sub(rf"^{_EN_CONN}\s+", "", out, flags=re.IGNORECASE)
        out = re.sub(rf"^{_BN_CONN}\s+", "", out)
        out = re.sub(rf"\s+{_BN_CONN}$", "", out)
        out = out.strip(" ,।-:;।")
    return out.strip() or normalize_digits(raw).strip()
