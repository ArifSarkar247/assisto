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
