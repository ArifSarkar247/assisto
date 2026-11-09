"""qjourney (Safe Journey V2, owner 9 Nov): is a manual "I've arrived" plausible?

Root cause of the owner's false "Arrived safely" (a Gazipur trip "arrived"
5 minutes after leaving Badda; two 6 Nov trips "arrived" while the phone was
still at the start): POST /journey/<id>/arrived accepted an arrival ANYWHERE,
at ANY time, and a trip could start with a destination that had no
coordinates. This module is the plausibility check the endpoint now runs.

Rule (owner): early does not mean safe. An arrival is UNUSUAL when
  * the destination has no coordinates (cannot be checked), or
  * we do not know where the phone is (no fresh fix), or
  * the phone is more than NEAR_M from the destination, or
  * it is earlier than C = the earliest PHYSICALLY possible time: straight-
    line distance from the start / the mode's top speed (roads are never
    shorter than a straight line, so C is a true lower bound).
An unusual arrival is never "Arrived safely": the traveller is asked for the
safety PIN (when one is set) and watchers see "Unusual arrival".

Pure: no Django imports (unit-tested on plain values).
"""
import math
from datetime import timedelta

NEAR_M = 1000           # "Nearly there" ring (owner spec); a tap inside it is fine
FIX_MAX_AGE_MIN = 15    # an older stored fix does not say where the phone is now
FIX_MAX_ACC_M = 300     # a phone-sent fix worse than this is not trusted

# straight-line top speeds, km/h (generous on purpose: C must never be later
# than a real arrival)
TOP_KMH = {
    "walk": 10, "rickshaw": 25, "launch": 45, "cng": 80, "local_bus": 80,
    "metro": 100, "bike": 110, "bus": 110, "long_bus": 110, "car": 130,
    "ride": 130, "train": 130,
}
DEFAULT_KMH = 130

# a destination that is a whole AREA (picked from our place list as a
# district, town, ...) is "reached" anywhere inside it, not at its centre
AREA_NEAR_M = {"division": 60000, "district": 15000, "upazila": 8000, "city": 8000,
               "union": 4000, "town": 3000, "area": 1500}


def near_for_kind(kind):
    return AREA_NEAR_M.get(str(kind or "").lower(), NEAR_M)


def _f(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


def point(d):
    """(lat, lng) of a dict with numeric, in-range lat/lng — else None."""
    if not isinstance(d, dict):
        return None
    lat, lng = _f(d.get("lat")), _f(d.get("lng"))
    if lat is None or lng is None or not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return None
    if lat == 0 and lng == 0:
        return None     # "null island": a missing value sent as 0,0
    return lat, lng


def haversine_m(a, b):
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def earliest_arrival(start_at, origin, dest, mode="", near_m=NEAR_M):
    """C: the earliest physically possible arrival (datetime), or None when
    the start point is unknown. A trip inside the NEAR_M ring has C = start."""
    if start_at is None or origin is None or dest is None:
        return None
    km = max(0.0, haversine_m(origin, dest) - max(NEAR_M, near_m)) / 1000.0
    kmh = TOP_KMH.get((mode or "").lower(), DEFAULT_KMH)
    return start_at + timedelta(hours=km / kmh)


def assess(*, dest, now, start_at=None, origin=None, here=None, here_at=None,
           mode="", radius_m=0, near_m=NEAR_M):
    """-> dict(ok, reason, distance_m, earliest_at).

    reason: '' (plausible) | 'no_destination' | 'no_location' | 'far' | 'too_early'.
    `here` = the phone's current (lat, lng); `here_at` its time (None = now).
    """
    out = {"ok": False, "reason": "", "distance_m": None, "earliest_at": None}
    if dest is None:
        out["reason"] = "no_destination"
        return out
    c = earliest_arrival(start_at, origin, dest, mode, near_m)
    out["earliest_at"] = c
    if here is not None and here_at is not None and \
            now - here_at > timedelta(minutes=FIX_MAX_AGE_MIN):
        here = None
    if here is None:
        out["reason"] = "no_location"
        return out
    dist = haversine_m(here, dest)
    out["distance_m"] = int(round(dist))
    if dist > max(NEAR_M, int(radius_m or 0), int(near_m or 0)):
        out["reason"] = "far"
        return out
    if c is not None and now < c:
        out["reason"] = "too_early"
        return out
    out["ok"] = True
    return out
