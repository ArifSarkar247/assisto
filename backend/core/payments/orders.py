"""billing-v2 — PaidOrder bookkeeping + the plan allowance of a paid period
(owner order 27 Oct; rules B, C, D, H, I, S, T, U).

One PaidOrder per real payment order (Play orderId: every renewal has its
own; EPS merchant tx). The plan allowance is granted PER PAID PERIOD from
that order — never per calendar month:

  monthly  one lot = the plan's monthly credits, expiring at the period end
           (Google's expiryTime / the verified EPS period), staged unlock.
  annual   twelve monthly lots on the paid-period anniversary (add_months
           from the period start): month 1 now (staged), months 2..12
           `scheduled` and granted by settle() when each month starts.
           Never 12 months upfront.

Grant keys `<channel>:<orderId>:m<i>` are unique, so an RTDN retry,
restore, reinstall or a double client verify can never grant twice.

Upgrade / downgrade (Premium<->Business, monthly<->annual through Play's
linkedPurchaseToken, or an EPS upgrade): the OLD source's remaining plan
allowance expires and the NEW period's full allowance replaces it — never
both (documented choice: "replace, not add").
"""
from datetime import timedelta
from decimal import Decimal

from django.db import IntegrityError, transaction
from django.utils import timezone

from . import catalog


def record(*, channel, order_id, user, sku, kind, plan="", months=0, price=0,
           currency="BDT", price_source="", is_test=False, purchased_at=None,
           period_start=None, period_end=None, token_hash="", owner_ref="",
           credits_planned=0, raw=None):
    """get_or_create the PaidOrder (channel, order_id). Returns (order, created)."""
    from ..models import PaidOrder
    purchased_at = purchased_at or timezone.now()
    defaults = dict(user=user, sku=sku, kind=kind, plan=plan or "", months=int(months or 0),
                    price=Decimal(str(price or 0)).quantize(Decimal("0.01")),
                    currency=(currency or "BDT")[:3], price_source=price_source[:16],
                    is_test=bool(is_test), purchased_at=purchased_at,
                    period_start=period_start, period_end=period_end,
                    token_hash=token_hash, owner_ref=owner_ref[:40],
                    credits_planned=int(credits_planned or 0), raw=raw or {})
    try:
        with transaction.atomic():
            return PaidOrder.objects.get_or_create(channel=channel, order_id=str(order_id)[:80],
                                                   defaults=defaults)
    except IntegrityError:
        return PaidOrder.objects.get(channel=channel, order_id=str(order_id)[:80]), False


def _slices(start, end, months):
    """[(i, slice_start, slice_end, full?)] month slices of [start, end)."""
    from .. import credits as CR
    out = []
    i = 0
    s = start
    while s < end and i < max(1, months) + 2:
        nxt = CR.add_months(start, i + 1)
        e = min(nxt, end)
        full = i == 0 or (e - s) >= (nxt - s) - timedelta(hours=12)
        out.append((i, s, e, full, (e - s).total_seconds() / max(1.0, (nxt - s).total_seconds())))
        s = e
        i += 1
    return out


def grant_allowance(order, *, source_prefix, now=None, staged=True):
    """Grant the plan allowance of one paid sub period (idempotent). The
    previous allowance of the same source (an earlier renewal) and any
    non-payment base month are expired first — never rolled over, never
    doubled. Returns credits granted now."""
    from .. import credits as CR
    from ..models import CreditLot
    now = now or timezone.now()
    if order.user_id is None or order.kind != "sub" or not order.period_end:
        return 0
    if order.period_end <= now:
        return 0
    first_key = "%s:%s:m0" % (order.channel, order.order_id)
    if CreditLot.objects.filter(grant_key=first_key).exists():
        return 0
    per_month = CR.plan_credits(order.plan, months=order.months or 1)
    user = order.user
    # replace, not add: earlier periods of this token + base months end now
    CR.expire_source(user, source_prefix=source_prefix, why="renewed", now=now)
    CR.expire_source(user, source_prefix="base:", why="paid_plan_started", now=now)
    start = order.period_start or now
    granted = 0
    planned = 0
    for i, s, e, full, frac in _slices(start, order.period_end, order.months or 1):
        amount = per_month if full else int(per_month * frac)
        if amount <= 0:
            continue
        planned += amount
        if e <= now:
            continue
        key = "%s:%s:m%d" % (order.channel, order.order_id, i)
        sid = "%s:%s" % (source_prefix, order.order_id)
        if s <= now:
            lot = CR.grant(user, CR.PLAN, amount, reason="grant",
                           note="%s %s month %d" % (order.plan, order.channel, i + 1),
                           source_type=order.channel, source_id=sid, key=key,
                           expires_at=e, staged=staged and i == 0, order=order,
                           starts_at=now if i == 0 else s, now=now)
            if lot is not None:
                granted += lot.remaining
        else:
            CR.grant(user, CR.PLAN, amount, reason="grant", note="annual month %d" % (i + 1),
                     source_type=order.channel, source_id=sid, key=key, expires_at=e,
                     order=order, starts_at=s, scheduled=True, now=now)
    if planned and planned != order.credits_planned:
        type(order).objects.filter(pk=order.pk).update(credits_planned=planned)
        order.credits_planned = planned
    return granted


def grant_pack(order, *, now=None):
    """Pack credits from a paid order: bucket `pack`, never expire."""
    from .. import credits as CR
    now = now or timezone.now()
    if order.user_id is None:
        return 0
    d = catalog.describe(order.sku) or {}
    n = int(d.get("credits") or order.credits_planned or 0)
    lot = CR.grant(order.user, CR.PACK, n, reason="topup",
                   note="pack:%s %s" % (d.get("pack_id", order.sku), order.channel),
                   source_type=order.channel, source_id="%s:%s" % (order.channel, order.order_id),
                   key="%s:%s:pack" % (order.channel, order.order_id), order=order, now=now)
    return n if lot is not None else 0


def current_sub_order(token_hash, channel="play"):
    """The latest paid period's order of one subscription token."""
    from ..models import PaidOrder
    return (PaidOrder.objects.filter(channel=channel, token_hash=token_hash, kind="sub")
            .order_by("-period_end", "-id").first())


def usage(order, now=None):
    """Numbers for the refund screens: credits granted / used, days used."""
    from ..models import CreditLot
    from django.db.models import Sum
    now = now or timezone.now()
    lots = CreditLot.objects.filter(order=order)
    granted = int(lots.exclude(status="scheduled").aggregate(s=Sum("granted"))["s"] or 0)
    used = int(lots.aggregate(s=Sum("spent"))["s"] or 0)
    planned = int(order.credits_planned or 0) or granted
    if order.kind == "pack":
        planned = planned or int((catalog.describe(order.sku) or {}).get("credits") or 0)
    days_total = days_used = 0.0
    if order.kind == "sub" and order.period_start and order.period_end:
        tot = (order.period_end - order.period_start).total_seconds()
        usd = min(max(0.0, (now - order.period_start).total_seconds()), tot)
        days_total, days_used = tot / 86400.0, usd / 86400.0
    return {"credits_granted": granted, "credits_planned": planned, "credits_used": used,
            "days_total": round(days_total, 2), "days_used": round(days_used, 2)}


def suggested_refund(order, now=None):
    """price x min(unused credits share, unused days share) — the unused part
    only (rule K). Packs have no days, so only the credits share counts."""
    u = usage(order, now)
    price = Decimal(order.price or 0) - Decimal(order.refunded_amount or 0)
    if price <= 0:
        return Decimal("0.00"), u
    cshare = Decimal(1)
    if u["credits_planned"] > 0:
        cshare = max(Decimal(0), Decimal(u["credits_planned"] - u["credits_used"])
                     / Decimal(u["credits_planned"]))
    dshare = Decimal(1)
    if order.kind == "sub" and u["days_total"] > 0:
        dshare = max(Decimal(0), Decimal(str(u["days_total"] - u["days_used"]))
                     / Decimal(str(u["days_total"])))
    share = min(cshare, dshare)
    amt = (price * share).quantize(Decimal("0.01"), rounding="ROUND_DOWN")
    u["credits_share"] = float(round(cshare, 4))
    u["days_share"] = float(round(dshare, 4))
    return amt, u
