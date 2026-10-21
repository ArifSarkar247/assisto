"""
pricing.py — the PURE, deterministic engine behind Assisto's SERVER-SIDE
PRICING config (Business Model, Build 1 of N; plan at .phaseB/BUSINESS_MODEL_PLAN.md).

This is the numeric counterpart to `admin_flags.py`. admin_flags is CONTRACTUALLY
barred from pricing ("NEVER HOLDS MONEY / NEVER SERVER-SIDE PRICING"); all plan
prices, included credits, annual discount, per-action credit costs and the
margin target live HERE and are persisted in the `PricingConfig` single row.

Like admin_flags.py this module is PURE: no Django, no DB, no network, no clock,
no AI. It is the SINGLE SOURCE OF TRUTH for:

  * the shipped DEFAULTS (Premium ৳199, Business ৳999, Free ৳0; the approved
    credit-cost-per-action table; margin 0.40),
  * normalize(data) — project an arbitrary stored dict onto the known shape,
    filling defaults,
  * credit_cost(action, cfg) / credits_for(action, qty, cfg) — read the config,
  * recompute_from_provider_cost(action, cfg) — the AUTO-RE-PRICING helper:
    ceil(provider_cost * (1 + margin) / credit_bdt) credits, keeping margin,
  * plan_public(lang, cfg) — build the localized public plans list from config
    (REPLACES the hard-coded Free/Premium/Business entries in core/plans.py),
  * validate_edit(data) — margin >= 0, prices >= 0, credits >= 0.

The server is the authority; a Dart mirror (if any) is advisory for UX only.
"""
import math

from . import home_defaults as HD

# --------------------------------------------------------------- currency basis
# Prices are stored in whole TAKA (BDT), matching core/plans.py `price` (e.g. 199).
# Provider costs are stored in USD (matching core/ai.py PRICES). The auto-reprice
# helper converts USD -> credits using usd_bdt (৳/USD) and credit_bdt (৳ a single
# credit is "worth" for pricing math).

CUR = "BDT"

# One canonical credit is priced at ৳ this much for provider-cost -> credits math.
DEFAULT_CREDIT_BDT = 1.0
DEFAULT_USD_BDT = 120.0
DEFAULT_MARGIN = 0.40          # >= 0.40 required

# ---- plan definitions (localized name/desc/benefits mirror core/plans.py) ----
# Free / Premium / Business are now driven by config. probashi + founder stay in
# core/plans.py (folded per the plan note); annual discount is a % on Premium.

_PLAN_META = {
    "free": {
        "name_bn": "ফ্রি", "name_en": "Free",
        "desc_bn": "শুরু করার জন্য — নিরাপত্তা সবসময় ফ্রি।",
        "desc_en": "To get started — safety is always free.",
        "benefits_bn": ["মাসে ১৫ AI স্ক্যান", "রিমাইন্ডার, ভল্ট, হিসাব",
                        "জরুরি SOS ও স্ক্যাম সতর্কতা (ফ্রি)", "ওষুধ রিমাইন্ডার (ফ্রি)"],
        "benefits_en": ["15 AI scans / month", "Reminders, documents, money",
                        "Emergency SOS & scam alerts (free)", "Medicine reminders (free)"],
    },
    "premium": {
        "name_bn": "প্রিমিয়াম", "name_en": "Premium",
        "desc_bn": "আনলিমিটেড AI, বিজ্ঞাপন নেই — পরিবারের যত্ন একসাথে।",
        "desc_en": "Unlimited AI, no ads — care for your family together.",
        "benefits_bn": ["আনলিমিটেড AI স্ক্যান ও সহকারী", "বিজ্ঞাপন নেই",
                        "৫ জন পর্যন্ত কানেক্টেড সার্কেল ও কেয়ারগিভার ড্যাশবোর্ড",
                        "স্মার্ট ব্রিফিং ও অগ্রাধিকার সাপোর্ট"],
        "benefits_en": ["Unlimited AI scans & assistant", "No ads",
                        "Up to 5-member Circle & caregiver dashboard",
                        "Smart briefings & priority support"],
    },
    "business": {
        "name_bn": "বিজনেস", "name_en": "Business",
        "desc_bn": "ছোট ব্যবসা ও বিক্রয় দলের জন্য।",
        "desc_en": "For small businesses and sales teams.",
        "benefits_bn": ["আনলিমিটেড AI", "বিজনেস মোড: ক্যাটালগ ও অর্ডার",
                        "AI CRM (Axon Dynamics)", "দলের আসন"],
        "benefits_en": ["Unlimited AI", "Business mode: catalog & orders",
                        "AI CRM (Axon Dynamics)", "Team seats"],
    },
}

# order the public catalog is rendered in
PLAN_ORDER = ("free", "premium", "business")

# ---------------------------------------------------------------- action table
# Approved credit-cost-per-action map. Each action: provider_cost (USD, our best
# estimate of the external spend) and credits (what the user is charged). The
# credits column is the APPROVED table from the plan; provider_cost seeds the
# auto-reprice helper. ai_msg_* mirror core/ai.py TIER_MODEL (cheap/medium/strong).
_ACTION_DEFAULTS = {
    # ai messages — cheap (haiku) vs advanced (sonnet/opus)
    "ai_msg_cheap":        {"provider_cost": 0.002, "credits": 1},
    "ai_msg_medium":       {"provider_cost": 0.015, "credits": 3},
    "ai_msg_strong":       {"provider_cost": 0.030, "credits": 6},
    # non-AI costly actions
    "scan_ocr":            {"provider_cost": 0.004, "credits": 2},
    "photo_enhance":       {"provider_cost": 0.004, "credits": 2},
    "video_min":           {"provider_cost": 0.002, "credits": 1},
    "remote_support_min":  {"provider_cost": 0.004, "credits": 2},
    "ivr_call":            {"provider_cost": 0.006, "credits": 3},
    "sms":                 {"provider_cost": 0.002, "credits": 1},
    "voice_clone":         {"provider_cost": 0.010, "credits": 5},
    "ai_sales":            {"provider_cost": 0.006, "credits": 3},
    # Shop loss-prevention (Part 4): Business includes 4 edge cameras; each
    # extra camera (or server-mode camera) costs credits. No provider cost —
    # it is an entitlement charge, priced so the owner tunes it from /admin/pricing.
    "shop_extra_camera":   {"provider_cost": 0.0,   "credits": 20},
}

# Business plan includes this many edge cameras at no credit cost; beyond it,
# each camera is charged `shop_extra_camera`. Non-Business plans get 0 included.
BUSINESS_INCLUDED_CAMERAS = 4

# tier (core/ai.py) -> action id
TIER_ACTION = {
    "cheap": "ai_msg_cheap",
    "medium": "ai_msg_medium",
    "strong": "ai_msg_strong",
}


# ---------------------------------------------------------------- v2 packs / fees / storage
# Business Model Build 2. 1 credit == ৳1 face (credit_bdt). Packs grant bonus
# credits (buy more, get more) and expire 12 months after purchase.
_TOPUP_PACKS = [
    {"id": "p20",  "price": 20,  "credits": 20,  "valid_months": 12},
    {"id": "p50",  "price": 50,  "credits": 55,  "valid_months": 12},
    {"id": "p100", "price": 100, "credits": 115, "valid_months": 12},
    {"id": "p200", "price": 200, "credits": 240, "valid_months": 12},
]

# Revenue fees used for the NET-margin guarantee. NET revenue a plan actually
# keeps = price * (1 - play_fee - gateway_fee - vat). All admin-editable.
DEFAULT_PLAY_FEE = 0.15          # store (Play/App Store) cut
DEFAULT_GATEWAY_FEE = 0.02       # bkash/nagad/sslcommerz gateway cut
DEFAULT_VAT = 0.00               # VAT / tax withheld
# DEFAULTS of the two NET-margin guarantees. Both are admin-editable under
# cfg["guarantees"] (bounded by GUARANTEE_BOUNDS); every reader goes through
# net_floor(cfg) / pool_cap(cfg), never these literals directly.
MARGIN_NET_FLOOR = 0.60          # every action's credit-value must be >= cost / 0.60
POOL_CAP_PCT_OF_NET = 0.60       # included-pool face value must be <= 60% of NET plan rev
GUARANTEE_BOUNDS = {"margin_net_floor": (0.10, 0.90),
                    "pool_cap_pct_of_net": (0.0, 1.0)}

# Other business limits (admin-editable under cfg["limits"]).
DEFAULT_TRIAL_DAYS = 7
DEFAULT_TRIAL_CREDITS = 15
DEFAULT_PROBASHI_PRICE_USD = 4.99

# Referral points economy (admin-editable under cfg["referral"]); mirrors the
# defaults in core.logic.referral.
_REFERRAL_DEFAULTS = {
    "points_per_referral": 50,
    "welcome_bonus_points": 20,
    "points_per_premium_day": 25,
    "min_redeem_points": 25,
    "monthly_referral_cap": 20,
    "max_redeem_days": 400,
}

GB = 1024 ** 3


def DEFAULTS():
    """The shipped default config dict (deep copy each call — never share refs)."""
    return {
        "plans": {
            # v2: Business 999 -> 499, Premium 199, Free 0. Monthly included
            # credit POOL (granted monthly, reset not accumulated — no rollover):
            # Free 0, Premium 90, Business 240.
            "free":     {"price": 0,   "credits": 0,   "unlimited_ai": False,
                         "ads": True,  "family": 0,
                         "storage_bytes": 1 * GB},
            "premium":  {"price": 199, "credits": 90,  "unlimited_ai": True,
                         "ads": False, "family": 5,
                         "storage_bytes": 5 * GB},
            "business": {"price": 499, "credits": 240, "unlimited_ai": True,
                         "ads": False, "family": 0,
                         "storage_bytes": 15 * GB},
        },
        "topup_packs": [dict(p) for p in _TOPUP_PACKS],
        "annual_discount_pct": 20,     # % off 12 months of Premium
        "action_costs": {k: dict(v) for k, v in _ACTION_DEFAULTS.items()},
        "margin": DEFAULT_MARGIN,
        "credit_bdt": DEFAULT_CREDIT_BDT,
        "usd_bdt": DEFAULT_USD_BDT,
        # NET-revenue fee structure (admin-editable)
        "play_fee": DEFAULT_PLAY_FEE,
        "gateway_fee": DEFAULT_GATEWAY_FEE,
        "vat": DEFAULT_VAT,
        # ad-funded wallet (free users) — admin-editable, deliberately tiny
        # defaults before we have real BD fill-rate / eCPM data.
        "ad_rewards": {
            "ecpm_bdt": 30.0,          # BD eCPM floor (৳ per 1000 impressions)
            "revenue_share": 0.70,     # credit the user at <=70% of the floor
            "appopen_min_gap_sec": 3 * 3600,   # app-open >= 3h apart
            "appopen_daily_cap": 4,
            "rewarded_daily_cap": 5,
            "interstitial_daily_cap": 10,
            "native_daily_cap": 20,
        },
        # daily profit guard thresholds (admin-editable)
        "profit_guard": {
            "spend_cap_pct": 0.60,     # variable cost <= 60% of NET revenue
            "approach_pct": 0.80,      # 'near' at 80% of that cap
        },
        # owner P&L fixed overhead per day (Build 3) — ৳/day server + infra cost,
        # admin-editable. Default ~৳300/day (a small cloud box) as a sensible
        # starting figure the owner tunes from the /admin/pnl dashboard.
        "fixed_cost_per_day": 300.0,
        # owner DEFAULT home quick buttons (6 ChatNav route keys) — shown to
        # users who have not customized their own (core.logic.home_defaults).
        "home_quick_defaults": list(HD.DEFAULT),
        # NET-margin guarantees (admin-editable, bounded)
        "guarantees": {"margin_net_floor": MARGIN_NET_FLOOR,
                       "pool_cap_pct_of_net": POOL_CAP_PCT_OF_NET},
        # plan/trial/camera limits (admin-editable)
        "limits": {
            "trial_days": DEFAULT_TRIAL_DAYS,
            "trial_credits": DEFAULT_TRIAL_CREDITS,
            "business_included_cameras": BUSINESS_INCLUDED_CAMERAS,
        },
        "probashi_price_usd": DEFAULT_PROBASHI_PRICE_USD,
        # 0 = use the server env AI_DAILY_BUDGET_USD kill-switch default
        "ai_daily_budget_usd": 0.0,
        "ai_user_daily_limit": 0,
        "referral": dict(_REFERRAL_DEFAULTS),
    }


def _num(v, fallback):
    try:
        if isinstance(v, bool):      # bool is an int subclass — reject it as a number
            return fallback
        return float(v)
    except (TypeError, ValueError):
        return fallback


def _int(v, fallback):
    n = _num(v, None)
    return int(n) if n is not None else fallback


def _bool(v, fallback):
    if isinstance(v, bool):
        return v
    if v in (1, 0):
        return bool(v)
    if isinstance(v, str) and v.lower() in ("true", "false", "1", "0"):
        return v.lower() in ("true", "1")
    return fallback


def normalize(data):
    """Project an arbitrary stored dict onto the known config shape, filling
    defaults for anything missing / malformed. Never mutates `data`. Pure."""
    d = data or {}
    base = DEFAULTS()

    # plans
    plans = {}
    for pid, pdef in base["plans"].items():
        raw = (d.get("plans") or {}).get(pid) or {}
        plans[pid] = {
            "price": max(0, _int(raw.get("price"), pdef["price"])),
            "credits": max(0, _int(raw.get("credits"), pdef["credits"])),
            "unlimited_ai": _bool(raw.get("unlimited_ai"), pdef["unlimited_ai"]),
            "ads": _bool(raw.get("ads"), pdef["ads"]),
            "family": max(0, _int(raw.get("family"), pdef["family"])),
            "storage_bytes": max(0, _int(raw.get("storage_bytes"),
                                         pdef["storage_bytes"])),
        }

    # topup packs — keep the known shape; owner may edit price/credits/validity.
    packs = []
    raw_packs = d.get("topup_packs")
    src = raw_packs if isinstance(raw_packs, list) and raw_packs else base["topup_packs"]
    for p in src:
        if not isinstance(p, dict) or not p.get("id"):
            continue
        packs.append({
            "id": str(p["id"])[:16],
            "price": max(0, _int(p.get("price"), 0)),
            "credits": max(0, _int(p.get("credits"), 0)),
            "valid_months": max(1, _int(p.get("valid_months"), 12)),
        })
    if not packs:
        packs = [dict(p) for p in base["topup_packs"]]

    # action costs
    costs = {}
    for aid, adef in base["action_costs"].items():
        raw = (d.get("action_costs") or {}).get(aid) or {}
        costs[aid] = {
            "provider_cost": max(0.0, _num(raw.get("provider_cost"), adef["provider_cost"])),
            "credits": max(0, _int(raw.get("credits"), adef["credits"])),
        }
    # keep any owner-added custom actions too (future-proof), clamped
    for aid, raw in (d.get("action_costs") or {}).items():
        if aid not in costs and isinstance(raw, dict):
            costs[aid] = {
                "provider_cost": max(0.0, _num(raw.get("provider_cost"), 0.0)),
                "credits": max(0, _int(raw.get("credits"), 1)),
            }

    return {
        "plans": plans,
        "topup_packs": packs,
        "annual_discount_pct": max(0, min(90, _int(d.get("annual_discount_pct"),
                                                   base["annual_discount_pct"]))),
        "action_costs": costs,
        "margin": max(0.0, _num(d.get("margin"), base["margin"])),
        "credit_bdt": max(0.01, _num(d.get("credit_bdt"), base["credit_bdt"])),
        "usd_bdt": max(0.01, _num(d.get("usd_bdt"), base["usd_bdt"])),
        "play_fee": max(0.0, min(0.95, _num(d.get("play_fee"), base["play_fee"]))),
        "gateway_fee": max(0.0, min(0.95, _num(d.get("gateway_fee"),
                                               base["gateway_fee"]))),
        "vat": max(0.0, min(0.95, _num(d.get("vat"), base["vat"]))),
        "ad_rewards": _norm_ad_rewards(d.get("ad_rewards"), base["ad_rewards"]),
        "profit_guard": _norm_profit_guard(d.get("profit_guard"),
                                           base["profit_guard"]),
        "fixed_cost_per_day": max(0.0, _num(d.get("fixed_cost_per_day"),
                                            base["fixed_cost_per_day"])),
        "home_quick_defaults": HD.normalize(d.get("home_quick_defaults")),
        "guarantees": _norm_guarantees(d.get("guarantees"), base["guarantees"]),
        "limits": _norm_limits(d.get("limits"), base["limits"]),
        "probashi_price_usd": round(max(0.0, _num(d.get("probashi_price_usd"),
                                                  base["probashi_price_usd"])), 2),
        "ai_daily_budget_usd": max(0.0, _num(d.get("ai_daily_budget_usd"),
                                             base["ai_daily_budget_usd"])),
        "ai_user_daily_limit": max(0, _int(d.get("ai_user_daily_limit"),
                                           base["ai_user_daily_limit"])),
        "referral": _norm_referral(d.get("referral"), base["referral"]),
    }


def _norm_guarantees(raw, base):
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, (lo, hi) in GUARANTEE_BOUNDS.items():
        out[k] = max(lo, min(hi, _num(raw.get(k), base[k])))
    return out


def _norm_limits(raw, base):
    raw = raw if isinstance(raw, dict) else {}
    return {
        "trial_days": max(0, min(90, _int(raw.get("trial_days"), base["trial_days"]))),
        "trial_credits": max(0, _int(raw.get("trial_credits"), base["trial_credits"])),
        "business_included_cameras": max(0, min(64, _int(
            raw.get("business_included_cameras"), base["business_included_cameras"]))),
    }


def _norm_referral(raw, base):
    raw = raw if isinstance(raw, dict) else {}
    out = {k: max(0, _int(raw.get(k), v)) for k, v in base.items()}
    out["points_per_premium_day"] = max(1, out["points_per_premium_day"])
    out["min_redeem_points"] = max(1, out["min_redeem_points"])
    out["max_redeem_days"] = max(1, out["max_redeem_days"])
    return out


def net_floor(cfg):
    """The admin-editable NET-margin floor (default 0.60)."""
    return normalize(cfg)["guarantees"]["margin_net_floor"]


def pool_cap(cfg):
    """The admin-editable included-pool cap as a share of NET revenue (0.60)."""
    return normalize(cfg)["guarantees"]["pool_cap_pct_of_net"]


def limits(cfg):
    """The normalized business limits dict (trial, cameras)."""
    return normalize(cfg)["limits"]


def _norm_ad_rewards(raw, base):
    raw = raw if isinstance(raw, dict) else {}
    return {
        "ecpm_bdt": max(0.0, _num(raw.get("ecpm_bdt"), base["ecpm_bdt"])),
        "revenue_share": max(0.0, min(0.70, _num(raw.get("revenue_share"),
                                                 base["revenue_share"]))),
        "appopen_min_gap_sec": max(0, _int(raw.get("appopen_min_gap_sec"),
                                           base["appopen_min_gap_sec"])),
        "appopen_daily_cap": max(0, _int(raw.get("appopen_daily_cap"),
                                         base["appopen_daily_cap"])),
        "rewarded_daily_cap": max(0, _int(raw.get("rewarded_daily_cap"),
                                          base["rewarded_daily_cap"])),
        "interstitial_daily_cap": max(0, _int(raw.get("interstitial_daily_cap"),
                                              base["interstitial_daily_cap"])),
        "native_daily_cap": max(0, _int(raw.get("native_daily_cap"),
                                        base["native_daily_cap"])),
    }


def _norm_profit_guard(raw, base):
    raw = raw if isinstance(raw, dict) else {}
    return {
        "spend_cap_pct": max(0.0, min(1.0, _num(raw.get("spend_cap_pct"),
                                                base["spend_cap_pct"]))),
        "approach_pct": max(0.0, min(1.0, _num(raw.get("approach_pct"),
                                               base["approach_pct"]))),
    }


# ---------------------------------------------------------------- v2 helpers

def topup_packs(cfg):
    """The list of purchasable credit packs from config."""
    return normalize(cfg)["topup_packs"]


def pack_by_id(pack_id, cfg):
    """One pack dict by id, or None."""
    for p in normalize(cfg)["topup_packs"]:
        if p["id"] == pack_id:
            return p
    return None


def storage_quota_bytes(plan_id, cfg):
    """Base storage quota (bytes) for a config-backed plan; 0 if unknown."""
    row = normalize(cfg)["plans"].get(plan_id)
    return int(row["storage_bytes"]) if row else 0


def net_fraction(cfg):
    """The fraction of a plan's gross price the business keeps after store cut,
    gateway fee and VAT: (1 - play_fee - gateway_fee - vat), clamped to >0."""
    cfg = normalize(cfg)
    keep = 1.0 - cfg["play_fee"] - cfg["gateway_fee"] - cfg["vat"]
    return max(0.0001, keep)


def net_plan_revenue(plan_id, cfg):
    """NET ৳ a plan actually earns per month = price * net_fraction."""
    cfg = normalize(cfg)
    row = cfg["plans"].get(plan_id)
    if not row:
        return 0.0
    return float(row["price"]) * net_fraction(cfg)


def action_credit_floor(action, cfg):
    """Minimum credits an action MUST charge to hold the NET-margin guarantee:
    credit ৳-value >= provider_cost ÷ MARGIN_NET_FLOOR (0.60), expressed in
    credits. provider_cost is USD; converted to ৳ via usd_bdt, divided by
    credit_bdt. Returns ceil(...) credits (0 for an unknown/free action)."""
    cfg = normalize(cfg)
    row = cfg["action_costs"].get(action)
    if not row or row["provider_cost"] <= 0:
        return 0
    cost_bdt = row["provider_cost"] * cfg["usd_bdt"]
    need_face_bdt = cost_bdt / cfg["guarantees"]["margin_net_floor"]
    return max(1, int(math.ceil(need_face_bdt / cfg["credit_bdt"])))


# ---------------------------------------------------------------- cost reads

def credit_cost(action, cfg):
    """Credits charged for ONE unit of `action`. Unknown action -> 0 (never
    accidentally charge for something unpriced)."""
    cfg = normalize(cfg)
    row = cfg["action_costs"].get(action)
    return int(row["credits"]) if row else 0


def credits_for(action, qty, cfg):
    """Credits for `qty` units of `action` (qty clamped to >= 1)."""
    return credit_cost(action, cfg) * max(1, int(qty or 1))


def recompute_from_provider_cost(action, cfg):
    """AUTO-RE-PRICING helper on the NET basis (Build 2). Given the action's
    provider_cost (USD), return the credit count that holds BOTH:

      * the legacy margin target:  price_bdt = cost_bdt * (1 + margin)
      * the NET-margin guarantee:  credit ৳-value >= cost_bdt / MARGIN_NET_FLOOR

    We take the stricter (larger) of the two so an action can never break the
    60%-NET floor. Pure; >=1 for any priced action, 0 for an unknown one."""
    cfg = normalize(cfg)
    row = cfg["action_costs"].get(action)
    if not row or row["provider_cost"] <= 0:
        return 0
    bdt_cost = row["provider_cost"] * cfg["usd_bdt"]
    margin_credits = math.ceil(bdt_cost * (1.0 + cfg["margin"]) / cfg["credit_bdt"])
    net_credits = action_credit_floor(action, cfg)   # the NET-floor minimum
    return max(1, int(margin_credits), int(net_credits))


def recompute_all(cfg):
    """Return a NEW normalized cfg whose every action `credits` is recomputed
    from provider_cost to hold the margin. Used by auto-reprice mode."""
    cfg = normalize(cfg)
    out = {k: (dict(v) if isinstance(v, dict) else v) for k, v in cfg.items()}
    out["plans"] = {k: dict(v) for k, v in cfg["plans"].items()}
    out["action_costs"] = {}
    for aid, row in cfg["action_costs"].items():
        new_credits = recompute_from_provider_cost(aid, cfg)
        out["action_costs"][aid] = {"provider_cost": row["provider_cost"],
                                    "credits": new_credits or row["credits"]}
    return out


# ---------------------------------------------------------------- validation

def validate_edit(data):
    """Return a list of problem codes for a proposed config; empty == OK.

    Codes: 'margin_negative', 'margin_below_target', 'price_negative',
    'credits_negative', 'provider_cost_negative', 'bad_credit_basis',
    'bad_fee' (fees out of [0,1) or summing >=1), 'action_breaks_margin'
    (an action charges fewer credits than the NET-margin floor requires), and
    'pool_exceeds_net' (a plan's monthly included-pool face value > 60% of its
    NET revenue). The last two are the Build-2 NET-margin guarantee."""
    d = data or {}
    problems = []
    margin = _num(d.get("margin"), None)
    if margin is not None:
        if margin < 0:
            problems.append("margin_negative")
        elif margin < DEFAULT_MARGIN:
            problems.append("margin_below_target")
    for pid, raw in (d.get("plans") or {}).items():
        if isinstance(raw, dict):
            if _num(raw.get("price"), 0) < 0:
                problems.append("price_negative")
            if _num(raw.get("credits"), 0) < 0:
                problems.append("credits_negative")
    for aid, raw in (d.get("action_costs") or {}).items():
        if isinstance(raw, dict):
            if _num(raw.get("provider_cost"), 0) < 0:
                problems.append("provider_cost_negative")
            if _num(raw.get("credits"), 0) < 0:
                problems.append("credits_negative")
    cb = _num(d.get("credit_bdt"), None)
    if cb is not None and cb <= 0:
        problems.append("bad_credit_basis")
    g = d.get("guarantees")
    if g is not None:
        if not isinstance(g, dict):
            problems.append("bad_guarantee")
        else:
            for k, (lo, hi) in GUARANTEE_BOUNDS.items():
                if k in g:
                    v = _num(g.get(k), None)
                    if v is None or v < lo or v > hi:
                        problems.append("bad_guarantee")
    for sect in ("limits", "referral"):
        sv = d.get(sect)
        if sv is None:
            continue
        if not isinstance(sv, dict):
            problems.append("limit_negative")
            continue
        for k, v in sv.items():
            n = _num(v, None)
            if n is None or n < 0:
                problems.append("limit_negative")
    for k in ("probashi_price_usd", "ai_daily_budget_usd", "ai_user_daily_limit"):
        if k in d:
            n = _num(d.get(k), None)
            if n is None or n < 0:
                problems.append("price_negative")
    if "home_quick_defaults" in d:
        problems.extend(HD.validate(d.get("home_quick_defaults")))

    # ---- Build 2: NET fee sanity + per-action margin + pool cap ----
    cfg = normalize(d)              # fills defaults so partial edits still validate
    for fkey in ("play_fee", "gateway_fee", "vat"):
        fv = _num(d.get(fkey), None)
        if fv is not None and (fv < 0 or fv >= 1):
            problems.append("bad_fee")
    if (cfg["play_fee"] + cfg["gateway_fee"] + cfg["vat"]) >= 1.0:
        problems.append("bad_fee")

    # every priced action's credits must be >= the NET-margin floor
    for aid, row in cfg["action_costs"].items():
        floor = action_credit_floor(aid, cfg)
        if floor and row["credits"] < floor:
            problems.append("action_breaks_margin")
            break

    # a plan's monthly included-pool face value must not exceed 60% of NET rev
    for pid, row in cfg["plans"].items():
        net = net_plan_revenue(pid, cfg)
        pool_face = row["credits"] * cfg["credit_bdt"]
        if net > 0 and pool_face > cfg["guarantees"]["pool_cap_pct_of_net"] * net:
            problems.append("pool_exceeds_net")
            break

    return list(dict.fromkeys(problems))   # ordered-unique


# ---------------------------------------------------------------- plans_public

def plan_public(lang, cfg):
    """Build the localized public plans list from config. REPLACES the hard-coded
    Free/Premium/Business entries in core/plans.py. probashi/founder are handled
    by core/plans.py (founder hidden; probashi appended there)."""
    from ..i18n import pick
    cfg = normalize(cfg)
    out = []
    for pid in PLAN_ORDER:
        s = cfg["plans"][pid]
        meta = _PLAN_META[pid]
        entry = {
            "id": pid,
            "name": pick(lang, meta["name_bn"], meta["name_en"]),
            "price": s["price"], "cur": CUR, "period": "mo",
            "desc": pick(lang, meta["desc_bn"], meta["desc_en"]),
            "benefits": meta["benefits_" + lang],
            "unlimited_ai": s["unlimited_ai"], "ads": s["ads"],
            "family": s["family"], "credits": s["credits"],
            "storage_bytes": s["storage_bytes"],
        }
        out.append(entry)
    # annual (Premium yearly with discount) — derived, not a separate plan row
    prem = cfg["plans"]["premium"]
    disc = cfg["annual_discount_pct"]
    annual_price = int(round(prem["price"] * 12 * (100 - disc) / 100.0))
    out.append({
        "id": "annual",
        "name": pick(lang, "বার্ষিক (প্রিমিয়াম)", "Annual (Premium)"),
        "price": annual_price, "cur": CUR, "period": "yr",
        "desc": pick(lang, f"প্রিমিয়াম — বছরে, {disc}% সাশ্রয়।",
                     f"Premium — yearly, save {disc}%."),
        "benefits": _PLAN_META["premium"]["benefits_" + lang],
        "unlimited_ai": True, "ads": False, "family": prem["family"],
        "credits": 0,
    })
    return out


def make_audit_entry(path, old, new, actor, reason, at_iso):
    """Build ONE append-only audit entry for a pricing edit. Caller supplies the
    timestamp + actor; the engine never reads a clock or identity."""
    return {
        "path": path, "old": old, "new": new,
        "actor": actor, "reason": (reason or "").strip(), "at": at_iso,
    }
