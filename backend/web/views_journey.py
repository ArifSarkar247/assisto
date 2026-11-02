"""journey100 — lifeassisto.com/j/<token>: the Safe Journey WATCHER page.

For a watcher without the app (or on a laptop). No login: the signed,
expiring token IS the permission (core.logic.safety_journey.make_web_token,
minted only for the traveller's own journey). One language per page
(?lang=en, default Bangla), noindex, no-store, no ads, rate-limited per IP.

Honest states, never a guess:
  live      a fix newer than 2 min       -> map + "updated N s ago"
  stale     2-15 min old                 -> map + "last seen N min ago"
  lost      older than 15 min            -> last known place + warning
  waiting   no fix yet                   -> "waiting for the first location"
  sos       an SOS (or duress) is open   -> last location + 999
  arrived / ended                        -> NO location (privacy)
  expired   past the privacy expiry      -> NO location, nothing else
  bad       forged / unknown link        -> 404

Map: the same tile setting as vehicle tracking (MAP_TILE_URL, {z}/{x}/{y}).
Without it the page says "map not set up" and links the coordinates to
Google Maps. tile.openstreetmap.org is never used.
"""
from django.conf import settings
from django.core.cache import cache
from django.http import JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_GET

from core import journey_watch as JW
from core.logic import journey_dest as JD
from core.logic import safety_journey as SJ

from .views import _ip_hash

RATE_PER_MIN = 40

TXT = {
    "bn": {
        "title": "লাইভ যাত্রা", "brand": "Assisto নিরাপদ যাত্রা",
        "to": "গন্তব্য", "eta": "পৌঁছানোর সময়", "battery": "ফোনের চার্জ",
        "updated": "লোকেশন আপডেট", "ride": "যানবাহন",
        "live": "লাইভ — লোকেশন আসছে", "stale": "কিছুক্ষণ নতুন লোকেশন আসেনি",
        "lost": "অনেকক্ষণ লোকেশন আসছে না — ফোন বন্ধ, চার্জ শেষ বা নেট নেই হতে পারে",
        "waiting": "প্রথম লোকেশনের অপেক্ষা চলছে", "sos": "জরুরি অবস্থা — এখনই খোঁজ নিন",
        "arrived": "নিরাপদে পৌঁছেছেন", "ended": "যাত্রা শেষ হয়েছে",
        "expired": "এই লিংকের মেয়াদ শেষ। গোপনীয়তার জন্য কোনো লোকেশন আর রাখা হয় না।",
        "bad": "লিংকটি ঠিক নেই।", "late": "পৌঁছানোর সময় পার হয়েছে",
        "ago_s": "{n} সেকেন্ড আগে", "ago_m": "{n} মিনিট আগে",
        "nomap": "ম্যাপ এখনো চালু হয়নি। লোকেশন Google Maps-এ দেখুন:",
        "open_maps": "Google Maps-এ খুলুন", "call999": "৯৯৯-এ কল করুন",
        "help": "জরুরি সাহায্য", "refresh": "প্রতি ২০ সেকেন্ডে নিজে থেকে হালনাগাদ হয়।",
        "offline": "ইন্টারনেট নেই — আবার চেষ্টা চলছে।",
        "privacy": "শুধু যাত্রী যাঁদের লিংক দিয়েছেন তাঁরা এটা দেখতে পান। যাত্রা শেষে লোকেশন দেখানো বন্ধ হয় ও নির্দিষ্ট সময় পরে মুছে যায়।",
        "photo": "যানবাহনের ছবি", "limited": "অনেকবার চেষ্টা হয়েছে। এক মিনিট পরে আবার খুলুন।",
        "other": "English",
        "revoked": "যাত্রী এই লিংকটি বন্ধ করে দিয়েছেন। কোনো লোকেশন দেখানো হয় না।",
        "left": "গন্তব্য থেকে দূরত্ব", "left_v": "সোজা দূরত্বে প্রায় {d} কিমি",
        "rough": "আনুমানিক বাকি সময়", "rough_v": "প্রায় {m} মিনিট (সাধারণ গতিতে, ট্রাফিক নয়)",
        "eta_note": "সময়টা যাত্রী নিজে দিয়েছেন।",
        "driver": "চালক", "call_driver": "চালককে কল করুন",
    },
    "en": {
        "title": "Live journey", "brand": "Assisto Safe Journey",
        "to": "Destination", "eta": "Expected by", "battery": "Phone battery",
        "updated": "Location updated", "ride": "Ride",
        "live": "Live — location is coming in", "stale": "No new location for a few minutes",
        "lost": "No location for a long time — the phone may be off, flat or offline",
        "waiting": "Waiting for the first location", "sos": "Emergency — check on them now",
        "arrived": "Arrived safely", "ended": "The journey has ended",
        "expired": "This link has expired. For privacy, no location is kept any more.",
        "bad": "This link is not valid.", "late": "The arrival time has passed",
        "ago_s": "{n} s ago", "ago_m": "{n} min ago",
        "nomap": "The map is not set up yet. See the location in Google Maps:",
        "open_maps": "Open in Google Maps", "call999": "Call 999",
        "help": "Emergency help", "refresh": "Updates by itself every 20 seconds.",
        "offline": "No internet — retrying.",
        "privacy": "Only people the traveller gave this link to can see it. Location stops showing when the trip ends and is deleted after a set time.",
        "photo": "Ride photo", "limited": "Too many tries. Please open it again in a minute.",
        "other": "বাংলা",
        "revoked": "The traveller turned this link off. No location is shown.",
        "left": "Distance to destination", "left_v": "about {d} km in a straight line",
        "rough": "Rough time left", "rough_v": "about {m} min (typical speed, not live traffic)",
        "eta_note": "The traveller set this time.",
        "driver": "Driver", "call_driver": "Call the driver",
    },
}


def _lang(request):
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_ok(request):
    key = "jw:web:%s:%s" % (_ip_hash(request), timezone.now().strftime("%Y%m%d%H%M"))
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


def public_state(token, now=None):
    """The JSON the page shows. Location ONLY for live / sos journeys inside
    their privacy expiry. Returns (dict, http_status)."""
    from core.models import Journey
    from core import push
    now = now or timezone.now()
    raw, ok, reason = SJ.parse_web_token(token, settings.SECRET_KEY, now=now)
    jid, gen = JW.split_link_id(raw)
    if reason == "bad" or jid is None:
        return {"state": "bad"}, 404
    j = Journey.objects.filter(pk=jid).select_related("traveller").first()
    if j is None:
        return {"state": "bad"}, 404
    if gen != int(j.web_gen or 0):
        # journey2: the traveller turned this link off — nothing else shows
        return {"state": "revoked"}, 200
    if (j.expires_at is not None and j.expires_at <= now) or \
            (not ok and j.status != "active" and not j.sos_active):
        return {"state": "expired"}, 200
    out = {"name": push.display_name(j.traveller),
           "destination": (j.destination or {}).get("name") or "",
           "eta": j.eta.isoformat() if j.eta else None}
    if j.sos_active:
        state = "sos"
    elif j.status == "arrived":
        return {**out, "state": "arrived",
                "at": j.stopped_at.isoformat() if j.stopped_at else None}, 200
    elif j.status != "active":
        return {**out, "state": "ended"}, 200
    else:
        state = None
    fx = JW.fix_of(j)
    if fx is None:
        out["state"] = state or "waiting"
    else:
        lat, lng, at, batt = fx
        age = int((now - at).total_seconds()) if at else None
        if state is None:
            state = ("live" if age is not None and age <= JW.FRESH_FIX_S else
                     "stale" if age is not None and age < JW.LOST_FIX_MIN * 60 else "lost")
        out.update(state=state, lat=round(lat, 6), lng=round(lng, 6),
                   at=at.isoformat() if at else None, age_s=age, battery=batt)
        out.update(JW.progress(j, fx))
    st, _m = JW.overdue(j, now)
    out["late"] = st in ("ask", "alert")
    v = JD.clean_vehicle(j.vehicle) or {}
    if v or j.vehicle_photo:
        try:
            photo = j.vehicle_photo.url if j.vehicle_photo else None
        except Exception:
            photo = None
        out["ride"] = {"plate": v.get("plate", ""),
                       "mode": v.get("mode") or (j.mode if j.mode in JD.MODES else ""),
                       "app": v.get("app", ""),
                       "driver_name": v.get("driver_name", ""),
                       "driver_phone": v.get("driver_phone", ""),
                       "photo": photo}
    return out, 200


def ride_line(ride, lang):
    """The ride in the page's language only (journey2: the raw mode code
    used to show on the Bangla page)."""
    return JD.ride_line(ride, lang) if ride else ""


@require_GET
def watch_data(request, token):
    if not _rate_ok(request):
        return _headers(JsonResponse({"state": "limited"}, status=429))
    data, st = public_state(token)
    if data.get("ride"):
        data["ride"]["line"] = ride_line(data["ride"], _lang(request))
    return _headers(JsonResponse(data, status=st))


@require_GET
def watch_page(request, token):
    lang = _lang(request)
    T = TXT[lang]
    if not _rate_ok(request):
        resp = render(request, "web/safe_journey.html",
                      {"lang": lang, "T": T, "limited": True}, status=429)
        return _headers(resp)
    data, st = public_state(token)
    if data.get("ride"):
        data["ride"]["line"] = ride_line(data["ride"], lang)
    tiles = JW.tile_config()
    ctx = {"lang": lang, "T": T, "token": token, "state": data.get("state"),
           "boot": {"data": data, "T": T, "lang": lang,
                    "tile": tiles["tile_url"], "attr": tiles["attribution"],
                    "api": "/j/%s/data" % token},
           "other_q": "" if lang == "en" else "?lang=en"}
    return _headers(render(request, "web/safe_journey.html", ctx, status=st))
