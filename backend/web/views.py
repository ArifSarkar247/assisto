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


def _lang(request):
    """Pages are strictly single-language. ?lang=en → English page; default Bangla."""
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_limited_page(request):
    return render(request, "web/limited.html", {"lang": _lang(request)}, status=429)


def _ctx(request, **extra):
    lang = _lang(request)
    ctx = {"lang": lang, "T": UI.get(lang, UI["bn"]), "qlang": "?lang=en" if lang == "en" else ""}
    ctx.update(extra)
    return ctx


# ---------------- UI label bundles (bn/en) ----------------
UI = {
    "bn": {
        "get_app": "📱 আরও সুবিধা — অ্যাপ নিন",
        "again": "↺ আবার চেষ্টা করুন",
        "share_friends": "বন্ধুদের শেয়ার করুন",
        "download_card": "কার্ড ডাউনলোড",
        "story_card": "স্টোরি সাইজ কার্ড",
        # CV
        "cv_h": "📄 CV স্কোর",
        "cv_lead": "আপনার CV-র লেখা পেস্ট করুন। আমরা ১০০-তে স্কোর ও সুনির্দিষ্ট পরামর্শ দেব। ডাটা সেভ করা হয় না।",
        "cv_disclaimer": "এটি নির্দেশনা, চাকরির নিশ্চয়তা নয়।",
        "cv_paste": "CV টেক্সট পেস্ট করুন",
        "cv_file": "অথবা .txt ফাইল দিন (ঐচ্ছিক)",
        "cv_btn": "স্কোর দেখুন",
        "cv_empty": "CV টেক্সট দিন বা পেস্ট করুন।",
        "cv_breakdown": "কোথায় কত পেলেন",
        "cv_tips": "উন্নতির পরামর্শ",
        "cv_redflags": "যা এখনই ঠিক করা দরকার",
        "cv_keywords": "যে চাকরি-বাজার কিওয়ার্ড পাওয়া গেছে",
        "cv_cta": "📱 চাকরি খুঁজছেন? অ্যাপের Job Hunter দিয়ে এগিয়ে যান",
        "cv_words": "শব্দ",
        # Scam
        "scam_h": "🛡️ স্ক্যাম চেকার",
        "scam_lead": "সন্দেহজনক SMS/মেসেজ/নম্বর/লিংক পেস্ট করুন — প্রতারণার লক্ষণ আছে কিনা যাচাই করে দেব। ডাটা সেভ করা হয় না।",
        "scam_paste": "মেসেজ / নম্বর / লিংক পেস্ট করুন",
        "scam_btn": "যাচাই করুন",
        "scam_empty": "মেসেজটি পেস্ট করুন।",
        "scam_why": "কেন এই সিদ্ধান্ত",
        "scam_report": "রিপোর্ট ও সাহায্য",
        "scam_risk": "ঝুঁকি স্কোর",
        "scam_warn_family": "পরিবারকে সাবধান করুন",
        "scam_cta": "📱 পরিবারের সুরক্ষায় অ্যাপের Scam Protection নিন",
        # Photo
        "photo_h": "🪪 পাসপোর্ট / ভিসা / NID ছবি",
        "photo_lead": "নিজের ছবি আপলোড করুন — সঠিক মাপে কেটে তৈরি করে দেব। শুধু আপনার নিজের ছবি ব্যবহার করুন; পরিচয় বদলানো হয় না।",
        "photo_upload": "ছবি আপলোড করুন",
        "photo_size": "সাইজ বেছে নিন",
        "photo_btn": "ছবি বানান",
        "photo_guide": "ভালো ছবির টিপস",
        "photo_err_none": "একটি ছবি আপলোড করুন।",
        "photo_err_big": "ছবি ১২MB-র কম হতে হবে।",
        "photo_err_proc": "ছবি প্রসেস করা গেল না। অন্য ছবি দিন।",
        "photo_dl": "ছবি ডাউনলোড",
        "photo_sheet": "প্রিন্ট শিট (৪ কপি)",
        "photo_cta": "📱 ছবি আরও সুন্দর করতে অ্যাপের Photo Enhance নিন",
        # Festival
        "fest_h": "🎉 উৎসবের শুভেচ্ছা কার্ড",
        "fest_lead": "উৎসব বেছে নিন, নাম লিখুন — সুন্দর কার্ড বানিয়ে দেব। ফেসবুক/হোয়াটসঅ্যাপে শেয়ার করুন।",
        "fest_select": "উৎসব",
        "fest_name": "আপনার নাম (ঐচ্ছিক)",
        "fest_msg": "বার্তা (ঐচ্ছিক)",
        "fest_btn": "কার্ড বানান",
        "fest_cta": "📱 আরও সুবিধা — অ্যাপ নিন",
    },
    "en": {
        "get_app": "📱 Get the Assisto app",
        "again": "↺ Try again",
        "share_friends": "Share with friends",
        "download_card": "Download card",
        "story_card": "Story-size card",
        "cv_h": "📄 CV Score",
        "cv_lead": "Paste your CV text. We'll score it out of 100 with concrete feedback. Nothing is saved.",
        "cv_disclaimer": "This is guidance, not a guarantee of a job.",
        "cv_paste": "Paste your CV text",
        "cv_file": "Or upload a .txt file (optional)",
        "cv_btn": "See my score",
        "cv_empty": "Please paste or upload your CV text.",
        "cv_breakdown": "Where your points came from",
        "cv_tips": "Improvement tips",
        "cv_redflags": "Fix these first",
        "cv_keywords": "Job-market keywords found",
        "cv_cta": "📱 Job hunting? Go further with Job Hunter in the app",
        "cv_words": "words",
        "scam_h": "🛡️ Scam Checker",
        "scam_lead": "Paste a suspicious SMS / message / number / link — we'll screen it for scam signals. Nothing is saved.",
        "scam_paste": "Paste the message / number / link",
        "scam_btn": "Check it",
        "scam_empty": "Please paste the message.",
        "scam_why": "Why this verdict",
        "scam_report": "Report & help",
        "scam_risk": "Risk score",
        "scam_warn_family": "Warn your family",
        "scam_cta": "📱 Protect your family with Scam Protection in the app",
        "photo_h": "🪪 Passport / Visa / NID photo",
        "photo_lead": "Upload your photo — we'll crop and size it to spec. Use only your own photo; identity is never altered.",
        "photo_upload": "Upload a photo",
        "photo_size": "Choose a size",
        "photo_btn": "Make photo",
        "photo_guide": "Tips for a good photo",
        "photo_err_none": "Please upload a photo.",
        "photo_err_big": "Photo must be under 12MB.",
        "photo_err_proc": "Could not process the image. Try another photo.",
        "photo_dl": "Download photo",
        "photo_sheet": "Print sheet (4 copies)",
        "photo_cta": "📱 Make photos look better with Photo Enhance in the app",
        "fest_h": "🎉 Festival greeting cards",
        "fest_lead": "Pick a festival, add your name — we'll make a shareable card for Facebook / WhatsApp.",
        "fest_select": "Festival",
        "fest_name": "Your name (optional)",
        "fest_msg": "Message (optional)",
        "fest_btn": "Make card",
        "fest_cta": "📱 Get the Assisto app",
    },
}


# ---------------- landing ----------------
def landing(request):
    return render(request, "web/landing.html", _ctx(request))


def get_app(request):
    data = {}
    try:
        with open(settings.APP_LATEST_FILE) as f:
            data = json.load(f)
    except Exception:
        pass
    return render(request, "web/get_app.html", _ctx(request, apk=data))


# ---------------- W1: CV score ----------------
@require_http_methods(["GET", "POST"])
def cv(request):
    lang = _lang(request)
    if request.method == "GET":
        return render(request, "web/cv.html", _ctx(request))
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
        return render(request, "web/cv.html", _ctx(request, error=UI[lang]["cv_empty"]))
    result = cvlogic.score_cv(text, lang=lang)
    used_ai, cost, ai_tips = False, 0.0, None
    if ai.available():
        try:
            task = ("নিচের CV-এর জন্য ৫টি সুনির্দিষ্ট, কাজে লাগার মতো উন্নতির পরামর্শ দাও "
                    "(প্রতিটি আলাদা লাইনে, বাংলায়)।") if lang == "bn" else (
                "Give 5 specific, actionable improvement tips for the CV below "
                "(one per line, in English).")
            out, cost = ai.generate(task=task, data=text[:6000], tier="cheap",
                                     feature="w1_cv", max_tokens=500)
            ai_tips = [l.strip("-•* ").strip() for l in out.splitlines() if l.strip()][:5]
            used_ai = True
        except ai.AIUnavailable:
            ai_tips = None
    _log("w1", h, used_ai, cost)
    share = request.build_absolute_uri(f"/cv/r?s={result['score']}")
    if lang == "en":
        share += "&lang=en"
    return render(request, "web/cv_result.html",
                  _ctx(request, r=result, ai_tips=ai_tips, share_url=share))


def cv_share(request):
    try:
        s = max(0, min(100, int(request.GET.get("s", "0"))))
    except ValueError:
        s = 0
    return render(request, "web/cv_share.html",
                  _ctx(request, score=s, share_url=request.build_absolute_uri()))


def cv_card(request):
    try:
        s = max(0, min(100, int(request.GET.get("s", "0"))))
    except ValueError:
        s = 0
    png = cardlogic.cv_card(s, story=request.GET.get("story") == "1", lang=_lang(request))
    return HttpResponse(png, content_type="image/png")


# ---------------- W2: scam checker ----------------
@require_http_methods(["GET", "POST"])
def scam(request):
    lang = _lang(request)
    if request.method == "GET":
        return render(request, "web/scam.html", _ctx(request))
    ok, h = _rate_ok(request, "w2")
    if not ok:
        return _rate_limited_page(request)
    msg = request.POST.get("message", "")
    if not msg.strip():
        return render(request, "web/scam.html", _ctx(request, error=UI[lang]["scam_empty"]))
    result = scamlogic.check_message(msg, lang=lang)
    used_ai, cost, ai_note = False, 0.0, None
    if ai.available():
        try:
            task = ("নিচের মেসেজটি প্রতারণা কিনা এক-দুই বাক্যে বাংলায় ব্যাখ্যা করো।"
                    if lang == "bn" else
                    "In one or two sentences, explain in English whether the message below is a scam.")
            out, cost = ai.generate(task=task, data=msg[:2000], tier="cheap",
                                     feature="w2_scam", max_tokens=200)
            ai_note = out.strip()
            used_ai = True
        except ai.AIUnavailable:
            ai_note = None
    _log("w2", h, used_ai, cost)
    share = request.build_absolute_uri(f"/scam/r?v={result['verdict']}")
    if lang == "en":
        share += "&lang=en"
    return render(request, "web/scam_result.html",
                  _ctx(request, r=result, ai_note=ai_note, share_url=share))


def scam_share(request):
    lang = _lang(request)
    v = request.GET.get("v", "safe")
    labels = scamlogic.VERDICT_LABEL.get(lang, scamlogic.VERDICT_LABEL["bn"])
    label, emoji = labels.get(v, labels["safe"])
    return render(request, "web/scam_share.html",
                  _ctx(request, v=v, label=label, emoji=emoji,
                       share_url=request.build_absolute_uri()))


def scam_card(request):
    lang = _lang(request)
    v = request.GET.get("v", "safe")
    labels = scamlogic.VERDICT_LABEL.get(lang, scamlogic.VERDICT_LABEL["bn"])
    label, emoji = labels.get(v, labels["safe"])
    png = cardlogic.scam_card(label, emoji, story=request.GET.get("story") == "1", lang=lang)
    return HttpResponse(png, content_type="image/png")


# ---------------- W3: photo maker ----------------
@require_http_methods(["GET", "POST"])
def photo(request):
    lang = _lang(request)
    presets = [(k, (p[0] if lang == "bn" else p[1]), p[4], p[5])
               for k, p in photologic.PRESETS.items()]
    guide = photologic.GUIDANCE[lang]
    bg_note = photologic.BG_NOTE[lang]
    if request.method == "GET":
        return render(request, "web/photo.html",
                      _ctx(request, presets=presets, guide=guide, bg_note=bg_note))
    ok, h = _rate_ok(request, "w3")
    if not ok:
        return _rate_limited_page(request)
    f = request.FILES.get("photo")
    preset = request.POST.get("preset", "bd_passport")
    base = dict(presets=presets, guide=guide, bg_note=bg_note)
    if not f:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_none"], **base))
    if f.size > 12 * 1024 * 1024:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_big"], **base))
    try:
        jpeg, label = photologic.make_photo(f.read(), preset, lang=lang)
        sheet = photologic.print_sheet(jpeg)
    except Exception:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_proc"], **base))
    wants_bg = photologic.PRESETS.get(preset, photologic.PRESETS["bd_passport"])[5]
    _log("w3", h)
    return render(request, "web/photo_result.html",
                  _ctx(request, img=base64.b64encode(jpeg).decode(),
                       sheet=base64.b64encode(sheet).decode(), label=label,
                       bg_note=bg_note if wants_bg else None))


# ---------------- W4: festival cards ----------------
@require_http_methods(["GET", "POST"])
def festival(request):
    lang = _lang(request)
    festivals = [(k, (f["title"] if lang == "bn" else f["title_en"]),
                  (f["sub"] if lang == "bn" else f["sub_en"]))
                 for k, f in cardlogic.FESTIVALS.items()]
    if request.method == "GET":
        return render(request, "web/festival.html", _ctx(request, festivals=festivals))
    ok, h = _rate_ok(request, "w4")
    if not ok:
        return _rate_limited_page(request)
    key = request.POST.get("festival", "eid")
    name = request.POST.get("name", "")[:40]
    msg = request.POST.get("message", "")[:120]
    _log("w4", h)
    from urllib.parse import urlencode
    q = urlencode({"f": key, "name": name, "msg": msg, "lang": lang})
    f = cardlogic.FESTIVALS.get(key, {})
    title = (f.get("title") if lang == "bn" else f.get("title_en")) or ""
    return render(request, "web/festival_result.html",
                  _ctx(request, q=q, title=title))


def wrapped_card(request):
    title = request.GET.get("title", "আমার মাস")[:40]
    badges = [b[:60] for b in request.GET.getlist("b")][:6]
    png = cardlogic.wrapped_card(title, badges, story=request.GET.get("story") == "1")
    return HttpResponse(png, content_type="image/png")


def festival_card(request):
    key = request.GET.get("f", "eid")
    name = request.GET.get("name", "")[:40]
    msg = request.GET.get("msg", "")[:120]
    png = cardlogic.festival_card(key, name, msg, story=request.GET.get("story") == "1",
                                  lang=_lang(request))
    return HttpResponse(png, content_type="image/png")
