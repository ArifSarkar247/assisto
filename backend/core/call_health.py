"""calls-health — call setup health for Owner Admin (owner 24 Oct: "Call
server busy — try again", "a call rang then dropped").

Two sources, no new per-call work on the hot path:
  * CallRecord + CallSession (every placed call) give the FUNNEL:
        placed -> push sent -> callee phone rang (ack) -> answered -> ICE
        connected, plus the honest end reasons (offline / failed / lost).
  * CallHealthEvent rows give what those rows cannot show: a throttled
    GET rtc/turn (server side) and a setup step the PHONE gave up on after
    its silent retries (POST rtc/health, client side) — calls that never
    produced a CallRecord.

summary() is one 24 h window; alert() turns it into the Owner Admin banner
(success below ALERT_SUCCESS_PCT with enough attempts, or any throttle).
Never raises into a caller.
"""
from __future__ import annotations

import logging
from datetime import timedelta

from django.core.cache import cache
from django.utils import timezone

log = logging.getLogger(__name__)

RETAIN_DAYS = 30
ALERT_SUCCESS_PCT = 80          # banner when success drops below this...
ALERT_MIN_ATTEMPTS = 5          # ...over at least this many finished attempts
CLIENT_MAX_PER_HOUR = 20        # client reports per user per hour (abuse cap)
CACHE_KEY = "calls_health_alert_v1"
CACHE_S = 60

CLIENT_STEPS = ("rtc_config", "place", "accept", "ring_ack", "ice")
CLIENT_CODES = ("throttled", "server", "network", "timeout", "media",
                "refused", "unknown")

# end reasons that are a SYSTEM failure (not the people: declined / busy /
# no answer / caller canceled are normal outcomes).
FAIL_REASONS = ("offline", "failed", "lost")


def log_event(step, code="", user=None, call_id=None, source="server"):
    """Record one setup failure. Never raises. Returns the row or None."""
    try:
        from .models import CallHealthEvent
        row = CallHealthEvent.objects.create(
            user=user if getattr(user, "pk", None) else None,
            step=str(step)[:16], code=str(code or "")[:24],
            source="client" if source == "client" else "server",
            call_id=int(call_id) if call_id else None)
        # cheap, indexed prune (1 in ~50 writes)
        if row.id % 50 == 0:
            CallHealthEvent.objects.filter(
                created_at__lt=timezone.now() - timedelta(days=RETAIN_DAYS)
            ).delete()
        cache.delete(CACHE_KEY)
        return row
    except Exception:
        log.exception("calls-health: log_event failed")
        return None


def client_report_allowed(user, now=None):
    from .models import CallHealthEvent
    now = now or timezone.now()
    n = CallHealthEvent.objects.filter(
        user=user, source="client",
        created_at__gte=now - timedelta(hours=1)).count()
    return n < CLIENT_MAX_PER_HOUR


def summary(hours=24, now=None):
    """The Owner Admin numbers for the last `hours`."""
    from .models import CallHealthEvent, CallRecord
    from .logic import call_signal as CS
    now = now or timezone.now()
    since = now - timedelta(hours=hours)
    recs = list(CallRecord.objects.filter(started_at__gte=since)
                .exclude(callee_id=None)
                .select_related("session"))
    placed = ended = ok = 0
    push = acked = answered = connected = 0
    reasons = {}
    for r in recs:
        if r.callee_id == r.caller_id:
            continue
        placed += 1
        sess = getattr(r, "session", None)
        if sess is None:
            continue
        if getattr(sess, "push_sent", False):
            push += 1
        if sess.ringing_at is not None or r.answered_at is not None:
            acked += 1
        if r.answered_at is not None:
            answered += 1
        if sess.connected_at is not None:
            connected += 1
        if CS.is_live(r.state):
            continue            # still ringing / in progress: not judged yet
        ended += 1
        reason = sess.end_reason or r.state
        reasons[reason] = reasons.get(reason, 0) + 1
        if reason not in FAIL_REASONS:
            ok += 1
    ev = list(CallHealthEvent.objects.filter(created_at__gte=since)
              .values_list("step", "code", "source", "call_id"))
    by_step = {}
    throttled = 0
    pre_place = 0       # attempts that never produced a CallRecord
    for step, code, source, call_id in ev:
        key = "%s:%s" % (step, code) if code else step
        by_step[key] = by_step.get(key, 0) + 1
        if code.startswith("throttled") and source == "server":
            throttled += 1      # GET rtc/turn answers (each retry counts)
        if step in ("rtc_config", "place") and not call_id and source == "client":
            pre_place += 1
    attempts = ended + pre_place
    success_pct = round(100.0 * ok / attempts) if attempts else None
    failures = {
        "rtc_config": sum(v for k, v in by_step.items()
                          if k.startswith("rtc_config")),
        "place": sum(v for k, v in by_step.items() if k.startswith("place")),
        # placed, but the callee's phone never rang
        "push": reasons.get("offline", 0),
        "accept": sum(v for k, v in by_step.items() if k.startswith("accept")),
        # answered, media never connected
        "ice": reasons.get("failed", 0),
        # connected, then dropped (network gone > reconnect grace)
        "dropped": reasons.get("lost", 0),
    }
    return {
        "hours": hours, "since": since, "placed": placed, "ended": ended,
        "attempts": attempts, "ok": ok, "success_pct": success_pct,
        "throttled": throttled, "pre_place": pre_place,
        "funnel": {"placed": placed, "push": push, "acked": acked,
                   "answered": answered, "connected": connected},
        "reasons": reasons, "failures": failures, "events": by_step,
    }


def alert(s):
    """None, or {"kind": "throttled"|"low_success", ...} for the banner."""
    if not s:
        return None
    if s["throttled"]:
        return {"kind": "throttled", "count": s["throttled"],
                "success_pct": s["success_pct"]}
    if (s["success_pct"] is not None and s["attempts"] >= ALERT_MIN_ATTEMPTS
            and s["success_pct"] < ALERT_SUCCESS_PCT):
        return {"kind": "low_success", "count": s["attempts"] - s["ok"],
                "success_pct": s["success_pct"]}
    return None


def cached_alert():
    """alert(summary()) cached for a minute (every Owner Admin page shows the
    banner). Never raises."""
    try:
        hit = cache.get(CACHE_KEY)
        if hit is not None:
            return hit or None
        a = alert(summary())
        cache.set(CACHE_KEY, a or {}, CACHE_S)
        return a
    except Exception:
        log.exception("calls-health: cached_alert failed")
        return None
