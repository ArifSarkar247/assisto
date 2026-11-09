"""cctvdet (CCTV Guard V3, part C, stage 1): ZONE DETECTIONS drawn by the
owner on the camera picture. ONE set of rules for the Shop Box (this file)
and the phone / Android Guard Box (app/lib/cctv/detect_rules.dart, a line
for line port). Both test suites run the SAME cases
(tests/fixtures/detect_cases.json) and assert their constants equal
cctv_thresholds.json["detect"].

Pure: plain lists and floats in, plain dicts out (no numpy, no clock, no
I/O), so every rule is pinned by unit tests and the CI accuracy harness
(tools/e2e/cctv_accuracy.py) measures exactly this code.

Zone types (normalised 0..1 polygons, schema v2) and what they detect:

  gate        PERSON AT THE SHUTTER / GATE: a person box overlaps the zone
              on GATE_CONFIRM checked frames in a row while the zone is
              armed -> "gate_person" (once per visit).
              GATE LEFT OPEN (opt-in, opts.watch_open): the zone's picture
              no longer matches the remembered CLOSED picture for
              opts.open_min minutes, nobody standing in it -> "gate_open"
              (once until it matches "closed" again).
  post        COUNTER / POST LEFT EMPTY: while the zone's own schedule says
              someone must be there, no person overlaps it for
              opts.absent_min minutes -> "post_empty" (once per absence).
  restricted  INTRUSION (analyzer.py, unchanged) + optional dwell below.
  any zone    LOITERING (opts.dwell_s > 0): one visit (a person present,
              gaps < PRESENCE_GAP_S) lasts dwell_s -> "loitering"
              {zone_dwell} (once per visit).

A box "overlaps" a zone when >= ZONE_HIT_POINTS of the 3 x 3 grid points
inside the box fall in the polygon (the phone's boxInZone rule): robust to
the feet being hidden behind a counter, and a person merely walking PAST a
small zone's corner does not count.

Without the person model (boxes is None) the person rules stay silent —
honest: we never guess presence or absence from motion. "gate left open"
needs no model (it compares pictures) and camera tamper (TamperCheck, the
server's still rule from core/logic/cctv_rules.assess_still, ported) needs
none either.

Never identity: only "a person box", never a face, a name or who it is.
"""
from __future__ import annotations

import math
from typing import Dict, List, Optional, Sequence

# --- constants (asserted equal to cctv_thresholds.json["detect"]) ---
ZONE_HIT_POINTS = 2          # of 9 grid points of a person box inside the zone
GATE_CONFIRM = 2             # checked frames in a row with a person at the gate
PRESENCE_GAP_S = 10.0        # a person unseen longer than this has left (new visit)
DWELL_S_DEFAULT = 120        # loitering: 2 minutes in the zone
ABSENT_MIN_DEFAULT = 5       # counter / post empty after 5 minutes
OPEN_MIN_DEFAULT = 10        # gate open after 10 minutes
POST_CHECK_S = 30.0          # the box runs the person model at least this often
                             # while a post zone is armed (no motion needed)
PRESENCE_CHECK_S = 2.0       # ... and this often while someone is in a zone
PATCH_W, PATCH_H = 16, 12    # the zone picture compared for "gate open"
GATE_CLOSED_SIM = 0.6        # similarity >= this == looks like "closed"
TAMPER_EVERY_S = 30.0        # the box checks covered / moved this often

# --- tamper: the server rule (core/logic/cctv_rules.py), ported verbatim ---
BAD_PERSIST_S = 60
MOVED_MIN_GAP_S = 120

GATE_PERSON = "gate_person"
LOITERING = "loitering"
POST_EMPTY = "post_empty"
GATE_OPEN = "gate_open"
CAMERA_HEALTH = "camera_health"
ZONE_KINDS = ("restricted", "cash", "entry_line", "gate", "post")


# ------------------------------------------------------------------ geometry
def point_in_polygon(x: float, y: float, poly: Sequence[Sequence[float]]) -> bool:
    inside = False
    n = len(poly)
    if n < 3:
        return False
    j = n - 1
    for i in range(n):
        xi, yi = float(poly[i][0]), float(poly[i][1])
        xj, yj = float(poly[j][0]), float(poly[j][1])
        if (yi > y) != (yj > y):
            dy = (yj - yi) if (yj - yi) != 0 else 1e-12
            if x < (xj - xi) * (y - yi) / dy + xi:
                inside = not inside
        j = i
    return inside


def box_in_zone(box: Sequence[float], poly, need: int = ZONE_HIT_POINTS) -> bool:
    """>= `need` of the 3 x 3 grid points (1/6, 1/2, 5/6 of the box) inside."""
    if len(poly) < 3 or len(box) < 4:
        return False
    x1, y1, x2, y2 = (float(v) for v in box[:4])
    hits = 0
    for fy in (1.0 / 6, 0.5, 5.0 / 6):
        for fx in (1.0 / 6, 0.5, 5.0 / 6):
            if point_in_polygon(x1 + (x2 - x1) * fx, y1 + (y2 - y1) * fy, poly):
                hits += 1
                if hits >= need:
                    return True
    return False


def poly_bbox(poly) -> List[float]:
    xs = [float(p[0]) for p in poly]
    ys = [float(p[1]) for p in poly]
    return [min(xs), min(ys), max(xs), max(ys)]


def zone_patch(gray: Sequence[int], width: int, height: int, poly,
               pw: int = PATCH_W, ph: int = PATCH_H) -> List[float]:
    """The zone's bounding box of a row-major grey frame, block-averaged to
    pw x ph (each cell = the mean of the integer pixel range it covers).
    The Dart port computes the same numbers."""
    bx1, by1, bx2, by2 = poly_bbox(poly)
    x0 = int(math.floor(bx1 * width))
    y0 = int(math.floor(by1 * height))
    x1 = max(x0 + 1, min(width, int(math.ceil(bx2 * width))))
    y1 = max(y0 + 1, min(height, int(math.ceil(by2 * height))))
    bw, bh = x1 - x0, y1 - y0
    out: List[float] = []
    for j in range(ph):
        ya = y0 + (bh * j) // ph
        yb = max(ya + 1, y0 + (bh * (j + 1)) // ph)
        for i in range(pw):
            xa = x0 + (bw * i) // pw
            xb = max(xa + 1, x0 + (bw * (i + 1)) // pw)
            s = 0
            n = 0
            for yy in range(ya, min(yb, height)):
                row = yy * width
                for xx in range(xa, min(xb, width)):
                    s += int(gray[row + xx])
                    n += 1
            out.append(round(s / n, 3) if n else 0.0)
    return out


def _ncc(a: Sequence[float], b: Sequence[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    ma = sum(a) / len(a)
    mb = sum(b) / len(b)
    num = na = nb = 0.0
    for x, y in zip(a, b):
        dx, dy = x - ma, y - mb
        num += dx * dy
        na += dx * dx
        nb += dy * dy
    if na < 1e-6 or nb < 1e-6:
        # two flat pictures: alike only when their brightness is alike
        return 1.0 if (na < 1e-6 and nb < 1e-6 and abs(ma - mb) < 12) else 0.0
    return num / math.sqrt(na * nb)


def _grad(p: Sequence[float], pw: int = PATCH_W, ph: int = PATCH_H) -> List[float]:
    out = []
    for j in range(ph):
        for i in range(pw):
            v = p[j * pw + i]
            dx = abs(p[j * pw + min(i + 1, pw - 1)] - v)
            dy = abs(p[min(j + 1, ph - 1) * pw + i] - v)
            out.append(dx + dy)
    return out


def similarity(patch, ref, grad_only: bool = False) -> float:
    """How much the zone picture looks like the remembered one (-1..1).
    Brightness / contrast changes do not matter (normalised correlation);
    the EDGE picture (gradients) is also compared so a night IR picture can
    still match a day reference by its shapes."""
    g = _ncc(_grad(patch), _grad(ref))
    if grad_only:
        return round(g, 4)
    return round(max(_ncc(patch, ref), g), 4)


# ------------------------------------------------------------------ schedule
def _hhmm(v) -> Optional[int]:
    try:
        h, m = str(v).split(":")
        h, m = int(h), int(m)
    except (TypeError, ValueError):
        return None
    if not (0 <= h <= 23 and 0 <= m <= 59):
        return None
    return h * 60 + m


def schedule_armed(sched, weekday: int, minute: int) -> bool:
    """core/logic/watchman.is_armed on (weekday Mon=0, minute of the day).
    None = always. start == end = the listed days all day. Overnight windows
    belong to the day they START on."""
    if not isinstance(sched, dict):
        return True
    days = set()
    for d in sched.get("days") or []:
        try:
            days.add(int(d))
        except (TypeError, ValueError):
            pass
    s, e = _hhmm(sched.get("start")), _hhmm(sched.get("end"))
    if s is None or e is None:
        return True
    if s == e:
        return weekday in days
    if s < e:
        return weekday in days and s <= minute < e
    if minute >= s:
        return weekday in days
    if minute < e:
        return ((weekday - 1) % 7) in days
    return False


# ------------------------------------------------------------------ the rules
def _opt_num(opts, key, default, lo, hi):
    try:
        v = float((opts or {}).get(key, default))
    except (TypeError, ValueError):
        v = float(default)
    if v != v:
        v = float(default)
    return min(max(v, lo), hi)


class _ZoneState:
    __slots__ = ("hits", "since", "last_seen", "gate_fired", "dwell_fired",
                 "absent_since", "absent_fired", "open_since", "open_fired",
                 "ref_day", "ref_night", "ref_at")

    def __init__(self):
        self.hits = 0
        self.since: Optional[float] = None
        self.last_seen: Optional[float] = None
        self.gate_fired = False
        self.dwell_fired = False
        self.absent_since: Optional[float] = None
        self.absent_fired = False
        self.open_since: Optional[float] = None
        self.open_fired = False
        self.ref_day: Optional[List[float]] = None
        self.ref_night: Optional[List[float]] = None
        self.ref_at: Optional[float] = None


class ZoneRules:
    """Per-camera zone detections. Call step() once per analysed frame."""

    def __init__(self, zones=None, cam_schedule=None):
        self.zones: List[dict] = []
        self.cam_schedule = cam_schedule
        self.state: Dict[str, _ZoneState] = {}
        self.configure(zones or [], cam_schedule)

    # zones: [{"id", "type", "points", "label"?, "schedule"?, "opts"?}]
    def configure(self, zones, cam_schedule=None) -> None:
        self.cam_schedule = cam_schedule
        keep = {}
        self.zones = []
        for z in zones or []:
            if not isinstance(z, dict) or z.get("type") not in ZONE_KINDS:
                continue
            if z["type"] in ("entry_line", "cash"):
                continue                       # analyzer.py's rules
            zid = str(z.get("id") or "")
            if not zid or len(z.get("points") or []) < 3:
                continue
            self.zones.append(z)
            keep[zid] = self.state.get(zid) or _ZoneState()
        self.state = keep

    # --- what the caller needs to know (when to run the model / patches)
    def needs_person_check(self, t: float, weekday: int, minute: int,
                           last_check: Optional[float]) -> bool:
        """True when the person model should run on this frame even without
        motion: a post zone is armed (every POST_CHECK_S) or someone is in a
        zone right now (every PRESENCE_CHECK_S, so dwell keeps counting while
        a person stands still)."""
        since = None if last_check is None else t - last_check
        for z in self.zones:
            st = self.state[str(z["id"])]
            if z["type"] == "post" and self._armed(z, weekday, minute):
                if since is None or since >= POST_CHECK_S:
                    return True
            if st.last_seen is not None and t - st.last_seen <= PRESENCE_GAP_S:
                if since is None or since >= PRESENCE_CHECK_S:
                    return True
        return False

    def gate_zones(self) -> List[dict]:
        return [z for z in self.zones if z["type"] == "gate"
                and (z.get("opts") or {}).get("watch_open")]

    def wants_ref(self, zid: str) -> bool:
        """A gate's CLOSED picture is (re)taken when the owner tapped "the gate
        is closed now" (opts.closed_at) after the remembered one."""
        z = next((z for z in self.zones if str(z["id"]) == zid), None)
        if z is None:
            return False
        st = self.state[zid]
        try:
            closed_at = float((z.get("opts") or {}).get("closed_at") or 0)
        except (TypeError, ValueError):
            closed_at = 0.0
        if closed_at <= 0:
            return False
        return st.ref_at is None or st.ref_at < closed_at

    def set_ref(self, zid: str, patch, night: bool, t: float) -> None:
        st = self.state.get(zid)
        if st is None or not patch:
            return
        # the picture taken now is the truth; the other light is relearned
        if night:
            st.ref_night, st.ref_day = list(patch), None
        else:
            st.ref_day, st.ref_night = list(patch), None
        st.ref_at = t
        st.open_since, st.open_fired = None, False

    def refs(self) -> dict:
        """Remembered closed pictures (persisted by the caller)."""
        return {zid: {"day": s.ref_day, "night": s.ref_night, "at": s.ref_at}
                for zid, s in self.state.items() if s.ref_at is not None}

    def load_refs(self, d) -> None:
        for zid, r in (d or {}).items():
            st = self.state.get(zid)
            if st is None or not isinstance(r, dict):
                continue
            st.ref_day = r.get("day") or None
            st.ref_night = r.get("night") or None
            st.ref_at = r.get("at")

    def _armed(self, z, weekday, minute) -> bool:
        sched = z.get("schedule")
        if z["type"] == "post":
            # a post must have its own "someone must be here" hours
            return isinstance(sched, dict) and schedule_armed(sched, weekday, minute)
        return schedule_armed(sched if isinstance(sched, dict) else self.cam_schedule,
                              weekday, minute)

    def _open_armed(self, z, weekday, minute) -> bool:
        # "gate left open" follows the zone's own schedule only (default: always)
        sched = z.get("schedule")
        return schedule_armed(sched if isinstance(sched, dict) else None, weekday, minute)

    def step(self, t: float, weekday: int, minute: int, boxes=None,
             night: bool = False, patches: Optional[Dict[str, list]] = None) -> List[dict]:
        """One analysed frame. boxes: [[x1, y1, x2, y2, score], ...] from the
        person model THIS frame, or None when the model did not run / is not
        available (presence then simply is not updated). patches: zone id ->
        zone_patch() for gate zones watching "open". Returns detections:
        {"type", "zone", "label", ...} (at most one per zone and type)."""
        out: List[dict] = []
        for z in self.zones:
            zid = str(z["id"])
            st = self.state[zid]
            opts = z.get("opts") or {}
            label = str(z.get("label") or "")[:40]
            in_zone = []
            if boxes is not None:
                in_zone = [b for b in boxes if box_in_zone(b, z["points"])]
                present = bool(in_zone)
                if present:
                    st.hits += 1
                    if st.last_seen is None or t - st.last_seen > PRESENCE_GAP_S:
                        st.since = t
                        st.gate_fired = st.dwell_fired = False
                    st.last_seen = t
                else:
                    st.hits = 0
                    if st.last_seen is not None and t - st.last_seen > PRESENCE_GAP_S:
                        st.since = None
            present_now = bool(in_zone)
            armed = self._armed(z, weekday, minute)
            conf = max((float(b[4]) for b in in_zone if len(b) > 4), default=None)

            # 1. person at the shutter / gate
            if (z["type"] == "gate" and armed and present_now
                    and st.hits >= GATE_CONFIRM and not st.gate_fired):
                st.gate_fired = True
                d = {"type": GATE_PERSON, "zone": zid, "label": label}
                if conf is not None:
                    d["conf"] = round(conf, 3)
                out.append(d)

            # 2. loitering = one long visit in a zone with dwell_s
            dwell = _opt_num(opts, "dwell_s", 0, 0, 3600)
            if (dwell > 0 and armed and present_now and st.since is not None
                    and t - st.since >= dwell and not st.dwell_fired):
                st.dwell_fired = True
                d = {"type": LOITERING, "zone": zid, "label": label,
                     "seconds": int(t - st.since)}
                if conf is not None:
                    d["conf"] = round(conf, 3)
                out.append(d)

            # 3. counter / post left empty
            if z["type"] == "post":
                if not armed:
                    st.absent_since, st.absent_fired = None, False
                elif boxes is not None:
                    if present_now:
                        st.absent_since, st.absent_fired = None, False
                    else:
                        if st.absent_since is None:
                            st.absent_since = t
                        need = _opt_num(opts, "absent_min", ABSENT_MIN_DEFAULT, 1, 240) * 60
                        if t - st.absent_since >= need and not st.absent_fired:
                            st.absent_fired = True
                            out.append({"type": POST_EMPTY, "zone": zid, "label": label,
                                        "minutes": int((t - st.absent_since) // 60)})

            # 4. gate left open (picture vs the remembered closed picture)
            if z["type"] == "gate" and opts.get("watch_open") and patches \
                    and zid in patches and (st.ref_day is not None
                                            or st.ref_night is not None):
                patch = patches[zid]
                if present_now:
                    pass                    # someone in front: hold, decide later
                else:
                    same = st.ref_night if night else st.ref_day
                    if same is not None:
                        sim = similarity(patch, same)
                    else:
                        # first night (or day) since the owner's picture: match
                        # by shapes only, then remember this light's picture
                        other = st.ref_day if night else st.ref_night
                        sim = similarity(patch, other, grad_only=True)
                        if sim >= GATE_CLOSED_SIM:
                            if night:
                                st.ref_night = list(patch)
                            else:
                                st.ref_day = list(patch)
                    if sim >= GATE_CLOSED_SIM:
                        st.open_since, st.open_fired = None, False
                    elif self._open_armed(z, weekday, minute):
                        if st.open_since is None:
                            st.open_since = t
                        need = _opt_num(opts, "open_min", OPEN_MIN_DEFAULT, 1, 720) * 60
                        if t - st.open_since >= need and not st.open_fired:
                            st.open_fired = True
                            out.append({"type": GATE_OPEN, "zone": zid, "label": label,
                                        "minutes": int((t - st.open_since) // 60),
                                        "sim": round(sim, 3)})
                    else:
                        st.open_since = None
        return out


# ------------------------------------------------------------------ tamper
def _corr(a, b) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    da = [x - ma for x in a]
    db = [y - mb for y in b]
    na = math.sqrt(sum(x * x for x in da))
    nb = math.sqrt(sum(y * y for y in db))
    if na < 1e-6 or nb < 1e-6:
        return 0.0
    return sum(x * y for x, y in zip(da, db)) / (na * nb)


def still_kind(mean, std):
    if mean < 20 and std < 8:
        return "dark"
    if std < 4:
        return "covered"
    return None


def assess_still(state, grid, mean, std, ir, ts):
    """= core/logic/cctv_rules.assess_still (the backend test runs both on
    the same cases). -> (new_state, "dark" | "covered" | "moved" | None)."""
    st = dict(state) if isinstance(state, dict) else {}
    kind = still_kind(mean, std)
    if kind:
        prev = st.get("bad")
        st.pop("pending", None)
        if prev and prev.get("kind") == kind:
            first = float(prev.get("ts", ts))
            if ts - first >= BAD_PERSIST_S:
                st["bad"] = {"kind": kind, "ts": ts}
                return st, kind
            return st, None
        st["bad"] = {"kind": kind, "ts": ts}
        return st, None
    st.pop("bad", None)
    key = "ref_ir" if ir else "ref_day"
    ref = st.get(key)
    if not ref:
        st[key] = [round(v, 1) for v in grid]
        return st, None
    c = _corr(grid, ref)
    if c >= 0.6:
        st[key] = [round(0.8 * r + 0.2 * g, 1) for r, g in zip(ref, grid)]
        st.pop("pending", None)
        return st, None
    if c < 0.35:
        p = st.get("pending")
        if p and p.get("ir") == bool(ir) and \
                ts - float(p.get("ts") or 0) >= MOVED_MIN_GAP_S and \
                _corr(grid, p.get("grid") or []) >= 0.7:
            st[key] = [round(v, 1) for v in grid]
            st.pop("pending", None)
            return st, "moved"
        if not p or p.get("ir") != bool(ir):
            st["pending"] = {"grid": [round(v, 1) for v in grid], "ts": ts,
                             "ir": bool(ir)}
    return st, None


def still_stats(gray: Sequence[int], width: int, height: int):
    """(8 x 8 grid, mean, std) of a row-major grey frame (block means)."""
    grid = zone_patch(gray, width, height, [[0, 0], [1, 0], [1, 1], [0, 1]], 8, 8)
    n = max(1, width * height)
    s = 0.0
    s2 = 0.0
    for v in gray[:n]:
        s += v
        s2 += v * v
    mean = s / n
    var = max(0.0, s2 / n - mean * mean)
    return grid, mean, math.sqrt(var)


class TamperCheck:
    """Covered / moved / dark on the box itself, every TAMPER_EVERY_S."""

    def __init__(self):
        self.state: dict = {}
        self.last: Optional[float] = None

    def due(self, t: float) -> bool:
        return self.last is None or t - self.last >= TAMPER_EVERY_S

    def check(self, grid, mean, std, ir, t) -> Optional[str]:
        self.last = t
        self.state, kind = assess_still(self.state, grid, mean, std, ir, t)
        return kind if kind in ("covered", "moved") else None
