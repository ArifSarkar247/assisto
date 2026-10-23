"""p1-bizagent owner-panel section: Sellers (Business AI Agent).

  * seller list — business, plan, replies used / quota, AI replies (30 days),
    worst-case AI cost, revenue (seller-plan payments + credits spent on
    replies), margin
  * per-channel status for every connected Page / Instagram / WhatsApp number,
    with a per-row disable/enable
  * global kill switches per channel type + an all-AI stop
  * seller plans (price, monthly AI replies), trial, WhatsApp per-message cost
    — edited through pricing_apply (margin rule enforced, PricingConfig audit)
    and OwnerAudit. Warning when the WhatsApp cost is still 0.
"""
from datetime import timedelta
from decimal import Decimal

from django.db.models import Sum
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page, to_int, to_num
from .i18n import strings

KINDS = ("messenger", "instagram", "whatsapp_cloud")
WA_CATS = ("marketing", "utility", "authentication", "service")


def _rows(cfg, days=30):
    from core import bizagent_service as BS
    from core.logic import bizagent as BZ
    from core.models import CreditLedger, Message, PaymentOrder, SellerAgent
    since = timezone.now() - timedelta(days=days)
    per = BZ.reply_cost_bdt(cfg)
    credit_bdt = float(cfg.get("credit_bdt") or 1.0)
    gw_fee = float(cfg["payments"].get("gateway_fee", 0.02))
    out = []
    for a in SellerAgent.objects.select_related("business", "business__user").order_by("-updated_at")[:300]:
        u = a.business.user
        ai = Message.objects.filter(thread__business=a.business, is_ai=True, direction="out",
                                    status__in=("sent", "delivered", "read"),
                                    created_at__gte=since).count()
        paid = PaymentOrder.objects.filter(user=u, kind="seller", status="paid",
                                           paid_at__gte=since).aggregate(s=Sum("amount_bdt"))["s"] or 0
        spent = -(CreditLedger.objects.filter(user=u, reason="consume", note="bizagent.reply",
                                              created_at__gte=since)
                  .aggregate(s=Sum("delta"))["s"] or 0)
        revenue = float(paid) * (1 - gw_fee) + spent * credit_bdt
        cost = ai * per
        st = BS.plan_status(a)
        out.append({"id": a.business_id, "shop": a.business.shop_name or "—",
                    "user_id": u.id, "user_name": u.name or "—", "plan": st["plan"],
                    "period_end": a.period_end, "used": st["used"], "quota": st["quota"],
                    "credits": st["credits"], "ai_enabled": a.ai_enabled, "ai30": ai,
                    "cost": round(cost, 2), "revenue": round(revenue, 2),
                    "margin": (round(100 * (revenue - cost) / revenue, 1) if revenue > 0 else None),
                    "channels": list(a.business.seller_channels.order_by("kind", "id"))})
    return out


@require_http_methods(["GET", "POST"])
@owner_view()
def sellers(request):
    from core import billing
    from core.logic import bizagent as BZ
    from core.models import SellerChannel
    from core.views_build61 import pricing_apply
    T = strings(request.owner_lang)
    cfg = billing.cfg()
    sa = cfg["seller_agent"]
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        if action == "channel":
            ch = SellerChannel.objects.filter(pk=to_int(request.POST.get("channel"))).first()
            if ch is None:
                raise Http404
            before = {"enabled": ch.enabled}
            ch.enabled = request.POST.get("enabled") == "on"
            ch.save(update_fields=["enabled"])
            S.audit(request, request.owner, "bizagent.channel", "channel:%s" % ch.pk,
                    before=before, after={"enabled": ch.enabled, "_reason": reason})
            return done("/owner/sellers")
        if action not in ("kill", "config"):
            raise Http404
        new = {}
        bad = []
        if action == "kill":
            new["kill"] = {k: request.POST.get("kill_" + k) == "on" for k in KINDS}
            new["ai_kill"] = request.POST.get("ai_kill") == "on"
        else:
            plans = {}
            for pid in sa["plans"]:
                pr, rp = to_num(request.POST.get("price_" + pid)), to_num(request.POST.get("replies_" + pid))
                if pr is None or rp is None or pr < 0 or rp < 0:
                    bad.append(pid)
                else:
                    plans[pid] = {"price": int(pr), "replies": int(rp)}
            new["plans"] = plans
            for k in ("trial_days", "trial_replies", "low_stock_default"):
                v = to_num(request.POST.get(k))
                if v is None or v < 0:
                    bad.append(k)
                else:
                    new[k] = int(v)
            wa = {}
            for c in WA_CATS:
                v = to_num(request.POST.get("wa_" + c))
                if v is None or v < 0:
                    bad.append("wa_" + c)
                else:
                    wa[c] = float(v)
            new["wa_cost_bdt"] = wa
            new["public_comment_reply"] = request.POST.get("public_comment_reply") == "on"
        if bad:
            ctx["problems"] = [T["p_invalid_number"]]
            status = 400
        else:
            ok, payload = pricing_apply(request.owner.id, {"config": {"seller_agent": new},
                                                           "reason": reason or "seller_agent"})
            if ok:
                b, a = diff(sa, payload["config"]["seller_agent"])
                S.audit(request, request.owner, "bizagent.config", "seller_agent",
                        before=b, after={**a, "_reason": reason})
                return done("/owner/sellers")
            ctx["problems"] = [T.get("p_" + p, p) for p in payload.get("problems") or []]
            status = 400
        cfg = billing.cfg()
        sa = cfg["seller_agent"]
    warn = []
    for w in BZ.warnings(cfg):
        if w["code"] == "wa_cost_unset":
            warn.append(T["sl_w_wa_cost"])
        elif w["code"] == "seller_plan_play_margin":
            warn.append(T["sl_w_play"] % {"plan": w["plan"], "pct": w["margin_play_pct"]})
    ctx.update({
        "sa": sa, "rows": _rows(cfg), "margin_rows": BZ.plan_margin_rows(cfg),
        "warn": warn, "kinds": KINDS, "wa_cats": WA_CATS,
        "kill_rows": [(k, sa["kill"].get(k)) for k in KINDS],
        "wa_rows": [(c, sa["wa_cost_bdt"].get(c)) for c in WA_CATS],
        "per_reply": round(BZ.reply_cost_bdt(cfg), 2),
        "webhook_meta": "https://api.lifeassisto.com/api/v1/bizagent/webhook/meta",
        "webhook_wa": "https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp",
    })
    return page(request, "owner/sellers.html", ctx, status=status, nav="sellers")
