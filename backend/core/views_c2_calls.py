"""
c2-calls — REAL 1:1 voice/video call signalling for My Circle.

Media is peer-to-peer WebRTC (or relayed by our coturn at turn.lifeassisto.com
with time-limited REST credentials); the server only:
  * places the call (video plan gate stays in views_build61 + circle_calls),
  * decides BUSY / OFFLINE up front, rings the callee by FCM data push,
  * relays SDP offer/answer + ICE candidates with sequence numbers,
  * runs the state machine ringing -> accepted -> connected -> ended with
    honest end reasons (logic in core/logic/call_signal.py),
  * writes the call log + a missed-call push.

Transport: gunicorn sync workers, no Django Channels -> ONE real-time
event queue (RtEvent, one row per recipient, id = sequence number) read by
SHORT polling: GET rt/events?after=<seq> answers at once (never held open, so
polls cannot starve the 3 workers). Phones poll ~0.5 s while a call is being
set up / typing is shown, ~2.5 s otherwise, slower in background. The same
queue carries call.* (this module), presence.* and typing.* (c3-msg adds
those producers via register_producer). WebSocket upgrade path:
.phaseB/proposals/c2-calls.md.

Event envelope (what a phone receives):
  {"seq": <int>, "topic": "call.signal" | "call.state" | "call.incoming" |
   "presence.*" | "typing.*", "payload": {...}, "ts": "<iso8601>"}

Endpoints (Token auth):
  GET  rt/events?after=N[&topics=call,typing]  my events after N + presence
  POST rt/send {topic, payload}                 dispatched by RT_PRODUCERS
  GET  circle/calls/incoming                    ringing calls for me
  GET  circle/calls/<id>                        status of one call (sweeps)
  POST circle/calls/<id>/event {event, relayed?}  ringing | answer | decline
       | busy | cancel | hangup | fail | connected | reconnect | timeout
  POST rt/send {topic:"call.signal", payload:{call_id, kind, data}}
       kind: offer | answer | ice | restart_offer | restart_answer | media
"""
from __future__ import annotations

import json
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from . import push as PUSH
from .i18n import req_lang
from .logic import call_signal as CS
from .logic import circle_calls as CC
from .models import (CallRecord, CallSession, CircleMember, Device, RtEvent,
                     RtPresence)

STUN_FALLBACK = [{"urls": ["stun:stun.l.google.com:19302"]}]


# ---------------------------------------------------------------- helpers
def ice_for(user):
    """ICE servers for a call: our coturn (STUN + TURN, time-limited HMAC
    credentials) when configured, else public STUN only (P2P may then fail
    on strict NATs — the phone shows an honest error)."""
    secret = getattr(settings, "TURN_STATIC_SECRET", "")
    host = getattr(settings, "TURN_HOST", "")
    if secret and host:
        from .logic import rtc as RTC
        creds = RTC.turn_credentials(secret, user.id, timezone.now().timestamp())
        return {"iceServers": RTC.ice_servers(
            host, getattr(settings, "TURN_PORT", 3478), creds),
            "turn": True, "ttl": creds["ttl"]}
    return {"iceServers": STUN_FALLBACK, "turn": False, "ttl": 0}


def session_of(rec):
    try:
        return rec.session
    except CallSession.DoesNotExist:
        return CallSession.objects.get_or_create(call=rec)[0]


def side_of(rec, user):
    if rec.caller_id == user.id:
        return "caller"
    if rec.callee_id == user.id:
        return "callee"
    return None


def _call_for(user, call_id):
    rec = CallRecord.objects.filter(pk=call_id).filter(
        Q(caller=user) | Q(callee=user)).first()
    return rec


def touch_presence(user, now=None):
    """Mark the phone as reachable. At most one write per 10 s per user (the
    app polls every 0.5–5 s)."""
    now = now or timezone.now()
    try:
        n = RtPresence.objects.filter(
            user=user, seen_at__lt=now - timedelta(seconds=10)
        ).update(seen_at=now)
        if not n and not RtPresence.objects.filter(user=user).exists():
            RtPresence.objects.create(user=user, seen_at=now)
    except Exception:
        pass


def is_reachable(user, now=None):
    """Can this phone ring right now? FCM device registered (and push live)
    OR the app polled for calls a moment ago."""
    now = now or timezone.now()
    try:
        if PUSH.is_available() and Device.objects.filter(
                user=user).exclude(push_token="").exists():
            return True
    except Exception:
        pass
    p = RtPresence.objects.filter(user=user).first()
    return bool(p and CS.is_presence_fresh(p.seen_at, now))


def is_busy(user, exclude_id=None, now=None):
    """Is `user` in another live call (after sweeping stale ones)?"""
    now = now or timezone.now()
    live = CallRecord.objects.filter(
        Q(caller=user) | Q(callee=user), state__in=CS.LIVE_STATES,
        started_at__gte=now - timedelta(seconds=CS.BUSY_WINDOW_S))
    if exclude_id:
        live = live.exclude(pk=exclude_id)
    for r in live:
        sweep(r, now)
        if CS.is_live(r.state) and r.caller_id != r.callee_id:
            return True
    return False


def hook_missed_call(rec, reason):
    """'Missed call from X' on the callee's phones (data-only; the app draws a
    quiet notification). Never raises."""
    try:
        if rec.callee_id == rec.caller_id:
            return False
        caller = rec.caller
        name = PUSH.display_name(caller)
        edge = PUSH._reverse_edge(rec.callee, caller)
        video = rec.kind == "video"
        return PUSH.safe_push(
            rec.callee, "missed_call",
            "%s-এর মিসড কল" % name, "Missed call from %s" % name,
            "ভিডিও কল" if video else "ভয়েস কল",
            "Video call" if video else "Voice call",
            data={"call_id": rec.id, "caller_id": caller.id,
                  "caller_name": name, "video": video, "reason": reason,
                  "chat_id": edge.id if edge is not None else "",
                  "route": "circle/calls"})
    except Exception:
        return False


def end_call(rec, reason, by="server", now=None, sess=None):
    """Move a live record to its terminal state for `reason` (idempotent)."""
    now = now or timezone.now()
    if not CS.is_live(rec.state):
        return rec
    sess = sess or session_of(rec)
    was_ringing = rec.state == "ringing"
    rec.state = CS.state_for_reason(reason)
    rec.ended_at = now
    rec.duration_sec = CS.duration_sec(sess.connected_at, now) \
        if sess.connected_at else 0
    rec.save(update_fields=["state", "ended_at", "duration_sec"])
    sess.end_reason = reason
    sess.ended_by = by
    upd = ["end_reason", "ended_by"]
    if reason in CS.MISSED_REASONS and not sess.missed_notified:
        sess.missed_notified = True
        upd.append("missed_notified")
        notify_missed = True
    else:
        notify_missed = False
    sess.save(update_fields=upd)
    publish_state(rec)
    if was_ringing:
        # stop the callee's ring on every device (FCM, key-gated)
        PUSH.hook_call_cancel(rec, rec.state if reason == "canceled" else reason)
    if notify_missed:
        hook_missed_call(rec, reason)
    return rec


def sweep(rec, now=None):
    now = now or timezone.now()
    if not CS.is_live(rec.state):
        return rec
    sess = session_of(rec)
    reason = CS.sweep_decision(
        rec.state, now, rec.started_at, ringing_at=sess.ringing_at,
        answered_at=rec.answered_at, caller_seen=sess.caller_seen_at,
        callee_seen=sess.callee_seen_at, connected_at=sess.connected_at)
    if reason:
        end_call(rec, reason, "server", now, sess)
    return rec


def _mark_seen(sess, side, now):
    field = "caller_seen_at" if side == "caller" else "callee_seen_at"
    prev = getattr(sess, field)
    if prev is None or (now - prev).total_seconds() >= 2:
        setattr(sess, field, now)
        sess.save(update_fields=[field])


def status_row(rec, side, lang="bn"):
    sess = session_of(rec)
    return {
        "call_id": rec.id, "kind": rec.kind, "side": side,
        "state": rec.state,
        "phase": CS.phase(rec.state, sess.ringing_at),
        "ringing": sess.ringing_at is not None,
        "end_reason": sess.end_reason or "",
        "ended_by": sess.ended_by or "",
        "connected_at": sess.connected_at.isoformat() if sess.connected_at else None,
        "duration_sec": rec.duration_sec,
        "server_time": timezone.now().isoformat(),
    }


# ---------------------------------------------------------------- real-time
RT_RETAIN_S = 600
RT_MAX_BATCH = 200
RT_MAX_PAYLOAD = 16 * 1024


def rt_publish(user, topic, payload):
    """Queue one event for `user`. Never raises; returns the seq or 0."""
    try:
        if user is None:
            return 0
        return RtEvent.objects.create(user=user, topic=str(topic)[:40],
                                      payload=payload or {}).id
    except Exception:
        return 0


def publish_state(rec):
    """call.state to BOTH parties (each gets its own side)."""
    for side, user_id in (("caller", rec.caller_id), ("callee", rec.callee_id)):
        try:
            row = status_row(rec, side)
            RtEvent.objects.create(user_id=user_id, topic="call.state",
                                   payload=row)
        except Exception:
            pass
        if rec.caller_id == rec.callee_id:
            break


def _sweep_mine(user, now):
    for r in CallRecord.objects.filter(
            Q(caller=user) | Q(callee=user), state__in=CS.LIVE_STATES,
            started_at__gte=now - timedelta(seconds=CS.BUSY_WINDOW_S)):
        sweep(r, now)
        if CS.is_live(r.state):
            _mark_seen(session_of(r), side_of(r, user), now)


RT_PRODUCERS = {}


def register_producer(prefix, fn):
    """fn(request, topic, payload) -> (body_dict, status). Prefix match on
    topic (e.g. "typing."). c3-msg registers presence/typing here."""
    RT_PRODUCERS[prefix] = fn


class RtEventsView(APIView):
    """GET rt/events?after=<seq>&topics=call,typing — returns immediately."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        touch_presence(me, now)
        _sweep_mine(me, now)
        try:
            after = int(request.query_params.get("after") or 0)
        except (TypeError, ValueError):
            after = 0
        q = RtEvent.objects.filter(user=me)
        latest = q.order_by("-id").values_list("id", flat=True).first() or 0
        rows = q.filter(id__gt=after)
        topics = [t.strip() for t in
                  (request.query_params.get("topics") or "").split(",") if t.strip()]
        if topics:
            f = Q()
            for t in topics:
                f |= Q(topic__startswith=t)
            rows = rows.filter(f)
        out = [{"seq": e.id, "topic": e.topic, "payload": e.payload,
                "ts": e.created_at.isoformat()}
               for e in rows.order_by("id")[:RT_MAX_BATCH]]
        # prune this user's old events (cheap, indexed)
        try:
            RtEvent.objects.filter(
                user=me, created_at__lt=now - timedelta(seconds=RT_RETAIN_S)
            ).delete()
        except Exception:
            pass
        return Response({"events": out, "seq": latest,
                         "more": len(out) >= RT_MAX_BATCH,
                         "server_time": now.isoformat()})


class RtSendView(APIView):
    """POST rt/send {topic, payload} -> the producer registered for it."""
    def post(self, request):
        lang = req_lang(request)
        topic = str((request.data or {}).get("topic") or "").strip()
        payload = (request.data or {}).get("payload") or {}
        if not isinstance(payload, dict):
            return _err(lang, "ভুল তথ্য।", "Invalid payload.", status=422,
                        code="bad_payload")
        if len(json.dumps(payload, default=str)) > RT_MAX_PAYLOAD:
            return _err(lang, "সিগন্যাল খুব বড়।", "Signal too large.",
                        status=413, code="too_large")
        for prefix, fn in RT_PRODUCERS.items():
            if topic.startswith(prefix):
                body, code = fn(request, topic, payload)
                return Response(body, status=code)
        return _err(lang, "অজানা বিষয়।", "Unknown topic.", status=422,
                    code="bad_topic")


def _produce_call(request, topic, payload):
    """call.signal -> relayed to the OTHER party of the call."""
    lang = req_lang(request)
    if topic != "call.signal":
        return {"detail": "bad topic", "code": "bad_topic"}, 422
    rec = _call_for(request.user, payload.get("call_id") or 0)
    if rec is None:
        return {"detail": "not found"}, 404
    side = side_of(rec, request.user)
    sweep(rec)
    if not CS.is_live(rec.state):
        return {"detail": CC.pick(lang, "কল শেষ হয়ে গেছে।", "This call has ended."),
                "code": "call_ended", "state": rec.state}, 410
    kind = str(payload.get("kind") or "")
    data = payload.get("data")
    if not isinstance(data, dict):
        data = {"value": data}
    try:
        sent = RtEvent.objects.filter(topic="call.signal",
                                      payload__call_id=rec.id).count()
    except Exception:
        sent = 0
    verdict = CS.validate_signal(kind, len(json.dumps(data, default=str)), sent)
    if verdict != "ok":
        return {"detail": verdict, "code": verdict}, 422
    other = rec.callee if side == "caller" else rec.caller
    seq = rt_publish(other, "call.signal",
                     {"call_id": rec.id, "kind": kind, "from": side,
                      "data": data})
    _mark_seen(session_of(rec), side, timezone.now())
    return {"ok": True, "seq": seq, "state": rec.state}, 201


register_producer("call.", _produce_call)


def ring_allowed(callee, caller):
    """Same rules as push.hook_call_placed: not blocked, call notifications
    on, and "silence unknown callers" respected."""
    try:
        edge = PUSH._reverse_edge(callee, caller)
        if edge is not None and getattr(edge, "blocked", False):
            return False
        if not PUSH._m1_notif(callee).get("calls", True):
            return False
        from .views_m1_messenger import call_prefs
        if call_prefs(callee)["silence_unknown"] and (
                edge is None or edge.state != "accepted"):
            return False
    except Exception:
        pass
    return True


def incoming_row(rec, me):
    edge = PUSH._reverse_edge(me, rec.caller)
    return {
        "call_id": rec.id, "kind": rec.kind, "video": rec.kind == "video",
        "caller_id": rec.caller_id,
        "caller_name": PUSH.display_name(rec.caller),
        "chat_id": edge.id if edge is not None else None,
        "phase": CS.phase(rec.state, session_of(rec).ringing_at),
    }


# ---------------------------------------------------------------- placing
def place_call(request, member, peer, kind):
    """Create the record + session for an allowed call and decide up front:
    busy (callee in another call), offline (no way to ring the phone), else
    ring by push. Returns the JSON body (status 201)."""
    now = timezone.now()
    me = request.user
    callee = peer or me
    rec = CallRecord.objects.create(caller=me, callee=callee, circle=member,
                                    kind=kind, state="ringing")
    sess = CallSession.objects.create(call=rec, caller_seen_at=now)
    outcome = ""
    if peer is not None and peer.pk != me.pk:
        if is_busy(peer, exclude_id=rec.id, now=now):
            outcome = "busy"
        elif not is_reachable(peer, now):
            outcome = "offline"
    if outcome:
        end_call(rec, outcome, "server", now, sess)
    else:
        # In-app ring over the real-time queue (app open, works without FCM)
        # + app-closed ring via FCM data message (key-gated, never raises).
        if ring_allowed(callee, me):
            rt_publish(callee, "call.incoming", incoming_row(rec, callee))
        else:
            # the callee silences this caller: no ring on their side, but it
            # is not "offline" either — it rings out as no answer (+ log).
            sess.ringing_at = now
            sess.save(update_fields=["ringing_at"])
        PUSH.hook_call_placed(me, member, rec)
    turn_ready = bool(getattr(settings, "TURN_STATIC_SECRET", "")) or \
        bool(getattr(settings, "CIRCLE_TURN_READY", False))
    push_ready = bool(getattr(settings, "CIRCLE_PUSH_READY", False)) \
        or PUSH.is_available()
    lang = req_lang(request)
    body = {
        "allowed": True, "kind": kind, "call_id": rec.id,
        "ice": ice_for(me),
        "transport": CC.transport_status(push_ready, turn_ready, lang),
    }
    body.update(status_row(rec, "caller", lang=lang))
    return body


def accept_call(rec, now=None):
    """Callee accepted: ringing -> connecting (= phase 'accepted')."""
    now = now or timezone.now()
    sweep(rec, now)
    if rec.state != "ringing":
        return False
    sess = session_of(rec)
    rec.state = "connecting"
    rec.answered_at = now
    rec.save(update_fields=["state", "answered_at"])
    if sess.ringing_at is None:
        sess.ringing_at = now
    sess.callee_seen_at = now
    sess.save(update_fields=["ringing_at", "callee_seen_at"])
    publish_state(rec)
    # stop the ring on the callee's OTHER devices
    PUSH.hook_call_cancel(rec, "answered")
    return True


def apply_event(rec, side, event, data=None, now=None):
    """The one place every client event lands. Returns the record."""
    now = now or timezone.now()
    data = data or {}
    sweep(rec, now)
    sess = session_of(rec)
    _mark_seen(sess, side, now)
    if event == "ringing":
        if side == "callee" and rec.state == "ringing" and sess.ringing_at is None:
            sess.ringing_at = now
            sess.save(update_fields=["ringing_at"])
            publish_state(rec)
        return rec
    if event == "answer":
        if side == "callee":
            accept_call(rec, now)
        return rec
    if event == "connected":
        if rec.state in ("connecting", "reconnecting", "active"):
            if rec.state != "active":
                rec.state = "active"
                rec.save(update_fields=["state"])
            upd = []
            if sess.connected_at is None:
                sess.connected_at = now
                upd.append("connected_at")
            if data.get("relayed") in (True, "true", 1, "1") and not sess.relayed:
                sess.relayed = True
                upd.append("relayed")
            if upd:
                sess.save(update_fields=upd)
            if "connected_at" in upd:
                publish_state(rec)
        return rec
    if event == "reconnect":
        if rec.state == "active":
            rec.state = "reconnecting"
            rec.save(update_fields=["state"])
            publish_state(rec)
        return rec
    if event in ("busy", "decline") and side != "callee":
        return rec
    reason = CS.end_reason_for_event(rec.state, event, side == "caller")
    if reason and CS.is_live(rec.state):
        end_call(rec, reason, side, now, sess)
    return rec


def _err(lang, bn, en, status=400, code=""):
    return Response({"detail": en if lang == "en" else bn, "code": code},
                    status=status)


# ---------------------------------------------------------------- views
class CallEventView(APIView):
    """POST circle/calls/<id>/event {event, relayed?}"""
    def post(self, request, call_id):
        rec = _call_for(request.user, call_id)
        if rec is None:
            return Response({"detail": "not found"}, status=404)
        side = side_of(rec, request.user)
        event = str((request.data or {}).get("event", "")).strip()
        with transaction.atomic():
            rec = CallRecord.objects.select_for_update().get(pk=rec.pk)
            apply_event(rec, side, event, request.data or {})
        rec.refresh_from_db()
        body = status_row(rec, side, lang=req_lang(request))
        if event == "answer" and side == "callee":
            body["ice"] = ice_for(request.user)
        return Response(body)


class CallStatusView(APIView):
    """GET circle/calls/<id> -> status (runs the lazy timeouts)."""
    def get(self, request, call_id):
        rec = _call_for(request.user, call_id)
        if rec is None:
            return Response({"detail": "not found"}, status=404)
        side = side_of(rec, request.user)
        now = timezone.now()
        sweep(rec, now)
        if CS.is_live(rec.state):
            _mark_seen(session_of(rec), side, now)
        return Response(status_row(rec, side, lang=req_lang(request)))


class IncomingCallsView(APIView):
    """GET circle/calls/incoming — calls ringing for me right now. Polled by
    the app while it is open (and on resume), so a phone without FCM still
    rings in-app; also records presence (=reachable)."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        touch_presence(me, now)
        out = []
        rows = CallRecord.objects.filter(
            callee=me, state="ringing",
            started_at__gte=now - timedelta(seconds=CS.OFFLINE_ACK_S
                                            + CS.RING_TIMEOUT_S + 10)
        ).exclude(caller=me).select_related("caller")
        for r in rows:
            sweep(r, now)
            if r.state != "ringing" or not ring_allowed(me, r.caller):
                continue
            out.append(incoming_row(r, me))
        return Response({"calls": out})


def answer_existing(request, member):
    """Legacy POST circle/<member>/call/answer: accept the ringing call from
    this member's user (or body call_id) — never creates a second record."""
    lang = req_lang(request)
    me = request.user
    cid = (request.data or {}).get("call_id")
    rec = None
    if cid:
        rec = CallRecord.objects.filter(pk=cid, callee=me).first()
    if rec is None:
        peer = PUSH.member_peer_user(member)
        q = CallRecord.objects.filter(callee=me, state__in=CS.LIVE_STATES)
        if peer is not None:
            q = q.filter(caller=peer)
        rec = q.order_by("-started_at").first()
    if rec is None:
        return _err(lang, "এই কলটি আর নেই।", "This call is no longer ringing.",
                    status=410, code="call_ended")
    with transaction.atomic():
        rec = CallRecord.objects.select_for_update().get(pk=rec.pk)
        if rec.state == "ringing":
            accept_call(rec)
    rec.refresh_from_db()
    if rec.state not in ("connecting", "active", "reconnecting"):
        return _err(lang, "এই কলটি আর নেই।", "This call is no longer ringing.",
                    status=410, code="call_ended")
    body = {"allowed": True, "kind": rec.kind, "call_id": rec.id,
            "ice": ice_for(me)}
    body.update(status_row(rec, "callee", lang=lang))
    return Response(body, status=201)


# history label for a record with a session reason (Calls tab).
_HIST = {
    # reason: (outgoing bn, outgoing en, incoming bn, incoming en)
    "no_answer": ("উত্তর নেই", "No answer", "মিসড কল", "Missed call"),
    "busy": ("ব্যস্ত", "Busy", "মিসড কল", "Missed call"),
    "offline": ("অফলাইন", "Offline", "মিসড কল", "Missed call"),
    "canceled": ("বাতিল করা কল", "Canceled call", "মিসড কল", "Missed call"),
    "declined": ("প্রত্যাখ্যাত", "Declined", "প্রত্যাখ্যাত", "Declined"),
    "failed": ("কল ব্যর্থ", "Call failed", "কল ব্যর্থ", "Call failed"),
}


def history_outcome(rec, viewer_id, lang):
    try:
        reason = rec.session.end_reason
    except CallSession.DoesNotExist:
        reason = ""
    if reason not in _HIST:
        return None
    outgoing = rec.caller_id == viewer_id
    ob, oe, ib, ie = _HIST[reason]
    word = (ob, oe) if outgoing else (ib, ie)
    video = rec.kind == "video"
    kind_word = CC.pick(lang, "ভিডিও" if video else "ভয়েস",
                        "Video" if video else "Voice")
    return "%s · %s" % (kind_word, CC.pick(lang, word[0], word[1]))


def history_reason(rec):
    try:
        return rec.session.end_reason or ""
    except CallSession.DoesNotExist:
        return ""


def member_for(user, pk):
    return CircleMember.objects.filter(user=user, pk=pk).first()
