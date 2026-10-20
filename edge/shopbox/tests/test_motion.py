import numpy as np

from conftest import blank_frame, frame_with_square
from shopbox.motion import MotionDetector

ZONE = [(0.0, 0.0), (0.5, 0.0), (0.5, 1.0), (0.0, 1.0)]   # left half


def warm(det, n=3):
    for _ in range(n):
        det.update(blank_frame(), ZONE)


def test_static_scene_has_no_motion():
    det = MotionDetector()
    results = [det.update(blank_frame(), ZONE) for _ in range(6)]
    assert not any(r.motion for r in results)
    assert results[0].warming_up


def test_object_appearing_is_detected_with_location():
    det = MotionDetector()
    warm(det)
    r = det.update(frame_with_square(400, 150), ZONE)   # right half
    assert r.motion
    assert len(r.boxes) == 1
    x1, y1, x2, y2 = r.boxes[0]
    assert 0.55 < x1 < 0.65 and x2 < 0.8 and 0.3 < y1 < 0.5
    assert r.zone_frac == 0.0                            # outside the zone


def test_motion_inside_zone_reports_zone_fraction():
    det = MotionDetector()
    warm(det)
    r = det.update(frame_with_square(100, 120), ZONE)
    assert r.motion and r.zone_frac > 0.03


def test_tiny_blob_below_min_area_is_ignored():
    det = MotionDetector(min_area_frac=0.01)
    warm(det)
    r = det.update(frame_with_square(100, 100, size=6))
    assert not r.motion


def test_low_amplitude_noise_is_ignored():
    rng = np.random.default_rng(0)
    det = MotionDetector()
    warm(det)
    for _ in range(4):
        noisy = np.clip(blank_frame().astype(int) + rng.integers(-6, 7, (360, 640, 3)),
                        0, 255).astype(np.uint8)
        assert not det.update(noisy, ZONE).motion


def test_global_lighting_change_is_scene_change_not_motion():
    det = MotionDetector()
    warm(det)
    r = det.update(blank_frame(value=200), ZONE)          # lights switched on
    assert r.scene_change and not r.motion
    # and the new scene is adopted as background
    assert not det.update(blank_frame(value=200), ZONE).motion
