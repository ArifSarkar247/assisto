"""
pa_pr.py — the deterministic engine behind PA SECRETARY MODE (celebrity tier)
PR & PRESS TRACKER (issue #122, SPEC v2.1 §14, ADVANCED).

A public-figure's PA tracks MEDIA COVERAGE and upcoming INTERVIEWS by hand,
offline, with NO key:
    * coverage items  — outlet, type (print/online/tv/radio/social), date,
                        sentiment (positive/neutral/negative), link
    * upcoming interviews — outlet, topic, date/time, place
    * talking-points notes (free text the PA keeps per topic)

This engine produces a deterministic coverage ROLL-UP (counts by type and by
sentiment, a simple sentiment tally), a chronological coverage list (newest
first), and an upcoming-interviews list split into UPCOMING vs PAST from a
passed-in `now`.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.
Nothing is fetched from any outlet and no sentiment is auto-detected — the PA
types the sentiment themselves; we never fabricate a quote, a link or a verdict.
Mirrors the conventions of the other pa_*/logic modules.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_pr_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Coverage media types (neutral English seed keys; the UI localises them).
TYPE_PRINT = "print"
TYPE_ONLINE = "online"
TYPE_TV = "tv"
TYPE_RADIO = "radio"
TYPE_SOCIAL = "social"
COVERAGE_TYPES = (TYPE_PRINT, TYPE_ONLINE, TYPE_TV, TYPE_RADIO, TYPE_SOCIAL)

# Sentiment the PA assigns (we never auto-detect it).
SENT_POSITIVE = "positive"
SENT_NEUTRAL = "neutral"
SENT_NEGATIVE = "negative"
SENTIMENTS = (SENT_POSITIVE, SENT_NEUTRAL, SENT_NEGATIVE)


# ------------------------------------------------------------------ parsing

def _parse(dt):
    """Lenient ISO-8601 → datetime, or None. Accepts a trailing 'Z'. Never
    raises."""
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

def normalize_coverage(item):
    """Coerce a dict into a clean coverage item. Unknown type → online, unknown
    sentiment → neutral. Never raises; never invents a link or a verdict."""
    x = dict(item or {})
    typ = x.get("type")
    if typ not in COVERAGE_TYPES:
        typ = TYPE_ONLINE
    sent = x.get("sentiment")
    if sent not in SENTIMENTS:
        sent = SENT_NEUTRAL
    return {
        "id": x.get("id"),
        "outlet": _clean(x.get("outlet")),
        "type": typ,
        "date": (str(x.get("date")).strip() if x.get("date") else ""),
        "sentiment": sent,
        "link": _clean(x.get("link")),
        "note": str(x.get("note") or ""),
    }


def normalize_interview(item):
    """Coerce a dict into a clean upcoming interview."""
    x = dict(item or {})
    return {
        "id": x.get("id"),
        "outlet": _clean(x.get("outlet")),
        "topic": _clean(x.get("topic")),
        "at": (str(x.get("at")).strip() if x.get("at") else ""),
        "place": _clean(x.get("place")),
        "note": str(x.get("note") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_coverage(item):
    """A coverage item needs an outlet; date must parse if present."""
    x = normalize_coverage(item)
    problems = []
    if not x["outlet"]:
        problems.append("outlet_required")
    if x["date"] and _parse(x["date"]) is None:
        problems.append("bad_date")
    return problems


def validate_interview(item):
    """An interview needs an outlet; at must parse if present."""
    x = normalize_interview(item)
    problems = []
    if not x["outlet"]:
        problems.append("outlet_required")
    if x["at"] and _parse(x["at"]) is None:
        problems.append("bad_at")
    return problems


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"
_NEAR = "0000-01-01T00:00:00"


def order_coverage(items):
    """Coverage newest-first; undated last. Stable (ties → outlet, id)."""
    normed = [normalize_coverage(x) for x in (items or [])]

    def key(c):
        d = _parse(c["date"])
        # newest first: invert by using a descending sort on the time
        return (d is None, _neg_time(d), c["outlet"].lower(), str(c.get("id") or ""))
    return sorted(normed, key=key)


def _neg_time(dt):
    """A sortable value that puts LATER datetimes first (newest-first). Dateless
    handled by the caller's (d is None) leading key."""
    if dt is None:
        return 0
    # negative POSIX-ish ordinal: larger date → smaller (earlier in sort)
    return -(dt.timestamp())


def order_interviews(items):
    """Interviews chronological (soonest first); undated last."""
    normed = [normalize_interview(x) for x in (items or [])]

    def key(m):
        d = _parse(m["at"])
        return (d.isoformat() if d else _FAR, m["outlet"].lower(),
                str(m.get("id") or ""))
    return sorted(normed, key=key)


# ---------------------------------------------------------------- derived

def coverage_rollup(items):
    """Deterministic counts by type and by sentiment + a net sentiment tally.
    Pure numbers the UI renders — no sentiment is auto-detected here."""
    normed = [normalize_coverage(x) for x in (items or [])]
    by_type = {t: 0 for t in COVERAGE_TYPES}
    by_sentiment = {s: 0 for s in SENTIMENTS}
    for c in normed:
        by_type[c["type"]] += 1
        by_sentiment[c["sentiment"]] += 1
    net = by_sentiment[SENT_POSITIVE] - by_sentiment[SENT_NEGATIVE]
    return {
        "count": len(normed),
        "by_type": by_type,
        "by_sentiment": by_sentiment,
        "net_sentiment": net,   # +ve ⇒ more positive coverage (PA-assigned)
        "mock": False,
    }


def split_interviews(items, now):
    """Split interviews into UPCOMING (at >= now) and PAST (at < now) from a
    passed-in `now`. Undated interviews count as upcoming (still to schedule).
    Deterministic — no clock."""
    ordered = order_interviews(items)
    upcoming, past = [], []
    for m in ordered:
        at = _parse(m["at"])
        if at is None or at >= now:
            upcoming.append(m)
        else:
            past.append(m)
    return {
        "upcoming": upcoming,
        "past": past,
        "upcoming_count": len(upcoming),
        "past_count": len(past),
    }
