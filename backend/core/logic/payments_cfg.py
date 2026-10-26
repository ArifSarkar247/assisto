"""payments_cfg.py — PURE defaults + normalization of the pay1 "payments" block
of PricingConfig (admin-editable at /owner/payments; /admin/pricing shows it).

No Django, no DB, no clock. core.logic.pricing.normalize() calls normalize()
so the block is always present and well-formed.

Keys
  play_enabled       Google Play Billing offered in the Play build.
  gateway_enabled    The payment gateway (EPS) offered on the direct APK and on
                     lifeassisto.com/premium.
  gateway_on_play    The gateway is ALSO offered inside the Play build
                     (owner compliance kill-switch; applies to EVERY user, it is
                     never a review-only toggle). Default OFF and must stay OFF
                     (owner 26 Oct): in the Play build every digital good is
                     sold through Google Play Billing only. The Play app
                     ignores it for digital goods in any case.
  web_enabled        lifeassisto.com/premium checkout page on/off.
  play_fee_subs      Google's cut on subscriptions (0.15 = 15 %).
  play_fee_packs     Google's cut on one-time products (credit packs).
  gateway_fee        Gateway MDR (EPS), fraction of the amount.
  channel_prices     {"play": {sku: ৳}, "gateway": {sku: ৳}} — per-channel
                     overrides; a missing sku = the base price (same price
                     everywhere, the owner's current decision).
  reminder_days      Days before a PREPAID gateway period ends when the user
                     gets a renew reminder (push, + SMS when the SMS gateway is
                     configured).
  play_products      Play Console product ids (subscription id + base plan id
                     per sku; product id per credit pack).
  pending_ttl_min    A gateway order still unpaid after this many minutes is
                     re-checked one last time and then marked expired.
"""

SUB_SKUS = ("premium_monthly", "premium_yearly", "business_monthly", "business_yearly")

_PLAY_PRODUCTS = {
    "premium_monthly": {"product_id": "assisto_premium", "base_plan": "monthly"},
    "premium_yearly": {"product_id": "assisto_premium", "base_plan": "yearly"},
    "business_monthly": {"product_id": "assisto_business", "base_plan": "monthly"},
    "business_yearly": {"product_id": "assisto_business", "base_plan": "yearly"},
}


def defaults():
    return {
        "play_enabled": True,
        "gateway_enabled": True,
        "gateway_on_play": False,   # owner 26 Oct: Play build sells digital goods via Play Billing only
        "web_enabled": True,
        "play_fee_subs": 0.15,
        "play_fee_packs": 0.15,
        "gateway_fee": 0.02,
        "channel_prices": {"play": {}, "gateway": {}},
        "reminder_days": [7, 3, 1],
        "play_products": {k: dict(v) for k, v in _PLAY_PRODUCTS.items()},
        "pack_product_prefix": "credits_",
        "pending_ttl_min": 120,
    }


def _bool(v, fb):
    if isinstance(v, bool):
        return v
    if isinstance(v, str) and v.lower() in ("true", "false", "1", "0", "on", "off"):
        return v.lower() in ("true", "1", "on")
    if v in (0, 1):
        return bool(v)
    return fb


def _frac(v, fb):
    try:
        if isinstance(v, bool):
            return fb
        f = float(v)
    except (TypeError, ValueError):
        return fb
    return max(0.0, min(0.5, f))


def _price(v):
    try:
        if isinstance(v, bool):
            return None
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


_ID_OK = set("abcdefghijklmnopqrstuvwxyz0123456789._-")


def _pid(v, fb):
    s = str(v or "").strip().lower()[:64]
    return s if s and set(s) <= _ID_OK and s[0].isalnum() else fb


def normalize(raw):
    raw = raw if isinstance(raw, dict) else {}
    base = defaults()
    out = {}
    for k in ("play_enabled", "gateway_enabled", "gateway_on_play", "web_enabled"):
        out[k] = _bool(raw.get(k), base[k])
    for k in ("play_fee_subs", "play_fee_packs", "gateway_fee"):
        out[k] = _frac(raw.get(k), base[k])
    cp = raw.get("channel_prices") if isinstance(raw.get("channel_prices"), dict) else {}
    out["channel_prices"] = {}
    for ch in ("play", "gateway"):
        src = cp.get(ch) if isinstance(cp.get(ch), dict) else {}
        clean = {}
        for sku, v in src.items():
            p = _price(v)
            if p is not None and isinstance(sku, str) and len(sku) <= 32:
                clean[sku] = p
        out["channel_prices"][ch] = clean
    days = raw.get("reminder_days")
    if isinstance(days, list):
        ds = sorted({int(d) for d in days
                     if isinstance(d, (int, float)) and not isinstance(d, bool)
                     and 0 < int(d) <= 30}, reverse=True)
    else:
        ds = list(base["reminder_days"])
    out["reminder_days"] = ds[:5]
    pp = raw.get("play_products") if isinstance(raw.get("play_products"), dict) else {}
    out["play_products"] = {}
    for sku, d in base["play_products"].items():
        r = pp.get(sku) if isinstance(pp.get(sku), dict) else {}
        out["play_products"][sku] = {
            "product_id": _pid(r.get("product_id"), d["product_id"]),
            "base_plan": _pid(r.get("base_plan"), d["base_plan"]),
        }
    out["pack_product_prefix"] = _pid(raw.get("pack_product_prefix"),
                                      base["pack_product_prefix"])
    try:
        ttl = int(raw.get("pending_ttl_min", base["pending_ttl_min"]))
    except (TypeError, ValueError):
        ttl = base["pending_ttl_min"]
    out["pending_ttl_min"] = max(15, min(1440, ttl))
    return out
