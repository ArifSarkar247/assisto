"""
suggestions_tests_snippets.py — plain-assert tests for core.logic.suggestions.

NOT a Django TestCase. Smoke locally:
    (cd backend && python3 -c "import core.logic.suggestions_tests_snippets as t; t.run_all()")

Covers the brief's required cases: new-user onboarding, business-user business
prompts, morning vs evening, missed-medicine surfaces, don't-show suppression,
no-repeat-two-days, strict-language.
"""
from datetime import datetime

from core.logic import suggestions as S

MORNING = datetime(2026, 10, 14, 8, 0)    # Wed 8am
EVENING = datetime(2026, 10, 14, 19, 0)   # Wed 7pm
FRIDAY = datetime(2026, 10, 16, 10, 0)    # Fri 10am


def _keys(prompts):
    return [p["key"] for p in prompts]


def test_returns_exactly_four():
    out = S.suggest("bn", MORNING, context={})
    assert len(out) == 4, out


def test_new_user_gets_onboarding():
    out = S.suggest("bn", MORNING, context={"new_user": True})
    ks = _keys(out)
    assert any(k.startswith("onboard_") for k in ks), ks
    # onboarding should dominate the deck for a brand-new user
    assert sum(1 for k in ks if k.startswith("onboard_")) >= 3, ks


def test_business_user_gets_business_prompts():
    out = S.suggest("en", MORNING, context={"active_modules": ["business"]})
    ks = _keys(out)
    assert "biz_orders" in ks or "biz_dues" in ks, ks


def test_crm_user_gets_crm_prompt():
    out = S.suggest("en", MORNING, context={"active_modules": ["crm"]})
    assert "crm_leads" in _keys(out)


def test_morning_vs_evening_differ():
    m = _keys(S.suggest("en", MORNING, context={}))
    e = _keys(S.suggest("en", EVENING, context={}))
    assert "morning_briefing" in m
    assert "morning_briefing" not in e
    assert "evening_wrap" in e


def test_missed_medicine_surfaces_on_top():
    out = S.suggest("bn", EVENING, context={"missed_medicine": True})
    ks = _keys(out)
    assert "medicine_due" in ks, ks
    # safety-critical: it should be the highest-ranked card
    assert ks[0] == "medicine_due", ks


def test_due_bill_surfaces():
    out = S.suggest("en", EVENING, context={"due_bills": True})
    assert "pay_bill" in _keys(out)


def test_dont_show_suppression_removes_key():
    hist = {"suppressed": ["medicine_due"]}
    out = S.suggest("bn", EVENING, context={"missed_medicine": True}, history=hist)
    assert "medicine_due" not in _keys(out)


def test_no_repeat_two_days():
    # Served a non-sticky prompt yesterday → it should be pushed out of the deck
    # when there are other candidates.
    ctx = {"recent_spending": True, "unfinished_tasks": True,
           "upcoming_birthday": True, "active_modules": ["business"]}
    hist = {"served_yesterday": ["spending_review"]}
    today = _keys(S.suggest("en", MORNING, context=ctx, history=hist))
    assert "spending_review" not in today, today


def test_no_repeat_sticky_medicine_survives_if_still_relevant():
    # Medicine was shown yesterday AND is still missed → it must stay (safety).
    hist = {"served_yesterday": ["medicine_due"]}
    out = _keys(S.suggest("bn", EVENING, context={"missed_medicine": True}, history=hist))
    assert "medicine_due" in out, out


def test_learn_from_use_raises_tapped_drops_ignored():
    ctx = {"recent_spending": True, "unfinished_tasks": True}
    # Without history, both spending_review and finish_tasks are candidates.
    base = _keys(S.suggest("en", MORNING, context=ctx))
    assert "finish_tasks" in base
    # Heavily ignore finish_tasks, tap spending_review → ranking shifts.
    hist = {"taps": {"spending_review": 5}, "ignores": {"finish_tasks": 5}}
    learned = S.suggest("en", MORNING, context=ctx, history=hist)
    sr = next(i for i, p in enumerate(learned) if p["key"] == "spending_review")
    ft_keys = _keys(learned)
    # spending_review should now out-rank finish_tasks (if finish_tasks survives)
    if "finish_tasks" in ft_keys:
        ft = ft_keys.index("finish_tasks")
        assert sr < ft, learned


def test_strict_language_bn_no_latin_mix():
    out = S.suggest("bn", MORNING, context={"missed_medicine": True})
    for p in out:
        assert isinstance(p["text"], str)
        # the bn catalogue text contains Bangla; ensure we didn't hand back the
        # en string by checking it matches the bn entry exactly.
        assert p["text"] == S._PROMPTS[p["key"]][3]["bn"]


def test_strict_language_en():
    out = S.suggest("en", MORNING, context={})
    for p in out:
        assert p["text"] == S._PROMPTS[p["key"]][3]["en"]


def test_seasonal_ramadan_and_eid():
    r = _keys(S.suggest("bn", MORNING, context={"season": "ramadan"}))
    assert "ramadan" in r
    e = _keys(S.suggest("bn", MORNING, context={"season": "eid"}))
    assert "eid" in e


def test_friday_prompt_on_friday_only():
    fri = _keys(S.suggest("en", FRIDAY, context={}))
    assert "friday" in fri
    wed = _keys(S.suggest("en", MORNING, context={}))
    assert "friday" not in wed


def test_refresh_rotates_the_deck():
    ctx = {"recent_spending": True, "unfinished_tasks": True,
           "upcoming_birthday": True, "active_modules": ["business"]}
    first = _keys(S.suggest("en", MORNING, context=ctx))
    hist = {"current": first}
    refreshed = _keys(S.suggest("en", MORNING, context=ctx, history=hist, refresh=True))
    # none of the originally-shown cards should reappear after a refresh
    assert not (set(first) & set(refreshed)) or len(refreshed) < 4, (first, refreshed)


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    tests = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
             if n.startswith("test_")]
    for fn in tests:
        fn()
    print(f"suggestions: {len(tests)} tests passed")


if __name__ == "__main__":
    run_all()
