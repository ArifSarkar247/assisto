"""billing-v2 — daily jobs (owner order 27 Oct; rules A, Q, R, add-ons).

  reconcile()          re-fetch every live / recent Play subscription and
                       recent pack from Google and mirror it (fixes missed
                       RTDNs: renewals, expiries, holds, refunds), then the
                       credits safety settle (expires plan allowance whose
                       period passed). Saves a BillingReport.
  credits_verify()     balance == ledger sum == lots for every user.
  profit_guard_users() users whose AI cost this month > what they paid
                       this month (owner list + optional staff push).
  entitlements_audit() every user whose plan or credits are not backed by a
                       verified payment or a recorded grant (+ --fix).
All never raise; each one writes a BillingReport shown in Owner Admin.
"""
import logging
from datetime import timedelta
from decimal import Decimal

from django.db.models import Sum
from django.utils import timezone

log = logging.getLogger(__name__)


def _report(kind, ok, summary):
    from ..models import BillingReport
    return BillingReport.objects.create(kind=kind, ok=bool(ok), summary=summary)


# ----------------------------------------------------------------- Q
def reconcile(now=None, days=7, limit=500):
    from ..models import PlayPurchase, PaidOrder
    from . import play
    from .. import credits as CR
    now = now or timezone.now()
    out = {"checked": 0, "changed": 0, "errors": 0, "mismatches": [], "settled": 0}
    if play.configured():
        qs = (PlayPurchase.objects.filter(kind="sub", revoked=False)
              .filter(expires_at__gt=now - timedelta(days=days)) |
              PlayPurchase.objects.filter(kind="pack", revoked=False,
                                          created_at__gte=now - timedelta(days=days)))
        for pp in qs.distinct()[:limit]:
            if pp.user_id is None:
                continue
            out["checked"] += 1
            before = (pp.state, pp.expires_at, pp.order_id)
            try:
                if pp.kind == "sub":
                    play.sync_subscription(pp.purchase_token, pp.user, now)
                else:
                    play.sync_pack(pp.purchase_token, pp.product_id, pp.user, now)
            except play.PlayError as e:
                out["errors"] += 1
                out["mismatches"].append({"ref": play.ref_for(pp.purchase_token)[:20],
                                          "error": e.reason})
                continue
            except Exception as e:      # never break the job
                out["errors"] += 1
                out["mismatches"].append({"ref": play.ref_for(pp.purchase_token)[:20],
                                          "error": type(e).__name__})
                continue
            pp.refresh_from_db()
            after = (pp.state, pp.expires_at, pp.order_id)
            if after != before:
                out["changed"] += 1
                out["mismatches"].append({
                    "ref": play.ref_for(pp.purchase_token)[:20], "user": pp.user_id,
                    "before": [before[0], before[1].isoformat() if before[1] else None, before[2][-6:]],
                    "after": [after[0], after[1].isoformat() if after[1] else None, after[2][-6:]]})
        # recent paid orders that never got their grant (missed grant)
        for o in PaidOrder.objects.filter(status="paid", purchased_at__gte=now - timedelta(days=days),
                                          user__isnull=False):
            if not o.lots.exists() and (o.kind == "pack" or (o.period_end and o.period_end > now)):
                out["mismatches"].append({"order": o.order_id[-6:], "user": o.user_id,
                                          "problem": "no_grant"})
    else:
        out["skipped"] = "play_not_configured"
    out["settled"] = CR.settle_all(now)
    out["mismatches"] = out["mismatches"][:200]
    _report("reconcile", out["errors"] == 0, out)
    return out


# ----------------------------------------------------------------- A
def credits_verify(user_ids=None):
    from ..models import User
    from .. import credits as CR
    bad = []
    n = 0
    qs = User.objects.all() if user_ids is None else User.objects.filter(pk__in=user_ids)
    for u in qs.only("pk", "ai_credits").iterator():
        n += 1
        v = CR.verify(u)
        if not v["ledger_ok"] or not v["ok"]:
            bad.append(v)
    out = {"users": n, "mismatches": len(bad), "rows": bad[:200]}
    _report("credits_verify", not bad, out)
    return out


# ----------------------------------------------------------------- R
def _month_start(now):
    lt = timezone.localtime(now)
    return lt.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def profit_guard_users(now=None, push=None):
    """Per user, this local month: AI cost (AIUsage USD x usd_bdt) vs what
    they paid (real, non-test PaidOrder price minus refunds). Users whose
    cost is above both what they paid and the owner's minimum are listed."""
    from ..models import AIUsage, PaidOrder, User
    from .. import billing, credits as CR
    now = now or timezone.now()
    since = _month_start(now)
    k = CR.bcfg()
    rate = float(billing.cfg()["usd_bdt"])
    min_bdt = float(k.get("profit_guard_min_bdt", 20))
    costs = {}
    for r in (AIUsage.objects.filter(created_at__gte=since, user__isnull=False)
              .values("user_id").annotate(s=Sum("cost_usd"))):
        costs[r["user_id"]] = float(r["s"] or 0) * rate
    paid = {}
    for o in PaidOrder.objects.filter(purchased_at__gte=since, is_test=False,
                                      user__isnull=False):
        paid[o.user_id] = paid.get(o.user_id, 0.0) + float(Decimal(o.price) - Decimal(o.refunded_amount))
    rows = []
    for uid, c in costs.items():
        p = paid.get(uid, 0.0)
        if c > p and c >= min_bdt:
            rows.append({"user": uid, "cost_bdt": round(c, 2), "paid_bdt": round(p, 2),
                         "over_bdt": round(c - p, 2)})
    rows.sort(key=lambda r: -r["over_bdt"])
    out = {"month": since.strftime("%Y-%m"), "users": rows[:200], "count": len(rows)}
    _report("profit_guard", not rows, out)
    if rows and (push if push is not None else k.get("profit_guard_push")):
        billing._owner_alert("Profit Guard: %d user(s) cost more than they paid" % len(rows),
                             "Top: user #%s cost ৳%s, paid ৳%s this month. See Owner Admin -> Payments -> Profit Guard."
                             % (rows[0]["user"], rows[0]["cost_bdt"], rows[0]["paid_bdt"]))
    return out


# ----------------------------------------------------------------- add-on: entitlements audit
def _grant_backing(u, now):
    """Why this user's current (non-free) plan is allowed, or ''."""
    from ..models import EntitlementGrant, FounderGrant, PlanPeriod
    from .. import plans
    if PlanPeriod.objects.filter(user=u, status="active", starts_at__lte=now, ends_at__gt=now).exists():
        return "payment"
    if plans.lifetime_founder(u):
        return "lifetime_founder"
    if EntitlementGrant.objects.filter(user=u, ends_at__gte=(u.plan_until or now) - timedelta(minutes=5),
                                       starts_at__lte=now).exclude(plan="free").exists():
        return "grant"
    if u.is_founder and FounderGrant.objects.filter(user=u, revoked_at__isnull=True).exists():
        return "founder_grant"
    return ""


def entitlements_audit(fix=False, dry_run=True, now=None):
    """List users whose plan / credits aren't backed by a verified payment or
    a recorded grant. --fix (without --dry-run) records the missing grant
    when the source is KNOWN (the Play reviewer by PLAY_REVIEWER_PHONE, a
    founder), and otherwise only PROPOSES removal (owner approval)."""
    from ..models import CreditLot, EntitlementGrant, User
    from .. import credits as CR, otp, plans
    from ..phone import canonical_phone
    now = now or timezone.now()
    rows = []
    reviewer = otp.reviewer_canon()
    for u in User.objects.all().iterator():
        items = []
        try:
            eff = plans.effective_plan(u)
        except Exception:
            eff = "free"
        if eff != "free" and plans.plan_active(u):
            back = _grant_backing(u, now)
            if not back:
                src = ""
                if reviewer and canonical_phone(u.phone or "") == reviewer:
                    src = "play_reviewer"
                items.append({"what": "plan", "plan": u.plan,
                              "until": u.plan_until.isoformat() if u.plan_until else None,
                              "known_source": src,
                              "fix": ("record a play_reviewer grant (keep Premium)" if src
                                      else "owner: confirm a grant, or end the plan")})
                if fix and not dry_run and src:
                    EntitlementGrant.objects.create(
                        user=u, source=src, plan=u.plan, starts_at=now, ends_at=u.plan_until,
                        reason="entitlements_audit --fix: backfill seed_play_reviewer")
                    items[-1]["fixed"] = True
        legacy = CreditLot.objects.filter(user=u, status="active", bucket=CR.LEGACY,
                                          remaining__gt=0).aggregate(s=Sum("remaining"))["s"] or 0
        if legacy:
            items.append({"what": "credits", "bucket": "legacy", "credits": int(legacy),
                          "fix": "run credits_rebuild_buckets (splits them into real buckets)"})
        base = CreditLot.objects.filter(user=u, status="active", bucket=CR.PLAN,
                                        source_type="base", remaining__gt=0)
        if base.exists() and eff != "free" and not _grant_backing(u, now):
            n = int(base.aggregate(s=Sum("remaining"))["s"] or 0)
            items.append({"what": "credits", "bucket": "plan", "credits": n,
                          "fix": "plan allowance from an unrecorded plan: record the grant, or expire via ledger"})
        v = CR.verify(u)
        if not v["ledger_ok"]:
            items.append({"what": "ledger", "balance": v["balance"], "ledger_sum": v["ledger_sum"],
                          "fix": "run credits_rebuild_buckets --dry-run and review"})
        if items:
            rows.append({"user": u.pk, "items": items})
    confirmed = []
    labels = {"play_reviewer": "Play reviewer grant", "owner_grant": "owner grant",
              "founding": "founding grant", "trial": "trial", "system": "system grant"}
    for g in EntitlementGrant.objects.filter(ends_at__gt=now).exclude(plan="free").select_related("user"):
        if g.user_id and g.user and g.user.plan_until and g.user.plan_until <= g.ends_at + timedelta(minutes=5):
            confirmed.append({"user": g.user_id, "source": g.source, "plan": g.plan,
                              "until": g.ends_at.isoformat(),
                              "label": labels.get(g.source, g.source), "reason": g.reason})
    out = {"users": len(rows), "rows": rows[:300], "fix": bool(fix), "dry_run": bool(dry_run),
           "confirmed": confirmed[:300]}
    _report("entitlements_audit", not rows, out)
    return out
