"""
cashguard_detect.py — OPTIONAL server check of ONE alarm snapshot (owner order
28 Oct, item 5): vendor-cloud / camera-push alarms carry a still; when the
camera did not report a target box, the server may run the SAME person model
the Shop Box uses (YOLOX-Nano, Apache-2.0) on that ONE still and test the
boxes against the owner's cash zone.

COST on this 2 vCPU box (measured 28 Oct, tools/cashguard/server_detect_bench.py,
1 intra-op thread, 640x360 JPEG): see owner_actions/CCTV_VENDOR_ACCOUNTS_BN.md
("সার্ভারের খরচ"). Because the edge already does this for Shop Box / Guard Box
cameras, it is OFF by default (pricing shop knob `cashguard_server_detect` = 0)
and, when on, serialised (one inference at a time, non-blocking: a busy
detector is skipped, never queued) with a per-minute budget.

Model file: settings.CASHGUARD_PERSON_MODEL or <MEDIA_ROOT>/../models/
yolox_nano.onnx, accepted only with the pinned SHA-256. Missing -> the check
is simply skipped (honest: the camera's own alarm stands as "possible").
NEVER raises into a view.
"""
import hashlib
import io
import logging
import os
import threading
import time

log = logging.getLogger("assisto.shop")

MODEL_SHA256 = "c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d"
INPUT = 416
STRIDES = (8, 16, 32)
PER_MIN = 20

_lock = threading.Lock()
_state = {"sess": None, "failed": False, "grids": None, "window": 0, "count": 0}


def enabled():
    from . import billing
    try:
        return int((billing.cfg().get("shop") or {}).get("cashguard_server_detect", 0)) == 1
    except Exception:
        return False


def _model_path():
    from django.conf import settings
    p = getattr(settings, "CASHGUARD_PERSON_MODEL", "") or os.path.join(
        os.path.dirname(os.path.abspath(str(settings.MEDIA_ROOT))), "models",
        "yolox_nano.onnx")
    return p if os.path.isfile(p) else ""


def _sha_ok(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest() == MODEL_SHA256


def _grids():
    import numpy as np
    gs, ss = [], []
    for s in STRIDES:
        n = INPUT // s
        xv, yv = np.meshgrid(np.arange(n), np.arange(n))
        gs.append(np.stack((xv, yv), 2).reshape(-1, 2))
        ss.append(np.full((n * n, 1), s))
    return (np.concatenate(gs, 0).astype("float32"),
            np.concatenate(ss, 0).astype("float32"))


def _session(path=None):
    if _state["sess"] is not None or _state["failed"]:
        return _state["sess"]
    path = path or _model_path()
    if not path or not _sha_ok(path):
        _state["failed"] = True
        return None
    try:
        import onnxruntime as ort
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1          # never more than one core
        o.inter_op_num_threads = 1
        _state["sess"] = ort.InferenceSession(path, sess_options=o,
                                              providers=["CPUExecutionProvider"])
        _state["grids"] = _grids()
    except Exception as exc:
        log.warning("cashguard detector unavailable (%s)", type(exc).__name__)
        _state["failed"] = True
    return _state["sess"]


def _letterbox(jpeg):
    import numpy as np
    from PIL import Image
    im = Image.open(io.BytesIO(jpeg)).convert("RGB")
    w, h = im.size
    r = min(INPUT / h, INPUT / w)
    nw, nh = max(1, int(round(w * r))), max(1, int(round(h * r)))
    canvas = np.full((INPUT, INPUT, 3), 114, dtype=np.uint8)
    canvas[:nh, :nw] = np.asarray(im.resize((nw, nh)))[:, :, ::-1]   # BGR
    blob = canvas.transpose(2, 0, 1)[None].astype("float32")
    return np.ascontiguousarray(blob), r, w, h


def _nms(boxes, scores, thr):
    import numpy as np
    order = scores.argsort()[::-1]
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
        iou = inter / (area[i] + area[order[1:]] - inter + 1e-9)
        order = order[1:][iou < thr]
    return keep


def detect_people(jpeg, score_thr=0.45, path=None):
    """Normalised person boxes [(x1, y1, x2, y2, score)] in ONE still, or None
    when the check did not run (off / busy / over budget / no model)."""
    import numpy as np
    now = int(time.time() // 60)
    if _state["window"] != now:
        _state["window"], _state["count"] = now, 0
    if _state["count"] >= PER_MIN:
        return None
    if not _lock.acquire(blocking=False):
        return None                       # busy: skip, never queue
    try:
        sess = _session(path)
        if sess is None:
            return None
        _state["count"] += 1
        blob, r, w, h = _letterbox(jpeg)
        out = sess.run(None, {sess.get_inputs()[0].name: blob})[0][0]
        grids, strides = _state["grids"]
        xy = (out[:, :2] + grids) * strides
        wh = np.exp(out[:, 2:4]) * strides
        sc = out[:, 4] * out[:, 5]        # objectness x person class
        k = sc >= score_thr
        if not np.any(k):
            return []
        xy, wh, sc = xy[k], wh[k], sc[k]
        b = np.concatenate([(xy - wh / 2) / r, (xy + wh / 2) / r], 1)
        res = []
        for i in _nms(b, sc, 0.45):
            x1, y1, x2, y2 = b[i]
            res.append((float(np.clip(x1 / w, 0, 1)), float(np.clip(y1 / h, 0, 1)),
                        float(np.clip(x2 / w, 0, 1)), float(np.clip(y2 / h, 0, 1)),
                        float(sc[i])))
        return res
    except Exception as exc:
        log.warning("cashguard detect failed (%s)", type(exc).__name__)
        return None
    finally:
        _lock.release()


def check_snapshot(jpeg, cash_poly):
    """True / False when the check ran (a person box in the cash zone?), None
    when it did not run. For the hook views."""
    from .logic.cash_guard import box_in_zone
    if not jpeg or not cash_poly or not enabled():
        return None
    boxes = detect_people(jpeg)
    if boxes is None:
        return None
    return any(box_in_zone(bx[:4], cash_poly) for bx in boxes)
