"""cctvroles (CCTV Guard V3 L) — the Premium AI tier PROPOSAL and its 40 %
worst-case profit check. Pure (no DB, no I/O). NOT a live price: nothing in
the app sells it; the owner decides (owner_actions/CCTV_PRICING_V3_BN.md).

One source of numbers, never forked:
  * base plan, extra camera, clip size / count, traffic, storage, server,
    Play fee, VAT  -> core/logic/cctv_plan.py (DEFAULTS, monthly_price,
    worst_camera_cost_bdt, addon_cost_bdt, net_share)
  * Claude model prices (Gemini is off, owner 9 Nov 13:30) -> core/ai_config.py
    DEFAULT_PRICES (USD per 1M tokens)

Where the AI runs: detection on the Guard Box (the customer's own Android
TV box / mini PC / Raspberry Pi / old phone — no cloud GPU cost to us).
Claude is used only for (1) a short Bangla description of an alert from one
small thumbnail, (2) "ask in Bangla" questions over event metadata, (3) the
closing-time daily report text. Each is CAPPED per camera / site / month.
"""
from . import cctv_plan as CP

# ---- the proposal (owner decides) ----
AI_ADDON_BDT_PER_CAMERA = 400        # per camera per month, on top of the base plan
# (350 passes alone at 42.6 % but leaves no room for the installer commission;
#  400 keeps >= 40 % WITH the 5 % commission: 41.3 % worst case)
TRIAL_DAYS_PROPOSED = 14             # live code today: cctv_plan.TRIAL_DAYS (7)
CLIP_KEEP_DAYS = 30                  # Premium: event clips in the cloud 30 days

# ---- caps that make the worst case finite ----
DESCRIBE_PER_CAMERA_DAY = 30         # Bangla alert descriptions (Haiku)
ASK_PER_SITE_MONTH = 60              # "ask in Bangla" questions (Sonnet)
REPORT_PER_SITE_MONTH = 31           # daily report texts (Haiku)

# ---- token budgets per call (worst case, measured upper bounds) ----
DESCRIBE_TOKENS = {"in": 1100, "out": 160}     # 640x360 thumbnail ~310 + prompt
ASK_TOKENS = {"in": 4000, "out": 600}          # event list as text, answer in Bangla
REPORT_TOKENS = {"in": 2500, "out": 700}

DESCRIBE_MODEL = "claude-haiku-5-5"
ASK_MODEL = "claude-sonnet-5-5"
REPORT_MODEL = "claude-haiku-5-5"
MIN_SITE_CAMERAS = 2                 # the base plan's cameras (ask cost spread)


def _prices():
    from core import ai_config
    return ai_config.DEFAULT_PRICES


def call_usd(model, tokens, prices=None):
    p = (prices or _prices()).get(model)
    if p is None:
        from core import ai_config
        p = ai_config.FALLBACK_PRICE
    return (tokens["in"] * p["in"] + tokens["out"] * p["out"]) / 1e6


def ai_cost_per_camera_bdt(cfg=None, prices=None):
    """Worst case Claude cost of ONE camera for one month (every cap used);
    the per-site ask + report cost is spread over MIN_SITE_CAMERAS."""
    c = CP.normalize_cfg(cfg)
    usd = c["usd_bdt"]
    describe = DESCRIBE_PER_CAMERA_DAY * 30 * call_usd(DESCRIBE_MODEL, DESCRIBE_TOKENS, prices)
    site = (ASK_PER_SITE_MONTH * call_usd(ASK_MODEL, ASK_TOKENS, prices)
            + REPORT_PER_SITE_MONTH * call_usd(REPORT_MODEL, REPORT_TOKENS, prices))
    return {"describe": round(describe * usd, 2),
            "site_share": round(site / MIN_SITE_CAMERAS * usd, 2),
            "total": round((describe + site / MIN_SITE_CAMERAS) * usd, 2)}


def clip_cost_per_camera_bdt(cfg=None):
    """30-day event clips: relay + storage, reusing the add-on cost model."""
    return CP.addon_cost_bdt(CP.normalize_cfg(cfg), CLIP_KEEP_DAYS)


def profit_table(cfg=None, prices=None, target_pct=40.0, commission_pct_of_net=0.0):
    """Per camera count 1..10: base plan + AI add-on price vs worst-case cost
    (base camera cost + Claude + 30-day clips), after Play fee + VAT, and
    optionally after an installer commission (% of net)."""
    c = CP.normalize_cfg(cfg)
    share = CP.net_share(c)
    base_cam = CP.worst_camera_cost_bdt(c)
    ai = ai_cost_per_camera_bdt(c, prices)["total"]
    clip = clip_cost_per_camera_bdt(c)
    rows = []
    for n in range(1, CP.MAX_CAMERAS + 1):
        price = CP.monthly_price(n) + AI_ADDON_BDT_PER_CAMERA * n
        net = price * share
        commission = net * commission_pct_of_net / 100.0
        cost = (base_cam + ai + clip) * max(n, 1)
        profit = net - cost - commission
        rows.append({"cameras": n, "price": price, "net": round(net, 2),
                     "cost": round(cost, 2), "commission": round(commission, 2),
                     "profit": round(profit, 2),
                     "pct": round(100.0 * profit / price, 1)})
    low = min(r["pct"] for r in rows)
    return {"rows": rows, "min_pct": low, "ok": low >= target_pct,
            "per_camera": {"base": round(base_cam, 2), "ai": ai, "clips": clip},
            "addon_price": AI_ADDON_BDT_PER_CAMERA, "net_share": round(share, 4),
            "target_pct": target_pct}


def base_with_commission(cfg=None, commission_pct_of_net=10.0, target_pct=40.0):
    """The TODAY base plan (no AI tier) after an installer commission."""
    c = CP.normalize_cfg(cfg)
    share = CP.net_share(c)
    per_cam = CP.worst_camera_cost_bdt(c)
    rows = []
    for n in range(1, CP.MAX_CAMERAS + 1):
        price = CP.monthly_price(n)
        net = price * share
        commission = net * commission_pct_of_net / 100.0
        profit = net - per_cam * n - commission
        rows.append({"cameras": n, "price": price, "pct": round(100.0 * profit / price, 1)})
    low = min(r["pct"] for r in rows)
    return {"rows": rows, "min_pct": low, "ok": low >= target_pct}
