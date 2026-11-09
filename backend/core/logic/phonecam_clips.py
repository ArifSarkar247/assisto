"""cctvplay — remote playback for the PHONE camera (owner order 9 Nov 14:45,
items 3 + 4). PURE rules (no Django, no DB, no clock — callers pass `now_ts`).

Two ways a viewer (owner / family viewer) plays what the camera phone saw:

1. PREVIEW on every alert (automatic, small): the camera phone records its
   ~10 s clip as before AND cuts a few small JPEG frames from it (320 px,
   about 1.5 frames/s), packs them in our "ACG1" container and SEALS it on the
   phone for the owner's + viewers' public keys (the cashguard construction:
   ChaCha20-Poly1305 + X25519 wraps). The server keeps ciphertext only, for
   24 h (PREVIEW_TTL_S), never opened, never deleted by a single view (the
   family may still want it). At most PREVIEWS_DAY per camera per day.
2. FULL VIDEO on demand: a viewer taps "Get the full video"; the camera phone
   sees the request on its next heartbeat (every 10 s), seals the original
   MP4 the same way and uploads it (<= FULL_MAX_BYTES). Kept 24 h. Each full
   video counts against the camera's monthly relay budget (cctvguard meter),
   because it is our server's bandwidth; with the owner-confirmed caps a
   paused budget refuses NEW full-video requests (alerts, photos and previews
   never stop).
3. (item 4) CONTINUOUS RECORDING segments use path 2: the viewer picks a
   minute on the timeline the camera phone published; the phone uploads that
   sealed segment.

The phone keeps the originals; when its storage cap rolls over, the oldest
are gone — the server answers "no longer on the camera phone" honestly.
"""
import re

from . import cash_guard as CG

CLIP_S = 10                       # what the camera phone records per alert
PREVIEW_MIN_S, PREVIEW_MAX_S = 2.0, 12.5
PREVIEW_MAX_FRAMES = 40
PREVIEW_MAX_KB = 600
PREVIEW_TTL_S = 24 * 3600
PREVIEWS_DAY_DEFAULT = 20         # per camera, Owner Admin knob phonecam_previews_day
FULL_FORMAT = "mp4"
FULL_AAD = "assisto-phonecam-video-v1"
FULL_MAX_BYTES = 8 * 1024 * 1024  # 10 s at ~0.8 Mbps is ~1 MB; a 1-min segment ~4-6 MB
FULL_MAX_S = 75.0
FULL_TTL_S = 24 * 3600
REQUEST_TTL_S = 24 * 3600         # a phone that stays offline longer -> "expired"
EST_FULL_MB = 1.5                 # shown before the tap ("about 1.5 MB")
EST_SEGMENT_MB = 5.0

STATUSES = ("requested", "ready", "missing", "expired", "failed")
_KEY_RE = re.compile(r"^(e[0-9]{1,12}|s[0-9]{9,11})$")


# ---------------------------------------------------------------- envelopes
def _base_problems(meta, fmt, aad):
    """The shared envelope checks of CG.clip_meta_problems with OUR format /
    aad and without its 3-5 s duration rule (each caller checks its own)."""
    if not isinstance(meta, dict):
        return ["bad_meta"]
    probe = dict(meta, format=CG.CLIP_FORMAT, aad=CG.CLIP_AAD, duration_s=4.0,
                 frames=10)
    out = list(CG.clip_meta_problems(probe))
    if meta.get("format") != fmt:
        out.append("bad_format")
    if meta.get("aad") != aad:
        out.append("bad_aad")
    return out


def _num(v, default=-1.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def preview_meta_problems(meta):
    """[] when a phone preview envelope (ACG1 frames, 2-12.5 s) is well formed."""
    out = _base_problems(meta, CG.CLIP_FORMAT, CG.CLIP_AAD)
    if out and out == ["bad_meta"]:
        return out
    if not PREVIEW_MIN_S <= _num(meta.get("duration_s")) <= PREVIEW_MAX_S:
        out.append("bad_duration")
    try:
        frames = int(meta.get("frames"))
    except (TypeError, ValueError):
        frames = 0
    if not 2 <= frames <= PREVIEW_MAX_FRAMES:
        out.append("bad_frames")
    return out


def full_meta_problems(meta):
    """[] when a full-video envelope (sealed MP4, <= 75 s) is well formed."""
    out = _base_problems(meta, FULL_FORMAT, FULL_AAD)
    if out and out == ["bad_meta"]:
        return out
    if not 0.5 <= _num(meta.get("duration_s"), 1.0) <= FULL_MAX_S:
        out.append("bad_duration")
    return out


# ---------------------------------------------------------------- requests
def clean_key(v):
    """'e<event id>' (an alert's full clip) or 's<unix start>' (a recording
    segment, item 4) — anything else is refused."""
    v = str(v or "").strip().lower()
    return v if _KEY_RE.match(v) else ""


def event_key(event_id):
    return "e%d" % int(event_id)


def request_state(req, now_ts):
    """The honest state of one stored request dict (lazy expiry)."""
    if not isinstance(req, dict):
        return "none"
    st = req.get("status")
    if st not in STATUSES:
        return "none"
    if st == "requested" and now_ts - _num(req.get("at"), 0) > REQUEST_TTL_S:
        return "expired"
    if st == "ready" and _num(req.get("expires"), 0) <= now_ts:
        return "expired"
    return st


def pending_for_device(reqs, now_ts, limit=3):
    """Requests the camera phone should answer now — oldest first, at most
    `limit` per heartbeat (an old phone uploads one at a time)."""
    rows = []
    for k, r in (reqs or {}).items():
        if clean_key(k) and request_state(r, now_ts) == "requested":
            rows.append((_num(r.get("at"), 0), k, r))
    rows.sort()
    out = []
    for _, k, r in rows[:limit]:
        row = {"key": k, "kind": "event" if k[0] == "e" else "segment"}
        if r.get("ref"):
            row["ref"] = r["ref"]
        if k[0] == "s":
            row["start"] = int(k[1:])
        out.append(row)
    return out


def prune(reqs, now_ts, keep=60):
    """Drop requests older than 2 days and keep the newest `keep`."""
    rows = {k: r for k, r in (reqs or {}).items()
            if clean_key(k) and isinstance(r, dict)
            and now_ts - _num(r.get("at"), 0) <= 2 * 86400}
    if len(rows) > keep:
        for k in sorted(rows, key=lambda x: _num(rows[x].get("at"), 0))[:len(rows) - keep]:
            rows.pop(k, None)
    return rows


# ---------------------------------------------------------------- budget
def budget_view(state, confirmed):
    """What the viewer sees before asking for a full video. `state` is
    cctv_traffic.account_state(): {used_bytes|used_mb, cap_mb, level, pct}."""
    cap = int(state.get("cap_mb") or 0)
    used_b = state.get("used_bytes")
    used = (int(used_b) / (1000 * 1000)) if used_b is not None else float(
        state.get("used_mb") or 0)
    left = max(0.0, cap - used)
    paused = bool(confirmed) and state.get("level") == "paused"
    return {"cap_mb": cap, "used_mb": round(used, 1), "left_mb": round(left, 1),
            "enforced": bool(confirmed), "paused": paused}


def online(last_seen_ts, now_ts, window_s=60):
    """The camera phone answers within ~10 s when its heartbeat is fresh."""
    return last_seen_ts is not None and now_ts - last_seen_ts <= window_s
