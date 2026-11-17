"""Download + verify the person-detection model.

The model is NEVER committed to the repository. It is fetched from its official
public release URL either at CI build time (and bundled next to the .exe) or on
first run, and is accepted only if its SHA-256 matches the pinned value below.
"""
from __future__ import annotations

import hashlib
import logging
import os
import sys
import tempfile
from typing import Optional

from . import paths

log = logging.getLogger(__name__)

MODEL_FILENAME = "yolox_nano.onnx"
# Official Megvii YOLOX release asset (Apache-2.0).
MODEL_URL = ("https://github.com/Megvii-BaseDetection/YOLOX/releases/download/"
             "0.1.1rc0/yolox_nano.onnx")
MODEL_SHA256 = "c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d"
MODEL_MAX_BYTES = 20 * 1024 * 1024   # sanity cap; the real file is ~3.6 MB
# cctvdet3: the optional VEHICLE model for parking / gate-line cameras only
# (people stay on YOLOX-Nano; phones never run it). Official Megvii release
# asset, Apache-2.0, 20 219 662 bytes (under MODEL_MAX_BYTES).
VEHICLE_MODEL_FILENAME = "yolox_tiny.onnx"
VEHICLE_MODEL_URL = ("https://github.com/Megvii-BaseDetection/YOLOX/releases/download/"
                     "0.1.1rc0/yolox_tiny.onnx")
VEHICLE_MODEL_SHA256 = "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7"
# cctvdet3: the BANGLADESH vehicle model (YOLOX-Nano fine-tuned on CC BY 4.0
# Bangladeshi street photos by tools/e2e/cctv_vehicle_train.py in CI; knows
# CNG, rickshaw, leguna ...). Preferred when published at this URL with this
# SHA-256 (published by the accuracy workflow's train mode, release
# shopbox-vehicle-bd-1, never overwritten).
BD_VEHICLE_MODEL_FILENAME = "assisto_vehicle_bd_nano.onnx"
BD_VEHICLE_MODEL_URL = ("https://github.com/ArifSarkar247/assisto/releases/download/"
                        "shopbox-vehicle-bd-1/assisto_vehicle_bd_nano.onnx")
BD_VEHICLE_MODEL_SHA256 = "c0189c8f9b8b16277e08cb0751c3744396887cd3eac4bab25a43032fbe220779"  # CI run 44021451977 (published)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_sha256(path: str, expected: str = MODEL_SHA256) -> bool:
    try:
        return sha256_of(path) == expected
    except OSError:
        return False


def candidate_paths(filename: str = MODEL_FILENAME):
    """Where a model may live, in priority order: bundled next to the program
    (PyInstaller puts data under sys._MEIPASS / the exe dir), then the per-user
    data dir (first-run download)."""
    out = []
    env = os.environ.get("SHOPBOX_MODEL" if filename == MODEL_FILENAME
                         else "SHOPBOX_VEHICLE_MODEL")
    if env:
        out.append(env)
    base = getattr(sys, "_MEIPASS", None)
    if base:
        out.append(os.path.join(base, "models", filename))
    if getattr(sys, "frozen", False):
        out.append(os.path.join(os.path.dirname(sys.executable), "models",
                                filename))
    out.append(os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "models", filename))
    out.append(os.path.join(paths.data_dir(), "models", filename))
    return out


def find_model(filename: str = MODEL_FILENAME) -> Optional[str]:
    for p in candidate_paths(filename):
        if p and os.path.isfile(p):
            return p
    return None


def download(dest: Optional[str] = None, url: str = MODEL_URL,
             expected: str = MODEL_SHA256, timeout: float = 60.0,
             filename: str = MODEL_FILENAME) -> str:
    """Download the model to `dest` (default: user data dir), verifying the
    SHA-256 BEFORE moving it into place. Raises on any failure."""
    import requests

    dest = dest or os.path.join(paths.data_dir(), "models", filename)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    h = hashlib.sha256()
    size = 0
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out, requests.get(
                url, stream=True, timeout=timeout) as r:
            r.raise_for_status()
            for chunk in r.iter_content(1 << 16):
                size += len(chunk)
                if size > MODEL_MAX_BYTES:
                    raise ValueError("model download larger than expected")
                h.update(chunk)
                out.write(chunk)
        got = h.hexdigest()
        if got != expected:
            raise ValueError("model SHA-256 mismatch: got %s" % got)
        os.replace(tmp, dest)
        log.info("person model downloaded and verified (%d bytes)", size)
        return dest
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def ensure_model(allow_download: bool = True) -> Optional[str]:
    """Find a verified model, downloading it once if allowed. Returns the path
    or None (caller degrades to motion_only)."""
    p = find_model()
    if p and verify_sha256(p):
        return p
    if not allow_download:
        return None
    try:
        return download()
    except Exception as exc:
        log.warning("could not fetch person model (%s); motion_only mode", exc)
        return None


def ensure_vehicle_model(allow_download: bool = True) -> Optional[str]:
    """cctvdet3: the vehicle model, fetched only when a camera has a parking,
    no-parking or vehicle gate-line zone. None -> vehicles come from the
    person model's own vehicle classes (less recall, measured and shown)."""
    choices = [(VEHICLE_MODEL_FILENAME, VEHICLE_MODEL_URL, VEHICLE_MODEL_SHA256)]
    if BD_VEHICLE_MODEL_SHA256:
        choices.insert(0, (BD_VEHICLE_MODEL_FILENAME, BD_VEHICLE_MODEL_URL,
                           BD_VEHICLE_MODEL_SHA256))
    for name, _url, sha in choices:
        p = find_model(name)
        if p and verify_sha256(p, sha):
            return p
    if not allow_download:
        return None
    for name, url, sha in choices:
        try:
            return download(url=url, expected=sha, filename=name)
        except Exception as exc:
            log.warning("could not fetch the vehicle model %s (%s)", name, exc)
    return None


def vehicle_model_sha(path: str) -> Optional[str]:
    """The pinned SHA-256 for a vehicle model file name (None = unknown)."""
    base = os.path.basename(path or "")
    if base == BD_VEHICLE_MODEL_FILENAME:
        return BD_VEHICLE_MODEL_SHA256
    if base == VEHICLE_MODEL_FILENAME:
        return VEHICLE_MODEL_SHA256
    return None


if __name__ == "__main__":   # used by CI: python -m shopbox.model_fetch <dest>
    logging.basicConfig(level=logging.INFO)
    target = sys.argv[1] if len(sys.argv) > 1 else None
    print(download(target))
