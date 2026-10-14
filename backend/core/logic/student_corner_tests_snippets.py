"""
student_corner_tests_snippets.py — plain-assert tests for STUDENT CORNER
(#192, §20). Pure stdlib. `python student_corner_tests_snippets.py` or import
and call run_all(). The engine is deterministic, so every assertion is
hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import student_corner as S
except ImportError:  # standalone
    import student_corner as S  # noqa: E402


# --------------------------------------------------------------- GPA scale

def test_letter_for_marks_bd_scale():
    assert S.letter_for_marks(80) == "A+"
    assert S.letter_for_marks(79) == "A"
    assert S.letter_for_marks(40) == "D"
    assert S.letter_for_marks(39) == "F"
    assert S.letter_for_marks(0) == "F"
    assert S.letter_for_marks(100) == "A+"


def test_letter_for_marks_junk_is_honest():
    assert S.letter_for_marks(None) is None
    assert S.letter_for_marks("abc") is None
    assert S.letter_for_marks(-5) is None
    assert S.letter_for_marks(120) is None


def test_point_for_letter_and_aliases():
    assert S.point_for_letter("A+") == 4.00
    assert S.point_for_letter("a plus") == 4.00
    assert S.point_for_letter("B-") == 2.75
    assert S.point_for_letter("Z") is None
    assert S.point_for_letter(None) is None


def test_scale_rows_cover_full_range():
    rows = S.scale_rows("en")
    assert len(rows) == 10
    assert rows[0]["letter"] == "A+" and rows[0]["max_marks"] == 100
    assert rows[-1]["letter"] == "F"


# --------------------------------------------------------------- CGPA math

def test_cgpa_weighted_and_transparent():
    # A+ (4.00) x 3cr, A- (3.50) x 3cr, B (3.00) x 2cr
    # quality = 12 + 10.5 + 6 = 28.5 ; credits = 8 ; cgpa = 3.5625
    courses = [
        {"title": "Math", "credit": 3, "letter": "A+"},
        {"title": "Physics", "credit": 3, "letter": "A-"},
        {"title": "English", "credit": 2, "letter": "B"},
    ]
    r = S.compute_cgpa(courses, "en")
    assert r["quality_points"] == 28.5
    assert r["graded_credits"] == 8
    assert r["cgpa"] == 3.5625
    assert r["cgpa_display"] == "3.56"
    # per-course contribution is shown
    assert r["courses"][0]["contribution"] == 12.0
    assert r["courses"][1]["contribution"] == 10.5


def test_cgpa_from_marks():
    courses = [{"title": "C1", "credit": 3, "marks": 82},  # A+ 4.00
               {"title": "C2", "credit": 3, "marks": 58}]  # B- 2.75
    r = S.compute_cgpa(courses, "en")
    # (12 + 8.25)/6 = 3.375
    assert r["cgpa"] == 3.375
    assert r["courses"][0]["letter"] == "A+"
    assert r["courses"][1]["letter"] == "B-"


def test_cgpa_f_counts_in_denominator():
    # One A (3.75 x 3) and one F (0 x 3). quality=11.25, credits=6 -> 1.875
    courses = [{"title": "Pass", "credit": 3, "letter": "A"},
               {"title": "Fail", "credit": 3, "letter": "F"}]
    r = S.compute_cgpa(courses, "en")
    assert r["graded_credits"] == 6  # F credit DOES count
    assert r["cgpa"] == 1.875


def test_cgpa_ungraded_course_excluded_not_invented():
    courses = [{"title": "Done", "credit": 3, "letter": "A+"},
               {"title": "Pending", "credit": 3}]  # no grade/marks
    r = S.compute_cgpa(courses, "en")
    assert r["graded_credits"] == 3           # only the graded one counts
    assert r["cgpa"] == 4.00
    assert r["courses"][1]["graded"] is False
    assert r["courses"][1]["point_display"] == "—"


def test_cgpa_empty_is_honest():
    r = S.compute_cgpa([], "en")
    assert r["cgpa"] == 0.0
    assert r["honest"] is True
    assert r["graded_credits"] == 0


def test_cgpa_is_deterministic():
    courses = [{"title": "x", "credit": 3, "marks": 73},
               {"title": "y", "credit": 2, "letter": "B+"}]
    assert S.compute_cgpa(courses, "en") == S.compute_cgpa(courses, "en")


def test_cgpa_scale_echoed():
    r = S.compute_cgpa([{"title": "x", "credit": 3, "letter": "A"}], "en")
    assert "Bangladesh 4.00" in r["scale"]["name"]
    assert len(r["scale"]["rows"]) == 10


# --------------------------------------------------------------- tracker

def test_assignment_overdue_honest():
    s = S.assignment_status(
        {"title": "Lab", "due_date": "2026-10-10"}, "2026-10-14")
    assert s["state"] == "overdue" and s["days"] == -4


def test_assignment_done_never_overdue():
    s = S.assignment_status(
        {"title": "Lab", "due_date": "2026-10-10", "done": True}, "2026-10-14")
    assert s["state"] == "done"


def test_assignment_no_due_never_overdue():
    s = S.assignment_status({"title": "Essay"}, "2026-10-14")
    assert s["state"] == "no_due" and s["days"] is None


def test_assignment_due_today_and_upcoming():
    assert S.assignment_status(
        {"title": "x", "due_date": "2026-10-14"}, "2026-10-14")["state"] \
        == "due_today"
    up = S.assignment_status(
        {"title": "x", "due_date": "2026-10-20"}, "2026-10-14")
    assert up["state"] == "upcoming" and up["days"] == 6


def test_tracker_board_partition_and_counts():
    items = [
        {"id": 1, "title": "A", "due_date": "2026-10-10"},   # overdue
        {"id": 2, "title": "B", "due_date": "2026-10-14"},   # due today
        {"id": 3, "title": "C", "due_date": "2026-10-20"},   # upcoming
        {"id": 4, "title": "D", "done": True},               # done
        {"id": 5, "title": "E"},                             # no due
    ]
    b = S.tracker_board(items, "2026-10-14")
    assert b["counts"]["overdue"] == 1
    assert b["counts"]["due_today"] == 1
    assert b["counts"]["upcoming"] == 1
    assert b["counts"]["done"] == 1
    assert b["counts"]["no_due"] == 1
    assert b["counts"]["open"] == 4
    # overdue sorts first in `all`
    assert b["all"][0]["title"] == "A"


# --------------------------------------------------------------- routine

def test_routine_groups_and_sorts_by_time():
    periods = [
        {"id": 1, "day": "sun", "start": "10:00", "end": "11:00", "subject": "Math"},
        {"id": 2, "day": "sat", "start": "09:00", "end": "10:00", "subject": "Eng"},
        {"id": 3, "day": "sat", "start": "08:00", "end": "09:00", "subject": "Bng"},
    ]
    r = S.routine_by_day(periods)
    days = r["days"]
    assert days[0]["key"] == "sat"            # sat (index 0) first
    assert [p["subject"] for p in days[0]["periods"]] == ["Bng", "Eng"]
    assert days[1]["key"] == "sun"


def test_routine_flags_overlap_honestly():
    periods = [
        {"id": 1, "day": 0, "start": "09:00", "end": "10:30", "subject": "A"},
        {"id": 2, "day": 0, "start": "10:00", "end": "11:00", "subject": "B"},
    ]
    r = S.routine_by_day(periods)
    day = r["days"][0]
    assert day["overlaps"] is True
    assert day["periods"][1]["conflict"] is True
    assert day["periods"][0]["conflict"] is False


def test_routine_empty():
    assert S.routine_by_day([]) == {"days": []}


# --------------------------------------------------------------- goals

def test_goal_progress():
    g = S.goal_progress([{"done": True}, {"done": False}, {"done": True}])
    assert g["total"] == 3 and g["done"] == 2 and g["percent"] == 67
    assert g["complete"] is False


def test_goal_progress_complete_and_empty():
    assert S.goal_progress([{"done": True}])["complete"] is True
    e = S.goal_progress([])
    assert e["empty"] is True and e["percent"] == 0


# --------------------------------------------------------------- validation

def test_validate_course():
    assert "title_required" in S.validate_course("", 3)
    assert "credit_positive" in S.validate_course("Math", 0)
    assert "credit_too_big" in S.validate_course("Math", 20)
    assert S.validate_course("Math", 3) == []


def test_validate_assignment():
    assert "title_required" in S.validate_assignment("  ")
    assert S.validate_assignment("Essay") == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"student_corner: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
