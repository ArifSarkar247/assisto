"""Cash-drawer zone geometry.

A zone is a polygon in NORMALISED image coordinates: a list of [x, y] pairs
with 0 <= x, y <= 1 (top-left origin), so it survives the camera's resolution
changing (main stream vs sub-stream). At least 3 points.
"""
from __future__ import annotations

from typing import Iterable, List, Optional, Sequence, Tuple

import numpy as np

Point = Tuple[float, float]


def normalize_polygon(points: Optional[Iterable[Sequence[float]]]) -> List[Point]:
    """Validate/clamp a polygon. Returns [] when it is not a usable polygon."""
    if not points:
        return []
    out: List[Point] = []
    for p in points:
        try:
            x, y = float(p[0]), float(p[1])
        except (TypeError, ValueError, IndexError):
            return []
        if not (np.isfinite(x) and np.isfinite(y)):
            return []
        out.append((min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)))
    if len(out) < 3 or polygon_area(out) <= 1e-6:
        return []
    return out


def polygon_area(poly: Sequence[Point]) -> float:
    """Shoelace area (normalised units, so 1.0 == the whole frame)."""
    a = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        a += x1 * y2 - x2 * y1
    return abs(a) / 2.0


def point_in_polygon(x: float, y: float, poly: Sequence[Point]) -> bool:
    """Ray-casting point-in-polygon test (even-odd rule). Points exactly on an
    edge may fall either side; that is irrelevant at pixel granularity."""
    inside = False
    n = len(poly)
    if n < 3:
        return False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def zone_mask(poly: Sequence[Point], width: int, height: int) -> np.ndarray:
    """Rasterise the polygon to a uint8 mask (255 inside) of the given size."""
    import cv2

    mask = np.zeros((height, width), dtype=np.uint8)
    if len(poly) >= 3:
        pts = np.array([[int(round(x * (width - 1))), int(round(y * (height - 1)))]
                        for x, y in poly], dtype=np.int32)
        cv2.fillPoly(mask, [pts], 255)
    return mask


def box_zone_overlap(box: Tuple[float, float, float, float], mask: np.ndarray) -> float:
    """Fraction of the ZONE covered by a normalised (x1, y1, x2, y2) box, or of
    the box covered by the zone, whichever is larger. Using the larger of the
    two means a small person-box fully inside a big zone, and a big person-box
    covering a small drawer zone, both count."""
    h, w = mask.shape[:2]
    x1 = int(np.clip(box[0], 0, 1) * w)
    y1 = int(np.clip(box[1], 0, 1) * h)
    x2 = int(np.ceil(np.clip(box[2], 0, 1) * w))
    y2 = int(np.ceil(np.clip(box[3], 0, 1) * h))
    if x2 <= x1 or y2 <= y1:
        return 0.0
    zone_px = int(np.count_nonzero(mask))
    if zone_px == 0:
        return 0.0
    inter = int(np.count_nonzero(mask[y1:y2, x1:x2]))
    box_px = (x2 - x1) * (y2 - y1)
    return max(inter / zone_px, inter / box_px)


# ------------------------------------------------------------- zones v2
def normalize_line(points) -> List[Point]:
    """An entry line: exactly 2 distinct normalised points, else []."""
    try:
        if not points or len(points) != 2:
            return []
    except TypeError:
        return []
    out: List[Point] = []
    for p in points:
        try:
            x, y = float(p[0]), float(p[1])
        except (TypeError, ValueError, IndexError):
            return []
        if not (np.isfinite(x) and np.isfinite(y)):
            return []
        out.append((min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)))
    if abs(out[0][0] - out[1][0]) + abs(out[0][1] - out[1][1]) < 1e-3:
        return []
    return out


def _orient(a: Point, b: Point, c: Point) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def segments_cross(p1: Point, p2: Point, q1: Point, q2: Point) -> bool:
    """True when segment p1->p2 (a centroid's movement between two analysed
    frames) properly crosses segment q1-q2 (the entry line). Merely touching
    the line, or moving along it, does not count."""
    d1, d2 = _orient(q1, q2, p1), _orient(q1, q2, p2)
    d3, d4 = _orient(p1, p2, q1), _orient(p1, p2, q2)
    return ((d1 > 0 > d2) or (d1 < 0 < d2)) and ((d3 > 0 > d4) or (d3 < 0 < d4))


def box_centroid(box) -> Point:
    return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)


ZONE_TYPES = ("restricted", "cash", "entry_line")
SENSITIVITY_MULT = {"low": 1.5, "medium": 1.0, "high": 0.7}


def normalize_zones_v2(d) -> Optional[dict]:
    """Server `zones` (v2) -> a clean dict, or None when absent/invalid.
    {"v": 2, "zones": [{id, type, points}], "schedule": dict|None,
     "sensitivity": low|medium|high, "quiet_hours": dict|None}"""
    if not isinstance(d, dict):
        return None
    try:
        if int(d.get("v") or 0) != 2:
            return None
    except (TypeError, ValueError):
        return None
    zones = []
    raw = d.get("zones") if isinstance(d.get("zones"), list) else []
    for z in raw[:16]:
        if not isinstance(z, dict) or z.get("type") not in ZONE_TYPES:
            continue
        zid = str(z.get("id") or "z%d" % (len(zones) + 1))[:32]
        pts = normalize_line(z.get("points")) if z["type"] == "entry_line" \
            else normalize_polygon(z.get("points"))
        if pts:
            zones.append({"id": zid, "type": z["type"],
                          "points": [list(p) for p in pts]})
    sens = d.get("sensitivity") if d.get("sensitivity") in SENSITIVITY_MULT \
        else "medium"
    sched = d.get("schedule") if isinstance(d.get("schedule"), dict) else None
    quiet = d.get("quiet_hours") if isinstance(d.get("quiet_hours"), dict) else None
    return {"v": 2, "zones": zones, "schedule": sched, "sensitivity": sens,
            "quiet_hours": quiet}


def normalize_tuning(d) -> Optional[dict]:
    """Server `tuning` -> clamped dict (only the keys present), or None."""
    if not isinstance(d, dict):
        return None
    out = {}
    for key, lo, hi in (("person_conf", 0.35, 0.85), ("motion_mult", 0.5, 3.0),
                        ("cooldown_s", 60.0, 900.0)):
        try:
            v = float(d[key])
        except (KeyError, TypeError, ValueError):
            continue
        if np.isfinite(v):
            out[key] = min(max(v, lo), hi)
    return out or None
