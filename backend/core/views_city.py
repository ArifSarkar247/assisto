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
    return Response(dict({"on": on, "keep_days": CS.TRIP_KEEP_DAYS, "trim_m": CS.TRIP_TRIM_M},
                         **CS.rider_stats(request.user)))       # citycov: + stops_verified, trips


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


@api_view(["POST"])
def city_trip_confirm(request):
    """mapapp: the one-tap "Which bus? What fare?" card after a trip."""
    d = request.data if isinstance(request.data, dict) else {}
    st, err = CS.confirm_ride(request.user, d)
    if err == "limit":
        return _bad(request, "আজকের সীমা পূর্ণ।", "Today's limit is reached.", 429)
    if err:
        return _bad(request, "উত্তরটা নেওয়া গেল না।", "That answer could not be saved.")
    return Response(dict(st, ok=True), status=201)


@api_view(["GET"])
def city_trip_mine(request):
    """mapapp: "You verified N stops" (anon key only)."""
    return Response(CS.rider_stats(request.user))


@api_view(["GET"])
def city_map(request):
    """mapapp: tiles base (CITY_MAP_TILES_API.md) + credits for the app map."""
    return Response(CS.map_config())


@api_view(["GET"])
def city_women(request):
    city = _city(request)
    w = CS.women(city)
    if w is None:
        return _no_data(request, city)
    return Response(w)


# ---------------------------------------------------------------- citycov
_FIELD_ERR = {
    "no_city": ("এই জায়গা আমাদের শহরের তালিকায় নেই।", "This place is outside our cities."),
    "no_data": ("এই শহরের তথ্য এখনো নেই।", "No data for this city yet."),
    "limit": ("আজকের সীমা পূর্ণ। কাল আবার চেষ্টা করুন।", "Today's limit is reached. Please try tomorrow."),
    "route": ("এই বাসটি পাওয়া যায়নি।", "That bus was not found."),
    "not_found": ("রিপোর্টটি পাওয়া যায়নি।", "Report not found."),
    "invalid": ("লোকেশন ঠিক নেই।", "Location is not valid."),
}


@api_view(["GET", "POST"])
def city_field_stops(request):
    """citycov: field collection. GET ?lat&lon = waiting reports nearby (to
    confirm). POST {lat, lon, route_id?} = "Add a stop here" / "This bus stops
    here" at the phone's location; POST {lat, lon, id} = "Yes, it stops here"
    on a nearby report. Reported until FIELD_CONFIRM different people agree."""
    if request.method == "GET":
        ll = _qll(request)
        if ll is None:
            return _need_loc(request)
        return Response({"items": CS.field_list(request.user, *ll), "need": CS.FIELD_CONFIRM,
                         "routes": CS.field_routes(*ll)})
    d = request.data if isinstance(request.data, dict) else {}
    try:
        rid = int(d.get("id")) if d.get("id") not in (None, "") else None
    except (TypeError, ValueError):
        rid = None
    if d.get("lat") in (None, "") or d.get("lon") in (None, ""):
        return _need_loc(request)
    obj, err = CS.field_stop(request.user, d.get("lat"), d.get("lon"),
                             str(d.get("route_id") or ""), rid)
    lang = req_lang(request)
    if err in _FIELD_ERR:
        bn, en = _FIELD_ERR[err]
        code = 429 if err == "limit" else 404 if err in ("not_found", "route") else 400
        return Response({"ok": False, "reason": err, "detail": pick(lang, bn, en)}, status=code)
    if err == "known":
        return Response({"ok": True, "status": "known",
                         "detail": pick(lang, "এখানে স্টপটি আগেই আছে — ধন্যবাদ!",
                                        "This stop is already on the map — thank you!")})
    if err == "far":
        return Response({"ok": False, "reason": "far",
                         "detail": pick(lang, "নিশ্চিত করতে স্টপের কাছে থাকুন।",
                                        "Please be at the stop to confirm it.")}, status=400)
    if err == "rejected":
        return Response({"ok": True, "status": "rejected",
                         "detail": pick(lang, "এটি আগে যাচাই করে বাদ দেওয়া হয়েছে।",
                                        "This was checked before and not added.")})
    people = len(obj.anons or [])
    st = "confirmed" if obj.status == "confirmed" else "already" if err == "already" else "reported"
    if st == "confirmed":
        msg = pick(lang, "নিশ্চিত! স্টপটি এখন সবার রুটে দেখাবে (যাত্রীদের জানানো)।",
                   "Confirmed! The stop now shows in everyone's routes (Reported by users).")
    else:
        msg = pick(lang, "ধন্যবাদ! আরও কয়েকজন নিশ্চিত করলে স্টপটি যোগ হবে।",
                   "Thanks! The stop is added once a few more people confirm it.")
    return Response({"ok": True, "id": obj.id, "status": st, "people": people,
                     "need": CS.FIELD_CONFIRM, "detail": msg}, status=200 if err else 201)


@api_view(["POST"])
def city_trip_confirm(request, tid):
    """citycov / own map A4: post-trip card {route_id?, fare?} for the
    rider's own trip (by its id from POST city/trips). No name kept."""
    d = request.data if isinstance(request.data, dict) else {}
    stats, err = CS.trip_confirm(request.user, tid, str(d.get("route_id") or ""), d.get("fare"))
    if err == "not_found":
        return _bad(request, "যাত্রাটি পাওয়া যায়নি।", "Trip not found.", 404)
    if err:
        return _bad(request, "বাস বা ভাড়া ঠিক নেই।", "Bus or fare is not valid.")
    return Response(dict({"ok": True}, **stats))
