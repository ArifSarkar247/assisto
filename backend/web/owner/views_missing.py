"""missing (owner 2 Nov): Owner Admin -> Missing alerts. The queue of
missing-person alerts (hidden-by-reports first) and their fake-post reports.
Actions: hide, restore, close, remove (fake), remove + 90-day posting ban.
Every action goes to the owner audit log and the alert's own event log.
The photo is shown only while the alert is live (it is deleted on any end)."""
from django.db.models import Count, Q
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 40
ACTIONS = ("hide", "restore", "close", "remove", "remove_ban")
FILTERS = ("review", "active", "pending", "ended", "all")


@require_http_methods(["GET"])
@owner_view()
def missing(request):
    from core.models import MissingAlert, MissingReport
    st = request.GET.get("status") or "review"
    if st not in FILTERS:
        st = "review"
    qs = (MissingAlert.objects.select_related("poster")
          .annotate(n_reports=Count("reports", filter=Q(reports__status="open")),
                    n_tips=Count("tips", distinct=True)))
    if st == "review":
        qs = qs.filter(Q(state="hidden") | Q(reports__status="open")).distinct()
    elif st == "active":
        qs = qs.filter(state="active")
    elif st == "pending":
        qs = qs.filter(state="pending")
    elif st == "ended":
        qs = qs.exclude(state__in=MissingAlert.LIVE)
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs.order_by("-id")[(pg - 1) * _PAGE: pg * _PAGE])
    reports = {}
    for r in (MissingReport.objects.filter(alert__in=rows).select_related("reporter")
              .order_by("-id")[:400]):
        reports.setdefault(r.alert_id, []).append(r)
    for a in rows:
        a.report_rows = reports.get(a.id, [])
        a.photo_link = a.photo.url if (a.photo and a.state in MissingAlert.LIVE) else ""
    tiles = [
        ("review", MissingAlert.objects.filter(state="hidden").count()),
        ("active", MissingAlert.objects.filter(state="active").count()),
        ("pending", MissingAlert.objects.filter(state="pending").count()),
        ("reports", MissingReport.objects.filter(status="open").count()),
    ]
    return page(request, "owner/missing.html", {
        "rows": rows, "st": st, "total": total, "page_no": pg,
        "has_next": pg * _PAGE < total, "tiles": tiles, "filters": FILTERS,
    }, nav="missing")


@require_http_methods(["POST"])
@owner_view()
def missing_action(request, pk):
    from core import missing_alert as MS
    from core.models import MissingAlert
    a = MissingAlert.objects.filter(pk=pk).select_related("poster").first()
    if a is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = "/owner/missing?status=%s" % (request.POST.get("status") or "review")
    if action not in ACTIONS:
        return done(back, "invalid")
    before = {"state": a.state}
    err = MS.admin_action(a, action, request.owner)
    S.audit(request, request.owner, "missing_alert." + action, "missing_alert:%s" % a.pk,
            before=before, after={"state": a.state, "error": err or ""}, ok=not err)
    return done(back, "invalid" if err else "saved")
