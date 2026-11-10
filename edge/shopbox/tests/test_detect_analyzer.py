"""cctvdet: the zone detections inside the Shop Box analyzer + engine
(person at the gate, post empty, gate left open, camera tamper)."""
import numpy as np

from conftest import blank_frame
from shopbox import payload
from shopbox.engine import DET_CLIP_TYPES, Engine
from test_zones_v2 import MON_NOON, SeqDetector, analyzer, cam_v2

ALL_DAY = {"days": list(range(7)), "start": "00:00", "end": "00:00"}
LOWER = [[0.3, 0.5], [0.7, 0.5], [0.7, 1.0], [0.3, 1.0]]
IN_BOX = (0.4, 0.6, 0.6, 0.95)


def _types(xs):
    return [(x.type, x.signals.get("zone")) for x in xs]


def test_person_at_gate_after_two_checks_with_signals():
    cam = cam_v2([{"id": "g1", "type": "gate", "points": LOWER, "label": "Shutter"},
                  {"id": "p1", "type": "post", "points": LOWER, "schedule": ALL_DAY}])
    an = analyzer(cam, SeqDetector([[IN_BOX]]))
    an.process(blank_frame(), now=MON_NOON)
    assert [x for x in an.take_extra() if x.type == "gate_person"] == []
    an.process(blank_frame(), now=MON_NOON + 3)      # presence re-check (2 s)
    got = [x for x in an.take_extra() if x.type == "gate_person"]
    assert _types(got) == [("gate_person", "g1")]
    s = got[0].signals
    assert s["person"] and s["zone_breach"] and s["source"] == "edge"
    assert s["zone_label"] == "Shutter" and s["detector"] == "yolox_nano"
    assert "face" not in str(s) and "name" not in s


def test_post_empty_after_its_minutes():
    cam = cam_v2([{"id": "p1", "type": "post", "points": LOWER, "schedule": ALL_DAY,
                   "opts": {"absent_min": 1}}])
    an = analyzer(cam, SeqDetector([[]]))
    seen = []
    for i in range(5):
        an.process(blank_frame(), now=MON_NOON + 30 * i)
        seen += an.take_extra()
    posts = [x for x in seen if x.type == "post_empty"]
    assert len(posts) == 1 and posts[0].signals["minutes"] == 1
    assert posts[0].signals["absent"] is True


def test_post_empty_needs_the_model():
    cam = cam_v2([{"id": "p1", "type": "post", "points": LOWER, "schedule": ALL_DAY,
                   "opts": {"absent_min": 1}}])
    an = analyzer(cam, SeqDetector([[]]))
    an.detector.available = False
    seen = []
    for i in range(8):
        an.process(blank_frame(), now=MON_NOON + 30 * i)
        seen += an.take_extra()
    assert [x for x in seen if x.type == "post_empty"] == []


def _stripes(vertical, lo=50, hi=200):
    f = blank_frame(value=lo)
    # coarse slats (64 px period): still stripes in the 16 x 12 zone picture
    if vertical:
        for x in range(0, 640, 64):
            f[180:, x:x + 32] = hi
    else:
        for y in range(180, 360, 64):
            f[y:y + 32, :] = hi
    return f


def test_gate_left_open_vs_the_remembered_closed_picture():
    gate = {"id": "g1", "type": "gate", "points": LOWER,
            "opts": {"watch_open": True, "open_min": 1, "closed_at": MON_NOON - 10}}
    cam = cam_v2([gate])
    an = analyzer(cam, SeqDetector([[]]))
    saved = []
    an.on_refs_changed = saved.append
    an.process(_stripes(False), now=MON_NOON)                  # owner: "closed now"
    assert saved and "g1" in saved[-1]
    seen = []
    for t in (5, 35, 70, 80):
        an.process(_stripes(True), now=MON_NOON + t)           # the shutter is up
        seen += an.take_extra()
    opens = [x for x in seen if x.type == "gate_open"]
    assert len(opens) == 1 and opens[0].signals["gate_open"] is True
    # closed again -> quiet, and the remembered picture is not retaken
    an.process(_stripes(False), now=MON_NOON + 90)
    assert [x for x in an.take_extra() if x.type == "gate_open"] == []
    assert len(saved) == 1


def test_tamper_covered_lens_is_reported_once_it_lasts_a_minute():
    cam = cam_v2([])
    an = analyzer(cam, SeqDetector([[]]))
    grey = np.full((360, 640, 3), 128, dtype=np.uint8)        # a hand / cloth
    seen = []
    for t in (0, 30, 60):
        an.process(grey, now=MON_NOON + t)
        seen += an.take_extra()
    health = [x for x in seen if x.type == "camera_health"]
    assert len(health) == 1 and health[0].signals["kind"] == "covered"


def test_detection_types_get_the_10_s_clip_and_are_server_types():
    for t in DET_CLIP_TYPES:
        assert t in payload.EVENT_TYPES and t in payload.EDGE_EMITTED_TYPES
    trig = type("T", (), {"type": "gate_person", "signals": {}})()
    assert Engine.wants_clip(trig)
