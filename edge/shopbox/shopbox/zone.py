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
