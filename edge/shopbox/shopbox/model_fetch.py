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


def candidate_paths():
    """Where a model may live, in priority order: bundled next to the program
    (PyInstaller puts data under sys._MEIPASS / the exe dir), then the per-user
    data dir (first-run download)."""
    out = []
    env = os.environ.get("SHOPBOX_MODEL")
    if env:
        out.append(env)
    base = getattr(sys, "_MEIPASS", None)
    if base:
        out.append(os.path.join(base, "models", MODEL_FILENAME))
    if getattr(sys, "frozen", False):
        out.append(os.path.join(os.path.dirname(sys.executable), "models",
                                MODEL_FILENAME))
    out.append(os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "models", MODEL_FILENAME))
    out.append(os.path.join(paths.data_dir(), "models", MODEL_FILENAME))
    return out


def find_model() -> Optional[str]:
    for p in candidate_paths():
        if p and os.path.isfile(p):
            return p
    return None


def download(dest: Optional[str] = None, url: str = MODEL_URL,
             expected: str = MODEL_SHA256, timeout: float = 60.0) -> str:
    """Download the model to `dest` (default: user data dir), verifying the
    SHA-256 BEFORE moving it into place. Raises on any failure."""
    import requests

    dest = dest or os.path.join(paths.data_dir(), "models", MODEL_FILENAME)
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


if __name__ == "__main__":   # used by CI: python -m shopbox.model_fetch <dest>
    logging.basicConfig(level=logging.INFO)
    target = sys.argv[1] if len(sys.argv) > 1 else None
    print(download(target))
