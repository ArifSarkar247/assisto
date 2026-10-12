import base64
import hashlib
import json
from datetime import timedelta

from django.conf import settings
from django.http import HttpResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from core.models import ToolUsage
from core import ai
from .logic import cv as cvlogic
from .logic import scam as scamlogic
from .logic import cards as cardlogic
from .logic import photo as photologic

RATE_PER_HOUR = 40  # per tool, per IP


def _client_ip(request):
    xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if xff:
        return xff.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR", "")


def _ip_hash(request):
    raw = (_client_ip(request) + settings.SECRET_KEY[:8]).encode()
    return hashlib.sha256(raw).hexdigest()


def _rate_ok(request, tool):
    h = _ip_hash(request)
    since = timezone.now() - timedelta(hours=1)
    n = ToolUsage.objects.filter(tool=tool, ip_hash=h, created_at__gte=since).count()
    return n < RATE_PER_HOUR, h


def _log(tool, h, used_ai=False, cost=0.0):
    ToolUsage.objects.create(tool=tool, ip_hash=h, used_ai=used_ai, cost_usd=cost)


def _rate_limited_page(request):
    return render(request, "web/limited.html", status=429)


# ---------------- landing ----------------
def landing(request):
    return render(request, "web/landing.html")


def get_app(request):
    data = {}
    try:
        with open(settings.APP_LATEST_FILE) as f:
            data = json.load(f)
    except Exception:
        pass
    return render(request, "web/get_app.html", {"apk": data})


# ---------------- W1: CV score ----------------
@require_http_methods(["GET", "POST"])
def cv(request):
    if request.method == "GET":
        return render(request, "web/cv.html")
    ok, h = _rate_ok(request, "w1")
    if not ok:
        return _rate_limited_page(request)
    text = request.POST.get("cv_text", "")
    f = request.FILES.get("cv_file")
    if f and not text.strip():
        try:
            text = f.read().decode("utf-8", "ignore")
        except Exception:
            text = ""
    if not text.strip():
        return render(request, "web/cv.html", {"error": "CV টেক্সট দিন বা পেস্ট করুন।"})
    result = cvlogic.score_cv(text)
    used_ai, cost, ai_tips = False, 0.0, None
    if ai.available():
        try:
            out, cost = ai.generate(
                task="নিচের CV-এর জন্য ৫টি সুনির্দিষ্ট, কাজে লাগার মতো উন্নতির পরামর্শ দাও "
                     "(প্রতিটি আলাদা লাইনে, বাংলায়)।",
                data=text[:6000], tier="cheap", feature="w1_cv", max_tokens=500)
            ai_tips = [l.strip("-•* ").strip() for l in out.splitlines() if l.strip()][:5]
            used_ai = True
        except ai.AIUnavailable:
            ai_tips = None
    _log("w1", h, used_ai, cost)
    return render(request, "web/cv_result.html",
                  {"r": result, "ai_tips": ai_tips,
                   "share_url": request.build_absolute_uri(f"/cv/r?s={result['score']}")})


def cv_share(request):
    try:
        s = max(0, min(100, int(request.GET.get("s", "0"))))
    except ValueError:
        s = 0
    return render(request, "web/cv_share.html",
                  {"score": s, "share_url": request.build_absolute_uri()})


def cv_card(request):
    try:
        s = max(0, min(100, int(request.GET.get("s", "0"))))
    except ValueError:
        s = 0
    png = cardlogic.cv_card(s, story=request.GET.get("story") == "1")
    return HttpResponse(png, content_type="image/png")


# ---------------- W2: scam checker ----------------
@require_http_methods(["GET", "POST"])
def scam(request):
    if request.method == "GET":
        return render(request, "web/scam.html")
    ok, h = _rate_ok(request, "w2")
    if not ok:
        return _rate_limited_page(request)
    msg = request.POST.get("message", "")
    if not msg.strip():
        return render(request, "web/scam.html", {"error": "মেসেজটি পেস্ট করুন।"})
    result = scamlogic.check_message(msg)
    used_ai, cost, ai_note = False, 0.0, None
    if ai.available():
        try:
            out, cost = ai.generate(
                task="নিচের মেসেজটি প্রতারণা কিনা এক-দুই বাক্যে বাংলায় ব্যাখ্যা করো।",
                data=msg[:2000], tier="cheap", feature="w2_scam", max_tokens=200)
            ai_note = out.strip()
            used_ai = True
        except ai.AIUnavailable:
            ai_note = None
    _log("w2", h, used_ai, cost)
    return render(request, "web/scam_result.html",
                  {"r": result, "ai_note": ai_note,
                   "share_url": request.build_absolute_uri(f"/scam/r?v={result['verdict']}")})


VERDICT_LABEL = {"scam": ("প্রতারণা", "⚠️"), "suspicious": ("সন্দেহজনক", "🟡"),
                 "safe": ("সম্ভবত নিরাপদ", "✅")}


def scam_share(request):
    v = request.GET.get("v", "safe")
    label, emoji = VERDICT_LABEL.get(v, VERDICT_LABEL["safe"])
    return render(request, "web/scam_share.html",
                  {"v": v, "label": label, "emoji": emoji,
                   "share_url": request.build_absolute_uri()})


def scam_card(request):
    v = request.GET.get("v", "safe")
    label, emoji = VERDICT_LABEL.get(v, VERDICT_LABEL["safe"])
    png = cardlogic.scam_card(label, emoji, story=request.GET.get("story") == "1")
    return HttpResponse(png, content_type="image/png")


# ---------------- W3: photo maker ----------------
@require_http_methods(["GET", "POST"])
def photo(request):
    if request.method == "GET":
        return render(request, "web/photo.html", {"presets": photologic.PRESETS})
    ok, h = _rate_ok(request, "w3")
    if not ok:
        return _rate_limited_page(request)
    f = request.FILES.get("photo")
    preset = request.POST.get("preset", "passport_2x2")
    if not f:
        return render(request, "web/photo.html",
                      {"presets": photologic.PRESETS, "error": "একটি ছবি আপলোড করুন।"})
    if f.size > 12 * 1024 * 1024:
        return render(request, "web/photo.html",
                      {"presets": photologic.PRESETS, "error": "ছবি ১২MB-র কম হতে হবে।"})
    try:
        jpeg, label = photologic.make_photo(f.read(), preset)
        sheet = photologic.print_sheet(jpeg)
    except Exception:
        return render(request, "web/photo.html",
                      {"presets": photologic.PRESETS, "error": "ছবি প্রসেস করা গেল না। অন্য ছবি দিন।"})
    _log("w3", h)
    return render(request, "web/photo_result.html",
                  {"img": base64.b64encode(jpeg).decode(),
                   "sheet": base64.b64encode(sheet).decode(), "label": label})


# ---------------- W4: festival cards ----------------
@require_http_methods(["GET", "POST"])
def festival(request):
    if request.method == "GET":
        return render(request, "web/festival.html", {"festivals": cardlogic.FESTIVALS})
    ok, h = _rate_ok(request, "w4")
    if not ok:
        return _rate_limited_page(request)
    key = request.POST.get("festival", "eid")
    name = request.POST.get("name", "")[:40]
    msg = request.POST.get("message", "")[:120]
    _log("w4", h)
    from urllib.parse import urlencode
    q = urlencode({"f": key, "name": name, "msg": msg})
    return render(request, "web/festival_result.html",
                  {"q": q, "festival": cardlogic.FESTIVALS.get(key, {})})


def wrapped_card(request):
    title = request.GET.get("title", "আমার মাস")[:40]
    badges = [b[:60] for b in request.GET.getlist("b")][:6]
    png = cardlogic.wrapped_card(title, badges, story=request.GET.get("story") == "1")
    return HttpResponse(png, content_type="image/png")


def festival_card(request):
    key = request.GET.get("f", "eid")
    name = request.GET.get("name", "")[:40]
    msg = request.GET.get("msg", "")[:120]
    png = cardlogic.festival_card(key, name, msg, story=request.GET.get("story") == "1")
    return HttpResponse(png, content_type="image/png")
