"""
admob_service.py — STATEFUL side of the AdMob tuning log (owner 25 Oct).

POST /ads/event with {placement, format, kind: impression|click|paid,
[value_micros, currency, precision]} lands here: validated by the pure
core.logic.ads.clean_event, rate limited per user, and added to ONE daily
counter row per (placement, format, currency) — no user or device id is
stored. Owner Admin -> Ads shows placement x impressions x clicks x revenue.

Free users only: a Premium/Business account never sees an ad, so an event
from one is refused (and never counted).
"""
from datetime import timedelta

from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.db.models import F, Sum
from django.utils import timezone

from .logic import ads as A

# per user per hour; a phone that really shows ads sends far fewer
RATE_PER_HOUR = 240


def _rate_ok(user):
    key = "admob_ev:%s:%s" % (user.pk, timezone.now().strftime("%Y%m%d%H"))
    try:
        if cache.add(key, 1, 3700):
            return True
        n = cache.incr(key)
    except Exception:
        return True          # cache down: the daily row cap below still holds
    return n <= RATE_PER_HOUR


def _is_free(user):
    from . import plans
    try:
        return plans.effective_plan(user) == "free"
    except Exception:
        return True


def record_event(user, data):
    """-> (http_status, body)."""
    ev, why = A.clean_event(data)
    if ev is None:
        return 400, {"ok": False, "reason": why}
    if not _is_free(user):
        return 200, {"ok": False, "reason": "not_free"}
    if not _rate_ok(user):
        return 429, {"ok": False, "reason": "rate_limited"}
    from .models import AdPlacementStat
    today = timezone.localdate()
    cur = ev["currency"] if ev["kind"] == "paid" else ""
    inc = {"impression": {"impressions": F("impressions") + 1},
           "click": {"clicks": F("clicks") + 1},
           "paid": {"paid_events": F("paid_events") + 1,
                    "revenue_micros": F("revenue_micros") + ev["value_micros"],
                    "precise_events": F("precise_events")
                    + (1 if ev["precision"] == "precise" else 0)}}[ev["kind"]]
    key = dict(date=today, placement=ev["placement"], fmt=ev["format"], currency=cur)
    for _ in range(2):
        n = AdPlacementStat.objects.filter(**key).update(**inc)
        if n:
            break
        try:
            with transaction.atomic():
                AdPlacementStat.objects.create(**key)
        except IntegrityError:
            pass             # a parallel request created it; update again
    return 200, {"ok": True}


def placement_stats(days=7):
    """Owner Admin: per-placement totals for the last `days` local days."""
    from .models import AdPlacementStat
    days = max(1, min(90, int(days or 7)))
    since = timezone.localdate() - timedelta(days=days - 1)
    rows = (AdPlacementStat.objects.filter(date__gte=since)
            .values("placement", "fmt", "currency")
            .annotate(impressions=Sum("impressions"), clicks=Sum("clicks"),
                      paid_events=Sum("paid_events"),
                      revenue_micros=Sum("revenue_micros")))
    return A.placement_report([dict(r, format=r["fmt"]) for r in rows])
