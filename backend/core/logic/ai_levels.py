"""aifinal (owner AI order 3 Nov 23:15, PART 3): the answer level the USER
chooses above the AI chat input. Pure logic (no DB, no network).

  Normal = Gemini 3.5 Flash-Lite (default)   Better = Claude Haiku 5.5
  Best   = Claude Sonnet 5.5

Prices (USD per 1M tokens, checked 3 Nov 2026 on the official pages):
  * gemini-3.5-flash-lite  in 0.30 / out 2.50   https://aistudio.google.com/docs/pricing
    (geminifix 4 Nov: gemini-2.5-flash is deprecated and no longer offered
    to new keys — HTTP 404 live; 3.5-flash-lite is Google's named
    replacement at the same price, see core/gemini_models.py)
  * gemini-2.5-flash       in 0.30 / out 2.50   (the earlier Normal)
  * gemini-2.5-flash-lite  in 0.10 / out 0.40   (the earlier Normal)
                                               (now served at aistudio.google.com/docs/pricing)
  * claude-haiku-5-5       in 0.10 / out 0.50 / 5m cache write 0.125
  * claude-sonnet-5-5      in 2.00 / out 10.00 / 5m cache write 2.50
                                               https://platform.claude.com/docs/en/about-claude/pricing
The live numbers come from the AI router's owner-editable price table
(Owner Admin -> AI); the table above is only the shipped default.

Credit cost per level = the WORST case: every input token at the dearest
input price (max of base input and cache write) up to the level's hard input
cap + the full output cap, in ৳ (usd_bdt from PricingConfig), divided by the
highest AI cost one credit may carry on the CHEAPEST credit we sell while
keeping 40 % profit after VAT 15 % and the Play fee 15 % (pricing_40
safe_bdt_per_credit). Rounded UP; the owner may set more, never less.

Rules: never auto-upgrade; fallback only to the same or a cheaper level;
a level whose provider hit its daily cap (or is not connected) shows
"temporarily unavailable". Shipped DISABLED (owner switch)."""
import math

LEVEL_IDS = ("normal", "better", "best")
PROVIDERS = ("gemini", "anthropic", "openai")

DEFAULT_LEVELS = {
    # owner rebuild order 4 Nov 01:02: Normal = Gemini FLASH (not Flash-Lite)
    # geminifix 4 Nov: gemini-2.5-flash -> its official replacement
    "normal": {"provider": "gemini", "model": "gemini-3.5-flash-lite",
               "in_cap": 5000, "out_cap": 1500, "max_chars": 2000, "history_turns": 12,
               "credits": 0, "per_day": 60},
    "better": {"provider": "anthropic", "model": "claude-haiku-5-5",
               "in_cap": 8000, "out_cap": 1800, "max_chars": 3000, "history_turns": 16,
               "credits": 0, "per_day": 40},
    "best": {"provider": "anthropic", "model": "claude-sonnet-5-5",
             "in_cap": 12000, "out_cap": 2500, "max_chars": 4000, "history_turns": 20,
             "credits": 0, "per_day": 20},
}
# credits 0 = use the computed worst-case minimum
BOUNDS = {"in_cap": (500, 16000), "out_cap": (100, 4000), "max_chars": (200, 20000),
          "history_turns": (0, 20), "credits": (0, 500), "per_day": (0, 1000)}
# PART 4 (owner-editable): welcome credits ONCE per verified phone + device,
# Normal answers one rewarded ad buys (adults only)
TOP_BOUNDS = {"welcome_credits": (0, 200), "ad_answers_per_ad": (0, 10)}
FLASH_LITE_PRICE = {"in": 0.10, "out": 0.40, "cache_read": 0.025, "cache_write": 0.0}


def defaults():
    # rebuild order 01:02: switched ON on deploy by migration 0152_ai_rebuild
    # (the live config row); the code default stays OFF so a fresh / test DB
    # keeps today's behaviour. The old pricing-40 "smart" mode (Sonnet for 2
    # credits) fails the 40 % rule in the worst case.
    return {"enabled": False, "default": "normal",
            "levels": {k: dict(v) for k, v in DEFAULT_LEVELS.items()},
            # PART 4: free + rewarded-ad credits pay ONLY for these levels
            "free_credit_levels": ["normal"],
            "welcome_on": False, "welcome_credits": 20, "ad_answers_per_ad": 2,
            # PART 5: action buttons under AI answers (fixed allow-list)
            "actions_on": False,
            # round 3 item 7: the nightly AI exam (core/ai_exam.py)
            "exam_on": False, "exam_budget_usd": 1.5, "exam_min_pass": 0.85,
            "exam_min_win": 0.9,
            # owner 01:12: web search for recent / changing facts (Gemini
            # grounding with Google Search: 1,500 free/day on the paid tier,
            # then $35 / 1,000 grounded prompts — checked 4 Nov 2026,
            # https://ai.google.dev/gemini-api/docs/pricing). The worst-case
            # price is added to the answer's credits. OFF until the owner
            # accepts that price.
            "web_on": False, "web_usd_per_prompt": 0.035,
            # geminifix: the one place for Gemini model ids (core/gemini_models.py)
            "gemini_models": _gemini_defaults()}


def _gemini_defaults():
    from ..gemini_models import DEFAULTS
    return dict(DEFAULTS)


def _clampi(v, lo, hi, d):
    try:
        if isinstance(v, bool):
            return d
        return max(lo, min(hi, int(float(v))))
    except (TypeError, ValueError):
        return d


def _model_ok(m):
    m = str(m or "")
    return 0 < len(m) <= 60 and all(c.isalnum() or c in ".-" for c in m) and m[0].isalnum()


def normalize(raw):
    """Bounded, defaults-filled block. Never raises."""
    raw = raw if isinstance(raw, dict) else {}
    base = defaults()
    out = {"enabled": raw.get("enabled", base["enabled"]) is True}
    d = str(raw.get("default") or "")
    out["default"] = d if d in LEVEL_IDS else base["default"]
    rl = raw.get("levels") if isinstance(raw.get("levels"), dict) else {}
    out["levels"] = {}
    for lid in LEVEL_IDS:
        r = rl.get(lid) if isinstance(rl.get(lid), dict) else {}
        b = base["levels"][lid]
        row = {k: _clampi(r.get(k), lo, hi, b[k]) for k, (lo, hi) in BOUNDS.items()}
        p = str(r.get("provider") or "")
        row["provider"] = p if p in PROVIDERS else b["provider"]
        row["model"] = str(r.get("model")) if _model_ok(r.get("model")) else b["model"]
        out["levels"][lid] = row
    fl = raw.get("free_credit_levels")
    fl = [x for x in fl if x in LEVEL_IDS] if isinstance(fl, list) else base["free_credit_levels"]
    out["free_credit_levels"] = fl or ["normal"]
    out["welcome_on"] = raw.get("welcome_on") is True
    out["actions_on"] = raw.get("actions_on") is True
    out["exam_on"] = raw.get("exam_on") is True
    out["web_on"] = raw.get("web_on") is True
    try:
        w = float(raw.get("web_usd_per_prompt", base["web_usd_per_prompt"]))
        out["web_usd_per_prompt"] = base["web_usd_per_prompt"] if w != w else max(0.0, min(1.0, w))
    except (TypeError, ValueError):
        out["web_usd_per_prompt"] = base["web_usd_per_prompt"]
    for k, lo, hi in (("exam_budget_usd", 0.0, 20.0), ("exam_min_pass", 0.0, 1.0),
                      ("exam_min_win", 0.0, 1.0)):
        try:
            v = float(raw.get(k, base[k]))
            out[k] = base[k] if v != v else round(max(lo, min(hi, v)), 3)
        except (TypeError, ValueError):
            out[k] = base[k]
    for k, (lo, hi) in TOP_BOUNDS.items():
        out[k] = _clampi(raw.get(k), lo, hi, base[k])
    rg = raw.get("gemini_models") if isinstance(raw.get("gemini_models"), dict) else {}
    out["gemini_models"] = {
        k: (str(rg.get(k)).strip().lower() if _model_ok(str(rg.get(k) or "").strip())
            and str(rg.get(k)).strip().lower().startswith("gemini") else v)
        for k, v in base["gemini_models"].items()}
    return out


def ad_profit_pct(normal_row, answers, prices, usd_bdt, ad_value_bdt):
    """Worst-case profit % of one rewarded ad that buys `answers` Normal
    answers (every answer at its hard caps)."""
    if ad_value_bdt <= 0:
        return 0.0
    cost = answers * worst_cost_usd(normal_row, prices) * float(usd_bdt)
    return round(100.0 * (ad_value_bdt - cost) / ad_value_bdt, 1)


def price_of(model, prices):
    p = (prices or {}).get(model)
    if p is None and model == "gemini-2.5-flash-lite":
        p = FLASH_LITE_PRICE
    if p is None:
        from ..ai_config import FALLBACK_PRICE
        p = FALLBACK_PRICE              # unknown model = dearest row (never under-counts)
    return p


def worst_cost_usd(row, prices):
    p = price_of(row["model"], prices)
    in_price = max(float(p.get("in", 0)), float(p.get("cache_write", 0)))
    return (row["in_cap"] * in_price + row["out_cap"] * float(p.get("out", 0))) / 1e6


def min_credits(row, prices, usd_bdt, safe_bdt_per_credit):
    """Fewest credits that keep the 40 % rule in the worst case."""
    if safe_bdt_per_credit <= 0:
        return 0
    bdt = worst_cost_usd(row, prices) * float(usd_bdt)
    return max(1, int(math.ceil(round(bdt / safe_bdt_per_credit, 6))))


def credits_for(row, prices, usd_bdt, safe_bdt_per_credit):
    """The level's price: the owner's number, but never below the minimum."""
    m = min_credits(row, prices, usd_bdt, safe_bdt_per_credit)
    return max(m, int(row.get("credits") or 0))


def profit_pct(row, credits, prices, usd_bdt, cheapest_bdt_per_credit,
               net=0.74, overhead=0.10):
    """Worst-case profit % of the price for one answer at `credits`."""
    price = credits * cheapest_bdt_per_credit
    if price <= 0:
        return 0.0
    cost = worst_cost_usd(row, prices) * float(usd_bdt)
    return round(100.0 * (price * (net - overhead) - cost) / price, 1)


def fallbacks(levels, lid, prices):
    """(provider, model) pairs to try after `lid`'s own model: other levels'
    models whose worst-case cost is the SAME OR LOWER — never a dearer one."""
    me = levels[lid]
    cap = worst_cost_usd(me, prices)
    seen = {(me["provider"], me["model"])}
    out = []
    rows = sorted(((worst_cost_usd(levels[o], prices), o) for o in LEVEL_IDS if o != lid),
                  reverse=True)
    for cost, o in rows:
        r = levels[o]
        key = (r["provider"], r["model"])
        if cost <= cap + 1e-12 and key not in seen:
            seen.add(key)
            out.append(key)
    return out


HARD_HINT_CHARS = 350


def hint_better(text, lid):
    """A small hint only (never an upgrade): a long / multi-part / reasoning
    question asked on Normal may be answered better on Better."""
    if lid != "normal":
        return False
    from .pricing_40 import is_hard_question
    try:
        return bool(is_hard_question(text or ""))
    except Exception:  # noqa: BLE001
        return False
