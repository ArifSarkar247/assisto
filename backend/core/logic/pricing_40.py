"""
pricing_40.py — the owner's "STRONG AI WITH PROFIT" rule (owner decision
27 Oct), as ONE pure, reproducible calculator. No Django, no DB, no network,
no AI calls. Used by:

  * owner_actions/PRICING_40PCT_BN.md (every number in it comes from here —
    `python -m core.logic.pricing_40` from backend/ prints the tables),
  * manage.py apply_pricing_preset (the NOT-YET-APPLIED preset below),
  * core/ai_cost_alert.py (the "safe cost per credit" the daily alert uses).

The rule: even if a user spends EVERY credit on the most expensive model a
product allows, the company keeps >= 40 % profit after Google's fee + VAT
(owner keeps ~74 % of the price) and ~10 % overhead (server, SMS, push).

  Interpretation A (used; the stricter one): profit >= 40 % of the PRICE
      => AI cost budget = 74 % - 10 % - 40 % = 24 % of the price.
  Interpretation B (shown for comparison): profit >= 40 % of NET (74 %)
      => AI budget = 74 % - 10 % - 0.40 x 74 % = 34.4 % of the price.

Token sizes are MEASURED from the code (exact prompt strings, history window,
max_tokens) and converted characters -> tokens with a stated conservative
ratio; nothing here is a live measurement (no AI key was ever set, so there
are no real usage logs). `manage.py ai_token_audit` gets EXACT counts from
Anthropic's free count_tokens endpoint once a key exists.
"""
import math

from .. import ai_config as _AIC

# ------------------------------------------------------------------ economics
USD_BDT = 120.0            # core/logic/pricing.DEFAULT_USD_BDT (live value unknown)
NET_PCT = 0.74             # owner: price / 1.15 VAT x (1 - 0.15 Google) = 0.739
OVERHEAD_PCT = 0.10        # owner: server, SMS, push
PROFIT_PCT = 0.40          # owner: >= 40 % profit


def ai_budget_pct(net=NET_PCT, overhead=OVERHEAD_PCT, profit=PROFIT_PCT, base="price"):
    """Share of the price that may go to AI. base='price' (A) or 'net' (B)."""
    if base == "net":
        return round(net - overhead - profit * net, 4)
    return round(net - overhead - profit, 4)


# ------------------------------------------------------------------ tokens
# characters -> tokens. English ~4 chars/token (0.25), conservative 0.30.
# Bangla (Bengali script, 3 UTF-8 bytes a letter) tokenizes far denser:
# 0.5-1.3 tokens per Bengali letter; planning value 1.0, stress 1.3.
TOK_PER_CHAR = {"en": 0.30, "bn": 1.00, "bn_stress": 1.30, "bn_low": 0.50,
                "other": 0.30}

# Exact character counts of what each chat turn sends (measured from the code:
# core/ai_prompt.system_prompt(), core/views_chat._produce_reply,
# core/logic/brain, core/ai_prompt.QUALITY_PROMPTS). (bengali_letters, other)
MEASURED_CHARS = {
    "system_prompt": (11, 1114),          # same for bn and en (English text)
    "chat_task_bn": (183, 61),
    "chat_task_en": (0, 245),
    "data_wrapper": (0, 61),              # "User's latest message: …<data>…"
    "data_summary_l4": (101, 33),         # brain L4 "needs a key" text (sent today!)
    "data_summary_l1": (118, 124),        # brain L1 overview, a typical user
    "user_msg_avg": (70, 14),             # mean of the 10 Bangla eval prompts (84 chars)
    "user_msg_max_eval": (104, 21),       # longest eval prompt (125 chars)
}
HISTORY_TURNS = 20                        # views_chat._HISTORY_TURNS (10 user + 10 reply)
CHAT_MAX_TOKENS = 700                     # views_chat: max_tokens=700 (visible)
THINK_HEADROOM_LOW = 1024                 # core/ai.py _THINK_HEADROOM["low"]
REPLY_TOKENS_TYPICAL = 350                # a "brief" Bangla answer (estimate)
THINKING_TOKENS_TYPICAL = 150             # effort low, chat (estimate; billed as output)


def tokens(key, bn_ratio=None):
    bn, other = MEASURED_CHARS[key]
    r = TOK_PER_CHAR["bn"] if bn_ratio is None else bn_ratio
    return int(math.ceil(bn * r + other * TOK_PER_CHAR["other"]))


def chat_base_input(lang="bn", bn_ratio=None, summary="data_summary_l1"):
    """Input tokens of one chat turn WITHOUT history."""
    return (tokens("system_prompt", bn_ratio) + tokens("chat_task_" + lang, bn_ratio)
            + tokens("data_wrapper", bn_ratio) + tokens(summary, bn_ratio)
            + tokens("user_msg_avg", bn_ratio))


def history_tokens(exchanges, reply=REPLY_TOKENS_TYPICAL, bn_ratio=None):
    return exchanges * (tokens("user_msg_avg", bn_ratio) + reply)


def today_chat_scenarios(bn_ratio=None):
    """What a chat message costs in tokens with TODAY's code (no caps)."""
    base = chat_base_input(bn_ratio=bn_ratio)
    out = REPLY_TOKENS_TYPICAL + THINKING_TOKENS_TYPICAL
    return {
        # a session averages ~3 earlier exchanges in the window
        "typical": {"in": base + history_tokens(3, bn_ratio=bn_ratio), "out": out},
        # a long session: the full 20-turn window
        "heavy": {"in": base + history_tokens(HISTORY_TURNS // 2, bn_ratio=bn_ratio), "out": out},
        # every reply in the window at the 700-token cap + output at its cap;
        # STILL not the ceiling: the user's own text has no length limit today
        "ceiling": {"in": base + history_tokens(HISTORY_TURNS // 2, reply=CHAT_MAX_TOKENS,
                                                bn_ratio=bn_ratio),
                    "out": CHAT_MAX_TOKENS + THINK_HEADROOM_LOW},
    }


# ------------------------------------------------------------------ prices
PRICES = {m: dict(p) for m, p in _AIC.DEFAULT_PRICES.items()}
OPUS, SONNET, HAIKU = "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"


def call_cost_usd(model, in_tok, out_tok, cache_read=0, cache_write=0, prices=None):
    p = (prices or PRICES)[model]
    return (in_tok * p["in"] + out_tok * p["out"] + cache_read * p["cache_read"]
            + cache_write * p["cache_write"]) / 1e6


def cached_chat_cost_usd(model, in_tok, out_tok, new_tok=400, prices=None):
    """A turn whose stable prefix (system + history) was cached by the previous
    turn (< 5 min ago): the prefix is a cache READ, the newest part a WRITE."""
    prefix = max(0, in_tok - new_tok)
    return call_cost_usd(model, 0, out_tok, cache_read=prefix, cache_write=new_tok, prices=prices)


# ------------------------------------------------------------------ chat modes
# The PROPOSED hard caps (fix T1-T4). in_cap = everything sent (system + task
# + data + trimmed history + the user's text); out_cap = max_tokens INCLUDING
# thinking. A message can never cost more than its cap row.
MODES = {
    # Haiku 5.5: thinking disabled (allowed at effort <= high)
    "quick": {"model": HAIKU, "effort": "low", "thinking": "disabled",
              "in_cap": 1500, "out_cap": 300, "history_turns": 4},
    # Sonnet 5.5: thinking OFF via {"type": "between_tools"} at effort low
    "smart": {"model": SONNET, "effort": "low", "thinking": "between_tools",
              "in_cap": 2000, "out_cap": 450, "history_turns": 8},
    # Opus 5.5: thinking cannot be disabled -> effort low; cap includes thinking
    "pro": {"model": OPUS, "effort": "low", "thinking": "adaptive",
            "in_cap": 2400, "out_cap": 750, "history_turns": 8},
}


def mode_cap_cost_usd(mode, modes=None, prices=None):
    m = (modes or MODES)[mode]
    return call_cost_usd(m["model"], m["in_cap"], m["out_cap"], prices=prices)


def mode_typical_cost_usd(mode, modes=None, prices=None):
    m = (modes or MODES)[mode]
    sc = today_chat_scenarios()["typical"]
    out = REPLY_TOKENS_TYPICAL + (0 if m["thinking"] != "adaptive" else THINKING_TOKENS_TYPICAL)
    return call_cost_usd(m["model"], min(sc["in"], m["in_cap"]), min(out, m["out_cap"]),
                         prices=prices)


# ------------------------------------------------------------------ agent task
# A multi-step agent task on Opus 5.5 (planner + tool calls). Modeled loop: a
# stable prefix (system + tool definitions + task) then per step one tool
# result in and one assistant turn out (thinking included, effort medium).
AGENT = {"model": OPUS, "prefix": 2500, "tool_result": 700, "step_out": 900,
         "steps_typical": 4, "steps_max": 6}


def agent_cost_usd(steps, cached=True, a=None, prices=None):
    a = a or AGENT
    total = 0.0
    prev = 0
    for k in range(1, steps + 1):
        ctx = a["prefix"] + (k - 1) * (a["tool_result"] + a["step_out"])
        if cached:
            total += call_cost_usd(a["model"], 0, a["step_out"], cache_read=prev,
                                   cache_write=ctx - prev, prices=prices)
        else:
            total += call_cost_usd(a["model"], ctx, a["step_out"], prices=prices)
        prev = ctx
    return total


def agent_step_allowed(spent_usd, next_in_uncached, next_cache_read, max_out, cap_usd,
                       model=OPUS, prices=None):
    """Hard per-task cap: run the next step only if even its WORST case
    (every new token a cache write, the full max_tokens) stays under the cap.
    Otherwise the loop stops and returns the partial result (and the unused
    credits are not charged twice: the price is fixed and shown up front)."""
    worst = call_cost_usd(model, 0, max_out, cache_read=next_cache_read,
                          cache_write=next_in_uncached, prices=prices)
    return spent_usd + worst <= cap_usd


# ------------------------------------------------------------------ proposals
OWNER_PROPOSAL = {
    "plans": {   # id: (price ৳/month, credits/month, modes allowed)
        "plus": (199, 60, ("smart",)),
        "premium": (449, 150, ("smart", "pro", "agent")),
        "business": (1299, 400, ("smart", "pro", "agent")),
    },
    "annual_price_x": 10,
    "packs": [(50, 179), (120, 399), (300, 949)],
    "credits": {"quick": 0, "smart": 1, "pro": 2, "agent": 10},
    "quick_free_per_day": 10,
    "free": {"credits": 20, "rewarded_per_day": 5},
}

# The SMALLEST fix that passes (see the doc): technical caps above + credit
# costs; prices, plan credits and packs exactly as the owner proposed. Annual
# keeps 10x the price and grants 10x the monthly credits (spread monthly).
FINAL_PROPOSAL = {
    **OWNER_PROPOSAL,
    "credits": {"quick": 0, "smart": 2, "pro": 5, "agent": 25},
    "annual_credits_x": 10,
    "agent_cap_usd": None,   # = agent credits x safe cost per credit (derived)
}

ECPM_REWARDED_USD = {"low": 1.0, "mid": 1.5, "high": 3.0}   # BD rewarded video (assumption)
QUICK_DAYS = 30


def _per_credit_usd(mode, credits, cost_fn):
    c = credits.get(mode, 0)
    return (cost_fn(mode) / c) if c else float("inf")


def products(prop, annual_credits_x=12):
    out = []
    for pid, (price, cr, modes) in prop["plans"].items():
        out.append({"id": pid, "kind": "month", "price": price, "credits": cr,
                    "modes": modes, "quick_months": 1})
        out.append({"id": pid + "_annual", "kind": "year", "price": price * prop["annual_price_x"],
                    "credits": cr * annual_credits_x, "modes": modes, "quick_months": 12})
    for cr, price in prop["packs"]:
        out.append({"id": "pack%d" % cr, "kind": "pack", "price": price, "credits": cr,
                    "modes": ("smart", "pro", "agent"), "quick_months": 0})
    return out


def margin_row(p, credits, cost_of, quick_cost_usd, quick_per_day, usd_bdt=USD_BDT,
               base="price"):
    """Worst case: every credit on the most expensive mode the product allows,
    + the free quick-reply quota fully used. Returns a dict (৳)."""
    worst_mode = max(p["modes"], key=lambda m: _per_credit_usd(m, credits, cost_of))
    per_credit = _per_credit_usd(worst_mode, credits, cost_of)
    ai = p["credits"] * per_credit * usd_bdt
    quick = quick_cost_usd * quick_per_day * QUICK_DAYS * p["quick_months"] * usd_bdt
    net = p["price"] * NET_PCT
    profit = net - p["price"] * OVERHEAD_PCT - ai - quick
    margin = profit / (p["price"] if base == "price" else net)
    return {"id": p["id"], "price": p["price"], "credits": p["credits"],
            "worst_mode": worst_mode, "ai_bdt": round(ai, 1), "quick_bdt": round(quick, 1),
            "profit_bdt": round(profit, 1), "margin_pct": round(100 * margin, 1),
            "ok": margin >= PROFIT_PCT}


def table(prop, cost_of, quick_cost_usd, annual_credits_x=12, usd_bdt=USD_BDT, base="price"):
    credits = prop["credits"]
    return [margin_row(p, credits, cost_of, quick_cost_usd, prop["quick_free_per_day"],
                       usd_bdt, base)
            for p in products(prop, annual_credits_x)]


def free_user_month(prop, cost_of, quick_cost_usd, ecpm_usd, usd_bdt=USD_BDT):
    """Marketing cost of ONE free user who uses everything (৳/month)."""
    credits = prop["credits"]
    per_credit = _per_credit_usd("smart", credits, cost_of) * usd_bdt
    rewarded = prop["free"]["rewarded_per_day"] * QUICK_DAYS
    cost = ((prop["free"]["credits"] + rewarded) * per_credit
            + quick_cost_usd * prop["quick_free_per_day"] * QUICK_DAYS * usd_bdt)
    ad_rev = rewarded * ecpm_usd / 1000.0 * usd_bdt
    return {"credits_cost": round((prop["free"]["credits"] + rewarded) * per_credit, 1),
            "quick_cost": round(quick_cost_usd * prop["quick_free_per_day"] * QUICK_DAYS * usd_bdt, 1),
            "ad_revenue": round(ad_rev, 1), "net_cost": round(cost - ad_rev, 1),
            "per_ad_revenue": round(ecpm_usd / 1000.0 * usd_bdt, 3),
            "per_rewarded_credit_cost": round(per_credit, 3)}


# ------------------------------------------------------------------ safe level
def bdt_per_credit_rows(cfg, annual_credit_months=None):
    """৳ the customer pays per credit, for every product the CONFIG sells
    (normalized PricingConfig dict): monthly plans, annual plans, packs.
    Annual months of credits: the credit_model value while it is enabled,
    else 12 (today: an annual plan grants the monthly credits every month).
    Free / 0-credit rows are skipped."""
    cm = cfg.get("credit_model") or {}
    if annual_credit_months is None:
        annual_credit_months = int(cm.get("annual_credit_months") or 12) if cm.get("enabled") else 12
    rows = []
    for pid, row in (cfg.get("plans") or {}).items():
        price, cr = float(row.get("price") or 0), float(row.get("credits") or 0)
        if price <= 0 or cr <= 0:
            continue
        rows.append((pid, price / cr))
        annual = float(row.get("annual_price") or 0)
        if annual <= 0:
            try:
                from . import pricing as _P
                annual = float(_P.annual_price(pid, cfg) or 0)
            except Exception:  # noqa: BLE001
                annual = 0.0
        if annual > 0:
            rows.append((pid + "_annual", annual / (cr * annual_credit_months)))
    for p in cfg.get("topup_packs") or []:
        price, cr = float(p.get("price") or 0), float(p.get("credits") or 0)
        if price > 0 and cr > 0:
            rows.append((str(p.get("id")), price / cr))
    return rows


def safe_bdt_per_credit(cfg, budget_pct=None):
    """The highest AI cost (৳) one consumed credit may carry and still keep
    the 40 % rule on the CHEAPEST credit we sell: min(৳/credit) x budget."""
    rows = bdt_per_credit_rows(cfg)
    if not rows:
        return 0.0
    b = ai_budget_pct() if budget_pct is None else float(budget_pct)
    return round(min(r[1] for r in rows) * b, 4)


# ------------------------------------------------------------------ credit model
# The PricingConfig block that turns the chat modes on. Shipped DISABLED: with
# enabled False every code path behaves exactly as before (no price, credit,
# model or cap changes). The preset below enables it after owner approval.
MODE_IDS = ("quick", "smart", "pro")
MODE_ACTION = {"quick": "ai_chat_quick", "smart": "ai_chat_smart", "pro": "ai_chat_pro"}
AGENT_ACTION = "ai_agent_task"
CAP_BOUNDS = {"in_cap": (500, 8000), "out_cap": (100, 4000), "history_turns": (0, 20)}
CM_BOUNDS = {"quick_free_per_day": (0, 100), "annual_credit_months": (1, 12),
             "user_text_max_chars": (500, 20000)}


def credit_model_defaults():
    return {
        "enabled": False,
        "quick_free_per_day": 10,
        "default_chat_mode": "smart",
        # 12 = today's behaviour (an annual plan grants the monthly credits
        # every month); the preset sets 10 (owner's "annual = 10x").
        "annual_credit_months": 12,
        "agent_confirm": True,
        "agent_cap_usd": 0.119,
        "user_text_max_chars": 4000,
        "modes": {m: {k: MODES[m][k] for k in CAP_BOUNDS} for m in MODE_IDS},
    }


def _clampi(v, lo, hi, d):
    try:
        if isinstance(v, bool):
            return d
        n = int(float(v))
    except (TypeError, ValueError):
        return d
    return max(lo, min(hi, n))


def normalize_credit_model(raw):
    """Bounded, defaults-filled credit_model block. Never raises."""
    raw = raw if isinstance(raw, dict) else {}
    base = credit_model_defaults()
    out = {"enabled": raw.get("enabled", base["enabled"]) is True,
           "agent_confirm": raw.get("agent_confirm", base["agent_confirm"]) is not False}
    for k, (lo, hi) in CM_BOUNDS.items():
        out[k] = _clampi(raw.get(k), lo, hi, base[k])
    dm = str(raw.get("default_chat_mode") or "").strip().lower()
    out["default_chat_mode"] = dm if dm in MODE_IDS else base["default_chat_mode"]
    try:
        cap = float(raw.get("agent_cap_usd", base["agent_cap_usd"]))
        if cap != cap or isinstance(raw.get("agent_cap_usd"), bool):
            raise ValueError
    except (TypeError, ValueError):
        cap = base["agent_cap_usd"]
    out["agent_cap_usd"] = round(max(0.01, min(5.0, cap)), 4)
    rm = raw.get("modes") if isinstance(raw.get("modes"), dict) else {}
    out["modes"] = {}
    for m in MODE_IDS:
        r = rm.get(m) if isinstance(rm.get(m), dict) else {}
        out["modes"][m] = {k: _clampi(r.get(k), lo, hi, base["modes"][m][k])
                           for k, (lo, hi) in CAP_BOUNDS.items()}
    return out


def mode_spec(cm, mode):
    """Model / effort / thinking (fixed per mode) + the owner-tunable caps."""
    spec = dict(MODES[mode])
    spec.update(cm["modes"][mode])
    return spec


# ------------------------------------------------------------------ fitting
def est_tokens(text):
    """Conservative token estimate (Bangla 1.3 / other 0.3 per char) used to
    keep a request under its in_cap BEFORE it is sent. Over-counts on purpose."""
    t = text or ""
    bn = sum(1 for c in t if "\u0980" <= c <= "\u09ff")
    return int(math.ceil(bn * TOK_PER_CHAR["bn_stress"] + (len(t) - bn) * TOK_PER_CHAR["other"])) + 4


def fit_input(system, prompt, history, in_cap, max_turns):
    """Trim so system + prompt + history <= in_cap (estimated, conservative).
    Newest history is kept first; then the prompt is shortened from the
    middle of its <data> as a last resort. Returns (prompt, history)."""
    hist = [h for h in (history or []) if isinstance(h, dict)][-max_turns:] if max_turns else []
    budget = in_cap - est_tokens(system)
    p = prompt or ""
    need = est_tokens(p)
    if need > budget:
        # keep the head (task) and the tail; cut the middle of the data
        keep = max(200, int(len(p) * budget / float(max(need, 1))) - 20)
        p = p[: keep // 2] + "\n…\n" + p[-(keep // 2):]
        while est_tokens(p) > budget and len(p) > 200:
            p = p[: len(p) // 2] + p[-(len(p) // 4):]
        need = est_tokens(p)
    left = budget - need
    kept = []
    for h in reversed(hist):
        c = est_tokens(h.get("content") or "")
        if c > left:
            break
        kept.append(h)
        left -= c
    kept.reverse()
    # a conversation must start with a user turn
    while kept and kept[0].get("role") != "user":
        kept.pop(0)
    return p, kept


# ------------------------------------------------------------------ the preset
# NOT APPLIED. manage.py apply_pricing_preset pricing_27oct --apply runs only
# after the owner's written approval (DB backup first). Keys mirror the
# normalized PricingConfig shape; credit_model is new (default disabled).
PRESETS = {
    "pricing_27oct": {
        "plans": {"premium": {"price": 449, "credits": 150, "annual_price": 4490},
                  "business": {"price": 1299, "credits": 400, "annual_price": 12990}},
        "topup_packs": [
            {"id": "c50", "price": 179, "credits": 50, "valid_months": 12},
            {"id": "c120", "price": 399, "credits": 120, "valid_months": 12},
            {"id": "c300", "price": 949, "credits": 300, "valid_months": 12},
        ],
        # owner: 74 % net = 15 % Google then 15 % VAT. pricing.net_fraction:
        # (1 - 0.15 play - 0.02 gateway) / 1.15 = 0.722 (a little safer).
        "vat": 0.15,
        # credits per chat mode / agent task; provider_cost = the HARD-CAP cost
        # (USD) so Owner Admin's NET-floor check holds them too.
        "action_costs": {
            "ai_chat_quick": {"provider_cost": 0.0003, "credits": 1},   # after the free quota
            "ai_chat_smart": {"provider_cost": 0.0085, "credits": 2},
            "ai_chat_pro": {"provider_cost": 0.0246, "credits": 5},
            "ai_agent_task": {"provider_cost": 0.119, "credits": 25},
        },
        "credit_model": {
            "enabled": True,
            "quick_free_per_day": 10,
            "default_chat_mode": "smart",
            "annual_credit_months": 10,
            "agent_confirm": True,
            # hard per-task cap, derived at ৳125/USD (holds at ৳120 too):
            # final_agent_cap_usd(10, 125.0) = 0.1194
            "agent_cap_usd": 0.119,
            "user_text_max_chars": 4000,
            "modes": {m: {k: MODES[m][k] for k in CAP_BOUNDS} for m in MODE_IDS},
        },
        "ad_rewards": {"rewarded_daily_cap": 5},
    },
}


def _fmt_rows(rows):
    return "\n".join("%-16s ৳%-6s cr %-5s worst=%-6s AI ৳%-7s quick ৳%-6s profit ৳%-8s %5s%% %s" % (
        r["id"], r["price"], r["credits"], r["worst_mode"], r["ai_bdt"], r["quick_bdt"],
        r["profit_bdt"], r["margin_pct"], "OK" if r["ok"] else "FAIL") for r in rows)


def report(usd_bdt=USD_BDT):   # pragma: no cover - printed for the doc
    lines = []
    sc = today_chat_scenarios()
    lines.append("budget A %.3f  B %.3f" % (ai_budget_pct(), ai_budget_pct(base="net")))
    lines.append("today chat tokens %s base=%d" % (sc, chat_base_input()))
    lines.append("today stress(1.3) %s" % today_chat_scenarios(1.3))
    for name, s in sc.items():
        lines.append("%s: " % name + "  ".join("%s $%.4f ৳%.2f" % (m, call_cost_usd(m, s["in"], s["out"]),
                                                              call_cost_usd(m, s["in"], s["out"]) * usd_bdt)
                                                for m in (HAIKU, SONNET, OPUS)))
        lines.append("   cached: " + "  ".join("%s $%.4f" % (m, cached_chat_cost_usd(m, s["in"], s["out"]))
                                                for m in (SONNET, OPUS)))
    for m in MODES:
        lines.append("mode %s cap $%.4f ৳%.2f typical $%.4f ৳%.2f" % (
            m, mode_cap_cost_usd(m), mode_cap_cost_usd(m) * usd_bdt,
            mode_typical_cost_usd(m), mode_typical_cost_usd(m) * usd_bdt))
    for st in (AGENT["steps_typical"], AGENT["steps_max"]):
        lines.append("agent %d steps cached $%.4f uncached $%.4f" % (
            st, agent_cost_usd(st), agent_cost_usd(st, cached=False)))
    # owner proposal, today's code (heavy, no cache); agent = 6-step cached
    heavy = sc["heavy"]
    today_cost = {"smart": call_cost_usd(SONNET, heavy["in"], heavy["out"]),
                  "pro": call_cost_usd(OPUS, heavy["in"], heavy["out"]),
                  "agent": agent_cost_usd(AGENT["steps_max"])}
    typ = sc["typical"]
    typ_cost = {"smart": call_cost_usd(SONNET, typ["in"], typ["out"]),
                "pro": call_cost_usd(OPUS, typ["in"], typ["out"]),
                "agent": agent_cost_usd(AGENT["steps_typical"])}
    q_today = call_cost_usd(HAIKU, heavy["in"], heavy["out"])
    q_cap = mode_cap_cost_usd("quick")
    lines.append("\nOWNER proposal, today's code, HEAVY, annual 12x credits")
    lines.append(_fmt_rows(table(OWNER_PROPOSAL, today_cost.get, q_today, 12, usd_bdt)))
    lines.append("\nOWNER proposal, today's code, TYPICAL, annual 12x")
    lines.append(_fmt_rows(table(OWNER_PROPOSAL, typ_cost.get, q_today, 12, usd_bdt)))
    capped = {"smart": mode_cap_cost_usd("smart"), "pro": mode_cap_cost_usd("pro")}
    cpc = safe_cap_usd = None
    lines.append("\nOWNER credits + CAPS (T1-T4), annual 12x")
    capped_a = dict(capped, agent=agent_cost_usd(AGENT["steps_max"]))
    lines.append(_fmt_rows(table(OWNER_PROPOSAL, capped_a.get, q_cap, 12, usd_bdt)))
    fin = FINAL_PROPOSAL
    # agent hard cap = its credits x the per-credit budget on the cheapest product
    tmp = table(fin, dict(capped, agent=0.0).get, q_cap, fin["annual_credits_x"], usd_bdt)
    del tmp, cpc, safe_cap_usd
    for ax in (10, 12):
        for rate in (120.0, 125.0):
            cap = final_agent_cap_usd(ax, rate)
            costs = dict(capped, agent=cap)
            lines.append("\nFINAL (annual %dx credits) usd_bdt %s agent cap $%.4f" % (ax, rate, cap))
            lines.append(_fmt_rows(table(fin, costs.get, q_cap, ax, rate)))
    for k, e in ECPM_REWARDED_USD.items():
        lines.append("free user (%s eCPM $%s): %s" % (
            k, e, free_user_month(fin, dict(capped, agent=0).get, q_cap, e, usd_bdt)))
    lines.append("free user OWNER/today typical: %s" % free_user_month(
        OWNER_PROPOSAL, typ_cost.get, q_today, ECPM_REWARDED_USD["mid"], usd_bdt))
    lines.append("B-interpretation FINAL annual 10x:")
    lines.append(_fmt_rows(table(fin, dict(capped, agent=final_agent_cap_usd(10)).get, q_cap, 10,
                                 usd_bdt, base="net")))
    return "\n".join(lines)


AGENT_CAP_SAFETY = 0.95     # the cap sits 5 % under the exact 40 % boundary


def final_agent_cap_usd(annual_credits_x=10, usd_bdt=USD_BDT, prop=None):
    """Agent hard cap (USD) = agent credits x the smallest per-credit AI budget
    over the products that allow agent tasks (after their quick-quota share),
    less a 5 % safety margin."""
    prop = prop or FINAL_PROPOSAL
    b = ai_budget_pct()
    q = mode_cap_cost_usd("quick") * prop["quick_free_per_day"] * QUICK_DAYS
    best = None
    for p in products(prop, annual_credits_x):
        if "agent" not in p["modes"]:
            continue
        per = (p["price"] * b / usd_bdt - q * p["quick_months"]) / p["credits"]
        best = per if best is None else min(best, per)
    return round(best * prop["credits"]["agent"] * AGENT_CAP_SAFETY, 4)


if __name__ == "__main__":   # pragma: no cover
    print(report())
