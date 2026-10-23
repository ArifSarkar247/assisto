"""
b3-group — group voice/video calls (3+ people) on OUR self-hosted LiveKit SFU
(Apache-2.0, deploy/livekit/). 1:1 calls stay peer-to-peer (views_c2_calls).

The server never touches media. It decides WHO may join a room, mints the
LiveKit access token (minimal HS256 JWT, core.logic.sfu), rings invitees over
the existing real-time queue + FCM, runs host actions (mute / remove) through
LiveKit's RoomService API, keeps join/leave records, meters the SFU egress
for the P&L and holds the consented-recording state (B5, 1:1 and group).

Not configured (LIVEKIT_URL / _API_KEY / _API_SECRET empty, or the owner's
switch off) -> GET config says available=false and the app hides every
group-call entry; every other endpoint answers 503 code=sfu_unavailable.

Endpoints (Token auth unless noted):
  GET  circle/calls/group/config
  GET  circle/calls/group/incoming                 rooms ringing for me
  POST circle/calls/group/start {call_id | group_id, member_ids?, kind?}
  GET  circle/calls/group/<room>                   status (+ my heartbeat)
  POST circle/calls/group/<room>/token             LiveKit JWT (members only)
  POST circle/calls/group/<room>/event {event: ringing|joined|left|decline|media, video?}
  POST circle/calls/group/<room>/invite {member_ids}
  POST circle/calls/group/<room>/mute {user_id, kind: audio|video, track_sid?}   host
  POST circle/calls/group/<room>/remove {user_id}                                host
  POST circle/calls/group/<room>/record {action: request|accept|decline|stop}
  POST circle/calls/<id>/record {action}           1:1 consent (B5)
  POST livekit/webhook                             LiveKit -> us (JWT-signed)

Real-time events (topic "call.group", payload.room = room name):
  kind: state (participants changed) | record (consent changed) |
        muted (the host muted you) | removed (the host removed you) | ended
Ring: topic "call.group_incoming" + FCM kind "group_call".
1:1 upgrade: call.signal {kind:"sfu_move", data:{room, kind}} to the other
1:1 party (its CallController joins the room, then ends the P2P call).
"""
from __future__ import annotations

import json
import logging
import secrets
import urllib.request
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import push as PUSH
from .i18n import req_lang
from .logic import call_signal as CS
from .logic import circle_calls as CC
from .logic import sfu as SFU
from .models import (CallRecord, CircleGroup, CircleGroupMember, CircleMember,
                     GroupCallParticipant, GroupCallRoom, SfuConfig, User)

log = logging.getLogger("assisto.sfu")

RING_S = 60            # an invite rings at most this long
SEEN_S = 45            # a joined phone silent this long counts as left
MAX_INVITES = 64       # a group with more members rings the first 64


# ---------------------------------------------------------------- config
def configured():
    return bool(getattr(settings, "LIVEKIT_URL", "")
                and getattr(settings, "LIVEKIT_API_KEY", "")
                and getattr(settings, "LIVEKIT_API_SECRET", ""))


def cfg():
    try:
        return SfuConfig.load()
    except Exception:
        return SfuConfig(pk=1)


def available():
    try:
        return configured() and bool(cfg().enabled)
    except Exception:
        return False


def max_participants():
    return SFU.clamp_max(cfg().max_participants)


def bdt_per_gb():
    c = cfg()
    if c.egress_bdt_per_gb and c.egress_bdt_per_gb > 0:
        return float(c.egress_bdt_per_gb)
    usd = float(getattr(settings, "TURN_EGRESS_USD_PER_GB",
                        SFU.DEFAULT_EGRESS_USD_PER_GB))
    try:
        from .billing import cfg as _bcfg
        usd_bdt = float(_bcfg().get("usd_bdt") or 0) or 120.0
    except Exception:
        usd_bdt = 120.0
    return usd * usd_bdt


def _err(lang, bn, en, status=400, code="", **extra):
    body = {"detail": en if lang == "en" else bn, "code": code}
    body.update(extra)
    return Response(body, status=status)


def _unavailable(lang):
    return _err(lang, "গ্রুপ কল এখন চালু নেই।",
                "Group calls are not available right now.",
                status=503, code="sfu_unavailable")


# ---------------------------------------------------------------- LiveKit API
def _http_post(url, body, token, timeout=4):
    """POST JSON to LiveKit's Twirp RoomService. Patched in tests."""
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer %s" % token})
    with urllib.request.urlopen(req, timeout=timeout) as r:   # noqa: S310
        raw = r.read() or b"{}"
    try:
        return json.loads(raw)
    except ValueError:
        return {}


def room_service(method, room, body):
    """Call livekit.RoomService/<method>. Returns (ok, json)."""
    try:
        base = (getattr(settings, "LIVEKIT_HTTP_URL", "")
                or SFU.http_base(settings.LIVEKIT_URL)).rstrip("/")
        tok = SFU.admin_token(settings.LIVEKIT_API_KEY,
                              settings.LIVEKIT_API_SECRET, room,
                              timezone.now().timestamp())
        out = _http_post("%s/twirp/livekit.RoomService/%s" % (base, method),
                         body, tok)
        return True, out or {}
    except OSError as e:     # LiveKit down / unreachable: no traceback spam
        log.warning("sfu: RoomService/%s unreachable (room=%s): %s",
                    method, room, e)
        return False, {}
    except Exception:
        log.exception("sfu: RoomService/%s failed (room=%s)", method, room)
        return False, {}


def _track_sids(room, identity, kind):
    """Published track sids of `identity` of type audio|video (incl. screen)."""
    ok, out = room_service("ListParticipants", room, {"room": room})
    if not ok:
        return None
    # protojson writes enums as names and OMITS the default (AUDIO = 0)
    want = ("AUDIO", "0") if kind == "audio" else ("VIDEO", "1")
    for p in out.get("participants") or []:
        if str(p.get("identity")) != str(identity):
            continue
        return [t.get("sid") for t in (p.get("tracks") or [])
                if str(t.get("type", "AUDIO")).upper() in want and t.get("sid")]
    return []


# ---------------------------------------------------------------- helpers
def _room(name):
    return GroupCallRoom.objects.filter(name=str(name)[:40]).first()


def _seat(room, user):
    return GroupCallParticipant.objects.filter(room=room, user=user).first()


def _present_qs(room, now=None):
    now = now or timezone.now()
    return room.participants.filter(state="joined").filter(
        Q(seen_at__isnull=True) | Q(seen_at__gte=now - timedelta(seconds=SEEN_S)))


def present_ids(room, now=None):
    return list(_present_qs(room, now).values_list("user_id", flat=True))


def _tick(room, now):
    """Accumulate stream-seconds for the room shape since the last tick."""
    joined = room.participants.filter(state="joined")
    n = joined.count()
    v = joined.filter(video=True).count()
    if room.tick_at is not None:
        secs = (now - room.tick_at).total_seconds()
        room.audio_stream_s, room.video_stream_s = SFU.tick(
            room.audio_stream_s, room.video_stream_s, n, v, secs)
    room.tick_at = now
    room.peak_participants = max(room.peak_participants, n)


def _save_room(room, *fields):
    room.save(update_fields=list(fields) or None)


def _photo(user):
    try:
        from .views_c2_calls import photo_of
        return photo_of(user)
    except Exception:
        return "", ""


def participant_row(p):
    url, ver = _photo(p.user)
    return {"user_id": p.user_id, "name": PUSH.display_name(p.user),
            "photo": url, "photo_v": ver, "role": p.role, "state": p.state,
            "video": bool(p.video)}


def status_body(room, me, lang="bn"):
    seat = _seat(room, me)
    rows = [participant_row(p) for p in
            room.participants.select_related("user").order_by("invited_at", "id")]
    return {"room": room.name, "kind": room.kind, "state": room.state,
            "source": room.source, "call_id": room.call_id,
            "group_id": room.group_id,
            "group_name": room.group.name if room.group_id else "",
            "host_id": room.host_id, "is_host": room.host_id == me.id,
            "me": {"role": seat.role if seat else "",
                   "state": seat.state if seat else ""},
            "participants": rows,
            "present": len(present_ids(room)),
            "max_participants": room.max_participants,
            "recording": SFU.consent_view(room.recording, me.id),
            "server_time": timezone.now().isoformat()}


def publish_room(room, kind, extra=None, to_ids=None):
    """call.group to everyone in the room (or `to_ids`)."""
    from .views_c2_calls import rt_publish
    ids = to_ids if to_ids is not None else list(
        room.participants.exclude(state__in=("declined", "removed"))
        .values_list("user_id", flat=True))
    for uid in dict.fromkeys(ids):
        u = User.objects.filter(pk=uid).first()
        if u is None:
            continue
        payload = {"room": room.name, "kind": kind}
        if kind == "record":
            payload["recording"] = SFU.consent_view(room.recording, uid)
        payload.update(extra or {})
        rt_publish(u, "call.group", payload)


def _end_room(room, now, delete_remote=True):
    if room.state == "ended":
        return
    _tick(room, now)
    for p in room.participants.filter(state="joined"):
        _leave(p, now)
    room.state = "ended"
    room.ended_at = now
    if (room.recording or {}).get("status") in ("pending", "recording", "paused"):
        room.recording = SFU.consent_stop(room.recording, room.host_id,
                                          now.isoformat())
    room.save()
    publish_room(room, "ended")
    if delete_remote and configured():
        room_service("DeleteRoom", room.name, {"room": room.name})


def _leave(p, now):
    if p.state != "joined":
        return
    if p.joined_at:
        p.total_s += max(0, int((now - p.joined_at).total_seconds()))
    p.state = "left"
    p.left_at = now
    p.video = False
    p.save(update_fields=["total_s", "state", "left_at", "video"])


def sweep_room(room, now=None):
    """Lazy timeouts: joined phones silent > SEEN_S leave; a room nobody is
    in (after someone joined, or 2 min after creation) ends."""
    now = now or timezone.now()
    if room.state != "live":
        return room
    stale = room.participants.filter(
        state="joined", seen_at__lt=now - timedelta(seconds=SEEN_S))
    if stale.exists():
        _tick(room, now)
        for p in stale:
            _leave(p, now)
        _save_room(room, "audio_stream_s", "video_stream_s", "tick_at",
                   "peak_participants")
        _recheck_consent(room, now)
    joined = room.participants.filter(state="joined").count()
    ever = room.participants.filter(joins__gt=0).exists()
    if joined == 0 and (ever or (now - room.created_at).total_seconds() > 120):
        _end_room(room, now)
    return room


def _recheck_consent(room, now):
    st = room.recording or {}
    if (st.get("status") or "none") in ("none",) + SFU.CONSENT_TERMINAL:
        return
    new = SFU.consent_eval(st, present_ids(room, now), now.isoformat())
    if new.get("status") != st.get("status"):
        room.recording = new
        _save_room(room, "recording")
        publish_room(room, "record")


def _incoming_row(room, me):
    host = room.host
    url, ver = _photo(host)
    return {"room": room.name, "kind": room.kind, "video": room.kind == "video",
            "host_id": host.id, "host_name": PUSH.display_name(host),
            "host_photo": url, "host_photo_v": ver,
            "group_id": room.group_id,
            "group_name": room.group.name if room.group_id else "",
            "present": len(present_ids(room))}


def ring(room, user, inviter):
    """Ring one invitee: in-app (real-time queue) + FCM tray notification.
    Same rules as a 1:1 ring (blocked / call notifications off / silence
    unknown callers)."""
    from .views_c2_calls import ring_allowed, rt_publish
    try:
        if not ring_allowed(user, inviter):
            return False
        rt_publish(user, "call.group_incoming", _incoming_row(room, user))
        name = PUSH.display_name(inviter)
        video = room.kind == "video"
        gname = room.group.name if room.group_id else ""
        title_bn = "%s গ্রুপ কলে ডাকছেন" % name
        title_en = "%s invites you to a group call" % name
        body_bn = ("%s · " % gname if gname else "") + (
            "গ্রুপ ভিডিও কল" if video else "গ্রুপ ভয়েস কল")
        body_en = ("%s · " % gname if gname else "") + (
            "Group video call" if video else "Group voice call")
        PUSH.safe_push(user, "group_call", title_bn, title_en, body_bn, body_en,
                       data={"room": room.name, "host_id": inviter.id,
                             "host_name": name, "video": video,
                             "group_id": room.group_id or "",
                             "route": "circle/calls"},
                       high_priority=True)
        return True
    except Exception:
        log.exception("sfu: ring failed")
        return False


def _my_circle_users(me, member_ids):
    """Accepted My Circle peers of `me` for the given CircleMember ids
    (or user ids under key `user_ids`)."""
    out = []
    ids = [int(x) for x in (member_ids or []) if str(x).isdigit()][:MAX_INVITES]
    for e in CircleMember.objects.filter(user=me, pk__in=ids, state="accepted",
                                         blocked=False).select_related("peer_user"):
        if e.peer_user_id and e.peer_user_id != me.id:
            out.append(e.peer_user)
    return out


def _circle_users_by_user_id(me, user_ids):
    ids = [int(x) for x in (user_ids or []) if str(x).isdigit()][:MAX_INVITES]
    out = []
    for e in CircleMember.objects.filter(user=me, peer_user_id__in=ids,
                                         state="accepted", blocked=False
                                         ).select_related("peer_user"):
        out.append(e.peer_user)
    return out


def _seat_for(room, user, role="member", inviter=None, state="invited"):
    p, created = GroupCallParticipant.objects.get_or_create(
        room=room, user=user,
        defaults={"role": role, "state": state, "invited_by": inviter})
    if not created and p.state in ("left", "declined") and state == "invited":
        p.state = "invited"
        p.invited_by = inviter
        p.save(update_fields=["state", "invited_by"])
    return p, created


def _gate(user, kind, edge_rec=None, group=None):
    """Video gate (Premium unless "Free calls (testing)"); voice always ok.
    Returns (allowed, prompt)."""
    if kind != "video":
        return True, None
    from .calls_free import entitle
    from . import plans
    if edge_rec is not None:
        from .views_c2_calls import video_upgrade_gate
        g = video_upgrade_gate(edge_rec, user)
        return bool(g.get("allowed")), None
    from .logic import circle_groups as G
    initiator = entitle({"id": user.id, "plan": plans.effective_plan(user),
                         "video_unlocked": False, "role": "member"})
    g = G.can_place_group_call(initiator, "video")
    if g.get("allowed"):
        return True, None
    return False, G.group_call_upgrade_prompt("bn")


VIDEO_SOURCES = ["microphone", "camera", "screen_share", "screen_share_audio"]


def publish_sources(room, user):
    """What `user` may publish in `room` (LiveKit canPublishSources, so the
    SFU itself enforces it). A video room: everything (a free person may
    JOIN a video call, like accepting a 1:1 video call). A voice room: the
    mic, plus screen share only with the video entitlement (Premium, or
    "Free calls (testing)" ON)."""
    if room.kind == "video":
        return list(VIDEO_SOURCES)
    ok, _ = _gate(user, "video")
    return ["microphone", "screen_share", "screen_share_audio"] if ok \
        else ["microphone"]


def token_body(room, user, lang="bn"):
    now = timezone.now()
    seat = _seat(room, user)
    host = room.host_id == user.id
    sources = publish_sources(room, user)
    tok = SFU.access_token(
        settings.LIVEKIT_API_KEY, settings.LIVEKIT_API_SECRET,
        identity=str(user.id), name=PUSH.display_name(user), room=room.name,
        now_ts=now.timestamp(), host=host, sources=sources,
        metadata={"role": "host" if host else "member"})
    return {"url": settings.LIVEKIT_URL, "token": tok, "room": room.name,
            "identity": str(user.id), "host": host, "kind": room.kind,
            "ttl": SFU.TOKEN_TTL_S,
            "expires_at": (now + timedelta(seconds=SFU.TOKEN_TTL_S)).isoformat(),
            "max_participants": room.max_participants,
            "screen_share": "screen_share" in sources,
            "role": seat.role if seat else "member"}


# ---------------------------------------------------------------- views
class GroupConfigView(APIView):
    """GET circle/calls/group/config — the app shows group-call entries ONLY
    when available is true (no showpiece before the owner installs LiveKit)."""
    def get(self, request):
        ok = available()
        return Response({"available": ok,
                         "max_participants": max_participants() if ok else 0,
                         "screen_share": ok, "recording_consent": True})


class GroupIncomingView(APIView):
    """GET circle/calls/group/incoming — live rooms I was invited to (app
    open / resume, and after a tray-notification tap)."""
    def get(self, request):
        me = request.user
        if not available():
            return Response({"rooms": []})
        now = timezone.now()
        out = []
        for p in GroupCallParticipant.objects.filter(
                user=me, state="invited", room__state="live",
                invited_at__gte=now - timedelta(seconds=RING_S)
        ).exclude(room__host=me).exclude(invited_by=me).select_related(
                "room", "room__host", "room__group"):
            sweep_room(p.room, now)
            if p.room.state == "live":
                out.append(_incoming_row(p.room, me))
        return Response({"rooms": out})


class GroupStartView(APIView):
    """POST circle/calls/group/start
       {call_id, member_ids}   add people to a LIVE 1:1 call (both 1:1
                               phones move to the room; invitees ring)
       {group_id, kind}        a circle group's voice/video call
    """
    def post(self, request):
        lang = req_lang(request)
        if not available():
            return _unavailable(lang)
        me = request.user
        d = request.data or {}
        now = timezone.now()
        cap = max_participants()
        from .calls_free import calls_free
        call_id, group_id = d.get("call_id"), d.get("group_id")
        if call_id:
            from .views_c2_calls import _call_for, rt_publish, side_of, sweep
            rec = _call_for(me, call_id)
            if rec is None:
                return Response({"detail": "not found"}, status=404)
            sweep(rec, now)
            if rec.state not in ("active", "reconnecting"):
                return _err(lang, "কলটি এখন চলছে না।", "This call is not live.",
                            status=410, code="call_ended")
            invitees = _my_circle_users(me, d.get("member_ids")) + \
                _circle_users_by_user_id(me, d.get("user_ids"))
            other = rec.callee if rec.caller_id == me.id else rec.caller
            invitees = [u for u in dict((u.id, u) for u in invitees).values()
                        if u.id not in (me.id, other.id)]
            if not invitees:
                return _err(lang, "কাউকে বেছে নিন।", "Pick someone to add.",
                            status=422, code="no_invitees")
            if 2 + len(invitees) > cap:
                return _err(lang, "এত জনকে একসাথে যোগ করা যাবে না।",
                            "That is more people than a group call allows.",
                            status=409, code="too_many", max_participants=cap)
            ok, prompt = _gate(me, rec.kind, edge_rec=rec)
            if not ok:
                return _err(lang, "ভিডিও কলের জন্য প্রিমিয়াম লাগবে।",
                            "Video calling needs Premium.", status=402,
                            code="upgrade_required", upgrade_required=True,
                            prompt=CC.upgrade_prompt(lang))
            with transaction.atomic():
                room = GroupCallRoom.objects.create(
                    name="ac-" + secrets.token_hex(8), host=me, kind=rec.kind,
                    source="upgrade", call=rec, max_participants=cap,
                    free_testing=calls_free(), tick_at=now)
                _seat_for(room, me, role="host", state="invited")
                _seat_for(room, other, inviter=me)
                for u in invitees:
                    _seat_for(room, u, inviter=me)
            rt_publish(other, "call.signal",
                       {"call_id": rec.id, "kind": "sfu_move",
                        "from": side_of(rec, me),
                        "data": {"room": room.name, "kind": room.kind}})
            try:
                from .views_c2_calls import nudge_call
                nudge_call(rec, "sfu_move", to_user_id=other.id)
            except Exception:
                pass
            for u in invitees:
                ring(room, u, me)
        elif group_id:
            g = CircleGroup.objects.filter(pk=group_id).first()
            if g is None or not CircleGroupMember.objects.filter(
                    group=g, member=me, status="active").exists():
                return Response({"detail": "not found"}, status=404)
            kind = CC.normalize_kind(d.get("kind", "voice"))
            ok, prompt = _gate(me, kind, group=g)
            if not ok:
                return _err(lang, "গ্রুপ ভিডিও কলের জন্য প্রিমিয়াম লাগবে।",
                            "Starting a group video call needs Premium.",
                            status=402, code="upgrade_required",
                            upgrade_required=True, prompt=prompt)
            # one live room per group: a second "call" joins it
            room = GroupCallRoom.objects.filter(group=g, state="live").first()
            if room is not None:
                sweep_room(room, now)
            if room is None or room.state != "live":
                members = list(CircleGroupMember.objects.filter(
                    group=g, status="active").exclude(member=me)
                    .select_related("member")[:MAX_INVITES])
                with transaction.atomic():
                    room = GroupCallRoom.objects.create(
                        name="gc-" + secrets.token_hex(8), host=me, kind=kind,
                        source="group", group=g, max_participants=cap,
                        free_testing=calls_free(), tick_at=now)
                    _seat_for(room, me, role="host", state="invited")
                    for m in members:
                        _seat_for(room, m.member, inviter=me)
                for m in members:
                    ring(room, m.member, me)
            else:
                _seat_for(room, me, inviter=room.host)
        else:
            return _err(lang, "ভুল অনুরোধ।", "Say which call or group.",
                        status=422, code="bad_request")
        body = status_body(room, me, lang)
        body["join"] = token_body(room, me, lang)
        return Response(body, status=201)


class _RoomView(APIView):
    def _load(self, request, name, need_seat=True):
        lang = req_lang(request)
        if not available():
            return None, None, _unavailable(lang)
        room = _room(name)
        if room is None:
            return None, None, Response({"detail": "not found"}, status=404)
        seat = _seat(room, request.user)
        if seat is None and room.group_id and CircleGroupMember.objects.filter(
                group_id=room.group_id, member=request.user,
                status="active").exists() and room.state == "live":
            # a group member may join a live group call they were not rung for
            seat, _ = _seat_for(room, request.user, inviter=room.host)
        if need_seat and seat is None:
            return None, None, Response({"detail": "not found"}, status=404)
        return room, seat, None


class GroupStatusView(_RoomView):
    def get(self, request, room):
        room, seat, err = self._load(request, room)
        if err:
            return err
        now = timezone.now()
        if seat.state == "joined":
            seat.seen_at = now
            seat.save(update_fields=["seen_at"])
        sweep_room(room, now)
        return Response(status_body(room, request.user, req_lang(request)))


class GroupTokenView(_RoomView):
    """POST circle/calls/group/<room>/token — only people of THIS room (the
    1:1 parties being upgraded, invitees, or members of the circle group)."""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        now = timezone.now()
        sweep_room(room, now)
        if room.state != "live":
            return _err(lang, "এই গ্রুপ কল শেষ হয়ে গেছে।",
                        "This group call has ended.", status=410,
                        code="room_ended")
        if seat.state == "removed":
            return _err(lang, "আপনাকে এই কল থেকে সরানো হয়েছে।",
                        "You were removed from this call.", status=403,
                        code="removed")
        if seat.state != "joined" and len(present_ids(room, now)) >= room.max_participants:
            return _err(lang, "কলটি পূর্ণ।", "This call is full.", status=409,
                        code="room_full", max_participants=room.max_participants)
        return Response(token_body(room, request.user, lang))


def _join(room, seat, now):
    _tick(room, now)
    if seat.state != "joined":
        seat.state = "joined"
        seat.joined_at = now
        seat.joins += 1
    seat.seen_at = now
    seat.save(update_fields=["state", "joined_at", "joins", "seen_at"])
    _save_room(room, "audio_stream_s", "video_stream_s", "tick_at",
               "peak_participants")
    _tick(room, now)   # re-read the shape (peak) after the join
    _save_room(room, "peak_participants", "tick_at")


class GroupEventView(_RoomView):
    """POST circle/calls/group/<room>/event {event, video?}"""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        ev = str((request.data or {}).get("event") or "")
        now = timezone.now()
        with transaction.atomic():
            room = GroupCallRoom.objects.select_for_update().get(pk=room.pk)
            seat.refresh_from_db()
            if ev == "joined":
                if room.state != "live":
                    return _err(lang, "এই গ্রুপ কল শেষ হয়ে গেছে।",
                                "This group call has ended.", status=410,
                                code="room_ended")
                if seat.state == "removed":
                    return Response({"detail": "removed", "code": "removed"},
                                    status=403)
                _join(room, seat, now)
                if room.source == "upgrade" and room.call_id:
                    # the 1:1 call that grew into this room is over for both
                    from .views_c2_calls import end_call
                    rec = CallRecord.objects.filter(pk=room.call_id).first()
                    if rec is not None and CS.is_live(rec.state):
                        end_call(rec, "hangup", "server", now)
            elif ev == "left":
                _tick(room, now)
                _leave(seat, now)
                _save_room(room, "audio_stream_s", "video_stream_s", "tick_at",
                           "peak_participants")
            elif ev == "decline":
                if seat.state == "invited":
                    seat.state = "declined"
                    seat.save(update_fields=["state"])
            elif ev == "media":
                v = bool((request.data or {}).get("video"))
                if seat.state == "joined" and seat.video != v:
                    _tick(room, now)
                    seat.video = v
                    seat.save(update_fields=["video"])
                    _save_room(room, "audio_stream_s", "video_stream_s",
                               "tick_at", "peak_participants")
            elif ev == "ringing":
                pass
            else:
                return _err(lang, "অজানা ঘটনা।", "Unknown event.", status=422,
                            code="bad_event")
        if ev in ("joined", "left"):
            _recheck_consent(room, now)
        if ev in ("joined", "left", "decline", "media"):
            publish_room(room, "state")
        sweep_room(room, now)
        return Response(status_body(room, request.user, lang))


class GroupInviteView(_RoomView):
    """POST circle/calls/group/<room>/invite {member_ids} — anyone IN the
    call may add their own accepted My Circle contacts (or, in a group call,
    members of that group)."""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        if room.state != "live" or seat.state != "joined":
            return _err(lang, "আগে কলে যোগ দিন।", "Join the call first.",
                        status=409, code="not_in_call")
        d = request.data or {}
        users = _my_circle_users(request.user, d.get("member_ids")) + \
            _circle_users_by_user_id(request.user, d.get("user_ids"))
        if room.group_id:
            ids = [int(x) for x in (d.get("user_ids") or []) if str(x).isdigit()]
            users += [m.member for m in CircleGroupMember.objects.filter(
                group_id=room.group_id, status="active", member_id__in=ids)
                .select_related("member")]
        users = [u for u in dict((u.id, u) for u in users).values()
                 if u.id != request.user.id]
        seated = set(room.participants.exclude(state__in=("left", "declined"))
                     .values_list("user_id", flat=True))
        new = [u for u in users if u.id not in seated]
        if not new:
            return _err(lang, "কাউকে বেছে নিন।", "Pick someone to add.",
                        status=422, code="no_invitees")
        if len(seated) + len(new) > room.max_participants:
            return _err(lang, "এত জনকে একসাথে যোগ করা যাবে না।",
                        "That is more people than a group call allows.",
                        status=409, code="too_many",
                        max_participants=room.max_participants)
        for u in new:
            _seat_for(room, u, inviter=request.user)
            ring(room, u, request.user)
        publish_room(room, "state")
        return Response(status_body(room, request.user, lang), status=201)


class GroupMuteView(_RoomView):
    """POST circle/calls/group/<room>/mute {user_id, kind, track_sid?} — HOST
    only. LiveKit RoomService MutePublishedTrack (a host can mute, never
    unmute: the person unmutes themselves)."""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        if room.host_id != request.user.id:
            return _err(lang, "শুধু হোস্ট এটি করতে পারেন।",
                        "Only the host can do this.", status=403,
                        code="host_only")
        d = request.data or {}
        target = _seat(room, User.objects.filter(pk=d.get("user_id") or 0).first())
        if target is None or target.state != "joined" or target.user_id == request.user.id:
            return Response({"detail": "not found"}, status=404)
        kind = "video" if d.get("kind") == "video" else "audio"
        sids = [d["track_sid"]] if d.get("track_sid") else _track_sids(
            room.name, target.user_id, kind)
        if sids is None:
            return _err(lang, "গ্রুপ কল সার্ভারে পৌঁছানো যাচ্ছে না।",
                        "Couldn't reach the group call server.", status=502,
                        code="sfu_error")
        for sid in sids:
            ok, _ = room_service("MutePublishedTrack", room.name, {
                "room": room.name, "identity": str(target.user_id),
                "track_sid": sid, "muted": True})
            if not ok:
                return _err(lang, "গ্রুপ কল সার্ভারে পৌঁছানো যাচ্ছে না।",
                            "Couldn't reach the group call server.",
                            status=502, code="sfu_error")
        publish_room(room, "muted", {"by": request.user.id, "media": kind},
                     to_ids=[target.user_id])
        return Response({"ok": True, "muted": len(sids)})


class GroupRemoveView(_RoomView):
    """POST circle/calls/group/<room>/remove {user_id} — HOST only."""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        if room.host_id != request.user.id:
            return _err(lang, "শুধু হোস্ট এটি করতে পারেন।",
                        "Only the host can do this.", status=403,
                        code="host_only")
        target = _seat(room, User.objects.filter(
            pk=(request.data or {}).get("user_id") or 0).first())
        if target is None or target.user_id == request.user.id:
            return Response({"detail": "not found"}, status=404)
        now = timezone.now()
        ok = True
        if target.state == "joined":
            ok, _ = room_service("RemoveParticipant", room.name, {
                "room": room.name, "identity": str(target.user_id)})
        with transaction.atomic():
            _tick(room, now)
            _leave(target, now)
            target.state = "removed"
            target.save(update_fields=["state"])
            _save_room(room, "audio_stream_s", "video_stream_s", "tick_at",
                       "peak_participants")
        publish_room(room, "removed", {"by": request.user.id},
                     to_ids=[target.user_id])
        publish_room(room, "state")
        _recheck_consent(room, now)
        return Response({"ok": True, "sfu": ok})


def _consent_action(state, action, user_id, present, now_iso, request_id):
    if action == "request":
        if (state or {}).get("status") in ("pending", "recording", "paused"):
            return state, "already"
        return SFU.consent_new(user_id, request_id, present, now_iso), "ok"
    if action == "accept":
        return SFU.consent_accept(state, user_id, present, now_iso), "ok"
    if action == "decline":
        return SFU.consent_decline(state, user_id, now_iso), "ok"
    if action == "stop":
        return SFU.consent_stop(state, user_id, now_iso), "ok"
    return state, "bad_action"


class GroupRecordView(_RoomView):
    """POST circle/calls/group/<room>/record {action} — B5 consent."""
    def post(self, request, room):
        lang = req_lang(request)
        room, seat, err = self._load(request, room)
        if err:
            return err
        if room.state != "live" or seat.state != "joined":
            return _err(lang, "আগে কলে যোগ দিন।", "Join the call first.",
                        status=409, code="not_in_call")
        action = str((request.data or {}).get("action") or "")
        now = timezone.now()
        with transaction.atomic():
            room = GroupCallRoom.objects.select_for_update().get(pk=room.pk)
            if action == "request":
                room.record_seq += 1
            new, verdict = _consent_action(
                room.recording, action, request.user.id,
                present_ids(room, now), now.isoformat(), room.record_seq)
            if verdict == "bad_action":
                return _err(lang, "ভুল অনুরোধ।", "Unknown action.", status=422,
                            code="bad_action")
            if verdict == "already":
                return _err(lang, "রেকর্ডিংয়ের অনুরোধ আগেই চলছে।",
                            "A recording request is already open.",
                            status=409, code="already")
            room.recording = new
            room.save(update_fields=["recording", "record_seq"])
        publish_room(room, "record")
        return Response({"recording": SFU.consent_view(room.recording,
                                                       request.user.id)})


class CallRecordView(APIView):
    """POST circle/calls/<id>/record {action} — B5 consent for a 1:1 call.
    The other person gets call.signal {kind:"record_state"}."""
    def post(self, request, call_id):
        from .models import CallSession
        from .views_c2_calls import _call_for, rt_publish, session_of, sweep
        lang = req_lang(request)
        rec = _call_for(request.user, call_id)
        if rec is None:
            return Response({"detail": "not found"}, status=404)
        sweep(rec)
        if rec.state not in ("active", "reconnecting"):
            return _err(lang, "কলটি এখন চলছে না।", "This call is not live.",
                        status=410, code="call_ended")
        action = str((request.data or {}).get("action") or "")
        now = timezone.now()
        with transaction.atomic():
            sess = CallSession.objects.select_for_update().get(
                pk=session_of(rec).pk)
            seq = int((sess.recording or {}).get("id") or 0) + (
                1 if action == "request" else 0)
            new, verdict = _consent_action(
                sess.recording, action, request.user.id,
                [rec.caller_id, rec.callee_id], now.isoformat(), seq)
            if verdict == "bad_action":
                return _err(lang, "ভুল অনুরোধ।", "Unknown action.", status=422,
                            code="bad_action")
            if verdict == "already":
                return _err(lang, "রেকর্ডিংয়ের অনুরোধ আগেই চলছে।",
                            "A recording request is already open.",
                            status=409, code="already")
            sess.recording = new
            sess.save(update_fields=["recording"])
        for uid, side in ((rec.caller_id, "caller"), (rec.callee_id, "callee")):
            u = User.objects.filter(pk=uid).first()
            if u is not None and uid != request.user.id:
                rt_publish(u, "call.signal", {
                    "call_id": rec.id, "kind": "record_state",
                    "from": "server",
                    "data": SFU.consent_view(new, uid)})
        return Response({"recording": SFU.consent_view(new, request.user.id)})


class LiveKitWebhookView(APIView):
    """POST livekit/webhook — LiveKit's own join/leave/track events (signed
    with the API secret: Authorization = JWT with the body's sha256). Keeps
    join/leave + cost metering right even when a phone dies silently."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        if not configured():
            return Response({"ok": False}, status=503)
        body = request.body or b""
        auth = request.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            auth = auth[7:]
        try:
            claims = SFU.jwt_decode(auth, settings.LIVEKIT_API_SECRET,
                                    now_ts=timezone.now().timestamp())
        except SFU.TokenError:
            return Response({"ok": False}, status=401)
        if claims.get("iss") != settings.LIVEKIT_API_KEY or \
                not SFU.webhook_body_ok(claims, body):
            return Response({"ok": False}, status=401)
        try:
            ev = json.loads(body or b"{}")
        except ValueError:
            return Response({"ok": False}, status=400)
        name = ((ev.get("room") or {}).get("name") or "")
        room = _room(name)
        if room is None:
            return Response({"ok": True, "ignored": True})
        kind = ev.get("event") or ""
        ident = str((ev.get("participant") or {}).get("identity") or "")
        now = timezone.now()
        seat = GroupCallParticipant.objects.filter(
            room=room, user_id=int(ident)).first() if ident.isdigit() else None
        with transaction.atomic():
            room = GroupCallRoom.objects.select_for_update().get(pk=room.pk)
            if kind == "participant_joined" and seat is not None and \
                    seat.state not in ("removed",) and room.state == "live":
                _join(room, seat, now)
            elif kind == "participant_left" and seat is not None:
                _tick(room, now)
                _leave(seat, now)
                _save_room(room, "audio_stream_s", "video_stream_s", "tick_at",
                           "peak_participants")
            elif kind in ("track_published", "track_unpublished") and \
                    seat is not None and seat.state == "joined":
                t = ev.get("track") or {}
                if str(t.get("type", "")).upper() == "VIDEO":
                    _tick(room, now)
                    seat.video = kind == "track_published"
                    seat.save(update_fields=["video"])
                    _save_room(room, "audio_stream_s", "video_stream_s",
                               "tick_at", "peak_participants")
            elif kind == "room_finished":
                _end_room(room, now, delete_remote=False)
        if kind in ("participant_joined", "participant_left"):
            _recheck_consent(room, now)
            publish_room(room, "state")
        return Response({"ok": True})


# ---------------------------------------------------------------- P&L
def sfu_cost(days=30, now=None):
    """SFU egress cost (estimate from stream-seconds x bitrate) for the P&L
    and Owner Admin -> Call relay. Free-calls (testing) rooms split out."""
    now = now or timezone.now()
    since = now - timedelta(days=days)
    c = cfg()
    price = bdt_per_gb()
    rows = GroupCallRoom.objects.filter(created_at__gte=since)
    tot = {"rooms": 0, "participant_min": 0.0, "gb": 0.0, "bdt": 0.0,
           "free_bdt": 0.0, "voice_rooms": 0, "video_rooms": 0}
    from django.db.models import Sum
    for r in rows:
        b = SFU.egress_bytes(r.audio_stream_s, r.video_stream_s,
                             c.audio_kbps, c.video_kbps)
        bdt = SFU.bdt_for_bytes(b, price)
        tot["rooms"] += 1
        tot["voice_rooms" if r.kind != "video" else "video_rooms"] += 1
        tot["gb"] += b / SFU.GIB
        tot["bdt"] += bdt
        if r.free_testing:
            tot["free_bdt"] += bdt
    secs = GroupCallParticipant.objects.filter(
        room__created_at__gte=since).aggregate(s=Sum("total_s"))["s"] or 0
    tot["participant_min"] = round(secs / 60.0, 1)
    for k in ("gb", "bdt", "free_bdt"):
        tot[k] = round(tot[k], 3 if k == "gb" else 2)
    tot.update({
        "configured": configured(), "enabled": bool(c.enabled),
        "audio_kbps": c.audio_kbps, "video_kbps": c.video_kbps,
        "bdt_per_gb": round(price, 2), "max_participants": max_participants(),
        "estimate": True,
        "bdt_per_min_voice_3": round(SFU.per_participant_minute_bdt(
            3, False, c.audio_kbps, c.video_kbps, price), 4),
        "bdt_per_min_video_3": round(SFU.per_participant_minute_bdt(
            3, True, c.audio_kbps, c.video_kbps, price), 4),
        "bdt_per_min_video_8": round(SFU.per_participant_minute_bdt(
            8, True, c.audio_kbps, c.video_kbps, price), 4),
    })
    return tot
