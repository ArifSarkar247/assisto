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

# owner 18 Nov (10378 live): a feature whose app code only exists from a given
# build is shown only to phones on that build or newer, so an old install never
# opens a broken screen. Build = the X-App-Version header, else the user's
# newest registered phone; unknown counts as too old. Owner / testers still
# get their preview.
MIN_BUILD = {
    "invoice_designs": 10374,   # the money parsing fix ("Tk. 500") is in 10374+
}


def _client_build(request):
    from .call_ack import app_build
    b = app_build(request.META.get("HTTP_X_APP_VERSION", ""))
    if b or not getattr(request.user, "is_authenticated", False):
        return b
    try:
        from .models import Device
        return max((app_build(v) for v in Device.objects.filter(
            user=request.user).values_list("app_version", flat=True)), default=0)
    except Exception:  # noqa: BLE001
        return 0


def _apply_min_build(body, request):
    feats = body.get("features") or {}
    gated = [k for k, b in MIN_BUILD.items() if feats.get(k)]
    if not gated:
        return body
    build = _client_build(request)
    preview = set(body.get("preview") or [])
    for k in gated:
        if build < MIN_BUILD[k] and k not in preview:
            feats[k] = False
    return body


class FeaturesView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        play = is_play_flavour(request) or request.query_params.get("flavour") == "play"
        try:   # unseen-rename: apps from the rename build on send fv=2 (FF.LEGACY_KEYS)
            fv = int(request.query_params.get("fv") or 1)
        except (TypeError, ValueError):
            fv = 1
        body = _apply_min_build(FF.payload(request.user, play, fv), request)
        tag = FF.etag(body)
        if (request.META.get("HTTP_IF_NONE_MATCH") or "").strip() == tag:
            resp = Response(status=304)
        else:
            resp = Response(body)
        resp["ETag"] = tag
        # per user + flavour: never in a shared cache; the app re-asks on
        # login and resume, a 304 costs one tiny round trip.
        resp["Cache-Control"] = "private, max-age=300"
        resp["Vary"] = "Authorization, X-Assisto-Flavour, X-App-Version, Accept-Language"
        return resp
