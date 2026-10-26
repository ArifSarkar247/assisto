"""
watchman.py — PURE helpers for the Home & shop watchman (cctv1). NO Django,
NO DB, NO network: plain dicts in, plain dicts out, so every rule is pinned by
fast unit tests.

1. ZONES v2 (ShopCamera.zone_config, schema-versioned). Drawn on a snapshot in
   the app, normalised 0..1 so they survive main/sub-stream resolution changes:

     {"v": 2,
      "zones": [{"id": "z1", "type": "restricted"|"cash"|"entry_line",
                 "points": [[x, y], ...]}],      # entry_line: exactly 2 points
      "schedule": {"days": [0..6 (0 = Monday)], "start": "HH:MM",
                   "end": "HH:MM"} | None,       # None = always armed
      "sensitivity": "low"|"medium"|"high",
      "quiet_hours": {"start": "HH:MM", "end": "HH:MM"} | None,
      # legacy keys the Shop Box already understands are kept side by side:
      "cash_zone": [[x, y], ...], "hours": {...}, "restricted_zone": bool}

   normalize_zone_config() validates + clamps, and mirrors the FIRST cash zone
   into the legacy `cash_zone` key so an older Shop Box keeps working.

2. SCHEDULE: is_armed(schedule, local_dt) — overnight windows (22:00-06:00)
   belong to the day they START on. in_window() is shared by quiet hours.

3. ADAPTIVE THRESHOLDS from the owner's Correct / Wrong marks — a simple,
   BOUNDED adjustment, documented here because the owner asked how it works:
     * "Wrong" (false alarm): person_conf += 0.05, motion_mult *= 1.15,
       cooldown_s += 60  -> the camera gets a bit stricter + quieter.
     * "Correct": each knob moves HALF-way back toward its default (it never
       becomes MORE sensitive than the default — no runaway alerts).
     * Bounds: person_conf 0.35..0.85, motion_mult 0.5..3.0,
       cooldown_s 60..900. Defaults 0.45 / 1.0 / 180.
   The gateway reads `tuning` from shop/config and applies it.
"""
from datetime import time as dtime

SCHEMA_V = 2
ZONE_TYPES = ("restricted", "cash", "entry_line")
SENSITIVITY = ("low", "medium", "high")
MAX_ZONES = 8
MAX_POINTS = 16

TUNING_DEFAULT = {"person_conf": 0.45, "motion_mult": 1.0, "cooldown_s": 180}
TUNING_BOUNDS = {"person_conf": (0.35, 0.85), "motion_mult": (0.5, 3.0),
                 "cooldown_s": (60, 900)}
WRONG_STEP = {"person_conf": 0.05, "motion_mult": 1.15, "cooldown_s": 60}


class ZoneError(ValueError):
    """Carries a machine `code` the view turns into an honest 422."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def parse_hhmm(v):
    if not isinstance(v, str):
        return None
    try:
        h, m = v.strip().split(":")
        h, m = int(h), int(m)
    except (ValueError, AttributeError):
        return None
    if not (0 <= h <= 23 and 0 <= m <= 59):
        return None
    return dtime(h, m)


def _pt(p):
    try:
        x, y = float(p[0]), float(p[1])
    except (TypeError, ValueError, IndexError, KeyError):
        raise ZoneError("bad_point")
    if x != x or y != y:          # NaN
        raise ZoneError("bad_point")
    return [round(min(max(x, 0.0), 1.0), 4), round(min(max(y, 0.0), 1.0), 4)]


def _area(pts):
    a = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        a += x1 * y2 - x2 * y1
    return abs(a) / 2.0


def _window(v, code):
    if v in (None, "", {}):
        return None
    if not isinstance(v, dict):
        raise ZoneError(code)
    s, e = parse_hhmm(v.get("start")), parse_hhmm(v.get("end"))
    if s is None or e is None or s == e:
        raise ZoneError(code)
    return {"start": s.strftime("%H:%M"), "end": e.strftime("%H:%M")}


def normalize_zone_config(raw, legacy=None):
    """Validate a v2 zone config from the app. Raises ZoneError(code) on bad
    input; returns the clean dict (legacy keys from `legacy` kept)."""
    if not isinstance(raw, dict):
        raise ZoneError("bad_zone")
    zones_in = raw.get("zones") or []
    if not isinstance(zones_in, list) or len(zones_in) > MAX_ZONES:
        raise ZoneError("too_many_zones")
    zones, seen = [], set()
    for i, z in enumerate(zones_in):
        if not isinstance(z, dict):
            raise ZoneError("bad_zone")
        ztype = z.get("type")
        if ztype not in ZONE_TYPES:
            raise ZoneError("bad_zone_type")
        pts_in = z.get("points") or []
        if not isinstance(pts_in, list) or len(pts_in) > MAX_POINTS:
            raise ZoneError("too_many_points")
        pts = [_pt(p) for p in pts_in]
        if ztype == "entry_line":
            if len(pts) != 2 or pts[0] == pts[1]:
                raise ZoneError("line_needs_two_points")
        elif len(pts) < 3 or _area(pts) < 0.0005:
            raise ZoneError("zone_needs_three_points")
        zid = str(z.get("id") or "z%d" % (i + 1))[:16]
        if zid in seen:
            zid = "z%d" % (i + 1)
        seen.add(zid)
        label = str(z.get("label") or "")[:40]
        zones.append({"id": zid, "type": ztype, "points": pts,
                      **({"label": label} if label else {})})

    sched = raw.get("schedule")
    schedule = None
    if sched not in (None, "", {}):
        if not isinstance(sched, dict):
            raise ZoneError("bad_schedule")
        days = sched.get("days")
        if not isinstance(days, list) or not days:
            raise ZoneError("bad_schedule")
        try:
            days = sorted({int(d) for d in days})
        except (TypeError, ValueError):
            raise ZoneError("bad_schedule")
        if any(d < 0 or d > 6 for d in days):
            raise ZoneError("bad_schedule")
        win = _window(sched, "bad_schedule")
        if win is None:
            raise ZoneError("bad_schedule")
        schedule = {"days": days, **win}

    sens = raw.get("sensitivity") or "medium"
    if sens not in SENSITIVITY:
        raise ZoneError("bad_sensitivity")
    quiet = _window(raw.get("quiet_hours"), "bad_quiet_hours")

    out = {}
    if isinstance(legacy, dict):
        for k in ("hours", "restricted_zone"):
            if k in legacy:
                out[k] = legacy[k]
    out.update({"v": SCHEMA_V, "zones": zones, "schedule": schedule,
                "sensitivity": sens, "quiet_hours": quiet})
    cash = next((z["points"] for z in zones if z["type"] == "cash"), None)
    if cash:
        out["cash_zone"] = cash
    if any(z["type"] == "restricted" for z in zones):
        out["restricted_zone"] = True
    return out


def in_window(win, local_dt):
    """True when local_dt's time-of-day is inside {start, end} (overnight ok)."""
    if not win:
        return False
    s, e = parse_hhmm(win.get("start")), parse_hhmm(win.get("end"))
    if s is None or e is None:
        return False
    t = local_dt.time().replace(second=0, microsecond=0)
    if s < e:
        return s <= t < e
    return t >= s or t < e


def is_armed(schedule, local_dt):
    """No schedule = always armed. Overnight windows belong to the START day."""
    if not schedule:
        return True
    days = set(schedule.get("days") or [])
    s, e = parse_hhmm(schedule.get("start")), parse_hhmm(schedule.get("end"))
    if s is None or e is None:
        return True
    t = local_dt.time().replace(second=0, microsecond=0)
    wd = local_dt.weekday()
    if s < e:
        return wd in days and s <= t < e
    # overnight: the evening part belongs to today, the morning part to yesterday
    if t >= s:
        return wd in days
    if t < e:
        return ((wd - 1) % 7) in days
    return False


def zone_v2(zc):
    """The v2 part of a stored zone_config, or None for a legacy config."""
    if isinstance(zc, dict) and zc.get("v") == SCHEMA_V:
        return zc
    return None


# ---------------------------------------------------------------- tuning
def _clamp(k, v):
    lo, hi = TUNING_BOUNDS[k]
    return max(lo, min(hi, v))


def tuning_of(raw):
    """Current knobs (defaults filled, bounds applied) + the feedback counts."""
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, d in TUNING_DEFAULT.items():
        try:
            v = float(raw.get(k, d))
        except (TypeError, ValueError):
            v = d
        out[k] = _clamp(k, v)
    out["cooldown_s"] = int(round(out["cooldown_s"]))
    out["person_conf"] = round(out["person_conf"], 3)
    out["motion_mult"] = round(out["motion_mult"], 3)
    for k in ("correct", "wrong"):
        try:
            out[k] = max(0, int(raw.get(k, 0)))
        except (TypeError, ValueError):
            out[k] = 0
    return out


def adapt(raw, verdict):
    """Apply one owner verdict ('correct' | 'wrong') -> new bounded tuning."""
    t = tuning_of(raw)
    if verdict == "wrong":
        t["person_conf"] = _clamp("person_conf", t["person_conf"] + WRONG_STEP["person_conf"])
        t["motion_mult"] = _clamp("motion_mult", t["motion_mult"] * WRONG_STEP["motion_mult"])
        t["cooldown_s"] = _clamp("cooldown_s", t["cooldown_s"] + WRONG_STEP["cooldown_s"])
        t["wrong"] += 1
    elif verdict == "correct":
        for k, d in TUNING_DEFAULT.items():
            cur = t[k]
            # half-way back to the default, never past it (never more sensitive)
            t[k] = _clamp(k, cur - (cur - d) / 2.0)
        t["correct"] += 1
    else:
        return t
    return tuning_of(t)


def device_tuning(raw):
    """What the gateway gets (no feedback counters)."""
    t = tuning_of(raw)
    return {k: t[k] for k in TUNING_DEFAULT}


def default_zone_config(site_kind):
    """A new watchman camera's starting point (the owner edits it later):
    home = always on guard; shop = on guard after closing (21:00-09:00) daily.
    No zones yet — the app asks the owner to draw them on a snapshot."""
    schedule = None
    if site_kind == "shop":
        schedule = {"days": [0, 1, 2, 3, 4, 5, 6], "start": "21:00", "end": "09:00"}
    return {"v": SCHEMA_V, "zones": [], "schedule": schedule,
            "sensitivity": "medium", "quiet_hours": None}
