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
    "ai_msg_strong":       {"provider_cost": 0.030, "credits": 5},
    # non-AI costly actions
    "scan_ocr":            {"provider_cost": 0.004, "credits": 2},
    "photo_enhance":       {"provider_cost": 0.004, "credits": 2},
    "video_min":           {"provider_cost": 0.002, "credits": 1},
    "remote_support_min":  {"provider_cost": 0.004, "credits": 2},
    "ivr_call":            {"provider_cost": 0.006, "credits": 3},
    "sms":                 {"provider_cost": 0.002, "credits": 1},
    "voice_clone":         {"provider_cost": 0.010, "credits": 5},
    "ai_sales":            {"provider_cost": 0.006, "credits": 3},
}

# tier (core/ai.py) -> action id
TIER_ACTION = {
    "cheap": "ai_msg_cheap",
    "medium": "ai_msg_medium",
    "strong": "ai_msg_strong",
}


def DEFAULTS():
    """The shipped default config dict (deep copy each call — never share refs)."""
    return {
        "plans": {
            "free":     {"price": 0,   "credits": 15, "unlimited_ai": False,
                         "ads": True,  "family": 0},
            "premium":  {"price": 199, "credits": 0,  "unlimited_ai": True,
                         "ads": False, "family": 5},
            "business": {"price": 999, "credits": 0,  "unlimited_ai": True,
                         "ads": False, "family": 0},
        },
        "annual_discount_pct": 20,     # % off 12 months of Premium
        "action_costs": {k: dict(v) for k, v in _ACTION_DEFAULTS.items()},
        "margin": DEFAULT_MARGIN,
        "credit_bdt": DEFAULT_CREDIT_BDT,
        "usd_bdt": DEFAULT_USD_BDT,
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
        }

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
        "annual_discount_pct": max(0, min(90, _int(d.get("annual_discount_pct"),
                                                   base["annual_discount_pct"]))),
        "action_costs": costs,
        "margin": max(0.0, _num(d.get("margin"), base["margin"])),
        "credit_bdt": max(0.01, _num(d.get("credit_bdt"), base["credit_bdt"])),
        "usd_bdt": max(0.01, _num(d.get("usd_bdt"), base["usd_bdt"])),
    }


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
    """AUTO-RE-PRICING helper. Given the action's provider_cost (USD), return the
    credit count that preserves the margin target:

        bdt_cost = provider_cost_usd * usd_bdt
        price_bdt = bdt_cost * (1 + margin)
        credits = ceil(price_bdt / credit_bdt)

    Pure; returns an int >= 1 for any priced action, 0 for an unknown one."""
    cfg = normalize(cfg)
    row = cfg["action_costs"].get(action)
    if not row:
        return 0
    bdt_cost = row["provider_cost"] * cfg["usd_bdt"]
    price_bdt = bdt_cost * (1.0 + cfg["margin"])
    credits = math.ceil(price_bdt / cfg["credit_bdt"])
    return max(1, int(credits)) if row["provider_cost"] > 0 else 0


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
    'credits_negative', 'provider_cost_negative', 'bad_credit_basis'."""
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
