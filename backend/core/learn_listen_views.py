"""langkoja — phone-voice listening practice API (flag `language_packs`).

  GET  /learn/<lang>/listening          questions (no answer keys) + tts_locale + honest label
  POST /learn/<lang>/listening/grade    {answers:{qid: optionIndex}} -> correct/total + explanations

Practice only: not stored as a course result (no certificate from phone-voice
listening) and never mixed into a mock score. Free, key-free, unlimited.
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .learn_views import flag_on, _off, _bad
from .logic import langpacks as LP
from .logic import listen_tts as LT

R = Response


class LearnListeningView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, lang):
        if not flag_on(request.user):
            return _off()
        d = LT.load(lang)
        if d is None:
            return _bad("no_listening", 404)
        return R(dict(LT.public(d), estimate_label=LP.ESTIMATE_LABEL))


class LearnListeningGradeView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, lang):
        if not flag_on(request.user):
            return _off()
        d = LT.load(lang)
        if d is None:
            return _bad("no_listening", 404)
        answers = (request.data or {}).get("answers")
        if not isinstance(answers, dict) or not answers:
            return _bad("no_answers")
        return R(dict(LT.grade(d, answers), ok=True, estimate_label=LP.ESTIMATE_LABEL))
