"""
fitness_partner_tests_snippets.py — plain-assert tests for the FITNESS PARTNER
engine (#72, §21). Pure stdlib. Deterministic progress/streak/weekly-summary
from a passed-in `now`; AI coaching is a documented key-gated seam that is NOT
built (coaching_available/fallback_tip verified honest). Every assertion
hand-verified. `python fitness_partner_tests_snippets.py` or import run_all().
"""

try:  # Django harness
    from core.logic import fitness_partner as F
except ImportError:  # standalone
    import fitness_partner as F  # noqa: E402


# --------------------------------------------------------- week bounds / dates
def test_week_bounds_monday_anchor():
    # 2026-02-04 is a Wednesday -> Monday 2026-02-02, Sunday 2026-02-08, wd 2
    mon, sun, wd = F.week_bounds("2026-02-04")
    assert mon == "2026-02-02"
    assert sun == "2026-02-08"
    assert wd == 2


def test_weekday_known_anchor():
    # 2026-01-01 is a Thursday -> wd 3
    assert F._weekday((2026, 1, 1)) == 3
    assert F.days_between("2026-01-01", "2026-01-08") == 7


# --------------------------------------------------------- weekly summary
def test_weekly_summary_counts_this_week_only():
    workouts = [
        {"date": "2026-02-02", "type": "walk", "minutes": 30, "calories": 120},
        {"date": "2026-02-04", "type": "gym", "minutes": 45},
        {"date": "2026-02-04", "type": "yoga", "minutes": 20},  # same day
        {"date": "2026-01-25", "type": "run", "minutes": 60},   # last week
    ]
    s = F.weekly_summary(workouts, "2026-02-04")
    assert s["count"] == 3          # three sessions this week
    assert s["days"] == 2           # two distinct days
    assert s["minutes"] == 95
    assert s["calories"] == 120     # only the one with a calorie figure
    assert s["empty"] is False


def test_weekly_summary_empty():
    s = F.weekly_summary([], "2026-02-04")
    assert s["empty"] and s["count"] == 0 and s["days"] == 0


# --------------------------------------------------------- streak
def test_streak_current_run():
    now = "2026-02-05"
    workouts = [
        {"date": "2026-02-05", "type": "walk", "minutes": 20},
        {"date": "2026-02-04", "type": "run", "minutes": 20},
        {"date": "2026-02-03", "type": "gym", "minutes": 20},
        {"date": "2026-02-01", "type": "yoga", "minutes": 20},  # gap -> break
    ]
    assert F.streak(workouts, now) == 3


def test_streak_stale_is_zero():
    # latest workout was 3 days ago -> no current streak
    workouts = [{"date": "2026-02-01", "type": "walk", "minutes": 20}]
    assert F.streak(workouts, "2026-02-05") == 0


def test_streak_yesterday_counts():
    workouts = [{"date": "2026-02-04", "type": "walk", "minutes": 20}]
    assert F.streak(workouts, "2026-02-05") == 1


# --------------------------------------------------------- workout_days goal
def test_workout_days_on_track():
    goal = {"kind": "workout_days", "target": 4, "start_date": "2026-02-01"}
    # Wed (elapsed 3/7). expected = 4*3/7 = 1.71. 2 distinct days -> on_track/ahead
    workouts = [
        {"date": "2026-02-02", "type": "walk", "minutes": 30},
        {"date": "2026-02-04", "type": "gym", "minutes": 40},
    ]
    p = F.progress(goal, workouts, "2026-02-04", lang="en")
    assert p["kind"] == "workout_days"
    assert p["actual"] == 2
    assert p["status"] in ("on_track", "ahead")
    assert p["percent"] == 50       # 2 of 4


def test_workout_days_behind():
    goal = {"kind": "workout_days", "target": 6, "start_date": "2026-02-01"}
    # Sunday (elapsed 7/7). expected 6; only 1 day done -> behind
    workouts = [{"date": "2026-02-02", "type": "walk", "minutes": 30}]
    p = F.progress(goal, workouts, "2026-02-08")
    assert p["status"] == "behind"


def test_workout_days_reached():
    goal = {"kind": "workout_days", "target": 3, "start_date": "2026-02-01"}
    workouts = [
        {"date": "2026-02-02", "type": "walk", "minutes": 30},
        {"date": "2026-02-03", "type": "run", "minutes": 30},
        {"date": "2026-02-04", "type": "gym", "minutes": 30},
    ]
    p = F.progress(goal, workouts, "2026-02-04")
    assert p["status"] == "reached" and p["percent"] == 100


def test_goal_not_started_future():
    goal = {"kind": "workout_days", "target": 3, "start_date": "2027-01-01"}
    p = F.progress(goal, [], "2026-02-04")
    assert p["status"] == "not_started" and p["percent"] == 0


def test_no_goal_not_started():
    p = F.progress(None, [], "2026-02-04")
    assert p["status"] == "not_started"


# --------------------------------------------------------- steps goal
def test_steps_today_only():
    goal = {"kind": "steps", "target": 8000, "start_date": "2026-02-01"}
    workouts = [
        {"date": "2026-02-04", "type": "walk", "minutes": 40, "steps": 5000},
        {"date": "2026-02-04", "type": "walk", "minutes": 20, "steps": 3000},
        {"date": "2026-02-03", "type": "walk", "minutes": 60, "steps": 9000},
    ]
    p = F.progress(goal, workouts, "2026-02-04", lang="en")
    assert p["actual"] == 8000      # only today's steps summed
    assert p["status"] == "reached"
    assert p["percent"] == 100


def test_steps_behind():
    goal = {"kind": "steps", "target": 10000, "start_date": "2026-02-01"}
    workouts = [{"date": "2026-02-04", "type": "walk", "steps": 2000,
                 "minutes": 20}]
    p = F.progress(goal, workouts, "2026-02-04")
    assert p["status"] == "behind" and p["percent"] == 20


# --------------------------------------------------------- weight goal
def test_weight_loss_progress():
    goal = {"kind": "weight", "target": 70, "start_weight": 80,
            "start_date": "2026-01-01"}
    weighins = [{"date": "2026-02-01", "weight": 75}]
    p = F.progress(goal, [], "2026-02-10", weighins=weighins, lang="en")
    assert p["current_weight"] == 75
    assert p["lost"] == 5.0
    assert p["remaining"] == 5.0
    assert p["percent"] == 50       # closed half the 10kg gap
    assert p["status"] == "on_track"


def test_weight_gain_goal():
    goal = {"kind": "weight", "target": 65, "start_weight": 60,
            "start_date": "2026-01-01"}
    weighins = [{"date": "2026-02-01", "weight": 65}]
    p = F.progress(goal, [], "2026-02-10", weighins=weighins)
    assert p["status"] == "reached" and p["percent"] == 100


def test_weight_no_weighin_uses_start():
    goal = {"kind": "weight", "target": 70, "start_weight": 80,
            "start_date": "2026-01-01"}
    p = F.progress(goal, [], "2026-02-10", weighins=[])
    assert p["current_weight"] == 80 and p["percent"] == 0


# --------------------------------------------------------- AI coaching seam
def test_coaching_unavailable_without_key():
    r = F.coaching_available(has_key=False)
    assert r["available"] is False
    assert "bn" in r["reason"] and "en" in r["reason"]


def test_coaching_available_with_key():
    assert F.coaching_available(has_key=True)["available"] is True


def test_fallback_tip_is_deterministic_nonmedical():
    a = F.fallback_tip("behind", "en")
    b = F.fallback_tip("behind", "en")
    assert a == b and isinstance(a, str) and a
    # bilingual
    assert F.fallback_tip("reached", "bn") != F.fallback_tip("reached", "en")


# --------------------------------------------------------- determinism
def test_progress_deterministic():
    goal = {"kind": "workout_days", "target": 4, "start_date": "2026-02-01"}
    w = [{"date": "2026-02-02", "type": "walk", "minutes": 30}]
    assert F.progress(goal, w, "2026-02-04") == F.progress(goal, w, "2026-02-04")


def test_note_bilingual_nonmedical():
    goal = {"kind": "workout_days", "target": 3, "start_date": "2026-02-01"}
    p = F.progress(goal, [{"date": "2026-02-02", "type": "walk", "minutes": 20}],
                   "2026-02-04")
    assert "bn" in p["note"] and "en" in p["note"]
    assert "medical" in p["note"]["en"].lower()


# --------------------------------------------------------- validation
def test_validate_goal():
    assert "bad_kind" in F.validate_goal("nope", 3)
    assert "target_positive" in F.validate_goal("steps", 0)
    assert "days_max_7" in F.validate_goal("workout_days", 9)
    assert "start_weight_required" in F.validate_goal("weight", 70)
    assert "target_equals_start" in F.validate_goal("weight", 70,
                                                     start_weight=70)
    assert F.validate_goal("weight", 70, start_weight=80) == []
    assert F.validate_goal("steps", 8000) == []


def test_validate_workout():
    assert "type_required" in F.validate_workout("", 30)
    assert "minutes_positive" in F.validate_workout("walk", 0)
    assert F.validate_workout("walk", 30) == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"fitness_partner: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
