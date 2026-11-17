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

from . import detect_rules as DR
from . import payload
from .config import CameraConfig, DetectionConfig
from .hours import Hours, Schedule, get_tz
from .motion import MotionDetector, MotionResult
from .night import NIGHT_SPREAD_MAX, NightConfirm, frame_stats, model_input
from .zone import (SENSITIVITY_MULT, box_centroid, box_zone_overlap,
                   normalize_polygon, point_in_polygon, segments_cross, zone_mask)

TRACK_MAX_JUMP = 0.25        # normalised distance a centroid may move per frame
GATE_PATCH_EVERY_S = 5.0     # cctvdet: "gate left open" is minutes, not frames
SMALL_W = 160                # cctvdet: the grey picture the zone / tamper checks use


def _measured():
    """cctvdet: the per-detection precision measured in CI (shared file)."""
    import json
    import os
    try:
        with open(os.path.join(os.path.dirname(__file__), "cctv_thresholds.json"),
                  encoding="utf-8") as f:
            m = json.load(f).get("measured") or {}
        return {k: v for k, v in m.items() if isinstance(v, dict)}
    except (OSError, ValueError):
        return {}


MEASURED = _measured()


def _vehicle_cfg():
    """cctvdet3: vehicle thresholds / second look from the shared file
    ("vehicle": {"default", "score": {coco id: thr}, "zoom", "zoom_max_area"})."""
    import json
    import os
    try:
        with open(os.path.join(os.path.dirname(__file__), "cctv_thresholds.json"),
                  encoding="utf-8") as f:
            v = json.load(f).get("vehicle") or {}
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


_VCFG = _vehicle_cfg()
VEH_SCORE = float(_VCFG.get("default", 0.35))
VEH_ZOOM = bool(_VCFG.get("zoom", False))           # second look on a parking zone crop
VEH_ZOOM_MAX_AREA = float(_VCFG.get("zoom_max_area", 0.35))
VEH_UNION = bool(_VCFG.get("union", False))         # + the person model's COCO vehicles
VEH_COCO_SCORE = float(_VCFG.get("coco_score", 0.35))
VEH_TINY_SCORE = float(_VCFG.get("tiny_default", 0.35))   # YOLOX-Tiny until the BD model is out


def veh_thr(det) -> float:
    """cctvdet3: the vehicle score for this model (each measured on its own)."""
    name = getattr(det, "name", "")
    if name == "assisto_vehicle_bd":
        return VEH_SCORE
    if name == "yolox_tiny":
        return VEH_TINY_SCORE
    return VEH_COCO_SCORE
# a "vehicle" box that is mostly a person box (a walker the vehicle model,
# which never learnt people, calls a cycle) is dropped; 1.0 = off
VEH_PERSON_IOU = float(_VCFG.get("person_iou", 1.0))


def _iou(a, b) -> float:
    ix = max(0.0, min(a.x2, b.x2) - max(a.x1, b.x1))
    iy = max(0.0, min(a.y2, b.y2) - max(a.y1, b.y1))
    i = ix * iy
    u = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - i
    return i / u if u > 0 else 0.0


def merge_vehicles(primary, extra):
    """cctvdet3: the vehicle model's boxes plus any other box it did not
    already cover (IoU <= 0.5) — a COCO car the local model missed."""
    out = list(primary or [])
    for v in extra or []:
        if all(_iou(v, p) <= 0.5 for p in out):
            out.append(v)
    return out
try:
    from . import person as _person
    _person.VEHICLE_SCORES.update({int(k): float(v)
                                   for k, v in (_VCFG.get("score") or {}).items()})
except Exception:                     # never let a bad file stop the box
    pass


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
        self.last_night = False          # cctvacc: last person check used night mode
        # cctvacc2: night frames are enhanced (night.model_input) and a night
        # person must be seen in NIGHT_CONFIRM checks in a row
        self._night_confirm = NightConfirm(frames=getattr(cfg, "night_confirm", None))
        self._now: Optional[float] = None
        self._after_defer = 0
        self.last_motion_at: Optional[float] = None   # cctvx (heartbeat)
        # cctvdet: zone detections (gate / post / dwell), camera tamper
        self.zrules = DR.ZoneRules()
        self.tamper = DR.TamperCheck()
        self.extra: List[Trigger] = []
        self._last_pcheck: Optional[float] = None
        self._last_patch: Optional[float] = None
        self._frame_dets = None
        self._frame_raw = None
        self._frame_veh = None
        self._frame_thr = None
        self.on_refs_changed: Optional[Callable[[dict], None]] = None
        self.plates = None               # cctvdet: plates.PlateReader (engine sets it)
        self.vehicle_detector = None     # cctvdet3: YOLOX-Tiny vehicles (engine sets it)
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
        # cctvacc: optional owner-drawn motion area (normalised polygon)
        self.motion.set_area(tuning.get("motion_area"))
        self.cooldown_s = tuning.get("cooldown_s")
        self._restricted_hits = {zid: self._restricted_hits.get(zid, 0)
                                 for zid, _ in self.restricted}
        # cctvdet: the zone detections keep their per-zone state across edits
        self.zrules.configure([z for z in zones
                               if z.get("type") in ("gate", "post", "parking", "no_parking")
                               or (z.get("opts") or {}).get("dwell_s")
                               or (z.get("opts") or {}).get("crowd_n")
                               or (z.get("type") == "entry_line"
                                   and (z.get("opts") or {}).get("vehicles"))],
                              (v2 or {}).get("schedule"))

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
        # cctvacc: IR / grey / dark frame -> the night threshold (same rule
        # and values as the phone app; measured in CI). cctvacc2: the night
        # frame is fit to 416 px and enhanced first, exactly as the phone.
        img, self.last_night = model_input(frame)
        thr = self.person_conf
        if thr is None:
            thr = (self.cfg.person_score_night if self.last_night
                   else self.cfg.person_score)
        # cctvdet stage 2: a post zone counts as manned on a weaker box
        # (POST_PRESENCE_SCORE) and parking / entry-line zones need vehicles
        # from the SAME model pass (COCO classes; no second model)
        low = self.zrules.weak_floor(thr)       # cctvdet3: post / dwell / crowd floors
        self._frame_thr = thr
        self._frame_veh = None
        try:
            vdet = self.vehicle_detector
            if self.zrules.wants_vehicles and vdet is not None:
                # cctvdet3: the vehicle model sees vehicles, nano sees people
                # (and, with VEH_UNION, nano's own COCO vehicles are added)
                coco = []
                if VEH_UNION and hasattr(self.detector, "detect_all"):
                    dets, coco = self.detector.detect_all(img, score_thr=low,
                                                          vehicle_thr=VEH_COCO_SCORE)
                else:
                    dets = self.detector.detect(img, score_thr=low)
                try:
                    self._frame_veh = merge_vehicles(
                        vdet.detect_vehicles(img, vehicle_thr=veh_thr(vdet)), coco)
                except Exception:
                    self._frame_veh = coco or None
            elif self.zrules.wants_vehicles and hasattr(self.detector, "detect_all"):
                dets, self._frame_veh = self.detector.detect_all(img, score_thr=low,
                                                                 vehicle_thr=VEH_COCO_SCORE)
            else:
                dets = self.detector.detect(img, score_thr=low)
        except TypeError:                # a detector without the override
            dets = self.detector.detect(img)
        # cctvdet: the zone rules confirm over their own checks (gate: 2 in a
        # row; post: minutes of absence) — they take the boxes BEFORE the
        # 2-s night confirm, which would otherwise hide a still guard at a
        # post checked every 30 s and raise a false "post empty"
        if self._frame_veh and VEH_PERSON_IOU < 1.0:
            ppl = [d for d in dets if d.score >= thr]
            self._frame_veh = [v for v in self._frame_veh
                               if all(_iou(v, p) < VEH_PERSON_IOU for p in ppl)]
        self._frame_raw = [d for d in dets if d.score >= low]
        dets = [d for d in dets if d.score >= thr]
        now = self._now if self._now is not None else self.clock()
        if not self._night_confirm.check(bool(dets), self.last_night, now):
            dets = []
        self.last_people = len(dets)
        self._frame_dets = dets          # cctvdet: one model run per frame
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

    def take_extra(self) -> List[Trigger]:
        """cctvdet: zone detections / tamper of the last frame(s) — the engine
        sends each (process() still returns the classic one)."""
        out, self.extra = self.extra, []
        return out

    def _det_trigger(self, d: dict, frame, now, m) -> Trigger:
        etype = d["type"]
        det = dict(d)
        # cctvdet stage 2: the plate of the vehicle, read on the box when the
        # optional open-source reader is installed (the server's AI reads the
        # photo otherwise) — plates are not faces
        if etype in payload.VEHICLE_TYPES and det.get("box") and self.plates is not None:
            try:
                p = self.plates.read(frame, det["box"])
                if p:
                    det["plate"] = p
            except Exception:
                pass
        mp = (MEASURED.get(etype) or {}).get("p")
        if mp is not None:
            det["mp"] = mp
        sig = payload.build_signals(etype, detector=self.detector_name, det=det)
        return Trigger(etype, sig, frame, now, m)

    def _zoom_boxes(self, frame, boxes):
        """cctvdet stage 2 (recall): a post / gate zone with NO person box
        gets a second look on its own crop (zoomed to the model's input),
        so a small or half-hidden person at a far counter is still seen.
        Boxes come back in full-frame coordinates."""
        out = []
        h, w = frame.shape[:2]
        for z in self.zrules.zones:
            if z["type"] not in ("post", "gate"):
                continue
            if any(DR.box_in_zone(b, z["points"]) for b in boxes):
                continue
            x1, y1, x2, y2 = DR.poly_bbox(z["points"])
            if (x2 - x1) * (y2 - y1) > 0.35:
                continue                   # a big zone gains nothing from a crop
            px, py = (x2 - x1) * 0.15, (y2 - y1) * 0.15
            x1, y1 = max(0.0, x1 - px), max(0.0, y1 - py)
            x2, y2 = min(1.0, x2 + px), min(1.0, y2 + py)
            crop = frame[int(y1 * h):max(int(y1 * h) + 2, int(y2 * h)),
                         int(x1 * w):max(int(x1 * w) + 2, int(x2 * w))]
            try:
                img, _night = model_input(crop)
                dets = self.detector.detect(img, score_thr=DR.POST_PRESENCE_SCORE)
            except Exception:
                continue
            for d in dets:
                out.append([x1 + d.x1 * (x2 - x1), y1 + d.y1 * (y2 - y1),
                            x1 + d.x2 * (x2 - x1), y1 + d.y2 * (y2 - y1), d.score])
        return out

    @property
    def wants_vehicle_model(self) -> bool:
        return self.zrules.wants_vehicles

    def _zoom_vehicles(self, frame, vehicles):
        """cctvdet3 (recall): a parking / no-parking zone with NO vehicle box
        gets a second look on its own crop, so a far or half-hidden vehicle
        is still seen. Boxes come back in full-frame coordinates."""
        if not VEH_ZOOM:
            return []
        det = self.vehicle_detector or self.detector
        if not hasattr(det, "detect_vehicles"):
            return []
        out = []
        h, w = frame.shape[:2]
        for z in self.zrules.zones:
            if z["type"] not in ("parking", "no_parking"):
                continue
            if any(DR.box_in_zone(v, z["points"]) for v in vehicles):
                continue
            x1, y1, x2, y2 = DR.poly_bbox(z["points"])
            if (x2 - x1) * (y2 - y1) > VEH_ZOOM_MAX_AREA:
                continue
            px, py = (x2 - x1) * 0.15, (y2 - y1) * 0.15
            x1, y1 = max(0.0, x1 - px), max(0.0, y1 - py)
            x2, y2 = min(1.0, x2 + px), min(1.0, y2 + py)
            crop = frame[int(y1 * h):max(int(y1 * h) + 2, int(y2 * h)),
                         int(x1 * w):max(int(x1 * w) + 2, int(x2 * w))]
            try:
                img, _night = model_input(crop)
                vs = det.detect_vehicles(img, vehicle_thr=veh_thr(det))
            except Exception:
                continue
            for v in vs:
                out.append([x1 + v.x1 * (x2 - x1), y1 + v.y1 * (y2 - y1),
                            x1 + v.x2 * (x2 - x1), y1 + v.y2 * (y2 - y1), v.score, v.cls])
        return out

    def _small_gray(self, frame):
        import cv2

        g = frame if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        h, w = g.shape[:2]
        if w > SMALL_W:
            g = cv2.resize(g, (SMALL_W, max(1, int(round(h * SMALL_W / w)))),
                           interpolation=cv2.INTER_AREA)
        return g

    def _zone_detections(self, frame, m, now, when) -> None:
        """cctvdet: gate / post / dwell zones + camera tamper (detect_rules)."""
        local = when.astimezone(get_tz(self.hours.timezone))
        wd, minute = local.weekday(), local.hour * 60 + local.minute
        small = None
        # camera tamper (covered / moved), every TAMPER_EVERY_S, model-free
        if self.tamper.due(now):
            small = self._small_gray(frame)
            spread, _luma = frame_stats(frame)
            grid, mean, std = DR.still_stats(small.ravel().tolist(), small.shape[1],
                                             small.shape[0])
            shape = DR.zone_patch(small.ravel().tolist(), small.shape[1], small.shape[0],
                                  [[0, 0], [1, 0], [1, 1], [0, 1]])
            kind = self.tamper.check(grid, mean, std, spread < NIGHT_SPREAD_MAX, now, shape)
            if kind:
                self.extra.append(self._det_trigger(
                    {"type": DR.CAMERA_HEALTH, "kind": kind}, frame, now, m))
        if not self.zrules.zones:
            return
        boxes = None
        vehicles = None
        if self.has_model and (m.motion or self.zrules.needs_person_check(
                now, wd, minute, self._last_pcheck)
                or self.zrules.needs_vehicle_check(now, self._last_pcheck)):
            if self._frame_dets is None:
                self._detect(frame)
            boxes = [[d.x1, d.y1, d.x2, d.y2, d.score] for d in (self._frame_raw or [])]
            boxes += self._zoom_boxes(frame, boxes)
            if self._frame_veh is not None:
                vehicles = [[v.x1, v.y1, v.x2, v.y2, v.score, v.cls] for v in self._frame_veh]
                vehicles += self._zoom_vehicles(frame, vehicles)
            self._last_pcheck = now
        patches = None
        gates = self.zrules.gate_zones()
        if gates and (self._last_patch is None or now - self._last_patch >= GATE_PATCH_EVERY_S):
            self._last_patch = now
            small = self._small_gray(frame) if small is None else small
            flat, h, w = small.ravel().tolist(), small.shape[0], small.shape[1]
            patches = {}
            night = self.last_night if boxes is not None else \
                frame_stats(frame)[0] < NIGHT_SPREAD_MAX
            changed = False
            for z in gates:
                zid = str(z["id"])
                patches[zid] = DR.zone_patch(flat, w, h, z["points"])
                busy = boxes is not None and any(DR.box_in_zone(b, z["points"]) for b in boxes)
                if self.zrules.wants_ref(zid) and not busy:
                    self.zrules.set_ref(zid, patches[zid], night, now)
                    changed = True
            if changed and self.on_refs_changed:
                try:
                    self.on_refs_changed(self.zrules.refs())
                except Exception:
                    pass
        else:
            night = self.last_night
        for d in self.zrules.step(now, wd, minute, boxes, night, patches,
                                  min_score=getattr(self, "_frame_thr", 0.0) or 0.0,
                                  vehicles=vehicles):
            self.extra.append(self._det_trigger(d, frame, now, m))

    def process(self, frame_bgr, now: Optional[float] = None) -> Optional[Trigger]:
        now = self.clock() if now is None else now
        self._now = now
        self._frame_dets = None
        self._frame_raw = None
        self._frame_veh = None
        frame = downscale(frame_bgr, self.cfg.frame_width)
        m = self.motion.update(frame, self.zone or None)
        if m.motion and not m.warming_up and not m.scene_change:
            # cctvx: "shop opened" — the server only needs WHEN movement was
            # last seen (reported on the heartbeat), never the frame
            self.last_motion_at = now
        confirm = max(1, int(self.cfg.confirm_frames))
        when = datetime.fromtimestamp(now, tz=timezone.utc)
        try:
            self._zone_detections(frame, m, now, when)
        except Exception:                 # never let a new rule stop the old ones
            pass

        if self.hours.is_after_hours(when):
            self._reset_open_state()
            self._after_hits = self._after_hits + 1 if m.motion else 0
            if self._after_hits < confirm:
                self._after_defer = 0
                return None
            person_in_zone = False
            if self.has_model and self.zone:
                person_in_zone = self._person_in_zone(frame, self._frame_dets)
                # cctvacc2: a night person seen once waits for the next frame
                # (2-frame check) instead of losing the person flag
                if (not person_in_zone and self._night_confirm.pending
                        and self._after_defer < self._night_confirm.frames - 1):
                    self._after_defer += 1
                    return None
            self._after_defer = 0
            sig = payload.build_signals(
                payload.AFTER_HOURS, detector=self.detector_name,
                frames=self._after_hits, person_in_zone=person_in_zone)
            return Trigger(payload.AFTER_HOURS, sig, frame, now, m)

        self._after_hits = 0
        if not self.is_armed(when):
            self._reset_open_state()
            return None

        dets = self._frame_dets          # cctvdet: already run this frame?
        if dets is None and self.v2 and self.has_model and m.motion:
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
