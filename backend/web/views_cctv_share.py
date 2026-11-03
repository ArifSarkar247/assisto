"""cctvteam — lifeassisto.com/c/<token>: a view-only CCTV share link for
someone WITHOUT the app (core.cctv_team_views; model CctvShareLink, only the
token's SHA-256 is stored).

What the page shows — honestly:
  active    the chosen cameras' newest still photos, refreshed every 30 s
            (a fresh photo from the camera maker's cloud at most once a
            minute per camera; else the newest photo Assisto already has),
            "shared until HH:MM", status pill per camera
  expired / revoked / paused   nothing but that sentence
  bad       404
Never audio, never past photos, never live video in the browser (WebRTC on
the web is not built yet — said on the page). noindex, no-store, no ads,
rate-limited per IP (40 / min). Every open is logged for the owner.
"""
from django.core.cache import cache
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_GET

from core import cctv_team_views as CTV

from .views import _ip_hash

RATE_PER_MIN = 40

TXT = {
    "bn": {
        "title": "শেয়ার করা ক্যামেরা", "brand": "Assisto সিসিটিভি",
        "until": "লিংক খোলা থাকবে", "updated": "ছবির সময়",
        "online": "চালু", "offline": "অফলাইন", "never": "এখনো সংযোগ হয়নি", "off": "বন্ধ",
        "nophoto": "এই ক্যামেরার কোনো ছবি এখনো নেই।",
        "active": "দেখার অনুমতি আছে — শুধু দেখা যাবে",
        "expired": "এই লিংকের মেয়াদ শেষ। আর কিছু দেখানো হয় না।",
        "revoked": "মালিক এই লিংকটি বন্ধ করে দিয়েছেন।",
        "paused": "এই সুবিধাটি এখন বন্ধ আছে।",
        "bad": "লিংকটি ঠিক নেই।",
        "refresh": "প্রতি ৩০ সেকেন্ডে ছবি নিজে থেকে হালনাগাদ হয়। ব্রাউজারে লাইভ ভিডিও এখনো নেই — চলমান ছবি দেখতে Assisto অ্যাপ লাগবে।",
        "noaudio": "কোনো শব্দ শেয়ার হয় না।",
        "privacy": "শুধু ক্যামেরার মালিক যাঁদের লিংক দিয়েছেন তাঁরা এটা দেখতে পান; কে কখন খুলেছেন মালিক দেখতে পান। আগের ছবি বা ভিডিও এখানে নেই। মেয়াদ শেষ হলে বা মালিক বন্ধ করলে আর কিছু দেখায় না। Assisto-র কর্মীরাও এই ক্যামেরা দেখতে পারেন না।",
        "offline_net": "ইন্টারনেট নেই — আবার চেষ্টা চলছে।",
        "limited": "অনেকবার চেষ্টা হয়েছে। এক মিনিট পরে আবার খুলুন।",
        "ago_s": "{n} সেকেন্ড আগে", "ago_m": "{n} মিনিট আগে", "ago_h": "{n} ঘণ্টা আগে",
        "other": "English",
    },
    "en": {
        "title": "Shared cameras", "brand": "Assisto CCTV",
        "until": "Link open until", "updated": "Photo taken",
        "online": "Online", "offline": "Offline", "never": "Not connected yet", "off": "Off",
        "nophoto": "No photo from this camera yet.",
        "active": "You may view — view only",
        "expired": "This link has expired. Nothing is shown any more.",
        "revoked": "The owner turned this link off.",
        "paused": "This is switched off right now.",
        "bad": "This link is not valid.",
        "refresh": "Photos update by themselves every 30 seconds. There is no live video in the browser yet — moving video needs the Assisto app.",
        "noaudio": "No sound is ever shared.",
        "privacy": "Only people the camera owner gave this link to can see it, and the owner sees when it was opened. No past photos or video are here. Nothing is shown after it expires or the owner turns it off. Assisto staff cannot see these cameras either.",
        "offline_net": "No internet — retrying.",
        "limited": "Too many tries. Please open it again in a minute.",
        "ago_s": "{n} s ago", "ago_m": "{n} min ago", "ago_h": "{n} h ago",
        "other": "বাংলা",
    },
}


def _lang(request):
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_ok(request):
    key = "cshare:%s:%s" % (_ip_hash(request), timezone.now().strftime("%Y%m%d%H%M"))
    try:
        n = cache.get(key, 0) + 1
        cache.set(key, n, 90)
        return n <= RATE_PER_MIN
    except Exception:
        return True


def _headers(resp):
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


@require_GET
def share_data(request, token):
    if not _rate_ok(request):
        return _headers(JsonResponse({"state": "limited"}, status=429))
    data, st = CTV.public_state(token)
    return _headers(JsonResponse(data, status=st))


@require_GET
def share_image(request, token, cam):
    if not _rate_ok(request):
        return _headers(HttpResponse(status=429))
    raw = CTV.public_image(token, cam)
    if raw is None:
        return _headers(HttpResponse(status=404))
    return _headers(HttpResponse(raw, content_type="image/jpeg"))


@require_GET
def share_page(request, token):
    lang = _lang(request)
    T = TXT[lang]
    if not _rate_ok(request):
        return _headers(render(request, "web/cctv_share.html",
                               {"lang": lang, "T": T, "limited": True}, status=429))
    data, st = CTV.public_state(token, count_view=True)
    ctx = {"lang": lang, "T": T, "state": data.get("state"),
           "boot": {"data": data, "T": T, "lang": lang,
                    "api": "/c/%s/data" % token, "img": "/c/%s/img/" % token},
           "other_q": "" if lang == "en" else "?lang=en"}
    return _headers(render(request, "web/cctv_share.html", ctx, status=st))
