"""
security_checkup_tests_snippets.py — plain-assert tests for the DIGITAL SECURITY
CHECK-UP engine (#198, §20). Pure stdlib. `python security_checkup_tests_snippets.py`
or import and call run_all(). The scorer is deterministic, so every assertion
below is hand-verified against fixed inputs and the fixed ITEM weights.
"""

try:  # Django harness: core.logic.security_checkup_tests_snippets
    from core.logic import security_checkup as S
except ImportError:  # standalone
    import security_checkup as S  # noqa: E402


# --------------------------------------------------------------- catalogue

def test_item_catalogue_is_consistent():
    assert len(S.ITEMS) == len(S.ITEM_IDS)
    # no duplicate ids
    assert len(set(S.ITEM_IDS)) == len(S.ITEM_IDS)
    # max is the exact sum of weights
    assert S.MAX_SCORE == sum(S.WEIGHTS[i] for i in S.ITEM_IDS)
    assert S.MAX_SCORE == 26
    # every item maps to a weight and a category
    for iid in S.ITEM_IDS:
        assert S.WEIGHTS[iid] >= 1
        assert iid in S.CATEGORY


# --------------------------------------------------------------- honesty

def test_self_reported_is_constant_true():
    assert S.self_reported() is True
    assert S.score({})["self_reported"] is True


def test_missing_answer_counts_as_not_done():
    r = S.score({})
    assert r["done"] == []
    assert r["earned"] == 0
    assert r["percent"] == 0
    assert r["done_count"] == 0
    assert r["total_count"] == len(S.ITEM_IDS)
    # every item is a weak area when nothing is done
    assert set(r["weak"]) == set(S.ITEM_IDS)


def test_only_strict_true_counts():
    # truthy-but-not-True values must NOT flatter the score
    for bad in (1, "yes", "true", [1], {"x": 1}):
        assert S.is_done({"screen_lock": bad}, "screen_lock") is False
    assert S.is_done({"screen_lock": True}, "screen_lock") is True
    assert S.is_done({"screen_lock": False}, "screen_lock") is False


# --------------------------------------------------------------- determinism

def test_score_is_deterministic():
    ans = {"screen_lock": True, "two_factor": True, "wallet_pin": False}
    assert S.score(ans) == S.score(ans)


def test_unknown_keys_are_ignored():
    a = S.score({"screen_lock": True})
    b = S.score({"screen_lock": True, "not_a_real_item": True, "xyz": False})
    assert a == b


# --------------------------------------------------------------- scoring math

def test_all_done_is_full_strong():
    ans = {iid: True for iid in S.ITEM_IDS}
    r = S.score(ans)
    assert r["earned"] == S.MAX_SCORE
    assert r["percent"] == 100
    assert r["grade"] == "strong"
    assert r["weak"] == []
    assert r["done_count"] == len(S.ITEM_IDS)


def test_partial_score_matches_weights():
    ans = {"screen_lock": True, "wallet_pin": True}   # 5 + 5 = 10
    r = S.score(ans)
    assert r["earned"] == 10
    assert r["percent"] == round(10 * 100 / S.MAX_SCORE)  # 38
    assert "screen_lock" in r["done"] and "wallet_pin" in r["done"]


def test_percent_is_integer_and_bounded():
    for ans in ({}, {"screen_lock": True}, {iid: True for iid in S.ITEM_IDS}):
        p = S.score(ans)["percent"]
        assert isinstance(p, int)
        assert 0 <= p <= 100


# --------------------------------------------------------------- grades

def test_grade_thresholds():
    assert S.grade_for(100) == "strong"
    assert S.grade_for(85) == "strong"
    assert S.grade_for(84) == "good"
    assert S.grade_for(65) == "good"
    assert S.grade_for(64) == "fair"
    assert S.grade_for(40) == "fair"
    assert S.grade_for(39) == "at_risk"
    assert S.grade_for(0) == "at_risk"


def test_grade_clamps_out_of_range():
    assert S.grade_for(200) == "strong"
    assert S.grade_for(-50) == "at_risk"


# --------------------------------------------------------------- weak areas

def test_weak_is_worst_weight_first():
    # done only the lightest item; the heaviest (weight 5) items lead the weak list
    r = S.score({"permissions_review": True})
    assert "permissions_review" not in r["weak"]
    # first weak item has the max weight among not-done
    first = r["weak"][0]
    assert S.WEIGHTS[first] == max(S.WEIGHTS[i] for i in r["weak"])


def test_weak_order_is_stable_on_ties():
    # two weight-5 items both not-done keep ITEMS order relative to each other
    r = S.score({})
    five_weight = [i for i in r["weak"] if S.WEIGHTS[i] == 5]
    assert five_weight == [i for i in S.ITEM_IDS if S.WEIGHTS[i] == 5]


def test_top_weak_returns_highest_impact():
    tw = S.top_weak({}, 3)
    assert len(tw) == 3
    # all are weight 5 (the three heaviest practices)
    assert all(S.WEIGHTS[i] == 5 for i in tw)
    assert S.top_weak({}, 0) == []


# --------------------------------------------------------------- sanitize

def test_sanitize_keys_only_known_items_as_strict_bool():
    out = S.sanitize({"screen_lock": True, "junk": True, "two_factor": "yes"})
    assert set(out.keys()) == set(S.ITEM_IDS)
    assert out["screen_lock"] is True
    assert out["two_factor"] is False   # "yes" is not strict True
    assert all(isinstance(v, bool) for v in out.values())


def test_sanitize_roundtrips_through_score():
    ans = {iid: True for iid in S.ITEM_IDS}
    assert S.score(S.sanitize(ans)) == S.score(ans)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"security_checkup: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
