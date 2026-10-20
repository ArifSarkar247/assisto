"""Cheap motion detection: running-average background + frame difference.

Deliberately simple and CPU-light (works on a 320-px-wide grey image), with a
few guards that matter in real shops:
  * min-area filter: tiny blobs (noise, compression artefacts) are ignored;
  * scene-change guard: when most of the frame changes at once (lights switched
    on/off, the camera flipping into night/IR mode, an auto-exposure jump) we
    reset the background and report NO motion for that frame, instead of firing
    an after-hours alert for what is really a lighting change;
  * warm-up: the first frames only build the background.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

import numpy as np

Box = Tuple[float, float, float, float]   # normalised x1, y1, x2, y2


@dataclass
class MotionResult:
    motion: bool                     # any blob >= min area in the frame
    boxes: List[Box] = field(default_factory=list)
    changed_frac: float = 0.0        # fraction of frame pixels that changed
    zone_frac: float = 0.0           # fraction of the ZONE pixels that changed
    scene_change: bool = False       # global change: background was reset
    warming_up: bool = False


class MotionDetector:
    def __init__(self, work_width: int = 320, min_area_frac: float = 0.002,
                 diff_threshold: int = 25, learn_rate: float = 0.05,
                 scene_change_frac: float = 0.6, warmup_frames: int = 2):
        self.work_width = int(work_width)
        self.min_area_frac = float(min_area_frac)
        self.diff_threshold = int(diff_threshold)
        self.learn_rate = float(learn_rate)
        self.scene_change_frac = float(scene_change_frac)
        self.warmup_frames = int(warmup_frames)
        self._bg: Optional[np.ndarray] = None
        self._seen = 0
        self._zone_cache = None      # (poly tuple, shape) -> mask

    def reset(self) -> None:
        self._bg = None
        self._seen = 0

    def _prep(self, frame_bgr):
        import cv2

        h, w = frame_bgr.shape[:2]
        if w > self.work_width:
            nh = max(1, int(round(h * self.work_width / w)))
            frame_bgr = cv2.resize(frame_bgr, (self.work_width, nh),
                                   interpolation=cv2.INTER_AREA)
        gray = frame_bgr if frame_bgr.ndim == 2 else cv2.cvtColor(
            frame_bgr, cv2.COLOR_BGR2GRAY)
        return cv2.GaussianBlur(gray, (5, 5), 0)

    def _zone_mask(self, poly, shape):
        from .zone import zone_mask

        key = (tuple(poly), shape)
        if self._zone_cache is None or self._zone_cache[0] != key:
            self._zone_cache = (key, zone_mask(poly, shape[1], shape[0]))
        return self._zone_cache[1]

    def update(self, frame_bgr, zone_poly=None) -> MotionResult:
        """Feed one sampled frame; returns what moved since the background."""
        import cv2

        gray = self._prep(frame_bgr)
        if self._bg is None or self._bg.shape != gray.shape:
            self._bg = gray.astype(np.float32)
            self._seen = 1
            return MotionResult(False, warming_up=True)
        self._seen += 1

        diff = cv2.absdiff(gray, cv2.convertScaleAbs(self._bg))
        _, mask = cv2.threshold(diff, self.diff_threshold, 255, cv2.THRESH_BINARY)
        mask = cv2.dilate(mask, None, iterations=2)
        h, w = mask.shape
        changed = float(np.count_nonzero(mask)) / float(h * w)

        if changed >= self.scene_change_frac:
            # Lighting / IR switch: adopt the new scene, report nothing.
            self._bg = gray.astype(np.float32)
            return MotionResult(False, changed_frac=changed, scene_change=True)

        cv2.accumulateWeighted(gray, self._bg, self.learn_rate)
        if self._seen <= self.warmup_frames:
            return MotionResult(False, changed_frac=changed, warming_up=True)

        min_area = self.min_area_frac * h * w
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL,
                                       cv2.CHAIN_APPROX_SIMPLE)
        boxes: List[Box] = []
        for c in contours:
            if cv2.contourArea(c) < min_area:
                continue
            x, y, bw, bh = cv2.boundingRect(c)
            boxes.append((x / w, y / h, (x + bw) / w, (y + bh) / h))

        zone_frac = 0.0
        if zone_poly and boxes:
            zm = self._zone_mask(zone_poly, mask.shape)
            zpx = int(np.count_nonzero(zm))
            if zpx:
                zone_frac = float(np.count_nonzero(cv2.bitwise_and(mask, zm))) / zpx
        return MotionResult(bool(boxes), boxes=boxes, changed_frac=changed,
                            zone_frac=zone_frac)
