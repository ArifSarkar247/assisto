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
    "free":     {"name_bn": "ফ্রি", "name_en": "Free", "price": 0, "cur": "BDT", "period": "mo",
                 "credits": 15, "unlimited_ai": False, "ads": True, "family": 0,
                 "desc_bn": "শুরু করার জন্য — নিরাপত্তা সবসময় ফ্রি।", "desc_en": "To get started — safety is always free.",
                 "benefits_bn": ["মাসে ১৫ AI স্ক্যান", "রিমাইন্ডার, ভল্ট, হিসাব", "জরুরি SOS ও স্ক্যাম সতর্কতা (ফ্রি)", "ওষুধ রিমাইন্ডার (ফ্রি)"],
                 "benefits_en": ["15 AI scans / month", "Reminders, documents, money", "Emergency SOS & scam alerts (free)", "Medicine reminders (free)"]},
    "premium":  {"name_bn": "প্রিমিয়াম", "name_en": "Premium", "price": 149, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0,
                 "desc_bn": "আনলিমিটেড AI, বিজ্ঞাপন নেই।", "desc_en": "Unlimited AI, no ads.",
                 "benefits_bn": ["আনলিমিটেড AI স্ক্যান ও সহকারী", "বিজ্ঞাপন নেই", "স্মার্ট ব্রিফিং ও প্রোঅ্যাকটিভ সাহায্য", "অগ্রাধিকার সাপোর্ট"],
                 "benefits_en": ["Unlimited AI scans & assistant", "No ads", "Smart briefings & proactive help", "Priority support"]},
    "family":   {"name_bn": "ফ্যামিলি", "name_en": "Family", "price": 299, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5,
                 "desc_bn": "৫ জন পর্যন্ত — বাবা-মায়ের যত্ন একসাথে।", "desc_en": "Up to 5 people — care for your parents together.",
                 "benefits_bn": ["প্রিমিয়ামের সব সুবিধা", "৫ জন পর্যন্ত পরিবারের সদস্য", "কেয়ারগিভার ড্যাশবোর্ড ও ওষুধ অ্যালার্ট", "কানেক্টেড সার্কেল শেয়ারিং"],
                 "benefits_en": ["Everything in Premium", "Up to 5 family members", "Caregiver dashboard & medicine alerts", "Connected Circle sharing"]},
    "probashi": {"name_bn": "প্রবাসী", "name_en": "Probashi", "price": 4.99, "cur": "USD", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5,
                 "desc_bn": "বিদেশ থেকে দেশের পরিবারের যত্ন।", "desc_en": "Care for your family back home, from abroad.",
                 "benefits_bn": ["ফ্যামিলির সব সুবিধা", "দেশের পরিবারের জন্য দূর থেকে যত্ন", "USD বিলিং"],
                 "benefits_en": ["Everything in Family", "Remote care for family in Bangladesh", "USD billing"]},
    "business": {"name_bn": "বিজনেস", "name_en": "Business", "price": 1999, "cur": "BDT", "period": "mo",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0,
                 "desc_bn": "ছোট ব্যবসা ও বিক্রয় দলের জন্য।", "desc_en": "For small businesses and sales teams.",
                 "benefits_bn": ["আনলিমিটেড AI", "বিজনেস মোড: ক্যাটালগ ও অর্ডার", "AI CRM (Axon Dynamics)", "দলের আসন (দাম মালিক ঠিক করবেন)"],
                 "benefits_en": ["Unlimited AI", "Business mode: catalog & orders", "AI CRM (Axon Dynamics)", "Team seats (pricing TO REVIEW BY OWNER)"]},
    "annual":   {"name_bn": "বার্ষিক (প্রিমিয়াম)", "name_en": "Annual (Premium)", "price": 1199, "cur": "BDT", "period": "yr",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 0,
                 "desc_bn": "প্রিমিয়াম — বছরে, ২ মাস সাশ্রয়।", "desc_en": "Premium — yearly, save ~2 months.",
                 "benefits_bn": ["প্রিমিয়ামের সব সুবিধা", "বছরে একবার পেমেন্ট", "প্রায় ২ মাস ফ্রি"],
                 "benefits_en": ["Everything in Premium", "Pay once a year", "About 2 months free"]},
    "founder":  {"name_bn": "ফাউন্ডার", "name_en": "Founder", "price": 0, "cur": "BDT", "period": "life",
                 "credits": 0, "unlimited_ai": True, "ads": False, "family": 5,
                 "desc_bn": "আজীবন — শুরুর সমর্থকদের জন্য।", "desc_en": "Lifetime — for early supporters.",
                 "benefits_bn": ["আজীবন আনলিমিটেড", "ফ্যামিলির সব সুবিধা"],
                 "benefits_en": ["Lifetime unlimited", "Everything in Family"]},
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


def entitlements(user, lang="bn"):
    from .i18n import pick
    p = effective_plan(user)
    spec = PLANS[p]
    return {
        "plan": p,
        "name": pick(lang, spec["name_bn"], spec["name_en"]),
        "name_bn": spec["name_bn"],
        "desc": pick(lang, spec["desc_bn"], spec["desc_en"]),
        "benefits": spec["benefits_" + lang],
        "unlimited_ai": spec["unlimited_ai"],
        "ads": spec["ads"] and not trial_active(user),
        "max_family": spec["family"],
        "credits": user.ai_credits,
        "trial_active": trial_active(user),
        "trial_until": user.trial_until.isoformat() if user.trial_until else None,
        "plan_until": user.plan_until.isoformat() if user.plan_until else None,
    }


def plans_public(lang="bn"):
    """All purchasable plans, localised, for the paywall/Plans screen."""
    from .i18n import pick
    out = []
    for pid, s in PLANS.items():
        if pid == "founder":
            continue
        out.append({
            "id": pid, "name": pick(lang, s["name_bn"], s["name_en"]),
            "price": s["price"], "cur": s["cur"], "period": s["period"],
            "desc": pick(lang, s["desc_bn"], s["desc_en"]),
            "benefits": s["benefits_" + lang], "unlimited_ai": s["unlimited_ai"],
            "ads": s["ads"], "family": s["family"],
        })
    return out


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
    # Count against the LOCAL day. `created_at__date` is evaluated in the active
    # timezone (Asia/Dhaka), so the comparison date must also be the local date —
    # timezone.now().date() returns the UTC date and, after ~18:00 UTC (past
    # Dhaka midnight), would mismatch and silently reset the cap. Use localdate().
    today = timezone.localdate()
    today_rewards = CreditLedger.objects.filter(
        user=user, reason="rewarded", created_at__date=today).count()
    if today_rewards >= REWARDED_DAILY_CAP:
        return (False, REWARDED_DAILY_CAP - today_rewards)
    _grant(user, 1, "rewarded", "watched a rewarded ad")
    return (True, REWARDED_DAILY_CAP - today_rewards - 1)
