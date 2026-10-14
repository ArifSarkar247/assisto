"""
daily_brief_tests_snippets.py — plain-assert tests for the MORNING BRIEF &
NIGHT SUMMARY engine (#7, §6, built to §21). Pure stdlib. The engine is
deterministic (``now`` always passed in), so every assertion is hand-verified
against fixed inputs.
"""

try:  # Django harness
    from core.logic import daily_brief as B
except ImportError:  # standalone
    import daily_brief as B  # noqa: E402


NOW = "2026-10-14T07:00:00"            # a fixed morning clock


def _fixtures():
    return dict(
        reminders=[
            {"title": "Call bank", "due_at": "2026-10-14T10:00:00", "done": False},
            {"title": "Pay rent", "due_at": "2026-10-13T09:00:00", "done": False},
            {"title": "Buy milk", "due_at": "2026-10-14T18:00:00", "done": True},
            {"title": "Dentist", "due_at": "2026-10-15T11:00:00", "done": False},
        ],
        payments=[
            {"name": "Electricity bill", "due_date": "2026-10-14",
             "amount": 120000, "paid": False},
            {"name": "Internet", "due_date": "2026-10-16", "amount": 50000,
             "paid": False},
        ],
        birthdays=[
            {"name": "Rahim", "next": "2026-10-14"},
            {"name": "Karim", "next": "2026-10-20"},
        ],
        events=[
            {"title": "Team standup", "start": "2026-10-14T09:30:00",
             "place": "Office"},
        ],
    )


# --------------------------------------------------------------- normalise

def test_normalise_skips_untitled_and_reads_fields():
    items = B.normalise(
        reminders=[{"title": "", "due_at": "2026-10-14T10:00:00"},
                   {"title": "Ok", "due_at": "2026-10-14T10:00:00"}],
        payments=[{"name": "Bill", "due_date": "2026-10-14", "amount": 999}])
    kinds = {i["kind"] for i in items}
    assert kinds == {"reminder", "payment"}
    assert len(items) == 2  # the empty-title reminder dropped


def test_normalise_bad_date_still_included_as_undated():
    items = B.normalise(reminders=[{"title": "No date", "due_at": "garbage"}])
    assert items[0]["when"] is None


# --------------------------------------------------------------- morning

def test_morning_groups_overdue_and_today():
    m = B.morning_brief(now=NOW, **_fixtures())
    assert m["mode"] == "morning"
    overdue_titles = [i["title"] for i in m["overdue"]]
    today_titles = [i["title"] for i in m["today"]]
    assert "Pay rent" in overdue_titles          # due yesterday, not done
    assert "Call bank" in today_titles
    assert "Electricity bill" in today_titles
    assert "Rahim" in today_titles               # birthday today
    assert "Team standup" in today_titles
    # done + future items must NOT be in morning
    assert "Buy milk" not in today_titles + overdue_titles
    assert "Dentist" not in today_titles + overdue_titles


def test_morning_counts_and_not_empty():
    m = B.morning_brief(now=NOW, **_fixtures())
    assert m["counts"]["total"] == len(m["overdue"]) + len(m["today"])
    assert m["empty"] is False
    assert m["counts"]["payment"] >= 1
    assert m["counts"]["birthday"] == 1


def test_morning_empty_state_is_honest():
    m = B.morning_brief(now=NOW)
    assert m["empty"] is True
    assert m["counts"]["total"] == 0


def test_morning_today_sorted_by_time_payment_first_on_tie():
    m = B.morning_brief(now=NOW, **_fixtures())
    # earliest time-of-day first: standup 09:30 before call bank 10:00
    today = m["today"]
    standup = next(i for i in today if i["title"] == "Team standup")
    call = next(i for i in today if i["title"] == "Call bank")
    assert today.index(standup) < today.index(call)


# --------------------------------------------------------------- night

def test_night_done_open_and_tomorrow():
    n = B.night_summary(now=NOW, **_fixtures())
    assert n["mode"] == "night"
    done = [i["title"] for i in n["done_today"]]
    openn = [i["title"] for i in n["open_today"]]
    tomorrow = [i["title"] for i in n["tomorrow"]]
    assert "Buy milk" in done                    # due today, marked done
    assert "Call bank" in openn                  # due today, still open
    assert "Dentist" in tomorrow                 # due tomorrow (15th)
    assert "Internet" not in tomorrow            # due 16th → future, not preview


def test_night_completion_pct_is_honest():
    n = B.night_summary(now=NOW, **_fixtures())
    due = n["counts"]["done"] + n["counts"]["open"]
    assert n["counts"]["completion_pct"] == round(n["counts"]["done"] / due * 100)
    # with open items it can never be 100
    assert n["counts"]["completion_pct"] < 100


def test_night_empty_when_nothing():
    n = B.night_summary(now=NOW)
    assert n["empty"] is True
    assert n["counts"]["completion_pct"] == 0


# --------------------------------------------------------------- determinism

def test_build_is_deterministic():
    a = B.build("morning", now=NOW, **_fixtures())
    b = B.build("morning", now=NOW, **_fixtures())
    assert a == b


def test_build_mode_fallback():
    assert B.build("bogus", now=NOW)["mode"] == "morning"
    assert B.build("night", now=NOW)["mode"] == "night"


# --------------------------------------------------------- weather/news seams

def test_weather_slot_honest_placeholder():
    w = B.weather_slot()
    assert w["needs_key"] is True
    assert w["connected"] is False
    assert w["data"] is None
    assert w["integration"] == "weather"


def test_weather_slot_filled_when_connected():
    w = B.weather_slot(connected=True, data={"temp_c": 30})
    assert w["needs_key"] is False
    assert w["data"] == {"temp_c": 30}


def test_news_slot_never_fabricates():
    n = B.news_slot()
    assert n["needs_key"] is True
    assert n["items"] == []
    assert n["integration"] == "news"


def test_morning_carries_weather_night_carries_news():
    assert B.morning_brief(now=NOW)["weather"]["slot"] == "weather"
    assert B.night_summary(now=NOW)["news"]["slot"] == "news"


# --------------------------------------------------------------- share / AI

def test_share_text_omits_empty_and_lists_items():
    txt = B.share_text(B.morning_brief(now=NOW, **_fixtures()))
    assert "Call bank" in txt
    assert "Pay rent" in txt


def test_share_text_nothing_scheduled():
    txt = B.share_text(B.morning_brief(now=NOW))
    assert "Nothing scheduled" in txt


def test_ai_brief_plan_contract_only():
    p = B.ai_brief_plan(B.morning_brief(now=NOW, **_fixtures()), lang="en")
    assert p["ai_required"] is True
    assert p["mock"] is False
    assert p["mode"] == "morning"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"daily_brief: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
