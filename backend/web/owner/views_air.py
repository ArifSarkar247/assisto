"""ai-report: Owner Admin -> AI reports. Answers users flagged from inside the
app (Google Play AI-Generated Content policy): reason, optional note and a
text-only snapshot of the AI answer. The owner reviews each one and marks it
resolved (or re-opens it). Every resolve is written to the audit log."""
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 50


@require_http_methods(["GET"])
@owner_view()
def ai_reports(request):
    from core.models import AiAnswerReport
    from django.db.models import Count
    st = request.GET.get("status") or "open"
    if st not in AiAnswerReport.STATUSES + ("all",):
        st = "open"
    reason = request.GET.get("reason") or ""
    qs = AiAnswerReport.objects.select_related("user")
    if st != "all":
        qs = qs.filter(status=st)
    if reason in AiAnswerReport.REASONS:
        qs = qs.filter(reason=reason)
    else:
        reason = ""
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs[(pg - 1) * _PAGE: pg * _PAGE])
    counts = {r["status"]: r["n"] for r in
              AiAnswerReport.objects.values("status").annotate(n=Count("id"))}
    return page(request, "owner/ai_reports.html", {
        "rows": rows, "st": st, "reason": reason, "total": total, "page_no": pg,
        "has_next": pg * _PAGE < total, "reasons": AiAnswerReport.REASONS,
        "counts": [(s, counts.get(s, 0)) for s in AiAnswerReport.STATUSES],
    }, nav="ai_reports")


@require_http_methods(["POST"])
@owner_view()
def ai_report_resolve(request, pk):
    from core.models import AiAnswerReport
    r = AiAnswerReport.objects.filter(pk=pk).first()
    if r is None:
        raise Http404
    before = {"status": r.status}
    if request.POST.get("undo"):
        r.status, r.resolved_at, r.resolved_by = "open", None, None
    else:
        r.status, r.resolved_at, r.resolved_by = "resolved", timezone.now(), request.owner
    r.save(update_fields=["status", "resolved_at", "resolved_by"])
    S.audit(request, request.owner, "ai_report.resolve", "ai_report:%s" % r.pk,
            before=before, after={"status": r.status})
    back = request.POST.get("next") or "/owner/ai-reports"
    if not back.startswith("/owner/ai-reports"):
        back = "/owner/ai-reports"
    return done(back)
