"""
govt_guide_tests_snippets.py — plain-assert tests for core.logic.govt_guide
(ADVANCED service-guide layer). NOT a Django TestCase.

Smoke locally:
    cd backend && python3 -c "import core.logic.govt_guide_tests_snippets as t; t.run_all()"

Covers: localisation (no Bangla leaking into en), every service is complete
(docs/fee/office/time/mistakes/url-or-portal), search (filter + query +
category), the "what do I need for X" flow, and the honesty invariant
(no invented fees — every fee is verify-on-portal with a source).
"""
import re

from core.logic import govt_guide as G

_BANGLA = re.compile(r"[ঀ-৿]")


def test_services_present_and_complete():
    assert len(G.SERVICES) >= 11, len(G.SERVICES)
    required_keys = {"nid", "epassport", "birth", "driving", "tin", "porcha",
                     "trade_license", "electricity", "police_clearance",
                     "brta_vehicle"}
    have = {s["key"] for s in G.SERVICES}
    assert required_keys <= have, required_keys - have
    for s in G.SERVICES:
        for f in ("steps", "docs", "mistakes"):
            assert s[f + "_bn"] and s[f + "_en"], (s["key"], f)
            assert len(s[f + "_bn"]) == len(s[f + "_en"]), (s["key"], f)
        for f in ("fee", "office", "time", "name"):
            assert s[f + "_bn"] and s[f + "_en"], (s["key"], f)
        # every service maps to a known category
        assert s["category"] in {c["key"] for c in G.CATEGORIES}, s["category"]


def test_localized_no_bangla_in_english():
    en = G.localized("en")
    assert en["version"] == "2.1"
    assert en["categories"] and en["services"]
    for s in en["services"]:
        assert "name" in s and "steps" in s and "docs" in s
        blob = " ".join([str(s.get("name", "")), str(s.get("fee", "")),
                         str(s.get("office", "")), str(s.get("time", "")),
                         str(s.get("steps", "")), str(s.get("docs", "")),
                         str(s.get("mistakes", "")), str(s.get("disclaimer", ""))])
        assert not _BANGLA.search(blob), ("bangla in en:", s["key"])
    # bn localisation keeps Bangla + still flattens keys
    bn = G.localized("bn")
    assert all("name_bn" not in s for s in bn["services"])


def test_search_filter_query_category():
    # empty -> everything
    assert len(G.search("", "en")) == len(G.SERVICES)
    # category filter
    driving = G.search("", "en", category="driving")
    assert driving and all(True for _ in driving)
    assert {s["name"] for s in driving}  # localised names present
    assert len(driving) == len([s for s in G.SERVICES if s["category"] == "driving"])
    # query match (english)
    passport = G.search("passport", "en")
    assert any(s["key"] == "epassport" for s in passport)
    # query match inside docs (english): "khatian" for land record
    porcha = G.search("khatian", "en")
    assert any(s["key"] == "porcha" for s in porcha)
    # no match
    assert G.search("zzznope", "en") == []


def test_what_do_i_need():
    need = G.what_do_i_need("nid", "en")
    assert need is not None
    assert need["name"] and need["docs"]
    assert need["fee"] and need["fee_verify"] is True
    assert need["office"] and need["url"] is not None
    assert need["source"].startswith("Source:")
    assert G.what_do_i_need("not_a_service") is None


def test_no_invented_fees_honesty_invariant():
    assert G.has_no_invented_fees() is True
    for s in G.SERVICES:
        assert s["fee_verify"] is True, s["key"]
        assert s["time_verify"] is True, s["key"]
        # fee text itself must carry a verify cue (bn or en)
        fee_en = s["fee_en"].lower()
        assert "verify" in fee_en, ("fee not marked verify:", s["key"], fee_en)
        # a source portal is always present
        assert s["portal"], s["key"]
        assert s["source_en"].startswith("Source:"), s["key"]


def run_all():
    tests = [
        test_services_present_and_complete,
        test_localized_no_bangla_in_english,
        test_search_filter_query_category,
        test_what_do_i_need,
        test_no_invented_fees_honesty_invariant,
    ]
    for t in tests:
        t()
        print("PASS", t.__name__)
    print("OK", len(tests), "tests")


if __name__ == "__main__":
    run_all()
