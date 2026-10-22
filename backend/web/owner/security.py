"""
Security core of the web owner panel (/owner/).

* TOTP (RFC 6238, SHA-1, 6 digits, 30 s) implemented with the standard library
  (hmac/hashlib/base32) — no new dependency. +-1 step drift, anti-replay via
  OwnerTOTP.last_counter.
* QR for the otpauth:// URI rendered as an inline SVG with reportlab's QR
  encoder (reportlab is already a dependency).
* Secrets encrypted at rest with Fernet (key derived from SECRET_KEY);
  recovery codes stored only as HMAC-SHA256 hashes, single use.
* Own session cookie `assisto_owner` (path /owner/, Secure, HttpOnly,
  SameSite=Strict), only its SHA-256 stored, idle timeout, absolute lifetime.
* DB-backed failure throttle with exponential lockout (per IP + per account).
* Append-only OwnerAudit rows.
"""
import base64
import hashlib
import hmac
import secrets
import struct
import time
from datetime import timedelta
from urllib.parse import quote

from django.conf import settings
from django.utils import timezone

COOKIE = "assisto_owner"
COOKIE_PATH = "/owner/"
PRE_MFA_MINUTES = 10           # a password-OK-but-no-2FA session lives 10 min
ABSOLUTE_HOURS = 12            # hard cap on any session
TOTP_STEP = 30
TOTP_DIGITS = 6
RECOVERY_COUNT = 10
LOCK_AFTER = 5                 # failures before the first lock
LOCK_BASE_SEC = 60             # 1 min, doubling: 1, 2, 4, 8 … 60 min
LOCK_MAX_SEC = 3600
FAIL_WINDOW_SEC = 3600         # failures older than this are forgotten


def idle_minutes():
    return int(getattr(settings, "OWNER_ADMIN_IDLE_MIN", 30) or 30)


def require_https():
    return bool(getattr(settings, "OWNER_ADMIN_REQUIRE_HTTPS", True))


# ------------------------------------------------------------------ crypto
def _fernet():
    from cryptography.fernet import Fernet
    raw = hashlib.sha256(b"assisto-owner-panel-v1:" +
                         settings.SECRET_KEY.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(raw))


def encrypt(text):
    return _fernet().encrypt(text.encode()).decode()


def decrypt(blob):
    if not blob:
        return ""
    try:
        return _fernet().decrypt(blob.encode()).decode()
    except Exception:
        return ""


def _hmac_hex(value, purpose):
    return hmac.new((purpose + ":" + settings.SECRET_KEY).encode(),
                    value.encode(), hashlib.sha256).hexdigest()


def sha256(value):
    return hashlib.sha256(value.encode()).hexdigest()


# -------------------------------------------------------------------- TOTP
def new_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _key(secret_b32):
    s = secret_b32.strip().replace(" ", "").upper()
    s += "=" * (-len(s) % 8)
    return base64.b32decode(s)


def hotp(secret_b32, counter):
    mac = hmac.new(_key(secret_b32), struct.pack(">Q", counter),
                   hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** TOTP_DIGITS)
    return str(code).zfill(TOTP_DIGITS)


def counter_at(ts=None):
    return int((time.time() if ts is None else ts) // TOTP_STEP)


def totp(secret_b32, ts=None):
    return hotp(secret_b32, counter_at(ts))


def verify_totp(secret_b32, code, last_counter=0, ts=None, window=1):
    """Return the matched counter (> last_counter) or None. Rejects replay of
    the same or an older time step."""
    code = "".join(ch for ch in str(code or "") if ch.isdigit())
    if len(code) != TOTP_DIGITS or not secret_b32:
        return None
    now = counter_at(ts)
    for c in range(now - window, now + window + 1):
        if c <= int(last_counter or 0):
            continue
        if hmac.compare_digest(hotp(secret_b32, c), code):
            return c
    return None


def otpauth_uri(secret_b32, account):
    label = quote("Assisto Owner:%s" % account)
    return ("otpauth://totp/%s?secret=%s&issuer=%s&algorithm=SHA1&digits=%d&period=%d"
            % (label, secret_b32, quote("Assisto Owner"), TOTP_DIGITS, TOTP_STEP))


def qr_svg(text, size=232):
    """Inline SVG QR (no script, no external request, CSP-safe)."""
    from reportlab.graphics.barcode import qrencoder as Q
    qr = Q.QRCode(None, Q.QRErrorCorrectLevel.M)
    qr.addData(text)
    qr.make()
    n = qr.getModuleCount()
    border = 4
    dim = n + 2 * border
    parts = []
    for r in range(n):
        c = 0
        while c < n:
            if qr.isDark(r, c):
                start = c
                while c < n and qr.isDark(r, c):
                    c += 1
                parts.append("M%d %dh%dv1h-%dz" % (start + border, r + border,
                                                     c - start, c - start))
            else:
                c += 1
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
            'width="%d" height="%d" role="img" aria-label="QR" '
            'shape-rendering="crispEdges"><rect width="%d" height="%d" '
            'fill="#ffffff"/><path fill="#000000" d="%s"/></svg>'
            % (dim, dim, size, size, dim, dim, "".join(parts)))


def group_secret(secret_b32):
    return " ".join(secret_b32[i:i + 4] for i in range(0, len(secret_b32), 4))


# ---------------------------------------------------------- recovery codes
_RC_ALPHA = "abcdefghjkmnpqrstuvwxyz23456789"


def _norm_rc(code):
    return "".join(ch for ch in str(code or "").lower() if ch.isalnum())


def new_recovery_codes(n=RECOVERY_COUNT):
    out = []
    for _ in range(n):
        raw = "".join(secrets.choice(_RC_ALPHA) for _ in range(10))
        out.append(raw[:5] + "-" + raw[5:])
    return out


def hash_recovery(code):
    return _hmac_hex(_norm_rc(code), "owner-recovery")


def looks_like_recovery(code):
    return len(_norm_rc(code)) == 10 and not _norm_rc(code).isdigit()


def consume_recovery(totp_row, code):
    """Single-use: True and the hash removed when `code` matches."""
    h = hash_recovery(code)
    hashes = list(totp_row.recovery_hashes or [])
    for i, stored in enumerate(hashes):
        if hmac.compare_digest(stored, h):
            del hashes[i]
            totp_row.recovery_hashes = hashes
            totp_row.save(update_fields=["recovery_hashes", "updated_at"])
            return True
    return False


# ------------------------------------------------------------- request meta
def client_ip(request):
    # nginx sets X-Forwarded-For to $remote_addr (replaces, not appends).
    xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
    ip = xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR", "")
    return (ip or "?")[:64]


def user_agent(request):
    return (request.META.get("HTTP_USER_AGENT", "") or "")[:200]


# ---------------------------------------------------------------- sessions
def create_session(request, user, stage):
    from core.models import OwnerSession
    raw = secrets.token_urlsafe(32)
    s = OwnerSession.objects.create(
        key_hash=sha256(raw), user=user, stage=stage,
        csrf=secrets.token_urlsafe(24),
        lang=getattr(request, "owner_lang", "bn"),
        ip=client_ip(request), ua=user_agent(request),
        last_seen=timezone.now())
    return raw, s


def rotate_session(session):
    """New cookie value + CSRF token for the same session (after 2FA)."""
    raw = secrets.token_urlsafe(32)
    session.key_hash = sha256(raw)
    session.csrf = secrets.token_urlsafe(24)
    session.save(update_fields=["key_hash", "csrf"])
    return raw


def set_cookie(response, raw):
    response.set_cookie(
        COOKIE, raw, max_age=ABSOLUTE_HOURS * 3600, path=COOKIE_PATH,
        secure=require_https(), httponly=True, samesite="Strict")


def clear_cookie(response):
    response.delete_cookie(COOKIE, path=COOKIE_PATH, samesite="Strict")


def load_session(request):
    """The live OwnerSession for this request's cookie or None. Enforces the
    idle timeout (30 min full / 10 min pre-2FA) and the absolute lifetime;
    an expired row is deleted."""
    from core.models import OwnerSession
    raw = request.COOKIES.get(COOKIE)
    if not raw:
        return None
    s = (OwnerSession.objects.select_related("user")
         .filter(key_hash=sha256(raw)).first())
    if s is None:
        return None
    now = timezone.now()
    idle = timedelta(minutes=idle_minutes() if s.stage == "full" else PRE_MFA_MINUTES)
    if (now - s.last_seen > idle or
            now - s.created_at > timedelta(hours=ABSOLUTE_HOURS)):
        s.delete()
        return None
    s.last_seen = now
    s.save(update_fields=["last_seen"])
    return s


def is_owner(user):
    from core.account_block import is_blocked
    return bool(user is not None and user.is_active and user.is_superuser
                and not is_blocked(user))


# ---------------------------------------------------------------- throttle
def lock_remaining(key):
    """Seconds this key is still locked (0 = free)."""
    from core.models import OwnerThrottle
    t = OwnerThrottle.objects.filter(key=key).first()
    if not t or not t.locked_until:
        return 0
    left = (t.locked_until - timezone.now()).total_seconds()
    return int(left) + 1 if left > 0 else 0


def register_fail(key):
    """Count a failure; lock with exponential backoff from the 5th failure."""
    from core.models import OwnerThrottle
    now = timezone.now()
    t, _ = OwnerThrottle.objects.get_or_create(key=key)
    if t.last_fail_at and (now - t.last_fail_at).total_seconds() > FAIL_WINDOW_SEC \
            and not lock_remaining(key):
        t.fails = 0
    t.fails += 1
    t.last_fail_at = now
    if t.fails >= LOCK_AFTER:
        sec = min(LOCK_MAX_SEC, LOCK_BASE_SEC * (2 ** (t.fails - LOCK_AFTER)))
        t.locked_until = now + timedelta(seconds=sec)
    t.save()
    return t.fails


def clear_fails(key):
    from core.models import OwnerThrottle
    OwnerThrottle.objects.filter(key=key).delete()


# ------------------------------------------------------------------- audit
def audit(request, actor, action, target="", before=None, after=None, ok=True):
    from core.models import OwnerAudit
    try:
        OwnerAudit.objects.create(
            actor=actor if (actor is not None and getattr(actor, "pk", None)) else None,
            action=action[:60], target=str(target or "")[:160],
            before=before, after=after, ok=ok,
            ip=client_ip(request), ua=user_agent(request))
    except Exception:
        pass


# ----------------------------------------------------------------- headers
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; "
       "img-src 'self' data:; font-src 'self'; connect-src 'self'; "
       "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")


def harden(response):
    response["Content-Security-Policy"] = CSP
    response["X-Frame-Options"] = "DENY"
    response["X-Content-Type-Options"] = "nosniff"
    # same-origin (not no-referrer): browsers then send a real Origin on POST,
    # which Django's CSRF origin check needs over HTTPS.
    response["Referrer-Policy"] = "same-origin"
    response["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    response["Cache-Control"] = "no-store"
    response["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response["Cross-Origin-Opener-Policy"] = "same-origin"
    if require_https():
        response["Strict-Transport-Security"] = "max-age=31536000"
    return response
