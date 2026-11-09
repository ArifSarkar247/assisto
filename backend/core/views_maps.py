"""mapscost (owner order 3 Nov 18:40, PART 1) — the app's door to paid maps
calls, all through core.maps_cost (server key, per-user + global daily caps,
free fallback). Every answer carries `state`; on anything but ok/cache the
app shows the coordinates text + "Open in Google Maps" instead.

  GET  /maps/status                          {ready, min_chars, debounce_ms}
  GET  /maps/reverse?lat&lng                 address (phone Geocoder first!)
  GET  /maps/autocomplete?q&session&lat&lng  Places (New) Autocomplete
  GET  /maps/place?id&session                one Place Details Essentials
  GET  /maps/eta?olat&olng&dlat&dlng&mode    one Routes call (start / tap)
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import maps_cost as MC
from .i18n import req_lang

DEBOUNCE_MS = 300


def _q(request, k):
    return request.query_params.get(k)


class MapsStatusView(APIView):
    def get(self, request):
        from . import bd_places as BP
        return Response({"ready": MC.ready(), "min_chars": MC.MIN_CHARS,
                         "debounce_ms": DEBOUNCE_MS,
                         # qjourney: our free place list answers /maps/search
                         # even with no Google key
                         "places": BP.available()})


class MapsReverseView(APIView):
    def get(self, request):
        return Response(MC.reverse(request.user, _q(request, "lat"), _q(request, "lng"),
                                   lang=req_lang(request)))


class MapsAutocompleteView(APIView):
    def get(self, request):
        return Response(MC.autocomplete(request.user, _q(request, "q"), _q(request, "session"),
                                        lat=_q(request, "lat"), lng=_q(request, "lng"),
                                        lang=req_lang(request)))


class MapsPlaceView(APIView):
    def get(self, request):
        return Response(MC.place_details(request.user, _q(request, "id"),
                                         _q(request, "session"), lang=req_lang(request)))


class MapsEtaView(APIView):
    def get(self, request):
        return Response(MC.route_eta(request.user, _q(request, "olat"), _q(request, "olng"),
                                     _q(request, "dlat"), _q(request, "dlng"),
                                     mode=_q(request, "mode") or ""))


class MapsSearchView(APIView):
    """qjourney (owner Safe Journey V2, 9 Nov) — GET /maps/search?q&session&lat&lng

    ONE merged destination list from the 2nd letter: our own free Bangladesh
    place list first (core/bd_places.py, OpenStreetMap), Google Places
    Autocomplete (session token) ONLY when fewer than 5 good local matches
    and the budget allows. Never a limit message: a capped / off / failed
    Google answer silently leaves our own rows ("none" when there are none —
    the phone then tries its own Geocoder). Local rows carry lat/lng, so
    picking one needs no paid Place Details.
    """
    def get(self, request):
        from . import bd_places as BP
        q = " ".join(str(_q(request, "q") or "").split())[:120]
        if len(q) < MC.MIN_CHARS:
            return Response({"state": "short", "results": []})
        lang = req_lang(request)
        lat, lng = _f(_q(request, "lat")), _f(_q(request, "lng"))
        local = BP.search(q, lat=lat, lng=lng, lang=lang, limit=8)
        rows = list(local)
        used_google = False
        if BP.good_count(local) < BP.WANT:
            g = MC.autocomplete(request.user, q, _q(request, "session"),
                                lat=_q(request, "lat"), lng=_q(request, "lng"), lang=lang)
            if g.get("state") == "ok":
                used_google = True
                have = {r["name"].lower() for r in rows}
                good = [r for r in rows if r.get("score", 0) >= BP.GOOD]
                rest = [r for r in rows if r.get("score", 0) < BP.GOOD]
                gl = [dict(r, source="google") for r in g.get("results") or []
                      if str(r.get("name", "")).lower() not in have]
                rows = (good + gl + rest)[:8]
        for r in rows:
            r.pop("score", None)
        return Response({"state": "ok" if rows else "none", "results": rows,
                         "google": used_google})


def _f(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if -180 <= x <= 180 else None
