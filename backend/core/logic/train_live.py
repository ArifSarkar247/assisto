"""train-engine — pure rules of the LIVE train engine (Train Tracker V2).

No Django, no DB, no Redis: everything here is unit-tested with fixed numbers.
The DB / Redis side is core/train_engine.py.

  * RouteIndex   — per-route grid spatial index: (chainage, offset) of a GPS
                   point in O(nearby segments), with a "hint" so a route that
                   passes the same place twice picks the expected pass;
  * point checks — keep a rider point ONLY when: not from a mock provider,
                   accuracy usable, within ON_ROUTE_M (100 m) of THIS train's
                   rail polyline, speed plausible for a train and not more than
                   2x the segment's max speed (reported AND implied speed);
  * Kalman1D     — per rider, 1-D along the line: state (position m, speed m/s);
  * consensus    — weighted median of the riders' filtered positions, outliers
                   dropped, trust scores move (majority wins);
  * cell towers  — learned tower -> track histogram, honest placement;
  * ETA / delay  — remaining km / rolling average speed x 60 + 2 min buffer;
                   stopped -> last-15-min average, else the route standard speed.

Never claims certainty: every result carries a confidence < 1 and its age.
"""
import math

# ------------------------------------------------------------ constants
ON_ROUTE_M = 100.0            # owner order B: keep a point only within 100 m of the line
LOWQ_TOL_M = 2500.0           # ...except on a flagged OSM gap (drawn as a straight chord)
MAX_ACC_M = 150.0             # worse GPS than this is not a position (cell may place it)
MAX_TRAIN_KMH = 130.0         # nothing in Bangladesh runs faster
DEFAULT_SEG_MAX_KMH = 100.0   # section limit when the data has none
SEG_MAX_FACTOR = 2.0          # "not > 2x the segment's max"
SPEED_ERR_M = 2.0             # x accuracy, GPS error allowance on implied speed
STOPPED_KMH = 5.0
ETA_BUFFER_MIN = 2.0
HIST_WINDOW_S = 15 * 60       # rolling average window
FRESH_S = 180                 # a rider counts as live this long after its last point
OUTLIER_MIN_M = 1000.0
TRUST_START = 0.6
TRUST_MIN, TRUST_MAX = 0.05, 1.0
TRUST_UP, TRUST_DOWN = 0.03, 0.15
CONF_CAP = 0.95               # never "100% accurate"
CELL_BIN_DEG = 0.005          # ~550 m bins for the tower -> track histogram
CELL_ON_ROUTE_M = 1500.0
CELL_MIN_N = 3
_GRID = 0.01                  # ~1.1 km grid cells (>> ON_ROUTE_M, so 3x3 is enough)
K_LAT = 111320.0


def haversine_m(lat1, lng1, lat2, lng2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(h)))


def _seg(lat, lng, a, b):
    c = math.cos(math.radians(lat))
    ax, ay = (a[1] - lng) * K_LAT * c, (a[0] - lat) * K_LAT
    bx, by = (b[1] - lng) * K_LAT * c, (b[0] - lat) * K_LAT
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L))
    return math.hypot(ax + t * dx, ay + t * dy), t


# ------------------------------------------------------------ spatial index
class RouteIndex:
    """One train's polyline [(lat, lng), ...] with cumulative metres and a
    grid of segment ids. project() looks only at the 3x3 cells around the
    point (no PostGIS needed; ~microseconds per point)."""

    def __init__(self, path):
        self.pts = [(float(p[0]), float(p[1])) for p in path]
        self.cum = [0.0]
        for a, b in zip(self.pts, self.pts[1:]):
            self.cum.append(self.cum[-1] + haversine_m(a[0], a[1], b[0], b[1]))
        self.length = self.cum[-1]
        self.grid = {}
        for i, (a, b) in enumerate(zip(self.pts, self.pts[1:])):
            i0, i1 = sorted((math.floor(a[0] / _GRID), math.floor(b[0] / _GRID)))
            j0, j1 = sorted((math.floor(a[1] / _GRID), math.floor(b[1] / _GRID)))
            for gi in range(i0, i1 + 1):
                for gj in range(j0, j1 + 1):
                    self.grid.setdefault((gi, gj), []).append(i)

    def candidates(self, lat, lng, radius_cells=1):
        gi, gj = math.floor(lat / _GRID), math.floor(lng / _GRID)
        seen = set()
        for di in range(-radius_cells, radius_cells + 1):
            for dj in range(-radius_cells, radius_cells + 1):
                for i in self.grid.get((gi + di, gj + dj), ()):
                    if i not in seen:
                        seen.add(i)
                        yield i

    def project(self, lat, lng, hint=None, radius_cells=1):
        """(chainage m, offset m) of the nearest point on the route, or
        (None, inf) when nothing is within ~1 km. With `hint` (expected
        chainage) a pass within 30 m of the best is preferred if closer to it."""
        found = []
        for i in self.candidates(lat, lng, radius_cells):
            d, t = _seg(lat, lng, self.pts[i], self.pts[i + 1])
            found.append((d, self.cum[i] + t * (self.cum[i + 1] - self.cum[i])))
        if not found:
            return None, math.inf
        best = min(found)
        if hint is not None:
            near = [f for f in found if f[0] <= best[0] + 30.0]
            best = min(near, key=lambda f: (abs(f[1] - hint), f[0]))
        return best[1], best[0]

    def point_at(self, ch):
        c = max(0.0, min(self.length, ch))
        lo, hi = 0, len(self.cum) - 1
        while lo < hi:                       # first cum >= c
            mid = (lo + hi) // 2
            if self.cum[mid] < c:
                lo = mid + 1
            else:
                hi = mid
        i = max(1, lo)
        seg = self.cum[i] - self.cum[i - 1]
        t = 0.0 if seg == 0 else (c - self.cum[i - 1]) / seg
        a, b = self.pts[i - 1], self.pts[i]
        return a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])


# ------------------------------------------------------------ segment speed
def seg_max_kmh(stops, chainage, sched_avg=None):
    """Max line speed around `chainage`: the data's own `max_kmh` on the stop
    that starts the section when present, else max(60, 1.6 x the scheduled
    average between those stops), else DEFAULT_SEG_MAX_KMH."""
    prev = None
    for s in stops or ():
        if float(s.get("km") or 0) * 1000.0 <= chainage:
            prev = s
    if prev and prev.get("max_kmh"):
        return float(prev["max_kmh"])
    if sched_avg:
        return max(60.0, 1.6 * float(sched_avg))
    return DEFAULT_SEG_MAX_KMH


def speed_limit_kmh(seg_max):
    return min(MAX_TRAIN_KMH, SEG_MAX_FACTOR * float(seg_max))


def in_ranges(ch, ranges):
    return ch is not None and any(a <= ch <= b for a, b in ranges or ())


def check_point(p, rt, prev=None, seg_max=DEFAULT_SEG_MAX_KMH, hint=None, lowq=None):
    """One rider point. p = {lat, lng, acc, speed (m/s)|None, heading|None,
    mock, at (epoch s)}; prev = the trip's last ACCEPTED {ch, at, acc};
    lowq = [(from_ch, to_ch)] flagged OSM-gap stretches (straight chord, wide
    tolerance: accepted by progress between the two stations).
    -> (ok, reason, chainage|None, offset|None)."""
    if p.get("mock"):
        return False, "mock", None, None
    lat, lng = p.get("lat"), p.get("lng")
    if lat is None or lng is None or not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return False, "no_gps", None, None
    acc = float(p.get("acc") or 0.0)
    if acc > MAX_ACC_M:
        return False, "bad_accuracy", None, None
    ch, off = rt.project(lat, lng, hint=hint)
    if (ch is None or off > ON_ROUTE_M) and lowq:
        ch2, off2 = rt.project(lat, lng, hint=hint, radius_cells=3)
        if in_ranges(ch2, lowq) and off2 <= LOWQ_TOL_M:
            ch, off = ch2, 0.0 if off2 <= ON_ROUTE_M else off2
    if ch is None or (off > ON_ROUTE_M and not (in_ranges(ch, lowq) and off <= LOWQ_TOL_M)):
        return False, "off_line", ch, (None if off == math.inf else off)
    lim = speed_limit_kmh(seg_max)
    spd = p.get("speed")
    if spd is not None and float(spd) * 3.6 > lim:
        return False, "too_fast", ch, off
    if prev is not None:
        dt = float(p["at"]) - float(prev["at"])
        if dt <= 0:
            return False, "stale", ch, off
        moved = max(0.0, abs(ch - prev["ch"]) - SPEED_ERR_M * (min(acc, 50.0) + min(
            float(prev.get("acc") or 0), 50.0)))
        if moved / dt * 3.6 > lim:
            return False, "too_fast", ch, off
    return True, "ok", ch, off


# ------------------------------------------------------------ Kalman 1-D
class Kalman1D:
    """Constant-velocity filter along the line. state x=[pos m, speed m/s],
    P 2x2. q = acceleration noise (m/s^2)."""
    Q_ACC = 0.4
    V_MAX = MAX_TRAIN_KMH / 3.6

    def __init__(self, x=0.0, v=0.0, P=None, t=None):
        self.x, self.v = float(x), float(v)
        self.P = P or [[400.0 ** 2, 0.0], [0.0, 10.0 ** 2]]
        self.t = t

    @classmethod
    def from_state(cls, s):
        if not s:
            return None
        return cls(s["x"], s["v"], s["P"], s["t"])

    def state(self):
        return {"x": round(self.x, 1), "v": round(self.v, 3),
                "P": [[round(c, 3) for c in r] for r in self.P], "t": self.t}

    def predict(self, t):
        if self.t is None:
            self.t = t
            return self
        dt = max(0.0, float(t) - float(self.t))
        if dt == 0:
            return self
        self.x += self.v * dt
        p = self.P
        q = self.Q_ACC ** 2
        p00 = p[0][0] + dt * (p[1][0] + p[0][1]) + dt * dt * p[1][1] + q * dt ** 4 / 4
        p01 = p[0][1] + dt * p[1][1] + q * dt ** 3 / 2
        p11 = p[1][1] + q * dt * dt
        self.P = [[p00, p01], [p01, p11]]
        self.t = t
        return self

    def update_pos(self, z, r):
        p = self.P
        s = p[0][0] + r
        k0, k1 = p[0][0] / s, p[1][0] / s
        y = z - self.x
        self.x += k0 * y
        self.v += k1 * y
        self.P = [[(1 - k0) * p[0][0], (1 - k0) * p[0][1]],
                  [p[1][0] - k1 * p[0][0], p[1][1] - k1 * p[0][1]]]
        self._clamp()
        return self

    def update_speed(self, z, r):
        p = self.P
        s = p[1][1] + r
        k0, k1 = p[0][1] / s, p[1][1] / s
        y = z - self.v
        self.x += k0 * y
        self.v += k1 * y
        self.P = [[p[0][0] - k0 * p[1][0], p[0][1] - k0 * p[1][1]],
                  [(1 - k1) * p[1][0], (1 - k1) * p[1][1]]]
        self._clamp()
        return self

    def _clamp(self):
        self.v = max(0.0, min(self.V_MAX, self.v))

    def sigma(self):
        return math.sqrt(max(0.0, self.P[0][0]))


def gps_r(acc):
    """Measurement variance of a matched GPS chainage (accuracy + path slack)."""
    return max(float(acc or 0), 10.0) ** 2 + 20.0 ** 2


def step(kf, t, ch, acc=None, speed=None, r=None):
    """Feed one accepted point (or a cell placement with its own r)."""
    if kf is None:
        kf = Kalman1D(ch, float(speed or 0.0), None, t)
        kf.P[0][0] = r if r is not None else gps_r(acc)
    else:
        kf.predict(t)
        kf.update_pos(ch, r if r is not None else gps_r(acc))
    if speed is not None and r is None:
        kf.update_speed(float(speed), 1.5 ** 2)
    return kf


# ------------------------------------------------------------ consensus
def weighted_median(pairs):
    """pairs = [(value, weight>0)] -> the weighted median value."""
    pairs = sorted((v, w) for v, w in pairs if w > 0)
    if not pairs:
        return None
    half = sum(w for _, w in pairs) / 2.0
    acc = 0.0
    for v, w in pairs:
        acc += w
        if acc >= half:
            return v
    return pairs[-1][0]


def consensus(riders):
    """riders = [{id, x, v, sigma, trust}] (already predicted to now).
    Weighted median -> inliers (within max(OUTLIER_MIN_M, 3 sigma)) ->
    weighted mean of inliers. With 3+ riders the majority wins and every
    outlier's trust drops; with exactly 2 that disagree there is no majority:
    the more trusted one wins, nobody's trust moves, confidence is lower.
    -> {x, v, inliers, outliers, trust:{id: new}, agree} or None."""
    if not riders:
        return None
    w = {r["id"]: max(TRUST_MIN, r["trust"]) / (1.0 + (r["sigma"] / 100.0) ** 2)
         for r in riders}
    med = weighted_median([(r["x"], w[r["id"]]) for r in riders])
    tol = {r["id"]: max(OUTLIER_MIN_M, 3.0 * r["sigma"]) for r in riders}
    inl = [r for r in riders if abs(r["x"] - med) <= tol[r["id"]]]
    out = [r for r in riders if r not in inl]
    trust = {}
    if len(riders) == 2 and out:
        a, b = sorted(riders, key=lambda r: (-r["trust"], r["sigma"]))
        inl, out = [a], []
        agree = False
    else:
        agree = len(inl) > len(out)
        if len(riders) >= 3 and agree:
            for r in out:
                trust[r["id"]] = max(TRUST_MIN, r["trust"] - TRUST_DOWN)
            for r in inl:
                trust[r["id"]] = min(TRUST_MAX, r["trust"] + TRUST_UP)
        elif len(riders) == 2:
            for r in inl:
                trust[r["id"]] = min(TRUST_MAX, r["trust"] + TRUST_UP / 2)
        if not agree:               # no majority: keep everybody, lower confidence
            inl, out = riders, []
    sw = sum(w[r["id"]] for r in inl)
    x = sum(r["x"] * w[r["id"]] for r in inl) / sw
    v = sum(r["v"] * w[r["id"]] for r in inl) / sw
    return {"x": x, "v": v, "inliers": [r["id"] for r in inl],
            "outliers": [r["id"] for r in out], "trust": trust, "agree": agree}


def gps_confidence(n, mean_trust, age_s, agree=True):
    base = {1: 0.6, 2: 0.72}.get(n, 0.85 if n < 5 else 0.9)
    if not agree:
        base -= 0.2
    c = base * (0.6 + 0.4 * mean_trust) * max(0.3, 1.0 - age_s / 600.0)
    return round(min(CONF_CAP, max(0.05, c)), 2)


# ------------------------------------------------------------ rolling speed / ETA
def push_hist(hist, t, x, window=HIST_WINDOW_S):
    """hist = [[t, x], ...] newest last; keeps the last `window` seconds."""
    hist = [h for h in (hist or []) if t - h[0] <= window and h[0] < t]
    hist.append([int(t), round(float(x), 1)])
    return hist


def rolling_kmh(hist):
    if not hist or len(hist) < 2:
        return None
    (t0, x0), (t1, x1) = hist[0], hist[-1]
    if t1 - t0 < 60:
        return None
    return max(0.0, (x1 - x0) / (t1 - t0) * 3.6)


def eta_speed_kmh(now_kmh, hist, standard_kmh):
    """Speed used for ETAs: the rolling 15-min average while moving; when
    stopped (< STOPPED_KMH) the last-15-min average if it is useful, else the
    route standard speed (length / scheduled duration)."""
    avg = rolling_kmh(hist)
    if now_kmh is not None and now_kmh >= STOPPED_KMH:
        return avg if avg and avg >= 10.0 else max(float(now_kmh), 10.0)
    if avg and avg >= 10.0:
        return avg
    return max(10.0, float(standard_kmh or 40.0))


def eta_minutes(remaining_km, speed_kmh):
    return max(0.0, remaining_km) / max(1.0, speed_kmh) * 60.0 + ETA_BUFFER_MIN


# ------------------------------------------------------------ cell towers
def cell_key(c):
    """{mcc, mnc, tac|lac, cid} -> 'mcc-mnc-tac-cid' or None."""
    if not isinstance(c, dict):
        return None
    try:
        parts = [int(c["mcc"]), int(c["mnc"]), int(c.get("tac", c.get("lac"))), int(c["cid"])]
    except (KeyError, TypeError, ValueError):
        return None
    if not (100 <= parts[0] <= 999) or parts[1] < 0 or parts[2] <= 0 or parts[3] <= 0:
        return None
    if parts[2] >= 2 ** 31 - 1 or parts[3] >= 2 ** 36:   # Android "unknown" sentinels
        return None
    return "%d-%d-%d-%d" % tuple(parts)


def cell_bin(lat, lng):
    return int(math.floor(lat / CELL_BIN_DEG)), int(math.floor(lng / CELL_BIN_DEG))


def bin_center(bi, bj):
    return (bi + 0.5) * CELL_BIN_DEG, (bj + 0.5) * CELL_BIN_DEG


def place_by_cell(bins, rt, hint=None):
    """bins = [(bin_lat, bin_lng, n)] learned for ONE tower. Projects each
    bin onto this route; -> {x, spread_m, n, confidence} or None when the
    tower was never seen on this line (honest: no guess)."""
    pairs = []
    for bi, bj, n in bins:
        lat, lng = bin_center(bi, bj)
        ch, off = rt.project(lat, lng, hint=hint, radius_cells=2)
        if ch is not None and off <= CELL_ON_ROUTE_M:
            pairs.append((ch, float(n)))
    total = sum(w for _, w in pairs)
    if total < CELL_MIN_N:
        return None
    x = weighted_median(pairs)
    spread = weighted_median([(abs(c - x), w) for c, w in pairs]) or 0.0
    spread = max(spread, 400.0)
    conf = min(0.4, total / (total + 15.0) * 0.5) * max(0.2, 1.0 - spread / 4000.0)
    return {"x": x, "spread_m": round(spread), "n": int(total),
            "confidence": round(max(0.05, conf), 2)}


# ------------------------------------------------------------ G: learned delay
DELAY_HALF_LIFE_D = 28.0      # recency weight: a 4-week-old pass counts half
DELAY_MIN_N = 3               # train x station x weekday needs this many passes
DELAY_MIN_N_ANYDAY = 5        # fallback: same train x station, any weekday
DELAY_CLAMP = (-30, 600)
PREDICT_CONF = 0.3            # "predicted" is never "live"


def learned_delay(samples, min_n=DELAY_MIN_N):
    """samples = [(days_ago, delay_min)] -> {delay_min, n, p25, p75} or None.
    Recency-weighted median (robust to one very late day) with quartiles."""
    rows = [(max(0.0, float(a)), max(DELAY_CLAMP[0], min(DELAY_CLAMP[1], float(dl))))
            for a, dl in samples]
    if len(rows) < min_n:
        return None
    pairs = [(dl, 0.5 ** (a / DELAY_HALF_LIFE_D)) for a, dl in rows]
    total = sum(w for _, w in pairs)

    def q(f):
        acc = 0.0
        for v, w in sorted(pairs):
            acc += w
            if acc >= f * total:
                return v
        return sorted(pairs)[-1][0]
    return {"delay_min": int(round(q(0.5))), "n": len(rows),
            "p25": int(round(q(0.25))), "p75": int(round(q(0.75)))}


def predict_chainage(stops_km_times, now_ts):
    """stops_km_times = [(km, predicted epoch s)] in order -> metres along
    the route at now (linear between predicted halts), or None."""
    pts = sorted(stops_km_times, key=lambda p: p[0])
    if not pts:
        return None
    if now_ts <= pts[0][1]:
        return pts[0][0] * 1000.0
    for (k0, t0), (k1, t1) in zip(pts, pts[1:]):
        if t0 <= now_ts <= t1:
            f = 0.0 if t1 <= t0 else (now_ts - t0) / (t1 - t0)
            return (k0 + f * (k1 - k0)) * 1000.0
    return pts[-1][0] * 1000.0


# ------------------------------------------------------------ B: "Are you on this train?"
ASK_MIN_KMH = 15.0
ASK_MIN_POINTS = 2


def onboard_signal(points, rt, seg_max=DEFAULT_SEG_MAX_KMH):
    """points = recent fixes [{lat, lng, acc, speed (m/s)?, at (epoch), mock?}]
    (NOT stored). -> {ask, on_line, train_speed, forward, km, speed_kmh}.
    ask = every fix within ON_ROUTE_M of the line, moving forward along it at
    a train speed (>= ASK_MIN_KMH, <= the line limit), no mock fix."""
    pts = sorted([p for p in points or [] if p.get("lat") is not None and
                  p.get("lng") is not None and p.get("at") is not None],
                 key=lambda p: p["at"])
    out = {"ask": False, "on_line": False, "train_speed": False, "forward": False,
           "km": None, "speed_kmh": None}
    if len(pts) < ASK_MIN_POINTS or any(p.get("mock") for p in pts):
        return out
    proj = []
    for p in pts:
        if float(p.get("acc") or 0) > MAX_ACC_M:
            return out
        ch, off = rt.project(p["lat"], p["lng"], hint=proj[-1] if proj else None)
        if ch is None or off > ON_ROUTE_M:
            return out
        proj.append(ch)
    out["on_line"] = True
    out["km"] = round(proj[-1] / 1000.0, 2)
    dt = float(pts[-1]["at"]) - float(pts[0]["at"])
    if dt <= 0:
        return out
    implied = (proj[-1] - proj[0]) / dt * 3.6
    rep = [float(p["speed"]) * 3.6 for p in pts if p.get("speed") is not None]
    kmh = sorted(rep)[len(rep) // 2] if rep else abs(implied)
    out["speed_kmh"] = round(kmh)
    out["forward"] = proj[-1] - proj[0] > 30.0
    out["train_speed"] = ASK_MIN_KMH <= kmh <= speed_limit_kmh(seg_max)
    out["ask"] = out["on_line"] and out["forward"] and out["train_speed"]
    return out
