"""group-calls — My Circle group calls (owner order 17 Nov, design approved).

MESH on top of the 1:1 call stack (views_c2_calls): every pair of people in a
group call is one normal CallRecord ("leg") linked to a GroupCall room. So a
ring into a group call is a normal ring (FCM full-screen with the app closed,
in-app ring, missed call, decline, timeouts) and every leg uses the same
offer/answer/ICE relay (rt/send call.signal), TURN credentials and sweeps.
The record's CALLER sends the WebRTC offer for that leg (logic/group_call).

Rules (server-enforced):
  * at most 8 people in one call (ringing + joined) -> clear Bangla message;
  * only people in MY accepted circle can be added (a group-chat call rings
    the group's active members); a block in EITHER direction between the
    new person and ANYONE seated in the call refuses the add (neutral reason,
    so a block is never revealed);
  * audio group calls are free; a VIDEO group call needs the video plan of
    the person who starts it / adds someone to it (same rule as 1:1: the
    caller pays, joiners are free);
  * leaving ends only my legs; the call goes on; with one person left (and
    nobody ringing) the room ends; the last two simply keep their leg.

Endpoints (Token auth):
  GET  circle/group-calls/candidates[?room=<id>]   My Circle picker rows
  POST circle/group-calls {kind, group_id | from_call_id, user_ids?}
  GET  circle/group-calls/<room>                    snapshot for me
  POST circle/group-calls/<room>/invite {user_ids}
  POST circle/group-calls/<room>/join  {call_id?}   answer / late join / repair
  POST circle/group-calls/<room>/leave
  POST circle/group-calls/<room>/media {muted?, camera?}
  GET  circle/group-calls/group/<gid>               the "Join call" bar

Real-time events (rt/events): group.state {room_id} = re-fetch the snapshot;
group.leg {room_id, call_id, peer_id, offerer} = a new leg for me;
group.upgrade {room_id, call_id} = my 1:1 call became a group call.
"""
from __future__ import annotations

import logging

from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from . import push as PUSH
from . import views_c2_calls as C2
from .i18n import req_lang
from .logic import call_signal as CS
from .logic import circle_calls as CC
from .logic import group_call as GC
from .models import (CallRecord, CallSession, CircleGroup, CircleGroupMember,
                     CircleMember, GroupCall, GroupCallMember, RtEvent,
                     RtPresence, User)

log = logging.getLogger("assisto.groupcalls")

LEG_TAG = "gleg:"     # CallSession.client_call_id of a non-ring leg
LIVE_LEG = ("connecting", "active", "reconnecting")


def _pick(lang, bn, en):
    return en if lang == "en" else bn


def _err(lang, bn, en, status=400, code="", **extra):
    body = {"detail": _pick(lang, bn, en), "code": code}
    body.update(extra)
    return Response(body, status=status)


def _full(lang):
    return _err(lang, GC.FULL_BN, GC.FULL_EN, status=409, code="full",
                max=GC.MAX_PEOPLE)


# ---------------------------------------------------------------- rules
def blocked_between(a_id, b_id):
    """A block in EITHER direction between two users (edge.blocked or a
    'blocked' edge state)."""
    return CircleMember.objects.filter(
        Q(user_id=a_id, peer_user_id=b_id) | Q(user_id=b_id, peer_user_id=a_id)
    ).filter(Q(blocked=True) | Q(state="blocked")).exists()


def my_edge(me, user_id):
    """My accepted, unblocked circle edge to `user_id`, or None."""
    return CircleMember.objects.filter(
        user=me, peer_user_id=user_id, state="accepted", blocked=False
    ).order_by("-id").first()


def seated_ids(room):
    return list(room.members.filter(state__in=GC.SEAT_STATES)
                .values_list("user_id", flat=True))


def joined_ids(room):
    return list(room.members.filter(state="joined")
                .values_list("user_id", flat=True))


def _video_gate(user):
    try:
        from .views_build61 import _caller_dict
        return CC.can_place_call(_caller_dict(user, None), {"accepted": True},
                                 "video")
    except Exception:
        log.exception("group-calls video gate")
        return {"allowed": False, "reason": "error"}


def _video_refused(lang):
    return _err(lang, "ভিডিও গ্রুপ কলের জন্য প্রিমিয়াম লাগবে। অডিও গ্রুপ কল সবার জন্য ফ্রি।",
                "Group video calls need Premium. Group audio calls are free "
                "for everyone.", status=402, code="upgrade_required",
                upgrade_required=True, prompt=CC.upgrade_prompt(lang))


def _group_member_ids(group):
    return list(CircleGroupMember.objects.filter(group=group, status="active")
                .values_list("member_id", flat=True))


def _can_seat(room, user_id, via_group=False, me=None):
    """'' when `user_id` may take a seat in `room`, else a refusal code.
    via_group: a group-chat member (no circle edge needed)."""
    if room.group_id and via_group:
        if user_id not in _group_member_ids(room.group):
            return "not_member"
    elif me is not None and my_edge(me, user_id) is None:
        return "not_in_circle"
    for other in seated_ids(room):
        if other != user_id and blocked_between(other, user_id):
            return "unavailable"
    return ""


# ---------------------------------------------------------------- events
def _publish(room, topic, payload, user_ids=None):
    ids = user_ids if user_ids is not None else seated_ids(room)
    for uid in dict.fromkeys(ids):
        try:
            with transaction.atomic():
                RtEvent.objects.create(user_id=uid, topic=topic,
                                       payload=dict(payload, room_id=room.id))
        except Exception:
            log.exception("group-calls publish %s lost (user=%s)", topic, uid)


def _changed(room):
    _publish(room, "group.state", {"room_id": room.id})


def _latest_seq(user):
    return RtEvent.objects.filter(user=user).order_by("-id") \
        .values_list("id", flat=True).first() or 0


# ---------------------------------------------------------------- sync
def _live_legs(room, user_id=None):
    q = CallRecord.objects.filter(room=room, state__in=LIVE_LEG)
    if user_id is not None:
        q = q.filter(Q(caller_id=user_id) | Q(callee_id=user_id))
    return q


def end_room(room, now=None, by="server"):
    now = now or timezone.now()
    if room.state != "live":
        return room
    for r in CallRecord.objects.filter(room=room, state__in=CS.LIVE_STATES):
        C2.end_call(r, "canceled" if r.state == "ringing" else "hangup", by,
                    now)
    room.members.filter(state="ringing").update(state="missed")
    room.members.filter(state="joined").update(state="left", left_at=now)
    room.state = "ended"
    room.ended_at = now
    room.save(update_fields=["state", "ended_at"])
    _publish(room, "group.state", {"room_id": room.id, "ended": True},
             user_ids=list(room.members.values_list("user_id", flat=True)))
    return room


def sync(room, now=None):
    """Lazy bookkeeping (every endpoint runs it): seats follow their ring
    records, a joined phone that stopped polling has left, and the room
    ends when one person is left with nobody ringing."""
    now = now or timezone.now()
    if room.state != "live":
        return room
    changed = False
    for m in room.members.filter(state__in=GC.SEAT_STATES).select_related(
            "ring_call"):
        if m.state == "ringing":
            rc = m.ring_call
            if rc is not None:
                C2.sweep(rc, now)
                rc.refresh_from_db()
                reason = C2.session_of(rc).end_reason
                new = GC.member_state_for_ring(rc.state, reason)
            else:
                new = "missed"
            if new and new != m.state:
                m.state = new
                if new == "joined":
                    m.joined_at = now
                m.save(update_fields=["state", "joined_at"])
                changed = True
        elif m.state == "joined":
            p = RtPresence.objects.filter(user_id=m.user_id).first()
            stale = p is None or (now - p.seen_at).total_seconds() \
                > GC.MEMBER_STALE_S
            if stale and not _live_legs(room, m.user_id).exists() \
                    and m.joined_at and \
                    (now - m.joined_at).total_seconds() > GC.MEMBER_STALE_S:
                m.state = "left"
                m.left_at = now
                m.save(update_fields=["state", "left_at"])
                changed = True
    states = list(room.members.values_list("state", flat=True))
    if GC.room_should_end(states.count("joined"), states.count("ringing")):
        end_room(room, now)
    elif changed:
        _changed(room)
    return room


# ---------------------------------------------------------------- snapshot
def snapshot(room, me, request=None, lang="bn"):
    members = []
    for m in room.members.select_related("user"):
        u = m.user
        edge = CircleMember.objects.filter(user=me, peer_user=u).first() \
            if u.pk != me.pk else None
        name = ((edge.name if edge is not None else "") or
                PUSH.display_name(u)).strip()
        photo = C2.photo_of(u, request)
        members.append({
            "user_id": u.pk, "name": name, "state": m.state,
            "muted": m.muted, "camera": m.camera, "is_me": u.pk == me.pk,
            "host": u.pk == room.host_id,
            "photo_url": photo[0], "photo_v": photo[1],
        })
    legs = []
    for r in _live_legs(room, me.pk).order_by("id"):
        peer = r.callee_id if r.caller_id == me.pk else r.caller_id
        legs.append({"call_id": r.id, "peer_id": peer,
                     "offerer": GC.is_offerer(me.pk, r.caller_id),
                     "state": r.state})
    states = [m["state"] for m in members]
    people = max(2, GC.seats_taken(states))
    return {
        "room_id": room.id, "kind": room.kind, "state": room.state,
        "live": room.state == "live", "group_id": room.group_id,
        "group_name": room.group.name if room.group_id else "",
        "host_id": room.host_id, "max": GC.MAX_PEOPLE,
        "seats_taken": GC.seats_taken(states),
        "free": GC.free_seats(states),
        "members": members, "legs": legs,
        "video_kbps": GC.video_kbps(people),
        "data_mb_per_min": GC.data_mb_per_min(people, room.kind == "video"),
        "full_message": _pick(lang, GC.FULL_BN, GC.FULL_EN),
    }


def _room_for(me, pk, seated_only=True):
    room = GroupCall.objects.filter(pk=pk).first()
    if room is None:
        return None
    if seated_only and not room.members.filter(user=me).exists():
        return None
    return room


# ---------------------------------------------------------------- actions
def _ring(request, room, user_id, via_group):
    """Ring one person into `room` from request.user. Returns a result row."""
    me = request.user
    code = _can_seat(room, user_id, via_group=via_group, me=me)
    if code:
        return {"user_id": user_id, "ok": False, "code": code}
    peer = User.objects.filter(pk=user_id).first()
    if peer is None or peer.pk == me.pk:
        return {"user_id": user_id, "ok": False, "code": "not_found"}
    try:
        from .views_m1_messenger import call_prefs
        if not call_prefs(peer)["incoming_calls"]:
            return {"user_id": user_id, "ok": False, "code": "unavailable"}
    except Exception:
        pass
    edge = my_edge(me, user_id)
    body = C2.place_call(request, edge, peer, room.kind, room=room)
    rec = CallRecord.objects.filter(pk=body.get("call_id")).first()
    seat, _ = GroupCallMember.objects.get_or_create(
        room=room, user=peer, defaults={"invited_by": me})
    seat.invited_by = me
    seat.ring_call = rec
    seat.state = "ringing"
    seat.left_at = None
    seat.save(update_fields=["invited_by", "ring_call", "state", "left_at"])
    out = {"user_id": user_id, "ok": True, "call_id": rec.id if rec else None}
    if rec is not None and not CS.is_live(rec.state):
        out.update(ok=False, code=C2.session_of(rec).end_reason or "ended")
    return out


def invite(request, room, user_ids, via_group=False):
    """Ring every id (in order) while places are free."""
    ids = []
    for u in user_ids or []:
        try:
            ids.append(int(u))
        except (TypeError, ValueError):
            continue
    seated = set(seated_ids(room))
    results = [{"user_id": u, "ok": False, "code": "already"}
               for u in ids if u in seated]
    ids = [u for u in ids if u not in seated]
    states = list(room.members.values_list("state", flat=True))
    ring, full = GC.split_invites(ids, states)
    for uid in ring:
        results.append(_ring(request, room, uid, via_group))
    results += [{"user_id": u, "ok": False, "code": "full"} for u in full]
    sync(room)
    _changed(room)
    return results


def open_legs(room, me, now=None):
    """Make sure `me` has one live leg with every other joined person; `me`
    is the caller (offerer) of each new leg."""
    now = now or timezone.now()
    pairs = set()
    for r in _live_legs(room, me.pk):
        pairs.add(GC.pair_key(r.caller_id, r.callee_id))
    created = []
    for uid in GC.legs_needed(me.pk, joined_ids(room), pairs):
        if blocked_between(me.pk, uid):
            continue
        peer = User.objects.filter(pk=uid).first()
        if peer is None:
            continue
        rec = CallRecord.objects.create(
            caller=me, callee=peer, circle=my_edge(me, uid), kind=room.kind,
            state="connecting", answered_at=now, room=room)
        CallSession.objects.create(
            call=rec, ringing_at=now, caller_seen_at=now, callee_seen_at=now,
            client_call_id="%s%s" % (LEG_TAG, room.id))
        _publish(room, "group.leg",
                 {"call_id": rec.id, "peer_id": me.pk, "offerer": False},
                 user_ids=[uid])
        C2.nudge_call(rec, "group", to_user_id=uid)
        created.append(rec.id)
    return created


def join(room, me, call_id=None, now=None):
    """Answer my ring (if any) and take my seat; open my legs."""
    now = now or timezone.now()
    seat = room.members.filter(user=me).first()
    if seat is not None and seat.ring_call_id and seat.state == "ringing":
        rc = CallRecord.objects.select_for_update().get(pk=seat.ring_call_id)
        if rc.state == "ringing":
            C2.accept_call(rc, now)
    if call_id:
        rc = CallRecord.objects.filter(pk=call_id, callee=me, room=room,
                                       state="ringing").first()
        if rc is not None:
            C2.accept_call(rc, now)
    if seat is None:
        seat = GroupCallMember.objects.create(room=room, user=me,
                                              state="joined", joined_at=now)
    elif seat.state != "joined":
        seat.state = "joined"
        seat.joined_at = now
        seat.left_at = None
        seat.save(update_fields=["state", "joined_at", "left_at"])
    return open_legs(room, me, now)


def leave(room, me, now=None):
    now = now or timezone.now()
    for r in CallRecord.objects.filter(room=room, state__in=CS.LIVE_STATES) \
            .filter(Q(caller=me) | Q(callee=me)):
        side = C2.side_of(r, me)
        reason = CS.end_reason_for_event(r.state, "hangup", side == "caller")
        C2.end_call(r, reason or "hangup", side, now)
    room.members.filter(user=me).update(state="left", left_at=now)
    sync(room, now)
    if room.state == "live":
        _changed(room)
    return room


# ---------------------------------------------------------------- views
def _locked(room):
    return GroupCall.objects.select_for_update().get(pk=room.pk)


class GroupCallCandidatesView(APIView):
    """My Circle people I can add (accepted, unblocked both ways). Never
    lists a blocked person; with ?room= marks who is already in the call and
    hides anyone blocked with someone in it."""
    def get(self, request):
        me = request.user
        room = None
        rid = request.query_params.get("room")
        if rid:
            try:
                room = _room_for(me, int(rid))
            except (TypeError, ValueError):
                room = None
        seated = set(seated_ids(room)) if room is not None else set()
        out = []
        for e in CircleMember.objects.filter(
                user=me, state="accepted", blocked=False,
                peer_user__isnull=False).select_related("peer_user") \
                .order_by("name", "id"):
            uid = e.peer_user_id
            if uid == me.pk or blocked_between(me.pk, uid):
                continue
            if room is not None and any(
                    blocked_between(s, uid) for s in seated if s != uid):
                continue
            photo = C2.photo_of(e.peer_user, request)
            out.append({"member_id": e.id, "user_id": uid,
                        "name": (e.name or PUSH.display_name(e.peer_user)).strip(),
                        "relation": e.relation, "photo_url": photo[0],
                        "photo_v": photo[1], "in_call": uid in seated})
        return Response({"people": out, "max": GC.MAX_PEOPLE,
                         "free": GC.MAX_PEOPLE - len(seated) if room else
                         GC.MAX_PEOPLE - 1})


class GroupCallStartView(APIView):
    """POST {kind, group_id | from_call_id, user_ids?} -> 201 snapshot."""
    def post(self, request):
        me = request.user
        lang = req_lang(request)
        d = request.data or {}
        kind = CC.normalize_kind(d.get("kind", "voice"))
        now = timezone.now()
        seq = _latest_seq(me)
        from_call = d.get("from_call_id")
        group_id = d.get("group_id")
        with transaction.atomic():
            if from_call:
                rec = C2._call_for(me, from_call)
                if rec is None:
                    return _err(lang, "কলটি পাওয়া যায়নি।", "Call not found.",
                                status=404, code="not_found")
                C2.sweep(rec, now)
                if rec.state not in LIVE_LEG:
                    return _err(lang, "কলটি আর চলছে না।",
                                "This call is no longer running.",
                                status=410, code="call_ended")
                if rec.kind == "video" and d.get("user_ids"):
                    # adding someone to a VIDEO call: the adder's plan (checked
                    # before anything changes)
                    gate = _video_gate(me)
                    if not gate.get("allowed"):
                        return _video_refused(lang)
                room = rec.room if rec.room_id and rec.room.state == "live" \
                    else None
                if room is None:
                    room = GroupCall.objects.create(host=me, kind=rec.kind)
                    rec.room = room
                    rec.save(update_fields=["room"])
                    for uid in (rec.caller_id, rec.callee_id):
                        GroupCallMember.objects.get_or_create(
                            room=room, user_id=uid,
                            defaults={"state": "joined", "joined_at": now})
                    other = rec.callee_id if rec.caller_id == me.pk \
                        else rec.caller_id
                    _publish(room, "group.upgrade",
                             {"call_id": rec.id}, user_ids=[other])
                    C2.nudge_call(rec, "group", to_user_id=other)
                room = _locked(room)
                results = invite(request, room, d.get("user_ids"))
            elif group_id:
                try:
                    group = CircleGroup.objects.filter(pk=int(group_id)).first()
                except (TypeError, ValueError):
                    group = None
                if group is None or me.pk not in _group_member_ids(group):
                    return _err(lang, "গ্রুপটি পাওয়া যায়নি।", "Group not found.",
                                status=404, code="not_found")
                live = GroupCall.objects.filter(group=group, state="live") \
                    .order_by("-id").first()
                if live is not None:
                    sync(live, now)
                    if live.state == "live":
                        # a call is already on in this group: join it
                        live = _locked(live)
                        if GC.free_seats(list(live.members.exclude(
                                user=me).values_list("state", flat=True))) <= 0:
                            return _full(lang)
                        if _can_seat(live, me.pk, via_group=True):
                            return _err(lang, "এই কলে যোগ দেওয়া যাচ্ছে না।",
                                        "You can't join this call.",
                                        status=403, code="unavailable")
                        join(live, me, now=now)
                        _changed(live)
                        body = snapshot(live, me, request, lang)
                        body.update(seq=seq, joined_existing=True,
                                    ice=C2.ice_for(me), results=[])
                        return Response(body, status=201)
                if kind == "video":
                    gate = _video_gate(me)
                    if not gate.get("allowed"):
                        return _video_refused(lang)
                room = GroupCall.objects.create(host=me, kind=kind,
                                                group=group)
                GroupCallMember.objects.create(room=room, user=me,
                                               state="joined", joined_at=now)
                others = [u for u in _group_member_ids(group) if u != me.pk]
                results = invite(request, room, others, via_group=True)
            else:
                ids = d.get("user_ids") or []
                if not ids:
                    return _err(lang, "অন্তত একজনকে বাছুন।",
                                "Pick at least one person.", status=400,
                                code="no_people")
                if kind == "video":
                    gate = _video_gate(me)
                    if not gate.get("allowed"):
                        return _video_refused(lang)
                room = GroupCall.objects.create(host=me, kind=kind)
                GroupCallMember.objects.create(room=room, user=me,
                                               state="joined", joined_at=now)
                results = invite(request, room, ids)
        room.refresh_from_db()
        body = snapshot(room, me, request, lang)
        body.update(seq=seq, ice=C2.ice_for(me), results=results)
        return Response(body, status=201)


class GroupCallDetailView(APIView):
    def get(self, request, pk):
        me = request.user
        room = _room_for(me, pk)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        now = timezone.now()
        sync(room, now)
        room.refresh_from_db()
        for r in _live_legs(room, me.pk):
            C2._mark_seen(C2.session_of(r), C2.side_of(r, me), now)
        return Response(snapshot(room, me, request, req_lang(request)))


class GroupCallInviteView(APIView):
    def post(self, request, pk):
        me = request.user
        lang = req_lang(request)
        room = _room_for(me, pk)
        if room is None or not room.members.filter(user=me, state="joined") \
                .exists():
            return _err(lang, "আপনি এই কলে নেই।", "You are not in this call.",
                        status=404, code="not_found")
        sync(room)
        room.refresh_from_db()
        if room.state != "live":
            return _err(lang, "কলটি শেষ হয়ে গেছে।", "This call has ended.",
                        status=410, code="call_ended")
        ids = (request.data or {}).get("user_ids") or []
        if not ids:
            return _err(lang, "অন্তত একজনকে বাছুন।", "Pick at least one person.",
                        status=400, code="no_people")
        if GC.free_seats(list(room.members.values_list("state", flat=True))) <= 0:
            return _full(lang)
        if room.kind == "video":
            gate = _video_gate(me)
            if not gate.get("allowed"):
                return _video_refused(lang)
        with transaction.atomic():
            room = _locked(room)
            results = invite(request, room, ids)
        body = snapshot(room, me, request, lang)
        body["results"] = results
        if results and all(r.get("code") == "full" for r in results):
            body["detail"] = _pick(lang, GC.FULL_BN, GC.FULL_EN)
        return Response(body, status=200)


class GroupCallJoinView(APIView):
    """Answer a group ring, late-join a live call (seat or group member), or
    repair missing legs. 409 full, 403 when a block stands in the way."""
    def post(self, request, pk):
        me = request.user
        lang = req_lang(request)
        room = GroupCall.objects.filter(pk=pk).first()
        if room is None:
            return _err(lang, "কলটি পাওয়া যায়নি।", "Call not found.",
                        status=404, code="not_found")
        seq = _latest_seq(me)
        now = timezone.now()
        sync(room, now)
        room.refresh_from_db()
        if room.state != "live":
            return _err(lang, "কলটি শেষ হয়ে গেছে।", "This call has ended.",
                        status=410, code="call_ended")
        with transaction.atomic():
            room = _locked(room)
            seat = room.members.filter(user=me).first()
            if seat is None and not (room.group_id and me.pk in
                                     _group_member_ids(room.group)):
                return _err(lang, "কলটি পাওয়া যায়নি।", "Call not found.",
                            status=404, code="not_found")
            if seat is None or seat.state not in GC.SEAT_STATES:
                states = list(room.members.exclude(user=me)
                              .values_list("state", flat=True))
                if GC.free_seats(states) <= 0:
                    return _full(lang)
                for other in seated_ids(room):
                    if other != me.pk and blocked_between(other, me.pk):
                        return _err(lang, "এই কলে যোগ দেওয়া যাচ্ছে না।",
                                    "You can't join this call.", status=403,
                                    code="unavailable")
            join(room, me, (request.data or {}).get("call_id"), now)
        _changed(room)
        body = snapshot(room, me, request, lang)
        body.update(seq=seq, ice=C2.ice_for(me))
        return Response(body, status=200)


class GroupCallLeaveView(APIView):
    def post(self, request, pk):
        me = request.user
        room = _room_for(me, pk)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        with transaction.atomic():
            room = _locked(room)
            leave(room, me)
        room.refresh_from_db()
        return Response({"ok": True, "room_id": room.id,
                         "room_state": room.state})


class GroupCallMediaView(APIView):
    """POST {muted?, camera?} -> my tile's mic / camera icon for everyone."""
    def post(self, request, pk):
        me = request.user
        room = _room_for(me, pk)
        if room is None:
            return Response({"detail": "not found"}, status=404)
        d = request.data or {}
        upd = {}
        if "muted" in d:
            upd["muted"] = d.get("muted") in (True, "true", 1, "1")
        if "camera" in d:
            upd["camera"] = d.get("camera") in (True, "true", 1, "1")
        if upd:
            room.members.filter(user=me).update(**upd)
            _changed(room)
        return Response({"ok": True})


class GroupLiveCallView(APIView):
    """GET circle/group-calls/group/<gid> -> {call: snapshot-lite | null} for
    the group chat's "Join call" bar (active group members only)."""
    def get(self, request, gid):
        me = request.user
        group = CircleGroup.objects.filter(pk=gid).first()
        if group is None or me.pk not in _group_member_ids(group):
            return Response({"detail": "not found"}, status=404)
        room = GroupCall.objects.filter(group=group, state="live") \
            .order_by("-id").first()
        if room is not None:
            sync(room)
            room.refresh_from_db()
        if room is None or room.state != "live":
            return Response({"call": None})
        states = list(room.members.values_list("state", flat=True))
        mine = room.members.filter(user=me).values_list("state", flat=True) \
            .first()
        return Response({"call": {
            "room_id": room.id, "kind": room.kind,
            "joined": states.count("joined"), "ringing": states.count("ringing"),
            "free": GC.free_seats(states), "max": GC.MAX_PEOPLE,
            "my_state": mine or "", "started_at": room.created_at.isoformat(),
        }})
