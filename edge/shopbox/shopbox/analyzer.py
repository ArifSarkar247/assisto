"""Per-camera decision logic: sampled frame in -> (maybe) one edge event out.

Pure apart from the detectors it is given, so it is unit-testable with
synthetic frames and a fake clock. Cooldown/dedupe is applied by the engine,
not here: while a condition holds, `process()` keeps reporting it.

Rules (all need `confirm_frames` CONSECUTIVE sampled frames, so a single noisy
frame never produces anything):

  shop CLOSED (after hours)       motion anywhere in frame
                                  -> type "after_hours"
  shop OPEN, zone set, model OK   person box overlaps the cash zone AND there
                                  is motion inside the zone
                                  -> type "hand_in_cash_zone"
  shop OPEN, zone set, no model   motion inside the zone (honest fallback)
                                  -> type "motion" + zone_breach,
                                     detector "motion_only"
  shop OPEN, no zone / zone quiet nothing is sent (the server would only log a
                                  lone motion anyway — "lone_motion")
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, Optional

import numpy as np

from . import payload
from .config import CameraConfig, DetectionConfig
from .hours import Hours
from .motion import MotionDetector, MotionResult
from .zone import box_zone_overlap, normalize_polygon, zone_mask


@dataclass
class Trigger:
    type: str
    signals: Dict[str, object]
    frame: np.ndarray                   # analysis-size frame for the snapshot
    at: float
    motion: Optional[MotionResult] = field(default=None, repr=False)


def downscale(frame, width: int):
    import cv2

    h, w = frame.shape[:2]
    if w <= width:
        return frame
    return cv2.resize(frame, (width, max(1, int(round(h * width / w)))),
                      interpolation=cv2.INTER_AREA)


class CameraAnalyzer:
    def __init__(self, cam: CameraConfig, hours: Hours, cfg: DetectionConfig,
                 detector, clock: Callable[[], float] = time.time):
        self.cam = cam
        self.hours = hours
        self.cfg = cfg
        self.detector = detector
        self.clock = clock
        self.zone = normalize_polygon(cam.zone)
        self.motion = MotionDetector(min_area_frac=cfg.motion_min_area_frac)
        self._after_hits = 0
        self._zone_hits = 0
        self._zone_since: Optional[float] = None
        self._zmask_cache = None
        self.last_people = 0             # for the UI "test" view

    @property
    def detector_name(self) -> str:
        return getattr(self.detector, "name", "motion_only")

    def _small_zone_mask(self, shape):
        # overlap is computed on a quarter-size mask: plenty for this purpose
        h, w = max(1, shape[0] // 4), max(1, shape[1] // 4)
        if self._zmask_cache is None or self._zmask_cache[0] != (h, w):
            self._zmask_cache = ((h, w), zone_mask(self.zone, w, h))
        return self._zmask_cache[1]

    def _person_in_zone(self, frame) -> bool:
        dets = self.detector.detect(frame)
        self.last_people = len(dets)
        if not dets or not self.zone:
            return False
        zm = self._small_zone_mask(frame.shape)
        return any(box_zone_overlap((d.x1, d.y1, d.x2, d.y2), zm)
                   >= self.cfg.zone_overlap for d in dets)

    def process(self, frame_bgr, now: Optional[float] = None) -> Optional[Trigger]:
        now = self.clock() if now is None else now
        frame = downscale(frame_bgr, self.cfg.frame_width)
        m = self.motion.update(frame, self.zone or None)
        confirm = max(1, int(self.cfg.confirm_frames))
        when = datetime.fromtimestamp(now, tz=timezone.utc)

        if self.hours.is_after_hours(when):
            self._zone_hits, self._zone_since = 0, None
            self._after_hits = self._after_hits + 1 if m.motion else 0
            if self._after_hits < confirm:
                return None
            person_in_zone = False
            if getattr(self.detector, "available", False) and self.zone:
                person_in_zone = self._person_in_zone(frame)
            sig = payload.build_signals(
                payload.AFTER_HOURS, detector=self.detector_name,
                frames=self._after_hits, person_in_zone=person_in_zone)
            return Trigger(payload.AFTER_HOURS, sig, frame, now, m)

        self._after_hits = 0
        if not self.zone:
            return None
        zone_motion = m.zone_frac >= self.cfg.zone_motion_frac
        hit = False
        if zone_motion:
            # the (more expensive) model only runs when the zone actually moved
            if getattr(self.detector, "available", False):
                hit = self._person_in_zone(frame)
            else:
                hit = True
        if not hit:
            self._zone_hits, self._zone_since = 0, None
            return None
        self._zone_hits += 1
        if self._zone_since is None:
            self._zone_since = now
        if self._zone_hits < confirm:
            return None
        lingering = (now - self._zone_since) >= self.cfg.linger_s
        if getattr(self.detector, "available", False):
            etype = payload.HAND_IN_CASH_ZONE
            sig = payload.build_signals(etype, detector=self.detector_name,
                                        motion_in_zone=True, lingering=lingering)
        else:
            etype = payload.MOTION
            sig = payload.build_signals(etype, detector="motion_only",
                                        motion_in_zone=True)
        return Trigger(etype, sig, frame, now, m)
