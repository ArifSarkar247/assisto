"""
subscriptions_tests_snippets.py — plain-assert tests for the subscriptions engine.

Pure stdlib. `python subscriptions_tests_snippets.py` or import and call run_all().
All money is integer poisha; totals and next-due rolls are hand-verified below.
"""

from datetime import date

import subscriptions as S  # noqa: E402  (flat import for standalone run)


# ---------------------------------------------------------------- money parse

def test_to_poisha_from_taka_string():
    assert S.to_poisha({"amount": "650.00"}) == 65000
    assert S.to_poisha({"amount": "650"}) == 65000
    assert S.to_poisha({"amount": "99.99"}) == 9999  # no float drift
    assert S.to_poisha({"amount": "0.10"}) == 10


def test_to_poisha_prefers_integer_field():
    assert S.to_poisha({"amount": "650.00", "amount_poisha": 12345}) == 12345
    assert S.to_poisha({"amount": None}) == 0
    assert S.to_poisha({}) == 0


def test_to_poisha_no_float_drift_summed():
    # 0.1 + 0.2 in float is 0.30000000000000004; poisha is exact.
    subs = [{"amount": "0.10"}, {"amount": "0.20"}]
    assert sum(S.to_poisha(s) for s in subs) == 30


# ---------------------------------------------------------------- next-due roll

def test_advance_monthly_keeps_day():
    assert S.advance_due("2026-01-15", "monthly") == date(2026, 2, 15)
    assert S.advance_due("2026-12-15", "monthly") == date(2027, 1, 15)  # year wrap


def test_advance_monthly_clamps_short_month():
    # 31 Jan + 1 month → 28 Feb (2026 is not a leap year).
    assert S.advance_due("2026-01-31", "monthly") == date(2026, 2, 28)


def test_advance_quarterly_yearly_weekly_custom():
    assert S.advance_due("2026-01-10", "quarterly") == date(2026, 4, 10)
    assert S.advance_due("2026-01-10", "yearly") == date(2027, 1, 10)
    assert S.advance_due("2026-01-10", "weekly") == date(2026, 1, 17)
    assert S.advance_due("2026-01-10", "custom", interval_days=45) == date(2026, 2, 24)


def test_mark_paid_catches_up_missed_cycles():
    # Due 15 Nov, today 20 Feb → next future monthly is 15 Mar (caught up 4 steps).
    sub = {"next_due": "2025-11-15", "cycle": "monthly"}
    rolled = S.mark_paid(sub, today=date(2026, 2, 20))
    assert rolled["next_due"] == "2026-03-15", rolled
    # original untouched
    assert sub["next_due"] == "2025-11-15"


def test_mark_paid_cancelled_is_noop():
    sub = {"next_due": "2025-01-01", "cycle": "monthly", "status": "cancelled"}
    assert S.mark_paid(sub, today=date(2026, 2, 20))["next_due"] == "2025-01-01"


# ---------------------------------------------------------------- normalised spend

def test_monthly_normalisation():
    assert S.monthly_poisha({"amount": "650", "cycle": "monthly"}) == 65000
    # yearly 12000 taka → 1000 taka/month = 100000 poisha
    assert S.monthly_poisha({"amount": "12000", "cycle": "yearly"}) == 100000
    # quarterly 300 taka → 100 taka/month
    assert S.monthly_poisha({"amount": "300", "cycle": "quarterly"}) == 10000


def test_yearly_normalisation():
    assert S.yearly_poisha({"amount": "650", "cycle": "monthly"}) == 65000 * 12
    assert S.yearly_poisha({"amount": "12000", "cycle": "yearly"}) == 1200000
    # weekly 100 taka → 365/7 * 100 taka = 5214.2857.. → 521428.57 poisha → 521429
    assert S.yearly_poisha({"amount": "100", "cycle": "weekly"}) == 521429


def test_paused_cancelled_excluded_from_spend():
    subs = [
        {"amount": "650", "cycle": "monthly"},
        {"amount": "500", "cycle": "monthly", "status": "paused"},
        {"amount": "999", "cycle": "monthly", "status": "cancelled"},
    ]
    t = S.totals(subs)
    assert t["monthly_poisha"] == 65000, t
    assert t["active_count"] == 1 and t["total_count"] == 3, t


def test_totals_hand_verified():
    # Netflix 650/mo, Spotify 170/mo, ISP 1200/mo, gym 6000/yr(=500/mo)
    subs = [
        {"amount": "650", "cycle": "monthly"},
        {"amount": "170", "cycle": "monthly"},
        {"amount": "1200", "cycle": "monthly"},
        {"amount": "6000", "cycle": "yearly"},
    ]
    t = S.totals(subs)
    # monthly: 65000 + 17000 + 120000 + 50000 = 252000 poisha = 2520 taka
    assert t["monthly_poisha"] == 252000, t
    # yearly: 780000 + 204000 + 1440000 + 600000 = 3024000 poisha = 30240 taka
    assert t["yearly_poisha"] == 3024000, t


# ---------------------------------------------------------------- smart views

def test_upcoming_window_and_order():
    today = date(2026, 2, 1)
    subs = [
        {"id": 1, "name": "A", "amount": "100", "cycle": "monthly", "next_due": "2026-02-05"},
        {"id": 2, "name": "B", "amount": "100", "cycle": "monthly", "next_due": "2026-02-20"},
        {"id": 3, "name": "C", "amount": "100", "cycle": "monthly", "next_due": "2026-01-30"},  # overdue
    ]
    up7 = S.upcoming(subs, 7, today)
    assert [x["id"] for x in up7] == [3, 1], up7  # overdue first (sorted by date), B out of window
    assert up7[0]["days_until"] == -2
    up30 = S.upcoming(subs, 30, today)
    assert [x["id"] for x in up30] == [3, 1, 2], up30


def test_trials_ending_before_charge():
    today = date(2026, 2, 1)
    subs = [
        {"id": 1, "name": "T", "amount": "650", "trial_end": "2026-02-04", "auto_renew": True},
        {"id": 2, "name": "U", "amount": "650", "trial_end": "2026-03-20"},  # out of 7d window
        {"id": 3, "name": "V", "amount": "650", "trial_end": "2026-02-02", "status": "cancelled"},
    ]
    te = S.trials_ending(subs, 7, today)
    assert [x["id"] for x in te] == [1], te
    assert te[0]["days_until"] == 3


def test_by_category_and_payment():
    subs = [
        {"amount": "650", "cycle": "monthly", "category": "streaming", "payment_method": "bkash"},
        {"amount": "170", "cycle": "monthly", "category": "streaming", "payment_method": "card"},
        {"amount": "1200", "cycle": "monthly", "category": "internet", "payment_method": "bkash"},
    ]
    cats = S.by_category(subs)
    assert cats[0]["category"] == "internet" and cats[0]["monthly_poisha"] == 120000, cats
    assert cats[1]["category"] == "streaming" and cats[1]["monthly_poisha"] == 82000, cats
    pms = S.by_payment_method(subs)
    assert pms[0]["payment_method"] == "bkash" and pms[0]["monthly_poisha"] == 185000, pms


def test_most_expensive():
    subs = [
        {"id": 1, "name": "A", "amount": "100", "cycle": "monthly"},
        {"id": 2, "name": "B", "amount": "1200", "cycle": "yearly"},  # 100/mo
        {"id": 3, "name": "C", "amount": "500", "cycle": "monthly"},
    ]
    top = S.most_expensive(subs, 2)
    assert [x["id"] for x in top] == [3, 1], top  # 50000, 10000 vs B 10000 -> stable


def test_cancel_candidates():
    today = date(2026, 3, 1)
    subs = [
        {"id": 1, "name": "Stale", "amount": "650", "cycle": "monthly", "last_used": "2025-12-01"},
        {"id": 2, "name": "Fresh", "amount": "650", "cycle": "monthly", "last_used": "2026-02-25"},
        {"id": 3, "name": "NoSignal", "amount": "650", "cycle": "monthly"},
    ]
    cc = S.cancel_candidates(subs, today)
    assert [x["id"] for x in cc] == [1], cc
    assert cc[0]["idle_days"] == 90


# ---------------------------------------------------------------- insights

def test_income_burden():
    subs = [{"amount": "2000", "cycle": "monthly"}]  # 200000 poisha/mo
    b = S.income_burden(subs, 1000000)  # income 10000 taka
    assert b["burden_pct"] == 20.0, b
    assert S.income_burden(subs, 0) is None
    assert S.income_burden(subs, None) is None


def test_savings_if_cancelled():
    subs = [
        {"id": 1, "amount": "650", "cycle": "monthly"},
        {"id": 2, "amount": "170", "cycle": "monthly"},
    ]
    # cancel #1 → yearly 65000*12 = 780000 poisha
    assert S.savings_if_cancelled(subs, [1]) == 780000


def test_summarize_shape():
    subs = [{"id": 1, "name": "A", "amount": "650", "cycle": "monthly", "next_due": "2026-02-05"}]
    out = S.summarize(subs, today=date(2026, 2, 1), monthly_income_poisha=1000000)
    for k in ("totals", "upcoming_7", "upcoming_30", "trials_ending",
              "by_category", "by_payment_method", "most_expensive",
              "cancel_candidates", "income_burden"):
        assert k in out, k


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"subscriptions: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
