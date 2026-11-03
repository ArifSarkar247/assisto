"""Food photo -> calories API (p2food; flag food_calories, OFF until proven).

GET /food/table -> the cited dish table (FCT Bangladesh 2013 + USDA FNDDS),
sources, disclaimer, general hints, goal bounds and whether a photo can be
recognised right now (a vision provider is connected). The photo itself goes
through the existing /chat-vision/* flow with purpose='food' (same money rails);
the log lives in the user's own generic collections food/log + food/goal.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import is_play_flavour, req_lang
from .logic import food_calories as FC

FLAG = "food_calories"


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user, play))
    except Exception:
        return False


def photo_ready():
    try:
        from . import chat_vision_service as CVS
        slug, _conf, _cost = CVS._active()
        return bool(slug)
    except Exception:
        return False


class FoodTableView(APIView):
    def get(self, request):
        lang = req_lang(request)
        if not flag_on(request.user, is_play_flavour(request)):
            return Response({"error": "feature_off",
                             "detail": "এই ফিচারটি এখনো চালু হয়নি।" if lang == "bn"
                             else "This feature is not available yet."}, status=403)
        body = FC.table(lang)
        body["photo_ready"] = photo_ready()
        return Response(body)
