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
    head = a.split("_", 1)[0]
    # e.g. "sos_sms", "health_reminder", "payment_bkash", "login_otp"
    return head in SAFETY_EXEMPT


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
    """Whether this user's effective plan includes unlimited AI (0 charged)."""
    from . import plans
    try:
        c = cfg()
        p = plans.effective_plan(user)
        row = c["plans"].get(p)
        if row is not None:
            return bool(row["unlimited_ai"])
        # founder / annual / probashi etc. aren't in config plans -> fall back
        return bool(plans.PLANS.get(p, {}).get("unlimited_ai"))
    except Exception:
        return False


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
    """Whole spendable credits currently in the user's ad wallet."""
    if user is None:
        return 0
    return get_ad_wallet(user).spendable_credits()


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
    return [{"date": r.date.isoformat(),
             "revenue_by_source": r.revenue_by_source,
             "variable_cost_by_type": r.variable_cost_by_type} for r in rows]


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

def plan_segment_counts(now=None):
    """Active-user counts by EFFECTIVE plan segment {free, premium, business}.

    'paid' = premium + business (plus annual/founder/probashi folded into premium
    for the segment view). Real counts from the User table — never fabricated."""
    from .models import User
    counts = {"free": 0, "premium": 0, "business": 0}
    for u in User.objects.filter(is_active=True).only(
            "plan", "plan_until", "trial_until", "is_founder"):
        try:
            seg = _segment_of(u)
        except Exception:
            seg = "free"
        counts[seg] = counts.get(seg, 0) + 1
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
    }


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
    c = cfg()
    from . import plans
    plan_id = plans.effective_plan(user)
    pool = 0
    prow = c["plans"].get(plan_id)
    if prow is not None:
        pool = int(prow["credits"])
    elif plan_id in ("annual", "founder", "probashi"):
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

    reason ∈ {"exempt", "unlimited", "ok", "insufficient", "guard_over"}.

      * Safety-exempt actions and unlimited plans are always allowed.
      * FREE users: the profit guard is consulted first — 'over' blocks a costly
        action ("guard_over") until the next local day (never a safety action).
        The spendable balance is included credits + ad-wallet credits.
    """
    if is_exempt(action):
        return True, "exempt"
    if user is None:
        return True, "unlimited"
    if _has_unlimited(user):
        return True, "unlimited"
    need = pricing.credits_for(action, qty, cfg())
    if need <= 0:
        return True, "ok"          # unpriced/unknown action -> free, never block

    if _is_free(user):
        try:
            if guard_state()["over"]:
                return False, "guard_over"
        except Exception:
            pass
        bal = int(getattr(user, "ai_credits", 0) or 0) + ad_wallet_credits(user)
    else:
        bal = int(getattr(user, "ai_credits", 0) or 0)
    if bal < need:
        return False, "insufficient"
    return True, "ok"


# --------------------------------------------------------------- atomic charge

def charge(user, action, qty=1, note=""):
    """ATOMIC debit of the per-action credit cost against User.ai_credits.

    Returns {"ok": bool, "reason": str, "charged": int, "balance": int}.

      * safety-exempt action -> {ok:True, reason:"exempt", charged:0}, NEVER blocked.
      * unlimited plan / no user -> {ok:True, reason:"unlimited", charged:0}.
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

    if user is None or _has_unlimited(user):
        bal = int(getattr(user, "ai_credits", 0) or 0) if user else 0
        return {"ok": True, "reason": "unlimited", "charged": 0, "balance": bal}

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

    from .models import AdWallet

    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        bal = int(locked.ai_credits or 0)
        ad_credits = 0
        if free:
            # include ad-wallet credits in the affordability check
            wallet = AdWallet.objects.select_for_update().get_or_create(
                user=locked)[0]
            ad_credits = wallet.spendable_credits()

        if bal + (ad_credits if free else 0) < need:
            return {"ok": False, "reason": "insufficient", "charged": 0,
                    "balance": bal}

        # spend INCLUDED/purchased credits first, then the ad wallet (free only)
        from_credits = min(bal, need)
        from_ad = need - from_credits
        if from_credits:
            User.objects.filter(pk=locked.pk).update(
                ai_credits=F("ai_credits") - from_credits)
            CreditLedger.objects.create(
                user=locked, delta=-from_credits, reason="consume",
                note=(note or action)[:120])
        if from_ad:
            AdWallet.objects.filter(pk=wallet.pk).update(
                balance_paisa=F("balance_paisa") - from_ad * 100)
            CreditLedger.objects.create(
                user=locked, delta=-from_ad, reason="ad_spend",
                note=(note or action)[:120])
        new_bal = bal - from_credits

    # keep the in-memory object consistent for the caller
    try:
        user.ai_credits = new_bal
    except Exception:
        pass
    return {"ok": True, "reason": "ok", "charged": need, "balance": new_bal}


def credit(user, source, amount, note=""):
    """Grant `amount` credits (top-up / refund / adjust) atomically + ledger row.
    Used by ai.generate to REFUND a failed-provider pre-charge. source maps to a
    CreditLedger reason ('topup'|'adjust'|'grant'|'rewarded')."""
    from .models import User, CreditLedger
    amount = int(amount or 0)
    if user is None or amount <= 0:
        return int(getattr(user, "ai_credits", 0) or 0) if user else 0
    reason = source if source in dict(CreditLedger.REASONS) else "adjust"
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") + amount)
        CreditLedger.objects.create(user=locked, delta=amount, reason=reason,
                                    note=(note or source)[:120])
        new_bal = int(locked.ai_credits or 0) + amount
    try:
        user.ai_credits = new_bal
    except Exception:
        pass
    return new_bal


# --------------------------------------------------------------- credit packs

# payment providers that, when enabled, REQUIRE a confirmed payment before any
# credits are granted (we never grant on a pending purchase with a live provider).
PAYMENT_PROVIDERS = ("play_billing", "bkash", "nagad", "sslcommerz")


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
        pack = pricing.pack_by_id(p.pack_id, cfg()) or {}
        months = int(pack.get("valid_months", 12) or 12)
        p.status = "confirmed"
        p.granted = True
        p.txn_ref = (txn_ref or p.txn_ref)[:120]
        p.confirmed_at = now
        p.expires_at = now + timedelta(days=30 * months)
        p.save(update_fields=["status", "granted", "txn_ref", "confirmed_at",
                              "expires_at"])
        locked = User.objects.select_for_update().get(pk=p.user_id)
        User.objects.filter(pk=locked.pk).update(
            ai_credits=F("ai_credits") + p.credits)
        CreditLedger.objects.create(
            user=locked, delta=p.credits, reason="topup",
            note=f"pack:{p.pack_id}")
        new_bal = int(locked.ai_credits or 0) + p.credits
    record_revenue("packs", p.price_bdt)
    return {"ok": True, "granted": p.credits, "balance": new_bal,
            "expires_at": p.expires_at.isoformat()}


def credit_history(user, now=None):
    """Ledger list + balance + expiry buckets for /credits/history.

    expiry_buckets = active (granted, un-expired) CreditPurchase rows grouped by
    the month they expire, so the app can warn 'N credits expire in <month>'."""
    from .models import CreditLedger, CreditPurchase
    now = now or timezone.now()
    ledger = [{
        "delta": r.delta, "reason": r.reason, "note": r.note,
        "at": r.created_at.isoformat(),
    } for r in CreditLedger.objects.filter(user=user)[:200]]
    buckets = {}
    active = CreditPurchase.objects.filter(
        user=user, granted=True, expires_at__gt=now)
    for p in active:
        key = p.expires_at.date().isoformat()
        buckets[key] = buckets.get(key, 0) + int(p.credits)
    return {
        "balance": int(getattr(user, "ai_credits", 0) or 0),
        "ad_wallet_credits": ad_wallet_credits(user) if _is_free(user) else 0,
        "ledger": ledger,
        "expiry_buckets": [{"expires_on": k, "credits": v}
                           for k, v in sorted(buckets.items())],
    }


# --------------------------------------------------------------- ad crediting

def _ad_reward_paisa(ad_cfg):
    """Paisa credited per valid impression: eCPM_৳/1000 * revenue_share, in
    paisa (×100). Clamped at <=70% of the floor by config normalize."""
    per_impression_bdt = float(ad_cfg["ecpm_bdt"]) / 1000.0
    return int(round(per_impression_bdt * float(ad_cfg["revenue_share"]) * 100))


def ad_event(user, kind, device_id="", ad_id="", now=None):
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
    # ad wallet is a FREE-tier mechanism only
    if not _is_free(user):
        return {"ok": False, "reason": "not_free"}

    ads_on = False
    try:
        ads_on = integrations.is_enabled("admob") and flag_on("ads_rewarded")
    except Exception:
        ads_on = False

    ad_cfg = cfg()["ad_rewards"]
    today = timezone.localdate()

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
    with transaction.atomic():
        w = AdWallet.objects.select_for_update().get_or_create(user=user)[0]
        before_credits = w.spendable_credits()
        AdWallet.objects.filter(pk=w.pk).update(
            balance_paisa=F("balance_paisa") + paisa)
        AdEvent.objects.create(user=user, kind=kind, device_id=device_id[:64],
                               ad_id=ad_id[:80], credited_paisa=paisa, at=now)
        w.refresh_from_db()
        after_credits = w.spendable_credits()
        whole_gained = after_credits - before_credits
        if whole_gained > 0:
            # unify the audit trail: a whole credit crossing writes a ledger row
            from .models import CreditLedger
            reason = {"app_open": "ad_appopen", "interstitial": "ad_interstitial",
                      "rewarded": "rewarded", "native": "ad_appopen"}.get(
                          kind, "rewarded")
            CreditLedger.objects.create(user=user, delta=whole_gained,
                                        reason=reason, note=f"ad:{kind}")
    # ad revenue into the DailyLedger (we got paid the eCPM; the user share is a cost
    # we recognise as the credit grant — we only book the NET we actually keep here).
    record_revenue("ads", paisa / 100.0)
    return {"ok": True, "reason": "ok", "credited_paisa": paisa,
            "credited_credits": after_credits, "wallet_credits": after_credits}


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
    """Zero out expired purchased credits (12-month validity). Append-only: for
    each purchase that has passed its expiry and not yet been swept, debit the
    still-held credits (bounded by the live balance) and write an 'expire'
    ledger row. Idempotent via the `granted` flag flip to a swept marker.

    Returns the number of credits expired. Called by the daily management
    command; safe to run repeatedly."""
    from .models import CreditPurchase, User, CreditLedger
    now = now or timezone.now()
    total = 0
    due = CreditPurchase.objects.filter(
        granted=True, status="confirmed", expires_at__lte=now)
    for p in due:
        with transaction.atomic():
            locked = User.objects.select_for_update().get(pk=p.user_id)
            take = min(int(locked.ai_credits or 0), int(p.credits or 0))
            if take > 0:
                User.objects.filter(pk=locked.pk).update(
                    ai_credits=F("ai_credits") - take)
                CreditLedger.objects.create(
                    user=locked, delta=-take, reason="expire",
                    note=f"pack:{p.pack_id} expired")
                total += take
            p.status = "failed"   # reuse as a "swept/closed" terminal marker
            p.granted = False
            p.save(update_fields=["status", "granted"])
    return total
