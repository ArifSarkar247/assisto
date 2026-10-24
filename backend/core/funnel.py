"""
p5-growth: the Owner Admin growth funnel (/owner/funnel). Real rows only, a
handful of indexed aggregate queries — never a per-user loop.

What each number means (shown on the page too):
* installs      — InstallPing rows: first app opens of builds that send the
                  ping (a reinstall counts again; older builds never sent it).
* signups       — accounts created (User.date_joined), staff/superusers excluded.
* activated     — of those signups, accounts active on at least
                  `invite_activation_days` different days within their first
                  14 days (ActiveDay). Cohorts younger than 14 days are still open.
* D1/D7/D30     — classic retention: share of a signup cohort that used the
                  app exactly 1 / 7 / 30 days after the signup day. Only cohorts
                  that signed up after activity tracking started are shown.
* paying users  — distinct accounts with a real payment (PaymentEvent
                  play.charge / order.paid) in the period.
* revenue       — NET payment revenue (after store/gateway fees, minus
                  refunds) from PaymentEvent; ad + sponsor revenue from the P&L
                  DailyLedger is shown separately.
* ARPU          — net payment revenue / users active in the period.
* ARPPU         — net payment revenue / paying users.
* referrals     — ReferralClaim rows by state + the reward credits and their
                  booked cost (Profit Guard "growth").
"""
from datetime import timedelta
from decimal import Decimal

from django.db.models import Count, Sum
from django.db.models.functions import TruncDate
from django.utils import timezone

from .growth import ACTIVATION_WINDOW_DAYS, cfg as growth_cfg

RET_DAYS = (1, 7, 30)
COHORT_WEEKS = 8


def _users():
    from .models import User
    return User.objects.filter(is_superuser=False, is_staff=False)


def tracking_started():
    from .models import ActiveDay
    first = ActiveDay.objects.order_by("day").values_list("day", flat=True).first()
    return first


def _div(a, b, nd=2):
    try:
        return round(float(a) / float(b), nd) if b else None
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def _pct(a, b):
    v = _div(a, b, 4)
    return None if v is None else round(v * 100, 1)


def headline(days=30, now=None):
    from .models import ActiveDay, InstallPing
    now = now or timezone.now()
    today = timezone.localdate(now)
    since_dt = now - timedelta(days=days)
    since_day = today - timedelta(days=days - 1)
    c = growth_cfg()
    need = int(c["invite_activation_days"])

    installs = InstallPing.objects.filter(created_at__gte=since_dt)
    n_install = installs.count()
    n_install_linked = installs.filter(user__isnull=False).count()
    signups = _users().filter(date_joined__gte=since_dt)
    n_signup = signups.count()

    # activation over the signups of the period (one grouped query)
    act_rows = (ActiveDay.objects.filter(
        user__in=signups.values("pk"), since_signup__lt=ACTIVATION_WINDOW_DAYS)
        .values("user_id").annotate(n=Count("id")).filter(n__gte=need))
    n_act = act_rows.count()
    open_cut = now - timedelta(days=ACTIVATION_WINDOW_DAYS)
    closed = signups.filter(date_joined__lte=open_cut)
    n_closed = closed.count()
    n_act_closed = (ActiveDay.objects.filter(
        user__in=closed.values("pk"), since_signup__lt=ACTIVATION_WINDOW_DAYS)
        .values("user_id").annotate(n=Count("id")).filter(n__gte=need).count())

    active = (ActiveDay.objects.filter(day__gte=since_day, user__is_superuser=False,
                                       user__is_staff=False)
              .values("user_id").distinct().count())
    pay = payments(days, now)
    return {
        "days": days, "need": need,
        "installs": n_install, "installs_linked": n_install_linked,
        "signups": n_signup,
        "signup_per_install": _pct(n_signup, n_install),
        "activated": n_act, "activated_pct": _pct(n_act, n_signup),
        "closed_signups": n_closed, "closed_activated": n_act_closed,
        "closed_activated_pct": _pct(n_act_closed, n_closed),
        "active_users": active,
        **pay,
        "arpu": _div(pay["net"], active),
        "arppu": _div(pay["net"], pay["paying_users"]),
        "arpu_ads": _div(pay["ads_revenue"], active),
        "paying_pct": _pct(pay["paying_users"], active),
    }


def payments(days=30, now=None):
    from .models import DailyLedger, PaymentEvent
    now = now or timezone.now()
    since = now - timedelta(days=days)
    evs = PaymentEvent.objects.filter(created_at__gte=since)
    paid = evs.filter(kind__in=("play.charge", "order.paid"))
    agg = paid.aggregate(g=Sum("amount_bdt"), n=Sum("net_bdt"), c=Count("id"))
    ref = evs.filter(kind__in=("play.refund", "order.refunded")).aggregate(
        n=Sum("net_bdt"))
    payers = paid.exclude(user__isnull=True).values("user_id").distinct().count()
    net = (agg["n"] or Decimal(0)) + (ref["n"] or Decimal(0))   # refunds are negative
    ads = 0.0
    since_day = timezone.localdate(now) - timedelta(days=days - 1)
    for r in DailyLedger.objects.filter(date__gte=since_day).values_list(
            "revenue_by_source", flat=True):
        for k in ("ads", "sponsored"):
            try:
                ads += float((r or {}).get(k, 0) or 0)
            except (TypeError, ValueError):
                pass
    return {"paying_users": payers, "payments": int(agg["c"] or 0),
            "gross": float(agg["g"] or 0), "net": float(net),
            "ads_revenue": round(ads, 2)}


def retention(now=None, weeks=COHORT_WEEKS):
    """Weekly signup cohorts (Mon-based) with classic D1/D7/D30."""
    from .models import ActiveDay
    now = now or timezone.now()
    today = timezone.localdate(now)
    start = tracking_started()
    if start is None:
        return {"tracking_started": None, "rows": []}
    first_week = today - timedelta(days=today.weekday()) - timedelta(weeks=weeks - 1)
    lo = max(start, first_week)
    sizes = {}
    for r in (_users().filter(date_joined__date__gte=lo)
              .annotate(d=TruncDate("date_joined")).values("d").annotate(n=Count("id"))):
        sizes[r["d"]] = r["n"]
    hits = {}
    for r in (ActiveDay.objects.filter(cohort_day__gte=lo, since_signup__in=RET_DAYS,
                                       user__is_superuser=False, user__is_staff=False)
              .values("cohort_day", "since_signup").annotate(n=Count("id"))):
        hits[(r["cohort_day"], r["since_signup"])] = r["n"]
    rows = []
    wk = today - timedelta(days=today.weekday())
    while wk >= first_week:
        days_in = [wk + timedelta(days=i) for i in range(7)
                   if lo <= wk + timedelta(days=i) <= today]
        size = sum(sizes.get(d, 0) for d in days_in)
        row = {"week": wk, "size": size, "ret": []}
        for n in RET_DAYS:
            # only cohort days whose day-N has already happened count
            ripe = [d for d in days_in if d + timedelta(days=n) <= today]
            base = sum(sizes.get(d, 0) for d in ripe)
            got = sum(hits.get((d, n), 0) for d in ripe)
            row["ret"].append({"n": n, "base": base, "got": got,
                               "pct": _pct(got, base) if ripe else None})
        if days_in:
            rows.append(row)
        wk -= timedelta(weeks=1)
    return {"tracking_started": start, "rows": rows}


def referrals(days=30, now=None):
    from .models import FoundingSeat, ReferralClaim
    now = now or timezone.now()
    since = now - timedelta(days=days)
    claimed = ReferralClaim.objects.filter(claimed_at__gte=since)
    by_state = {s: 0 for s in ("pending", "rewarded", "rejected")}
    for r in claimed.values("state").annotate(n=Count("id")):
        by_state[r["state"]] = r["n"]
    rew = ReferralClaim.objects.filter(state="rewarded", decided_at__gte=since)
    agg = rew.aggregate(a=Sum("inviter_credits"), b=Sum("invitee_credits"),
                        c=Sum("cost_bdt"), n=Count("id"))
    reasons = list(ReferralClaim.objects.filter(state="rejected", decided_at__gte=since)
                   .values("reason").annotate(n=Count("id")).order_by("-n"))
    capped = rew.filter(reason="inviter_cap").count()
    seats = FoundingSeat.objects.aggregate(n=Count("id"), c=Sum("cost_bdt"),
                                           cr=Sum("credits"))
    seats_period = FoundingSeat.objects.filter(granted_at__gte=since).aggregate(
        n=Count("id"), c=Sum("cost_bdt"))
    top = list(rew.exclude(inviter__isnull=True).values("inviter_id")
               .annotate(n=Count("id")).order_by("-n")[:10])
    return {
        "claimed": sum(by_state.values()), **by_state,
        "conversion_pct": _pct(by_state["rewarded"], sum(by_state.values())),
        "rewarded_period": int(agg["n"] or 0),
        "inviter_credits": int(agg["a"] or 0), "invitee_credits": int(agg["b"] or 0),
        "cost_bdt": float(agg["c"] or 0), "capped": capped, "rejected_reasons": reasons,
        "seats_taken": int(seats["n"] or 0), "seats_credits": int(seats["cr"] or 0),
        "seats_cost_total": float(seats["c"] or 0),
        "seats_period": int(seats_period["n"] or 0),
        "seats_cost_period": float(seats_period["c"] or 0),
        "top_inviters": top,
    }


def series(days=30, now=None):
    """Daily installs / signups / active users for the chart (3 grouped queries)."""
    from .models import ActiveDay, InstallPing
    now = now or timezone.now()
    today = timezone.localdate(now)
    lo = today - timedelta(days=days - 1)
    inst = {r["d"]: r["n"] for r in InstallPing.objects.filter(
        created_at__date__gte=lo).annotate(d=TruncDate("created_at"))
        .values("d").annotate(n=Count("id"))}
    sign = {r["d"]: r["n"] for r in _users().filter(date_joined__date__gte=lo)
            .annotate(d=TruncDate("date_joined")).values("d").annotate(n=Count("id"))}
    act = {r["day"]: r["n"] for r in ActiveDay.objects.filter(day__gte=lo)
           .values("day").annotate(n=Count("id"))}
    out = []
    d = lo
    while d <= today:
        out.append({"date": d, "installs": inst.get(d, 0), "signups": sign.get(d, 0),
                    "active": act.get(d, 0)})
        d += timedelta(days=1)
    return out


def dashboard(days=30, now=None):
    return {"head": headline(days, now), "retention": retention(now),
            "referrals": referrals(days, now), "series": series(days, now),
            "tracking_started": tracking_started()}
