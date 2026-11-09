"""cctvacc: night mode for the person check — the SAME rule on the phone
(GuardBoxChannel.kt, on the bitmap it already scales for the model) and here.

A frame is "night" when it is grey (the camera's IR night mode: mean colour
spread max(R,G,B)-min(R,G,B) below NIGHT_SPREAD_MAX) or dark (mean luma below
NIGHT_LUMA_MAX). Night frames use PERSON_SCORE_NIGHT; day frames keep
PERSON_SCORE_DAY. The night value was picked on a CALIBRATION half of the
night test set only and is reported on the held-out half plus a second,
differently simulated night set (tools/e2e/cctv_accuracy.py, CI).
Constants are asserted equal to shopbox/cctv_thresholds.json.
"""
from __future__ import annotations

import numpy as np

PERSON_SCORE_DAY = 0.45
PERSON_SCORE_NIGHT = 0.30
NIGHT_SIDE = 416
NIGHT_SPREAD_MAX = 10.0
NIGHT_LUMA_MAX = 40.0


def frame_stats(frame_bgr):
    """(mean colour spread, mean luma) on the frame scaled to fit 416 x 416
    (what the phone measures on its model-input bitmap)."""
    import cv2

    if frame_bgr is None or frame_bgr.size == 0:
        return 0.0, 0.0
    if frame_bgr.ndim == 2:
        g = frame_bgr
        h, w = g.shape
        r = min(NIGHT_SIDE / h, NIGHT_SIDE / w, 1.0)
        if r < 1.0:
            g = cv2.resize(g, (max(1, round(w * r)), max(1, round(h * r))),
                           interpolation=cv2.INTER_AREA)
        return 0.0, float(g.mean())
    h, w = frame_bgr.shape[:2]
    r = min(NIGHT_SIDE / h, NIGHT_SIDE / w, 1.0)
    img = frame_bgr
    if r < 1.0:
        img = cv2.resize(frame_bgr, (max(1, round(w * r)), max(1, round(h * r))),
                         interpolation=cv2.INTER_AREA)
    f = img.astype(np.float32)
    spread = float((f.max(axis=2) - f.min(axis=2)).mean())
    luma = float((0.114 * f[..., 0] + 0.587 * f[..., 1] + 0.299 * f[..., 2]).mean())
    return spread, luma


def is_night(frame_bgr) -> bool:
    spread, luma = frame_stats(frame_bgr)
    return spread < NIGHT_SPREAD_MAX or luma < NIGHT_LUMA_MAX


def person_threshold(frame_bgr, day: float = PERSON_SCORE_DAY,
                     night: float = PERSON_SCORE_NIGHT) -> float:
    return float(night) if is_night(frame_bgr) else float(day)
