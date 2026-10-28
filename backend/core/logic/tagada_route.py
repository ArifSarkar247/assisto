"""
tagada_route.py — tagada2 (owner order 28 Oct, part B), PURE (no Django):

  1. the SEND ORDER the server decides per customer, and
  2. the SMS-pack price math by the owner's 40 % rule.

SEND ORDER (cheapest first, never a paid route when a free one works):
  1  "assisto"      the customer is an Assisto user matched by a VERIFIED
                    phone (OTP-proven, never the unverified matching flag):
                    an Assisto push + a message in the shop <-> customer
                    thread. FREE.
  2  "whatsapp"     wa.me link, or "own_sms" — the shop owner's OWN SIM SMS
                    composer. FREE; the owner taps send in his own app.
  3  "gateway_sms"  Assisto sends the SMS. NEVER free: the Business plan's
                    monthly SMS allowance first, then bought SMS-pack parts.
                    Never sent without enough parts.

Rules on EVERY channel (server-enforced): at most ONE tagada per customer
per shop per Asia/Dhaka day; a customer who BLOCKED the shop is "not
reachable" (the shop never learns it was a block); STOP / opt-out refuses
Assisto-sent messages; quiet hours 21:00-09:00 refuse what Assisto itself
sends (push + gateway SMS) — WhatsApp / own SIM are the owner's own taps.

PRICE (owner's rule, core/logic/pricing_40.py interpretation A, the
stricter one): after Google's 15 % fee and 15 % VAT the company keeps
price / 1.15 x 0.85; minus 10 % overhead and the real per-part SMS cost,
profit must stay >= 40 % of the price:

    price / 1.15 x 0.85 - 0.10 x price - parts x cost >= 0.40 x price
    => price >= parts x cost / (0.85 / 1.15 - 0.10 - 0.40)  (= / 0.2391)

then rounded UP to a Play-friendly price ending in 9.
"""
import math

CHANNELS = ("assisto", "whatsapp", "own_sms", "gateway_sms")
FREE_CHANNELS = ("assisto", "whatsapp", "own_sms")
SERVER_SENT = ("assisto", "gateway_sms")       # quiet hours + STOP apply

GOOGLE_FEE = 0.15
VAT = 0.15
OVERHEAD = 0.10
PROFIT_MIN = 0.40
DEFAULT_COST_PER_PART = 0.35                   # ৳ until the owner sets the real one

# Proposed packs (parts). Owner approves the table before anything is sold.
PACK_PARTS = (100, 300, 1000)
# Proposed Business plan allowance (parts / month). See SMS_PACKS_BN.md.
DEFAULT_BUSINESS_MONTHLY_PARTS = 30
DEFAULT_LOW_PARTS = 10


# ------------------------------------------------------------------ route
def decide(*, assisto_user, reachable, phone_ok, sent_today, opted_out=False,
           quiet=False, sms_ready=False, parts_needed=1, parts_left=0,
           owner=True):
    """The per-customer route + every option with its honest state.

    Returns {"route": "assisto"|"share"|"none", "options": [
        {"channel", "free", "available", "reason"}]}.
    reason codes: not_reachable, daily_limit, not_assisto_user, opted_out,
    quiet_hours, bad_phone, sms_not_configured, owner_only, no_balance.
    """
    opts = []

    def opt(ch, ok_reasons):
        why = next((r for r, bad in ok_reasons if bad), "")
        opts.append({"channel": ch, "free": ch in FREE_CHANNELS,
                     "available": not why, "reason": why})

    common = [("not_reachable", not reachable), ("daily_limit", sent_today)]
    opt("assisto", common + [("not_assisto_user", not assisto_user),
                             ("opted_out", opted_out), ("quiet_hours", quiet)])
    opt("whatsapp", common + [("bad_phone", not phone_ok)])
    opt("own_sms", common + [("bad_phone", not phone_ok)])
    opt("gateway_sms", common + [("bad_phone", not phone_ok),
                                 ("opted_out", opted_out),
                                 ("quiet_hours", quiet),
                                 ("sms_not_configured", not sms_ready),
                                 ("owner_only", not owner),
                                 ("no_balance", parts_left < max(1, parts_needed))])
    by = {o["channel"]: o for o in opts}
    if by["assisto"]["available"]:
        route = "assisto"
    elif by["whatsapp"]["available"]:
        route = "share"
    else:
        route = "none"
    return {"route": route, "options": opts}


def refusal(channel, *, assisto_user, reachable, phone_ok, sent_today,
            opted_out=False, quiet=False, sms_ready=False, parts_needed=1,
            parts_left=0, owner=True):
    """The reason `channel` can't be used right now, or '' when it can.
    Same rules as decide() — one source of truth for the screen and the
    send endpoint."""
    if channel not in CHANNELS:
        return "bad_channel"
    d = decide(assisto_user=assisto_user, reachable=reachable, phone_ok=phone_ok,
               sent_today=sent_today, opted_out=opted_out, quiet=quiet,
               sms_ready=sms_ready, parts_needed=parts_needed,
               parts_left=parts_left, owner=owner)
    return next(o["reason"] for o in d["options"] if o["channel"] == channel)


# ------------------------------------------------------------------ wallet
def spend_split(parts, allowance_left, pack_left):
    """Allowance FIRST, then pack. None when the two together are short
    (never send without balance)."""
    parts = int(parts)
    if parts <= 0:
        return {"allowance": 0, "pack": 0}
    a = max(0, int(allowance_left))
    p = max(0, int(pack_left))
    if a + p < parts:
        return None
    from_a = min(a, parts)
    return {"allowance": from_a, "pack": parts - from_a}


# ------------------------------------------------------------------ price
def keep_fraction(google=GOOGLE_FEE, vat=VAT):
    """Share of the price the company keeps after VAT and Google's fee."""
    return (1.0 - google) / (1.0 + vat)


def cost_share_max(google=GOOGLE_FEE, vat=VAT, overhead=OVERHEAD, profit=PROFIT_MIN):
    """Largest share of the price the SMS cost may take (≈ 0.2391)."""
    return keep_fraction(google, vat) - overhead - profit


def play_round(taka):
    """Round UP to a whole taka ending in 9 (149, 449, 1469 ...)."""
    t = max(9, int(math.ceil(float(taka) - 1e-9)))
    return t + (9 - t % 10) % 10


def margin(price, parts, cost_per_part, google=GOOGLE_FEE, vat=VAT, overhead=OVERHEAD):
    """{net, vat, google, overhead, sms_cost, profit, profit_pct} at `price`."""
    price = float(price)
    gross_ex_vat = price / (1.0 + vat)
    vat_amt = price - gross_ex_vat
    google_amt = gross_ex_vat * google
    net = gross_ex_vat - google_amt
    ovh = price * overhead
    cost = parts * float(cost_per_part)
    profit = net - ovh - cost
    return {"price": round(price, 2), "vat": round(vat_amt, 2),
            "google": round(google_amt, 2), "net": round(net, 2),
            "overhead": round(ovh, 2), "sms_cost": round(cost, 2),
            "profit": round(profit, 2),
            "profit_pct": round(100.0 * profit / price, 1) if price else 0.0}


def pack_price(parts, cost_per_part=DEFAULT_COST_PER_PART):
    """Minimum price (exact) and the Play price (ending in 9) for a pack."""
    need = parts * float(cost_per_part) / cost_share_max()
    price = play_round(need)
    m = margin(price, parts, cost_per_part)
    assert m["profit_pct"] >= PROFIT_MIN * 100 - 1e-6
    return {"parts": int(parts), "cost_per_part": float(cost_per_part),
            "min_price": round(need, 2), "price": price,
            "per_part": round(price / parts, 3), **{k: m[k] for k in
                                                    ("vat", "google", "net", "overhead",
                                                     "sms_cost", "profit", "profit_pct")}}


def pack_table(cost_per_part=DEFAULT_COST_PER_PART, parts_list=PACK_PARTS):
    return [pack_price(n, cost_per_part) for n in parts_list]


def allowance_cost(parts_per_month, cost_per_part=DEFAULT_COST_PER_PART, plan_price=499):
    """What a full monthly allowance costs the company, as ৳ and % of price."""
    c = parts_per_month * float(cost_per_part)
    return {"parts": int(parts_per_month), "cost": round(c, 2),
            "pct_of_price": round(100.0 * c / plan_price, 2) if plan_price else 0.0}


if __name__ == "__main__":   # pragma: no cover - prints the doc table
    for r in pack_table():
        print(r)
    for n in (30, 50, 100):
        print(allowance_cost(n))
