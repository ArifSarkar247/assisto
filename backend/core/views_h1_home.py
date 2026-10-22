"""
h1-home: image in chat (home chat + Assisto AI chat).

  GET  chat-vision/config               plan, funding quote (pool / ads / credits,
                                        Profit Guard decided), provider state
                                        ("needs key X"), upload cap
  POST chat-vision/jobs                 create a detailed-answer job: face-ID refused
                                        first, then funding TAKEN (pool/credits) or
                                        awaited (ads)
  GET  chat-vision/jobs/<pk>            job state (ads verified / remaining, answer)
  POST chat-vision/jobs/<pk>/ad-ticket  a rewarded-ad ticket (ps1 ledger, SSV custom_data)
  POST chat-vision/jobs/<pk>/fund       switch an ads job to credits (no-fill path)
  POST chat-vision/jobs/<pk>/answer     run the funded job: the photo is used in
                                        memory only and never stored

Ads are verified ONLY by the shared Google-signed /ads/ssv callback (ps1).
"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import chat_vision_service as CVS
from . import photo_studio_service as S
from .i18n import req_lang


class ChatVisionConfigView(APIView):
    def get(self, request):
        return Response(CVS.client_config(request.user, req_lang(request)))


class ChatVisionJobsView(APIView):
    def post(self, request):
        code, body = CVS.create_job(request.user, request.data or {}, req_lang(request))
        return Response(body, status=code)


def _job(request, pk):
    return CVS.owned_job(request.user, pk)


def _missing():
    return Response({"ok": False}, status=status.HTTP_404_NOT_FOUND)


class ChatVisionJobView(APIView):
    def get(self, request, pk):
        job = _job(request, pk)
        if job is None:
            return _missing()
        return Response({"ok": True, "job": CVS.job_state(job, req_lang(request))})


class ChatVisionTicketView(APIView):
    def post(self, request, pk):
        job = _job(request, pk)
        if job is None:
            return _missing()
        code, body = S.issue_ticket(request.user, job, req_lang(request))
        if isinstance(body.get("job"), dict):
            body["job"] = CVS.job_state(job, req_lang(request))
        return Response(body, status=code)


class ChatVisionFundView(APIView):
    def post(self, request, pk):
        job = _job(request, pk)
        if job is None:
            return _missing()
        code, body = CVS.fund_with_credits(request.user, job, req_lang(request))
        return Response(body, status=code)


class ChatVisionAnswerView(APIView):
    def post(self, request, pk):
        job = _job(request, pk)
        if job is None:
            return _missing()
        code, body = CVS.answer(request.user, job, request.data or {}, req_lang(request))
        return Response(body, status=code)
