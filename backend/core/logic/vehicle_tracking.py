"""
vehicle_tracking.py — PURE logic for Assisto vehicle tracking (v1-vehicle).

No Django, no DB, no clock (callers pass `now`), no network. Everything here is
deterministic and unit-tested in core/tests_v1_vehicle.py:

  * haversine_m / downsample
  * compute_trips(fixes)          -> trips, stops, total km (server-side mileage)
  * decide_cutoff(...)            -> may the engine be cut right now?
  * inside_fence / evaluate_alerts -> geofence enter/exit, over-speed, night ignition
  * unusual_trip_facts / rule_summary -> facts fed to the AI summary (and the
                                     honest no-key fallback text)

A "fix" is a dict: {at: datetime (aware), lat, lng, speed_kmh, ignition (bool|None),
valid (bool)}.
"""
import math
from datetime import timedelta

EARTH_R_M = 6371000.0

# Defaults (the live values are admin-editable in PricingConfig["vehicle"];
# see core.logic.pricing.vehicle_cfg).
MOVING_KMH = 5.0            # at/above this a fix counts as moving
STOP_MIN_S = 180            # a stationary run this long ends a trip
MAX_GAP_S = 600             # a data gap this long ends a trip
MAX_JUMP_KMH = 250.0        # implied speed above this = GPS jump, dropped
JITTER_M = 15.0             # parked GPS wander below this is not distance


def haversine_m(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R_M * math.asin(min(1.0, math.sqrt(a)))


def _clean(fixes):
    """Valid fixes in time order, GPS jumps removed."""
    pts = sorted((f for f in fixes if f.get("valid", True)
                  and f.get("lat") is not None and f.get("lng") is not None
                  and not (f["lat"] == 0 and f["lng"] == 0)),
                 key=lambda f: f["at"])
    out = []
    for f in pts:
        if out:
            prev = out[-1]
            dt = (f["at"] - prev["at"]).total_seconds()
            if dt <= 0:
                continue
            d = haversine_m(prev["lat"], prev["lng"], f["lat"], f["lng"])
            if d / dt * 3.6 > MAX_JUMP_KMH:
                continue
        out.append(f)
    return out


def _is_moving(f, moving_kmh):
    return float(f.get("speed_kmh") or 0) >= moving_kmh


def compute_trips(fixes, moving_kmh=MOVING_KMH, stop_min_s=STOP_MIN_S,
                  max_gap_s=MAX_GAP_S, night=None):
    """Split a fix list into trips and stops.

    A trip starts at the first moving fix and ends when the vehicle has been
    stationary for >= stop_min_s, or when the data has a gap >= max_gap_s.
    Distance is the sum of point-to-point great-circle distance inside trips,
    ignoring sub-JITTER_M wander. `night` = optional (start_h, end_h) to flag
    trips that START at night (local hour is taken from fix["local_hour"] when
    present, else the fix's own .hour).

    Returns {trips, stops, total_km, moving_s, max_speed_kmh, points}."""
    pts = _clean(fixes)
    trips, stops = [], []
    cur = None            # open trip
    still_since = None    # first stationary fix inside an open trip
    last = None

    def close_trip(end_fix):
        nonlocal cur
        if cur is None:
            return
        cur["end"] = end_fix["at"]
        cur["end_lat"], cur["end_lng"] = end_fix["lat"], end_fix["lng"]
        cur["duration_s"] = int((cur["end"] - cur["start"]).total_seconds())
        cur["km"] = round(cur.pop("_m") / 1000.0, 2)
        hrs = cur["duration_s"] / 3600.0
        cur["avg_kmh"] = round(cur["km"] / hrs, 1) if hrs > 0 else 0.0
        if cur["km"] > 0.05 or cur["duration_s"] >= 60:
            trips.append(cur)
        cur = None

    for f in pts:
        if last is not None:
            gap = (f["at"] - last["at"]).total_seconds()
            if gap >= max_gap_s and cur is not None:
                close_trip(last)
                still_since = None
        moving = _is_moving(f, moving_kmh)
        if cur is None:
            if moving:
                start = last if (last is not None and
                                 (f["at"] - last["at"]).total_seconds() < max_gap_s) else f
                cur = {"start": start["at"], "start_lat": start["lat"],
                       "start_lng": start["lng"], "_m": 0.0,
                       "max_kmh": float(f.get("speed_kmh") or 0),
                       "night": _is_night(start, night)}
                if start is not f:
                    cur["_m"] += _step(start, f)
                still_since = None
        else:
            cur["_m"] += _step(last, f)
            cur["max_kmh"] = max(cur["max_kmh"], float(f.get("speed_kmh") or 0))
            if moving:
                still_since = None
            else:
                if still_since is None:
                    still_since = f
                elif (f["at"] - still_since["at"]).total_seconds() >= stop_min_s:
                    close_trip(still_since)
                    still_since = None
        last = f
    if cur is not None and last is not None:
        close_trip(still_since or last)

    # stops = the spaces between trips (and before the first / after the last)
    if pts:
        bounds = []
        prev_end = (pts[0]["at"], pts[0]["lat"], pts[0]["lng"])
        for t in trips:
            bounds.append((prev_end, t["start"]))
            prev_end = (t["end"], t["end_lat"], t["end_lng"])
        bounds.append((prev_end, pts[-1]["at"]))
        for (s_at, s_lat, s_lng), e_at in bounds:
            dur = int((e_at - s_at).total_seconds())
            if dur >= stop_min_s:
                stops.append({"start": s_at, "end": e_at, "duration_s": dur,
                              "lat": s_lat, "lng": s_lng})
    total_km = round(sum(t["km"] for t in trips), 2)
    return {
        "trips": trips, "stops": stops, "total_km": total_km,
        "moving_s": sum(t["duration_s"] for t in trips),
        "max_speed_kmh": max([t["max_kmh"] for t in trips] or [0.0]),
        "points": len(pts),
    }


def _step(a, b):
    d = haversine_m(a["lat"], a["lng"], b["lat"], b["lng"])
    return d if d >= JITTER_M else 0.0


def _is_night(f, night):
    if not night:
        return False
    h = f.get("local_hour", f["at"].hour)
    return in_window(h, night[0], night[1])


def in_window(hour, start_h, end_h):
    """Is `hour` inside [start_h, end_h) on a 24h clock that may wrap midnight."""
    if start_h == end_h:
        return False
    if start_h < end_h:
        return start_h <= hour < end_h
    return hour >= start_h or hour < end_h


def downsample(points, max_n=600):
    """Keep at most max_n points, always keeping the first and last."""
    n = len(points)
    if n <= max_n or max_n < 2:
        return list(points)
    step = (n - 1) / float(max_n - 1)
    return [points[int(round(i * step))] for i in range(max_n)]


# ----------------------------------------------------------------- engine cut

def decide_cutoff(last_fix_at, last_speed_kmh, now, max_speed_kmh=5.0,
                  max_fix_age_s=120, online=True, kind="engine_cut"):
    """Server-side safety gate for remote immobilisation.

    Engine CUT is allowed only when the latest fix is FRESH (<= max_fix_age_s)
    and the vehicle is stopped / crawling (< max_speed_kmh). Restore is always
    allowed (it can only make the car drivable again). Returns (ok, reason)
    where reason in {'ok','no_fix','stale_fix','moving','offline'}."""
    if kind != "engine_cut":
        return True, "ok"
    if not online:
        return False, "offline"
    if last_fix_at is None:
        return False, "no_fix"
    age = (now - last_fix_at).total_seconds()
    if age > max_fix_age_s:
        return False, "stale_fix"
    if float(last_speed_kmh or 0) >= max_speed_kmh:
        return False, "moving"
    return True, "ok"


# ----------------------------------------------------------------- alerts

def point_in_polygon(points, lat, lng):
    """Ray casting on [[lat, lng], ...] (>= 3 vertices; closing edge implied).
    Fine at city scale (no antimeridian fences in Bangladesh)."""
    pts = [(float(p[0]), float(p[1])) for p in points or []]
    if len(pts) < 3:
        return False
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        yi, xi = pts[i]
        yj, xj = pts[j]
        if (yi > lat) != (yj > lat):
            x_cross = (xj - xi) * (lat - yi) / ((yj - yi) or 1e-12) + xi
            if lng < x_cross:
                inside = not inside
        j = i
    return inside


def inside_fence(fence, lat, lng):
    """Circle {lat, lng, radius_m} or polygon {points: [[lat, lng], ...]}."""
    try:
        if fence.get("points"):
            return point_in_polygon(fence["points"], lat, lng)
        return haversine_m(float(fence["lat"]), float(fence["lng"]), lat, lng) \
            <= float(fence.get("radius_m") or 200)
    except (KeyError, TypeError, ValueError, IndexError):
        return False


def _seg_dist_m(lat, lng, a, b):
    """Metres from (lat, lng) to segment a-b (local equirectangular plane —
    accurate to well under 1 % at city / highway-corridor scale)."""
    k = math.cos(math.radians(lat))
    ax, ay = (a[1] - lng) * k * 111320.0, (a[0] - lat) * 110574.0
    bx, by = (b[1] - lng) * k * 111320.0, (b[0] - lat) * 110574.0
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L2))
    px, py = ax + t * dx, ay + t * dy
    return math.hypot(px, py)


def route_distance_m(points, lat, lng):
    """Shortest distance (m) from a fix to a planned-route polyline
    [[lat, lng], ...]. inf for an empty route."""
    pts = [(float(p[0]), float(p[1])) for p in points or []]
    if not pts:
        return float("inf")
    if len(pts) == 1:
        return haversine_m(pts[0][0], pts[0][1], lat, lng)
    return min(_seg_dist_m(lat, lng, pts[i], pts[i + 1]) for i in range(len(pts) - 1))


OFF_ROUTE_FIXES = 3        # consecutive fixes outside the corridor before alerting


def _eval_routes(st, fix, routes, moving_kmh=MOVING_KMH):
    """Route-deviation + long-stop state machine for planned routes.

    A route only ARMS once the vehicle has been seen inside its corridor (so a
    car parked off-route at home never fires); it disarms on arrival (inside
    the corridor near the last point). While armed:
      * off_route  — OFF_ROUTE_FIXES consecutive fixes farther than corridor_m;
                     re-arms once the vehicle is back inside the corridor;
      * long_stop  — stationary for >= stop_alert_min minutes (0 = off)."""
    alerts = []
    rstate = dict(st.get("route") or {})
    lat, lng = fix["lat"], fix["lng"]
    at = fix.get("at")
    for r in routes or []:
        rid = str(r.get("id"))
        pts = r.get("points") or []
        if len(pts) < 2:
            continue
        corridor = float(r.get("corridor_m") or 300)
        rs = dict(rstate.get(rid) or {})
        d = route_distance_m(pts, lat, lng)
        end = pts[-1]
        at_end = haversine_m(float(end[0]), float(end[1]), lat, lng) <= corridor
        if d <= corridor:
            rs["off_n"] = 0
            rs["off_alerted"] = False
            if at_end:
                rs["armed"] = False          # arrived: trip along this route done
                rs["stop_since"] = None
                rs["stop_alerted"] = False
            elif not rs.get("armed"):
                rs["armed"] = True
        elif rs.get("armed"):
            rs["off_n"] = int(rs.get("off_n") or 0) + 1
            if rs["off_n"] >= OFF_ROUTE_FIXES and not rs.get("off_alerted"):
                rs["off_alerted"] = True
                alerts.append({"kind": "off_route", "route_id": rid,
                               "route_name": r.get("name") or "",
                               "distance_m": int(d), "corridor_m": int(corridor),
                               "lat": lat, "lng": lng})
        stop_min = int(r.get("stop_alert_min") or 0)
        if rs.get("armed") and stop_min > 0 and at is not None:
            if float(fix.get("speed_kmh") or 0) < moving_kmh:
                since = rs.get("stop_since")
                if not since:
                    rs["stop_since"] = at.isoformat()
                else:
                    from datetime import datetime
                    try:
                        s0 = datetime.fromisoformat(since)
                    except ValueError:
                        s0 = at
                    mins = (at - s0).total_seconds() / 60.0
                    if mins >= stop_min and not rs.get("stop_alerted"):
                        rs["stop_alerted"] = True
                        alerts.append({"kind": "long_stop", "route_id": rid,
                                       "route_name": r.get("name") or "",
                                       "minutes": int(mins),
                                       "lat": lat, "lng": lng})
            else:
                rs["stop_since"] = None
                rs["stop_alerted"] = False
        rstate[rid] = rs
    st["route"] = rstate
    return alerts


def _parse_hhmm(s, default):
    try:
        h, m = str(s).split(":")
        h = int(h)
        if 0 <= h <= 23:
            return h
    except (ValueError, AttributeError):
        pass
    return default


def evaluate_alerts(state, fix, settings, local_hour):
    """Advance the per-vehicle alert state machine by one fix.

    settings: {speed_limit_kmh (0 = off), night_start "22:00", night_end "05:00",
               night_ignition (bool), geofences [{id,name,lat,lng,radius_m}]}
    Returns (new_state, alerts) where each alert is {kind, ...details} with
    kind in {'geofence_enter','geofence_exit','overspeed','night_ignition',
    'off_route','long_stop'}. settings may also carry routes
    [{id,name,points:[[lat,lng]...],corridor_m,stop_alert_min}] (planned routes;
    see _eval_routes).
    The FIRST observation of a fence only records inside/outside (no alert), so
    pairing a tracker that is already parked at home never fires "entered"."""
    st = dict(state or {})
    alerts = []
    fences_state = dict(st.get("fence") or {})
    if fix.get("valid", True) and fix.get("lat") is not None:
        for fence in settings.get("geofences") or []:
            fid = str(fence.get("id"))
            now_in = inside_fence(fence, fix["lat"], fix["lng"])
            was = fences_state.get(fid)
            want = fence.get("alert") or "both"     # both | enter | exit
            if was is not None and was != now_in and (
                    want == "both" or want == ("enter" if now_in else "exit")):
                alerts.append({"kind": "geofence_enter" if now_in else "geofence_exit",
                               "fence_id": fid, "fence_name": fence.get("name") or "",
                               "lat": fix["lat"], "lng": fix["lng"]})
            fences_state[fid] = now_in
        st["fence"] = fences_state
        if settings.get("routes"):
            alerts.extend(_eval_routes(st, fix, settings["routes"]))

        limit = float(settings.get("speed_limit_kmh") or 0)
        spd = float(fix.get("speed_kmh") or 0)
        if limit > 0:
            if spd > limit:
                st["over_n"] = int(st.get("over_n") or 0) + 1
                # two consecutive fixes over the limit (one spike is GPS noise)
                if st["over_n"] >= 2 and not st.get("over_alerted"):
                    st["over_alerted"] = True
                    alerts.append({"kind": "overspeed", "speed_kmh": spd,
                                   "limit_kmh": limit,
                                   "lat": fix["lat"], "lng": fix["lng"]})
            else:
                st["over_n"] = 0
                if spd < limit - 10:      # hysteresis: re-arm only well below
                    st["over_alerted"] = False

        alerts.extend(_eval_stop(st, fix, settings))

    ign = fix.get("ignition")
    if ign is not None:
        prev = st.get("ign")
        night = False
        if ign and prev is False and settings.get("night_ignition", True):
            s_h = _parse_hhmm(settings.get("night_start"), 22)
            e_h = _parse_hhmm(settings.get("night_end"), 5)
            if in_window(local_hour, s_h, e_h):
                night = True
                alerts.append({"kind": "night_ignition", "hour": local_hour,
                               "lat": fix.get("lat"), "lng": fix.get("lng")})
        # veh100: plain ignition on / off alerts (opt-in; the night alert
        # already covers a night start, so it is never doubled).
        if prev is not None and bool(ign) != prev and not night:
            k = "ignition_on" if ign else "ignition_off"
            if settings.get(k):
                alerts.append({"kind": k, "lat": fix.get("lat"), "lng": fix.get("lng")})
        st["ign"] = bool(ign)
    return st, alerts


def _eval_stop(st, fix, settings, moving_kmh=MOVING_KMH):
    """veh100: a LONG STOP anywhere (no planned route needed): the vehicle
    moved, then stayed below moving speed for >= stop_alert_min minutes.
    Once per stop; re-arms when it moves again. 0 = off."""
    mins_cfg = int(settings.get("stop_alert_min") or 0)
    at = fix.get("at")
    if mins_cfg <= 0 or at is None:
        return []
    if float(fix.get("speed_kmh") or 0) >= moving_kmh:
        st["moved"] = True
        st["still_since"] = None
        st["stop_alerted"] = False
        return []
    if not st.get("moved"):
        return []                      # parked since pairing: never "long stop"
    since = st.get("still_since")
    if not since:
        st["still_since"] = at.isoformat()
        return []
    from datetime import datetime
    try:
        s0 = datetime.fromisoformat(since)
    except ValueError:
        st["still_since"] = at.isoformat()
        return []
    mins = (at - s0).total_seconds() / 60.0
    if mins >= mins_cfg and not st.get("stop_alerted"):
        st["stop_alerted"] = True
        return [{"kind": "long_stop", "route_id": "", "route_name": "",
                 "minutes": int(mins), "lat": fix.get("lat"), "lng": fix.get("lng")}]
    return []


# ----------------------------------------------------------------- device power / alarms

ALERT_ALARMS = ("sos", "power_cut", "tamper", "low_battery")
EXT_CUT_V = 5.0          # main power below this = unplugged / cut
EXT_OK_V = 9.0           # ... re-arms only once back above this (12 V bike/car, 24 V truck)
BATT_LOW_V = 3.6         # internal Li-ion backup battery
BATT_OK_V = 3.8
GT06_LEVEL_LOW = (1, 2)  # 0x13 voltage level: 1 extremely low, 2 low-battery alarm
GT06_LEVEL_OK = 4


def evaluate_device(state, alarms=(), signals=None, slot="dev_alarms"):
    """Device-reported alarms + power signals -> alerts, on the RISING EDGE.

    alarms   : codes the device reports NOW (explicit packets or status bits;
               levels repeat in every frame, so only a new one alerts).
    slot     : state key of this alarm SOURCE ('dev_alarms' = carried by
               fixes, 'st_alarms' = carried by status / heartbeat packets).
    signals  : {ext_voltage_v, battery_v, voltage_level} when the model sends
               them. Derived alerts: main power dropped below EXT_CUT_V after
               being >= EXT_OK_V (unplugged / cut); backup battery below
               BATT_LOW_V, or GT06 level 1-2. Each re-arms only after a clear
               recovery (hysteresis), so a flapping wire alerts once.
    Returns (state, alerts) with alert kind 'device_alarm' + 'alarm' code
    (+ 'source': 'device' | 'voltage')."""
    st = dict(state or {})
    sig = signals or {}
    out = []
    active = set(a for a in alarms or () if a in ALERT_ALARMS)
    prev = set(st.get(slot) or [])
    for a in sorted(active - prev):
        out.append({"kind": "device_alarm", "alarm": a, "source": "device"})
    st[slot] = sorted(active)
    pw = dict(st.get("pwr") or {})
    ext = sig.get("ext_voltage_v")
    if isinstance(ext, (int, float)):
        if ext >= EXT_OK_V:
            pw["ext_armed"] = True
        elif ext < EXT_CUT_V and pw.get("ext_armed"):
            pw["ext_armed"] = False
            if "power_cut" not in active:
                out.append({"kind": "device_alarm", "alarm": "power_cut",
                            "source": "voltage", "volts": round(float(ext), 2)})
    batt = sig.get("battery_v")
    lvl = sig.get("voltage_level")
    low = None
    if isinstance(batt, (int, float)) and batt > 0:
        low = batt < BATT_LOW_V if (batt < BATT_LOW_V or batt >= BATT_OK_V) else None
    elif isinstance(lvl, int):
        low = True if lvl in GT06_LEVEL_LOW else (False if lvl >= GT06_LEVEL_OK else None)
    if low is False:
        pw["batt_armed"] = True
    elif low is True and pw.get("batt_armed", True):
        pw["batt_armed"] = False
        if "low_battery" not in active:
            out.append({"kind": "device_alarm", "alarm": "low_battery",
                        "source": "voltage",
                        "volts": round(float(batt), 2) if isinstance(batt, (int, float)) else None})
    st["pwr"] = pw
    return st, out


def silent_alert(state, last_seen_at, now, silent_min=30, was_moving=False):
    """veh100: tracker went SILENT (possible unplug with no backup battery,
    no SIM data, or no signal). Fires once per silence when the tracker was
    last seen > silent_min minutes ago; re-arms as soon as it is seen again.
    Returns (state, alert|None)."""
    st = dict(state or {})
    if not last_seen_at or silent_min <= 0:
        return st, None
    seen_key = last_seen_at.isoformat()
    if st.get("silent_for") == seen_key:
        return st, None                          # already alerted this silence
    mins = (now - last_seen_at).total_seconds() / 60.0
    if mins < silent_min:
        return st, None
    st["silent_for"] = seen_key
    return st, {"kind": "tracker_silent", "minutes": int(mins), "moving": bool(was_moving)}


# ----------------------------------------------------------------- caps / quiet hours

# Kinds that ALWAYS push (safety); everything else respects the owner's
# quiet hours (in-app only during them). Per-kind cooldown in seconds.
SAFETY_KINDS = ("device_alarm", "night_ignition", "geofence_exit", "off_route",
                "tracker_silent")
COOLDOWN_S = {"overspeed": 600, "geofence_enter": 120, "geofence_exit": 120,
              "ignition_on": 300, "ignition_off": 300, "long_stop": 300,
              "off_route": 600, "night_ignition": 900, "device_alarm": 600,
              "tracker_silent": 1800}
DAILY_PUSH_CAP = 30      # pushes per tracker per local day (the rest: in-app)


def _hhmm_min(s, default):
    try:
        h, m = str(s).split(":")
        h, m = int(h), int(m)
        if 0 <= h <= 23 and 0 <= m <= 59:
            return h * 60 + m
    except (ValueError, AttributeError):
        pass
    return default


def in_quiet(local_dt, quiet_start, quiet_end):
    """Minute-precise quiet window, may wrap midnight. Equal = off."""
    s = _hhmm_min(quiet_start, -1)
    e = _hhmm_min(quiet_end, -1)
    if s < 0 or e < 0 or s == e:
        return False
    m = local_dt.hour * 60 + local_dt.minute
    return s <= m < e if s < e else (m >= s or m < e)


def gate_alert(cap_state, alert, local_dt, prefs=None):
    """Decide how ONE alert goes out: 'push' (push + in-app), 'inapp' (quiet
    hours / daily cap reached: in-app notification only) or 'drop' (same
    kind inside its cooldown — a duplicate). Pure; returns (decision, state).
    The key for cooldown includes the alarm / fence so a power cut never
    hides an SOS."""
    st = dict(cap_state or {})
    p = prefs or {}
    day = local_dt.date().isoformat()
    if st.get("day") != day:
        st = {"day": day, "n": 0, "last": {}}
    last = dict(st.get("last") or {})
    kind = alert.get("kind")
    key = "%s:%s" % (kind, alert.get("alarm") or alert.get("fence_id") or
                     alert.get("route_id") or "")
    cd = COOLDOWN_S.get(kind, 300)
    t = local_dt.timestamp()
    if key in last and t - float(last[key]) < cd:
        return "drop", st
    last[key] = t
    st["last"] = last
    safety = kind in SAFETY_KINDS
    if not safety and in_quiet(local_dt, p.get("quiet_start"), p.get("quiet_end")):
        return "inapp", st
    cap = int(p.get("daily_push_cap") or DAILY_PUSH_CAP)
    if st.get("n", 0) >= cap and not (kind == "device_alarm" and alert.get("alarm") == "sos"):
        return "inapp", st
    st["n"] = int(st.get("n", 0)) + 1
    return "push", st


# ----------------------------------------------------------------- engine-cut gate

STOPPED_FIXES = 3


def stopped_for(recent, now, n=STOPPED_FIXES, max_speed_kmh=5.0, max_age_s=120,
                window_s=900):
    """veh100 engine-cut gate, on top of decide_cutoff: the LAST n stored fixes
    (newest first or any order) must ALL be below max_speed_kmh, the newest
    must be fresh (<= max_age_s) and all inside window_s. Returns (ok, reason)
    with reason in {'ok','few_fixes','stale_fix','moving'}."""
    pts = sorted((f for f in recent or [] if f.get("at") is not None),
                 key=lambda f: f["at"], reverse=True)[:n]
    if len(pts) < n:
        return False, "few_fixes"
    if (now - pts[0]["at"]).total_seconds() > max_age_s:
        return False, "stale_fix"
    if (now - pts[-1]["at"]).total_seconds() > window_s:
        return False, "few_fixes"
    if any(float(f.get("speed_kmh") or 0) >= max_speed_kmh for f in pts):
        return False, "moving"
    return True, "ok"


# ----------------------------------------------------------------- driver behaviour

HARSH_BRAKE_KMH_S = -12.0    # <= -12 km/h per second (~0.34 g)
HARSH_ACCEL_KMH_S = 10.0     # >= +10 km/h per second (~0.28 g)
BEHAVIOUR_MAX_DT_S = 10      # only fix pairs this close can show a harsh event
DEFAULT_LIMIT_KMH = 80       # used when the owner set no limit (BD highways)


def behaviour(fixes, speed_limit_kmh=0, moving_kmh=MOVING_KMH):
    """Driver behaviour from GPS fixes ONLY (no accelerometer).

    HONEST LIMIT: a tracker reporting every 5 s sees a 1-2 s hard brake only as
    an average over the 5 s gap; events between fixes farther apart than
    BEHAVIOUR_MAX_DT_S are invisible. `coverage` = share of moving time made
    of close-enough fix pairs; below 0.5 the score is flagged 'limited'.

    Score (0-100) per 100 km driven (min 20 km base so a short hop is not
    over-punished): 100 - (4 x harsh brakes + 3 x harsh accelerations +
    1 x minute above the limit) x 100 / max(km, 20)."""
    pts = _clean(fixes)
    limit = float(speed_limit_kmh or 0) or DEFAULT_LIMIT_KMH
    hb = ha = 0
    over_s = 0.0
    moving_s = close_s = 0.0
    dist_m = 0.0
    for a, b in zip(pts, pts[1:]):
        dt = (b["at"] - a["at"]).total_seconds()
        if dt <= 0 or dt > MAX_GAP_S:
            continue
        va, vb = float(a.get("speed_kmh") or 0), float(b.get("speed_kmh") or 0)
        if va >= moving_kmh or vb >= moving_kmh:
            moving_s += dt
            dist_m += _step(a, b)
            if dt <= BEHAVIOUR_MAX_DT_S:
                close_s += dt
                acc = (vb - va) / dt
                if acc <= HARSH_BRAKE_KMH_S:
                    hb += 1
                elif acc >= HARSH_ACCEL_KMH_S:
                    ha += 1
            if va > limit and vb > limit:
                over_s += dt
            elif va > limit or vb > limit:
                over_s += dt / 2.0
    km = dist_m / 1000.0
    coverage = round(close_s / moving_s, 2) if moving_s > 0 else 0.0
    penalty = (4 * hb + 3 * ha + over_s / 60.0) * 100.0 / max(km, 20.0)
    score = None if moving_s <= 0 else int(round(max(0.0, min(100.0, 100.0 - penalty))))
    return {"score": score, "harsh_brake": hb, "harsh_accel": ha,
            "overspeed_s": int(over_s), "limit_kmh": int(limit),
            "limit_default": not bool(speed_limit_kmh), "km": round(km, 2),
            "moving_s": int(moving_s), "coverage": coverage,
            "limited": coverage < 0.5}


def score_band(score):
    if score is None:
        return "none"
    return "good" if score >= 85 else ("ok" if score >= 70 else "improve")


def day_stats(fixes, speed_limit_kmh=0, night=None):
    """One day's numbers for the daily / monthly report (pure)."""
    s = compute_trips(fixes, night=night)
    b = behaviour(fixes, speed_limit_kmh)
    pts = _clean(fixes)
    idle_s = 0
    for a, c in zip(pts, pts[1:]):
        dt = (c["at"] - a["at"]).total_seconds()
        if 0 < dt <= MAX_GAP_S and a.get("ignition") is True \
                and float(a.get("speed_kmh") or 0) < MOVING_KMH:
            idle_s += dt
    return {"km": s["total_km"], "trips": len(s["trips"]), "moving_s": s["moving_s"],
            "idle_s": int(idle_s), "max_kmh": s["max_speed_kmh"],
            "overspeed_s": b["overspeed_s"], "harsh_brake": b["harsh_brake"],
            "harsh_accel": b["harsh_accel"], "score": b["score"],
            "coverage": b["coverage"], "night_trips": sum(1 for t in s["trips"] if t.get("night")),
            "points": s["points"]}


def month_totals(days):
    """Sum a list of day_stats dicts (score = km-weighted mean of scored days)."""
    tot = {"km": 0.0, "trips": 0, "moving_s": 0, "idle_s": 0, "max_kmh": 0.0,
           "overspeed_s": 0, "harsh_brake": 0, "harsh_accel": 0, "night_trips": 0,
           "days_driven": 0}
    wsum = wkm = 0.0
    for d in days:
        tot["km"] += float(d.get("km") or 0)
        for k in ("trips", "moving_s", "idle_s", "overspeed_s", "harsh_brake",
                  "harsh_accel", "night_trips"):
            tot[k] += int(d.get(k) or 0)
        tot["max_kmh"] = max(tot["max_kmh"], float(d.get("max_kmh") or 0))
        if float(d.get("km") or 0) > 0:
            tot["days_driven"] += 1
        if d.get("score") is not None and float(d.get("km") or 0) > 0:
            wsum += d["score"] * float(d["km"])
            wkm += float(d["km"])
    tot["km"] = round(tot["km"], 2)
    tot["score"] = int(round(wsum / wkm)) if wkm > 0 else None
    return tot


# ----------------------------------------------------------------- reminders

# Vehicle papers on a "My Vehicles" record (PaCollectionItem data keys).
PAPER_KEYS = ("tax_token_expiry", "fitness_expiry", "insurance_expiry",
              "route_permit_expiry")
PAPER_STAGES = (30, 7, 1)
PAPER_LABELS = {
    "tax_token_expiry": ("ট্যাক্স টোকেন", "Tax token"),
    "fitness_expiry": ("ফিটনেস সার্টিফিকেট", "Fitness certificate"),
    "insurance_expiry": ("বিমা", "Insurance"),
    "route_permit_expiry": ("রুট পারমিট", "Route permit"),
    "licence_expiry": ("ড্রাইভিং লাইসেন্স", "Driving licence"),
}


def paper_stage(days_left, stages=PAPER_STAGES):
    """Most urgent stage reached (30/7/1; day 0 counts as 1), None if expired
    or further away."""
    if days_left is None or days_left < 0:
        return None
    for s_ in sorted(stages):
        if days_left <= s_:
            return s_
    return None


def maintenance_due(item, odometer_km, today, warn_km=300, warn_days=7):
    """One maintenance rule {name, every_km, every_days, last_km, last_date}.
    Due by distance (odometer - last_km >= every_km - warn_km) or by date
    (today >= last_date + every_days - warn_days), whichever first. Returns
    {due: bool, overdue: bool, km_left, days_left, by: 'km'|'date'|None}."""
    from datetime import date as _date
    km_left = days_left = None
    try:
        every_km = float(item.get("every_km") or 0)
        last_km = float(item.get("last_km") or 0)
    except (TypeError, ValueError):
        every_km = 0
        last_km = 0
    if every_km > 0 and odometer_km is not None:
        km_left = round(last_km + every_km - float(odometer_km), 1)
    try:
        every_days = int(item.get("every_days") or 0)
    except (TypeError, ValueError):
        every_days = 0
    if every_days > 0 and item.get("last_date"):
        try:
            last = _date.fromisoformat(str(item["last_date"])[:10])
            days_left = (last.toordinal() + every_days) - today.toordinal()
        except ValueError:
            days_left = None
    due_km = km_left is not None and km_left <= warn_km
    due_d = days_left is not None and days_left <= warn_days
    by = None
    if due_km and due_d:
        by = "km" if (km_left or 0) / max(every_km, 1) <= (days_left or 0) / max(every_days, 1) else "date"
    elif due_km:
        by = "km"
    elif due_d:
        by = "date"
    overdue = (km_left is not None and km_left <= 0) or (days_left is not None and days_left <= 0)
    return {"due": bool(by), "overdue": bool(overdue and by), "km_left": km_left,
            "days_left": days_left, "by": by}



# ----------------------------------------------------------------- summaries

LONG_TRIP_KM = 150.0


def unusual_trip_facts(summary, speed_limit_kmh=0):
    """Facts worth a human look, from a compute_trips() summary. Facts only —
    never an accusation ("please check")."""
    facts = []
    for t in summary.get("trips", []):
        if t.get("night"):
            facts.append({"kind": "night_trip", "start": t["start"], "km": t["km"]})
        if t["km"] >= LONG_TRIP_KM:
            facts.append({"kind": "long_trip", "start": t["start"], "km": t["km"]})
        if speed_limit_kmh and t["max_kmh"] > speed_limit_kmh:
            facts.append({"kind": "fast_trip", "start": t["start"],
                          "max_kmh": t["max_kmh"]})
    return facts


def rule_summary(summary, facts, lang="bn"):
    """Plain-language, NON-AI summary (the honest fallback when no AI key)."""
    n = len(summary.get("trips", []))
    km = summary.get("total_km", 0)
    if lang == "bn":
        head = "গত ২৪ ঘণ্টায় %s টি যাত্রা, মোট %s কিমি।" % (_bn(n), _bn(km))
        if not facts:
            return head + " অস্বাভাবিক কিছু পাওয়া যায়নি।"
        parts = []
        for f in facts:
            if f["kind"] == "night_trip":
                parts.append("রাতে একটি যাত্রা হয়েছে (%s কিমি)" % _bn(f["km"]))
            elif f["kind"] == "long_trip":
                parts.append("একটি লম্বা যাত্রা (%s কিমি)" % _bn(f["km"]))
            elif f["kind"] == "fast_trip":
                parts.append("একটি যাত্রায় সর্বোচ্চ গতি %s কিমি/ঘণ্টা" % _bn(int(f["max_kmh"])))
        return head + " দয়া করে দেখে নিন: " + "; ".join(parts) + "।"
    head = "%d trip(s) in the last 24 hours, %s km in total." % (n, km)
    if not facts:
        return head + " Nothing unusual found."
    parts = []
    for f in facts:
        if f["kind"] == "night_trip":
            parts.append("a trip at night (%s km)" % f["km"])
        elif f["kind"] == "long_trip":
            parts.append("a long trip (%s km)" % f["km"])
        elif f["kind"] == "fast_trip":
            parts.append("a trip that reached %d km/h" % int(f["max_kmh"]))
    return head + " Please check: " + "; ".join(parts) + "."


_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def _bn(v):
    return str(v).translate(_BN_DIGITS)


_ALARM_BN = {"sos": "SOS বোতাম", "power_cut": "ট্র্যাকারের বিদ্যুৎ বিচ্ছিন্ন",
             "tamper": "ট্র্যাকারে হাত দেওয়া হয়েছে", "low_battery": "ট্র্যাকারের ব্যাটারি কম"}
_ALARM_EN = {"sos": "SOS button", "power_cut": "tracker power disconnected",
             "tamper": "tracker tampered", "low_battery": "tracker battery low"}


def alert_text(alert, vehicle_name, lang="bn"):
    """(title, body) for one alert. Wording is 'please check', never blame."""
    k = alert["kind"]
    v = vehicle_name or ("আপনার গাড়ি" if lang == "bn" else "Your vehicle")
    if lang == "bn":
        if k == "geofence_enter":
            return ("%s এলাকায় ঢুকেছে" % v,
                    "%s \"%s\" এলাকায় ঢুকেছে।" % (v, alert.get("fence_name") or "নির্ধারিত"))
        if k == "geofence_exit":
            return ("%s এলাকা ছেড়েছে" % v,
                    "%s \"%s\" এলাকা থেকে বেরিয়েছে। আপনি জানেন কি না দেখে নিন।"
                    % (v, alert.get("fence_name") or "নির্ধারিত"))
        if k == "overspeed":
            return ("%s দ্রুত চলছে" % v,
                    "গতি %s কিমি/ঘণ্টা (সীমা %s)। দয়া করে খোঁজ নিন।"
                    % (_bn(int(alert["speed_kmh"])), _bn(int(alert["limit_kmh"]))))
        if k == "night_ignition":
            return ("রাতে %s চালু হয়েছে" % v,
                    "রাতে ইঞ্জিন চালু হয়েছে। আপনি বা পরিচিত কেউ না হলে দয়া করে দেখে নিন।")
        if k == "off_route":
            return ("%s পথ থেকে সরে গেছে" % v,
                    "%s \"%s\" পথ থেকে প্রায় %s মিটার দূরে চলে গেছে। দয়া করে খোঁজ নিন।"
                    % (v, alert.get("route_name") or "নির্ধারিত",
                       _bn(int(alert.get("distance_m") or 0))))
        if k == "long_stop" and not alert.get("route_id"):
            return ("%s অনেকক্ষণ থেমে আছে" % v,
                    "%s %s মিনিট ধরে এক জায়গায় থেমে আছে। দয়া করে খোঁজ নিন।"
                    % (v, _bn(int(alert.get("minutes") or 0))))
        if k == "long_stop":
            return ("%s অনেকক্ষণ থেমে আছে" % v,
                    "%s \"%s\" পথে %s মিনিট ধরে থেমে আছে। দয়া করে খোঁজ নিন।"
                    % (v, alert.get("route_name") or "নির্ধারিত",
                       _bn(int(alert.get("minutes") or 0))))
        if k == "ignition_on":
            return ("%s চালু হয়েছে" % v, "%s-এর ইঞ্জিন চালু হয়েছে।" % v)
        if k == "ignition_off":
            return ("%s বন্ধ হয়েছে" % v, "%s-এর ইঞ্জিন বন্ধ হয়েছে।" % v)
        if k == "tracker_silent":
            return ("%s-এর ট্র্যাকার সাড়া দিচ্ছে না" % v,
                    "%s মিনিট ধরে ট্র্যাকার থেকে কোনো সংকেত আসেনি। ট্র্যাকার খুলে ফেলা, "
                    "বিদ্যুৎ বিচ্ছিন্ন, সিমে ডাটা নেই বা নেটওয়ার্ক না থাকতে পারে। দয়া করে দেখে নিন।"
                    % _bn(int(alert.get("minutes") or 0)))
        if k == "device_alarm" and alert.get("source") == "voltage" \
                and alert.get("alarm") == "power_cut":
            return ("%s: ট্র্যাকারের বিদ্যুৎ বিচ্ছিন্ন" % v,
                    "ট্র্যাকারের মূল বিদ্যুৎ চলে গেছে (তার খোলা বা কাটা হতে পারে)। "
                    "দয়া করে দেখে নিন।")
        if k == "device_alarm":
            what = _ALARM_BN.get(alert.get("alarm"), "সতর্ক সংকেত")
            return ("%s: %s" % (v, what),
                    "ট্র্যাকার থেকে \"%s\" সংকেত এসেছে। দয়া করে দেখে নিন।" % what)
        return ("%s সতর্কতা" % v, "দয়া করে দেখে নিন।")
    if k == "geofence_enter":
        return ("%s entered an area" % v,
                "%s entered \"%s\"." % (v, alert.get("fence_name") or "your area"))
    if k == "geofence_exit":
        return ("%s left an area" % v,
                "%s left \"%s\". Please check that you know about it."
                % (v, alert.get("fence_name") or "your area"))
    if k == "overspeed":
        return ("%s is going fast" % v,
                "Speed %d km/h (limit %d). Please check in."
                % (int(alert["speed_kmh"]), int(alert["limit_kmh"])))
    if k == "night_ignition":
        return ("%s started at night" % v,
                "The engine was switched on at night. If it was not you or someone "
                "you know, please check.")
    if k == "off_route":
        return ("%s left the planned route" % v,
                "%s is about %d m off the \"%s\" route. Please check in."
                % (v, int(alert.get("distance_m") or 0),
                   alert.get("route_name") or "planned"))
    if k == "long_stop" and not alert.get("route_id"):
        return ("%s has been stopped a while" % v,
                "%s has been stopped in one place for %d minutes. Please check in."
                % (v, int(alert.get("minutes") or 0)))
    if k == "ignition_on":
        return ("%s started" % v, "The engine of %s was switched on." % v)
    if k == "ignition_off":
        return ("%s switched off" % v, "The engine of %s was switched off." % v)
    if k == "tracker_silent":
        return ("%s: tracker not responding" % v,
                "No signal from the tracker for %d minutes. It may have been unplugged, "
                "lost power, run out of SIM data or lost network. Please check."
                % int(alert.get("minutes") or 0))
    if k == "device_alarm" and alert.get("source") == "voltage" \
            and alert.get("alarm") == "power_cut":
        return ("%s: tracker power disconnected" % v,
                "The tracker lost its main power (a wire may be unplugged or cut). "
                "Please check.")
    if k == "long_stop":
        return ("%s has been stopped a while" % v,
                "%s has been stopped for %d minutes on the \"%s\" route. Please check in."
                % (v, int(alert.get("minutes") or 0), alert.get("route_name") or "planned"))
    if k == "device_alarm":
        what = _ALARM_EN.get(alert.get("alarm"), "alarm")
        return ("%s: %s" % (v, what),
                "The tracker sent a \"%s\" signal. Please check." % what)
    return ("%s alert" % v, "Please check.")


def is_online(last_seen_at, now, window_s=600):
    return bool(last_seen_at) and (now - last_seen_at) <= timedelta(seconds=window_s)
