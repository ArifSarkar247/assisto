"""nearby (owner 3 Nov 18:50): the phone's side of Assisto's own emergency
list (core.nearby_list). Zero Google calls.

GET  /api/v1/nearby/area?lat=&lon=&v=<cached token>
     -> the 3x3-degree area the phone caches (compact rows; the phone sorts
        by distance itself and works offline from it), or {unchanged: true}.
POST /api/v1/nearby/report {place, kind, phone, note}
     -> "Report wrong number" -> Owner Admin review queue.
GET  /api/v1/nearby/sponsored?lat=&lon=&cat=food|shop|atm|fuel
     -> Assisto business listings with a Sponsored label (flag
        nearby_sponsored, default OFF). Never emergency categories.
"""
from rest_framework.decorators import api_view
from rest_framework.response import Response

from . import feature_flags as FF
from . import nearby_list as NL
from .i18n import pick


def _lang(request):
    from .views import req_lang
    return req_lang(request)


def _latlon(request):
    try:
        lat = float(request.query_params.get("lat"))
        lon = float(request.query_params.get("lon"))
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def _need_location(request):
    lang = _lang(request)
    return Response({"detail": pick(lang, "লোকেশন (lat/lon) দরকার।",
                                    "Location (lat/lon) is required.")}, status=400)


@api_view(["GET"])
def nearby_area(request):
    ll = _latlon(request)
    if ll is None:
        return _need_location(request)
    have = (request.query_params.get("v") or "")[:400]
    return Response(NL.area(ll[0], ll[1], have=have))


@api_view(["POST"])
def nearby_report(request):
    d = request.data if isinstance(request.data, dict) else {}
    lang = _lang(request)
    try:
        pid = int(d.get("place"))
    except (TypeError, ValueError):
        pid = 0
    r, err = NL.report(request.user, pid, kind=str(d.get("kind") or "wrong_number"),
                       phone=d.get("phone") or "", note=d.get("note") or "")
    if err == "not_found":
        return Response({"detail": pick(lang, "জায়গাটি পাওয়া যায়নি।", "Place not found.")},
                        status=404)
    if err == "limit":
        return Response({"detail": pick(lang, "আজকের রিপোর্টের সীমা পূর্ণ। কাল আবার চেষ্টা করুন।",
                                        "Today's report limit is reached. Please try tomorrow.")},
                        status=429)
    return Response({"ok": True, "id": r.id,
                     "detail": pick(lang, "ধন্যবাদ! আমরা নম্বরটি যাচাই করে ঠিক করব।",
                                    "Thanks! We'll check the number and fix it.")}, status=201)


@api_view(["GET"])
def nearby_sponsored(request):
    ll = _latlon(request)
    if ll is None:
        return _need_location(request)
    cat = request.query_params.get("cat") or ""
    if cat not in NL.GENERAL or not FF.is_on("nearby_sponsored", request.user):
        return Response({"cat": cat, "places": []})
    return Response({"cat": cat, "places": NL.sponsored(ll[0], ll[1], cat),
                     "label": pick(_lang(request), "Sponsored (বিজ্ঞাপন)", "Sponsored")})
