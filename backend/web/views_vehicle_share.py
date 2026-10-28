"""veh100 — lifeassisto.com/v/<token>: a vehicle's LIVE location for someone
the owner shared a link with (no login, no app). The random token IS the
permission (only its SHA-256 is stored: core.models.VehicleShareLink).

Honest states, never a guess:
  live      fix newer than 2 min        -> map + speed + "updated N s ago"
  stale     2-15 min old                -> map + "last seen N min ago"
  lost      older than 15 min           -> last known place + warning
  waiting   paired but no fix yet       -> "waiting for the first location"
  paused    tracker turned off / unpaid -> NO location
  expired / revoked                     -> NO location, nothing else
  bad       unknown link                -> 404
Only the CURRENT position, never the route history. noindex, no-store, no
ads, rate-limited per IP (40 / min). Map: the configured licensed tile
provider (MAP_TILE_URL) or an honest "open in Google Maps" link —
tile.openstreetmap.org is never used.
"""
from django.core.cache import cache
from django.http import JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_GET

from core import journey_watch as JW
from core import vehicle100 as V1

from .views import _ip_hash

RATE_PER_MIN = 40

TXT = {
    "bn": {
        "title": "গাড়ির লাইভ অবস্থান", "brand": "Assisto গাড়ি ট্র্যাকিং",
        "updated": "লোকেশন আপডেট", "speed": "গতি", "kmh": "কিমি/ঘণ্টা",
        "moving": "চলছে", "parked": "থেমে আছে", "until": "লিংক খোলা থাকবে",
        "live": "লাইভ — লোকেশন আসছে", "stale": "কিছুক্ষণ নতুন লোকেশন আসেনি",
        "lost": "অনেকক্ষণ লোকেশন আসছে না — ট্র্যাকারে নেটওয়ার্ক বা বিদ্যুৎ না থাকতে পারে",
        "waiting": "প্রথম লোকেশনের অপেক্ষা চলছে",
        "paused": "মালিক এখন ট্র্যাকিং বন্ধ রেখেছেন। কোনো লোকেশন দেখানো হচ্ছে না।",
        "expired": "এই লিংকের মেয়াদ শেষ। কোনো লোকেশন আর দেখানো হয় না।",
        "revoked": "মালিক এই লিংকটি বন্ধ করে দিয়েছেন।",
        "bad": "লিংকটি ঠিক নেই।",
        "ago_s": "{n} সেকেন্ড আগে", "ago_m": "{n} মিনিট আগে",
        "nomap": "ম্যাপ এখনো চালু হয়নি। লোকেশন Google Maps-এ দেখুন:",
        "open_maps": "Google Maps-এ খুলুন",
        "refresh": "প্রতি ১৫ সেকেন্ডে নিজে থেকে হালনাগাদ হয়।",
        "offline": "ইন্টারনেট নেই — আবার চেষ্টা চলছে।",
        "privacy": "শুধু গাড়ির মালিক যাঁদের লিংক দিয়েছেন তাঁরা এটা দেখতে পান। শুধু এখনকার অবস্থান দেখায় — আগের পথ নয়। মেয়াদ শেষ হলে বা মালিক বন্ধ করলে আর কিছু দেখায় না।",
        "limited": "অনেকবার চেষ্টা হয়েছে। এক মিনিট পরে আবার খুলুন।",
        "other": "English",
    },
    "en": {
        "title": "Vehicle live location", "brand": "Assisto vehicle tracking",
        "updated": "Location updated", "speed": "Speed", "kmh": "km/h",
        "moving": "Moving", "parked": "Stopped", "until": "Link open until",
        "live": "Live — location is coming in", "stale": "No new location for a few minutes",
        "lost": "No location for a long time — the tracker may have no network or power",
        "waiting": "Waiting for the first location",
        "paused": "The owner has paused tracking. No location is shown.",
        "expired": "This link has expired. No location is shown any more.",
        "revoked": "The owner turned this link off.",
        "bad": "This link is not valid.",
        "ago_s": "{n} s ago", "ago_m": "{n} min ago",
        "nomap": "The map is not set up yet. See the location in Google Maps:",
        "open_maps": "Open in Google Maps",
        "refresh": "Updates by itself every 15 seconds.",
        "offline": "No internet — retrying.",
        "privacy": "Only people the vehicle owner gave this link to can see it. It shows the current position only — never the past route. Nothing is shown after it expires or the owner turns it off.",
        "limited": "Too many tries. Please open it again in a minute.",
        "other": "বাংলা",
    },
}


def _lang(request):
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_ok(request):
    key = "vshare:%s:%s" % (_ip_hash(request), timezone.now().strftime("%Y%m%d%H%M"))
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
    data, st = V1.share_state(token, count_view=False)
    return _headers(JsonResponse(data, status=st))


@require_GET
def share_page(request, token):
    lang = _lang(request)
    T = TXT[lang]
    if not _rate_ok(request):
        return _headers(render(request, "web/vehicle_live.html",
                               {"lang": lang, "T": T, "limited": True}, status=429))
    data, st = V1.share_state(token)
    tiles = JW.tile_config()
    ctx = {"lang": lang, "T": T, "state": data.get("state"),
           "boot": {"data": data, "T": T, "lang": lang,
                    "tile": tiles["tile_url"], "attr": tiles["attribution"],
                    "api": "/v/%s/data" % token},
           "other_q": "" if lang == "en" else "?lang=en"}
    return _headers(render(request, "web/vehicle_live.html", ctx, status=st))
