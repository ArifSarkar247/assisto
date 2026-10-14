"""
savings_challenge_tests_snippets.py — plain-assert tests for the SAVINGS
CHALLENGE engine (#171). Pure stdlib. Deterministic schedule + progress; every
assertion hand-verified against fixed inputs. `python
savings_challenge_tests_snippets.py` or import and call run_all().
"""

try:  # Django harness
    from core.logic import savings_challenge as S
except ImportError:  # standalone
    import savings_challenge as S  # noqa: E402


# --------------------------------------------------------------- poisha/fmt
def test_to_poisha_and_fmt():
    assert S.to_poisha("50") == 5000
    assert S.to_poisha("2,600") == 260000
    assert S.fmt_poisha(6890000) == "৳68,900.00"
    assert S.to_poisha(True) == 0


# --------------------------------------------------------------- dates
def test_days_between_and_add():
    assert S.days_between("2026-01-01", "2026-01-08") == 7
    assert S.days_between("2026-02-28", "2026-03-01") == 1  # 2026 not leap
    assert S.days_between("2024-02-28", "2024-03-01") == 2  # 2024 leap
    assert S._add_days((2026, 1, 1), 7) == "2026-01-08"
    assert S._add_days((2026, 12, 31), 1) == "2027-01-01"
    assert S.days_between("junk", "2026-01-01") is None


# --------------------------------------------------------------- week52
def test_week52_schedule_classic_totals():
    plan = {"kind": "week52", "base": "50", "start_date": "2026-01-01"}
    sch = S.schedule(plan)
    assert len(sch) == 52
    assert sch[0]["target"] == 5000      # ৳50 week 1
    assert sch[1]["target"] == 10000     # ৳100 week 2
    assert sch[51]["target"] == 260000   # ৳2600 week 52
    # classic grand total = 50 * (52*53/2) = 68,900 taka
    assert sch[-1]["cumulative"] == 6890000
    assert S.plan_total(plan) == 6890000
    # weekly dates step by 7 days
    assert sch[1]["date"] == "2026-01-08"


def test_week52_default_base_when_missing():
    plan = {"kind": "week52", "start_date": "2026-01-01"}
    assert S.plan_total(plan) == 6890000  # defaults to ৳50 base


# --------------------------------------------------------------- fixed
def test_fixed_schedule_and_total():
    plan = {"kind": "fixed", "base": "100", "periods": 10,
            "period": "monthly", "start_date": "2026-01-01"}
    sch = S.schedule(plan)
    assert len(sch) == 10
    assert all(r["target"] == 10000 for r in sch)
    assert S.plan_total(plan) == 100000  # 10 * 100 = 1000 taka
    # monthly step ~30 days
    assert sch[1]["date"] == "2026-01-31"


def test_fixed_bad_periods_empty():
    assert S.schedule({"kind": "fixed", "base": "100", "periods": 0}) == []


# --------------------------------------------------------------- expected_by
def test_expected_by_only_arrived_periods():
    plan = {"kind": "fixed", "base": "100", "periods": 10,
            "period": "weekly", "start_date": "2026-01-01"}
    # 2 weeks + 1 day in -> weeks 1,2,3 arrived (days 0,7,14 <= day 15)
    exp, elapsed = S.expected_by(plan, "2026-01-16")
    assert elapsed == 3
    assert exp == 30000  # 3 * 100 taka


def test_expected_zero_before_start():
    plan = {"kind": "fixed", "base": "100", "periods": 5,
            "period": "weekly", "start_date": "2026-06-01"}
    exp, elapsed = S.expected_by(plan, "2026-01-01")
    assert exp == 0 and elapsed == 0


# --------------------------------------------------------------- progress
def test_progress_on_track():
    plan = {"name": "Car", "kind": "fixed", "base": "100", "periods": 10,
            "period": "weekly", "start_date": "2026-01-01"}
    # 3 weeks elapsed, expected 300; saved exactly 300 -> on_track
    deposits = [{"amount": "300", "date": "2026-01-10"}]
    p = S.progress(plan, deposits, "2026-01-16", lang="en")
    assert p["expected"] == 30000
    assert p["saved"] == 30000
    assert p["status"] == "on_track"
    assert p["goal"] == 100000
    assert p["percent"] == 30  # 300/1000


def test_progress_behind():
    plan = {"name": "X", "kind": "fixed", "base": "100", "periods": 10,
            "period": "weekly", "start_date": "2026-01-01"}
    deposits = [{"amount": "100", "date": "2026-01-02"}]  # only 100 of 300 due
    p = S.progress(plan, deposits, "2026-01-16")
    assert p["status"] == "behind"
    assert p["ahead_by"] == -20000  # 100 - 300 = -200 taka


def test_progress_ahead():
    plan = {"name": "X", "kind": "fixed", "base": "100", "periods": 10,
            "period": "weekly", "start_date": "2026-01-01"}
    deposits = [{"amount": "600", "date": "2026-01-02"}]  # 600 vs expected 300
    p = S.progress(plan, deposits, "2026-01-16")
    assert p["status"] == "ahead"
    assert p["ahead_by"] == 30000


def test_progress_not_started():
    plan = {"name": "Future", "kind": "week52", "base": "50",
            "start_date": "2027-01-01"}
    p = S.progress(plan, [], "2026-10-01")
    assert p["status"] == "not_started"
    assert p["saved"] == 0


def test_progress_complete_caps_at_goal():
    plan = {"name": "Done", "kind": "fixed", "base": "100", "periods": 5,
            "period": "weekly", "start_date": "2026-01-01"}
    deposits = [{"amount": "500", "date": "2026-01-02"}]  # whole 500 goal
    p = S.progress(plan, deposits, "2026-03-01")
    assert p["status"] == "complete"
    assert p["percent"] == 100
    assert p["projected"] == 50000  # not inflated past the goal


def test_projected_at_pace():
    plan = {"name": "P", "kind": "fixed", "base": "100", "periods": 10,
            "period": "weekly", "start_date": "2026-01-01"}
    # saved 300 over 3 elapsed periods -> pace 100/period * 10 = 1000 = goal
    deposits = [{"amount": "300", "date": "2026-01-10"}]
    p = S.progress(plan, deposits, "2026-01-16")
    assert p["projected"] == 100000


# --------------------------------------------------------------- streak
def test_week52_streak_counts_covered_periods():
    plan = {"kind": "week52", "base": "50", "start_date": "2026-01-01"}
    # cumulative after 3 weeks = 50+100+150 = 300 taka
    deposits = [{"amount": "300", "date": "2026-01-15"}]
    assert S.streak(plan, deposits) == 3
    # a little short of week 3 cumulative -> only 2 covered
    deposits2 = [{"amount": "150", "date": "2026-01-15"}]
    assert S.streak(plan, deposits2) == 2


def test_roundup_streak_consecutive_days():
    plan = {"kind": "roundup", "base": "10", "start_date": "2026-01-01"}
    deposits = [
        {"amount": "5", "date": "2026-01-10"},
        {"amount": "7", "date": "2026-01-09"},
        {"amount": "3", "date": "2026-01-08"},
        {"amount": "2", "date": "2026-01-05"},  # gap breaks the streak
    ]
    assert S.streak(plan, deposits) == 3


def test_roundup_progress_gentle_target():
    plan = {"name": "Jar", "kind": "roundup", "base": "10",
            "start_date": "2026-01-01"}
    # 10 days in (inclusive) -> expected 10*10 = 100 taka
    deposits = [{"amount": "120", "date": "2026-01-05"}]
    p = S.progress(plan, deposits, "2026-01-10", lang="en")
    assert p["expected"] == 10000
    assert p["status"] == "ahead"
    assert p["goal"] == 0          # open-ended
    assert p["percent"] is None


# --------------------------------------------------------------- determinism
def test_progress_is_deterministic():
    plan = {"name": "D", "kind": "week52", "base": "50",
            "start_date": "2026-01-01"}
    dep = [{"amount": "300", "date": "2026-01-15"}]
    a = S.progress(plan, dep, "2026-02-01", lang="en")
    b = S.progress(plan, dep, "2026-02-01", lang="en")
    assert a == b


def test_no_money_note_bilingual():
    plan = {"name": "N", "kind": "week52", "base": "50",
            "start_date": "2026-01-01"}
    p = S.progress(plan, [], "2026-02-01")
    assert "bn" in p["note"] and "en" in p["note"]


# --------------------------------------------------------------- validation
def test_validate_plan():
    assert "name_required" in S.validate_plan("", "week52", "50", 0)
    assert "bad_kind" in S.validate_plan("X", "nope", "50", 0)
    assert "base_required" in S.validate_plan("X", "week52", "0", 0)
    assert "periods_required" in S.validate_plan("X", "fixed", "100", 0)
    assert S.validate_plan("X", "fixed", "100", 10) == []


def test_validate_deposit():
    assert "amount_required" in S.validate_deposit("0")
    assert S.validate_deposit("50") == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"savings_challenge: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
