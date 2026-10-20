"""
media_sign.py — PRIVATE uploads (vault photos, shop snapshots, theft/intruder
photos, khata bills, CRM attachments, avatars) are never served from a public
/media/ path. Every FileField `.url` now resolves to a short-lived HMAC-signed
link (/api/v1/m/<name>?e=<expiry>&s=<sig>) that works in an <img>/Image.network
without an auth header but cannot be guessed or reused after it expires.

The signing key is derived from SECRET_KEY. Expiry is rounded UP to the next
whole hour (+1h) so the same file keeps the same URL for a while and clients
can cache images. nginx serves the bytes via X-Accel-Redirect to an `internal`
location; /media/ itself is closed (404) at nginx.
"""
import hashlib
import hmac
import time
from urllib.parse import quote

from django.conf import settings
from django.core.files.storage import FileSystemStorage

TTL_S = 3600
SIGNED_PREFIX = "/api/v1/m/"
ACCEL_PREFIX = "/protected-media/"


def _key():
    return hashlib.sha256(b"assisto-media:" + settings.SECRET_KEY.encode()).digest()


def _sig(name, exp):
    msg = ("%s|%d" % (name, exp)).encode()
    return hmac.new(_key(), msg, hashlib.sha256).hexdigest()[:32]


def signed_url(name, now=None):
    now = int(now if now is not None else time.time())
    exp = (now // TTL_S + 2) * TTL_S          # 1-2h validity, stable per hour
    return "%s%s?e=%d&s=%s" % (SIGNED_PREFIX, quote(name), exp, _sig(name, exp))


def verify(name, exp, sig, now=None):
    try:
        exp = int(exp)
    except (TypeError, ValueError):
        return False
    if exp < int(now if now is not None else time.time()):
        return False
    return hmac.compare_digest(_sig(name, exp), str(sig or ""))


class SignedMediaStorage(FileSystemStorage):
    """FileSystemStorage whose .url() is a signed, expiring link."""

    def url(self, name):
        return signed_url(name)


def serve_signed(request, name):
    """GET /api/v1/m/<name>?e=&s= — 404 on any bad/expired signature or path
    (never reveals whether a file exists). In production nginx streams the
    bytes (X-Accel-Redirect); in dev/tests Django does."""
    import mimetypes
    import os
    from django.http import FileResponse, Http404, HttpResponse

    if ".." in name.split("/") or name.startswith("/") or "\\" in name:
        raise Http404
    if not verify(name, request.GET.get("e"), request.GET.get("s")):
        raise Http404
    root = os.path.realpath(settings.MEDIA_ROOT)
    path = os.path.realpath(os.path.join(root, name))
    if not path.startswith(root + os.sep) or not os.path.isfile(path):
        raise Http404
    ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    if getattr(settings, "MEDIA_X_ACCEL", False):
        resp = HttpResponse(content_type=ctype)
        resp["X-Accel-Redirect"] = ACCEL_PREFIX + quote(name)
    else:
        resp = FileResponse(open(path, "rb"), content_type=ctype)
    resp["Cache-Control"] = "private, max-age=3600"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp
