"""train — pure rail geometry, fix validation, fusion and timetable estimate.

No Django, no DB: everything here is unit-tested with fixed coordinates.

Data:
  core/data/train/rail_bd.json   OSM rail network, simplified 20 m (ODbL) —
                                 the "is it on ANY rail line" check;
  trains / stations / paths      train-engine (17 Nov): the OFFICIAL Bangladesh
                                 Railway timetable (every train, both
                                 directions) + OSM segments, read through
                                 core.train_source (the data lane's br_*.json,
                                 also loaded into PostgreSQL). The old
                                 Wikipedia file timetable_bd.json is no longer
                                 read. approved:false until the owner checks.

A crowd fix is accepted only when ALL hold:
  1. GPS accuracy is usable (<= MAX_ACC_M);
  2. it lies on a rail line (network distance <= ON_LINE_M + accuracy slack);
  3. it lies on THIS train's route (route distance, same tolerance + path
     simplification slack) — a passenger on the wrong train is refused;
  4. plausible speed versus the same sharer's previous accepted fix
     (<= MAX_SPEED_KMH; Bangladesh trains run well under 120 km/h);
  5. direction: along-route position never goes back more than
     BACKWARD_TOL_M, and a moving GPS bearing agrees with the route heading;
  6. timetable: the train is due to be running (dep - 45 min .. arr + 14 h)
     and is not impossibly AHEAD of its timetable.
Several sharers are fused by the median along-route position; outliers more
than OUTLIER_M from the median are dropped (3+ sharers).
"""
import json
import math
from datetime import datetime, timedelta
from datetime import timezone as _dtz
from functools import lru_cache
from pathlib import Path
from zoneinfo import ZoneInfo

DATA = Path(__file__).resolve().parents[1] / "data" / "train"
DHAKA = ZoneInfo("Asia/Dhaka")
_UTC = _dtz.utc

MAX_ACC_M = 300.0
ON_LINE_M = 120.0
ROUTE_SLACK_M = 60.0          # the route path is simplified at 30 m
MAX_SPEED_KMH = 130.0
BACKWARD_TOL_M = 400.0
BEARING_MIN_KMH = 15.0
BEARING_MAX_DIFF = 100.0
EARLY_START_MIN = 45
LATE_END_H = 14
AHEAD_MAX_MIN = 25
AHEAD_SLACK_M = 2000.0
OUTLIER_M = 2000.0
FRESH_S = 180                 # a sharer's fix counts for live this long
ARRIVE_M = 800.0              # within this of the end of the route = arrived
LOWQ_TOL_M = 2500.0           # flagged OSM gap: matched by progress (train_source)
_CELL = 0.02                  # grid cell (degrees) for the network index


# ------------------------------------------------------------ basic geo
def haversine_m(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(h)))


def bearing_deg(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lng2 - lng1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def angle_diff(a, b):
    d = abs((a - b) % 360.0)
    return 360.0 - d if d > 180.0 else d


def _seg_project(lat, lng, a, b):
    """(distance m, t in 0..1) of point to segment a-b (local flat metres)."""
    k = 111320.0
    c = math.cos(math.radians(lat))
    ax, ay = (a[1] - lng) * k * c, (a[0] - lat) * k
    bx, by = (b[1] - lng) * k * c, (b[0] - lat) * k
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L))
    return math.hypot(ax + t * dx, ay + t * dy), t


# ------------------------------------------------------------ rail network
class Network:
    """Rail lines with a coarse grid index of segments."""

    def __init__(self, lines):
        self.grid = {}
        for line in lines:
            for a, b in zip(line, line[1:]):
                a, b = tuple(a), tuple(b)
                for cell in self._cells(a, b):
                    self.grid.setdefault(cell, []).append((a, b))

    @staticmethod
    def _cells(a, b):
        i0, i1 = sorted((int(math.floor(a[0] / _CELL)), int(math.floor(b[0] / _CELL))))
        j0, j1 = sorted((int(math.floor(a[1] / _CELL)), int(math.floor(b[1] / _CELL))))
        return [(i, j) for i in range(i0, i1 + 1) for j in range(j0, j1 + 1)]

    def distance_m(self, lat, lng):
        """Metres to the nearest rail line (inf beyond ~2 km)."""
        i, j = int(math.floor(lat / _CELL)), int(math.floor(lng / _CELL))
        best = math.inf
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for a, b in self.grid.get((i + di, j + dj), ()):
                    d, _ = _seg_project(lat, lng, a, b)
                    if d < best:
                        best = d
        return best


@lru_cache(maxsize=1)
def network():
    with open(DATA / "rail_bd.json") as fh:
        return Network(json.load(fh)["lines"])


# ------------------------------------------------------------ one route
class Route:
    """A train's path from origin to destination with cumulative metres."""

    def __init__(self, path):
        self.pts = [tuple(p) for p in path]
        self.cum = [0.0]
        for a, b in zip(self.pts, self.pts[1:]):
            self.cum.append(self.cum[-1] + haversine_m(a[0], a[1], b[0], b[1]))
        self.length = self.cum[-1]

    def project(self, lat, lng):
        """(chainage m along the route, offset m from it)."""
        best, ch = math.inf, 0.0
        for i, (a, b) in enumerate(zip(self.pts, self.pts[1:])):
            if (abs(a[0] - lat) > 0.3 and abs(b[0] - lat) > 0.3) or \
               (abs(a[1] - lng) > 0.3 and abs(b[1] - lng) > 0.3):
                continue
            d, t = _seg_project(lat, lng, a, b)
            if d < best:
                best, ch = d, self.cum[i] + t * (self.cum[i + 1] - self.cum[i])
        return ch, best

    def point_at(self, chainage):
        c = max(0.0, min(self.length, chainage))
        for i in range(1, len(self.cum)):
            if self.cum[i] >= c:
                seg = self.cum[i] - self.cum[i - 1]
                t = 0.0 if seg == 0 else (c - self.cum[i - 1]) / seg
                a, b = self.pts[i - 1], self.pts[i]
                return (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]))
        return self.pts[-1]

    def heading_at(self, chainage):
        c = max(0.0, min(self.length, chainage))
        for i in range(1, len(self.cum)):
            if self.cum[i] >= c:
                a, b = self.pts[i - 1], self.pts[i]
                return bearing_deg(a[0], a[1], b[0], b[1])
        a, b = self.pts[-2], self.pts[-1]
        return bearing_deg(a[0], a[1], b[0], b[1])


# ------------------------------------------------------------ timetable
def timetable():
    """{"_meta", "stations", "trains"} — the official data (cached)."""
    from core import train_source
    return train_source.geo_timetable()


def stations():
    return timetable()["stations"]


@lru_cache(maxsize=1)
def _by_no():
    return {t["no"]: t for t in timetable()["trains"]}


def train(no):
    return _by_no().get(str(no or "").strip())


@lru_cache(maxsize=256)
def _route(no):
    t = train(no)
    return Route(t["path"]) if t and len(t.get("path") or []) >= 2 else None


def route(no):
    return _route(str(no))


def _hm(s):
    h, m = s.split(":")
    return int(h), int(m)


def times(t, service_date):
    """(departure, arrival) aware datetimes (Asia/Dhaka) for one service day.
    service_date = the date it leaves its origin. Arrival rolls to the next
    day when the clock time is earlier than departure (overnight trains)."""
    dh, dm = _hm(t["dep"])
    ah, am = _hm(t["arr"])
    dep = datetime(service_date.year, service_date.month, service_date.day, dh, dm, tzinfo=DHAKA)
    arr = datetime(service_date.year, service_date.month, service_date.day, ah, am, tzinfo=DHAKA)
    arr += timedelta(days=int(t.get("arr_day") or 0))
    if arr <= dep:
        arr += timedelta(days=1)
    return dep, arr


def runs_on(t, service_date):
    return service_date.weekday() not in set(t.get("off_days") or [])


def sched_chainage(t, rt, service_date, now):
    """Where the timetable says the train is (metres), linear in time."""
    dep, arr = times(t, service_date)
    if now <= dep:
        return 0.0
    if now >= arr:
        return rt.length
    return rt.length * (now - dep).total_seconds() / (arr - dep).total_seconds()


def _official_times(t, service_date):
    """{station: official scheduled time} when the stops carry times."""
    if not any(s.get("arr") or s.get("dep") for s in t.get("stops") or []):
        return {}
    from core import train_source
    return train_source.stop_times(t, service_date)


def stop_etas(t, rt, service_date):
    """Timetable time at each stop: official when the timetable lists it,
    else interpolated by rail distance (estimate)."""
    off = _official_times(t, service_date)
    if off and all(off.get(s["st"]) for s in t["stops"]):
        return [{"st": s["st"], "km": s["km"], "at": off[s["st"]]} for s in t["stops"]]
    dep, arr = times(t, service_date)
    total = (arr - dep).total_seconds()
    km_total = max(0.001, rt.length / 1000.0)
    out = []
    for s in t["stops"]:
        frac = max(0.0, min(1.0, float(s["km"]) / km_total))
        out.append({"st": s["st"], "km": s["km"],
                    "at": dep + timedelta(seconds=total * frac)})
    return out


def estimate(t, service_date, now):
    """Timetable-only estimate. ALWAYS labelled 'estimate' by the caller."""
    rt = route(t["no"])
    if rt is None:
        return None
    dep, arr = times(t, service_date)
    ch = sched_chainage(t, rt, service_date, now)
    state = "not_started" if now < dep else ("arrived" if now >= arr else "running")
    lat, lng = rt.point_at(ch)
    etas = stop_etas(t, rt, service_date)
    nxt = next((e for e in etas if e["km"] * 1000.0 > ch + 1), None)
    return {"label": "estimate", "state": state, "chainage_m": round(ch),
            "lat": round(lat, 6), "lng": round(lng, 6),
            "next_stop": nxt["st"] if nxt and state == "running" else None,
            "dep": dep, "arr": arr, "approved": bool(t.get("approved"))}


# ------------------------------------------------------------ validation
def validate_fix(t, service_date, fix, prev=None, net=None):
    """Check one crowd fix. fix = {lat, lng, acc, at (aware dt), speed_kmh?,
    bearing?}; prev = the same sharer's previous ACCEPTED fix
    {chainage, at, lat, lng} or None. Returns (ok, reason, chainage, offset)."""
    rt = route(t["no"])
    if rt is None:
        return False, "no_route", None, None
    lat, lng = float(fix["lat"]), float(fix["lng"])
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return False, "bad_coords", None, None
    acc = float(fix.get("acc") or 0.0)
    if acc > MAX_ACC_M:
        return False, "bad_accuracy", None, None
    tol = ON_LINE_M + min(max(acc, 0.0), 150.0)
    net = net or network()
    ch, off = rt.project(lat, lng)
    # train-engine: a flagged OSM gap (straight chord) is matched by progress
    lowq = any(a <= ch <= b for a, b in t.get("lowq") or ()) and off <= LOWQ_TOL_M
    if not lowq and net.distance_m(lat, lng) > tol:
        return False, "off_line", None, None
    if not lowq and off > tol + ROUTE_SLACK_M:
        return False, "off_route", ch, off
    at = fix["at"]
    dep, arr = times(t, service_date)
    if at < dep - timedelta(minutes=EARLY_START_MIN) or at > arr + timedelta(hours=LATE_END_H):
        return False, "not_running", ch, off
    ahead = sched_chainage(t, rt, service_date, at + timedelta(minutes=AHEAD_MAX_MIN))
    if ch > ahead + AHEAD_SLACK_M:
        return False, "ahead_of_timetable", ch, off
    if prev is not None:
        dt = (at - prev["at"]).total_seconds()
        if dt <= 0:
            return False, "stale", ch, off
        dist = haversine_m(prev["lat"], prev["lng"], lat, lng)
        # allow GPS error of both fixes before calling it a speed
        if max(0.0, dist - 2 * min(acc, 100.0)) / dt * 3.6 > MAX_SPEED_KMH:
            return False, "too_fast", ch, off
        if ch < prev["chainage"] - BACKWARD_TOL_M:
            return False, "wrong_way", ch, off
    spd = fix.get("speed_kmh")
    brg = fix.get("bearing")
    if spd is not None and brg is not None and float(spd) >= BEARING_MIN_KMH:
        if angle_diff(float(brg), rt.heading_at(ch)) > BEARING_MAX_DIFF:
            return False, "wrong_way", ch, off
    return True, "ok", ch, off


# ------------------------------------------------------------ fusion
def _median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _advance(f, now):
    """Dead reckoning: chainage + speed x age (age <= FRESH_S, speed <= the
    rail limit). No speed = no move (honest)."""
    spd = f.get("speed_kmh")
    if spd is None:
        return float(f["chainage"])
    age = max(0.0, min(float(FRESH_S), (now - f["at"]).total_seconds()))
    return float(f["chainage"]) + min(float(spd), MAX_SPEED_KMH) / 3.6 * age


def fuse(t, latest, now):
    """latest = [{chainage, at, speed_kmh?}] — each sharer's newest ACCEPTED
    fix. Fresh ones (<= FRESH_S) are fused by the median along-route position;
    with 3+ sharers, those > OUTLIER_M from the median are dropped.
    Returns None when nobody fresh is sharing."""
    rt = route(t["no"])
    fresh = [f for f in latest if rt is not None and
             0 <= (now - f["at"]).total_seconds() <= FRESH_S]
    if not fresh:
        return None
    dropped = 0
    # sjtrain: each fix moved forward by its own speed x its age (capped), so
    # a 2-minute-old fix at 80 km/h is not 2.7 km behind the train
    fresh = [dict(f, chainage=_advance(f, now)) for f in fresh]
    if len(fresh) >= 3:
        med = _median([f["chainage"] for f in fresh])
        keep = [f for f in fresh if abs(f["chainage"] - med) <= OUTLIER_M]
        dropped = len(fresh) - len(keep)
        fresh = keep or fresh
    ch = min(rt.length, _median([f["chainage"] for f in fresh]))
    lat, lng = rt.point_at(ch)
    newest = max(f["at"] for f in fresh)
    speeds = [float(f["speed_kmh"]) for f in fresh if f.get("speed_kmh") is not None]
    return {"label": "live", "chainage_m": round(ch), "lat": round(lat, 6),
            "lng": round(lng, 6), "sharers": len(fresh), "dropped": dropped,
            "age_s": int((now - newest).total_seconds()),
            "speed_kmh": round(_median(speeds)) if speeds else None,
            "arrived": ch >= rt.length - ARRIVE_M}


def delay_minutes(t, service_date, chainage, now):
    """Minutes behind the timetable at this position (negative = ahead)."""
    rt = route(t["no"])
    if rt is None or rt.length <= 0:
        return None
    dep, arr = times(t, service_date)
    due = dep + (arr - dep) * (max(0.0, min(rt.length, chainage)) / rt.length)
    return int(round((now - due).total_seconds() / 60.0))


def next_stop_after(t, chainage):
    for s in t["stops"]:
        if float(s["km"]) * 1000.0 > chainage + 1:
            return s["st"]
    return None


# ------------------------------------------------------------ sjtrain: the station line
@lru_cache(maxsize=1)
def _line_data():
    try:
        with open(DATA / "line_stations_bd.json", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"trains": {}}


def line_stations(t):
    """Every station the train passes, in order: [{id, bn, en, km, lat, lng,
    stop}] (stop = a timetable halt). Falls back to the timetable stops."""
    from core import train_source
    rows = train_source.geo_line_stations(t["no"])
    if rows:
        return rows
    st = stations()
    return [dict(id=s["st"], bn=st[s["st"]].get("bn", ""), en=st[s["st"]].get("en", ""),
                 km=s["km"], lat=st[s["st"]]["lat"], lng=st[s["st"]]["lng"], stop=True)
            for s in t["stops"] if s["st"] in st]


def line_view(t, service_date, chainage, now, delay_min=None):
    """The metro-style line: each station with passed / now / ETA.
    chainage = where the train is (live or the timetable estimate);
    delay_min shifts the timetable times (live only). Returns
    {"stations": [...], "now_index", "passing", "next_index"}."""
    rt = route(t["no"])
    rows = line_stations(t)
    if rt is None or not rows:
        return {"stations": [], "now_index": None, "passing": None, "next_index": None}
    dep, arr = times(t, service_date)
    total = (arr - dep).total_seconds()
    km_total = max(0.001, rt.length / 1000.0)
    shift = timedelta(minutes=delay_min or 0)
    off = _official_times(t, service_date)
    timed = sorted((float(s["km"]), off[s["st"]]) for s in t["stops"] if off.get(s["st"]))
    out, now_i, next_i = [], None, None
    for i, r in enumerate(rows):
        m = float(r["km"]) * 1000.0
        official = bool(off.get(r["id"])) and any(
            s["st"] == r["id"] and (s.get("arr") or s.get("dep")) for s in t["stops"])
        if off.get(r["id"]):
            sched = off[r["id"]]
        elif len(timed) >= 2:
            k = float(r["km"])
            lo = max((x for x in timed if x[0] <= k), default=timed[0])
            hi = min((x for x in timed if x[0] >= k), default=timed[-1])
            f = 0.0 if hi[0] == lo[0] else (k - lo[0]) / (hi[0] - lo[0])
            sched = lo[1] + (hi[1] - lo[1]) * f
        else:
            sched = dep + timedelta(seconds=total * max(0.0, min(1.0, float(r["km"]) / km_total)))
        passed = chainage is not None and m <= chainage + 150.0
        if passed:
            now_i = i
        elif next_i is None and chainage is not None:
            next_i = i
        out.append({"id": r["id"], "bn": r.get("bn", ""), "en": r.get("en", ""),
                    "km": r["km"], "stop": bool(r.get("stop")),
                    "lat": r.get("lat"), "lng": r.get("lng"),
                    "sched": sched.isoformat(), "eta": (sched + shift).isoformat(),
                    # official time from the timetable, or placed between known halts
                    "sched_official": official,
                    "passed": passed})
    passing = None
    if now_i is not None and chainage is not None:
        here = float(rows[now_i]["km"]) * 1000.0
        if chainage - here <= 1500.0:      # within 1.5 km = "passing X"
            passing = now_i
    return {"stations": out, "now_index": now_i, "passing": passing, "next_index": next_i}


# ------------------------------------------------------------ sjtrain: sun side
def sun_position(lat, lng, at):
    """(azimuth deg from north clockwise, elevation deg) — NOAA low-precision
    formulas, good to ~1 degree; enough to say which side of a coach is sunny."""
    utc = at.astimezone(_UTC)
    doy = utc.timetuple().tm_yday
    hour = utc.hour + utc.minute / 60.0 + utc.second / 3600.0
    g = 2 * math.pi / 365.0 * (doy - 1 + (hour - 12) / 24.0)
    eqt = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                    - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g)
            - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
            - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    tst = hour * 60 + eqt + 4 * lng                      # true solar time, minutes
    ha = math.radians(tst / 4.0 - 180.0)
    la = math.radians(lat)
    cos_z = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha)
    zen = math.acos(max(-1.0, min(1.0, cos_z)))
    elev = 90.0 - math.degrees(zen)
    az = math.degrees(math.atan2(math.sin(ha),
                                 math.cos(ha) * math.sin(la) - math.tan(decl) * math.cos(la)))
    return (az + 180.0) % 360.0, elev


SUN_MIN_ELEV = 8.0       # lower than this the sun is not "in your face" through a window


def sun_side(t, service_date, step_km=5.0):
    """Which side (in the direction of travel) gets direct sun on this trip,
    from the rail path + timetable times. -> {"left": %, "right": %,
    "dark": %, "side": "left"|"right"|"none"} (percent of trip time)."""
    rt = route(t["no"])
    if rt is None or rt.length <= 0:
        return None
    dep, arr = times(t, service_date)
    total = (arr - dep).total_seconds()
    n = max(2, int(rt.length / 1000.0 / step_km))
    left = right = dark = 0
    for i in range(n):
        ch = rt.length * (i + 0.5) / n
        at = dep + timedelta(seconds=total * (i + 0.5) / n)
        lat, lng = rt.point_at(ch)
        az, el = sun_position(lat, lng, at)
        if el < SUN_MIN_ELEV:
            dark += 1
            continue
        rel = (az - rt.heading_at(ch)) % 360.0
        if rel < 180.0:
            right += 1
        else:
            left += 1
    pct = lambda x: int(round(100.0 * x / n))
    side = "none"
    if left + right and max(left, right) >= 1.5 * min(left, right) and \
            max(left, right) >= 0.2 * n:
        side = "left" if left > right else "right"
    return {"left": pct(left), "right": pct(right), "dark": pct(dark), "side": side,
            "label": "calculated"}
