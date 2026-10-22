"""
call_signal.py — c2-calls: the REAL 1:1 call session rules (pure, no DB).

The CallRecord row (core.models) keeps the history state used by the Calls tab
(circle_calls.CALL_* values).  This module adds what a real call needs on top:

  * the PHASE both phones render:
        calling      placed, the callee's phone has NOT confirmed it is ringing
        ringing      the callee's phone reported it is ringing (FCM handler or
                     in-app poll) -> only now does the caller hear ringback
        accepted     callee tapped Accept, media is negotiating
        connected    ICE connected, media flowing (timer runs)
        reconnecting ICE dropped mid-call, ICE restart in progress
        ended        terminal; `end_reason` says why
  * the END REASONS (honest outcomes for both sides):
        no_answer  rang out          busy      callee already in a call
        declined   callee declined   offline   callee phone never rang
        canceled   caller hung up before answer
        hangup     normal end        failed    media/ICE failed
        lost       a phone stopped polling mid-call (network gone)
  * the server-side TIMEOUTS (evaluated lazily by `sweep_decision`).
  * signal validation (kinds + size).

Signalling transport: the backend is WSGI (gunicorn sync workers, no Django
Channels), so phones exchange SDP/ICE by SHORT polling with sequence numbers
(GET .../signal?after=<seq>, never held open, so a poll can never tie up a
worker).  A WebSocket upgrade is documented in .phaseB/proposals/c2-calls.md.
"""
from __future__ import annotations

from datetime import datetime, timezone

# ---- timeouts (seconds) ----------------------------------------------------
OFFLINE_ACK_S = 20      # placed, but the callee phone never said "ringing"
RING_TIMEOUT_S = 45     # ringing with no answer -> no_answer
CONNECT_TIMEOUT_S = 40  # accepted but ICE never connected -> failed
STALE_S = 40            # a side stopped polling during a live call -> lost
PRESENCE_S = 30         # in-app poll seen this recently = phone is reachable
BUSY_WINDOW_S = 3 * 3600  # an "active" call older than this is never busy

PHASES = ("calling", "ringing", "accepted", "connected", "reconnecting", "ended")
END_REASONS = ("no_answer", "busy", "declined", "offline", "canceled",
               "hangup", "failed", "lost")

# end_reason -> the CallRecord.state stored for history.
REASON_STATE = {
    "no_answer": "missed",
    "busy": "missed",
    "offline": "missed",
    "canceled": "canceled",
    "declined": "declined",
    "hangup": "ended",
    "lost": "ended",
    "failed": "failed",
}

# reasons where the callee gets a "missed call" notification.
MISSED_REASONS = ("no_answer", "busy", "offline", "canceled")

LIVE_STATES = ("ringing", "connecting", "active", "reconnecting")

SIGNAL_KINDS = ("offer", "answer", "ice", "restart_offer", "restart_answer",
                "media")
MAX_SIGNAL_BYTES = 16 * 1024
MAX_SIGNALS_PER_CALL = 400


def _ts(dt):
    if dt is None:
        return None
    if isinstance(dt, (int, float)):
        return float(dt)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def is_live(state):
    return state in LIVE_STATES


def phase(state, ringing_at=None):
    """The phase a phone renders, from the stored record state."""
    if state == "ringing":
        return "ringing" if ringing_at else "calling"
    if state == "connecting":
        return "accepted"
    if state == "active":
        return "connected"
    if state == "reconnecting":
        return "reconnecting"
    return "ended"


def state_for_reason(reason):
    return REASON_STATE.get(reason, "ended")


def end_reason_for_event(state, event, by_caller):
    """Map a client end event on a live record to an end_reason.
    Returns None for a non-ending event."""
    if event == "decline":
        return "declined" if state == "ringing" else None
    if event == "busy":
        return "busy" if state == "ringing" else None
    if event == "cancel":
        return "canceled" if state == "ringing" else "hangup"
    if event == "hangup":
        if state == "ringing":
            return "canceled" if by_caller else "declined"
        return "hangup"
    if event == "fail":
        return "failed"
    if event == "timeout":
        return "no_answer" if state == "ringing" else None
    return None


def sweep_decision(state, now, started_at, ringing_at=None, answered_at=None,
                   caller_seen=None, callee_seen=None, connected_at=None):
    """Lazy server-side timeout check.  Returns an end_reason or None.

      ringing, never acked, > OFFLINE_ACK_S        -> offline
      ringing, acked,  > RING_TIMEOUT_S since ack  -> no_answer
      connecting (accepted), > CONNECT_TIMEOUT_S   -> failed
      any live phase: a side silent > STALE_S      -> lost / canceled
    """
    if not is_live(state):
        return None
    now_s = _ts(now)
    started = _ts(started_at) or now_s
    if state == "ringing":
        if ringing_at is None:
            if now_s - started > OFFLINE_ACK_S:
                return "offline"
        elif now_s - _ts(ringing_at) > RING_TIMEOUT_S:
            return "no_answer"
        # the caller closed the app / lost network while ringing
        cs = _ts(caller_seen)
        if cs is not None and now_s - cs > STALE_S:
            return "canceled"
        return None
    if state == "connecting":
        ans = _ts(answered_at) or started
        if now_s - ans > CONNECT_TIMEOUT_S:
            return "failed"
    for seen in (caller_seen, callee_seen):
        s = _ts(seen)
        if s is not None and now_s - s > STALE_S:
            return "lost"
    return None


def is_presence_fresh(seen_at, now):
    s = _ts(seen_at)
    return s is not None and _ts(now) - s <= PRESENCE_S


def validate_signal(kind, payload_json_len, count):
    """('ok'|'bad_kind'|'too_large'|'too_many')."""
    if kind not in SIGNAL_KINDS:
        return "bad_kind"
    if payload_json_len > MAX_SIGNAL_BYTES:
        return "too_large"
    if count >= MAX_SIGNALS_PER_CALL:
        return "too_many"
    return "ok"


def duration_sec(connected_at, ended_at):
    """Talk time counts from ICE connected (not from accept)."""
    c, e = _ts(connected_at), _ts(ended_at)
    if c is None or e is None:
        return 0
    return max(0, int(e - c))


def now_utc():
    return datetime.now(timezone.utc)
