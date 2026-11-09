"""cctvacc: the shared motion gate + night threshold — same constants and same
answers as the phone app (app/test/cctv_gate_parity_test.dart runs the same
fixture file)."""
import json
import os

import numpy as np

from conftest import blank_frame, frame_with_square
from shopbox import motion_gate as mg
from shopbox import night
from shopbox.config import DetectionConfig
from shopbox.motion import MotionDetector
from shopbox.zone import normalize_tuning

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(os.path.join(HERE, "..", "shopbox", "cctv_thresholds.json")))
CASES = json.load(open(os.path.join(HERE, "fixtures", "motion_gate_cases.json")))["cases"]


def test_constants_match_the_shared_spec():
    m = SPEC["motion"]
    for k, v in m.items():
        assert getattr(mg, k.upper()) == v, k
    assert night.PERSON_SCORE_DAY == SPEC["person_score_day"]
    assert night.PERSON_SCORE_NIGHT == SPEC["person_score_night"]
    assert night.NIGHT_SIDE == SPEC["night_side"]
    assert night.NIGHT_SPREAD_MAX == SPEC["night_spread_max"]
    assert night.NIGHT_LUMA_MAX == SPEC["night_luma_max"]
    d = DetectionConfig()
    assert d.person_score == SPEC["person_score_day"]
    assert d.person_score_night == SPEC["person_score_night"]
    assert d.confirm_frames == m["confirm_frames"]


def _grid(frame):
    g = np.full(mg.GRID_W * mg.GRID_H, float(frame["base"]))
    for x, y, w, h, v in frame.get("rects", []):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                g[yy * mg.GRID_W + xx] = float(v)
    return g * float(frame.get("gain", 1.0))


def _mask(rect):
    if not rect:
        return None
    x, y, w, h = rect
    m = np.zeros(mg.GRID_W * mg.GRID_H, dtype=bool)
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            m[yy * mg.GRID_W + xx] = True
    return m


def test_shared_fixture_cases():
    assert len(CASES) >= 8
    for case in CASES:
        gate = mg.MotionGate(mask=_mask(case.get("mask")))
        res = [gate.feed(_grid(f)) for f in case["frames"]]
        assert [r.candidate for r in res] == case["candidate"], case["name"]
        assert [r.confirmed for r in res] == case["confirmed"], case["name"]
        if "scene" in case:
            assert [r.scene_change for r in res] == case["scene"], case["name"]


def test_phone_grid_matches_a_plain_block_average_on_flat_regions():
    g = np.zeros((240, 320), np.uint8)
    g[:, 160:] = 200
    grid = mg.phone_grid(g).reshape(mg.GRID_H, mg.GRID_W)
    assert grid[0, 0] == 0 and grid[0, -1] == 200


def test_box_detector_ignores_a_lamp_but_sees_a_walker():
    det = MotionDetector()
    for _ in range(3):
        det.update(blank_frame())
    lamp = blank_frame()
    lamp[0:120, 0:200] = 120                      # a lamp lights one corner
    hits = [det.update(lamp).motion for _ in range(5)]
    assert sum(hits) < 3                          # never 3 frames in a row
    det = MotionDetector()
    for _ in range(3):
        det.update(blank_frame())
    walk = [det.update(frame_with_square(100 + i * 60, 140)).motion for i in range(5)]
    assert all(walk)


def test_motion_area_from_tuning_masks_the_gate():
    t = normalize_tuning({"motion_area": [[0.6, 0.0], [1.0, 0.0], [1.0, 1.0], [0.6, 1.0]]})
    assert len(t["motion_area"]) == 4
    det = MotionDetector()
    det.set_area(t["motion_area"])
    for _ in range(3):
        det.update(blank_frame())
    # the walker stays in the left half: outside the drawn area
    assert not any(det.update(frame_with_square(40 + i * 40, 140)).motion for i in range(5))


def test_night_rule_grey_or_dark_frames():
    colour = np.zeros((360, 640, 3), np.uint8)
    colour[..., 0], colour[..., 1], colour[..., 2] = 40, 120, 200   # BGR, bright, colourful
    assert not night.is_night(colour)
    assert night.person_threshold(colour) == 0.45
    grey = np.full((360, 640, 3), 120, np.uint8)                    # IR: no colour
    assert night.is_night(grey) and night.person_threshold(grey) == 0.30
    dark = (colour * 0.15).astype(np.uint8)                          # low light colour
    assert night.is_night(dark)


def test_analyzer_uses_the_night_threshold_on_ir_frames():
    from shopbox.analyzer import CameraAnalyzer
    from shopbox.config import CameraConfig
    from shopbox.hours import Hours
    from shopbox.person import Detection

    class Rec:
        name, available = "yolox_nano", True

        def __init__(self):
            self.thr = []

        def detect(self, frame, score_thr=None):
            self.thr.append(score_thr)
            return [Detection(0.1, 0.1, 0.3, 0.6, score=0.35)]

    det = Rec()
    cam = CameraConfig(id="c1", name="Gate", rtsp_url="rtsp://x", zone=[])
    an = CameraAnalyzer(cam, Hours(open="09:00", close="22:00"), DetectionConfig(), det)
    grey = np.full((360, 640, 3), 90, np.uint8)
    assert len(an._detect(grey)) == 1 and det.thr[-1] == 0.30 and an.last_night
    colour = np.zeros((360, 640, 3), np.uint8)
    colour[..., 0], colour[..., 1], colour[..., 2] = 40, 120, 200
    assert an._detect(colour) == [] and det.thr[-1] == 0.45 and not an.last_night
