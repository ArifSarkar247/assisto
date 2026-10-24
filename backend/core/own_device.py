"""
own-device (owner 24 Oct): the app sends a stable per-install id on every API
request (header X-Device-Id; a hash of the random install id, never a
hardware id). The native anti-theft engine on the same phone sends the same
id with its ingest, and we keep only its sha256 on AntiTheftEngine.device_hash.

If an authenticated request comes FROM a protected phone whose went-dark latch
is set, that phone is obviously alive (its owner is using the app on it), so
the went-dark alert is resolved and the latch cleared. A request from another
device or the web (different / no header) never resolves it.

Cheap: no header -> nothing; otherwise at most ONE query per request, and a
short per-process negative cache skips even that for most requests. Never
raises.
"""
import hashlib
import re
import threading
import time

HEADER = "HTTP_X_DEVICE_ID"
_VALID = re.compile(r"^[A-Za-z0-9_\-]{8,128}$")

# (user_id, device_hash) -> monotonic time until which "nothing latched" holds
NEG_TTL_S = 60
_neg = {}
_lock = threading.Lock()


def device_hash(raw):
    """sha256 hex of a well-formed device id, else "" (junk is ignored)."""
    raw = (raw or "").strip()
    if not raw or not _VALID.match(raw):
        return ""
    return hashlib.sha256(("assisto-dev:" + raw).encode("utf-8")).hexdigest()


def hash_from_request(request):
    try:
        return device_hash(request.META.get(HEADER, ""))
    except Exception:
        return ""


def remember(eng, request):
    """Store the request's device hash on the engine (enable / ingest).
    Returns True if it changed (the caller saves). Never raises."""
    try:
        h = hash_from_request(request)
        if h and eng.device_hash != h:
            eng.device_hash = h
            return True
    except Exception:
        pass
    return False


def forget_cache():
    with _lock:
        _neg.clear()


def touch(request, user, now=None):
    """Called once per authenticated request. Resolves a went-dark latch on
    the user's protected phone when the request comes from that phone.
    Returns the resolved phone (tests) or None. Never raises."""
    try:
        h = hash_from_request(request)
        if not h or user is None or not getattr(user, "pk", None):
            return None
        key = (user.pk, h)
        t = time.monotonic()
        with _lock:
            until = _neg.get(key)
            if until is not None and until > t:
                return None
            if len(_neg) > 5000:
                _neg.clear()
        from .models import ProtectedPhone
        phone = (ProtectedPhone.objects
                 .filter(owner_id=user.pk, went_dark_alerted=True,
                         engine__device_hash=h)
                 .first())
        if phone is None:
            with _lock:
                _neg[key] = t + NEG_TTL_S
            return None
        from django.utils import timezone
        from .views_antitheft import resolve_went_dark
        now = now or timezone.now()
        # seen just now: also stops the went-dark job re-alerting on the
        # same stale gap a minute later
        ProtectedPhone.objects.filter(pk=phone.pk).update(
            went_dark_alerted=False, last_heartbeat_at=now)
        phone.went_dark_alerted = False
        phone.last_heartbeat_at = now
        resolve_went_dark(phone, now)
        return phone
    except Exception:
        return None
