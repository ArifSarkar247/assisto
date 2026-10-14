"""
health_timeline.py — pure, deterministic HEALTH-TIMELINE logic (#69, SPEC v2.1
§10, ADVANCED). A chronological personal health RECORD: the user logs events
(doctor visit, test result, prescription, vaccination, symptom, hospitalisation)
with a date and notes, then views them as a filterable, grouped timeline.

This is a RECORD / LOG — it is NOT a medical opinion. We never diagnose, never
score severity, never give treatment advice. Any medicine reference stays with
the DGDA-sourced medicine module; this file invents no drug data and holds no
clinical knowledge. A gentle "not medical advice — consult a doctor" note is
returned for the UI to show.

HARD RULES (Section-21 "advanced" discipline):

  * NO DB, NO AI, NO I/O, NO live clock. Every function is pure: plain
    dict/list in, plain dict/list out. "now"/"today" is always PASSED IN so the
    Dart mirror and the tests pin identical output.
  * DETERMINISTIC ordering. Events sort newest-first by (date, created_at, id)
    with a total, stable tie-break — the same list always yields the same order.
  * HONEST. We never fabricate an event, a category, or a date. A missing date
    is surfaced as "undated", not guessed.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Row shape (one flexible per-user JSON collection, path 'health/timeline'):
    {id, category, title, date (YYYY-MM-DD), notes, doctor, place}

Run self-tests (no DB):
    python3 -c "import core.logic.health_timeline_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime

# The event categories, in a fixed display order. Each is a stable machine key;
# the UI localises the label. We deliberately keep this list closed so the
# timeline groups deterministically and the Dart mirror cannot drift.
CATEGORIES = (
    "visit",          # doctor / clinic visit
    "test",           # lab / diagnostic test result
    "prescription",   # a prescription issued
    "vaccination",    # a vaccine dose
    "symptom",        # a symptom the user noted (record only, never diagnosed)
    "hospitalization",  # admission / hospital stay
    "other",          # anything else the user wants to keep
)

_CATEGORY_SET = frozenset(CATEGORIES)


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# date helpers (pure — no live clock)
# ---------------------------------------------------------------------------

def _parse_date(v):
    """Coerce an ISO-ish date string / date / datetime to a `date`. Junk -> None."""
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip().split("T")[0].split(" ")[0]
    try:
        return date.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def _iso(d):
    return d.isoformat() if isinstance(d, date) else None


def norm_category(c):
    """Map any input to a known category; unknown -> 'other' (never dropped)."""
    s = str(c or "").strip().lower()
    return s if s in _CATEGORY_SET else "other"


# ---------------------------------------------------------------------------
# normalisation
# ---------------------------------------------------------------------------

def normalize(row):
    """One raw stored row -> a clean, display-ready event dict. Pure; keeps the
    original id so the UI can edit/delete. A missing/unparsable date becomes
    `date=None` and `undated=True` (honest, never guessed)."""
    d = _parse_date(row.get("date"))
    created = _parse_date(row.get("created_at")) or d
    return {
        "id": row.get("id"),
        "category": norm_category(row.get("category")),
        "title": str(row.get("title") or "").strip(),
        "notes": str(row.get("notes") or "").strip(),
        "doctor": str(row.get("doctor") or "").strip(),
        "place": str(row.get("place") or "").strip(),
        "date": _iso(d),
        "undated": d is None,
        "_d": d,            # internal, for sorting
        "_created": created,  # internal, for sorting tie-break
    }


# ---------------------------------------------------------------------------
# deterministic ordering
# ---------------------------------------------------------------------------

def _sort_key(e):
    """Newest first. Undated events sort to the very bottom (date.min).
    Tie-break: created_at desc, then id desc — a TOTAL, stable order so the
    same list always renders identically."""
    d = e["_d"] or date.min
    c = e["_created"] or date.min
    # id may be int or None; coerce to a comparable with None last.
    eid = e.get("id")
    eid = eid if isinstance(eid, int) else -1
    # negate via ordinal for descending on a reverse=False sort would be messy;
    # we instead return a tuple and sort reverse=True on the whole thing.
    return (d.toordinal(), c.toordinal(), eid)


def order_events(rows):
    """Normalise + sort newest-first, deterministically. Returns clean events
    with the internal `_d`/`_created` keys removed."""
    events = [normalize(r) for r in (rows or [])]
    events.sort(key=_sort_key, reverse=True)
    for e in events:
        e.pop("_d", None)
        e.pop("_created", None)
    return events


# ---------------------------------------------------------------------------
# filtering
# ---------------------------------------------------------------------------

def filter_events(rows, categories=None, query=None):
    """Return ordered events restricted to `categories` (iterable of category
    keys; None/empty = all) and matching a free-text `query` (case-insensitive
    substring over title/notes/doctor/place; None/empty = all). Pure."""
    wanted = None
    if categories:
        wanted = {norm_category(c) for c in categories}
    q = str(query or "").strip().lower()
    out = []
    for e in order_events(rows):
        if wanted is not None and e["category"] not in wanted:
            continue
        if q:
            hay = " ".join(
                [e["title"], e["notes"], e["doctor"], e["place"]]).lower()
            if q not in hay:
                continue
        out.append(e)
    return out


# ---------------------------------------------------------------------------
# grouping
# ---------------------------------------------------------------------------

def group_by_month(rows, categories=None, query=None):
    """Group the (filtered, ordered) events into month buckets, newest month
    first. Undated events go into a dedicated trailing bucket keyed 'undated'.
    Returns a list of {key, year, month, count, events} — deterministic."""
    events = filter_events(rows, categories=categories, query=query)
    buckets = []
    index = {}
    for e in events:
        if e["date"]:
            d = date.fromisoformat(e["date"])
            key = f"{d.year:04d}-{d.month:02d}"
            year, month = d.year, d.month
        else:
            key, year, month = "undated", None, None
        b = index.get(key)
        if b is None:
            b = {"key": key, "year": year, "month": month,
                 "count": 0, "events": []}
            index[key] = b
            buckets.append(b)
        b["events"].append(e)
        b["count"] += 1
    # events already newest-first; buckets preserve first-seen order which,
    # given the sort, is newest month first then 'undated' last.
    return buckets


def group_by_category(rows, categories=None, query=None):
    """Group events by category in CATEGORIES order (empty categories omitted).
    Returns a list of {category, count, events}. Deterministic."""
    events = filter_events(rows, categories=categories, query=query)
    by = {c: [] for c in CATEGORIES}
    for e in events:
        by[e["category"]].append(e)
    return [{"category": c, "count": len(by[c]), "events": by[c]}
            for c in CATEGORIES if by[c]]


# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

def category_counts(rows):
    """{category: count} over ALL rows, every category present (0 allowed).
    Deterministic; used for the filter chips / summary header."""
    counts = {c: 0 for c in CATEGORIES}
    for r in (rows or []):
        counts[norm_category(r.get("category"))] += 1
    return counts


def summary(rows, today):
    """A deterministic header summary from a PASSED-IN `today` (ISO str / date).
    Returns total, dated/undated counts, per-category counts, the most-recent
    dated event's date, and days-since-last-event (None if no dated event)."""
    t = _parse_date(today)
    events = order_events(rows)
    dated = [e for e in events if e["date"]]
    last_date = dated[0]["date"] if dated else None
    days_since = None
    if last_date and t:
        days_since = (t - date.fromisoformat(last_date)).days
    return {
        "total": len(events),
        "dated": len(dated),
        "undated": len(events) - len(dated),
        "by_category": category_counts(rows),
        "last_event_date": last_date,
        "days_since_last": days_since,
    }


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate(category, title, date_value):
    """Return a list of machine error keys for a proposed event (empty = ok).
    A title is required; the date, if given, must parse; category must be known
    (unknown is coerced, never an error)."""
    errs = []
    if not str(title or "").strip():
        errs.append("title_required")
    if date_value not in (None, "") and _parse_date(date_value) is None:
        errs.append("bad_date")
    _ = norm_category(category)  # never fails; coerces
    return errs


# ---------------------------------------------------------------------------
# honest disclaimer (bilingual, returned — never a Bangla literal in .dart)
# ---------------------------------------------------------------------------

def disclaimer():
    return {
        "bn": "এটি শুধু আপনার স্বাস্থ্য রেকর্ড — কোনো চিকিৎসা পরামর্শ নয়। "
              "সিদ্ধান্তের জন্য ডাক্তারের সঙ্গে কথা বলুন।",
        "en": "This is only your health record — not medical advice. "
              "Please consult a doctor for any decision.",
    }
