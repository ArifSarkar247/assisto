"""Server-authoritative product catalog for every payment channel.

A SKU is what the user buys:
  premium_monthly / premium_yearly / business_monthly / business_yearly
      plan subscriptions (Play: auto-renewing; gateway: a PREPAID period)
  pack_<id>  (pack_p20, pack_p50, ...)
      one-time credit packs from PricingConfig.topup_packs

Prices come ONLY from PricingConfig (plans.*.price, annual_discount_pct,
topup_packs) plus optional per-channel overrides in payments.channel_prices.
The client never sends a price; whatever it sends is ignored.
"""
from decimal import Decimal

from ..logic import pricing

CHANNELS = ("play", "gateway")
SUB_PLANS = ("premium", "business")
TIER = {"free": 0, "premium": 1, "family": 1, "annual": 1, "probashi": 1,
        "founder": 1, "business": 2}


def _cfg(cfg=None):
    if cfg is not None:
        return pricing.normalize(cfg)
    from .. import billing
    return billing.cfg()


def pay_cfg(cfg=None):
    return _cfg(cfg)["payments"]


def base_price(sku, cfg=None):
    """Whole-taka base price of a sku, or None for an unknown sku."""
    c = _cfg(cfg)
    if sku.startswith("pack_"):
        p = pricing.pack_by_id(sku[5:], c)
        return int(p["price"]) if p else None
    try:
        plan, period = sku.rsplit("_", 1)
    except ValueError:
        return None
    if plan not in SUB_PLANS or period not in ("monthly", "yearly"):
        return None
    if period == "monthly":
        return int(c["plans"][plan]["price"])
    return int(pricing.annual_price(plan, c))


def price(sku, channel, cfg=None):
    """Price (whole ৳) of `sku` on `channel`; None when not for sale."""
    base = base_price(sku, cfg)
    if base is None or base <= 0:
        return None
    over = pay_cfg(cfg)["channel_prices"].get(channel, {}).get(sku)
    return int(over) if over else base


def fee_pct(sku, channel, cfg=None):
    pc = pay_cfg(cfg)
    if channel == "play":
        return pc["play_fee_packs"] if sku.startswith("pack_") else pc["play_fee_subs"]
    return pc["gateway_fee"]


def net(amount, sku, channel, cfg=None):
    """Amount we keep after the channel fee (VAT is reported separately)."""
    a = Decimal(str(amount or 0))
    return (a * (Decimal(1) - Decimal(str(fee_pct(sku, channel, cfg))))).quantize(
        Decimal("0.01"))


def describe(sku, cfg=None):
    """{sku, kind, plan, period, months, credits, valid_months} or None."""
    c = _cfg(cfg)
    if sku.startswith("pack_"):
        p = pricing.pack_by_id(sku[5:], c)
        if not p:
            return None
        return {"sku": sku, "kind": "pack", "plan": "", "period": "", "months": 0,
                "credits": int(p["credits"]), "valid_months": int(p["valid_months"]),
                "pack_id": p["id"]}
    if base_price(sku, c) is None:
        return None
    plan, period = sku.rsplit("_", 1)
    return {"sku": sku, "kind": "sub", "plan": plan, "period": period,
            "months": 1 if period == "monthly" else 12, "credits": 0}


def all_skus(cfg=None):
    c = _cfg(cfg)
    out = [f"{p}_{per}" for p in SUB_PLANS for per in ("monthly", "yearly")]
    out += ["pack_" + p["id"] for p in pricing.topup_packs(c)]
    return [s for s in out if base_price(s, c)]


def play_product(sku, cfg=None):
    """(product_id, base_plan_id) in Play Console for a sku."""
    pc = pay_cfg(cfg)
    if sku.startswith("pack_"):
        return (pc["pack_product_prefix"] + sku[5:], "")
    d = pc["play_products"].get(sku)
    return (d["product_id"], d["base_plan"]) if d else ("", "")


def sku_for_play(product_id, base_plan_id="", cfg=None):
    """Reverse map of play_product(); '' when the product is not ours."""
    pc = pay_cfg(cfg)
    for sku, d in pc["play_products"].items():
        if d["product_id"] == product_id and (not base_plan_id
                                              or d["base_plan"] == base_plan_id):
            return sku
    pre = pc["pack_product_prefix"]
    if product_id.startswith(pre):
        sku = "pack_" + product_id[len(pre):]
        if describe(sku, cfg):
            return sku
    return ""


def products(channel, lang="bn", cfg=None):
    """The public list for the checkout sheet: price on THIS channel."""
    from ..i18n import pick
    c = _cfg(cfg)
    out = []
    names = {"premium": ("প্রিমিয়াম", "Premium"), "business": ("বিজনেস", "Business")}
    for sku in all_skus(c):
        d = describe(sku, c)
        pr = price(sku, channel, c)
        if not d or not pr:
            continue
        if d["kind"] == "sub":
            bn, en = names[d["plan"]]
            title = pick(lang, bn, en)
        else:
            title = pick(lang, f"{d['credits']} ক্রেডিট", f"{d['credits']} credits")
        pid, bp = play_product(sku, c)
        out.append({"sku": sku, "kind": d["kind"], "plan": d["plan"],
                    "period": d["period"], "months": d["months"],
                    "credits": d["credits"], "price_bdt": pr, "cur": "BDT",
                    "title": title, "play_product_id": pid, "play_base_plan": bp})
    return out
