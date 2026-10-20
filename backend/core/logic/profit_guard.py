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

REVENUE_SOURCES = ("ads", "subs", "packs", "commissions")
COST_TYPES = ("ai", "sms", "ivr", "video", "storage")

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
