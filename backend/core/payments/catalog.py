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
SUB_PLANS = ("premium", "business", "plus", "premium_pro")   # plus/premium_pro: price 0 = not sold
# probashi-plan: a Play-only subscription (assisto_probashi). Its real price
# is Google's local-currency price; the BDT figure here is only the revenue
# fallback (probashi_price_usd x usd_bdt) when Google's price is not in BDT.
PLAY_ONLY_PLANS = ("probashi",)
TIER = {"free": 0, "premium": 1, "family": 1, "annual": 1, "probashi": 1,
        "plus": 1, "premium_pro": 1,
        "founder": 1, "business": 2}


def _cfg(cfg=None):
    if cfg is not None:
        return pricing.normalize(cfg)
    from .. import billing
    return billing.cfg()


def pay_cfg(cfg=None):
    return _cfg(cfg)["payments"]


SELLER_PREFIX = "seller_"   # p1-bizagent: seller_<plan>_monthly (gateway only)
# tagada2: SMS packs (smspack_<parts>) — PLAY ONLY one-time products that add
# SMS PARTS (core/sms_wallet), never AI credits. Priced by the owner's 40 %
# rule from the real per-part cost (core/logic/tagada_route.pack_price).
SMSPACK_PREFIX = "smspack_"
SMSPACK_PRODUCT_PREFIX = "assisto_sms_"


def _smspack_parts(sku):
    from ..logic import tagada_route as TR
    if not sku.startswith(SMSPACK_PREFIX):
        return 0
    try:
        n = int(sku[len(SMSPACK_PREFIX):])
    except ValueError:
        return 0
    return n if n in TR.PACK_PARTS else 0


def _smspack_price(n, c):
    from ..logic import tagada_route as TR
    cost = float((c.get("sms") or {}).get("default_cost_per_segment_bdt")
                 or TR.DEFAULT_COST_PER_PART)
    return TR.pack_price(n, cost)["price"]


def is_smspack(sku):
    return _smspack_parts(sku) > 0


def _seller_plan(sku):
    if not sku.startswith(SELLER_PREFIX) or not sku.endswith("_monthly"):
        return ""
    return sku[len(SELLER_PREFIX):-len("_monthly")]


def base_price(sku, cfg=None):
    """Whole-taka base price of a sku, or None for an unknown sku."""
    c = _cfg(cfg)
    sp = _seller_plan(sku)
    if sp:
        row = (c.get("seller_agent") or {}).get("plans", {}).get(sp)
        return int(row["price"]) if row else None
    if sku.startswith("pack_"):
        p = pricing.pack_by_id(sku[5:], c)
        return int(p["price"]) if p else None
    if sku.startswith(SMSPACK_PREFIX):
        n = _smspack_parts(sku)
        return _smspack_price(n, c) if n else None
    try:
        plan, period = sku.rsplit("_", 1)
    except ValueError:
        return None
    if period not in ("monthly", "yearly"):
        return None
    if plan in PLAY_ONLY_PLANS:
        m = int(round(float(c.get("probashi_price_usd") or 0) * float(c.get("usd_bdt") or 0)))
        if m <= 0:
            return None
        return m if period == "monthly" else m * 10   # annual = 10 x monthly (owner)
    if plan not in SUB_PLANS:
        return None
    if period == "monthly":
        return int(c["plans"][plan]["price"])
    return int(pricing.annual_price(plan, c))


# pricing-40 (owner 27 Oct night): every NEW product stays NOT purchasable
# until the server has verified through the Play Developer API that its Play
# product / base plan exists and is ACTIVE (core/payments/play_verify.py).
LEGACY_PACKS = ("p20", "p50", "p100", "p200")
GATED_PREFIXES = ("plus_", "premium_pro_", "probashi_")


def is_gated(sku):
    if sku.startswith(SMSPACK_PREFIX):
        return True
    if sku.startswith("pack_"):
        return sku[5:] not in LEGACY_PACKS
    return sku.startswith(GATED_PREFIXES)


def price(sku, channel, cfg=None, gate=True):
    """Price (whole ৳) of `sku` on `channel`; None when not for sale.
    gate=False (only for syncing a purchase Google already made) skips the
    Play-verified check."""
    if channel != "play" and sku.split("_", 1)[0] in PLAY_ONLY_PLANS:
        return None
    if sku.startswith(SMSPACK_PREFIX):
        # Play only, and only once the owner switched packs on (approval).
        if channel != "play":
            return None
        if gate and not int((_cfg(cfg).get("sms") or {}).get("packs_on_sale") or 0):
            return None
    base = base_price(sku, cfg)
    if base is None or base <= 0:
        return None
    if gate and is_gated(sku):
        from . import play_verify
        if not play_verify.verified(sku):
            return None
    over = pay_cfg(cfg)["channel_prices"].get(channel, {}).get(sku)
    return int(over) if over else base


def fee_pct(sku, channel, cfg=None):
    pc = pay_cfg(cfg)
    if channel == "play":
        return pc["play_fee_packs"] if sku.startswith(("pack_", SMSPACK_PREFIX)) \
            else pc["play_fee_subs"]
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
    if sku.startswith(SMSPACK_PREFIX):
        n = _smspack_parts(sku)
        if not n:
            return None
        return {"sku": sku, "kind": "smspack", "plan": "", "period": "", "months": 0,
                "credits": 0, "sms_parts": n}
    if base_price(sku, c) is None:
        return None
    sp = _seller_plan(sku)
    if sp:   # p1-bizagent: a prepaid month of AI replies for the seller agent
        return {"sku": sku, "kind": "seller", "plan": sp, "period": "monthly",
                "months": 1, "credits": 0}
    plan, period = sku.rsplit("_", 1)
    return {"sku": sku, "kind": "sub", "plan": plan, "period": period,
            "months": 1 if period == "monthly" else 12, "credits": 0}


def all_skus(cfg=None):
    c = _cfg(cfg)
    out = [f"{p}_{per}" for p in SUB_PLANS for per in ("monthly", "yearly")]
    out += ["pack_" + p["id"] for p in pricing.topup_packs(c)]
    from ..logic import tagada_route as TR
    out += ["%s%d" % (SMSPACK_PREFIX, n) for n in TR.PACK_PARTS]
    return [s for s in out if base_price(s, c)]


def play_product(sku, cfg=None):
    """(product_id, base_plan_id) in Play Console for a sku."""
    pc = pay_cfg(cfg)
    if sku.startswith("pack_"):
        return (pc["pack_product_prefix"] + sku[5:], "")
    if sku.startswith(SMSPACK_PREFIX):
        return (SMSPACK_PRODUCT_PREFIX + sku[len(SMSPACK_PREFIX):], "")
    d = pc["play_products"].get(sku)
    return (d["product_id"], d["base_plan"]) if d else ("", "")


def sku_for_play(product_id, base_plan_id="", cfg=None):
    """Reverse map of play_product(); '' when the product is not ours."""
    pc = pay_cfg(cfg)
    for sku, d in pc["play_products"].items():
        if d["product_id"] == product_id and (not base_plan_id
                                              or d["base_plan"] == base_plan_id):
            return sku
    if product_id.startswith(SMSPACK_PRODUCT_PREFIX):
        sku = SMSPACK_PREFIX + product_id[len(SMSPACK_PRODUCT_PREFIX):]
        return sku if is_smspack(sku) else ""
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
    names = {"premium": ("প্রিমিয়াম", "Premium"), "business": ("বিজনেস", "Business"),
             "plus": ("প্লাস", "Plus"), "premium_pro": ("প্রিমিয়াম প্রো", "Premium Pro")}
    for sku in all_skus(c):
        d = describe(sku, c)
        pr = price(sku, channel, c)
        if not d or not pr:
            continue
        if d["kind"] == "sub":
            bn, en = names[d["plan"]]
            title = pick(lang, bn, en)
        elif d["kind"] == "smspack":
            from ..logic.business_khata import normalize_digits_out as _bn
            title = pick(lang, f"{_bn(str(d['sms_parts']))}টি SMS", f"{d['sms_parts']} SMS")
        else:
            title = pick(lang, f"{d['credits']} ক্রেডিট", f"{d['credits']} credits")
        pid, bp = play_product(sku, c)
        out.append({"sku": sku, "kind": d["kind"], "plan": d["plan"],
                    "period": d["period"], "months": d["months"],
                    "credits": d["credits"], "price_bdt": pr, "cur": "BDT",
                    "title": title, "play_product_id": pid, "play_base_plan": bp})
    return out
