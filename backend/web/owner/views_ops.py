"""ops-watch: Owner Admin → System health (cron jobs, services, disk, backups,
restore drill, missing cron lines) and Owner Admin → Crash rate (our own
crash / ANR rate per day, app version, phone brand / model, Android version,
top crash signatures). Read-only; owner_view = active superuser + 2FA."""
from datetime import timedelta

from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .base import owner_view, page, to_int


@require_http_methods(["GET"])
@owner_view()
def system_health(request):
    from core import ops_health as H
    from core.models import OpsAlertState
    snap = H.snapshot()
    order = {"failing": 0, "stuck": 1, "late": 2, "not_scheduled": 3, "waiting": 4, "ok": 5}
    jobs = sorted(snap["jobs"], key=lambda j: (order.get(j["status"], 9), j["name"]))
    newest = snap["backups"][0] if snap["backups"] else None
    backup_age_h = None
    if newest:
        backup_age_h = round((snap["now"] - newest["mtime"]).total_seconds() / 3600, 1)
    ctx = {
        "jobs": jobs, "services": snap["services"], "disk": snap["disk"],
        "backups": snap["backups"][:7], "newest_backup": newest,
        "backup_age_h": backup_age_h, "offsite": snap["offsite"],
        "restore": snap["restore"], "missing": snap["missing"],
        "cron_known": snap["cron_known"],
        "bad_jobs": sum(1 for j in jobs if j["status"] in H.BAD_JOB),
        "down": sum(1 for s in snap["services"] if s["status"] == "down"),
        "alerts": OpsAlertState.objects.filter(bad=True).order_by("since"),
    }
    return page(request, "owner/system_health.html", ctx, nav="system")


@require_http_methods(["GET"])
@owner_view()
def crash_rate_page(request):
    from core import crash_rate as CR
    days = max(1, min(30, to_int(request.GET.get("days"), 7)))
    today = timezone.localdate()
    rows = CR.daily(30, today)
    win = CR.summarize(rows[-days:])
    week = CR.window(7)
    for r in rows:
        r["crash_pct"] = CR.pct(r["crash_rate"])
        r["anr_pct"] = CR.pct(r["anr_rate"])
        r["free_pct"] = CR.pct(r["crash_free"])
    from .i18n import strings
    T = strings(getattr(request, "owner_lang", "bn"))
    dims = []
    for field, label in (("version", "cr_by_version"), ("brand", "cr_by_brand"),
                         ("model", "cr_by_model"), ("android", "cr_by_android")):
        b = CR.breakdown(field, days, today)
        for x in b:
            x["crash_pct"] = CR.pct(x["crash_rate"])
        dims.append({"field": field, "title": T[label], "rows": b})
    ctx = {
        "days": days, "day_options": (1, 7, 30),
        "rows": list(reversed(rows[-days:])), "win": win, "week": week,
        "win_crash_pct": CR.pct(win["crash_rate"]), "win_anr_pct": CR.pct(win["anr_rate"]),
        "win_free_pct": CR.pct(win["crash_free"], 3),
        "week_crash_pct": CR.pct(week["crash_rate"]), "week_anr_pct": CR.pct(week["anr_rate"]),
        "crash_bar": round(CR.CRASH_BAR * 100, 2), "anr_bar": round(CR.ANR_BAR * 100, 2),
        "dims": dims, "sigs": CR.top_signatures(days, today),
        "since": today - timedelta(days=days - 1), "today": today,
    }
    return page(request, "owner/crash_rate.html", ctx, nav="vitals")
