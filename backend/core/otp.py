"""
OTP engine (o1-otp) — SMS one-time codes, purpose-bound, provider-agnostic.

Public helper API (also used by other slots — see .phaseB/OTP_API.md):

    issue(phone, purpose, request=None, user=None, lang=None) -> dict
    verify(phone, purpose, code)                               -> raw otp_proof
    consume_proof(token, purpose, phone=None)                  -> canonical phone | None

All three raise OtpError(reason, http_status, **extra) on failure (consume_proof
returns None instead — callers decide the response).

Security properties
  * 6-digit code from `secrets`, 5-minute expiry (admin-editable).
  * Stored ONLY as HMAC-SHA256(SECRET_KEY, salt|phone|purpose|code) with a
    per-code random salt. Plaintext is never stored and never logged.
  * Verify uses hmac.compare_digest (constant time).
  * Purpose binding: the purpose is inside the HMAC AND the lookup; a code
    issued for 'signup' can never verify for 'login'.
  * Max attempts per challenge, then the phone+purpose is LOCKED for N minutes.
  * Resend cooldown per phone+purpose; hourly caps per phone, per IP, per device.
  * A successful verify returns a short-lived SINGLE-USE otp_proof token (only
    its SHA-256 is stored); the target endpoint consumes it atomically.
  * Key-gated: nothing is sent unless the "sms" integration is CONNECTED
    (owner pasted a key in Integrations and the honest Test passed).
"""
import hashlib
import hmac
import re
import secrets
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from .i18n import pick

PURPOSES = ("signup", "login", "password_reset", "delete_account", "section8",
            "change_number")
# Purposes that only make sense for a signed-in user.
AUTHED_PURPOSES = ("delete_account", "section8", "change_number")
CODE_LENGTH = 6


class OtpError(Exception):
    def __init__(self, reason, http_status=400, **extra):
        super().__init__(reason)
        self.reason = reason
        self.http_status = http_status
        self.extra = extra

    def body(self, lang="bn"):
        return {"ok": False, "reason": self.reason,
                "message": message(self.reason, lang, **self.extra), **self.extra}


# ------------------------------------------------------------------ phones
_BD_MOBILE = re.compile(r"^1[3-9]\d{8}$")


def normalize_bd_phone(raw):
    """01XXXXXXXXX | +8801XXXXXXXXX | 8801XXXXXXXXX | 008801… → '+8801XXXXXXXXX'.
    Spaces, dashes, dots, brackets and Bangla digits are accepted. Anything
    else → None. c1-contacts: delegates to THE canonical helper core.phone."""
    from .phone import canonical_bd
    return canonical_bd(raw)


def local_form(canon):
    """'+8801XXXXXXXXX' → '01XXXXXXXXX' (how most users type it)."""
    return "0" + canon[4:] if canon else canon


def phone_variants(canon):
    if not canon:
        return []
    return [local_form(canon), canon, canon[1:]]


def mask(canon):
    if not canon:
        return ""
    lf = local_form(canon)
    return lf[:3] + "•" * (len(lf) - 6) + lf[-3:]


def find_user_by_phone(canon):
    from .models import User
    if not canon:
        return None
    from .phone import variants
    return (User.objects.filter(phone__in=variants(canon)).order_by("id")
            .first())


def user_phone(user):
    return normalize_bd_phone(getattr(user, "phone", "") or "")


# ------------------------------------------------------------------ config
def limits():
    from .logic import pricing as P
    try:
        from . import billing
        return P.otp_limits(billing.get_config().data)
    except Exception:  # noqa: BLE001
        return P.otp_limits({})


def sms_available():
    """True only when the SMS gateway integration is CONNECTED (key pasted +
    honest Test passed). This is the single switch for every OTP surface."""
    try:
        from . import integrations
        return integrations.is_enabled("sms")
    except Exception:  # noqa: BLE001
        return False


def password_only_signup_allowed():
    """Launch gate (admin flag `auth_password_only_signup`, default ON)."""
    from . import billing
    return billing.flag_on("auth_password_only_signup", True)


def otp_required_for(user):
    """Sensitive actions (delete-account, Section 8) require an OTP proof only
    when SMS can actually deliver one AND the user has a valid BD mobile. With
    SMS off they degrade honestly to their other factors (password / PIN)."""
    return sms_available() and bool(user_phone(user))


# ------------------------------------------------------------------ hashing
def _hash(salt, phone, purpose, code):
    key = (settings.SECRET_KEY or "").encode("utf-8")
    msg = f"{salt}|{phone}|{purpose}|{code}".encode("utf-8")
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def _sha(raw):
    return hashlib.sha256((raw or "").encode("utf-8")).hexdigest()


def _gen_code():
    return f"{secrets.randbelow(10 ** CODE_LENGTH):0{CODE_LENGTH}d}"


# ------------------------------------------------------------------ request ctx
def client_ip(request):
    if request is None:
        return ""
    meta = request.META
    remote = meta.get("REMOTE_ADDR", "") or ""
    # nginx (deploy) proxies from loopback and OVERWRITES X-Forwarded-For with
    # $remote_addr, so trust it only when the hop is local.
    if remote in ("127.0.0.1", "::1"):
        xff = (meta.get("HTTP_X_FORWARDED_FOR") or "").split(",")[-1].strip()
        if xff:
            return xff[:64]
    return remote[:64]


def device_id(request):
    if request is None:
        return ""
    v = (request.META.get("HTTP_X_DEVICE_ID") or "")
    if not v:
        try:
            v = str((request.data or {}).get("device_id") or "")
        except Exception:  # noqa: BLE001
            v = ""
    return v.strip()[:128]


# ------------------------------------------------------------------ messages
def sms_text(code, lang, ttl_seconds, app_hash=""):
    mins = max(1, ttl_seconds // 60)
    if lang == "en":
        txt = (f"Assisto: your code is {code}. It expires in {mins} min. "
               f"Never share it — Assisto will never ask for it.")
    else:
        bn_digits = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
        txt = (f"Assisto: আপনার কোড {code}। {str(mins).translate(bn_digits)} মিনিটে "
               f"মেয়াদ শেষ। কাউকে বলবেন না — Assisto কখনো এই কোড চায় না।")
    if app_hash:
        txt = txt + "\n" + app_hash.strip()[:11]
    return txt


_MSG = {
    "sms_not_configured": (
        "OTP এখন বন্ধ — SMS প্রোভাইডার যুক্ত করা হয়নি। ফোন/ইমেইল ও পাসওয়ার্ড দিয়ে লগইন করুন।",
        "OTP is off for now — no SMS provider is set up yet. Sign in with your phone/email and password."),
    "bad_phone": ("সঠিক বাংলাদেশি মোবাইল নম্বর দিন (01XXXXXXXXX)।",
                  "Enter a valid Bangladeshi mobile number (01XXXXXXXXX)."),
    "bad_purpose": ("অজানা উদ্দেশ্য।", "Unknown purpose."),
    "auth_required": ("এজন্য আগে লগইন করুন।", "Please sign in first."),
    "phone_mismatch": ("এই নম্বরটি আপনার অ্যাকাউন্টের নম্বর নয়।",
                       "That number isn't the one on your account."),
    "already_registered": ("এই ফোন নম্বর আগে থেকেই আছে। লগইন করুন।",
                           "This phone number is already registered. Please sign in."),
    "cooldown": ("একটু অপেক্ষা করে আবার কোড চান।", "Please wait a moment before asking for a new code."),
    "rate_limited": ("অনেকবার চেষ্টা হয়েছে। কিছুক্ষণ পরে আবার চেষ্টা করুন।",
                     "Too many requests. Please try again later."),
    "locked": ("অনেকবার ভুল কোড। কিছুক্ষণের জন্য বন্ধ — পরে আবার চেষ্টা করুন।",
               "Too many wrong codes. Locked for a while — please try again later."),
    "send_failed": ("SMS পাঠানো যায়নি। একটু পরে আবার চেষ্টা করুন।",
                    "We couldn't send the SMS. Please try again shortly."),
    "invalid_code": ("কোডটি মেলেনি। আবার দেখে লিখুন।", "That code didn't match. Please check and try again."),
    "expired": ("কোডের মেয়াদ শেষ। নতুন কোড চান।", "That code has expired. Ask for a new one."),
    "no_active_code": ("কোনো সক্রিয় কোড নেই। নতুন কোড চান।", "No active code. Ask for a new one."),
    "otp_required": ("এই কাজের জন্য আপনার ফোনে পাঠানো কোড দিয়ে নিশ্চিত করুন।",
                     "Confirm this with the code sent to your phone."),
    "bad_otp": ("যাচাই কোড সঠিক নয় বা মেয়াদ শেষ। আবার কোড চান।",
                "The verification is invalid or expired. Ask for a new code."),
    "sent": ("কোড পাঠানো হয়েছে।", "Code sent."),
    "sent_neutral": ("এই নম্বরে অ্যাকাউন্ট থাকলে একটি কোড পাঠানো হয়েছে।",
                     "If an account exists for this number, a code has been sent."),
}


def message(reason, lang="bn", **_):
    bn, en = _MSG.get(reason, ("কিছু একটা ভুল হয়েছে।", "Something went wrong."))
    return pick(lang, bn, en)


# ------------------------------------------------------------------ core API
def _check_purpose(purpose):
    if purpose not in PURPOSES:
        raise OtpError("bad_purpose", 400)


def _canon_or_raise(phone):
    canon = normalize_bd_phone(phone)
    if not canon:
        raise OtpError("bad_phone", 400)
    return canon


def _active_lock(canon, purpose, now):
    from .models import OtpChallenge
    row = (OtpChallenge.objects.filter(phone=canon, purpose=purpose,
                                       locked_until__gt=now)
           .order_by("-locked_until").first())
    return row.locked_until if row else None


def _retry(dt, now):
    return max(1, int((dt - now).total_seconds()))


def issue(phone, purpose, request=None, user=None, lang=None, send=True):
    """Create + send a code. Returns {ok, sent, phone_masked, expires_in,
    resend_in, code_length}. `send=False` performs every check and counts
    against the limits but creates/sends nothing (anti-enumeration path for
    login/reset to an unknown number — no SMS cost, same response)."""
    from .models import OtpChallenge
    _check_purpose(purpose)
    if not sms_available():
        raise OtpError("sms_not_configured", 503, sms_enabled=False)
    canon = _canon_or_raise(phone)
    lim = limits()
    now = timezone.now()
    lang = lang or "bn"

    locked = _active_lock(canon, purpose, now)
    if locked:
        raise OtpError("locked", 423, retry_after=_retry(locked, now))

    last = (OtpChallenge.objects.filter(phone=canon, purpose=purpose)
            .order_by("-created_at").first())
    cd = lim["resend_cooldown_seconds"]
    if last and (now - last.created_at).total_seconds() < cd:
        raise OtpError("cooldown", 429,
                       retry_after=_retry(last.created_at + timedelta(seconds=cd), now))

    hour = now - timedelta(hours=1)
    ip = client_ip(request)
    dev = device_id(request)
    recent = OtpChallenge.objects.filter(created_at__gt=hour)
    if recent.filter(phone=canon).count() >= lim["per_phone_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)
    if ip and recent.filter(ip=ip).count() >= lim["per_ip_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)
    if dev and recent.filter(device_id=dev).count() >= lim["per_device_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)

    ttl = lim["ttl_seconds"]
    out = {"ok": True, "sms_enabled": True, "purpose": purpose,
           "phone_masked": mask(canon), "expires_in": ttl, "resend_in": cd,
           "code_length": CODE_LENGTH}

    # Supersede earlier live codes for this phone+purpose (only the newest works).
    OtpChallenge.objects.filter(phone=canon, purpose=purpose,
                                consumed_at__isnull=True).update(consumed_at=now)

    code = _gen_code() if send else ""
    salt = secrets.token_hex(16)
    ch = OtpChallenge.objects.create(
        phone=canon, purpose=purpose,
        code_hash=_hash(salt, canon, purpose, code) if send else "",
        salt=salt, created_at=now, expires_at=now + timedelta(seconds=ttl),
        ip=ip, device_id=dev, sent=False,
        consumed_at=None if send else now)   # a not-sent row never verifies
    if not send:
        ch.detail = "not sent (no account)"
        ch.save(update_fields=["detail"])
        return out

    from . import sms_gateway
    ad = sms_gateway.adapter()
    if ad is None:
        ch.consumed_at = now
        ch.save(update_fields=["consumed_at"])
        raise OtpError("sms_not_configured", 503, sms_enabled=False)
    app_hash = ad.cfg.get("app_hash", "") or ""
    ok, detail = ad.send(canon, sms_text(code, lang, ttl, app_hash), secret=code)
    del code
    ch.sent = bool(ok)
    ch.detail = (detail or "")[:200]
    if not ok:
        ch.consumed_at = now
    ch.save(update_fields=["sent", "detail", "consumed_at"])
    if not ok:
        raise OtpError("send_failed", 502)
    return out


def verify(phone, purpose, code):
    """Check `code` for phone+purpose. Returns the RAW otp_proof token (give it
    to the client once; only its hash is stored). Raises OtpError."""
    from .models import OtpChallenge, OtpProof
    _check_purpose(purpose)
    canon = _canon_or_raise(phone)
    now = timezone.now()
    lim = limits()

    locked = _active_lock(canon, purpose, now)
    if locked:
        raise OtpError("locked", 423, retry_after=_retry(locked, now))

    ch = (OtpChallenge.objects.filter(phone=canon, purpose=purpose,
                                      consumed_at__isnull=True, sent=True)
          .order_by("-created_at").first())
    if ch is None:
        raise OtpError("no_active_code", 400)
    if ch.expires_at <= now:
        ch.consumed_at = now
        ch.save(update_fields=["consumed_at"])
        raise OtpError("expired", 400)

    supplied = re.sub(r"\D", "", str(code or ""))[:CODE_LENGTH]
    good = (len(supplied) == CODE_LENGTH and
            hmac.compare_digest(_hash(ch.salt, canon, purpose, supplied), ch.code_hash))
    if not good:
        ch.attempts += 1
        fields = ["attempts"]
        left = lim["max_attempts"] - ch.attempts
        if left <= 0:
            ch.consumed_at = now
            ch.locked_until = now + timedelta(minutes=lim["lockout_minutes"])
            fields += ["consumed_at", "locked_until"]
            ch.save(update_fields=fields)
            raise OtpError("locked", 423, retry_after=_retry(ch.locked_until, now))
        ch.save(update_fields=fields)
        raise OtpError("invalid_code", 400, attempts_left=left)

    # Burn the challenge atomically (a concurrent second verify can't also win).
    won = OtpChallenge.objects.filter(pk=ch.pk, consumed_at__isnull=True).update(
        consumed_at=now)
    if not won:
        raise OtpError("no_active_code", 400)
    raw = secrets.token_urlsafe(32)
    OtpProof.objects.create(token_hash=_sha(raw), phone=canon, purpose=purpose,
                            created_at=now,
                            expires_at=now + timedelta(seconds=lim["proof_ttl_seconds"]))
    return raw


def consume_proof(token, purpose, phone=None):
    """Single-use: returns the proven canonical phone and burns the proof, or
    None when the token is unknown / used / expired / for another purpose /
    for another phone. `phone` (any BD format) adds a binding check."""
    from .models import OtpProof
    if not token or purpose not in PURPOSES:
        return None
    now = timezone.now()
    qs = OtpProof.objects.filter(token_hash=_sha(str(token)), purpose=purpose,
                                 used_at__isnull=True, expires_at__gt=now)
    if phone is not None:
        canon = normalize_bd_phone(phone)
        if not canon:
            return None
        qs = qs.filter(phone=canon)
    row = qs.first()
    if row is None:
        return None
    if not OtpProof.objects.filter(pk=row.pk, used_at__isnull=True).update(used_at=now):
        return None
    return row.phone


def mark_verified(user, canon):
    from .models import PhoneVerification
    PhoneVerification.objects.update_or_create(
        user=user, defaults={"phone": canon, "verified_at": timezone.now()})


def public_status():
    lim = limits()
    return {"sms_enabled": sms_available(),
            "password_only_signup": password_only_signup_allowed(),
            "code_length": CODE_LENGTH,
            "expires_in": lim["ttl_seconds"],
            "resend_in": lim["resend_cooldown_seconds"],
            "purposes": list(PURPOSES)}
