"""fcbrain — Family Care v3 BRAIN endpoints (core/family_brain.py).

Every endpoint is the caller's own data, or a family member's card data
through family_brain.can_view. Nothing here is mounted under an admin or
owner page; staff accounts get no extra access (tests_fcbrain).
"""
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import family_brain as FB
from . import notif_budget as NB


def _lang(request):
    h = (request.headers.get("Accept-Language") or "").lower()
    if h.startswith("en"):
        return "en"
    if h.startswith("bn"):
        return "bn"
    return getattr(request.user, "language", "bn") or "bn"


def _me(request):
    st = FB.state_of(request.user)
    p = FB.prefs_of(st)
    return {"prefs": p,
            "paused_until": FB._iso(FB._paused_until(st, FB._now())) if FB._paused_until(st, FB._now()) else None,
            "watch_on": bool(st.get("watch_on")),
            "watch_mode": "background" if FB.background_watch_on(request.user) else "foreground",
            "budget": NB.status(request.user),
            "pause_hours": list(FB.PAUSE_HOURS),
            "night_items": list(FB.NIGHT_ITEMS)}


class BrainPingView(APIView):
    """POST family/brain/ping — heartbeat + on-phone geofence / battery events."""
    def post(self, request):
        return Response(FB.ping(request.user, request.data or {}))


class BrainPrefsView(APIView):
    """GET/POST family/brain/prefs — my brain settings. POST {member_id?,
    auto_arrive?, leave_news?, night?:{on,time,voice,items}}; member_id
    (a child) only for their guardian, only auto_arrive / leave_news."""
    def get(self, request):
        return Response(_me(request))

    def post(self, request):
        d = dict(request.data or {})
        member = request.user
        mid = d.pop("member_id", None)
        if mid not in (None, "", request.user.pk):
            from .models import User
            member = User.objects.filter(pk=mid).first()
            if member is None:
                return Response({"error": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        ok, err = FB.set_prefs(request.user, member, d)
        if not ok:
            code = status.HTTP_403_FORBIDDEN if err == "consent_own_phone" else status.HTTP_400_BAD_REQUEST
            return Response({"error": err}, status=code)
        return Response(_me(request) if member.pk == request.user.pk else {"ok": True})


class BrainPauseView(APIView):
    """POST family/brain/pause {hours: 1|2|8} · {resume: true}."""
    def post(self, request):
        d = request.data or {}
        if d.get("resume") is True:
            FB.resume(request.user)
            return Response(_me(request))
        until = FB.pause(request.user, d.get("hours"))
        if until is None:
            return Response({"error": "bad_hours", "allowed": list(FB.PAUSE_HOURS)},
                            status=status.HTTP_400_BAD_REQUEST)
        return Response(_me(request))


class BrainVisibilityView(APIView):
    """GET family/brain/visibility — who can see me. POST {seen: true}
    resets the monthly reminder."""
    def get(self, request):
        return Response(FB.visibility(request.user))

    def post(self, request):
        FB.mark_visibility_seen(request.user)
        return Response(FB.visibility(request.user))


class BrainLeaveView(APIView):
    """POST family/brain/leave {family_id} — anyone, any time."""
    def post(self, request):
        fid = (request.data or {}).get("family_id")
        if not FB.leave(request.user, fid):
            return Response({"ok": False, "error": "not_member"}, status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True})


class BrainNightNewsView(APIView):
    """GET family/brain/night-news — tonight's card (cached per day; before
    it is sent, a preview built from the template — never an AI call per open)."""
    def get(self, request):
        lang = _lang(request)
        card = FB.night_card(request.user, lang=lang, build=False)
        if card is None:
            # speedproof: the preview walks every member's day (~8 SQL each:
            # live p50 314 ms / p95 584 ms, 10-17 Nov) on EVERY open of
            # Family Care; it is a preview of tonight's card, so 5 minutes old
            # is fine.
            from django.core.cache import cache
            key = "fb_night_preview:%d:%s" % (request.user.pk, lang)
            card = cache.get(key)
            if card is None:
                facts = FB.night_facts(request.user, lang=lang)
                card = {"text": FB.night_template(facts, lang), "source": "preview",
                        "members": len(facts)}
                cache.set(key, card, 300)
        p = FB.prefs_of(FB.state_of(request.user))["night"]
        return Response({"card": card, "night": p})


class BrainAskView(APIView):
    """POST family/brain/ask {q, family_id} -> {text, member_user_id, action, source}."""
    def post(self, request):
        d = request.data or {}
        q = str(d.get("q") or "").strip()[:300]
        if not q:
            return Response({"error": "empty"}, status=status.HTTP_400_BAD_REQUEST)
        return Response(FB.ask(request.user, q, d.get("family_id"), lang=_lang(request)))


class BrainMemberView(APIView):
    """GET family/brain/member/<id> — brain state + today's timeline + both
    clocks (Probashi) for a family member (403 unless we share a family)."""
    def get(self, request, uid):
        from .models import User
        member = User.objects.filter(pk=uid).first()
        if member is None or not FB.can_view(request.user, member):
            return Response({"error": "forbidden"}, status=status.HTTP_403_FORBIDDEN)
        lang = _lang(request)
        return Response({"brain": FB.member_brain_state(request.user, member),
                         "timeline": FB.member_timeline(request.user, member, lang=lang),
                         "clocks": FB.clocks(request.user, member)})


class BrainWatchTokenView(APIView):
    """POST family/brain/watch — the open app switching arrival news on:
    -> {mode, fences:[{id,kind,label,lat,lng,r}], interval_s, token?}. Only
    when the member turned auto-arrive on (their own consent). The scoped
    token for the native BACKGROUND watch only while the owner switch
    family_auto_arrival is ON; otherwise mode "foreground" (app open only)."""
    def post(self, request):
        st = FB.state_of(request.user)
        if not FB.prefs_of(st)["auto_arrive"]:
            return Response({"error": "auto_arrive_off"}, status=status.HTTP_409_CONFLICT)
        bg = FB.background_watch_on(request.user)
        out = {"mode": "background" if bg else "foreground",
               "fences": FB.fences(request.user), "interval_s": FB.WATCH_INTERVAL_S}
        if bg:
            out["token"] = FB.watch_token(request.user)
        return Response(out)


class BrainWatchPingView(APIView):
    """POST family/brain/watch-ping — FamilyWatchService (native, no user
    session): header X-Fc-Watch = the scoped token. Same body as ping.
    A revoked / expired token -> 401 and the phone stops its service."""
    authentication_classes = []
    permission_classes = [AllowAny]

    def post(self, request):
        user = FB.user_for_watch_token(request.headers.get("X-Fc-Watch"))
        if user is None:
            return Response({"error": "watch_off"}, status=status.HTTP_401_UNAUTHORIZED)
        out = FB.ping(user, request.data or {})
        out["fences"] = FB.fences(user)
        return Response(out)
