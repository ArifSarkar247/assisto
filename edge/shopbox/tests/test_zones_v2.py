"""Zones v2 / armed schedule / sensitivity / tuning, and backward compat."""
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np

from conftest import blank_frame, frame_with_square
from shopbox import payload
from shopbox.analyzer import CameraAnalyzer
from shopbox.config import AppConfig, CameraConfig, DetectionConfig
from shopbox.cooldown import Cooldown
from shopbox.device import apply_server_camera
from shopbox.hours import Hours, Schedule
from shopbox.person import Detection, NullDetector
from shopbox.zone import (normalize_tuning, normalize_zones_v2, segments_cross)

DHAKA = ZoneInfo("Asia/Dhaka")
MON_NOON = datetime(2026, 10, 19, 12, 0, tzinfo=DHAKA).timestamp()   # Monday


def at(day, hh, mm=0):
    return datetime(2026, 10, 19 + day, hh, mm, tzinfo=DHAKA)


# ------------------------------------------------------------- schedule
def test_schedule_day_window_and_overnight():
    s = Schedule.from_dict({"days": [0, 1, 2, 3, 4], "start": "09:00", "end": "18:00"})
    assert s.is_armed(at(0, 10), "Asia/Dhaka")            # Mon 10:00
    assert not s.is_armed(at(0, 19), "Asia/Dhaka")
    assert not s.is_armed(at(5, 10), "Asia/Dhaka")        # Sat
    night = Schedule.from_dict({"days": [4], "start": "22:00", "end": "06:00"})
    assert night.is_armed(at(4, 23), "Asia/Dhaka")        # Fri 23:00
    assert night.is_armed(at(5, 5, 59), "Asia/Dhaka")     # Sat 05:59 (Fri's night)
    assert not night.is_armed(at(5, 6), "Asia/Dhaka")
    assert not night.is_armed(at(4, 5), "Asia/Dhaka")     # Fri 05:00 = Thu's night
    allday = Schedule.from_dict({"days": [6], "start": "00:00", "end": "00:00"})
    assert allday.is_armed(at(6, 3), "Asia/Dhaka")
    assert Schedule.from_dict(None) is None
    assert Schedule.from_dict({"days": [1], "start": "25:00", "end": "x"}) is None


# ------------------------------------------------------------- geometry
def test_segments_cross():
    line = ((0.5, 0.0), (0.5, 1.0))
    assert segments_cross((0.4, 0.5), (0.6, 0.5), *line)
    assert segments_cross((0.6, 0.5), (0.4, 0.5), *line)
    assert not segments_cross((0.1, 0.5), (0.4, 0.5), *line)
    assert not segments_cross((0.4, 0.5), (0.5, 0.5), *line)   # touching only
    assert not segments_cross((0.5, 0.1), (0.5, 0.9), *line)   # along it


def test_normalize_zones_and_tuning():
    z = normalize_zones_v2({"v": 2, "zones": [
        {"id": "z1", "type": "restricted", "points": [[0, 0], [0.5, 0], [0.5, 0.5]]},
        {"id": "l1", "type": "entry_line", "points": [[0.5, 0], [0.5, 1]]},
        {"id": "bad", "type": "entry_line", "points": [[0.5, 0], [0.5, 1], [1, 1]]},
        {"id": "x", "type": "teleport", "points": []}],
        "sensitivity": "extreme", "schedule": None})
    assert [x["id"] for x in z["zones"]] == ["z1", "l1"]
    assert z["sensitivity"] == "medium" and z["schedule"] is None
    assert normalize_zones_v2({"v": 1}) is None and normalize_zones_v2("x") is None
    t = normalize_tuning({"person_conf": 0.1, "motion_mult": 9, "cooldown_s": "120"})
    assert t == {"person_conf": 0.35, "motion_mult": 3.0, "cooldown_s": 120.0}
    assert normalize_tuning({}) is None


# ------------------------------------------------------------- analyzer
class SeqDetector:
    """Returns the next box list on each call (the last one repeats)."""
    name = "yolox_nano"
    available = True

    def __init__(self, seq, score=0.9):
        self.seq, self.score, self.calls, self.thr = list(seq), score, 0, []

    def detect(self, frame, score_thr=None):
        self.thr.append(score_thr)
        boxes = self.seq[min(self.calls, len(self.seq) - 1)]
        self.calls += 1
        return [Detection(*b, score=self.score) for b in boxes]


def cam_v2(zones, schedule=None, sensitivity="medium", tuning=None, cash=None):
    c = CameraConfig(id="c1", name="Door", rtsp_url="rtsp://x", zone=cash or [])
    c.zones_v2 = normalize_zones_v2({"v": 2, "zones": zones, "schedule": schedule,
                                     "sensitivity": sensitivity})
    c.tuning = normalize_tuning(tuning) if tuning else None
    return c


def analyzer(cam, det):
    return CameraAnalyzer(cam, Hours(open="09:00", close="22:00"),
                          DetectionConfig(confirm_frames=2), det)


def moving_frames(n, step=40, x0=40):
    return [frame_with_square(x0 + i * step, 140) for i in range(n)]


def run(an, frames, t0=MON_NOON):
    return [an.process(f, now=t0 + i * 0.33) for i, f in enumerate(frames)]


RESTRICTED = {"id": "back", "type": "restricted",
              "points": [[0.5, 0.0], [1.0, 0.0], [1.0, 1.0], [0.5, 1.0]]}
LINE = {"id": "door", "type": "entry_line", "points": [[0.5, 0.0], [0.5, 1.0]]}


def test_zone_intrusion_person_centroid_inside():
    det = SeqDetector([[(0.6, 0.3, 0.8, 0.7)]])
    an = analyzer(cam_v2([RESTRICTED]), det)
    out = [t for t in run(an, moving_frames(6)) if t]
    assert out and out[0].type == payload.ZONE_INTRUSION
    assert out[0].signals["zone_breach"] is True and out[0].signals["zone"] == "back"


def test_line_crossing_between_frames():
    seq = [[(0.30, 0.3, 0.40, 0.7)], [(0.38, 0.3, 0.48, 0.7)],
           [(0.47, 0.3, 0.57, 0.7)], [(0.56, 0.3, 0.66, 0.7)]]
    det = SeqDetector(seq)
    an = analyzer(cam_v2([LINE]), det)
    types = [t.type for t in run(an, moving_frames(7)) if t]
    assert payload.LINE_CROSSING in types
    trig = [t for t in run(analyzer(cam_v2([LINE]), SeqDetector(seq)),
                           moving_frames(7)) if t and t.type == payload.LINE_CROSSING][0]
    assert trig.signals == {"detector": "yolox_nano", "zone_breach": True,
                            "line": "door"}


def test_person_detected_anywhere_while_armed_with_conf():
    det = SeqDetector([[(0.1, 0.1, 0.2, 0.4)]], score=0.77)
    an = analyzer(cam_v2([]), det)
    out = [t for t in run(an, moving_frames(6)) if t]
    assert out[0].type == payload.PERSON_DETECTED
    assert out[0].signals["person"] is True and out[0].signals["conf"] == 0.77


def test_not_armed_sends_nothing_but_after_hours_still_works():
    sched = {"days": [5, 6], "start": "09:00", "end": "18:00"}    # weekend only
    det = SeqDetector([[(0.6, 0.3, 0.8, 0.7)]])
    cash = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]
    an = analyzer(cam_v2([RESTRICTED], schedule=sched, cash=cash), det)
    assert all(t is None for t in run(an, moving_frames(6)))       # Monday noon
    closed = datetime(2026, 10, 19, 23, 30, tzinfo=DHAKA).timestamp()
    out = [t for t in run(an, moving_frames(6), t0=closed) if t]
    assert out and out[0].type == payload.AFTER_HOURS


def test_cash_zone_keeps_priority_and_v2_cash_zone_is_used():
    det = SeqDetector([[(0.0, 0.0, 1.0, 1.0)]])
    cash = {"id": "till", "type": "cash",
            "points": [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]}
    an = analyzer(cam_v2([cash, RESTRICTED]), det)
    out = [t for t in run(an, moving_frames(6)) if t]
    assert out[0].type == payload.HAND_IN_CASH_ZONE


def test_tuning_person_conf_and_sensitivity_and_motion_mult():
    det = SeqDetector([[(0.1, 0.1, 0.2, 0.4)]], score=0.5)
    an = analyzer(cam_v2([], sensitivity="low", tuning={"person_conf": 0.6,
                                                       "motion_mult": 2.0}), det)
    assert an.person_conf == 0.6
    base = DetectionConfig()
    assert abs(an.motion.min_area_frac - base.motion_min_area_frac * 3.0) < 1e-9
    assert abs(an.zone_motion_frac - base.zone_motion_frac * 3.0) < 1e-9
    assert all(t is None for t in run(an, moving_frames(6)))   # 0.5 < 0.6
    assert 0.6 in det.thr
    high = analyzer(cam_v2([], sensitivity="high"), SeqDetector([[]]))
    assert abs(high.motion.min_area_frac - base.motion_min_area_frac * 0.7) < 1e-9


def test_tuning_cooldown_replaces_default(tmp_path):
    from shopbox.analyzer import Trigger
    from shopbox.engine import Engine, EventLog
    from shopbox.secure_store import SecretStore, _FernetCipher

    clock = {"t": 0.0}
    cfg = AppConfig()
    cam = cam_v2([], tuning={"cooldown_s": 60})
    cfg.cameras.append(cam)
    store = SecretStore(str(tmp_path), cipher=_FernetCipher(str(tmp_path / "k")))
    eng = Engine(cfg, store, detector=NullDetector(),
                 events=EventLog(str(tmp_path / "ev.jsonl")))
    eng.cooldown = Cooldown(180, clock=lambda: clock["t"])
    trig = Trigger(payload.PERSON_DETECTED, {"detector": "yolox_nano", "person": True},
                   blank_frame(), 1.0)
    assert eng.handle_trigger("c1", trig)
    clock["t"] = 61.0
    assert eng.handle_trigger("c1", trig)          # 60 s, not the default 180 s
    _, rec, snap = eng.outbox.peek()
    assert rec["event"]["type"] == "person_detected"


# ------------------------------------------------------------- compat
def test_old_config_and_old_server_unchanged():
    old = CameraConfig.from_dict({"id": "c1", "name": "Till", "rtsp_url": "rtsp://x",
                                  "zone": [[0, 0], [1, 0], [1, 1]]})
    assert old.zones_v2 is None and old.tuning is None and old.server_id is None
    an = CameraAnalyzer(old, Hours(), DetectionConfig(), NullDetector())
    assert an.v2 is None and an.is_armed(datetime.now(DHAKA))
    assert an.zone_motion_frac == DetectionConfig().zone_motion_frac
    # an old server's camera row (no zones/tuning/source) leaves them alone
    old.zones_v2 = {"v": 2, "zones": [], "schedule": None, "sensitivity": "high",
                    "quiet_hours": None}
    assert not apply_server_camera(old, {"enabled": True, "hours": None,
                                         "zone_config": {}, "restricted_zone": True})
    assert old.zones_v2["sensitivity"] == "high"


def test_apply_server_camera_v2_keys_and_source_has_no_secret():
    cam = CameraConfig(id="srv5", name="Gate", rtsp_url="rtsp://h/x", server_id=5)
    changed = apply_server_camera(cam, {
        "enabled": True,
        "source": {"vendor": "imou", "host": "192.168.1.20", "port": 554,
                   "channel": 1, "stream": "sub", "secret": "NOPE",
                   "rtsp_path": "rtsp://admin:NOPE@h/cam"},
        "zones": {"v": 2, "zones": [LINE], "schedule": {"days": [0], "start": "22:00",
                                                        "end": "06:00"},
                  "sensitivity": "high", "quiet_hours": {"start": "23:00", "end": "07:00"}},
        "tuning": {"person_conf": 0.5, "cooldown_s": 300}})
    assert changed
    assert "secret" not in cam.source and "NOPE" not in str(cam.source)
    assert cam.zones_v2["zones"][0]["id"] == "door"
    assert cam.tuning == {"person_conf": 0.5, "cooldown_s": 300.0}
    d = CameraConfig.from_dict(AppConfig(cameras=[cam]).to_dict()["cameras"][0])
    assert d.zones_v2 == cam.zones_v2 and d.server_id == 5


def test_payload_new_types_are_multipart_with_snapshot():
    for et in (payload.PERSON_DETECTED, payload.ZONE_INTRUSION, payload.LINE_CROSSING):
        assert et in payload.EVENT_TYPES and et in payload.EDGE_EMITTED_TYPES
        assert payload.transport_for(et, True, "auto") == "multipart"
    ev = payload.build_event(payload.ZONE_INTRUSION, payload.build_signals(
        payload.ZONE_INTRUSION, detector="motion_only", zone_id="z1"), camera_id="c1")
    assert ev["signals"] == {"detector": "motion_only", "zone_breach": True, "zone": "z1"}
    assert np is not None
