"""mapscost (owner order 3 Nov 18:40, PART 1) — the app's door to paid maps
calls, all through core.maps_cost (server key, per-user + global daily caps,
free fallback). Every answer carries `state`; on anything but ok/cache the
app shows the coordinates text + "Open in Google Maps" instead.

  GET  /maps/status                          {ready, min_chars, debounce_ms}
  GET  /maps/reverse?lat&lng                 address (phone Geocoder first!)
  GET  /maps/autocomplete?q&session&lat&lng  Places (New) Autocomplete
  GET  /maps/place?id&session                one Place Details Essentials
  GET  /maps/eta?olat&olng&dlat&dlng&mode    one Routes call (start / tap)
  GET  /maps/transit?olat&olng&dlat&dlng     mapapp: live Google transit (Google view only, never stored)
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import maps_cost as MC
from . import place_suggest as PS
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
        # sjp0: never a limit state to the phone (caps -> "none" + free coords)
        return Response(PS.public(MC.reverse(request.user, _q(request, "lat"), _q(request, "lng"),
                                             lang=req_lang(request))))


class MapsAutocompleteView(APIView):
    """sjp0 (owner P0 9 Nov): the SAME merged list as /maps/search — saved +
    recent + our BD list first, Google on top only when allowed. Old V1 apps
    in the field call this endpoint and show any non-ok state as 'limit
    reached', so the answer is always ok / none / short."""
    def get(self, request):
        return Response(PS.suggest(request.user, _q(request, "q"), _q(request, "session"),
                                   lat=_q(request, "lat"), lng=_q(request, "lng"),
                                   lang=req_lang(request)))


class MapsPlaceView(APIView):
    def get(self, request):
        lang = req_lang(request)
        mine = PS.local_details(request.user, _q(request, "id"), lang=lang)
        if mine is not None:
            return Response(mine)
        return Response(PS.public(MC.place_details(request.user, _q(request, "id"),
                                                   _q(request, "session"), lang=lang)))


class MapsEtaView(APIView):
    def get(self, request):
        return Response(PS.public(MC.route_eta(request.user, _q(request, "olat"), _q(request, "olng"),
                                               _q(request, "dlat"), _q(request, "dlng"),
                                               mode=_q(request, "mode") or "")))


class MapsTransitView(APIView):
    """mapapp (owner 10 Nov 00:35): Google Routes TRANSIT for the City
    Service Google view. Live per request, never cached or stored; any
    refusal answers state "none" + routes [] (the app then shows only our
    own results, never a limit message)."""
    def get(self, request):
        return Response(PS.public(MC.transit(request.user, _q(request, "olat"), _q(request, "olng"),
                                             _q(request, "dlat"), _q(request, "dlng"),
                                             lang=req_lang(request))))


class MapsSearchView(APIView):
    """qjourney (owner Safe Journey V2, 9 Nov) — GET /maps/search?q&session&lat&lng

    ONE merged destination list from the 2nd letter (core/place_suggest.py):
    saved + recent, our own free Bangladesh place list, Google Places
    Autocomplete (session token) ONLY when fewer than 5 good local matches
    and the budget allows. Never a limit message ("none" only when nothing
    matches — the phone then tries its own Geocoder). Local rows carry
    lat/lng, so picking one needs no paid Place Details.
    """
    def get(self, request):
        return Response(PS.suggest(request.user, _q(request, "q"), _q(request, "session"),
                                   lat=_q(request, "lat"), lng=_q(request, "lng"),
                                   lang=req_lang(request)))
