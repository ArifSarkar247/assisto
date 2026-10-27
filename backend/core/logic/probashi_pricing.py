"""
probashi_pricing.py — the 40 % profit rule for the Probashi family plan, per
country (owner decision 27 Oct). PURE: no DB, no network, no clock.

The rule (owner, 27 Oct): even if EVERY credit of the plan is spent on the
MOST EXPENSIVE model, the company keeps >= 40 % profit after Google's fee,
the country's VAT/GST and ~10 % overhead (server, SMS, push).

Method (the same inputs as owner_actions/AI_ROUTER_BN.md and the domestic
40 % check):

  ex_tax      = price / (1 + vat)        when Play prices are tax-INCLUSIVE
              = price                    when tax is added on top (US, CA)
  net         = ex_tax * (1 - google_fee)          google_fee = 15 % (subs)
  overhead    = 10 % of net
  profit      >= 40 % of net
  => AI cost  <= 50 % of net   (per month)

  The ANNUAL base plan is 10 x monthly but serves 12 months, so the binding
  case is the annual one: AI cost per month <= 0.5 * net_annual / 12.

  AI cost per credit, worst case = the most expensive model (Opus 5.5,
  $4 in / $20 out per 1M tokens; thinking billed as output) on the action
  with the highest cost PER CREDIT in today's credit table: a 1-credit chat
  message routed to the MAIN class (2,000 input tokens incl. system prompt +
  history, 400 output tokens incl. thinking) = $0.016 / credit.  Long text
  (3 credits) and agent work (6 credits) cost less per credit
  ($0.010 and $0.0077). Cache reads ($0.20/M) only lower this, so they are
  ignored (worst case). A heavy-context sensitivity row uses 6,000 in /
  1,000 out = $0.044 / credit.

  Free Haiku quota: none exists in the code today (every AI call debits
  credits). The parameter is kept so a future free quota is priced in:
  free_haiku_calls_per_person_month * 5 people * $0.0004 (Haiku 5.5,
  2,000 in / 400 out).
"""
from __future__ import annotations

from decimal import ROUND_FLOOR, Decimal

GOOGLE_FEE = Decimal("0.15")        # Play: every auto-renewing subscription
OVERHEAD = Decimal("0.10")          # of net: server, SMS, push
PROFIT_MIN = Decimal("0.40")        # of net
AI_SHARE = 1 - OVERHEAD - PROFIT_MIN   # 0.50 of net may go to AI, worst case
ANNUAL_MULT = 10                    # annual = 10 x monthly (owner)

# USD per 1M tokens (owner's table, = core.ai_config.DEFAULT_PRICES)
MODEL_PRICES = {
    "claude-opus-5-5": (Decimal("4"), Decimal("20")),
    "claude-sonnet-5-5": (Decimal("2"), Decimal("10")),
    "claude-haiku-5-5": (Decimal("0.10"), Decimal("0.50")),
}
# (action, credits, input tokens, output tokens incl. thinking) — AI_ROUTER_BN.md §2
ACTIONS = (
    ("chat (ai_msg_cheap on MAIN)", 1, 2000, 400),
    ("long text (ai_msg_medium)", 3, 1500, 1200),
    ("agent / complex (ai_msg_strong)", 6, 4000, 1500),
)
HEAVY = ("chat, heavy context", 1, 6000, 1000)


def call_cost(model, tin, tout):
    pin, pout = MODEL_PRICES[model]
    return (pin * tin + pout * tout) / Decimal(1_000_000)


def worst_cost_per_credit(model="claude-opus-5-5", actions=ACTIONS):
    """(usd_per_credit, action_label) — the highest cost per credit."""
    best = None
    for label, cr, tin, tout in actions:
        c = call_cost(model, tin, tout) / cr
        if best is None or c > best[0]:
            best = (c, label)
    return best


# Countries (owner's 13). vat = VAT/GST/digital service tax on a consumer
# subscription; inclusive = Play shows the tax-inclusive price (Google
# collects and remits it from the price). Sources: Play Console Help
# "Tax rates and VAT" (support.google.com/googleplay/android-developer/
# answer/138000) for SA 15 %, AE 5 %, OM 5 %, SG 9 %, AU 10 %, BH/GB/US/CA
# (Google remits); BH 10 % since 1 Jan 2022 (NBR); MY 8 % service tax on
# foreign digital services since 1 Mar 2024 (RMCD); IT 22 %; GB 20 %;
# QA and KW have no VAT; US sales tax and CA GST/HST are added ON TOP of the
# Play price (not taken out of it).
# fx = local units per 1 USD (pegs exact; floating rates are an ASSUMPTION
# for 27 Oct 2026 — re-check against Play Console's converted price).
COUNTRIES = (
    # code, name_bn, name_en, cur, vat, inclusive, fx, fx_pegged, monthly, annual
    ("SA", "সৌদি আরব", "Saudi Arabia", "SAR", "0.15", True, "3.75", True, "37.99", "379.99"),
    ("AE", "সংযুক্ত আরব আমিরাত", "UAE", "AED", "0.05", True, "3.6725", True, "36.99", "369.99"),
    ("QA", "কাতার", "Qatar", "QAR", "0", True, "3.64", True, "36.99", "369.99"),
    ("OM", "ওমান", "Oman", "OMR", "0.05", True, "0.3845", True, "3.900", "39.000"),
    ("KW", "কুয়েত", "Kuwait", "KWD", "0", True, "0.307", False, "2.990", "29.900"),
    ("BH", "বাহরাইন", "Bahrain", "BHD", "0.10", True, "0.376", True, "3.790", "37.900"),
    ("MY", "মালয়েশিয়া", "Malaysia", "MYR", "0.08", True, "4.25", False, "42.90", "429.00"),
    ("SG", "সিঙ্গাপুর", "Singapore", "SGD", "0.09", True, "1.30", False, "12.98", "129.80"),
    ("IT", "ইতালি", "Italy", "EUR", "0.22", True, "0.87", False, "9.99", "99.99"),
    ("GB", "যুক্তরাজ্য", "United Kingdom", "GBP", "0.20", True, "0.76", False, "7.99", "79.99"),
    ("US", "যুক্তরাষ্ট্র", "USA", "USD", "0", False, "1", True, "9.99", "99.99"),
    ("CA", "কানাডা", "Canada", "CAD", "0", False, "1.39", False, "13.99", "139.99"),
    ("AU", "অস্ট্রেলিয়া", "Australia", "AUD", "0.10", True, "1.53", False, "15.99", "159.99"),
)


def _d(v):
    return Decimal(str(v))


def net_usd(price, vat, inclusive, fx):
    """What Google pays us (USD) for one sale at `price` (local)."""
    price, vat, fx = _d(price), _d(vat), _d(fx)
    ex = price / (1 + vat) if inclusive else price
    return ex * (1 - GOOGLE_FEE) / fx


def ai_budget_month_usd(monthly, annual, vat, inclusive, fx):
    """Max AI spend per month that keeps >= 40 % profit on BOTH base plans."""
    m = net_usd(monthly, vat, inclusive, fx)
    y = net_usd(annual, vat, inclusive, fx) / 12
    return AI_SHARE * min(m, y)


def pool_credits(budget_usd, per_credit_usd, free_haiku_cost_usd=Decimal(0)):
    b = _d(budget_usd) - _d(free_haiku_cost_usd)
    if b <= 0:
        return 0
    return int((b / _d(per_credit_usd)).to_integral_value(rounding=ROUND_FLOOR))


def min_monthly_price(pool, per_credit_usd, vat, inclusive, fx, free_haiku_cost_usd=Decimal(0)):
    """Lowest local monthly price (annual = 10x) at which `pool` credits/month
    still meet the rule: the annual case binds (net_y/12 = 10/12 net_m)."""
    need_net_m = (_d(pool) * _d(per_credit_usd) + _d(free_haiku_cost_usd)) / AI_SHARE
    need_net_m = need_net_m * 12 / ANNUAL_MULT
    ex = need_net_m * _d(fx) / (1 - GOOGLE_FEE)
    return ex * (1 + _d(vat)) if inclusive else ex


def margin(price, vat, inclusive, fx, ai_cost_usd):
    """Profit as a share of net for one period, given that period's AI cost."""
    n = net_usd(price, vat, inclusive, fx)
    if n <= 0:
        return Decimal(0)
    return (n - OVERHEAD * n - _d(ai_cost_usd)) / n


def table(pool=None, per_credit_usd=None, free_haiku_calls=0, people=5):
    """One row per country. With pool=None the pool is the largest single
    number every country can carry (so one server value is honest
    everywhere)."""
    if per_credit_usd is None:
        per_credit_usd = worst_cost_per_credit()[0]
    haiku = call_cost("claude-haiku-5-5", 2000, 400) * free_haiku_calls * people
    rows = []
    for code, bn, en, cur, vat, inc, fx, peg, mo, yr in COUNTRIES:
        budget = ai_budget_month_usd(mo, yr, vat, inc, fx)
        rows.append({"code": code, "name_bn": bn, "name_en": en, "cur": cur,
                     "vat": _d(vat), "inclusive": inc, "fx": _d(fx), "fx_pegged": peg,
                     "monthly": _d(mo), "annual": _d(yr),
                     "usd_monthly": _d(mo) / _d(fx),
                     "net_usd_m": net_usd(mo, vat, inc, fx),
                     "net_usd_y_per_m": net_usd(yr, vat, inc, fx) / 12,
                     "ai_budget_usd_m": budget,
                     "max_pool": pool_credits(budget, per_credit_usd, haiku)})
    final_pool = pool if pool is not None else min(r["max_pool"] for r in rows)
    for r in rows:
        r["pool"] = final_pool
        ai = _d(final_pool) * _d(per_credit_usd) + haiku
        r["ai_cost_usd_m"] = ai
        r["margin_monthly"] = margin(r["monthly"], r["vat"], r["inclusive"], r["fx"], ai)
        r["margin_annual"] = margin(r["annual"], r["vat"], r["inclusive"], r["fx"], ai * 12)
        r["min_monthly"] = min_monthly_price(final_pool, per_credit_usd, r["vat"],
                                             r["inclusive"], r["fx"], haiku)
        r["ok"] = (r["margin_monthly"] >= PROFIT_MIN and r["margin_annual"] >= PROFIT_MIN
                   and r["monthly"] >= r["min_monthly"])
    return rows, final_pool


if __name__ == "__main__":   # python3 -m core.logic.probashi_pricing
    w, lab = worst_cost_per_credit()
    rows, pool = table()
    print("worst $/credit %.4f (%s); pool %d credits/month" % (w, lab, pool))
    for r in rows:
        print("%s %s %s/%s vat %s net$m %.2f net$y/m %.2f AI$ %.2f maxpool %d "
              "margin m %.1f%% y %.1f%% min %.2f ok %s" % (
                  r["code"], r["cur"], r["monthly"], r["annual"], r["vat"], r["net_usd_m"],
                  r["net_usd_y_per_m"], r["ai_budget_usd_m"], r["max_pool"],
                  100 * r["margin_monthly"], 100 * r["margin_annual"], r["min_monthly"], r["ok"]))
