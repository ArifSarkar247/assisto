"""
doc_scanner.py — the deterministic, key-free logic behind Assisto's DOCUMENT
SCANNER / organiser (issue #29, SPEC v2.1 §21, ADVANCED).

This is a document CAPTURE + ORGANISE tool. The user adds a document (a photo
from the picker, or a plain manual entry), gives it a TITLE + optional NOTES,
TAGS it by type (NID / passport / certificate / bill / receipt / other), and
gets a searchable, filterable list back. It complements — does not duplicate —
the secure vault: the focus here is scan/organise/tag, not encrypted storage.

This module is PURE: no Django, no DB, no network, no clock, **no OCR, no AI**.
It is a DETERMINISTIC organiser — normalise a document, categorise/validate a
type, and filter/search a list — so the on-device Dart mirror behaves
identically offline and the tests can pin it.

HONEST OCR, KEY-GATED
---------------------
Reading text OUT of the image (OCR) is a DOCUMENTED key-gated seam. Without an
OCR key (Integrations → `ocr`), the tool works fully as a MANUAL organiser and
NEVER fabricates extracted text — `ocr_state()` returns an honest
"connect an OCR key to auto-read text" state and `extracted_text` stays "". When
the owner connects the `ocr` key, the app/executor MAY route the image to the
provider and fill `extracted_text`; this file does no OCR and invents nothing.

STORAGE SEAM
------------
This logic holds NO bytes. A document's image is referenced by `image_ref` — an
opaque string the UI fills with the picked file path (the way other media
screens keep a local path) OR a server document id if one is uploaded through an
existing media endpoint. The organiser treats `image_ref` as an opaque handle
and never reads it.

Everything is plain stdlib and hand-verified in doc_scanner_tests_snippets.py.
"""

# ---------------------------------------------------------------- vocabulary

# Document types the organiser tags by. The UI localises these keys; the engine
# only validates / filters on them. "other" is the safe fallback.
DOC_TYPES = ("nid", "passport", "certificate", "bill", "receipt", "other")

# The honest OCR state keys the UI renders. The engine never emits prose.
OCR_LOCKED = "ocr_locked"   # no key → manual only, "connect an OCR key"
OCR_READY = "ocr_ready"     # key present → auto-read offered (routed elsewhere)

# Which Integrations key auto text-extraction needs. Documented seam.
OCR_KEY = "ocr"

# Keyword hints that nudge a FALLBACK type guess from a title the user typed.
# These only SUGGEST a type when the user hasn't picked one; they never OCR and
# never override an explicit choice. Neutral English + romanised-only seeds so
# the Dart mirror stays Bangla-free; matching is case-insensitive substring.
_TYPE_HINTS = {
    "nid": ("nid", "national id", "smart card", "voter"),
    "passport": ("passport", "mrp", "e-passport"),
    "certificate": ("certificate", "certi", "degree", "diploma", "marksheet",
                    "transcript", "ssc", "hsc"),
    "bill": ("bill", "invoice", "utility", "electric", "gas", "water", "wasa",
             "desco", "palli"),
    "receipt": ("receipt", "memo", "voucher", "payment slip", "money receipt"),
}


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def normalise_type(doc_type):
    """Coerce any input to a known type; unknown / blank ⇒ 'other'. Total."""
    t = _clean(doc_type).lower()
    return t if t in DOC_TYPES else "other"


def suggest_type(title, notes=""):
    """Deterministic FALLBACK type guess from the title/notes keywords. Returns
    a type key, defaulting to 'other' when nothing matches. This is a hint the
    UI can pre-select; it is NOT OCR and never reads the image. First matching
    type in DOC_TYPES order wins so the guess is stable."""
    hay = (_clean(title) + " " + _clean(notes)).lower()
    for t in DOC_TYPES:
        for kw in _TYPE_HINTS.get(t, ()):  # 'other' has no hints → skipped
            if kw in hay:
                return t
    return "other"


# ----------------------------------------------------------------- validate

def validate(title, doc_type="other", image_ref="", notes=""):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    A document needs at least a TITLE (so the list is readable) and either a
    typed entry or an image — but a title alone is enough to save a manual
    record, so `image_ref` is optional. An unknown type is a soft problem the
    UI can auto-fix via normalise_type()."""
    problems = []
    if not _clean(title):
        problems.append("title_required")
    if _clean(doc_type).lower() not in DOC_TYPES:
        problems.append("bad_type")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- build row

def build_item(title, doc_type="other", image_ref="", notes="", date=""):
    """Normalise one document into the row shape stored in the collection.

    Returns:
        {
          "title", "doc_type", "image_ref", "notes", "date",
          "has_image":   bool,        # whether an image handle is attached
          "extracted_text": "",       # HONEST: empty until OCR key reads it
          "ocr_state":   "ocr_locked",  # UI shows the honest key-gated state
          "ai_required": False,       # manual organise needs no key
          "mock": True,               # honest: organiser output, no OCR run
          "problems": [...]           # validate() keys
        }

    Deterministic + total: never raises on bad input, coerces the type. Holds
    no bytes — `image_ref` is an opaque handle the UI supplies (local path or a
    server media id). `extracted_text` is ALWAYS "" here; only the key-gated OCR
    seam fills it, and this engine never fabricates it."""
    title = _clean(title)
    dt = normalise_type(doc_type)
    ref = _clean(image_ref)
    return {
        "title": title,
        "doc_type": dt,
        "image_ref": ref,
        "notes": _clean(notes),
        "date": _clean(date),
        "has_image": bool(ref),
        "extracted_text": "",       # never fabricated; OCR seam fills it
        "ocr_state": OCR_LOCKED,    # honest: no key → manual only
        "ai_required": False,
        "mock": True,
        "problems": validate(title, doc_type, ref, notes),
    }


def ocr_state(ocr_key_present):
    """Honest OCR availability for the UI. Returns a dict, never prose:

        {"state", "key": "ocr", "can_autoread": bool}

    `ocr_locked` → the UI shows "connect an OCR key to auto-read text" and the
    tool stays a manual organiser. `ocr_ready` → the UI may OFFER auto-read,
    which is routed through the key-gated provider elsewhere (not here). This
    engine never runs OCR and never fabricates extracted text either way."""
    present = bool(ocr_key_present)
    return {
        "state": OCR_READY if present else OCR_LOCKED,
        "key": OCR_KEY,
        "can_autoread": present,
    }


# ----------------------------------------------------------------- list ops

def filter_items(items, doc_type=None, query=""):
    """Filter + search a list of document rows, deterministically.

    * `doc_type` (optional) keeps only rows of that type (normalised); None/""
      or 'all' keeps every type.
    * `query` (optional) is a case-insensitive substring matched against the
      title AND notes AND any already-extracted_text (so OCR'd text becomes
      searchable once the key fills it — but we never fabricate it).

    Order is preserved (stable). Each item is read-only; nothing is mutated."""
    q = _clean(query).lower()
    want = None
    if doc_type and _clean(doc_type).lower() not in ("", "all"):
        want = normalise_type(doc_type)
    out = []
    for it in (items or []):
        t = normalise_type(it.get("doc_type"))
        if want is not None and t != want:
            continue
        if q:
            hay = " ".join([
                _clean(it.get("title")),
                _clean(it.get("notes")),
                _clean(it.get("extracted_text")),
            ]).lower()
            if q not in hay:
                continue
        out.append(it)
    return out


def type_counts(items):
    """Deterministic per-type tally (every DOC_TYPE present, zero-filled) plus a
    'total'. The UI renders the filter chips with these counts."""
    counts = {t: 0 for t in DOC_TYPES}
    total = 0
    for it in (items or []):
        counts[normalise_type(it.get("doc_type"))] += 1
        total += 1
    counts["total"] = total
    return counts
