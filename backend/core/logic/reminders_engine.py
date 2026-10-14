"""
reminders_engine.py — pure recurrence / snooze / next-occurrence / overdue logic
for Assisto reminders. No Django, no DB, no network, no AI — deterministic stdlib.

Works hand-in-hand with nlp_datetime.parse():
  parse() gives {datetime (anchor), recurrence_rule}; this module projects that
  into concrete future occurrences, computes the next fire time, decides overdue,
  and resolves natural-language snooze ("10 min", "tomorrow morning", "১ ঘণ্টা").

A `rule` is the dict produced by nlp_datetime._mk_rule:
  {"freq","interval","weekday","day_of_month","month","time"}
and `anchor` is a naive datetime (the first/seed occurrence).
"""

import re
from datetime import datetime, date, time, timedelta

from .nlp_datetime import (
    normalize_digits, _add_months, _days_in_month, _next_weekday,
)

DEFAULT_HOUR = 9


def _tod_from_rule(rule, anchor):
    if rule and rule.get("time"):
        h, m = rule["time"].split(":")
        return int(h), int(m)
    if anchor:
        return anchor.hour, anchor.minute
    return DEFAULT_HOUR, 0


def next_occurrence(anchor, rule, after=None):
    """Return the first occurrence strictly after `after` (default: now).
    For a one-off (rule None) returns the anchor if it is still after `after`,
    else None (it has passed and does not repeat)."""
    after = after or datetime.now()
    if anchor is None:
        return None
    if not rule:
        return anchor if anchor > after else None

    freq = rule.get("freq")
    interval = max(1, int(rule.get("interval") or 1))
    h, mi = _tod_from_rule(rule, anchor)

    if freq == "daily":
        d = max(anchor.date(), after.date())
        cand = datetime(d.year, d.month, d.day, h, mi)
        while cand <= after:
            cand += timedelta(days=interval)
        return cand

    if freq == "weekly":
        wd = rule.get("weekday")
        if wd is None:
            wd = anchor.weekday()
        d = _next_weekday(after.date(), wd, allow_today=True)
        cand = datetime(d.year, d.month, d.day, h, mi)
        while cand <= after:
            cand += timedelta(weeks=interval)
        return cand

    if freq == "monthly":
        dom = rule.get("day_of_month") or anchor.day
        base = date(after.year, after.month, 1)
        for step in range(0, 48):
            m = _add_months(base, step)
            day = min(dom, _days_in_month(m.year, m.month))
            cand = datetime(m.year, m.month, day, h, mi)
            if cand > after:
                # respect interval: only every `interval` months from anchor
                if interval > 1:
                    months_from_anchor = (m.year - anchor.year) * 12 + (m.month - anchor.month)
                    if months_from_anchor % interval != 0:
                        continue
                return cand
        return None

    if freq == "yearly":
        mo = rule.get("month") or anchor.month
        dom = rule.get("day_of_month") or anchor.day
        for y in range(after.year, after.year + 20):
            day = min(dom, _days_in_month(y, mo))
            cand = datetime(y, mo, day, h, mi)
            if cand > after:
                if interval > 1 and (y - anchor.year) % interval != 0:
                    continue
                return cand
        return None

    # unknown freq → treat as one-off
    return anchor if anchor > after else None


def expand(anchor, rule, start=None, end=None, limit=50):
    """List concrete occurrences in [start, end] (inclusive), capped at `limit`.
    One-off: just the anchor if in range."""
    start = start or datetime.now()
    out = []
    if anchor is None:
        return out
    if not rule:
        if (anchor >= start) and (end is None or anchor <= end):
            out.append(anchor)
        return out
    cursor = anchor - timedelta(seconds=1)
    # seed from max(anchor-1s, start-1s) so first >= start is captured
    if start and start > anchor:
        cursor = start - timedelta(seconds=1)
    for _ in range(limit * 4):
        nxt = next_occurrence(anchor, rule, after=cursor)
        if nxt is None:
            break
        if end is not None and nxt > end:
            break
        if nxt >= start:
            out.append(nxt)
            if len(out) >= limit:
                break
        cursor = nxt
    return out


def agenda(items, start=None, end=None, now=None, limit_per_item=50):
    """Build a combined, time-sorted agenda across mixed items for a calendar
    window — the server-side mirror of the app's calendar _collect().

    Each `item` is a dict:
        {"id", "kind", "anchor" (datetime|None), "rule" (dict|None),
         "done" (bool), "title" (str)}
    where `kind` is e.g. "reminder" | "todo" | "note". Recurring reminders are
    expanded via expand()/next_occurrence() so every occurrence inside
    [start, end] appears; one-off items / dated todos / dated notes contribute a
    single point if in range. Returns a list of occurrence dicts:
        {"id","kind","title","when","overdue","done","recurring"}
    sorted ascending by `when`. Deterministic; no DB, no AI."""
    now = now or datetime.now()
    out = []
    for it in items or []:
        anchor = it.get("anchor")
        if anchor is None:
            continue
        rule = it.get("rule")
        done = bool(it.get("done"))
        base = {
            "id": it.get("id"),
            "kind": it.get("kind"),
            "title": it.get("title", ""),
            "done": done,
            "recurring": bool(rule),
        }
        if not rule:
            if (start is None or anchor >= start) and (end is None or anchor <= end):
                out.append({**base, "when": anchor,
                            "overdue": (not done) and anchor < now})
        else:
            for occ in expand(anchor, rule, start=start, end=end, limit=limit_per_item):
                out.append({**base, "when": occ,
                            "overdue": (not done) and occ < now})
    out.sort(key=lambda o: o["when"])
    return out


def is_overdue(anchor, rule, done=False, now=None):
    """True when a reminder has a fire time in the past that still needs action.
    Recurring reminders are overdue when their *most recent* occurrence has passed
    and the next one hasn't fired yet only matters for display; here we report
    whether the current/last due instant is in the past and not done."""
    now = now or datetime.now()
    if done or anchor is None:
        return False
    if not rule:
        return anchor < now
    # recurring: find the last occurrence at or before now
    last = last_occurrence(anchor, rule, at=now)
    if last is None:
        return False
    # overdue only within a day window (recurring reminders auto-advance)
    return last <= now


def last_occurrence(anchor, rule, at=None):
    """Most recent occurrence at or before `at` (default now), or None."""
    at = at or datetime.now()
    if anchor is None or anchor > at:
        return None
    if not rule:
        return anchor
    # walk forward from anchor until we pass `at`, keeping the previous
    prev = None
    cursor = anchor - timedelta(seconds=1)
    for _ in range(2000):
        nxt = next_occurrence(anchor, rule, after=cursor)
        if nxt is None or nxt > at:
            break
        prev = nxt
        cursor = nxt
    return prev


# ---------------------------------------------------------------- snooze
_SNOOZE_PRESETS_MIN = {
    "10 min": 10, "15 min": 15, "30 min": 30, "1 hour": 60, "2 hour": 120,
}

_BN_NUM_WORDS = {
    "আধা": 0.5, "এক": 1, "দুই": 2, "তিন": 3, "চার": 4, "পাঁচ": 5,
    "ছয়": 6, "সাত": 7, "আট": 8, "নয়": 9, "দশ": 10, "পনের": 15,
    "পনেরো": 15, "কুড়ি": 20, "বিশ": 20, "ত্রিশ": 30, "আধ": 0.5,
}


def snooze(current_due, text, now=None):
    """Resolve a natural-language snooze request to a new datetime.

    Handles: "10 min", "snooze 30 minutes", "১৫ মিনিট", "আধা ঘণ্টা", "১ ঘণ্টা",
    "2 hours", "tomorrow", "tomorrow morning", "আগামীকাল সকাল", "কাল", "tonight",
    "next week". Relative durations are added to `now` (or current_due if already
    future and no explicit 'from now'); date words jump to that day.

    Returns a datetime, or None if nothing parseable."""
    now = now or datetime.now()
    base = current_due if (current_due and current_due > now) else now
    low = normalize_digits(text or "").lower().strip()

    # ---- absolute-ish day jumps ----
    # day-after-tomorrow ("পরশু") -> +2 days at the requested daypart (default 9)
    if re.search(r"পরশু|day after tomorrow", low):
        d = now.date() + timedelta(days=2)
        hr = _part_hour(low, default=DEFAULT_HOUR)
        return datetime(d.year, d.month, d.day, hr, 0)
    if re.search(r"tomorrow|আগামীকাল|আগামিকাল|\bকাল\b|\bkal\b", low):
        d = now.date() + timedelta(days=1)
        hr = _part_hour(low, default=8)  # tomorrow defaults to morning 8
        return datetime(d.year, d.month, d.day, hr, 0)
    if re.search(r"tonight|আজ রাতে|রাতে", low):
        return datetime(now.year, now.month, now.day, 21, 0)
    if re.search(r"next week|আগামী সপ্তাহ", low):
        d = now.date() + timedelta(days=7)
        hr = _part_hour(low, default=9)
        return datetime(d.year, d.month, d.day, hr, 0)
    if re.search(r"later today|আজ পরে|একটু পরে", low):
        return now + timedelta(hours=3)

    # ---- durations: digits ----
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:min|minute|মিনিট|m\b)", low)
    if m:
        return now + timedelta(minutes=float(m.group(1)))
    m = re.search(r"(\d+(?:\.\d+)?)\s*(?:hour|hr|ঘণ্টা|ঘন্টা|h\b)", low)
    if m:
        return now + timedelta(hours=float(m.group(1)))
    m = re.search(r"(\d+)\s*(?:day|দিন)", low)
    if m:
        return now + timedelta(days=int(m.group(1)))

    # ---- durations: bangla number words ("আধা ঘণ্টা", "তিন ঘণ্টা") ----
    for word, val in _BN_NUM_WORDS.items():
        if word in low:
            if "ঘণ্টা" in low or "ঘন্টা" in low:
                return now + timedelta(hours=val)
            if "মিনিট" in low:
                return now + timedelta(minutes=val)
            if "দিন" in low:
                return now + timedelta(days=int(val))

    # ---- morning/evening without a day → next such part ----
    hr = _part_hour(low, default=None)
    if hr is not None:
        cand = datetime(now.year, now.month, now.day, hr, 0)
        if cand <= now:
            cand += timedelta(days=1)
        return cand

    return None


def _part_hour(low, default=None):
    if re.search(r"morning|সকাল|ভোর", low):
        return 8
    if re.search(r"noon|দুপুর", low):
        return 13
    if re.search(r"afternoon|বিকাল|বিকেল", low):
        return 16
    if re.search(r"evening|সন্ধ্যা|সন্ধ্যে", low):
        return 18
    if re.search(r"night|রাত", low):
        return 21
    return default


# ---------------------------------------------------------------- memory search
def _tokens(s):
    s = normalize_digits(s or "").lower()
    # split on whitespace + common punctuation (keeps bangla & latin words)
    return [t for t in re.split(r"[\s,।.!?;:\-/()\"']+", s) if t]


def _fuzzy_contains(hay, needle):
    """Cheap fuzzy: substring, or prefix match >=4 chars (handles minor suffix
    differences like plural/বিভক্তি without a full edit-distance library)."""
    if needle in hay:
        return True
    if len(needle) >= 4 and (hay.startswith(needle) or needle.startswith(hay)):
        return True
    return False


# strip common Bangla question framing so "আমি তোমাকে X সম্পর্কে কী বলেছিলাম?" → "X"
_MEMORY_STOP = {
    "what", "did", "i", "tell", "you", "about", "me", "my", "the", "a", "an",
    "do", "know", "remember", "said", "was", "is", "of",
    "আমি", "তোমাকে", "আপনাকে", "কী", "কি", "বলেছিলাম", "বলেছি", "সম্পর্কে",
    "নিয়ে", "তুমি", "আপনি", "জানো", "জানেন", "আমার", "মনে", "আছে", "কে", "টা",
    "বিষয়ে", "ব্যাপারে", "কোথায়", "কখন", "কত",
}


def extract_memory_query(text):
    """Pull the meaningful search terms out of a natural-language memory question.
    'আমি তোমাকে আম্মুর ওষুধ সম্পর্কে কী বলেছিলাম?' -> ['আম্মুর', 'ওষুধ']."""
    toks = _tokens(text)
    keep = [t for t in toks if t not in _MEMORY_STOP and len(t) > 1]
    return keep or toks


def search_memory(query, items, limit=10):
    """Rank memory items by relevance to a natural-language query.

    items: list of dicts with keys 'title', 'detail', 'category' (any may be '').
    Returns a new list (subset) sorted by descending score, each item augmented
    with '_score' and '_matched' (the query tokens that hit). Deterministic:
    ties broken by original order (stable)."""
    terms = extract_memory_query(query)
    scored = []
    for idx, it in enumerate(items):
        title = normalize_digits(it.get("title", "")).lower()
        detail = normalize_digits(it.get("detail", "")).lower()
        category = normalize_digits(it.get("category", "")).lower()
        title_toks = _tokens(title)
        detail_toks = _tokens(detail)
        cat_toks = _tokens(category)
        score = 0.0
        matched = []
        for term in terms:
            hit = False
            # weighted: title 3, category 2, detail 1 (exact token beats fuzzy)
            if term in title_toks:
                score += 3.0; hit = True
            elif any(_fuzzy_contains(t, term) for t in title_toks):
                score += 2.0; hit = True
            if term in cat_toks:
                score += 2.0; hit = True
            elif any(_fuzzy_contains(t, term) for t in cat_toks):
                score += 1.0; hit = True
            if term in detail_toks:
                score += 1.0; hit = True
            elif any(_fuzzy_contains(t, term) for t in detail_toks):
                score += 0.5; hit = True
            if hit:
                matched.append(term)
        if score > 0:
            scored.append((score, -idx, idx, it, matched))
    scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
    out = []
    for score, _neg, _idx, it, matched in scored[:limit]:
        row = dict(it)
        row["_score"] = round(score, 2)
        row["_matched"] = matched
        out.append(row)
    return out


def summarize_rule(rule, lang="bn"):
    """Human recurrence label for UI (fallback — app prefers ARB labels)."""
    if not rule:
        return ""
    freq = rule.get("freq")
    en = {"daily": "Daily", "weekly": "Weekly", "monthly": "Monthly", "yearly": "Yearly"}
    bn = {"daily": "প্রতিদিন", "weekly": "প্রতি সপ্তাহ", "monthly": "প্রতি মাস", "yearly": "প্রতি বছর"}
    tbl = en if lang == "en" else bn
    return tbl.get(freq, freq or "")
