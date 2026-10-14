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

# Each entry MAY carry (all open / hand-written, generic common words):
#   bn, en            — canonical headwords (required)
#   pos               — part of speech
#   example           — a short generic example sentence (hand-written)
#   ipa               — a light pronunciation note for the EN side (common ARPAbet-
#                       free approximation; NOT copied from any proprietary source)
#   syn / ant         — synonyms / antonyms (EN side, generic common words)
# These extra fields are optional; older/real datasets without them still work.
SAMPLE_ENTRIES = [
    {"bn": "পানি", "en": "water", "pos": "noun", "ipa": "ˈwɔːtər",
     "example": "She drank a glass of water.", "syn": ["H2O"], "ant": []},
    {"bn": "বই", "en": "book", "pos": "noun", "ipa": "bʊk",
     "example": "I read a good book.", "syn": ["volume", "text"], "ant": []},
    {"bn": "ঘর", "en": "house", "pos": "noun", "ipa": "haʊs",
     "example": "They built a new house.", "syn": ["home", "dwelling"], "ant": []},
    {"bn": "খাবার", "en": "food", "pos": "noun", "ipa": "fuːd",
     "example": "The food was delicious.", "syn": ["meal"], "ant": []},
    {"bn": "বন্ধু", "en": "friend", "pos": "noun", "ipa": "frɛnd",
     "example": "He is my best friend.", "syn": ["companion", "mate"],
     "ant": ["enemy", "foe"]},
    {"bn": "ভালো", "en": "good", "pos": "adjective", "ipa": "ɡʊd",
     "example": "This is a good idea.", "syn": ["fine", "nice"],
     "ant": ["bad", "poor"]},
    {"bn": "খারাপ", "en": "bad", "pos": "adjective", "ipa": "bæd",
     "example": "The weather is bad today.", "syn": ["poor", "awful"],
     "ant": ["good", "fine"]},
    {"bn": "বড়", "en": "big", "pos": "adjective", "ipa": "bɪɡ",
     "example": "That is a big tree.", "syn": ["large", "huge"],
     "ant": ["small", "little"]},
    {"bn": "ছোট", "en": "small", "pos": "adjective", "ipa": "smɔːl",
     "example": "A small cup of tea.", "syn": ["little", "tiny"],
     "ant": ["big", "large"]},
    {"bn": "যাওয়া", "en": "go", "pos": "verb", "ipa": "ɡoʊ",
     "example": "Let us go home.", "syn": ["move", "leave"],
     "ant": ["stay", "come"]},
    {"bn": "আসা", "en": "come", "pos": "verb", "ipa": "kʌm",
     "example": "Please come here.", "syn": ["arrive", "approach"],
     "ant": ["go", "leave"]},
    {"bn": "খাওয়া", "en": "eat", "pos": "verb", "ipa": "iːt",
     "example": "We eat rice daily.", "syn": ["consume"], "ant": ["fast"]},
    {"bn": "দিন", "en": "day", "pos": "noun", "ipa": "deɪ",
     "example": "It was a long day.", "syn": ["daytime"], "ant": ["night"]},
    {"bn": "রাত", "en": "night", "pos": "noun", "ipa": "naɪt",
     "example": "The night was cold.", "syn": ["nighttime"], "ant": ["day"]},
    {"bn": "সময়", "en": "time", "pos": "noun", "ipa": "taɪm",
     "example": "We have little time.", "syn": ["period", "moment"], "ant": []},
    {"bn": "টাকা", "en": "money", "pos": "noun", "ipa": "ˈmʌni",
     "example": "He saved some money.", "syn": ["cash", "funds"], "ant": []},
    {"bn": "কাজ", "en": "work", "pos": "noun", "ipa": "wɜːrk",
     "example": "She started her work.", "syn": ["job", "labour"],
     "ant": ["rest", "play"]},
    {"bn": "ভালোবাসা", "en": "love", "pos": "noun", "ipa": "lʌv",
     "example": "Love is powerful.", "syn": ["affection"], "ant": ["hate"]},
    {"bn": "সাহায্য", "en": "help", "pos": "noun", "ipa": "hɛlp",
     "example": "Thank you for your help.", "syn": ["aid", "support"], "ant": []},
    {"bn": "ধন্যবাদ", "en": "thanks", "pos": "noun", "ipa": "θæŋks",
     "example": "Many thanks for coming.", "syn": ["gratitude"], "ant": []},
]

# Module-level active dataset; starts as the sample. load_dataset() swaps it.
_ENTRIES = list(SAMPLE_ENTRIES)
_SOURCE_LABEL = SOURCE_LABEL_DEFAULT
_IS_SAMPLE = True


def _as_list(v):
    """Coerce a syn/ant field to a clean list of non-empty strings."""
    if isinstance(v, str):
        v = [p for p in re.split(r"[;,]", v)]
    out = []
    for x in (v or []):
        s = str(x).strip()
        if s and s not in out:
            out.append(s)
    return out


def _shape(e, bn=None, en=None):
    """Normalise one raw entry into the full advanced shape.

    Guarantees every optional advanced field (pos, example, ipa, syn, ant)
    exists so the UI can render uniformly. Datasets that omit a field just get
    an empty value — we never fabricate meanings, examples or pronunciation.
    """
    e = e or {}
    bn = bn if bn is not None else str(e.get("bn", "")).strip()
    en = en if en is not None else str(e.get("en", "")).strip()
    return {
        "bn": bn,
        "en": en,
        "pos": str(e.get("pos", "")).strip(),
        "example": str(e.get("example", "")).strip(),
        "ipa": str(e.get("ipa", "")).strip(),
        "syn": _as_list(e.get("syn")),
        "ant": _as_list(e.get("ant")),
    }


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
        cleaned.append(_shape(e, bn, en))
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
       'results': [ {bn, en, pos, example, ipa, syn[], ant[]}, ... ],
       'suggestions': [ shaped entries ],  # autocomplete for the query
       'word_of_the_day': shaped entry,    # stable per calendar day
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
    payload = {
        "found": found,
        "query": str(query or ""),
        "direction": direction,
        "results": [_shape(r) for r in results],
        "is_sample": _IS_SAMPLE,
        "source": _SOURCE_LABEL,
        "needs_data": needs,
        "needs_data_key": NEEDS_DATA_KEY if needs else None,
    }
    # Autocomplete for the query (source side). Empty for an empty query.
    payload["suggestions"] = suggestions(query, direction=direction, limit=8)
    # Word of the day travels on every response so the UI (incl. its empty
    # intro state) can show + offline-cache it without a second endpoint.
    payload["word_of_the_day"] = word_of_the_day()
    return payload


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
    out = [_shape(e) for e in _ENTRIES if _norm(e.get(src)).startswith(q)]
    out.sort(key=lambda e: _norm(e.get(src)))
    return out[:limit]


def word_of_the_day(day=None):
    """A deterministic "word of the day" drawn from the active dataset.

    `day`: a date-like object with .toordinal(), or None for today. The same day
    always yields the same word (stable across requests) so the UI can cache it
    offline. Returns a shaped entry dict, or {} if the dataset is empty.
    Never fabricates — only picks from already-loaded open/sample entries.
    """
    if not _ENTRIES:
        return {}
    if day is None:
        import datetime
        day = datetime.date.today()
    try:
        idx = int(day.toordinal()) % len(_ENTRIES)
    except Exception:
        idx = 0
    e = _shape(_ENTRIES[idx])
    e["is_sample"] = _IS_SAMPLE
    e["source"] = _SOURCE_LABEL
    return e


def needs_data_message(lang="bn"):
    """The honest empty/needs-data string (also exposed to the UI as a key)."""
    return pick(lang,
                "চালু হবে যখন ওপেন অভিধান ডাটা যুক্ত হবে",
                "Available when open dictionary data is added")
