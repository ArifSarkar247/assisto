"""aimoney (owner final order 10 Nov 03:45, part G): the free-AI money rules
at runtime. Numbers and formulas: core/logic/ad_money.py (pure).

* recompute(): ONCE a day inside minute_jobs (`ad_money_tick`) — the real
  cost of one ad-funded Normal answer (our AIUsage log, last 7 days) and the
  real income of one rewarded ad (AdMob paid events, AdPlacementStat; ৳0.40
  until real data exists) -> N ads per answer, saved as one AdMoneyDay row.
* ads_per_answer(): what the app shows ("Watch N ads for 1 answer") and
  what one verified rewarded ad credits (ai_levels_service.ad_paisa).
* ad_level(): an answer paid with rewarded-ad credits runs at the Normal
  level with the shorter max output (prompt caching stays on).
* money_table(): Owner Admin -> Money (daily): free users' profit / loss,
  AI cost per answer by level, ad income per ad type, credits sold.
"""
import logging
from datetime import datetime, time as dtime, timedelta

from django.db.models import Count, Q, Sum
from django.utils import timezone

from .logic import ad_money as AM

log = logging.getLogger(__name__)

AD_TAG = "adfund"        # appended to AIUsage.attempts of an ad-funded answer
STAMP = "ad_money_tick"


def _levels(c=None):
    from . import ai_levels_service as ALS
    return ALS.cfg(c)


def _rate(c):
    from . import ai_levels_service as ALS
    return ALS._economics(c)[1]


def worst_bdt(c=None):
    """৳ of the longest answer rewarded ads can buy (current config)."""
    from .logic import ai_levels as AL
    lv, c = _levels(c)
    from . import ai_router as R
    prices = R.cfg()["prices"]
    return AM.worst_answer_bdt(lv["levels"], lambda m: AL.price_of(m, prices), _rate(c),
                               int(lv.get("ad_out_cap") or AM.AD_OUT_CAP))


def real_cost(now=None, c=None):
    """(৳ per ad-funded answer incl. its share of free Continues, samples,
    source). Tagged ad-funded answers first; too few -> every Normal answer
    (longer, so dearer); none -> None (the worst case stands in)."""
    from .models import AIUsage
    now = now or timezone.now()
    since = now - timedelta(days=AM.WINDOW_DAYS)
    base = AIUsage.objects.filter(created_at__gte=since, ok=True)
    rate = _rate(_levels(c)[1])
    for src, qs in (("ad_answers", base.filter(attempts__contains=AD_TAG)),
                    ("normal_answers", base.filter(level="normal").exclude(feature="chat.continue"))):
        agg = qs.aggregate(n=Count("id"), usd=Sum("cost_usd"))
        n = int(agg["n"] or 0)
        if n >= AM.MIN_COST_SAMPLES:
            cont = base.filter(feature="chat.continue").aggregate(
                n=Count("id"), usd=Sum("cost_usd"))
            lv_all = base.filter(level__in=("normal", "better")).exclude(
                feature="chat.continue").count() or 1
            nc = int(cont["n"] or 0)
            per_cont = float(cont["usd"] or 0) / nc if nc else 0.0
            share = min(1.0, float(nc) / lv_all)
            usd = float(agg["usd"] or 0) / n + share * per_cont
            return round(usd * rate, 4), n, src
    return None, 0, "worst_case"


def real_income(now=None, c=None):
    """(৳ per rewarded ad, paid events, source) from AdMob paid events."""
    from .models import AdPlacementStat
    now = now or timezone.now()
    since = timezone.localdate(now) - timedelta(days=AM.WINDOW_DAYS)
    rows = list(AdPlacementStat.objects.filter(date__gte=since, fmt="rewarded", test=False)
                .values("fmt", "currency")
                .annotate(paid_events=Sum("paid_events"), revenue_micros=Sum("revenue_micros")))
    lv, c = _levels(c)
    return AM.income_per_ad_bdt(rows, float(c.get("usd_bdt") or 125.0))


def compute(now=None, c=None):
    """The day's number and its inputs — nothing saved."""
    from . import ai_levels_service as ALS
    lv, c = _levels(c)
    cost, samples, csrc = real_cost(now, c)
    inc, events, isrc = real_income(now, c)
    worst = worst_bdt(c)
    try:
        credits = int(lv["ad_answers_per_ad"] or 1) * int(ALS.credits("normal", c) or 1)
    except Exception:  # noqa: BLE001
        credits = 1
    n = AM.ads_per_answer(cost, inc, worst, credits)
    return n, {"real_cost_bdt": cost, "cost_samples": samples, "cost_source": csrc,
               "income_bdt": inc, "ad_events": events, "income_source": isrc,
               "worst_bdt": round(worst, 4),
               "profit_pct": AM.profit_pct(n, inc, max(worst, (cost or 0) * AM.SAFETY), credits),
               "answer_credits": credits}


def recompute(now=None):
    """Save today's AdMoneyDay row (idempotent per local date)."""
    from .models import AdMoneyDay
    now = now or timezone.now()
    n, data = compute(now)
    row, _ = AdMoneyDay.objects.update_or_create(
        date=timezone.localdate(now), defaults={"ads_per_answer": n, "data": data})
    return row


def tick(now=None):
    """minute_jobs slice: recompute once per local day. Idle = one read."""
    from . import ops_health as H
    now = now or timezone.now()
    last = H.stamp_get(STAMP)
    if last is not None and timezone.localdate(last) == timezone.localdate(now):
        return None
    row = recompute(now)
    H.stamp_set(STAMP, now)
    return row


def ads_per_answer(c=None):
    """N shown to the user and used for crediting. Dynamic: the newest
    AdMoneyDay row of the last 3 days, never below the CURRENT config's
    break-even (a config change applies at once); no row -> computed from
    the worst case with no DB write. Static (ad_dynamic off): the config."""
    lv, c = _levels(c)
    if not lv.get("ad_dynamic"):
        return max(1, int(lv.get("ads_per_answer") or 1))
    floor_n = AM.MIN_ADS
    try:
        from .models import AdMoneyDay
        since = timezone.localdate() - timedelta(days=2)
        row = AdMoneyDay.objects.filter(date__gte=since).order_by("-date").first()
        if row is not None:
            inc = float((row.data or {}).get("income_bdt") or AM.DEFAULT_AD_INCOME_BDT)
            return max(int(row.ads_per_answer), AM.ads_per_answer(0.0, inc, worst_bdt(c)))
        return AM.ads_per_answer(None, AM.DEFAULT_AD_INCOME_BDT, worst_bdt(c))
    except Exception as e:  # noqa: BLE001 — never below the floor
        log.warning("ad_money: N unreadable (%s)", type(e).__name__)
        return floor_n


# ---------------------------------------------------------------- ad answers
def ad_funded(user, need):
    """True when THIS spend of `need` credits would take rewarded-ad credits
    (the owner's bucket order: plan -> free/rewarded/referral by expiry ->
    pack). Read-only; a free user's answer paid by ads."""
    if user is None or int(need or 0) <= 0:
        return False
    try:
        from . import credits as CR
        left = int(need)
        for lot in CR._spend_order(CR._active(user).filter(remaining__gt=0)):
            take = min(int(lot.remaining), left)
            if take > 0 and lot.bucket == CR.REWARDED:
                return True
            left -= take
            if left <= 0:
                break
    except Exception:  # noqa: BLE001
        return False
    return False


def ad_level(user, lvl, c=None):
    """(level spec, ad_funded). An answer paid with rewarded-ad credits runs
    on the Normal row with the shorter output; its price (credits) stays."""
    if user is None or not lvl or not lvl.get("free_ok"):
        return lvl, False
    lv, c = _levels(c)
    if not lv.get("ad_dynamic"):
        return lvl, False          # aimoney rules not switched on in this row
    if not ad_funded(user, lvl.get("credits")):
        return lvl, False
    from . import ai_levels_service as ALS
    normal = ALS.spec("normal", c)
    if normal is None:
        return lvl, False
    row = dict(AM.ad_row(normal, int(lv.get("ad_out_cap") or AM.AD_OUT_CAP)))
    row["credits"] = lvl["credits"]
    row["free_ok"] = True
    row["fallbacks"] = [x for x in (normal.get("fallbacks") or [])]
    return row, True


# ---------------------------------------------------------------- dashboard
def money_table(days=14, now=None):
    """Owner Admin -> Money (daily). Aggregates only — no user is shown."""
    from .models import AdEvent, AdPlacementStat, AIUsage, CreditLedger
    now = now or timezone.now()
    days = max(1, min(60, int(days or 14)))
    today = timezone.localdate(now)
    first = today - timedelta(days=days - 1)
    dates = [first + timedelta(days=i) for i in range(days)]
    lv, c = _levels()
    rate = _rate(c)
    usd_bdt = float(c.get("usd_bdt") or 125.0)
    # ad income per ad type (AdMob paid events; ৳ per currency)
    ad_income = {}
    for r in (AdPlacementStat.objects.filter(date__gte=first, test=False)
              .values("date", "fmt", "currency").annotate(m=Sum("revenue_micros"))):
        cur = (r["currency"] or "").upper()
        if cur not in ("BDT", "USD"):
            continue
        v = float(r["m"] or 0) / 1e6 * (usd_bdt if cur == "USD" else 1.0)
        d = ad_income.setdefault(r["date"], {})
        d[r["fmt"]] = d.get(r["fmt"], 0.0) + v
    # no paid data for rewarded that day -> the honest estimate (৳0.40 an ad)
    est_days = set()
    start = timezone.make_aware(datetime.combine(first, dtime.min))
    for r in (AdEvent.objects.filter(at__gte=start, kind="rewarded", credited_paisa__gt=0)
              .values("at__date").annotate(n=Count("id"))):
        d = ad_income.setdefault(r["at__date"], {})
        if not d.get("rewarded"):
            d["rewarded"] = r["n"] * AM.DEFAULT_AD_INCOME_BDT
            est_days.add(r["at__date"])
    # AI cost: free users (no paid plan / trial now) and per answer by level
    paid_now = Q(user__plan_until__gt=now) | Q(user__trial_until__gt=now) | Q(
        user__is_founder=True, user__founder_since__isnull=True)
    ai = AIUsage.objects.filter(created_at__gte=start, ok=True)
    free_ai = {r["created_at__date"]: float(r["usd"] or 0) * rate for r in
               ai.filter(user__isnull=False).exclude(paid_now)
               .values("created_at__date").annotate(usd=Sum("cost_usd"))}
    level_cost = {}
    for r in (ai.exclude(level="").exclude(feature="chat.continue")
              .values("created_at__date", "level").annotate(n=Count("id"), usd=Sum("cost_usd"))):
        level_cost.setdefault(r["created_at__date"], {})[r["level"]] = (
            r["n"], float(r["usd"] or 0) * rate)
    for r in (ai.filter(attempts__contains=AD_TAG).values("created_at__date")
              .annotate(n=Count("id"), usd=Sum("cost_usd"))):
        level_cost.setdefault(r["created_at__date"], {})["ad"] = (r["n"], float(r["usd"] or 0) * rate)
    # credits sold: packs (top-ups) and plan allowances granted that day
    sold = {}
    for r in (CreditLedger.objects.filter(created_at__gte=start, delta__gt=0)
              .filter(Q(reason="topup") | Q(reason="grant", bucket="plan"))
              .values("created_at__date", "reason").annotate(s=Sum("delta"))):
        k = "packs" if r["reason"] == "topup" else "plans"
        sold.setdefault(r["created_at__date"], {})[k] = int(r["s"] or 0)
    rows = AM.money_rows(dates, ad_income, free_ai, level_cost, sold)
    for r in rows:
        r["rewarded_estimate"] = r["date"] in est_days
    return {"rows": rows, "ads_per_answer": ads_per_answer(c), "today": compute(now, c)[1],
            "rate": rate}
