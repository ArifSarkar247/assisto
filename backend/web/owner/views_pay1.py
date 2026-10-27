"""pay1 owner-panel section: Payments.

  * per-channel switches (Play on/off, gateway on/off, gateway inside the
    Play build on/off = the compliance kill-switch, website checkout on/off)
    — stored in PricingConfig.payments, read by the app at runtime via
    GET /api/v1/payments/config (no new build), the same for every user
  * fees (Play subs / packs, gateway MDR) and renew-reminder days
  * per-channel prices (empty = base price from Pricing & plans)
  * net revenue per channel (after fees, minus refunds)
  * recent gateway orders + "mark refunded" (reverses the grant + revenue)
Every change goes through pricing_apply (PricingConfig audit) AND OwnerAudit.
"""
from decimal import Decimal

from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page, to_int
from .i18n import strings

SWITCHES = ("play_enabled", "gateway_enabled", "gateway_on_play", "web_enabled")
FEES = ("play_fee_subs", "play_fee_packs", "gateway_fee")


def _f(v):
    try:
        f = float(str(v).strip())
    except (TypeError, ValueError):
        return None
    return f if 0 <= f <= 0.5 else None


@require_http_methods(["GET", "POST"])
@owner_view()
def payments(request):
    from core.payments import catalog, gateway as G, play, service
    from core.views_build61 import pricing_apply
    from core import billing
    from core.models import PaymentEvent, PaymentOrder
    T = strings(request.owner_lang)
    cur = billing.cfg()["payments"]
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        if action == "save":
            new = dict(cur)
            errors = []
            for k in SWITCHES:
                new[k] = request.POST.get(k) == "on"
            for k in FEES:
                v = _f(request.POST.get(k, cur[k]))
                if v is None:
                    errors.append(T["pay_err_fee"])
                else:
                    new[k] = v
            days = [d.strip() for d in request.POST.get("reminder_days", "").split(",") if d.strip()]
            try:
                new["reminder_days"] = [int(d) for d in days]
            except ValueError:
                errors.append(T["pay_err_price"])
            prices = {"play": {}, "gateway": {}}
            for sku in catalog.all_skus():
                for ch in ("play", "gateway"):
                    raw = request.POST.get("price_%s_%s" % (ch, sku), "").strip()
                    if not raw:
                        continue
                    n = to_int(raw)
                    if n is None or n <= 0:
                        errors.append(T["pay_err_price"])
                    else:
                        prices[ch][sku] = n
            new["channel_prices"] = prices
            if errors:
                ctx["error"] = errors[0]
                status = 400
            else:
                ok, payload = pricing_apply(request.owner.id, {"config": {"payments": new},
                                                               "reason": reason or "payments"})
                if ok:
                    b, a = diff(cur, payload["config"]["payments"])
                    S.audit(request, request.owner, "payments.update", "payments",
                            before=b, after={**a, "_reason": reason})
                    return done("/owner/payments")
                ctx["error"] = ", ".join(payload.get("problems") or ["invalid"])
                status = 400
        elif action == "refund":
            o = PaymentOrder.objects.filter(pk=to_int(request.POST.get("order"))).first()
            if o is None:
                raise Http404
            if not reason:
                ctx["error"] = T["err_reason"]
                status = 400
            else:
                before = {"status": o.status}
                o2, changed = service.refund_order(o, actor=request.owner, reason=reason)
                S.audit(request, request.owner, "payments.refund", "order:%s" % o.pk,
                        before=before, after={"status": o2.status, "_reason": reason}, ok=changed)
                return done("/owner/payments", "refunded" if changed else "not_refundable")
        else:
            raise Http404
    days = 30
    pnl = service.channel_pnl(days)
    cfg = billing.cfg()
    rows = []
    for sku in catalog.all_skus(cfg):
        rows.append({"sku": sku, "base": catalog.base_price(sku, cfg),
                     "play": cfg["payments"]["channel_prices"]["play"].get(sku, ""),
                     "gateway": cfg["payments"]["channel_prices"]["gateway"].get(sku, "")})
    gw = G.get()
    ctx.update({
        "p": cfg["payments"], "rows": rows, "pnl": pnl, "days": days,
        "chan_rows": [(T["pay_ch_play"], pnl["channels"]["play"]),
                      (T["pay_ch_gateway"], pnl["channels"]["gateway"])],
        "gw_ready": gw is not None, "play_ready": play.configured(),
        "orders": PaymentOrder.objects.select_related("user")[:50],
        "events": PaymentEvent.objects.select_related("user").exclude(
            kind__in=("entitlement.update", "play.rtdn"))[:60],
        "event_rows": _event_rows(PaymentEvent.objects.select_related("user").exclude(
            kind__in=("entitlement.update", "play.rtdn"))[:60], request.owner_lang),
        "paid_orders": _paid_orders(),
        "reminder_days": ", ".join(str(d) for d in cfg["payments"]["reminder_days"]),
        "urls": service.urls(),
        "rtdn_url": service.api_base() + "/api/v1/payments/play/rtdn",
        "zero": Decimal(0),
    })
    msg = request.GET.get("m", "")
    if msg in ("refunded", "not_refundable"):
        ctx["flash"] = T["pay_refunded"] if msg == "refunded" else T["pay_not_refundable"]
    return page(request, "owner/payments.html", ctx, status=status, nav="payments")


def _event_rows(qs, lang):
    from .views_bill2 import event_rows
    return event_rows(qs, lang)


def _paid_orders():
    from core.models import PaidOrder
    return PaidOrder.objects.select_related("user")[:50]
