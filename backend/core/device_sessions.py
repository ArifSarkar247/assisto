"""
Per-device sign-in sessions (recovery, owner order Part 8).

Before this, DRF gave ONE rest_framework Token per user, so the app could not
list the phones an account is signed in on, or sign out just one of them.

Now:
  * A NEW app build sends `X-Session-Mode: device` on sign-in. The server then
    issues a DeviceSession key (40 hex chars, the same shape as a Token key,
    sent the same way: `Authorization: Token <key>`). Only sha256(key) is
    stored.
  * An OLDER build (no header) gets the legacy single Token exactly as before
    — it keeps working until that phone signs in again on a new build. The
    devices list shows it as one "Older app version" row that can be signed
    out like any other.
  * core.account_block.BlockAwareTokenAuthentication accepts both: the Token
    table first (unchanged path), then an unrevoked DeviceSession.

revoke_all() is THE "sign out everywhere" helper: every place that used to do
Token.objects.filter(user=u).delete() also calls it.
"""
import hashlib
import secrets
from datetime import timedelta

from django.utils import timezone

SESSION_HEADER = "HTTP_X_SESSION_MODE"
TOUCH_EVERY = timedelta(minutes=5)     # last_seen write at most every 5 min
MAX_ACTIVE = 20                        # oldest sessions beyond this are revoked


def _sha(raw):
    return hashlib.sha256(str(raw).encode()).hexdigest()


def wants_device_session(request):
    try:
        return (request.META.get(SESSION_HEADER, "") or "").strip().lower() == "device"
    except Exception:  # noqa: BLE001
        return False


def _meta(request, name, limit):
    try:
        return (request.META.get(name, "") or "").strip()[:limit]
    except Exception:  # noqa: BLE001
        return ""


def _client_ip(request):
    try:
        from .otp import client_ip
        return (client_ip(request) or "")[:45]
    except Exception:  # noqa: BLE001
        return ""


def create(user, request=None, reason="login"):
    """New session for `user` from `request`. Returns (raw_key, session)."""
    from .models import DeviceSession
    raw = secrets.token_hex(20)
    now = timezone.now()
    s = DeviceSession.objects.create(
        user=user, key_hash=_sha(raw),
        device_id=_meta(request, "HTTP_X_DEVICE_ID", 64) if request else "",
        device_name=_meta(request, "HTTP_X_DEVICE_NAME", 80) if request else "",
        platform=(_meta(request, "HTTP_X_PLATFORM", 16) or "android") if request else "",
        app_version=_meta(request, "HTTP_X_APP_VERSION", 24) if request else "",
        ip=_client_ip(request) if request else "",
        created_at=now, last_seen_at=now)
    # A device that signs in again replaces its own older session.
    if s.device_id:
        (DeviceSession.objects.filter(user=user, device_id=s.device_id,
                                      revoked_at__isnull=True)
         .exclude(pk=s.pk).update(revoked_at=now, revoke_reason="replaced"))
    live = list(DeviceSession.objects.filter(user=user, revoked_at__isnull=True)
                .order_by("-last_seen_at").values_list("pk", flat=True))
    if len(live) > MAX_ACTIVE:
        DeviceSession.objects.filter(pk__in=live[MAX_ACTIVE:]).update(
            revoked_at=now, revoke_reason="too_many")
    return raw, s


def login_token(user, request):
    """The token a sign-in view returns: a DeviceSession key for new builds
    (header), the legacy single Token otherwise (unchanged behaviour)."""
    if wants_device_session(request):
        raw, _s = create(user, request)
        return raw
    from rest_framework.authtoken.models import Token
    token, _ = Token.objects.get_or_create(user=user)
    return token.key


def lookup(key):
    """The live DeviceSession for a raw key, or None. Touches last_seen."""
    from .models import DeviceSession
    if not key or len(key) > 128:
        return None
    s = (DeviceSession.objects.select_related("user")
         .filter(key_hash=_sha(key), revoked_at__isnull=True).first())
    if s is None:
        return None
    now = timezone.now()
    if now - s.last_seen_at > TOUCH_EVERY:
        DeviceSession.objects.filter(pk=s.pk).update(last_seen_at=now)
        s.last_seen_at = now
    return s


def is_session(auth):
    from .models import DeviceSession
    return isinstance(auth, DeviceSession)


def revoke(session, reason="signed_out"):
    from .models import DeviceSession
    DeviceSession.objects.filter(pk=session.pk, revoked_at__isnull=True).update(
        revoked_at=timezone.now(), revoke_reason=reason[:24])


def revoke_all(user, keep=None, reason="signed_out_all", keep_legacy=False):
    """Sign `user` out of every device. `keep` = the current DeviceSession to
    keep. The legacy Token is deleted unless keep_legacy. Returns the count."""
    from .models import DeviceSession
    from rest_framework.authtoken.models import Token
    qs = DeviceSession.objects.filter(user=user, revoked_at__isnull=True)
    if keep is not None and is_session(keep):
        qs = qs.exclude(pk=keep.pk)
    n = qs.update(revoked_at=timezone.now(), revoke_reason=reason[:24])
    if not keep_legacy:
        n += Token.objects.filter(user=user).delete()[0]
    return n


def listing(user, current=None, lang="bn"):
    """The devices list for the Account & security page."""
    from .models import DeviceSession
    from rest_framework.authtoken.models import Token
    out = []
    for s in (DeviceSession.objects.filter(user=user, revoked_at__isnull=True)
              .order_by("-last_seen_at")[:MAX_ACTIVE]):
        out.append({
            "id": "s%d" % s.pk, "kind": "device",
            "name": s.device_name or "", "platform": s.platform or "",
            "app_version": s.app_version or "",
            "created_at": s.created_at.isoformat(),
            "last_seen_at": s.last_seen_at.isoformat(),
            "current": bool(current is not None and is_session(current) and current.pk == s.pk),
        })
    tok = Token.objects.filter(user=user).first()
    if tok is not None:
        out.append({
            "id": "legacy", "kind": "legacy", "name": "", "platform": "",
            "app_version": "", "created_at": tok.created.isoformat(),
            "last_seen_at": None,
            "current": bool(current is not None and not is_session(current)
                            and getattr(current, "key", None) == tok.key),
        })
    return out


def revoke_by_id(user, sid, current=None):
    """Sign out one device from the list. Returns 'ok' | 'not_found' | 'current'."""
    from .models import DeviceSession
    from rest_framework.authtoken.models import Token
    if sid == "legacy":
        tok = Token.objects.filter(user=user).first()
        if tok is None:
            return "not_found"
        if current is not None and not is_session(current) and \
                getattr(current, "key", None) == tok.key:
            return "current"
        tok.delete()
        return "ok"
    try:
        pk = int(str(sid).lstrip("s"))
    except (TypeError, ValueError):
        return "not_found"
    s = DeviceSession.objects.filter(pk=pk, user=user, revoked_at__isnull=True).first()
    if s is None:
        return "not_found"
    if current is not None and is_session(current) and current.pk == s.pk:
        return "current"
    revoke(s, "signed_out_remote")
    return "ok"
