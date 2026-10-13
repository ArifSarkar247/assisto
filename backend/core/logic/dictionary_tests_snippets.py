"""
dictionary_tests_snippets.py — plain-assert tests for core.logic.dictionary.
NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.dictionary_tests_snippets as t; t.run_all()"
"""
from core.logic import dictionary as D


def _reset():
    D.reset_to_sample()


def test_sample_is_active_by_default():
    _reset()
    assert D.is_sample() is True
    assert D.entry_count() == len(D.SAMPLE_ENTRIES)
    assert D.source_label() == D.SOURCE_LABEL_DEFAULT


def test_detect_lang():
    assert D.detect_lang("পানি") == "bn"
    assert D.detect_lang("water") == "en"
    assert D.detect_lang("") == "en"


def test_lookup_bn2en_and_en2bn_auto():
    _reset()
    r = D.lookup("পানি")
    assert r["found"] and r["direction"] == "bn2en"
    assert any(x["en"] == "water" for x in r["results"])
    r2 = D.lookup("water")
    assert r2["found"] and r2["direction"] == "en2bn"
    assert any(x["bn"] == "পানি" for x in r2["results"])


def test_lookup_miss_on_sample_sets_needs_data():
    _reset()
    r = D.lookup("supercalifragilistic")
    assert r["found"] is False
    assert r["needs_data"] is True
    assert r["needs_data_key"] == D.NEEDS_DATA_KEY


def test_lookup_case_insensitive_and_prefix():
    _reset()
    r = D.lookup("WATER")
    assert r["found"] is True
    # prefix: "boo" -> "book"
    r2 = D.lookup("boo", direction="en2bn")
    assert r2["found"] and any(x["en"] == "book" for x in r2["results"])


def test_suggestions():
    _reset()
    s = D.suggestions("b", direction="en2bn")
    ens = {x["en"] for x in s}
    assert "book" in ens and "bad" in ens and "big" in ens
    assert D.suggestions("", direction="en2bn") == []


def test_load_dataset_clears_needs_data():
    _reset()
    n = D.load_dataset(
        [{"bn": "আকাশ", "en": "sky", "pos": "noun"},
         {"bn": "", "en": "bad-skip"},          # skipped (missing bn)
         {"bn": "মাটি", "en": "soil"}],
        "FreeDict bn-en (open)")
    assert n == 2 and D.is_sample() is False
    assert D.source_label() == "FreeDict bn-en (open)"
    r = D.lookup("আকাশ")
    assert r["found"] and r["is_sample"] is False
    # miss on a REAL dataset -> not a needs-data state, just not found
    miss = D.lookup("nonexistentword", direction="en2bn")
    assert miss["found"] is False and miss["needs_data"] is False
    _reset()


def test_needs_data_message_bilingual():
    assert "open dictionary" in D.needs_data_message("en")
    assert "ওপেন অভিধান" in D.needs_data_message("bn")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    D.reset_to_sample()
    print(f"dictionary: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
