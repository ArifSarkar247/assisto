"""
billing.py — the ONE accessor costly endpoints import to charge AI credits.

Business Model, Build 1 of N (plan: .phaseB/BUSINESS_MODEL_PLAN.md). This wraps
the pure `core.logic.pricing` engine + the `PricingConfig` row with the stateful
pieces pricing.py (correctly) refuses to touch: the DB, the clock, and the atomic
debit of `User.ai_credits`.

What lives here:
  * get_config() / cfg()  — load+normalize the single PricingConfig row (seeding
    the shipped defaults once if the row is missing).
  * charge(user, action, qty=1) -> {ok, reason, charged, balance}
      ATOMIC debit (select_for_update + F()) against User.ai_credits + one
      CreditLedger row. Fixes the pre-existing non-atomic double-spend race in
      plans.consume_credit. NEVER lets the balance go negative; one ledger row
      per charge so a double-call can't double-spend.
  * guard_can(user, action, qty=1) -> (allowed, reason)
      the same decision WITHOUT debiting (pre-flight check).
  * SAFETY_EXEMPT — the hard allow-list of life-safety actions that are NEVER
    charged and NEVER blocked. Asserted by a test per the plan's load-bearing
    safety note.

Prices are SERVER-AUTHORITATIVE: the client never decides what it costs.
"""
from datetime import timedelta

from django.db import transaction
from django.db.models import F, Sum
from django.utils import timezone

from .logic import pricing
from .logic import profit_guard as PG

# --------------------------------------------------------------- safety allow-list
# These actions are life-safety / account-critical and are NEVER charged and NEVER
# blocked — not by credits, not by the ad wallet (Build 3), not by Profit Guard
# (Build 4). A missing entry could block an SOS, so this set is load-bearing and
# pinned by a test. Keys are action ids OR feature prefixes checked by is_exempt().
SAFETY_EXEMPT = frozenset({
    "sos", "safe_journey", "anti_theft", "health", "elderly",
    "payment", "login",
})


def flag_on(flag_id, default=True):
    """Read an owner kill-switch from AdminFlagState (Build 2 global kill-switch
    reuse). Missing row/flag -> the catalog default. Never raises."""
    try:
        from .models import AdminFlagState
        from .logic import admin_flags as AF
        row = AdminFlagState.objects.filter(key="global").first()
        state = AF.normalize_state(row.state if row else {})
        return bool(state.get(flag_id, default))
    except Exception:
        return default


def is_exempt(action):
    """True if `action` is on the safety allow-list (exact id or <prefix>_...)."""
    if not action:
        return False
    a = str(action)
    if a in SAFETY_EXEMPT:
        return True
    # e.g. "sos_sms", "health_reminder", "payment_bkash", "login_otp" — and the
    # multi-word keys too ("anti_theft_alert", "safe_journey_sos"), which a
    # first-segment split used to miss.
    return any(a.startswith(k + "_") for k in SAFETY_EXEMPT)


# --------------------------------------------------------------- config accessor

def get_config():
    """Return the single PricingConfig row, creating it seeded with the shipped
    defaults on first access (idempotent). The returned row's `.data` is the raw
    stored dict — use cfg() when you want the normalized view."""
    from .models import PricingConfig
    row, created = PricingConfig.objects.get_or_create(key="global")
    if created or not row.data:
        row.data = pricing.DEFAULTS()
        row.save(update_fields=["data", "updated_at"])
    return row


def cfg():
    """The normalized pricing config dict (defaults filled)."""
    return pricing.normalize(get_config().data)


def _has_unlimited(user):
    """Owner decision (2026-10): NOTHING is unlimited in any plan — Premium is
    90 credits/month, Business 240, and every AI action debits credits. Kept
    as a function (always False) so existing call sites stay readable;
    safety-exempt actions are still free via is_exempt(), not via this."""
    return False


# --------------------------------------------------------------- monthly pool

POOL_NOTE = "pool:"          # CreditLedger(reason="grant").note prefix


def monthly_pool_credits(user):
    """The monthly included credit pool this user is entitled to RIGHT NOW.

    * paid plans in PricingConfig (premium / business) -> that plan's credits;
    * annual / founder / probashi (Premium-equivalent, not config rows) -> the
      Premium pool;
    * free users and trial-only users -> 0 (free earns via ads/packs; the
      trial has its own trial_credits grant)."""
    from . import plans
    if user is None:
        return 0
    try:
        if not plans.plan_active(user):
            return 0
        p = plans.effective_plan(user)
        if p == "free":
            return 0
        if p == "probashi":     # probashi-plan: the family's shared pool
            from . import credits as CR
            return CR.plan_credits(p)
        c = cfg()
        row = c["plans"].get(p) or c["plans"]["premium"]
        return max(0, int(row["credits"]))
    except Exception:
        return 0


def grant_monthly_pool(user, now=None):
    """billing-v2: plan allowance follows the PAID PERIOD (core.credits), not
    calendar months. Paid Play / EPS periods grant their own allowance when
    the payment is verified; plan time that is NOT a payment (owner grant,
    reviewer, founder) gets one month at a time here. Settles the user's
    lots (unlock / expiry) and returns the base-month credits granted now."""
    from . import credits as CR
    if user is None or not getattr(user, "pk", None):
        return 0
    return int(CR.settle(user, now=now).get("base_granted", 0))


def ensure_monthly_pool(user):
    """Best-effort wrapper used on the hot paths (charge, /me, usage) — never
    raises, never blocks the caller."""
    try:
        if user is not None and getattr(user, "pk", None):
            return grant_monthly_pool(user)
    except Exception:
        pass
    return 0


def grant_all_monthly_pools(now=None):
    """Daily safety sweep: settle every user with something due (staged
    unlocks, expiries even when an RTDN was missed, annual months, base plan
    months). Returns users settled."""
    from . import credits as CR
    return CR.settle_all(now=now)


def _is_free(user):
    """True when the user's EFFECTIVE plan is the free tier (the only tier the
    ad wallet and the profit guard apply to)."""
    from . import plans
    try:
        return plans.effective_plan(user) == "free"
    except Exception:
        return False


# --------------------------------------------------------------- ad wallet

def get_ad_wallet(user):
    from .models import AdWallet
    w, _ = AdWallet.objects.get_or_create(user=user)
    return w


def ad_wallet_credits(user):
    """Rewarded-ad credits the user can spend: billing-v2 moves every whole
    ad credit into the `rewarded` bucket (part of the balance), so this is
    that bucket plus any whole credit still waiting in the wallet."""
    if user is None:
        return 0
    from . import credits as CR
    try:
        b = CR.buckets(user).get(CR.REWARDED, 0)
    except Exception:
        b = 0
    return int(b) + get_ad_wallet(user).spendable_credits()


# --------------------------------------------------------------- storage (Build 3)

def storage_quota_bytes(user):
    """The user's storage quota (bytes) from their EFFECTIVE plan via PricingConfig
    (Free 1GB / Premium 5GB / Business 15GB). Plans not in config (founder/annual/
    probashi) fall back to the Premium quota so a paid user is never squeezed
    below Premium. Never raises."""
    from . import plans
    try:
        c = cfg()
        p = plans.effective_plan(user)
        q = pricing.storage_quota_bytes(p, c)
        if q > 0:
            return int(q)
        # founder / annual / probashi etc. -> at least the Premium quota
        return int(pricing.storage_quota_bytes("premium", c))
    except Exception:
        return int(1024 ** 3)   # safe default: 1 GB


def _storage_row(user):
    from .models import StorageUsage
    row, _ = StorageUsage.objects.get_or_create(user=user)
    return row


def storage_state(user):
    """The always-visible storage meter for `user`:
        {used, quota_bytes, pct, full}
    `used` is the retained-media byte total; `quota_bytes` from the plan; `pct`
    is 0..100 (int); `full` is True when used >= quota. Never raises."""
    quota = storage_quota_bytes(user)
    used = 0
    try:
        if user is not None:
            used = int(_storage_row(user).used_bytes or 0)
    except Exception:
        used = 0
    used = max(0, used)
    pct = 0
    if quota > 0:
        pct = min(100, int(round(used * 100.0 / quota)))
    return {"used": used, "quota_bytes": int(quota), "pct": pct,
            "full": quota > 0 and used >= quota}


def add_storage(user, delta_bytes):
    """Atomically add `delta_bytes` (may be negative on delete/expiry) to the
    user's retained-media total; clamped at >= 0. Returns the new storage_state.
    Called AFTER a media upload is accepted, and with a negative delta by the
    status-expiry / purge sweep when delivered media is pruned."""
    from .models import StorageUsage
    if user is None:
        return storage_state(user)
    delta = int(delta_bytes or 0)
    with transaction.atomic():
        row = StorageUsage.objects.select_for_update().get_or_create(user=user)[0]
        new_used = max(0, int(row.used_bytes or 0) + delta)
        StorageUsage.objects.filter(pk=row.pk).update(used_bytes=new_used)
    return storage_state(user)


# --------------------------------------------------------------- daily ledger (P&L)

def _today_ledger():
    """Today's DailyLedger row (Asia/Dhaka local date), created empty if absent."""
    from .models import DailyLedger
    row, _ = DailyLedger.objects.get_or_create(
        date=timezone.localdate(),
        defaults={"revenue_by_source": {}, "variable_cost_by_type": {}})
    return row


def record_revenue(source, amount_bdt):
    """Add ৳`amount_bdt` to today's revenue under `source`
    ∈ {ads, subs, packs, commissions}. Append-only daily (upsert today's row)."""
    amount = float(amount_bdt or 0)
    if source not in PG.REVENUE_SOURCES or amount <= 0:
        return
    with transaction.atomic():
        row = _today_ledger()
        rev = dict(row.revenue_by_source or {})
        rev[source] = float(rev.get(source, 0) or 0) + amount
        row.revenue_by_source = rev
        row.save(update_fields=["revenue_by_source", "updated_at"])


def record_cost(ctype, amount_bdt):
    """Add ৳`amount_bdt` to today's variable cost under `ctype`
    ∈ {ai, sms, ivr, video, storage}. AI callers convert USD -> ৳ first."""
    amount = float(amount_bdt or 0)
    if ctype not in PG.COST_TYPES or amount <= 0:
        return
    with transaction.atomic():
        row = _today_ledger()
        cost = dict(row.variable_cost_by_type or {})
        cost[ctype] = float(cost.get(ctype, 0) or 0) + amount
        row.variable_cost_by_type = cost
        row.save(update_fields=["variable_cost_by_type", "updated_at"])


def record_ai_cost_usd(usd):
    """Convenience: convert a USD AI spend to ৳ (via cfg.usd_bdt) and record it."""
    try:
        bdt = float(usd or 0) * float(cfg()["usd_bdt"])
        record_cost("ai", bdt)
    except Exception:
        pass


def _trailing_rows(days=7, now=None):
    from .models import DailyLedger
    today = timezone.localdate()
    since = today - timedelta(days=days - 1)
    rows = DailyLedger.objects.filter(date__gte=since, date__lte=today)
    out = [{"date": r.date.isoformat(),
            "revenue_by_source": r.revenue_by_source,
            "variable_cost_by_type": r.variable_cost_by_type} for r in rows]
    return _merge_sponsored(out, since, today)


def _merge_sponsored(rows, since, today):
    """d1-discover: add booked SPONSORED Discover-card revenue (spread over each
    card's run) as the `sponsored` revenue source. Computed from the cards, not
    written into DailyLedger, so editing/deleting a deal never double-counts."""
    try:
        from .views_discover import sponsored_revenue_by_day
        extra = sponsored_revenue_by_day(since, today)
    except Exception:
        extra = {}
    if not extra:
        return rows
    by_date = {r["date"]: r for r in rows}
    for d, amt in extra.items():
        key = d.isoformat()
        r = by_date.get(key)
        if r is None:
            r = {"date": key, "revenue_by_source": {}, "variable_cost_by_type": {}}
            by_date[key] = r
            rows.append(r)
        rev = dict(r.get("revenue_by_source") or {})
        try:
            prev = float(rev.get("sponsored", 0) or 0)
        except (TypeError, ValueError):
            prev = 0.0
        rev["sponsored"] = round(prev + amt, 2)
        r["revenue_by_source"] = rev
    return rows


def guard_state(now=None):
    """The current profit-guard decision from the trailing-7-day DailyLedger,
    using the admin-editable thresholds in PricingConfig (fallback to the
    profit_guard defaults). Returns the profit_guard.guard_state dict."""
    c = cfg()
    pg = c.get("profit_guard") if isinstance(c.get("profit_guard"), dict) else {}
    spend_cap = pg.get("spend_cap_pct", PG.DEFAULT_SPEND_CAP_PCT)
    approach = pg.get("approach_pct", PG.DEFAULT_APPROACH_PCT)
    return PG.guard_state(_trailing_rows(7, now),
                          spend_cap_pct=float(spend_cap),
                          approach_pct=float(approach))


# --------------------------------------------------------------- owner P&L (Build 3)

def verified_paid_orders(now=None):
    """{user_id: plan} of users with a VERIFIED, REAL (non-test) Play or EPS
    subscription payment whose paid period is active now (owner 27 Oct:
    trials, test purchases and owner/system grants are NOT paid)."""
    from .models import PaidOrder, PlanPeriod
    now = now or timezone.now()
    out = {}
    live = set(PlanPeriod.objects.filter(status="active", starts_at__lte=now, ends_at__gt=now)
               .values_list("user_id", flat=True))
    for o in PaidOrder.objects.filter(kind="sub", is_test=False, status="paid",
                                      period_end__gt=now, user_id__in=live).only(
            "user_id", "plan", "period_start"):
        if o.period_start and o.period_start > now:
            continue
        if out.get(o.user_id) != "business":
            out[o.user_id] = "business" if o.plan == "business" else "premium"
    return out


def plan_segment_counts(now=None):
    """Active-user counts for the owner Overview / P&L.

    billing-v2: `paid`, `premium` and `business` count ONLY users with a
    verified real payment whose paid period is active (verified_paid_orders).
    Trials, test purchases and owner/system grants are shown separately and
    counted inside `free` for the P&L (they bring no revenue)."""
    from . import plans
    from .models import PaidOrder, User
    now = now or timezone.now()
    paid = verified_paid_orders(now)
    test_ids = set(PaidOrder.objects.filter(kind="sub", is_test=True, status="paid",
                                            period_end__gt=now)
                   .values_list("user_id", flat=True))
    counts = {"free": 0, "premium": 0, "business": 0, "trial": 0, "test": 0, "grants": 0}
    for u in User.objects.filter(is_active=True).only(
            "plan", "plan_until", "trial_until", "is_founder", "founder_since"):
        seg = paid.get(u.pk)
        if seg:
            counts[seg] += 1
            continue
        counts["free"] += 1
        try:
            eff = plans.effective_plan(u)
        except Exception:
            eff = "free"
        if u.pk in test_ids:
            counts["test"] += 1
        elif eff != "free" and plans.trial_active(u) and not plans.plan_active(u):
            counts["trial"] += 1
        elif eff != "free":
            counts["grants"] += 1
    counts["paid"] = counts["premium"] + counts["business"]
    counts["total"] = counts["free"] + counts["paid"]
    return counts


def _segment_of(user):
    """Map a user's effective plan to a P&L segment {free, premium, business}.
    business stays business; everything paid-but-not-business -> premium."""
    from . import plans
    p = plans.effective_plan(user)
    if p == "business":
        return "business"
    if p == "free":
        return "free"
    return "premium"   # premium / annual / founder / probashi / trial


def margin_per_feature(cfg_dict=None):
    """Margin per feature/action from the config cost table: for each priced
    action, credit face-value (credits * credit_bdt, ৳) vs provider cost (USD ->
    ৳), and the margin ratio. Real config numbers only."""
    c = cfg_dict or cfg()
    credit_bdt = float(c["credit_bdt"])
    usd_bdt = float(c["usd_bdt"])
    out = []
    for aid, row in sorted(c["action_costs"].items()):
        face = float(row["credits"]) * credit_bdt
        cost = float(row["provider_cost"]) * usd_bdt
        margin = None if face <= 0 else round((face - cost) / face, 4)
        out.append({"action": aid, "credits": row["credits"],
                    "charge_bdt": round(face, 4), "provider_cost_bdt": round(cost, 4),
                    "margin": margin})
    return out


def _price_map(c=None):
    """plan -> monthly ৳ price, for analytics.revenue_by_plan (config-authoritative)."""
    c = c or cfg()
    return {pid: row["price"] for pid, row in c["plans"].items()}


def arpu_per_day(c=None, now=None):
    """Current average NET revenue per PAID user per DAY, from REAL inputs: the
    config plan prices (NET of fees) weighted by the live premium/business counts,
    divided by 30 days. 0 when there are no paid users (break-even then reports
    users_needed = null — never a divide-by-zero or an invented figure)."""
    from .logic import pricing as P
    c = c or cfg()
    counts = plan_segment_counts(now)
    paid = counts["premium"] + counts["business"]
    if paid <= 0:
        return 0.0
    monthly_net = (counts["premium"] * P.net_plan_revenue("premium", c) +
                   counts["business"] * P.net_plan_revenue("business", c))
    return (monthly_net / paid) / 30.0


def pnl_dashboard(days=30, now=None):
    """The owner P&L dashboard payload for GET /admin/pnl.

    Real numbers only: the daily P&L series comes straight from DailyLedger; the
    break-even line is computed from live paid-user counts + config-derived ARPU;
    margins come from the config cost table and the analytics revenue-by-plan."""
    c = cfg()
    fixed = float(c["fixed_cost_per_day"])
    rows = _trailing_rows(max(1, int(days or 30)), now)
    series = PG.pnl_series(rows, fixed)
    counts = plan_segment_counts(now)
    arpu = arpu_per_day(c, now)
    be = PG.break_even(rows, fixed, counts["paid"], arpu,
                       ad_rev_per_day=None)
    guard = guard_state(now)
    # recent cost kill-switch / guard alerts the owner should see
    alerts = _recent_cost_alerts()
    return {
        "days": days,
        "fixed_cost_per_day": round(fixed, 2),
        "series": series["days"],
        "totals": series["totals"],
        "segments": counts,
        "margin_per_feature": margin_per_feature(c),
        "revenue_by_plan_prices": _price_map(c),
        "break_even": be,
        "guard": guard,
        "alerts": alerts,
        "sponsored": _sponsored_summary(rows),
        # ps1-photo: Photo Studio ad revenue vs cost, per day per feature
        "photo_studio": _photo_studio_stats(days),
        # pay1: gross / fee / refunds / NET per payment channel
        "payments_by_channel": _payments_by_channel(days),
    }


def _payments_by_channel(days):
    try:
        from .payments import service
        r = service.channel_pnl(days)
        return {ch: {k: (float(v) if not isinstance(v, int) else v) for k, v in row.items()}
                for ch, row in r["channels"].items()}
    except Exception:
        return {}


def _sponsored_summary(rows):
    """d1-discover: the sponsored-card revenue line of the P&L period."""
    total = 0.0
    for r in rows or []:
        try:
            total += float((r.get("revenue_by_source") or {}).get("sponsored", 0) or 0)
        except (TypeError, ValueError):
            pass
    return {"total": round(total, 2)}


def _photo_studio_stats(days):
    try:
        from . import photo_studio_service
        return photo_studio_service.owner_stats(days)
    except Exception:
        return {"days": [], "features": [], "totals": {}}


def _recent_cost_alerts(limit=20):
    """Recent owner-facing cost alerts (profit-guard FamilyAlert rows). Honest:
    returns [] when none exist — never fabricated."""
    try:
        from .models import FamilyAlert
        rows = FamilyAlert.objects.filter(kind="cost_guard").order_by("-id")[:limit]
        return [{"title": r.title, "body": getattr(r, "body", ""),
                 "at": r.created_at.isoformat() if getattr(r, "created_at", None)
                 else None} for r in rows]
    except Exception:
        return []


def usage_summary(user, now=None):
    """GET /me/usage-summary — the signed-in user's own credit + storage picture:
    balance, included monthly pool (from plan), this-month spend by action, and
    the storage meter. Complements /credits/history (which is the ledger view)."""
    from .models import CreditLedger
    now = now or timezone.now()
    ensure_monthly_pool(user)
    c = cfg()
    from . import plans
    plan_id = plans.effective_plan(user)
    pool = 0
    prow = c["plans"].get(plan_id)
    if prow is not None:
        pool = int(prow["credits"])
    elif plan_id == "probashi":         # probashi-plan: shared family pool
        pool = int(c["probashi_plan"]["pool_credits"])
    elif plan_id in ("annual", "founder"):
        pool = int(c["plans"]["premium"]["credits"])
    # this calendar month's consumption grouped by action (the ledger note)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    by_action = {}
    rows = CreditLedger.objects.filter(
        user=user, delta__lt=0, created_at__gte=month_start)
    for r in rows:
        key = r.note or r.reason
        by_action[key] = by_action.get(key, 0) + (-int(r.delta))
    usage = [{"action": k, "credits": v}
             for k, v in sorted(by_action.items(), key=lambda kv: -kv[1])]
    return {
        "plan": plan_id,
        "balance": int(getattr(user, "ai_credits", 0) or 0),
        "ad_wallet_credits": ad_wallet_credits(user) if _is_free(user) else 0,
        "included_pool": pool,
        "unlimited_ai": _has_unlimited(user),
        "month_usage": usage,
        "month_total": sum(u["credits"] for u in usage),
        "storage": storage_state(user),
    }


def effective_tier(user, requested_tier):
    """AI model-downgrade hook. When a FREE user's action runs while the profit
    guard is 'near', step the requested tier down one rung (strong->medium->
    cheap) to cut cost. Paid users and non-'near' states keep the requested
    tier. Returns the tier string ai.generate should actually use."""
    try:
        if not _is_free(user):
            return requested_tier
        st = guard_state()
        if st["near"]:
            return PG.cheaper_tier(requested_tier)
    except Exception:
        pass
    return requested_tier


def _owner_alert(title, body):
    """Fire an honest owner alert when the profit guard blocks free-tier costly
    actions. Reuses FamilyAlert (the foreground-polled alert the app already
    renders) addressed to every superuser/owner; best-effort, never raises."""
    try:
        from .models import User, FamilyAlert
        owners = User.objects.filter(is_superuser=True)[:5]
        for o in owners:
            FamilyAlert.objects.get_or_create(
                user=o, kind="cost_guard", title=title[:160],
                defaults={"body": body, "severity": "high",
                          "payload": {"source": "profit_guard"}})
    except Exception:
        pass


# --------------------------------------------------------------- guard (no debit)

def guard_can(user, action, qty=1):
    """Can this charge succeed, WITHOUT debiting? Returns (allowed, reason).

    reason ∈ {"exempt", "unlimited", "ok", "insufficient", "guard_over"}
    ("unlimited" now only for the anonymous user=None path — no plan is).

      * Safety-exempt actions are always allowed.
      * FREE users: the profit guard is consulted first — 'over' blocks a costly
        action ("guard_over") until the next local day (never a safety action).
        The spendable balance is included credits + ad-wallet credits.
    """
    if is_exempt(action):
        return True, "exempt"
    if user is None:
        return True, "unlimited"
    ensure_monthly_pool(user)
    need = pricing.credits_for(action, qty, cfg())
    if need <= 0:
        return True, "ok"          # unpriced/unknown action -> free, never block

    if _is_free(user):
        try:
            if guard_state()["over"]:
                return False, "guard_over"
        except Exception:
            pass
    # billing-v2: rewarded ad credits are part of the balance (bucket
    # `rewarded`); a negative balance (refund debt) blocks everything.
    bal = int(getattr(user, "ai_credits", 0) or 0)
    if bal < need:
        try:   # probashi-plan: the family pool (within this member's cap)
            from . import probashi_plan as PB
            if PB.pool_can(user, need):
                return True, "ok"
        except Exception:
            pass
        return False, "insufficient"
    return True, "ok"


# --------------------------------------------------------------- atomic charge

def charge(user, action, qty=1, note=""):
    """ATOMIC debit of the per-action credit cost against User.ai_credits.

    Returns {"ok": bool, "reason": str, "charged": int, "balance": int}.

      * safety-exempt action -> {ok:True, reason:"exempt", charged:0}, NEVER blocked.
      * no user -> {ok:True, reason:"unlimited", charged:0}. No PLAN is
        unlimited: Premium/Business debit their monthly pool like anyone.
      * unpriced action -> {ok:True, reason:"ok", charged:0}.
      * else: inside transaction.atomic() + select_for_update() on the User row,
        re-read the balance (fixing the old read-modify-write race); if it can't
        cover `need` -> {ok:False, reason:"insufficient"} with balance UNCHANGED;
        otherwise F('ai_credits') - need + ONE CreditLedger(reason="consume") row.

    Never lets the balance go negative; exactly one ledger row per successful
    charge so concurrent/duplicate calls can't double-spend."""
    from .models import User, CreditLedger

    if is_exempt(action):
        bal = int(getattr(user, "ai_credits", 0) or 0) if user else 0
        return {"ok": True, "reason": "exempt", "charged": 0, "balance": bal}

    if user is None:
        return {"ok": True, "reason": "unlimited", "charged": 0, "balance": 0}

    # paid plans: make sure this month's included pool has landed first
    ensure_monthly_pool(user)

    need = pricing.credits_for(action, qty, cfg())
    if need <= 0:
        return {"ok": True, "reason": "ok", "charged": 0,
                "balance": int(user.ai_credits or 0)}

    free = _is_free(user)

    # FREE-tier PROFIT GUARD: when trailing cost is 'over' 60% of NET revenue,
    # block free-tier costly actions until the next local day + alert the owner.
    # Safety-exempt actions already returned above, so safety is NEVER blocked.
    if free:
        try:
            st = guard_state()
        except Exception:
            st = {"over": False}
        if st.get("over"):
            cap_pct = int(round(100 * float(
                (cfg().get("profit_guard") or {}).get(
                    "spend_cap_pct", PG.DEFAULT_SPEND_CAP_PCT))))
            _owner_alert(
                "Cost guard tripped — free-tier costly actions paused",
                f"Trailing-7-day variable cost exceeded {cap_pct}% of NET revenue. "
                "Free-tier paid actions are paused until tomorrow; paid users "
                "and all safety features are unaffected.")
            return {"ok": False, "reason": "guard_over", "charged": 0,
                    "balance": int(user.ai_credits or 0)}

    # billing-v2: ONE atomic spend in the owner's bucket order (plan ->
    # free/rewarded/referral -> pack) under the user row lock; rewarded ad
    # credits are a bucket of the balance now, not a side wallet.
    from . import credits as CR
    # probashi-plan: a family member whose own balance cannot cover this
    # spends from the payer's SHARED pool (plan bucket only, per-member cap)
    if int(getattr(user, "ai_credits", 0) or 0) < need:
        try:
            from . import probashi_plan as PB
            fam = PB.charge_pool(user, need, note=(note or action))
        except Exception:
            fam = None
        if fam is not None and (fam["ok"] or fam["reason"] == "family_cap"):
            return fam
    res = CR.spend(user, need, note=(note or action))
    return {"ok": res["ok"], "reason": res["reason"], "charged": res["charged"],
            "balance": res["balance"], "spend_ref": res.get("spend_ref", ""),
            **({"negative": True} if res.get("negative") else {})}


_SOURCE_BUCKET = {"topup": "pack", "rewarded": "rewarded", "trial": "free"}


def credit(user, source, amount, note="", spend_ref=None):
    """Grant `amount` credits atomically + one ledger row.

    billing-v2: a REFUND of a failed call (source 'adjust' with a refund
    note, or an explicit spend_ref) goes back to the SAME lots the charge
    came from (rule N); other grants land in their bucket: topup -> pack,
    rewarded -> rewarded, trial / founding / owner -> free, referral notes
    -> referral."""
    from . import credits as CR
    amount = int(amount or 0)
    if user is None or amount <= 0:
        return int(getattr(user, "ai_credits", 0) or 0) if user else 0
    is_return = bool(spend_ref) or (source == "adjust" and "refund" in (note or "").lower())
    if spend_ref and str(spend_ref).startswith("fam:"):
        # probashi-plan: a failed call paid from the family pool goes back
        # to the payer's same lots
        from . import probashi_plan as PB
        PB.return_pool(spend_ref, note=(note or "returned"))
        return int(user.ai_credits or 0)
    if is_return:
        ref = spend_ref or CR.last_spend_ref(user, amount)
        if ref:
            CR.return_spend(user, ref, note=(note or "returned"))
            user.refresh_from_db(fields=["ai_credits"])
            return int(user.ai_credits or 0)
    bucket = _SOURCE_BUCKET.get(source, "free")
    if (note or "").startswith("referral"):
        bucket = "referral"
    from .models import CreditLedger
    reason = source if source in dict(CreditLedger.REASONS) else "adjust"
    CR.grant(user, bucket, amount, reason=reason, note=(note or source),
             source_type=source[:24], source_id=(note or source)[:120])
    return int(user.ai_credits or 0)


# --------------------------------------------------------------- credit packs

# payment providers that, when enabled, REQUIRE a confirmed payment before any
# credits are granted (we never grant on a pending purchase with a live provider).
PAYMENT_PROVIDERS = ("play_billing", "eps", "bkash", "nagad", "sslcommerz")


def enabled_payment_provider():
    """The first configured+enabled payment provider, or '' if none. HONESTY:
    when a provider is required, topup must not grant credits without a real,
    confirmed payment through it."""
    try:
        from . import integrations
        for slug in PAYMENT_PROVIDERS:
            if integrations.is_enabled(slug):
                return slug
    except Exception:
        pass
    return ""


def start_topup(user, pack_id):
    """Begin a credit-pack top-up (Build 2).

      * No payment provider configured -> return an HONEST 'needs_provider'
        state and grant NOTHING (we never fake money).
      * Provider configured -> create a PENDING CreditPurchase; credits are
        granted only by confirm_topup() on a verified payment callback.

    Returns {ok, state, purchase_id, pack, provider}."""
    if not flag_on("topups_enabled"):
        return {"ok": False, "state": "disabled"}
    pack = pricing.pack_by_id(pack_id, cfg())
    if not pack:
        return {"ok": False, "state": "bad_pack"}
    provider = enabled_payment_provider()
    if not provider:
        return {"ok": False, "state": "needs_provider", "pack": pack}
    if provider in ("play_billing", "eps"):
        # pay1: packs are bought through the checkout sheet
        # (POST /payments/checkout or Play Billing) — never a pending row here.
        return {"ok": False, "state": "use_checkout", "pack": pack,
                "sku": "pack_" + pack["id"], "provider": provider}
    from .models import CreditPurchase
    p = CreditPurchase.objects.create(
        user=user, pack_id=pack["id"], price_bdt=pack["price"],
        credits=pack["credits"], provider=provider, status="pending")
    return {"ok": True, "state": "pending", "purchase_id": p.id,
            "pack": pack, "provider": provider}


def confirm_topup(purchase_id, txn_ref="", now=None):
    """Grant a pending purchase's credits ATOMICALLY on a confirmed payment.

    Idempotent: a purchase that already granted does nothing. Sets a 12-month
    expiry (pack.valid_months) and records the pack revenue in the DailyLedger.
    Returns {ok, granted, balance, expires_at}."""
    from .models import CreditPurchase, User, CreditLedger
    now = now or timezone.now()
    with transaction.atomic():
        p = CreditPurchase.objects.select_for_update().filter(
            pk=purchase_id).first()
        if p is None:
            return {"ok": False, "reason": "not_found"}
        if p.granted or p.status == "confirmed":
            return {"ok": True, "granted": 0, "balance": None,
                    "expires_at": p.expires_at.isoformat() if p.expires_at else None}
        p.status = "confirmed"
        p.granted = True
        p.txn_ref = (txn_ref or p.txn_ref)[:120]
        p.confirmed_at = now
        p.expires_at = None          # billing-v2 (rule B): packs never expire
        p.save(update_fields=["status", "granted", "txn_ref", "confirmed_at",
                              "expires_at"])
    from . import credits as CR
    CR.grant(p.user, CR.PACK, p.credits, reason="topup", note=f"pack:{p.pack_id}",
             source_type="pack", source_id="cp:%d" % p.pk, key="cp:%d" % p.pk, now=now)
    p.user.refresh_from_db(fields=["ai_credits"])
    new_bal = int(p.user.ai_credits or 0)
    record_revenue("packs", p.price_bdt)
    return {"ok": True, "granted": p.credits, "balance": new_bal, "expires_at": None}


def credit_history(user, now=None):
    """Ledger list + balance + expiry buckets for /credits/history.

    expiry_buckets = active (granted, un-expired) CreditPurchase rows grouped by
    the month they expire, so the app can warn 'N credits expire in <month>'."""
    from .models import CreditLedger, CreditPurchase
    now = now or timezone.now()
    from . import credits as CR
    from .models import CreditLot
    st = CR.state(user, now)
    ledger = [{
        "delta": r.delta, "reason": r.reason, "note": r.note,
        "at": r.created_at.isoformat(), "bucket": r.bucket,
    } for r in CreditLedger.objects.filter(user=user)[:200]]
    # billing-v2: only PLAN allowance expires (end of its paid period); packs
    # never do. expiry_buckets keeps its shape for the app.
    buckets = {}
    for lot in CreditLot.objects.filter(user=user, status="active", bucket=CR.PLAN,
                                        expires_at__gt=now):
        key = lot.expires_at.date().isoformat()
        buckets[key] = buckets.get(key, 0) + int(lot.remaining + lot.locked)
    return {
        "balance": int(st["balance"]),
        "ad_wallet_credits": ad_wallet_credits(user) if _is_free(user) else 0,
        "ledger": ledger,
        "expiry_buckets": [{"expires_on": k, "credits": v}
                           for k, v in sorted(buckets.items())],
        "credits_state": st,
    }


# --------------------------------------------------------------- ad crediting

def _ad_reward_paisa(ad_cfg):
    """Paisa credited per valid impression: eCPM_৳/1000 * revenue_share, in
    paisa (×100). Clamped at <=70% of the floor by config normalize."""
    per_impression_bdt = float(ad_cfg["ecpm_bdt"]) / 1000.0
    return int(round(per_impression_bdt * float(ad_cfg["revenue_share"]) * 100))


def ad_event(user, kind, device_id="", ad_id="", now=None, verified=False):
    """Record one ad impression for a FREE user and, if the caps/fraud checks
    pass AND AdMob is configured, credit the ad wallet at <=70% of the eCPM floor.

    Returns {ok, credited_paisa, credited_credits, reason, wallet_credits,
    caps}. reason ∈ {'ok','ads_not_configured','not_free','bad_kind','capped',
    'too_soon','fraud'}.

    HONESTY: no AdMob key -> NO crediting (we never fake ad revenue); the event
    is still logged (credited 0) so caps/fraud history stays intact."""
    from . import integrations
    from .models import AdEvent, AdWallet
    now = now or timezone.now()
    kind = str(kind or "")
    valid_kinds = {"app_open", "rewarded", "native", "interstitial"}
    if kind not in valid_kinds:
        return {"ok": False, "reason": "bad_kind"}
    # p2-money: a REWARDED ad is credited ONLY from Google's signed SSV
    # callback (verified=True, core.photo_studio_service.ssv_callback ->
    # placement "credits"). A client "I watched it" claim earns nothing.
    if kind == "rewarded" and not verified:
        return {"ok": False, "reason": "ssv_required", "credited_paisa": 0,
                "credited_credits": 0}
    # The ad wallet is a FREE-tier mechanism. Paid (Premium/Business) users see
    # NO ads — except a rewarded ad they explicitly opt into for credits (a6):
    # its sub-credit value accumulates in the wallet and every WHOLE credit is
    # moved straight into their purchased balance (User.ai_credits).
    paid = not _is_free(user)
    if paid and kind != "rewarded":
        return {"ok": False, "reason": "not_free"}

    ads_on = False
    try:
        ads_on = integrations.is_enabled("admob") and flag_on("ads_rewarded")
    except Exception:
        ads_on = False

    ad_cfg = cfg()["ad_rewards"]
    today = timezone.localdate()
    # admob (owner 25 Oct): until the owner turns REAL unit ids on, the app
    # shows Google TEST ads — an impression of a test ad earns nobody
    # anything (rewarded is SSV-verified, and only real units call SSV).
    if kind != "rewarded" and not ad_cfg.get("admob_real_ids", False):
        ads_on = False

    # --- fraud guard: impossible frequency (per user AND per device) ---
    # reject >1 impression of the same kind within 2s from the same user/device.
    recent_cut = now - timedelta(seconds=2)
    dup = AdEvent.objects.filter(kind=kind, at__gte=recent_cut).filter(
        models_q_user_or_device(user, device_id)).exists()
    if dup:
        AdEvent.objects.create(user=user, kind=kind, device_id=device_id[:64],
                               ad_id=ad_id[:80], credited_paisa=0, at=now)
        return {"ok": False, "reason": "fraud", "credited_paisa": 0,
                "credited_credits": 0}

    # --- per-kind caps (server-checked, Asia/Dhaka local day) ---
    cap_map = {
        "app_open": ad_cfg["appopen_daily_cap"],
        "rewarded": ad_cfg["rewarded_daily_cap"],
        "interstitial": ad_cfg["interstitial_daily_cap"],
        "native": ad_cfg["native_daily_cap"],
    }
    today_count = AdEvent.objects.filter(
        user=user, kind=kind, credited_paisa__gt=0, at__date=today).count()
    if today_count >= cap_map.get(kind, 0):
        AdEvent.objects.create(user=user, kind=kind, device_id=device_id[:64],
                               ad_id=ad_id[:80], credited_paisa=0, at=now)
        return {"ok": False, "reason": "capped", "credited_paisa": 0,
                "credited_credits": 0}

    # --- app-open minimum gap (>= configured seconds since last credited) ---
    if kind == "app_open":
        gap = int(ad_cfg["appopen_min_gap_sec"])
        last = AdEvent.objects.filter(
            user=user, kind="app_open", credited_paisa__gt=0).order_by("-at").first()
        if last and (now - last.at).total_seconds() < gap:
            AdEvent.objects.create(user=user, kind=kind,
                                   device_id=device_id[:64], ad_id=ad_id[:80],
                                   credited_paisa=0, at=now)
            return {"ok": False, "reason": "too_soon", "credited_paisa": 0,
                    "credited_credits": 0}

    if not ads_on:
        AdEvent.objects.create(user=user, kind=kind, device_id=device_id[:64],
                               ad_id=ad_id[:80], credited_paisa=0, at=now)
        return {"ok": False, "reason": "ads_not_configured",
                "credited_paisa": 0, "credited_credits": 0}

    paisa = _ad_reward_paisa(ad_cfg)
    moved = 0
    whole = 0
    from . import credits as CR
    with transaction.atomic():
        u = CR._lock(user)
        w = AdWallet.objects.select_for_update().get_or_create(user=u)[0]
        AdWallet.objects.filter(pk=w.pk).update(
            balance_paisa=F("balance_paisa") + paisa)
        AdEvent.objects.create(user=user, kind=kind, device_id=device_id[:64],
                               ad_id=ad_id[:80], credited_paisa=paisa, at=now)
        w.refresh_from_db()
        whole = w.spendable_credits()
        if whole > 0:
            # billing-v2 (audit #7): a whole ad credit leaves the wallet and
            # lands in the `rewarded` bucket of the balance with ONE ledger
            # row, so balance == ledger sum always holds.
            AdWallet.objects.filter(pk=w.pk).update(
                balance_paisa=F("balance_paisa") - whole * 100)
            reason = {"app_open": "ad_appopen", "interstitial": "ad_interstitial",
                      "rewarded": "rewarded", "native": "ad_appopen"}.get(kind, "rewarded")
            CR.grant(None, CR.REWARDED, whole, reason=reason,
                     note="ad:%s%s" % (kind, ":paid" if paid else ""),
                     source_type="ad", source_id="ad:%s" % kind, now=now, _u=u)
            moved = whole
    try:
        user.ai_credits = u.ai_credits
    except Exception:
        pass
    after_credits = ad_wallet_credits(user)
    # ad revenue into the DailyLedger (we got paid the eCPM; the user share is a cost
    # we recognise as the credit grant — we only book the NET we actually keep here).
    record_revenue("ads", paisa / 100.0)
    out = {"ok": True, "reason": "ok", "credited_paisa": paisa,
           "credited_credits": whole if not paid else 0,
           "wallet_credits": after_credits}
    if paid:
        out["moved_to_balance"] = moved
    return out


def ad_wallet_state(user, now=None):
    """GET /ads/wallet -> balance + today's remaining caps per kind."""
    from .models import AdEvent
    now = now or timezone.now()
    today = timezone.localdate()
    ad_cfg = cfg()["ad_rewards"]
    caps = {
        "app_open": ad_cfg["appopen_daily_cap"],
        "rewarded": ad_cfg["rewarded_daily_cap"],
        "interstitial": ad_cfg["interstitial_daily_cap"],
        "native": ad_cfg["native_daily_cap"],
    }
    used = {k: AdEvent.objects.filter(
        user=user, kind=k, credited_paisa__gt=0, at__date=today).count()
        for k in caps}
    return {
        "balance_credits": ad_wallet_credits(user),
        "caps": {k: {"cap": caps[k], "used": used[k],
                     "remaining": max(0, caps[k] - used[k])} for k in caps},
        "ads_configured": _ads_configured(),
    }


def _ads_configured():
    try:
        from . import integrations
        return bool(integrations.is_enabled("admob"))
    except Exception:
        return False


def models_q_user_or_device(user, device_id):
    """A Q matching rows by this user OR (when present) this device_id — the
    cross-account anti-farming guard."""
    from django.db.models import Q
    q = Q(user=user)
    if device_id:
        q = q | Q(device_id=device_id)
    return q


# --------------------------------------------------------------- expiry sweep

def expire_credits(now=None):
    """billing-v2 (rule B): purchased PACK credits NEVER expire, so this no
    longer touches packs. It expires PLAN allowance whose paid period ended
    (also when an RTDN was missed) via the bucket settle. Returns credits
    expired."""
    from . import credits as CR
    from .models import CreditLot, User
    from django.db.models import Sum as _S
    now = now or timezone.now()
    ids = set(CreditLot.objects.filter(status="active", bucket=CR.PLAN,
                                       expires_at__lte=now).values_list("user_id", flat=True))
    total = 0
    for u in User.objects.filter(pk__in=ids):
        total += int(CR.settle(u, now).get("expired", 0))
    return total
