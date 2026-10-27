"""billing-v2 rule V — rebuild the credit buckets of pre-v2 balances from the
ledger (audit option 1). Used by `manage.py credits_rebuild_buckets`.

For each user, the OLD ledger rows (bucket "") are replayed in time order:
  pool:YYYY-MM grants  -> plan allowance, expiring at the end of that month
                          or when the plan that covered it ended, if earlier
  trial                -> plan allowance (source trial), expiring at trial_until
  founding / other     -> free;  referral:* -> referral;  topup -> pack
  rewarded / ad_*      -> rewarded (wallet-only ad rows are moved out of the
                          ad wallet so the balance finally equals the ledger)
  consume / ad_spend   -> spent in the owner's order (plan -> free/rewarded
                          /referral -> pack), after expiring ended plan lots
  expire / -adjust     -> plan (or pack for a pack refund) first
Then every plan lot whose period has ended expires. The `legacy` lot is
replaced by the rebuilt lots and ONE adjust ledger row writes the difference,
so afterwards balance == ledger sum == lots. Idempotent (one migration row
per user). Nothing is deleted.
"""
from datetime import datetime, timedelta

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

ORDER = {"plan": 0, "free": 1, "rewarded": 1, "referral": 1, "pack": 2}
KEY = "migr:billing_v2:%d"


def _month_end(ym):
    from zoneinfo import ZoneInfo
    y, m = int(ym[:4]), int(ym[5:7])
    y2, m2 = (y + 1, 1) if m == 12 else (y, m + 1)
    return datetime(y2, m2, 1, tzinfo=ZoneInfo("Asia/Dhaka"))


def _coverage_end(user, t, periods, now):
    ends = [p.ends_at for p in periods if p.starts_at <= t < p.ends_at]
    if ends:
        return max(ends)
    from . import plans
    if plans.lifetime_founder(user):
        return None
    if user.plan_until and user.plan_until > t and (user.plan or "free") != "free":
        return user.plan_until
    return t


def _bucket_of(r, user):
    note = r.note or ""
    if r.reason == "grant" and note.startswith("pool:"):
        return "plan"
    if r.reason == "trial":
        return "plan" if user.trial_until else "free"
    if r.reason == "topup":
        return "pack"
    if r.reason in ("rewarded", "ad_appopen", "ad_interstitial"):
        return "rewarded"
    if note.startswith("referral"):
        return "referral"
    return "free"


def _wallet_only(r):
    note = r.note or ""
    if r.reason in ("ad_appopen", "ad_interstitial", "ad_spend"):
        return True
    return r.reason == "rewarded" and note.startswith("ad:") and not note.endswith(":paid")


def plan_for(user, now=None):
    """The rebuild of one user, without writing. Returns a dict."""
    from .models import CreditLedger, CreditLot, PlanPeriod
    from . import credits as CR
    now = now or timezone.now()
    rows = list(CreditLedger.objects.filter(user=user).order_by("created_at", "id"))
    pre = [r for r in rows if not r.bucket]
    periods = list(PlanPeriod.objects.filter(user=user))
    lots = []
    wallet_net = 0
    last_spent = []

    def expire_due(t):
        for l in lots:
            if l["bucket"] == "plan" and l["exp"] is not None and l["exp"] <= t and l["amt"] > 0:
                l["expired"] += l["amt"]
                l["amt"] = 0

    def take(n, prefer=None):
        order = sorted([l for l in lots if l["amt"] > 0],
                       key=lambda l: (0 if prefer and l["bucket"] == prefer else 1,
                                      ORDER[l["bucket"]], l["exp"] or datetime.max.replace(tzinfo=now.tzinfo),
                                      l["i"]))
        got = []
        for l in order:
            if n <= 0:
                break
            t = min(l["amt"], n)
            l["amt"] -= t
            n -= t
            got.append((l, t))
        return got, n

    unmatched = 0
    for r in pre:
        expire_due(r.created_at)
        if _wallet_only(r):
            wallet_net += int(r.delta)
        if r.delta > 0:
            if r.reason == "adjust" and "refund" in (r.note or "").lower() and last_spent:
                left = int(r.delta)
                for l, t in reversed(last_spent):
                    back = min(t, left)
                    l["amt"] += back
                    left -= back
                    if left <= 0:
                        break
                last_spent = []
                if left <= 0:
                    continue
                delta = left
            else:
                delta = int(r.delta)
            b = _bucket_of(r, user)
            exp = None
            src = (r.note or r.reason)[:60]
            if b == "plan" and r.reason == "trial":
                exp = user.trial_until
                src = "trial"
            elif b == "plan":
                exp = _month_end((r.note or "pool:")[5:12]) if len(r.note or "") >= 12 else None
                cov = _coverage_end(user, r.created_at, periods, now)
                if cov is not None:
                    exp = min(exp, cov) if exp else cov
            lots.append({"i": len(lots), "bucket": b, "amt": delta, "granted": delta, "exp": exp,
                         "start": r.created_at, "src": src, "expired": 0})
        elif r.delta < 0:
            n = -int(r.delta)
            prefer = None
            if r.reason == "expire":
                prefer = "pack" if (r.note or "").startswith("pack:") else "plan"
            elif r.reason == "adjust" and "pack" in (r.note or ""):
                prefer = "pack"
            got, miss = take(n, prefer)
            last_spent = got if r.reason in ("consume", "ad_spend") else []
            unmatched += miss
    # post-v2 spends that came out of the temporary legacy lot
    legacy_spent = -int(sum(int(r.delta) for r in rows
                            if r.bucket == CR.LEGACY and r.delta < 0) or 0)
    if legacy_spent:
        _g, miss = take(legacy_spent)
        unmatched += miss
    expire_due(now)
    expired = sum(l["expired"] for l in lots)
    rebuilt = {b: 0 for b in ORDER}
    for l in lots:
        rebuilt[l["bucket"]] += l["amt"]
    other = int(CreditLot.objects.filter(user=user, status="active").exclude(
        bucket__in=(CR.LEGACY,)).aggregate(s=Sum("remaining"))["s"] or 0)
    ledger_sum = int(sum(int(r.delta) for r in rows))
    if not pre:
        # no pre-v2 history: whatever balance is not in a v2 lot was written
        # without a ledger row (old direct writes) -> free bucket
        gap = max(0, int(user.ai_credits or 0) - other)
        if gap:
            lots.append({"i": len(lots), "bucket": "free", "amt": gap, "granted": gap,
                         "exp": None, "start": now, "src": "unledgered balance", "expired": 0})
            rebuilt["free"] += gap
    target = other + sum(rebuilt.values())
    return {"user": user.pk, "balance": int(user.ai_credits or 0), "ledger_sum": ledger_sum,
            "wallet_only": wallet_net, "expired_plan": expired, "unmatched_spend": unmatched,
            "buckets": rebuilt, "other_lots": other, "target": target,
            "adjust": target - ledger_sum, "lots": lots,
            "done": CreditLedger.objects.filter(grant_key=KEY % user.pk).exists()}


def apply(user, plan, now=None):
    """Write one user's rebuild (inside one transaction)."""
    from .models import AdWallet, CreditLedger, CreditLot, User
    from . import credits as CR
    now = now or timezone.now()
    with transaction.atomic():
        u = CR._lock(user)
        if CreditLedger.objects.filter(grant_key=KEY % u.pk).exists():
            return False
        for lot in CreditLot.objects.filter(user=u, status="active", bucket=CR.LEGACY):
            lot.remaining = 0
            CR._close(lot, "rebuilt", now)
        for l in plan["lots"]:
            if l["amt"] <= 0:
                continue
            CreditLot.objects.create(
                user=u, bucket=l["bucket"], granted=l["granted"], remaining=l["amt"],
                spent=max(0, l["granted"] - l["amt"] - l["expired"]), starts_at=l["start"],
                expires_at=l["exp"], source_type="trial" if l["src"] == "trial" else "migration",
                source_id=("migr:%s" % l["src"])[:120],
                grant_key="migr:%d:%d" % (u.pk, l["i"]))
        if plan["wallet_only"] > 0:
            w = AdWallet.objects.select_for_update().filter(user=u).first()
            if w is not None:
                n = min(plan["wallet_only"], int(w.balance_paisa // 100))
                AdWallet.objects.filter(pk=w.pk).update(balance_paisa=w.balance_paisa - n * 100)
        target = plan["target"]
        User.objects.filter(pk=u.pk).update(ai_credits=target)
        u.ai_credits = target
        bits = []
        if plan["expired_plan"]:
            bits.append("expired plan allowance %d" % plan["expired_plan"])
        if plan["wallet_only"]:
            bits.append("ad wallet credits %d moved into the balance" % plan["wallet_only"])
        CreditLedger.objects.create(
            user=u, delta=plan["adjust"], reason="adjust",
            bucket="plan" if plan["expired_plan"] and plan["adjust"] == -plan["expired_plan"] else "",
            note=("billing v2 bucket rebuild: " + (", ".join(bits) or "no change"))[:120],
            source_type="migration", source_id="billing_v2", grant_key=KEY % u.pk,
            balance_after=target)
    return True
