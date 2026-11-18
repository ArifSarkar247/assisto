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
  * Key-gated: nothing is sent unless an SMS gateway integration is CONNECTED
    (owner pasted a key in Integrations and the honest Test passed).

smsotp additions
  * SMS goes through core/sms_service.send_sms (per-purpose per-day caps,
    primary → secondary failover, cost logging). OTP purposes map to the
    "otp" bucket, sign-up / change-number / booking to "phone_verify".
  * EMAIL channel (backup): issue_email(...) sends the same 6-digit code to a
    VERIFIED email address (core/email_sender, Gmail SMTP, rolling-24 h cap).
    Identity is either the account's phone (code delivered by email — the
    proof then carries channel "email" and never marks the phone verified) or
    the email address itself (purpose email_verify / email login). The same
    lockout, cooldown (per channel) and hourly limits per phone / email / IP /
    device apply. Never for sign-up / change-number / booking: email can't
    prove a phone number.
"""
import hashlib
import hmac
import logging
import os
import re
import secrets
import time
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from .i18n import pick

# signup-otp: one structured line per send attempt — channel, purpose,
# result, provider reason and latency. NEVER the phone, address or code.
log = logging.getLogger("assisto.otp")

PURPOSES = ("signup", "login", "password_reset", "delete_account", "section8",
            "change_number",
            # booking-bot: a guest proves the phone they book with (public page)
            "booking",
            # smsotp: prove an email address (signed-in user, email channel only)
            "email_verify",
            # vault100: prove it is you before a forgotten vault PIN is reset
            # (the PIN itself never leaves the phone — see core/vault_recovery)
            "vault_reset",
            # recovery: prove the NEW number a lost-phone recovery request
            # will be finished on (support recovery, core/account_recovery)
            "account_recovery")
# Purposes that only make sense for a signed-in user.
AUTHED_PURPOSES = ("delete_account", "section8", "change_number", "email_verify",
                   "vault_reset")
# Own-account purposes: the code goes to the SIGNED-IN user's phone / verified
# email only (never to a number typed by the caller).
OWN_ACCOUNT_PURPOSES = ("delete_account", "section8", "vault_reset")
# smsotp: purposes a code may be delivered for by EMAIL
EMAIL_PURPOSES = ("login", "password_reset", "delete_account", "section8", "email_verify",
                  "vault_reset")
# smsotp: core/sms_service purpose bucket per OTP purpose
PHONE_VERIFY_PURPOSES = ("signup", "change_number", "booking", "account_recovery")


def sms_purpose(purpose):
    return "phone_verify" if purpose in PHONE_VERIFY_PURPOSES else "otp"
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
    c = canonical_bd(raw)
    if c:
        return c
    rc = reviewer_canon()
    if rc:  # the Play reviewer number is outside the real BD mobile ranges
        from .phone import to_ascii_digits
        d = re.sub(r"\D", "", to_ascii_digits(str(raw or "")))
        if d.startswith("00"):
            d = d[2:]
        if d.startswith("880"):
            d = "0" + d[3:]
        if d == "0" + rc[4:]:
            return rc
    return None


# ------------------------------------------------------- Play reviewer login
# Google Play's review team signs in with ONE fixed demo number and ONE fixed
# login code. Both live only in the server's .env (PLAY_REVIEWER_PHONE,
# PLAY_REVIEWER_OTP), never in git. Only that number, only purpose "login",
# no SMS is sent; attempts/lockout/cooldown limits still apply.
def reviewer_canon():
    d = re.sub(r"\D", "", os.environ.get("PLAY_REVIEWER_PHONE", ""))
    if len(d) == 11 and d.startswith("01"):
        return "+880" + d[1:]
    return None


def _reviewer_code(canon, purpose):
    code = re.sub(r"\D", "", os.environ.get("PLAY_REVIEWER_OTP", ""))
    if (purpose == "login" and canon and canon == reviewer_canon()
            and len(code) == CODE_LENGTH):
        return code
    return None


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


# recovery (owner order Part 8): adding / verifying an email while signed in
# — the code lives 10 minutes and may be re-sent after 45 seconds (5 tries,
# then the usual lockout). Every other purpose keeps the admin limits.
PURPOSE_LIMITS = {"email_verify": {"ttl_seconds": 600, "resend_cooldown_seconds": 45,
                                   "max_attempts": 5}}


def purpose_limits(purpose, lim=None):
    out = dict(lim if lim is not None else limits())
    out.update(PURPOSE_LIMITS.get(purpose, {}))
    return out


def sms_available():
    """True only when an SMS gateway integration is CONNECTED (key pasted +
    honest Test passed). This is the single switch for every OTP surface —
    config-driven: no flag, no build."""
    try:
        from . import sms_gateway
        return sms_gateway.ready()
    except Exception:  # noqa: BLE001
        return False


def email_available():
    """The company email entry is CONNECTED and under its rolling-24 h cap."""
    try:
        from . import email_sender
        return email_sender.available()
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
def _key(phone="", email=""):
    """The identity inside the HMAC: the canonical phone, or email:<addr>."""
    return phone if phone else "email:" + (email or "")


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
               # smsotp: ASCII hyphen keeps this GSM-7 = ONE SMS segment
               f"Never share it - Assisto will never ask for it.")
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
    # smsotp
    "sms_daily_cap": ("আজকের SMS সীমা শেষ। ইমেইলে কোড নিন বা পাসওয়ার্ড দিয়ে লগইন করুন।",
                      "Today's SMS limit is used up. Get the code by email or sign in with your password."),
    "email_not_configured": ("ইমেইলে কোড এখন বন্ধ — ইমেইল সেটআপ হয়নি।",
                             "Codes by email are off for now — email isn't set up yet."),
    "email_daily_cap": ("আজ ইমেইলে আর কোড পাঠানো যাচ্ছে না। SMS দিয়ে চেষ্টা করুন বা পরে আবার।",
                        "We can't email more codes today. Try SMS, or try again later."),
    "bad_email": ("সঠিক ইমেইল ঠিকানা দিন।", "Enter a valid email address."),
    "email_purpose_not_allowed": ("এই কাজের কোড ইমেইলে পাঠানো যায় না — SMS লাগবে।",
                                  "This code can't be sent by email — it needs SMS."),
    "no_verified_email": ("আপনার কোনো যাচাই-করা ইমেইল নেই। প্রোফাইলে ইমেইল যোগ করে যাচাই করুন।",
                          "You have no verified email. Add and verify one in your profile."),
    "sent_email": ("ইমেইলে কোড পাঠানো হয়েছে। Spam ফোল্ডারও দেখুন।",
                   "Code sent by email. Check your Spam folder too."),
    # signup-otp: new people read this as "your sign-up code is coming" —
    # say plainly that sign-up needs no code
    "sent_email_neutral": ("এই অ্যাকাউন্টে যাচাই-করা ইমেইল থাকলে সেখানে কোড গেছে — Spam ফোল্ডারও দেখুন। নতুন হলে কোড লাগবে না: ফিরে গিয়ে \"প্রোফাইল তৈরি করুন\" চাপুন। ২ মিনিটে না এলে পাসওয়ার্ড বা SMS দিয়ে ঢুকুন।",
                           "If this account has a verified email, the code is on its way — check Spam too. New to Assisto? No code is needed: go back and tap Create a profile. Not there in 2 minutes? Sign in with your password or by SMS."),
    # emailrel: honest email failures, each with the way out
    "email_send_failed": ("ইমেইল এখন পাঠানো যায়নি (মেইল সার্ভারে সাময়িক সমস্যা)। SMS-এ কোড নিন, বা কয়েক মিনিট পরে আবার চেষ্টা করুন।",
                          "We couldn't send the email right now (the mail server had a temporary problem). Get the code by SMS, or try again in a few minutes."),
    "email_bouncing": ("এই ঠিকানায় ইমেইল পৌঁছায় না (ফেরত এসেছে)। ইমেইল ঠিকানাটি ঠিক আছে কি না দেখুন, অথবা SMS-এ কোড নিন।",
                       "Emails to this address bounce back. Please check your email address, or get the code by SMS."),
    "email_rejected": ("আপনার ইমেইল সার্ভার মেইলটি নেয়নি (ইনবক্স ভরা বা ব্লক)। ইনবক্স দেখুন, অথবা SMS-এ কোড নিন।",
                       "Your email provider refused the message (inbox full or blocked). Check your inbox, or get the code by SMS."),
    "email_verified": ("ইমেইল যাচাই হয়েছে।", "Email verified."),
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


def _ident(phone="", email=""):
    """Queryset filter for one identity (phone, or email-only)."""
    return {"phone": phone} if phone else {"phone": "", "email": email}


def _active_lock(canon, purpose, now, email=""):
    from .models import OtpChallenge
    row = (OtpChallenge.objects.filter(purpose=purpose, locked_until__gt=now,
                                       **_ident(canon, email))
           .order_by("-locked_until").first())
    return row.locked_until if row else None


def _check_limits(purpose, now, lim, request, *, phone="", email="", channel="sms",
                  target_email=""):
    """Lockout, per-channel resend cooldown and hourly caps per phone / email /
    IP / device (shared by SMS and email). Raises OtpError."""
    from .models import OtpChallenge
    locked = _active_lock(phone, purpose, now, email)
    if locked:
        raise OtpError("locked", 423, retry_after=_retry(locked, now))
    last = (OtpChallenge.objects.filter(purpose=purpose, channel=channel,
                                        **_ident(phone, email))
            .order_by("-created_at").first())
    cd = lim["resend_cooldown_seconds"]
    if last and (now - last.created_at).total_seconds() < cd:
        raise OtpError("cooldown", 429,
                       retry_after=_retry(last.created_at + timedelta(seconds=cd), now))
    hour = now - timedelta(hours=1)
    ip = client_ip(request)
    dev = device_id(request)
    recent = OtpChallenge.objects.filter(created_at__gt=hour)
    if phone and recent.filter(phone=phone).count() >= lim["per_phone_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)
    for addr in {a for a in (email, target_email) if a}:
        if recent.filter(email=addr).count() >= lim["per_email_per_hour"]:
            raise OtpError("rate_limited", 429, retry_after=3600)
    if ip and recent.filter(ip=ip).count() >= lim["per_ip_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)
    if dev and recent.filter(device_id=dev).count() >= lim["per_device_per_hour"]:
        raise OtpError("rate_limited", 429, retry_after=3600)
    return ip, dev


def _daily_phone_cap(canon, purpose, now):
    """Pricing → sms.<bucket>_per_phone_day counted on CHALLENGES (sent or
    not), so an unknown number and a real account hit it at the same point
    (no enumeration through the daily cap)."""
    from .models import OtpChallenge
    from . import sms_service
    bucket = sms_purpose(purpose)
    cap = sms_service.caps_for(bucket)["per_phone_day"]
    purposes = PHONE_VERIFY_PURPOSES if bucket == "phone_verify" else \
        tuple(p for p in PURPOSES if p not in PHONE_VERIFY_PURPOSES)
    n = OtpChallenge.objects.filter(phone=canon, channel="sms", purpose__in=purposes,
                                    created_at__gte=sms_service._day_start(now)).count()
    if cap and n >= cap:
        raise OtpError("rate_limited", 429, retry_after=3600)


# ---- signup-otp: idempotent resend + no-PII send log -------------------
def _rid_hash(rid):
    """Short hash of the app's request id (a double tap / retry of the SAME
    request carries the same id). Never the raw id."""
    rid = str(rid or "").strip()[:80]
    return hashlib.sha256(rid.encode()).hexdigest()[:12] if rid else ""


def _tag_rid(ch, rid_h):
    if rid_h:
        ch.detail = ("%s rid=%s" % (ch.detail or "", rid_h)).strip()[:200]
        ch.save(update_fields=["detail"])


def log_send(channel, purpose, result, reason="", provider="", ms=None):
    """One line per send attempt; no phone, address or code (asserted by
    tests_signup_otp)."""
    log.info("otp send channel=%s purpose=%s result=%s reason=%s provider=%s ms=%s",
             channel, purpose, result, (reason or "-")[:40], (provider or "-")[:24],
             "-" if ms is None else int(ms))


def _replay(purpose, channel, now, lim, rid_h, phone="", email=""):
    """Same request id inside the cooldown -> the earlier answer (no second
    code, no second SMS/email, no 429 for a double tap). Only a request
    whose first answer was 'sent' (or the neutral not-sent answer) replays;
    a provider failure never replays as success."""
    if not rid_h:
        return None
    from .models import OtpChallenge
    last = (OtpChallenge.objects.filter(purpose=purpose, channel=channel,
                                        **_ident(phone, email))
            .order_by("-created_at").first())
    if last is None or ("rid=%s" % rid_h) not in (last.detail or ""):
        return None
    age = (now - last.created_at).total_seconds()
    cd = lim["resend_cooldown_seconds"]
    if age >= cd:
        return None
    if not (last.sent or (last.detail or "").startswith("not sent")):
        return None
    return {"resend_in": max(1, int(cd - age)),
            "expires_in": max(0, int((last.expires_at - now).total_seconds())),
            "row": last}


def _retry(dt, now):
    return max(1, int((dt - now).total_seconds()))


def issue(phone, purpose, request=None, user=None, lang=None, send=True,
          request_id=""):
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
    rid_h = _rid_hash(request_id)
    rep = _replay(purpose, "sms", now, lim, rid_h, phone=canon)
    if rep is not None:   # signup-otp: same request again -> same answer
        log_send("sms", purpose, "replay")
        return {"ok": True, "sms_enabled": True, "purpose": purpose,
                "phone_masked": mask(canon), "expires_in": rep["expires_in"],
                "resend_in": rep["resend_in"], "code_length": CODE_LENGTH,
                "already_sent": True}

    ip, dev = _check_limits(purpose, now, lim, request, phone=canon, channel="sms")
    _daily_phone_cap(canon, purpose, now)
    cd = lim["resend_cooldown_seconds"]

    ttl = lim["ttl_seconds"]
    out = {"ok": True, "sms_enabled": True, "purpose": purpose,
           "phone_masked": mask(canon), "expires_in": ttl, "resend_in": cd,
           "code_length": CODE_LENGTH}

    # Supersede earlier live codes for this phone+purpose (only the newest works).
    OtpChallenge.objects.filter(phone=canon, purpose=purpose,
                                consumed_at__isnull=True).update(consumed_at=now)

    fixed = _reviewer_code(canon, purpose) if send else None
    code = (fixed or _gen_code()) if send else ""
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
        _tag_rid(ch, rid_h)
        log_send("sms", purpose, "not_sent", "no_account")
        return out

    if fixed:  # Play reviewer: no SMS, the reviewer already has the code
        del code
        ch.sent = True
        ch.detail = "play reviewer (fixed code, no SMS)"
        ch.save(update_fields=["sent", "detail"])
        _tag_rid(ch, rid_h)
        return out

    from . import sms_gateway, sms_service
    ads = sms_gateway.active()
    if not ads:
        ch.consumed_at = now
        ch.save(update_fields=["consumed_at"])
        log_send("sms", purpose, "failed", "sms_not_configured")
        raise OtpError("sms_not_configured", 503, sms_enabled=False)
    app_hash = (getattr(ads[0], "cfg", {}) or {}).get("app_hash", "") or ""
    t0 = time.monotonic()
    r = sms_service.send_sms(canon, sms_text(code, lang, ttl, app_hash),
                             sms_purpose(purpose), user=user, secret=code, now=now)
    del code
    ms = (time.monotonic() - t0) * 1000
    ok = r["ok"]
    ch.sent = bool(ok)
    ch.detail = ("%s %s %dms" % (r["reason"], r["provider"], ms)).strip()[:180]
    if not ok:
        ch.consumed_at = now
    ch.save(update_fields=["sent", "detail", "consumed_at"])
    log_send("sms", purpose, "sent" if ok else "failed", r.get("reason"),
             r.get("provider"), ms)
    if ok:
        _tag_rid(ch, rid_h)
    if not ok:
        fb = email_available()
        if r["reason"] in ("phone_daily_cap", "user_daily_cap"):
            raise OtpError("rate_limited", 429, retry_after=3600, email_fallback=fb)
        if r["reason"] in ("global_daily_cap", "purpose_off"):
            raise OtpError("sms_daily_cap", 503, email_fallback=fb)
        if r["reason"] == "sms_not_configured":
            raise OtpError("sms_not_configured", 503, sms_enabled=False)
        raise OtpError("send_failed", 502, email_fallback=fb)
    out["segments"] = r["segments"]
    return out


def issue_email(purpose, *, phone=None, email=None, target=None, request=None,
                lang=None, send=True, request_id="", notice_if_unknown=False):
    """smsotp: create + EMAIL a code. Identity = `phone` (any BD format; the
    code is delivered to `target`, the account's verified address) or `email`
    (email-only identity; delivered to that same address). `send=False`
    counts against every limit but sends nothing (anti-enumeration).
    Returns {ok, channel:"email", expires_in, resend_in, code_length,
    prefer_sms}."""
    from .models import OtpChallenge
    from . import email_sender
    _check_purpose(purpose)
    if purpose not in EMAIL_PURPOSES:
        raise OtpError("email_purpose_not_allowed", 400)
    if not email_sender.configured():
        raise OtpError("email_not_configured", 503, email_enabled=False)
    cap = email_sender.cap_state()
    if cap["blocked"]:
        raise OtpError("email_daily_cap", 503, prefer_sms=True)
    canon = ""
    addr = ""
    if phone:
        canon = _canon_or_raise(phone)
    else:
        addr = email_sender.normalize_email(email)
        if not addr:
            raise OtpError("bad_email", 400)
    tgt = email_sender.normalize_email(target or addr) or ""
    lim = purpose_limits(purpose)   # recovery: email_verify = 10 min / 45 s
    now = timezone.now()
    lang = lang or "bn"
    rid_h = _rid_hash(request_id)
    rep = _replay(purpose, "email", now, lim, rid_h, phone=canon, email=addr)
    if rep is not None:   # signup-otp: same request again -> same answer
        log_send("email", purpose, "replay")
        out = {"ok": True, "channel": "email", "purpose": purpose,
               "email_enabled": True, "expires_in": rep["expires_in"],
               "resend_in": rep["resend_in"], "code_length": CODE_LENGTH,
               "prefer_sms": bool(cap["near"]), "already_sent": True}
        if rep["row"].sent and rep["row"].email:
            out["email_masked"] = email_sender.mask_email(rep["row"].email)
        return out
    ip, dev = _check_limits(purpose, now, lim, request, phone=canon, email=addr,
                            channel="email", target_email=tgt)
    ttl = lim["ttl_seconds"]
    out = {"ok": True, "channel": "email", "purpose": purpose, "email_enabled": True,
           "expires_in": ttl, "resend_in": lim["resend_cooldown_seconds"],
           "code_length": CODE_LENGTH, "prefer_sms": bool(cap["near"])}
    OtpChallenge.objects.filter(purpose=purpose, consumed_at__isnull=True,
                                **_ident(canon, addr)).update(consumed_at=now)
    send = bool(send and tgt)
    code = _gen_code() if send else ""
    salt = secrets.token_hex(16)
    ch = OtpChallenge.objects.create(
        phone=canon, email=tgt or addr, channel="email", purpose=purpose,
        code_hash=_hash(salt, _key(canon, addr), purpose, code) if send else "",
        salt=salt, created_at=now, expires_at=now + timedelta(seconds=ttl),
        ip=ip, device_id=dev, sent=False, consumed_at=None if send else now)
    if not send:
        ch.detail = "not sent (no verified email)"
        # signup-otp (owner-found 17 Nov): a NEW person tapped "sign in with
        # an email code", got the neutral "sent" answer and waited for a code
        # that could never come. Now the typed address gets a short "no
        # account uses this email yet — create one / sign in with password"
        # note (no code). Same API answer either way (no enumeration).
        if notice_if_unknown and addr and purpose in ("login", "password_reset"):
            ch.detail += " · notice %s" % no_account_notice(addr, lang, purpose)
        ch.save(update_fields=["detail"])
        _tag_rid(ch, rid_h)
        log_send("email", purpose, "not_sent", "no_verified_email")
        return out
    subject, body, html = email_sender.otp_email_html(code, lang, ttl)
    del code
    # emailrel: a user (re)verifying an address may try a bounced one again
    t0 = time.monotonic()
    r = email_sender.send_email(tgt, subject, body, purpose="otp", html=html,
                                bypass_suppression=(purpose == "email_verify"))
    ms = (time.monotonic() - t0) * 1000
    del subject, body, html
    ch.sent = bool(r["ok"])
    ch.detail = ("email %s %dms" % (r["reason"], ms))[:180]
    if not r["ok"]:
        ch.consumed_at = now
    ch.save(update_fields=["sent", "detail", "consumed_at"])
    log_send("email", purpose, "sent" if r["ok"] else "failed", r.get("reason"),
             r.get("provider"), ms)
    if r["ok"]:
        _tag_rid(ch, rid_h)
    if not r["ok"]:
        # emailrel: an honest reason + the alternative (SMS / later) — the
        # old "send_failed" said "SMS could not be sent" for an email
        if r["reason"] == "email_daily_cap":
            raise OtpError("email_daily_cap", 503, prefer_sms=True)
        if r["reason"] == "email_bouncing":
            raise OtpError("email_bouncing", 400, prefer_sms=True)
        if r["reason"] == "email_rejected":
            raise OtpError("email_rejected", 502, prefer_sms=True)
        raise OtpError("email_send_failed", 502, prefer_sms=True, retry_later=True)
    out["email_masked"] = email_sender.mask_email(tgt)
    return out


NOTICE_TEXTS = {
    "title": ("এই ইমেইলে এখনো কোনো যাচাই-করা Assisto অ্যাকাউন্ট নেই",
              "No Assisto account has this email verified yet"),
    "body": ("কেউ (সম্ভবত আপনি) এই ইমেইলে Assisto-তে ঢোকার কোড চেয়েছেন। কোনো অ্যাকাউন্টে এই ইমেইল যাচাই করা নেই, তাই কোড পাঠানো হয়নি।\n\n"
             "নতুন? অ্যাপে \"নতুন? প্রোফাইল তৈরি করুন\" চাপুন — নাম, ফোন নম্বর ও পাসওয়ার্ড দিলেই হবে, কোনো কোড লাগে না।\n\n"
             "আগে থেকেই অ্যাকাউন্ট আছে? ফোন নম্বর ও পাসওয়ার্ড দিয়ে ঢুকুন, তারপর সেটিংস → অ্যাকাউন্টের নিরাপত্তা থেকে এই ইমেইল যাচাই করুন।\n\n"
             "আপনি না চাইলে এই ইমেইলটি উপেক্ষা করুন — কিছুই বদলায়নি।",
             "Someone (probably you) asked for an Assisto sign-in code for this email. No account has this email verified, so no code was sent.\n\n"
             "New here? In the app tap \"New here? Create a profile\" — your name, phone number and a password are enough; no code is needed.\n\n"
             "Already have an account? Sign in with your phone number and password, then verify this email in Settings → Account security.\n\n"
             "If this wasn't you, ignore this email — nothing has changed."),
}
NOTICE_PURPOSE = "otp_noacct"


def no_account_notice(addr, lang, purpose="login"):
    """Send the 'no account uses this email yet' note at most once per
    address per 24 h. Returns a short no-PII status for the challenge row:
    sent | skipped_recent | <failure reason>."""
    from .models import EmailLog
    from . import email_sender, email_templates as T
    since = timezone.now() - timedelta(hours=24)
    if EmailLog.objects.filter(purpose=NOTICE_PURPOSE, to_hash=email_sender.email_hash(addr),
                               status="sent", created_at__gte=since).exists():
        return "skipped_recent"
    subject, text, html = T.render_notice(
        lang, NOTICE_TEXTS["title"][0], NOTICE_TEXTS["title"][1],
        NOTICE_TEXTS["body"][0], NOTICE_TEXTS["body"][1])
    t0 = time.monotonic()
    r = email_sender.send_email(addr, subject, text, purpose=NOTICE_PURPOSE, html=html,
                                category="normal")   # codes keep the cap first
    ms = (time.monotonic() - t0) * 1000
    log_send("email", purpose, "notice_sent" if r["ok"] else "notice_failed",
             r.get("reason"), r.get("provider"), ms)
    return "sent" if r["ok"] else (r.get("reason") or "failed")[:24]


_BN_ASCII = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _decoy_verify(canon, addr, purpose, now, lim):
    """gap-recovery (enumeration): a code typed for an identity that got the
    neutral "sent" answer but no code (no account / no verified email) used to
    answer "no_active_code" at once, while a real account answered
    "invalid_code, N tries left" — so two requests told a stranger which
    emails / numbers have an account. The decoy row now answers exactly like
    a real wrong code: tries left, then the same lockout, then "expired".
    Always raises OtpError."""
    from .models import OtpChallenge
    d = (OtpChallenge.objects.filter(purpose=purpose, sent=False, locked_until__isnull=True,
                                     detail__startswith="not sent",
                                     created_at__gt=now - timedelta(hours=1),
                                     **_ident(canon, addr))
         .order_by("-created_at").first())
    if d is None or " exp" in (d.detail or ""):
        raise OtpError("no_active_code", 400)
    if d.expires_at <= now:
        d.detail = ((d.detail or "") + " exp")[:200]
        d.save(update_fields=["detail"])
        raise OtpError("expired", 400)
    d.attempts += 1
    left = lim["max_attempts"] - d.attempts
    if left <= 0:
        d.locked_until = now + timedelta(minutes=lim["lockout_minutes"])
        d.save(update_fields=["attempts", "locked_until"])
        raise OtpError("locked", 423, retry_after=_retry(d.locked_until, now))
    d.save(update_fields=["attempts"])
    raise OtpError("invalid_code", 400, attempts_left=left)


def verify(phone, purpose, code, email=None):
    """Check `code` for phone+purpose (or, with phone=None, the email-only
    identity `email`). Returns the RAW otp_proof token (give it to the client
    once; only its hash is stored). Raises OtpError."""
    from .models import OtpChallenge, OtpProof
    _check_purpose(purpose)
    if phone or not email:
        canon, addr = _canon_or_raise(phone), ""
    else:
        from .email_sender import normalize_email
        canon, addr = "", normalize_email(email)
        if not addr:
            raise OtpError("bad_email", 400)
    now = timezone.now()
    lim = purpose_limits(purpose)

    locked = _active_lock(canon, purpose, now, addr)
    if locked:
        raise OtpError("locked", 423, retry_after=_retry(locked, now))

    ch = (OtpChallenge.objects.filter(purpose=purpose, consumed_at__isnull=True,
                                      sent=True, **_ident(canon, addr))
          .order_by("-created_at").first())
    if ch is None:
        _decoy_verify(canon, addr, purpose, now, lim)   # always raises
    if ch.expires_at <= now:
        ch.consumed_at = now
        ch.save(update_fields=["consumed_at"])
        raise OtpError("expired", 400)

    # gap-recovery: a code typed on a Bangla keyboard (৪৮২৯১৩) used to keep
    # the Bangla digits (\d matches them) and never matched.
    supplied = re.sub(r"[^0-9]", "", str(code or "").translate(_BN_ASCII))[:CODE_LENGTH]
    good = (len(supplied) == CODE_LENGTH and
            hmac.compare_digest(_hash(ch.salt, _key(canon, addr), purpose, supplied),
                                ch.code_hash))
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
                            channel=ch.channel or "sms",
                            email=addr or (ch.email if ch.channel == "email" else ""),
                            created_at=now,
                            expires_at=now + timedelta(seconds=lim["proof_ttl_seconds"]))
    return raw


def consume_proof_row(token, purpose, phone=None, email=None):
    """Single-use: burns and returns the OtpProof row, or None when the token
    is unknown / used / expired / for another purpose / another identity.
    `phone` (any BD format) or `email` (email-only identity) binds it."""
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
    elif email is not None:
        from .email_sender import normalize_email
        addr = normalize_email(email)
        if not addr:
            return None
        qs = qs.filter(phone="", email=addr)
    row = qs.first()
    if row is None:
        return None
    if not OtpProof.objects.filter(pk=row.pk, used_at__isnull=True).update(used_at=now):
        return None
    return row


def consume_proof(token, purpose, phone=None, row=False):
    """Single-use: returns the proven canonical phone and burns the proof, or
    None when the token is unknown / used / expired / for another purpose /
    for another phone. `phone` (any BD format) adds a binding check. An
    email-only proof (no phone) never satisfies a phone purpose.
    smsotp: row=True returns the OtpProof row (channel / email) instead."""
    r = consume_proof_row(token, purpose, phone=phone)
    if r is None or not r.phone:
        return None
    return r if row else r.phone


def mark_verified(user, canon):
    from .models import PhoneVerification
    PhoneVerification.objects.update_or_create(
        user=user, defaults={"phone": canon, "verified_at": timezone.now()})


# ------------------------------------------------------------- email helpers
def verified_email(user):
    """The user's VERIFIED email address (normalized) or ''."""
    if user is None:
        return ""
    from .models import EmailVerification
    from .email_sender import normalize_email
    row = EmailVerification.objects.filter(user=user).first()
    if not row:
        return ""
    return normalize_email(row.email) or ""


def find_user_by_verified_email(addr):
    from .models import EmailVerification
    from .email_sender import normalize_email
    a = normalize_email(addr)
    if not a:
        return None
    row = (EmailVerification.objects.filter(email=a).select_related("user")
           .order_by("verified_at").first())
    return row.user if row else None


def email_taken_by_other(user, addr):
    from .models import EmailVerification, User
    return (User.objects.filter(email__iexact=addr).exclude(pk=user.pk).exists() or
            EmailVerification.objects.filter(email=addr).exclude(user=user).exists())


def mark_email_verified(user, addr):
    """Record the proven address; also set User.email when it is free."""
    from .models import EmailVerification
    EmailVerification.objects.update_or_create(
        user=user, defaults={"email": addr, "verified_at": timezone.now()})
    try:                      # emailrel: a proven address is not "bouncing"
        from .email_sender import unsuppress
        unsuppress(addr)
    except Exception:  # noqa: BLE001
        pass
    if (user.email or "").lower() != addr and not email_taken_by_other(user, addr):
        user.email = addr
        user.save(update_fields=["email"])


def public_status():
    lim = limits()
    prefer_sms = False
    try:
        from . import email_sender
        prefer_sms = email_sender.configured() and email_sender.cap_state()["near"]
    except Exception:  # noqa: BLE001
        pass
    return {"sms_enabled": sms_available(),
            "email_enabled": email_available(),
            "email_prefer_sms": bool(prefer_sms),
            "email_purposes": list(EMAIL_PURPOSES),
            "password_only_signup": password_only_signup_allowed(),
            "code_length": CODE_LENGTH,
            "expires_in": lim["ttl_seconds"],
            "resend_in": lim["resend_cooldown_seconds"],
            "purposes": list(PURPOSES)}
