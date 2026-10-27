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
from .logic import webphoto
from .logic import made30 as made30logic

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
        # w1-webphoto (funnel: watermarked preview on the web, clean file in the app)
        "photo_title": "পাসপোর্ট সাইজ ছবি অনলাইনে — বাংলাদেশ পাসপোর্ট ও ভিসা ছবির মাপ | Assisto",
        "photo_meta": "বাংলাদেশ পাসপোর্ট, MRP, NID ও ভিসার মাপে ছবি কেটে দিন — ৩৫×৪৫ মিমি, ৪৫×৫৫ মিমি, ২×২ ইঞ্চি, ৬০০×৬০০। প্রিভিউ এখানে, পরিষ্কার ফাইল Assisto অ্যাপে।",
        "photo_sizes_h": "বাংলাদেশ পাসপোর্ট ও ভিসা ছবির মাপ",
        "photo_col_doc": "কাগজ",
        "photo_col_size": "মাপ",
        "photo_col_px": "পিক্সেল (৩০০ DPI)",
        "photo_sizes_note": "নিয়ম বদলাতে পারে, দূতাবাস ভেদে আলাদা হতে পারে — প্রিন্টের আগে সংশ্লিষ্ট অফিসে মিলিয়ে নিন।",
        "photo_how_h": "কীভাবে কাজ করে",
        "photo_how": ["ছবি আপলোড করে মাপ বেছে নিন।", "এখানে জলছাপসহ প্রিভিউ দেখুন — ক্রপ ঠিক আছে কিনা।", "“Assisto অ্যাপে নিন” চাপুন — একই ছবি অ্যাপের Photo Studio-তে খুলবে, সেখান থেকে পরিষ্কার ফুল-HD ফাইল সেভ/প্রিন্ট করুন।"],
        "photo_privacy_h": "গোপনীয়তা",
        "photo_privacy": "আপনার আসল ছবি সংরক্ষণ করা হয় না — শুধু মাপ করা ছবিটি অ্যাপে পাঠানোর জন্য সর্বোচ্চ ১ ঘণ্টা সার্ভারে থাকে, তারপর নিজে থেকেই মুছে যায় (অ্যাপে নিলে সঙ্গে সঙ্গে)। ছবি কারও সাথে শেয়ার বা বিক্রি করা হয় না।",
        "photo_preview_h": "প্রিভিউ (জলছাপসহ)",
        "photo_preview_note": "এটি শুধু প্রিভিউ — ছোট ও জলছাপসহ। পরিষ্কার ফুল-HD ছবি পাবেন Assisto অ্যাপে।",
        "photo_open_app": "📱 Assisto অ্যাপে নিন (পরিষ্কার ফুল-HD)",
        "photo_open_hint": "অ্যাপ ইনস্টল থাকলে একই ছবি Photo Studio-তে খুলবে (লগইন লাগবে); না থাকলে ডাউনলোড পেজ খুলবে। লিংকটি {mins} মিনিট পর্যন্ত কাজ করবে।",
        "photo_export_rule": "অ্যাপে সেভ/প্রিন্টের নিয়ম Photo Studio-র মতোই: ফ্রি ব্যবহারকারী ছোট বিজ্ঞাপন দেখে বা ক্রেডিট দিয়ে, Premium-এ সরাসরি।",
        "photo_app_h": "ছবিটি Assisto অ্যাপে খুলুন",
        "photo_app_lead": "অ্যাপ ইনস্টল থাকলে নিচের বোতাম চাপুন — একই ছবি Photo Studio-তে খুলবে। অ্যাপ না থাকলে আগে ইনস্টল করুন, তারপর এই পেজে ফিরে আবার চাপুন।",
        "photo_app_btn": "অ্যাপে ছবিটি খুলুন",
        "photo_app_expired": "লিংকটির মেয়াদ শেষ বা আগেই ব্যবহার হয়েছে। ছবি ১ ঘণ্টা পর মুছে যায় — আবার বানিয়ে নিন।",
        "photo_app_valid": "লিংকটি আর প্রায় {mins} মিনিট কাজ করবে।",
        # Festival
        "fest_h": "🎉 উৎসবের শুভেচ্ছা কার্ড",
        "fest_lead": "উৎসব বেছে নিন, নাম লিখুন — সুন্দর কার্ড বানিয়ে দেব। ফেসবুক/হোয়াটসঅ্যাপে শেয়ার করুন।",
        "fest_select": "উৎসব",
        "fest_name": "আপনার নাম (ঐচ্ছিক)",
        "fest_msg": "বার্তা (ঐচ্ছিক)",
        "fest_btn": "কার্ড বানান",
        "fest_cta": "📱 আরও সুবিধা — অ্যাপ নিন",
        # Made in 30s — instant shop poster
        "m30_h": "⚡ ৩০ সেকেন্ডে পোস্টার",
        "m30_lead": "দোকান/পেজের নাম, কয়েকটি পণ্যের দাম লিখুন — সাথে সাথে শেয়ার করার মতো সুন্দর পোস্টার পাবেন। লগইন লাগবে না, ডাটা সেভ হয় না।",
        "m30_shop": "দোকান / পেজের নাম",
        "m30_tag": "ট্যাগলাইন (ঐচ্ছিক)",
        "m30_items": "পণ্য ও দাম (প্রতি লাইনে একটি: নাম - দাম)",
        "m30_items_ph": "চা - ১০৳\nসিঙ্গারা - ১৫৳\nকফি - ৫০৳",
        "m30_phone": "মোবাইল / অর্ডার নম্বর (ঐচ্ছিক)",
        "m30_theme": "রঙ",
        "m30_btn": "পোস্টার বানান",
        "m30_empty": "দোকান / পেজের নাম লিখুন।",
        "m30_cta": "📱 ব্যবসা চালান Assisto অ্যাপে — খাতা, রিমাইন্ডার, গ্রাহক",
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
        # w1-webphoto
        "photo_title": "Passport Photo Bangladesh Online — BD Passport & Visa Photo Size | Assisto",
        "photo_meta": "Make a passport photo for Bangladesh: e-Passport 35×45 mm, MRP 45×55 mm, NID, 2×2 inch and US visa 600×600. Free preview here; the clean file in the Assisto app.",
        "photo_sizes_h": "Bangladesh passport & visa photo sizes",
        "photo_col_doc": "Document",
        "photo_col_size": "Size",
        "photo_col_px": "Pixels (300 DPI)",
        "photo_sizes_note": "Rules change and missions abroad may differ — confirm with the office before printing.",
        "photo_how_h": "How it works",
        "photo_how": ["Upload a photo and choose the size.", "Check the watermarked preview here — is the crop right?", "Tap \u201cGet it in the Assisto app\u201d — the same photo opens in Photo Studio, where you save or print the clean full-HD file."],
        "photo_privacy_h": "Privacy",
        "photo_privacy": "Your original photo is not stored. Only the sized photo is kept on the server — for at most 1 hour, so the app can fetch it — and then it is deleted automatically (immediately once the app takes it). Photos are never shared or sold.",
        "photo_preview_h": "Preview (watermarked)",
        "photo_preview_note": "This is a preview only — small and watermarked. The clean full-HD photo is in the Assisto app.",
        "photo_open_app": "📱 Get it in the Assisto app (clean full-HD)",
        "photo_open_hint": "If the app is installed, the same photo opens in Photo Studio (sign-in needed); if not, the download page opens. The link works for {mins} minutes.",
        "photo_export_rule": "Saving/printing in the app follows the normal Photo Studio rule: free users watch a short ad or use credits; Premium saves directly.",
        "photo_app_h": "Open this photo in the Assisto app",
        "photo_app_lead": "If the app is installed, tap the button below — the same photo opens in Photo Studio. If not, install it first, then come back to this page and tap again.",
        "photo_app_btn": "Open the photo in the app",
        "photo_app_expired": "This link has expired or was already used. Photos are deleted after 1 hour — please make it again.",
        "photo_app_valid": "This link works for about {mins} more minutes.",
        "fest_h": "🎉 Festival greeting cards",
        "fest_lead": "Pick a festival, add your name — we'll make a shareable card for Facebook / WhatsApp.",
        "fest_select": "Festival",
        "fest_name": "Your name (optional)",
        "fest_msg": "Message (optional)",
        "fest_btn": "Make card",
        "fest_cta": "📱 Get the Assisto app",
        "m30_h": "⚡ Poster in 30 seconds",
        "m30_lead": "Type your shop / page name and a few items with prices — instantly get a clean, shareable poster. No login, nothing saved.",
        "m30_shop": "Shop / page name",
        "m30_tag": "Tagline (optional)",
        "m30_items": "Items & prices (one per line: name - price)",
        "m30_items_ph": "Tea - 10 Tk\nSamosa - 15 Tk\nCoffee - 50 Tk",
        "m30_phone": "Mobile / order number (optional)",
        "m30_theme": "Colour",
        "m30_btn": "Make poster",
        "m30_empty": "Please enter a shop / page name.",
        "m30_cta": "📱 Run your business in the Assisto app — ledger, reminders, customers",
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


# ---------------- W3: photo maker (w1-webphoto: funnel, no free bypass) ----------------
# The web shows ONLY a reduced, watermarked preview (as an inline data: URI).
# The clean file is parked under an unguessable token (DB, <= 1 hour) and is
# reachable only by the logged-in app (POST /api/v1/web-photo/claim), where
# the normal Photo Studio export gate applies. No web route serves it.
PHOTO_RATE_PER_HOUR = 20
APP_PACKAGE = "com.assisto.assisto"


def _site():
    return getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")


def _photo_seo(request, lang, path="/photo"):
    site = _site()
    bn_url = site + path
    en_url = site + path + "?lang=en"
    return {"canonical": en_url if lang == "en" else bn_url,
            "alt_bn": bn_url, "alt_en": en_url}


def _photo_base(request, lang):
    T = UI.get(lang, UI["bn"])
    presets = [(k, (p[0] if lang == "bn" else p[1]), p[4], p[5])
               for k, p in photologic.PRESETS.items()]
    sizes = [((p[0] if lang == "bn" else p[1]), p[4], "%d×%d" % (p[2], p[3]),
              photologic.PRESET_NOTES[lang].get(k, ""))
             for k, p in photologic.PRESETS.items()]
    return dict(presets=presets, sizes=sizes, guide=photologic.GUIDANCE[lang],
                bg_note=photologic.BG_NOTE[lang], how=T["photo_how"],
                seo=_photo_seo(request, lang))


def _app_links(request, token, lang):
    """(https App Link, href for the button). On Android Chrome an intent: URL
    opens the app when installed and falls back to the download page when not
    (Chrome never hands a same-site https link to an app by itself)."""
    from urllib.parse import quote
    q = "&lang=en" if lang == "en" else ""
    https = "%s/photo/app?t=%s%s" % (_site(), token, q)
    ua = request.META.get("HTTP_USER_AGENT", "")
    if "Android" not in ua:
        return https, https
    host = _site().split("://", 1)[-1]
    fallback = quote(https, safe="")
    intent = ("intent://%s/photo/app?t=%s%s#Intent;scheme=https;package=%s;"
              "S.browser_fallback_url=%s;end" % (host, token, q, APP_PACKAGE, fallback))
    return https, intent


@require_http_methods(["GET", "POST"])
def photo(request):
    lang = _lang(request)
    base = _photo_base(request, lang)
    if request.method == "GET":
        return render(request, "web/photo.html", _ctx(request, **base))
    ok, h = _rate_ok(request, "w3")
    if ok:
        since = timezone.now() - timedelta(hours=1)
        ok = ToolUsage.objects.filter(tool="w3", ip_hash=h,
                                      created_at__gte=since).count() < PHOTO_RATE_PER_HOUR
    if not ok:
        return _rate_limited_page(request)
    f = request.FILES.get("photo")
    preset = request.POST.get("preset", "bd_passport")
    if preset not in photologic.PRESETS:
        preset = "bd_passport"
    if not f:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_none"], **base))
    if f.size > 12 * 1024 * 1024:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_big"], **base))
    try:
        clean, label = photologic.make_photo(f.read(), preset, lang=lang)
        preview = webphoto.watermarked_preview(clean)
    except Exception:
        return render(request, "web/photo.html", _ctx(request, error=UI[lang]["photo_err_proc"], **base))
    drop = webphoto.park(clean, preset, ip_hash=h)
    del clean                                   # never rendered, never linked
    wants_bg = photologic.PRESETS[preset][5]
    _log("w3", h)
    https, href = _app_links(request, drop.token, lang)
    mins = int(webphoto.ttl().total_seconds() // 60)
    resp = render(request, "web/photo_result.html",
                  _ctx(request, preview=base64.b64encode(preview).decode(), label=label,
                       app_href=href, app_https=https,
                       open_hint=UI[lang]["photo_open_hint"].format(mins=mins),
                       bg_note=base["bg_note"] if wants_bg else None,
                       seo=base["seo"]))
    resp["Cache-Control"] = "no-store"
    resp["Referrer-Policy"] = "no-referrer"     # the token must not leak via Referer
    return resp


def photo_app(request):
    """https://lifeassisto.com/photo/app?t=<token> — the App Link target.
    With the app installed (verified App Links) Android opens the app and
    this page never loads. In a browser it shows install/open help. It NEVER
    returns any image bytes."""
    lang = _lang(request)
    token = request.GET.get("t", "")
    drop = webphoto.live_drop(token)            # expired -> deleted right here
    data = {}
    try:
        with open(settings.APP_LATEST_FILE) as fh:
            data = json.load(fh)
    except Exception:
        pass
    ctx = {"apk": data, "seo": _photo_seo(request, lang, "/photo")}
    if drop is not None:
        _https, href = _app_links(request, drop.token, lang)
        left = max(1, int((drop.expires_at - timezone.now()).total_seconds() // 60))
        ctx.update(app_href=href, valid_note=UI[lang]["photo_app_valid"].format(mins=left))
    resp = render(request, "web/get_app.html", _ctx(request, photo_link=True,
                                                   photo_ok=drop is not None, **ctx))
    resp["Cache-Control"] = "no-store"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Robots-Tag"] = "noindex"
    return resp


def assetlinks(request):
    """/.well-known/assetlinks.json for Android App Links (lifeassisto.com/photo/app).
    Fingerprints come from ANDROID_CERT_SHA256 (comma-separated SHA-256 of the
    release signing certificate — public, not a secret). Empty -> [] (honest:
    links then open the browser page, which still offers the app)."""
    import os
    raw = getattr(settings, "ANDROID_CERT_SHA256", "") or os.getenv("ANDROID_CERT_SHA256", "")
    fps = [x.strip().upper() for x in raw.split(",") if x.strip()]
    body = []
    if fps:
        body = [{"relation": ["delegate_permission/common.handle_all_urls"],
                 "target": {"namespace": "android_app", "package_name": APP_PACKAGE,
                            "sha256_cert_fingerprints": fps}}]
    return HttpResponse(json.dumps(body), content_type="application/json")


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


# ---------------- W5: Made in 30 seconds (instant shop poster) ----------------
@require_http_methods(["GET", "POST"])
def made30(request):
    lang = _lang(request)
    themes = [(k, (t["name_bn"] if lang == "bn" else t["name_en"]))
              for k, t in made30logic.THEMES.items()]
    if request.method == "GET":
        return render(request, "web/made30.html", _ctx(request, themes=themes))
    ok, h = _rate_ok(request, "w5")
    if not ok:
        return _rate_limited_page(request)
    shop = request.POST.get("shop", "").strip()[:made30logic.NAME_MAX]
    if not shop:
        return render(request, "web/made30.html",
                      _ctx(request, error=UI[lang]["m30_empty"], themes=themes))
    tagline = request.POST.get("tagline", "").strip()[:made30logic.TAG_MAX]
    phone = request.POST.get("phone", "").strip()[:20]
    theme = request.POST.get("theme", made30logic.DEFAULT_THEME)
    if theme not in made30logic.THEMES:
        theme = made30logic.DEFAULT_THEME
    items = made30logic.parse_items(request.POST.get("items", ""), lang=lang)
    _log("w5", h)
    from urllib.parse import urlencode
    pairs = [("shop", shop), ("tag", tagline), ("phone", phone),
             ("theme", theme), ("lang", lang)]
    for name, price in items:
        pairs.append(("i", name + ("|" + price if price else "")))
    q = urlencode(pairs)
    return render(request, "web/made30_result.html", _ctx(request, q=q, title=shop))


def made30_card(request):
    lang = _lang(request)
    shop = request.GET.get("shop", "")[:made30logic.NAME_MAX]
    tagline = request.GET.get("tag", "")[:made30logic.TAG_MAX]
    phone = request.GET.get("phone", "")[:20]
    theme = request.GET.get("theme", made30logic.DEFAULT_THEME)
    items = []
    for raw in request.GET.getlist("i")[:made30logic.MAX_ITEMS]:
        name, _, price = raw.partition("|")
        name = name.strip()[:made30logic.ITEM_NAME_MAX]
        if name:
            items.append((name, price.strip()[:made30logic.PRICE_MAX]))
    png = made30logic.poster_card(shop, tagline=tagline, items=items, phone=phone,
                                  theme=theme, story=request.GET.get("story") == "1",
                                  lang=lang)
    return HttpResponse(png, content_type="image/png")


# ---- m3-circle: /i/<token> — the page a My Circle invite link opens ----
def referral_invite(request, raw):
    """p5-growth: https://lifeassisto.com/i/<CODE> — invite landing. Shows the
    code + Play link (carrying the code as install referrer) and the honest
    reward rule. Never shows the inviter's name, phone or any account data."""
    from core import growth as G
    from core.models import User as _User
    lang = _lang(request)
    code = G.normalize_code(raw)
    valid = bool(code) and _User.objects.filter(
        referral_code=code, is_active=True, account_status="active").exists()
    c = G.cfg()
    bn = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
    ctx = _ctx(request, code=code, valid=valid,
               play_url=G.play_link(code if valid else ""),
               claim_days=c["invite_claim_days"],
               claim_days_bn=str(c["invite_claim_days"]).translate(bn),
               need=c["invite_activation_days"],
               need_bn=str(c["invite_activation_days"]).translate(bn),
               inviter_credits=c["invite_credits_inviter"],
               invitee_credits=c["invite_credits_invitee"],
               inviter_credits_bn=str(c["invite_credits_inviter"]).translate(bn),
               invitee_credits_bn=str(c["invite_credits_invitee"]).translate(bn))
    resp = render(request, "web/invite.html", ctx, status=200 if valid else 404)
    resp["Cache-Control"] = "public, max-age=300"
    return resp


def circle_join_landing(request, raw):
    """invite-join: https://lifeassisto.com/i/<CODE>. With the app installed
    (verified App Link on /i/) Android opens the app and this page never
    loads. Shows only the inviter's FIRST name. None = not a circle code
    (the caller falls through to the referral landing)."""
    from core import invite_join as IJ
    from core import otp as _otp
    lang = _lang(request)
    ip = _otp.client_ip(request)
    if IJ.ip_locked(ip) or not IJ.preview_rate_ok(ip):
        return _rate_limited_page(request)
    inv = IJ.find(raw)
    if inv is None:
        IJ.note_bad(ip)
        return None
    code = inv.code
    p = IJ.preview(inv, lang)
    ok = bool(p.get("ok"))
    name = p.get("inviter_name", "") if ok else ""
    intent_url = ("intent://%s/i/%s#Intent;scheme=https;package=%s;"
                  "S.browser_fallback_url=%s;end" % (
                      _site().split("://", 1)[-1], code, APP_PACKAGE,
                      IJ.play_link(code).replace("&", "%26").replace("=", "%3D")
                      .replace(":", "%3A").replace("/", "%2F").replace("?", "%3F")))
    ctx = _ctx(request, ok=ok, code=code, name=name,
               initial=(name[:1] or "A"), intent_url=intent_url,
               play_url=IJ.play_link(code),
               reason_text=IJ.message(p.get("state", "invalid"), lang))
    resp = render(request, "web/circle_join.html", ctx, status=200 if ok else 410)
    resp["Cache-Control"] = "no-store"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Robots-Tag"] = "noindex"
    return resp


def circle_invite(request, token):
    """Landing page for a shared My Circle invite (QR / share / SMS link).
    Bilingual, no login. Step 1 install Assisto, step 2 in the app: My Circle
    -> Add to My Circle -> "Paste invite link". Never reveals the inviter's
    phone; shows only their display name when the token is valid."""
    # invite-join: a 10-char circle invite code -> "Join X's circle" (App
    # Link opens the app; else Play with the code as install referrer).
    from core import invite_join as _IJ
    if _IJ.looks_like_code(token):
        resp = circle_join_landing(request, token)
        if resp is not None:
            return resp
    # p5-growth: a short code without a dot is an INVITE CODE (referral), not a
    # signed My Circle token -> the referral landing (Play link + the code).
    if "." not in token and len(token) <= 12:
        return referral_invite(request, token)
    from django.utils.html import escape
    from core.logic import circle as _circle
    from core.models import User as _User
    from django.conf import settings as _s
    ok, _info = _circle.parse_invite_token(token, _s.SECRET_KEY)
    name = ""
    if ok:
        try:
            u = _User.objects.filter(pk=int(token.split(".", 1)[0])).first()
            name = (u.name or "").strip() if u else ""
        except (TypeError, ValueError):
            name = ""
    link = escape(request.build_absolute_uri())
    who_bn = f"{escape(name)} আপনাকে" if name else "আপনাকে"
    who_en = f"{escape(name)} invited you" if name else "You were invited"
    state_bn = "" if ok else "<p><b>এই লিংকের মেয়াদ শেষ বা সঠিক নয় — নতুন লিংক চেয়ে নিন।</b></p>"
    state_en = "" if ok else "<p><b>This link has expired or isn't valid — ask for a new one.</b></p>"
    html = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Assisto — My Circle</title>
<style>body{{font-family:system-ui,sans-serif;max-width:560px;margin:auto;padding:24px;line-height:1.5}}
a.b{{display:inline-block;background:#2563eb;color:#fff;padding:12px 18px;border-radius:12px;text-decoration:none}}
code{{word-break:break-all;background:#f1f5f9;padding:6px;border-radius:6px;display:block}}</style></head><body>
<h2>{who_bn} Assisto-র “আমার সার্কেল”-এ যোগ হতে আমন্ত্রণ জানিয়েছেন</h2>{state_bn}
<ol><li>Assisto অ্যাপ ইনস্টল করুন: <a class="b" href="/get">অ্যাপ নিন</a></li>
<li>অ্যাপে: আমার সার্কেল → ＋ → আমার সার্কেলে যোগ করুন → “আমন্ত্রণ লিংক পেস্ট করুন”, তারপর এই লিংকটি দিন:</li></ol>
<code>{link}</code><hr>
<h3>{who_en} to their Assisto My Circle</h3>{state_en}
<ol><li>Install Assisto: <a class="b" href="/get">Get the app</a></li>
<li>In the app: My Circle → + → Add to My Circle → "Paste invite link", and paste the link above.</li></ol>
</body></html>"""
    return HttpResponse(html)
