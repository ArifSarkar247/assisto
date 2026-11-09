"""aifinal PART 3: answer levels (Normal / Better / Best) on top of the AI
router — config, prices, availability and the app payload. The pure math
lives in core/logic/ai_levels.py; the call itself in core/ai.py generate
(`level=`)."""
from .i18n import pick
from .logic import ai_levels as AL

NAMES = {"normal": ("সাধারণ", "Normal"), "better": ("ভালো", "Better"),
         "best": ("সেরা", "Best")}


def cfg(c=None):
    """(levels block, full PricingConfig dict). geminioff: while the Gemini
    breaker is open every Gemini level row is served as its Claude twin
    (effective_levels) — prices, fallbacks and availability follow it."""
    from . import billing
    c = c or billing.cfg()
    lv = AL.normalize(c.get("ai_levels"))
    try:
        from . import gemini_breaker as GB
        if GB.is_open():
            lv["levels"] = effective_levels(lv["levels"])
    except Exception:  # noqa: BLE001 — routing never breaks the answer
        pass
    return lv, c


# geminioff (owner 9 Nov 13:30): Normal + Better = Claude Haiku 5.5, Best =
# Claude Sonnet 5.5 while Gemini is off. Better keeps its LARGER budget: the
# Haiku answer cap (fallback_out_cap, else 2500) and at least 8000 in.
CLAUDE_TWIN = {"normal": "claude-haiku-5-5", "better": "claude-haiku-5-5",
               "best": "claude-sonnet-5-5"}


def effective_levels(levels):
    out = {}
    for lid, row in levels.items():
        r = dict(row)
        if r.get("provider") == "gemini":
            r["provider"] = "anthropic"
            r["model"] = CLAUDE_TWIN.get(lid, "claude-haiku-5-5")
            if lid == "better":
                r["out_cap"] = max(int(r.get("out_cap") or 0),
                                   int(r.get("fallback_out_cap") or 0) or 2500)
                r["in_cap"] = max(int(r.get("in_cap") or 0), 8000)
                r["history_turns"] = max(int(r.get("history_turns") or 0), 16)
            r["fallback_out_cap"] = 0
            r["gemini_off"] = True
        out[lid] = r
    return out


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
    if (c.get("pricing_v2") or {}).get("on"):
        from .logic import plan_book as _BOOK
        rate = max(rate, _BOOK.SAFETY_USD_BDT)     # plansprep: costs at >= ৳125/USD
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
    call, and it is under its own daily budget cap (Owner Admin -> AI).
    geminifix: when the level's own model hit a 404/402/403 hard error
    (retired model, billing off, key permission) but a SAME-OR-CHEAPER
    fallback can answer, the level stays available — the user gets a normal answer
    at the level's own price, never "temporarily unavailable"."""
    from . import ai
    from . import ai_health as AH
    from . import ai_router as R
    from .gemini_models import resolve
    lv, c = cfg(c)
    row = lv["levels"][lid]
    conf = R.cfg()
    if R.total_capped(conf):
        return False, "budget"
    connected = dict(ai._providers())

    def why_not(prov, model):
        if prov not in connected:
            return "not_connected"
        if R.provider_capped(prov, conf):
            return "budget"
        if prov == "gemini":
            model = resolve(model, "text", conf["prices"])
        if AH.is_down(prov, model):
            return "down"
        if not R.allow(prov, conf):
            return "circuit"
        return ""

    first = why_not(row["provider"], row["model"])
    if not first:
        return True, "ok"
    if first != "down":
        return False, first     # caps / circuit: the level's own honest state
    prices = conf["prices"]
    for prov, model in AL.fallbacks(lv["levels"], lid, prices):
        if not why_not(prov, model):
            return True, "fallback"
    return False, first


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


# ---------------------------------------------------------------- PART 4
WELCOME_KIND = "ai_welcome"


def phone_verified(user):
    """The account's phone passed an SMS/e-mail OTP (a consumed challenge)."""
    try:
        from .models import OtpChallenge, PhoneVerification
        from .phone import canonical_phone
        ph = canonical_phone(getattr(user, "phone", "") or "")
        if not ph:
            return False
        if PhoneVerification.objects.filter(user=user, phone=ph).exists():
            return True
        return OtpChallenge.objects.filter(phone=ph, consumed_at__isnull=False).exists()
    except Exception:  # noqa: BLE001 — fails closed (no grant)
        return False


def grant_welcome(user, device_id=""):
    """The 20 free AI credits — ONCE per person: one per verified phone AND
    device AND e-mail, even after delete + re-signup (antifarm tombstones).
    They land in the FREE bucket, so they pay only for the free-credit levels
    (Normal). Returns (granted_credits, reason)."""
    from django.db import transaction
    from . import antifarm
    from . import credits as CR
    from .models import User
    lv, _ = cfg()
    if not (lv["enabled"] and lv["welcome_on"]) or lv["welcome_credits"] <= 0:
        return 0, "off"
    if not device_id:
        return 0, "no_device"
    if not phone_verified(user):
        return 0, "phone_not_verified"
    with transaction.atomic():
        u = User.objects.select_for_update().get(pk=user.pk)
        keys = antifarm.keys_for(u, device_id)
        if not keys or antifarm.claimed(WELCOME_KIND, keys):
            return 0, "already_claimed"
        if not antifarm.claim(WELCOME_KIND, keys):
            return 0, "already_claimed"
        CR.grant(u, CR.FREE, lv["welcome_credits"], reason="trial", note="ai_welcome",
                 source_type="ai_welcome", source_id="ai_welcome")
    user.refresh_from_db(fields=["ai_credits"])
    return lv["welcome_credits"], "ok"


def ad_credits(c=None):
    """Credits one verified rewarded ad buys while levels are on: N Normal
    answers (owner ratio). None = levels off (the eCPM wallet rule applies)."""
    lv, c = cfg(c)
    if not lv["enabled"]:
        return None
    return int(lv["ad_answers_per_ad"]) * credits("normal", c)


def ad_paisa(c=None):
    """plansprep (owner 9 Nov item 8): paisa of credit ONE verified rewarded
    ad adds to the ad wallet while levels are on: ad_answers_per_ad Normal
    answers per ads_per_answer ads (2 ads = 1 Normal answer = 50 paisa an ad;
    the wallet moves whole credits only). None = levels off."""
    lv, c = cfg(c)
    if not lv["enabled"]:
        return None
    per = max(1, int(lv.get("ads_per_answer") or 1))
    return int(int(lv["ad_answers_per_ad"]) * credits("normal", c) * 100 // per)


def over_daily_limit(user, lid, now=None):
    """Per-user answers per day for this level (owner-editable; 0 = none)."""
    from . import ai_router as R
    from .models import AIUsage
    lv, _ = cfg()
    cap = int(lv["levels"][lid].get("per_day") or 0)
    if user is None or cap <= 0:
        return False
    n = AIUsage.objects.filter(user=user, level=lid, ok=True,
                               created_at__gte=R.day_start(now)).count()
    return n >= cap


# Every AI call either debits the user (ai.generate with user=...) or is on
# this documented list (owner order PART 4). A CI test scans every caller.
FREE_EXEMPT = {
    "eval.": "owner-only quality evals (manage.py ai_eval), never user-facing",
    "smoke": "owner-only live smoke check (core/ai_live_smoke.py)",
    "bizagent.reply": "billed once per reply by bizagent consume_reply (ai_sales)",
    "w1_cv": "public website CV tips, per-IP rate limited, no account",
    "w2_scam": "public website scam check (safety), per-IP rate limited, no account",
    "learn.roleplay": "Learn hub daily free practice quota; beyond it the user pays",
    "chat.continue": "continues an answer that was CUT at its output limit — already paid once",
}


def exempt(feature):
    f = str(feature or "")
    return any(f == k or (k.endswith(".") and f.startswith(k)) for k in FREE_EXEMPT)


def ad_table(c=None):
    """Owner Admin: what one rewarded ad buys and its worst-case profit."""
    from .logic import photo_studio as PS
    lv, c = cfg(c)
    prices, rate, _, _ = _economics(c)
    try:
        val = float(PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"]))
    except Exception:  # noqa: BLE001
        val = 0.0
    n = int(lv["ad_answers_per_ad"])
    return {"answers": n, "ad_value_bdt": round(val, 4),
            "profit_pct": AL.ad_profit_pct(lv["levels"]["normal"], n, prices, rate, val)}


# ---------------------------------------------------------------- web search
import re as _re
RECENT = _re.compile(
    r"\b(today|latest|news|current(?:ly)?|right now|this week|price (?:now|today)|score|"
    r"weather|exchange rate|dollar rate|20[2-3]\d)\b|আজ|আজকের|সর্বশেষ|খবর|এখন(?:কার)? দাম|"
    r"আবহাওয়া|ডলারের রেট|ajker|aj ke|latest", _re.I)


def web_credits(c=None):
    """Extra credits for one grounded answer (worst case, 40 % rule)."""
    import math
    lv, c = cfg(c)
    _, rate, safe, _ = _economics(c)
    if safe <= 0:
        return 0
    return int(math.ceil(lv["web_usd_per_prompt"] * rate / safe))


def wants_web(text, lid, c=None):
    """Use web search for this turn? Only for recent / changing facts and only
    while the owner switch is on. plansprep (owner 9 Nov item 9): any level —
    the free daily Gemini grounding quota is used first (web_route), then
    Claude web search; the user pays web_credits() only when a search ran."""
    lv, _ = cfg(c)
    if not lv.get("web_on") or not RECENT.search(text or ""):
        return False
    return lid in lv["levels"]


def gemini_web_model(c=None):
    """The Gemini model a grounded turn runs on: the first Gemini level's
    model, else the configured Gemini text model."""
    lv, _ = cfg(c)
    for lid in AL.LEVEL_IDS:
        row = lv["levels"][lid]
        if row["provider"] == "gemini":
            return row["model"]
    return (lv.get("gemini_models") or {}).get("text") or "gemini-3.5-flash-lite"


def gemini_web_left(now=None, c=None):
    """Free Gemini grounding prompts left today (web_free_per_day minus the
    grounded answers already given today)."""
    from . import ai_router as R
    from .models import AIUsage
    lv, _ = cfg(c)
    cap = int(lv.get("web_free_per_day") or 0)
    if cap <= 0:
        return 0
    from . import gemini_breaker as GB
    if GB.is_open():
        return 0          # geminioff: web search = Claude web search only
    used = AIUsage.objects.filter(created_at__gte=R.day_start(now), provider="gemini",
                                  attempts__contains="gemini:ok:web").count()
    return max(0, cap - used)
