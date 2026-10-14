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
        assert t["source"] in (H.SOURCE_DGHS, H.SOURCE_WHO, H.SOURCE_IEDCR), t
        # topic must be a known topic
        assert any(top["id"] == t["topic"] for top in H.TOPICS), t


def test_library_shape_both_langs():
    for lang in ("bn", "en"):
        lib = H.library(lang)
        assert lib["topics"] and lib["tips"], lib
        assert lib["disclaimer"], lib
        assert len(lib["sources"]) == 3, lib  # DGHS, WHO, IEDCR
        assert "seasonal" in lib, lib
        # every localised tip carries a source_name AND a review date
        for tip in lib["tips"]:
            assert tip["source_name"], tip
            assert tip["reviewed"], tip
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
    assert "IEDCR" in H.source_name(H.SOURCE_IEDCR, "en")
    assert "IEDCR" in H.source_name(H.SOURCE_IEDCR, "bn")


# ---- ADVANCED (v2.1) ----

def test_iedcr_source_present():
    # the IEDCR-sourced dengue-surveillance tip exists and is source-named.
    t = H.tip_by_id("dengue_surveillance", "en")
    assert t and t["source"] == H.SOURCE_IEDCR, t
    assert "IEDCR" in t["source_name"], t


def test_seasonal_by_month():
    # dengue is in season Jun–Nov; not in Feb.
    aug = [s["id"] for s in H.seasonal("en", month=8)]
    assert "dengue" in aug and "flood" in aug, aug
    feb = [s["id"] for s in H.seasonal("en", month=2)]
    assert "dengue" not in feb, feb
    assert "winter" in feb, feb
    # every seasonal highlight is source-named with a review date
    for lang in ("bn", "en"):
        for s in H.seasonal(lang, month=8):
            assert s["source_name"] and s["reviewed"] and s["title"] and s["body"], s


def test_seasonal_suppressed_during_search():
    lib = H.library("en", query="salt", month=8)
    assert lib["seasonal"] == [], lib  # search stays focused on results


def test_symptom_awareness_is_not_diagnosis():
    # awareness notes are "see a doctor if…" guidance, never a diagnosis.
    t = H.tip_by_id("dengue_warning", "en")
    assert "awareness" in t, t
    aw = t["awareness"].lower()
    assert ("see a doctor" in aw) or ("999" in aw), aw
    # a tip without an awareness note must not fabricate one.
    assert "awareness" not in H.tip_by_id("handwash", "en")


def test_reviewed_date_format():
    import re
    t = H.tip_by_id("handwash", "en")
    assert re.match(r"^\d{4}-\d{2}$", t["reviewed"]), t


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
