"""citydata (owner 9 Nov 11:45): City Service API — contract in
owner_actions/CITY_SERVICE_API.md. Zero Google calls (other cities get an
honest "no data yet" + a plain Google Maps link)."""
from django.http import HttpResponse
from rest_framework.decorators import api_view
from rest_framework.response import Response

from . import city_service as CS
from .i18n import pick, req_lang


def _ll(s):
    try:
        a, b = [float(x) for x in str(s or "").split(",")[:2]]
    except (TypeError, ValueError):
        return None
    if not (-90 <= a <= 90 and -180 <= b <= 180):
        return None
    return a, b


def _qll(request):
    return _ll("%s,%s" % (request.query_params.get("lat"), request.query_params.get("lon")))


def _bad(request, bn, en, status=400):
    return Response({"detail": pick(req_lang(request), bn, en)}, status=status)


def _need_loc(request):
    return _bad(request, "লোকেশন (lat/lon) দরকার।", "Location (lat/lon) is required.")


def _city(request):
    c = (request.query_params.get("city") or "dhaka").lower()
    return c if c in CS.CITIES else "dhaka"


def _no_data(request, city):
    return Response({"ok": False, "reason": "no_data", "city": city,
                     "google_maps": CS.google_maps(),
                     "detail": pick(req_lang(request), "এই শহরের তথ্য এখনো নেই।",
                                    "No data for this city yet.")})


@api_view(["GET"])
def city_where(request):
    ll = _qll(request)
    if ll is None:
        return _need_loc(request)
    return Response(CS.where(*ll))


@api_view(["GET"])
def city_plan(request):
    a = _ll(request.query_params.get("from"))
    b = _ll(request.query_params.get("to"))
    if a is None or b is None:
        return _bad(request, "কোথা থেকে ও কোথায় — দুটোই দরকার।", "Both From and To are required.")
    modes = [m for m in (request.query_params.get("modes") or "").split(",") if m]
    ans = CS.plan(a[0], a[1], b[0], b[1], at=request.query_params.get("at") or "", modes=modes)
    if not ans.get("ok"):
        lang = req_lang(request)
        ans["detail"] = (pick(lang, "এই শহরের রুটের তথ্য এখনো নেই। Google Maps-এ খুলুন।",
                              "No route data for this city yet. Open in Google Maps.")
                         if ans.get("reason") == "no_data" else
                         pick(lang, "আমাদের তথ্যে এই যাত্রার বাস/মেট্রো রুট পাওয়া যায়নি।",
                              "We found no bus/metro route for this trip in our data."))
    return Response(ans)


@api_view(["GET"])
def city_package(request):
    city = _city(request)
    tok, gz = CS.package(city, have=(request.query_params.get("v") or "")[:80])
    if tok is None:
        return _no_data(request, city)
    if gz == b"":
        return Response({"unchanged": True, "v": tok})
    resp = HttpResponse(gz, content_type="application/json; charset=utf-8")
    resp["Content-Encoding"] = "gzip"
    resp["X-City-Data-Version"] = tok
    return resp


@api_view(["GET"])
def city_stations(request):
    city = _city(request)
    st = CS.stations(city)
    if st is None:
        return _no_data(request, city)
    return Response({"city": city, "stations": st, "attribution": CS.ATTRIBUTION})


@api_view(["GET"])
def city_station(request, stop_id):
    city = _city(request)
    ll = _qll(request)
    g = CS.station(city, stop_id[:80], *(ll or (None, None)))
    if g is None:
        return _bad(request, "স্টেশন পাওয়া যায়নি।", "Station not found.", 404)
    return Response(g)


@api_view(["GET"])
def city_metro(request):
    city = _city(request)
    m = CS.metro_info(city)
    if m is None:
        return _no_data(request, city)
    return Response(m)


@api_view(["GET"])
def city_route(request, route_id):
    r = CS.route_detail(_city(request), route_id[:80])
    if r is None:
        return _bad(request, "রুট পাওয়া যায়নি।", "Route not found.", 404)
    return Response(r)


@api_view(["GET"])
def city_search(request):
    city = _city(request)
    r = CS.search(city, request.query_params.get("q") or "")
    if r is None:
        return _no_data(request, city)
    return Response(r)


@api_view(["GET"])
def city_stops_near(request):
    ll = _qll(request)
    if ll is None:
        return _need_loc(request)
    city = CS.city_at(*ll)
    r = CS.stops_near(city, *ll) if city else None
    if r is None:
        return _no_data(request, city)
    return Response({"city": city, "stops": r})


def _dir(kind):
    @api_view(["GET"])
    def view(request):
        city = _city(request)
        items = CS.directory(city, kind)
        if items is None:
            return _no_data(request, city)
        return Response({"city": city, "items": items, "attribution": CS.ATTRIBUTION})
    view.__name__ = "city_dir_" + kind
    return view


city_terminals = _dir("terminal")
city_ghats = _dir("ghat")
city_offices = _dir("office")


@api_view(["GET", "POST"])
def city_reports(request):
    if request.method == "GET":
        ll = _qll(request)
        if ll is None:
            return _need_loc(request)
        try:
            km = min(10.0, max(0.5, float(request.query_params.get("km") or 3)))
        except ValueError:
            km = 3.0
        return Response({"reports": CS.live_list(ll[0], ll[1], km), "ttl_min": CS.LIVE_TTL_MIN})
    d = request.data if isinstance(request.data, dict) else {}
    ll = _ll("%s,%s" % (d.get("lat"), d.get("lon")))
    if ll is None:
        return _need_loc(request)
    r, err = CS.live_report(request.user, str(d.get("kind") or ""), ll[0], ll[1],
                            str(d.get("route_id") or ""))
    if err == "kind":
        return _bad(request, "ভুল ধরন।", "Unknown report type.")
    if err == "limit":
        return _bad(request, "এক ঘণ্টায় অনেক রিপোর্ট হয়েছে। একটু পরে চেষ্টা করুন।",
                    "Too many reports this hour. Please try later.", 429)
    return Response({"ok": True, "id": r.id, "count": r.count,
                     "detail": pick(req_lang(request), "ধন্যবাদ! সবাই দেখতে পাবে (৬০ মিনিট)।",
                                    "Thanks! Everyone nearby will see it (60 minutes).")},
                    status=201)


@api_view(["POST"])
def city_report_flag(request, rid):
    r = CS.live_flag(request.user, rid)
    if r is None:
        return _bad(request, "রিপোর্ট পাওয়া যায়নি।", "Report not found.", 404)
    return Response({"ok": True, "hidden": r.hidden})


@api_view(["POST"])
def city_correction(request):
    d = request.data if isinstance(request.data, dict) else {}
    c, err = CS.correction(request.user, str(d.get("city") or "dhaka"), d)
    if err == "limit":
        return _bad(request, "আজকের সীমা পূর্ণ। কাল আবার চেষ্টা করুন।",
                    "Today's limit is reached. Please try tomorrow.", 429)
    if err:
        return _bad(request, "কী ভুল তা লিখুন বা বেছে নিন।", "Please say or pick what is wrong.")
    return Response({"ok": True, "id": c.id,
                     "detail": pick(req_lang(request), "ধন্যবাদ! আমরা যাচাই করে ঠিক করব।",
                                    "Thanks! We'll check and fix it.")}, status=201)


@api_view(["POST"])
def city_fare_report(request):
    d = request.data if isinstance(request.data, dict) else {}
    km = d.get("km")
    a, b = _ll(d.get("from")), _ll(d.get("to"))
    if km in (None, "") and a and b:
        km = CS.E.hav(a[0], a[1], b[0], b[1]) * 1.35 / 1000.0
    r, err = CS.fare_report(request.user, str(d.get("city") or "dhaka"),
                            str(d.get("mode") or ""), km, d.get("paid"))
    if err == "limit":
        return _bad(request, "আজকের সীমা পূর্ণ।", "Today's limit is reached.", 429)
    if err:
        return _bad(request, "ভাড়া বা দূরত্ব ঠিক নেই।", "Fare or distance is not valid.")
    return Response({"ok": True, "id": r.id}, status=201)


@api_view(["POST"])
def city_night_rating(request):
    d = request.data if isinstance(request.data, dict) else {}
    r, err = CS.night_rating(request.user, str(d.get("city") or "dhaka"),
                             str(d.get("route_id") or ""), d.get("stars"))
    if err:
        return _bad(request, "১ থেকে ৫ তারা দিন।", "Give 1 to 5 stars.")
    return Response({"ok": True, "stars": r.stars}, status=201)


@api_view(["GET", "POST"])
def city_trip_consent(request):
    if request.method == "POST":
        d = request.data if isinstance(request.data, dict) else {}
        on = CS.consent(request.user, bool(d.get("on")))
    else:
        on = CS.consent(request.user)
    return Response({"on": on, "keep_days": CS.TRIP_KEEP_DAYS, "trim_m": CS.TRIP_TRIM_M})


@api_view(["POST"])
def city_trip(request):
    d = request.data if isinstance(request.data, dict) else {}
    t, err = CS.submit_trip(request.user, str(d.get("mode") or "bus"), d.get("points"))
    if err == "no_consent":
        return _bad(request, "আগে অনুমতি দিন।", "Please give consent first.", 403)
    if err == "limit":
        return _bad(request, "আজকের সীমা পূর্ণ।", "Today's limit is reached.", 429)
    if err:
        return Response({"ok": False, "reason": err})
    return Response({"ok": True, "id": t.id}, status=201)


@api_view(["GET"])
def city_women(request):
    city = _city(request)
    w = CS.women(city)
    if w is None:
        return _no_data(request, city)
    return Response(w)
