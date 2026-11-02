"""amarket (3 Nov): Owner Admin -> Market. Two jobs:
1. Seller applications — v1 verification = an existing Business account +
   the OWNER's manual approve here (no documents collected; the document
   rules are an owner decision). Approve / suspend / reject / back to
   pending; suspending withdraws the seller's open offers at once.
2. Market reports — needs, offers and sellers people reported
   (ModerationItem kinds mkt_need / mkt_bid / mkt_seller). Remove hides the
   need / offer (or suspends the seller); Restore makes it visible again.
Every action is audited (OwnerAudit + ModerationAudit)."""
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

KINDS = ("mkt_need", "mkt_bid", "mkt_seller")


def _label(it):
    from core.models import MarketBid, MarketNeed, User
    tid = int(it.target_id) if str(it.target_id).isdigit() else 0
    if it.target_kind == "mkt_need":
        n = MarketNeed.objects.filter(pk=tid).first()
        return ("%s — %s" % (n.title, (n.description or "")[:120])) if n else "—"
    if it.target_kind == "mkt_bid":
        b = MarketBid.objects.filter(pk=tid).select_related("need").first()
        return ("৳%s/unit · %s · %s" % (b.unit_price // 100, b.need.title[:60], b.notes[:100])) if b else "—"
    u = User.objects.filter(pk=tid).first()
    return ("%s (#%s)" % (u.name or "—", u.pk)) if u else "—"


@require_http_methods(["GET"])
@owner_view()
def market(request):
    from core import market as MK
    from core.models import (MarketDeal, MarketNeed, MarketSeller,
                             ModerationItem)
    st = request.GET.get("status") or "pending"
    sellers = MarketSeller.objects.select_related("user", "business")
    sellers = sellers.filter(status=st) if st in MarketSeller.STATUSES else sellers
    rows = list(sellers.order_by("-applied_at")[:200])
    for s in rows:
        s.area_label = MK.area_label(s.area, getattr(request, "owner_lang", "bn"))
        s.cat_labels = ", ".join(MK.category_label(c, getattr(request, "owner_lang", "bn"))
                                 for c in (s.categories or []))
    reports = list(ModerationItem.objects.filter(target_kind__in=KINDS)
                   .exclude(queue_state="resolved")
                   .order_by("-severe", "-report_count", "-opened_at")[:100])
    for r in reports:
        r.label = _label(r)
    stats = {
        "pending": MarketSeller.objects.filter(status="pending").count(),
        "approved": MarketSeller.objects.filter(status="approved").count(),
        "open_needs": MarketNeed.objects.filter(status="open").count(),
        "deals": MarketDeal.objects.count(),
        "delivered": MarketDeal.objects.filter(status="delivered").count(),
    }
    return page(request, "owner/market.html",
                {"rows": rows, "st": st, "reports": reports, "stats": stats,
                 "statuses": MarketSeller.STATUSES},
                nav="market")


@require_http_methods(["POST"])
@owner_view()
def market_seller_act(request, pk):
    from core import market as MK
    from core.models import MarketSeller
    s = MarketSeller.objects.filter(pk=pk).first()
    if s is None:
        raise Http404
    decision = request.POST.get("decision")
    if decision not in MarketSeller.STATUSES:
        raise Http404
    before = {"status": s.status}
    MK.decide_seller(request.owner, pk, decision, request.POST.get("note", ""))
    S.audit(request, request.owner, "market_seller.%s" % decision,
            "market_seller:%s" % pk, before=before, after={"status": decision})
    return done("/owner/market")


@require_http_methods(["POST"])
@owner_view()
def market_report_act(request, pk):
    from core import market as MK
    from core.logic import msg_moderation as mmod
    from core.models import ModerationAudit, ModerationItem
    it = ModerationItem.objects.filter(pk=pk, target_kind__in=KINDS).first()
    if it is None:
        raise Http404
    action = request.POST.get("action")
    if action not in (mmod.A_REMOVE, mmod.A_RESTORE):
        raise Http404
    reason = (request.POST.get("reason") or "").strip()[:300] or "owner review"
    before = {"content_status": it.content_status}
    new_item, audit = mmod.apply_admin_action(
        {"id": it.id, "target_kind": it.target_kind, "target_id": it.target_id,
         "content_status": it.content_status, "legal_retention": it.legal_retention},
        action, request.owner.id, reason)
    it.content_status = new_item["content_status"]
    it.queue_state = new_item["queue_state"]
    it.decision = new_item["decision"]
    it.resolved_at = timezone.now()
    it.save(update_fields=["content_status", "queue_state", "decision", "resolved_at"])
    MK.apply_status(it.target_kind, it.target_id, it.content_status)
    ModerationAudit.objects.create(
        actor=request.owner, action=audit["action"], target_kind=audit["target_kind"],
        target_id=str(audit["target_id"]), reason=audit["reason"],
        extra={"via": "owner_admin_market"})
    S.audit(request, request.owner, "market_report.%s" % action,
            "moderation:%s" % it.pk, before=before,
            after={"content_status": it.content_status})
    return done("/owner/market")
