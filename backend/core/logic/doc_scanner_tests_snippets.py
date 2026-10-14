"""
doc_scanner_tests_snippets.py — plain-assert tests for the DOCUMENT SCANNER /
organiser (#29, §21). Pure stdlib. `python doc_scanner_tests_snippets.py` or
import and call run_all(). All logic is deterministic + holds no bytes + runs
no OCR, so every assertion below is hand-verified against fixed inputs.
"""

try:  # Django harness: core.logic.doc_scanner_tests_snippets
    from core.logic import doc_scanner as D
except ImportError:  # standalone
    import doc_scanner as D  # noqa: E402


# --------------------------------------------------------------- type coerce

def test_normalise_type_known_and_fallback():
    assert D.normalise_type("NID") == "nid"
    assert D.normalise_type("  Passport ") == "passport"
    assert D.normalise_type("garbage") == "other"
    assert D.normalise_type("") == "other"
    assert D.normalise_type(None) == "other"


def test_suggest_type_from_title_keywords():
    assert D.suggest_type("My Passport scan") == "passport"
    assert D.suggest_type("DESCO electricity bill June") == "bill"
    assert D.suggest_type("SSC marksheet") == "certificate"
    assert D.suggest_type("grocery money receipt") == "receipt"
    assert D.suggest_type("Smart card national id") == "nid"
    assert D.suggest_type("random unrelated note") == "other"


# --------------------------------------------------------------- validation

def test_validate_ok_with_title_only():
    assert D.validate("My NID", "nid") == []


def test_validate_catches_missing_title_and_bad_type():
    assert "title_required" in D.validate("   ", "nid")
    assert "bad_type" in D.validate("Doc", "spaceship")


# --------------------------------------------------------------- build row

def test_build_item_shape_and_honest_ocr_flags():
    it = D.build_item("Electric bill", "bill", image_ref="/tmp/a.jpg",
                      notes="June", date="2026-06-01")
    for k in ("title", "doc_type", "image_ref", "notes", "date", "has_image",
              "extracted_text", "ocr_state", "ai_required", "mock", "problems"):
        assert k in it, k
    assert it["doc_type"] == "bill"
    assert it["has_image"] is True
    # HONEST: no OCR run here, so extracted text is empty and state is locked
    assert it["extracted_text"] == ""
    assert it["ocr_state"] == "ocr_locked"
    assert it["ai_required"] is False
    assert it["mock"] is True
    assert it["problems"] == []


def test_build_item_manual_entry_without_image():
    it = D.build_item("Birth certificate", "certificate")
    assert it["has_image"] is False
    assert it["image_ref"] == ""
    assert it["problems"] == []  # title alone is a valid manual record


def test_build_item_coerces_bad_type_but_flags_nothing_fatal():
    it = D.build_item("Some doc", "unknown-type")
    assert it["doc_type"] == "other"  # coerced
    # validate ran on the RAW type, so it surfaces the soft bad_type key
    assert "bad_type" in it["problems"]


# --------------------------------------------------------------- ocr state

def test_ocr_state_locked_without_key():
    s = D.ocr_state(False)
    assert s["state"] == "ocr_locked"
    assert s["key"] == "ocr"
    assert s["can_autoread"] is False


def test_ocr_state_ready_with_key():
    s = D.ocr_state(True)
    assert s["state"] == "ocr_ready"
    assert s["can_autoread"] is True


# --------------------------------------------------------------- list ops

_ITEMS = [
    {"title": "My NID", "doc_type": "nid", "notes": "", "extracted_text": ""},
    {"title": "DESCO bill", "doc_type": "bill", "notes": "June", "extracted_text": ""},
    {"title": "Passport", "doc_type": "passport", "notes": "expires 2030",
     "extracted_text": ""},
    {"title": "Shop memo", "doc_type": "receipt", "notes": "",
     "extracted_text": "Total 500"},
]


def test_filter_by_type():
    out = D.filter_items(_ITEMS, doc_type="bill")
    assert len(out) == 1 and out[0]["title"] == "DESCO bill"


def test_filter_all_keeps_everything():
    assert len(D.filter_items(_ITEMS, doc_type="all")) == len(_ITEMS)
    assert len(D.filter_items(_ITEMS, doc_type=None)) == len(_ITEMS)


def test_search_matches_title_notes_and_extracted_text():
    assert len(D.filter_items(_ITEMS, query="desco")) == 1          # title
    assert len(D.filter_items(_ITEMS, query="expires")) == 1        # notes
    assert len(D.filter_items(_ITEMS, query="total 500")) == 1      # OCR text
    assert D.filter_items(_ITEMS, query="total 500")[0]["title"] == "Shop memo"


def test_filter_is_stable_and_nonmutating():
    before = [dict(x) for x in _ITEMS]
    _ = D.filter_items(_ITEMS, doc_type="all", query="o")
    assert _ITEMS == before  # inputs untouched


def test_type_counts_zero_filled_plus_total():
    c = D.type_counts(_ITEMS)
    assert c["nid"] == 1 and c["bill"] == 1 and c["passport"] == 1
    assert c["receipt"] == 1 and c["certificate"] == 0 and c["other"] == 0
    assert c["total"] == 4


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"doc_scanner: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
