"""ai-reply-core (owner order 17 Nov): AI reply API. Contract:
owner_actions/AI_REPLY_SPEC_BN.md "API". Logic: core/ai_reply.py.

  POST   ai/reply/suggest                 user token OR X-Assisto-AiReply (lane 2)
  POST   ai/reply/auto                    Busy / Full auto decision (send|hold|skip)
  GET    ai/reply/notif-state
  POST   ai/reply/notif-token             DELETE = revoke
  GET    ai/reply/settings/<kind>/<id>    kind = member | group ; POST = change
  GET    ai/reply/style                   POST {consent}
  POST   ai/reply/style/learn             {samples: [own sent texts]}
  GET    ai/reply/held                    POST ai/reply/held/<id>/seen
Message text is never stored or logged."""
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ai_reply as AR

HEADER = "HTTP_X_ASSISTO_AIREPLY"


def _data(request):
    d = request.data
    return d if hasattr(d, "get") else {}


class AiReplySuggestView(APIView):
    """In-app (user token) or from the notification listener (scoped
    X-Assisto-AiReply token: 401 = stay quiet)."""
    permission_classes = [AllowAny]

    def post(self, request):
        body = _data(request)
        user = request.user if getattr(request.user, "is_authenticated", False) else None
        tok = request.META.get(HEADER, "")
        if user is None and tok:
            user = AR.notif_user(tok)
        if user is None:
            return Response({"ok": False, "reason": "unauthorized"}, status=401)
        source = "notif" if str(body.get("source") or "") == "notif" else "circle"
        if tok and not getattr(request.user, "is_authenticated", False):
            source = "notif"        # the scoped token is ONLY for notification suggestions
        st, out = AR.suggest(user, body, source=source)
        return Response(out, status=st)


class AiReplyAutoView(APIView):
    def post(self, request):
        st, out = AR.auto(request.user, _data(request))
        return Response(out, status=st)


class AiReplyNotifStateView(APIView):
    def get(self, request):
        return Response(AR.notif_state(request.user))


class AiReplyNotifTokenView(APIView):
    def post(self, request):
        st, out = AR.notif_token(request.user)
        return Response(out, status=st)

    def delete(self, request):
        return Response(AR.notif_revoke(request.user))


def _target(request, kind, pk):
    from .models import CircleGroup, CircleGroupMember, CircleMember
    if kind == "member":
        e = CircleMember.objects.filter(user=request.user, pk=pk).first()
        return (e, None) if e is not None else None
    if kind == "group":
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is not None and CircleGroupMember.objects.filter(
                group=g, member=request.user, status="active").exists():
            return None, g
    return None


class AiReplySettingsView(APIView):
    def get(self, request, kind, pk):
        t = _target(request, kind, pk)
        if t is None:
            return Response({"ok": False, "reason": "not_found"}, status=404)
        return Response(AR.settings_body(request.user, *t))

    def post(self, request, kind, pk):
        t = _target(request, kind, pk)
        if t is None:
            return Response({"ok": False, "reason": "not_found"}, status=404)
        st, out = AR.settings_set(request.user, _data(request), *t)
        return Response(out, status=st)


class AiReplyStyleView(APIView):
    def get(self, request):
        return Response(AR.style_body(request.user))

    def post(self, request):
        return Response(AR.style_set_consent(request.user, bool(_data(request).get("consent"))))


class AiReplyStyleLearnView(APIView):
    def post(self, request):
        st, out = AR.style_learn(request.user, _data(request).get("samples"))
        return Response(out, status=st)


class AiReplyHeldView(APIView):
    def get(self, request):
        return Response(AR.held_list(request.user))


class AiReplyHeldSeenView(APIView):
    def post(self, request, pk):
        ok = AR.held_seen(request.user, pk)
        return Response({"ok": ok}, status=200 if ok else 404)
