"""
wellness_tracker.py — pure, deterministic WATER / SLEEP / DIET tracker logic
(#71, SPEC v2.1 §10, ADVANCED). Daily wellness logging: water intake (glasses
vs a goal), sleep hours (vs a goal) and meals / diet notes. We compute today's
goal progress ("rings"), a 7-day trend and honest streaks.

This is a personal TRACKER — it is NOT medical advice. We never prescribe a
water/sleep target (the user sets their own goals, with gentle, widely-published
DEFAULTS), never diagnose, never judge a diet. A gentle "not medical advice —
consult a doctor" note is returned for the UI to show.

HARD RULES (Section-21 "advanced" discipline):

  * NO DB, NO AI, NO I/O, NO live clock. Pure functions: dict/list in, plain
    data out. "today"/"now" is always PASSED IN so the Dart mirror and the
    tests pin identical output.
  * DETERMINISTIC progress / trend / streak math. One log per day keyed by its
    ISO date; if duplicates exist for a day we fold them deterministically
    (water/sleep summed, latest non-empty diet note wins by id then order).
  * HONEST. A day with no log is a genuine gap (counted as a missed day, shown
    as empty) — never back-filled or guessed. Progress is clamped to [0,1] for
    the ring but the raw ratio is also returned so "over goal" is visible.
  * Human-facing copy returned as bilingual {"bn","en"} pairs — ZERO Bangla in
    .dart.

Row shape (one flexible per-user JSON collection, path 'wellness/logs'):
    {id, date (YYYY-MM-DD), water (glasses:int), sleep (hours:float),
     diet (free text), water_goal (int, optional), sleep_goal (float, optional)}

Run self-tests (no DB):
    python3 -c "import core.logic.wellness_tracker_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

# Gentle, widely-published DEFAULT goals — NOT a medical prescription; the user
# can override per-log. 8 glasses (~2 L) of water and 8 hours of sleep are the
# common lay guidance, exposed as constants so the Dart mirror pins them.
DEFAULT_WATER_GOAL = 8       # glasses
DEFAULT_SLEEP_GOAL = 8.0     # hours
TREND_DAYS = 7               # how many days the trend spans (inclusive of today)


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# coercion helpers (pure)
# ---------------------------------------------------------------------------

def _parse_date(v):
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip().split("T")[0].split(" ")[0]
    try:
        return date.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def _num(v, default=0.0):
    """Coerce to a non-negative float; junk/negative -> default. Deterministic."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    return f if f >= 0 else default


def _int(v, default=0):
    return int(round(_num(v, default)))


# ---------------------------------------------------------------------------
# fold rows into one record per day
# ---------------------------------------------------------------------------

def fold_by_day(rows):
    """Collapse raw rows into {iso_date: day_record}. Water & sleep are SUMMED
    across same-day rows (so two "I drank 3 glasses" entries = 6); the diet note
    and goals take the last non-empty value in (id, input-order) order. Rows
    with an unparsable date are skipped (honest — we don't guess a day)."""
    days = {}
    # Stable order: by id if present, else by original index — deterministic.
    indexed = list(enumerate(rows or []))
    indexed.sort(key=lambda p: (
        p[1].get("id") if isinstance(p[1].get("id"), int) else 10**12, p[0]))
    for _, r in indexed:
        d = _parse_date(r.get("date"))
        if d is None:
            continue
        key = d.isoformat()
        rec = days.get(key)
        if rec is None:
            rec = {"date": key, "water": 0, "sleep": 0.0, "diet": "",
                   "water_goal": DEFAULT_WATER_GOAL,
                   "sleep_goal": DEFAULT_SLEEP_GOAL, "ids": []}
            days[key] = rec
        rec["water"] += _int(r.get("water"), 0)
        rec["sleep"] += _num(r.get("sleep"), 0.0)
        diet = str(r.get("diet") or "").strip()
        if diet:
            rec["diet"] = diet
        if r.get("water_goal") not in (None, ""):
            rec["water_goal"] = max(1, _int(r.get("water_goal"),
                                            DEFAULT_WATER_GOAL))
        if r.get("sleep_goal") not in (None, ""):
            rec["sleep_goal"] = max(1.0, _num(r.get("sleep_goal"),
                                              DEFAULT_SLEEP_GOAL))
        if isinstance(r.get("id"), int):
            rec["ids"].append(r["id"])
    return days


# ---------------------------------------------------------------------------
# progress math (pure, clamped ring + raw ratio)
# ---------------------------------------------------------------------------

def _ratio(value, goal):
    """raw = value/goal (0 if goal<=0); ring = clamped to [0,1]; met = raw>=1."""
    g = goal if goal and goal > 0 else 0
    raw = (value / g) if g else 0.0
    ring = 0.0 if raw < 0 else (1.0 if raw > 1 else raw)
    return {"value": value, "goal": g, "raw": round(raw, 4),
            "ring": round(ring, 4), "met": raw >= 1.0}


def day_progress(day_record):
    """A folded day_record -> {water, sleep, diet, has_diet} progress block."""
    water = _ratio(day_record.get("water", 0),
                   day_record.get("water_goal", DEFAULT_WATER_GOAL))
    sleep = _ratio(day_record.get("sleep", 0.0),
                   day_record.get("sleep_goal", DEFAULT_SLEEP_GOAL))
    diet = str(day_record.get("diet") or "").strip()
    return {"date": day_record.get("date"), "water": water, "sleep": sleep,
            "diet": diet, "has_diet": bool(diet)}


def _empty_day(iso):
    return {"date": iso, "water": 0, "sleep": 0.0, "diet": "",
            "water_goal": DEFAULT_WATER_GOAL,
            "sleep_goal": DEFAULT_SLEEP_GOAL, "ids": []}


def today_view(rows, today):
    """Today's progress rings from a PASSED-IN `today`. An absent log yields an
    honest all-zero day (not a guess)."""
    t = _parse_date(today)
    days = fold_by_day(rows)
    rec = days.get(t.isoformat()) if t else None
    if rec is None:
        rec = _empty_day(t.isoformat() if t else "")
    return {**day_progress(rec), "logged": t is not None and
            t.isoformat() in days}


# ---------------------------------------------------------------------------
# 7-day trend (pure, from passed-in today)
# ---------------------------------------------------------------------------

def trend(rows, today, days=TREND_DAYS):
    """A deterministic trend of the last `days` days ending at `today`
    (oldest-first). Each entry carries the day's water/sleep progress and a
    `logged` flag. Missing days appear as honest empty entries. Also returns
    averages over the LOGGED days only (so gaps don't silently deflate them)."""
    t = _parse_date(today)
    folded = fold_by_day(rows)
    series = []
    if t is None:
        return {"days": days, "series": [], "avg_water": 0.0,
                "avg_sleep": 0.0, "logged_days": 0,
                "water_goal_days": 0, "sleep_goal_days": 0}
    start = t - timedelta(days=days - 1)
    logged = 0
    sum_water = 0
    sum_sleep = 0.0
    water_goal_days = 0
    sleep_goal_days = 0
    for i in range(days):
        d = start + timedelta(days=i)
        iso = d.isoformat()
        rec = folded.get(iso)
        is_logged = rec is not None
        p = day_progress(rec if rec else _empty_day(iso))
        p["logged"] = is_logged
        series.append(p)
        if is_logged:
            logged += 1
            sum_water += rec["water"]
            sum_sleep += rec["sleep"]
            if p["water"]["met"]:
                water_goal_days += 1
            if p["sleep"]["met"]:
                sleep_goal_days += 1
    return {
        "days": days,
        "series": series,
        "avg_water": round(sum_water / logged, 2) if logged else 0.0,
        "avg_sleep": round(sum_sleep / logged, 2) if logged else 0.0,
        "logged_days": logged,
        "water_goal_days": water_goal_days,
        "sleep_goal_days": sleep_goal_days,
    }


# ---------------------------------------------------------------------------
# streaks (honest — a day counts only if its goal was actually met)
# ---------------------------------------------------------------------------

def _streak(folded, today, metric):
    """Current consecutive run (ending today or yesterday) of days whose
    `metric` goal was met, plus the best run seen anywhere in the logged data.
    `metric` is 'water' or 'sleep'. Pure; a missing day breaks the run."""
    t = _parse_date(today)
    if t is None or not folded:
        return {"current": 0, "best": 0}

    def met_on(d):
        rec = folded.get(d.isoformat())
        if rec is None:
            return False
        return day_progress(rec)[metric]["met"]

    # current: walk backwards from today; allow starting at yesterday if today
    # isn't logged yet (so a not-yet-finished today doesn't zero the streak).
    cur = 0
    anchor = t if met_on(t) else t - timedelta(days=1)
    d = anchor
    while met_on(d):
        cur += 1
        d -= timedelta(days=1)

    # best: scan all logged dates in order for the longest consecutive met-run.
    best = 0
    run = 0
    all_dates = sorted(date.fromisoformat(k) for k in folded)
    prev = None
    for cd in all_dates:
        is_met = day_progress(folded[cd.isoformat()])[metric]["met"]
        if not is_met:
            run = 0
            prev = cd
            continue
        if prev is not None and (cd - prev).days == 1 and run > 0:
            run += 1
        else:
            run = 1
        best = max(best, run)
        prev = cd
    return {"current": cur, "best": best}


def streaks(rows, today):
    """Water & sleep streaks (current + best) from a PASSED-IN `today`."""
    folded = fold_by_day(rows)
    return {
        "water": _streak(folded, today, "water"),
        "sleep": _streak(folded, today, "sleep"),
    }


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate(date_value, water=None, sleep=None):
    """Return machine error keys for a proposed log (empty = ok). A date is
    required and must parse; water/sleep, if given, must be non-negative
    numbers within sane caps (guards fat-finger input, not a medical limit)."""
    errs = []
    if _parse_date(date_value) is None:
        errs.append("date_required")
    if water not in (None, ""):
        try:
            w = float(water)
            if w < 0 or w > 60:
                errs.append("bad_water")
        except (TypeError, ValueError):
            errs.append("bad_water")
    if sleep not in (None, ""):
        try:
            s = float(sleep)
            if s < 0 or s > 24:
                errs.append("bad_sleep")
        except (TypeError, ValueError):
            errs.append("bad_sleep")
    return errs


# ---------------------------------------------------------------------------
# honest disclaimer (bilingual, returned — never a Bangla literal in .dart)
# ---------------------------------------------------------------------------

def disclaimer():
    return {
        "bn": "এটি একটি ব্যক্তিগত ট্র্যাকার — কোনো চিকিৎসা পরামর্শ নয়। "
              "লক্ষ্য আপনার নিজের; প্রয়োজনে ডাক্তারের সঙ্গে কথা বলুন।",
        "en": "This is a personal tracker — not medical advice. The goals are "
              "your own; please consult a doctor if needed.",
    }
