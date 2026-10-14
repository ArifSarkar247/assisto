"""
proactive_ai_tests_snippets.py — plain-assert tests for core.logic.proactive_ai.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.proactive_ai_tests_snippets as t; t.run_all()"
"""
from core.logic import proactive_ai as P


def test_suggestion_id_stable_and_uses_ref():
    a = P.suggestion_id({"kind": "bill_due", "ref": "dhaka-wasa"})
    b = P.suggestion_id({"kind": "bill_due", "ref": "dhaka-wasa"})
    assert a == b == "bill_due:dhaka-wasa"
    # falls back to title when no ref
    c = P.suggestion_id({"kind": "birthday", "title": "Rahim"})
    assert c == "birthday:Rahim"


def test_epoch_from_due_or_week():
    assert P.epoch({"due": "2026-10-20"}) == "2026-10-20"
    assert P.epoch({"week": "2026-W41"}) == "2026-W41"
    assert P.epoch({"kind": "x"}) == ""


def test_reason_key_lookup_and_fallback():
    assert P.reason_key("bill_due") == "reason_bill_due"
    assert P.reason_key("unknown_kind") == P.REASON_FALLBACK


def test_to_suggestion_maps_group_to_urgency():
    now = P.to_suggestion({"kind": "reminder", "days_until": 0})
    assert now["urgency"] == P.URGENCY_NOW
    soon = P.to_suggestion({"kind": "bill_due", "days_until": 2,
                            "severity": "med"})
    assert soon["urgency"] == P.URGENCY_SOON
    needs = P.to_suggestion({"kind": "family_alert", "days_until": None,
                             "severity": "high"})
    assert needs["urgency"] == P.URGENCY_NOW


def test_low_sev_upcoming_becomes_fyi():
    fyi = P.to_suggestion({"kind": "subscription", "days_until": 5,
                           "severity": "low"})
    assert fyi["urgency"] == P.URGENCY_FYI


def test_to_suggestion_drops_far_future():
    assert P.to_suggestion({"kind": "subscription", "days_until": 40}) is None


def test_to_suggestion_traces_back_fields():
    s = P.to_suggestion({"kind": "bill_due", "ref": "wasa",
                         "title": "WASA bill", "text": "৳ 850",
                         "module": "/finance", "days_until": 1,
                         "severity": "high"})
    assert s["title"] == "WASA bill"
    assert s["module"] == "/finance"
    assert s["reason"] == "reason_bill_due"
    assert s["ai_required"] is False
    assert s["marker"] == "proactive_rule"


def test_digest_groups_counts_and_empty():
    empty = P.digest([])
    assert empty["has_any"] is False
    assert empty["counts"]["total"] == 0

    signals = [
        {"kind": "reminder", "ref": "doctor", "days_until": 0,
         "severity": "med"},                                      # today → now
        {"kind": "bill_due", "ref": "wasa", "days_until": -1,
         "severity": "high"},                                     # overdue → now
        {"kind": "subscription", "ref": "netflix", "days_until": 4,
         "severity": "med"},                                      # upcoming → soon
        {"kind": "birthday", "ref": "rahim", "days_until": 6,
         "severity": "low"},                                      # low upcoming → fyi
        {"kind": "subscription", "ref": "old", "days_until": 99},  # dropped
    ]
    d = P.digest(signals)
    assert d["has_any"] is True
    assert d["counts"]["now"] == 2      # today reminder + overdue-high bill
    assert d["counts"]["soon"] == 1     # netflix med upcoming
    assert d["counts"]["fyi"] == 1      # birthday low → fyi
    assert d["counts"]["total"] == 4


def test_dismissal_hides_same_epoch_only():
    signal = {"kind": "bill_due", "ref": "wasa", "due": "2026-10-20",
              "days_until": 2, "severity": "med"}
    dismissed = [{"id": "bill_due:wasa", "epoch": "2026-10-20"}]
    d = P.digest([signal], dismissed=dismissed)
    assert d["counts"]["total"] == 0
    assert d["dismissed_count"] == 1
    # same bill, NEW due date → re-surfaces
    signal2 = dict(signal, due="2026-11-20")
    d2 = P.digest([signal2], dismissed=dismissed)
    assert d2["counts"]["total"] == 1
    assert d2["dismissed_count"] == 0


def test_is_dismissed_direct():
    s = {"kind": "expense_gap", "ref": "weekly", "week": "2026-W41"}
    assert P.is_dismissed(s, [{"id": "expense_gap:weekly",
                               "epoch": "2026-W41"}]) is True
    assert P.is_dismissed(s, [{"id": "expense_gap:weekly",
                               "epoch": "2026-W42"}]) is False


def test_ordered_flattens_now_soon_fyi():
    signals = [
        {"kind": "subscription", "ref": "a", "days_until": 5, "severity": "low"},
        {"kind": "reminder", "ref": "b", "days_until": 0},
        {"kind": "bill_due", "ref": "c", "days_until": 3, "severity": "med"},
    ]
    flat = P.ordered(signals)
    assert [s["urgency"] for s in flat] == [
        P.URGENCY_NOW, P.URGENCY_SOON, P.URGENCY_FYI]


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    tests = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
             if n.startswith("test_")]
    for fn in tests:
        fn()
    print(f"proactive_ai: {len(tests)} tests passed")


if __name__ == "__main__":
    run_all()
