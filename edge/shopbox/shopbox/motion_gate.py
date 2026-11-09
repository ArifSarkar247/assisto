"""cctvacc: the motion GATE shared by the Shop Box and the phone app.

One small, CPU-light algorithm on a 32 x 24 grid of mean brightness, ported
line by line to Dart (app/lib/shop_motion.dart, class MotionGate). The
constants below are asserted equal to shopbox/cctv_thresholds.json by both
test suites, and both run the same fixture cases
(edge/shopbox/tests/fixtures/motion_gate_cases.json), so the phone and the box
decide the same way. Measured in CI by tools/e2e/cctv_accuracy.py.

Per sampled frame (about 3 per second):
  1. global lighting is compensated: the frame's median brightness over the
     background's median is the exposure ratio (auto exposure, flicker, a dim
     or brighter scene) — the background is scaled by it before comparing;
  2. a jump outside [RATIO_MIN, RATIO_MAX], or GLOBAL_FRAC of the cells
     changing at once (lights switched, IR night mode switching), is a SCENE
     CHANGE: the new scene is adopted for HOLD_FRAMES frames, no motion;
  3. a cell "moved" when it differs from the scaled background by more than
     max(CELL_THR, K_SIGMA x its own learned noise) — swaying trees, rain and
     IR noise raise their cells' noise and stop counting;
  4. a cell that differs from the background but is STILL frame to frame
     (a lamp switched on in one corner, a parked bag) is absorbed into the
     background after STABLE_FRAMES frames;
  5. only blobs (8-connected) of >= MIN_BLOB cells that contain >= MIN_FRESH
     cells which changed since the previous frame count ("fresh" = something
     is actually moving), optionally only inside a mask (zone);
  6. the caller confirms motion only after CONFIRM_FRAMES candidate frames in
     a row (the Shop Box analyzer's confirm_frames; the phone's streak).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np

GRID_W = 32
GRID_H = 24
CELL_THR = 14.0
K_SIGMA = 3.0
SIGMA0 = 4.0
VAR_LEARN = 0.1
VAR_CAP = 3600.0
BG_LEARN = 0.08
RATIO_MIN = 0.6
RATIO_MAX = 1.6667
GLOBAL_FRAC = 0.35
MIN_BLOB = 3
MIN_FRESH = 2
FRESH_DIFF = 7.0
STABLE_FRAMES = 2
HOLD_FRAMES = 2
CONFIRM_FRAMES = 3


@dataclass
class GateResult:
    candidate: bool = False        # a fresh moving blob this frame
    confirmed: bool = False        # candidate for CONFIRM_FRAMES frames in a row
    scene_change: bool = False     # global lighting change: scene adopted
    warming_up: bool = False
    frac: float = 0.0              # share of cells that moved (after absorb)
    ratio: float = 1.0             # exposure ratio used
    moved: Optional[np.ndarray] = None   # bool cells (after absorb + mask)


def any_blob(moved: np.ndarray, fresh: np.ndarray) -> bool:
    """True when an 8-connected blob of moved cells has >= MIN_BLOB cells and
    >= MIN_FRESH fresh cells (Dart: the same rule with a BFS)."""
    if not moved.any():
        return False
    import cv2

    n, lab = cv2.connectedComponents(moved.reshape(GRID_H, GRID_W).astype(np.uint8),
                                     connectivity=8)
    lab = lab.ravel()
    sizes = np.bincount(lab, minlength=n)
    fr = np.bincount(lab, weights=fresh.astype(np.float64), minlength=n)
    return bool(np.any((sizes[1:] >= MIN_BLOB) & (fr[1:] >= MIN_FRESH)))


class MotionGate:
    def __init__(self, mask: Optional[np.ndarray] = None,
                 confirm_frames: int = CONFIRM_FRAMES):
        self.mask = None if mask is None else np.asarray(mask, dtype=bool).ravel()
        self.confirm_frames = int(confirm_frames)
        self.reset()

    def reset(self) -> None:
        self._bg = None
        self._var = None
        self._prev = None
        self._stable = None
        self._hold = 0
        self.streak = 0

    def set_mask(self, mask: Optional[np.ndarray]) -> None:
        self.mask = None if mask is None else np.asarray(mask, dtype=bool).ravel()

    def _adopt(self, g) -> None:
        self._bg = g.copy()
        self._prev = g.copy()
        self._stable = np.zeros(g.shape[0], dtype=np.int64)
        self.streak = 0

    def feed(self, grid) -> GateResult:
        g = np.asarray(grid, dtype=np.float64).ravel()
        if self._bg is None or self._bg.shape != g.shape:
            self._adopt(g)
            self._var = np.full(g.shape[0], SIGMA0 * SIGMA0)
            self._hold = 0
            return GateResult(warming_up=True)
        if self._hold > 0:
            self._hold -= 1
            self._adopt(g)
            return GateResult(scene_change=True)
        mg = float(np.median(g))
        ratio = (mg + 1.0) / (float(np.median(self._bg)) + 1.0)
        if ratio < RATIO_MIN or ratio > RATIO_MAX:
            self._adopt(g)
            self._hold = HOLD_FRAMES
            return GateResult(scene_change=True, ratio=ratio)
        pred = self._bg * ratio
        d = g - pred
        thr = np.maximum(CELL_THR, K_SIGMA * np.sqrt(self._var))
        moved = np.abs(d) > thr
        frac = float(np.count_nonzero(moved)) / g.shape[0]
        if frac >= GLOBAL_FRAC:
            self._adopt(g)
            self._hold = HOLD_FRAMES
            return GateResult(scene_change=True, ratio=ratio, frac=frac)
        pr = (mg + 1.0) / (float(np.median(self._prev)) + 1.0)
        fresh = np.abs(g - self._prev * pr) > FRESH_DIFF
        self._stable = np.where(moved & ~fresh, self._stable + 1, 0)
        absorb = self._stable >= STABLE_FRAMES
        moved = moved & ~absorb
        if self.mask is not None and self.mask.shape == moved.shape:
            moved = moved & self.mask
        candidate = any_blob(moved, fresh)
        # learn
        self._var = (1.0 - VAR_LEARN) * self._var + VAR_LEARN * np.minimum(d * d, VAR_CAP)
        self._bg = (1.0 - BG_LEARN) * pred + BG_LEARN * g
        self._bg[absorb] = g[absorb]
        self._stable[absorb] = 0
        self._prev = g.copy()
        self.streak = self.streak + 1 if candidate else 0
        return GateResult(candidate=candidate,
                          confirmed=self.streak >= self.confirm_frames,
                          frac=float(np.count_nonzero(moved)) / g.shape[0],
                          ratio=ratio, moved=moved)


def grid_from_gray(gray) -> np.ndarray:
    """Shop Box: area-average a grey image down to the gate grid."""
    import cv2

    return cv2.resize(gray, (GRID_W, GRID_H),
                      interpolation=cv2.INTER_AREA).astype(np.float64).ravel()


_PHONE_IDX: dict = {}


def phone_grid(gray) -> np.ndarray:
    """The phone's own downsample (shop_motion.dart MotionDetector.downsample:
    4 x 4 sample points per cell of the Y plane) — used by the accuracy
    harness so the phone path is measured as the phone computes it."""
    h, w = gray.shape[:2]
    s = 4
    key = (h, w)
    if key not in _PHONE_IDX:
        cw, ch = w / GRID_W, h / GRID_H
        ys = [min(max(int(np.floor(gy * ch + (iy + 0.5) * ch / s)), 0), h - 1)
              for gy in range(GRID_H) for iy in range(s)]
        xs = [min(max(int(np.floor(gx * cw + (ix + 0.5) * cw / s)), 0), w - 1)
              for gx in range(GRID_W) for ix in range(s)]
        _PHONE_IDX[key] = (ys, xs)
    ys, xs = _PHONE_IDX[key]
    sub = np.asarray(gray, dtype=np.float64)[np.ix_(ys, xs)]
    return sub.reshape(GRID_H, s, GRID_W, s).mean(axis=(1, 3)).ravel()


def mask_from_polygon(poly) -> Optional[np.ndarray]:
    """A normalised polygon (owner-drawn motion area) -> bool grid, or None."""
    if not poly or len(poly) < 3:
        return None
    from .zone import zone_mask

    return zone_mask(poly, GRID_W, GRID_H).ravel() > 0
