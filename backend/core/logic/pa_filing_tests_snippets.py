"""
pa_filing_tests_snippets.py — plain-assert tests for the PA document-filing
cabinet engine (#109, §14, advanced §21). Pure stdlib.
`python pa_filing_tests_snippets.py` or import and call run_all(). The engine is
deterministic, so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import pa_filing as F
except ImportError:  # standalone
    import pa_filing as F  # noqa: E402


_ITEMS = [
    {"title": "Office lease agreement", "category": "contracts",
     "tags": ["legal", "2026"], "notes": "renewal due"},
    {"title": "DESCO electricity bill", "category": "invoices",
     "tags": ["utility"], "notes": "paid"},
    {"title": "Resignation letter", "category": "letters", "tags": []},
    {"title": "Q3 audit report", "category": "reports",
     "tags": ["finance", "2026"]},
    {"title": "Misc note", "category": "garbage", "tags": ["misc"]},  # → other
]


# --------------------------------------------------------------- categories

def test_normalise_category_known_and_fallback():
    assert F.normalise_category("Contracts") == "contracts"
    assert F.normalise_category("  REPORTS ") == "reports"
    assert F.normalise_category("nonsense") == "other"
    assert F.normalise_category("") == "other"
    assert F.normalise_category(None) == "other"


def test_suggest_category_from_keywords():
    assert F.suggest_category("Service agreement") == "contracts"
    assert F.suggest_category("Monthly invoice #42") == "invoices"
    assert F.suggest_category("Cover letter") == "letters"
    assert F.suggest_category("Annual report") == "reports"
    assert F.suggest_category("random words") == "other"


def test_suggest_category_order_is_stable():
    # 'contract' (contracts) wins over 'report' (reports) by CATEGORIES order
    assert F.suggest_category("contract report") == "contracts"


# --------------------------------------------------------------- tags

def test_normalise_tags_string_and_list_dedupe():
    assert F.normalise_tags("Legal, 2026 , legal") == ["legal", "2026"]
    assert F.normalise_tags(["A", "b", "A"]) == ["a", "b"]
    assert F.normalise_tags(None) == []
    assert F.normalise_tags("") == []


# --------------------------------------------------------------- validate

def test_validate_ok_and_problems():
    assert F.validate("Lease", category="contracts") == []
    assert "title_required" in F.validate("   ", category="letters")
    assert "bad_category" in F.validate("X", category="zzz")


# --------------------------------------------------------------- build_item

def test_build_item_shape_and_honest_ocr():
    it = F.build_item("  Lease  deal ", category="Contracts",
                      image_ref="/tmp/a.jpg", notes="x", date="2026-10-14",
                      tags="legal, 2026")
    assert it["title"] == "Lease deal"          # whitespace collapsed
    assert it["category"] == "contracts"
    assert it["has_image"] is True
    assert it["tags"] == ["legal", "2026"]
    # HONEST: never fabricated; OCR seam fills it
    assert it["extracted_text"] == ""
    assert it["ocr_state"] == F.OCR_LOCKED
    assert it["ai_required"] is False and it["mock"] is True
    assert it["problems"] == []


def test_build_item_coerces_bad_category():
    it = F.build_item("T", category="junk")
    assert it["category"] == "other"
    assert it["has_image"] is False


# --------------------------------------------------------------- ocr_state

def test_ocr_state_locked_and_ready():
    locked = F.ocr_state(False)
    assert locked["state"] == F.OCR_LOCKED and locked["can_autoread"] is False
    assert locked["key"] == "ocr"
    ready = F.ocr_state(True)
    assert ready["state"] == F.OCR_READY and ready["can_autoread"] is True


# --------------------------------------------------------------- filter/search

def test_filter_by_category():
    out = F.filter_items(_ITEMS, category="contracts")
    assert [x["title"] for x in out] == ["Office lease agreement"]


def test_filter_all_keeps_everything():
    assert len(F.filter_items(_ITEMS, category="all")) == len(_ITEMS)
    assert len(F.filter_items(_ITEMS, category="")) == len(_ITEMS)
    assert len(F.filter_items(_ITEMS, category=None)) == len(_ITEMS)


def test_filter_query_matches_title_notes_tags():
    assert len(F.filter_items(_ITEMS, query="desco")) == 1      # title
    assert len(F.filter_items(_ITEMS, query="renewal")) == 1    # notes
    assert len(F.filter_items(_ITEMS, query="utility")) == 1    # tag


def test_filter_by_tag():
    out = F.filter_items(_ITEMS, tag="2026")
    assert len(out) == 2


def test_filter_is_stable_and_nonmutating():
    before = [dict(x) for x in _ITEMS]
    _ = F.filter_items(_ITEMS, category="all", query="e", tag="2026")
    assert _ITEMS == before  # inputs untouched


# --------------------------------------------------------------- tallies

def test_category_counts_zero_filled_plus_total():
    c = F.category_counts(_ITEMS)
    assert c["contracts"] == 1 and c["invoices"] == 1 and c["letters"] == 1
    assert c["reports"] == 1 and c["other"] == 1  # 'garbage' → other
    assert c["total"] == 5


def test_all_tags_sorted_deduped():
    assert F.all_tags(_ITEMS) == ["2026", "finance", "legal", "misc", "utility"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_filing: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
