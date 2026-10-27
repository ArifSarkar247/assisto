"""billing-v2 owner-panel pages (owner order 27 Oct; rules K, L, Q, R, U +
the unverified-plans add-on):

  /owner/payments/refunds        Refund requests: user, order id, purchase
                                 time, hours since, plan / pack, price paid,
                                 credits granted / used, days used, the
                                 suggested refund; Approve suggested /
                                 Approve custom / Reject + note
  /owner/payments/flagged        users flagged for Google refunds (+ unblock)
  /owner/payments/reports        latest reconcile / voided poll / credits
                                 verify / Profit Guard reports
  /owner/payments/unverified     "Unverified plans and credits"
Every action is audited (OwnerAudit) like the rest of the panel.
"""
from decimal import Decimal, InvalidOperation

from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int
from .i18n import strings

# short Bangla / English label per payment event (rule U)
EVENT_LABELS = {
    "play.charge": ("Play পেমেন্ট", "Play payment"),
    "play.test_charge": ("Play টেস্ট কেনাকাটা", "Play test purchase"),
    "play.refund": ("Play রিফান্ড", "Play refund"),
    "play.rtdn": ("Google নোটিফিকেশন", "Google notification"),
    "play.ack_sweep": ("Play স্বীকৃতি পুনরায়", "Play acknowledge retry"),
    "play.void_unconfirmed": ("রিফান্ড যাচাই বাকি", "Refund not yet confirmed"),
    "play.revoke_unconfirmed": ("বাতিল যাচাই হয়নি", "Revoke not confirmed"),
    "play.rtdn_other_account": ("অন্য অ্যাকাউন্টের কেনাকাটা", "Another account's purchase"),
    "credits.grant": ("ক্রেডিট যোগ", "Credits added"),
    "credits.revoke": ("ক্রেডিট সরানো", "Credits removed"),
    "entitlement.grant": ("প্ল্যান চালু", "Plan started"),
    "entitlement.update": ("প্ল্যান হালনাগাদ", "Plan updated"),
    "entitlement.change": ("প্ল্যান বদল", "Plan changed"),
    "entitlement.revoke": ("প্ল্যান বাতিল", "Plan revoked"),
    "entitlement.replaced": ("প্ল্যান বদলি (আপগ্রেড/ডাউনগ্রেড)", "Plan replaced (up/downgrade)"),
    "entitlement.owner_grant": ("মালিক/সিস্টেমের দেওয়া প্ল্যান", "Owner / system grant"),
    "order.created": ("EPS অর্ডার তৈরি", "EPS order created"),
    "order.paid": ("EPS পেমেন্ট", "EPS payment"),
    "order.refunded": ("EPS রিফান্ড", "EPS refund"),
    "order.refused": ("EPS যাচাই ব্যর্থ", "EPS verify refused"),
    "refund.requested": ("রিফান্ডের অনুরোধ", "Refund requested"),
    "refund.approved": ("রিফান্ড অনুমোদিত", "Refund approved"),
    "refund.rejected": ("রিফান্ড নাকচ", "Refund rejected"),
    "refund.counted": ("Google রিফান্ড গণনা", "Google refund counted"),
    "refund.unblocked": ("কেনাকাটা আবার চালু", "Purchases unblocked"),
}


def event_rows(events, lang):
    """Payment audit rows: Bangla label, real price + currency, TEST tag,
    credits as '+20 credits' (never ৳)."""
    i = 0 if lang == "bn" else 1
    out = []
    for e in events:
        d = e.detail or {}
        lab = EVENT_LABELS.get(e.kind, (e.kind, e.kind))[i]
        test = bool(d.get("test")) or e.kind == "play.test_charge"
        amount = ""
        if e.kind in ("credits.grant", "credits.revoke"):
            n = int(d.get("credits") or 0)
            sign = "+" if e.kind == "credits.grant" else "-"
            amount = ("%s%d ক্রেডিট" if i == 0 else "%s%d credits") % (sign, abs(n))
        elif e.amount_bdt:
            amount = "%s BDT" % e.amount_bdt
        out.append({"e": e, "label": lab, "amount": amount, "test": test})
    return out


def _T(request):
    return strings(request.owner_lang)


def _dec(v):
    try:
        d = Decimal(str(v).strip())
        return d if d > 0 else None
    except (InvalidOperation, ValueError):
        return None


@require_http_methods(["GET", "POST"])
@owner_view()
def refunds(request):
    from core.models import RefundRequest
    from core.payments import refunds as R
    T = _T(request)
    ctx, status = {}, 200
    if request.method == "POST":
        r = RefundRequest.objects.filter(pk=to_int(request.POST.get("req"))).first()
        if r is None:
            raise Http404
        action = request.POST.get("action", "")
        note = request.POST.get("note", "").strip()[:300]
        try:
            if action == "approve":
                R.approve(r, request.owner, None, note)
            elif action == "approve_custom":
                amt = _dec(request.POST.get("amount"))
                if amt is None:
                    raise R.RefundError("bad_amount")
                R.approve(r, request.owner, amt, note)
            elif action == "reject":
                if not note:
                    raise R.RefundError("note_required")
                R.reject(r, request.owner, note)
            else:
                raise Http404
            r.refresh_from_db()
            S.audit(request, request.owner, "refund." + action, "refund:%s" % r.pk,
                    after={"status": r.status, "amount": str(r.approved_amount), "_reason": note})
            return done("/owner/payments/refunds")
        except R.RefundError as e:
            ctx["error"] = T.get("b2_err_" + e.reason, e.reason)
            status = 400
    rows = [R.review_row(r) for r in RefundRequest.objects.select_related("order", "user")[:100]]
    ctx.update({"rows": rows, "window": R.window_hours()})
    return page(request, "owner/bill2_refunds.html", ctx, status=status, nav="payments")


@require_http_methods(["GET", "POST"])
@owner_view()
def flagged(request):
    from core.models import CreditAccount, User
    from core.payments import refunds as R
    if request.method == "POST":
        u = User.objects.filter(pk=to_int(request.POST.get("user"))).first()
        if u is None:
            raise Http404
        note = request.POST.get("note", "").strip()[:200]
        R.unblock(u, request.owner, note)
        S.audit(request, request.owner, "refund.unblock", "user:%s" % u.pk,
                after={"purchase_blocked": False, "_reason": note})
        return done("/owner/payments/flagged")
    rows = CreditAccount.objects.filter(flagged=True).select_related("user").order_by("-updated_at")[:200]
    return page(request, "owner/bill2_flagged.html", {"rows": rows}, nav="payments")


@require_http_methods(["GET"])
@owner_view()
def reports(request):
    from core.models import BillingReport
    kinds = ("reconcile", "voided_poll", "credits_verify", "profit_guard", "entitlements_audit")
    latest = []
    for k in kinds:
        r = BillingReport.objects.filter(kind=k).first()
        latest.append({"kind": k, "r": r})
    return page(request, "owner/bill2_reports.html", {"latest": latest}, nav="payments")


@require_http_methods(["GET"])
@owner_view()
def unverified(request):
    """Read-only scan (never fixes from the page; --fix is a command)."""
    from core.payments import reconcile as RC
    out = RC.entitlements_audit(fix=False, dry_run=True)
    return page(request, "owner/bill2_unverified.html", {"out": out}, nav="payments")


def user_billing(u):
    """Extra context for the owner user page: full ledger, buckets, the
    invariant, purchases, grants and refund flags."""
    from core import credits as CR
    from core.models import (CreditAccount, CreditLedger, EntitlementGrant, PaidOrder)
    return {
        "b2_ledger": CreditLedger.objects.filter(user=u).order_by("-created_at", "-id")[:500],
        "b2_buckets": CR.buckets(u),
        "b2_verify": CR.verify(u),
        "b2_orders": PaidOrder.objects.filter(user=u)[:50],
        "b2_grants": EntitlementGrant.objects.filter(user=u)[:20],
        "b2_account": CreditAccount.objects.filter(user=u).first(),
    }
