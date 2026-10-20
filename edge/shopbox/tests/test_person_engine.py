
import numpy as np
import pytest

from shopbox import model_fetch
from shopbox.analyzer import Trigger
from shopbox.config import AppConfig, CameraConfig
from shopbox.person import NullDetector, load_detector


def test_missing_model_degrades_to_motion_only(tmp_path):
    det = load_detector(str(tmp_path / "nope.onnx"))
    assert isinstance(det, NullDetector) and det.name == "motion_only"
    assert det.detect(np.zeros((10, 10, 3), np.uint8)) == []


def test_tampered_model_rejected_by_sha256(tmp_path):
    fake = tmp_path / "yolox_nano.onnx"
    fake.write_bytes(b"not the real model")
    assert not model_fetch.verify_sha256(str(fake))
    assert load_detector(str(fake)).name == "motion_only"


@pytest.mark.skipif(not model_fetch.find_model(), reason="model not downloaded")
def test_real_model_loads_and_runs_on_cpu():
    det = load_detector()
    assert det.name == "yolox_nano"
    # an empty grey frame has no people in it
    assert det.detect(np.full((360, 640, 3), 114, np.uint8)) == []


def test_engine_cooldown_dedupes_and_queues_one_snapshot(tmp_path):
    from shopbox.engine import Engine, EventLog
    from shopbox.secure_store import SecretStore, _FernetCipher

    cfg = AppConfig()
    cfg.cameras.append(CameraConfig(id="c1", name="Counter", rtsp_url="rtsp://x",
                                    zone=[[0, 0], [1, 0], [1, 1]]))
    store = SecretStore(str(tmp_path), cipher=_FernetCipher(str(tmp_path / "k")))
    eng = Engine(cfg, store, detector=NullDetector(),
                 events=EventLog(str(tmp_path / "ev.jsonl")))
    frame = np.full((720, 1280, 3), 90, np.uint8)
    trig = Trigger("after_hours", {"detector": "motion_only", "after_hours": True},
                   frame, 1_700_000_000.0)
    assert eng.handle_trigger("c1", trig) is True
    assert eng.handle_trigger("c1", trig) is False          # cooldown
    assert len(eng.outbox) == 1
    _, rec, snap = eng.outbox.peek()
    assert rec["has_snapshot"] and len(snap) <= 150 * 1024
    assert eng.events.recent(1)[0]["status"] == "queued"
