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

def inside_fence(fence, lat, lng):
    try:
        return haversine_m(float(fence["lat"]), float(fence["lng"]), lat, lng) \
            <= float(fence.get("radius_m") or 200)
    except (KeyError, TypeError, ValueError):
        return False


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
    kind in {'geofence_enter','geofence_exit','overspeed','night_ignition'}.
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
            if was is not None and was != now_in:
                alerts.append({"kind": "geofence_enter" if now_in else "geofence_exit",
                               "fence_id": fid, "fence_name": fence.get("name") or "",
                               "lat": fix["lat"], "lng": fix["lng"]})
            fences_state[fid] = now_in
        st["fence"] = fences_state

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

    ign = fix.get("ignition")
    if ign is not None:
        prev = st.get("ign")
        if ign and prev is False and settings.get("night_ignition", True):
            s_h = _parse_hhmm(settings.get("night_start"), 22)
            e_h = _parse_hhmm(settings.get("night_end"), 5)
            if in_window(local_hour, s_h, e_h):
                alerts.append({"kind": "night_ignition", "hour": local_hour,
                               "lat": fix.get("lat"), "lng": fix.get("lng")})
        st["ign"] = bool(ign)
    return st, alerts


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
    if k == "device_alarm":
        what = _ALARM_EN.get(alert.get("alarm"), "alarm")
        return ("%s: %s" % (v, what),
                "The tracker sent a \"%s\" signal. Please check." % what)
    return ("%s alert" % v, "Please check.")


def is_online(last_seen_at, now, window_s=600):
    return bool(last_seen_at) and (now - last_seen_at) <= timedelta(seconds=window_s)
