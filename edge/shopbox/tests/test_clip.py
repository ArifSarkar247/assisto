"""cashguard: edge-cut, end-to-end-sealed 3-5 s clips."""
import base64
import json
import os

import numpy as np
import pytest

from conftest import REPO_ROOT, FakeClock
from shopbox import clip as C
from shopbox import payload
from shopbox.analyzer import Trigger
from shopbox.client import (DROP, RETRY, SENT, ClipSender, SendResult,
                            classify_clip_response)
from shopbox.outbox import Outbox

VECTOR = os.path.join(REPO_ROOT, "tools", "cashguard", "clip_vector.json")


def _keypair(seed):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    import hashlib
    priv = bytearray(hashlib.sha256(seed).digest())
    priv[0] &= 248
    priv[31] &= 127
    priv[31] |= 64
    priv = bytes(priv)
    pub = X25519PrivateKey.from_private_bytes(priv).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return priv, pub


def _recip(uid, pub):
    return {"uid": uid, "key_id": C.key_id(pub), "pub": base64.b64encode(pub).decode()}


def test_seal_open_roundtrip_for_every_recipient_and_never_for_others():
    o_priv, o_pub = _keypair(b"owner")
    v_priv, v_pub = _keypair(b"viewer")
    x_priv, _ = _keypair(b"stranger")
    plain = C.encode_container([(1.0, b"\xff\xd8a\xff\xd9"), (1.2, b"\xff\xd8b\xff\xd9"),
                                (1.4, b"\xff\xd8c\xff\xd9")], 5)
    ct, meta = C.seal(plain, [_recip(1, o_pub), _recip(2, v_pub)])
    assert plain not in ct and b"\xff\xd8" not in ct[:8]
    assert set(meta["wraps"]) == {"1", "2"}
    assert C.open_clip(ct, meta, 1, o_priv) == plain
    assert C.open_clip(ct, meta, 2, v_priv) == plain
    with pytest.raises(Exception):
        C.open_clip(ct, meta, 1, x_priv)          # a stranger's key fails
    tampered = bytes([ct[0] ^ 1]) + ct[1:]
    with pytest.raises(Exception):
        C.open_clip(tampered, meta, 1, o_priv)    # AEAD catches tampering
    # every clip gets a fresh ephemeral key and content key
    ct2, meta2 = C.seal(plain, [_recip(1, o_pub)])
    assert meta2["eph_pub"] != meta["eph_pub"] and ct2 != ct


def test_bad_recipient_key_is_skipped_not_fatal():
    _, o_pub = _keypair(b"owner")
    ct, meta = C.seal(b"x" * 100, [{"uid": 9, "pub": "not-base64!"}, _recip(1, o_pub)])
    assert list(meta["wraps"]) == ["1"]


def test_fixed_vector_matches_this_code():
    """The same bytes the app's Dart test opens (cashguard_clip_test.dart)."""
    v = json.load(open(VECTOR))
    priv = base64.b64decode(v["recipient_private"])
    plain = C.open_clip(base64.b64decode(v["ciphertext"]), v["meta"], v["uid"], priv)
    import hashlib
    assert hashlib.sha256(plain).hexdigest() == v["plain_sha256"]
    head, frames = C.decode_container(plain)
    assert head["n"] == 16 and len(frames) == 16 and frames[0].startswith(b"\xff\xd8")


def test_container_roundtrip():
    frames = [(10.0 + i * 0.2, b"\xff\xd8%d\xff\xd9" % i) for i in range(5)]
    head, out = C.decode_container(C.encode_container(frames, 5))
    assert head["n"] == 5 and head["ts"][-1] == pytest.approx(0.8)
    assert out == [j for _, j in frames]


def test_recorder_pre_and_post_roll_make_a_4_second_clip():
    clock = FakeClock(1000.0)
    ready = []
    rec = C.ClipRecorder(on_ready=lambda *a: ready.append(a), clock=clock)
    _, pub = _keypair(b"owner")
    assert not rec.enabled
    rec.configure({"enabled": True, "recipients": [_recip(1, pub)], "fps": 5,
                   "seconds": 4, "pre_s": 2, "max_kb": 900})
    frame = np.full((360, 640, 3), 100, np.uint8)
    for _ in range(15):                    # 3 s of history at 5 fps
        rec.tap("c1", frame)
        clock.advance(0.2)
    assert rec.start("c1", "ab" * 16)
    for _ in range(12):                    # post-roll arrives
        rec.tap("c1", frame)
        clock.advance(0.2)
    assert len(ready) == 1
    cam, ref, frames = ready[0]
    built = C.build_clip(frames, 5, rec.cfg["recipients"], 900 * 1024)
    assert built is not None
    ct, meta = built
    assert 3.0 <= meta["duration_s"] <= 5.0 and meta["frames"] >= 15
    assert len(ct) <= 900 * 1024


def test_too_short_or_nobody_to_seal_for_gives_no_clip():
    _, pub = _keypair(b"owner")
    two = [(1.0, b"a"), (1.2, b"b")]
    assert C.build_clip(two, 5, [_recip(1, pub)], 10 ** 6) is None
    many = [(1.0 + i * 0.2, b"\xff\xd8x") for i in range(20)]
    assert C.build_clip(many, 5, [], 10 ** 6) is None


def test_clip_shrinks_to_fit_the_size_cap():
    _, pub = _keypair(b"owner")
    many = [(1.0 + i * 0.2, b"\xff\xd8" + b"z" * 20_000) for i in range(20)]
    built = C.build_clip(many, 5, [_recip(1, pub)], 250_000)
    assert built is not None and len(built[0]) <= 250_000
    assert built[1]["frames"] < 20


def test_disabled_recorder_costs_nothing():
    rec = C.ClipRecorder(on_ready=lambda *a: None)
    rec.tap("c1", np.zeros((10, 10, 3), np.uint8))
    assert rec.rings == {} and rec.start("c1", "ab" * 16) is False


def test_ingest_payload_carries_clip_ref_outside_signals():
    ev = payload.build_event("hand_in_cash_zone", {"detector": "yolox_nano",
                                                   "motion_in_zone": True},
                             camera_id="c1", at=5.0)
    ev["clip_ref"] = "cd" * 16
    t, body, files = payload.build_request(ev, site_token=None, camera_token="t",
                                           snapshot=b"\xff\xd8x")
    assert t == "multipart" and body["clip_ref"] == "cd" * 16
    assert "clip_ref" not in json.loads(body["signals"])


def test_clip_response_classes():
    assert classify_clip_response(404, {"error": "no_event"}).outcome == RETRY
    assert classify_clip_response(429, {"error": "clip_cap"}).outcome == DROP
    assert classify_clip_response(415, {"error": "not_encrypted"}).outcome == DROP
    assert classify_clip_response(201, {"ok": True}).outcome == SENT


class _FakeClipClient:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def send(self, item, blob, *, site_token, camera_token):
        self.calls.append((item, blob))
        return self.results.pop(0)


def test_clip_sender_waits_for_the_alert_then_sends(tmp_path):
    clock = FakeClock(1000.0)
    box = Outbox(str(tmp_path / "clips"), clock=clock, ext=".bin")
    box.put({"clip_ref": "ef" * 16, "camera_id": "c1", "meta": {}}, b"\x01" * 2000)
    cli = _FakeClipClient([SendResult(RETRY, status=404, detail="no_event"),
                           SendResult(SENT, status=201)])
    s = ClipSender(box, cli, lambda cid: ("site", None), clock=clock)
    assert s.step() > 0 and len(box) == 1          # alert not there yet
    assert s.step() == 0.0 and len(box) == 0 and s.sent == 1
    assert os.listdir(tmp_path / "clips") == []


def test_clip_sender_gives_up_after_the_server_window(tmp_path):
    clock = FakeClock(1000.0)
    box = Outbox(str(tmp_path / "clips"), clock=clock, ext=".bin")
    box.put({"clip_ref": "ef" * 16, "camera_id": "c1", "meta": {}}, b"\x01" * 2000)
    clock.advance(16 * 60)
    s = ClipSender(box, _FakeClipClient([]), lambda cid: ("site", None), clock=clock)
    s.step()
    assert len(box) == 0 and s.dropped == 1


def test_engine_only_clips_cash_guard_alerts():
    from shopbox.engine import Engine
    f = np.zeros((4, 4, 3), np.uint8)
    yes = [Trigger("hand_in_cash_zone", {}, f, 0.0),
           Trigger("zone_intrusion", {"zone_breach": True}, f, 0.0),
           Trigger("motion", {"motion_in_zone": True}, f, 0.0),
           Trigger("after_hours", {"person_in_zone": True}, f, 0.0)]
    no = [Trigger("person_detected", {"person": True}, f, 0.0),
          Trigger("after_hours", {"after_hours": True}, f, 0.0),
          Trigger("line_crossing", {}, f, 0.0)]
    assert all(Engine.wants_clip(t) for t in yes)
    assert not any(Engine.wants_clip(t) for t in no)


def test_engine_names_the_clip_in_the_queued_alert(tmp_path):
    from shopbox.config import AppConfig, CameraConfig
    from shopbox.engine import Engine, EventLog
    from shopbox.person import NullDetector
    from shopbox.secure_store import SecretStore, _FernetCipher

    cfg = AppConfig()
    cfg.cameras.append(CameraConfig(id="c1", name="Till", rtsp_url="rtsp://x",
                                    zone=[[0, 0], [1, 0], [1, 1]]))
    store = SecretStore(str(tmp_path), cipher=_FernetCipher(str(tmp_path / "k")))
    eng = Engine(cfg, store, detector=NullDetector(),
                 events=EventLog(str(tmp_path / "ev.jsonl")))
    _, pub = _keypair(b"owner")
    eng.apply_server_config({"clip": {"enabled": True, "recipients": [_recip(1, pub)]}},
                            None)
    assert eng.clips.enabled
    frame = np.full((360, 640, 3), 90, np.uint8)
    trig = Trigger("hand_in_cash_zone", {"detector": "yolox_nano"}, frame, 1_700_000_000.0)
    assert eng.handle_trigger("c1", trig)
    _, rec, _ = eng.outbox.peek()
    assert len(rec["event"]["clip_ref"]) == 32
    assert eng.status()["clips"]["enabled"] is True
