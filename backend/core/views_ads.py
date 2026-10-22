"""
GET /ads/config — what the app needs to drive AdMob (slot a6).

Key-gated: until the owner saves REAL AdMob ids in Integrations (and the
format test passes), `configured` is False and the app uses Google's TEST ids
only; billing.ad_event never credits real money in that state.
"""
from rest_framework.response import Response
from rest_framework.views import APIView


class AdsConfigView(APIView):
    def get(self, request):
        from . import billing, integrations, plans
        from .logic import ads as A
        user = request.user
        try:
            plan = plans.effective_plan(user)
        except Exception:
            plan = "free"
        paid = plan != "free"
        try:
            admob_cfg = integrations.get("admob")
            working = integrations.is_enabled("admob")
        except Exception:
            admob_cfg, working = {}, False
        try:
            c = billing.cfg()
            caps = c["ad_rewards"]
            hero_refresh = (c.get("home_hero") or {}).get("refresh_sec", 90)
        except Exception:
            caps, hero_refresh = {}, 90
        return Response(A.client_config(
            plan=plan, paid=paid, admob_cfg=admob_cfg, admob_working=working,
            flag_rewarded=billing.flag_on("ads_rewarded"),
            flag_app_open=billing.flag_on("ads_app_open"),
            ad_caps=caps, hero_refresh=hero_refresh))
