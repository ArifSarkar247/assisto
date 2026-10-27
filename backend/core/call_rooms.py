"""
callsB — GROUP calls (up to 4 people) on the current mesh.

The server keeps the ROSTER (CallRoom / CallRoomMember) and creates one PAIR
link (a normal CallRecord + CallSession, wrapped by CallRoomLink) for every
two joined people. Everything a pair needs already exists for 1:1 calls and
is reused unchanged:

  * signalling: rt/send call.signal {call_id, kind, data} is relayed to the
    OTHER party of that record only -> signalling is routed per pair;
  * ringing an added person: views_c2_calls.place_call (call.incoming on the
    real-time queue + the FCM ring push + native acks) -> the added person
    gets the NORMAL incoming ring everywhere, exactly like a 1:1 call;
  * the state machine, timeouts, "connected"/"relayed" reports and the
    duration -> relay minutes in the P&L (turn_monitor.relay_cost counts
    every relayed CallRecord, so a 3-person relayed call counts 3 pairs).

Pair link kinds (CallRoomLink.via):
  base  the 1:1 call the group grew out of
  ring  inviter -> invitee (rang like a 1:1 call; inviter = offerer)
  mesh  created silently when someone joins, caller = the joiner (offerer);
        never rings, never shows in the call history.

Every phone in the room gets `call.roster` on the real-time queue whenever
the roster changes (payload = the roster as THAT phone sees it, including
its own pair links). 1:1 calls never touch any of this: the hooks in
views_c2_calls return after one indexed lookup when a record has no room.
"""
from __future__ import annotations

import logging
from datetime import timedelta

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .logic import call_rooms as R
from .logic import call_signal as CS

log = logging.getLogger("assisto.rt")


# ------------------------------------------------------------------ lookups
def link_of(rec):
    from .models import CallRoomLink
    if rec is None:
        return None
    try:
        return CallRoomLink.objects.select_related("room").filter(call=rec).first()
    except Exception:
        return None


def room_of_call(rec):
    link = link_of(rec)
    return link.room if link is not None else None


def member_of(room, user_or_id):
    from .models import CallRoomMember
    uid = getattr(user_or_id, "pk", user_or_id)
    return CallRoomMember.objects.filter(room=room, user_id=uid).first()


def live_room_of_group(group):
    from .models import CallRoom
    if group is None:
        return None
    room = CallRoom.objects.filter(group=group, state="live").order_by("-id").first()
    if room is not None:
        sweep_room(room)
        room.refresh_from_db()
        if room.state != "live":
            return None
    return room


def _states(room):
    return list(room.members.values_list("state", flat=True))


def live_links_of(room, user_id):
    from .models import CallRecord
    return CallRecord.objects.filter(
        room_link__room=room, state__in=CS.LIVE_STATES).filter(
        Q(caller_id=user_id) | Q(callee_id=user_id))


# ------------------------------------------------------------------ roster
def _edge_photo(viewer, user, request=None):
    from .views_c2_calls import photo_of
    return photo_of(user, request)


def roster(room, viewer, request=None):
    """The room as `viewer` sees it (names = the viewer's nicknames)."""
    from . import push as PUSH
    members = []
    rows = list(room.members.select_related("user").order_by("invited_at", "id"))
    from .models import CircleMember
    edges = dict(CircleMember.objects.filter(
        user=viewer, peer_user_id__in=[m.user_id for m in rows])
        .values_list("peer_user_id", "id"))
    for m in rows:
        photo, ver = _edge_photo(viewer, m.user, request)
        members.append({
            "user_id": m.user_id,
            "name": (PUSH.seen_name(viewer, m.user) if m.user_id != viewer.id
                     else PUSH.display_name(m.user)),
            "photo_url": photo, "photo_v": ver,
            "state": m.state, "me": m.user_id == viewer.id,
            "muted": m.muted, "camera": m.camera, "screen": m.screen,
            "invited_by": m.invited_by_id,
            # the viewer's own My Circle id for this person (add sheet / chat)
            "member_id": edges.get(m.user_id),
            "joined_at": m.joined_at.isoformat() if m.joined_at else None,
        })
    links = []
    from .models import CallRecord
    recs = CallRecord.objects.filter(room_link__room=room).filter(
        Q(caller_id=viewer.id) | Q(callee_id=viewer.id)).select_related(
        "room_link", "session").order_by("id")
    for r in recs:
        if not CS.is_live(r.state):
            continue
        mine_caller = r.caller_id == viewer.id
        try:
            sess = r.session
            ph = CS.phase(r.state, sess.ringing_at, getattr(sess, "delivered_at", None))
        except Exception:
            ph = CS.phase(r.state)
        links.append({
            "call_id": r.id, "via": r.room_link.via,
            "peer_user_id": r.callee_id if mine_caller else r.caller_id,
            "role": "caller" if mine_caller else "callee",
            "state": r.state, "phase": ph,
        })
    states = [m.state for m in rows]
    me = next((m for m in rows if m.user_id == viewer.id), None)
    joined = sum(1 for s in states if s == "joined")
    return {
        "room_id": room.id, "kind": room.kind, "state": room.state,
        "group_id": room.group_id,
        "group_name": room.group.name if room.group_id else "",
        "host_id": room.host_id,
        "base_call_id": room.base_call_id,
        "max": room.max_participants,
        "active": R.active_count(states), "joined": joined,
        "my_state": me.state if me is not None else "",
        "can_add": (room.state == "live" and me is not None
                    and me.state == "joined"
                    and R.has_seat(states, room.max_participants)),
        "low_bandwidth": R.low_bandwidth(R.active_count(states)),
        "members": members, "links": links,
        "server_time": timezone.now().isoformat(),
    }


def publish_roster(room):
    """call.roster to every phone on the roster (each its own view)."""
    from .views_c2_calls import rt_publish
    for m in room.members.select_related("user"):
        try:
            rt_publish(m.user, "call.roster", roster(room, m.user))
        except Exception:
            log.exception("callsB: publish_roster (room=%s user=%s)",
                          room.pk, m.user_id)


# ------------------------------------------------------------------ create
def ensure_room_for_call(rec, by_user):
    """The room a live 1:1 call belongs to; created on the first "Add
    person" (both people joined, the call = the base link)."""
    from .models import CallRoom, CallRoomLink, CallRoomMember
    room = room_of_call(rec)
    if room is not None:
        return room
    now = timezone.now()
    room = CallRoom.objects.create(host=by_user, base_call=rec, kind=rec.kind)
    CallRoomLink.objects.create(room=room, call=rec, via="base")
    for uid in dict.fromkeys([rec.caller_id, rec.callee_id]):
        CallRoomMember.objects.create(room=room, user_id=uid, state="joined",
                                      call=rec, joined_at=now)
    return room


def create_group_room(group, host, kind):
    from .models import CallRoom, CallRoomMember
    room = CallRoom.objects.create(host=host, group=group, kind=kind)
    CallRoomMember.objects.create(room=room, user=host, state="joined",
                                  joined_at=timezone.now())
    return room


def _mesh_record(room, caller_id, callee_id, now):
    from .calls_free import calls_free
    from .models import CallRecord, CallRoomLink, CallSession, CircleMember
    edge = CircleMember.objects.filter(user_id=caller_id,
                                       peer_user_id=callee_id).first()
    rec = CallRecord.objects.create(
        caller_id=caller_id, callee_id=callee_id, circle=edge, kind=room.kind,
        state="connecting", answered_at=now, free_testing=calls_free())
    CallSession.objects.create(call=rec, ringing_at=now, caller_seen_at=now,
                               callee_seen_at=now)
    CallRoomLink.objects.create(room=room, call=rec, via="mesh")
    return rec


def _link_mesh(room, user_id, now):
    """Pair links from a new participant to every joined person."""
    joined = list(room.members.filter(state="joined")
                  .values_list("user_id", flat=True))
    linked = set()
    for r in live_links_of(room, user_id):
        linked.add(r.callee_id if r.caller_id == user_id else r.caller_id)
    for a, b in R.mesh_pairs(user_id, joined, linked):
        _mesh_record(room, a, b, now)


# ------------------------------------------------------------------ invite
def recent_invites(inviter, room=None, now=None):
    """Rings this person started into group calls recently (each add-person
    = one ring record): in `room` in the last minute, else in any room in
    the last 10 minutes."""
    from .models import CallRoomLink
    now = now or timezone.now()
    q = CallRoomLink.objects.filter(via="ring", call__caller=inviter)
    if room is not None:
        return q.filter(room=room, created_at__gte=now - timedelta(seconds=60)).count()
    return q.filter(created_at__gte=now - timedelta(minutes=10)).count()


def invite(request, room, edge, peer):
    """Ring `peer` (the inviter's accepted My Circle contact `edge`) into the
    room with the NORMAL 1:1 ring path. Returns (verdict, body)."""
    from .models import CallRoomLink, CallRoomMember
    from . import views_c2_calls as C2
    me = request.user
    now = timezone.now()
    mine = member_of(room, me)
    target = member_of(room, peer) if peer is not None else None
    verdict = R.invite_verdict(
        inviter_joined=mine is not None and mine.state == "joined",
        room_live=room.state == "live", states=_states(room),
        target_state=target.state if target is not None else "",
        accepted_contact=(edge is not None and edge.state == "accepted"
                          and peer is not None and peer.pk != me.pk),
        blocked=bool(edge is not None and edge.blocked) or _blocked_by(peer, me),
        cap=room.max_participants,
        recent_room_invites=recent_invites(me, room, now),
        recent_invites=recent_invites(me, None, now))
    if verdict != "ok":
        return verdict, {}
    body = C2.place_call(request, edge, peer, room.kind)
    rec_id = body.get("call_id")
    from .models import CallRecord
    rec = CallRecord.objects.filter(pk=rec_id).first() if rec_id else None
    if rec is None:
        return "failed", body
    if target is None:
        target = CallRoomMember(room=room, user=peer)
    target.invited_by = me
    target.invited_at = now
    target.call = rec
    target.left_at = None
    if CS.is_live(rec.state):
        target.state = "ringing" if rec.state == "ringing" else "joined"
    else:
        target.state = R.ring_outcome(C2.history_reason(rec) or rec.state)
    target.save()
    CallRoomLink.objects.get_or_create(call=rec, defaults={"room": room,
                                                           "via": "ring"})
    if target.state == "joined":
        # glare: they were calling me at that moment -> already accepted
        target.joined_at = now
        target.save(update_fields=["joined_at"])
        _link_mesh(room, peer.pk, now)
    publish_roster(room)
    return "ok", body


def _blocked_by(peer, me):
    """The person I want to add blocked me (never revealed: neutral)."""
    if peer is None:
        return False
    try:
        from . import push as PUSH
        edge = PUSH._reverse_edge(peer, me)
        if edge is not None and edge.blocked:
            return True
        from .views_m1_messenger import call_prefs
        return not call_prefs(peer)["incoming_calls"]
    except Exception:
        return False


# ------------------------------------------------------------------ join/leave
def may_join(room, user):
    """On the roster already (any state), or an active member of the room's
    group chat."""
    if member_of(room, user) is not None:
        return True
    if room.group_id:
        from .models import CircleGroupMember
        return CircleGroupMember.objects.filter(
            group_id=room.group_id, member=user, status="active").exists()
    return False


def join(room, user):
    """Join the ongoing call (from the chat). Returns the verdict."""
    from .models import CallRoomMember
    now = timezone.now()
    with transaction.atomic():
        mine = member_of(room, user)
        verdict = R.join_verdict(
            room_live=room.state == "live",
            my_state=mine.state if mine is not None else "",
            allowed=may_join(room, user), states=_states(room),
            cap=room.max_participants)
        if verdict != "ok":
            return verdict
        if mine is None:
            mine = CallRoomMember(room=room, user=user)
        if mine.state == "ringing" and mine.call_id:
            # joining from the chat while it rings: the ring stops (joined)
            try:
                from . import views_c2_calls as C2
                rec = mine.call
                if rec is not None and rec.state == "ringing":
                    C2.end_call(rec, "canceled", "server", notify=False)
            except Exception:
                log.exception("callsB: join stop ring")
        mine.state = "joined"
        mine.joined_at = now
        mine.left_at = None
        mine.save()
        _link_mesh(room, user.pk, now)
    publish_roster(room)
    return "ok"


def leave(room, user, reason="hangup"):
    """Leave the call: my pair links end (the others' tiles go), the room
    ends when nobody is left to talk to."""
    from . import views_c2_calls as C2
    now = timezone.now()
    mine = member_of(room, user)
    if mine is not None and mine.state in R.ACTIVE_STATES:
        mine.state = "left"
        mine.left_at = now
        mine.save(update_fields=["state", "left_at"])
    for rec in list(live_links_of(room, user.pk)):
        side = "caller" if rec.caller_id == user.pk else "callee"
        try:
            C2.end_call(rec, CS.end_reason_for_event(
                rec.state, reason, side == "caller") or "hangup", side, now)
        except Exception:
            log.exception("callsB: leave end link %s", rec.pk)
    maybe_end_room(room)
    publish_roster(room)


def set_media(room, user, data):
    m = member_of(room, user)
    if m is None:
        return False
    upd = []
    for f in ("muted", "camera", "screen"):
        if f in data:
            setattr(m, f, data.get(f) in (True, "true", 1, "1"))
            upd.append(f)
    if upd:
        m.save(update_fields=upd)
        publish_roster(room)
    return True


def maybe_end_room(room, now=None):
    if room.state != "live":
        return False
    if not R.should_end(_states(room)):
        return False
    from . import views_c2_calls as C2
    now = now or timezone.now()
    room.state = "ended"
    room.ended_at = now
    room.save(update_fields=["state", "ended_at"])
    from .models import CallRecord
    for rec in CallRecord.objects.filter(room_link__room=room,
                                         state__in=CS.LIVE_STATES):
        try:
            C2.end_call(rec, "canceled" if rec.state == "ringing" else "hangup",
                        "server", now)
        except Exception:
            log.exception("callsB: end room link %s", rec.pk)
    room.members.filter(state__in=R.ACTIVE_STATES).update(
        state="left", left_at=now)
    return True


def sweep_room(room, now=None):
    """Lazy: a room whose phones all went silent ends (links are swept by
    the normal 1:1 timeouts; this only closes the roster)."""
    from . import views_c2_calls as C2
    if room.state != "live":
        return
    from .models import CallRecord
    for rec in CallRecord.objects.filter(room_link__room=room,
                                         state__in=CS.LIVE_STATES):
        C2.sweep(rec, now)


# ------------------------------------------------------------------ hooks
def on_record_accepted(rec):
    """views_c2_calls.accept_call: an invitee answered the ring -> joined,
    pair links to everyone else in the call. Never raises."""
    try:
        link = link_of(rec)
        if link is None or link.via != "ring":
            return
        room = link.room
        if room.state != "live":
            return
        m = member_of(room, rec.callee_id)
        if m is None or m.state == "joined":
            return
        now = timezone.now()
        m.state = "joined"
        m.joined_at = now
        m.save(update_fields=["state", "joined_at"])
        _link_mesh(room, rec.callee_id, now)
        publish_roster(room)
    except Exception:
        log.exception("callsB: on_record_accepted %s", getattr(rec, "pk", None))


def on_record_ended(rec, reason):
    """views_c2_calls.end_call: a pair link ended. A ring that never got
    answered updates the invitee's roster state; a person with no live link
    left is treated as gone; the room ends when nobody is left. Never
    raises; a record without a room returns after one lookup."""
    try:
        link = link_of(rec)
        if link is None:
            return
        room = link.room
        if room.state != "live":
            return
        now = timezone.now()
        if link.via == "ring":
            m = member_of(room, rec.callee_id)
            if m is not None and m.state == "ringing" and m.call_id == rec.id:
                m.state = R.ring_outcome(reason)
                m.save(update_fields=["state"])
        for uid in dict.fromkeys([rec.caller_id, rec.callee_id]):
            m = member_of(room, uid)
            if (m is not None and m.state == "joined"
                    and not live_links_of(room, uid).exists()):
                m.state = "left"
                m.left_at = now
                m.save(update_fields=["state", "left_at"])
        maybe_end_room(room, now)
        publish_roster(room)
    except Exception:
        log.exception("callsB: on_record_ended %s", getattr(rec, "pk", None))
