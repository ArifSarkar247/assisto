"""On-device person detection (CPU, onnxruntime) with an honest fallback.

Model: YOLOX-Nano (Megvii, Apache-2.0), the official ONNX export published on
the YOLOX GitHub release page. ~3.6 MB, 416x416 input, ~1 GFLOP — it runs in
tens of milliseconds on an ordinary shop PC CPU. We only keep COCO class 0
("person").

The detector is only invoked when the cheap motion stage has already seen
movement, so on a quiet camera it costs nothing.

If the model file is missing, fails its SHA-256 check, or onnxruntime is not
importable, `load_detector()` returns a `NullDetector` whose `name` is
"motion_only". The engine then degrades to motion-in-zone and reports
`detector: "motion_only"` in the signals instead of pretending to see people.
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from typing import List, Optional

import numpy as np

from . import model_fetch

log = logging.getLogger(__name__)

PERSON_CLASS = 0
_INPUT_SIZE = 416
_STRIDES = (8, 16, 32)


@dataclass(frozen=True)
class Detection:
    """A person box in NORMALISED image coords (0..1), plus its score."""
    x1: float
    y1: float
    x2: float
    y2: float
    score: float


class NullDetector:
    """Used when no model is available. Finds nothing; says so honestly."""
    name = "motion_only"
    available = False

    def detect(self, frame_bgr, score_thr=None) -> List[Detection]:  # noqa: D401
        return []


class YoloxPersonDetector:
    """YOLOX-Nano ONNX person detector (CPU only)."""
    name = "yolox_nano"
    available = True

    def __init__(self, model_path: str, score_thr: float = 0.45,
                 nms_thr: float = 0.45, threads: int = 2):
        import onnxruntime as ort  # imported lazily: optional dependency

        opts = ort.SessionOptions()
        # Keep the footprint small: a shop PC also runs the till software.
        opts.intra_op_num_threads = max(1, int(threads))
        opts.inter_op_num_threads = 1
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self._sess = ort.InferenceSession(model_path, sess_options=opts,
                                          providers=["CPUExecutionProvider"])
        self._input = self._sess.get_inputs()[0].name
        self.score_thr = float(score_thr)
        self.nms_thr = float(nms_thr)
        self._grids, self._expanded_strides = _make_grids(_INPUT_SIZE)
        # onnxruntime sessions are thread-safe for run(), but serialising keeps
        # peak CPU/RAM predictable when several cameras trigger at once.
        self._lock = threading.Lock()

    def detect(self, frame_bgr, score_thr: Optional[float] = None) -> List[Detection]:
        """`score_thr` overrides the threshold for this call (per-camera
        tuning.person_conf from the owner's app)."""
        h, w = frame_bgr.shape[:2]
        blob, ratio = _letterbox(frame_bgr, _INPUT_SIZE)
        with self._lock:
            out = self._sess.run(None, {self._input: blob})[0][0]
        thr = self.score_thr if score_thr is None else float(score_thr)
        return _decode(out, self._grids, self._expanded_strides, ratio, w, h,
                       thr, self.nms_thr)


def _make_grids(size: int):
    grids, strides = [], []
    for s in _STRIDES:
        n = size // s
        xv, yv = np.meshgrid(np.arange(n), np.arange(n))
        grids.append(np.stack((xv, yv), 2).reshape(-1, 2))
        strides.append(np.full((n * n, 1), s))
    return (np.concatenate(grids, 0).astype(np.float32),
            np.concatenate(strides, 0).astype(np.float32))


def _letterbox(img, size: int):
    """Resize keeping aspect ratio and pad with 114 (YOLOX's own preprocessing:
    BGR order, CHW, float32, no mean/std normalisation)."""
    import cv2

    h, w = img.shape[:2]
    r = min(size / h, size / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    canvas = np.full((size, size, 3), 114, dtype=np.uint8)
    canvas[:nh, :nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    blob = canvas.transpose(2, 0, 1)[None].astype(np.float32)
    return np.ascontiguousarray(blob), r


def _decode(out, grids, strides, ratio, w, h, score_thr, nms_thr):
    import cv2

    # out: (N, 85) = cx, cy, w, h (grid-relative), objectness, 80 class scores
    xy = (out[:, :2] + grids) * strides
    wh = np.exp(out[:, 2:4]) * strides
    scores = out[:, 4] * out[:, 5 + PERSON_CLASS]
    keep = scores >= score_thr
    if not np.any(keep):
        return []
    xy, wh, scores = xy[keep], wh[keep], scores[keep]
    x1y1 = (xy - wh / 2) / ratio
    boxes_xywh = np.concatenate([x1y1, wh / ratio], 1)
    idx = cv2.dnn.NMSBoxes(boxes_xywh.tolist(), scores.tolist(),
                           score_thr, nms_thr)
    dets = []
    for i in np.array(idx).reshape(-1):
        bx, by, bw, bh = boxes_xywh[i]
        dets.append(Detection(
            x1=float(np.clip(bx / w, 0, 1)), y1=float(np.clip(by / h, 0, 1)),
            x2=float(np.clip((bx + bw) / w, 0, 1)),
            y2=float(np.clip((by + bh) / h, 0, 1)),
            score=float(scores[i])))
    return dets


def load_detector(model_path: Optional[str] = None, score_thr: float = 0.45,
                  threads: int = 2):
    """Return a working YOLOX detector, or a NullDetector (motion_only) with the
    reason logged. Never raises: detection must degrade, not crash."""
    path = model_path or model_fetch.find_model()
    if not path:
        log.warning("person model not found; running in motion_only mode")
        return NullDetector()
    if not model_fetch.verify_sha256(path):
        log.warning("person model failed its SHA-256 check; motion_only mode")
        return NullDetector()
    try:
        det = YoloxPersonDetector(path, score_thr=score_thr, threads=threads)
    except Exception as exc:  # onnxruntime missing / corrupt model / bad CPU
        log.warning("person model could not be loaded (%s); motion_only mode",
                    type(exc).__name__)
        return NullDetector()
    log.info("person detector ready: %s", det.name)
    return det
