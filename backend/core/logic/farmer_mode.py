"""
farmer_mode.py — the deterministic, key-free engine behind Assisto's
FARMER / VILLAGE MODE (SPEC v2.1 §20 #199, ADVANCED).

A simple, large-touch mode for rural users built out of three honest, offline
pieces:

  1. FARM LEDGER — for each crop/livestock record the farmer enters planting /
     harvest dates, input costs (৳) and sale income; we compute profit, margin,
     cost/income totals and a per-record status (planned / growing / harvested /
     sold).  Pure arithmetic — no invented numbers.

  2. SEASONAL CROP CALENDAR — "which crop, when" derived DETERMINISTICALLY from
     a small, hand-curated table of the three Bangladeshi cropping seasons
     (Rabi / Kharif-1 / Kharif-2) and the common crops in each.  This is NOT a
     live-weather or agronomy service; it is a fixed almanac the farmer can read
     offline.  Every entry is generic, widely-published planting guidance — we
     never claim a yield, a price, or a guarantee.

  3. LIVESTOCK TRACKING — count per animal type and a VACCINATION-DUE check
     computed from a passed-in `now` (never the wall clock) against the animal's
     last-vaccination date and a standard interval.  The reminder itself is a
     SEAM: this module only tells you whether a shot is DUE / SOON / OK and how
     many days away; delivering the reminder (local notification / IVR) is the
     app/integrator's job and is documented, not faked.

This module is PURE, exactly like the other §20 engines: no Django, no DB, no
network, no AI, and NO wall-clock — callers pass `now` (a datetime) so every
result is reproducible and the on-device Dart mirror + the tests can pin it.

Dates are ISO `YYYY-MM-DD` strings (what the generic collection stores).
Money is integer-or-float Taka; we never fabricate a price the farmer did not
enter.  Text the UI shows is localised by key in Dart — this engine only ever
returns machine tokens (season codes, status codes, crop keys), never prose.
"""

from datetime import datetime, date, timedelta

# --------------------------------------------------------------------------- #
# Cropping seasons (Bangladesh almanac).  Months are 1..12.  A crop may appear
# in more than one season.  These are the fixed, widely-published season
# windows; they are a reading almanac, not agronomy advice.
# --------------------------------------------------------------------------- #

SEASONS = {
    # code: {months: inclusive month set, crops: [crop keys], sow, harvest}
    "rabi": {
        # winter / dry season — sown Oct–Nov, harvested Feb–Apr
        "months": (10, 11, 12, 1, 2, 3),
        "sow_months": (10, 11),
        "harvest_months": (2, 3, 4),
        "crops": ["boro_rice", "wheat", "potato", "mustard", "lentil",
                  "onion", "garlic", "maize", "tomato", "cabbage"],
    },
    "kharif1": {
        # pre-monsoon — sown Mar–Apr, harvested Jun–Jul
        "months": (3, 4, 5, 6, 7),
        "sow_months": (3, 4),
        "harvest_months": (6, 7),
        "crops": ["aus_rice", "jute", "chilli", "aubergine", "cucumber",
                  "bitter_gourd", "okra"],
    },
    "kharif2": {
        # monsoon — sown Jul–Aug, harvested Nov–Dec
        "months": (7, 8, 9, 10, 11, 12),
        "sow_months": (7, 8),
        "harvest_months": (11, 12),
        "crops": ["aman_rice", "pumpkin", "spinach", "radish",
                  "cauliflower", "bean"],
    },
}
SEASON_CODES = tuple(SEASONS.keys())

# Every crop key the calendar can emit (stable tokens → Dart localises labels).
CROP_KEYS = tuple(sorted({c for s in SEASONS.values() for c in s["crops"]}))

ANIMAL_KEYS = ("cow", "goat", "sheep", "buffalo", "chicken", "duck")

# Record lifecycle status tokens.
STATUS_PLANNED = "planned"
STATUS_GROWING = "growing"
STATUS_HARVESTED = "harvested"
STATUS_SOLD = "sold"

# Vaccination-due windows (days).  "soon" = within SOON_DAYS of due.
VACC_INTERVAL_DAYS = 180      # generic default 6-monthly booster
SOON_DAYS = 14

VACC_DUE = "due"
VACC_SOON = "soon"
VACC_OK = "ok"
VACC_UNKNOWN = "unknown"      # no last-vaccination date recorded


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #

def _to_date(value):
    """Parse an ISO date string / date / datetime → date, or None."""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return datetime.strptime(str(value)[:10], "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None


def _num(value):
    """Coerce a money/count value to a number; blank / bad → 0."""
    if value is None or value == "":
        return 0
    try:
        n = float(value)
    except (ValueError, TypeError):
        return 0
    # keep ints tidy
    return int(n) if n == int(n) else round(n, 2)


# --------------------------------------------------------------------------- #
# 1) FARM LEDGER
# --------------------------------------------------------------------------- #

def record_status(row, now=None):
    """Deterministic lifecycle status for one crop/livestock ledger row.

    Priority: SOLD (income recorded) > HARVESTED (harvest date passed) >
    GROWING (planted, harvest still ahead) > PLANNED (no planting date yet).
    `now` drives "has the date passed" — never the wall clock.
    """
    now = _to_date(now) or date.today()
    income = _num(row.get("income"))
    planted = _to_date(row.get("planted"))
    harvest = _to_date(row.get("harvest"))
    if income > 0:
        return STATUS_SOLD
    if harvest is not None and harvest <= now:
        return STATUS_HARVESTED
    if planted is not None:
        return STATUS_GROWING
    return STATUS_PLANNED


def record_profit(row):
    """Profit math for one ledger row: income − cost.  Pure arithmetic over the
    numbers the farmer entered; returns a dict (never invents a price)."""
    cost = _num(row.get("cost"))
    income = _num(row.get("income"))
    profit = round(income - cost, 2)
    profit = int(profit) if profit == int(profit) else profit
    # margin only meaningful once there is income
    margin = None
    if income > 0:
        margin = round(profit / income * 100, 1)
    return {
        "cost": cost,
        "income": income,
        "profit": profit,
        "margin_pct": margin,          # None until sold
        "profitable": income > 0 and profit > 0,
    }


def ledger_summary(rows, now=None):
    """Aggregate a list of ledger rows into farm-wide totals + per-status
    counts.  Deterministic; blanks are treated as 0 so partial data is honest
    rather than crashing."""
    rows = rows or []
    total_cost = 0.0
    total_income = 0.0
    counts = {STATUS_PLANNED: 0, STATUS_GROWING: 0,
              STATUS_HARVESTED: 0, STATUS_SOLD: 0}
    for row in rows:
        p = record_profit(row)
        total_cost += p["cost"]
        total_income += p["income"]
        counts[record_status(row, now=now)] += 1
    total_cost = int(total_cost) if total_cost == int(total_cost) else round(total_cost, 2)
    total_income = int(total_income) if total_income == int(total_income) else round(total_income, 2)
    net = round(total_income - total_cost, 2)
    net = int(net) if net == int(net) else net
    return {
        "count": len(rows),
        "total_cost": total_cost,
        "total_income": total_income,
        "net_profit": net,
        "profitable": total_income > 0 and net > 0,
        "status_counts": counts,
    }


# --------------------------------------------------------------------------- #
# 2) SEASONAL CROP CALENDAR
# --------------------------------------------------------------------------- #

def season_for_month(month):
    """The PRIMARY season code for a calendar month (1..12).  A month can sit in
    more than one season window; we return the season whose SOWING window the
    month falls in first, else the first season that simply contains it.  This
    is a fixed almanac lookup, fully deterministic."""
    month = int(month)
    if not 1 <= month <= 12:
        raise ValueError("month 1..12")
    # prefer a season actively sowing this month
    for code in SEASON_CODES:
        if month in SEASONS[code]["sow_months"]:
            return code
    for code in SEASON_CODES:
        if month in SEASONS[code]["months"]:
            return code
    return "rabi"  # calendar covers all months; defensive fallback


def season_now(now=None):
    """Season code for the passed-in `now` (never the wall clock)."""
    d = _to_date(now) or date.today()
    return season_for_month(d.month)


def crops_for_season(season_code):
    """The curated crop-key list for a season.  Unknown code → empty list
    (honest "no data" rather than a guess)."""
    s = SEASONS.get(season_code)
    return list(s["crops"]) if s else []


def crop_calendar(now=None):
    """A deterministic almanac view for the farmer's current month: the active
    season, its sowing / harvest month windows, and the crops typically grown.
    No weather, no live data, no AI — a fixed reading table."""
    code = season_now(now)
    s = SEASONS[code]
    return {
        "season": code,
        "sow_months": list(s["sow_months"]),
        "harvest_months": list(s["harvest_months"]),
        "crops": list(s["crops"]),
        # all three seasons so the UI can show the full year, current flagged
        "all_seasons": [
            {"season": c,
             "sow_months": list(SEASONS[c]["sow_months"]),
             "harvest_months": list(SEASONS[c]["harvest_months"]),
             "crops": list(SEASONS[c]["crops"]),
             "current": c == code}
            for c in SEASON_CODES
        ],
    }


# --------------------------------------------------------------------------- #
# 3) LIVESTOCK TRACKING + vaccination-due (reminder SEAM)
# --------------------------------------------------------------------------- #

def vaccination_status(last_vaccinated, now=None, interval_days=VACC_INTERVAL_DAYS):
    """Is a booster DUE / SOON / OK for one animal, from the LAST vaccination
    date and a standard interval, measured against the passed-in `now`.

    Returns {status, due_date, days_until}.  `days_until` is negative/zero when
    overdue.  No last date → UNKNOWN (honest; we do not pretend a schedule).

    This is the REMINDER SEAM: the engine decides *whether* a shot is due; the
    app/integrator decides *how* to remind (local notification now; SMS/IVR when
    an owner key is present).  Nothing here sends anything.
    """
    now = _to_date(now) or date.today()
    last = _to_date(last_vaccinated)
    if last is None:
        return {"status": VACC_UNKNOWN, "due_date": None, "days_until": None}
    due = last + timedelta(days=int(interval_days))
    days_until = (due - now).days
    if days_until <= 0:
        status = VACC_DUE
    elif days_until <= SOON_DAYS:
        status = VACC_SOON
    else:
        status = VACC_OK
    return {
        "status": status,
        "due_date": due.isoformat(),
        "days_until": days_until,
    }


def livestock_summary(rows, now=None):
    """Aggregate livestock rows into total head, per-type counts, and how many
    animals need attention (vaccination due/soon).  Deterministic from `now`."""
    rows = rows or []
    total_head = 0
    by_type = {}
    due = 0
    soon = 0
    unknown = 0
    for row in rows:
        count = int(_num(row.get("count")) or 0)
        if count < 0:
            count = 0
        total_head += count
        atype = str(row.get("animal") or "").strip() or "other"
        by_type[atype] = by_type.get(atype, 0) + count
        v = vaccination_status(row.get("last_vaccinated"), now=now)
        if v["status"] == VACC_DUE:
            due += 1
        elif v["status"] == VACC_SOON:
            soon += 1
        elif v["status"] == VACC_UNKNOWN:
            unknown += 1
    return {
        "animals": len(rows),
        "total_head": total_head,
        "by_type": by_type,
        "vacc_due": due,
        "vacc_soon": soon,
        "vacc_unknown": unknown,
    }


# --------------------------------------------------------------------------- #
# validation (mirrors the Dart form guards)
# --------------------------------------------------------------------------- #

def validate_record(row):
    """Return a list of problem codes for a crop ledger row (empty = ok).
    Honest guards only; blanks are allowed (a planned record may have no numbers
    yet)."""
    problems = []
    if not str(row.get("name") or "").strip():
        problems.append("name_required")
    if _num(row.get("cost")) < 0:
        problems.append("cost_negative")
    if _num(row.get("income")) < 0:
        problems.append("income_negative")
    planted = _to_date(row.get("planted"))
    harvest = _to_date(row.get("harvest"))
    if planted and harvest and harvest < planted:
        problems.append("harvest_before_planting")
    return problems


def validate_livestock(row):
    problems = []
    if not str(row.get("animal") or "").strip():
        problems.append("animal_required")
    if _num(row.get("count")) < 0:
        problems.append("count_negative")
    return problems
