"""Personal Secretary (PS) API — owner Part 2.1 (flag ps_secretary, OFF until
proven). GET /ps/today → the grounded Today brief (no AI, 0 credits)."""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ps_service as S
from .i18n import is_play_flavour, req_lang


class PsTodayView(APIView):
    def get(self, request):
        if not S.flag_on(request.user, is_play_flavour(request)):
            bn = req_lang(request) == "bn"
            return Response({"error": "feature_off",
                             "detail": "এই ফিচারটি এখনো চালু হয়নি।" if bn
                             else "This feature is not available yet."}, status=403)
        return Response(S.today(request.user))
