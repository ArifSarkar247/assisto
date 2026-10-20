"""The payload builder must match the server contract EXACTLY. Where the
backend source is available (it is, in this monorepo and in CI) we load the
REAL pure decision engine (backend/core/logic/shop_guard.py — no Django) and
the real ShopEvent.TYPES, and check every event the edge emits behaves as
intended server-side."""
import importlib.util
import json
import os
import re

import numpy as np
import pytest

from conftest import REPO_ROOT
from shopbox import payload

GUARD_PATH = os.path.join(REPO_ROOT, "backend", "core", "logic", "shop_guard.py")
MODELS_PATH = os.path.join(REPO_ROOT, "backend", "core", "models.py")
needs_backend = pytest.mark.skipif(not os.path.exists(GUARD_PATH),
                                   reason="backend source not present")


@pytest.fixture(scope="module")
def guard():
    spec = importlib.util.spec_from_file_location("shop_guard_under_test", GUARD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@needs_backend
def test_event_types_mirror_server_model():
    src = open(MODELS_PATH, encoding="utf-8").read()
    block = src[src.index("class ShopEvent("):]
    block = block[block.index("TYPES = ["):block.index("]", block.index("TYPES = ["))]
    server_types = set(re.findall(r'\("([a-z_]+)",', block))
    assert server_types == set(payload.EVENT_TYPES)
    assert payload.EDGE_EMITTED_TYPES <= server_types


def _event(etype, **kw):
    sig = payload.build_signals(etype, **kw)
    return payload.build_event(etype, sig, camera_id="c1", at=1_700_000_000.0)


@needs_backend
def test_hand_in_zone_raises_without_pos_and_clears_with_sale(guard):
    ev = _event(payload.HAND_IN_CASH_ZONE, detector="yolox_nano", motion_in_zone=True)
    d = guard.combine(ev, [], now=ev["at"])
    assert d["raise"] and d["type"] == "hand_in_cash_zone" and not d["possible"]
    assert "motion_in_zone" in d["reason_signals"]
    sale = [{"kind": "sale", "amount": 100, "at": ev["at"] + 10}]
    assert not guard.combine(ev, sale, now=ev["at"])["raise"]


@needs_backend
def test_after_hours_raises_and_multiple_frames_counts(guard):
    ev = _event(payload.AFTER_HOURS, detector="motion_only", frames=3)
    assert ev["signals"]["after_hours"] is True
    d = guard.combine(ev, [], now=ev["at"])
    assert d["raise"] and "multiple_frames" in d["reason_signals"]
    assert d["confidence"] == pytest.approx(0.8)


@needs_backend
def test_motion_only_zone_breach_raises_but_lone_motion_does_not(guard):
    ev = _event(payload.MOTION, detector="motion_only", motion_in_zone=True)
    assert ev["signals"] == {"detector": "motion_only", "zone_breach": True,
                             "motion_in_zone": True}
    assert guard.combine(ev, [], now=ev["at"])["raise"]
    lone = _event(payload.MOTION, detector="motion_only")
    assert not guard.combine(lone, [], now=lone["at"])["raise"]


def test_only_true_observations_are_sent():
    s = payload.build_signals(payload.HAND_IN_CASH_ZONE, detector="yolox_nano",
                              motion_in_zone=False, lingering=False)
    assert s == {"detector": "yolox_nano"}
    with pytest.raises(ValueError):
        payload.build_signals("drawer_open", detector="x")   # not edge-emitted


def test_queued_event_has_no_credentials_and_valid_fields():
    ev = _event(payload.AFTER_HOURS, detector="yolox_nano", frames=2)
    assert set(ev) == {"type", "signals", "camera_id", "at"}
    assert isinstance(ev["at"], float)
    assert "token" not in json.dumps(ev)
    with pytest.raises(ValueError):
        payload.build_event("theft", {}, camera_id="c1")


def test_request_json_shape_matches_ingest_view():
    ev = _event(payload.MOTION, detector="motion_only", motion_in_zone=True)
    transport, body, files = payload.build_request(
        ev, site_token="SITE", camera_token=None, snapshot=b"\xff\xd8jpeg")
    # motion's raise depends on signals -> JSON (signals preserved), no image
    assert transport == "json" and files is None
    assert body == {"site_token": "SITE", "type": "motion",
                    "at": 1_700_000_000.0, "signals": ev["signals"]}


def test_request_multipart_shape_and_single_snapshot():
    ev = _event(payload.HAND_IN_CASH_ZONE, detector="yolox_nano", motion_in_zone=True)
    transport, form, files = payload.build_request(
        ev, site_token="SITE", camera_token="CAM", snapshot=b"\xff\xd8jpeg")
    assert transport == "multipart"
    assert form["camera_token"] == "CAM" and "site_token" not in form
    assert form["type"] == "hand_in_cash_zone"
    assert float(form["at"]) == 1_700_000_000.0
    assert json.loads(form["signals"]) == ev["signals"]
    assert list(files) == ["snapshot"]                     # exactly one file
    assert files["snapshot"][2] == "image/jpeg"
    # never-mode keeps signals and sends no image at all
    t2, _, f2 = payload.build_request(ev, site_token="S", camera_token=None,
                                      snapshot=b"x", snapshot_mode="never")
    assert t2 == "json" and f2 is None


def test_unpaired_request_refused():
    ev = _event(payload.AFTER_HOURS, detector="motion_only")
    with pytest.raises(ValueError):
        payload.build_request(ev, site_token=None, camera_token=None)


def test_snapshot_is_small_jpeg_even_for_large_noisy_frame():
    import cv2
    rng = np.random.default_rng(1)
    frame = rng.integers(0, 256, (1080, 1920, 3), dtype=np.uint8)  # worst case
    jpg = payload.encode_snapshot(frame, max_bytes=150 * 1024,
                                  zone=[(0.1, 0.1), (0.5, 0.1), (0.5, 0.5)])
    assert jpg[:2] == b"\xff\xd8" and len(jpg) <= 150 * 1024
    img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    assert img.shape[1] <= 640
