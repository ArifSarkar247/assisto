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
        return Response({"ready": MC.ready(), "min_chars": MC.MIN_CHARS,
                         "debounce_ms": DEBOUNCE_MS})


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
