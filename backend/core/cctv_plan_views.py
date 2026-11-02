"""cctvprice — the CCTV plan screen's API (behind the cctv_watchman switch).

  GET  shop/cctv-plan                 tiers 1..10 with exact prices, yearly,
                                      trial, add-on, status, notices, the Play
                                      ids the app buys with, the cost guards
  POST shop/cctv-plan/addon-cameras   {"ids": [camera ids]} — which cameras
                                      carry the video add-on
Purchases themselves go through the EXISTING /payments/play/verify (and RTDN).
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import cctv_plan as CP
from . import cctv_plan_service as CPS


def _off(request):
    try:
        from .i18n import is_play_flavour
        play = is_play_flavour(request)
    except Exception:
        play = False
    return not CPS.feature_on(request.user, play)


def _feature_off(lang):
    return Response({"error": "feature_off",
                     "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                                    "This feature is not available yet.")}, status=403)


def plan_payload(user, lang="bn"):
    c = CPS.cfg()
    st = CPS.status(user)
    used = CPS.counted_cameras(user)
    try:
        from .payments import play
        account = play.account_id(user)
        play_ready = play.configured()
    except Exception:
        account, play_ready = "", False
    bn, en = CP.unpaid_line()
    return {
        "on_sale": bool(c["on_sale"]),
        "play_ready": play_ready,
        "product_id": c["product_id"],
        "addon_product_id": c["addon_product_id"],
        "trial_offer_id": c["trial_offer_id"],
        "trial_days": CP.TRIAL_DAYS,
        "trial_base_plan": CP.base_plan_id(CP.BASE_CAMERAS, "monthly"),
        "trial_available": not st["trial_used"],
        "base_cameras": CP.BASE_CAMERAS,
        "base_price": CP.BASE_PRICE_BDT,
        "extra_camera_price": CP.EXTRA_CAMERA_BDT,
        "max_cameras": CP.MAX_CAMERAS,
        "tiers": CP.tiers(),
        "addon": {"days": list(CP.ADDON_DAYS),
                  "price_per_camera": {str(d): p for d, p in CP.ADDON_PRICE_BDT.items()},
                  "plans": {str(d): [CP.addon_plan_id(d, n)
                                     for n in range(1, CP.MAX_CAMERAS + 1)]
                            for d in CP.ADDON_DAYS}},
        "status": st,
        "cameras_used": used,
        "over_by": max(0, used - st["cameras"]) if st["status"] == "active" else 0,
        "addon_cameras": CPS.addon_camera_ids(user)[0],
        "notice": CPS.notice_for(user),
        "unpaid_line": pick(lang, bn, en),
        "play_account_id": account,
        "limits": {"relay_mb_per_camera": c["relay_mb_per_camera"],
                   "ai_checks_per_camera": c["ai_checks_per_camera"],
                   "p2p_lan_unlimited": True,
                   "owner_confirmed": c["limits_owner_confirmed"]},
    }


class CctvPlanView(APIView):
    def get(self, request):
        lang = req_lang(request)
        if _off(request):
            return _feature_off(lang)
        return Response(plan_payload(request.user, lang))


class CctvPlanAddonCamerasView(APIView):
    def post(self, request):
        lang = req_lang(request)
        if _off(request):
            return _feature_off(lang)
        raw = (request.data or {}).get("ids")
        if not isinstance(raw, list):
            return Response({"error": "bad_request",
                             "detail": pick(lang, "ক্যামেরা বাছাই করুন।",
                                            "Choose the cameras.")}, status=400)
        try:
            ids = [int(i) for i in raw][:CP.MAX_CAMERAS]
        except (TypeError, ValueError):
            return Response({"error": "bad_request",
                             "detail": pick(lang, "ক্যামেরা বাছাই করুন।",
                                            "Choose the cameras.")}, status=400)
        CPS.set_addon_cameras(request.user, ids)
        return Response({"ok": True, "addon_cameras": CPS.addon_camera_ids(request.user)[0]})
