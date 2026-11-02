"""
school_mode.py — Child School Mode: the PURE per-day state machine (no Django,
no DB, no clock). core/kidswatch_service.py feeds it and delivers what it
returns. Owner idea 2 (28 Oct).

WATCH (fully automatic): position fixes from the kids watch drive it —
    leaves home  -> tracking fast ("left_home", in-app + push)
    at school    -> "arrived_school" notice, tracking slow
    school hours -> quiet; alert only when the child LEAVES the school
                    geofence (2 fixes outside, or 1 far outside)
    school end   -> tracking fast by itself ("school_over")
    at home      -> "reached_home" notice, then slow / night
    late by N min (owner-set) -> "late_school" / "late_home" alert with the
                    last known location.

PHONE (honest): no background location (Play policy), so nothing is detected
on its own. The child presses ONE big button — "এখন রওনা দিচ্ছি" (leaving
now) / "পৌঁছেছি" (reached) — with the location of that moment (foreground,
only if the child allows) and an optional voice note. The schedule supplies
the expectations: no "reached school" by start + late_min -> first ask the
CHILD "ঠিক আছো?" (ask_ok), and only if there is no answer within ASK_GRACE_MIN
the parents get "late_school" with the last known location. "I'm OK" from the
child extends the deadline once by late_min.

Times are LOCAL (Asia/Dhaka) naive-aware datetimes passed in by the caller.
Weekdays: Python's Monday=0 ... Sunday=6; the Bangladesh school week default
is Sunday-Thursday (6, 0, 1, 2, 3).
"""
import math
from datetime import datetime, timedelta

DEFAULT_DAYS = [6, 0, 1, 2, 3]
DEFAULTS = {"start": "08:00", "end": "13:30", "commute_min": 40, "late_min": 15,
            "days": DEFAULT_DAYS}
RADIUS_MIN_M, RADIUS_MAX_M, RADIUS_DEFAULT_M = 75, 1000, 150
HYST_M = 60                 # beyond radius + this = clearly outside
FAR_FACTOR = 3              # one fix this far outside is enough
LATE_MIN_RANGE = (5, 120)
COMMUTE_MIN_RANGE = (5, 180)
ASK_GRACE_MIN = 5
OPEN_BEFORE_MIN = 60        # the morning window opens commute + this before start
CLOSE_AFTER_MIN = 180       # the afternoon window closes this long after home_due
WIFI_MAX = 12

STATES = ("idle", "at_home", "to_school", "at_school", "to_home", "home")


# --------------------------------------------------------------- config

def hhmm_min(s):
    try:
        h, m = str(s).split(":")
        h, m = int(h), int(m)
    except (ValueError, AttributeError):
        return None
    if not (0 <= h <= 23 and 0 <= m <= 59):
        return None
    return h * 60 + m


def clean_place(p):
    """{lat,lng,radius_m,name,wifi} or None."""
    if not isinstance(p, dict):
        return None
    try:
        lat, lng = float(p.get("lat")), float(p.get("lng"))
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lng <= 180) or (lat == 0 and lng == 0):
        return None
    try:
        r = int(float(p.get("radius_m") or RADIUS_DEFAULT_M))
    except (TypeError, ValueError):
        r = RADIUS_DEFAULT_M
    wifi = [str(m).lower() for m in (p.get("wifi") or []) if isinstance(m, str)][:WIFI_MAX]
    return {"lat": round(lat, 6), "lng": round(lng, 6),
            "radius_m": max(RADIUS_MIN_M, min(RADIUS_MAX_M, r)),
            "name": str(p.get("name") or "")[:60], "wifi": wifi}


def validate(cfg):
    """Normalized config dict, or raises ValueError(reason)."""
    out = dict(DEFAULTS)
    out.update({k: v for k, v in (cfg or {}).items() if v is not None})
    s, e = hhmm_min(out["start"]), hhmm_min(out["end"])
    if s is None or e is None:
        raise ValueError("bad_time")
    if e <= s + 30:
        raise ValueError("end_before_start")
    try:
        out["late_min"] = int(out["late_min"])
        out["commute_min"] = int(out["commute_min"])
    except (TypeError, ValueError):
        raise ValueError("bad_number")
    if not LATE_MIN_RANGE[0] <= out["late_min"] <= LATE_MIN_RANGE[1]:
        raise ValueError("late_range")
    if not COMMUTE_MIN_RANGE[0] <= out["commute_min"] <= COMMUTE_MIN_RANGE[1]:
        raise ValueError("commute_range")
    days = out.get("days") or []
    try:
        days = sorted({int(d) for d in days})
    except (TypeError, ValueError):
        raise ValueError("bad_days")
    if not days or any(d < 0 or d > 6 for d in days):
        raise ValueError("bad_days")
    out["days"] = days
    out["home"] = clean_place(out.get("home"))
    out["school"] = clean_place(out.get("school"))
    return out


# --------------------------------------------------------------- geometry

def dist_m(a_lat, a_lng, b_lat, b_lng):
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def relation(place, lat=None, lng=None, wifi=None):
    """'in' / 'out' / 'far' / None (ambiguous band or unknown).
    A fix with no usable GPS but a Wi-Fi MAC learned at the place = 'in'."""
    if not place:
        return None
    if lat is None or lng is None:
        macs = {w.get("mac") if isinstance(w, dict) else w for w in (wifi or [])}
        if macs and set(place.get("wifi") or ()) & macs:
            return "in"
        return None
    d = dist_m(place["lat"], place["lng"], lat, lng)
    if d <= place["radius_m"]:
        return "in"
    if d > place["radius_m"] * FAR_FACTOR + HYST_M:
        return "far"
    if d > place["radius_m"] + HYST_M:
        return "out"
    return None


def learn_wifi(place, wifi):
    """Remember the strongest Wi-Fi MACs seen INSIDE a place (GPS-confirmed),
    so a later Wi-Fi-only fix (indoors, no GPS) still counts — free, no
    geolocation API. Returns the updated MAC list."""
    have = list(place.get("wifi") or [])
    for w in sorted(wifi or [], key=lambda w: -int(w.get("rssi") or -100)):
        m = w.get("mac")
        if m and m not in have:
            have.append(m)
    return have[-WIFI_MAX:]


# --------------------------------------------------------------- schedule

def is_school_day(cfg, local_dt):
    return local_dt.weekday() in cfg["days"]


def times(cfg, local_dt):
    """The school-day timeline for local_dt's date (aware datetimes)."""
    d0 = local_dt.replace(hour=0, minute=0, second=0, microsecond=0)
    s = d0 + timedelta(minutes=hhmm_min(cfg["start"]))
    e = d0 + timedelta(minutes=hhmm_min(cfg["end"]))
    c, late = cfg["commute_min"], cfg["late_min"]
    home_due = e + timedelta(minutes=c + late)
    return {"open": s - timedelta(minutes=c + OPEN_BEFORE_MIN), "start": s,
            "arrive_due": s + timedelta(minutes=late), "end": e,
            "home_due": home_due,
            "close": home_due + timedelta(minutes=CLOSE_AFTER_MIN)}


def window(cfg, local_dt):
    """'off' (not a school day) | 'night' | 'morning' | 'school' | 'afternoon'."""
    if not is_school_day(cfg, local_dt):
        return "off"
    t = times(cfg, local_dt)
    if local_dt < t["open"] or local_dt >= t["close"]:
        return "night"
    if local_dt < t["start"]:
        return "morning"
    if local_dt < t["end"]:
        return "school"
    return "afternoon"


def new_day(local_dt):
    return {"date": local_dt.date().isoformat(), "state": "idle", "out_n": 0,
            "left_home_at": None, "arrived_school_at": None, "left_school_at": None,
            "home_at": None, "early_exit_at": None, "alerts": {}, "ask": {},
            "deadline": {}, "events": []}


def ensure_day(day, local_dt):
    if not day or day.get("date") != local_dt.date().isoformat():
        return new_day(local_dt)
    return day


def _iso(dt):
    return dt.isoformat()


def _ev(kind, local_dt, notify, **kw):
    e = {"kind": kind, "at": _iso(local_dt), "notify": notify}
    e.update(kw)
    return e


def _log(day, events):
    for e in events:
        day["events"] = (day.get("events") or [])[-30:] + [
            {"kind": e["kind"], "at": e["at"], "source": e.get("source", "")}]
    return day


# --------------------------------------------------------------- transitions

def on_fix(cfg, day, local_dt, lat=None, lng=None, wifi=None, source="gps"):
    """A WATCH position. Returns (day, events)."""
    day = ensure_day(day, local_dt)
    w = window(cfg, local_dt)
    ev = []
    if w in ("off", "night") or day.get("paused"):
        return day, ev
    home = relation(cfg.get("home"), lat, lng, wifi)
    school = relation(cfg.get("school"), lat, lng, wifi)
    st = day["state"]
    if st == "idle":
        if w == "morning":
            st = "at_home"
        elif w == "school":
            st = "at_school" if school == "in" else "at_home"
        else:
            st = "home" if home == "in" else "to_home"
        day["state"] = st
        if st == "home":
            day["home_at"] = _iso(local_dt)      # was home all along: no notice
    if w == "morning" or (w == "school" and not day["arrived_school_at"]):
        if st == "at_home" and home in ("out", "far") and school != "in":
            day["out_n"] = day.get("out_n", 0) + 1
            if home == "far" or day["out_n"] >= 2:
                day.update(state="to_school", left_home_at=_iso(local_dt), out_n=0)
                ev.append(_ev("left_home", local_dt, "push", source=source))
        elif home == "in":
            day["out_n"] = 0
        if school == "in" and not day["arrived_school_at"]:
            day.update(state="at_school", arrived_school_at=_iso(local_dt), out_n=0)
            ev.append(_ev("arrived_school", local_dt, "push", source=source))
    elif w == "school":
        if school in ("out", "far"):
            day["out_n"] = day.get("out_n", 0) + 1
            if (school == "far" or day["out_n"] >= 2) and not day["early_exit_at"]:
                day["early_exit_at"] = _iso(local_dt)
                ev.append(_ev("left_school_early", local_dt, "alert", source=source,
                              lat=lat, lng=lng))
        elif school == "in":
            day["out_n"] = 0
            if day["early_exit_at"]:
                day["early_exit_at"] = None
                ev.append(_ev("back_in_school", local_dt, "push", source=source))
    else:  # afternoon
        went = day["arrived_school_at"] or day["left_home_at"]
        if went and st != "home" and school in ("out", "far") and home != "in" \
                and not day["left_school_at"]:
            day.update(state="to_home", left_school_at=_iso(local_dt))
            ev.append(_ev("left_school", local_dt, "in_app", source=source))
        if home == "in" and not day["home_at"]:
            day.update(state="home", home_at=_iso(local_dt))
            if went:
                ev.append(_ev("reached_home", local_dt, "push", source=source))
    return _log(day, ev), ev


CHECKINS = ("leaving", "arrived", "ok")


def on_checkin(cfg, day, local_dt, kind, lat=None, lng=None):
    """A PHONE button press: 'leaving' (এখন রওনা দিচ্ছি), 'arrived'
    (পৌঁছেছি) or 'ok' (answer to ঠিক আছো?). The window decides whether it is
    the school or the home leg. Returns (day, events)."""
    if kind not in CHECKINS:
        raise ValueError("bad_kind")
    day = ensure_day(day, local_dt)
    w = window(cfg, local_dt)
    morning = (w == "morning" or (w == "school" and not day["arrived_school_at"])
               or (w in ("night", "off") and local_dt.hour < 12))
    place = cfg.get("school") if morning else cfg.get("home")
    rel = relation(place, lat, lng) if lat is not None else None
    match = {"in": "inside", "out": "outside", "far": "outside"}.get(rel, "unknown")
    ev = []
    if kind == "ok":
        leg = "school" if morning else "home"
        day["ask"].pop(leg, None)
        day["deadline"][leg] = _iso(local_dt + timedelta(minutes=cfg["late_min"]))
        day.setdefault("asked_once", {})[leg] = True
        ev.append(_ev("child_ok", local_dt, "push", leg=leg, place_match=match))
        return _log(day, ev), ev
    if morning:
        if kind == "leaving":
            day.update(state="to_school", left_home_at=_iso(local_dt))
            ev.append(_ev("left_home", local_dt, "push", source="phone", place_match=match))
        else:
            day.update(state="at_school", arrived_school_at=_iso(local_dt))
            day["ask"].pop("school", None)
            ev.append(_ev("arrived_school", local_dt, "push", source="phone",
                          place_match=match))
    else:
        if kind == "leaving":
            day.update(state="to_home", left_school_at=_iso(local_dt))
            ev.append(_ev("left_school", local_dt, "push", source="phone",
                          place_match=match))
        else:
            day.update(state="home", home_at=_iso(local_dt))
            day["ask"].pop("home", None)
            ev.append(_ev("reached_home", local_dt, "push", source="phone",
                          place_match=match))
    return _log(day, ev), ev


def _parse(s):
    return datetime.fromisoformat(s) if s else None


def on_tick(cfg, day, local_dt, phone=False):
    """Clock-driven steps (every minute from the server job). Returns
    (day, events)."""
    day = ensure_day(day, local_dt)
    ev = []
    if not is_school_day(cfg, local_dt) or day.get("paused"):
        return day, ev
    t = times(cfg, local_dt)
    w = window(cfg, local_dt)
    if w == "afternoon" and day["state"] in ("at_school", "idle") and \
            not day.get("school_over"):
        day["school_over"] = True
        if day["state"] == "at_school":
            day["state"] = "to_home"
        ev.append(_ev("school_over", local_dt, "none"))
    for leg, done_key, due_key, kind in (
            ("school", "arrived_school_at", "arrive_due", "late_school"),
            ("home", "home_at", "home_due", "late_home")):
        if day.get(done_key) or day["alerts"].get(kind):
            continue
        if leg == "home" and not (day["arrived_school_at"] or day["left_school_at"]
                                  or day.get("school_over")):
            continue
        due = _parse(day["deadline"].get(leg)) or t[due_key]
        if local_dt < due or local_dt >= t["close"]:
            continue
        if phone and not day["ask"].get(leg) and not day.get("asked_once", {}).get(leg):
            day["ask"][leg] = _iso(local_dt)
            ev.append(_ev("ask_ok", local_dt, "child", leg=leg))
            continue
        asked = _parse(day["ask"].get(leg))
        if phone and asked and local_dt < asked + timedelta(minutes=ASK_GRACE_MIN):
            continue
        day["alerts"][kind] = _iso(local_dt)
        day["ask"].pop(leg, None)
        ev.append(_ev(kind, local_dt, "alert"))
    return _log(day, ev), ev


def battery_phase(cfg, day, local_dt):
    """Which UPLOAD interval the watch should use now (battery plan):
    'commute' (1 min) while travelling, 'at_school' / 'at_home' (10 min),
    'night' (60 min) outside the school-day window and on days off."""
    w = window(cfg, local_dt)
    if w in ("off", "night"):
        return "night"
    st = (day or {}).get("state") if (day or {}).get("date") == \
        local_dt.date().isoformat() else "idle"
    if st in ("to_school", "to_home"):
        return "commute"
    if st == "at_school":
        return "at_school"
    if st == "home":
        return "at_home"
    if w == "afternoon":
        return "commute"         # school is over: tracking on by itself
    if w == "morning":
        return "at_home"
    return "at_school"
