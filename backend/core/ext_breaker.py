"""ext_breaker — circuit breaker for the NON-AI outside services a request
or a push worker can wait on: FCM, the SMS gateway, Meta Graph, maps
(Google Places / OpenStreetMap), the TURN credential API and couriers.

Owner order H: "graceful behaviour when any outside service is down".
When a service keeps failing, callers stop waiting on it (no gunicorn
worker parked on a dead host for 15–40 s) and answer honestly at once;
after `cooldown_s` one caller probes it again.

It REUSES core/ai_router.py's DB-row breaker (AIProviderState rows, slug
"x:<service>") so every gunicorn worker sees the same circuit — no new table,
no migration, no cache infrastructure. ai_router.states() only lists AI
provider slugs, so these rows never show up as AI providers.

Cost on the hot path: one indexed SELECT per call while the circuit is
healthy; a success is only written when it closes a non-clean circuit.
Never raises into a caller (a DB hiccup lets traffic through).
"""
import logging
import time

from . import ai_router as R

log = logging.getLogger(__name__)

SERVICES = ("fcm", "sms", "graph", "maps", "osm", "turn", "courier")

# Consecutive failures open the circuit (the error-rate rule is off: healthy
# successes are not booked, see module doc). 5 in a row, 30 s cool-down.
CONF = {
    "circuit": {"fail_threshold": 5, "window_s": 60, "min_calls": 10 ** 9,
                "error_rate_pct": 101, "cooldown_s": 30},
    "timeouts_s": {"main": 10},
}


class Unavailable(Exception):
    """The service's circuit is open: fail fast, answer honestly."""


def slug(name):
    return ("x:" + str(name))[:20]


def _clean(name):
    """(allowed, clean): clean = closed with no recent failure (a success
    then needs no write)."""
    try:
        r = R._state(slug(name))
        if r.state == "closed" and not r.consecutive_failures:
            return True, True
    except Exception as e:  # noqa: BLE001
        log.warning("ext_breaker.state %s: %s", name, type(e).__name__)
        return True, True
    return R.allow(slug(name), CONF), False


def allow(name):
    """May a call go to `name` now? (open circuit -> False)."""
    return _clean(name)[0]


def is_open(name):
    try:
        return R._state(slug(name)).state == "open"
    except Exception:  # noqa: BLE001
        return False


def ok(name):
    R.record(slug(name), True, CONF)


def fail(name, error=""):
    st = R.record(slug(name), False, CONF, error=str(error or "error")[:100])
    if st == "open":
        _alert_once(name, error)
    return st


_LABEL = {"fcm": "Push (FCM)", "sms": "SMS gateway", "graph": "Meta Graph",
          "maps": "Google Places", "osm": "OpenStreetMap", "turn": "TURN API",
          "courier": "Courier API"}


def _alert_once(name, error):
    """Owner alert (existing push.notify_owner: owner push + email when SMTP
    is set) the moment a circuit OPENS — once per outage, never per call.
    Runs off the request thread in production."""
    try:
        r = R._state(slug(name))
        if r.consecutive_failures != CONF["circuit"]["fail_threshold"]:
            return False          # already open before: alerted then
        subject = "Assisto: %s is down" % _LABEL.get(name, name)
        body = ("%s failed %d times in a row (%s). Assisto skips it for %d s "
                "and answers users honestly; it retries on its own." % (
                    _LABEL.get(name, name), r.consecutive_failures,
                    str(error or "error")[:80], CONF["circuit"]["cooldown_s"]))
        from django.conf import settings
        from . import push

        def _go():
            from django.db import connection
            try:
                push.notify_owner(subject, body)
            finally:
                if not getattr(settings, "PUSH_SYNC", False):
                    connection.close()
        if getattr(settings, "PUSH_SYNC", False):
            _go()
        else:
            import threading
            threading.Thread(target=_go, daemon=True,
                             name="ext-breaker-alert").start()
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("ext_breaker.alert %s: %s", name, type(e).__name__)
        return False


def call(name, fn, *args, **kwargs):
    """Run fn(*args, **kwargs) through the `name` circuit.
    Raises Unavailable at once when the circuit is open; re-raises fn's own
    exception after booking the failure."""
    allowed, clean = _clean(name)
    if not allowed:
        raise Unavailable(name)
    t0 = time.monotonic()
    try:
        out = fn(*args, **kwargs)
    except Exception as e:
        fail(name, "%s %.1fs" % (type(e).__name__, time.monotonic() - t0))
        raise
    if not clean:
        ok(name)
    return out


def book(name, success, error=""):
    """For callers that judge success themselves (HTTP status / body)."""
    if success:
        try:
            if not _clean(name)[1]:
                ok(name)
        except Exception:  # noqa: BLE001
            pass
    else:
        fail(name, error)


def states():
    """{service: state} for Owner Admin / health (never raises)."""
    out = {}
    for n in SERVICES:
        try:
            r = R._state(slug(n))
            out[n] = {"state": r.state, "fails": r.consecutive_failures,
                      "last_error": r.last_error,
                      "last_failure_at": (r.last_failure_at.isoformat()
                                          if r.last_failure_at else None)}
        except Exception:  # noqa: BLE001
            out[n] = {"state": "unknown"}
    return out
