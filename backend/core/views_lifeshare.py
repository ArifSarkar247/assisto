"""p3life — turn a read-only share link / a guest RSVP link on or off.

POST life/share         {kind: trip|event|guest, id} -> {url}
POST life/share/revoke  {kind, id}                   -> {ok: true}
Only the caller's OWN row (404 otherwise). See core.life_share."""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import life_share as LS


def _args(request):
    kind = str(request.data.get("kind") or "")
    try:
        rid = int(request.data.get("id"))
    except (TypeError, ValueError):
        rid = None
    return kind, rid


class LifeShareView(APIView):
    def post(self, request):
        kind, rid = _args(request)
        if kind not in LS.KINDS or rid is None:
            return Response({"error": "bad_request"}, status=400)
        url = LS.issue(request.user, kind, rid)
        if url is None:
            return Response({"error": "not_found"}, status=404)
        return Response({"url": url, "kind": kind})


class LifeShareRevokeView(APIView):
    def post(self, request):
        kind, rid = _args(request)
        if kind not in LS.KINDS or rid is None:
            return Response({"error": "bad_request"}, status=400)
        if not LS.revoke(request.user, kind, rid):
            return Response({"error": "not_found"}, status=404)
        return Response({"ok": True})
