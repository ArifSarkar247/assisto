"""blood (owner 2 Nov): Owner Admin -> Blood donors. Two queues:
  * urgent blood requests (hidden-by-reports first) + their fake reports —
    hide / restore / close / remove / remove + 90-day posting ban;
  * donation-slip photos for the "verified donor" badge — approve / reject.
    The photo FILE is deleted as soon as it is reviewed (never public).
Every action goes to the owner audit log and the panel's event log."""
from django.db.models import Count, Q
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 40
ACTIONS = ("hide", "restore", "close", "remove", "remove_ban")
FILTERS = ("review", "active", "ended", "slips", "all")


@require_http_methods(["GET"])
@owner_view()
def blood(request):
    from core.models import BloodDonor, BloodReport, BloodRequest, BloodVerification
    st = request.GET.get("status") or "review"
    if st not in FILTERS:
        st = "review"
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    rows, slips, total = [], [], 0
    if st == "slips":
        qs = BloodVerification.objects.filter(state="pending").select_related("user")
        total = qs.count()
        slips = list(qs.order_by("id")[(pg - 1) * _PAGE: pg * _PAGE])
        for v in slips:
            v.photo_link = v.photo.url if v.photo else ""
            v.donor = BloodDonor.objects.filter(user=v.user).first()
    else:
        qs = (BloodRequest.objects.select_related("requester")
              .annotate(n_reports=Count("reports", filter=Q(reports__status="open"))))
        if st == "review":
            qs = qs.filter(Q(state="hidden") | Q(reports__status="open")).distinct()
        elif st == "active":
            qs = qs.filter(state="active")
        elif st == "ended":
            qs = qs.exclude(state__in=BloodRequest.LIVE)
        total = qs.count()
        rows = list(qs.order_by("-id")[(pg - 1) * _PAGE: pg * _PAGE])
        reports = {}
        for r in (BloodReport.objects.filter(request__in=rows).select_related("reporter")
                  .order_by("-id")[:400]):
            reports.setdefault(r.request_id, []).append(r)
        for r in rows:
            r.report_rows = reports.get(r.id, [])
            r.n_can = r.recipients.filter(response__in=("can", "donated")).count()
    tiles = [
        ("review", BloodRequest.objects.filter(state="hidden").count()),
        ("active", BloodRequest.objects.filter(state="active").count()),
        ("slips", BloodVerification.objects.filter(state="pending").count()),
        ("donors", BloodDonor.objects.filter(enabled=True).count()),
    ]
    return page(request, "owner/blood.html", {
        "rows": rows, "slips": slips, "st": st, "total": total, "page_no": pg,
        "has_next": pg * _PAGE < total, "tiles": tiles, "filters": FILTERS,
    }, nav="blood")


@require_http_methods(["POST"])
@owner_view()
def blood_action(request, pk):
    from core import blood_panel as BP
    from core.models import BloodRequest
    r = BloodRequest.objects.filter(pk=pk).select_related("requester").first()
    if r is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = "/owner/blood?status=%s" % (request.POST.get("status") or "review")
    if action not in ACTIONS:
        return done(back, "invalid")
    before = {"state": r.state}
    err = BP.admin_action(r, action, request.owner)
    S.audit(request, request.owner, "blood_request." + action, "blood_request:%s" % r.pk,
            before=before, after={"state": r.state, "error": err or ""}, ok=not err)
    return done(back, "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def blood_slip(request, pk):
    from core import blood_panel as BP
    from core.models import BloodVerification
    v = BloodVerification.objects.filter(pk=pk).select_related("user").first()
    if v is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = "/owner/blood?status=slips"
    if action not in ("approve", "reject"):
        return done(back, "invalid")
    err = BP.review_slip(v, action == "approve", request.owner, request.POST.get("note") or "")
    S.audit(request, request.owner, "blood_slip." + action, "blood_slip:%s" % v.pk,
            before={"state": "pending"}, after={"state": v.state, "error": err or ""}, ok=not err)
    return done(back, "invalid" if err else "saved")
