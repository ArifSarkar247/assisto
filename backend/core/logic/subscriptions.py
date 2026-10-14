"""
subscriptions.py — pure recurring-subscription analytics for Assisto.

No Django, no DB, no network, no AI — deterministic stdlib only. The HTTP layer
hands this module a plain list of subscription dicts (the shape the list endpoint
returns, optionally enriched with the client-side metadata documented in
.phaseB/up_subs_integration.md) and we compute every "advanced" view a modern
subscription tracker (Bobby / Rocket Money) shows, adapted to Bangladesh:

  - normalised monthly / yearly spend per subscription and in total
  - upcoming charges in the next N days, trials ending before they charge
  - breakdowns by category and by payment method
  - most-expensive subscriptions, cancel-candidate nudges
  - rolling next_due forward when the user marks a cycle "paid"
  - income-burden + "cancel X to save Y" savings insights

MONEY IS INTEGER POISHA EVERYWHERE (1 taka = 100 poisha). We never carry a float
through arithmetic, so there is no drift when we sum / annualise / average. Amounts
arrive either as integer poisha (preferred) or as a taka string/decimal from the
Django DecimalField; `to_poisha` normalises both without float rounding error.

A subscription dict understood here (unknown keys are ignored, missing keys use
safe defaults):

    {
      "id": 1,
      "name": "Netflix",
      "amount": "650.00",        # taka string (DRF DecimalField) OR ...
      "amount_poisha": 65000,    # ... integer poisha (preferred; wins if present)
      "cycle": "monthly",        # weekly|monthly|quarterly|yearly|custom
      "interval_days": 30,       # required only when cycle == "custom"
      "next_due": "2026-02-01",  # ISO date, or None
      "category": "streaming",
      "payment_method": "bkash", # bkash|nagad|rocket|card|cash|bank
      "trial_end": "2026-01-20", # ISO date the free trial converts to paid, or None
      "auto_renew": true,
      "status": "active",        # active|paused|cancelled
      "last_used": "2026-01-02", # ISO date last used (for cancel-candidate nudge)
    }
"""

from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP

# ---------------------------------------------------------------- constants

CYCLES = ("weekly", "monthly", "quarterly", "yearly", "custom")

# Average days per cycle, used only for custom/weekly annualisation ratios.
# Calendar cycles (monthly/quarterly/yearly) advance by real calendar months so
# the day-of-month is preserved; these per-year counts are exact integers.
_PER_YEAR = {
    "weekly": Decimal(365) / Decimal(7),
    "monthly": Decimal(12),
    "quarterly": Decimal(4),
    "yearly": Decimal(1),
}

ACTIVE = "active"
PAUSED = "paused"
CANCELLED = "cancelled"

# A subscription unused for this many days is nudged as a cancel candidate.
STALE_DAYS = 60


# ---------------------------------------------------------------- money

def to_poisha(sub):
    """Integer poisha for a subscription. Prefers `amount_poisha`; else parses
    the taka `amount` (string/Decimal/number) with NO float arithmetic."""
    if sub.get("amount_poisha") is not None:
        try:
            return int(sub["amount_poisha"])
        except (TypeError, ValueError):
            return 0
    raw = sub.get("amount")
    if raw is None or raw == "":
        return 0
    try:
        taka = Decimal(str(raw))
    except Exception:
        return 0
    # taka → poisha, banker-free half-up, exact (no binary float).
    return int((taka * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def _parse_date(value):
    """ISO 'YYYY-MM-DD' (or date) → date, else None. Tolerant of datetimes."""
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _is_live(sub):
    """Counts toward spend / reminders? Cancelled never; paused never charges."""
    return str(sub.get("status", ACTIVE)) == ACTIVE


# ---------------------------------------------------------------- next due roll

def advance_due(current, cycle, interval_days=None, times=1):
    """Roll a due date forward by `times` whole cycles.

    Calendar cycles step by real months (day-of-month preserved, clamped for
    short months) so "1st of the month" stays the 1st. weekly/custom step by a
    fixed day count. Returns a date, or None if `current` is None.
    """
    d = _parse_date(current)
    if d is None:
        return None
    times = max(1, int(times))
    if cycle == "weekly":
        return d + timedelta(days=7 * times)
    if cycle == "custom":
        step = int(interval_days or 30)
        return d + timedelta(days=step * times)
    months = {"monthly": 1, "quarterly": 3, "yearly": 12}.get(cycle, 1) * times
    return _add_months(d, months)


def _add_months(d, n):
    m = d.month - 1 + n
    y = d.year + m // 12
    m = m % 12 + 1
    day = min(d.day, _days_in_month(y, m))
    return date(y, m, day)


def _days_in_month(y, m):
    nxt = date(y + 1, 1, 1) if m == 12 else date(y, m + 1, 1)
    return (nxt - date(y, m, 1)).days


def mark_paid(sub, today=None):
    """Return a shallow copy with next_due rolled to the first cycle strictly
    after `today` (handles catching up several missed cycles at once). Idempotent
    on cancelled subs. Does NOT mutate the input."""
    today = today or date.today()
    out = dict(sub)
    due = _parse_date(sub.get("next_due"))
    if due is None or str(sub.get("status", ACTIVE)) == CANCELLED:
        return out
    cycle = sub.get("cycle", "monthly")
    interval = sub.get("interval_days")
    # Advance until strictly in the future (never stall on an unknown cycle).
    guard = 0
    while due <= today and guard < 600:
        nxt = advance_due(due, cycle, interval)
        if nxt is None or nxt <= due:
            break
        due = nxt
        guard += 1
    out["next_due"] = due.isoformat()
    return out


# ---------------------------------------------------------------- normalised spend

def monthly_poisha(sub):
    """This subscription's spend normalised to one month, in integer poisha.
    Paused/cancelled subscriptions contribute 0."""
    if not _is_live(sub):
        return 0
    amt = to_poisha(sub)
    cycle = sub.get("cycle", "monthly")
    if cycle == "custom":
        step = int(sub.get("interval_days") or 30)
        if step <= 0:
            return 0
        per_year = Decimal(365) / Decimal(step)
    else:
        per_year = _PER_YEAR.get(cycle, Decimal(12))
    monthly = (Decimal(amt) * per_year) / Decimal(12)
    return int(monthly.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def yearly_poisha(sub):
    """This subscription's spend normalised to one year, in integer poisha."""
    if not _is_live(sub):
        return 0
    amt = to_poisha(sub)
    cycle = sub.get("cycle", "monthly")
    if cycle == "custom":
        step = int(sub.get("interval_days") or 30)
        if step <= 0:
            return 0
        per_year = Decimal(365) / Decimal(step)
    else:
        per_year = _PER_YEAR.get(cycle, Decimal(12))
    yearly = Decimal(amt) * per_year
    return int(yearly.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def totals(subs):
    """Portfolio totals in integer poisha."""
    monthly = sum(monthly_poisha(s) for s in subs)
    yearly = sum(yearly_poisha(s) for s in subs)
    live = [s for s in subs if _is_live(s)]
    return {
        "monthly_poisha": monthly,
        "yearly_poisha": yearly,
        "active_count": len(live),
        "total_count": len(subs),
    }


# ---------------------------------------------------------------- smart views

def upcoming(subs, within_days=7, today=None):
    """Live subscriptions due within `within_days` (inclusive), soonest first.
    Each item carries `days_until` (negative = overdue) and `amount_poisha`."""
    today = today or date.today()
    horizon = today + timedelta(days=within_days)
    out = []
    for s in subs:
        if not _is_live(s):
            continue
        due = _parse_date(s.get("next_due"))
        if due is None or due > horizon:
            continue
        out.append({
            "id": s.get("id"),
            "name": s.get("name", ""),
            "next_due": due.isoformat(),
            "days_until": (due - today).days,
            "amount_poisha": to_poisha(s),
        })
    out.sort(key=lambda x: x["next_due"])
    return out


def trials_ending(subs, within_days=7, today=None):
    """Free trials converting to paid within `within_days` — the alert that
    stops a surprise charge. Soonest first; overdue-to-convert included."""
    today = today or date.today()
    horizon = today + timedelta(days=within_days)
    out = []
    for s in subs:
        if str(s.get("status", ACTIVE)) == CANCELLED:
            continue
        end = _parse_date(s.get("trial_end"))
        if end is None or end > horizon:
            continue
        out.append({
            "id": s.get("id"),
            "name": s.get("name", ""),
            "trial_end": end.isoformat(),
            "days_until": (end - today).days,
            "amount_poisha": to_poisha(s),
            "auto_renew": bool(s.get("auto_renew", True)),
        })
    out.sort(key=lambda x: x["trial_end"])
    return out


def by_category(subs):
    """Monthly spend grouped by category, descending. Empty category → 'other'."""
    buckets = {}
    for s in subs:
        if not _is_live(s):
            continue
        cat = (s.get("category") or "other").strip() or "other"
        b = buckets.setdefault(cat, {"category": cat, "monthly_poisha": 0, "count": 0})
        b["monthly_poisha"] += monthly_poisha(s)
        b["count"] += 1
    return sorted(buckets.values(), key=lambda x: -x["monthly_poisha"])


def by_payment_method(subs):
    """Monthly spend grouped by payment method, descending."""
    buckets = {}
    for s in subs:
        if not _is_live(s):
            continue
        pm = (s.get("payment_method") or "cash").strip() or "cash"
        b = buckets.setdefault(pm, {"payment_method": pm, "monthly_poisha": 0, "count": 0})
        b["monthly_poisha"] += monthly_poisha(s)
        b["count"] += 1
    return sorted(buckets.values(), key=lambda x: -x["monthly_poisha"])


def most_expensive(subs, limit=3):
    """Top `limit` live subscriptions by normalised monthly cost, descending."""
    ranked = [
        {"id": s.get("id"), "name": s.get("name", ""),
         "monthly_poisha": monthly_poisha(s)}
        for s in subs if _is_live(s)
    ]
    ranked.sort(key=lambda x: -x["monthly_poisha"])
    return ranked[:limit]


def cancel_candidates(subs, today=None, stale_days=STALE_DAYS):
    """Nudge: live subscriptions unused for `stale_days`+ (or never marked used),
    most costly first — "you could save X by cancelling Y". Subs with no
    last_used and no next_due are skipped (not enough signal)."""
    today = today or date.today()
    out = []
    for s in subs:
        if not _is_live(s):
            continue
        last = _parse_date(s.get("last_used"))
        if last is None:
            continue
        idle = (today - last).days
        if idle < stale_days:
            continue
        out.append({
            "id": s.get("id"),
            "name": s.get("name", ""),
            "idle_days": idle,
            "monthly_poisha": monthly_poisha(s),
            "yearly_poisha": yearly_poisha(s),
        })
    out.sort(key=lambda x: -x["yearly_poisha"])
    return out


# ---------------------------------------------------------------- insights

def income_burden(subs, monthly_income_poisha):
    """Recurring monthly burden as a share of known income. Returns None when
    income is unknown/zero (UI should hide the gauge rather than divide by zero)."""
    if not monthly_income_poisha or monthly_income_poisha <= 0:
        return None
    monthly = totals(subs)["monthly_poisha"]
    pct = (Decimal(monthly) * 100 / Decimal(monthly_income_poisha))
    return {
        "monthly_poisha": monthly,
        "income_poisha": int(monthly_income_poisha),
        "burden_pct": float(pct.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)),
    }


def savings_if_cancelled(subs, ids):
    """Yearly poisha saved by cancelling the given subscription ids."""
    wanted = set(ids)
    saved = sum(yearly_poisha(s) for s in subs if s.get("id") in wanted and _is_live(s))
    return saved


# ---------------------------------------------------------------- one-call summary

def summarize(subs, today=None, monthly_income_poisha=None):
    """Everything the dashboard needs in a single pass — the shape a view can
    serialise straight to JSON."""
    today = today or date.today()
    out = {
        "totals": totals(subs),
        "upcoming_7": upcoming(subs, 7, today),
        "upcoming_30": upcoming(subs, 30, today),
        "trials_ending": trials_ending(subs, 7, today),
        "by_category": by_category(subs),
        "by_payment_method": by_payment_method(subs),
        "most_expensive": most_expensive(subs, 3),
        "cancel_candidates": cancel_candidates(subs, today),
    }
    if monthly_income_poisha:
        out["income_burden"] = income_burden(subs, monthly_income_poisha)
    return out
