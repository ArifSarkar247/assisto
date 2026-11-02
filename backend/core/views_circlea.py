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
        return Response({"guardians": guardianship.guardians_of(request.user)})


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
