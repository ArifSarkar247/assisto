"""
flag-vehicle: raw tracker packet log for the FIRST real devices (ST-906 4G).

Every H02 frame (text or binary), every refused device id and every
connection whose first bytes match no protocol we speak is written as ONE
JSON line: time, protocol, device id, whether it is paired, the raw bytes as
hex (first 256 bytes), the parsed fields or the parse error. Owner Admin ->
"Tracker packets" (web/owner/views_trackerpkt.py) shows the last 50 with the
device id masked except its last 4 digits.

Short retention by design (it holds positions): a rotating file of at most
2 x 2 MB, and the reader drops anything older than RETENTION_S (72 h).
Logging can never break the tracker: every call swallows its own errors.
"""
import json
import logging
import os
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler

RETENTION_S = 72 * 3600
MAX_BYTES = 2 * 1024 * 1024
HEX_MAX = 256
_logger = None
_path = None


def log_path():
    p = os.environ.get("TRACKER_RAW_LOG", "")
    if p:
        return p
    try:
        from django.conf import settings
        p = str(getattr(settings, "TRACKER_RAW_LOG", "") or "")
        if p:
            return p
        base = str(settings.BASE_DIR)
    except Exception:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "logs", "tracker_raw.jsonl")


def _get():
    global _logger, _path
    p = log_path()
    if _logger is not None and _path == p:
        return _logger
    os.makedirs(os.path.dirname(p), exist_ok=True)
    lg = logging.getLogger("assisto.tracker.raw")
    lg.propagate = False
    lg.setLevel(logging.INFO)
    for h in list(lg.handlers):
        lg.removeHandler(h)
        h.close()
    h = RotatingFileHandler(p, maxBytes=MAX_BYTES, backupCount=1, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(message)s"))
    lg.addHandler(h)
    _logger, _path = lg, p
    return lg


def _iso(v):
    return v.isoformat() if isinstance(v, datetime) else v


def fields(parsed):
    """The parsed packet, small and JSON-safe (no raw dicts of unknown size)."""
    if not isinstance(parsed, dict):
        return {}
    out = {"kind": parsed.get("kind", "")}
    fix = parsed.get("fix") or {}
    for k in ("at", "lat", "lng", "speed_kmh", "course", "valid", "ignition"):
        if k in fix:
            out[k] = _iso(fix[k])
    if parsed.get("alarms"):
        out["alarms"] = list(parsed["alarms"])[:8]
    if parsed.get("status") is not None:
        out["status"] = "%08X" % (int(parsed["status"]) & 0xFFFFFFFF)
    if parsed.get("text"):
        out["text"] = str(parsed["text"])[:120]
    if parsed.get("binary"):
        out["binary"] = True
    return out


def record(proto, imei, raw=b"", parsed=None, error="", known=None):
    try:
        entry = {"ts": round(time.time(), 3), "proto": str(proto or "")[:16],
                 "imei": str(imei or "")[:20], "known": known,
                 "len": len(raw or b""), "hex": bytes(raw or b"")[:HEX_MAX].hex(),
                 "fields": fields(parsed), "error": str(error or "")[:40]}
        _get().info(json.dumps(entry, separators=(",", ":"), default=str))
    except Exception:
        pass


def mask(imei):
    s = str(imei or "")
    return ("•" * max(0, min(len(s), 15) - 4)) + s[-4:] if s else "—"


def recent(n=50, now=None):
    """Newest first, at most n, never older than RETENTION_S."""
    now = now or time.time()
    p = log_path()
    rows = []
    for f in (p + ".1", p):
        try:
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(e, dict) and now - float(e.get("ts") or 0) <= RETENTION_S:
                        rows.append(e)
        except OSError:
            continue
    rows.sort(key=lambda e: e.get("ts") or 0, reverse=True)
    return rows[:n]
