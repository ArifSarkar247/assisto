"""
watch_feed_tests_snippets.py — plain-assert tests for core.logic.watch_feed.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.watch_feed_tests_snippets as t; t.run_all()"
"""
from core.logic import watch_feed as W


def test_needs_you_kind_floats_regardless_of_date():
    assert W.classify_group("family_alert", 5, W.SEV_MED) == W.GROUP_NEEDS_YOU
    assert W.classify_group("checkin_overdue", None, W.SEV_HIGH) == W.GROUP_NEEDS_YOU


def test_high_overdue_promotes_to_needs_you():
    assert W.classify_group("refill", 0, W.SEV_HIGH) == W.GROUP_NEEDS_YOU
    assert W.classify_group("refill", -2, W.SEV_HIGH) == W.GROUP_NEEDS_YOU


def test_today_vs_upcoming():
    assert W.classify_group("reminder", 0, W.SEV_MED) == W.GROUP_TODAY
    assert W.classify_group("reminder", -1, W.SEV_MED) == W.GROUP_TODAY
    assert W.classify_group("subscription", 3, W.SEV_MED) == W.GROUP_UPCOMING


def test_undated_non_needs_you_goes_today():
    assert W.classify_group("reminder", None, W.SEV_MED) == W.GROUP_TODAY


def test_window_filters_far_future_but_keeps_overdue():
    assert W.in_window(3) is True
    assert W.in_window(7) is True
    assert W.in_window(8) is False
    assert W.in_window(-1) is True
    assert W.in_window(None) is True


def test_priority_needs_you_before_today_before_upcoming():
    p_needs = W.priority(W.GROUP_NEEDS_YOU, W.SEV_LOW, 5)
    p_today = W.priority(W.GROUP_TODAY, W.SEV_HIGH, 0)
    p_up = W.priority(W.GROUP_UPCOMING, W.SEV_HIGH, 1)
    assert p_needs < p_today < p_up, (p_needs, p_today, p_up)


def test_priority_tiebreak_sooner_first():
    a = W.priority(W.GROUP_UPCOMING, W.SEV_MED, 1)
    b = W.priority(W.GROUP_UPCOMING, W.SEV_MED, 5)
    assert a < b, (a, b)


def test_normalize_drops_far_future_and_fills_defaults():
    assert W.normalize({"kind": "subscription", "days_until": 30}) is None
    it = W.normalize({"kind": "reminder", "days_until": 0})
    assert it["group"] == W.GROUP_TODAY
    assert it["severity"] == W.SEV_MED
    assert "priority" in it


def test_normalize_coerces_bad_values():
    it = W.normalize({"kind": "x", "severity": "bogus", "days_until": "nope"})
    assert it["severity"] == W.SEV_MED
    assert it["days_until"] is None


def test_build_feed_groups_and_sorts():
    signals = [
        {"kind": "subscription", "days_until": 5, "severity": "low"},
        {"kind": "family_alert", "days_until": None, "severity": "high"},
        {"kind": "reminder", "days_until": 0, "severity": "med"},
        {"kind": "loan_due", "days_until": -3, "severity": "med"},
        {"kind": "subscription", "days_until": 40, "severity": "low"},  # dropped
    ]
    feed = W.build_feed(signals)
    assert len(feed[W.GROUP_NEEDS_YOU]) == 1
    assert len(feed[W.GROUP_TODAY]) == 2      # reminder today + overdue loan
    assert len(feed[W.GROUP_UPCOMING]) == 1
    # upcoming far-future was dropped
    assert feed[W.GROUP_UPCOMING][0]["days_until"] == 5


def test_ordered_flattens_in_group_order():
    signals = [
        {"kind": "subscription", "days_until": 2},
        {"kind": "family_alert", "days_until": None, "severity": "high"},
        {"kind": "reminder", "days_until": 0},
    ]
    flat = W.ordered(signals)
    assert [it["group"] for it in flat] == [
        W.GROUP_NEEDS_YOU, W.GROUP_TODAY, W.GROUP_UPCOMING]


def test_counts():
    signals = [
        {"kind": "reminder", "days_until": 0},
        {"kind": "reminder", "days_until": 0},
        {"kind": "subscription", "days_until": 3},
    ]
    c = W.counts(signals)
    assert c[W.GROUP_TODAY] == 2
    assert c[W.GROUP_UPCOMING] == 1
    assert c[W.GROUP_NEEDS_YOU] == 0


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    tests = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
             if n.startswith("test_")]
    for fn in tests:
        fn()
    print(f"watch_feed: {len(tests)} tests passed")


if __name__ == "__main__":
    run_all()
