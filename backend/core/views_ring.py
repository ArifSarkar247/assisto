"""ring-everywhere endpoints (see core/call_ack.py for the design).

  POST circle/calls/<id>/ack        NO account token: the phone's native FCM
       {sig, stage, brand, model, sdk}   service, authorised by the ring push's
                                     per-call `ack_sig` (HMAC). stage:
                                     delivered | ringing | decline.
                                     -> {ok, phase, ended, state}
  GET  circle/calls/missed_pending  (Token) never-delivered missed calls,
                                     each returned once -> {items: [...]}
"""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import call_ack
from .i18n import req_lang
from .models import CallRecord


class RingAckView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []      # native service: no token, sig only
    throttle_classes = []

    def post(self, request, call_id):
        d = request.data if isinstance(request.data, dict) else {}
        stage = str(d.get("stage", "delivered") or "delivered")[:12]
        if stage not in call_ack.STAGES:
            return Response({"ok": False, "code": "bad_stage"}, status=400)
        rec = CallRecord.objects.filter(pk=call_id).only(
            "id", "callee_id", "caller_id", "state").first()
        if rec is None or not call_ack.verify(rec.id, rec.callee_id, d.get("sig")):
            # same answer for "no such call" and "bad signature"
            return Response({"ok": False, "code": "not_found"}, status=404)
        rec = CallRecord.objects.select_related("caller", "callee", "circle") \
            .get(pk=rec.pk)
        return Response(call_ack.apply_ack(rec, stage, d))


class MissedPendingView(APIView):
    def get(self, request):
        items = call_ack.take_missed_pending(request.user, req_lang(request))
        return Response({"items": items})
