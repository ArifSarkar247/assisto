"""train — pure rail geometry, fix validation, fusion and timetable estimate.

No Django, no DB: everything here is unit-tested with fixed coordinates.

Data (bundled, built by tools/train/build_train_data.py — sources and dates
inside each file's "_meta"):
  core/data/train/rail_bd.json       OSM rail network, simplified 20 m (ODbL)
  core/data/train/timetable_bd.json  intercity trains: stops, route path,
                                     origin dep / destination arr (Bangla
                                     Wikipedia, CC BY-SA), approved:false until
                                     the owner checks the official timetable.

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
from functools import lru_cache
from pathlib import Path
from zoneinfo import ZoneInfo

DATA = Path(__file__).resolve().parents[1] / "data" / "train"
DHAKA = ZoneInfo("Asia/Dhaka")

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
@lru_cache(maxsize=1)
def timetable():
    with open(DATA / "timetable_bd.json", encoding="utf-8") as fh:
        return json.load(fh)


def stations():
    return timetable()["stations"]


def train(no):
    no = str(no or "").strip()
    for t in timetable()["trains"]:
        if t["no"] == no:
            return t
    return None


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


def stop_etas(t, rt, service_date):
    """Timetable time at each stop, interpolated by rail distance (estimate)."""
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
    if net.distance_m(lat, lng) > tol:
        return False, "off_line", None, None
    ch, off = rt.project(lat, lng)
    if off > tol + ROUTE_SLACK_M:
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
    if len(fresh) >= 3:
        med = _median([f["chainage"] for f in fresh])
        keep = [f for f in fresh if abs(f["chainage"] - med) <= OUTLIER_M]
        dropped = len(fresh) - len(keep)
        fresh = keep or fresh
    ch = _median([f["chainage"] for f in fresh])
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
