"""
sms_margin.py — bizauto: the owner's 40 % PROFIT RULE for every SMS part a
business pays for with CREDITS (retention / crmauto SMS, CRM Assisto SMS,
tagada fallback that is charged in credits). Pure; no Django, no DB.

The rule is the one in core/logic/pricing_40.py (interpretation A, the
stricter one): of every ৳ a customer pays, Google + VAT leave NET_PCT (74 %),
OVERHEAD_PCT (10 %) runs the company, and at least PROFIT_PCT (40 %) must be
left as profit. So the real cost of what one credit buys may be at most

    budget = (NET_PCT - OVERHEAD_PCT - PROFIT_PCT) = 24 % of what that credit
             was SOLD for,

measured on the CHEAPEST credit the config sells (the biggest top-up pack or
an annual plan) — a user who bought there and spends everything on SMS must
still leave 40 %. Hence

    credits_per_part = ceil(cost_per_part_bdt / (cheapest_bdt_per_credit x budget))

pricing.normalize() lifts the "sms" action to this floor, so neither a stale
live row nor an Owner-Admin edit can sell an SMS part below the rule, and a
gateway entry with a higher own cost (sms_service) charges more, never less.
`proof()` is what the backend test and Owner Admin show.
"""
import math

from .pricing_40 import NET_PCT, OVERHEAD_PCT, PROFIT_PCT

BUDGET_PCT = round(NET_PCT - OVERHEAD_PCT - PROFIT_PCT, 4)   # 0.24


def _f(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def bdt_per_credit_rows(plans, packs, annual_discount_pct=0):
    """[(id, ৳ per credit)] for everything that SELLS credits. Annual rows:
    the explicit annual_price when set, else the monthly price less the
    configured discount (a LOWER bound: the shop clamps the discount further,
    which only raises the real price per credit)."""
    rows = []
    disc = max(0.0, min(0.9, _f(annual_discount_pct) / 100.0))
    for pid, row in (plans or {}).items():
        price, cr = _f((row or {}).get("price")), _f((row or {}).get("credits"))
        if price <= 0 or cr <= 0:
            continue
        rows.append((pid, price / cr))
        annual = _f((row or {}).get("annual_price"))
        if annual > 0:
            rows.append((pid + "_annual", annual / (cr * 12)))
        elif disc > 0:
            rows.append((pid + "_annual", price * (1 - disc) / cr))
    for p in packs or []:
        price, cr = _f((p or {}).get("price")), _f((p or {}).get("credits"))
        if price > 0 and cr > 0:
            rows.append((str((p or {}).get("id")), price / cr))
    return rows


def cheapest_bdt_per_credit(plans, packs, annual_discount_pct=0):
    rows = bdt_per_credit_rows(plans, packs, annual_discount_pct)
    return min(r[1] for r in rows) if rows else 0.0


def credits_per_part(cost_per_part_bdt, cheapest_bdt, budget=BUDGET_PCT):
    """Fewest whole credits per SMS part that keep the 40 % rule. >= 1."""
    cost = max(0.0, _f(cost_per_part_bdt))
    allowed = _f(cheapest_bdt) * _f(budget)
    if cost <= 0:
        return 1
    if allowed <= 0:
        return 10 ** 6            # nothing sells credits: never sell an SMS
    return max(1, int(math.ceil(cost / allowed - 1e-9)))


def margin(credits, cost_per_part_bdt, bdt_per_credit):
    """Money of ONE SMS part paid with `credits` credits bought at
    `bdt_per_credit` ৳ each: {price, net, overhead, sms_cost, profit,
    profit_pct}. profit_pct is of the PRICE (interpretation A)."""
    price = _f(credits) * _f(bdt_per_credit)
    net = price * NET_PCT
    ovh = price * OVERHEAD_PCT
    cost = max(0.0, _f(cost_per_part_bdt))
    profit = net - ovh - cost
    return {"price": round(price, 4), "net": round(net, 4), "overhead": round(ovh, 4),
            "sms_cost": round(cost, 4), "profit": round(profit, 4),
            "profit_pct": round(100.0 * profit / price, 2) if price else 0.0}


def proof(cfg):
    """The full per-message proof for a NORMALIZED pricing config: what one
    SMS part costs us, what it is charged, and the profit on the cheapest
    credit. ok = profit_pct >= 40."""
    sms = cfg.get("sms") or {}
    costs = cfg.get("action_costs") or {}
    row = costs.get("sms") or {}
    cost = max(_f(sms.get("default_cost_per_segment_bdt")),
               _f(row.get("provider_cost")) * _f(cfg.get("usd_bdt"), 0.0))
    cheapest = cheapest_bdt_per_credit(cfg.get("plans"), cfg.get("topup_packs"),
                                       cfg.get("annual_discount_pct"))
    credits = int(_f(row.get("credits"), 0))
    m = margin(credits, cost, cheapest)
    return {"cost_per_part_bdt": round(cost, 4), "credits_per_part": credits,
            "cheapest_bdt_per_credit": round(cheapest, 4),
            "needed_credits_per_part": credits_per_part(cost, cheapest),
            **m, "ok": m["profit_pct"] >= PROFIT_PCT * 100 - 1e-6}
