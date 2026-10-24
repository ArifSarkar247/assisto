"""
profit_guard.py — the PURE, deterministic engine behind Assisto's DAILY PROFIT
GUARD (Business Model, Build 2 of N; plan at .phaseB/BUSINESS_MODEL_PLAN.md).

Like pricing.py / admin_flags.py this module is PURE: no Django, no DB, no
network, no clock, no AI. It operates on plain dicts (DailyLedger rows projected
to {date, revenue_by_source, variable_cost_by_type}) and returns decisions the
stateful layer (core/billing.py) acts on.

The guard compares trailing-7-day VARIABLE COST against a share of trailing-7-day
NET REVENUE:

  * ok          cost <= approach_pct * cap   (cap = spend_cap_pct * net_rev7d)
  * near        approach_pct*cap < cost <= cap     -> force the cheaper AI model
  * over        cost > cap                         -> block FREE-tier costly
                                                      actions + alert the owner

Safety (SOS / family-alert SMS / safety notifications) is NEVER subject to the
guard — that decision lives in billing.SAFETY_EXEMPT, asserted by a test.
"""

REVENUE_SOURCES = ("ads", "subs", "packs", "commissions", "sponsored")
COST_TYPES = ("ai", "sms", "ivr", "video", "storage",
              "growth")   # p5: referral + founding-seat reward credits (estimated provider cost)

# config defaults (mirrored into PricingConfig via pricing defaults if desired)
DEFAULT_SPEND_CAP_PCT = 0.60     # variable cost must stay <= 60% of NET revenue
DEFAULT_APPROACH_PCT = 0.80      # "near" at >= 80% of that cap


def _sum(d, keys):
    if not isinstance(d, dict):
        return 0.0
    tot = 0.0
    for k in keys:
        try:
            v = d.get(k, 0)
            if isinstance(v, bool):
                continue
            tot += float(v or 0)
        except (TypeError, ValueError):
            continue
    return tot


def row_revenue(row):
    """Total ৳ revenue recorded on one ledger row."""
    return _sum((row or {}).get("revenue_by_source"), REVENUE_SOURCES)


def row_cost(row):
    """Total ৳ variable cost recorded on one ledger row."""
    return _sum((row or {}).get("variable_cost_by_type"), COST_TYPES)


def trailing_revenue(rows):
    """Sum of revenue across the given (already trailing-7-day) rows."""
    return sum(row_revenue(r) for r in (rows or []))


def trailing_cost(rows):
    """Sum of variable cost across the given rows."""
    return sum(row_cost(r) for r in (rows or []))


def guard_state(rows, spend_cap_pct=DEFAULT_SPEND_CAP_PCT,
                approach_pct=DEFAULT_APPROACH_PCT):
    """Decide the guard state from a list of trailing-7-day ledger rows.

    Returns {state, ratio, rev7d, cost7d, cap, ok, near, over}.

      * No revenue yet (rev7d == 0): we are bootstrapping — the guard returns
        'ok' (never blocks a brand-new product with zero revenue history), BUT
        the absolute AI budget kill-switch in core/ai.py still applies as the
        belt-and-suspenders ceiling. ratio is reported as inf for visibility.
      * cap = spend_cap_pct * rev7d.
    """
    rev7d = float(trailing_revenue(rows))
    cost7d = float(trailing_cost(rows))
    cap = max(0.0, spend_cap_pct) * rev7d

    if rev7d <= 0:
        state = "ok"
        ratio = float("inf") if cost7d > 0 else 0.0
    else:
        ratio = cost7d / rev7d
        if cost7d > cap:
            state = "over"
        elif cost7d >= approach_pct * cap:
            state = "near"
        else:
            state = "ok"

    return {
        "state": state, "ratio": ratio,
        "rev7d": round(rev7d, 4), "cost7d": round(cost7d, 4),
        "cap": round(cap, 4),
        "ok": state == "ok", "near": state == "near", "over": state == "over",
    }


def cheaper_tier(tier):
    """Model-downgrade hint used when the guard is 'near': step a requested AI
    tier down one rung (strong->medium->cheap; cheap stays cheap)."""
    return {"strong": "medium", "medium": "cheap", "cheap": "cheap"}.get(
        tier or "cheap", "cheap")


# ===========================================================================
# Owner P&L dashboard (Build 3) — PURE daily P&L from DailyLedger rows.
# ===========================================================================
def _round(x, n=2):
    try:
        return round(float(x or 0), n)
    except (TypeError, ValueError):
        return 0.0


def day_pnl(row, fixed_cost_per_day):
    """One day's P&L dict from a projected ledger row + the admin fixed cost/day.

    Returns {date, revenue{<source>.., total}, variable{<type>.., total},
             fixed, profit}. profit = revenue - variable - fixed. No invented
             numbers — a missing source/type is simply 0."""
    rev_src = (row or {}).get("revenue_by_source") or {}
    cost_src = (row or {}).get("variable_cost_by_type") or {}
    revenue = {s: _round(rev_src.get(s, 0)) for s in REVENUE_SOURCES}
    variable = {t: _round(cost_src.get(t, 0)) for t in COST_TYPES}
    rev_total = _round(sum(revenue.values()))
    var_total = _round(sum(variable.values()))
    fixed = _round(fixed_cost_per_day)
    revenue["total"] = rev_total
    variable["total"] = var_total
    return {
        "date": (row or {}).get("date"),
        "revenue": revenue,
        "variable": variable,
        "fixed": fixed,
        "profit": _round(rev_total - var_total - fixed),
    }


def pnl_series(rows, fixed_cost_per_day):
    """A daily P&L series (one day_pnl per row) + period totals.

    Returns {days:[day_pnl...], totals:{revenue, variable, fixed, profit}}.
    `rows` are projected DailyLedger dicts (any order); output is oldest-first."""
    rows = sorted((rows or []), key=lambda r: (r or {}).get("date") or "")
    days = [day_pnl(r, fixed_cost_per_day) for r in rows]
    totals = {
        "revenue": _round(sum(d["revenue"]["total"] for d in days)),
        "variable": _round(sum(d["variable"]["total"] for d in days)),
        "fixed": _round(fixed_cost_per_day * len(days)),
        "profit": _round(sum(d["profit"] for d in days)),
    }
    return {"days": days, "totals": totals}


def break_even(rows, fixed_cost_per_day, paid_users, arpu_per_day,
               ad_rev_per_day):
    """How far today is from covering fixed+variable cost, expressed BOTH as
    "X more paid users" and "৳Y more ad revenue/day", from REAL inputs.

      daily_cost  = today's variable cost + fixed_cost_per_day
      daily_rev   = today's total revenue (all sources)
      gap         = max(0, daily_cost - daily_rev)   (0 when already profitable)

    `arpu_per_day` = current average NET revenue per paid user per day (0 when
    there are no paid users -> users_needed is null, never a divide-by-zero or a
    fabricated figure). Returns {daily_cost, daily_rev, gap, arpu_per_day,
    users_needed, ad_revenue_needed, covered}."""
    today = sorted((rows or []), key=lambda r: (r or {}).get("date") or "")
    last = today[-1] if today else {}
    daily_var = row_cost(last)
    daily_rev = row_revenue(last)
    daily_cost = daily_var + _round(fixed_cost_per_day)
    gap = max(0.0, daily_cost - daily_rev)
    users_needed = None
    if arpu_per_day and arpu_per_day > 0:
        import math
        users_needed = int(math.ceil(gap / arpu_per_day)) if gap > 0 else 0
    return {
        "daily_cost": _round(daily_cost),
        "daily_rev": _round(daily_rev),
        "gap": _round(gap),
        "arpu_per_day": _round(arpu_per_day, 4),
        "users_needed": users_needed,
        "ad_revenue_needed": _round(gap),   # ৳/day of extra ad revenue closes it
        "covered": gap <= 0,
    }
