"""Logging with secret redaction.

Every handler gets a filter that:
  * masks any `scheme://user:pass@` userinfo (RTSP URLs) -> `scheme://***@`;
  * masks every secret value the app has loaded (enrollment/camera tokens,
    passwords), registered via `register_secret()`;
  * masks `site_token` / `camera_token` key=value or "key": "value" shapes.
Logs go to a rotating file in the user config dir (+ console when present).
"""
from __future__ import annotations

import logging
import logging.handlers
import os
import re
import sys
import threading

_SECRETS: set = set()
_SECRETS_LOCK = threading.Lock()
_USERINFO_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@")
_TOKEN_KV_RE = re.compile(
    r"((?:site_token|camera_token|password|passwd|pass)[\"']?\s*[:=]\s*[\"']?)"
    r"[^\"'\s,&}]+", re.IGNORECASE)


def register_secret(value: str) -> None:
    if value and len(value) >= 4:
        with _SECRETS_LOCK:
            _SECRETS.add(value)


def redact(text: str) -> str:
    if not text:
        return text
    text = _USERINFO_RE.sub(r"\1***@", text)
    text = _TOKEN_KV_RE.sub(r"\1***", text)
    with _SECRETS_LOCK:
        secrets = sorted(_SECRETS, key=len, reverse=True)
    for s in secrets:
        if s in text:
            text = text.replace(s, "***")
    return text


def mask_url(url: str) -> str:
    """Display form of an RTSP URL with credentials hidden."""
    return redact(url or "")


class RedactFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        record.msg = redact(msg)
        record.args = ()
        return True


def setup(log_dir: str, level: int = logging.INFO, console: bool = True) -> None:
    os.makedirs(log_dir, exist_ok=True)
    root = logging.getLogger()
    root.setLevel(level)
    for h in list(root.handlers):
        root.removeHandler(h)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(threadName)s %(name)s: %(message)s")
    fh = logging.handlers.RotatingFileHandler(
        os.path.join(log_dir, "shopbox.log"), maxBytes=2 * 1024 * 1024,
        backupCount=3, encoding="utf-8")
    handlers = [fh]
    # a --noconsole PyInstaller build has no stdout
    if console and sys.stderr is not None:
        handlers.append(logging.StreamHandler(sys.stderr))
    for h in handlers:
        h.setFormatter(fmt)
        h.addFilter(RedactFilter())
        root.addHandler(h)
