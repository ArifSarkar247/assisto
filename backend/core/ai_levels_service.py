"""aifinal PART 3: answer levels (Normal / Better / Best) on top of the AI
router — config, prices, availability and the app payload. The pure math
lives in core/logic/ai_levels.py; the call itself in core/ai.py generate
(`level=`)."""
from .i18n import pick
from .logic import ai_levels as AL

NAMES = {"normal": ("সাধারণ", "Normal"), "better": ("ভালো", "Better"),
         "best": ("সেরা", "Best")}


def cfg(c=None):
    """(levels block, full PricingConfig dict)."""
    from . import billing
    c = c or billing.cfg()
    return AL.normalize(c.get("ai_levels")), c


def enabled(c=None):
    try:
        return cfg(c)[0]["enabled"]
    except Exception:  # noqa: BLE001
        return False


def _economics(c):
    from . import ai_router as R
    from .logic import pricing_40 as P40
    prices = R.cfg()["prices"]
    rate = float(c.get("usd_bdt") or 120.0)
    safe = P40.safe_bdt_per_credit(c)
    rows = P40.bdt_per_credit_rows(c)
    cheapest = min(r[1] for r in rows) if rows else 0.0
    return prices, rate, safe, cheapest


def credits(lid, c=None):
    lv, c = cfg(c)
    prices, rate, safe, _ = _economics(c)
    return AL.credits_for(lv["levels"][lid], prices, rate, safe)


def spec(lid, c=None):
    """Everything generate() needs for one level, or None when unknown."""
    lv, c = cfg(c)
    if lid not in AL.LEVEL_IDS:
        return None
    prices, rate, safe, _ = _economics(c)
    row = dict(lv["levels"][lid])
    row["id"] = lid
    row["credits"] = AL.credits_for(row, prices, rate, safe)
    row["fallbacks"] = AL.fallbacks(lv["levels"], lid, prices)
    row["free_ok"] = lid in lv["free_credit_levels"]
    return row


def available(lid, c=None):
    """(ok, why): the level's provider is connected, its circuit allows a
    call, and it is under its own daily budget cap (Owner Admin -> AI)."""
    from . import ai
    from . import ai_router as R
    lv, c = cfg(c)
    prov = lv["levels"][lid]["provider"]
    if prov not in dict(ai._providers()):
        return False, "not_connected"
    conf = R.cfg()
    if R.total_capped(conf) or R.provider_capped(prov, conf):
        return False, "budget"
    if not R.allow(prov, conf):
        return False, "circuit"
    return True, "ok"


def table(c=None):
    """Owner Admin rows: worst cost, minimum + charged credits, profit %."""
    lv, c = cfg(c)
    prices, rate, safe, cheapest = _economics(c)
    out = []
    for lid in AL.LEVEL_IDS:
        row = lv["levels"][lid]
        n = AL.credits_for(row, prices, rate, safe)
        out.append({"id": lid, **row,
                    "worst_usd": round(AL.worst_cost_usd(row, prices), 6),
                    "worst_bdt": round(AL.worst_cost_usd(row, prices) * rate, 4),
                    "min_credits": AL.min_credits(row, prices, rate, safe),
                    "charged": n,
                    "profit_pct": AL.profit_pct(row, n, prices, rate, cheapest)})
    return {"rows": out, "usd_bdt": rate, "safe_bdt_per_credit": safe,
            "cheapest_bdt_per_credit": round(cheapest, 4)}


def resolve(requested, c=None):
    """The level for a turn: the app's choice when known, else the default.
    NEVER a dearer level than the user picked."""
    lv, _ = cfg(c)
    r = str(requested or "").strip().lower()
    return r if r in AL.LEVEL_IDS else lv["default"]


def app_payload(user, lang="bn", c=None):
    """GET /chat/levels: what the picker shows (estimated credits before
    sending, max length, temporarily unavailable). Provider-neutral."""
    lv, c = cfg(c)
    if not lv["enabled"]:
        return {"enabled": False, "levels": []}
    rows = []
    for lid in AL.LEVEL_IDS:
        ok, why = available(lid, c)
        row = lv["levels"][lid]
        rows.append({"id": lid, "name": pick(lang, *NAMES[lid]),
                     "credits": credits(lid, c), "max_chars": row["max_chars"],
                     "available": ok, "free_credits_ok": lid in lv["free_credit_levels"],
                     **({} if ok else {"why": "temporarily_unavailable"})})
    from . import ai_chat_guard as G
    return {"enabled": True, "default": lv["default"], "levels": rows,
            "balance": G.balance(user)}
