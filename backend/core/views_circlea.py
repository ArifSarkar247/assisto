"""circlea — My Circle part A1 endpoints.

  POST /circle/<pk>/people-group  {group: family|others|auto}
       Mark one of MY Circle edges Family / Others (auto = back to the
       suggestion).  Returns the full member dict (same as /circle/members).
"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import circle_family


class CirclePeopleGroupView(APIView):
    def post(self, request, pk):
        m, err = circle_family.set_group(request.user, pk,
                                         (request.data or {}).get("group", ""))
        if err == "not_found":
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        if err:
            return Response({"detail": err}, status=status.HTTP_400_BAD_REQUEST)
        from .views_module5 import _member_dict
        return Response(_member_dict(m))


class GuardiansMineView(APIView):
    """GET /guardians/mine — the CHILD's side: every guardian who can see me,
    by name, from every feature (kids watch, school mode, guardian journey),
    with what they see and whether I can remove them. Never flag-gated:
    transparency must always work."""

    def get(self, request):
        from . import guardianship
        from . import guardian_links   # guardian2: requests waiting for approval
        return Response({"guardians": guardianship.guardians_of(request.user),
                         "pending": guardian_links.pending_for_child(request.user)})


class GuardianRemoveView(APIView):
    """POST /guardians/mine/<uid>/remove — the child removes one guardian
    from everything the child decides (school mode watcher / plan they own,
    guardian journeys). A kids watch stays (set up by its parent) and the
    answer names who can change it."""

    def post(self, request, uid):
        from . import guardianship
        if uid not in guardianship.guardian_user_ids(request.user):
            return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        res = guardianship.remove_guardian(request.user, uid)
        return Response({"ok": True, **res,
                         "guardians": guardianship.guardians_of(request.user)})


class GuardianChildrenView(APIView):
    """GET /guardians/children — the guardian's side: every child I watch
    (own setup or shared with me) and the OTHER guardians of each child."""

    def get(self, request):
        from . import guardianship
        return Response({"children": guardianship.children_of(request.user)})


# ------------------------------------------------------------ link previews
_LINK_CONTEXTS = ("channel",)
_LINK_RATE = 120          # per user per hour (preview + check together)


def _link_rate_ok(user):
    from django.core.cache import cache
    k = "lp:rate:%d" % user.id
    n = cache.get(k, 0)
    if n >= _LINK_RATE:
        return False
    cache.set(k, n + 1, 3600)
    return True


def _link_args(request):
    d = request.data or {}
    url = str(d.get("url") or "").strip()
    ctx = str(d.get("context") or "").strip().lower()
    if ctx not in _LINK_CONTEXTS:
        # end-to-end-encrypted chats NEVER send a URL here: the sender's
        # phone builds the preview inside the encrypted message.
        return None, Response({"detail": "e2e_never"}, status=status.HTTP_400_BAD_REQUEST)
    if not url or len(url) > 2048:
        return None, Response({"detail": "bad_url"}, status=status.HTTP_400_BAD_REQUEST)
    if not _link_rate_ok(request.user):
        return None, Response({"detail": "rate"}, status=status.HTTP_429_TOO_MANY_REQUESTS)
    return url, None


class LinkPreviewView(APIView):
    """POST /links/preview {url, context:'channel'} — SSRF-safe, cached."""

    def post(self, request):
        url, err = _link_args(request)
        if err:
            return err
        from . import link_preview as LP
        return Response(LP.cached_preview(url))


class LinkCheckView(APIView):
    """POST /links/check {url, context:'channel'} — heuristics + the real
    destination of a shortener + Google Safe Browsing when configured."""

    def post(self, request):
        url, err = _link_args(request)
        if err:
            return err
        from django.core.cache import cache
        from . import link_preview as LP
        k = LP.cache_key("ck", url)
        hit = cache.get(k)
        if hit is None:
            hit = LP.check_link(url)
            cache.set(k, hit, 6 * 3600)
        return Response(hit)
