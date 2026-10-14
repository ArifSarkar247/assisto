"""
area_community.py — pure, deterministic AREA / NEIGHBOURHOOD BOARD logic
(#194, SPEC v2.1 §20, built to the §21 "advanced" standard).

A LOCAL-AREA utility board: residents of one AREA post short notices — an
announcement, a local service on offer, a lost-&-found, a community event, or a
neighbourhood alert — and browse what others in the SAME area posted, with
category filters and honest empty states.

This is NOT the Messenger community system. The Messenger module already has
general Communities (threaded group chat). This is a small, focused, READ-mostly
NOTICE BOARD scoped to a geographic area (a ward / neighbourhood string the user
sets) — a bulletin board, not a chat. Keep it that way.

HARD RULES
----------
  * PURE: no Django, no DB, no network, no live clock, no AI. `now` is always
    PASSED IN so the Dart mirror is identical offline and tests can pin it.
  * CONSERVATIVE PRIVACY: a post is scoped to an AREA LABEL (e.g. "Dhanmondi,
    Dhaka") — never an exact address or GPS. This module refuses to surface a
    `house`/`gps`/`lat`/`lon` field even if a caller smuggles one in: it only
    ever reads the whitelisted display fields. Area matching is case-insensitive
    on the normalised area label.
  * DETERMINISTIC ORDER: newest first by `created` (ISO string compare is safe
    because we require ISO-8601), ties broken by descending id, so the list is
    stable for the tests and the mirror.
  * Human-facing copy is bilingual {"bn","en"} so the Dart layer renders it
    directly and keeps ZERO Bangla in .dart. The ৳ sign (if a service lists a
    price) is a currency glyph and is gate-exempt.

PERSISTENCE (generic per-user JSON collection; integrator wires 'area/posts'
into GENERIC_COLLECTIONS in core/views.py — list precedent, no migration):
    area/posts → [{id, category, title, body, area, contact?, price?, created}]
This module holds no rows; the view persists them. Note: the generic collection
is per-user; "area scope" here is a deterministic FILTER over whatever rows the
caller passes in (the user's own board + any shared rows the app merges). We do
not fabricate a cross-user feed — honest about what the data is.

Run self-tests (no DB):
    python3 -c "import core.logic.area_community_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary

# The five post categories. Stable keys; the UI localises each label. "all" is a
# filter-only pseudo-category (never stored on a post).
CATEGORIES = ("announcement", "service", "lost_found", "event", "alert")
FILTER_ALL = "all"

# Only these fields are ever read off a stored post. Anything else a caller
# smuggles in (house number, gps, lat/lon, phone-in-body …) is IGNORED here —
# conservative privacy is enforced by the whitelist, not by trusting the caller.
_DISPLAY_FIELDS = ("id", "category", "title", "body", "area", "contact",
                   "price", "created")

# Fields we actively refuse to echo, documented so the intent is explicit.
_FORBIDDEN_FIELDS = ("house", "address", "gps", "lat", "lon", "latitude",
                     "longitude", "exact_location")

MAX_TITLE = 120
MAX_BODY = 1000


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def norm_area(area):
    """Normalise an area label for forgiving, case-insensitive matching: trim,
    collapse whitespace, strip spaces around commas, lower-case, so people who
    type the same place slightly differently still land in the same area.
    '  Dhanmondi ,  Dhaka ' and 'dhanmondi, dhaka' both -> 'dhanmondi,dhaka'."""
    s = _clean(area).lower()
    # collapse spaces around commas so ', ' / ' ,' / ' , ' all unify to ','
    return ",".join(part.strip() for part in s.split(","))


def is_known_category(cat):
    return cat in CATEGORIES


# ----------------------------------------------------------------- validate

def validate(category, title, body="", area=""):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    * category must be a known post category (NOT 'all', which is filter-only).
    * title is required and bounded.
    * body is optional but bounded.
    * area is required (a post must belong to an area to be scoped).
    """
    problems = []
    if category not in CATEGORIES:
        problems.append("bad_category")
    t = _clean(title)
    if not t:
        problems.append("empty_title")
    elif len(t) > MAX_TITLE:
        problems.append("title_too_long")
    if len(_clean(body)) > MAX_BODY:
        problems.append("body_too_long")
    if not _clean(area):
        problems.append("empty_area")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- sanitise

def display_post(row):
    """Project a stored row to the SAFE, whitelisted display shape. Forbidden
    precise-location fields are dropped. Returns a plain dict; never mutates the
    input. `contact`/`price` are optional and omitted when blank."""
    row = row or {}
    out = {
        "id": row.get("id"),
        "category": row.get("category") if is_known_category(row.get("category")) else "announcement",
        "title": _clean(row.get("title")),
        "body": _clean(row.get("body")),
        "area": _clean(row.get("area")),
        "created": _clean(row.get("created")),
    }
    contact = _clean(row.get("contact"))
    if contact:
        out["contact"] = contact
    price = _clean(row.get("price"))
    if price:
        out["price"] = price
    return out


# ----------------------------------------------------------------- feed

def _sort_key(post):
    """Newest first by ISO `created`, ties by descending id. We negate id via a
    (created, id) tuple and reverse-sort, so missing ids sort last, stably."""
    return (post.get("created") or "", post.get("id") or 0)


def feed(posts, area=None, category=FILTER_ALL):
    """Build the area board: filter rows to `area` (when given) and `category`
    (when not 'all'), project each to the safe display shape, newest first.

    Returns {"posts":[...], "count":int, "counts":{cat:int,...}, "area":str,
    "category":str}. `counts` is per-category over the AREA-scoped rows (before
    the category filter) so the UI can show honest filter badges. Deterministic.
    """
    want_area = norm_area(area) if area else None
    scoped = []
    for raw in (posts or []):
        p = display_post(raw)
        if not p["title"]:
            continue  # a titleless row is not a real notice; drop it
        if want_area is not None and norm_area(p["area"]) != want_area:
            continue
        scoped.append(p)

    counts = {c: 0 for c in CATEGORIES}
    for p in scoped:
        counts[p["category"]] = counts.get(p["category"], 0) + 1

    if category != FILTER_ALL and category in CATEGORIES:
        shown = [p for p in scoped if p["category"] == category]
    else:
        shown = list(scoped)

    shown.sort(key=_sort_key, reverse=True)
    return {
        "posts": shown,
        "count": len(shown),
        "counts": counts,
        "area_total": len(scoped),
        "area": _clean(area) if area else "",
        "category": category if (category == FILTER_ALL or category in CATEGORIES) else FILTER_ALL,
    }


def category_label(lang, category):
    """Bilingual label for a category key (for test parity; the Dart layer has
    its own localised getters — this is for the backend/self-tests)."""
    labels = {
        "announcement": ("ঘোষণা", "Announcement"),
        "service": ("স্থানীয় সেবা", "Local service"),
        "lost_found": ("হারানো-পাওয়া", "Lost & found"),
        "event": ("অনুষ্ঠান", "Event"),
        "alert": ("সতর্কতা", "Alert"),
        "all": ("সব", "All"),
    }
    bn, en = labels.get(category, labels["announcement"])
    return pick(lang, bn, en)
