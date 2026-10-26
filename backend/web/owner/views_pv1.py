"""play-vitals: Owner Admin → Play Vitals. Google's own crash / ANR numbers
(Play Developer Reporting API, pulled daily by play_vitals_pull): overall
trend for the last 28 days next to Google's bad-behaviour thresholds, worst
phone models / Android versions / app versions, and Google's error issues with
a sample stack. Shows honestly how fresh Google's data is. Our own in-app
crash reports stay on Reports → App errors (linked, not duplicated)."""
from datetime import timedelta

from django.db.models import Max, Sum
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import charts
from .base import done, owner_view, page, to_int

METRIC_CHOICES = ("user_perceived_crash", "crash", "user_perceived_anr", "anr")


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


def _pct(rate):
    return None if rate is None else round(rate * 100, 2)


def _breakdown(metric, kind, latest, min_users, limit=40):
    """Per dimension value over the 28 days up to `latest`: user-weighted
    rate and summed daily users; worst first; values under min_users hidden."""
    from core.models import PlayVitalDaily
    agg = {}
    for r in PlayVitalDaily.objects.filter(metric=metric, dim_kind=kind,
                                           date__gt=latest - timedelta(days=28)):
        a = agg.setdefault(r.dim_value, {"value": r.dim_value, "label": r.label,
                                         "num": 0.0, "users": 0, "days": 0, "rates": []})
        if r.label:
            a["label"] = r.label
        if r.rate is None:
            continue
        a["num"] += r.rate * (r.users or 0)
        a["users"] += r.users or 0
        a["days"] += 1
        a["rates"].append(r.rate)
    rows = []
    for a in agg.values():
        if a["users"] < min_users:
            continue
        rate = (a["num"] / a["users"]) if a["users"] else (
            sum(a["rates"]) / len(a["rates"]) if a["rates"] else None)
        if rate is None:
            continue
        rows.append({"value": a["value"], "label": a["label"] or a["value"],
                     "pct": _pct(rate), "users": a["users"], "days": a["days"]})
    rows.sort(key=lambda x: (-(x["pct"] or 0), -x["users"]))
    return rows[:limit]


@require_http_methods(["GET"])
@owner_view()
def vitals(request):
    from core import play_vitals as PV
    from core.models import ClientErrorReport, PlayErrorIssue, PlayVitalDaily
    T = _T(request)
    metric = request.GET.get("metric") or "user_perceived_crash"
    if metric not in METRIC_CHOICES:
        metric = "user_perceived_crash"
    min_users = max(0, min(100000, to_int(request.GET.get("min_users"), 10) or 0))

    overall = PlayVitalDaily.objects.filter(dim_kind="overall")
    latest = overall.aggregate(d=Max("date"))["d"]
    pulled = PlayVitalDaily.objects.aggregate(t=Max("updated_at"))["t"]
    ctx = {"latest": latest, "pulled": pulled, "metric": metric, "min_users": min_users,
           "metric_choices": [(m, T["pv_m_" + m]) for m in METRIC_CHOICES],
           "metric_label": T["pv_m_" + metric], "chart": "", "tiles": [],
           "by_device": [], "by_api": [], "by_version": []}
    if latest:
        start = latest - timedelta(days=27)
        days = [start + timedelta(days=i) for i in range(28)]
        series = {}
        for r in overall.filter(date__gte=start, metric__in=("crash", "anr")):
            series[(r.metric, r.date)] = _pct(r.rate) or 0
        if series:
            ctx["chart"] = charts.bars(
                [d.strftime("%m-%d") for d in days],
                [(T["pv_m_crash"], "s1", [series.get(("crash", d), 0) for d in days]),
                 (T["pv_m_anr"], "s2", [series.get(("anr", d), 0) for d in days])],
                unit="")
        for m in ("user_perceived_crash", "user_perceived_anr", "crash", "anr"):
            rate = PV.weighted_rate(m)
            limit = PV.THRESHOLDS.get(m)
            ctx["tiles"].append({
                "label": T["pv_m_" + m], "pct": _pct(rate),
                "limit": _pct(limit) if limit else None,
                "bad": bool(limit and rate is not None and rate > limit)})
        ctx["by_device"] = _breakdown(metric, "device", latest, min_users)
        ctx["by_api"] = _breakdown(metric, "api", latest, min_users)
        ctx["by_version"] = _breakdown(metric, "version", latest, min_users)
    ctx["issues"] = list(PlayErrorIssue.objects.order_by("status", "-users", "-reports")[:50])
    ctx["own_7d"] = ClientErrorReport.objects.filter(
        last_at__gte=timezone.now() - timedelta(days=7), fatal=True
    ).aggregate(n=Sum("count"))["n"] or 0
    return page(request, "owner/vitals.html", ctx, nav="vitals")


@require_http_methods(["POST"])
@owner_view()
def issue_known(request, pk):
    from core.models import PlayErrorIssue
    n = PlayErrorIssue.objects.filter(pk=pk).update(
        status="new" if request.POST.get("undo") else "known")
    if not n:
        raise Http404
    return done("/owner/vitals")
