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
PIX_CASES = json.load(open(os.path.join(HERE, "fixtures", "pixel_check_cases.json")))["cases"]


def test_constants_match_the_shared_spec():
    m = SPEC["motion"]
    for k, v in m.items():
        assert getattr(mg, k.upper()) == v, k
    assert night.PERSON_SCORE_DAY == SPEC["person_score_day"]
    assert night.PERSON_SCORE_NIGHT == SPEC["person_score_night"]
    assert night.NIGHT_SIDE == SPEC["night_side"]
    assert night.NIGHT_SPREAD_MAX == SPEC["night_spread_max"]
    assert night.NIGHT_LUMA_MAX == SPEC["night_luma_max"]
    # cctvacc2: night enhancement + 2-frame check, phone pixel check
    assert night.NIGHT_PRE == SPEC["night_pre"]
    assert night.NIGHT_CLAHE_CLIP == SPEC["night_clahe_clip"]
    assert night.NIGHT_CLAHE_TILES == SPEC["night_clahe_tiles"]
    assert night.NIGHT_GAMMA_TARGET == SPEC["night_gamma_target"]
    assert night.NIGHT_CONFIRM == SPEC["night_confirm"]
    assert night.NIGHT_CONFIRM_GAP_S == SPEC["night_confirm_gap_s"]
    for k, v in SPEC["pixel"].items():
        assert getattr(mg, "PIX_" + k.upper()) == v, k
    assert DetectionConfig().night_confirm == SPEC["night_confirm"]
    # the box's own pixel path uses the same diff / learn / scene constants
    box = MotionDetector()
    assert box.diff_threshold == SPEC["pixel"]["box_diff"]
    assert box.learn_rate == SPEC["pixel"]["learn"]
    assert box.scene_change_frac == SPEC["pixel"]["scene_frac"]
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
    # cctvacc2: a night person needs 2 checks in a row
    an._now = 100.0
    assert an._detect(grey) == [] and det.thr[-1] == night.PERSON_SCORE_NIGHT and an.last_night
    an._now = 100.33
    assert len(an._detect(grey)) == 1 and an.last_night
    colour = np.zeros((360, 640, 3), np.uint8)
    colour[..., 0], colour[..., 1], colour[..., 2] = 40, 120, 200
    assert an._detect(colour) == [] and det.thr[-1] == 0.45 and not an.last_night


# ------------------------------------------------------------ cctvacc2
def _plane(frame):
    g = np.full(mg.PIX_W * mg.PIX_H, float(frame["base"]))
    for x, y, w, h, v in frame.get("rects", []):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                g[yy * mg.PIX_W + xx] = float(v)
    return g * float(frame.get("gain", 1.0))


def test_pixel_check_shared_fixture_cases():
    assert len(PIX_CASES) >= 8
    for case in PIX_CASES:
        pc = mg.PixelCheck()
        gm = _mask(case.get("gate_moved"))
        got = [pc.feed(_plane(f), gm) for f in case["frames"]]
        assert got == case["expect"], case["name"]


def test_hist_median_is_the_lower_median_of_floors():
    assert mg.hist_median([1.9, 5.0, 7.2, 200.0]) == 5
    assert mg.hist_median(np.full(10, 33.7)) == 33


def test_phone_motion_sees_a_walker_but_not_a_lamp():
    pm = mg.PhoneMotion()
    blank = blank_frame()[..., 0]
    for _ in range(3):
        assert not pm.feed(blank)
    lamp = blank.copy()
    lamp[0:120, 0:200] = 120
    assert sum(pm.feed(lamp) for _ in range(5)) == 0
    pm = mg.PhoneMotion()
    for _ in range(3):
        pm.feed(blank)
    walk = [pm.feed(frame_with_square(100 + i * 60, 140)[..., 0]) for i in range(6)]
    assert any(walk) and not walk[0]


def test_night_confirm_needs_two_checks_in_a_row():
    c = night.NightConfirm(frames=2, gap_s=2.0)
    assert c.check(True, night=False, now=0.0)          # day: at once
    assert not c.check(True, night=True, now=1.0) and c.pending
    assert c.check(True, night=True, now=1.4)
    assert not c.check(True, night=True, now=10.0)      # too far apart: start again
    assert not c.check(False, night=True, now=10.3) and not c.pending
    assert night.NightConfirm(frames=1).check(True, night=True, now=0.0)


def test_night_enhance_lifts_a_dark_ir_frame_and_keeps_day_frames():
    rng = np.random.default_rng(1)
    g = (rng.random((300, 400)) * 40 + 10).astype(np.uint8)
    g[100:200, 150:250] += 25                       # a dim figure
    frame = np.repeat(g[..., None], 3, axis=2)
    for pre in ("clahe", "gamma"):
        out = night.enhance(night.fit_side(frame), pre)
        assert out.shape == frame.shape and out.dtype == np.uint8
        assert out.mean() > frame.mean() + 10, pre
        assert (out[..., 0] == out[..., 2]).all()  # grey stays grey
    img, is_n = night.model_input(frame)
    assert is_n and img.shape == frame.shape
    colour = np.zeros((360, 640, 3), np.uint8)
    colour[..., 0], colour[..., 1], colour[..., 2] = 40, 120, 200
    same, is_n = night.model_input(colour)
    assert not is_n and same is colour
    big = np.full((720, 1280, 3), 30, np.uint8)
    assert night.model_input(big)[0].shape == (234, 416, 3)


def test_clahe_of_a_flat_image_is_flat_and_bounded():
    y = np.full((64, 64), 50, np.int64)
    out = night.clahe(y)
    assert out.min() == out.max() and 0 <= out.min() <= 255


def test_after_hours_night_person_waits_one_frame_for_the_second_check():
    from shopbox.analyzer import CameraAnalyzer
    from shopbox.config import CameraConfig
    from shopbox.hours import Hours
    from shopbox.person import Detection

    class Always:
        name, available = "yolox_nano", True

        def detect(self, frame, score_thr=None):
            return [Detection(0.1, 0.2, 0.4, 0.9, score=0.8)]

    zone = [[0.0, 0.0], [0.5, 0.0], [0.5, 1.0], [0.0, 1.0]]
    cam = CameraConfig(id="c1", name="Gate", rtsp_url="rtsp://x", zone=zone)
    an = CameraAnalyzer(cam, Hours(open="09:00", close="22:00"),
                        DetectionConfig(confirm_frames=2), Always())
    from datetime import datetime
    from zoneinfo import ZoneInfo
    t0 = datetime(2026, 10, 19, 23, 30, tzinfo=ZoneInfo("Asia/Dhaka")).timestamp()
    frames = [blank_frame()] * 3 + [frame_with_square(100 + i * 40, 120) for i in range(5)]
    out = [an.process(f, now=t0 + i * 0.33) for i, f in enumerate(frames)]
    trig = [t for t in out if t]
    assert trig and trig[0].signals.get("person_in_zone") is True
