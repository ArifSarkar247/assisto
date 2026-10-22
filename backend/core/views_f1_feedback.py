"""
f1-founders: in-app "Send feedback / report a problem".

  POST feedback          create a report (auth, rate-limited per user,
                         optional screenshot as base64 PNG/JPEG/WebP)
  GET  feedback          the signed-in user's OWN reports (newest first)
  GET  feedback/<pk>     one OWN report (404 for anybody else's)

The screenshot is stored through the default storage (core.media_sign
SignedMediaStorage: short-lived signed links, nothing under a public /media
path) and is only ever linked from the owner panel and the reporter's own
GET. Limits (feedback_per_hour / feedback_per_day) are PricingConfig
limits, admin-editable.
"""
import base64
import binascii
import io
from datetime import timedelta

from django.core.files.base import ContentFile
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang

MAX_NOTE = 2000
MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_SIDE = 4096
_META = {"app_version": 32, "app_build": 16, "device_model": 80,
         "os_version": 40, "language": 8, "route": 80}

_MSG = {
    "note_required": ("একটি ছোট নোট লিখুন।", "Please write a short note."),
    "note_too_long": ("নোটটি অনেক বড় — ২০০০ অক্ষরের মধ্যে লিখুন।",
                      "The note is too long — keep it under 2000 characters."),
    "bad_category": ("ধরনটি ঠিক নয়।", "Unknown category."),
    "bad_image": ("স্ক্রিনশটটি পড়া গেল না — ছাড়াই পাঠান বা আবার চেষ্টা করুন।",
                  "The screenshot couldn't be read — send without it or try again."),
    "image_too_large": ("স্ক্রিনশটটি অনেক বড় (সর্বোচ্চ ৪ MB)।",
                        "The screenshot is too large (max 4 MB)."),
    "rate_limited": ("অল্প সময়ে অনেকগুলো রিপোর্ট পাঠানো হয়েছে। একটু পরে আবার চেষ্টা করুন।",
                     "You've sent several reports just now. Please try again a little later."),
}


def _err(lang, code, status=400, **extra):
    bn, en = _MSG[code]
    return Response({"ok": False, "code": code, "detail": pick(lang, bn, en), **extra},
                    status=status)


def _limits():
    try:
        from . import billing
        lim = billing.cfg()["limits"]
        return int(lim["feedback_per_hour"]), int(lim["feedback_per_day"])
    except Exception:
        return 5, 20


def _decode_image(b64):
    """bytes, ext — or raises ValueError(code)."""
    s = str(b64 or "").strip()
    if s.startswith("data:") and "," in s:
        s = s.split(",", 1)[1]
    if len(s) > (MAX_IMAGE_BYTES * 4) // 3 + 8:
        raise ValueError("image_too_large")
    try:
        data = base64.b64decode(s, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("bad_image")
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("image_too_large")
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        kind = "png"
    elif data[:3] == b"\xff\xd8\xff":
        kind = "jpg"
    elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        kind = "webp"
    else:
        raise ValueError("bad_image")
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(data))
        im.verify()
        w, h = im.size
        if w < 1 or h < 1 or w > MAX_SIDE or h > MAX_SIDE:
            raise ValueError("bad_image")
        if kind != "png":
            # re-encode JPEG/WebP so no EXIF (location, device ids) survives
            im = Image.open(io.BytesIO(data)).convert("RGB")
            out = io.BytesIO()
            im.save(out, "JPEG", quality=85)
            data, kind = out.getvalue(), "jpg"
    except ValueError:
        raise
    except Exception:
        raise ValueError("bad_image")
    return data, kind


def payload(r, with_shot=False):
    d = {"id": r.id, "category": r.category, "status": r.status,
         "note": r.note, "created_at": r.created_at.isoformat(),
         "has_screenshot": bool(r.screenshot)}
    if with_shot and r.screenshot:
        try:
            d["screenshot_url"] = r.screenshot.url
        except Exception:
            d["screenshot_url"] = ""
    return d


class FeedbackView(APIView):
    def get(self, request):
        from .models import FeedbackReport
        rows = FeedbackReport.objects.filter(user=request.user)[:50]
        return Response({"ok": True, "results": [payload(r) for r in rows]})

    def post(self, request):
        from .models import FeedbackReport
        lang = req_lang(request)
        d = request.data or {}
        note = str(d.get("note") or "").strip()
        if not note:
            return _err(lang, "note_required")
        if len(note) > MAX_NOTE:
            return _err(lang, "note_too_long")
        cat = str(d.get("category") or "bug").strip().lower()
        if cat not in FeedbackReport.CATEGORIES:
            return _err(lang, "bad_category")
        per_hour, per_day = _limits()
        now = timezone.now()
        mine = FeedbackReport.objects.filter(user=request.user)
        if (mine.filter(created_at__gte=now - timedelta(hours=1)).count() >= per_hour
                or mine.filter(created_at__gte=now - timedelta(days=1)).count() >= per_day):
            return _err(lang, "rate_limited", status=429, retry_after=3600)
        shot = None
        if d.get("screenshot_b64"):
            try:
                shot = _decode_image(d.get("screenshot_b64"))
            except ValueError as e:
                return _err(lang, str(e) if str(e) in _MSG else "bad_image")
        meta = {k: str(d.get(k) or "").strip()[:n] for k, n in _META.items()}
        r = FeedbackReport(user=request.user, category=cat, note=note, **meta)
        if shot is not None:
            data, ext = shot
            r.screenshot.save("shot." + ext, ContentFile(data), save=False)
            r.screenshot_bytes = len(data)
        r.save()
        return Response({"ok": True, **payload(r)}, status=201)


class FeedbackDetailView(APIView):
    def get(self, request, pk):
        from .models import FeedbackReport
        r = FeedbackReport.objects.filter(pk=pk, user=request.user).first()
        if r is None:
            return Response({"ok": False}, status=404)
        return Response({"ok": True, **payload(r, with_shot=True)})
