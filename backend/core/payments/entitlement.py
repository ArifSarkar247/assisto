"""THE entitlement service — one per account, every channel calls it.

    plan + plan_until  live on User (everything else in the app reads them via
                       core.plans.effective_plan). This module is the ONLY
                       payment code that writes them.
    credits            User.ai_credits + CreditLedger + CreditPurchase rows
                       (12-month expiry buckets, same as the existing packs).

Rules (also in .phaseB/proposals/pay1.md and owner_actions/PAYMENTS_SETUP.md)

  * Paid time is stored as PlanPeriod rows, one per purchase/subscription
    token, unique on (source, ref) => the same payment can never grant twice.
  * At any instant the HIGHEST tier that is covered wins (Business > Premium).
  * Non-payment time (Founding Member, referral days, an owner edit) is kept
    as the account's BASE in PaymentAccount; a payment never wipes it and it
    never wipes a payment. Same tier: the later end wins.
  * Gateway (prepaid) purchases:
      same plan    -> the new period starts when the current one of that plan
                      ends (stacking, nothing lost)
      upgrade      -> Business starts now; the unused Premium GATEWAY time is
                      converted at the monthly price ratio into extra Business
                      days (prorated, nothing lost)
      downgrade    -> Premium is queued to start when the Business time ends
  * Play subscriptions: Google decides the dates (renewals, grace, hold,
    upgrades via linkedPurchaseToken). The period mirrors Google's
    expiryTime; non-entitled states end it now; a revoke/refund revokes it.
  * Refund / revoke -> the period is revoked, the plan is recomputed (expiry
    downgrade), pack credits still unspent are debited (never below zero).
  * Expiry -> recompute() (called by the sweep and on every payment API read)
    drops the user to whatever is still covered, else their base, else Free.
  * Every change writes a PaymentEvent (append-only) + the user's AuditLog.
"""
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import F
from django.utils import timezone

from . import catalog

TOL = timedelta(minutes=2)       # gap tolerated between back-to-back periods


def tier(plan):
    return catalog.TIER.get(plan or "free", 0)


# ----------------------------------------------------------------- audit
def event(user, kind, channel="", ref="", amount=0, net=0, **detail):
    from ..models import AuditLog, PaymentEvent
    PaymentEvent.objects.create(
        user=user if getattr(user, "pk", None) else None, kind=kind[:40],
        channel=channel[:10], ref=str(ref or "")[:80],
        amount_bdt=Decimal(str(amount or 0)), net_bdt=Decimal(str(net or 0)),
        detail=detail)
    if getattr(user, "pk", None):
        try:
            AuditLog.objects.create(user=user, action=("pay." + kind)[:80],
                                    detail={"channel": channel, "ref": str(ref)[:80],
                                            **{k: v for k, v in detail.items()
                                               if isinstance(v, (str, int, float, bool))}})
        except Exception:
            pass


def ledger(source, delta_bdt):
    """Add (or, for refunds, subtract) NET ৳ on today's DailyLedger revenue
    source ('subs'|'packs'). Profit Guard reads these as NET revenue."""
    from .. import billing
    amt = float(delta_bdt or 0)
    if not amt:
        return
    with transaction.atomic():
        row = billing._today_ledger()
        rev = dict(row.revenue_by_source or {})
        rev[source] = round(float(rev.get(source, 0) or 0) + amt, 2)
        row.revenue_by_source = rev
        row.save(update_fields=["revenue_by_source", "updated_at"])


# ----------------------------------------------------------------- recompute
def _coverage_end(rows, now):
    """End of the contiguous coverage that contains `now`, else None."""
    rows = sorted(rows, key=lambda r: r.starts_at)
    end = None
    for r in rows:
        if end is None:
            if r.starts_at <= now < r.ends_at:
                end = r.ends_at
        elif r.starts_at <= end + TOL and r.ends_at > end:
            end = r.ends_at
    return end


class _Base:
    """The non-payment base as a pseudo period (for coverage math only)."""
    def __init__(self, plan, starts_at, ends_at):
        self.plan, self.starts_at, self.ends_at = plan, starts_at, ends_at


def _active_rows(user, now):
    from ..models import PlanPeriod
    return list(PlanPeriod.objects.filter(user=user, status="active",
                                          ends_at__gt=now))


def paid_state(user, now=None):
    """(plan, until) covered by payments right now, or (None, None)."""
    now = now or timezone.now()
    rows = _active_rows(user, now)
    for plan in sorted({r.plan for r in rows}, key=tier, reverse=True):
        end = _coverage_end([r for r in rows if r.plan == plan], now)
        if end:
            return plan, end
    return None, None


def recompute(user, now=None, reason="recompute"):
    """Derive User.plan / plan_until from paid periods + the base. Idempotent.
    Returns (plan, plan_until)."""
    from ..models import PaymentAccount, User
    now = now or timezone.now()
    with transaction.atomic():
        u = User.objects.select_for_update().get(pk=user.pk)
        acct, _ = PaymentAccount.objects.select_for_update().get_or_create(
            user=u, defaults={"base_plan": u.plan or "free", "base_until": u.plan_until})
        cur = (u.plan or "free", u.plan_until)
        if not acct.has_written or cur != (acct.written_plan or "free", acct.written_until):
            # something other than a payment set the plan (founder grant,
            # referral redeem, owner edit, legacy data) -> that is the base.
            acct.base_plan, acct.base_until = cur
        base_ok = bool(acct.base_until and acct.base_until > now
                       and tier(acct.base_plan) > 0)
        rows = _active_rows(u, now)
        if base_ok:
            rows.append(_Base(acct.base_plan, now - timedelta(seconds=1), acct.base_until))
        final = None
        for t_ in sorted({tier(r.plan) for r in rows}, reverse=True):
            same = [r for r in rows if tier(r.plan) == t_]
            end = _coverage_end(same, now)
            if end:
                paid = [r for r in same if not isinstance(r, _Base)]
                name = (paid[0].plan if paid else acct.base_plan)
                final = (name, end)
                break
        if final is None:
            final = (acct.base_plan or "free", acct.base_until)
        changed = cur != final
        if changed:
            User.objects.filter(pk=u.pk).update(plan=final[0], plan_until=final[1])
        acct.written_plan, acct.written_until, acct.has_written = final[0], final[1], True
        acct.save()
    user.plan, user.plan_until = final
    if changed:
        event(user, "entitlement.change", ref=reason,
              before_plan=cur[0], before_until=cur[1].isoformat() if cur[1] else "",
              plan=final[0], until=final[1].isoformat() if final[1] else "")
    return final


# ----------------------------------------------------------------- gateway (prepaid)
def _months_after(dt, n):
    from ..founders import add_months
    return add_months(dt, n)


def _monthly_price(plan):
    return catalog.price(f"{plan}_monthly", "gateway") or 0


def grant_prepaid(user, *, order, now=None):
    """Grant the PREPAID period a paid gateway order bought. Idempotent per
    order (PlanPeriod unique (gateway, order.merchant_tx_id))."""
    from ..models import PlanPeriod
    now = now or timezone.now()
    ref = "gw:" + order.merchant_tx_id
    if PlanPeriod.objects.filter(source="gateway", ref=ref).exists():
        return None
    from ..models import PaymentAccount
    recompute(user, now, reason="pre:" + ref)       # capture the current base
    plan, months = order.plan, int(order.months or 1)
    rows = _active_rows(user, now)
    acct = PaymentAccount.objects.filter(user=user).first()
    start = now
    # 1) same plan: stack after the latest end of that plan (paid or base)
    same_ends = [r.ends_at for r in rows if r.plan == plan]
    if acct and acct.base_until and acct.base_until > now and tier(acct.base_plan) == tier(plan):
        same_ends.append(acct.base_until)
    if same_ends:
        start = max(start, max(same_ends))
    # 2) downgrade: queue after the higher tier's coverage
    for hp in {r.plan for r in rows if tier(r.plan) > tier(plan)}:
        h_end = _coverage_end([r for r in rows if r.plan == hp], now)
        if h_end:
            start = max(start, h_end)
    if acct and acct.base_until and acct.base_until > now and tier(acct.base_plan) > tier(plan):
        start = max(start, acct.base_until)
    # 3) upgrade: convert unused lower-tier GATEWAY time into extra days
    bonus = timedelta(0)
    converted = []
    hi = _monthly_price(plan)
    for r in rows:
        if r.source == "gateway" and tier(r.plan) < tier(plan) and tier(r.plan) > 0:
            lo = _monthly_price(r.plan)
            left = r.ends_at - max(r.starts_at, now)
            if left.total_seconds() > 0 and hi > 0:
                bonus += timedelta(seconds=left.total_seconds() * lo / hi)
            r.status = "converted"
            r.note = ("converted to %s %s" % (plan, ref))[:160]
            r.ends_at = max(r.starts_at, min(r.ends_at, now))
            r.save(update_fields=["status", "note", "ends_at", "updated_at"])
            converted.append(r.ref)
    end = _months_after(start, months) + bonus
    p = PlanPeriod.objects.create(user=user, source="gateway", ref=ref, plan=plan,
                                  starts_at=start, ends_at=end, order=order,
                                  note="prepaid %s mo" % months)
    event(user, "entitlement.grant", "gateway", ref, amount=order.amount_bdt,
          plan=plan, starts=start.isoformat(), ends=end.isoformat(),
          bonus_seconds=int(bonus.total_seconds()), converted=",".join(converted))
    recompute(user, now, reason=ref)
    return p


# ----------------------------------------------------------------- play (auto-renew)
def upsert_play_period(user, *, ref, plan, starts, ends, entitled, auto_renew,
                       state="", now=None):
    """Mirror Google's view of one subscription token. `entitled` False
    (on hold / paused / expired / pending) ends the period now."""
    from ..models import PlanPeriod
    now = now or timezone.now()
    if not entitled:
        ends = min(ends or now, now)
    starts = starts or now
    if ends <= starts:
        starts = ends
    with transaction.atomic():
        p = PlanPeriod.objects.select_for_update().filter(source="play", ref=ref).first()
        if p is None:
            p = PlanPeriod.objects.create(user=user, source="play", ref=ref, plan=plan,
                                          starts_at=starts, ends_at=ends,
                                          auto_renew=auto_renew, note=state[:160])
            kind = "entitlement.grant"
        elif p.status == "revoked":
            return p              # a revoked token never comes back
        else:
            p.plan, p.ends_at, p.auto_renew, p.note = plan, ends, auto_renew, state[:160]
            if starts < p.starts_at:
                p.starts_at = starts
            p.save(update_fields=["plan", "ends_at", "auto_renew", "note",
                                  "starts_at", "updated_at"])
            kind = "entitlement.update"
    event(user, kind, "play", ref, plan=plan, state=state, entitled=entitled,
          ends=ends.isoformat())
    recompute(user, now, reason=ref)
    return p


def revoke_period(source, ref, reason="", now=None):
    """Revoke (refund / chargeback / Google REVOKED). Returns the period."""
    from ..models import PlanPeriod
    now = now or timezone.now()
    with transaction.atomic():
        p = PlanPeriod.objects.select_for_update().filter(source=source, ref=ref).first()
        if p is None or p.status == "revoked":
            return p
        p.status = "revoked"
        p.note = ("revoked: " + reason)[:160]
        p.ends_at = max(p.starts_at, min(p.ends_at, now))
        p.save(update_fields=["status", "note", "ends_at", "updated_at"])
    event(p.user, "entitlement.revoke", source, ref, reason=reason)
    recompute(p.user, now, reason="revoke:" + ref)
    return p


def mark_replaced(source, ref, by_ref, now=None):
    """A Play upgrade/downgrade/resubscribe replaced this token
    (linkedPurchaseToken). The old period ends now; the new one carries on."""
    from ..models import PlanPeriod
    now = now or timezone.now()
    p = PlanPeriod.objects.filter(source=source, ref=ref, status="active").first()
    if p is None:
        return None
    p.status = "replaced"
    p.note = ("replaced by " + by_ref)[:160]
    p.ends_at = max(p.starts_at, min(p.ends_at, now))
    p.save(update_fields=["status", "note", "ends_at", "updated_at"])
    event(p.user, "entitlement.replaced", source, ref, by=by_ref)
    return p


# ----------------------------------------------------------------- credits
def grant_pack(user, *, channel, ref, sku, amount_bdt, now=None):
    """Grant a credit pack once per (provider, ref). Returns credits granted
    (0 when this ref was already granted)."""
    from ..models import CreditLedger, CreditPurchase, User
    now = now or timezone.now()
    d = catalog.describe(sku)
    if not d or d["kind"] != "pack":
        return 0
    provider = "play_billing" if channel == "play" else "eps"
    txn = ref[:120]
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        if CreditPurchase.objects.filter(provider=provider, txn_ref=txn).exists():
            return 0
        CreditPurchase.objects.create(
            user=locked, pack_id=d["pack_id"], price_bdt=int(Decimal(str(amount_bdt))),
            credits=d["credits"], provider=provider, status="confirmed", txn_ref=txn,
            granted=True, confirmed_at=now,
            expires_at=now + timedelta(days=30 * int(d["valid_months"] or 12)))
        User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") + d["credits"])
        CreditLedger.objects.create(user=locked, delta=d["credits"], reason="topup",
                                    note=f"pack:{d['pack_id']} {channel}")
    user.ai_credits = int(getattr(locked, "ai_credits", 0) or 0) + d["credits"]
    event(user, "credits.grant", channel, ref, amount=amount_bdt,
          credits=d["credits"], sku=sku)
    return d["credits"]


def revoke_pack(user, *, channel, ref, reason=""):
    """Refund of a pack: debit what is still unspent (never below zero)."""
    from ..models import CreditLedger, CreditPurchase, User
    provider = "play_billing" if channel == "play" else "eps"
    with transaction.atomic():
        cp = CreditPurchase.objects.select_for_update().filter(
            provider=provider, txn_ref=ref[:120], granted=True).first()
        if cp is None:
            return 0
        locked = User.objects.select_for_update().get(pk=cp.user_id)
        take = min(int(locked.ai_credits or 0), int(cp.credits or 0))
        if take > 0:
            User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") - take)
            CreditLedger.objects.create(user=locked, delta=-take, reason="adjust",
                                        note=f"refund pack:{cp.pack_id}"[:120])
        cp.granted = False
        cp.status = "failed"
        cp.save(update_fields=["granted", "status"])
    event(locked, "credits.revoke", channel, ref, credits=take, reason=reason)
    return take


# ----------------------------------------------------------------- read model
def summary(user, now=None):
    """What /payments/state returns: the entitlement + where it comes from."""
    from ..models import PlanPeriod
    from .. import plans
    now = now or timezone.now()
    recompute(user, now)
    try:
        user.refresh_from_db(fields=["ai_credits", "plan", "plan_until"])
    except Exception:
        pass
    rows = PlanPeriod.objects.filter(user=user, status="active",
                                     ends_at__gt=now).order_by("starts_at")
    periods = [{"source": r.source, "plan": r.plan, "starts_at": r.starts_at.isoformat(),
                "ends_at": r.ends_at.isoformat(), "auto_renew": r.auto_renew,
                "queued": r.starts_at > now,
                "sku": (r.order.sku if r.order_id else "")} for r in rows.select_related("order")]
    gw = [p for p in periods if p["source"] == "gateway" and not p["queued"]]
    play = [p for p in periods if p["source"] == "play"]
    renew = None
    if gw and not play:
        cur = max(gw, key=lambda p: p["ends_at"])
        later = [p for p in periods if p["source"] == "gateway"]
        last = max(later, key=lambda p: p["ends_at"])
        renew = {"sku": cur["sku"] or cur["plan"] + "_monthly",
                 "ends_at": last["ends_at"]}
    try:   # pay-e2e: grace / on hold / paused / cancelled -> app banner + deep link
        from .play import sub_status
        play_sub = sub_status(user, now)
    except Exception:
        play_sub = None
    return {"plan": plans.effective_plan(user),
            "plan_until": user.plan_until.isoformat() if user.plan_until else None,
            "credits": int(user.ai_credits or 0), "periods": periods,
            "managed_by_play": bool(play), "renew": renew, "play": play_sub}
