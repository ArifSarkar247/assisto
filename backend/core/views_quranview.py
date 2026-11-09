"""quranview — app API for the bilingual ayah view (spec:
owner_actions/QURAN_BILINGUAL_SPEC_BN.md, section 4). Signed-in users only.

  GET /quran/meaning/<surah>            Bangla + English meaning (QuranEnc, verbatim)
  GET /quran/tafsir/<surah>/<ayah>      licensed tafsir + notes + shane nuzul units
  GET /quran/qf/<surah>/<ayah>?reciter= word-by-word, transliteration, audio (QF)
  GET /quran/reciters                   QF reciter list

The pronunciation endpoint (/quran/pron/...) belongs to lane 15 (quranpron).
No AI anywhere; no ads; texts are never altered.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import quran_bilingual as QB


def _err(e):
    code = str(e) or "unavailable"
    return Response({"ok": False, "reason": code},
                    status=400 if code == "bad_ref" else 503)


class MeaningView(APIView):
    def get(self, request, surah):
        if not QB.valid_ref(surah):
            return _err(QB.SourceError("bad_ref"))
        try:
            return Response(QB.meaning(surah))
        except QB.SourceError as e:
            return _err(e)


class TafsirView(APIView):
    def get(self, request, surah, ayah):
        try:
            return Response(QB.tafsir(surah, ayah))
        except QB.SourceError as e:
            return _err(e)


class QfAyahView(APIView):
    def get(self, request, surah, ayah):
        rec = request.query_params.get("reciter") or None
        if rec is not None and not str(rec).isdigit():
            return _err(QB.SourceError("bad_ref"))
        try:
            return Response(QB.qf_ayah(surah, ayah, reciter=rec))
        except QB.SourceError as e:
            return _err(e)


class RecitersView(APIView):
    def get(self, request):
        try:
            return Response(QB.qf_reciters())
        except QB.SourceError as e:
            return _err(e)
