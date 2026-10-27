"""ops-watch: crash and ANR rate from OUR OWN data (Play Vitals has too few
users to show anything yet — owner_actions/QUALITY_BARS_BN.md rows 5–6).

Definitions (same shape as Google's "user-perceived" daily rates):

* daily active users (DAU) of a day = accounts with an ActiveDay row that day
  (core.growth.touch — any authenticated API use) UNION accounts that sent an
  app report that day (so a rate can never exceed 100%);
* crashed users of a day = distinct accounts with >= 1 FATAL ClientErrorReport
  that is not an ANR (source app / startup / exit);
* ANR users of a day = distinct accounts with >= 1 report of source "anr"
  (Android ApplicationExitInfo REASON_ANR, read lazily on the next start);
* a window's rate = sum(crashed users per day) / sum(DAU per day) — i.e. per
  user-day, so a big day weighs more than a quiet one;
* crash-free users = 1 - crash rate.

Honesty: below MIN_USER_DAYS user-days in the window the numbers are shown
but marked "too few users" and NEVER alert. ClientErrorReport keeps 30 days
(purge_l1_retention), so 30 days is the longest window.
"""
from datetime import timedelta

from django.conf import settings
from django.db.models import Count, Q, Sum
from django.utils import timezone

CRASH_BAR = 0.003     # owner bar: crash rate under 0.3 %
ANR_BAR = 0.002       # owner bar: ANR rate under 0.2 %


def min_user_days():
    return int(getattr(settings, "OPS_CRASH_MIN_USER_DAYS", 500))


def _crash_q():
    return Q(fatal=True) & ~Q(source="anr")


def _days(end, n):
    return [end - timedelta(days=i) for i in range(n - 1, -1, -1)]


def daily(days=30, end=None):
    """[{day, dau, crash_users, anr_users, crash_rate, anr_rate, crash_free}]
    oldest first, zero-filled. `end` = last day included (default today)."""
    from .models import ActiveDay, ClientErrorReport
    end = end or timezone.localdate()
    start = end - timedelta(days=days - 1)
    active = {}
    for d, uid in ActiveDay.objects.filter(day__gte=start, day__lte=end).values_list("day", "user_id"):
        active.setdefault(d, set()).add(uid)
    crash, anr, reporters = {}, {}, {}
    rows = (ClientErrorReport.objects.filter(day__gte=start, day__lte=end, user_id__isnull=False)
            .values_list("day", "user_id", "fatal", "source"))
    for d, uid, fatal, source in rows:
        reporters.setdefault(d, set()).add(uid)
        if source == "anr":
            anr.setdefault(d, set()).add(uid)
        elif fatal:
            crash.setdefault(d, set()).add(uid)
    out = []
    for d in _days(end, days):
        dau = len(active.get(d, set()) | reporters.get(d, set()))
        c, a = len(crash.get(d, ())), len(anr.get(d, ()))
        out.append({"day": d, "dau": dau, "crash_users": c, "anr_users": a,
                    "crash_rate": (c / dau) if dau else None,
                    "anr_rate": (a / dau) if dau else None,
                    "crash_free": (1 - c / dau) if dau else None})
    return out


def summarize(rows):
    """Window totals over daily() rows."""
    ud = sum(r["dau"] for r in rows)
    cu = sum(r["crash_users"] for r in rows)
    au = sum(r["anr_users"] for r in rows)
    active_days = [r for r in rows if r["dau"]]
    return {
        "user_days": ud, "crash_user_days": cu, "anr_user_days": au,
        "crash_rate": (cu / ud) if ud else None,
        "anr_rate": (au / ud) if ud else None,
        "crash_free": (1 - cu / ud) if ud else None,
        "enough": ud >= min_user_days(), "min_user_days": min_user_days(),
        "first_day": active_days[0]["day"] if active_days else None,
        "last_day": active_days[-1]["day"] if active_days else None,
        "days_with_users": len(active_days),
        "crash_over": bool(ud >= min_user_days() and cu / ud > CRASH_BAR) if ud else False,
        "anr_over": bool(ud >= min_user_days() and au / ud > ANR_BAR) if ud else False,
    }


def window(days=7, end=None):
    """Summary of the last `days` COMPLETE days (default: up to yesterday)."""
    end = end or (timezone.localdate() - timedelta(days=1))
    return summarize(daily(days, end))


def breakdown(field, days=7, end=None, limit=25):
    """Crashed / ANR users per value of `field` (version, build, brand, model,
    android) over the window. For "version" a DAU denominator is estimated from
    User.app_version of that window's active users (their CURRENT version —
    an approximation, labelled so on the page); other fields have no
    denominator (phones do not send brand/model on every request)."""
    from .models import ActiveDay, ClientErrorReport
    end = end or timezone.localdate()
    start = end - timedelta(days=days - 1)
    qs = ClientErrorReport.objects.filter(day__gte=start, day__lte=end)
    rows = list(qs.values(field).annotate(
        crash_users=Count("user_id", filter=_crash_q(), distinct=True),
        anr_users=Count("user_id", filter=Q(source="anr"), distinct=True),
        events=Sum("count"),
        nonfatal=Count("id", filter=Q(fatal=False) & ~Q(source="anr")))
        .order_by("-crash_users", "-anr_users", "-events")[:limit])
    denom = {}
    if field == "version":
        for v, n in (ActiveDay.objects.filter(day__gte=start, day__lte=end)
                     .values("user__app_version")
                     .annotate(n=Count("user_id", distinct=True))
                     .values_list("user__app_version", "n")):
            denom[v or ""] = n
    out = []
    for r in rows:
        v = r[field] or ""
        users = denom.get(v)
        out.append({"value": v or "—", "crash_users": r["crash_users"],
                    "anr_users": r["anr_users"], "events": r["events"] or 0,
                    "nonfatal": r["nonfatal"], "users": users,
                    "crash_rate": (r["crash_users"] / users) if users else None})
    return out


def top_signatures(days=7, end=None, limit=15):
    from .models import ClientErrorReport
    end = end or timezone.localdate()
    start = end - timedelta(days=days - 1)
    qs = ClientErrorReport.objects.filter(day__gte=start, day__lte=end).filter(
        Q(fatal=True) | Q(source="anr"))
    groups = list(qs.values("fingerprint").annotate(
        users=Count("user_id", distinct=True), events=Sum("count"))
        .order_by("-users", "-events")[:limit])
    for g in groups:
        head = qs.filter(fingerprint=g["fingerprint"]).order_by("-last_at").first()
        g["type"] = head.error_type if head else ""
        g["message"] = head.message if head else ""
        g["source"] = head.source if head else ""
    return groups


def pct(x, nd=2):
    return None if x is None else round(x * 100, nd)


def alert_checks(end=None):
    """ops_watch checks for the owner bars over the last 7 complete days:
    [(key, bad, detail, need)]. Too few users -> never bad."""
    s = window(7, end)
    if not s["enough"]:
        note = "too few users (%d user-days < %d)" % (s["user_days"], s["min_user_days"])
        return [("crash_rate", False, "crash rate: " + note, 1),
                ("anr_rate", False, "ANR rate: " + note, 1)]
    return [
        ("crash_rate", s["crash_over"],
         "crash rate %.2f%% over the last 7 days (bar 0.3%%; %d of %d user-days)"
         % (pct(s["crash_rate"]), s["crash_user_days"], s["user_days"]), 1),
        ("anr_rate", s["anr_over"],
         "ANR rate %.2f%% over the last 7 days (bar 0.2%%; %d of %d user-days)"
         % (pct(s["anr_rate"]), s["anr_user_days"], s["user_days"]), 1),
    ]
