"""kidaudio — HTTP API for child emergency audio (rules: core/kid_audio.py).

Flag `child_emergency_audio` (OFF) gates setting up consent and listening.
NEVER flag-gated (autonomy / audit): revoking consent, the child stopping a
session, the log, and the child's pending check (so a switch-off mid-session
can never leave a phone without its Stop).
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import kid_audio as KA


def _bad(reason, status=400, **extra):
    return Response({"ok": False, "reason": reason, **extra}, status=status)


def _consent_for(user, pk):
    from django.db.models import Q
    from .models import KidAudioConsent
    return (KidAudioConsent.objects.filter(pk=pk)
            .filter(Q(guardian=user) | Q(child=user))
            .select_related("guardian", "child", "watch").first())


def _session_for(user, pk):
    from django.db.models import Q
    from .models import KidAudioSession
    return (KidAudioSession.objects.filter(pk=pk)
            .filter(Q(guardian=user) | Q(child=user))
            .select_related("guardian", "child", "consent").first())


def _children(user):
    """My Circle people who are MY child on both sides (one-tap pick)."""
    from .models import CircleMember
    out = []
    for m in (CircleMember.objects.filter(user=user, state="accepted", blocked=False,
                                          relation=KA.CHILD_EDGE)
              .select_related("peer_user")[:20]):
        u = m.peer_user
        if u is not None and KA.is_guardian(user, u):
            out.append({"id": u.pk, "name": KA._name(user, u)})
    return out


class ConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from django.db.models import Q
        from .models import KidAudioConsent, KidsWatch
        me = request.user
        on = KA.flag_on(me)
        consents = [KA.consent_row(c, me) for c in KidAudioConsent.objects.filter(
            Q(guardian=me) | Q(child=me)).select_related("guardian", "child")[:30]]
        children = _children(me) if on else []
        kids = {c["id"] for c in children}
        watches = [{"id": w.pk, "child_name": w.child_name, "child_user_id": w.child_user_id}
                   for w in KidsWatch.objects.filter(owner=me, state="paired",
                                                     child_user_id__in=kids)[:10]] if on else []
        return Response({"enabled": on, "max_session_s": KA.MAX_SESSION_S,
                         "max_sessions": KA.MAX_SESSIONS_PER_EMERGENCY,
                         "adult_age": KA.ADULT_AGE, "children": children,
                         "watches": watches, "consents": consents})


class ConsentView(APIView):
    """POST {child_id, birth_year, watch_id?, watch_phone?} — the parent."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from .models import KidsWatch, User
        if not KA.flag_on(request.user):
            return _bad("flag_off", 403)
        d = request.data or {}
        try:
            child = User.objects.get(pk=int(d.get("child_id")))
            year = int(d.get("birth_year"))
        except (TypeError, ValueError, User.DoesNotExist):
            return _bad("bad_request")
        watch = None
        if d.get("watch_id"):
            watch = KidsWatch.objects.filter(pk=d.get("watch_id"), owner=request.user).first()
            if watch is None:
                return _bad("no_watch")
        c, reason = KA.set_consent(request.user, child, year, watch=watch,
                                   watch_phone=d.get("watch_phone") or "")
        if c is None:
            return _bad(reason, 403 if reason == "not_guardian" else 400)
        return Response({"ok": True, "consent": KA.consent_row(c, request.user)})


class ConsentAgreeView(APIView):
    """POST {birth_year} — the child, on their own phone."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not KA.flag_on(request.user):
            return _bad("flag_off", 403)
        c = _consent_for(request.user, pk)
        if c is None or c.child_id != request.user.pk:
            return _bad("not_found", 404)
        ok, reason = KA.child_agree(request.user, c, (request.data or {}).get("birth_year"))
        if not ok:
            return _bad(reason)
        return Response({"ok": True, "consent": KA.consent_row(c, request.user)})


class ConsentRevokeView(APIView):
    """Either side, any time. Never flag-gated."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        c = _consent_for(request.user, pk)
        if c is None:
            return _bad("not_found", 404)
        KA.revoke(request.user, c)
        return Response({"ok": True, "consent": KA.consent_row(c, request.user)})


class ListenView(APIView):
    """POST {consent_id, channel: phone|watch} — the parent asks to listen.
    Every call writes an audit row, granted or refused."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        d = request.data or {}
        try:
            c = _consent_for(request.user, int(d.get("consent_id")))
        except (TypeError, ValueError):
            c = None
        if c is None or c.guardian_id != request.user.pk:
            return _bad("no_consent", 404)
        s, reason = KA.request_listen(request.user, c, d.get("channel") or "phone")
        if reason:
            return Response({"ok": False, "reason": reason,
                             "session": KA.session_row(s, request.user) if s else None},
                            status=403)
        body = {"ok": True, "session": KA.session_row(s, request.user)}
        if s.channel == "watch":
            body["dial"] = c.watch_phone      # the parent's own phone dials it
        return Response(body)


class PendingView(APIView):
    """GET — the child's phone (on open / resume / push). Never flag-gated:
    returns nothing unless a session was granted while the flag was on."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        s = KA.pending_for_child(request.user)
        if s is None:
            return Response({"pending": None})
        row = KA.session_row(s, request.user)
        row["member_id"] = KA.child_member_id(s)
        row["guardian_id"] = s.guardian_id
        return Response({"pending": row})


class SessionEventView(APIView):
    """POST {event: started|stop, notice_shown?}.
    started — child only, and only with the foreground notice showing;
    stop    — either side (never flag-gated)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        s = _session_for(request.user, pk)
        if s is None:
            return _bad("not_found", 404)
        d = request.data or {}
        ev = d.get("event")
        me = request.user
        if ev == "started":
            if s.child_id != me.pk:
                return _bad("not_child", 403)
            ok, reason = KA.child_started(me, s, d.get("notice_shown"))
            if not ok:
                return _bad(reason, 409)
        elif ev == "stop":
            side = "child" if s.child_id == me.pk else "guardian"
            KA.end_session(s, "stopped", by=side)
        else:
            return _bad("bad_event")
        s.refresh_from_db()
        return Response({"ok": True, "session": KA.session_row(s, me)})


class LogView(APIView):
    """GET — every session row where I am the parent OR the child."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from django.db.models import Q
        from .models import KidAudioSession
        me = request.user
        KA.enforce(me)
        rows = (KidAudioSession.objects.filter(Q(guardian=me) | Q(child=me))
                .select_related("guardian", "child")[:100])
        return Response({"sessions": [KA.session_row(s, me) for s in rows]})
