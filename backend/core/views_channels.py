"""channels (2 Nov): COMMUNITIES you can find and join — my list, invite
link / code (https://lifeassisto.com/cm/<code>), preview + join-with-approval.
Channel routes live in views_messenger (+ the directory in views_m1_routes);
shared rules in core.channels_service."""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import channels_service as CS
from .models import Community, CommunityGroup, CommunityJoinRequest, CommunityMember


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _code(raw):
    return "".join(ch for ch in str(raw or "").strip().lower()
                   if ch in CS.CODE_ALPHABET)[:16]


def _by_code(raw):
    code = _code(raw)
    if len(code) < 6:
        return None
    return Community.objects.filter(invite_code=code).first()


def _state(c, user):
    if CS.community_role(c, user) is not None:
        return "member"
    if CommunityJoinRequest.objects.filter(
            group__community=c, group__kind="announcements",
            requester=user, state="pending").exists():
        return "requested"
    return "none"


class CommunitiesView(APIView):
    """GET /communities -> {results:[community]} the communities I'm in
    (admin first), plus `requested` — the ones waiting for an admin."""

    def get(self, request):
        me = request.user
        roles = {}
        for cid, role in (CommunityMember.objects.filter(member=me, status="active")
                          .values_list("community_id", "role")):
            if roles.get(cid) != "admin":
                roles[cid] = role
        rows = [CS.community_view(c, me, roles[c.id])
                for c in Community.objects.filter(pk__in=list(roles))]
        rows.sort(key=lambda r: (r["viewer_role"] != "admin", r["name"].lower()))
        pend = (CommunityJoinRequest.objects.filter(
            requester=me, state="pending", group__kind="announcements")
            .exclude(group__community_id__in=list(roles))
            .select_related("group__community"))
        requested = [{"id": r.group.community_id, "name": r.group.community.name,
                      "description": r.group.community.description,
                      "state": "requested"} for r in pend]
        return Response({"results": rows, "requested": requested})


class CommunityPreviewView(APIView):
    """GET /communities/preview?code= -> {id, name, description, member_count,
    group_count, state: member|requested|none}. 404 for a wrong code."""

    def get(self, request):
        c = _by_code(request.query_params.get("code"))
        if c is None:
            return _nf()
        v = CS.community_view(c, request.user, CS.community_role(c, request.user))
        v.pop("invite_url", None)
        v.pop("invite_code", None)
        v["state"] = _state(c, request.user)
        return Response(v)


class CommunityJoinByCodeView(APIView):
    """POST /communities/join {code} -> asks the admins (join request on the
    announcements group; they get a push). Already in -> state member.
    20 join requests/hour per person."""

    def post(self, request):
        # adminsafe: Owner Admin restriction (community_join) — server-side
        from .admin_safety import gate as _as_gate
        _denied = _as_gate(request, "community_join")
        if _denied is not None:
            return _denied
        c = _by_code((request.data or {}).get("code"))
        if c is None:
            return _nf()
        st = _state(c, request.user)
        if st != "none":
            return Response({"state": st, "id": c.id, "name": c.name})
        ann = CommunityGroup.objects.filter(community=c, kind="announcements").first()
        if ann is None:
            return _nf()
        if not CS.rate_ok(request.user, "cmjoin", CS.JOINS_PER_HOUR, 3600):
            return Response({"detail": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        CommunityJoinRequest.objects.create(group=ann, requester=request.user,
                                            state="pending")
        CS.notify_join_request(ann, request.user)
        return Response({"state": "requested", "id": c.id, "name": c.name},
                        status=status.HTTP_201_CREATED)


class CommunityInviteView(APIView):
    """GET /community/<id>/invite -> {url, code} (admins). POST -> a new code
    (the old link stops working)."""

    def _get(self, request, pk):
        c = Community.objects.filter(pk=pk).first()
        if c is None or CS.community_role(c, request.user) is None:
            return None, _nf()
        if CS.community_role(c, request.user) != "admin":
            return None, Response({"detail": "admins_only"},
                                  status=status.HTTP_403_FORBIDDEN)
        return c, None

    def get(self, request, pk):
        c, err = self._get(request, pk)
        if err is not None:
            return err
        if not c.invite_code:
            c.invite_code = CS.new_code(Community)
            c.save(update_fields=["invite_code"])
        return Response({"url": CS.community_link(c), "code": c.invite_code,
                         "name": c.name})

    def post(self, request, pk):
        c, err = self._get(request, pk)
        if err is not None:
            return err
        c.invite_code = CS.new_code(Community)
        c.save(update_fields=["invite_code"])
        return Response({"url": CS.community_link(c), "code": c.invite_code,
                         "name": c.name})
