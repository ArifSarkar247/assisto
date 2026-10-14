"""
medicine_db_tests_snippets.py — plain-assert tests for core.logic.medicine_db.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.medicine_db_tests_snippets as t; t.run_all()"
"""
from core.logic import medicine_db as M


def _reset():
    M.set_source(M.SOURCE_SAMPLE)


def test_every_record_has_required_fields():
    for rec in M._RECORDS:
        for f in ("brand", "generic", "strength", "form", "manufacturer", "price"):
            assert rec.get(f) not in (None, ""), (f, rec)
        assert rec["uses_bn"] and rec["uses_en"], rec
        assert rec["how_bn"] and rec["how_en"], rec


def test_search_by_brand_prefix():
    r = M.search("napa", "en")
    assert r, r
    assert r[0]["brand"].lower().startswith("napa"), r


def test_search_by_generic():
    r = M.search("paracetamol", "en")
    brands = {x["brand"] for x in r}
    assert "Napa" in brands and "Ace" in brands, r


def test_search_empty():
    assert M.search("", "en") == []
    assert M.search("zzzznodrug", "en") == []


def test_lookup_has_alternatives_and_warning():
    _reset()
    r = M.lookup("Napa", "en")
    assert r is not None, r
    assert r["switch_warning"], r
    alts = r["alternatives"]
    assert alts, alts
    alt_brands = {a["brand"] for a in alts}
    assert "Ace" in alt_brands, alts
    # same-generic + same-strength only: 665mg Napa Extend must NOT be an alt of 500mg
    assert "Napa Extend" not in alt_brands, alts


def test_every_alternative_has_switch_warning():
    for brand in ("Napa", "Losectil", "Cef-3", "Metryl"):
        for a in M.alternatives(brand, "bn"):
            assert a["switch_warning"], (brand, a)
            assert "পরামর্শ" in a["switch_warning"], a


def test_alternatives_sorted_cheapest_first():
    alts = M.alternatives_by_generic("Metformin", "en")
    prices = [a["price"] for a in alts]
    assert prices == sorted(prices), prices


def test_sample_source_default_and_notice():
    _reset()
    assert M.is_sample() is True
    m = M.meta("en")
    assert m["is_sample"] is True, m
    assert m["sample_notice"], m
    assert "DGDA" in m["sample_notice"], m


def test_set_source_dgda_hides_sample_notice():
    # DGDA flip now REQUIRES real records to replace the sample set.
    real = [dict(r) for r in M._RECORDS]
    M.set_source(M.SOURCE_DGDA, records=real)
    m = M.meta("en")
    assert m["is_sample"] is False, m
    assert m["sample_notice"] == "", m
    _reset()


def test_set_source_dgda_without_records_refuses():
    # Guard: flipping to DGDA without real records must raise (never present
    # SAMPLE data as authoritative DGDA data).
    _reset()
    raised = False
    try:
        M.set_source(M.SOURCE_DGDA)
    except ValueError:
        raised = True
    assert raised, "set_source(DGDA) without records should raise"
    # state unchanged -> still sample
    assert M.is_sample() is True, M.current_source()
    _reset()


def test_needs_data_state():
    s = M.needs_data_state("en")
    assert s["available"] is False, s
    assert "DGDA" in s["message"], s


def test_no_fabricated_facts_bounded_set():
    # guard: the curated set stays small + explicit (never silently grows huge)
    assert 1 <= M.record_count() <= 60, M.record_count()


def test_price_display_has_taka_and_unit():
    d = M.price_display(1.2, "en")
    assert "৳" in d, d


def test_every_record_has_detail_fields():
    for rec in M._RECORDS:
        assert rec.get("side_bn") and rec.get("side_en"), rec
        assert rec.get("precaution_bn") and rec.get("precaution_en"), rec


def test_lookup_exposes_detail_fields():
    _reset()
    r = M.lookup("Napa", "en")
    assert r["side_effects"], r
    assert r["precautions"], r
    assert r["interactions"] and r["interactions"]["text"], r


def test_search_includes_detail_and_alternatives():
    # search rows now carry full detail so the app can cache for offline view
    r = M.search("losectil", "en")
    assert r and r[0].get("side_effects"), r
    assert "alternatives" in r[0], r[0]


def test_interactions_note_is_source_noted_and_honest():
    note = M.interactions_note("Paracetamol", "en")
    assert note["text"] and note["source_note"], note
    assert "not a full interaction check" in note["source_note"].lower(), note
    assert note["has_note"] is True, note
    # unknown generic -> honest fallback, still source-noted, has_note False
    unk = M.interactions_note("zzzznogeneric", "en")
    assert unk["has_note"] is False, unk
    assert unk["source_note"], unk


def test_source_label_never_claims_dgda_on_sample():
    _reset()
    lbl = M.source_label("en")
    assert "not a dgda" in lbl.lower() or "sample" in lbl.lower(), lbl
    m = M.meta("en")
    assert m["source_label"] == lbl, m


def test_report_wrong_info_validates_and_acknowledges():
    ok = M.report_wrong_info("Napa", "price looks off", "en")
    assert ok["ok"] is True, ok
    assert ok["known_record"] is True, ok
    assert ok["message"], ok
    # unknown brand still accepted (lets users flag gaps)
    gap = M.report_wrong_info("SomeNewBrand", "missing", "en")
    assert gap["ok"] is True and gap["known_record"] is False, gap
    # empty -> rejected honestly
    bad = M.report_wrong_info("", "", "en")
    assert bad["ok"] is False, bad


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    _reset()
    print(f"medicine_db: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
