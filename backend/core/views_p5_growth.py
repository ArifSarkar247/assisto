"""p5-growth endpoints (logic in core.growth).

  GET  growth/me       invite code + link + honest rules + my progress + seat
  POST growth/claim    {code}  enter a friend's invite code (once, within N days)
  POST growth/install  {install_id, app_version, platform, ref}  anonymous
                       first-open marker (AllowAny; only a hash is stored)
"""
from django.core.cache import cache
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import growth as G
from .i18n import req_lang

CLAIM_TRIES_PER_HOUR = 10


def _device_id(request):
    try:
        from .otp import device_id
        return device_id(request)
    except Exception:
        return ""


class GrowthMeView(APIView):
    def get(self, request):
        return Response(G.summary(request.user, req_lang(request)))


class GrowthClaimView(APIView):
    def post(self, request):
        lang = req_lang(request)
        key = "p5claim:%s" % request.user.pk
        tries = cache.get(key, 0)
        if tries >= CLAIM_TRIES_PER_HOUR:
            return Response({"ok": False, "reason": "rate_limited",
                             "detail": G.pick(lang, "অনেকবার চেষ্টা হয়েছে। এক ঘণ্টা পরে আবার চেষ্টা করুন।",
                                              "Too many tries. Please try again in an hour.")},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        cache.set(key, tries + 1, 3600)
        ok, reason, _row = G.claim(request.user, (request.data or {}).get("code"),
                                   device_id=_device_id(request))
        body = {"ok": ok, "reason": reason, "detail": G.claim_message(reason, lang)}
        if ok:
            body["me"] = G.summary(request.user, lang)
        return Response(body, status=status.HTTP_200_OK if ok else status.HTTP_400_BAD_REQUEST)


class InstallPingView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        d = request.data or {}
        user = request.user if getattr(request.user, "is_authenticated", False) else None
        created = G.install_ping(d.get("install_id"), user=user,
                                 platform=d.get("platform") or "android",
                                 app_version=d.get("app_version") or "",
                                 ref=d.get("ref") or "", device_id=_device_id(request))
        return Response({"ok": True, "new": bool(created)})
