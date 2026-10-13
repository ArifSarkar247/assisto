"""
dictionary.py — Assisto bn<->en dictionary logic (module-5 "Life").

LICENSING (STRICT):
  This module ships ONLY a small, hand-written sample of common, generic words
  as a demo so the feature has a clean, honest first run. It does NOT bundle the
  Bangla Academy dictionary or any other proprietary / copyrighted lexical data,
  and it NEVER fabricates definitions. A real dictionary becomes available only
  when an OPEN-LICENSE dataset (e.g. CC0 / CC-BY / public-domain wordlists such
  as the FreeDict bn-en project, or Wiktionary extracts under CC-BY-SA with
  attribution) is wired in by the integrator via `load_dataset()`.

  Until such open data is added, lookups that miss the tiny sample return a
  clear needs-data state, which the UI renders as:
    "চালু হবে যখন ওপেন অভিধান ডাটা যুক্ত হবে /
     Available when open dictionary data is added"

Pure Python, deterministic, no AI key, unit-testable. Benchmarked against
offline dictionary apps (e.g. open-source "QuickDic"/StarDict-style lookup).
"""
import re
import unicodedata


def pick(lang, bn, en):
    return en if lang == "en" else bn


# The machine key the UI turns into the bilingual needs-data message above.
NEEDS_DATA_KEY = "dictionary_needs_open_data"
SOURCE_LABEL_DEFAULT = "sample"  # demo sample; real data sets its own label


# ---------------------------------------------------------------------------
# SAMPLE DATA — hand-written, generic common words only. NOT a copied dict.
# Each entry: canonical bn, canonical en, part-of-speech, example (optional).
# Kept intentionally tiny; it exists to demo the UI, not to be a dictionary.
# ---------------------------------------------------------------------------

SAMPLE_ENTRIES = [
    {"bn": "পানি", "en": "water", "pos": "noun"},
    {"bn": "বই", "en": "book", "pos": "noun"},
    {"bn": "ঘর", "en": "house", "pos": "noun"},
    {"bn": "খাবার", "en": "food", "pos": "noun"},
    {"bn": "বন্ধু", "en": "friend", "pos": "noun"},
    {"bn": "ভালো", "en": "good", "pos": "adjective"},
    {"bn": "খারাপ", "en": "bad", "pos": "adjective"},
    {"bn": "বড়", "en": "big", "pos": "adjective"},
    {"bn": "ছোট", "en": "small", "pos": "adjective"},
    {"bn": "যাওয়া", "en": "go", "pos": "verb"},
    {"bn": "আসা", "en": "come", "pos": "verb"},
    {"bn": "খাওয়া", "en": "eat", "pos": "verb"},
    {"bn": "দিন", "en": "day", "pos": "noun"},
    {"bn": "রাত", "en": "night", "pos": "noun"},
    {"bn": "সময়", "en": "time", "pos": "noun"},
    {"bn": "টাকা", "en": "money", "pos": "noun"},
    {"bn": "কাজ", "en": "work", "pos": "noun"},
    {"bn": "ভালোবাসা", "en": "love", "pos": "noun"},
    {"bn": "সাহায্য", "en": "help", "pos": "noun"},
    {"bn": "ধন্যবাদ", "en": "thanks", "pos": "noun"},
]

# Module-level active dataset; starts as the sample. load_dataset() swaps it.
_ENTRIES = list(SAMPLE_ENTRIES)
_SOURCE_LABEL = SOURCE_LABEL_DEFAULT
_IS_SAMPLE = True


def load_dataset(entries, source_label):
    """Integrator hook: replace the sample with an OPEN-LICENSE dataset.

    `entries`: iterable of dicts with at least 'bn' and 'en' keys.
    `source_label`: human string for attribution/UI (e.g. 'FreeDict bn-en (GPL)',
                    'Wiktionary (CC-BY-SA)'). This label is surfaced in the UI.
    Passing proprietary data here would violate licensing — don't. Only wire
    open/permissive sources.
    """
    global _ENTRIES, _SOURCE_LABEL, _IS_SAMPLE
    cleaned = []
    for e in (entries or []):
        bn = str((e or {}).get("bn", "")).strip()
        en = str((e or {}).get("en", "")).strip()
        if not bn or not en:
            continue
        cleaned.append({
            "bn": bn, "en": en,
            "pos": str((e or {}).get("pos", "")).strip(),
            "example": str((e or {}).get("example", "")).strip(),
        })
    _ENTRIES = cleaned
    _SOURCE_LABEL = str(source_label or "open-dataset")
    _IS_SAMPLE = False
    return len(_ENTRIES)


def reset_to_sample():
    """Restore the demo sample (used by tests / when no dataset is wired)."""
    global _ENTRIES, _SOURCE_LABEL, _IS_SAMPLE
    _ENTRIES = list(SAMPLE_ENTRIES)
    _SOURCE_LABEL = SOURCE_LABEL_DEFAULT
    _IS_SAMPLE = True


def is_sample():
    return _IS_SAMPLE


def source_label():
    return _SOURCE_LABEL


def entry_count():
    return len(_ENTRIES)


# ---------------------------------------------------------------------------
# normalisation + lookup
# ---------------------------------------------------------------------------

def _norm(s):
    """Case-fold + strip + unicode-normalise for stable matching."""
    s = unicodedata.normalize("NFC", str(s or "")).strip()
    return s.casefold()


def detect_lang(query):
    """Guess the query's script: 'bn' if it contains Bengali code points,
    else 'en'. Used to pick lookup direction automatically."""
    for ch in str(query or ""):
        if "ঀ" <= ch <= "৿":
            return "bn"
    return "en"


def lookup(query, direction="auto"):
    """Look a word up.

    direction: 'bn2en', 'en2bn', or 'auto' (detect from script).
    Returns a dict:
      {'found': bool, 'query': str, 'direction': str,
       'results': [ {bn, en, pos, example}, ... ],
       'is_sample': bool, 'source': str,
       'needs_data': bool, 'needs_data_key': str|None}

    When the active dataset is the demo sample and the word misses, `needs_data`
    is True so the UI shows the honest "open dictionary data" message instead of
    pretending the word doesn't exist in any dictionary.
    """
    q = _norm(query)
    if direction == "auto":
        direction = "bn2en" if detect_lang(query) == "bn" else "en2bn"
    results = []
    if q:
        src = "bn" if direction == "bn2en" else "en"
        # exact matches first, then prefix matches (both on the source side)
        exact = [e for e in _ENTRIES if _norm(e.get(src)) == q]
        prefix = [e for e in _ENTRIES
                  if e not in exact and _norm(e.get(src)).startswith(q)]
        results = exact + prefix
    found = len(results) > 0
    needs = (not found) and _IS_SAMPLE
    return {
        "found": found,
        "query": str(query or ""),
        "direction": direction,
        "results": [dict(r) for r in results],
        "is_sample": _IS_SAMPLE,
        "source": _SOURCE_LABEL,
        "needs_data": needs,
        "needs_data_key": NEEDS_DATA_KEY if needs else None,
    }


def suggestions(prefix, direction="auto", limit=8):
    """Autocomplete: words whose source side starts with `prefix`.

    Returns up to `limit` dicts (source-word + its translation). Empty prefix or
    no matches -> []. Never fabricates — only draws from the active dataset.
    """
    q = _norm(prefix)
    if not q:
        return []
    if direction == "auto":
        direction = "bn2en" if detect_lang(prefix) == "bn" else "en2bn"
    src = "bn" if direction == "bn2en" else "en"
    out = [dict(e) for e in _ENTRIES if _norm(e.get(src)).startswith(q)]
    out.sort(key=lambda e: _norm(e.get(src)))
    return out[:limit]


def needs_data_message(lang="bn"):
    """The honest empty/needs-data string (also exposed to the UI as a key)."""
    return pick(lang,
                "চালু হবে যখন ওপেন অভিধান ডাটা যুক্ত হবে",
                "Available when open dictionary data is added")
