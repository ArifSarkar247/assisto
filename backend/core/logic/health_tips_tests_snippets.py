"""
health_tips_tests_snippets.py — plain-assert tests for core.logic.health_tips.

NOT a Django TestCase. The integrator folds these into core/tests.py. Each
function raises AssertionError on failure. Smoke locally:

    python3 -c "import core.logic.health_tips_tests_snippets as t; t.run_all()"
"""
from core.logic import health_tips as H


def test_every_tip_bilingual_and_sourced():
    for t in H.TIPS:
        assert t["title_bn"] and t["title_en"], t
        assert t["body_bn"] and t["body_en"], t
        assert t["source"] in (H.SOURCE_DGHS, H.SOURCE_WHO), t
        # topic must be a known topic
        assert any(top["id"] == t["topic"] for top in H.TOPICS), t


def test_library_shape_both_langs():
    for lang in ("bn", "en"):
        lib = H.library(lang)
        assert lib["topics"] and lib["tips"], lib
        assert lib["disclaimer"], lib
        assert len(lib["sources"]) == 2, lib
        # every localised tip carries a source_name
        for tip in lib["tips"]:
            assert tip["source_name"], tip
            assert tip["title"] and tip["body"], tip


def test_topic_filter():
    dengue = H.tips("bn", topic="dengue_mosquito")
    assert dengue, dengue
    assert all(t["topic"] == "dengue_mosquito" for t in dengue), dengue


def test_query_filter():
    res = H.tips("en", query="salt")
    assert any("salt" in t["title"].lower() or "salt" in t["body"].lower()
               for t in res), res
    assert H.tips("en", query="zzzznotopic") == []


def test_emergency_detects_redflags_en():
    r = H.emergency_check("I have severe chest pain and can't breathe", "en")
    assert r["emergency"] is True, r
    assert r["action"], r
    assert "999" in r["action"], r


def test_emergency_detects_redflags_bn():
    r = H.emergency_check("হঠাৎ বুকে ব্যথা ও শ্বাসকষ্ট হচ্ছে", "bn")
    assert r["emergency"] is True, r
    assert "৯৯৯" in r["action"], r


def test_emergency_not_a_diagnosis_for_normal_text():
    r = H.emergency_check("I want to eat healthy and sleep well", "en")
    assert r["emergency"] is False, r
    assert r["action"] == "", r


def test_emergency_word_boundary_no_false_positive_en():
    # 'strokeplay' must NOT match the red-flag 'stroke';
    # 'poisonous' must NOT match 'poison'.
    r = H.emergency_check("His cricket strokeplay against poisonous spin was great", "en")
    assert r["emergency"] is False, r
    assert r["matched"] == [], r


def test_emergency_bangla_bishoy_not_emergency():
    # benign 'বিষয়' (topic) must NOT trip the (now longer) 'বিষ' red-flags.
    r = H.emergency_check("আজকের আলোচনার বিষয় ছিল স্বাস্থ্য সচেতনতা।", "bn")
    assert r["emergency"] is False, r
    assert r["matched"] == [], r


def test_emergency_real_poisoning_bangla_still_fires():
    r = H.emergency_check("সে বিষ খেয়েছে, দ্রুত সাহায্য দরকার", "bn")
    assert r["emergency"] is True, r
    assert "৯৯৯" in r["action"], r


def test_emergency_real_redflags_still_fire():
    # real 'chest pain' / 'বুকে ব্যথা' must still fire as emergencies.
    r_en = H.emergency_check("sudden chest pain while running", "en")
    assert r_en["emergency"] is True, r_en
    r_bn = H.emergency_check("হঠাৎ বুকে ব্যথা শুরু হয়েছে", "bn")
    assert r_bn["emergency"] is True, r_bn


def test_disclaimer_is_non_diagnostic():
    for lang in ("bn", "en"):
        d = H.disclaimer(lang).lower()
        # must explicitly say it is NOT a diagnosis/treatment
        assert ("not a diagnosis" in d) or ("রোগ নির্ণয়" in H.disclaimer(lang)), d


def test_tip_by_id():
    t = H.tip_by_id("handwash", "en")
    assert t and t["id"] == "handwash", t
    assert H.tip_by_id("nope", "en") is None


def test_source_names_localised():
    assert "WHO" in H.source_name(H.SOURCE_WHO, "en")
    assert "DGHS" in H.source_name(H.SOURCE_DGHS, "en")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"health_tips: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
