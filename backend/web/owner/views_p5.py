"""p5-growth: Owner Admin → Growth funnel. Installs → signups → activated →
retained (D1/D7/D30) → paying, revenue per user, referral conversions and
reward cost. Read-only; every number comes from core.funnel (real rows)."""
from django.views.decorators.http import require_http_methods

from . import charts
from .base import owner_view, page, to_int


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


@require_http_methods(["GET"])
@owner_view()
def funnel(request):
    from core import funnel as FN
    days = max(1, min(180, to_int(request.GET.get("days"), 30)))
    data = FN.dashboard(days)
    T = _T(request)
    s = data["series"]
    labels = [d["date"].strftime("%m-%d") for d in s]
    has = any(d["installs"] or d["signups"] for d in s)
    chart = charts.bars(labels, [
        (T["fn_installs"], "s1", [d["installs"] for d in s]),
        (T["fn_signups"], "s2", [d["signups"] for d in s]),
    ]) if has else ""
    has_act = any(d["active"] for d in s)
    chart_act = charts.bars(labels, [(T["fn_active"], "s1", [d["active"] for d in s])]) \
        if has_act else ""
    return page(request, "owner/funnel.html", {
        "d": data, "h": data["head"], "r": data["referrals"], "ret": data["retention"],
        "days": days, "chart": chart, "chart_act": chart_act,
        "day_choices": (7, 30, 90, 180),
    }, nav="funnel")
