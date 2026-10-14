"""
Password reset / recovery (launch gap A) — email-based, on OUR OWN backend.
No third-party reset provider. SMS reset is designed but key-gated until an SMS
gateway is connected ("Available when SMS gateway added").

Security properties enforced here:
- Secure random tokens (secrets.token_urlsafe), stored only as a SHA-256 HASH
  (a leaked PasswordResetToken table can't be used to reset anyone).
- Short expiry (default 30 min) and single-use (consumed on success).
- NO user-enumeration leak: request_reset() ALWAYS returns the same neutral
  response whether or not the email/phone exists, and whether or not we could
  send. The integrator must return that response verbatim (never 404/400 for
  "no such user").
- Password strength is validated on confirm.

Integrator wires: PasswordResetToken model (see MIGRATION NOTE), the
request/confirm endpoints, and an email send call (Django send_mail or the
owner's configured email integration). This module stays network-free: it
builds the token + the localized message; the view performs the actual send.
"""
import hashlib
import secrets
from datetime import timedelta

from .i18n import pick

TOKEN_TTL_MINUTES = 30
# channels the UI may request; "sms" is accepted but gated off until a gateway
# is connected (see sms_reset_available()).
CHANNELS = ("email", "sms")


def generate_token():
    """Return (raw_token, token_hash). The RAW token goes to the user (in the
    email link / code); only the HASH is persisted."""
    raw = secrets.token_urlsafe(32)
    return raw, hash_token(raw)


def hash_token(raw):
    return hashlib.sha256((raw or "").encode("utf-8")).hexdigest()


def expiry(now):
    return now + timedelta(minutes=TOKEN_TTL_MINUTES)


def neutral_response(lang="bn", channel="email"):
    """The SAME response is returned regardless of whether the account exists.
    This is the anti-enumeration guarantee — the view MUST NOT branch on
    existence before returning this."""
    if channel == "email":
        msg = pick(lang,
                   "যদি এই ইমেইলে কোনো অ্যাকাউন্ট থাকে, একটি রিসেট লিংক পাঠানো হয়েছে।",
                   "If an account exists for that email, a reset link has been sent.")
    else:
        msg = pick(lang,
                   "যদি এই নম্বরে কোনো অ্যাকাউন্ট থাকে, একটি রিসেট কোড পাঠানো হবে।",
                   "If an account exists for that number, a reset code will be sent.")
    return {"ok": True, "message": msg}


def sms_reset_available():
    """SMS reset only turns on when an SMS gateway integration is connected.
    Until then the UI shows 'Available when SMS gateway added'."""
    try:
        from . import integrations
        # any configured + working SMS provider enables it
        for slug in ("sms", "ssl_sms", "bulk_sms"):
            if slug in getattr(integrations, "REGISTRY", {}) and integrations.is_enabled(slug):
                return True
    except Exception:
        pass
    return False


def build_email(lang, name, reset_link):
    """(subject, body) for the reset email. No secrets other than the one-time
    link the user themselves requested."""
    subject = pick(lang, "আপনার Assisto পাসওয়ার্ড রিসেট",
                   "Reset your Assisto password")
    greeting = pick(lang, f"হ্যালো {name or ''},".strip(),
                    f"Hello {name or ''},".strip())
    body = pick(
        lang,
        (f"{greeting}\n\n"
         "আপনার পাসওয়ার্ড রিসেট করতে নিচের লিংকে ক্লিক করুন। "
         f"লিংকটি {TOKEN_TTL_MINUTES} মিনিট পর কাজ করবে না।\n\n"
         f"{reset_link}\n\n"
         "আপনি যদি এই অনুরোধ না করে থাকেন, এই মেইলটি উপেক্ষা করুন।\n\n— Assisto"),
        (f"{greeting}\n\n"
         "Click the link below to reset your password. "
         f"The link expires in {TOKEN_TTL_MINUTES} minutes.\n\n"
         f"{reset_link}\n\n"
         "If you did not request this, you can safely ignore this email.\n\n— Assisto"),
    )
    return subject, body


def reset_link(base_url, raw_token):
    """Deep link the app opens on the reset-confirm screen. Integrator sets
    base_url (e.g. the app scheme or https landing)."""
    base = (base_url or "assisto://reset").rstrip("/")
    return f"{base}/confirm?token={raw_token}"


# --- password strength (reused on confirm) ---------------------------------
def validate_password(pw, lang="bn"):
    """Return (ok, message). Minimal, locale-aware strength FLOOR. This is the
    authoritative rule the confirm endpoint enforces; the app's strength meter
    only mirrors it for a fast offline hint."""
    pw = pw or ""
    if len(pw) < 8:
        return False, pick(lang, "পাসওয়ার্ড কমপক্ষে ৮ অক্ষরের হতে হবে।",
                           "Password must be at least 8 characters.")
    if pw.isdigit() or pw.isalpha():
        return False, pick(lang, "পাসওয়ার্ডে অক্ষর ও সংখ্যা উভয়ই রাখুন।",
                           "Use both letters and numbers in your password.")
    return True, pick(lang, "ঠিক আছে", "OK")


# strength LEVELS mirrored by the Flutter meter (reset_strength_meter.dart).
STRENGTH_WEAK = "weak"
STRENGTH_FAIR = "fair"
STRENGTH_GOOD = "good"
STRENGTH_STRONG = "strong"


def score_password(pw):
    """Pure strength score, kept in lock-step with the app's PwScore.of(). Returns
    a level string ('weak'|'fair'|'good'|'strong'). 'weak' means below the floor
    that validate_password() rejects; 'fair'+ means the floor is met. Used by the
    strength meter and reusable for a change-password (logged-in) flow."""
    pw = pw or ""
    if not pw:
        return STRENGTH_WEAK
    import re
    has_lower = bool(re.search(r"[a-z]", pw))
    has_upper = bool(re.search(r"[A-Z]", pw))
    has_digit = bool(re.search(r"[0-9]", pw))
    has_symbol = bool(re.search(r"[^A-Za-z0-9]", pw))
    long_enough = len(pw) >= 8
    very_long = len(pw) >= 12
    mixes = (has_lower or has_upper) and has_digit
    if not long_enough or not mixes:
        return STRENGTH_WEAK
    classes = sum([has_lower, has_upper, has_digit, has_symbol])
    if very_long and classes >= 3:
        return STRENGTH_STRONG
    if (very_long and classes >= 2) or (long_enough and classes >= 3):
        return STRENGTH_GOOD
    return STRENGTH_FAIR


def should_revoke_sessions(request_data):
    """Whether a successful reset/change should sign out all other devices.
    Secure default: True. The integrator calls this and, when True, deletes the
    user's auth Token(s) (see MIGRATION/INTEGRATION NOTE) so any session an
    attacker may hold is invalidated. Network-free: just reads the flag."""
    data = request_data or {}
    val = data.get("revoke_sessions", True)
    if isinstance(val, str):
        return val.strip().lower() not in ("false", "0", "no", "")
    return bool(val)


def change_password_check(current_ok, new_pw, lang="bn"):
    """Reusable validator for a logged-in change-password flow. `current_ok` is
    whether the supplied CURRENT password verified (the view checks that against
    the hash; this module never sees stored secrets). Returns (ok, message)."""
    if not current_ok:
        return False, pick(lang, "বর্তমান পাসওয়ার্ড মেলেনি।",
                           "Your current password is incorrect.")
    return validate_password(new_pw, lang)


def check_token(stored_hash, raw_token, expires_at, now, used):
    """Validate a confirm attempt. Returns (ok, reason_key). reason_key is a
    stable machine code the view maps to a localized message — but note the
    view should still avoid telling an attacker *which* part failed beyond
    'invalid or expired'."""
    if used:
        return False, "used"
    if not stored_hash or not raw_token:
        return False, "invalid"
    if not secrets.compare_digest(stored_hash, hash_token(raw_token)):
        return False, "invalid"
    if expires_at is not None and now is not None and now > expires_at:
        return False, "expired"
    return True, "ok"


def confirm_message(lang, reason):
    if reason == "ok":
        return pick(lang, "পাসওয়ার্ড পরিবর্তন হয়েছে। এখন লগইন করুন।",
                    "Password changed. You can log in now.")
    # Deliberately collapse used/expired/invalid into one message to the client.
    return pick(lang, "লিংকটি অকার্যকর বা মেয়াদোত্তীর্ণ। আবার চেষ্টা করুন।",
                "This link is invalid or expired. Please request a new one.")
