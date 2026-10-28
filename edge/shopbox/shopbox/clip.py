"""Smart Cash Guard clips: a 3-5 s clip cut HERE from the local stream,
sealed end to end for the owner's phones, uploaded only as ciphertext.

  CameraWorker tap (~5 fps) -> FrameRing (last few seconds, as small JPEGs)
  trigger -> ClipJob (pre-roll from the ring + post-roll as frames arrive)
          -> encode_container() "ACG1" (JSON header + JPEG frames, no codec)
          -> seal() per-event key, wrapped for every recipient's X25519 key
          -> clip outbox (disk) -> ClipSender -> POST shop/clips

CRYPTO (must match the app's chat E2E, app/lib/crypto/e2e.dart, scheme
"x25519-xchacha-fallback-v1"):
  content   K = 32 random bytes; ct = ChaCha20-Poly1305(K, nonce12,
            container, aad = b"assisto-cashguard-clip-v1")
  per user  an EPHEMERAL X25519 key e (fresh per clip); shared = X25519(e,
            user_pub); wrap_key = HKDF-SHA256(salt = 32 zero bytes,
            info = b"assisto-circle-x25519-xchacha-fallback-v1" + lo + hi,
            where lo/hi are e_pub / user_pub in byte order); wrap =
            ChaCha20-Poly1305(wrap_key, nonce12, base64(K), aad = key_id(e))
  key_id    first 6 bytes of SHA-256(pub) as 12 hex chars (the app's
            fingerprint), so the app opens a wrap with its normal
            E2E.decrypt(self, senderPublicKey = e_pub, ...).
The server stores the ciphertext + this public envelope only; it has no
private key and cannot open a clip. The ephemeral private key is dropped
right after sealing.
"""
from __future__ import annotations

import base64
import collections
import hashlib
import json
import os
import struct
import threading
import time
from typing import Dict, List, Optional, Sequence, Tuple

SCHEME = "x25519-xchacha-fallback-v1"
AAD = b"assisto-cashguard-clip-v1"
MAGIC = b"ACG1"
FORMAT = "acg1"
CLIP_TYPES = frozenset({"hand_in_cash_zone", "after_hours", "zone_intrusion",
                        "motion"})


def key_id(pub: bytes) -> str:
    return hashlib.sha256(pub).digest()[:6].hex()


def _info(a: bytes, b: bytes) -> bytes:
    lo, hi = (a, b) if a < b else (b, a)
    return ("assisto-circle-%s" % SCHEME).encode() + lo + hi


# ------------------------------------------------------------------ frames
class FrameRing:
    """The last `seconds` of tap frames for one camera, as JPEG bytes."""

    def __init__(self, seconds: float = 3.0, fps: float = 5.0):
        self.seconds = float(seconds)
        self._q: collections.deque = collections.deque(
            maxlen=max(4, int(seconds * fps * 2)))
        self._lock = threading.Lock()

    def add(self, ts: float, jpeg: bytes) -> None:
        with self._lock:
            self._q.append((ts, jpeg))
            while self._q and ts - self._q[0][0] > self.seconds:
                self._q.popleft()

    def since(self, t0: float) -> List[Tuple[float, bytes]]:
        with self._lock:
            return [(t, j) for t, j in self._q if t >= t0]


def encode_frame(frame_bgr, width: int = 480, quality: int = 60) -> bytes:
    import cv2

    h, w = frame_bgr.shape[:2]
    img = frame_bgr
    if w > width:
        img = cv2.resize(frame_bgr, (width, max(1, int(round(h * width / w)))),
                         interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, int(quality)])
    if not ok:
        raise ValueError("jpeg encode failed")
    return buf.tobytes()


def encode_container(frames: Sequence[Tuple[float, bytes]], fps: float,
                     extra: Optional[dict] = None) -> bytes:
    """MAGIC + u32 header length + JSON header + (u32 length + JPEG) * n."""
    if not frames:
        raise ValueError("no frames")
    head = {"v": 1, "fps": round(float(fps), 2), "n": len(frames),
            "t0": round(frames[0][0], 3),
            "ts": [round(t - frames[0][0], 3) for t, _ in frames]}
    head.update(extra or {})
    hb = json.dumps(head, separators=(",", ":")).encode()
    parts = [MAGIC, struct.pack(">I", len(hb)), hb]
    for _, j in frames:
        parts += [struct.pack(">I", len(j)), j]
    return b"".join(parts)


def decode_container(raw: bytes) -> Tuple[dict, List[bytes]]:
    """Inverse of encode_container (tests + the precision harness)."""
    if raw[:4] != MAGIC:
        raise ValueError("not an ACG1 clip")
    (hl,) = struct.unpack(">I", raw[4:8])
    head = json.loads(raw[8:8 + hl].decode())
    off, out = 8 + hl, []
    for _ in range(int(head["n"])):
        (n,) = struct.unpack(">I", raw[off:off + 4])
        out.append(raw[off + 4:off + 4 + n])
        off += 4 + n
    return head, out


def duration_of(frames: Sequence[Tuple[float, bytes]], fps: float) -> float:
    if not frames:
        return 0.0
    return round(frames[-1][0] - frames[0][0] + 1.0 / max(fps, 0.5), 2)


# ------------------------------------------------------------------ sealing
def seal(plain: bytes, recipients: Sequence[dict], *, rand=os.urandom,
         eph_private: Optional[bytes] = None) -> Tuple[bytes, dict]:
    """-> (ciphertext, public envelope). recipients: [{uid, key_id, pub}]
    with `pub` the base64 32-byte X25519 public key the app published."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey)
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    k = rand(32)
    nonce = rand(12)
    ct = ChaCha20Poly1305(k).encrypt(nonce, plain, AAD)
    eph = (X25519PrivateKey.from_private_bytes(eph_private) if eph_private
           else X25519PrivateKey.generate())
    eph_pub = eph.public_key().public_bytes(serialization.Encoding.Raw,
                                            serialization.PublicFormat.Raw)
    eid = key_id(eph_pub)
    wraps: Dict[str, dict] = {}
    k_b64 = base64.b64encode(k)
    for r in recipients:
        try:
            pub = base64.b64decode(str(r["pub"]), validate=True)
            if len(pub) != 32:
                continue
            shared = eph.exchange(X25519PublicKey.from_public_bytes(pub))
        except Exception:
            continue                      # a bad key never blocks the others
        wk = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
                  info=_info(eph_pub, pub)).derive(shared)
        wn = rand(12)
        wraps[str(int(r["uid"]))] = {
            "key_id": str(r.get("key_id") or key_id(pub)),
            "nonce": base64.b64encode(wn).decode(),
            "ct": base64.b64encode(ChaCha20Poly1305(wk).encrypt(
                wn, k_b64, eid.encode())).decode()}
    meta = {"v": 1, "alg": "chacha20poly1305", "scheme": SCHEME,
            "format": FORMAT, "aad": AAD.decode(),
            "nonce": base64.b64encode(nonce).decode(),
            "eph_pub": base64.b64encode(eph_pub).decode(), "eph_key_id": eid,
            "wraps": wraps, "sha256": hashlib.sha256(ct).hexdigest()}
    del k, eph
    return ct, meta


def open_clip(ct: bytes, meta: dict, uid, private_key: bytes) -> bytes:
    """What the app does (tests / the harness): unwrap with my X25519
    private key, then decrypt the clip."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey)
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    me = X25519PrivateKey.from_private_bytes(private_key)
    my_pub = me.public_key().public_bytes(serialization.Encoding.Raw,
                                          serialization.PublicFormat.Raw)
    eph_pub = base64.b64decode(meta["eph_pub"])
    w = meta["wraps"][str(uid)] if "wraps" in meta else meta["wrap"]
    shared = me.exchange(X25519PublicKey.from_public_bytes(eph_pub))
    wk = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
              info=_info(eph_pub, my_pub)).derive(shared)
    k = base64.b64decode(ChaCha20Poly1305(wk).decrypt(
        base64.b64decode(w["nonce"]), base64.b64decode(w["ct"]),
        meta["eph_key_id"].encode()))
    return ChaCha20Poly1305(k).decrypt(base64.b64decode(meta["nonce"]), ct,
                                       meta["aad"].encode())


# ------------------------------------------------------------------ jobs
class ClipJob:
    """One clip being collected: pre-roll frames + post-roll until `until`."""

    def __init__(self, cam_id: str, clip_ref: str, frames, until: float,
                 started: float):
        self.cam_id = cam_id
        self.clip_ref = clip_ref
        self.frames = list(frames)
        self.until = until
        self.started = started
        self.done = False

    def add(self, ts: float, jpeg: bytes) -> bool:
        """Feed a frame; True once the post-roll is complete."""
        if self.done:
            return True
        if ts <= self.until:
            self.frames.append((ts, jpeg))
        if ts >= self.until:
            self.done = True
        return self.done


def build_clip(frames, fps: float, recipients, max_bytes: int,
               min_s: float = 2.5, max_s: float = 5.5):
    """-> (ciphertext, meta) or None (too short / nobody to seal for / too big
    even at the smallest quality). Shrinks by dropping every other frame."""
    frames = sorted(frames)
    if not recipients or len(frames) < 3:
        return None
    # never longer than max_s: keep the frames closest to the trigger window
    while frames and duration_of(frames, fps) > max_s:
        frames = frames[1:]
    if duration_of(frames, fps) < min_s:
        return None
    eff_fps = fps
    for _ in range(4):
        plain = encode_container(frames, eff_fps)
        if len(plain) + 64 <= max_bytes:
            ct, meta = seal(plain, recipients)
            if not meta["wraps"]:
                return None
            meta.update({"frames": len(frames),
                         "duration_s": duration_of(frames, eff_fps),
                         "fps": round(eff_fps, 2)})
            return ct, meta
        if len(frames) <= 6:
            break
        frames = frames[::2]
        eff_fps = eff_fps / 2.0
    return None


class ClipRecorder:
    """Per-camera rings + running jobs. Thread-safe; cheap when idle."""

    def __init__(self, on_ready, clock=time.time):
        self.on_ready = on_ready           # (cam_id, clip_ref, frames) -> None
        self.clock = clock
        self.rings: Dict[str, FrameRing] = {}
        self.jobs: List[ClipJob] = []
        self._lock = threading.Lock()
        self.cfg = {"enabled": False, "recipients": [], "seconds": 4,
                    "pre_s": 2, "fps": 5, "max_kb": 900}

    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled")) and bool(self.cfg.get("recipients"))

    def configure(self, clip_cfg: Optional[dict]) -> None:
        if not isinstance(clip_cfg, dict):
            return
        c = dict(self.cfg)
        for k in ("enabled", "recipients", "seconds", "pre_s", "fps", "max_kb"):
            if k in clip_cfg:
                c[k] = clip_cfg[k]
        c["fps"] = max(2.0, min(10.0, float(c.get("fps") or 5)))
        c["seconds"] = max(3.0, min(5.0, float(c.get("seconds") or 4)))
        c["pre_s"] = max(0.5, min(c["seconds"] - 1.0, float(c.get("pre_s") or 2)))
        c["recipients"] = [r for r in (c.get("recipients") or [])
                           if isinstance(r, dict) and r.get("pub") and r.get("uid")]
        self.cfg = c

    def tap(self, cam_id: str, frame_bgr, ts: Optional[float] = None) -> None:
        if not self.enabled:
            return
        ts = self.clock() if ts is None else ts
        try:
            jpeg = encode_frame(frame_bgr)
        except Exception:
            return
        ring = self.rings.get(cam_id)
        if ring is None:
            ring = self.rings[cam_id] = FrameRing(self.cfg["pre_s"] + 1.0,
                                                  self.cfg["fps"])
        ring.add(ts, jpeg)
        ready = []
        with self._lock:
            for j in self.jobs:
                if j.cam_id == cam_id and j.add(ts, jpeg):
                    ready.append(j)
            self.jobs = [j for j in self.jobs if j not in ready]
        for j in ready:
            self.on_ready(j.cam_id, j.clip_ref, j.frames)

    def start(self, cam_id: str, clip_ref: str, now: Optional[float] = None) -> bool:
        if not self.enabled:
            return False
        now = self.clock() if now is None else now
        ring = self.rings.get(cam_id)
        pre = ring.since(now - self.cfg["pre_s"]) if ring else []
        post = self.cfg["seconds"] - self.cfg["pre_s"]
        with self._lock:
            if len(self.jobs) >= 8:
                return False             # bounded: never pile up
            self.jobs.append(ClipJob(cam_id, clip_ref, pre, now + post, now))
        return True

    def sweep(self, now: Optional[float] = None) -> None:
        """A stalled stream: finish jobs whose post-roll never came."""
        now = self.clock() if now is None else now
        with self._lock:
            stale = [j for j in self.jobs if now - j.until > 3.0]
            self.jobs = [j for j in self.jobs if j not in stale]
        for j in stale:
            self.on_ready(j.cam_id, j.clip_ref, j.frames)
