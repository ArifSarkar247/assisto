"""recovery (owner order Part 8): Owner Admin -> Account recovery. The queue
of support recovery requests (lost phone + no verified email). A reviewer
sees MATCH RESULTS only (typed name vs. the account name, signup month,
how many Circle names matched, old password yes/no, family confirmation) —
never chats, photos, documents or the raw answers. Approve never skips the
48 h hold: the person can finish only after hold_until. Every decision goes
to the owner audit log."""
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 40
FILTERS = ("pending", "approved", "done", "all")


@require_http_methods(["GET"])
@owner_view(perm="act_support")
def recovery(request):
    from core.models import RecoveryRequest
    from core.otp import mask
    st = request.GET.get("status") or "pending"
    if st not in FILTERS:
        st = "pending"
    qs = RecoveryRequest.objects.exclude(user__isnull=True).select_related("user", "family_user")
    if st == "pending":
        qs = qs.filter(state="pending")
    elif st == "approved":
        qs = qs.filter(state="approved")
    elif st == "done":
        qs = qs.exclude(state__in=("pending", "approved"))
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs.order_by("-id")[(pg - 1) * _PAGE: pg * _PAGE])
    now = timezone.now()
    for r in rows:
        r.acct_m = mask(r.account_phone)
        r.contact_m = mask(r.contact_phone)
        r.hold_left_h = max(0, int((r.hold_until - now).total_seconds() // 3600))
        r.p = r.proof or {}
    tiles = [("pending", RecoveryRequest.objects.filter(state="pending").exclude(
                 user__isnull=True).count()),
             ("approved", RecoveryRequest.objects.filter(state="approved").count())]
    return page(request, "owner/recovery.html", {
        "rows": rows, "st": st, "total": total, "page_no": pg,
        "has_next": pg * _PAGE < total, "tiles": tiles, "filters": FILTERS,
    }, nav="recovery")


@require_http_methods(["POST"])
@owner_view(perm="act_support")
def recovery_action(request, pk):
    from core import account_recovery as AR
    from core.models import RecoveryRequest
    r = RecoveryRequest.objects.filter(pk=pk).first()
    if r is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = "/owner/recovery?status=%s" % (request.POST.get("status") or "pending")
    before = {"state": r.state, "family": r.family_state}
    err = AR.admin_decide(r, action, request.owner, request.POST.get("note") or "")
    r.refresh_from_db()
    S.audit(request, request.owner, "recovery." + action[:20], "recovery:%s" % r.pk,
            before=before, after={"state": r.state, "error": err}, ok=not err)
    return done(back, "invalid" if err else "saved")
