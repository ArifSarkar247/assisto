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
    }

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
}
# which parts mean PM for a bare hour like "৮টা"
_PM_PARTS = {"দুপুর", "বিকাল", "বিকেল", "সন্ধ্যা", "সন্ধ্যে", "রাত", "রাতে",
             "afternoon", "evening", "night", "noon"}

_FREQ_WORDS = {
    "daily": ("daily", "everyday", "every day", "প্রতিদিন", "রোজ", "protidin"),
    "weekly": ("weekly", "প্রতি সপ্তাহ", "সাপ্তাহিক", "proti soptah"),
    "monthly": ("monthly", "প্রতি মাস", "মাসিক", "proti mash"),
    "yearly": ("yearly", "annually", "every year", "প্রতি বছর", "বার্ষিক", "proti bochor"),
}

# default reminder clock when only a date is known
DEFAULT_HOUR = 9
DEFAULT_MIN = 0


def _mk_rule(freq, interval=1, weekday=None, day_of_month=None, month=None, tod=None):
    return {"freq": freq, "interval": interval, "weekday": weekday,
            "day_of_month": day_of_month, "month": month, "time": tod}


# ---------------------------------------------------------------- time parse
_TIME_RX = re.compile(
    r"(?<!\d)(\d{1,2})\s*[:.]\s*(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?"           # 5:30pm / 17.00
    r"|(?<!\d)(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)"                            # 5pm
    r"|(?<!\d)(\d{1,2})\s*টা(?:\s*(\d{1,2})\s*মিনিট)?"                       # ৮টা / ৮টা ৩০ মিনিট
    r"|(\d{1,2})\s*ঘটিকা",
    re.IGNORECASE,
)


def _extract_time(text, daypart_hint=None):
    """Return ((hour,minute), matched_span_text) or (None, None)."""
    m = _TIME_RX.search(text)
    if not m:
        return None, None
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
        if daypart_hint in _PM_PARTS and 1 <= hour <= 11:
            hour += 12
        elif daypart_hint in ("সকাল", "ভোর", "morning", "dawn") and hour == 12:
            hour = 0
    hour = max(0, min(23, hour))
    minute = max(0, min(59, minute))
    return (hour, minute), m.group(0)


def _find_daypart(text):
    for word, hr in _DAYPART.items():
        if word in text:
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
def parse(text, now=None, lang=None):
    now = now or datetime.now()
    raw = text or ""
    lang = lang or _detect_lang(raw)
    norm = normalize_digits(raw)
    low = norm.lower()
    matched = []
    confidence = 0.0

    daypart_word, daypart_hr = _find_daypart(low)
    tod, tod_span = _extract_time(norm, daypart_hint=daypart_word)
    if tod_span:
        matched.append(tod_span.strip())
        confidence += 0.35
    elif daypart_word:
        tod = (daypart_hr, 0)
        matched.append(daypart_word)
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
        base_date, span, conf = _relative_date(low, now)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- explicit "N তারিখ" of this/next month, or "আগামী মাসের ৫ তারিখ" ----
    if base_date is None:
        base_date, span, conf = _month_date(low, now)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- bare weekday ("next friday", "শুক্রবার") one-off ----
    if base_date is None:
        base_date, span, conf = _bare_weekday(low, now)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # ---- explicit dd/mm[/yy] ----
    if base_date is None:
        base_date, span, conf = _explicit_date(norm, now)
        if span:
            matched.append(span)
            confidence = max(confidence, conf)

    # If we have a time but no date → assume today (or tomorrow if already past).
    if base_date is None and tod is not None:
        cand = _combine(now.date(), tod)
        if cand <= now:
            base_date = now.date() + timedelta(days=1)
        else:
            base_date = now.date()
        confidence = max(confidence, 0.5)

    result_dt = None
    if base_date is not None:
        dt = _combine(base_date, tod)
        # for a one-off today without explicit future time already handled above
        result_dt = dt

    confidence = round(min(confidence, 1.0), 2)
    clean = _clean_title(raw, matched)

    return {
        "datetime": result_dt.replace(microsecond=0).isoformat() if result_dt else None,
        "date_only": date_only,
        "recurrence_rule": recurrence,
        "clean_title": clean,
        "matched": [m for m in matched if m],
        "confidence": confidence,
        "lang": lang,
    }


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
def _relative_date(low, now):
    today = now.date()
    # tomorrow (check before 'today', since আগামীকাল contains কাল; and কাল means
    # tomorrow in everyday Bangla reminder usage)
    if re.search(r"আগামীকাল|আগামিকাল|কালকে|কাল|tomorrow|\bkalke\b|\bkal\b", low):
        return today + timedelta(days=1), _first_hit(
            low, ["আগামীকাল", "আগামিকাল", "কালকে", "কাল", "tomorrow", "kalke", "kal"]), 0.85
    # today
    if re.search(r"আজকে|আজ|\btoday\b|\bajke\b|\baj\b", low):
        return today, _first_hit(low, ["আজকে", "আজ", "today", "ajke", "aj"]), 0.8
    # day after tomorrow
    if re.search(r"পরশু|day after tomorrow", low):
        return today + timedelta(days=2), _first_hit(
            low, ["পরশু", "day after tomorrow"]), 0.85
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
    return None, None, 0.0


def _month_date(low, now):
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
    # bare "N তারিখ"
    m = re.search(r"(\d{1,2})\s*তারিখ(?:ে)?", low)
    if m:
        dom = int(m.group(1))
        return _next_dom(now.date(), dom), m.group(0), 0.7
    return None, None, 0.0


def _bare_weekday(low, now):
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
        allow_today = not re.search(r"next|আগামী", low)
        d = _next_weekday(now.date(), wd, allow_today=False if ("next" in low or "আগামী" in low) else False)
        # "this friday" → upcoming incl today handled by allow_today False → next occurrence
        return d, token, 0.65
    return None, None, 0.0


_DMY_RX = re.compile(r"(?<!\d)(\d{1,2})[/\-.](\d{1,2})(?:[/\-.](\d{2,4}))?(?!\d)")


def _explicit_date(norm, now):
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
    if not m.group(3) and cand < now.date():
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


def _clean_title(raw, matched):
    out = normalize_digits(raw)
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
