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


def test_entries_carry_advanced_fields():
    _reset()
    r = D.lookup("water")
    e = r["results"][0]
    # every advanced field is always present (shaped), even if empty
    for k in ("bn", "en", "pos", "example", "ipa", "syn", "ant"):
        assert k in e
    assert e["ipa"] and e["example"]           # water has both (hand-written)
    assert isinstance(e["syn"], list) and isinstance(e["ant"], list)


def test_synonyms_antonyms_open_sample():
    _reset()
    r = D.lookup("good")
    e = r["results"][0]
    assert "bad" in e["ant"]                    # generic open antonym
    assert e["syn"]                             # has synonyms


def test_lookup_bundles_suggestions_and_wotd():
    _reset()
    r = D.lookup("b", direction="en2bn")
    assert isinstance(r["suggestions"], list) and r["suggestions"]
    assert all("bn" in s and "en" in s for s in r["suggestions"])
    wotd = r["word_of_the_day"]
    assert wotd and "bn" in wotd and "en" in wotd


def test_word_of_the_day_is_stable_per_day():
    _reset()
    import datetime
    d1 = datetime.date(2026, 10, 14)
    a = D.word_of_the_day(d1)
    b = D.word_of_the_day(d1)
    assert a == b                               # same day -> same word
    c = D.word_of_the_day(datetime.date(2026, 10, 15))
    # different ordinal -> may differ; at minimum the picker is deterministic
    assert isinstance(c, dict) and "en" in c


def test_shape_coerces_string_syn_ant():
    _reset()
    n = D.load_dataset(
        [{"bn": "আগুন", "en": "fire", "syn": "flame; blaze", "ant": "water"}],
        "open-test")
    assert n == 1
    e = D.lookup("fire", direction="en2bn")["results"][0]
    assert "flame" in e["syn"] and "blaze" in e["syn"]
    assert e["ant"] == ["water"]
    _reset()


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
