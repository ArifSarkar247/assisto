"""plansprep (owner pricing decisions 9 Nov 10:20, PRICING_PLAN_BN.md §8):
the ONE source of truth for plan numbers. PURE: no Django, no DB, no clock.

Everything that shows or charges a plan number — the app (/plans, /credits),
Owner Admin (Plans page, Pricing), the website pricing page and receipts —
reads the normalized PricingConfig dict, and with the `pricing_v2` block ON
that dict carries numbers DERIVED here by one formula, never typed by hand:

  * 1 credit is sold for at least MIN_BDT_PER_CREDIT (৳2.80) on every plan
    and pack, so a credit may carry at most C = ৳2.80 x AI_BUDGET (23.9 %)
    = ৳0.669 of worst-case AI cost and every product still keeps >= 40 %
    profit after VAT 15 % and the Play fee 15 % (pricing_40 rule A).
  * plan / pack credits = floor-to-10((price - other_costs / AI_BUDGET) / 2.80)
    -> Premium ৳449 = 160, Business ৳1,299 = 440 (30 SMS parts inside),
       Plus ৳199 = 70, Premium Pro ৳999 = 350, Probashi $4.99 = 210,
       packs ৳179 = 60, ৳399 = 140, ৳949 = 330. A different live price gives
       its own formula number (owner item 12: live prices are not changed).
  * an AI answer level costs ceil(worst-case ৳ / C) credits (Normal and
    Better = 1, Best (Sonnet) = 11); an action with a provider cost costs
    max(that, the legacy NET-floor) credits.
  * no drip (100 % at purchase), bought packs expire after 12 months, the
    old ৳1-a-credit packs p20/p50/p100/p200 are no longer sold (balances stay).

The `pricing_v2` block is OFF by default; `manage.py pricing_v2_apply
--apply` turns it on in the live row (plus the non-derived owner settings in
v2_settings_patch) after a DB backup. Off -> every number is exactly as before.
"""
import math

MIN_BDT_PER_CREDIT = 2.80          # owner-approved floor price of one credit
NET_PCT = 0.739                    # price / 1.15 VAT x (1 - 0.15 Play fee)
OVERHEAD_PCT = 0.10                # server, SMS, push
PROFIT_PCT = 0.40                  # owner: >= 40 % worst-case profit
AI_BUDGET = round(NET_PCT - OVERHEAD_PCT - PROFIT_PCT, 4)          # 0.239
CREDIT_AI_CAP_BDT = round(MIN_BDT_PER_CREDIT * AI_BUDGET, 4)       # 0.6692
SAFETY_USD_BDT = 125.0             # costs are always counted at >= ৳125/USD
ROUND_TO = 10

LEGACY_PACKS = ("p20", "p50", "p100", "p200")
# the three packs the owner approved (prices unchanged; credits by formula)
V2_PACKS = ({"id": "c50", "price": 179, "valid_months": 12},
            {"id": "c120", "price": 399, "valid_months": 12},
            {"id": "c300", "price": 949, "valid_months": 12})
PACK_EXPIRY_MONTHS = 12
PACK_EXPIRY_WARN_DAYS = 7
# Business includes 30 SMS parts a month (worst case ৳0.35 a part)
OTHER_COST_BDT = {"business": 30 * 0.35}
PAID_PLANS = ("plus", "premium", "premium_pro", "business")
# the owner's approved numbers (9 Nov) — ONLY used by the CI test that proves
# the formula reproduces them at the proposal prices; never read at runtime
APPROVED = {"plus": (199, 70), "premium": (449, 160), "premium_pro": (999, 350),
            "business": (1299, 440), "c50": (179, 60), "c120": (399, 140),
            "c300": (949, 330)}
APPROVED_PROBASHI = (4.99, 120.0, 210)
APPROVED_LEVEL_CREDITS = {"normal": 1, "better": 1, "best": 11}
HAIKU_PROMPT_MAX_TOKENS = 90000     # owner: above 100k Haiku costs 5x


def block_defaults():
    return {"on": False}


def normalize_block(raw):
    raw = raw if isinstance(raw, dict) else {}
    return {"on": raw.get("on") is True}


def is_on(cfg):
    return bool(((cfg or {}).get("pricing_v2") or {}).get("on"))


def _floor_to(n, step=ROUND_TO):
    n = int(math.floor(n))
    return max(0, n - n % step) if n >= step else max(0, n)


def credits_for_price(price_bdt, other_cost_bdt=0.0):
    """THE formula: credits a product may grant at `price_bdt` and still keep
    >= 40 % worst-case profit with every credit spent on the dearest answer."""
    p = float(price_bdt or 0)
    if p <= 0:
        return 0
    usable = p - float(other_cost_bdt or 0) / AI_BUDGET
    return _floor_to(usable / MIN_BDT_PER_CREDIT)


def level_credits(worst_cost_usd, usd_bdt=SAFETY_USD_BDT):
    """Credits for one answer whose worst case costs `worst_cost_usd`."""
    bdt = float(worst_cost_usd) * max(float(usd_bdt or 0), SAFETY_USD_BDT)
    return max(1, int(math.ceil(round(bdt / CREDIT_AI_CAP_BDT, 6))))


def level_credit_table(cfg):
    """{level: credits} from the config's own levels + router prices (pure)."""
    from . import ai_levels as AL
    lv = (cfg or {}).get("ai_levels") or AL.defaults()
    prices = ((cfg or {}).get("ai_router") or {}).get("prices") or {}
    out = {}
    for lid, row in (lv.get("levels") or {}).items():
        out[lid] = max(level_credits(AL.worst_cost_usd(row, prices), (cfg or {}).get("usd_bdt")),
                       int(row.get("credits") or 0))
    return out


def action_credits(provider_cost_usd, legacy_floor):
    """An action's credits: the strict per-credit cap or the legacy NET floor,
    whichever is HIGHER (never cheaper than the rule shipped before)."""
    c = float(provider_cost_usd or 0)
    if c <= 0:
        return None
    return max(int(legacy_floor or 0), level_credits(c))


def probashi_price_bdt(cfg):
    return float(cfg.get("probashi_price_usd") or 0) * float(cfg.get("usd_bdt") or 0)


def derive(out, legacy_floor_fn=None):
    """Mutate a normalized config dict IN PLACE with the v2 numbers (only when
    its pricing_v2 block is on). Idempotent. `legacy_floor_fn(action, cfg)`
    returns the old NET-floor credits for an action."""
    if not is_on(out):
        return out
    for pid in PAID_PLANS:
        row = out["plans"].get(pid)
        if row is not None and row["price"] > 0:
            row["credits"] = credits_for_price(row["price"], OTHER_COST_BDT.get(pid, 0.0))
    # packs: the approved three are sold, the ৳1-a-credit packs are not
    have = {p["id"] for p in out["topup_packs"]}
    for p in V2_PACKS:
        if p["id"] not in have:
            out["topup_packs"].append(dict(p, credits=0))
    for p in out["topup_packs"]:
        p["credits"] = credits_for_price(p["price"])
        p["valid_months"] = PACK_EXPIRY_MONTHS
    out["pricing_v2"]["packs_off"] = [p["id"] for p in out["topup_packs"]
                                      if p["id"] in LEGACY_PACKS]
    # Probashi family pool (Play bills USD; counted at the config rate)
    m = probashi_price_bdt(out)
    if "probashi_plan" in out and m > 0:
        out["probashi_plan"]["pool_credits"] = credits_for_price(m)
        out["probashi_plan"]["annual_pool_credits"] = credits_for_price(m * 10)
    # actions with a real provider cost
    if legacy_floor_fn is not None:
        for aid, row in out["action_costs"].items():
            n = action_credits(row.get("provider_cost"), legacy_floor_fn(aid, row, out))
            if n is not None:
                row["credits"] = n
    # no drip: 100 % at purchase; bought packs expire after 12 months
    out["billing"]["unlock_pct"] = 100
    out["billing"]["unlock_hours"] = 0
    out["billing"]["pack_expiry_months"] = PACK_EXPIRY_MONTHS
    return out


def annual_credits_total(price_year_bdt, plan_id=""):
    """A yearly plan's credits for the whole year (granted 1/12 a month)."""
    return credits_for_price(price_year_bdt, 12 * OTHER_COST_BDT.get(plan_id, 0.0))


def packs_off(cfg):
    return set(((cfg or {}).get("pricing_v2") or {}).get("packs_off") or [])


# ------------------------------------------------------------ owner settings
# What `pricing_v2_apply --apply` writes besides the switch (the owner's
# answers that are settings, not numbers): AI levels (item 13), welcome
# credits (7), rewarded ads (8), web search (9), Care Call (10).
V2_LEVELS = {
    # Normal = Claude Haiku 5.5 (cheapest and working)
    "normal": {"provider": "anthropic", "model": "claude-haiku-5-5",
               "in_cap": 5000, "out_cap": 1500, "history_turns": 12},
    # Better = Gemini Flash (not Lite). Its caps keep it at ONE credit by the
    # formula (worst case ৳0.66); when Gemini is down / billing off the level
    # falls back to Haiku with the longer answer budget (fallback_out_cap).
    "better": {"provider": "gemini", "model": "gemini-3.6-flash",
               "in_cap": 3000, "out_cap": 800, "history_turns": 12,
               "fallback_out_cap": 2500},
    # Best = Claude Sonnet 5.5 (11 credits by the formula)
    "best": {"provider": "anthropic", "model": "claude-sonnet-5-5",
             "in_cap": 12000, "out_cap": 2500, "history_turns": 20},
}
V2_CARECALL = {"free": {"schedules": 3, "rings_month": 90},
               "child": {"schedules": 5, "rings_month": 0},
               "family": {"schedules": 20, "rings_month": 0}}


def v2_settings_patch():
    """The non-derived settings the apply command merges into the live row."""
    return {
        "pricing_v2": {"on": True},
        "ai_levels": {
            "enabled": True,
            "levels": {k: dict(v) for k, v in V2_LEVELS.items()},
            "free_credit_levels": ["normal", "better"],
            "welcome_on": True, "welcome_credits": 30,
            "ad_answers_per_ad": 1, "ads_per_answer": 2,
            # web search ON: free Gemini grounding quota first, then Claude
            # web search; +credits (formula: 3) only when a search really ran
            "web_on": True, "web_usd_per_prompt": 0.015, "web_free_per_day": 1500,
        },
        "ad_rewards": {"rewarded_daily_cap": 5},
    }


def deep_merge(base, patch):
    out = dict(base or {})
    for k, v in (patch or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict) and k != "levels":
            out[k] = deep_merge(out[k], v)
        elif k == "levels" and isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = {lid: deep_merge(out[k].get(lid) or {}, row) for lid, row in
                      {**{x: {} for x in out[k]}, **v}.items()}
        else:
            out[k] = v
    return out


def flat_diff(before, after, prefix=""):
    """[(path, old, new)] for every scalar/list leaf that differs."""
    rows = []
    keys = sorted(set((before or {}).keys()) | set((after or {}).keys()))
    for k in keys:
        a = (before or {}).get(k)
        b = (after or {}).get(k)
        p = "%s.%s" % (prefix, k) if prefix else str(k)
        if isinstance(a, dict) and isinstance(b, dict):
            rows += flat_diff(a, b, p)
        elif isinstance(a, list) and isinstance(b, list) and a and isinstance(a[0], dict):
            ida = {str(x.get("id")): x for x in a if isinstance(x, dict)}
            idb = {str(x.get("id")): x for x in b if isinstance(x, dict)}
            for i in sorted(set(ida) | set(idb)):
                rows += flat_diff(ida.get(i) or {}, idb.get(i) or {}, "%s[%s]" % (p, i))
        elif a != b:
            rows.append((p, a, b))
    return rows


# ------------------------------------------------------------ 40 % check
def worst_case_rows(cfg):
    """[{id, kind, price, credits, max_ai_bdt, other_bdt, profit_pct}] for
    every plan and pack the config sells: every credit spent at the per-credit
    AI cap, the fixed other costs, VAT + Play fee + 10 % overhead."""
    rows = []

    def row(i, kind, price, credits, other=0.0):
        if price <= 0 or credits <= 0:
            return
        ai = credits * CREDIT_AI_CAP_BDT
        keep = price * NET_PCT - price * OVERHEAD_PCT - ai - other
        rows.append({"id": i, "kind": kind, "price": price, "credits": credits,
                     "max_ai_bdt": round(ai, 2), "other_bdt": round(other, 2),
                     "profit_pct": round(100.0 * keep / price, 1)})
    for pid, p in (cfg.get("plans") or {}).items():
        row(pid, "plan", float(p["price"]), int(p["credits"]), OTHER_COST_BDT.get(pid, 0.0))
    off = packs_off(cfg)
    for p in cfg.get("topup_packs") or []:
        if p["id"] not in off:
            row(p["id"], "pack", float(p["price"]), int(p["credits"]))
    pb = cfg.get("probashi_plan") or {}
    m = probashi_price_bdt(cfg)
    if m > 0 and pb:
        row("probashi", "plan", m, int(pb.get("pool_credits") or 0))
    return rows


def level_rows(levels, prices, worst_fn, credits_fn):
    """[{id, model, worst_bdt, credits, profit_pct}] per AI answer level, the
    price of one answer counted at the CHEAPEST credit we sell (৳2.80)."""
    out = []
    for lid, r in levels.items():
        w = worst_fn(r, prices) * SAFETY_USD_BDT
        c = credits_fn(r)
        price = c * MIN_BDT_PER_CREDIT
        keep = price * (NET_PCT - OVERHEAD_PCT) - w
        out.append({"id": lid, "model": r.get("model"), "worst_bdt": round(w, 3),
                    "credits": c, "profit_pct": round(100.0 * keep / price, 1) if price else 0.0})
    return out


# ------------------------------------------------------------ low credit
def low_credit(usable, monthly_pool, cheapest_answer=1):
    """The low-credit warning: under 10 % of the plan's monthly pool, or
    under 5 cheapest answers for an account with no pool (free / packs)."""
    usable = max(0, int(usable or 0))
    pool = max(0, int(monthly_pool or 0))
    threshold = max(int(cheapest_answer or 1) * 5, pool // 10)
    return {"low": usable <= threshold, "empty": usable == 0,
            "threshold": threshold}


# ------------------------------------------------------------ per-plan P&L
def plan_pnl(revenue, ai_cost, users, net_pct=NET_PCT):
    """{plan: {users, gross_bdt, net_bdt, ai_cost_bdt, profit_bdt, margin_pct}}
    from per-plan gross revenue (৳), AI cost (৳) and active user counts."""
    out = {}
    for pid in sorted(set(revenue) | set(ai_cost) | set(users)):
        g = float(revenue.get(pid, 0.0))
        n = g * net_pct
        cost = float(ai_cost.get(pid, 0.0))
        profit = n - cost
        out[pid] = {"users": int(users.get(pid, 0)), "gross_bdt": round(g, 2),
                    "net_bdt": round(n, 2), "ai_cost_bdt": round(cost, 2),
                    "profit_bdt": round(profit, 2),
                    "margin_pct": round(100.0 * profit / g, 1) if g > 0 else None}
    return out
