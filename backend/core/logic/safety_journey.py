"""
safety_journey.py — Assisto Safe Journey & Personal Safety engine (no AI key;
pure Python, deterministic, fully unit-testable). This is the TOP-priority
safety feature: women's night-safety journeys + parents living alone.

Benchmarked (capability only) vs bSafe / Life360 / Noonlight-class apps.

Everything here is logic/state only. The sensors + OS hooks (foreground
service, power-button x5, shake, lock-screen tile, hidden widget, FCM ring,
SMS gateway) are platform-gated and clearly marked TODO for the integrator.
The IN-APP SOS button + in-app live journey screen work NOW on top of this.

PRIVACY (item 18) is enforced in the DATA SHAPE this module defines:
  - a journey carries an explicit `expires_at`; `location_retention` controls
    how long trip location history survives AFTER the trip ends.
  - `watcher_ids` is the ONLY audience; nothing is shared beyond it.
  - `journey_is_expired()` / `redact_expired_journey()` give the server a pure
    predicate + transform to drop all location once the link/trip is over.
  - the web link token is bound to the journey id + expiry; it dies on stop.

Bilingual via pick(). Run self-tests:
    python3 -c "import core.logic.safety_journey_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, time as dtime
from math import radians, sin, cos, asin, sqrt
import hashlib
import hmac

# Reuse the shared helpers from the existing safety module so the two stay
# consistent (haversine, pick, parse_dt).  No circular import: safety.py does
# not import this file.
from core.logic.safety import pick, haversine_m, parse_dt


# ===========================================================================
# constants / tunables
# ===========================================================================

ARRIVAL_RADIUS_M_DEFAULT = 150        # geofence radius for auto-arrival
ARRIVAL_RADIUS_M_MIN = 50
ARRIVAL_RADIUS_M_MAX = 500

OVERDUE_GRACE_DEFAULT = 10            # minutes past ETA before "Are you OK?"
OVERDUE_GRACE_MIN = 0
OVERDUE_GRACE_MAX = 60

# After "Are you OK?" fires at ETA+grace, the traveller gets this long to
# answer before watchers are alerted.
OVERDUE_RESPONSE_WINDOW_DEFAULT = 5   # minutes
OVERDUE_RESPONSE_WINDOW_MIN = 1
OVERDUE_RESPONSE_WINDOW_MAX = 30

LOW_BATTERY_THRESHOLD = 15           # percent — auto-send location when below

# Wellness check (parents living alone): no movement/app-use for this long
# (quiet hours respected) prompts "Is everything OK?"; no answer -> alert kids.
WELLNESS_PERIOD_HOURS_DEFAULT = 12
WELLNESS_PERIOD_HOURS_MIN = 2
WELLNESS_PERIOD_HOURS_MAX = 48
WELLNESS_RESPONSE_WINDOW_MIN_DEFAULT = 60   # minutes to answer before alerting

# Route deviation: how far off the expected corridor before we flag it.
ROUTE_DEVIATION_M_DEFAULT = 500
ROUTE_DEVIATION_M_MIN = 150
ROUTE_DEVIATION_M_MAX = 3000

# Trip location history auto-delete default (hours after trip end). 0 = delete
# immediately on stop.  Honours item-18 "auto-deleted after trip (configurable)".
LOCATION_RETENTION_HOURS_DEFAULT = 24
LOCATION_RETENTION_HOURS_MIN = 0
LOCATION_RETENTION_HOURS_MAX = 24 * 7

# Expiring web-link token: extra life past the journey's own expiry so a
# watcher who opened it right at the end still sees the "trip ended" page.
WEB_LINK_GRACE_MINUTES = 5

# Fake-incoming-call default delay.
FAKE_CALL_DELAY_DEFAULT = 15         # seconds
FAKE_CALL_DELAY_MIN = 0
FAKE_CALL_DELAY_MAX = 300


# Verified helplines (item 12). VERIFY against official sources before shipping
# (see report). 999 = national emergency (police/hospital/fire). 109 = National
# Helpline Centre for Violence Against Women & Children (MoWCA, toll-free 24/7).
HELPLINES = [
    {"key": "emergency", "number": "999",
     "bn": "জাতীয় জরুরি সেবা", "en": "National Emergency"},
    {"key": "vaw", "number": "109",
     "bn": "নারী ও শিশু নির্যাতন হেল্পলাইন", "en": "Violence against Women & Children"},
]


def _clamp(v, lo, hi, default):
    try:
        x = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, x))


# ===========================================================================
# item 1 — START JOURNEY: destination, ETA, watchers, presets
# ===========================================================================

def new_journey(*, traveller_id, destination, eta, watcher_ids,
                origin=None, mode=None, vehicle=None, started_at=None,
                arrival_radius_m=ARRIVAL_RADIUS_M_DEFAULT,
                overdue_grace_min=OVERDUE_GRACE_DEFAULT,
                overdue_response_min=OVERDUE_RESPONSE_WINDOW_DEFAULT,
                route_deviation_m=ROUTE_DEVIATION_M_DEFAULT,
                route_deviation_on=False,
                location_retention_hours=LOCATION_RETENTION_HOURS_DEFAULT,
                planned_route=None):
    """Build an immutable-ish journey dict the server stores.

    destination: {"name","lat","lng"}  (lat/lng optional -> no geofence)
    eta: iso/datetime the traveller expects to arrive by.
    watcher_ids: the ONLY audience (circle member ids). Deduped, order kept.
    planned_route: optional list of {"lat","lng"} waypoints for route-deviation.

    expires_at = eta + grace + response window + retention — a hard cap after
    which NO location may be served (privacy item 18).
    """
    started = parse_dt(started_at) or datetime.now()
    eta_dt = parse_dt(eta)
    watchers = []
    for w in (watcher_ids or []):
        if w is not None and w not in watchers:
            watchers.append(w)
    grace = _clamp(overdue_grace_min, OVERDUE_GRACE_MIN, OVERDUE_GRACE_MAX,
                   OVERDUE_GRACE_DEFAULT)
    resp = _clamp(overdue_response_min, OVERDUE_RESPONSE_WINDOW_MIN,
                  OVERDUE_RESPONSE_WINDOW_MAX, OVERDUE_RESPONSE_WINDOW_DEFAULT)
    retain = _clamp(location_retention_hours, LOCATION_RETENTION_HOURS_MIN,
                    LOCATION_RETENTION_HOURS_MAX, LOCATION_RETENTION_HOURS_DEFAULT)
    radius = _clamp(arrival_radius_m, ARRIVAL_RADIUS_M_MIN,
                    ARRIVAL_RADIUS_M_MAX, ARRIVAL_RADIUS_M_DEFAULT)
    dev = _clamp(route_deviation_m, ROUTE_DEVIATION_M_MIN,
                 ROUTE_DEVIATION_M_MAX, ROUTE_DEVIATION_M_DEFAULT)
    expires = None
    if eta_dt is not None:
        expires = eta_dt + timedelta(minutes=grace + resp) + timedelta(hours=retain)
    return {
        "status": "active",               # active|arrived|stopped|expired
        "traveller_id": traveller_id,
        "origin": origin,                 # {"name","lat","lng"} or None
        "destination": destination,       # {"name","lat","lng"}
        "eta": eta_dt.isoformat() if eta_dt else None,
        "watcher_ids": watchers,
        "mode": mode,                     # "cng"|"rickshaw"|"car"|"bus"|"walk"|...
        "vehicle": vehicle,               # item 3: {"plate","photo_id","note"}
        "started_at": started.isoformat(),
        "stopped_at": None,
        "arrival_radius_m": radius,
        "overdue_grace_min": grace,
        "overdue_response_min": resp,
        "route_deviation_m": dev,
        "route_deviation_on": bool(route_deviation_on),
        "planned_route": list(planned_route or []),
        "location_retention_hours": retain,
        "expires_at": expires.isoformat() if expires else None,
        "last_location": None,            # {"lat","lng","at","battery"}
        "last_activity_at": started.isoformat(),
        "sos_active": False,
        "silent": False,                  # set when a duress alert is in flight
    }


def preset_journey(preset, traveller_id, watcher_ids, now=None):
    """One-tap frequent-trip preset -> a ready-to-start journey.

    preset: {"name","destination":{...},"minutes":N} — "minutes" is how long the
    trip usually takes; ETA = now + minutes. Used by item 1 presets + item 14
    routine auto-start.
    """
    now = now or datetime.now()
    minutes = _clamp(preset.get("minutes", 30), 1, 24 * 60, 30)
    eta = now + timedelta(minutes=minutes)
    return new_journey(
        traveller_id=traveller_id,
        destination=preset.get("destination"),
        eta=eta,
        watcher_ids=watcher_ids,
        mode=preset.get("mode"),
        started_at=now,
    )


# ===========================================================================
# item 4 — AUTO-ARRIVAL (geofence) + item 2 live location update
# ===========================================================================

def record_location(journey, lat, lng, at=None, battery=None):
    """Append a location fix to the journey (mutates last_location +
    last_activity_at). Returns the journey. Battery is 0-100 or None."""
    at = parse_dt(at) or datetime.now()
    journey["last_location"] = {
        "lat": lat, "lng": lng, "at": at.isoformat(),
        "battery": battery,
    }
    journey["last_activity_at"] = at.isoformat()
    return journey


def arrival_check(journey, cur_lat=None, cur_lng=None):
    """Auto-arrival: True if the current fix is within the destination geofence.

    Falls back to the journey's last_location if no explicit fix passed.
    Returns (arrived: bool, distance_m or None).
    """
    dest = journey.get("destination") or {}
    dlat, dlng = dest.get("lat"), dest.get("lng")
    if dlat is None or dlng is None:
        return (False, None)
    if cur_lat is None or cur_lng is None:
        loc = journey.get("last_location") or {}
        cur_lat, cur_lng = loc.get("lat"), loc.get("lng")
    if cur_lat is None or cur_lng is None:
        return (False, None)
    dist = haversine_m(cur_lat, cur_lng, dlat, dlng)
    radius = journey.get("arrival_radius_m", ARRIVAL_RADIUS_M_DEFAULT)
    return (dist <= radius, dist)


def mark_arrived(journey, at=None):
    """Traveller arrived (auto or manual 'I'm safe'). Ends live tracking."""
    at = parse_dt(at) or datetime.now()
    journey["status"] = "arrived"
    journey["stopped_at"] = at.isoformat()
    journey["sos_active"] = False
    return journey


def stop_journey(journey, at=None):
    """Traveller stopped the journey manually (not necessarily at destination).
    Live tracking ends; privacy auto-delete clock starts."""
    at = parse_dt(at) or datetime.now()
    journey["status"] = "stopped"
    journey["stopped_at"] = at.isoformat()
    journey["sos_active"] = False
    return journey


# ===========================================================================
# item 5 — OVERDUE: ETA+grace -> "Are you OK?" -> no answer -> alert
# ===========================================================================

def overdue_state(journey, now=None, responded_ok=False):
    """Journey overdue state machine.

    Returns (state, minutes) where state is one of:
      'arrived'/'stopped'   terminal (never overdue)
      'no_eta'              no ETA set -> cannot be overdue
      'on_time' , mins_left before ETA
      'grace'   , mins_in   past ETA, inside grace (quiet — not asking yet)
      'ask'     , mins_since past ETA+grace, inside response window -> prompt
                             the traveller "Are you OK?"
      'alert'   , mins_over  no response after the window -> ALERT WATCHERS
    `responded_ok=True` means the traveller answered the "Are you OK?" prompt
    (resets to on_time-ish 'ok').
    """
    status = journey.get("status")
    if status in ("arrived", "stopped", "expired"):
        return (status, 0)
    eta = parse_dt(journey.get("eta"))
    if eta is None:
        return ("no_eta", 0)
    if responded_ok:
        return ("ok", 0)
    now = now or datetime.now()
    if (eta.tzinfo is None) != (now.tzinfo is None):
        eta = eta.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    grace = journey.get("overdue_grace_min", OVERDUE_GRACE_DEFAULT)
    resp = journey.get("overdue_response_min", OVERDUE_RESPONSE_WINDOW_DEFAULT)
    delta = (now - eta).total_seconds() / 60.0
    if delta < 0:
        return ("on_time", int(round(-delta)))
    if delta <= grace:
        return ("grace", int(delta))
    if delta <= grace + resp:
        return ("ask", int(delta - grace))
    return ("alert", int(delta - grace))


def should_alert_overdue(journey, now=None, responded_ok=False):
    return overdue_state(journey, now=now, responded_ok=responded_ok)[0] == "alert"


# ===========================================================================
# item 6 — LOW BATTERY <15% -> auto-send latest location
# ===========================================================================

def low_battery_trigger(journey, battery_pct, last_sent_pct=None,
                        threshold=LOW_BATTERY_THRESHOLD):
    """True when we should auto-send the latest location because the phone is
    about to die. Fires when crossing below the threshold (not repeatedly every
    poll): only if we haven't already sent at/below it.

    last_sent_pct: the battery % at the last auto-send (None if never).
    """
    if journey.get("status") != "active":
        return False
    try:
        b = int(battery_pct)
    except (TypeError, ValueError):
        return False
    if b >= threshold:
        return False
    if last_sent_pct is None:
        return True
    try:
        return int(last_sent_pct) > b   # only re-send if it dropped further
    except (TypeError, ValueError):
        return True


# ===========================================================================
# item 8 — DURESS PIN: normal PIN cancels; duress PIN fake-cancels + silent SOS
# ===========================================================================

def hash_pin(pin, salt):
    """One-way PIN hash the server stores (never the raw PIN). PBKDF2-HMAC."""
    pin = str(pin or "")
    salt = str(salt or "")
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), salt.encode(), 120_000).hex()


def verify_pin_action(entered_pin, normal_hash, duress_hash, salt):
    """Classify a PIN entered to stop a journey / cancel an SOS.

    Returns one of:
      'cancel'  -> the NORMAL pin: genuinely cancel (safe).
      'duress'  -> the DURESS pin: the UI MUST look exactly like 'cancel'
                   (screen shows cancelled) while the caller SILENTLY fires an
                   emergency alert + live location to watchers.
      'wrong'   -> neither matched: do NOT cancel; keep the alert path armed.
    The two pins must differ; if a user set them equal we treat a match as a
    normal cancel (fail safe toward the user's explicit cancel intent).
    """
    entered = hash_pin(entered_pin, salt)
    if normal_hash and hmac.compare_digest(entered, str(normal_hash)):
        return "cancel"
    if duress_hash and hmac.compare_digest(entered, str(duress_hash)):
        return "duress"
    return "wrong"


def duress_outcome(action):
    """Map a verify_pin_action result to what the system does.
    Returns {"ui","alert","silent"}:
      ui    = what the screen shows ('cancelled' | 'stay' )
      alert = whether watchers get an emergency alert
      silent= whether that alert is silent (traveller must not notice)
    """
    if action == "cancel":
        return {"ui": "cancelled", "alert": False, "silent": False}
    if action == "duress":
        # looks identical to a real cancel, but fires a silent emergency alert
        return {"ui": "cancelled", "alert": True, "silent": True}
    return {"ui": "stay", "alert": False, "silent": False}


# ===========================================================================
# item 16 — WELLNESS CHECK (parents living alone), quiet-hours respected
# ===========================================================================

def default_wellness_config():
    """Parent-opt-in wellness watch. Children may set this up WITH the parent's
    permission (parent_opt_in must be True to arm)."""
    return {
        "enabled": False,
        "parent_opt_in": False,          # hard gate: parent must consent
        "period_hours": WELLNESS_PERIOD_HOURS_DEFAULT,
        "response_window_min": WELLNESS_RESPONSE_WINDOW_MIN_DEFAULT,
        "quiet_start": "22:00",          # no prompts inside quiet hours
        "quiet_end": "07:00",
        "watcher_ids": [],               # children/family to alert
    }


def _parse_hhmm(v, default):
    try:
        h, m = str(v).split(":")
        return dtime(int(h) % 24, int(m) % 60)
    except (ValueError, AttributeError):
        return default


def in_quiet_hours(cfg, now=None):
    """True if `now` falls inside the configured quiet window (wraps midnight)."""
    now = now or datetime.now()
    t = now.time()
    start = _parse_hhmm(cfg.get("quiet_start"), dtime(22, 0))
    end = _parse_hhmm(cfg.get("quiet_end"), dtime(7, 0))
    if start <= end:
        return start <= t < end
    # wraps midnight (e.g. 22:00 -> 07:00)
    return t >= start or t < end


def wellness_state(cfg, last_activity_at, now=None, responded=False,
                   prompt_sent_at=None):
    """Wellness-check state machine for a parent living alone.

    last_activity_at: last time the parent moved / used the phone (iso/dt).
    prompt_sent_at:   when "Is everything OK?" was last shown (iso/dt or None).
    responded:        parent answered the prompt.

    Returns (state, hours_or_minutes):
      'off'                 not enabled or parent hasn't opted in
      'ok'                  parent answered, or recent activity
      'quiet'               period elapsed but we're inside quiet hours -> wait
      'prompt'              period elapsed, awake hours -> ask "Is everything OK?"
      'alert'               prompt unanswered past response window -> alert kids
    """
    if not cfg.get("enabled") or not cfg.get("parent_opt_in"):
        return ("off", 0)
    if responded:
        return ("ok", 0)
    now = now or datetime.now()
    last = parse_dt(last_activity_at)
    if last is None:
        return ("ok", 0)
    period_h = _clamp(cfg.get("period_hours"), WELLNESS_PERIOD_HOURS_MIN,
                      WELLNESS_PERIOD_HOURS_MAX, WELLNESS_PERIOD_HOURS_DEFAULT)
    idle_h = (now - last).total_seconds() / 3600.0
    if idle_h < period_h:
        return ("ok", int(idle_h))
    # period elapsed. If a prompt is ALREADY in flight, evaluate its response
    # window regardless of quiet hours — we never silence a live escalation.
    sent = parse_dt(prompt_sent_at)
    if sent is not None:
        resp_min = _clamp(cfg.get("response_window_min"), 1, 24 * 60,
                          WELLNESS_RESPONSE_WINDOW_MIN_DEFAULT)
        since_prompt_min = (now - sent).total_seconds() / 60.0
        if since_prompt_min <= resp_min:
            return ("prompt", int(since_prompt_min))
        return ("alert", int(since_prompt_min))
    # no prompt yet -> are we allowed to START one right now?
    if in_quiet_hours(cfg, now):
        return ("quiet", int(idle_h))
    return ("prompt", int(idle_h))


# ===========================================================================
# item 15 — ROUTE DEVIATION
# ===========================================================================

def route_deviation(journey, cur_lat, cur_lng):
    """Distance (m) from the nearest planned waypoint, and whether it exceeds
    the configured threshold. Returns (deviated: bool, nearest_m or None).

    Only meaningful when route_deviation_on and a planned_route exist.
    """
    if not journey.get("route_deviation_on"):
        return (False, None)
    route = journey.get("planned_route") or []
    if not route or cur_lat is None or cur_lng is None:
        return (False, None)
    nearest = min(
        haversine_m(cur_lat, cur_lng, p.get("lat"), p.get("lng"))
        for p in route
        if p.get("lat") is not None and p.get("lng") is not None
    )
    thresh = journey.get("route_deviation_m", ROUTE_DEVIATION_M_DEFAULT)
    return (nearest > thresh, nearest)


# ===========================================================================
# item 14 — ROUTINE COMMUTES (scheduled journeys)
# ===========================================================================

_WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


def routine_due(routine, now=None, last_started=None, window_min=10):
    """Should a scheduled routine journey auto-start (with a confirm notif)?

    routine: {"days":["sun","mon",...],"time":"18:00","enabled":True}
    window_min: how many minutes after the scheduled time it stays 'due'
                (so a poll that fires late still catches it).
    last_started: iso/dt of the last auto-start, to avoid double-firing same day.
    Returns True when due and not already started today.
    """
    if not routine.get("enabled"):
        return False
    now = now or datetime.now()
    days = {str(d).lower()[:3] for d in (routine.get("days") or [])}
    today = {k for k, v in _WEEKDAYS.items() if v == now.weekday()}
    if not (days & today):
        return False
    sched = _parse_hhmm(routine.get("time"), None)
    if sched is None:
        return False
    sched_dt = datetime(now.year, now.month, now.day, sched.hour, sched.minute)
    if not (sched_dt <= now <= sched_dt + timedelta(minutes=max(1, window_min))):
        return False
    last = parse_dt(last_started)
    if last is not None and last.date() == now.date() and last >= sched_dt:
        return False
    return True


# ===========================================================================
# item 13 — EXPIRING WEB LINK (watchers without the app)
# ===========================================================================

def make_web_token(journey_id, expires_at, secret):
    """Signed, opaque, EXPIRING token for the public live-location web page.

    Format:  <journey_id>.<exp_epoch>.<hmac>
    The token carries ONLY the journey id + expiry; it reveals nothing and
    cannot be forged without `secret`. It dies when the journey expires.
    """
    exp = parse_dt(expires_at)
    exp_epoch = int(exp.timestamp()) if exp else 0
    msg = f"{journey_id}.{exp_epoch}"
    sig = hmac.new(str(secret).encode(), msg.encode(), hashlib.sha256).hexdigest()[:24]
    return f"{msg}.{sig}"


def parse_web_token(token, secret, now=None):
    """Validate a web token. Returns (journey_id, ok, reason):
      ok=True                     -> serve the live page for journey_id
      reason='bad'                -> malformed / wrong signature
      reason='expired'            -> link died (trip ended) — show 'trip ended'
    NEVER serves location past expiry (privacy item 18 enforcement point).
    """
    now = now or datetime.now()
    try:
        jid, exp_s, sig = str(token).split(".")
        exp_epoch = int(exp_s)
    except (ValueError, AttributeError):
        return (None, False, "bad")
    msg = f"{jid}.{exp_s}"
    expect = hmac.new(str(secret).encode(), msg.encode(), hashlib.sha256).hexdigest()[:24]
    if not hmac.compare_digest(sig, expect):
        return (None, False, "bad")
    hard_exp = exp_epoch + WEB_LINK_GRACE_MINUTES * 60
    if now.timestamp() > hard_exp:
        return (jid, False, "expired")
    if now.timestamp() > exp_epoch:
        # inside the small grace: valid token but trip is over -> ended page
        return (jid, False, "ended")
    return (jid, True, "ok")


# ===========================================================================
# item 18 — PRIVACY: expiry + auto-delete of trip location
# ===========================================================================

def journey_is_expired(journey, now=None):
    """True once the journey's hard `expires_at` has passed OR it ended and the
    retention window elapsed. After this, the server must serve NO location."""
    now = now or datetime.now()
    status = journey.get("status")
    if status in ("arrived", "stopped"):
        stopped = parse_dt(journey.get("stopped_at")) or now
        retain_h = journey.get("location_retention_hours",
                               LOCATION_RETENTION_HOURS_DEFAULT)
        return now >= stopped + timedelta(hours=retain_h)
    exp = parse_dt(journey.get("expires_at"))
    if exp is None:
        return False
    if (exp.tzinfo is None) != (now.tzinfo is None):
        exp = exp.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    return now >= exp


def redact_expired_journey(journey, now=None):
    """Return a copy with ALL location stripped once expired (the server stores
    this / returns it). Enforces 'NO server location after expiry'. Keeps only
    non-location metadata so the trip can still show 'ended' with no map."""
    if not journey_is_expired(journey, now=now):
        return journey
    out = dict(journey)
    out["status"] = "expired"
    out["last_location"] = None
    out["planned_route"] = []
    if out.get("origin"):
        out["origin"] = {"name": (out["origin"] or {}).get("name")}
    if out.get("destination"):
        out["destination"] = {"name": (out["destination"] or {}).get("name")}
    return out


# ===========================================================================
# item 17 — OFFLINE: queue + retry (pure helpers the app/server share)
# ===========================================================================

def enqueue_alert(queue, alert, now=None):
    """Append an alert to the outbound queue with retry bookkeeping. Pure:
    returns a NEW list. `alert` is any dict payload (see payload builders)."""
    now = parse_dt(now) or datetime.now()
    item = dict(alert)
    item.setdefault("id", hashlib.sha1(
        f"{item.get('kind')}:{now.isoformat()}:{len(queue or [])}".encode()
    ).hexdigest()[:12])
    item["attempts"] = 0
    item["queued_at"] = now.isoformat()
    item["next_retry_at"] = now.isoformat()
    item["sent"] = False
    return list(queue or []) + [item]


def next_backoff_seconds(attempts, base=5, cap=300):
    """Exponential backoff with a cap: 5,10,20,40,...,<=300s."""
    try:
        n = max(0, int(attempts))
    except (TypeError, ValueError):
        n = 0
    return min(cap, base * (2 ** n))


def due_alerts(queue, now=None):
    """Alerts ready to (re)send now: unsent and next_retry_at <= now."""
    now = parse_dt(now) or datetime.now()
    out = []
    for a in (queue or []):
        if a.get("sent"):
            continue
        nr = parse_dt(a.get("next_retry_at"))
        if nr is None or nr <= now:
            out.append(a)
    return out


def mark_alert_result(queue, alert_id, success, now=None):
    """Return a NEW queue with the alert's result applied. On failure, schedule
    the next retry with backoff; on success, mark sent."""
    now = parse_dt(now) or datetime.now()
    out = []
    for a in (queue or []):
        if a.get("id") != alert_id:
            out.append(a)
            continue
        b = dict(a)
        if success:
            b["sent"] = True
        else:
            b["attempts"] = int(b.get("attempts", 0)) + 1
            delay = next_backoff_seconds(b["attempts"])
            b["next_retry_at"] = (now + timedelta(seconds=delay)).isoformat()
        out.append(b)
    return out


# ===========================================================================
# item 10 — "WHERE ARE YOU?" consent request
# ===========================================================================

def where_are_you_request(requester_id, requester_name, lang="bn"):
    """A watcher asks for the traveller's location. The traveller must ACCEPT
    (consent always) before anything is shared. Returns the prompt payload."""
    return {
        "kind": "where_are_you",
        "requester_id": requester_id,
        "title": pick(lang, "অবস্থান জানতে চাওয়া হয়েছে",
                      "Location requested"),
        "body": pick(lang,
            f"{requester_name} আপনার অবস্থান জানতে চান। আপনি অনুমতি দিলে তবেই শেয়ার হবে।",
            f"{requester_name} wants to know where you are. It is shared only if you accept."),
        "actions": ["accept", "decline"],
    }


def resolve_where_are_you(accepted):
    """Consent gate. Returns 'share' only when the traveller tapped accept."""
    return "share" if accepted else "withheld"


# ===========================================================================
# item 11 — NEAREST HELP (reuse the Nearby/OSM layer)
# ===========================================================================

def nearest_help_query(lat, lng):
    """Parameters the app/server pass to the EXISTING Nearby provider
    (GET /nearby?lat&lon&type=; Google Places -> OSM fallback). We only
    construct the two emergency place types — no new provider."""
    return [
        {"type": "police", "lat": lat, "lon": lng},
        {"type": "hospital", "lat": lat, "lon": lng},
    ]


def rank_nearest(places, lat, lng, limit=3):
    """Given raw Nearby results [{name,lat,lng,phone?}], sort by distance and
    return the closest `limit` with a computed distance_m + a maps directions
    link. Skips entries without coords."""
    out = []
    for p in (places or []):
        plat, plng = p.get("lat"), p.get("lng")
        if plat is None or plng is None:
            continue
        d = haversine_m(lat, lng, plat, plng)
        out.append({**p, "distance_m": int(d),
                    "directions": f"https://maps.google.com/?daddr={plat},{plng}"})
    out.sort(key=lambda x: x["distance_m"])
    return out[:max(1, limit)]


# ===========================================================================
# item 9 — FAKE INCOMING CALL
# ===========================================================================

def fake_call_plan(caller_name, delay_seconds=FAKE_CALL_DELAY_DEFAULT, now=None):
    """Schedule a realistic fake incoming call in N seconds to extract from an
    uncomfortable situation. Returns {caller, ring_at} the UI uses to pop a
    call screen. No network — purely local."""
    now = parse_dt(now) or datetime.now()
    d = _clamp(delay_seconds, FAKE_CALL_DELAY_MIN, FAKE_CALL_DELAY_MAX,
               FAKE_CALL_DELAY_DEFAULT)
    name = (caller_name or "").strip() or pick("bn", "মা", "Mom")
    return {"caller": name, "delay_seconds": d,
            "ring_at": (now + timedelta(seconds=d)).isoformat()}


# ===========================================================================
# item 3/5/7/8 — alert payload builders (integrator pushes; foreground-poll now)
# ===========================================================================

def _loc_line(loc, lang):
    if not loc or loc.get("lat") is None:
        return ""
    link = f"https://maps.google.com/?q={loc['lat']},{loc['lng']}"
    return pick(lang, f" অবস্থান: {link}", f" Location: {link}")


def journey_started_payload(person_name, dest_name, web_link=None, lang="bn"):
    dest = dest_name or pick(lang, "গন্তব্য", "the destination")
    extra = ""
    if web_link:
        extra = pick(lang, f" লিংক: {web_link}", f" Track: {web_link}")
    return {
        "kind": "journey_started",
        "title": pick(lang, "যাত্রা শুরু হয়েছে", "Journey started"),
        "body": pick(lang,
            f"{person_name} {dest}-এর উদ্দেশ্যে রওনা দিয়েছেন। Assisto যাত্রাটি দেখছে।{extra}",
            f"{person_name} started a trip to {dest}. Assisto is watching it.{extra}"),
    }


def arrived_payload(person_name, dest_name, lang="bn"):
    dest = dest_name or pick(lang, "গন্তব্য", "the destination")
    return {
        "kind": "journey_arrived",
        "title": pick(lang, "নিরাপদে পৌঁছেছেন ✅", "Arrived safely ✅"),
        "body": pick(lang,
            f"{person_name} {dest}-এ নিরাপদে পৌঁছেছেন।",
            f"{person_name} arrived safely at {dest}."),
    }


def overdue_payload(person_name, dest_name, minutes_overdue, loc=None, lang="bn"):
    dest = dest_name or pick(lang, "গন্তব্য", "the destination")
    return {
        "kind": "journey_overdue",
        "title": pick(lang, "যাত্রার খবর আসেনি", "No arrival — please check"),
        "body": pick(lang,
            f"{person_name} {dest}-এ পৌঁছানোর কথা জানায়নি (প্রায় {minutes_overdue} মিনিট দেরি), সাড়াও দিচ্ছে না। খোঁজ নিন।{_loc_line(loc, lang)}",
            f"{person_name} hasn't confirmed reaching {dest} (about {minutes_overdue} min late) and isn't responding. Please check on them.{_loc_line(loc, lang)}"),
    }


def sos_journey_payload(person_name, loc=None, silent=False, lang="bn"):
    return {
        "kind": "sos",
        "silent": bool(silent),
        "title": pick(lang, "জরুরি SOS", "Emergency SOS"),
        "body": pick(lang,
            f"{person_name} SOS পাঠিয়েছেন — এখনই সাহায্য দরকার।{_loc_line(loc, lang)}",
            f"{person_name} triggered an SOS — they need help now.{_loc_line(loc, lang)}"),
    }


def low_battery_payload(person_name, battery_pct, loc=None, lang="bn"):
    return {
        "kind": "low_battery",
        "title": pick(lang, "ফোনের চার্জ কমে যাচ্ছে", "Low battery on the trip"),
        "body": pick(lang,
            f"{person_name}-এর ফোনে {battery_pct}% চার্জ — শেষ অবস্থান পাঠানো হলো।{_loc_line(loc, lang)}",
            f"{person_name}'s phone is at {battery_pct}% — sending their last location.{_loc_line(loc, lang)}"),
    }


def wellness_payload(person_name, loc=None, lang="bn"):
    return {
        "kind": "wellness_alert",
        "title": pick(lang, "অনেকক্ষণ সাড়া নেই", "No activity for a while"),
        "body": pick(lang,
            f"{person_name} অনেকক্ষণ ফোন ব্যবহার করেননি এবং খোঁজ নেওয়ার বার্তার সাড়া দেননি। একটু খোঁজ নিন।{_loc_line(loc, lang)}",
            f"{person_name} hasn't used their phone for a long time and didn't answer a wellness check. Please check on them.{_loc_line(loc, lang)}"),
    }


def route_deviation_payload(person_name, meters, loc=None, lang="bn"):
    return {
        "kind": "route_deviation",
        "title": pick(lang, "পথ পরিবর্তন", "Off the usual route"),
        "body": pick(lang,
            f"{person_name} নির্ধারিত পথ থেকে প্রায় {meters} মিটার সরে গেছেন।{_loc_line(loc, lang)}",
            f"{person_name} has moved about {meters} m off the expected route.{_loc_line(loc, lang)}"),
    }


def vehicle_payload(person_name, vehicle, lang="bn"):
    """item 3 — share the ride's plate/photo with watchers in one tap."""
    v = vehicle or {}
    plate = v.get("plate") or pick(lang, "অজানা", "unknown")
    mode = v.get("mode") or ""
    return {
        "kind": "vehicle_shared",
        "title": pick(lang, "যানবাহনের তথ্য", "Ride details shared"),
        "body": pick(lang,
            f"{person_name} যে {mode} নিয়েছেন তার নম্বর: {plate}।",
            f"{person_name} shared their ride ({mode}) — plate: {plate}."),
    }


def helplines(lang="bn"):
    """Localised helpline list for item 12 (verified numbers only)."""
    return [{"key": h["key"], "number": h["number"], "label": pick(lang, h["bn"], h["en"])}
            for h in HELPLINES]
