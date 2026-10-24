"""
Monetization (P3) — plan definitions + entitlement helpers.

Prices/limits from spec §17 + owner's 23-Sept plan. Credits are consumable AI
units. NOTHING is unlimited in any plan (owner decision 2026-10): every paid
plan carries a monthly credit POOL (Premium 90, Business 240 — live values in
PricingConfig), granted once per calendar month by billing.grant_monthly_pool,
and every AI action debits credits. Safety actions stay free. New users may start a 3-day Premium trial once (p2-money; live length in limits.trial_days). Rewarded ads grant +1 credit
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
                 "benefits_bn": ["AI: ক্রেডিট প্যাক কিনে বা বিজ্ঞাপন দেখে", "রিমাইন্ডার, ভল্ট, হিসাব", "জরুরি SOS ও স্ক্যাম সতর্কতা (ফ্রি)", "ওষুধ রিমাইন্ডার (ফ্রি)"],
                 "benefits_en": ["AI with credit packs or rewarded ads", "Reminders, documents, money", "Emergency SOS & scam alerts (free)", "Medicine reminders (free)"]},
    # NOTE (Business Model Build 1): Premium absorbs the former Family plan — it
    # now carries family=5 (5-member circle + caregiver dashboard). The standalone
    # "family" plan is REMOVED and existing Family subscribers are migrated to
    # Premium by migration 0039. Live prices/credits/ads come from PricingConfig
    # (core.logic.pricing); these literals are the DEFAULT/fallback only.
    "premium":  {"name_bn": "প্রিমিয়াম", "name_en": "Premium", "price": 199, "cur": "BDT", "period": "mo",
                 "credits": 90, "unlimited_ai": False, "ads": False, "family": 5,
                 "desc_bn": "প্রতি মাসে ৯০ AI ক্রেডিট, বিজ্ঞাপন নেই — পরিবারের যত্ন একসাথে।", "desc_en": "90 AI credits a month, no ads — care for your family together.",
                 "benefits_bn": ["প্রতি মাসে ৯০ AI ক্রেডিট (স্ক্যান ও সহকারী)", "বিজ্ঞাপন নেই", "৫ জন পর্যন্ত কানেক্টেড সার্কেল ও কেয়ারগিভার ড্যাশবোর্ড", "স্মার্ট ব্রিফিং ও অগ্রাধিকার সাপোর্ট"],
                 "benefits_en": ["90 AI credits / month (scans & assistant)", "No ads", "Up to 5-member Circle & caregiver dashboard", "Smart briefings & priority support"]},
    "probashi": {"name_bn": "প্রবাসী", "name_en": "Probashi", "price": 4.99, "cur": "USD", "period": "mo",
                 "credits": 90, "unlimited_ai": False, "ads": False, "family": 5,
                 "desc_bn": "বিদেশ থেকে দেশের পরিবারের যত্ন।", "desc_en": "Care for your family back home, from abroad.",
                 "benefits_bn": ["প্রিমিয়ামের সব সুবিধা", "দেশের পরিবারের জন্য দূর থেকে যত্ন", "USD বিলিং"],
                 "benefits_en": ["Everything in Premium", "Remote care for family in Bangladesh", "USD billing"]},
    "business": {"name_bn": "বিজনেস", "name_en": "Business", "price": 999, "cur": "BDT", "period": "mo",
                 "credits": 240, "unlimited_ai": False, "ads": False, "family": 0,
                 "desc_bn": "ছোট ব্যবসা ও বিক্রয় দলের জন্য।", "desc_en": "For small businesses and sales teams.",
                 "benefits_bn": ["প্রতি মাসে ২৪০ AI ক্রেডিট", "বিজনেস মোড: ক্যাটালগ ও অর্ডার", "AI CRM (Axon Dynamics)", "দলের আসন (দাম মালিক ঠিক করবেন)"],
                 "benefits_en": ["240 AI credits / month", "Business mode: catalog & orders", "AI CRM (Axon Dynamics)", "Team seats (pricing TO REVIEW BY OWNER)"]},
    "annual":   {"name_bn": "বার্ষিক (প্রিমিয়াম)", "name_en": "Annual (Premium)", "price": 1199, "cur": "BDT", "period": "yr",
                 "credits": 90, "unlimited_ai": False, "ads": False, "family": 0,
                 "desc_bn": "প্রিমিয়াম — বছরে, ২ মাস সাশ্রয়।", "desc_en": "Premium — yearly, save ~2 months.",
                 "benefits_bn": ["প্রিমিয়ামের সব সুবিধা", "বছরে একবার পেমেন্ট", "প্রায় ২ মাস ফ্রি"],
                 "benefits_en": ["Everything in Premium", "Pay once a year", "About 2 months free"]},
    "founder":  {"name_bn": "ফাউন্ডার", "name_en": "Founder", "price": 0, "cur": "BDT", "period": "life",
                 "credits": 90, "unlimited_ai": False, "ads": False, "family": 5,
                 "desc_bn": "আজীবন — শুরুর সমর্থকদের জন্য।", "desc_en": "Lifetime — for early supporters.",
                 "benefits_bn": ["আজীবন প্রিমিয়াম — প্রতি মাসে ৯০ AI ক্রেডিট", "প্রিমিয়ামের সব সুবিধা"],
                 "benefits_en": ["Lifetime Premium — 90 AI credits every month", "Everything in Premium"]},
}

# credit top-up packs (৳20–30 range, like mobile recharge)
TOPUP_PACKS = [
    {"id": "p20", "price": 20, "cur": "BDT", "credits": 20},
    {"id": "p30", "price": 30, "cur": "BDT", "credits": 35},
]

# DEFAULTS only — live values come from PricingConfig (admin-editable in
# /admin/pricing): limits.trial_days / limits.trial_credits and
# ad_rewards.rewarded_daily_cap. Read them via the helpers below.
TRIAL_DAYS = 7
REWARDED_DAILY_CAP = 5


def _cfg():
    try:
        from . import billing
        return billing.cfg()
    except Exception:
        return None


def trial_days():
    c = _cfg()
    return int(c["limits"]["trial_days"]) if c else TRIAL_DAYS


def trial_credits():
    c = _cfg()
    return int(c["limits"]["trial_credits"]) if c else PLANS["free"]["credits"]


def rewarded_daily_cap():
    c = _cfg()
    return int(c["ad_rewards"]["rewarded_daily_cap"]) if c else REWARDED_DAILY_CAP


def trial_active(user):
    return bool(user.trial_until and user.trial_until > timezone.now())


def lifetime_founder(user):
    """The legacy LIFETIME founder (plan "founder"): is_founder with no
    Founding Member grant date. A Founding Member (f1-founders, founder_since
    set) is entitled through plan/plan_until like any Premium user — the
    badge stays, the free Premium ends at founder_until."""
    return bool(user.is_founder and not getattr(user, "founder_since", None))


def founding_member(user):
    """Badge payload for /me: {"active", "lifetime", "since", "premium_until"}."""
    if not user.is_founder:
        # p5-growth: an automatic numbered Founding seat shows the same badge
        # (no free Premium attached — its perk was one-time credits).
        try:
            from .models import FoundingSeat
            seat = FoundingSeat.objects.filter(user_id=user.pk).first()
        except Exception:
            seat = None
        if seat is not None:
            return {"active": True, "lifetime": False,
                    "since": seat.granted_at.isoformat(), "premium_until": None,
                    "seat": seat.number}
        return {"active": False, "lifetime": False, "since": None, "premium_until": None}
    since = getattr(user, "founder_since", None)
    until = getattr(user, "founder_until", None)
    return {"active": True, "lifetime": since is None,
            "since": since.isoformat() if since else None,
            "premium_until": until.isoformat() if until else None}


def plan_active(user):
    if lifetime_founder(user):
        return True
    return bool(user.plan_until and user.plan_until > timezone.now())


def effective_plan(user):
    """What the user is actually entitled to right now."""
    if lifetime_founder(user):
        return "founder"
    if plan_active(user):
        # Family was folded into Premium (Build 1); any stray "family" row still
        # on a user maps to premium so their 5-member circle keeps working.
        if user.plan == "family":
            return "premium"
        if user.plan in PLANS:
            return user.plan
    if trial_active(user):
        return "premium"          # full trial
    return "free"


def _config_plan(pid):
    """The PricingConfig view of a plan (price/credits/ads/family), or
    None if config isn't applicable (founder/annual/probashi stay literal). The
    server is authoritative: edits in /admin/pricing show here with no app change."""
    try:
        from . import billing
        return billing.cfg()["plans"].get(pid)
    except Exception:
        return None


def _benefits(pid, lang, spec):
    """Config-derived benefit lines for free/premium/business (numbers come
    from the live PricingConfig); literal lines for the other plans."""
    try:
        from .logic import pricing
        c = _cfg()
        if c is not None and pid in c["plans"]:
            return pricing.plan_benefits(pid, lang, c)
    except Exception:
        pass
    return spec["benefits_" + lang]


def entitlements(user, lang="bn"):
    from .i18n import pick
    try:
        from . import billing
        billing.ensure_monthly_pool(user)   # paid plans: this month's 90/240
    except Exception:
        pass
    p = effective_plan(user)
    spec = PLANS[p]
    # Prices/credits/ads/family come from PricingConfig when the plan is config-
    # backed (free/premium/business); founder/annual/probashi keep the literal.
    cp = _config_plan(p)
    ads = (cp["ads"] if cp else spec["ads"])
    max_family = cp["family"] if cp else spec["family"]
    return {
        "plan": p,
        "name": pick(lang, spec["name_bn"], spec["name_en"]),
        "name_bn": spec["name_bn"],
        "desc": pick(lang, spec["desc_bn"], spec["desc_en"]),
        "benefits": _benefits(p, lang, spec),
        "unlimited_ai": False,        # nothing is unlimited (owner decision)
        "ads": ads and not trial_active(user),
        "max_family": max_family,
        "credits": user.ai_credits,
        "trial_active": trial_active(user),
        "trial_until": user.trial_until.isoformat() if user.trial_until else None,
        # p2-money: the "Start free trial" button (once per user)
        "trial_available": trial_available(user),
        "trial_days": trial_days(),
        "plan_until": user.plan_until.isoformat() if user.plan_until else None,
    }


def plans_public(lang="bn"):
    """All purchasable plans, localised, for the paywall/Plans screen.

    Build 1: Free/Premium/Business (+ derived Annual) come from PricingConfig via
    the pure pricing.plan_public() — so the owner's /admin/pricing edits show in
    the app with NO app change. Family is removed from the catalog. probashi is
    appended from the literal; founder stays hidden."""
    from .i18n import pick
    from .logic import pricing
    from . import billing
    out = pricing.plan_public(lang, billing.cfg())
    # append probashi (USD plan kept per the plan; not config-backed yet)
    s = PLANS.get("probashi")
    if s:
        c = _cfg()
        out.append({
            "id": "probashi", "name": pick(lang, s["name_bn"], s["name_en"]),
            "price": c["probashi_price_usd"] if c else s["price"], "cur": s["cur"], "period": s["period"],
            "desc": pick(lang, s["desc_bn"], s["desc_en"]),
            "benefits": s["benefits_" + lang], "unlimited_ai": False,
            "ads": s["ads"], "family": s["family"],
            "credits": (c["plans"]["premium"]["credits"] if c else s["credits"]),
        })
    return out


def trial_on_signup():
    c = _cfg()
    try:
        return bool(c["limits"].get("trial_on_signup", False)) if c else False
    except Exception:
        return False


def trial_available(user):
    """p2-money: may this user START the Premium trial now? Once per user
    (trial_until is set forever after — an expired trial is a used trial),
    Free users only, no card needed."""
    if user is None or getattr(user, "trial_until", None):
        return False
    if user.is_founder or plan_active(user):
        return False
    return trial_days() > 0


def start_trial_button(user):
    """POST /plans/trial/start -> (ok, reason). Server-enforced once."""
    from django.db import transaction
    from .models import User
    with transaction.atomic():
        u = User.objects.select_for_update().get(pk=user.pk)
        if u.trial_until:
            return False, "trial_used"
        if not trial_available(u):
            return False, "not_eligible"
        start_trial(u)
    user.refresh_from_db()
    return True, "ok"


def start_trial(user):
    if not user.trial_until:
        days = trial_days()
        user.trial_until = timezone.now() + timedelta(days=days)
        user.save(update_fields=["trial_until"])
        _grant(user, trial_credits(), "trial", f"{days}-day trial start")


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
    cp = _config_plan("free")
    free_credits = cp["credits"] if cp else PLANS["free"]["credits"]
    _grant(user, free_credits, "grant", f"{now:%Y-%m} monthly")


def has_ai_quota(user):
    """True if the user may run an AI call now (has credits — no plan is
    unlimited)."""
    if user is None:
        return True
    grant_monthly_if_due(user)
    return (user.ai_credits or 0) > 0


def consume_credit(user, note="ai"):
    """Consume one credit (every plan is credit-limited)."""
    if user is None:
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
    cap = rewarded_daily_cap()
    if today_rewards >= cap:
        return (False, max(0, cap - today_rewards))
    _grant(user, 1, "rewarded", "watched a rewarded ad")
    return (True, cap - today_rewards - 1)
