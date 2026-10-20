from datetime import datetime
from zoneinfo import ZoneInfo

from conftest import blank_frame, frame_with_square
from shopbox.analyzer import CameraAnalyzer
from shopbox.config import CameraConfig, DetectionConfig
from shopbox.hours import Hours
from shopbox.person import Detection, NullDetector

ZONE = [[0.0, 0.0], [0.5, 0.0], [0.5, 1.0], [0.0, 1.0]]
OPEN_TS = datetime(2026, 10, 19, 12, 0, tzinfo=ZoneInfo("Asia/Dhaka")).timestamp()
CLOSED_TS = datetime(2026, 10, 19, 23, 30, tzinfo=ZoneInfo("Asia/Dhaka")).timestamp()


class FakePersonDetector:
    name = "yolox_nano"
    available = True

    def __init__(self, boxes):
        self.boxes = boxes
        self.calls = 0

    def detect(self, frame):
        self.calls += 1
        return [Detection(*b, score=0.9) for b in self.boxes]


def make(detector, zone=ZONE):
    cam = CameraConfig(id="c1", name="Counter", rtsp_url="rtsp://x", zone=zone)
    return CameraAnalyzer(cam, Hours(open="09:00", close="22:00"),
                          DetectionConfig(confirm_frames=2), detector)


def run(an, frames, t0):
    out = []
    for i, f in enumerate(frames):
        out.append(an.process(f, now=t0 + i * 0.33))
    return out


def moving_frames(x0, n=3, step=12):
    return [blank_frame()] * 3 + [frame_with_square(x0 + i * step, 120) for i in range(n)]


def test_after_hours_motion_needs_confirmation_then_fires():
    an = make(NullDetector())
    res = run(an, moving_frames(400), CLOSED_TS)
    assert res[3] is None                     # first moving frame: not yet
    trig = res[4]
    assert trig.type == "after_hours"
    assert trig.signals == {"detector": "motion_only", "after_hours": True,
                            "multiple_frames": True}


def test_quiet_scene_after_hours_sends_nothing():
    an = make(NullDetector())
    assert all(r is None for r in run(an, [blank_frame()] * 8, CLOSED_TS))


def test_open_hours_motion_only_fallback_reports_honestly():
    an = make(NullDetector())
    trig = [r for r in run(an, moving_frames(100), OPEN_TS) if r][0]
    assert trig.type == "motion"
    assert trig.signals == {"detector": "motion_only", "zone_breach": True,
                            "motion_in_zone": True}


def test_open_hours_motion_outside_zone_sends_nothing():
    an = make(NullDetector())
    assert all(r is None for r in run(an, moving_frames(420), OPEN_TS))


def test_person_in_zone_with_model_is_hand_in_cash_zone():
    det = FakePersonDetector([(0.1, 0.2, 0.4, 0.9)])
    an = make(det)
    trig = [r for r in run(an, moving_frames(100), OPEN_TS) if r][0]
    assert trig.type == "hand_in_cash_zone"
    assert trig.signals == {"detector": "yolox_nano", "motion_in_zone": True}


def test_motion_in_zone_but_person_elsewhere_is_not_an_event():
    det = FakePersonDetector([(0.7, 0.2, 0.95, 0.9)])
    an = make(det)
    assert all(r is None for r in run(an, moving_frames(100), OPEN_TS))
    assert det.calls > 0


def test_model_not_run_when_nothing_moves():
    det = FakePersonDetector([(0.1, 0.2, 0.4, 0.9)])
    an = make(det)
    run(an, [blank_frame()] * 6, OPEN_TS)
    assert det.calls == 0


def test_no_zone_during_open_hours_sends_nothing():
    an = make(NullDetector(), zone=[])
    assert all(r is None for r in run(an, moving_frames(100), OPEN_TS))
