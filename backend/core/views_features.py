"""feature-flags: GET /api/v1/features — the features THIS user may see in
THIS build (the Play build sends `X-Assisto-Flavour: play`).

  200 {"v": 1, "flavour": "play"|"apk", "features": {key: bool},
       "preview": [keys visible only because the caller is the owner / staff
                   or an allow-listed tester]}
  304 when If-None-Match matches the ETag (the app keeps its cached copy).

Open to signed-out callers too (first launch): they get the public set (no
rollout share, no preview). Resolution: core.feature_flags."""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import feature_flags as FF
from .i18n import is_play_flavour


class FeaturesView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        play = is_play_flavour(request) or request.query_params.get("flavour") == "play"
        body = FF.payload(request.user, play)
        tag = FF.etag(body)
        if (request.META.get("HTTP_IF_NONE_MATCH") or "").strip() == tag:
            resp = Response(status=304)
        else:
            resp = Response(body)
        resp["ETag"] = tag
        # per user + flavour: never in a shared cache; the app re-asks on
        # login and resume, a 304 costs one tiny round trip.
        resp["Cache-Control"] = "private, max-age=300"
        resp["Vary"] = "Authorization, X-Assisto-Flavour, Accept-Language"
        return resp
