"""
savings_challenge.py — pure, deterministic SAVINGS CHALLENGE engine
(#171, SPEC v2.1). A gamified savings tracker for the ordinary saver: pick a
challenge, and the engine generates a fixed DEPOSIT SCHEDULE; you then log the
deposits you actually made and it tells you — honestly — your progress %, your
streak, the projected final amount, and whether you are BEHIND / ON-TRACK /
AHEAD of plan as of a passed-in date.

Three challenge types (all deterministic schedules):

  * "week52"  — the classic 52-week challenge: week 1 you save `base`, week 2
    `2*base`, … week N `N*base`. A full year of rising deposits. (base default
    ৳50 → ৳50, ৳100, … ৳2600; total ৳68,900.)
  * "fixed"   — a fixed amount every period (daily/weekly/monthly) for N periods.
  * "roundup" — a round-up jar: you log round-up deposits freely; the "plan" is a
    gentle per-day target (`base`) so progress/status stay honest without ever
    fabricating round-ups the user didn't make.

HARD RULES:
  * ALL MONEY IS INTEGER POISHA. The schedule is built from integer poisha; the
    projected final is exact. The only division (progress %) is display-only and
    reported as a rounded integer percent plus the exact poisha it came from.
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING. Returns plain dicts.
  * TIME IS PASSED IN. "How many periods should have elapsed by now" takes an
    explicit `now` date string; no hidden clock. Schedule dates are derived from
    the plan's own `start_date`, not today.
  * HONEST STATUS. Behind/on-track/ahead compares actual deposits to the amount
    the plan EXPECTED by `now` — never to the grand total — so a saver two weeks
    in is not told they are "98% behind". If the challenge hasn't started yet, or
    has no schedule, we say so plainly rather than inventing a status.
  * Bilingual {"bn","en"} copy; ZERO Bangla in .dart.

Row shapes the view layer stores (see integration note):
  plan    : {id, name, kind, base, periods, period, start_date}
  deposit : {id, plan, date, amount}        # date 'YYYY-MM-DD', amount taka-ish

Run self-tests (no DB):
    python3 -c "import core.logic.savings_challenge_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


KINDS = [
    ("week52", "৫২-সপ্তাহ চ্যালেঞ্জ", "52-week challenge"),
    ("fixed", "নির্দিষ্ট জমা", "Fixed deposit"),
    ("roundup", "রাউন্ড-আপ জার", "Round-up jar"),
]
PERIODS = [
    ("daily", "প্রতিদিন", "Daily"),
    ("weekly", "প্রতি সপ্তাহে", "Weekly"),
    ("monthly", "প্রতি মাসে", "Monthly"),
]
_PERIOD_DAYS = {"daily": 1, "weekly": 7, "monthly": 30}


def kind_label(value, lang="bn"):
    for v, bn, en in KINDS:
        if v == value:
            return pick(lang, bn, en)
    return value or ""


def period_label(value, lang="bn"):
    for v, bn, en in PERIODS:
        if v == value:
            return pick(lang, bn, en)
    return value or ""


# ---------------------------------------------------------------------------
# poisha <-> taka — mirrors mess_accounting / famacct_engine
# ---------------------------------------------------------------------------

def to_poisha(v):
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_poisha(p):
    p = int(round(p))
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# date helpers — proleptic Gregorian ordinal, NO live clock
# ---------------------------------------------------------------------------

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
    """Days since 0001-01-01 (deterministic; no datetime import needed)."""
    y, m, d = ymd
    days = 0
    for yy in range(1, y):
        days += 366 if _is_leap(yy) else 365
    for mm in range(1, m):
        days += _MDAYS[mm - 1] + (1 if (mm == 2 and _is_leap(y)) else 0)
    return days + d


def _add_days(ymd, n):
    """Return a 'YYYY-MM-DD' string n days after ymd tuple."""
    o = _ordinal(ymd) + n
    # invert ordinal -> ymd
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
    """b - a in days (ints). None if either unparseable."""
    ya, yb = _ymd(a), _ymd(b)
    if not ya or not yb:
        return None
    return _ordinal(yb) - _ordinal(ya)


# ---------------------------------------------------------------------------
# schedule generation (deterministic from the plan + its own start_date)
# ---------------------------------------------------------------------------

def schedule(plan):
    """The deposit schedule for a plan — a list of
        {index (1-based), date, target (poisha), cumulative (poisha)}
    derived ONLY from the plan (never from today), so it is stable.

    * week52 : 52 rising weekly targets base, 2*base, … 52*base.
    * fixed  : `periods` equal targets of `base`, one per period.
    * roundup: an open jar — no fixed schedule; returns [] (progress uses a
      gentle per-day target instead; see progress())."""
    kind = plan.get("kind", "week52")
    base = to_poisha(plan.get("base"))
    start = _ymd(plan.get("start_date"))
    period = plan.get("period", "weekly")
    if kind == "roundup":
        return []
    if kind == "week52":
        n, step, per = 52, _PERIOD_DAYS["weekly"], "weekly"
        if base <= 0:
            base = to_poisha("50")  # the classic ৳50 base
        rows, cum = [], 0
        for i in range(1, n + 1):
            tgt = base * i
            cum += tgt
            date = _add_days(start, (i - 1) * step) if start else None
            rows.append({"index": i, "date": date, "target": tgt,
                         "cumulative": cum})
        return rows
    # fixed
    n = _int(plan.get("periods"), 0)
    if n <= 0 or base <= 0:
        return []
    step = _PERIOD_DAYS.get(period, 7)
    rows, cum = [], 0
    for i in range(1, n + 1):
        cum += base
        date = _add_days(start, (i - 1) * step) if start else None
        rows.append({"index": i, "target": base, "date": date,
                     "cumulative": cum})
    return rows


def _int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def plan_total(plan):
    """The grand total the plan aims for, in INTEGER poisha (exact)."""
    kind = plan.get("kind", "week52")
    if kind == "roundup":
        return 0  # open-ended: no fixed goal
    sch = schedule(plan)
    return sch[-1]["cumulative"] if sch else 0


# ---------------------------------------------------------------------------
# progress / streak / status from actual deposits
# ---------------------------------------------------------------------------

def deposits_total(deposits):
    return sum(to_poisha(d.get("amount")) for d in deposits)


def expected_by(plan, now):
    """How much the plan EXPECTED to be saved by `now` (poisha). For week52 /
    fixed it's the cumulative target of every scheduled period whose date has
    arrived on or before `now`. For roundup it's a gentle base-per-day target.
    Returns (expected_poisha, elapsed_periods). Honest: 0 before start."""
    kind = plan.get("kind", "week52")
    start = _ymd(plan.get("start_date"))
    if kind == "roundup":
        base = to_poisha(plan.get("base"))
        if not start or base <= 0:
            return (0, 0)
        d = days_between(plan.get("start_date"), now)
        if d is None or d < 0:
            return (0, 0)
        elapsed = d + 1  # inclusive of the start day
        return (base * elapsed, elapsed)
    sch = schedule(plan)
    if not sch:
        return (0, 0)
    if not start:
        return (0, 0)
    elapsed = 0
    expected = 0
    for row in sch:
        if row["date"] is not None:
            dd = days_between(row["date"], now)
            if dd is None or dd < 0:
                break  # this period hasn't arrived yet
        elapsed += 1
        expected = row["cumulative"]
    return (expected, elapsed)


def streak(plan, deposits):
    """Current run of consecutive scheduled periods (newest backwards) that were
    met — a deposit on-or-after that period's date covering its cumulative
    target. Deterministic, counts from the latest arrived period. For roundup
    (no schedule) the streak is the run of consecutive calendar days ending at
    the most recent deposit day that each had at least one deposit."""
    sch = schedule(plan)
    if plan.get("kind") == "roundup" or not sch:
        return _roundup_streak(deposits)
    total = deposits_total(deposits)
    run = 0
    # Walk periods from last to first; a period counts if cumulative deposits
    # already cover that period's cumulative target.
    for row in reversed(sch):
        if total >= row["cumulative"]:
            # every earlier period is also covered (cumulative monotonic) -> the
            # streak is the count of covered periods from the start.
            run = row["index"]
            break
    return run


def _roundup_streak(deposits):
    days = sorted({d.get("date") for d in deposits
                   if _ymd(d.get("date")) and to_poisha(d.get("amount")) > 0},
                  reverse=True)
    if not days:
        return 0
    run = 1
    for i in range(1, len(days)):
        if days_between(days[i], days[i - 1]) == 1:
            run += 1
        else:
            break
    return run


def progress(plan, deposits, now, lang="bn"):
    """The full honest progress report. Returns:

        {name, kind, kind_label,
         saved, saved_display,            # actual deposits total (poisha)
         goal, goal_display,             # plan grand total (0 => open-ended)
         percent,                        # saved/goal, 0..100 int (None if open)
         expected, expected_display,     # what plan expected by `now`
         elapsed_periods, total_periods,
         ahead_by, ahead_by_display,     # saved - expected (signed)
         projected, projected_display,   # exact projected final amount
         streak,                         # consecutive periods/days met
         status: 'not_started'|'behind'|'on_track'|'ahead'|'complete',
         status_label, note: {bn,en}}

    PROJECTED FINAL: if a goal exists and the user is keeping their current pace
    (saved / elapsed periods × total periods), the projected end amount — capped
    honestly at the goal for a finished plan, never inflated past it for a
    not-yet-finished one. With no elapsed period we don't guess: projected =
    saved."""
    kind = plan.get("kind", "week52")
    saved = deposits_total(deposits)
    goal = plan_total(plan)
    sch = schedule(plan)
    total_periods = len(sch) if sch else (
        _int(plan.get("periods")) if kind == "fixed" else 0)
    expected, elapsed = expected_by(plan, now)
    ahead_by = saved - expected

    percent = None
    if goal > 0:
        percent = max(0, min(100, int(round(saved * 100 / goal))))

    # projected final at current pace
    if goal > 0 and elapsed > 0 and total_periods > 0:
        pace = saved / elapsed
        proj = int(round(pace * total_periods))
        proj = min(proj, goal) if saved < goal else saved
    else:
        proj = saved

    # status
    start = _ymd(plan.get("start_date"))
    if not start or (days_between(plan.get("start_date"), now) or -1) < 0:
        status = "not_started"
    elif goal > 0 and saved >= goal:
        status = "complete"
    elif expected <= 0:
        status = "on_track"  # started, nothing expected yet -> fine
    elif ahead_by >= 0:
        # within one period's slack of plan counts as on_track vs ahead
        one = (sch[0]["target"] if sch else to_poisha(plan.get("base")))
        status = "ahead" if ahead_by > one else "on_track"
    else:
        status = "behind"

    status_label = {
        "not_started": pick(lang, "এখনো শুরু হয়নি", "Not started yet"),
        "behind": pick(lang, "পরিকল্পনার পিছনে", "Behind plan"),
        "on_track": pick(lang, "ঠিক পথে", "On track"),
        "ahead": pick(lang, "পরিকল্পনার আগে", "Ahead of plan"),
        "complete": pick(lang, "লক্ষ্য পূর্ণ!", "Goal reached!"),
    }[status]

    return {
        "name": plan.get("name", ""),
        "kind": kind,
        "kind_label": kind_label(kind, lang),
        "saved": saved,
        "saved_display": fmt_poisha(saved),
        "goal": goal,
        "goal_display": fmt_poisha(goal),
        "percent": percent,
        "expected": expected,
        "expected_display": fmt_poisha(expected),
        "elapsed_periods": elapsed,
        "total_periods": total_periods,
        "ahead_by": ahead_by,
        "ahead_by_display": fmt_poisha(ahead_by),
        "projected": proj,
        "projected_display": fmt_poisha(proj),
        "streak": streak(plan, deposits),
        "status": status,
        "status_label": status_label,
        "note": {
            "bn": "সব হিসাব আপনার জমা থেকে — অ্যাপ কোনো টাকা রাখে না, শুধু "
                  "অগ্রগতি দেখায়।",
            "en": "Computed from your own deposits — the app holds no money, it "
                  "only shows your progress.",
        },
    }


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_plan(name, kind, base, periods):
    problems = []
    if not (name or "").strip():
        problems.append("name_required")
    if kind not in ("week52", "fixed", "roundup"):
        problems.append("bad_kind")
    if kind in ("week52", "fixed", "roundup") and to_poisha(base) <= 0:
        problems.append("base_required")
    if kind == "fixed" and _int(periods) <= 0:
        problems.append("periods_required")
    return problems


def validate_deposit(amount):
    return [] if to_poisha(amount) > 0 else ["amount_required"]
