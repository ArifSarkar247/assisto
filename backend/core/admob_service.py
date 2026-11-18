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


def _claim(key):
    """True the FIRST time `key` is seen (DB-unique, so it holds across
    gunicorn workers — the cache is per worker); False for a repeat."""
    from .models import AdEventSeen
    try:
        with transaction.atomic():
            AdEventSeen.objects.create(key=key)
        return True
    except IntegrityError:
        return False


def _seen(key):
    from .models import AdEventSeen
    return AdEventSeen.objects.filter(key=key).exists()


PURGE_ODDS = 0.005   # ~1 in 200 events purges old dedupe rows


def _purge_old(now, odds=None):
    """Dedupe rows only matter for a few minutes; keep 2 days, purge
    opportunistically (~1 in 200 events)."""
    import random
    if random.random() >= (PURGE_ODDS if odds is None else odds):
        return
    from .models import AdEventSeen
    try:
        AdEventSeen.objects.filter(at__lt=now - timedelta(days=2)).delete()
    except Exception:
        pass


def is_test_event(user):
    """ads-guard (owner 17 Nov): this event came from a Google TEST ad —
    real unit ids are off (`admob_real_ids`), or the account only ever gets
    test units (owner / staff / tester / Play reviewer, core.views_ads).
    Test events are counted apart and NEVER shown as revenue. Fails safe:
    an error -> test."""
    try:
        from . import billing, integrations
        from .views_ads import test_ads_account
        if not (billing.cfg().get("ad_rewards") or {}).get("admob_real_ids", False):
            return True
        return test_ads_account(user, integrations.get("admob") or {})
    except Exception:
        return True


def record_event(user, data):
    """-> (http_status, body). body["counted"] says whether a counter moved.

    COUNTING (owner ads check 28 Oct): per ad instance (`ad_event_id`) at
    most ONE impression, ONE click and ONE paid value; a click counts only
    after that instance's impression; old builds without an id get one click
    per placement per minute; and a placement's clicks can never exceed its
    impressions for the day (the update itself is conditional)."""
    ev, why = A.clean_event(data)
    if ev is None:
        return 400, {"ok": False, "reason": why}
    if not _is_free(user):
        return 200, {"ok": False, "reason": "not_free"}
    if not _rate_ok(user):
        return 429, {"ok": False, "reason": "rate_limited"}
    from .models import AdPlacementStat
    now = timezone.now()
    _purge_old(now)
    kind, eid, pl = ev["kind"], ev["event_id"], ev["placement"]
    if kind == "exit":
        # Ad impact: one aggregate count per user/placement/minute, only for
        # an interstitial placement; stored as a row with fmt "exit"
        if ev["format"] != "interstitial":
            return 400, {"ok": False, "reason": "bad_format"}
        if not _claim(A.dedupe_key(user.pk, pl, kind, A.minute_bucket(now))):
            return 200, {"ok": True, "counted": False, "reason": "duplicate"}
    elif eid:
        if kind == "click" and not _seen(A.dedupe_key(user.pk, pl, "impression", eid)):
            return 200, {"ok": True, "counted": False, "reason": "click_without_impression"}
        if not _claim(A.dedupe_key(user.pk, pl, kind, eid)):
            return 200, {"ok": True, "counted": False, "reason": "duplicate"}
    elif kind == "click":
        if not _claim(A.dedupe_key(user.pk, pl, kind, A.minute_bucket(now))):
            return 200, {"ok": True, "counted": False, "reason": "duplicate"}
    today = timezone.localdate()
    cur = ev["currency"] if kind == "paid" else ""
    key = dict(date=today, placement=pl,
               fmt="exit" if kind == "exit" else ev["format"], currency=cur,
               test=is_test_event(user))
    if kind == "click":
        # never more clicks than impressions (no row = no impression yet)
        n = AdPlacementStat.objects.filter(clicks__lt=F("impressions"), **key).update(
            clicks=F("clicks") + 1)
        if not n:
            return 200, {"ok": True, "counted": False, "reason": "clicks_capped"}
        return 200, {"ok": True, "counted": True}
    inc = {"impression": {"impressions": F("impressions") + 1},
           "exit": {"impressions": F("impressions") + 1},
           "paid": {"paid_events": F("paid_events") + 1,
                    "revenue_micros": F("revenue_micros") + ev["value_micros"],
                    "precise_events": F("precise_events")
                    + (1 if ev["precision"] == "precise" else 0)}}[kind]
    for _ in range(2):
        n = AdPlacementStat.objects.filter(**key).update(**inc)
        if n:
            break
        try:
            with transaction.atomic():
                AdPlacementStat.objects.create(**key)
        except IntegrityError:
            pass             # a parallel request created it; update again
    return 200, {"ok": True, "counted": True}


def placement_stats(days=7, test=False):
    """Owner Admin: per-placement totals for the last `days` local days —
    REAL ads only (test=False) unless asked for the test rows."""
    from .models import AdPlacementStat
    days = max(1, min(90, int(days or 7)))
    since = timezone.localdate() - timedelta(days=days - 1)
    rows = (AdPlacementStat.objects.filter(date__gte=since, test=bool(test))
            .values("placement", "fmt", "currency")
            .annotate(impressions=Sum("impressions"), clicks=Sum("clicks"),
                      paid_events=Sum("paid_events"),
                      revenue_micros=Sum("revenue_micros")))
    return A.placement_report([dict(r, format=r["fmt"]) for r in rows])


def stats_source(days=7):
    """ads-guard: where the Owner Admin ad numbers come from, honestly.
    Source = the app's own SDK events (impression / click / onPaidEvent value
    = Google's ESTIMATE per impression); there is NO AdMob Reporting API sync
    (it needs an OAuth client the owner authorises), so no "last sync".
    -> {source, api_connected, last_event_at, real_impressions,
        test_impressions, real_ids_on}"""
    from django.db.models import Max
    from .models import AdEventSeen, AdPlacementStat
    days = max(1, min(90, int(days or 7)))
    since = timezone.localdate() - timedelta(days=days - 1)
    out = {"source": "app_events", "api_connected": False, "last_event_at": None,
           "real_impressions": 0, "test_impressions": 0, "real_ids_on": False}
    try:
        for r in (AdPlacementStat.objects.filter(date__gte=since).exclude(fmt="exit")
                  .values("test").annotate(n=Sum("impressions"))):
            out["test_impressions" if r["test"] else "real_impressions"] = int(r["n"] or 0)
        out["last_event_at"] = AdEventSeen.objects.aggregate(m=Max("at"))["m"]
        from . import billing
        out["real_ids_on"] = bool((billing.cfg().get("ad_rewards") or {})
                                  .get("admob_real_ids", False))
    except Exception:
        pass
    return out


def placement_on(key):
    """adcontrol (owner 10 Nov): is the owner's Ad control switch for the
    registered placement `key` on right now? (server-side gate for rewarded
    tickets issued outside /ads/config — Photo Studio, Language Partner).
    Unknown key -> False; a config read failure -> the registry default."""
    from .logic import ad_control as AC
    if key not in AC.BY_KEY:
        return False
    try:
        from . import billing
        return bool(AC.normalize(billing.cfg().get("ad_control"))["placements"][key]["on"])
    except Exception:
        return AC.BY_KEY[key]["on"]
