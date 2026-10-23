"""p4-world: Unseen World REST endpoints (all authenticated).

GET  world/config            readiness flags (hidden-without-key), prefs, cities
POST world/prefs             per-card on/off, city, job types, alerts (synced)
GET  world/today             Today cards (only cards with real data)
POST world/ask               live web-search answer with numbered sources (credits)
GET  world/jobs              job portals (link-out) + types + feed notes
GET  world/hub/<id>          curated hub content (expat/students/farmers/gov/health)
POST world/hub/<id>/ai       paid AI help for a hub (credits via ai.generate)
GET  world/mcq               topics + a round (no answers) + score history
POST world/mcq               score a round on the server, store the attempt
"""
import random

from rest_framework.response import Response
from rest_framework.views import APIView

from . import world_service as SVC
from .i18n import req_lang
from .logic import world_content as WC
from .logic import world_mcq as MCQ


class WorldConfigView(APIView):
    def get(self, request):
        return Response(SVC.config(request.user, req_lang(request)))


class WorldPrefsView(APIView):
    def get(self, request):
        return Response(SVC.prefs_public(SVC.prefs(request.user)))

    def post(self, request):
        data = request.data if isinstance(request.data, dict) else {}
        return Response(SVC.update_prefs(request.user, data))


class WorldTodayView(APIView):
    def get(self, request):
        return Response(SVC.today(request.user, req_lang(request)))


class WorldAskView(APIView):
    # per-user daily cap + credits live in world_service.web_answer
    def post(self, request):
        data = request.data if isinstance(request.data, dict) else {}
        lang = data.get("lang") or req_lang(request)
        st, body = SVC.web_answer(request.user, data.get("question", ""), lang)
        return Response(body, status=st)


class WorldJobsView(APIView):
    def get(self, request):
        out = WC.jobs_public(req_lang(request))
        out["alerts_ready"] = SVC.careerjet_ready()
        out["prefs"] = SVC.prefs_public(SVC.prefs(request.user))
        return Response(out)


class WorldHubView(APIView):
    def get(self, request, hub):
        lang = req_lang(request)
        d = WC.hub_public(hub, lang)
        if d is None:
            return Response({"ok": False, "reason": "unknown_hub"}, status=404)
        from . import ai
        d["ai_ready"] = bool(d["ai"]) and ai.available()
        if d.get("photo"):
            from . import chat_vision_service as CVS
            try:
                d["photo_ready"] = bool(CVS._active()[0])
            except Exception:
                d["photo_ready"] = False
        if hub == "health":
            from .logic import medicine_db
            d["medicine_price_ready"] = not medicine_db.is_sample()
        if hub == "students":
            d["mcq_topics"] = MCQ.topics_public(lang)
        return Response(d)


class WorldHubAiView(APIView):
    def post(self, request, hub):
        data = request.data if isinstance(request.data, dict) else {}
        lang = data.get("lang") or req_lang(request)
        st, body = SVC.hub_ai(request.user, hub, data.get("question", ""), lang)
        return Response(body, status=st)


class WorldMcqView(APIView):
    def get(self, request):
        lang = req_lang(request)
        topic = request.query_params.get("topic", "mixed")
        if topic not in MCQ.TOPICS:
            topic = "mixed"
        seed = random.SystemRandom().randrange(1 << 30)
        return Response({"topics": MCQ.topics_public(lang), "topic": topic,
                         "questions": MCQ.pick_round(topic, seed, lang),
                         "history": SVC.mcq_history(request.user)})

    def post(self, request):
        data = request.data if isinstance(request.data, dict) else {}
        lang = data.get("lang") or req_lang(request)
        answers = data.get("answers") if isinstance(data.get("answers"), list) else []
        return Response(SVC.mcq_submit(request.user, str(data.get("topic") or "mixed"),
                                       answers[:50], lang))
