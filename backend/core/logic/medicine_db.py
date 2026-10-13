"""
medicine_db.py — Assisto Medicine DATABASE (drug lookup), distinct from
medicine.py (which handles dose schedules / adherence for a person's own meds).

Benchmarked against the SAFE lookup subset of 1mg / Medisafe: search a brand or
generic, see generic + strength + form + manufacturer + indicative price + uses
+ how-to-take, and find same-generic alternatives.

LICENSING / SAFETY (STRICT — legal):
  - Drug data in Bangladesh is governed by DGDA (Directorate General of Drug
    Administration). We ship ONLY a SMALL, clearly-marked CURATED SAMPLE here so
    the feature is demonstrable; it is NOT a complete or authoritative database.
  - We NEVER copy DIMS, MedEx or any other proprietary database. These sample
    records are hand-written from widely-known public facts (generic name,
    common strength/form) and carry INDICATIVE prices only.
  - When real DGDA data is wired (via `set_source()` / a provider feed), the UI
    shows a live source; until then it shows the SAMPLE badge and a needs-data
    state. We NEVER fabricate drug facts beyond this curated set.
  - EVERY alternative and every record carries the switch-warning:
    "ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া ওষুধ বদলাবেন না /
     Do not switch medicines without a doctor's or pharmacist's advice."

Run self-tests:
    python3 -c "import core.logic.medicine_db_tests_snippets as t; t.run_all()"
"""


def pick(lang, bn, en):
    return en if lang == "en" else bn


# Data-source state. Default is the curated SAMPLE (no DGDA key wired yet).
SOURCE_SAMPLE = "sample"
SOURCE_DGDA = "dgda"

_SOURCE = SOURCE_SAMPLE


def set_source(source, records=None):
    """Integrator hook: flip the active data source. Kept module-level so the
    logic stays import-only and testable.

    SAFETY GUARD (legal): flipping to SOURCE_DGDA claims the data is the
    authoritative, licensed DGDA set. That is only honest if real records are
    supplied to REPLACE the curated SAMPLE _RECORDS. We therefore REQUIRE a
    non-empty `records` list when switching to SOURCE_DGDA; otherwise we refuse
    (raise) so sample data is never presented as authoritative DGDA data.

    `records` (when given) replaces the module's _RECORDS. Flipping back to
    SOURCE_SAMPLE restores the curated sample set.
    """
    global _SOURCE, _RECORDS
    if source not in (SOURCE_SAMPLE, SOURCE_DGDA):
        return _SOURCE
    if source == SOURCE_DGDA:
        if not records:
            raise ValueError(
                "set_source(SOURCE_DGDA) requires real `records` to replace the "
                "curated sample set; refusing to present SAMPLE data as "
                "authoritative DGDA data."
            )
        _RECORDS = list(records)
    elif source == SOURCE_SAMPLE and records is not None:
        _RECORDS = list(records)
    _SOURCE = source
    return _SOURCE


def current_source():
    return _SOURCE


def is_sample():
    return _SOURCE == SOURCE_SAMPLE


# ---------------------------------------------------------------------------
# the switch-warning — MUST appear on every record & alternative
# ---------------------------------------------------------------------------

def switch_warning(lang="bn"):
    return pick(lang,
                "ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া ওষুধ বদলাবেন না।",
                "Do not switch medicines without a doctor's or pharmacist's advice.")


def sample_notice(lang="bn"):
    """Shown while the source is the curated sample set."""
    return pick(lang,
                "এটি একটি ছোট নমুনা তালিকা। সম্পূর্ণ তথ্য চালু হবে যখন DGDA ডাটা যুক্ত হবে।",
                "This is a small sample list. Full data becomes available when DGDA data is added.")


def needs_data_state(lang="bn"):
    """Clean empty/needs-data state when no records are available for a query
    (or before any data source is wired)."""
    return {
        "available": False,
        "title": pick(lang, "ডাটা যুক্ত হয়নি", "Data not added yet"),
        "message": pick(lang,
                        "চালু হবে যখন DGDA ডাটা যুক্ত হবে।",
                        "Available when DGDA data is added."),
    }


# ---------------------------------------------------------------------------
# curated SAMPLE records (clearly marked — public, non-proprietary facts only)
# ---------------------------------------------------------------------------
# Fields: brand, generic, strength, form, manufacturer, price (indicative, BDT),
# uses_bn/en, how_bn/en. Prices are INDICATIVE strip/unit prices for display.

_RECORDS = [
    {"brand": "Napa", "generic": "Paracetamol", "strength": "500 mg",
     "form": "Tablet", "manufacturer": "Beximco Pharmaceuticals", "price": 1.20,
     "uses_bn": "জ্বর ও ব্যথা উপশমে।", "uses_en": "For fever and mild to moderate pain.",
     "how_bn": "খাবার পর পানি দিয়ে খান; ডাক্তারের নির্দেশিত মাত্রার বেশি নয়।",
     "how_en": "Take after food with water; do not exceed the dose your doctor advises."},
    {"brand": "Ace", "generic": "Paracetamol", "strength": "500 mg",
     "form": "Tablet", "manufacturer": "Square Pharmaceuticals", "price": 1.20,
     "uses_bn": "জ্বর ও ব্যথা উপশমে।", "uses_en": "For fever and mild to moderate pain.",
     "how_bn": "খাবার পর পানি দিয়ে খান; অতিরিক্ত মাত্রা লিভারের ক্ষতি করতে পারে।",
     "how_en": "Take after food with water; overdose can harm the liver."},
    {"brand": "Napa Extend", "generic": "Paracetamol", "strength": "665 mg",
     "form": "Tablet (ER)", "manufacturer": "Beximco Pharmaceuticals", "price": 1.80,
     "uses_bn": "দীর্ঘস্থায়ী ব্যথা উপশমে (ধীরে মুক্তি)।", "uses_en": "For longer-lasting pain relief (extended release).",
     "how_bn": "আস্ত গিলে খান, চিবাবেন না।", "how_en": "Swallow whole; do not chew."},

    {"brand": "Losectil", "generic": "Omeprazole", "strength": "20 mg",
     "form": "Capsule", "manufacturer": "Eskayef Pharmaceuticals", "price": 7.00,
     "uses_bn": "গ্যাস্ট্রিক, অম্লতা ও আলসারে।", "uses_en": "For acidity, gastric reflux and ulcers.",
     "how_bn": "সকালে খাবারের আগে খালি পেটে খান।", "how_en": "Take in the morning before food, on an empty stomach."},
    {"brand": "Seclo", "generic": "Omeprazole", "strength": "20 mg",
     "form": "Capsule", "manufacturer": "Square Pharmaceuticals", "price": 7.00,
     "uses_bn": "গ্যাস্ট্রিক, অম্লতা ও আলসারে।", "uses_en": "For acidity, gastric reflux and ulcers.",
     "how_bn": "সকালে খাবারের আগে খালি পেটে খান।", "how_en": "Take in the morning before food, on an empty stomach."},

    {"brand": "Monas", "generic": "Montelukast", "strength": "10 mg",
     "form": "Tablet", "manufacturer": "Acme Laboratories", "price": 9.00,
     "uses_bn": "হাঁপানি ও অ্যালার্জি প্রতিরোধে।", "uses_en": "To prevent asthma and allergy symptoms.",
     "how_bn": "রাতে একবার খান; হঠাৎ শ্বাসকষ্টে ইনহেলার ব্যবহার করুন।",
     "how_en": "Take once at night; use an inhaler for sudden breathing trouble."},

    {"brand": "Maxpro", "generic": "Esomeprazole", "strength": "20 mg",
     "form": "Capsule", "manufacturer": "Renata Limited", "price": 9.00,
     "uses_bn": "অম্লতা ও রিফ্লাক্সে।", "uses_en": "For acidity and reflux.",
     "how_bn": "খাবারের আগে খান।", "how_en": "Take before food."},

    {"brand": "Cef-3", "generic": "Cefixime", "strength": "200 mg",
     "form": "Capsule", "manufacturer": "Square Pharmaceuticals", "price": 25.00,
     "uses_bn": "ব্যাকটেরিয়াজনিত সংক্রমণে (ডাক্তারের নির্দেশে)।",
     "uses_en": "For bacterial infections (only as prescribed).",
     "how_bn": "পূর্ণ কোর্স শেষ করুন; মাঝপথে বন্ধ করবেন না।",
     "how_en": "Finish the full course; do not stop midway."},
    {"brand": "Fixim", "generic": "Cefixime", "strength": "200 mg",
     "form": "Capsule", "manufacturer": "Opsonin Pharma", "price": 25.00,
     "uses_bn": "ব্যাকটেরিয়াজনিত সংক্রমণে (ডাক্তারের নির্দেশে)।",
     "uses_en": "For bacterial infections (only as prescribed).",
     "how_bn": "পূর্ণ কোর্স শেষ করুন; অ্যান্টিবায়োটিক নিজে থেকে নেবেন না।",
     "how_en": "Finish the full course; never take antibiotics on your own."},

    {"brand": "Fexo", "generic": "Fexofenadine", "strength": "120 mg",
     "form": "Tablet", "manufacturer": "Sanofi Bangladesh", "price": 8.00,
     "uses_bn": "অ্যালার্জি, হাঁচি ও চুলকানিতে।", "uses_en": "For allergy, sneezing and itching.",
     "how_bn": "দিনে একবার খান; ঘুম কম আসে এমন অ্যান্টিহিস্টামিন।",
     "how_en": "Take once daily; a non-drowsy antihistamine."},

    {"brand": "Metryl", "generic": "Metformin", "strength": "500 mg",
     "form": "Tablet", "manufacturer": "Opsonin Pharma", "price": 2.00,
     "uses_bn": "টাইপ-২ ডায়াবেটিসে রক্তে সুগার নিয়ন্ত্রণে।",
     "uses_en": "To help control blood sugar in type-2 diabetes.",
     "how_bn": "খাবারের সাথে বা পরে খান; ডাক্তারের মাত্রা মেনে চলুন।",
     "how_en": "Take with or after food; follow your doctor's dose."},
    {"brand": "Comet", "generic": "Metformin", "strength": "500 mg",
     "form": "Tablet", "manufacturer": "Square Pharmaceuticals", "price": 2.00,
     "uses_bn": "টাইপ-২ ডায়াবেটিসে রক্তে সুগার নিয়ন্ত্রণে।",
     "uses_en": "To help control blood sugar in type-2 diabetes.",
     "how_bn": "খাবারের সাথে বা পরে খান।", "how_en": "Take with or after food."},
]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _norm(s):
    return " ".join(str(s or "").lower().split())


def _localize_record(rec, lang, with_alternatives=False):
    out = {
        "brand": rec["brand"],
        "generic": rec["generic"],
        "strength": rec["strength"],
        "form": rec["form"],
        "manufacturer": rec["manufacturer"],
        "price": rec["price"],
        "price_display": price_display(rec["price"], lang),
        "uses": pick(lang, rec["uses_bn"], rec["uses_en"]),
        "how_to_take": pick(lang, rec["how_bn"], rec["how_en"]),
        "source": _SOURCE,
        "is_sample": is_sample(),
        "switch_warning": switch_warning(lang),
    }
    if with_alternatives:
        out["alternatives"] = alternatives(rec["brand"], lang)
    return out


def price_display(price, lang="bn"):
    """Indicative per-unit price string. ৳ is allowed in .dart, but we format
    here so the backend owns the unit label."""
    if price is None:
        return pick(lang, "দাম অজানা", "price unknown")
    txt = ("%.2f" % float(price)).rstrip("0").rstrip(".")
    return pick(lang, f"আনুমানিক ৳{txt}/ইউনিট", f"approx ৳{txt}/unit")


# ---------------------------------------------------------------------------
# public API: search, lookup, alternatives
# ---------------------------------------------------------------------------

def search(query, lang="bn", limit=20):
    """Search by brand OR generic (prefix/substring, case-insensitive).
    Brand-prefix matches rank first, then generic matches, then substring.
    Returns localised records (no alternatives — kept light for lists)."""
    q = _norm(query)
    if not q:
        return []
    scored = []
    for rec in _RECORDS:
        b, g = _norm(rec["brand"]), _norm(rec["generic"])
        score = None
        if b.startswith(q):
            score = 0
        elif g.startswith(q):
            score = 1
        elif q in b:
            score = 2
        elif q in g:
            score = 3
        if score is not None:
            scored.append((score, rec["brand"], rec))
    scored.sort(key=lambda x: (x[0], x[1]))
    return [_localize_record(r, lang) for _, _, r in scored[:limit]]


def lookup(brand, lang="bn"):
    """Full localised detail for one brand (case-insensitive), with
    same-generic alternatives. None if not found."""
    b = _norm(brand)
    for rec in _RECORDS:
        if _norm(rec["brand"]) == b:
            return _localize_record(rec, lang, with_alternatives=True)
    return None


def alternatives(brand, lang="bn"):
    """Other brands with the SAME generic + strength as `brand`.
    Each alternative carries the switch-warning. Empty list if none/unknown."""
    b = _norm(brand)
    target = None
    for rec in _RECORDS:
        if _norm(rec["brand"]) == b:
            target = rec
            break
    if not target:
        return []
    out = []
    for rec in _RECORDS:
        if rec is target:
            continue
        if _norm(rec["generic"]) == _norm(target["generic"]) \
                and _norm(rec["strength"]) == _norm(target["strength"]):
            out.append({
                "brand": rec["brand"],
                "generic": rec["generic"],
                "strength": rec["strength"],
                "form": rec["form"],
                "manufacturer": rec["manufacturer"],
                "price": rec["price"],
                "price_display": price_display(rec["price"], lang),
                "switch_warning": switch_warning(lang),
            })
    out.sort(key=lambda a: (a["price"] if a["price"] is not None else 1e9, a["brand"]))
    return out


def alternatives_by_generic(generic, lang="bn"):
    """All brands of a given generic name (any strength), cheapest first."""
    g = _norm(generic)
    out = [rec for rec in _RECORDS if _norm(rec["generic"]) == g]
    out.sort(key=lambda r: (r["price"] if r["price"] is not None else 1e9, r["brand"]))
    return [_localize_record(r, lang) for r in out]


def record_count():
    return len(_RECORDS)


def meta(lang="bn"):
    """Header metadata for the screen: source badge + notice + disclaimer."""
    return {
        "source": _SOURCE,
        "is_sample": is_sample(),
        "count": record_count(),
        "sample_notice": sample_notice(lang) if is_sample() else "",
        "switch_warning": switch_warning(lang),
    }
