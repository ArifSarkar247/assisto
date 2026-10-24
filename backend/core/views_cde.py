"""cde-chat (order 6 D + E) — the server copy of a chat's theme + nicknames.

GET  /circle/decor/member/<edge id>
POST /circle/decor/member/<edge id>  {theme: id} | {nick: {who: peer|me, name}}
GET  /circle/decor/group/<group id>
POST /circle/decor/group/<group id>  {theme: id} | {nick: {user_id, name}}

Answers carry `at_ms` (server time of the write) — the phone puts the SAME
stamp in the E2E control message it sends next, so every phone applies the
newest change. A locked (Premium) theme is refused with 402 + reason
`premium_required`; the phone shows the plans sheet. See core/chat_decor.py.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import chat_decor as CD
from .i18n import pick, req_lang
from .models import CircleGroup, CircleMember

_MSG = {
    "premium_required": ("এই থিমটি প্রিমিয়ামে পাওয়া যায়।",
                         "This theme is part of Premium."),
    "unknown_theme": ("এই থিমটি পাওয়া যায়নি।", "That theme was not found."),
    "not_found": ("চ্যাটটি পাওয়া যায়নি।", "Chat not found."),
    "not_accepted": ("সার্কেলের অনুরোধ গ্রহণের পর থিম ও ডাকনাম দেওয়া যায়।",
                     "Themes and nicknames work once the request is accepted."),
    "bad_target": ("এই মানুষটি এই চ্যাটে নেই।", "That person isn't in this chat."),
    "bad_request": ("অনুরোধটি বোঝা যায়নি।", "That request wasn't understood."),
}


def _err(request, reason, status=400):
    bn, en = _MSG.get(reason, _MSG["bad_request"])
    return Response({"ok": False, "reason": reason,
                     "detail": pick(req_lang(request), bn, en)}, status=status)


def _member_payload(row, edge, peer, me):
    return {
        "ok": True,
        "theme": CD.theme_block(row, me),
        "nick_peer": CD.nick_of(row, peer.pk),
        "nick_me": CD.nick_of(row, me.pk),
        "nick_at": {"peer": CD.nick_at(row, peer.pk), "me": CD.nick_at(row, me.pk)},
        **CD.catalog(me),
    }


class DecorMemberView(APIView):
    def _edge(self, request, pk):
        return CircleMember.objects.filter(user=request.user, pk=pk).first()

    def get(self, request, pk):
        edge = self._edge(request, pk)
        if edge is None:
            return _err(request, "not_found", 404)
        row, peer = CD.member_row(edge)
        if peer is None:
            return _err(request, "not_found", 404)
        return Response(_member_payload(row, edge, peer, request.user))

    def post(self, request, pk):
        edge = self._edge(request, pk)
        if edge is None:
            return _err(request, "not_found", 404)
        if (edge.state or "accepted") != "accepted" or getattr(edge, "blocked", False):
            return _err(request, "not_accepted", 403)
        row, peer = CD.member_row(edge, create=True)
        if peer is None or row is None:
            return _err(request, "not_found", 404)
        d = request.data or {}
        try:
            if "theme" in d:
                at = CD.set_theme(row, request.user, str(d.get("theme") or "classic"))
            elif isinstance(d.get("nick"), dict):
                who = str(d["nick"].get("who") or "")
                if who not in ("peer", "me"):
                    return _err(request, "bad_target")
                target = peer.pk if who == "peer" else request.user.pk
                _, at = CD.set_nick(row, request.user, target, d["nick"].get("name"))
            else:
                return _err(request, "bad_request")
        except CD.DecorError as e:
            return _err(request, e.reason, e.status)
        out = _member_payload(row, edge, peer, request.user)
        out["at_ms"] = CD.ms(at)
        return Response(out)


def _group_payload(row, group, me):
    from .models import CircleGroupMember
    uids = list(CircleGroupMember.objects.filter(
        group=group, status="active").values_list("member_id", flat=True))
    return {
        "ok": True,
        "theme": CD.theme_block(row, me),
        "nicknames": {str(u): CD.nick_of(row, u) for u in uids if CD.nick_of(row, u)},
        "nick_at": {str(u): CD.nick_at(row, u) for u in uids if CD.nick_at(row, u)},
        **CD.catalog(me),
    }


class DecorGroupView(APIView):
    def _group(self, request, pk):
        from .views_m2 import _my_membership
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return None
        return g

    def get(self, request, pk):
        g = self._group(request, pk)
        if g is None:
            return _err(request, "not_found", 404)
        return Response(_group_payload(CD.group_row(g), g, request.user))

    def post(self, request, pk):
        from .models import CircleGroupMember
        g = self._group(request, pk)
        if g is None:
            return _err(request, "not_found", 404)
        row = CD.group_row(g, create=True)
        d = request.data or {}
        try:
            if "theme" in d:
                at = CD.set_theme(row, request.user, str(d.get("theme") or "classic"))
            elif isinstance(d.get("nick"), dict):
                try:
                    uid = int(d["nick"].get("user_id"))
                except (TypeError, ValueError):
                    return _err(request, "bad_target")
                if not CircleGroupMember.objects.filter(
                        group=g, member_id=uid, status="active").exists():
                    return _err(request, "bad_target")
                _, at = CD.set_nick(row, request.user, uid, d["nick"].get("name"))
            else:
                return _err(request, "bad_request")
        except CD.DecorError as e:
            return _err(request, e.reason, e.status)
        out = _group_payload(row, g, request.user)
        out["at_ms"] = CD.ms(at)
        return Response(out)
