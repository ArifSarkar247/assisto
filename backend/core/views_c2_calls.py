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
those producers via register_producer and its heartbeat via
register_poll_hook — views_c3_msg). WebSocket upgrade path:
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
       b1-calls: video_request (plan-gated, 402 upgrade_required) |
             video_accept (record becomes kind=video) | video_decline |
             video_cancel | video_off | reneg_offer | reneg_answer |
             reneg_request | restart_request;  media data {camera, mic, video}
"""
from __future__ import annotations

import json
import logging
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

# rt2: the real-time writes below stay NON-FATAL for the request (a lost
# typing ping must never 500 a call), but they are no longer silent: reality
# run 39859999833 lost a `call.incoming` ("database is locked") with no trace.
# Each failure is logged with its traceback (ERROR -> the server error log /
# crash reporting) and runs in its own savepoint, so a failed insert cannot
# poison an outer transaction on Postgres.
log = logging.getLogger("assisto.rt")


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
            host, getattr(settings, "TURN_PORT", 3478), creds,
            tls_port=getattr(settings, "TURN_TLS_PORT", 0)),
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
        with transaction.atomic():
            n = RtPresence.objects.filter(
                user=user, seen_at__lt=now - timedelta(seconds=10)
            ).update(seen_at=now)
            if not n and not RtPresence.objects.filter(user=user).exists():
                RtPresence.objects.create(user=user, seen_at=now)
    except Exception:
        log.exception("rt: touch_presence failed (user=%s)", getattr(user, "pk", None))


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


def _has_push_device(user):
    try:
        return Device.objects.filter(user=user).exclude(push_token="").exists()
    except Exception:
        return False


def is_busy(user, exclude_id=None, now=None, exclude_peer=None):
    """Is `user` REALLY in another call (x1-calls A1-f)? Only a call whose
    media connected and whose two phones both polled within HEARTBEAT_S
    counts — a ringing / connecting / silent row never makes anyone busy.
    Calls between `user` and `exclude_peer` never count (that is glare or a
    repeat, handled by place_call)."""
    now = now or timezone.now()
    live = CallRecord.objects.filter(
        Q(caller=user) | Q(callee=user), state__in=CS.LIVE_STATES,
        started_at__gte=now - timedelta(seconds=CS.BUSY_WINDOW_S))
    if exclude_id:
        live = live.exclude(pk=exclude_id)
    if exclude_peer is not None:
        live = live.exclude(Q(caller=exclude_peer) | Q(callee=exclude_peer))
    for r in live:
        sweep(r, now)
        if not CS.is_live(r.state) or r.caller_id == r.callee_id:
            continue
        sess = session_of(r)
        if CS.is_truly_active(r.state, now, sess.connected_at,
                              sess.caller_seen_at, sess.callee_seen_at):
            return True
    return False


# x1-calls A1-c: the call-time poll is the primary path (~0.3 s while a call
# is set up); a high-priority FCM DATA push "call_signal" (ids only — never
# SDP, never names) nudges the other phone to poll NOW when its poll is slow
# (Doze, backgrounded during the call). Unknown to old app builds -> ignored.
NUDGE_SIGNAL_KINDS = ("offer", "answer", "restart_offer", "restart_answer",
                      # b1-calls: a video request / renegotiation / restart
                      # request must reach a backgrounded (slow-poll) phone
                      "video_request", "reneg_offer", "reneg_answer",
                      "restart_request")


def _nudge_send(tokens, data, collapse):
    from django.db import close_old_connections
    try:
        close_old_connections()
        for tok in tokens:
            PUSH.send_to_token(tok, data, None, priority="high", ttl_s=20,
                               collapse_key=collapse)
    except Exception:
        pass


def nudge_call(rec, what, to_user_id=None):
    """Fire-and-forget FCM nudge to one party (or both). Never raises."""
    try:
        if not PUSH.is_available():
            return False
        ids = [to_user_id] if to_user_id else list(
            dict.fromkeys([rec.caller_id, rec.callee_id]))
        tokens = list(Device.objects.filter(user_id__in=ids)
                      .exclude(push_token="").values_list("push_token", flat=True))
        if not tokens:
            return False
        data = {"kind": "call_signal", "call_id": rec.id, "what": str(what)[:20]}
        collapse = "callsig-%s" % rec.id
        if getattr(settings, "PUSH_SYNC", False):
            _nudge_send(tokens, data, collapse)
        else:
            PUSH._get_executor().submit(_nudge_send, tokens, data, collapse)
        return True
    except Exception:
        return False


def photo_of(user, request=None):
    """(absolute-or-relative signed photo URL, cache version) for `user`.
    The version changes only when the photo changes (new upload / link), so
    phones cache the image per (user, version) and refresh on change."""
    try:
        if user is None:
            return "", ""
        url = getattr(user, "photo_url", "") or ""
        if not url:
            return "", ""
        import hashlib
        key = str(user.photo.name) if user.photo else (user.photo_link or "")
        ver = hashlib.md5(key.encode()).hexdigest()[:8]
        if url.startswith("/"):
            if request is not None:
                url = request.build_absolute_uri(url)
            else:
                base = (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/")
                url = base + url if base.startswith("http") else url
        return url, ver
    except Exception:
        return "", ""


def missed_streak(rec):
    """How many calls in a row from this caller the callee missed (this one
    included, last 24 h, back to the last call between them that was not a
    missed incoming one) — the "T Shanto BD (6)" count."""
    try:
        since = timezone.now() - timedelta(hours=24)
        rows = CallRecord.objects.filter(
            Q(caller_id=rec.caller_id, callee_id=rec.callee_id)
            | Q(caller_id=rec.callee_id, callee_id=rec.caller_id),
            started_at__gte=since).exclude(state__in=CS.LIVE_STATES) \
            .order_by("-started_at", "-id").select_related("session")[:50]
        n = 0
        for r in rows:
            if r.caller_id != rec.caller_id:
                break
            reason = history_reason(r)
            if r.state in ("missed", "canceled") or reason in CS.MISSED_REASONS:
                n += 1
            else:
                break
        return max(1, n)
    except Exception:
        return 1


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
        # x1-calls A1-g: ONE notification per caller, WhatsApp-style
        # "T Shanto BD (6)" — the app replaces it by caller_id (group_key).
        n = missed_streak(rec)
        photo, ver = photo_of(caller)
        if n > 1:
            title_bn, title_en = "%s (%d)" % (name, n), "%s (%d)" % (name, n)
            body_bn, body_en = "%dটি মিসড কল" % n, "%d missed calls" % n
        else:
            title_bn, title_en = ("%s-এর মিসড কল" % name,
                                  "Missed call from %s" % name)
            body_bn = "ভিডিও কল" if video else "ভয়েস কল"
            body_en = "Video call" if video else "Voice call"
        return PUSH.safe_push(
            rec.callee, "missed_call", title_bn, title_en, body_bn, body_en,
            data={"call_id": rec.id, "caller_id": caller.id,
                  "caller_name": name, "video": video, "reason": reason,
                  "missed_count": n, "group_key": "caller-%s" % caller.id,
                  "caller_photo": photo, "caller_photo_v": ver,
                  "chat_id": edge.id if edge is not None else "",
                  "route": "circle/calls"})
    except Exception:
        return False


def end_call(rec, reason, by="server", now=None, sess=None, notify=True):
    """Move a live record to its terminal state for `reason` (idempotent).
    notify=False (one-time stale cleanup): no push, no missed-call alert."""
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
    if notify and reason in CS.MISSED_REASONS and not sess.missed_notified:
        sess.missed_notified = True
        upd.append("missed_notified")
        notify_missed = True
    else:
        notify_missed = False
    # ring-everywhere: never delivered to the callee's phone -> show it as a
    # missed call when that phone next comes online (call_ack).
    if notify and was_ringing:
        try:
            from . import call_ack
            if call_ack.mark_missed_pending(rec, sess, reason):
                upd.append("missed_pending")
        except Exception:
            pass
    sess.save(update_fields=upd)
    publish_state(rec)
    # callsB: a pair link of a GROUP call ended -> roster (no-op for 1:1)
    try:
        from . import call_rooms
        call_rooms.on_record_ended(rec, reason)
    except Exception:
        log.exception("callsB: on_record_ended hook")
    if notify and not was_ringing:
        # accepted / live call ended: wake the other phone now (a ringing
        # end already sends call_cancel to the callee)
        nudge_call(rec, "state")
    if was_ringing and notify:
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
    if rec.state == "ringing":
        # ring-everywhere: no delivered / ringing ack 4 s after the ring push
        # -> resend it (bounded, idempotent; call_ack.maybe_resend).
        try:
            from . import call_ack
            call_ack.maybe_resend(rec, sess, now)
        except Exception:
            pass
    reason = CS.sweep_decision(
        rec.state, now, rec.started_at, ringing_at=sess.ringing_at or getattr(sess, "delivered_at", None),
        answered_at=rec.answered_at, caller_seen=sess.caller_seen_at,
        callee_seen=sess.callee_seen_at, connected_at=sess.connected_at,
        push_sent=bool(getattr(sess, "push_sent", False)))
    if reason:
        end_call(rec, reason, "server", now, sess)
    return rec


def sweep_user(user, now=None):
    """Sweep every live call of `user` (on every call event, A1-e)."""
    now = now or timezone.now()
    if user is None:
        return
    for r in CallRecord.objects.filter(
            Q(caller=user) | Q(callee=user), state__in=CS.LIVE_STATES):
        sweep(r, now)


def sweep_all(now=None):
    """Cron (`manage.py calls_sweep`, every minute): run the lazy timeouts on
    every live row. Returns {reason: count}."""
    now = now or timezone.now()
    out = {}
    for r in CallRecord.objects.filter(state__in=CS.LIVE_STATES):
        before = r.state
        sweep(r, now)
        if r.state != before:
            reason = session_of(r).end_reason or r.state
            out[reason] = out.get(reason, 0) + 1
    return out


def stale_cleanup(now=None, apply=False):
    """One-time cleanup (`manage.py calls_cleanup_stale [--apply]`): every
    live row the timeouts say is dead, or that is older than BUSY_WINDOW_S,
    is ended WITHOUT pushes (old rows must not ring/alert anyone). Returns a
    list of (id, state, reason) that were (or would be) ended."""
    now = now or timezone.now()
    out = []
    for r in CallRecord.objects.filter(state__in=CS.LIVE_STATES).order_by("id"):
        sess = session_of(r)
        reason = CS.sweep_decision(
            r.state, now, r.started_at, ringing_at=sess.ringing_at,
            answered_at=r.answered_at, caller_seen=sess.caller_seen_at,
            callee_seen=sess.callee_seen_at, connected_at=sess.connected_at,
            push_sent=bool(getattr(sess, "push_sent", False)))
        if reason is None and (now - r.started_at).total_seconds() > CS.BUSY_WINDOW_S:
            reason = "lost" if sess.connected_at else (
                "no_answer" if r.state == "ringing" else "failed")
        if reason is None:
            continue
        out.append((r.id, r.state, reason))
        if apply:
            end_call(r, reason, "server", now, sess, notify=False)
    return out


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
        "phase": CS.phase(rec.state, sess.ringing_at,
                          getattr(sess, "delivered_at", None)),
        "ringing": sess.ringing_at is not None,
        # calls95: the callee phone confirmed the ring push arrived
        "delivered": bool(getattr(sess, "delivered_at", None)
                          or sess.ringing_at),
        "end_reason": sess.end_reason or "",
        "ended_by": sess.ended_by or "",
        "connected_at": sess.connected_at.isoformat() if sess.connected_at else None,
        "duration_sec": rec.duration_sec,
        "relayed": bool(sess.relayed),
        "connect_timeout_s": CS.CONNECT_TIMEOUT_S,
        "server_time": timezone.now().isoformat(),
    }


# ---------------------------------------------------------------- real-time
RT_RETAIN_S = 600
RT_MAX_BATCH = 200
RT_MAX_PAYLOAD = 16 * 1024


def rt_publish(user, topic, payload):
    """Queue one event for `user`. Never raises; returns the seq or 0."""
    if user is None:
        return 0
    try:
        with transaction.atomic():
            return RtEvent.objects.create(user=user, topic=str(topic)[:40],
                                          payload=payload or {}).id
    except Exception:
        log.exception("rt: rt_publish lost an event (user=%s topic=%s)",
                      getattr(user, "pk", None), str(topic)[:40])
        return 0


def publish_state(rec):
    """call.state to BOTH parties (each gets its own side)."""
    for side, user_id in (("caller", rec.caller_id), ("callee", rec.callee_id)):
        try:
            row = status_row(rec, side)
            with transaction.atomic():
                RtEvent.objects.create(user_id=user_id, topic="call.state",
                                       payload=row)
        except Exception:
            log.exception("rt: publish_state lost call.state (call=%s user=%s)",
                          getattr(rec, "pk", None), user_id)
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


RT_POLL_HOOKS = []


def register_poll_hook(fn):
    """fn(request, now) runs on every rt/events poll (never raises into the
    poll). c3-msg's presence heartbeat (`online=1`) rides here, so the phone
    needs no second request loop."""
    if fn not in RT_POLL_HOOKS:
        RT_POLL_HOOKS.append(fn)


class RtEventsView(APIView):
    """GET rt/events?after=<seq>&topics=call,typing[&online=1] — returns
    immediately. `online=1` = a My Circle screen is open (c3 heartbeat)."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        touch_presence(me, now)
        _sweep_mine(me, now)
        for hook in list(RT_POLL_HOOKS):
            try:
                hook(request, now)
            except Exception:
                pass
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
        try:
            only_call = int(request.query_params.get("call_id") or 0)
        except (TypeError, ValueError):
            only_call = 0
        if only_call:
            rows = rows.filter(payload__call_id=only_call)
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
    if kind == "video_request" and rec.kind != "video":
        # b1-calls: switching a voice call to video runs THE SAME plan gate
        # as placing a video call, for the person asking (the one who
        # accepts may be free). "Free calls (testing)" lifts it (entitle()).
        gate = video_upgrade_gate(rec, request.user)
        if not gate.get("allowed"):
            return {"detail": CC.pick(
                lang, "ভিডিও কলের জন্য প্রিমিয়াম লাগবে।",
                "Video calling needs Premium."),
                "code": "upgrade_required", "upgrade_required": True,
                "prompt": CC.upgrade_prompt(lang)}, 402
    if kind == "video_accept" and rec.kind != "video":
        # b1-calls: the call is a VIDEO call from now on — history shows it
        # and the P&L relay-cost estimate (turn_monitor, per kind) uses the
        # video bitrate for it.
        rec.kind = "video"
        rec.save(update_fields=["kind"])
    other = rec.callee if side == "caller" else rec.caller
    seq = rt_publish(other, "call.signal",
                     {"call_id": rec.id, "kind": kind, "from": side,
                      "data": data})
    _mark_seen(session_of(rec), side, timezone.now())
    if kind in NUDGE_SIGNAL_KINDS:
        nudge_call(rec, kind, to_user_id=other.id)
    return {"ok": True, "seq": seq, "state": rec.state}, 201


register_producer("call.", _produce_call)


def video_upgrade_gate(rec, user):
    """b1-calls: may `user` (a party of `rec`) switch it to video? The same
    circle_calls.can_place_call gate as placing a video call, with the
    asker as the "caller". Never raises (an error means allowed=False)."""
    try:
        from .views_build61 import _callee_dict, _caller_dict
        other = rec.callee if user.id == rec.caller_id else rec.caller
        edge = (rec.circle if (rec.circle is not None
                               and rec.circle.user_id == user.id) else None)
        if edge is None:
            edge = CircleMember.objects.filter(user=user,
                                               peer_user=other).first()
        return CC.can_place_call(_caller_dict(user, edge),
                                 _callee_dict(edge), "video")
    except Exception:
        log.exception("b1 video_upgrade_gate")
        return {"allowed": False, "reason": "error"}


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
        "caller_photo": photo_of(rec.caller)[0],
        "caller_photo_v": photo_of(rec.caller)[1],
        "chat_id": edge.id if edge is not None else None,
        "phase": CS.phase(rec.state, session_of(rec).ringing_at,
                          getattr(session_of(rec), "delivered_at", None)),
    }


# ---------------------------------------------------------------- placing
def _lock_users(*users):
    """Serialise placements between the same people (row locks in id order;
    a no-op on SQLite). Two POSTs ~0 s apart from one phone, or both people
    calling each other at once, can then never create two live records."""
    ids = sorted({u.pk for u in users if u is not None})
    if ids:
        from .models import User
        list(User.objects.select_for_update().filter(pk__in=ids).order_by("pk")
             .values_list("pk", flat=True))


def _existing_body(request, rec, side, lang, **flags):
    body = {"allowed": True, "kind": rec.kind, "call_id": rec.id,
            "ice": ice_for(request.user)}
    body.update(flags)
    body.update(status_row(rec, side, lang=lang))
    return body


def place_call(request, member, peer, kind, client_call_id=""):
    """Create the record + session for an allowed call and decide up front
    (x1-calls rules, A1-a/f):

      * IDEMPOTENT: the same client_call_id from this caller -> the same call.
      * DEDUPE: a live call me -> peer placed < DEDUPE_WINDOW_S ago is
        returned as is (never a second record, never "busy" against myself).
      * GLARE: the peer is calling ME right now -> merge: I join THAT call as
        its callee (it is accepted at once) — never "busy".
      * BUSY only when the peer has a really active call with someone else
        (media connected + fresh heartbeat); OFFLINE when the phone cannot
        ring at all; else ring by push + the real-time queue.
    Returns the JSON body (status 201)."""
    now = timezone.now()
    me = request.user
    callee = peer or me
    lang = req_lang(request)
    key = str(client_call_id or "").strip()[:64]
    with transaction.atomic():
        _lock_users(me, peer)
        sweep_user(me, now)
        if peer is not None and peer.pk != me.pk:
            sweep_user(peer, now)
        if key:
            sess = CallSession.objects.filter(
                client_call_id=key, call__caller=me).select_related("call") \
                .order_by("-id").first()
            if sess is not None:
                return _existing_body(request, sess.call, "caller", lang,
                                      deduped=True)
        mine = CallRecord.objects.filter(
            caller=me, callee=callee, state__in=CS.LIVE_STATES) \
            .order_by("-started_at", "-id")
        for old in mine:
            if CS.dedupe_match(old.started_at, now) and old.kind == kind:
                if key:
                    s0 = session_of(old)
                    if not s0.client_call_id:
                        s0.client_call_id = key
                        s0.save(update_fields=["client_call_id"])
                return _existing_body(request, old, "caller", lang,
                                      deduped=True)
            # an older live call to the same person is superseded by this tap
            end_call(old, "canceled" if old.state == "ringing" else "hangup",
                     "caller", now)
        if peer is not None and peer.pk != me.pk:
            theirs = CallRecord.objects.filter(
                caller=peer, callee=me, state__in=("ringing", "connecting")) \
                .order_by("-started_at", "-id").first()
            if theirs is not None:
                # glare: both tapped call -> ONE call, I am its callee
                if theirs.state == "ringing":
                    accept_call(theirs, now)
                    theirs.refresh_from_db()
                return _existing_body(request, theirs, "callee", lang,
                                      merged=True, role="callee")
        from .calls_free import calls_free   # dl1
        rec = CallRecord.objects.create(caller=me, callee=callee, circle=member,
                                        kind=kind, state="ringing",
                                        free_testing=calls_free())
        sess = CallSession.objects.create(call=rec, caller_seen_at=now,
                                          client_call_id=key)
        outcome = ""
        if peer is not None and peer.pk != me.pk:
            if is_busy(peer, exclude_id=rec.id, now=now, exclude_peer=me):
                outcome = "busy"
            elif not is_reachable(peer, now):
                outcome = "offline"
        if outcome:
            end_call(rec, outcome, "server", now, sess)
        else:
            # In-app ring over the real-time queue (app open, works without
            # FCM) + app-closed ring via FCM data message (key-gated).
            if ring_allowed(callee, me):
                rt_publish(callee, "call.incoming", incoming_row(rec, callee))
            else:
                # the callee silences this caller: no ring on their side, but
                # it is not "offline" either — it rings out as no answer.
                sess.ringing_at = now
                sess.save(update_fields=["ringing_at"])
            if PUSH.hook_call_placed(me, member, rec) and _has_push_device(callee):
                # calls-health: an FCM ring went to a real device -> wait the
                # full ring window for its ack (call_signal.OFFLINE_ACK_PUSHED_S)
                sess.push_sent = True
                sess.last_push_at = now   # ring-everywhere: resend clock
                upd = ["push_sent", "last_push_at"]
                try:
                    from . import call_ack
                    upd += call_ack.stamp_callee_device(sess, callee)
                except Exception:
                    pass
                sess.save(update_fields=upd)
    turn_ready = bool(getattr(settings, "TURN_STATIC_SECRET", "")) or \
        bool(getattr(settings, "CIRCLE_TURN_READY", False))
    push_ready = bool(getattr(settings, "CIRCLE_PUSH_READY", False)) \
        or PUSH.is_available()
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
    # callsB: an added person answered -> joined + pair links (no-op for 1:1)
    try:
        from . import call_rooms
        call_rooms.on_record_accepted(rec)
    except Exception:
        log.exception("callsB: on_record_accepted hook")
    return True


def request_user_of(rec, side):
    return rec.caller if side == "caller" else rec.callee


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
    if event == "busy" and not is_busy(request_user_of(rec, side), now=now,
                                       exclude_id=rec.id,
                                       exclude_peer=rec.caller):
        # A1-f: the phone thinks it is busy, but it has no really active call
        # (only a ringing / connecting / dead one) -> keep ringing.
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
        sweep_user(request.user)  # A1-e: sweep on every call event
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


def history_groups(rows, viewer):
    """A1-g: the call log grouped WhatsApp-style — consecutive calls with the
    same person, direction, outcome and day become ONE row "Name (n)".
    `rows` = the CircleCallsView dicts (newest first). Each group is the
    newest row + "count" + "ids"."""
    from django.utils.dateparse import parse_datetime
    keyed = []
    for r in rows:
        try:
            day = timezone.localtime(parse_datetime(
                r["started_at"])).date().isoformat()
        except Exception:
            day = str(r.get("started_at", ""))[:10]
        keyed.append({
            "id": r["id"], "peer_key": r.get("peer_id") or r.get("name"),
            "outgoing": bool(r.get("outgoing")),
            "category": CS.history_category(r.get("state", ""),
                                            r.get("end_reason", ""),
                                            bool(r.get("outgoing"))),
            "day": day, "row": r})
    out = []
    for g in CS.group_history(keyed):
        row = dict(g["first"]["row"])
        row["count"] = g["count"]
        row["ids"] = g["ids"]
        out.append(row)
    return out


def history_reason(rec):
    try:
        return rec.session.end_reason or ""
    except CallSession.DoesNotExist:
        return ""


def member_for(user, pk):
    return CircleMember.objects.filter(user=user, pk=pk).first()
