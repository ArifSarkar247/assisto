"""credits.py — the bucketed credit engine (owner order 27 Oct 2026,
BILLING, CREDIT AND REFUND HARDENING; rules A, B, C, I, L, N, V).

Model
  CreditLot     one grant into ONE bucket: plan | pack | free | rewarded |
                referral | legacy | debt. `remaining` is usable now and is
                part of User.ai_credits; `locked` is the staged-unlock part
                (NOT in the balance until it unlocks); `scheduled` lots are
                future annual months (not granted yet, no ledger row).
  CreditLedger  APPEND-ONLY. Every change of User.ai_credits is exactly one
                row (grant, topup, trial, rewarded, consume, unlock, expire,
                revoke, refund, return, adjust) with bucket + source + the
                balance after it. Grants carry a unique grant_key, so a
                retried grant is a no-op.

Invariant (credits_verify):  User.ai_credits == sum(ledger.delta)
                                            == sum(active lots.remaining)

Spend order (rule B): plan allowance (soonest expiry first) -> free, rewarded,
referral, legacy -> pack. Pack credits never expire. Plan allowance expires at
the end of its paid period and never rolls over. A failed call returns the
credit to the SAME lot it came from (rule N).

Everything that changes credits holds the User row lock (select_for_update)
first, so parallel requests cannot double-spend.

Backward compatibility: code (and tests) that still write User.ai_credits
directly are reconciled by settle(): a balance above the lots becomes a
`legacy` lot, a balance below them shrinks the lots in spend order (no ledger
row, the direct writer wrote its own). credits_verify still reports any
ledger mismatch, so nothing is hidden.
"""
import uuid
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import F, Sum
from django.utils import timezone

PLAN, PACK, FREE, REWARDED, REFERRAL, LEGACY, DEBT = (
    "plan", "pack", "free", "rewarded", "referral", "legacy", "debt")
BUCKETS = (PLAN, PACK, FREE, REWARDED, REFERRAL, LEGACY)
GROUP = {PLAN: 0, FREE: 1, REWARDED: 1, REFERRAL: 1, LEGACY: 1, PACK: 2}


def _far():
    from datetime import datetime, timezone as dtz
    return datetime(9999, 1, 1, tzinfo=dtz.utc)


def bcfg():
    """Normalized billing knobs (unlock_pct, unlock_hours, refund_window_hours)."""
    from . import billing
    try:
        return billing.cfg()["billing"]
    except Exception:
        from .logic import billing_cfg
        return billing_cfg.defaults()


def plan_credits(plan, months=1):
    """Monthly allowance of a plan from PricingConfig (founder/annual/probashi
    -> Premium). pricing-40: for a paid period of 12+ months (an annual
    plan) with credit_model enabled, each month grants
    credits x annual_credit_months / 12 (owner: annual = 10x price, 10x
    credits). Disabled (default) -> the full monthly allowance, as before."""
    from . import billing
    c = billing.cfg()
    row = c["plans"].get(plan) or c["plans"]["premium"]
    n = max(0, int(row["credits"]))
    cm = c.get("credit_model") or {}
    if int(months or 1) >= 12 and cm.get("enabled"):
        n = (n * int(cm.get("annual_credit_months") or 12)) // 12
    return n


def add_months(dt, n):
    from .founders import add_months as _am
    return _am(dt, n)


# ----------------------------------------------------------------- primitives
def _lock(user):
    from .models import User
    return User.objects.select_for_update().get(pk=user.pk)


def _write(u, delta, reason, bucket, note="", lot=None, source_type="", source_id="",
           grant_key=None):
    """ONE ledger row + move the cached balance. Caller holds the row lock."""
    from .models import CreditLedger, User
    delta = int(delta)
    if delta:
        User.objects.filter(pk=u.pk).update(ai_credits=F("ai_credits") + delta)
    u.ai_credits = int(u.ai_credits or 0) + delta
    return CreditLedger.objects.create(
        user=u, delta=delta, reason=reason, bucket=bucket, note=(note or "")[:120],
        lot=lot, source_type=(source_type or "")[:24], source_id=(source_id or "")[:120],
        grant_key=grant_key, balance_after=u.ai_credits)


def _sync_user(user, u):
    try:
        user.ai_credits = u.ai_credits
    except Exception:
        pass


def _active(u):
    from .models import CreditLot
    return CreditLot.objects.filter(user=u, status="active")


def _spend_order(qs):
    lots = [l for l in qs if l.bucket in GROUP]
    return sorted(lots, key=lambda l: (GROUP[l.bucket], l.expires_at or _far(), l.id))


def _close(lot, why, now):
    lot.status = "closed"
    lot.close_reason = why[:40]
    lot.save(update_fields=["status", "close_reason", "remaining", "locked", "spent"])


def _debt_lot(u, now):
    from .models import CreditLot
    lot = CreditLot.objects.filter(user=u, bucket=DEBT, status="active").first()
    if lot is None:
        lot = CreditLot.objects.create(user=u, bucket=DEBT, granted=0, remaining=0,
                                       starts_at=now, source_type="debt")
    return lot


# ----------------------------------------------------------------- grant
def grant(user, bucket, amount, *, reason="grant", note="", source_type="",
          source_id="", key=None, expires_at=None, staged=False, order=None,
          starts_at=None, scheduled=False, now=None, _u=None):
    """Grant `amount` credits into `bucket`. Idempotent on `key` (returns None
    when that key was already granted). `staged` applies the staged unlock
    (rule I: only unlock_pct% usable for unlock_hours). `scheduled` creates a
    future lot (an annual month) that settle() activates at `starts_at`."""
    from .models import CreditLot
    amount = int(amount or 0)
    now = now or timezone.now()
    if amount <= 0 or bucket not in BUCKETS:
        return None

    def _do(u):
        if key and CreditLot.objects.filter(grant_key=key).exists():
            return None
        usable, locked, unlocks = amount, 0, None
        if staged:
            k = bcfg()
            pct, hours = int(k["unlock_pct"]), int(k["unlock_hours"])
            if hours > 0 and pct < 100:
                usable = amount * pct // 100
                locked = amount - usable
                unlocks = (starts_at if (starts_at and not scheduled) else now) + timedelta(hours=hours)
        try:
            with transaction.atomic():
                lot = CreditLot.objects.create(
                    user=u, bucket=bucket, granted=amount,
                    remaining=0 if scheduled else usable,
                    locked=0 if scheduled else locked, unlocks_at=None if scheduled else unlocks,
                    starts_at=starts_at or now, expires_at=expires_at,
                    status="scheduled" if scheduled else "active",
                    source_type=source_type[:24], source_id=source_id[:120], order=order,
                    grant_key=key)
                if not scheduled:
                    n = note or source_id
                    if locked:
                        n = ("%s (+%d locked)" % (n, locked))
                    _write(u, usable, reason, bucket, n, lot, source_type, source_id,
                           grant_key=key)
        except IntegrityError:
            return None                       # a concurrent grant of the same key
        return lot

    if _u is not None:
        return _do(_u)
    with transaction.atomic():
        u = _lock(user)
        lot = _do(u)
    _sync_user(user, u)
    return lot


# ----------------------------------------------------------------- settle
def settle(user, now=None, _u=None):
    """Bring the user's lots up to date under the row lock: reconcile direct
    writes, move whole ad-wallet credits into `rewarded`, grant a due base
    (non-payment) plan month, activate due annual months, unlock staged
    credits, expire ended plan allowance. Idempotent. Returns a small dict."""
    now = now or timezone.now()
    if _u is not None:
        return _settle(_u, now)
    with transaction.atomic():
        u = _lock(user)
        out = _settle(u, now)
    _sync_user(user, u)
    return out


def _settle(u, now):
    from .models import AdWallet, CreditLot
    out = {"base_granted": 0, "unlocked": 0, "expired": 0, "activated": 0, "rewarded": 0}
    _reconcile_cache(u, now)
    # ad wallet -> rewarded bucket (audit #7: the wallet used to write ledger
    # rows without moving the balance)
    w = AdWallet.objects.select_for_update().filter(user=u).first()
    if w is not None and w.balance_paisa >= 100:
        n = int(w.balance_paisa // 100)
        AdWallet.objects.filter(pk=w.pk).update(balance_paisa=F("balance_paisa") - n * 100)
        grant(None, REWARDED, n, reason="rewarded", note="ad wallet", source_type="ad",
              source_id="wallet", now=now, _u=u)
        out["rewarded"] = n
    # plan ended (free now) -> every active plan lot expires (the owner's leak)
    plan_on = _plan_on(u, now)
    if not plan_on:
        ended = _active(u).filter(bucket=PLAN)
        if u.trial_until and u.trial_until > now:
            ended = ended.exclude(source_type="trial")   # trial credits end with the trial
        out["expired"] += _expire_plan(u, now, "plan_ended", lots=ended)
        for lot in CreditLot.objects.filter(user=u, status="scheduled", bucket=PLAN):
            _close(lot, "plan_ended", now)
    # scheduled (annual) months that started
    for lot in CreditLot.objects.filter(user=u, status="scheduled", starts_at__lte=now).order_by("starts_at"):
        if lot.expires_at and lot.expires_at <= now:
            _close(lot, "missed", now)
            continue
        lot.status = "active"
        usable = lot.granted
        if (lot.grant_key or "").endswith(":m0"):
            # the first month of a queued (prepaid, stacked) paid period is a
            # NEW paid period too: staged unlock applies (rule I)
            k = bcfg()
            pct, hours = int(k["unlock_pct"]), int(k["unlock_hours"])
            if hours > 0 and pct < 100:
                usable = lot.granted * pct // 100
                lot.locked = lot.granted - usable
                lot.unlocks_at = now + timedelta(hours=hours)
        lot.remaining = usable
        lot.save(update_fields=["status", "remaining", "locked", "unlocks_at"])
        _write(u, usable, "grant", lot.bucket, "plan month %s" % lot.source_id,
               lot, lot.source_type, lot.source_id, grant_key="act:%s" % lot.grant_key
               if lot.grant_key else None)
        out["activated"] += 1
    # base (non-payment) plan time: owner grant, founder, reviewer
    if plan_on:
        out["base_granted"] = _base_allowance(u, now)
    # staged unlock
    for lot in _active(u).filter(locked__gt=0, unlocks_at__lte=now):
        n = lot.locked
        lot.remaining += n
        lot.locked = 0
        lot.save(update_fields=["remaining", "locked"])
        _write(u, n, "unlock", lot.bucket, "staged unlock", lot, lot.source_type,
               lot.source_id)
        out["unlocked"] += n
    # plan allowance past its paid period
    out["expired"] += _expire_plan(u, now, "period_end", lots=_active(u).filter(
        bucket=PLAN, expires_at__lte=now))
    return out


def _plan_on(u, now):
    from . import plans
    try:
        if plans.lifetime_founder(u):
            return True
        return bool(u.plan_until and u.plan_until > now and (u.plan or "free") != "free")
    except Exception:
        return False


def _paid_coverage(u, now):
    from .models import PlanPeriod
    return PlanPeriod.objects.filter(user=u, status="active", starts_at__lte=now,
                                     ends_at__gt=now).exists()


def _base_allowance(u, now):
    """Plan time that is NOT a payment (owner grant / reviewer / founder):
    one month of allowance at a time, anchored on the previous base month,
    expiring after a month or at plan_until. Never while a paid period runs
    (that one carries its own allowance — no doubling)."""
    from . import plans
    from .models import CreditLot
    if _paid_coverage(u, now):
        return 0
    p = plans.effective_plan(u)
    if p in ("free",):
        return 0
    amount = plan_credits(p)
    if amount <= 0:
        return 0
    from .models import CreditLedger
    last = CreditLot.objects.filter(user=u, bucket=PLAN, source_type__in=("base", "migration")
                                    ).order_by("-starts_at", "-id").first()
    last_start = last.starts_at if last is not None else None
    # a pre-v2 calendar pool (ledger "pool:YYYY-MM", not yet rebuilt into
    # buckets) counts as the last base month too, so it is never doubled
    old_pool = (CreditLedger.objects.filter(user=u, reason="grant", bucket="",
                                            note__startswith="pool:")
                .order_by("-created_at").values_list("created_at", flat=True).first())
    if old_pool and (last_start is None or old_pool > last_start):
        last_start = old_pool
    start = now
    if last_start is not None:
        nxt = add_months(last_start, 1)
        if now < nxt:
            return 0
        if now - nxt < timedelta(days=28):
            start = nxt
    end = add_months(start, 1)
    if u.plan_until and not plans.lifetime_founder(u):
        end = min(end, u.plan_until)
    if end <= now:
        return 0
    key = "base:%d:%s" % (u.pk, start.strftime("%Y%m%d%H%M%S"))
    lot = grant(None, PLAN, amount, reason="grant", note="plan month (%s, no payment)" % p,
                source_type="base", source_id="base:%s" % p, key=key, expires_at=end,
                starts_at=start, now=now, _u=u)
    return amount if lot else 0


def _expire_plan(u, now, why, lots):
    n = 0
    for lot in lots.select_for_update():
        if lot.locked:
            _write(u, 0, "expire", lot.bucket, "%d locked credits cancelled (%s)" % (lot.locked, why),
                   lot, lot.source_type, lot.source_id)
            lot.locked = 0
        if lot.remaining > 0:
            take = lot.remaining
            lot.remaining = 0
            _write(u, -take, "expire", lot.bucket, "unused plan allowance (%s)" % why,
                   lot, lot.source_type, lot.source_id)
            n += take
        _close(lot, why, now)
    return n


def _reconcile_cache(u, now):
    """Keep sum(active lots) == User.ai_credits when legacy code (or a test)
    wrote the balance directly. No ledger row: the direct writer wrote one."""
    from .models import CreditLot
    bal = int(u.ai_credits or 0)
    tot = _active(u).aggregate(s=Sum("remaining"))["s"] or 0
    gap = bal - int(tot)
    if gap == 0:
        return
    if gap > 0:
        debt = _active(u).filter(bucket=DEBT).first()
        if debt is not None and debt.remaining < 0:
            pay = min(gap, -debt.remaining)
            debt.remaining += pay
            debt.save(update_fields=["remaining"])
            gap -= pay
        if gap > 0:
            lot = _active(u).filter(bucket=LEGACY).first()
            if lot is None:
                CreditLot.objects.create(user=u, bucket=LEGACY, granted=gap, remaining=gap,
                                         starts_at=now, source_type="legacy",
                                         source_id="pre-buckets balance")
            else:
                lot.granted += gap
                lot.remaining += gap
                lot.save(update_fields=["granted", "remaining"])
        return
    need = -gap
    for lot in _spend_order(_active(u).filter(remaining__gt=0).select_for_update()):
        take = min(lot.remaining, need)
        lot.remaining -= take
        lot.spent += take
        lot.save(update_fields=["remaining", "spent"])
        need -= take
        if need == 0:
            break
    if need:
        d = _debt_lot(u, now)
        d.remaining -= need
        d.save(update_fields=["remaining"])


# ----------------------------------------------------------------- spend
def spend(user, need, note="", now=None, source_type="spend", _u=None):
    """ATOMIC spend of `need` credits in the owner's order. Returns
    {ok, reason, charged, balance, spend_ref}. A negative balance blocks every
    credit feature (rule L). One ledger row per lot touched, all sharing the
    spend_ref (so a failed call can be returned to the same lots)."""
    now = now or timezone.now()
    need = int(need or 0)

    def _do(u):
        _settle(u, now)
        bal = int(u.ai_credits or 0)
        if need <= 0:
            return {"ok": True, "reason": "ok", "charged": 0, "balance": bal, "spend_ref": ""}
        if bal < need:
            return {"ok": False, "reason": "insufficient", "charged": 0, "balance": bal,
                    "negative": bal < 0, "spend_ref": ""}
        ref = "sp:" + uuid.uuid4().hex[:20]
        left = need
        for lot in _spend_order(_active(u).filter(remaining__gt=0).select_for_update()):
            take = min(lot.remaining, left)
            lot.remaining -= take
            lot.spent += take
            lot.save(update_fields=["remaining", "spent"])
            _write(u, -take, "consume", lot.bucket, note, lot, source_type, ref)
            left -= take
            if left == 0:
                break
        if left:   # cannot happen after _reconcile_cache; stay honest anyway
            raise RuntimeError("credit lots out of sync")
        return {"ok": True, "reason": "ok", "charged": need, "balance": int(u.ai_credits),
                "spend_ref": ref}

    if _u is not None:
        return _do(_u)
    with transaction.atomic():
        u = _lock(user)
        res = _do(u)
    _sync_user(user, u)
    return res


def return_spend(user, spend_ref, note="returned", now=None):
    """Return a spend to the SAME lots it came from (rule N). Idempotent per
    spend_ref. A lot that closed meanwhile (expired plan month) is not
    revived: that part is written as a 0 row for the audit. Returns credits
    returned."""
    from .models import CreditLedger
    now = now or timezone.now()
    if not spend_ref:
        return 0
    with transaction.atomic():
        u = _lock(user)
        rows = list(CreditLedger.objects.filter(user=u, reason="consume", source_id=spend_ref)
                    .select_related("lot"))
        if not rows or CreditLedger.objects.filter(grant_key="ret:" + spend_ref).exists():
            return 0
        back = 0
        first = True
        for r in rows:
            n = -int(r.delta)
            lot = r.lot
            key = ("ret:" + spend_ref) if first else None
            first = False
            if lot is not None and lot.status == "active":
                lot.remaining += n
                lot.spent = max(0, lot.spent - n)
                lot.save(update_fields=["remaining", "spent"])
                _write(u, n, "return", lot.bucket, note, lot, "return", spend_ref, grant_key=key)
                back += n
            else:
                _write(u, 0, "return", r.bucket, "%s (lot closed, %d not returned)" % (note, n),
                       lot, "return", spend_ref, grant_key=key)
    _sync_user(user, u)
    return back


def last_spend_ref(user, amount, within_s=900, now=None):
    """The newest not-yet-returned spend of exactly `amount` credits (the
    fallback for callers that refund without passing spend_ref)."""
    from .models import CreditLedger
    now = now or timezone.now()
    since = now - timedelta(seconds=within_s)
    refs = []
    for r in (CreditLedger.objects.filter(user=user, reason="consume", source_type="spend",
                                          created_at__gte=since)
              .order_by("-created_at", "-id").values("source_id", "delta")[:60]):
        if r["source_id"] not in refs:
            refs.append(r["source_id"])
    for ref in refs:
        if CreditLedger.objects.filter(grant_key="ret:" + ref).exists():
            continue
        tot = CreditLedger.objects.filter(user=user, reason="consume",
                                          source_id=ref).aggregate(s=Sum("delta"))["s"] or 0
        if -int(tot) == int(amount):
            return ref
    return ""


# ----------------------------------------------------------------- plan / order ends
def expire_source(user, *, source_prefix="", order=None, why="ended", now=None):
    """End the plan allowance of one source (a token's orders, one order):
    unused credits expire with ledger rows, future annual months are closed.
    Returns credits expired."""
    from .models import CreditLot
    now = now or timezone.now()
    if user is None:
        return 0
    with transaction.atomic():
        u = _lock(user)
        qs = CreditLot.objects.filter(user=u, bucket=PLAN)
        if order is not None:
            qs = qs.filter(order=order)
        elif source_prefix:
            qs = qs.filter(source_id__startswith=source_prefix)
        else:
            return 0
        n = _expire_plan(u, now, why, qs.filter(status="active"))
        for lot in qs.filter(status="scheduled"):
            _close(lot, why, now)
    _sync_user(user, u)
    return n


def revoke_order(order, *, why, debt, refund_reason="revoke", now=None):
    """A refunded / voided order: remove every credit it granted (see
    revoke_lots). Returns {"removed": n, "debt": d}."""
    from .models import CreditLot
    if order is None or order.user_id is None:
        return {"removed": 0, "debt": 0}
    return revoke_lots(order.user, CreditLot.objects.filter(order=order), why=why, debt=debt,
                       refund_reason=refund_reason,
                       debt_key="debt:%s:%s" % (order.channel, order.order_id),
                       source_id=order.order_id, now=now)


def revoke_lots(user, lots, *, why, debt, refund_reason="revoke", debt_key="",
                source_id="", now=None):
    """Unused credits leave with `revoke` / `refund` rows; locked parts and
    future annual months are cancelled; with `debt` (Google gave the money
    back for credits already spent) the spent part is written as a negative
    balance in the `debt` bucket, so every credit feature stays blocked until
    the balance is back to zero (rule L). Idempotent (debt_key unique)."""
    from .models import CreditLedger
    now = now or timezone.now()
    out = {"removed": 0, "debt": 0}
    with transaction.atomic():
        u = _lock(user)
        _settle(u, now)
        all_lots = list(lots.select_for_update().order_by("id"))
        for lot in all_lots:
            if lot.status == "closed":
                continue
            if lot.status == "scheduled":
                _close(lot, why, now)
                continue
            if lot.locked:
                _write(u, 0, refund_reason, lot.bucket,
                       "%d locked credits cancelled (%s)" % (lot.locked, why),
                       lot, "order", source_id or lot.source_id)
                lot.locked = 0
            if lot.remaining > 0:
                n = lot.remaining
                lot.remaining = 0
                _write(u, -n, refund_reason, lot.bucket, "%s: unused credits removed" % why,
                       lot, "order", source_id or lot.source_id)
                out["removed"] += n
            _close(lot, why, now)
        if debt:
            spent = sum(int(l.spent) for l in all_lots)
            if spent > 0 and debt_key and not CreditLedger.objects.filter(grant_key=debt_key).exists():
                out["debt"] = _add_debt(u, spent, why, debt_key, source_id, now)
    _sync_user(user, u)
    return out


def _add_debt(u, n, why, key, source_id, now):
    d = _debt_lot(u, now)
    d.remaining -= n
    d.granted -= n
    d.save(update_fields=["remaining", "granted"])
    _write(u, -n, "revoke", DEBT, "%s: %d credits already spent were refunded" % (why, n),
           d, "order", source_id, grant_key=key)
    return n


def revoke_amount(user, amount, *, why, debt, key, now=None):
    """Refund of a pre-buckets purchase (no lots of its own): take `amount`
    off in spend order; with `debt` what cannot be taken goes negative."""
    from .models import CreditLedger
    now = now or timezone.now()
    amount = int(amount or 0)
    if amount <= 0 or CreditLedger.objects.filter(grant_key=key).exists():
        return 0
    with transaction.atomic():
        u = _lock(user)
        _settle(u, now)
        left = amount
        first = True
        for lot in _spend_order(_active(u).filter(remaining__gt=0).select_for_update()):
            if left <= 0:
                break
            t = min(lot.remaining, left)
            lot.remaining -= t
            lot.save(update_fields=["remaining"])
            _write(u, -t, "revoke", lot.bucket, "%s: credits removed" % why, lot, "order", key,
                   grant_key=key if first else None)
            first = False
            left -= t
        if left and debt:
            _add_debt(u, left, why, key if first else key + ":d", key, now)
            left = 0
    _sync_user(user, u)
    return amount - left


def owner_adjust(user, delta, note, actor=None, now=None):
    """Owner correction: +delta lands in `free`; -delta comes off in spend
    order and may not take the balance below zero."""
    now = now or timezone.now()
    delta = int(delta)
    if delta > 0:
        grant(user, FREE, delta, reason="adjust", note=note, source_type="owner",
              source_id="owner:%s" % (getattr(actor, "pk", "") or ""), now=now)
        return int(user.ai_credits or 0)
    with transaction.atomic():
        u = _lock(user)
        _settle(u, now)
        take = min(max(0, int(u.ai_credits or 0)), -delta)
        left = take
        for lot in _spend_order(_active(u).filter(remaining__gt=0).select_for_update()):
            if left <= 0:
                break
            t = min(lot.remaining, left)
            lot.remaining -= t
            lot.save(update_fields=["remaining"])
            _write(u, -t, "adjust", lot.bucket, note, lot, "owner",
                   "owner:%s" % (getattr(actor, "pk", "") or ""))
            left -= t
    _sync_user(user, u)
    return int(u.ai_credits or 0)


# ----------------------------------------------------------------- read model
def buckets(user, now=None):
    """{bucket: remaining} for the active lots (debt negative)."""
    from .models import CreditLot
    out = {b: 0 for b in BUCKETS}
    out[DEBT] = 0
    for r in (CreditLot.objects.filter(user=user, status="active").values("bucket")
              .annotate(s=Sum("remaining"))):
        out[r["bucket"]] = int(r["s"] or 0)
    return out


def state(user, now=None):
    """GET /credits/state — what the app's Plan & credits screen shows:
    {balance, now_usable, locked, unlocks_at, ...} (rule I contract)."""
    from .models import CreditAccount, CreditLot
    now = now or timezone.now()
    settle(user, now)
    user.refresh_from_db(fields=["ai_credits", "plan", "plan_until"])
    bal = int(user.ai_credits or 0)
    locked_lots = CreditLot.objects.filter(user=user, status="active", locked__gt=0)
    locked = int(locked_lots.aggregate(s=Sum("locked"))["s"] or 0)
    nxt = locked_lots.order_by("unlocks_at").first()
    plan_lot = CreditLot.objects.filter(user=user, status="active", bucket=PLAN).order_by(
        "expires_at").first()
    acct = CreditAccount.objects.filter(user=user).first()
    k = bcfg()
    return {
        "balance": bal,
        "now_usable": max(0, bal),
        "locked": locked,
        "unlocks_at": nxt.unlocks_at.isoformat() if nxt and nxt.unlocks_at else None,
        "negative": bal < 0,
        "blocked": bal < 0,
        "purchase_blocked": bool(acct and acct.purchase_blocked),
        "buckets": buckets(user, now),
        "plan_expires_at": plan_lot.expires_at.isoformat() if plan_lot and plan_lot.expires_at else None,
        "unlock_pct": int(k["unlock_pct"]), "unlock_hours": int(k["unlock_hours"]),
        "refund_window_hours": int(k["refund_window_hours"]),
        "server_time": now.isoformat(),
    }


def verify(user):
    """Invariant check for one user (rule A)."""
    from .models import CreditLedger
    led = int(CreditLedger.objects.filter(user=user).aggregate(s=Sum("delta"))["s"] or 0)
    lots = int(_active(user).aggregate(s=Sum("remaining"))["s"] or 0)
    bal = int(type(user).objects.filter(pk=user.pk).values_list("ai_credits", flat=True)[0] or 0)
    return {"user": user.pk, "balance": bal, "ledger_sum": led, "lots_sum": lots,
            "ok": bal == led == lots, "ledger_ok": bal == led}


def settle_all(now=None, limit=None):
    """Daily / hourly safety job: settle every user with something due
    (unlock, expiry, scheduled month, base plan time)."""
    from django.db.models import Q
    from .models import CreditLot, User
    now = now or timezone.now()
    ids = set(CreditLot.objects.filter(
        Q(status="active", locked__gt=0, unlocks_at__lte=now)
        | Q(status="active", bucket=PLAN, expires_at__lte=now)
        | Q(status="scheduled", starts_at__lte=now)).values_list("user_id", flat=True))
    ids |= set(CreditLot.objects.filter(status__in=("active", "scheduled"), bucket=PLAN)
               .values_list("user_id", flat=True))
    ids |= set(User.objects.filter(Q(plan_until__gt=now) | Q(is_founder=True))
               .values_list("pk", flat=True))
    n = 0
    for u in User.objects.filter(pk__in=ids)[:limit]:
        try:
            settle(u, now)
            n += 1
        except Exception:
            pass
    return n
