"""e2-keys — peer key lookup + key request (see core/e2_keys.py).

GET  /circle/keys/peer/<member_id>  -> the peer's key LIVE from the per-user
     directory {user_id, public_key, key_id, scheme, updated_at, changed_at,
     requested}. When the peer has no key yet a silent key_request push is
     queued for them (throttled) and requested=true — the chat calls this on
     open and before each send, so a sender never dead-ends.
POST /circle/keys/request {member_id} -> {queued, key} — the outbox asks
     explicitly (same throttle).
GET  /circle/keys/users?ids=1,2,3   -> {results: {"<uid>": key}} for group
     rosters (members of my groups / my contacts only).
"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import e2_keys
from .models import CircleGroupMember, CircleMember


def _edge(user, pk):
    try:
        pk = int(pk)
    except (TypeError, ValueError):
        return None
    return CircleMember.objects.filter(user=user, pk=pk).first()


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


class CirclePeerKeyView(APIView):
    def get(self, request, pk):
        edge = _edge(request.user, pk)
        if edge is None:
            return _nf()
        peer = e2_keys.edge_peer(edge)
        row = e2_keys.key_row(peer)
        out = e2_keys.key_dict(row, peer.id if peer is not None else None)
        out["requested"] = False
        if row is None and peer is not None and edge.state == "accepted":
            out["requested"] = e2_keys.request_key(request.user, peer)
            out["pending"] = True
        return Response(out)


class CircleKeyRequestView(APIView):
    def post(self, request):
        edge = _edge(request.user, (request.data or {}).get("member_id"))
        if edge is None:
            return _nf()
        peer = e2_keys.edge_peer(edge)
        row = e2_keys.key_row(peer)
        queued = False
        if row is None and peer is not None and edge.state == "accepted":
            queued = e2_keys.request_key(request.user, peer)
        return Response({"queued": queued,
                         "key": e2_keys.key_dict(
                             row, peer.id if peer is not None else None)})


class CircleUserKeysView(APIView):
    def get(self, request):
        raw = str(request.query_params.get("ids", ""))
        ids = []
        for p in raw.split(","):
            p = p.strip()
            if p.isdigit():
                ids.append(int(p))
        ids = ids[:256]
        me = request.user
        # Only people I share a group with, or my accepted contacts.
        gids = CircleGroupMember.objects.filter(
            member=me, status="active").values_list("group_id", flat=True)
        allowed = set(CircleGroupMember.objects.filter(
            group_id__in=list(gids), status="active", member_id__in=ids)
            .values_list("member_id", flat=True))
        allowed |= set(CircleMember.objects.filter(
            user=me, state="accepted", peer_user_id__in=ids)
            .values_list("peer_user_id", flat=True))
        rows = e2_keys.keys_for(list(allowed))
        out = {str(u): e2_keys.key_dict(rows.get(u), u) for u in allowed}
        return Response({"results": out})
