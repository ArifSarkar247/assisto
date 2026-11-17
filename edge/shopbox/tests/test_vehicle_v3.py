"""cctvdet3: the vehicle model + the parking-zone second look in the Shop
Box analyzer, per-class vehicle thresholds and the pinned vehicle models."""
import numpy as np

from shopbox import analyzer as AN
from shopbox import model_fetch, person
from shopbox.person import Vehicle
from test_zones_v2 import MON_NOON, SeqDetector, analyzer, cam_v2

SPOT = [[0.4, 0.5], [0.6, 0.5], [0.6, 0.8], [0.4, 0.8]]


def day_frame():
    """A bright colour frame (a DAY frame: the model sees it unchanged)."""
    return np.full((360, 640, 3), (40, 140, 220), dtype=np.uint8)


class CropOnlyVehicles:
    """Sees the vehicle only on the zoomed crop (a far / small vehicle)."""
    name = "assisto_vehicle_bd"
    available = True

    def __init__(self):
        self.sizes = []

    def detect_vehicles(self, img, vehicle_thr=0.35):
        self.sizes.append(img.shape[1])
        if img.shape[1] >= 300:
            return []
        return [Vehicle(0.3, 0.3, 0.7, 0.7, 0.8, 2)]


def _run(zoom, monkeypatch):
    monkeypatch.setattr(AN, "VEH_ZOOM", zoom)
    cam = cam_v2([{"id": "np", "type": "no_parking", "points": SPOT, "label": "Gate front",
                   "opts": {"wrong_s": 30}}])
    an = analyzer(cam, SeqDetector([[]]))
    vd = CropOnlyVehicles()
    an.vehicle_detector = vd
    seen = []
    for i in range(5):
        an.process(day_frame(), now=MON_NOON + 10 * i)
        seen += an.take_extra()
    return [x for x in seen if x.type == "wrong_parking"], vd


def test_second_look_finds_the_far_vehicle(monkeypatch):
    got, vd = _run(True, monkeypatch)
    assert len(got) == 1
    s = got[0].signals
    assert s["zone"] == "np" and s.get("zone_label") == "Gate front"
    assert any(w < 300 for w in vd.sizes)            # the crop was looked at
    assert "face" not in str(s)


def test_without_the_second_look_nothing_is_guessed(monkeypatch):
    got, vd = _run(False, monkeypatch)
    assert got == []
    assert vd.sizes and all(w >= 300 for w in vd.sizes)


def test_per_class_vehicle_threshold(monkeypatch):
    monkeypatch.setattr(person, "VEHICLE_SCORES", {3: 0.5})
    assert person.class_thr(3, 0.3) == 0.5
    assert person.class_thr(2, 0.3) == 0.3


def test_vehicle_models_are_pinned(monkeypatch):
    assert model_fetch.vehicle_model_sha("x/yolox_tiny.onnx") == model_fetch.VEHICLE_MODEL_SHA256
    assert model_fetch.vehicle_model_sha("x/other.onnx") is None
    assert model_fetch.VEHICLE_MODEL_URL.startswith("https://github.com/Megvii-BaseDetection/")
    monkeypatch.setattr(model_fetch, "find_model", lambda name=None: None)
    assert model_fetch.ensure_vehicle_model(allow_download=False) is None
    assert person.load_vehicle_detector(allow_download=False) is None
