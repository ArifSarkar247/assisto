"""
fitness_partner.py — pure, deterministic FITNESS PARTNER logic (#72, SPEC v2.1
§21 advanced). A gentle workout/fitness companion for an ordinary person:

  * GOAL          — one active goal of a kind:
        workout_days — N workout days per WEEK (the default, most honest unit)
        steps        — N steps per DAY
        weight       — a target weight in kg, with a start weight (progress is
                        the share of the gap closed; direction inferred from
                        start vs target so both loss and gain goals work)
    A goal is NOT a medical plan. Copy avoids medical/extreme claims — this is a
    tracker, not a prescription.
  * WORKOUTS      — log {type, minutes, calories?} on a date. Calories are
    OPTIONAL and reported as the user entered them; we never estimate calories
    from minutes (that would be a fabricated medical figure).
  * PROGRESS      — vs the goal, over the current week (Mon-anchored from a
    passed-in `now`), with an honest status:
        not_started — no goal set, or goal starts in the future
        behind      — below the pro-rated expectation for how far the week/day is
        on_track    — at/near the pro-rated expectation
        ahead       — comfortably above it
        reached     — goal already met for the period
  * WEEKLY SUMMARY + STREAK — this week's workout count/minutes, and the streak
    of consecutive days (ending at the latest workout day) with ≥1 workout.

HARD RULES (this module holds no data and does no I/O):
  * NO DB, NO AI, NO CLOCK. Every time-relative function takes `now` explicitly
    (an ISO date) so results are reproducible and testable. Returns plain dicts.
  * DETERMINISTIC MATH. Progress is a share of a pro-rated target — no random,
    no hidden clock, no estimation of unentered figures.
  * GENTLE, NON-MEDICAL. Status labels and notes are encouraging and honest;
    they never diagnose, never push intensity, never claim health outcomes.
  * Bilingual {"bn","en"} copy; ZERO Bangla in .dart.

AI-PERSONALISED-COACHING SEAM (documented, NOT built): `coaching_available(
has_key)` reports whether an optional, key-gated coaching feature COULD run. The
core tracker is fully deterministic and complete with NO key. When no key is
present we return `available=False` and a plain deterministic tip drawn from a
fixed, non-medical table — never a fabricated "AI" message. A real model is
wired outside this module only if a key is configured.

Row shapes the view layer stores (see integration note):
  goal    : {id, kind, target, start_weight, start_date}
            kind ∈ {workout_days, steps, weight}; target numeric;
            start_weight only for kind == 'weight'; start_date 'YYYY-MM-DD'.
  workout : {id, date, type, minutes, calories, steps}
            date 'YYYY-MM-DD'; minutes/calories/steps numeric-ish, optional.
  weighin : {id, date, weight}    # for a weight goal's progress (optional log)

Run self-tests (no DB):
    python3 -c "import core.logic.fitness_partner_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# catalog: goal kinds + workout types
# ===========================================================================

# (value, bn_label, en_label, unit_bn, unit_en, per)  per ∈ {week, day, total}
GOAL_KINDS = (
    ("workout_days", "সপ্তাহে ব্যায়ামের দিন", "Workout days / week",
     "দিন", "days", "week"),
    ("steps", "দৈনিক পদক্ষেপ", "Daily steps", "পদক্ষেপ", "steps", "day"),
    ("weight", "ওজনের লক্ষ্য", "Weight goal", "কেজি", "kg", "total"),
)
_GOAL_INFO = {v: (bn, en, ub, ue, per) for v, bn, en, ub, ue, per in GOAL_KINDS}
VALID_KINDS = tuple(v for v, *_ in GOAL_KINDS)

WORKOUT_TYPES = (
    ("walk", "হাঁটা", "Walking"),
    ("run", "দৌড়", "Running"),
    ("cycle", "সাইক্লিং", "Cycling"),
    ("gym", "জিম", "Gym"),
    ("yoga", "যোগব্যায়াম", "Yoga"),
    ("sport", "খেলাধুলা", "Sport"),
    ("other", "অন্যান্য", "Other"),
)
_WTYPE = {v: (bn, en) for v, bn, en in WORKOUT_TYPES}


def goal_kind_label(value, lang="bn"):
    info = _GOAL_INFO.get(value)
    return pick(lang, info[0], info[1]) if info else (value or "")


def goal_unit(value, lang="bn"):
    info = _GOAL_INFO.get(value)
    return pick(lang, info[2], info[3]) if info else ""


def goal_kind_rows(lang="bn"):
    return [{"value": v, "label": pick(lang, bn, en),
             "unit": pick(lang, ub, ue), "per": per}
            for v, bn, en, ub, ue, per in GOAL_KINDS]


def workout_type_label(value, lang="bn"):
    info = _WTYPE.get(value)
    return pick(lang, info[0], info[1]) if info else (value or "")


def workout_type_rows(lang="bn"):
    return [{"value": v, "label": pick(lang, bn, en)}
            for v, bn, en in WORKOUT_TYPES]


# ===========================================================================
# numeric + date helpers (no live clock)
# ===========================================================================

def _num(v):
    """Coerce to float; junk/None/bool → None (so callers stay honest)."""
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return None
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _int(v, default=0):
    n = _num(v)
    return int(n) if n is not None else default


def _ymd(s):
    if not s:
        return None
    parts = str(s).strip().split("-")
    try:
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
    except (IndexError, ValueError):
        return None
    if not (1 <= m <= 12 and 1 <= d <= 31):
        return None
    return (y, m, d)


def _is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


_MDAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)


def _ordinal(ymd):
    y, m, d = ymd
    days = 0
    for yy in range(1, y):
        days += 366 if _is_leap(yy) else 365
    for mm in range(1, m):
        days += _MDAYS[mm - 1] + (1 if (mm == 2 and _is_leap(y)) else 0)
    return days + d


def _from_ordinal(o):
    y = 1
    while True:
        yl = 366 if _is_leap(y) else 365
        if o > yl:
            o -= yl
            y += 1
        else:
            break
    m = 1
    while True:
        ml = _MDAYS[m - 1] + (1 if (m == 2 and _is_leap(y)) else 0)
        if o > ml:
            o -= ml
            m += 1
        else:
            break
    return f"{y:04d}-{m:02d}-{o:02d}"


def days_between(a, b):
    ya, yb = _ymd(a), _ymd(b)
    if not ya or not yb:
        return None
    return _ordinal(yb) - _ordinal(ya)


def _weekday(ymd):
    """0=Mon .. 6=Sun for an ymd tuple (proleptic Gregorian; 0001-01-01 = Mon)."""
    return (_ordinal(ymd) - 1) % 7


def week_bounds(now):
    """The Monday-anchored week containing `now`. Returns (monday_iso,
    sunday_iso, day_index) where day_index is 0..6 (Mon..the `now` weekday),
    i.e. how many days into the week (inclusive of today) we are: Mon→1 … Sun→7
    is returned as `elapsed_days`. None on junk input."""
    ymd = _ymd(now)
    if not ymd:
        return None
    wd = _weekday(ymd)              # 0=Mon
    o = _ordinal(ymd)
    monday = _from_ordinal(o - wd)
    sunday = _from_ordinal(o - wd + 6)
    return (monday, sunday, wd)


def _in_week(date_str, monday, sunday):
    d = _ymd(date_str)
    if not d:
        return False
    o = _ordinal(d)
    return _ordinal(_ymd(monday)) <= o <= _ordinal(_ymd(sunday))


# ===========================================================================
# weekly summary + streak
# ===========================================================================

def weekly_summary(workouts, now):
    """This week's (Mon-anchored) workout rollup from a passed-in `now`.
    Returns {week_start, week_end, days, count, minutes, calories, by_type,
    empty}. `days` is the number of DISTINCT dates with ≥1 workout this week.
    calories sums only the entries that carried one (honest: unlogged calories
    are not invented)."""
    wb = week_bounds(now)
    if not wb:
        return {"week_start": None, "week_end": None, "days": 0, "count": 0,
                "minutes": 0, "calories": 0, "by_type": {}, "empty": True}
    monday, sunday, _ = wb
    count = minutes = calories = 0
    dates = set()
    by_type = {}
    for w in workouts:
        if not _in_week(w.get("date"), monday, sunday):
            continue
        count += 1
        minutes += _int(w.get("minutes"))
        cal = _num(w.get("calories"))
        if cal is not None:
            calories += int(cal)
        dates.add(str(w.get("date")))
        t = w.get("type") or "other"
        by_type[t] = by_type.get(t, 0) + 1
    return {
        "week_start": monday,
        "week_end": sunday,
        "days": len(dates),
        "count": count,
        "minutes": minutes,
        "calories": calories,
        "by_type": by_type,
        "empty": count == 0,
    }


def streak(workouts, now):
    """Consecutive-day streak of workouts, counted BACKWARDS from the most
    recent workout day — but only "current" if that most recent day is `now` or
    `now`-1 (so a streak that ended days ago is honestly 0 as of today).
    Deterministic. Returns an int."""
    days = sorted({w.get("date") for w in workouts
                   if _ymd(w.get("date"))}, reverse=True)
    if not days:
        return 0
    gap = days_between(days[0], now)
    if gap is None or gap < 0 or gap > 1:
        # latest workout is in the future, or more than a day stale → no current
        # streak.
        return 0
    run = 1
    for i in range(1, len(days)):
        if days_between(days[i], days[i - 1]) == 1:
            run += 1
        else:
            break
    return run


# ===========================================================================
# progress vs goal (deterministic, pro-rated, honest status)
# ===========================================================================

def _pro_rated_status(actual, expected, target, lang):
    """Shared status classifier. `expected` is the pro-rated amount due by now;
    `target` the full-period goal. Returns (status, label)."""
    if target is not None and target > 0 and actual >= target:
        status = "reached"
    elif expected <= 0:
        status = "on_track"           # period just begun, nothing due yet
    elif actual >= expected * 1.1:
        status = "ahead"
    elif actual >= expected * 0.9:
        status = "on_track"
    else:
        status = "behind"
    return status, _status_label(status, lang)


def _status_label(status, lang):
    return {
        "not_started": pick(lang, "এখনো শুরু হয়নি", "Not started yet"),
        "behind": pick(lang, "একটু পিছিয়ে", "A little behind"),
        "on_track": pick(lang, "ঠিক পথে", "On track"),
        "ahead": pick(lang, "দারুণ এগিয়ে", "Ahead — great going"),
        "reached": pick(lang, "লক্ষ্য পূরণ!", "Goal reached!"),
    }[status]


def progress(goal, workouts, now, weighins=None, lang="bn"):
    """The full honest progress report for the active goal as of `now`.

    Common fields: {kind, kind_label, unit, target, actual, percent,
    expected, status, status_label, period, note}. Per-kind extras:
      workout_days : week_start/week_end, days (distinct workout days this week)
      steps        : today's logged steps (sum of today's workouts' steps)
      weight       : start_weight, current_weight, lost (signed), remaining

    percent is 0..100 (progress toward the full-period target), clamped. A goal
    that starts in the future (or no goal) → status 'not_started', percent 0."""
    weighins = weighins or []
    if not goal or goal.get("kind") not in VALID_KINDS:
        return _not_started(None, lang)
    kind = goal["kind"]
    start = goal.get("start_date")
    if start and (days_between(start, now) or 0) < 0:
        return _not_started(kind, lang)

    unit = goal_unit(kind, lang)
    note = {
        "bn": "এটি কোনো চিকিৎসা পরামর্শ নয় — শুধু আপনার নিজের লগ থেকে অগ্রগতি। "
              "নিজের গতিতে, আনন্দ নিয়ে চালিয়ে যান।",
        "en": "This is not medical advice — just progress from your own log. "
              "Go at your own pace and enjoy it.",
    }

    if kind == "workout_days":
        target = _num(goal.get("target")) or 0
        wk = weekly_summary(workouts, now)
        actual = wk["days"]
        wb = week_bounds(now)
        elapsed = (wb[2] + 1) if wb else 7      # Mon→1 … Sun→7
        expected = (target * elapsed / 7.0) if target > 0 else 0
        percent = _pct(actual, target)
        status, label = _pro_rated_status(actual, expected, target, lang)
        if not workouts:
            status, label = "not_started", _status_label("not_started", lang)
        return {
            "kind": kind, "kind_label": goal_kind_label(kind, lang),
            "unit": unit, "target": target, "actual": actual,
            "percent": percent, "expected": round(expected, 2),
            "status": status, "status_label": label, "period": "week",
            "week_start": wk["week_start"], "week_end": wk["week_end"],
            "days": wk["days"], "note": note,
        }

    if kind == "steps":
        target = _num(goal.get("target")) or 0
        today_steps = sum(_int(w.get("steps")) for w in workouts
                          if str(w.get("date")) == str(now))
        expected = target        # a daily goal is "due" in full by end of day
        percent = _pct(today_steps, target)
        status, label = _pro_rated_status(today_steps, target, target, lang)
        if not any(str(w.get("date")) == str(now) for w in workouts):
            status, label = "not_started", _status_label("not_started", lang)
        return {
            "kind": kind, "kind_label": goal_kind_label(kind, lang),
            "unit": unit, "target": target, "actual": today_steps,
            "percent": percent, "expected": round(expected, 2),
            "status": status, "status_label": label, "period": "day",
            "note": note,
        }

    # weight
    target = _num(goal.get("target"))
    start_w = _num(goal.get("start_weight"))
    current = _latest_weight(weighins)
    if current is None:
        current = start_w
    if target is None or start_w is None or current is None:
        return _not_started(kind, lang)
    gap = start_w - target                 # signed: + means losing, - gaining
    done_amt = start_w - current
    if abs(gap) < 1e-9:
        percent = 100
        status = "reached"
    else:
        frac = done_amt / gap              # share of the gap closed
        percent = max(0, min(100, int(round(frac * 100))))
        reached = (current <= target) if gap > 0 else (current >= target)
        status = "reached" if reached else ("on_track" if percent > 0
                                            else "behind")
    remaining = round(abs(current - target), 2)
    return {
        "kind": kind, "kind_label": goal_kind_label(kind, lang),
        "unit": unit, "target": target, "actual": current,
        "percent": percent, "expected": target,
        "status": status, "status_label": _status_label(status, lang),
        "period": "total", "start_weight": start_w, "current_weight": current,
        "lost": round(done_amt, 2), "remaining": remaining, "note": note,
    }


def _latest_weight(weighins):
    dated = [w for w in weighins if _ymd(w.get("date"))
             and _num(w.get("weight")) is not None]
    if not dated:
        return None
    latest = max(dated, key=lambda w: w.get("date"))
    return _num(latest.get("weight"))


def _pct(actual, target):
    if not target or target <= 0:
        return 0
    return max(0, min(100, int(round(actual * 100 / target))))


def _not_started(kind, lang):
    return {
        "kind": kind, "kind_label": goal_kind_label(kind, lang) if kind else "",
        "unit": goal_unit(kind, lang) if kind else "",
        "target": 0, "actual": 0, "percent": 0, "expected": 0,
        "status": "not_started", "status_label": _status_label("not_started", lang),
        "period": "", "note": {
            "bn": "একটি লক্ষ্য ঠিক করে শুরু করুন — ছোট লক্ষ্যই যথেষ্ট।",
            "en": "Set a goal to begin — a small, gentle target is plenty.",
        },
    }


# ===========================================================================
# AI coaching seam (documented, NOT built) — deterministic fallback tip
# ===========================================================================

# A fixed, non-medical, encouraging tip per status. These are NOT AI output;
# they are the honest key-free fallback the screen shows.
_TIPS = {
    "not_started": ("ছোট একটা লক্ষ্য দিয়ে শুরু করুন — সপ্তাহে ৩ দিন হাঁটাও দারুণ।",
                    "Start with a small goal — even a 3-day walking week is great."),
    "behind": ("কোনো সমস্যা নেই — আজ অল্প সময়ের একটা সহজ ব্যায়ামই যথেষ্ট।",
               "No worries — a short, easy session today is enough to get back."),
    "on_track": ("সুন্দর ছন্দে আছেন। এই ধারাটা ধরে রাখুন।",
                 "Nice rhythm. Keep this gentle pace going."),
    "ahead": ("দারুণ করছেন! নিজের শরীরের কথা শুনে বিশ্রামও নিন।",
              "Doing great! Remember to rest and listen to your body too."),
    "reached": ("অভিনন্দন, লক্ষ্য পূরণ! চাইলে নতুন একটা মৃদু লক্ষ্য দিন।",
                "Congratulations on reaching your goal! Set a new gentle one if you like."),
}


def coaching_available(has_key=False):
    """The AI-coaching seam. Returns {available, reason:{bn,en}}. available is
    True ONLY when a licensed AI key is configured (passed in by the caller);
    otherwise False with an honest reason. This module NEVER calls a model —
    the live coaching route lives outside and is wired only when a key exists."""
    if has_key:
        return {"available": True, "reason": {
            "bn": "ব্যক্তিগত কোচিং চালু আছে।",
            "en": "Personalised coaching is enabled.",
        }}
    return {"available": False, "reason": {
        "bn": "ব্যক্তিগত এআই কোচিং ঐচ্ছিক ও কি-নির্ভর; কি ছাড়াও পুরো ট্র্যাকার কাজ করে।",
        "en": "Personalised AI coaching is optional and key-gated; the full "
              "tracker works without any key.",
    }}


def fallback_tip(status, lang="bn"):
    """The deterministic, key-free, non-medical tip for a status. Honest: this
    is clearly NOT AI output — it's a fixed encouraging line the UI shows when
    coaching is unavailable."""
    bn, en = _TIPS.get(status, _TIPS["on_track"])
    return pick(lang, bn, en)


# ===========================================================================
# validation
# ===========================================================================

def validate_goal(kind, target, start_weight=None):
    errs = []
    if kind not in VALID_KINDS:
        errs.append("bad_kind")
        return errs
    t = _num(target)
    if t is None or t <= 0:
        errs.append("target_positive")
    if kind == "workout_days" and t is not None and t > 7:
        errs.append("days_max_7")
    if kind == "weight":
        sw = _num(start_weight)
        if sw is None or sw <= 0:
            errs.append("start_weight_required")
        elif t is not None and abs(sw - t) < 1e-9:
            errs.append("target_equals_start")
    return errs


def validate_workout(wtype, minutes):
    errs = []
    if not (wtype or "").strip():
        errs.append("type_required")
    m = _num(minutes)
    if m is None or m <= 0:
        errs.append("minutes_positive")
    return errs
