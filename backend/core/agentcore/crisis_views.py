"""AF-3 crisis API (not behind the agent_core flag — safety is never gated):

  GET  /api/v1/crisis/helplines?category=   999 + the owner-CONFIRMED numbers
  POST /api/v1/crisis/family-alert {token}  the user TAPPED "Yes, tell them":
       one crisis_support family alert (no category, no words, no location),
       idempotent per crisis event; a forged / expired / foreign token -> 400.
Free (no credits), never automatic.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from ..i18n import pick, req_lang
from . import crisis_guard as CG


class CrisisHelplinesView(APIView):
    def get(self, request):
        lang = req_lang(request)
        cat = request.query_params.get("category") or ""
        if cat not in CG.CATEGORIES:
            cat = ""
        return Response({"helplines": CG.helplines(cat, lang)})


class CrisisFamilyAlertView(APIView):
    def post(self, request):
        lang = req_lang(request)
        stats = CG.alert_family(request.user, (request.data or {}).get("token"))
        if stats is None:
            return Response({"ok": False, "error": "bad_token",
                             "detail": pick(lang, "এই অনুরোধের সময় শেষ — আবার চেষ্টা করুন।",
                                            "This request has expired — please try again.")},
                            status=400)
        n = int(stats.get("recipients") or 0)
        if n:
            msg = pick(lang, "আপনার পরিবারের %sজনকে জানানো হয়েছে।" % str(n).translate(CG._TO_BN),
                       "%d family member(s) have been told." % n)
        else:
            msg = pick(lang, "পরিবারের কাউকে পাওয়া যায়নি — দয়া করে নিজে ফোন করুন বা ৯৯৯-এ কল করুন।",
                       "No family member could be reached — please call someone yourself or call 999.")
        return Response({"ok": True, "recipients": n, "sent": int(stats.get("sent") or 0),
                         "duplicate": int(stats.get("duplicate") or 0), "detail": msg})
