"""guardian2 — PART 6 two guardians (owner 3 Nov 18:40). Rules:
core/guardian_links.py. Never flag-gated, never billed (safety is free);
the plan only sets HOW MANY guardians a child may have.

  GET  /guardians/links                   requests to approve, my invites,
                                          co-guardians, my own requests
  POST /guardians/invites   {child_id}    existing guardian -> code + link
  POST /guardians/join      {code}        second person -> waits for approval
  POST /guardians/links/<id>/approve      an existing guardian (never the requester)
  POST /guardians/links/<id>/reject
  POST /guardians/links/<id>/remove       any guardian of the child / the co-guardian
                                          leaving / cancel an unused invite
  POST /family/alerts/<id>/responding     "I am responding" on an SOS"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import guardian_links as GL


def _err(e):
    return Response({"detail": e.code, **e.extra}, status=e.http)


class GuardianLinksView(APIView):
    def get(self, request):
        return Response(GL.overview(request.user))


class GuardianInviteView(APIView):
    def post(self, request):
        from .models import User
        try:
            cid = int((request.data or {}).get("child_id"))
        except (TypeError, ValueError):
            return Response({"detail": "bad_child"}, status=status.HTTP_400_BAD_REQUEST)
        child = User.objects.filter(pk=cid).first()
        try:
            link = GL.create_invite(request.user, child)
        except GL.LinkError as e:
            if e.code == "not_guardian":   # never reveal who is whose child
                return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
            return _err(e)
        return Response({**GL.link_dict(link, request.user), "max": GL.max_guardians(child)},
                        status=status.HTTP_201_CREATED)


class GuardianJoinView(APIView):
    def post(self, request):
        try:
            link = GL.join(request.user, (request.data or {}).get("code"))
        except GL.LinkError as e:
            return _err(e)
        return Response(GL.link_dict(link, request.user), status=status.HTTP_201_CREATED)


class GuardianLinkActionView(APIView):
    def post(self, request, pk, action):
        try:
            if action == "approve":
                link = GL.decide(request.user, pk, True)
            elif action == "reject":
                link = GL.decide(request.user, pk, False)
            elif action == "remove":
                link = GL.remove(request.user, pk)
            else:
                return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        except GL.LinkError as e:
            return _err(e)
        return Response({"ok": True, "link": GL.link_dict(link, request.user),
                         **GL.overview(request.user)})


class SosRespondingView(APIView):
    def post(self, request, pk):
        out = GL.responding(request.user, pk)
        if out is None:
            return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, **out})
