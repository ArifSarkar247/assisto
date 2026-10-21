"""
ps1-photo: Photo Studio API.

  GET  photo-studio/config                 plan, entry-ad due?, per-feature funding quotes,
                                           provider state ("needs key X"), ready options
  POST photo-studio/safety                 server-side safety check (no job created)
  POST photo-studio/entry-ad               report the entry interstitial (server cap)
  POST photo-studio/jobs                   create a job: safety -> funding TAKEN first
  GET  photo-studio/jobs/<pk>              job state (ads verified / remaining)
  POST photo-studio/jobs/<pk>/ad-ticket    a rewarded-ad ticket (SSV custom_data)
  POST photo-studio/jobs/<pk>/fund        switch an ads job to credits (no-fill path)
  POST photo-studio/jobs/<pk>/run          run a funded cloud job on the provider
  POST photo-studio/jobs/<pk>/unlock       THE export gate (save/share/wallpaper/copy/open_in)
  GET  ads/ssv                             AdMob server-side verification callback (public,
                                           Google-signed; the only thing that verifies an ad)
  GET  admin/photo-studio/pnl              owner: ad revenue vs cost per day per feature
"""
from django.http import JsonResponse
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import photo_studio_service as S
from .i18n import req_lang
from .logic import photo_studio as PS


class PhotoStudioConfigView(APIView):
    def get(self, request):
        return Response(S.client_config(request.user, req_lang(request)))


class PhotoStudioSafetyView(APIView):
    def post(self, request):
        d = request.data or {}
        lang = req_lang(request)
        v = PS.classify(str(d.get("prompt") or "")[:500], d.get("options") or [],
                        beauty_ops=d.get("beauty") or [],
                        photo_kind=str(d.get("photo_kind") or ""),
                        child_in_photo=bool(d.get("child_in_photo")),
                        others_in_photo=bool(d.get("others_in_photo")),
                        own_photo=bool(d.get("own_photo", True)),
                        feature=str(d.get("feature") or "prompt_edit"))
        if not v["allowed"]:
            v["message"] = S.refusal_message(v["reason"], lang)
        return Response(v)


class PhotoStudioEntryAdView(APIView):
    def post(self, request):
        code, body = S.record_entry_ad(request.user, bool((request.data or {}).get("shown")))
        return Response(body, status=code)


class PhotoStudioJobsView(APIView):
    def post(self, request):
        code, body = S.create_job(request.user, request.data or {}, req_lang(request))
        return Response(body, status=code)


def _job_or_404(request, pk):
    return S._owned_job(request.user, pk)


class PhotoStudioJobView(APIView):
    def get(self, request, pk):
        job = _job_or_404(request, pk)
        if job is None:
            return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, "job": S.job_state(job, req_lang(request))})


class PhotoStudioTicketView(APIView):
    def post(self, request, pk):
        job = _job_or_404(request, pk)
        if job is None:
            return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)
        code, body = S.issue_ticket(request.user, job, req_lang(request))
        return Response(body, status=code)


class PhotoStudioFundView(APIView):
    def post(self, request, pk):
        job = _job_or_404(request, pk)
        if job is None:
            return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)
        code, body = S.fund_with_credits(request.user, job, req_lang(request))
        return Response(body, status=code)


class PhotoStudioRunView(APIView):
    def post(self, request, pk):
        job = _job_or_404(request, pk)
        if job is None:
            return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        code, body = S.run_cloud(request.user, job, d.get("image_b64") or "",
                                 req_lang(request), face_boxes=d.get("face_boxes"))
        return Response(body, status=code)


class PhotoStudioUnlockView(APIView):
    def post(self, request, pk):
        job = _job_or_404(request, pk)
        if job is None:
            return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)
        code, body = S.unlock(request.user, job, str((request.data or {}).get("kind") or ""),
                              req_lang(request))
        return Response(body, status=code)


class AdMobSsvView(APIView):
    """Google calls this with a signed query string. No auth (Google is the
    caller); the ECDSA signature is the authentication."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        code, body = S.ssv_callback(request.META.get("QUERY_STRING", ""),
                                    request.GET)
        return JsonResponse(body, status=code)


class AdminPhotoStudioPnlView(APIView):
    def get(self, request):
        u = request.user
        if not (u and u.is_authenticated and u.is_superuser):
            return Response({"can_manage": False}, status=status.HTTP_403_FORBIDDEN)
        try:
            days = max(1, min(180, int(request.query_params.get("days", 30))))
        except (TypeError, ValueError):
            days = 30
        out = S.owner_stats(days)
        out["days_window"] = days
        out["can_manage"] = True
        return Response(out)
