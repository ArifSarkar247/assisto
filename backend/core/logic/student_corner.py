"""
student_corner.py — pure, deterministic STUDENT CORNER logic (#192, SPEC v2.1
§20). Thin tools for a Bangladeshi student:

  * CLASS ROUTINE / TIMETABLE  — group period rows by weekday, sort by start
    time, flag overlapping periods honestly, and pick "today" / "next class"
    from a passed-in `now` (never the wall clock).
  * ASSIGNMENT / EXAM TRACKER  — days-until / overdue status from a passed-in
    `now` (honest: an undated item is never "overdue"; a done item is never
    overdue), with a stable upcoming/overdue/done partition.
  * CGPA / RESULT CALCULATOR   — credit-weighted GPA on the STANDARD Bangladeshi
    4.00 university scale (UGC uniform grading), with the grade→point map shown
    transparently and every course's contribution (point × credit) returned so
    the arithmetic is auditable. No rounding until display (4 dp internally).
  * STUDY-GOAL CHECKLIST       — done/total progress, percent, honest empty.

HARD RULES (money-free; this module holds no money and does no I/O):
  * NO DB, NO AI, NO CLOCK. Every time-relative function takes `now` explicitly
    so results are reproducible and testable. Returns plain dicts/lists.
  * The GPA scale is the UGC "Uniform Grading System" for Bangladeshi
    universities (the 4.00 scale). It is a module constant, documented below,
    and echoed back in every CGPA result so the math is never a black box.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer renders them directly and keeps ZERO Bangla in .dart.

Standard Bangladeshi 4.00 GPA scale (UGC Uniform Grading System):

    Marks (%)   Letter   Grade point
    80-100      A+       4.00
    75-79       A        3.75
    70-74       A-       3.50
    65-69       B+       3.25
    60-64       B        3.00
    55-59       B-       2.75
    50-54       C+       2.50
    45-49       C        2.25
    40-44       D        2.00
    0-39        F        0.00

An F course carries 0.00 points but STILL counts in the credit denominator
(a failed credit drags the CGPA down — that is the honest behaviour and what
every BD university transcript does).

Run self-tests (no DB):
    python3 -c "import core.logic.student_corner_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# CGPA / RESULT — standard Bangladeshi 4.00 scale (UGC uniform grading)
# ===========================================================================

# Ordered high→low. Each: (letter, grade_point, min_marks_inclusive).
GPA_SCALE = (
    ("A+", 4.00, 80),
    ("A", 3.75, 75),
    ("A-", 3.50, 70),
    ("B+", 3.25, 65),
    ("B", 3.00, 60),
    ("B-", 2.75, 55),
    ("C+", 2.50, 50),
    ("C", 2.25, 45),
    ("D", 2.00, 40),
    ("F", 0.00, 0),
)

# letter → grade point, for when the user enters a letter directly.
GRADE_POINTS = {letter: point for letter, point, _ in GPA_SCALE}
# Common aliases students type.
_LETTER_ALIASES = {"A PLUS": "A+", "B PLUS": "B+", "C PLUS": "C+"}


def scale_rows(lang="bn"):
    """The whole scale as display rows — so the UI can SHOW the table it uses.
    [{letter, point, point_display, min_marks, band}]."""
    rows = []
    for i, (letter, point, lo) in enumerate(GPA_SCALE):
        hi = 100 if i == 0 else GPA_SCALE[i - 1][2] - 1
        rows.append({
            "letter": letter,
            "point": point,
            "point_display": _fmt_gp(point),
            "min_marks": lo,
            "max_marks": hi,
            "band": f"{lo}–{hi}" if letter != "F" else f"0–{hi}",
        })
    return rows


def letter_for_marks(marks):
    """Marks (0-100) → letter grade on the BD 4.00 scale. None/invalid → None
    (honest: we do NOT guess a grade from junk)."""
    m = _num(marks)
    if m is None or m < 0 or m > 100:
        return None
    for letter, _point, lo in GPA_SCALE:
        if m >= lo:
            return letter
    return "F"


def point_for_letter(letter):
    """Letter grade → grade point. Unknown letter → None (honest)."""
    if letter is None:
        return None
    key = str(letter).strip().upper()
    key = _LETTER_ALIASES.get(key, key)
    return GRADE_POINTS.get(key)


def _course_point(course):
    """Resolve a course's grade point: prefer an explicit letter, else derive
    from marks. Returns (point, letter) or (None, None) if neither is usable."""
    letter = course.get("letter") or course.get("grade")
    if letter:
        p = point_for_letter(letter)
        if p is not None:
            key = str(letter).strip().upper()
            return p, _LETTER_ALIASES.get(key, key)
    if course.get("marks") not in (None, ""):
        lt = letter_for_marks(course.get("marks"))
        if lt is not None:
            return GRADE_POINTS[lt], lt
    return None, None


def compute_cgpa(courses, lang="bn"):
    """Credit-weighted CGPA on the BD 4.00 scale, with transparent per-course
    math. `courses`: [{title, credit, letter|grade|marks}].

    Returns {
      cgpa, cgpa_display, total_credits, graded_credits,
      quality_points, quality_points_display, class_band,
      courses: [{title, credit, letter, point, point_display,
                 contribution, contribution_display, graded}],
      scale, note, honest
    }
    A course with no resolvable grade is kept but marked graded=False and
    EXCLUDED from both numerator and denominator (honest: we never invent a
    grade). An F course IS graded (0.00 points) and DOES count in credits.
    """
    rows = []
    total_credits = 0.0       # every valid-credit course (incl. F)
    graded_credits = 0.0      # courses with a resolved grade
    quality = 0.0             # sum of point × credit
    for c in courses:
        credit = _num(c.get("credit"))
        if credit is None or credit <= 0:
            credit = 0.0
        point, letter = _course_point(c)
        graded = point is not None
        contribution = round(point * credit, 4) if graded else 0.0
        if graded:
            graded_credits += credit
            quality += contribution
        if credit > 0:
            total_credits += credit
        rows.append({
            "title": (c.get("title") or "").strip(),
            "credit": credit,
            "letter": letter,
            "point": point,
            "point_display": _fmt_gp(point) if graded else "—",
            "contribution": contribution,
            "contribution_display": _fmt_gp(contribution) if graded else "—",
            "graded": graded,
        })
    cgpa = round(quality / graded_credits, 4) if graded_credits > 0 else 0.0
    band = _class_band(cgpa, graded_credits, lang)
    return {
        "cgpa": cgpa,
        "cgpa_display": _fmt_gp(cgpa),
        "total_credits": round(total_credits, 3),
        "graded_credits": round(graded_credits, 3),
        "quality_points": round(quality, 4),
        "quality_points_display": _fmt_gp(round(quality, 4)),
        "class_band": band,
        "courses": rows,
        "scale": {"name": "UGC Uniform Grading (Bangladesh 4.00)",
                  "rows": scale_rows(lang)},
        "note": {
            "bn": "CGPA = (গ্রেড পয়েন্ট × ক্রেডিট)-এর যোগ ÷ মোট ক্রেডিট। F সহ গ্রেডফুল কোর্স গণনায় ধরা হয়।",
            "en": "CGPA = sum of (grade point × credit) ÷ total graded credits. Graded courses including F are counted.",
        },
        "honest": graded_credits <= 0,
    }


def _class_band(cgpa, graded_credits, lang):
    """A rough honours-class band label on the 4.00 scale. Returns a bilingual
    pair, or an honest 'no grade yet' when nothing is graded."""
    if graded_credits <= 0:
        return {"bn": "এখনো কোনো গ্রেড নেই",
                "en": "No grade entered yet"}
    if cgpa >= 3.75:
        return {"bn": "অসাধারণ", "en": "Outstanding"}
    if cgpa >= 3.00:
        return {"bn": "ভালো", "en": "Very good"}
    if cgpa >= 2.00:
        return {"bn": "স্বাভাবিক", "en": "Satisfactory"}
    return {"bn": "উন্নতি প্রয়োজন",
            "en": "Needs improvement"}


def _fmt_gp(v):
    """Grade point / CGPA → 2-dp string (e.g. '3.75'). None → '—'."""
    if v is None:
        return "—"
    return f"{float(v):.2f}"


# ===========================================================================
# ASSIGNMENT / EXAM TRACKER — honest overdue from a passed-in `now`
# ===========================================================================

def _parse_date(value):
    """ISO 'YYYY-MM-DD' (or date/datetime) → date, else None."""
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except (ValueError, TypeError):
        return None


def _is_done(item):
    return bool(item.get("done"))


def assignment_status(item, now):
    """Status of one assignment/exam relative to `now` (an ISO date or a
    date).  Returns {state, days, due_date, done, title, kind, label} where
    state is one of:
        done        — marked done (never 'overdue', even if past due)
        no_due      — no due date set (honest: cannot be overdue)
        overdue     — due date is strictly before `now` and not done
        due_today   — due date == now
        upcoming    — due date is after now
    `days` is signed days-until (negative = days overdue), or None for
    done/no_due.
    """
    n = _parse_date(now)
    due = _parse_date(item.get("due_date"))
    done = _is_done(item)
    title = (item.get("title") or "").strip()
    kind = item.get("kind") or "assignment"   # assignment | exam
    if done:
        return _st("done", None, due, done, title, kind)
    if due is None:
        return _st("no_due", None, due, done, title, kind)
    if n is None:
        # No reference time → we cannot judge overdue; be honest.
        return _st("upcoming", None, due, done, title, kind)
    delta = (due - n).days
    if delta < 0:
        state = "overdue"
    elif delta == 0:
        state = "due_today"
    else:
        state = "upcoming"
    return _st(state, delta, due, done, title, kind)


def _st(state, days, due, done, title, kind):
    return {
        "state": state,
        "days": days,
        "due_date": due.isoformat() if isinstance(due, date) else None,
        "done": done,
        "title": title,
        "kind": kind,
    }


_TRACKER_ORDER = {"overdue": 0, "due_today": 1, "upcoming": 2,
                  "no_due": 3, "done": 4}


def tracker_board(items, now):
    """Partition + sort assignments/exams for display. Returns {
        overdue, due_today, upcoming, no_due, done,   (lists of status dicts)
        counts: {overdue, due_today, upcoming, no_due, done, open},
        all: [...]   (every item, stable-sorted: overdue→done, then by due)
    }. Deterministic: within a bucket, sort by due date then title then id."""
    statuses = []
    for it in items:
        s = assignment_status(it, now)
        s["id"] = it.get("id")
        statuses.append(s)

    def key(s):
        due = s["due_date"] or "9999-99-99"
        return (_TRACKER_ORDER.get(s["state"], 9), due,
                s["title"].lower(), str(s.get("id")))

    statuses.sort(key=key)
    buckets = {k: [] for k in _TRACKER_ORDER}
    for s in statuses:
        buckets[s["state"]].append(s)
    counts = {k: len(v) for k, v in buckets.items()}
    counts["open"] = counts["overdue"] + counts["due_today"] + \
        counts["upcoming"] + counts["no_due"]
    return {
        "overdue": buckets["overdue"],
        "due_today": buckets["due_today"],
        "upcoming": buckets["upcoming"],
        "no_due": buckets["no_due"],
        "done": buckets["done"],
        "counts": counts,
        "all": statuses,
    }


# ===========================================================================
# CLASS ROUTINE / TIMETABLE
# ===========================================================================

# Monday-first weekday order; BD weeks vary, so we key periods by a 0-6 index
# the UI supplies. 0 = Saturday is common in BD school routines; we DON'T
# assume — we just group by whatever integer `day` each period carries and sort
# days ascending. The label map is bilingual and lives with the engine.
WEEKDAYS = (
    ("sat", "শনি", "Sat"),
    ("sun", "রবি", "Sun"),
    ("mon", "সোম", "Mon"),
    ("tue", "মঙ্গল", "Tue"),
    ("wed", "বুধ", "Wed"),
    ("thu", "বৃহস্পতি", "Thu"),
    ("fri", "শুক্র", "Fri"),
)
_DAY_INDEX = {k: i for i, (k, _b, _e) in enumerate(WEEKDAYS)}


def _day_index(period):
    """Resolve a period's weekday to a 0-6 int (0=Sat). Accepts int or key
    string ('sat'..'fri'). Unknown → 7 (sorted last)."""
    d = period.get("day")
    if isinstance(d, bool):
        return 7
    if isinstance(d, int):
        return d if 0 <= d <= 6 else 7
    return _DAY_INDEX.get(str(d).strip().lower(), 7)


def _minutes(hhmm):
    """'HH:MM' → minutes since midnight, or None."""
    if hhmm is None:
        return None
    s = str(hhmm).strip()
    if ":" not in s:
        return None
    h, _, m = s.partition(":")
    try:
        hh, mm = int(h), int(m)
    except ValueError:
        return None
    if not (0 <= hh <= 23 and 0 <= mm <= 59):
        return None
    return hh * 60 + mm


def routine_by_day(periods):
    """Group timetable periods by weekday and sort each day by start time.
    `periods`: [{id, day, start('HH:MM'), end('HH:MM'), subject, room}].
    Returns {days: [{index, key, label:{bn,en}, periods:[...], overlaps:bool}]}.
    Each period gets a `conflict` flag when it overlaps the previous one on the
    same day (honest: we show the clash, we don't silently resolve it)."""
    by_day = {}
    for p in periods:
        di = _day_index(p)
        by_day.setdefault(di, []).append(p)
    days = []
    for di in sorted(by_day):
        rows = sorted(
            by_day[di],
            key=lambda p: (
                _minutes(p.get("start")) if _minutes(p.get("start")) is not None
                else 9999,
                (p.get("subject") or "").lower(),
                str(p.get("id")),
            ),
        )
        prev_end = None
        day_overlap = False
        out_rows = []
        for p in rows:
            start = _minutes(p.get("start"))
            end = _minutes(p.get("end"))
            conflict = (prev_end is not None and start is not None
                        and start < prev_end)
            if conflict:
                day_overlap = True
            out_rows.append({
                "id": p.get("id"),
                "subject": (p.get("subject") or "").strip(),
                "room": (p.get("room") or "").strip(),
                "start": p.get("start"),
                "end": p.get("end"),
                "conflict": conflict,
            })
            if end is not None:
                prev_end = end if prev_end is None else max(prev_end, end)
        key, bn, en = WEEKDAYS[di] if 0 <= di <= 6 else ("other", "অন্য", "Other")
        days.append({
            "index": di,
            "key": key,
            "label": {"bn": bn, "en": en},
            "periods": out_rows,
            "overlaps": day_overlap,
        })
    return {"days": days}


# ===========================================================================
# STUDY-GOAL CHECKLIST
# ===========================================================================

def goal_progress(goals):
    """done/total progress of a study-goal checklist. `goals`: [{done}].
    Returns {total, done, remaining, percent, complete, empty}."""
    total = len(goals)
    done = sum(1 for g in goals if bool(g.get("done")))
    percent = round(done * 100 / total) if total else 0
    return {
        "total": total,
        "done": done,
        "remaining": total - done,
        "percent": percent,
        "complete": total > 0 and done == total,
        "empty": total == 0,
    }


# ===========================================================================
# validation (wire validates on save; UI mirrors this)
# ===========================================================================

def validate_course(title, credit):
    """Return a list of error codes for a CGPA course row. Empty → valid."""
    errs = []
    if not (title or "").strip():
        errs.append("title_required")
    c = _num(credit)
    if c is None or c <= 0:
        errs.append("credit_positive")
    elif c > 12:
        errs.append("credit_too_big")
    return errs


def validate_assignment(title):
    return [] if (title or "").strip() else ["title_required"]


# ===========================================================================
# small numeric helper
# ===========================================================================

def _num(v):
    """Coerce to float; junk/None → None (so callers can be honest)."""
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None
