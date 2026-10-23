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
# x1-calls (owner order A1-e): stale calls die fast so nobody is ever shown
# "Busy" or left on "Connecting…" by a dead row.
OFFLINE_ACK_S = 20      # placed, but the callee phone never said "ringing"
RING_TIMEOUT_S = 45     # ringing at most 45 s from placement -> no_answer
CONNECT_TIMEOUT_S = 20  # accepted but ICE never connected -> failed (both)
HEARTBEAT_S = 15        # a side stopped polling during a live call -> lost
STALE_S = HEARTBEAT_S   # (old name, kept for callers/tests)
PRESENCE_S = 30         # in-app poll seen this recently = phone is reachable
BUSY_WINDOW_S = 3 * 3600  # an "active" call older than this is never busy
# x1-calls: a second "place" for the same caller -> callee inside this window
# returns the EXISTING live call (double tap, gate pre-check, retry).
DEDUPE_WINDOW_S = 60

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
                "media",
                # b1-calls: voice <-> video mid-call + renegotiation + the
                # callee asking the caller for an ICE restart.
                "video_request", "video_accept", "video_decline",
                "video_cancel", "video_off", "reneg_offer", "reneg_answer",
                "reneg_request", "restart_request")

# b1-calls: a side that is RECONNECTING (Wi-Fi <-> mobile data) may be silent
# longer than HEARTBEAT_S while its new network comes up; the phones give up
# after 30 s themselves, so the server waits a little longer than that.
RECONNECT_GRACE_S = 35
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

      ringing, never acked, > OFFLINE_ACK_S          -> offline
      ringing, > RING_TIMEOUT_S since placement      -> no_answer
      ringing, caller silent > HEARTBEAT_S           -> canceled
      connecting (accepted), > CONNECT_TIMEOUT_S     -> failed
      any live phase: a side silent > HEARTBEAT_S    -> lost (failed when
                                                         media never connected)
      reconnecting: a side silent > RECONNECT_GRACE_S -> lost (b1-calls)
    """
    if not is_live(state):
        return None
    now_s = _ts(now)
    started = _ts(started_at) or now_s
    if state == "ringing":
        if ringing_at is None and now_s - started > OFFLINE_ACK_S:
            return "offline"
        if now_s - started > RING_TIMEOUT_S:
            return "no_answer"
        # the caller closed the app / lost network while ringing
        cs = _ts(caller_seen)
        if cs is not None and now_s - cs > HEARTBEAT_S:
            return "canceled"
        return None
    if state == "connecting":
        ans = _ts(answered_at) or started
        if now_s - ans > CONNECT_TIMEOUT_S:
            return "failed"
    silent_limit = RECONNECT_GRACE_S if state == "reconnecting" else HEARTBEAT_S
    for seen in (caller_seen, callee_seen):
        s = _ts(seen)
        if s is not None and now_s - s > silent_limit:
            return "lost" if connected_at is not None else "failed"
    return None


def is_truly_active(state, now, connected_at=None, caller_seen=None,
                    callee_seen=None):
    """BUSY rule (A1-f): a call makes its parties busy ONLY when media really
    connected AND both phones polled within HEARTBEAT_S. Ringing/connecting
    calls, or a connected call whose phones went silent, never cause busy."""
    if state not in ("active", "reconnecting") or connected_at is None:
        return False
    now_s = _ts(now)
    for seen in (caller_seen, callee_seen):
        s = _ts(seen)
        if s is None or now_s - s > HEARTBEAT_S:
            return False
    return True


def dedupe_match(started_at, now, window=DEDUPE_WINDOW_S):
    """Is a live call placed at `started_at` recent enough to be returned for
    a repeated place request?"""
    st = _ts(started_at)
    return st is not None and _ts(now) - st <= window


def group_history(rows):
    """WhatsApp-style call-log grouping (A1-g). `rows` newest first, each a
    dict with peer_key, outgoing, category ('missed'|'answered'|'other'),
    day ('YYYY-MM-DD') and id. Consecutive rows with the same peer,
    direction, category and day collapse into one group:
        {"first": <row>, "count": n, "ids": [...]}"""
    groups = []
    for r in rows:
        g = groups[-1] if groups else None
        if g is not None:
            f = g["first"]
            if (f.get("peer_key") == r.get("peer_key")
                    and f.get("outgoing") == r.get("outgoing")
                    and f.get("category") == r.get("category")
                    and f.get("day") == r.get("day")):
                g["count"] += 1
                g["ids"].append(r.get("id"))
                continue
        groups.append({"first": r, "count": 1, "ids": [r.get("id")]})
    return groups


def history_category(state, end_reason, outgoing):
    if end_reason in ("hangup", "lost") or state == "ended":
        return "answered"
    if not outgoing and (state in ("missed", "canceled")
                         or end_reason in MISSED_REASONS):
        return "missed"
    return "other:%s" % (end_reason or state)


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
