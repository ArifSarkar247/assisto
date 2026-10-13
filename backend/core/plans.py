"""
Monetization (P3) — plan definitions + entitlement helpers.

Prices/limits from spec §17 + owner's 23-Sept plan. Credits are consumable AI
units; paid plans effectively have unlimited AI under the global daily budget
kill-switch. New users get a 7-day full trial. Rewarded ads grant +1 credit
(daily cap). Ads only on free, non-personalized, never on sensitive screens
(enforced in the app).
"""
from datetime import timedelta
from django.utils import timezone

# credits == AI "scans" per month for credit-limited plans
PLANS = {
    "free":     {"name_bn": "ফ্রি", "price": 0, "cur": "BDT", "period": "mo",
                 "credits": 15, "unlimited_ai": False, "ads": True, "family": 0},
    "premium":  {"name_bn": "প্রিমিয়াম", "price": 149, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0},
    "family":   {"name_bn": "ফ্যামিলি", "price": 299, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5},
    "probashi": {"name_bn": "প্রবাসী", "price": 4.99, "cur": "USD", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5},
    "business": {"name_bn": "বিজনেস", "price": 1999, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0},
    "annual":   {"name_bn": "বার্ষিক (প্রিমিয়াম)", "price": 1199, "cur": "BDT", "period": "yr",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0},
    "founder":  {"name_bn": "ফাউন্ডার", "price": 0, "cur": "BDT", "period": "life",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5},
}

# credit top-up packs (৳20–30 range, like mobile recharge)
TOPUP_PACKS = [
    {"id": "p20", "price": 20, "cur": "BDT", "credits": 20},
    {"id": "p30", "price": 30, "cur": "BDT", "credits": 35},
]

TRIAL_DAYS = 7
REWARDED_DAILY_CAP = 5


def trial_active(user):
    return bool(user.trial_until and user.trial_until > timezone.now())


def plan_active(user):
    if user.is_founder:
        return True
    return bool(user.plan_until and user.plan_until > timezone.now())


def effective_plan(user):
    """What the user is actually entitled to right now."""
    if user.is_founder:
        return "founder"
    if plan_active(user) and user.plan in PLANS:
        return user.plan
    if trial_active(user):
        return "premium"          # full trial
    return "free"


def entitlements(user):
    p = effective_plan(user)
    spec = PLANS[p]
    return {
        "plan": p,
        "name_bn": spec["name_bn"],
        "unlimited_ai": spec["unlimited_ai"],
        "ads": spec["ads"] and not trial_active(user),
        "max_family": spec["family"],
        "credits": user.ai_credits,
        "trial_active": trial_active(user),
        "trial_until": user.trial_until.isoformat() if user.trial_until else None,
        "plan_until": user.plan_until.isoformat() if user.plan_until else None,
    }


def start_trial(user):
    if not user.trial_until:
        user.trial_until = timezone.now() + timedelta(days=TRIAL_DAYS)
        user.save(update_fields=["trial_until"])
        _grant(user, PLANS["free"]["credits"], "trial", "7-day trial start")


def _grant(user, n, reason, note=""):
    from .models import CreditLedger
    if n <= 0:
        return
    user.ai_credits = (user.ai_credits or 0) + n
    user.save(update_fields=["ai_credits"])
    CreditLedger.objects.create(user=user, delta=n, reason=reason, note=note)


def grant_monthly_if_due(user):
    """Grant this month's free-plan credits once per calendar month."""
    from .models import CreditLedger
    if effective_plan(user) != "free":
        return
    now = timezone.now()
    last = (CreditLedger.objects.filter(user=user, reason="grant")
            .order_by("-created_at").first())
    if last and last.created_at.year == now.year and last.created_at.month == now.month:
        return
    _grant(user, PLANS["free"]["credits"], "grant", f"{now:%Y-%m} monthly")


def has_ai_quota(user):
    """True if the user may run an AI call now (unlimited plan or has credits)."""
    if user is None:
        return True
    if PLANS[effective_plan(user)]["unlimited_ai"]:
        return True
    grant_monthly_if_due(user)
    return (user.ai_credits or 0) > 0


def consume_credit(user, note="ai"):
    """Consume one credit for credit-limited plans. No-op for unlimited plans."""
    if user is None or PLANS[effective_plan(user)]["unlimited_ai"]:
        return
    from .models import CreditLedger
    if (user.ai_credits or 0) <= 0:
        return
    user.ai_credits -= 1
    user.save(update_fields=["ai_credits"])
    CreditLedger.objects.create(user=user, delta=-1, reason="consume", note=note)


def reward_ad(user):
    """Grant +1 credit for watching a rewarded ad, up to a daily cap."""
    from .models import CreditLedger
    now = timezone.now()
    today_rewards = CreditLedger.objects.filter(
        user=user, reason="rewarded", created_at__date=now.date()).count()
    if today_rewards >= REWARDED_DAILY_CAP:
        return (False, REWARDED_DAILY_CAP - today_rewards)
    _grant(user, 1, "rewarded", "watched a rewarded ad")
    return (True, REWARDED_DAILY_CAP - today_rewards - 1)
