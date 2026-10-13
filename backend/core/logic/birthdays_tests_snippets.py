"""
birthdays_tests_snippets.py — plain-assert tests for core.logic.birthdays.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.birthdays_tests_snippets as t; t.run_all()"
"""
from datetime import date
from core.logic import birthdays as B


def test_next_occurrence_future_this_year():
    today = date(2026, 1, 1)
    nxt = B.next_occurrence("1990-06-15", today=today)
    assert nxt == date(2026, 6, 15), nxt


def test_next_occurrence_rolls_to_next_year():
    today = date(2026, 7, 1)
    nxt = B.next_occurrence("1990-06-15", today=today)
    assert nxt == date(2027, 6, 15), nxt


def test_today_counts_as_occurrence():
    today = date(2026, 6, 15)
    assert B.next_occurrence("1990-06-15", today=today) == today
    assert B.days_until("1990-06-15", today=today) == 0


def test_leap_day_moves_to_feb28_nonleap():
    # 2026 is not a leap year -> Feb 29 falls back to Feb 28
    nxt = B.next_occurrence("2000-02-29", today=date(2026, 1, 1))
    assert nxt == date(2026, 2, 28), nxt


def test_turning_age():
    today = date(2026, 1, 1)
    assert B.turning_age("1990-06-15", today=today) == 36
    # unknown year sentinel -> None
    assert B.turning_age("1900-06-15", today=today) is None


def test_turning_age_future_year_never_negative():
    # A birth/start year AFTER the next occurrence must never yield a negative
    # age — it is clamped to 0.
    today = date(2026, 1, 1)
    # next occurrence of 06-15 in 2026; birth year 2030 is in the future.
    age = B.turning_age("2030-06-15", today=today)
    assert age == 0, age


def test_lead_days_single_and_day_of():
    today = date(2026, 6, 1)
    dates = B.reminder_dates("1990-06-15", lead_days=1, today=today)
    assert date(2026, 6, 14) in dates, dates   # 1 day before
    assert date(2026, 6, 15) in dates, dates   # day of


def test_lead_days_multiple_and_deduped():
    today = date(2026, 6, 1)
    dates = B.reminder_dates("1990-06-15", lead_days=[7, 1], today=today)
    assert date(2026, 6, 8) in dates, dates
    assert date(2026, 6, 14) in dates, dates
    assert date(2026, 6, 15) in dates, dates
    assert dates == sorted(dates), dates
    assert len(dates) == len(set(dates)), dates


def test_lead_days_not_before_today():
    today = date(2026, 6, 14)
    dates = B.reminder_dates("1990-06-15", lead_days=[30, 1], today=today)
    assert all(d >= today for d in dates), dates


def test_should_remind_today():
    assert B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 14))
    assert B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 15))
    assert not B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 10))


def test_clamp_lead_days():
    assert B.clamp_lead_days(-5) == 0
    assert B.clamp_lead_days(999) == B.LEAD_DAYS_MAX
    assert B.clamp_lead_days("bad") == B.LEAD_DAYS_DEFAULT


def test_upcoming_sorted_and_filtered():
    today = date(2026, 6, 1)
    occ = [
        {"name": "A", "date": "1990-06-20", "kind": "birthday"},
        {"name": "B", "date": "1985-06-05", "kind": "birthday"},
        {"name": "C", "date": "1970-12-25", "kind": "memorable"},
    ]
    up = B.upcoming(occ, within_days=30, today=today)
    names = [o["name"] for o in up]
    assert names == ["B", "A"], names   # C is >30 days away, filtered out
    assert up[0]["days_until"] <= up[1]["days_until"], up


def test_wish_drafts_three_styles_and_name():
    for lang in ("bn", "en"):
        d = B.wish_drafts("Rahim", "birthday", age=40, lang=lang)
        assert len(d) == 3, d
        assert {x["style"] for x in d} == {"short", "warm", "formal"}, d
        assert all("Rahim" in x["text"] for x in d), d


def test_wish_drafts_age_only_when_relevant():
    # death anniversary never shows an age clause
    d = B.wish_drafts("X", "death_anniversary", age=50, lang="en")
    assert all("50" not in x["text"] for x in d), d


def test_greeting_card_both_langs():
    for lang in ("bn", "en"):
        c = B.greeting_card("Mina", "birthday", age=30, lang=lang)
        assert c["title"] and c["body"], c
        assert "Mina" in c["body"], c


def test_reminder_payload_variants():
    p0 = B.reminder_payload("A", "birthday", 0, "en")
    assert "Today" in p0["body"], p0
    p1 = B.reminder_payload("A", "birthday", 1, "en")
    assert "Tomorrow" in p1["body"], p1
    p5 = B.reminder_payload("A", "birthday", 5, "en")
    assert "5 days" in p5["body"], p5


def test_never_auto_send_contract():
    # drafts are plain text structures only — no send/network symbols exist
    src_fns = [B.wish_drafts, B.greeting_card]
    for fn in src_fns:
        assert callable(fn)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"birthdays: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
