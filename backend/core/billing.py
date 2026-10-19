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
from django.db import transaction
from django.db.models import F

from .logic import pricing

# --------------------------------------------------------------- safety allow-list
# These actions are life-safety / account-critical and are NEVER charged and NEVER
# blocked — not by credits, not by the ad wallet (Build 3), not by Profit Guard
# (Build 4). A missing entry could block an SOS, so this set is load-bearing and
# pinned by a test. Keys are action ids OR feature prefixes checked by is_exempt().
SAFETY_EXEMPT = frozenset({
    "sos", "safe_journey", "anti_theft", "health", "elderly",
    "payment", "login",
})


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


# --------------------------------------------------------------- guard (no debit)

def guard_can(user, action, qty=1):
    """Can this charge succeed, WITHOUT debiting? Returns (allowed, reason).

    reason ∈ {"exempt", "unlimited", "ok", "insufficient"}. Safety-exempt actions
    and unlimited plans are always allowed; otherwise checks the live balance."""
    if is_exempt(action):
        return True, "exempt"
    if user is None:
        return True, "unlimited"
    if _has_unlimited(user):
        return True, "unlimited"
    need = pricing.credits_for(action, qty, cfg())
    if need <= 0:
        return True, "ok"          # unpriced/unknown action -> free, never block
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

    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        bal = int(locked.ai_credits or 0)
        if bal < need:
            return {"ok": False, "reason": "insufficient", "charged": 0,
                    "balance": bal}
        User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") - need)
        CreditLedger.objects.create(
            user=locked, delta=-need, reason="consume",
            note=(note or action)[:120])
        new_bal = bal - need

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
