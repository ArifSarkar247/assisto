"""Agent Core proactive API (flag `agent_core`, default OFF -> 403 feature_off).
A user only ever sees and changes their own nudges and settings. No AI, no
credits (template-only).

  GET  agent-core/nudges                 my in-app cards (last 7 days, not dismissed)
  POST agent-core/nudges/<id>/open       opened (stats)
  POST agent-core/nudges/<id>/dismiss    hide the card
  POST agent-core/nudges/<id>/mute       stop this trigger for me (opt-out)
  GET  agent-core/nudge-prefs            settings (cap, brief times, quiet hours, triggers)
  PUT  agent-core/nudge-prefs            partial update
  GET  agent-core/brief?kind=morning|evening   live brief/recap (text + voice text)
"""
from datetime import timedelta

from django.utils import timezone
from rest_framework.response import Response

from ..i18n import req_lang
from . import proactive as P
from .views import _Gated, _err


def _mine(request, pk):
    from ..models import AgentNudge
    return AgentNudge.objects.filter(user=request.user, pk=pk).first()


class NudgesView(_Gated):
    def get(self, request):
        from ..models import AgentNudge
        lang = req_lang(request)
        since = timezone.localdate() - timedelta(days=7)
        rows = (AgentNudge.objects.filter(user=request.user, for_date__gte=since,
                                          dismissed_at__isnull=True)
                .order_by("-created_at", "-id")[:40])
        # agentcore: every number on a card is re-checked against the user's
        # real rows before it is shown; a stale card is hidden for good
        from . import suggest as SG
        rows = SG.verify_nudges(request.user, list(rows))
        return Response({"results": [P.nudge_out(n, lang) for n in rows],
                         "prefs": P.prefs_out(P.prefs_for(request.user), lang)})


class NudgeActionView(_Gated):
    def post(self, request, pk, action):
        lang = req_lang(request)
        n = _mine(request, pk)
        if n is None:
            return _err(lang, "not_found", 404)
        now = timezone.now()
        if action in ("dismiss", "mute"):
            # agentcore: hiding a card with a proposal = "not now" (nothing done)
            apid = (n.data or {}).get("approval")
            if apid:
                from ..models import AgentApproval
                from . import runner as RN
                if AgentApproval.objects.filter(pk=apid, user=request.user, status="pending").exists():
                    RN.decide(request.user, apid, "reject", lang=lang)
        if action == "open":
            if not n.opened_at:
                n.opened_at = now
                n.save(update_fields=["opened_at"])
        elif action == "dismiss":
            if not n.dismissed_at:
                n.dismissed_at = now
                n.save(update_fields=["dismissed_at"])
        elif action == "mute":
            if n.trigger not in P.TRIGGERS:
                return _err(lang, "bad_input")
            P.mute_trigger(request.user, n.trigger)
            if not n.dismissed_at:
                n.dismissed_at = now
                n.save(update_fields=["dismissed_at"])
        else:
            return _err(lang, "not_found", 404)
        return Response({"ok": True, "nudge": P.nudge_out(n, lang),
                         "prefs": P.prefs_out(P.prefs_for(request.user), lang)})


class NudgePrefsView(_Gated):
    def get(self, request):
        return Response(P.prefs_out(P.prefs_for(request.user), req_lang(request)))

    def put(self, request):
        lang = req_lang(request)
        try:
            p = P.save_prefs(request.user, request.data if isinstance(request.data, dict) else {})
        except P.PrefsError as e:
            r = _err(lang, "bad_input")
            r.data["field"] = str(e)
            return r
        return Response(P.prefs_out(p, lang))

    patch = put


class BriefView(_Gated):
    def get(self, request):
        lang = req_lang(request)
        k = request.query_params.get("kind") or "morning"
        if k not in ("morning", "evening"):
            return _err(lang, "bad_input")
        b = P.build_brief(request.user, "brief_" + k, timezone.now())
        return Response(P.brief_out(b, lang))
