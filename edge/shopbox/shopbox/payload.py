"""The ONLY thing that leaves the PC: an alert signal + at most one snapshot.

Server contract (backend/core/shop_views.py :: ShopIngestView, POST
`<base>/shop/ingest`, no user login):

    site_token | camera_token   device auth (enrollment token / camera token)
    type                        one of ShopEvent.TYPES (see EVENT_TYPES below)
    signals                     dict — read by shop_guard.combine()
    at                          epoch seconds (float) or ISO-8601
    snapshot                    optional, multipart file — the ONE still image

How shop_guard.combine() reads `signals` for the types this edge emits:

  hand_in_cash_zone  raises unless a POS sale/drawer-open correlates (+-45 s);
                     EVERY truthy key in `signals` is appended to the reasons
                     and adds +0.1 confidence. So we only send keys that are
                     true observations and omit false ones.
  after_hours        raises unless signals["after_hours"] is falsy (default
                     True); signals["multiple_frames"] adds +0.1.
  motion             never raises alone; raises (0.55) with signals["zone_breach"]
                     or escalates to after_hours with signals["after_hours"].

Transport caveat (honest): the server reads `signals` with
`isinstance(request.data.get("signals"), dict)`. In a multipart upload (needed
to attach the snapshot) every form field is a STRING, so today the server
drops the signals of a multipart request. `transport_for()` therefore sends
JSON (signals kept, no snapshot) whenever the server's decision DEPENDS on the
signals, and multipart (snapshot kept) only for types whose raise decision does
not. The signals are still included in multipart as a JSON string so the
payload is correct the day the server parses it.
"""
from __future__ import annotations

import json
import time
from typing import Dict, Optional

# Mirrors ShopEvent.TYPES (backend/core/models.py). The edge emits only the
# first three; the others are listed so validation matches the server exactly.
HAND_IN_CASH_ZONE = "hand_in_cash_zone"
AFTER_HOURS = "after_hours"
MOTION = "motion"
# CCTV AI Watchman (zones v2)
PERSON_DETECTED = "person_detected"
ZONE_INTRUSION = "zone_intrusion"
LINE_CROSSING = "line_crossing"
EVENT_TYPES = frozenset({
    HAND_IN_CASH_ZONE, "drawer_open", "void_spike", "refund_spike",
    "discount_spike", "eod_mismatch", MOTION, AFTER_HOURS, "pose_possible",
    PERSON_DETECTED, ZONE_INTRUSION, LINE_CROSSING, "camera_alarm",
})
EDGE_EMITTED_TYPES = frozenset({HAND_IN_CASH_ZONE, AFTER_HOURS, MOTION,
                                PERSON_DETECTED, ZONE_INTRUSION, LINE_CROSSING})

# person_detected / zone_intrusion / line_crossing go multipart (snapshot kept):
# the server parses the JSON-string `signals` of a multipart upload.
# Types whose server-side raise decision depends on keys inside `signals`
# (so they must be sent as JSON until the server parses multipart signals).
SIGNAL_DEPENDENT_TYPES = frozenset({MOTION, "pose_possible", "eod_mismatch",
                                    "void_spike", "refund_spike",
                                    "discount_spike"})

INGEST_PATH = "shop/ingest"


def build_signals(etype: str, *, detector: str, after_hours: bool = False,
                  motion_in_zone: bool = False, person_in_zone: bool = False,
                  frames: int = 1, lingering: bool = False,
                  conf: Optional[float] = None, zone_id: Optional[str] = None,
                  line_id: Optional[str] = None) -> Dict[str, object]:
    """Build the `signals` dict for one edge event, shaped for shop_guard.

    Only TRUE observations are included (a key with a false value would be
    harmless to the server but is noise). `detector` is always present so the
    owner/support can see how the event was produced ("yolox_nano" or the
    honest "motion_only").
    """
    if etype not in EDGE_EMITTED_TYPES:
        raise ValueError("edge does not emit %r" % etype)
    s: Dict[str, object] = {"detector": detector}
    if etype == AFTER_HOURS:
        s["after_hours"] = True
        if frames >= 2:
            s["multiple_frames"] = True
        if person_in_zone:
            s["person_in_zone"] = True
    elif etype == MOTION:
        # Only a zone breach (or after-hours) makes the server raise on motion.
        if motion_in_zone:
            s["zone_breach"] = True
            s["motion_in_zone"] = True
        if after_hours:
            s["after_hours"] = True
    elif etype == HAND_IN_CASH_ZONE:
        # The type itself already says "a person reached the cash zone"; the
        # extra keys are INDEPENDENT corroborations only.
        if motion_in_zone:
            s["motion_in_zone"] = True
        if lingering:
            s["lingering"] = True
    elif etype == PERSON_DETECTED:
        s["person"] = True
        if conf is not None:
            s["conf"] = round(float(conf), 3)
    elif etype == ZONE_INTRUSION:
        s["zone_breach"] = True
        s["zone"] = str(zone_id or "")[:32]
    elif etype == LINE_CROSSING:
        s["zone_breach"] = True
        s["line"] = str(line_id or "")[:32]
    return s


def build_event(etype: str, signals: Dict[str, object], *, camera_id: str,
                at: Optional[float] = None) -> Dict[str, object]:
    """The queued (on-disk) form of an event. Holds NO token: credentials are
    attached only at send time from the encrypted store."""
    if etype not in EVENT_TYPES:
        raise ValueError("unknown event type %r" % etype)
    if not isinstance(signals, dict):
        raise TypeError("signals must be a dict")
    return {"type": etype, "signals": dict(signals), "camera_id": str(camera_id),
            "at": float(at if at is not None else time.time())}


def auth_fields(site_token: Optional[str], camera_token: Optional[str]) -> Dict[str, str]:
    """Prefer the per-camera token (lets the server attribute the camera);
    fall back to the shop's enrollment token."""
    if camera_token:
        return {"camera_token": camera_token}
    if site_token:
        return {"site_token": site_token}
    raise ValueError("not paired: no site or camera token")


def transport_for(etype: str, has_snapshot: bool, snapshot_mode: str = "auto") -> str:
    """'json' or 'multipart' — see the module docstring for why."""
    if not has_snapshot or snapshot_mode == "never":
        return "json"
    if snapshot_mode == "auto" and etype in SIGNAL_DEPENDENT_TYPES:
        return "json"
    return "multipart"


def build_request(event: Dict[str, object], *, site_token: Optional[str],
                  camera_token: Optional[str], snapshot: Optional[bytes] = None,
                  snapshot_mode: str = "auto"):
    """Return (transport, body, files) for requests.post.

    json      -> body is the JSON object; files is None
    multipart -> body is form fields (signals JSON-encoded); files carries the
                 single snapshot as `snapshot` (image/jpeg)
    """
    body: Dict[str, object] = dict(auth_fields(site_token, camera_token))
    body["type"] = event["type"]
    body["at"] = float(event["at"])
    transport = transport_for(str(event["type"]), bool(snapshot), snapshot_mode)
    if transport == "json":
        body["signals"] = dict(event["signals"])
        return transport, body, None
    # multipart form fields are strings; the server's float(at) parses this back
    form = {k: str(v) for k, v in body.items()}
    form["signals"] = json.dumps(event["signals"], separators=(",", ":"),
                                 sort_keys=True)
    files = {"snapshot": ("snapshot.jpg", snapshot, "image/jpeg")}
    return transport, form, files


def encode_snapshot(frame_bgr, max_bytes: int = 150 * 1024, max_width: int = 640,
                    zone=None) -> bytes:
    """Downscale + JPEG-encode one still, stepping quality/size down until it
    fits `max_bytes`. The zone outline is drawn (thin) so the owner sees what
    the camera was watching; NO labels, NO boxes captioned as anything."""
    import cv2
    import numpy as np

    img = frame_bgr
    h, w = img.shape[:2]
    if w > max_width:
        img = cv2.resize(img, (max_width, max(1, int(round(h * max_width / w)))),
                         interpolation=cv2.INTER_AREA)
    else:
        img = img.copy()
    if zone and len(zone) >= 3:
        hh, ww = img.shape[:2]
        pts = np.array([[int(x * (ww - 1)), int(y * (hh - 1))] for x, y in zone],
                       dtype=np.int32)
        cv2.polylines(img, [pts], True, (0, 200, 255), 1, cv2.LINE_AA)
    for _ in range(6):
        for q in (75, 65, 55, 45, 35):
            ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])
            if ok and len(buf) <= max_bytes:
                return buf.tobytes()
        hh, ww = img.shape[:2]
        img = cv2.resize(img, (max(16, int(ww * 0.75)), max(16, int(hh * 0.75))),
                         interpolation=cv2.INTER_AREA)
    raise ValueError("could not encode snapshot under %d bytes" % max_bytes)
