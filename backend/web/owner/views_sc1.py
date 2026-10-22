"""sc1: Owner Admin → Reports → App errors. Scrubbed app crash/error reports
(ClientErrorReport) grouped by fingerprint: phone models, Android versions,
ROMs, counts, first/last seen, affected builds; filter by brand / build /
period; a detail page per fingerprint. Read-only. Data: last 30 days at most
(purge_l1_retention)."""
from datetime import timedelta

from django.db.models import Count, Max, Min, Q, Sum
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .base import owner_view, page, to_int


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


def _filtered(request):
    from core.models import ClientErrorReport
    days = max(1, min(30, to_int(request.GET.get("days"), 7)))
    brand = (request.GET.get("brand") or "").strip().lower()[:40]
    build = (request.GET.get("build") or "").strip()[:16]
    kind = request.GET.get("kind") or ""
    qs = ClientErrorReport.objects.filter(last_at__gte=timezone.now() - timedelta(days=days))
    if brand:
        qs = qs.filter(brand=brand)
    if build:
        qs = qs.filter(build=build)
    if kind == "fatal":
        qs = qs.filter(fatal=True)
    elif kind == "nonfatal":
        qs = qs.filter(fatal=False)
    return qs, {"days": days, "brand": brand, "build": build, "kind": kind}


def _distinct(qs, field, limit=6):
    vals = [v for v in qs.values_list(field, flat=True).distinct().order_by(field)[:limit + 1] if v]
    more = len(vals) > limit
    return vals[:limit], more


@require_http_methods(["GET"])
@owner_view()
def app_errors(request):
    from core.models import ClientErrorReport
    qs, f = _filtered(request)
    groups = list(qs.values("fingerprint").annotate(
        total=Sum("count"), phones=Count("user_id", distinct=True),
        first=Min("first_at"), last=Max("last_at"),
        fatal=Count("id", filter=Q(fatal=True))).order_by("-total")[:100])
    for g in groups:
        sub = qs.filter(fingerprint=g["fingerprint"])
        head = sub.order_by("-last_at").first()
        g["type"] = head.error_type if head else ""
        g["message"] = head.message if head else ""
        g["models"], g["more_models"] = _distinct(sub, "model")
        g["roms"], _ = _distinct(sub, "rom")
        g["androids"], _ = _distinct(sub, "android")
        g["builds"], g["more_builds"] = _distinct(sub, "build")
    all_recent = ClientErrorReport.objects.filter(
        last_at__gte=timezone.now() - timedelta(days=30))
    ctx = {
        "f": f, "groups": groups, "day_options": (1, 7, 30),
        "brands": [b for b in all_recent.values_list("brand", flat=True).distinct().order_by("brand") if b],
        "build_list": [b for b in all_recent.values_list("build", flat=True).distinct().order_by("-build")[:30] if b],
        "total": qs.aggregate(n=Sum("count"))["n"] or 0,
        "phones": qs.values("user_id", "model").distinct().count(),
    }
    return page(request, "owner/app_errors.html", ctx, nav="reports")


@require_http_methods(["GET"])
@owner_view()
def app_error_detail(request, fp):
    from core.models import ClientErrorReport
    if not fp.isalnum() or len(fp) > 24:
        raise Http404
    rows = list(ClientErrorReport.objects.filter(fingerprint=fp)
                .select_related("user").order_by("-last_at")[:200])
    if not rows:
        raise Http404
    head = rows[0]
    by_model = (ClientErrorReport.objects.filter(fingerprint=fp)
                .values("brand", "model", "android", "sdk", "rom")
                .annotate(n=Sum("count"), phones=Count("user_id", distinct=True))
                .order_by("-n")[:50])
    ctx = {"fp": fp, "head": head, "rows": rows, "by_model": by_model,
           "total": sum(r.count for r in rows)}
    return page(request, "owner/app_error_detail.html", ctx, nav="reports")
