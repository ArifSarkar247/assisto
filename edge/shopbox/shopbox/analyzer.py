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

Zones v2 (the owner draws zones in the app; `cam.zones_v2`, all optional —
without it the rules above are exactly the old behaviour):

  outside the ARMED schedule      nothing but the after-hours rule above
  restricted zone                 person (or, without a model, motion) centroid
                                  inside -> "zone_intrusion" {zone_breach, zone}
  entry_line                      a tracked centroid crosses the line between
                                  two analysed frames (no confirm needed)
                                  -> "line_crossing" {zone_breach, line}
  anywhere                        a person (model only) -> "person_detected"
                                  {person, conf}
  cash zone                       the rules above (a v2 cash zone replaces the
                                  locally drawn one)

Priority when several hold in one frame: cash > zone_intrusion >
line_crossing > person_detected. Sensitivity (low x1.5 / medium x1 / high
x0.7) times tuning.motion_mult scales the motion area thresholds;
tuning.person_conf replaces the person score threshold. Quiet hours are the
server's business (it delivers silently) and do not stop sending.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np

from . import payload
from .config import CameraConfig, DetectionConfig
from .hours import Hours, Schedule
from .motion import MotionDetector, MotionResult
from .zone import (SENSITIVITY_MULT, box_centroid, box_zone_overlap,
                   normalize_polygon, point_in_polygon, segments_cross, zone_mask)

TRACK_MAX_JUMP = 0.25        # normalised distance a centroid may move per frame


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


def _dist(a, b) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


class CameraAnalyzer:
    def __init__(self, cam: CameraConfig, hours: Hours, cfg: DetectionConfig,
                 detector, clock: Callable[[], float] = time.time):
        self.cam = cam
        self.hours = hours
        self.cfg = cfg
        self.detector = detector
        self.clock = clock
        self.motion = MotionDetector(min_area_frac=cfg.motion_min_area_frac)
        self._after_hits = 0
        self._zone_hits = 0
        self._zone_since: Optional[float] = None
        self._zmask_cache = None
        self._restricted_hits: Dict[str, int] = {}
        self._person_hits = 0
        self._prev_pts: List[Tuple[float, float]] = []
        self._prev_age = 0
        self.last_people = 0             # for the UI "test" view
        self.reconfigure()

    def reconfigure(self, cam: Optional[CameraConfig] = None,
                    hours: Optional[Hours] = None) -> None:
        """(Re)read zones v2 / schedule / sensitivity / tuning from the camera
        config. Called on start and whenever the owner's settings change."""
        if cam is not None:
            self.cam = cam
        if hours is not None:
            self.hours = hours
        self.zone = normalize_polygon(self.cam.cash_zone())
        self._zmask_cache = None
        v2 = self.cam.zones_v2 or None
        self.v2 = v2
        self.schedule = Schedule.from_dict(v2.get("schedule")) if v2 else None
        zones = (v2 or {}).get("zones") or []
        self.restricted = [(z["id"], z["points"]) for z in zones
                           if z.get("type") == "restricted"]
        self.lines = [(z["id"], z["points"]) for z in zones
                      if z.get("type") == "entry_line"]
        tuning = self.cam.tuning or {}
        mult = SENSITIVITY_MULT.get((v2 or {}).get("sensitivity") or "medium", 1.0)
        mult *= float(tuning.get("motion_mult", 1.0))
        self.motion_mult = mult
        self.motion.min_area_frac = self.cfg.motion_min_area_frac * mult
        self.zone_motion_frac = self.cfg.zone_motion_frac * mult
        self.person_conf = tuning.get("person_conf")
        self.cooldown_s = tuning.get("cooldown_s")
        self._restricted_hits = {zid: self._restricted_hits.get(zid, 0)
                                 for zid, _ in self.restricted}

    @property
    def detector_name(self) -> str:
        return getattr(self.detector, "name", "motion_only")

    @property
    def has_model(self) -> bool:
        return bool(getattr(self.detector, "available", False))

    def _small_zone_mask(self, shape):
        # overlap is computed on a quarter-size mask: plenty for this purpose
        h, w = max(1, shape[0] // 4), max(1, shape[1] // 4)
        if self._zmask_cache is None or self._zmask_cache[0] != (h, w):
            self._zmask_cache = ((h, w), zone_mask(self.zone, w, h))
        return self._zmask_cache[1]

    def _detect(self, frame):
        thr = self.person_conf
        if thr is None:
            dets = self.detector.detect(frame)
        else:
            try:
                dets = self.detector.detect(frame, score_thr=thr)
            except TypeError:            # a detector without the override
                dets = self.detector.detect(frame)
            dets = [d for d in dets if d.score >= thr]
        self.last_people = len(dets)
        return dets

    def _person_in_zone(self, frame, dets=None) -> bool:
        dets = self._detect(frame) if dets is None else dets
        if not dets or not self.zone:
            return False
        zm = self._small_zone_mask(frame.shape)
        return any(box_zone_overlap((d.x1, d.y1, d.x2, d.y2), zm)
                   >= self.cfg.zone_overlap for d in dets)

    def is_armed(self, when: datetime) -> bool:
        if not self.v2 or self.schedule is None:
            return True                  # no v2 / no schedule = always armed
        return self.schedule.is_armed(when, self.hours.timezone)

    def _reset_open_state(self) -> None:
        self._zone_hits, self._zone_since = 0, None
        self._person_hits = 0
        self._restricted_hits = {k: 0 for k in self._restricted_hits}
        self._prev_pts, self._prev_age = [], 0

    def process(self, frame_bgr, now: Optional[float] = None) -> Optional[Trigger]:
        now = self.clock() if now is None else now
        frame = downscale(frame_bgr, self.cfg.frame_width)
        m = self.motion.update(frame, self.zone or None)
        confirm = max(1, int(self.cfg.confirm_frames))
        when = datetime.fromtimestamp(now, tz=timezone.utc)

        if self.hours.is_after_hours(when):
            self._reset_open_state()
            self._after_hits = self._after_hits + 1 if m.motion else 0
            if self._after_hits < confirm:
                return None
            person_in_zone = False
            if self.has_model and self.zone:
                person_in_zone = self._person_in_zone(frame)
            sig = payload.build_signals(
                payload.AFTER_HOURS, detector=self.detector_name,
                frames=self._after_hits, person_in_zone=person_in_zone)
            return Trigger(payload.AFTER_HOURS, sig, frame, now, m)

        self._after_hits = 0
        if not self.is_armed(when):
            self._reset_open_state()
            return None

        dets = None
        if self.v2 and self.has_model and m.motion:
            dets = self._detect(frame)       # once per frame, shared below
        cash = self._cash_rule(frame, m, now, confirm, dets)
        if not self.v2:
            return cash
        other = self._v2_rules(frame, m, now, confirm, dets)
        return cash or other

    def _cash_rule(self, frame, m, now, confirm, dets) -> Optional[Trigger]:
        if not self.zone:
            return None
        zone_motion = m.zone_frac >= self.zone_motion_frac
        hit = False
        if zone_motion:
            # the (more expensive) model only runs when the zone actually moved
            if self.has_model:
                hit = self._person_in_zone(frame, dets)
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
        if self.has_model:
            etype = payload.HAND_IN_CASH_ZONE
            sig = payload.build_signals(etype, detector=self.detector_name,
                                        motion_in_zone=True, lingering=lingering)
        else:
            etype = payload.MOTION
            sig = payload.build_signals(etype, detector="motion_only",
                                        motion_in_zone=True)
        return Trigger(etype, sig, frame, now, m)

    def _v2_rules(self, frame, m, now, confirm, dets) -> Optional[Trigger]:
        # centroids of what is moving: people when the model is available (so
        # shadows / lights do not count), else motion blobs (honest fallback)
        if self.has_model:
            pts = [box_centroid((d.x1, d.y1, d.x2, d.y2)) for d in (dets or [])]
        else:
            pts = [box_centroid(b) for b in (m.boxes if m.motion else [])]
        out: List[Trigger] = []

        for zid, poly in self.restricted:
            inside = any(point_in_polygon(x, y, poly) for x, y in pts)
            hits = self._restricted_hits.get(zid, 0) + 1 if inside else 0
            self._restricted_hits[zid] = hits
            if inside and hits >= confirm and not out:
                sig = payload.build_signals(payload.ZONE_INTRUSION,
                                            detector=self.detector_name,
                                            zone_id=zid)
                out.append(Trigger(payload.ZONE_INTRUSION, sig, frame, now, m))

        crossed = None
        if self.lines and self._prev_pts and pts:
            for cur in pts:
                prev = min(self._prev_pts, key=lambda p: _dist(p, cur))
                if _dist(prev, cur) > TRACK_MAX_JUMP:
                    continue
                for lid, (a, b) in self.lines:
                    if segments_cross(prev, cur, tuple(a), tuple(b)):
                        crossed = lid
                        break
                if crossed:
                    break
        if pts:
            self._prev_pts, self._prev_age = list(pts), 0
        else:
            self._prev_age += 1
            if self._prev_age > 2:       # lost track: start fresh
                self._prev_pts, self._prev_age = [], 0
        if crossed:
            sig = payload.build_signals(payload.LINE_CROSSING,
                                        detector=self.detector_name, line_id=crossed)
            out.append(Trigger(payload.LINE_CROSSING, sig, frame, now, m))

        if self.has_model and dets:
            self._person_hits += 1
            if self._person_hits >= confirm:
                sig = payload.build_signals(payload.PERSON_DETECTED,
                                            detector=self.detector_name,
                                            conf=max(d.score for d in dets))
                out.append(Trigger(payload.PERSON_DETECTED, sig, frame, now, m))
        else:
            self._person_hits = 0
        return out[0] if out else None
