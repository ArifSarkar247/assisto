"""cctvroles (CCTV Guard V3 L) — the Premium AI tier and its 40 % worst-case
profit check. Pure (no DB, no I/O). OWNER-DECIDED 17 Nov 2026 12:35: 400 Tk
per camera per month (30-day clips, smart alerts), installer commission 10 %
of the NET Premium AI part only (owner_actions/CCTV_PRICING_V3_BN.md). It is
sold only after the owner creates the Play product after launch (Play freeze;
cctv_plan DEFAULTS premium_ai_on_sale).

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
from . import plan_book as PB

# ---- owner-decided 17 Nov 12:35 (numbers live in plan_book.CCTV_DECIDED) ----
AI_ADDON_BDT_PER_CAMERA = PB.CCTV_DECIDED["premium_ai_bdt_per_camera"]   # 400
CLIP_KEEP_DAYS = PB.CCTV_DECIDED["premium_ai_clip_days"]                 # 30
COMMISSION_PCT = PB.CCTV_DECIDED["installer_commission_pct"]            # 10
# 10 % of the NET Premium AI part keeps the worst row at 40.4 % (2 cameras);
# 10 % of the WHOLE site net would drop it to 37.6 % — so the commission base
# is the Premium AI part only, never the base plan.

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
    """Worst case Claude cost for one month (every cap used): `describe` per
    camera, `site` once per site (asks + daily reports), and `total` = one
    camera's share on the smallest paid site (MIN_SITE_CAMERAS)."""
    c = CP.normalize_cfg(cfg)
    usd = c["usd_bdt"]
    describe = DESCRIBE_PER_CAMERA_DAY * 30 * call_usd(DESCRIBE_MODEL, DESCRIBE_TOKENS, prices)
    site = (ASK_PER_SITE_MONTH * call_usd(ASK_MODEL, ASK_TOKENS, prices)
            + REPORT_PER_SITE_MONTH * call_usd(REPORT_MODEL, REPORT_TOKENS, prices))
    return {"describe": round(describe * usd, 2),
            "site": round(site * usd, 2),
            "site_share": round(site / MIN_SITE_CAMERAS * usd, 2),
            "total": round((describe + site / MIN_SITE_CAMERAS) * usd, 2)}


def clip_cost_per_camera_bdt(cfg=None):
    """30-day event clips: relay + storage, reusing the add-on cost model."""
    return CP.addon_cost_bdt(CP.normalize_cfg(cfg), CLIP_KEEP_DAYS)


def profit_table(cfg=None, prices=None, target_pct=40.0, commission_pct_of_net=0.0,
                 commission_pct_of_addon_net=0.0):
    """Per camera count 1..10: base plan + AI add-on price vs worst-case cost
    (base camera cost + Claude + 30-day clips), after Play fee + VAT, and
    optionally after an installer commission: `commission_pct_of_net` = % of
    the whole site net (old proposal math), `commission_pct_of_addon_net` =
    % of the NET Premium AI part only (the owner's decision)."""
    c = CP.normalize_cfg(cfg)
    share = CP.net_share(c)
    base_cam = CP.worst_camera_cost_bdt(c)
    ai_all = ai_cost_per_camera_bdt(c, prices)
    ai, site = ai_all["describe"], ai_all["site"]
    clip = clip_cost_per_camera_bdt(c)
    rows = []
    for n in range(1, CP.MAX_CAMERAS + 1):
        price = CP.monthly_price(n) + AI_ADDON_BDT_PER_CAMERA * n
        net = price * share
        addon_net = AI_ADDON_BDT_PER_CAMERA * n * share
        commission = (net * commission_pct_of_net / 100.0
                      + addon_net * commission_pct_of_addon_net / 100.0)
        # the base plan bills at least BASE_CAMERAS, so cost does too (worst)
        cost = (base_cam + ai + clip) * n + site
        profit = net - cost - commission
        rows.append({"cameras": n, "price": price, "net": round(net, 2),
                     "cost": round(cost, 2), "commission": round(commission, 2),
                     "profit": round(profit, 2),
                     "pct": round(100.0 * profit / price, 1)})
    low = min(r["pct"] for r in rows)
    return {"rows": rows, "min_pct": low, "ok": low >= target_pct,
            "per_camera": {"base": round(base_cam, 2), "ai": ai, "clips": clip},
            "per_site": {"ai": site},
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


def decided_table(cfg=None, prices=None, target_pct=40.0):
    """The OWNER-DECIDED Premium AI rows: 400 Tk per camera WITH the 10 %
    installer commission on the net Premium AI part (worst case: every site
    has an installer)."""
    return profit_table(cfg, prices, target_pct,
                        commission_pct_of_addon_net=COMMISSION_PCT)


def forty_check(cfg=None, prices=None, target_pct=40.0):
    """The CCTV 40 % CI check (owner 17 Nov 12:35). `ok` only when EVERY row
    of every part is >= 40 %:
      * premium_ai  — Premium AI 400 Tk/camera with the 10 % commission,
      * base        — the base plan (500 / 2 cameras, 250 each extra) with NO
                      commission (base_plan_commission_pct = 0),
      * trial       — the 7-day trial rows, with NO EZVIZ row any more."""
    prem = decided_table(cfg, prices, target_pct)
    base = base_with_commission(cfg, PB.CCTV_DECIDED["base_plan_commission_pct"],
                                target_pct)
    trial = CP.trial_profit_rows(cfg, target_pct)
    trial_low = min(r["pct"] for r in trial["rows"]) if trial["rows"] else 100.0
    ezviz_rows = [r for r in trial["rows"]
                  if r["vendor"] in PB.CCTV_DECIDED["trial_excluded_vendors"]]
    ok = (prem["ok"] and base["ok"] and not trial["below"] and not ezviz_rows
          and trial_low >= target_pct)
    return {"ok": ok, "target_pct": target_pct,
            "premium_ai": {"min_pct": prem["min_pct"], "rows": prem["rows"],
                           "commission_pct_of_ai_net": COMMISSION_PCT},
            "base": {"min_pct": base["min_pct"], "rows": base["rows"],
                     "commission_pct": PB.CCTV_DECIDED["base_plan_commission_pct"]},
            "trial": {"min_pct": trial_low, "rows": trial["rows"],
                      "ezviz_rows": len(ezviz_rows)}}
