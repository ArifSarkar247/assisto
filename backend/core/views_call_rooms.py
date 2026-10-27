"""
callsB — GROUP call endpoints (mesh, max 4). Logic: core/call_rooms.py +
core/logic/call_rooms.py. Token auth (DRF default).

  POST circle/calls/<call_id>/add {member_id}   add a My Circle contact to
       the call I am in (rings them like a normal call; creates the room on
       the first add). 403 not_contact / not_in_call, 409 already_in / full,
       410 ended, 429 rate_limited, 402 upgrade_required (video plan gate).
  GET  circle/calls/<call_id>/room              the room this call is in
       (404 when it is a plain 1:1 call)
  GET  circle/rooms/<room_id>                   roster (members + my links)
  POST circle/rooms/<room_id>/join              join the ongoing call
  POST circle/rooms/<room_id>/leave             leave it
  POST circle/rooms/<room_id>/media {muted?, camera?, screen?}
  POST circle/groups/<gid>/call/start {kind, user_ids:[...]}  start a group
       call from the group chat (rings up to 3 members who are my accepted
       contacts); an ongoing call of the group is returned instead
  GET  circle/groups/<gid>/call/active          {"room": roster|null} — the
       group chat's "Join call" banner
"""
from __future__ import annotations

from django.db import transaction
from rest_framework.response import Response
from rest_framework.views import APIView

from . import call_rooms as CR
from .i18n import req_lang
from .logic import call_rooms as R
from .logic import call_signal as CS
from .logic import circle_calls as CC
from .models import (CallRecord, CallRoom, CircleGroup, CircleGroupMember,
                     CircleMember)

_MSG = {
    "not_in_call": (403, "আপনি এই কলে নেই।", "You are not in this call."),
    "ended": (410, "কলটি শেষ হয়ে গেছে।", "This call has ended."),
    "not_contact": (403, "শুধু আমার সার্কেলের গৃহীত কন্টাক্ট যোগ করা যায়।",
                    "Only accepted My Circle contacts can be added."),
    "blocked": (403, "এই মুহূর্তে তাঁকে যোগ করা যাচ্ছে না।",
                "This person can't be added right now."),
    "already_in": (409, "তিনি আগে থেকেই কলে আছেন।", "They are already in the call."),
    "full": (409, "একটি কলে সর্বোচ্চ ৪ জন থাকতে পারেন।",
             "A call can have at most 4 people."),
    "rate_limited": (429, "অল্প সময়ে অনেক জনকে ডাকা হয়েছে। একটু পরে আবার চেষ্টা করুন।",
                     "Too many invites in a short time. Try again in a minute."),
    "forbidden": (403, "আপনি এই কলে যোগ দিতে পারবেন না।", "You can't join this call."),
    "failed": (503, "এখন কল করা যাচ্ছে না। আবার চেষ্টা করুন।",
               "Couldn't ring them right now. Please try again."),
    "no_one": (409, "কাউকে কল করা গেল না।", "Couldn't ring anyone."),
}


def _refuse(lang, code, **extra):
    st, bn, en = _MSG.get(code, (400, "অনুরোধটি সম্ভব নয়।", "Not possible."))
    body = {"detail": en if lang == "en" else bn, "code": code}
    body.update(extra)
    return Response(body, status=st)


def _my_call(user, call_id):
    from django.db.models import Q
    return CallRecord.objects.filter(pk=call_id).filter(
        Q(caller=user) | Q(callee=user)).first()


def _room_for(user, room_id):
    room = CallRoom.objects.filter(pk=room_id).first()
    if room is None or not CR.may_join(room, user):
        return None
    return room


def _video_gate(user, edge, kind):
    if kind != "video":
        return {"allowed": True}
    from .views_build61 import _callee_dict, _caller_dict
    return CC.can_place_call(_caller_dict(user, edge), _callee_dict(edge), kind)


class AddPersonView(APIView):
    def post(self, request, call_id):
        lang = req_lang(request)
        me = request.user
        rec = _my_call(me, call_id)
        if rec is None:
            return Response({"detail": "not found"}, status=404)
        from . import views_c2_calls as C2
        C2.sweep(rec)
        room = CR.room_of_call(rec)
        if room is None and rec.state not in ("active", "reconnecting"):
            # "during a call": only a connected call can grow into a group
            return _refuse(lang, "ended" if not CS.is_live(rec.state)
                           else "not_in_call")
        try:
            mid = int((request.data or {}).get("member_id") or 0)
        except (TypeError, ValueError):
            mid = 0
        edge = CircleMember.objects.filter(user=me, pk=mid).first()
        if edge is None:
            return _refuse(lang, "not_contact")
        from . import push as PUSH
        peer = PUSH.member_peer_user(edge)
        kind = room.kind if room is not None else rec.kind
        gate = _video_gate(me, edge, kind)
        if not gate.get("allowed"):
            return Response({"detail": CC.pick(
                lang, "ভিডিও কলের জন্য প্রিমিয়াম লাগবে।",
                "Video calling needs Premium."), "code": "upgrade_required",
                "upgrade_required": True, "prompt": CC.upgrade_prompt(lang)},
                status=402)
        with transaction.atomic():
            room = CR.ensure_room_for_call(rec, me)
            verdict, body = CR.invite(request, room, edge, peer)
        if verdict != "ok":
            if room.base_call_id == rec.id and room.members.count() <= 2 \
                    and not room.links.exclude(via="base").exists():
                # nobody was added: keep the plain 1:1 call (no empty room)
                room.delete()
                return _refuse(lang, verdict)
            return _refuse(lang, verdict, room=CR.roster(room, me, request))
        out = CR.roster(room, me, request)
        out["invited"] = {"user_id": peer.pk, "call_id": body.get("call_id"),
                          "phase": body.get("phase"),
                          "end_reason": body.get("end_reason", "")}
        return Response(out, status=201)


class CallRoomOfCallView(APIView):
    def get(self, request, call_id):
        rec = _my_call(request.user, call_id)
        room = CR.room_of_call(rec) if rec is not None else None
        if room is None:
            return Response({"detail": "not found", "room": None}, status=404)
        return Response(CR.roster(room, request.user, request))


class RoomView(APIView):
    def get(self, request, room_id):
        room = _room_for(request.user, room_id)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        CR.sweep_room(room)
        room.refresh_from_db()
        return Response(CR.roster(room, request.user, request))


class RoomJoinView(APIView):
    def post(self, request, room_id):
        lang = req_lang(request)
        room = _room_for(request.user, room_id)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        CR.sweep_room(room)
        room.refresh_from_db()
        if room.kind == "video":
            # joining a group VIDEO call: the same plan gate as starting one
            from .views_build61 import _caller_dict
            gate = CC.can_place_call(_caller_dict(request.user, None),
                                     {"accepted": True, "blocked": False},
                                     "video")
            if not gate.get("allowed"):
                return Response({"detail": CC.pick(
                    lang, "ভিডিও কলের জন্য প্রিমিয়াম লাগবে।",
                    "Video calling needs Premium."),
                    "code": "upgrade_required", "upgrade_required": True,
                    "prompt": CC.upgrade_prompt(lang)}, status=402)
        verdict = CR.join(room, request.user)
        if verdict not in ("ok", "joined"):
            return _refuse(lang, verdict)
        room.refresh_from_db()
        from . import views_c2_calls as C2
        out = CR.roster(room, request.user, request)
        out["ice"] = C2.ice_for(request.user)
        return Response(out, status=200)


class RoomLeaveView(APIView):
    def post(self, request, room_id):
        room = _room_for(request.user, room_id)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        CR.leave(room, request.user)
        room.refresh_from_db()
        return Response(CR.roster(room, request.user, request))


class RoomMediaView(APIView):
    def post(self, request, room_id):
        room = _room_for(request.user, room_id)
        if room is None or not CR.set_media(room, request.user, request.data or {}):
            return Response({"detail": "not found"}, status=404)
        return Response({"ok": True})


def _group_and_me(request, gid):
    g = CircleGroup.objects.filter(pk=gid).first()
    if g is None:
        return None, None
    mine = CircleGroupMember.objects.filter(group=g, member=request.user,
                                            status="active").first()
    return (g, mine) if mine is not None else (None, None)


class GroupCallStartView(APIView):
    def post(self, request, gid):
        lang = req_lang(request)
        g, mine = _group_and_me(request, gid)
        if g is None:
            return Response({"detail": "not found"}, status=404)
        live = CR.live_room_of_group(g)
        if live is not None:
            out = CR.roster(live, request.user, request)
            out["existing"] = True
            return Response(out, status=200)
        d = request.data or {}
        kind = CC.normalize_kind(d.get("kind", "voice"))
        from . import plans
        from .calls_free import entitle
        from .logic import circle_groups as G
        gate = G.can_place_group_call(entitle({
            "id": request.user.id, "plan": plans.effective_plan(request.user),
            "video_unlocked": False, "role": mine.role}), kind)
        if not gate["allowed"]:
            body = {"allowed": False, "kind": kind,
                    "upgrade_required": gate.get("upgrade_required", False),
                    "reason": gate.get("reason")}
            if gate.get("upgrade_required"):
                body["prompt"] = G.group_call_upgrade_prompt(lang)
            return Response(body, status=200)
        ids = []
        for raw in (d.get("user_ids") or []):
            try:
                uid = int(raw)
            except (TypeError, ValueError):
                continue
            if uid != request.user.id and uid not in ids:
                ids.append(uid)
        ids = ids[:R.MAX_PARTICIPANTS - 1]
        members = set(CircleGroupMember.objects.filter(
            group=g, status="active", member_id__in=ids)
            .values_list("member_id", flat=True))
        from . import push as PUSH
        with transaction.atomic():
            room = CR.create_group_room(g, request.user, kind)
            outcomes = {}
            for uid in ids:
                if uid not in members:
                    outcomes[uid] = "not_member"
                    continue
                edge = CircleMember.objects.filter(
                    user=request.user, peer_user_id=uid).first()
                peer = PUSH.member_peer_user(edge) if edge is not None else None
                verdict, body = CR.invite(request, room, edge, peer)
                outcomes[uid] = verdict
        room.refresh_from_db()
        if not room.members.filter(state="ringing").exists() \
                and not room.members.exclude(user=request.user).filter(
                    state="joined").exists():
            CR.maybe_end_room(room)
            return _refuse(lang, "no_one", outcomes=outcomes)
        out = CR.roster(room, request.user, request)
        out["outcomes"] = outcomes
        return Response(out, status=201)


class GroupCallActiveView(APIView):
    def get(self, request, gid):
        g, _ = _group_and_me(request, gid)
        if g is None:
            return Response({"detail": "not found"}, status=404)
        room = CR.live_room_of_group(g)
        # who "Start group call" can ring: active members who are my
        # ACCEPTED My Circle contacts (the others can tap Join call)
        ids = CircleGroupMember.objects.filter(group=g, status="active") \
            .exclude(member=request.user).values_list("member_id", flat=True)
        ringable = sorted(CircleMember.objects.filter(
            user=request.user, state="accepted", blocked=False,
            peer_user_id__in=list(ids)).values_list("peer_user_id", flat=True))
        return Response({"room": CR.roster(room, request.user, request)
                         if room is not None else None,
                         "ringable": ringable,
                         "max": R.MAX_PARTICIPANTS})
