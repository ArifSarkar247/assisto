"""
wellness_tracker_tests_snippets.py — plain-assert tests for the WATER / SLEEP /
DIET tracker logic (#71, §10). Pure stdlib. `python3 wellness_tracker_tests_
snippets.py` or import and call run_all(). Deterministic (time passed in), so
every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import wellness_tracker as W
except ImportError:  # standalone
    import wellness_tracker as W  # noqa: E402


# --------------------------------------------------------------- folding

def test_fold_sums_same_day_water_and_sleep():
    rows = [
        {"id": 1, "date": "2026-03-10", "water": 3, "sleep": 4},
        {"id": 2, "date": "2026-03-10", "water": 2, "sleep": 3.5},
    ]
    days = W.fold_by_day(rows)
    rec = days["2026-03-10"]
    assert rec["water"] == 5
    assert rec["sleep"] == 7.5


def test_fold_latest_diet_note_wins():
    rows = [
        {"id": 1, "date": "2026-03-10", "diet": "rice"},
        {"id": 2, "date": "2026-03-10", "diet": "fish and veg"},
    ]
    assert W.fold_by_day(rows)["2026-03-10"]["diet"] == "fish and veg"


def test_fold_skips_undated_rows():
    rows = [{"id": 1, "date": "", "water": 5}]
    assert W.fold_by_day(rows) == {}


def test_fold_per_log_goal_override():
    rows = [{"id": 1, "date": "2026-03-10", "water": 6, "water_goal": 6}]
    rec = W.fold_by_day(rows)["2026-03-10"]
    assert rec["water_goal"] == 6


# --------------------------------------------------------------- progress

def test_ratio_clamps_ring_but_keeps_raw():
    rows = [{"id": 1, "date": "2026-03-10", "water": 12, "sleep": 8}]
    v = W.today_view(rows, today="2026-03-10")
    assert v["water"]["met"] is True
    assert v["water"]["raw"] == 1.5         # 12/8 default goal
    assert v["water"]["ring"] == 1.0        # clamped
    assert v["sleep"]["met"] is True


def test_today_view_absent_log_is_honest_zero():
    v = W.today_view([], today="2026-03-10")
    assert v["logged"] is False
    assert v["water"]["value"] == 0
    assert v["water"]["met"] is False


def test_today_view_logged_flag():
    rows = [{"id": 1, "date": "2026-03-10", "water": 1}]
    assert W.today_view(rows, today="2026-03-10")["logged"] is True
    assert W.today_view(rows, today="2026-03-11")["logged"] is False


# --------------------------------------------------------------- trend

def test_trend_spans_seven_days_oldest_first():
    rows = [{"id": 1, "date": "2026-03-10", "water": 8, "sleep": 8}]
    tr = W.trend(rows, today="2026-03-10")
    assert tr["days"] == 7
    assert len(tr["series"]) == 7
    assert tr["series"][0]["date"] == "2026-03-04"   # 7 days back inclusive
    assert tr["series"][-1]["date"] == "2026-03-10"
    assert tr["series"][-1]["logged"] is True
    assert tr["series"][0]["logged"] is False


def test_trend_averages_over_logged_days_only():
    rows = [
        {"id": 1, "date": "2026-03-09", "water": 6, "sleep": 7},
        {"id": 2, "date": "2026-03-10", "water": 8, "sleep": 9},
    ]
    tr = W.trend(rows, today="2026-03-10")
    assert tr["logged_days"] == 2
    assert tr["avg_water"] == 7.0      # (6+8)/2, gaps excluded
    assert tr["avg_sleep"] == 8.0


def test_trend_counts_goal_days():
    rows = [
        {"id": 1, "date": "2026-03-09", "water": 8, "sleep": 8},
        {"id": 2, "date": "2026-03-10", "water": 4, "sleep": 8},
    ]
    tr = W.trend(rows, today="2026-03-10")
    assert tr["water_goal_days"] == 1   # only the 8-glass day met
    assert tr["sleep_goal_days"] == 2


# --------------------------------------------------------------- streaks

def test_water_streak_counts_only_met_days():
    rows = [
        {"id": 1, "date": "2026-03-08", "water": 8},
        {"id": 2, "date": "2026-03-09", "water": 8},
        {"id": 3, "date": "2026-03-10", "water": 8},
    ]
    s = W.streaks(rows, today="2026-03-10")
    assert s["water"]["current"] == 3
    assert s["water"]["best"] == 3


def test_streak_breaks_on_missing_or_unmet_day():
    rows = [
        {"id": 1, "date": "2026-03-08", "water": 8},
        {"id": 2, "date": "2026-03-09", "water": 2},   # unmet -> breaks
        {"id": 3, "date": "2026-03-10", "water": 8},
    ]
    s = W.streaks(rows, today="2026-03-10")
    assert s["water"]["current"] == 1
    assert s["water"]["best"] == 1


def test_streak_allows_today_not_yet_logged():
    # today unlogged, yesterday & before met -> current counts from yesterday
    rows = [
        {"id": 1, "date": "2026-03-08", "water": 8},
        {"id": 2, "date": "2026-03-09", "water": 8},
    ]
    s = W.streaks(rows, today="2026-03-10")
    assert s["water"]["current"] == 2


# --------------------------------------------------------------- validation

def test_validate_requires_date():
    assert "date_required" in W.validate("", water=5)
    assert W.validate("2026-03-10", water=5, sleep=8) == []


def test_validate_rejects_insane_numbers():
    assert "bad_water" in W.validate("2026-03-10", water=100)
    assert "bad_sleep" in W.validate("2026-03-10", sleep=30)
    assert "bad_water" in W.validate("2026-03-10", water="lots")


# --------------------------------------------------------------- disclaimer

def test_disclaimer_is_bilingual_and_not_advice():
    d = W.disclaimer()
    assert "bn" in d and "en" in d
    assert "not medical advice" in d["en"].lower()


# --------------------------------------------------------------- determinism

def test_everything_deterministic():
    rows = [{"id": 1, "date": "2026-03-10", "water": 8, "sleep": 8,
             "diet": "ok"}]
    a = (W.today_view(rows, "2026-03-10"), W.trend(rows, "2026-03-10"),
         W.streaks(rows, "2026-03-10"))
    b = (W.today_view(rows, "2026-03-10"), W.trend(rows, "2026-03-10"),
         W.streaks(rows, "2026-03-10"))
    assert a == b


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"wellness_tracker: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
