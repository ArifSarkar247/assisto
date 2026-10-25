"""Payments orchestration — what the API views, the website and the sweep call.

Gateway flow (direct APK + lifeassisto.com/premium):
  checkout(user, sku)            -> PaymentOrder (amount from OUR table) +
                                    hosted-checkout redirect URL
  browser returns to /pay/return -> complete(order)  (status API verify)
  gateway IPN                    -> complete(order)  (status API verify)
  sweep                          -> re-verifies stale pending orders
complete() grants only when the gateway's own status API says paid AND its
merchant tx id, amount and currency match the order. Idempotent under a row
lock; the gateway transaction id is unique, so one payment = one grant.
"""
import logging
import secrets
import time
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from . import catalog, entitlement as E, gateway as G

log = logging.getLogger(__name__)


class PayError(Exception):
    def __init__(self, reason, status=400, **extra):
        super().__init__(reason)
        self.reason, self.status, self.extra = reason, status, extra


MESSAGES = {
    "not_for_sale": ("এই প্যাকটি এখন কেনা যাচ্ছে না।", "This item is not for sale right now."),
    "channel_off": ("এই পেমেন্ট পদ্ধতি এখন বন্ধ আছে।", "This payment method is switched off right now."),
    "not_configured": ("পেমেন্ট গেটওয়ে এখনও চালু হয়নি — মালিক কী যোগ করলে চালু হবে।",
                       "The payment gateway is not set up yet — it turns on when the owner adds the keys."),
    "managed_by_play": ("আপনার সাবস্ক্রিপশন Google Play থেকে চলছে — সেখান থেকেই পরিবর্তন করুন।",
                        "Your subscription runs through Google Play — change it there."),
    "rate_limited": ("একটু পরে আবার চেষ্টা করুন।", "Please try again in a little while."),
    "gateway_error": ("পেমেন্ট শুরু করা যায়নি। একটু পরে আবার চেষ্টা করুন।",
                      "Could not start the payment. Please try again shortly."),
    "prepaid_active": ("আপনার প্রিপেইড প্ল্যান এখনও চালু আছে — শেষ হলে নবায়ন করুন, বা বিজনেসে আপগ্রেড করুন।",
                       "Your prepaid plan is still running — renew when it ends, or upgrade to Business."),
    "not_found": ("খুঁজে পাওয়া যায়নি।", "Not found."),
    "bad_request": ("অনুরোধটি ঠিক নেই।", "That request was not valid."),
    "idempotency_conflict": ("এই অনুরোধ আগে অন্য কিছুর জন্য ব্যবহার হয়েছে।",
                             "This request was already used for something else."),
    "other_account": ("এই কেনাকাটা অন্য একটি Assisto অ্যাকাউন্টের।",
                      "This purchase belongs to another Assisto account."),
    "unknown_product": ("এই পণ্যটি চেনা যায়নি।", "Unknown product."),
    "already_active": ("এই প্ল্যান আপনার আগে থেকেই চালু আছে (Google Play)।",
                       "You already have this plan through Google Play."),
}


def message(reason, lang="bn"):
    bn, en = MESSAGES.get(reason, ("কিছু একটা ভুল হয়েছে।", "Something went wrong."))
    return en if lang == "en" else bn


def site():
    return getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")


def api_base():
    return getattr(settings, "PUBLIC_API_BASE", "https://api.lifeassisto.com").rstrip("/")


def urls():
    s = site()
    return {"success": s + "/pay/return?r=success", "fail": s + "/pay/return?r=fail",
            "cancel": s + "/pay/return?r=cancel",
            "ipn": api_base() + "/api/v1/payments/gateway/ipn"}


# ----------------------------------------------------------------- runtime config
def channel_state(flavour="apk"):
    """Which ways to pay exist for THIS build, from the owner's switches.
    `flavour` is 'play' (Google Play build) or 'apk' (website APK / web).
    The switches apply to everyone — no per-reviewer hiding."""
    from . import play
    pc = catalog.pay_cfg()
    gw = G.get()
    gw_ok = bool(gw and pc["gateway_enabled"] and (flavour != "play" or pc["gateway_on_play"]))
    out = []
    if flavour == "play":
        out.append({"id": "play", "enabled": bool(pc["play_enabled"]),
                    "ready": play.configured(), "label": "Google Play"})
    out.append({"id": "gateway", "provider": gw.slug if gw else G.default_slug(),
                "enabled": bool(pc["gateway_enabled"] and (flavour != "play" or pc["gateway_on_play"])),
                "ready": gw_ok, "label": "bKash / Nagad / Card — EPS"})
    return out


def any_live(flavour="apk"):
    """NO SHOWPIECES: True iff at least one way to pay is really usable on
    this build — the owner switch is on AND its keys are added. The app shows
    Choose / Buy / Renew entry points only while this is true (s2's
    `purchasable` contract on /credits/packs is this value)."""
    try:
        return any(c["enabled"] and c["ready"] for c in channel_state(flavour))
    except Exception:
        return False


def config_for(user, flavour, lang="bn"):
    from . import play
    chans = channel_state(flavour)
    products = {c["id"]: catalog.products(c["id"], lang) for c in chans}
    return {"channels": chans, "products": products,
            "purchasable": any(c["enabled"] and c["ready"] for c in chans),
            "play_account_id": play.account_id(user) if user else "",
            "state": E.summary(user) if user else None,
            "server_time": timezone.now().isoformat()}


# ----------------------------------------------------------------- gateway checkout
def _new_tx():
    # EPS wants a numeric merchantTransactionId of at least 10 digits.
    return "%d%04d" % (int(time.time() * 1000), secrets.randbelow(10000))


def _play_conflict(user, plan, now):
    """A Google Play subscription of the same or higher tier is running —
    paying the gateway too would double-charge."""
    from ..models import PlanPeriod
    for p in PlanPeriod.objects.filter(user=user, source="play", status="active",
                                       ends_at__gt=now):
        if E.tier(p.plan) >= E.tier(plan):
            return True
    return False


def checkout(user, sku, *, source="app", idem="", flavour="apk", ip="", lang="bn", now=None):
    """Create (or return the existing, idempotent) gateway order + session."""
    from ..models import PaymentOrder
    now = now or timezone.now()
    pc = catalog.pay_cfg()
    if not pc["gateway_enabled"] or (flavour == "play" and not pc["gateway_on_play"]) \
            or (source == "web" and not pc["web_enabled"]):
        raise PayError("channel_off", 409)
    d = catalog.describe(sku)
    amount = catalog.price(sku, "gateway")
    if not d or not amount:
        raise PayError("not_for_sale", 400)
    gw = G.get()
    if gw is None:
        raise PayError("not_configured", 503)
    if d["kind"] == "sub" and _play_conflict(user, d["plan"], now):
        raise PayError("managed_by_play", 409)
    idem = (idem or "")[:64]
    if idem:
        prev = PaymentOrder.objects.filter(user=user, idempotency_key=idem).first()
        if prev is not None:
            if prev.sku != sku:
                raise PayError("idempotency_conflict", 409)
            if prev.status in ("created", "pending") and prev.raw.get("redirect_url"):
                return prev
            if prev.status == "paid":
                return prev
    recent = PaymentOrder.objects.filter(user=user, created_at__gte=now - timedelta(hours=1)).count()
    if recent >= 15:
        raise PayError("rate_limited", 429)
    try:
        with transaction.atomic():
            order = PaymentOrder.objects.create(
                user=user, channel="gateway", provider=gw.slug, source=source, sku=sku,
                kind=d["kind"], plan=d["plan"], months=d["months"], credits=d["credits"],
                amount_bdt=Decimal(amount).quantize(Decimal("0.01")), fee_pct=Decimal(str(catalog.fee_pct(sku, "gateway"))),
                merchant_tx_id=_new_tx(), idempotency_key=idem, status="created")
    except IntegrityError:
        prev = PaymentOrder.objects.filter(user=user, idempotency_key=idem).first()
        if prev:
            return prev
        raise
    from .. import plans
    product = ("Assisto " + d["plan"].title() + (" (1 year)" if d["months"] == 12 else " (1 month)")
               if d["kind"] == "sub" else
               ("Assisto Seller AI " + d["plan"].title() + " (1 month)") if d["kind"] == "seller"
               else "Assisto %d credits" % d["credits"])
    cust = {"name": (user.name or "")[:60], "email": (user.email or "")[:80],
            "phone": (user.phone or "")[:20], "ip": ip, "product": product}
    try:
        sess = gw.create_session(order, cust, urls())
    except G.GatewayError as e:
        order.status, order.detail = "failed", ("init: %s %s" % (e.reason, e.detail))[:200]
        order.save(update_fields=["status", "detail", "updated_at"])
        E.event(user, "order.init_failed", "gateway", order.merchant_tx_id, reason=e.reason)
        raise PayError("gateway_error", 502)
    order.status = "pending"
    order.raw = {"redirect_url": sess["redirect_url"], "session_id": sess.get("session_id", "")}
    order.save(update_fields=["status", "raw", "updated_at"])
    E.event(user, "order.created", "gateway", order.merchant_tx_id, amount=order.amount_bdt,
            sku=sku, source=source, plan_now=plans.effective_plan(user))
    return order


def complete(order, now=None, via="return"):
    """Verify with the gateway and, if paid and matching, grant. Returns the
    (refreshed) order. Never raises for a gateway outage (stays pending)."""
    from ..models import PaymentOrder
    now = now or timezone.now()
    if order.status in ("paid", "refunded"):
        return order
    gw = G.get(order.provider)
    if gw is None or not gw.configured():
        return order
    try:
        res = gw.verify(order)
    except G.GatewayError as e:
        E.event(order.user, "order.verify_error", "gateway", order.merchant_tx_id,
                reason=e.reason, via=via)
        return order
    with transaction.atomic():
        o = PaymentOrder.objects.select_for_update().get(pk=order.pk)
        if o.status in ("paid", "refunded"):
            return o
        problems = []
        if res.merchant_tx_id and res.merchant_tx_id != o.merchant_tx_id:
            problems.append("tx_mismatch")
        if res.status == "paid":
            if res.amount != o.amount_bdt.quantize(Decimal("0.01")):
                problems.append("amount_mismatch")
            if (res.currency or "BDT").upper() != o.currency:
                problems.append("currency_mismatch")
            if not res.provider_tx_id:
                problems.append("no_provider_tx")
        if problems:
            o.detail = ("refused: " + ",".join(problems))[:200]
            o.raw = {**o.raw, "verify": res.raw}
            o.save(update_fields=["detail", "raw", "updated_at"])
            E.event(o.user, "order.refused", "gateway", o.merchant_tx_id,
                    problems=",".join(problems), via=via, got_amount=str(res.amount))
            return o
        if res.status != "paid":
            new = {"failed": "failed", "cancelled": "cancelled"}.get(res.status, "pending")
            if o.status != new:
                o.status = new
                o.detail = ("gateway: " + res.status)[:200]
                o.save(update_fields=["status", "detail", "updated_at"])
            return o
        if PaymentOrder.objects.filter(provider_tx_id=res.provider_tx_id).exclude(pk=o.pk).exists():
            o.detail = "refused: provider tx already used"
            o.save(update_fields=["detail", "updated_at"])
            E.event(o.user, "order.refused", "gateway", o.merchant_tx_id,
                    problems="provider_tx_reused", via=via)
            return o
        o.status, o.paid_at, o.provider_tx_id = "paid", now, res.provider_tx_id
        o.detail = ("paid via %s %s" % (via, res.method))[:200]
        o.raw = {**o.raw, "verify": res.raw}
        o.save(update_fields=["status", "paid_at", "provider_tx_id", "detail", "raw",
                              "updated_at"])
        net = catalog.net(o.amount_bdt, o.sku, "gateway")
        E.event(o.user, "order.paid", "gateway", o.merchant_tx_id, amount=o.amount_bdt,
                net=net, sku=o.sku, via=via, provider_tx=res.provider_tx_id)
        if o.kind == "sub":
            E.grant_prepaid(o.user, order=o, now=now)
            E.ledger("subs", net)
        elif o.kind == "seller":   # p1-bizagent seller plan month
            from .. import bizagent_service as BA
            BA.activate_plan_for_user(o.user, o.plan, months=o.months or 1, now=now)
            E.ledger("seller", net)
        else:
            E.grant_pack(o.user, channel="gateway", ref="gw:" + o.merchant_tx_id,
                         sku=o.sku, amount_bdt=o.amount_bdt, now=now)
            E.ledger("packs", net)
    _notify_paid(o)
    return o


def _notify_paid(o):
    try:
        from .. import push
        push.push_to_user(o.user, "reminder", "পেমেন্ট সফল", "Payment received",
                          "আপনার Assisto কেনাকাটা চালু হয়েছে।", "Your Assisto purchase is active.",
                          data={"route": "plans"})
    except Exception:
        pass


def order_for_tx(tx):
    from ..models import PaymentOrder
    return PaymentOrder.objects.filter(merchant_tx_id=str(tx or "")[:32]).select_related(
        "user").first()


def handle_return(params):
    """Browser came back from the gateway. Finds the order and verifies it."""
    gw = G.get()
    if gw is None:
        return None
    o = order_for_tx(gw.tx_from_return(params))
    if o is None:
        return None
    return complete(o, via="return")


def handle_ipn(body, headers):
    """Gateway server notification -> (http_status, body)."""
    from ..models import WebhookReceipt
    gw = G.get()
    if gw is None:
        return 503, {"status": "ERROR", "message": "not configured"}
    try:
        tx, ptx = gw.tx_from_ipn(body, headers)
    except G.GatewayError as e:
        E.event(None, "gateway.ipn_rejected", "gateway", "", reason=e.reason)
        return 400, {"status": "ERROR", "message": "Invalid payload"}
    o = order_for_tx(tx)
    if o is None:
        return 404, {"status": "ERROR", "message": "unknown order"}
    mid = (tx + ":" + ptx)[:128]
    if ptx:
        try:
            with transaction.atomic():
                WebhookReceipt.objects.create(source="gw_ipn", message_id=mid)
        except IntegrityError:
            return 200, {"status": "OK", "message": "duplicate"}
    o = complete(o, via="ipn")
    if ptx and o.status not in ("paid", "refunded"):
        # not final yet (status API down / still pending): forget the receipt
        # so the gateway's retry of this IPN is verified again, not "duplicate"
        WebhookReceipt.objects.filter(source="gw_ipn", message_id=mid).delete()
    return 200, {"status": "OK", "message": "IPN received", "order": o.status}


def refund_order(order, actor=None, reason="", now=None):
    """Owner marks a gateway order refunded (refund made in the EPS merchant
    panel). Reverses the grant and the revenue."""
    from ..models import PaymentOrder
    now = now or timezone.now()
    with transaction.atomic():
        o = PaymentOrder.objects.select_for_update().get(pk=order.pk)
        if o.status != "paid":
            return o, False
        o.status = "refunded"
        o.detail = ("refunded: " + (reason or ""))[:200]
        o.save(update_fields=["status", "detail", "updated_at"])
    net = catalog.net(o.amount_bdt, o.sku, "gateway")
    if o.kind == "sub":
        E.revoke_period("gateway", "gw:" + o.merchant_tx_id, "refund", now)
        E.ledger("subs", -float(net))
    elif o.kind == "seller":   # p1-bizagent: end the refunded seller month now
        from .. import bizagent_service as BA
        BA.revoke_plan_for_user(o.user, now=now)
        E.ledger("seller", -float(net))
    else:
        E.revoke_pack(o.user, channel="gateway", ref="gw:" + o.merchant_tx_id, reason="refund")
        E.ledger("packs", -float(net))
    E.event(o.user, "order.refunded", "gateway", o.merchant_tx_id, amount=-o.amount_bdt,
            net=-net, by=getattr(actor, "pk", None), reason=reason)
    return o, True


# ----------------------------------------------------------------- sweep
def _remind(period, days, now):
    from ..models import PaymentReminder
    from .. import otp, push, sms_gateway
    u = period.user
    try:
        with transaction.atomic():
            r = PaymentReminder.objects.create(user=u, period=period, days_before=days)
    except IntegrityError:
        return False
    lang = push.user_lang(u)
    end = timezone.localtime(period.ends_at).strftime("%d-%m-%Y")
    sku = period.order.sku if period.order_id else period.plan + "_monthly"
    link = site() + "/premium?renew=" + sku + ("&lang=en" if lang == "en" else "")
    tb, te = "প্ল্যানের মেয়াদ শেষ হচ্ছে", "Your plan ends soon"
    bb = "আপনার Assisto %s %s তারিখে শেষ হবে। এক ট্যাপে নবায়ন করুন।" % (period.plan.title(), end)
    be = "Your Assisto %s ends on %s. Renew in one tap." % (period.plan.title(), end)
    chans = []
    if push.push_to_user(u, "reminder", tb, te, bb, be,
                         data={"route": "plans", "renew_sku": sku}):
        chans.append("push")
    try:
        canon = otp.normalize_bd_phone(u.phone or "")
        ad = sms_gateway.adapter() if canon else None
        if ad is not None:
            ok, _ = ad.send(canon, ("Assisto: your %s ends %s. Renew: %s" % (
                period.plan.title(), end, link)) if lang == "en" else
                ("Assisto: %s %s এ শেষ। নবায়ন: %s" % (period.plan.title(), end, link)))
            if ok:
                chans.append("sms")
                from .. import billing
                billing.record_cost("sms", float(billing.cfg()["usd_bdt"]) *
                                    float(billing.cfg()["action_costs"]["sms"]["provider_cost"]))
    except Exception:
        pass
    r.channels = ",".join(chans)
    r.save(update_fields=["channels"])
    E.event(u, "reminder.sent", "gateway", period.ref, days=days, channels=r.channels)
    return True


def sweep(now=None):
    """Hourly: expire/recompute, renew reminders, re-verify stale orders."""
    from ..models import PaymentOrder, PlanPeriod, PaymentAccount, User
    now = now or timezone.now()
    out = {"recomputed": 0, "reminders": 0, "reverified": 0, "expired_orders": 0}
    # 1) everyone whose written plan has ended, or has periods starting/ending now
    ids = set(PaymentAccount.objects.filter(has_written=True, written_until__lte=now)
              .exclude(written_plan__in=("", "free")).values_list("user_id", flat=True))
    ids |= set(PlanPeriod.objects.filter(status="active", starts_at__lte=now,
                                         ends_at__gt=now - timedelta(hours=2))
               .values_list("user_id", flat=True))
    for u in User.objects.filter(pk__in=ids):
        before = (u.plan, u.plan_until)
        if E.recompute(u, now, reason="sweep") != before:
            out["recomputed"] += 1
    # 2) reminders for prepaid gateway periods (the LAST one in a chain)
    days_list = catalog.pay_cfg()["reminder_days"]
    if days_list:
        horizon = now + timedelta(days=max(days_list))
        for p in PlanPeriod.objects.filter(source="gateway", status="active",
                                           ends_at__gt=now, ends_at__lte=horizon) \
                .select_related("user", "order"):
            if PlanPeriod.objects.filter(user=p.user, status="active", plan=p.plan,
                                         starts_at__gte=p.ends_at - E.TOL,
                                         starts_at__lte=p.ends_at + E.TOL).exists():
                continue                      # already renewed (next period queued)
            if PlanPeriod.objects.filter(user=p.user, source="play", status="active",
                                         ends_at__gt=now, auto_renew=True).exists():
                continue
            left = (p.ends_at - now).total_seconds() / 86400.0
            due = [d for d in days_list if left <= d]
            if due and _remind(p, min(due), now):
                out["reminders"] += 1
    # 3) pending orders: re-verify (lost callbacks), then expire
    ttl = timedelta(minutes=catalog.pay_cfg()["pending_ttl_min"])
    for o in PaymentOrder.objects.filter(status__in=("pending", "cancelled", "failed"),
                                         created_at__gte=now - ttl - timedelta(hours=24),
                                         created_at__lte=now - timedelta(minutes=3)) \
            .exclude(raw={}).select_related("user")[:200]:
        o = complete(o, now, via="sweep")
        out["reverified"] += 1
        if o.status != "paid" and o.created_at < now - ttl and o.status == "pending":
            o.status = "expired"
            o.save(update_fields=["status", "updated_at"])
            out["expired_orders"] += 1
    return out


# ----------------------------------------------------------------- owner P&L
def channel_pnl(days=30, now=None):
    """Gross, fee, net, refunds and count per channel for the last N days —
    from PaymentEvent (append-only), so it can be audited row by row."""
    from ..models import PaymentEvent
    now = now or timezone.now()
    since = now - timedelta(days=int(days))
    rows = {"play": {}, "gateway": {}}
    for ch in rows:
        rows[ch] = {"gross": Decimal(0), "net": Decimal(0), "refunds": Decimal(0),
                    "count": 0, "refund_count": 0}
    for ev in PaymentEvent.objects.filter(created_at__gte=since, kind__in=(
            "play.charge", "play.refund", "order.paid", "order.refunded")):
        ch = "play" if ev.kind.startswith("play.") else "gateway"
        r = rows[ch]
        if ev.kind in ("play.charge", "order.paid"):
            r["gross"] += ev.amount_bdt
            r["net"] += ev.net_bdt
            r["count"] += 1
        else:
            r["refunds"] += -ev.amount_bdt
            r["net"] += ev.net_bdt
            r["refund_count"] += 1
    total = {"gross": Decimal(0), "net": Decimal(0), "refunds": Decimal(0), "count": 0}
    for ch, r in rows.items():
        r["fee"] = (r["gross"] - r["refunds"] - r["net"]).quantize(Decimal("0.01"))
        for k in ("gross", "net", "refunds", "count"):
            total[k] += r[k]
    total["fee"] = sum((r["fee"] for r in rows.values()), Decimal(0))
    return {"days": days, "channels": rows, "total": total}
