"""
pa_filing.py — the deterministic, key-free engine behind PA SECRETARY MODE's
DOCUMENT FILING cabinet (issue #109, SPEC v2.1 §14, ADVANCED §21).

This is a FILING CABINET the PA keeps for the owner: file a document into a
category (contracts / invoices / letters / reports / other), with a TITLE, free
TAGS, NOTES and a filing DATE, then search / filter the cabinet. It complements
— does not duplicate — the document SCANNER (#29 doc_scanner.py, which captures
and tags loose scans) and the encrypted vault; the focus here is ORGANISING an
office's correspondence into folders the PA can retrieve on demand.

This module is PURE: no Django, no DB, no network, no clock, **no OCR, no AI**.
It is a DETERMINISTIC organiser — categorise, validate, normalise, filter and
tally — so the on-device Dart mirror (`pa_filing_engine.dart`) behaves
identically offline and the tests can pin it.

HONEST OCR, KEY-GATED
---------------------
Auto-READING the text of a filed scan (OCR) is a DOCUMENTED key-gated seam.
Without an OCR key (Integrations → `ocr`) the cabinet works fully as a MANUAL
filing tool and NEVER fabricates extracted text — `ocr_state()` returns an
honest "connect an OCR key to auto-extract text / title" state and
`extracted_text` stays "". When the owner connects the `ocr` key, the
app/executor MAY route the filed image to the provider, fill `extracted_text`,
and OFFER a suggested title; this file does no OCR and invents nothing either
way. `extracted_text` is ALWAYS "" here.

STORAGE SEAM
------------
This logic holds NO bytes. A filed scan is referenced by `image_ref` — an opaque
string the UI fills with the picked file path or a server media id. The cabinet
treats `image_ref` as an opaque handle and never reads it.

PERSISTENCE (described, not performed here): rows round-trip through the generic
per-user JSON collection `pa/filing` (PaCollectionItem precedent) as
{id, ...build_item(...)}. See up_pafileminutes_integration.md.

Everything is plain stdlib and hand-verified in pa_filing_tests_snippets.py.
"""

# ---------------------------------------------------------------- vocabulary

# Filing categories (folders) the cabinet sorts by. The UI localises these keys;
# the engine only validates / filters on them. "other" is the safe fallback.
CATEGORIES = ("contracts", "invoices", "letters", "reports", "other")

# The honest OCR state keys the UI renders. The engine never emits prose.
OCR_LOCKED = "ocr_locked"   # no key → manual only, "connect an OCR key"
OCR_READY = "ocr_ready"     # key present → auto-extract offered (routed away)

# Which Integrations key auto text-extraction needs. Documented seam.
OCR_KEY = "ocr"

# Keyword hints that nudge a FALLBACK category guess from the title/notes the
# user typed. These only SUGGEST a folder when the user hasn't chosen one; they
# never OCR and never override an explicit choice. Neutral English +
# romanised-only seeds so the Dart mirror stays Bangla-free; matching is
# case-insensitive substring. First matching category in CATEGORIES order wins.
_CATEGORY_HINTS = {
    "contracts": ("contract", "agreement", "mou", "nda", "deed", "lease",
                  "tenancy", "chukti"),
    "invoices": ("invoice", "bill", "receipt", "voucher", "payment", "memo",
                 "quotation", "challan"),
    "letters": ("letter", "memo to", "notice", "circular", "application",
                "cover letter", "chithi"),
    "reports": ("report", "summary", "statement", "minutes", "audit",
                "survey", "analysis"),
}


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def normalise_category(category):
    """Coerce any input to a known category; unknown / blank ⇒ 'other'. Total."""
    c = _clean(category).lower()
    return c if c in CATEGORIES else "other"


def normalise_tags(tags):
    """Coerce tags (a list OR a comma-separated string) into a clean, de-duped,
    lower-cased list in first-seen order. Total; never raises."""
    raw = []
    if isinstance(tags, str):
        raw = tags.replace("\n", ",").split(",")
    elif isinstance(tags, (list, tuple)):
        raw = list(tags)
    out, seen = [], set()
    for t in raw:
        c = _clean(t).lower()
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def suggest_category(title, notes=""):
    """Deterministic FALLBACK category guess from title/notes keywords. Returns
    a category key, defaulting to 'other' when nothing matches. This is a hint
    the UI can pre-select; it is NOT OCR and never reads the image. First
    matching category in CATEGORIES order wins so the guess is stable."""
    hay = (_clean(title) + " " + _clean(notes)).lower()
    for c in CATEGORIES:
        for kw in _CATEGORY_HINTS.get(c, ()):  # 'other' has no hints → skipped
            if kw in hay:
                return c
    return "other"


# ----------------------------------------------------------------- validate

def validate(title, category="other", image_ref="", notes="", tags=None):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    A filed document needs at least a TITLE (so the cabinet is readable). The
    category is auto-fixed via normalise_category(); an unknown value is a soft
    problem the UI can repair. `image_ref` is optional — a title alone files a
    manual record."""
    problems = []
    if not _clean(title):
        problems.append("title_required")
    if _clean(category).lower() not in CATEGORIES:
        problems.append("bad_category")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- build row

def build_item(title, category="other", image_ref="", notes="", date="",
               tags=None):
    """Normalise one document into the row shape stored in the `pa/filing`
    collection.

    Returns:
        {
          "title", "category", "image_ref", "notes", "date", "tags",
          "has_image":      bool,       # whether a scan handle is attached
          "extracted_text": "",         # HONEST: empty until the OCR key reads it
          "ocr_state":      "ocr_locked",  # UI shows the honest key-gated state
          "ai_required":    False,      # manual filing needs no key
          "mock":           True,       # honest: organiser output, no OCR run
          "problems":       [...]       # validate() keys
        }

    Deterministic + total: never raises on bad input, coerces the category.
    Holds no bytes — `image_ref` is an opaque handle the UI supplies.
    `extracted_text` is ALWAYS "" here; only the key-gated OCR seam fills it and
    this engine never fabricates it."""
    title = _clean(title)
    cat = normalise_category(category)
    ref = _clean(image_ref)
    return {
        "title": title,
        "category": cat,
        "image_ref": ref,
        "notes": _clean(notes),
        "date": _clean(date),
        "tags": normalise_tags(tags),
        "has_image": bool(ref),
        "extracted_text": "",       # never fabricated; OCR seam fills it
        "ocr_state": OCR_LOCKED,    # honest: no key → manual only
        "ai_required": False,
        "mock": True,
        "problems": validate(title, category, ref, notes, tags),
    }


def ocr_state(ocr_key_present):
    """Honest OCR availability for the UI. Returns a dict, never prose:

        {"state", "key": "ocr", "can_autoread": bool}

    `ocr_locked` → the UI shows "connect an OCR key to auto-extract text / title"
    and the cabinet stays a manual filing tool. `ocr_ready` → the UI may OFFER
    auto-extraction, routed through the key-gated provider elsewhere (not here).
    This engine never runs OCR and never fabricates extracted text either way."""
    present = bool(ocr_key_present)
    return {
        "state": OCR_READY if present else OCR_LOCKED,
        "key": OCR_KEY,
        "can_autoread": present,
    }


# ----------------------------------------------------------------- list ops

def filter_items(items, category=None, query="", tag=""):
    """Filter + search a list of filed rows, deterministically.

    * `category` (optional) keeps only rows of that folder (normalised);
      None / "" / 'all' keeps every folder.
    * `query` (optional) is a case-insensitive substring matched against the
      title AND notes AND tags AND any already-extracted_text (so OCR'd text
      becomes searchable once the key fills it — never fabricated).
    * `tag` (optional) keeps only rows carrying that exact tag (normalised).

    Order is preserved (stable). Each item is read-only; nothing is mutated."""
    q = _clean(query).lower()
    tg = _clean(tag).lower()
    want = None
    if category and _clean(category).lower() not in ("", "all"):
        want = normalise_category(category)
    out = []
    for it in (items or []):
        c = normalise_category(it.get("category"))
        if want is not None and c != want:
            continue
        item_tags = normalise_tags(it.get("tags"))
        if tg and tg not in item_tags:
            continue
        if q:
            hay = " ".join([
                _clean(it.get("title")),
                _clean(it.get("notes")),
                " ".join(item_tags),
                _clean(it.get("extracted_text")),
            ]).lower()
            if q not in hay:
                continue
        out.append(it)
    return out


def category_counts(items):
    """Deterministic per-category tally (every CATEGORY present, zero-filled)
    plus a 'total'. The UI renders the folder chips with these counts."""
    counts = {c: 0 for c in CATEGORIES}
    total = 0
    for it in (items or []):
        counts[normalise_category(it.get("category"))] += 1
        total += 1
    counts["total"] = total
    return counts


def all_tags(items):
    """Deterministic sorted set of every tag across the cabinet (for the tag
    filter). De-duped, lower-cased, sorted for a stable chip order."""
    seen = set()
    for it in (items or []):
        for t in normalise_tags(it.get("tags")):
            seen.add(t)
    return sorted(seen)
