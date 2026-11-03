"""
adminsafe: Owner Admin user statistics — every number is a real count and
each one is also a filter of the Users list (same queryset, so the number
and the list always agree).

Signals (no estimates):
  app use      core.ActiveDay — one row per account per Dhaka day on which the
               app made any signed-in server call (core.growth.touch from
               BlockAwareTokenAuthentication). Recorded since p5-growth
               (migration 0076). User.last_active = the newest such day.
  uninstalled  core.PushDeadMark — Firebase answered UNREGISTERED / invalid for
               the account's LAST push token (core.push._drop_token) and no new
               token arrived since. Recorded from the adminsafe deploy on.
  paid         core.billing.verified_paid_orders — verified, real (non-test)
               Play / EPS subscription with an active paid period.
Counts are cached for CACHE_SEC (60 s).
"""
from datetime import timedelta

from django.core.cache import cache
from django.db.models import Count, Q
from django.utils import timezone

CACHE_SEC = 60
_KEY = "adminsafe:user_stats:v1"

FILTERS = ("all", "active_today", "active_7", "active_30", "inactive_30",
           "uninstalled", "new_today", "new_7", "plan_free", "plan_paid",
           "plan_trial", "suspended", "banned", "restricted", "appeal_open")


def _today():
    return timezone.localdate()


def _active_ids(days):
    from .models import ActiveDay
    since = _today() - timedelta(days=days - 1)
    return ActiveDay.objects.filter(day__gte=since).values("user_id")


def _paid_ids(now=None):
    try:
        from .billing import verified_paid_orders
        return list(verified_paid_orders(now).keys())
    except Exception:
        return []


def _trial_q(now, paid):
    lifetime = Q(is_founder=True, founder_since__isnull=True)
    return (Q(trial_until__gt=now) & ~Q(pk__in=paid) & ~lifetime
            & ~Q(plan_until__gt=now))


def queryset(key, now=None):
    """The User queryset behind one stats number / list filter."""
    from .models import AccountAppeal, PushDeadMark, User, UserRestriction
    now = now or timezone.now()
    qs = User.objects.all()
    today = _today()
    if key == "active_today":
        return qs.filter(pk__in=_active_ids(1))
    if key == "active_7":
        return qs.filter(pk__in=_active_ids(7))
    if key == "active_30":
        return qs.filter(pk__in=_active_ids(30))
    if key == "inactive_30":
        cut = now - timedelta(days=30)
        return qs.filter(Q(last_active__lt=cut) |
                         Q(last_active__isnull=True, date_joined__lt=cut))
    if key == "uninstalled":
        return qs.filter(pk__in=PushDeadMark.objects.values("user_id")).exclude(
            devices__push_token__gt="")
    if key == "new_today":
        return qs.filter(date_joined__date=today)
    if key == "new_7":
        return qs.filter(date_joined__date__gte=today - timedelta(days=6))
    if key in ("plan_free", "plan_paid", "plan_trial"):
        paid = _paid_ids(now)
        if key == "plan_paid":
            return qs.filter(pk__in=paid)
        trial = _trial_q(now, paid)
        if key == "plan_trial":
            return qs.filter(trial)
        return qs.exclude(pk__in=paid).exclude(trial)
    if key == "suspended":
        return qs.filter(account_status="suspended")
    if key == "banned":
        return qs.filter(account_status="banned")
    if key == "restricted":
        rs = UserRestriction.objects.filter(
            Q(lifted_at__isnull=True) & (Q(until__isnull=True) | Q(until__gt=now)))
        return qs.filter(pk__in=rs.values("user_id"))
    if key == "appeal_open":
        return qs.filter(pk__in=AccountAppeal.objects.filter(state="open").values("user_id"))
    return qs


def trend(days=30):
    """[(iso_day, active_accounts, signups)] for the last `days` Dhaka days."""
    from .models import ActiveDay, User
    from django.db.models.functions import TruncDate
    today = _today()
    since = today - timedelta(days=days - 1)
    act = {r["day"]: r["n"] for r in ActiveDay.objects.filter(day__gte=since)
           .values("day").annotate(n=Count("user_id", distinct=True))}
    sig = {r["d"]: r["n"] for r in User.objects.filter(date_joined__date__gte=since)
           .annotate(d=TruncDate("date_joined")).values("d").annotate(n=Count("id"))}
    out, d = [], since
    while d <= today:
        out.append((d.isoformat(), act.get(d, 0), sig.get(d, 0)))
        d += timedelta(days=1)
    return out


def compute(now=None):
    from . import admin_safety
    from .models import User
    now = now or timezone.now()
    try:
        admin_safety.sweep_expired(now)      # ended suspensions are not counted
    except Exception:
        pass
    counts = {"all": User.objects.count()}
    for k in FILTERS[1:]:
        try:
            counts[k] = queryset(k, now).count()
        except Exception:
            counts[k] = None
    return {"counts": counts, "trend": trend(30), "at": now.isoformat()}


def cached(force=False):
    """The stats dict, at most CACHE_SEC old."""
    if not force:
        hit = cache.get(_KEY)
        if hit:
            return hit
    data = compute()
    try:
        cache.set(_KEY, data, CACHE_SEC)
    except Exception:
        pass
    return data


def invalidate():
    try:
        cache.delete(_KEY)
    except Exception:
        pass
