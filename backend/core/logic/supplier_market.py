"""
supplier_market.py — pure, deterministic SUPPLIER & WHOLESALE MARKET math
(#144, SPEC v2.1 §21, ADVANCED).

A supplier directory/manager for ONE business. The user records THEIR OWN
suppliers (name, category, products, location, contact, price notes, rating)
and this module filters/searches, compares a shortlist, and builds a
reorder/contact list. It is PURE, like price_radar.py / in_chat_ai.py: no
Django, no DB, no network, **no AI**, no clock, no external directory. Same
inputs → same output, so the on-device Dart mirror matches offline and the
tests pin it.

ONLY THE USER'S OWN SUPPLIERS — NO SCRAPING, NO FABRICATION
-----------------------------------------------------------
Every supplier shown is one the user themselves entered. We NEVER scrape a
LinkedIn-style external directory, never invent a vendor, never fabricate a
price or a review. With zero suppliers the directory is simply empty (honest
welcome state on the client).

HONEST PARTNER-DIRECTORY SEAM (KEY-GATED)
-----------------------------------------
A real partner/wholesale-market directory (a curated external source of
verified vendors) is a DOCUMENTED seam only: `directory_seam()` returns
{required, mock, query_shape} describing what such a route would look like.
Nothing here fetches anything and it returns NO suppliers — `partner_required=
True` is the honest "connect a partner-directory source" state. There is NO
partner-directory key in the Integrations REGISTRY yet; the integrator adds one
(slug e.g. `supplier_directory`) when a real partner source is chosen. Until
then this manual manager is the whole, honest feature.

MONEY
-----
`price notes` are free text the user keeps per supplier; this module does NOT
hold or compute money, so there is no poisha math here. Rating is an integer
0–5 the user assigns.

Hand-verified in supplier_market_tests_snippets.py.
"""

MARKER_KEY = "supplier_manual"       # "your own supplier list — not a directory"

# Stable category slugs the UI localises. "other" is the normalised fallback so
# an unknown/blank category never splinters the filter. We never invent
# categories — the user picks one of these when adding a supplier.
CATEGORIES = (
    "raw_material", "wholesale", "packaging", "electronics", "clothing",
    "food", "logistics", "services", "other",
)

# Rating is a 0–5 integer (0 = unrated). Clamped so a bad value never crashes
# sort/compare.
MAX_RATING = 5


# ------------------------------------------------------------------ helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _lc(text):
    return _clean(text).lower()


def _category(v):
    c = _lc(v) or "other"
    c = c.replace(" ", "_").replace("-", "_")
    return c if c in CATEGORIES else "other"


def _rating(v):
    """Parse a rating to a clamped int 0..MAX_RATING. Junk → 0."""
    try:
        r = int(round(float(v)))
    except (TypeError, ValueError):
        return 0
    return max(0, min(MAX_RATING, r))


def _products(v):
    """Normalise the products field to a clean list of strings.

    Accepts a list, or a comma/newline-separated string (what the UI text field
    gives). Trims, drops empties, de-dupes case-insensitively while keeping the
    first-seen display casing and input order."""
    raw = []
    if isinstance(v, (list, tuple)):
        raw = list(v)
    elif v:
        import re
        raw = re.split(r"[,\n]+", str(v))
    out, seen = [], set()
    for p in raw:
        p = _clean(p)
        if not p:
            continue
        k = p.lower()
        if k in seen:
            continue
        seen.add(k)
        out.append(p)
    return out


def normalize(row):
    """One raw supplier dict → a normalised supplier dict (pure).

    Keeps the original `id`/`raw` so the client can edit/delete the exact row.
    Deterministic; never raises on bad input.
    """
    name = _clean(row.get("name"))
    products = _products(row.get("products"))
    return {
        "id": row.get("id"),
        "name": name,
        "category": _category(row.get("category")),
        "products": products,
        "products_display": ", ".join(products),
        "location": _clean(row.get("location")),
        "contact": _clean(row.get("contact")),
        "price_note": _clean(row.get("price_note")),
        "rating": _rating(row.get("rating")),
        "note": _clean(row.get("note")),
        "reorder": bool(row.get("reorder")),
        "marker": MARKER_KEY,
        "raw": row,
    }


# ------------------------------------------------------------------ search

def _matches_query(sup, q):
    """Case-insensitive substring match across name / products / location /
    price note / free note. Empty query matches everything."""
    if not q:
        return True
    hay = " ".join([
        sup["name"], sup["products_display"], sup["location"],
        sup["price_note"], sup["note"],
    ]).lower()
    return q in hay


def search(rows, query="", category="", location="", min_rating=0,
           reorder_only=False):
    """Filter + sort the user's suppliers (pure).

    * query        — substring across name/products/location/notes (case-insens).
    * category      — exact category slug ('' = any).
    * location      — substring on location (case-insens; '' = any).
    * min_rating    — keep suppliers rated >= this (0 = any).
    * reorder_only  — keep only suppliers flagged for reorder.

    Sorted by rating DESC, then name ASC (stable, deterministic). Returns a dict
    with the matched list + counts + the category histogram for filter chips."""
    q = _lc(query)
    cat = _category(category) if _clean(category) else ""
    loc = _lc(location)
    minr = _rating(min_rating)

    normalized = [normalize(r) for r in (rows or []) if _clean(r.get("name"))]

    # category histogram over ALL suppliers (for filter chips + counts)
    by_cat = {}
    for s in normalized:
        by_cat[s["category"]] = by_cat.get(s["category"], 0) + 1

    matched = []
    for s in normalized:
        if cat and s["category"] != cat:
            continue
        if loc and loc not in s["location"].lower():
            continue
        if s["rating"] < minr:
            continue
        if reorder_only and not s["reorder"]:
            continue
        if not _matches_query(s, q):
            continue
        matched.append(s)

    # rating DESC, then name ASC — stable
    matched.sort(key=lambda s: (-s["rating"], s["name"].lower()))

    return {
        "suppliers": matched,
        "match_count": len(matched),
        "total_count": len(normalized),
        "reorder_count": sum(1 for s in normalized if s["reorder"]),
        "by_category": by_cat,
        "marker": MARKER_KEY,
        "partner_required": False,       # the manual manager needs no key
        "mock": True,
    }


# ------------------------------------------------------------------ compare

def compare(rows, ids):
    """Side-by-side compare a shortlist of suppliers by id (pure).

    `ids` is the user's picked shortlist (any length; 0/1 is allowed and honest
    — the client shows a hint to pick 2+). Returns the picked suppliers in the
    given order plus deterministic 'best' pointers computed ONLY from the user's
    own data: highest rating, and who to reorder. Ratings tie → first in the
    shortlist order (stable). Never fabricates a recommendation."""
    want = [i for i in (ids or [])]
    index = {}
    for r in rows or []:
        rid = r.get("id")
        if rid is not None and rid not in index and _clean(r.get("name")):
            index[rid] = normalize(r)

    picked = [index[i] for i in want if i in index]

    best_rating_id = None
    best_rating = -1
    reorder_ids = []
    for s in picked:
        if s["rating"] > best_rating:
            best_rating = s["rating"]
            best_rating_id = s["id"]
        if s["reorder"]:
            reorder_ids.append(s["id"])

    # a "best rating" pointer is only honest when at least one pick is rated
    if best_rating <= 0:
        best_rating_id = None

    return {
        "suppliers": picked,
        "count": len(picked),
        "best_rating_id": best_rating_id,
        "reorder_ids": reorder_ids,
        "enough": len(picked) >= 2,       # client hint: pick 2+ to compare
        "marker": MARKER_KEY,
        "mock": True,
    }


# ------------------------------------------------------------------ reorder

def reorder_list(rows):
    """The reorder/contact list: suppliers the user flagged `reorder=True`.

    Sorted by rating DESC then name ASC (same order as search). Pure; derived
    only from the user's flags. Returns the list + a count so the client can
    show an honest empty state when nothing is flagged."""
    normalized = [normalize(r) for r in (rows or []) if _clean(r.get("name"))]
    flagged = [s for s in normalized if s["reorder"]]
    flagged.sort(key=lambda s: (-s["rating"], s["name"].lower()))
    return {
        "suppliers": flagged,
        "count": len(flagged),
        "has_contact": sum(1 for s in flagged if s["contact"]),
        "marker": MARKER_KEY,
        "mock": True,
    }


# ------------------------------------------------------------------ directory seam

def directory_seam(query=None, category=None, location=None):
    """DOCUMENTED, key-gated seam for a PARTNER / WHOLESALE-MARKET directory —
    not wired.

    Returns the query shape a real partner-directory route would use, with
    `partner_required=True` as the honest "connect a partner-directory source"
    state. Nothing here fetches anything and it returns NO suppliers — only the
    user's own suppliers (via `search`) are ever shown; we never scrape a
    LinkedIn-style directory. There is no partner-directory key in the
    Integrations REGISTRY yet; the integrator adds one (slug e.g.
    `supplier_directory`) when a real partner source is chosen."""
    return {
        "partner_required": True,
        "mock": True,
        "marker": MARKER_KEY,
        "integration": "supplier_directory",   # NOT yet in REGISTRY — documented
        "query_shape": {
            "query": query, "category": category, "location": location,
        },
        # explicitly no suppliers: we never fabricate or scrape a listing
        "suppliers": [],
        "note_key": "supplierPartnerSeamBody",
    }
