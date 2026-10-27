"""
ai_config.py — the AI router's owner-editable settings (pure: no DB, no
network). Stored inside the single PricingConfig row under data["ai_router"]
so it rides the existing audit/save path; core/logic/pricing.normalize keeps
the block (normalized here) so a /admin/pricing save never drops it.

Everything is BOUNDED and NORMALIZED: a bad value falls back to the shipped
default, numbers are clamped, model ids are sanitised. Anthropic models are a
closed choice (only the three current ids); OpenAI / Gemini ids are free text
because the owner's account decides which ones exist ("set in Owner Admin").

Job -> class -> provider order (see core/ai.py generate()):
  * tier "medium" / "strong" (chat, assistant, agent, complex) = class MAIN:
      Anthropic -> OpenAI -> Gemini
  * tier "cheap" (classify, short replies, summaries, extraction) = class CHEAP:
      Gemini -> OpenAI -> Anthropic (Haiku)
"""
import re

PROVIDERS = ("anthropic", "openai", "gemini")
CLASSES = ("main", "cheap")
TIERS = ("cheap", "medium", "strong")

ORDER = {
    "main": ("anthropic", "openai", "gemini"),
    "cheap": ("gemini", "openai", "anthropic"),
}

# The only Anthropic ids the router may send (no date suffixes).
ANTHROPIC_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
# Models that take output_config.effort + adaptive thinking (never temperature,
# never thinking={"type":"disabled"} — both are a 400 on these).
EFFORT_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
# Server-side refusal fallback ("default" form) is offered on Opus/Sonnet only;
# Haiku 5.5 has none.
SERVER_FALLBACK_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5")
EFFORTS = ("low", "medium", "high", "xhigh", "max")

# key -> (provider, default model). "*_strong/medium" are used by tier; the
# OpenAI / Gemini side has one MAIN and one CHEAP model each.
MODEL_SLOTS = {
    "anthropic_strong": ("anthropic", "claude-opus-5-5"),
    "anthropic_medium": ("anthropic", "claude-opus-5-5"),
    "anthropic_cheap": ("anthropic", "claude-haiku-5-5"),
    # ids already referenced by this codebase (vision_providers / old ai.py);
    # change them in Owner Admin -> AI if your account has better ones.
    "openai_main": ("openai", "gpt-4o-mini"),
    "openai_cheap": ("openai", "gpt-4o-mini"),
    "gemini_main": ("gemini", "gemini-2.5-flash"),
    "gemini_cheap": ("gemini", "gemini-2.5-flash"),
}

SLOT_LABELS = {
    "anthropic_strong": ("Anthropic — এজেন্ট/জটিল কাজ (strong)", "Anthropic — agent / complex (strong)"),
    "anthropic_medium": ("Anthropic — সাধারণ চ্যাট/সহকারী (medium)", "Anthropic — normal chat / assistant (medium)"),
    "anthropic_cheap": ("Anthropic — সস্তা কাজের শেষ ব্যাকআপ (cheap)", "Anthropic — cheap-task last backup (cheap)"),
    "openai_main": ("OpenAI — মূল কাজের ব্যাকআপ", "OpenAI — main-task backup"),
    "openai_cheap": ("OpenAI — সস্তা কাজের ব্যাকআপ", "OpenAI — cheap-task backup"),
    "gemini_main": ("Gemini — মূল কাজের শেষ ব্যাকআপ", "Gemini — main-task last backup"),
    "gemini_cheap": ("Gemini — সস্তা কাজ (প্রথম পছন্দ)", "Gemini — cheap tasks (first choice)"),
}

# USD per 1M tokens. cache_read / cache_write only where the provider bills
# them separately. Owner-editable (prices change); unknown model -> FALLBACK
# (deliberately the most expensive row so a cap never under-counts).
DEFAULT_PRICES = {
    "claude-opus-5-5": {"in": 4.00, "out": 20.00, "cache_read": 0.20, "cache_write": 5.00},
    "claude-sonnet-5-5": {"in": 2.00, "out": 10.00, "cache_read": 0.20, "cache_write": 2.50},
    "claude-haiku-5-5": {"in": 0.10, "out": 0.50, "cache_read": 0.01, "cache_write": 0.125},
    "gpt-4o-mini": {"in": 0.15, "out": 0.60, "cache_read": 0.075, "cache_write": 0.0},
    "gemini-2.5-flash": {"in": 0.30, "out": 2.50, "cache_read": 0.075, "cache_write": 0.0},
}
FALLBACK_PRICE = {"in": 4.00, "out": 20.00, "cache_read": 0.40, "cache_write": 5.00}
PRICE_KEYS = ("in", "out", "cache_read", "cache_write")

MAIN_FEATURES = ("chat", "agent_qa", "circle_assisto_ask", "bizagent.reply",
                 "business.reply", "business.ai_reply")
_FEATURE_RE = re.compile(r"^[a-z0-9_.\-]{1,40}$")

_MODEL_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]{0,59}$")

_DEFAULTS = {
    "models": {k: v[1] for k, v in MODEL_SLOTS.items()},
    # Anthropic effort per tier (low for chat, medium for agent work).
    "effort": {"strong": "medium", "medium": "low", "cheap": "low"},
    # daily USD caps (Asia/Dhaka calendar day). "total" is ANDed with the
    # legacy kill-switch (ai_daily_budget_usd / env AI_DAILY_BUDGET_USD):
    # the effective total is the SMALLER of the two.
    "caps_usd": {"anthropic": 3.0, "openai": 3.0, "gemini": 3.0, "total": 5.0},
    "alert_pct": 80,
    "timeouts_s": {"main": 45, "cheap": 15},
    # a successful call slower than this counts against the error-rate window
    "slow_ms": {"main": 30000, "cheap": 8000},
    "circuit": {"fail_threshold": 3, "error_rate_pct": 50, "min_calls": 10,
                "window_s": 300, "cooldown_s": 60},
    "server_fallback": True,
    # cheap-tier (1-credit) features that are really chat / assistant / agent
    # work and so run on the MAIN class (owner order: main model for chat,
    # assistant and agent work). Prefix match on the AIUsage feature name.
    # Credits are NOT changed by this — see owner_actions/AI_ROUTER_BN.md.
    "main_features": list(MAIN_FEATURES),
    "prices": {m: dict(p) for m, p in DEFAULT_PRICES.items()},
}

BOUNDS = {
    "caps_usd": (0.0, 1000.0),
    "alert_pct": (10, 99),
    "timeouts_s": (3, 120),
    "slow_ms": (1000, 120000),
    "fail_threshold": (1, 50),
    "error_rate_pct": (5, 100),
    "min_calls": (2, 1000),
    "window_s": (30, 3600),
    "cooldown_s": (10, 3600),
    "price": (0.0, 1000.0),
}

LABELS = {
    "cap_anthropic": ("Anthropic দৈনিক খরচের সীমা (USD)", "Anthropic daily spend cap (USD)"),
    "cap_openai": ("OpenAI দৈনিক খরচের সীমা (USD)", "OpenAI daily spend cap (USD)"),
    "cap_gemini": ("Gemini দৈনিক খরচের সীমা (USD)", "Gemini daily spend cap (USD)"),
    "cap_total": ("মোট দৈনিক AI খরচের সীমা (USD)", "Total daily AI spend cap (USD)"),
    "alert_pct": ("কত % খরচ হলে আপনাকে সতর্ক করব", "Alert me at this % of a cap"),
    "timeout_main": ("মূল কাজের টাইমআউট (সেকেন্ড)", "Main-task timeout (seconds)"),
    "timeout_cheap": ("সস্তা কাজের টাইমআউট (সেকেন্ড)", "Cheap-task timeout (seconds)"),
    "slow_main": ("মূল কাজ ধীর ধরা হবে (মিলিসেকেন্ড)", "Main task counts as slow after (ms)"),
    "slow_cheap": ("সস্তা কাজ ধীর ধরা হবে (মিলিসেকেন্ড)", "Cheap task counts as slow after (ms)"),
    "fail_threshold": ("পরপর কতবার ব্যর্থ হলে প্রোভাইডার বন্ধ", "Open the circuit after N failures in a row"),
    "error_rate_pct": ("ত্রুটির হার % (উইন্ডোতে) হলে বন্ধ", "…or at this error rate % in the window"),
    "min_calls": ("হার মাপতে ন্যূনতম কল", "Minimum calls before the rate counts"),
    "window_s": ("ত্রুটি মাপার উইন্ডো (সেকেন্ড)", "Error window (seconds)"),
    "cooldown_s": ("বন্ধ থাকার পর আবার চেষ্টা (সেকেন্ড)", "Retry a closed-off provider after (seconds)"),
    "effort_strong": ("Anthropic চিন্তার মাত্রা — এজেন্ট/জটিল", "Anthropic effort — agent / complex"),
    "effort_medium": ("Anthropic চিন্তার মাত্রা — চ্যাট", "Anthropic effort — chat"),
    "effort_cheap": ("Anthropic চিন্তার মাত্রা — সস্তা", "Anthropic effort — cheap"),
    "server_fallback": ("Anthropic সার্ভার-সাইড রিফিউজাল ফলব্যাক", "Anthropic server-side refusal fallback"),
}


def defaults():
    import copy
    return copy.deepcopy(_DEFAULTS)


def _num(v, d):
    try:
        if isinstance(v, bool):
            return d
        return float(v)
    except (TypeError, ValueError):
        return d


def _clamp(v, lo, hi, d, as_int=False):
    n = _num(v, None)
    if n is None or n != n:          # NaN
        n = d
    n = max(lo, min(hi, n))
    return int(round(n)) if as_int else round(float(n), 4)


def clean_model(provider, value, default):
    s = str(value or "").strip().lower()
    if provider == "anthropic":
        return s if s in ANTHROPIC_MODELS else default
    return s if _MODEL_RE.match(s) else default


def normalize(raw):
    """Bounded, defaults-filled router config. Never raises."""
    raw = raw if isinstance(raw, dict) else {}
    base = defaults()
    out = {}
    rm = raw.get("models") if isinstance(raw.get("models"), dict) else {}
    out["models"] = {slot: clean_model(prov, rm.get(slot), dflt)
                     for slot, (prov, dflt) in MODEL_SLOTS.items()}
    re_ = raw.get("effort") if isinstance(raw.get("effort"), dict) else {}
    out["effort"] = {t: (str(re_.get(t)).lower() if str(re_.get(t)).lower() in EFFORTS
                         else base["effort"][t]) for t in TIERS}
    rc = raw.get("caps_usd") if isinstance(raw.get("caps_usd"), dict) else {}
    lo, hi = BOUNDS["caps_usd"]
    out["caps_usd"] = {k: _clamp(rc.get(k), lo, hi, base["caps_usd"][k])
                       for k in base["caps_usd"]}
    lo, hi = BOUNDS["alert_pct"]
    out["alert_pct"] = _clamp(raw.get("alert_pct"), lo, hi, base["alert_pct"], as_int=True)
    for blk in ("timeouts_s", "slow_ms"):
        rb = raw.get(blk) if isinstance(raw.get(blk), dict) else {}
        lo, hi = BOUNDS[blk]
        out[blk] = {c: _clamp(rb.get(c), lo, hi, base[blk][c], as_int=True) for c in CLASSES}
    rcc = raw.get("circuit") if isinstance(raw.get("circuit"), dict) else {}
    out["circuit"] = {}
    for k, d in base["circuit"].items():
        lo, hi = BOUNDS[k]
        out["circuit"][k] = _clamp(rcc.get(k), lo, hi, d, as_int=True)
    sf = raw.get("server_fallback", base["server_fallback"])
    out["server_fallback"] = sf if isinstance(sf, bool) else base["server_fallback"]
    mf = raw.get("main_features", base["main_features"])
    if isinstance(mf, str):
        mf = mf.split(",")
    if not isinstance(mf, (list, tuple)):
        mf = base["main_features"]
    clean = []
    for f in mf:
        f = str(f or "").strip().lower()
        if _FEATURE_RE.match(f) and f not in clean:
            clean.append(f)
    out["main_features"] = clean[:40]
    rp = raw.get("prices") if isinstance(raw.get("prices"), dict) else {}
    prices = {m: dict(p) for m, p in DEFAULT_PRICES.items()}
    lo, hi = BOUNDS["price"]
    for m, p in rp.items():
        mid = str(m or "").strip().lower()
        if not _MODEL_RE.match(mid) or not isinstance(p, dict):
            continue
        cur = prices.get(mid, dict(FALLBACK_PRICE))
        prices[mid] = {k: _clamp(p.get(k), lo, hi, cur.get(k, 0.0)) for k in PRICE_KEYS}
    out["prices"] = prices
    return out


def validate(raw):
    """Problems (list of codes) for an owner edit BEFORE it is normalized —
    the page refuses the save instead of silently clamping a typo."""
    problems = []
    if not isinstance(raw, dict):
        return ["invalid"]
    for k, v in (raw.get("caps_usd") or {}).items():
        n = _num(v, None)
        if n is None or n < 0 or n > BOUNDS["caps_usd"][1]:
            problems.append("cap_" + str(k))
    for slot, v in (raw.get("models") or {}).items():
        if slot not in MODEL_SLOTS:
            continue
        prov = MODEL_SLOTS[slot][0]
        if clean_model(prov, v, None) is None:
            problems.append("model_" + slot)
    for t, v in (raw.get("effort") or {}).items():
        if str(v).lower() not in EFFORTS:
            problems.append("effort_" + str(t))
    for m, p in (raw.get("prices") or {}).items():
        for k in PRICE_KEYS:
            if isinstance(p, dict) and k in p:
                n = _num(p.get(k), None)
                if n is None or n < 0 or n > BOUNDS["price"][1]:
                    problems.append("price_" + str(m))
                    break
    if "alert_pct" in raw:
        n = _num(raw.get("alert_pct"), None)
        lo, hi = BOUNDS["alert_pct"]
        if n is None or not lo <= n <= hi:
            problems.append("alert_pct")
    return sorted(set(problems))


def price_of(cfg, model):
    p = (cfg.get("prices") or {}).get(model)
    return p if p else FALLBACK_PRICE


def cost_usd(cfg, model, in_tok, out_tok, cache_read=0, cache_write=0):
    """USD for one call. in_tok = UNCACHED input tokens."""
    p = price_of(cfg, model)
    return (max(0, in_tok) * p["in"] + max(0, out_tok) * p["out"]
            + max(0, cache_read) * p.get("cache_read", 0.0)
            + max(0, cache_write) * p.get("cache_write", 0.0)) / 1_000_000


def task_class(tier, feature="", cfg=None):
    """main | cheap. medium/strong tiers are always MAIN; a cheap-tier call is
    MAIN when its feature is listed in main_features (chat/assistant/agent)."""
    if tier in ("medium", "strong"):
        return "main"
    f = (feature or "").lower()
    for pre in ((cfg or {}).get("main_features") or MAIN_FEATURES):
        if f == pre or f.startswith(pre):
            return "main"
    return "cheap"


def anthropic_slot(tier, klass):
    """strong -> strong slot; other MAIN work -> medium slot (chat at low
    effort); CHEAP class -> the cheap slot (Haiku)."""
    if klass == "cheap":
        return "cheap"
    return "strong" if tier == "strong" else "medium"


def model_for(cfg, provider, tier, klass=None):
    klass = klass or task_class(tier, cfg=cfg)
    m = cfg["models"]
    if provider == "anthropic":
        return m["anthropic_" + anthropic_slot(tier, klass)]
    return m["%s_%s" % (provider, klass)]


def effort_for(cfg, tier, klass):
    return cfg["effort"][anthropic_slot(tier, klass)]
