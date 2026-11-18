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


# cctv-preview: a SMALL preview of a signed image (the CCTV alert photo on a
# 2G phone). `w` is not part of the signature: it can only SHRINK an image
# the link already grants, to one of a few fixed widths (no resize-DoS).
PREVIEW_WIDTHS = (160, 320)
PREVIEW_MAX_BYTES = 20 * 1024
PREVIEW_CACHE_S = 2 * 3600


def preview_url(url, w=320):
    """The same signed link, asking for the small preview."""
    if not url:
        return url
    return "%s%sw=%d" % (url, "&" if "?" in url else "?", int(w))


def preview_jpeg(raw, w, max_bytes=PREVIEW_MAX_BYTES):
    """<= w px wide JPEG, <= max_bytes (quality stepped down), or None."""
    import io
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw))
        im = im.convert("RGB")
        im.thumbnail((int(w), int(w)))
        best = None
        for q in (60, 50, 40, 30):
            out = io.BytesIO()
            im.save(out, "JPEG", quality=q, optimize=True, progressive=True)
            best = out.getvalue()
            if len(best) <= max_bytes:
                break
        return best
    except Exception:
        return None


def _raw_image(name):
    """(bytes, content type) of a stored private file, or None."""
    import mimetypes
    import os
    from .logic import cctv_store
    if cctv_store.valid_name(name):
        got = cctv_store.response_for(name)
        return (got[0], got[1]) if got else None
    root = os.path.realpath(settings.MEDIA_ROOT)
    path = os.path.realpath(os.path.join(root, name))
    if not path.startswith(root + os.sep) or not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        return fh.read(), (mimetypes.guess_type(path)[0] or "application/octet-stream")


def preview_for(name, w):
    """Cached preview bytes for a stored image (None = not an image)."""
    from django.core.cache import cache
    key = "mprev:%d:%s" % (int(w), hashlib.sha256(name.encode()).hexdigest()[:40])
    got = cache.get(key)
    if got is not None:
        return got or None
    raw = _raw_image(name)
    data = None
    if raw and str(raw[1]).startswith("image/"):
        data = preview_jpeg(raw[0], w)
    cache.set(key, data or b"", PREVIEW_CACHE_S)
    return data


def warm_preview(name, w=320):
    """At alert time: make the preview before the first phone asks for it.
    Never raises."""
    try:
        preview_for(name, w)
    except Exception:
        pass


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
    # cctv-preview: ?w=160|320 -> the small preview (a 2G phone sees the
    # alert photo in seconds); anything else -> the full file below
    try:
        w = int(request.GET.get("w") or 0)
    except ValueError:
        w = 0
    if w in PREVIEW_WIDTHS:
        data = preview_for(name, w)
        if data:
            resp = HttpResponse(data, content_type="image/jpeg")
            resp["Cache-Control"] = "private, max-age=3600"
            resp["X-Content-Type-Options"] = "nosniff"
            resp["X-Robots-Tag"] = "noindex, noimageindex, noarchive"
            return resp
    # cctvevidence (W7): CCTV photos / clips are sealed objects (AES-GCM,
    # S3 or encrypted local) — opened here, never streamed raw by nginx.
    from .logic import cctv_store
    if cctv_store.valid_name(name):
        got = cctv_store.response_for(name)
        if got is None:
            raise Http404
        resp = HttpResponse(got[0], content_type=got[1])
        resp["Cache-Control"] = "private, max-age=3600"
        resp["X-Content-Type-Options"] = "nosniff"
        resp["X-Robots-Tag"] = "noindex, noimageindex, noarchive"
        return resp
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
    # missing (owner 2 Nov): private media is never indexed / archived by a
    # search engine (missing children's photos above all).
    resp["X-Robots-Tag"] = "noindex, noimageindex, noarchive"
    return resp
