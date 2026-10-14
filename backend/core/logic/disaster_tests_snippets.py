"""
disaster_tests_snippets.py — plain-assert tests for core.logic.disaster.

NOT a Django TestCase. Smoke locally:
    python3 -c "import core.logic.disaster_tests_snippets as t; t.run_all()"
"""
from core.logic import disaster as D


def test_cyclone_signal_severity_bands():
    assert D.cyclone_signal_severity(1) == D.SEV_ADVISORY
    assert D.cyclone_signal_severity(3) == D.SEV_ADVISORY
    assert D.cyclone_signal_severity(5) == D.SEV_WARNING
    assert D.cyclone_signal_severity(8) == D.SEV_SEVERE
    assert D.cyclone_signal_severity(10) == D.SEV_EXTREME
    assert D.cyclone_signal_severity(11) == D.SEV_EXTREME
    assert D.cyclone_signal_severity(0) == D.SEV_INFO      # out of range
    assert D.cyclone_signal_severity(99) == D.SEV_INFO
    assert D.cyclone_signal_severity("x") == D.SEV_INFO


def test_cyclone_signal_label_bilingual():
    assert D.cyclone_signal_label(10, "en") == "Great danger signal"
    assert D.cyclone_signal_label(10, "bn") != D.cyclone_signal_label(10, "en")


def test_flood_level_severity_bands():
    assert D.flood_level_severity(-0.2) == D.SEV_INFO
    assert D.flood_level_severity(0.1) == D.SEV_ADVISORY
    assert D.flood_level_severity(0.7) == D.SEV_WARNING
    assert D.flood_level_severity(1.2) == D.SEV_SEVERE
    assert D.flood_level_severity(2.0) == D.SEV_EXTREME
    assert D.flood_level_severity(None) == D.SEV_INFO


def test_heat_severity_bands():
    assert D.heat_severity(30) == D.SEV_INFO
    assert D.heat_severity(37) == D.SEV_ADVISORY
    assert D.heat_severity(39) == D.SEV_WARNING
    assert D.heat_severity(41) == D.SEV_SEVERE
    assert D.heat_severity(43) == D.SEV_EXTREME


def test_heat_index_monotonic_and_guarded():
    assert D.heat_index_c("x", 50) is None
    assert D.heat_index_c(20, 90) == 20.0        # cool -> passthrough
    hi = D.heat_index_c(38, 70)
    assert hi is not None and hi >= 38           # humidity makes it feel hotter


def test_quake_severity_bands():
    assert D._quake_severity(3.0) == D.SEV_INFO
    assert D._quake_severity(4.5) == D.SEV_ADVISORY
    assert D._quake_severity(5.5) == D.SEV_WARNING
    assert D._quake_severity(6.5) == D.SEV_SEVERE
    assert D._quake_severity(7.5) == D.SEV_EXTREME


def test_safety_steps_present_and_source_noted():
    for kind in D.KINDS:
        s = D.safety_steps(kind, "en")
        assert s and s["source"] and len(s["steps"]) >= 4, kind
    assert D.safety_steps("nope") is None


def test_preparedness_checklist_source_noted():
    c = D.preparedness_checklist("en")
    assert c["source"] and len(c["items"]) >= 5
    # hotlines appear in the checklist
    assert any("999" in i and "1090" in i for i in c["items"])


def test_emergency_contacts_are_999_and_1090():
    cs = D.emergency_contacts("en")
    nums = {c["number"] for c in cs}
    assert nums == {"999", "1090"}, nums
    primary = [c for c in cs if c["primary"]]
    assert len(primary) == 1 and primary[0]["number"] == "999"


def test_active_warnings_empty_without_feed():
    # The core honesty guarantee: NO feed -> NO warnings (never fabricated).
    assert D.active_warnings(None) == []
    assert D.active_warnings([]) == []


def test_active_warnings_classify_and_sort():
    feed = [
        {"kind": "heat", "temp_c": 37, "area": "Dhaka"},          # advisory
        {"kind": "cyclone", "signal": 10, "area": "Khulna"},      # extreme
        {"kind": "flood", "above_danger_m": 0.7, "area": "Sirajganj"},  # warning
        {"kind": "garbage"},                                      # dropped
    ]
    out = D.active_warnings(feed)
    assert len(out) == 3
    assert out[0]["kind"] == "cyclone" and out[0]["severity"] == D.SEV_EXTREME
    # every live warning is flagged live / non-sample and source-noted
    for w in out:
        assert w["is_live"] is True and w["sample"] is False and w["source"]


def test_normalize_warning_respects_explicit_severity():
    w = D.normalize_warning({"kind": "flood", "severity": "severe"})
    assert w["severity"] == D.SEV_SEVERE
    assert D.normalize_warning({"no": "kind"}) is None
    assert D.normalize_warning("nope") is None


def test_feed_state_is_key_gated():
    assert D.feed_state(False, None) == "no_key"
    assert D.feed_state(False, [{"kind": "heat", "temp_c": 41}]) == "no_key"
    assert D.feed_state(True, []) == "empty"
    assert D.feed_state(True, [{"kind": "heat", "temp_c": 41}]) == "active"


def test_sample_warnings_never_look_live():
    for w in D.sample_warnings("en"):
        assert w["sample"] is True and w["is_live"] is False
        assert "sample" in (w.get("source") or "").lower()


def test_area_matches_both_directions():
    assert D.area_matches("Barishal", "Coastal districts incl Barishal")
    assert D.area_matches("Coastal", "coastal districts")
    assert not D.area_matches("", "Dhaka")
    assert not D.area_matches("Sylhet", "")
    assert not D.area_matches("Sylhet", "Khulna")


def test_affected_family_pairs_most_severe():
    members = [
        {"name": "Ma", "area": "Khulna"},
        {"name": "Baba", "area": "Dhaka"},
        {"name": "Bhai", "area": "Rangpur"},     # no warning
    ]
    warnings = D.active_warnings([
        {"kind": "cyclone", "signal": 10, "area": "Khulna"},
        {"kind": "heat", "temp_c": 41, "area": "Dhaka"},
    ])
    out = D.affected_family(members, warnings)
    names = [x["member"]["name"] for x in out]
    assert "Ma" in names and "Baba" in names and "Bhai" not in names
    # Ma's cyclone-extreme sorts above Baba's heat-severe
    assert out[0]["member"]["name"] == "Ma"


def test_affected_family_empty_without_warnings():
    members = [{"name": "Ma", "area": "Khulna"}]
    assert D.affected_family(members, []) == []
    assert D.affected_family(None, None) == []


def test_warning_share_text_honest_and_has_hotlines():
    live = D.active_warnings([{"kind": "cyclone", "signal": 8, "area": "Chattogram"}])[0]
    txt = D.warning_share_text(live, "en")
    assert "999" in txt and "1090" in txt and "Chattogram" in txt
    assert "example" not in txt.lower()           # live warning is not flagged sample
    sample = D.sample_warnings("en")[0]
    stxt = D.warning_share_text(sample, "en")
    assert "example" in stxt.lower()              # sample IS flagged honestly


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"disaster: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
