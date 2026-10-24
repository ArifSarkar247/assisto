"""
p5-growth — invite-code referral (credits for BOTH after activation), automatic
Founding Member seats, daily activity (retention) and the anonymous install
ping. The owner funnel (/owner/funnel) reads the same tables (core.funnel).

Rules (owner order P5 + master strategy):
* Credits are AI credits, never cash, never withdrawable. Nothing unlimited:
  every amount, the monthly cap per inviter and the seat count are Admin-
  editable in Owner Admin → Pricing → referral (core.logic.pricing bounds).
* A reward is granted ONLY when the invitee is ACTIVATED:
    - active on `invite_activation_days` (default 2) DIFFERENT days within the
      first 14 days after signup (ActiveDay rows), AND
    - phone: OTP-verified when the SMS gateway is connected; while SMS is not
      connected a valid BD mobile number on the account is required instead.
* Anti-abuse: self-referral blocked (same account, or the invitee's device
  is one the inviter used), the inviter must have signed up BEFORE the
  invitee, one reward per device and per phone (hashes survive account
  deletion), one claim per account, code accepted only within
  `invite_claim_days` of signup, monthly cap per inviter.
* Every reward credit is booked in Profit Guard / P&L as variable cost type
  "growth" at its ESTIMATED provider cost (credit_bdt / (1 + margin)) at grant
  time. This is conservative: the real AI cost of spending them is also
  booked when they are used.
"""
import hashlib
import hmac
import re
import secrets
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

ACTIVATION_WINDOW_DAYS = 14          # activation must happen within 14 days
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no O/0/I/1 confusion
CODE_RE = re.compile(r"^[A-Z0-9]{4,12}$")

DEFAULTS = {
    "invite_credits_inviter": 20, "invite_credits_invitee": 10,
    "invite_monthly_cap": 10, "invite_claim_days": 14,
    "invite_activation_days": 2, "founding_auto_seats": 500,
    "founding_seat_credits": 20,
}


def pick(lang, bn, en):
    return en if lang == "en" else bn


def cfg():
    out = dict(DEFAULTS)
    try:
        from . import billing
        out.update({k: v for k, v in billing.cfg()["referral"].items() if k in DEFAULTS})
    except Exception:
        pass
    return out


def site():
    return getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")


def play_package():
    return getattr(settings, "PLAY_PACKAGE_NAME", "com.assisto.assisto")


def _h(raw):
    key = (settings.SECRET_KEY or "").encode("utf-8")
    return hmac.new(key, ("p5|%s" % raw).encode("utf-8"), hashlib.sha256).hexdigest()


def cost_per_credit():
    """Estimated provider cost (৳) behind one credit: prices are set so that
    cost × (1 + margin) <= credit face value, so this is the upper bound."""
    try:
        from . import billing
        c = billing.cfg()
        return float(c["credit_bdt"]) / (1.0 + max(0.0, float(c["margin"])))
    except Exception:
        return 1.0 / 1.4


# ------------------------------------------------------------------ codes
def normalize_code(raw):
    s = re.sub(r"[\s\-]", "", str(raw or "")).upper()
    if "/I/" in s:                       # a pasted link https://…/i/CODE
        s = s.rsplit("/I/", 1)[1].split("?")[0].strip("/")
    return s if CODE_RE.match(s) else ""


def ensure_code(user):
    """The user's permanent invite code (8 chars), created on first use."""
    from .models import User
    if user.referral_code and CODE_RE.match(user.referral_code):
        return user.referral_code
    for _ in range(20):
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
        if not User.objects.filter(referral_code=code).exists():
            User.objects.filter(pk=user.pk).update(referral_code=code)
            user.referral_code = code
            return code
    raise RuntimeError("could not allocate an invite code")


def invite_link(code):
    return "%s/i/%s" % (site(), code)


def play_link(code=""):
    url = "https://play.google.com/store/apps/details?id=%s" % play_package()
    if code:
        # Play passes `referrer` to the install-referrer API; harmless when the
        # app does not read it (the code is also shown on the landing page).
        url += "&referrer=ref%%3D%s" % code
    return url


def share_text(code, lang):
    link = invite_link(code)
    return pick(lang,
                "Assisto ব্যবহার করে দেখুন — বাংলায় AI সহকারী, রিমাইন্ডার, হিসাব ও "
                "পরিবারের নিরাপত্তা এক অ্যাপে। আমার আমন্ত্রণ কোড: %s\n%s" % (code, link),
                "Try Assisto — an AI assistant in Bangla and English, with reminders, "
                "money notes and family safety in one app. My invite code: %s\n%s"
                % (code, link))


# ------------------------------------------------------------------ activity
def touch(user, now=None):
    """Record that `user` used the app today (once per local day). Called from
    token authentication; never raises. Returns True when a new day was
    written (then pending rewards / founding seat are re-evaluated)."""
    try:
        if user is None or not getattr(user, "pk", None):
            return False
        now = now or timezone.now()
        today = timezone.localdate(now)
        la = getattr(user, "last_active", None)
        if la is not None and timezone.localdate(la) == today:
            return False
        from .models import ActiveDay, User
        cohort = timezone.localdate(user.date_joined) if user.date_joined else today
        ActiveDay.objects.bulk_create(
            [ActiveDay(user_id=user.pk, day=today, cohort_day=cohort,
                       since_signup=max(0, (today - cohort).days))],
            ignore_conflicts=True)
        User.objects.filter(pk=user.pk).update(last_active=now)
        user.last_active = now
        try:
            evaluate(user, now=now)
        except Exception:
            pass
        return True
    except Exception:
        return False


def active_days_in_window(user):
    from .models import ActiveDay
    return ActiveDay.objects.filter(
        user_id=user.pk, since_signup__lt=ACTIVATION_WINDOW_DAYS).count()


def sms_on():
    try:
        from . import otp
        return bool(otp.sms_available())
    except Exception:
        return False


def phone_ok(user):
    from .phone import canonical_phone
    canon = canonical_phone(getattr(user, "phone", "") or "")
    if not canon:
        return False
    if not sms_on():
        return True
    from .models import PhoneVerification
    pv = PhoneVerification.objects.filter(user_id=user.pk).first()
    return bool(pv) and canonical_phone(pv.phone) == canon


def activation(user, c=None):
    c = c or cfg()
    need = int(c["invite_activation_days"])
    days = active_days_in_window(user)
    ph = phone_ok(user)
    return {"days": days, "need": need, "phone_ok": ph, "sms_on": sms_on(),
            "activated": bool(ph and days >= need)}


# ------------------------------------------------------------------ claim
def claim(invitee, raw_code, device_id="", now=None):
    """The invitee enters an invite code. Returns (ok, reason, ReferralClaim|None).
    Nothing is granted here — only when the invitee is activated."""
    from .models import InstallPing, ReferralClaim, User
    from .phone import canonical_phone
    now = now or timezone.now()
    c = cfg()
    code = normalize_code(raw_code)
    if not code:
        return False, "bad_code", None
    if ReferralClaim.objects.filter(invitee_id=invitee.pk).exists():
        return False, "already_claimed", None
    joined = invitee.date_joined or now
    if now - joined > timedelta(days=int(c["invite_claim_days"])):
        return False, "too_late", None
    inviter = User.objects.filter(referral_code=code).first()
    if inviter is None or not inviter.is_active or \
            getattr(inviter, "account_status", "active") != "active":
        return False, "bad_code", None
    if inviter.pk == invitee.pk:
        return False, "self", None
    if inviter.date_joined and inviter.date_joined > joined:
        return False, "not_eligible", None
    dh = _h("dev:%s" % device_id) if device_id else ""
    if dh and InstallPing.objects.filter(user_id=inviter.pk, device_hash=dh).exists():
        return False, "self", None
    if dh and ReferralClaim.objects.filter(device_hash=dh).exclude(
            state="rejected").exists():
        return False, "device_used", None
    canon = canonical_phone(getattr(invitee, "phone", "") or "")
    ph = _h("ph:%s" % canon) if canon else ""
    if ph and ReferralClaim.objects.filter(phone_hash=ph).exists():
        return False, "phone_used", None
    try:
        with transaction.atomic():
            row = ReferralClaim.objects.create(
                inviter=inviter, invitee=invitee, code=code, device_hash=dh,
                phone_hash=ph)
    except IntegrityError:
        return False, "already_claimed", None
    if not invitee.referred_by:
        User.objects.filter(pk=invitee.pk).update(referred_by=code)
        invitee.referred_by = code
    try:
        evaluate(invitee, now=now)
        row.refresh_from_db()
    except Exception:
        pass
    return True, "ok", row


def _month_start(now):
    lt = timezone.localtime(now)
    return lt.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def _book_cost(credits):
    """Book reward credits as Profit Guard variable cost 'growth' (৳)."""
    amt = round(credits * cost_per_credit(), 2)
    if amt > 0:
        try:
            from . import billing
            billing.record_cost("growth", amt)
        except Exception:
            pass
    return Decimal(str(amt))


def _reward(claim_id, c, now):
    from . import billing
    from .models import ReferralClaim
    with transaction.atomic():
        row = ReferralClaim.objects.select_for_update().filter(
            pk=claim_id, state="pending").first()
        if row is None:
            return None
        inviter = row.inviter
        give_inviter = int(c["invite_credits_inviter"])
        reason = "ok"
        if inviter is None or not inviter.is_active or \
                getattr(inviter, "account_status", "active") != "active":
            give_inviter, reason = 0, "inviter_gone"
        else:
            done = ReferralClaim.objects.filter(
                inviter_id=inviter.pk, state="rewarded", inviter_credits__gt=0,
                decided_at__gte=_month_start(now)).count()
            if done >= int(c["invite_monthly_cap"]):
                give_inviter, reason = 0, "inviter_cap"
        give_invitee = int(c["invite_credits_invitee"])
        if give_inviter:
            billing.credit(inviter, "grant", give_inviter, note="referral:inviter")
        if give_invitee and row.invitee is not None:
            billing.credit(row.invitee, "grant", give_invitee, note="referral:invitee")
        row.state = "rewarded"
        row.reason = reason
        row.inviter_credits = give_inviter
        row.invitee_credits = give_invitee
        row.cost_bdt = _book_cost(give_inviter + give_invitee)
        row.decided_at = now
        row.save(update_fields=["state", "reason", "inviter_credits",
                                "invitee_credits", "cost_bdt", "decided_at"])
    _notify_inviter(row)
    return row


def _notify_inviter(row):
    """Best-effort in-app alert to the inviter (no phone/name of the invitee)."""
    if not row.inviter_credits or row.inviter is None:
        return
    try:
        from .models import FamilyAlert
        lang = getattr(row.inviter, "language", "bn")
        FamilyAlert.objects.create(
            user=row.inviter, kind="referral", severity="info",
            title=pick(lang, "আমন্ত্রণের ক্রেডিট পেয়েছেন", "Invite credits received"),
            body=pick(lang, "আপনার আমন্ত্রিত একজন বন্ধু Assisto চালু করেছেন। %d ক্রেডিট যোগ হয়েছে।",
                      "A friend you invited started using Assisto. %d credits added.")
            % row.inviter_credits)
    except Exception:
        pass


def evaluate(user, now=None):
    """Re-check the user's pending invite reward and Founding seat. Idempotent."""
    from .models import FoundingSeat, ReferralClaim
    now = now or timezone.now()
    c = cfg()
    act = None
    pending = ReferralClaim.objects.filter(invitee_id=user.pk, state="pending").first()
    if pending is not None:
        act = activation(user, c)
        if act["activated"]:
            _reward(pending.pk, c, now)
        elif user.date_joined and now - user.date_joined > timedelta(
                days=ACTIVATION_WINDOW_DAYS + 1):
            ReferralClaim.objects.filter(pk=pending.pk, state="pending").update(
                state="rejected", reason="not_activated", decided_at=now)
    seats = int(c["founding_auto_seats"])
    if seats > 0 and not FoundingSeat.objects.filter(user_id=user.pk).exists():
        act = act or activation(user, c)
        if act["activated"]:
            grant_seat(user, c, now)


def grant_seat(user, c=None, now=None):
    """Give the next Founding seat if any is left. Returns the seat or None."""
    from . import billing
    from .models import FoundingSeat
    c = c or cfg()
    seats = int(c["founding_auto_seats"])
    for _ in range(5):
        taken = FoundingSeat.objects.count()
        if taken >= seats:
            return None
        if FoundingSeat.objects.filter(user_id=user.pk).exists():
            return FoundingSeat.objects.get(user_id=user.pk)
        last = FoundingSeat.objects.order_by("-number").first()
        num = (last.number if last else 0) + 1
        if num > seats:
            return None
        credits = int(c["founding_seat_credits"])
        try:
            with transaction.atomic():
                seat = FoundingSeat.objects.create(user=user, number=num, credits=credits)
                if credits:
                    billing.credit(user, "grant", credits, note="founding:%d" % num)
                seat.cost_bdt = _book_cost(credits)
                seat.save(update_fields=["cost_bdt"])
            return seat
        except IntegrityError:
            continue      # a concurrent grant took this number (or this user)
    return None


# ------------------------------------------------------------------ install ping
def install_ping(install_id, user=None, platform="android", app_version="",
                 ref="", device_id=""):
    """Record the first open of an install (idempotent). Links the user when
    the same install later sends the ping signed in."""
    from .models import InstallPing
    iid = str(install_id or "").strip()
    if not (16 <= len(iid) <= 128):
        return False
    h = _h("inst:%s" % iid)
    dh = _h("dev:%s" % device_id) if device_id else ""
    row, created = InstallPing.objects.get_or_create(
        id_hash=h, defaults={
            "platform": str(platform or "android")[:12],
            "app_version": str(app_version or "")[:24],
            "ref_code": normalize_code(ref)[:12], "device_hash": dh,
            "user": user if (user is not None and user.pk) else None})
    upd = []
    if not created and user is not None and user.pk and row.user_id is None:
        row.user = user
        upd.append("user")
    if not created and dh and not row.device_hash:
        row.device_hash = dh
        upd.append("device_hash")
    if upd:
        row.save(update_fields=upd)
    return created


# ------------------------------------------------------------------ app summary
def summary(user, lang="bn", now=None):
    """GET /growth/me — everything the invite screen shows, from real rows."""
    from django.db.models import Sum
    from .models import FoundingSeat, ReferralClaim
    now = now or timezone.now()
    c = cfg()
    code = ensure_code(user)
    made = ReferralClaim.objects.filter(inviter_id=user.pk)
    rewarded = made.filter(state="rewarded")
    month_used = rewarded.filter(inviter_credits__gt=0,
                                 decided_at__gte=_month_start(now)).count()
    mine = ReferralClaim.objects.filter(invitee_id=user.pk).first()
    act = activation(user, c)
    joined = user.date_joined or now
    can_claim = (mine is None and
                 now - joined <= timedelta(days=int(c["invite_claim_days"])))
    seat = FoundingSeat.objects.filter(user_id=user.pk).first()
    taken = FoundingSeat.objects.count()
    return {
        "code": code,
        "link": invite_link(code),
        "share_text": share_text(code, lang),
        "rules": {
            "inviter_credits": int(c["invite_credits_inviter"]),
            "invitee_credits": int(c["invite_credits_invitee"]),
            "monthly_cap": int(c["invite_monthly_cap"]),
            "claim_days": int(c["invite_claim_days"]),
            "activation_days": int(c["invite_activation_days"]),
            "activation_window_days": ACTIVATION_WINDOW_DAYS,
            "phone_otp": act["sms_on"],
        },
        "stats": {
            "joined": made.count(),
            "pending": made.filter(state="pending").count(),
            "rewarded": rewarded.count(),
            "credits_earned": int(rewarded.aggregate(s=Sum("inviter_credits"))["s"] or 0),
            "month_used": month_used,
        },
        "my_claim": None if mine is None else {
            "state": mine.state, "reason": mine.reason,
            "credits": mine.invitee_credits,
            "days": act["days"], "need": act["need"], "phone_ok": act["phone_ok"]},
        "can_claim": can_claim,
        "founding": {
            "enabled": int(c["founding_auto_seats"]) > 0,
            "seats": int(c["founding_auto_seats"]),
            "taken": taken,
            "number": seat.number if seat else None,
            "credits": int(c["founding_seat_credits"]),
            "my_credits": seat.credits if seat else 0,
            "activation": {"days": act["days"], "need": act["need"],
                           "phone_ok": act["phone_ok"]},
        },
    }


def claim_message(reason, lang="bn"):
    m = {
        "ok": ("কোড যুক্ত হয়েছে। আপনি সক্রিয় হলে দুজনেই ক্রেডিট পাবেন।",
               "Code added. You both get credits once you are active."),
        "bad_code": ("এই কোডটি সঠিক নয়।", "That code isn't valid."),
        "already_claimed": ("আপনি আগেই একটি কোড দিয়েছেন।", "You have already entered a code."),
        "too_late": ("সাইন আপের পর কোড দেওয়ার সময় শেষ।",
                     "The time to enter a code after signing up has passed."),
        "self": ("নিজের কোড দেওয়া যায় না।", "You can't use your own code."),
        "not_eligible": ("এই কোডটি আপনার অ্যাকাউন্টে ব্যবহার করা যাবে না।",
                         "This code can't be used on your account."),
        "device_used": ("এই ফোনে আগেই একটি আমন্ত্রণ ব্যবহার হয়েছে।",
                        "An invite was already used on this phone."),
        "phone_used": ("এই নম্বরে আগেই একটি আমন্ত্রণ ব্যবহার হয়েছে।",
                       "An invite was already used with this number."),
    }
    bn, en = m.get(reason, m["bad_code"])
    return pick(lang, bn, en)
