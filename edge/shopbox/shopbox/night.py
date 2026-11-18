"""cctvacc: night mode for the person check — the SAME rule on the phone
(GuardBoxChannel.kt, on the bitmap it already scales for the model) and here.

A frame is "night" when it is grey (the camera's IR night mode: mean colour
spread max(R,G,B)-min(R,G,B) below NIGHT_SPREAD_MAX) or dark (mean luma below
NIGHT_LUMA_MAX). Night frames use PERSON_SCORE_NIGHT; day frames keep
PERSON_SCORE_DAY. The night value was picked on a CALIBRATION half of the
night test set only and is reported on the held-out half plus a second,
differently simulated night set (tools/e2e/cctv_accuracy.py, CI).
Constants are asserted equal to shopbox/cctv_thresholds.json.

cctvacc2: night frames are also ENHANCED before the model (NIGHT_PRE:
"clahe" = contrast-limited adaptive histogram equalisation on the luma of
the 416-px image, 8 x 8 tiles, clip NIGHT_CLAHE_CLIP; "gamma" = one global
curve that lifts the mean luma to NIGHT_GAMMA_TARGET; "none"), and a night
person counts only when NIGHT_CONFIRM checked frames in a row (about 0.3 to
1 s apart) both see one. Pure integer / float64 maths so the phone
(GuardBoxChannel.kt enhanceNight) computes the same pixels. Picked on the
calibration half of night_ir by tools/e2e/cctv_accuracy.py (CI).
"""
from __future__ import annotations

import numpy as np

PERSON_SCORE_DAY = 0.45
PERSON_SCORE_NIGHT = 0.30
NIGHT_SIDE = 416
# cctv-accuracy (18 Nov): 10 -> 3. On REAL clips (tools/cctvacc, CI) every
# IR night camera has a colour spread of exactly 0.0, but grey DAYLIGHT
# (rain, overcast street, rain on the lens) is 3.4-9.8 — with 10 those day
# pictures were treated as IR night (lower threshold, the 2-check night rule).
NIGHT_SPREAD_MAX = 3.0
NIGHT_LUMA_MAX = 40.0
NIGHT_PRE = "clahe"
NIGHT_CLAHE_CLIP = 2.0
NIGHT_CLAHE_TILES = 8
NIGHT_GAMMA_TARGET = 0.45
NIGHT_CONFIRM = 2
NIGHT_CONFIRM_GAP_S = 2.0


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


# ------------------------------------------------------------ cctvacc2
def fit_side(frame_bgr):
    """The frame scaled to fit NIGHT_SIDE (what the model sees, unpadded)."""
    import cv2

    h, w = frame_bgr.shape[:2]
    r = min(NIGHT_SIDE / h, NIGHT_SIDE / w, 1.0)
    if r < 1.0:
        return cv2.resize(frame_bgr, (max(1, round(w * r)), max(1, round(h * r))),
                          interpolation=cv2.INTER_AREA)
    return frame_bgr


def luma_u8(img_bgr) -> np.ndarray:
    """Integer luma, the same formula as the phone: (299R + 587G + 114B + 500) / 1000."""
    f = img_bgr.astype(np.int64)
    return (299 * f[..., 2] + 587 * f[..., 1] + 114 * f[..., 0] + 500) // 1000


def clahe_lut(y: np.ndarray, clip: float = None, tiles: int = None) -> np.ndarray:
    """Per-tile 256-entry LUTs (tiles x tiles x 256) of a uint8 luma image."""
    clip = NIGHT_CLAHE_CLIP if clip is None else clip
    t = NIGHT_CLAHE_TILES if tiles is None else tiles
    h, w = y.shape
    luts = np.zeros((t, t, 256), dtype=np.int64)
    for ty in range(t):
        y0, y1 = (ty * h) // t, ((ty + 1) * h) // t
        for tx in range(t):
            x0, x1 = (tx * w) // t, ((tx + 1) * w) // t
            area = max(1, (y1 - y0) * (x1 - x0))
            hist = np.bincount(y[y0:y1, x0:x1].ravel(), minlength=256).astype(np.int64)
            limit = max(1, int(clip * area / 256.0))
            excess = int(np.maximum(hist - limit, 0).sum())
            hist = np.minimum(hist, limit) + excess // 256
            hist[: excess % 256] += 1
            luts[ty, tx] = np.minimum(255, (np.cumsum(hist) * 255) // area)
    return luts


def clahe(y: np.ndarray, clip: float = None, tiles: int = None) -> np.ndarray:
    """Bilinear blend of the 4 nearest tile LUTs (float64, then +0.5 floor)."""
    t = NIGHT_CLAHE_TILES if tiles is None else tiles
    h, w = y.shape
    luts = clahe_lut(y, clip, t)

    def axis(n):
        pos = (np.arange(n) + 0.5) * t / n - 0.5
        i0 = np.clip(np.floor(pos), 0, t - 1).astype(np.int64)
        i1 = np.minimum(i0 + 1, t - 1)
        a = np.clip(pos - i0, 0.0, 1.0)
        a[pos < 0] = 0.0
        return i0, i1, a

    yi0, yi1, ay = axis(h)
    xi0, xi1, ax = axis(w)
    v = y.astype(np.int64)
    Y0, X0 = yi0[:, None], xi0[None, :]
    Y1, X1 = yi1[:, None], xi1[None, :]
    a = ax[None, :]
    b = ay[:, None]
    top = (1 - a) * luts[Y0, X0, v] + a * luts[Y0, X1, v]
    bot = (1 - a) * luts[Y1, X0, v] + a * luts[Y1, X1, v]
    return np.floor((1 - b) * top + b * bot + 0.5).astype(np.int64)


def gamma_curve(y: np.ndarray) -> np.ndarray:
    m = max(1.0, float(y.mean()))
    if m / 255.0 >= NIGHT_GAMMA_TARGET:
        return y.astype(np.int64)
    g = max(0.35, min(1.0, np.log(NIGHT_GAMMA_TARGET) / np.log(m / 255.0)))
    lut = np.floor(255.0 * np.power(np.arange(256) / 255.0, g) + 0.5).astype(np.int64)
    return lut[y]


def enhance(img_bgr, pre: str = None) -> np.ndarray:
    """Night enhancement of an image ALREADY fit to NIGHT_SIDE: the new luma
    Y' is computed, then each channel c -> min(255, floor(c * (Y'+1) / (Y+1) + 0.5))."""
    pre = NIGHT_PRE if pre is None else pre
    if pre == "none" or img_bgr is None or img_bgr.size == 0:
        return img_bgr
    if img_bgr.ndim == 2:
        img_bgr = np.repeat(img_bgr[..., None], 3, axis=2)
    y = luma_u8(img_bgr)
    y2 = clahe(y) if pre == "clahe" else gamma_curve(y)
    k = (y2 + 1.0) / (y + 1.0)
    out = np.floor(img_bgr.astype(np.float64) * k[..., None] + 0.5)
    return np.minimum(255, out).astype(np.uint8)


def model_input(frame_bgr, pre: str = None):
    """(image for the detector, night?) — a night frame is fit to 416 and
    enhanced, exactly as the phone does on its model-input bitmap; a day
    frame is returned unchanged."""
    if frame_bgr is None or frame_bgr.size == 0:
        return frame_bgr, False
    if not is_night(frame_bgr):
        return frame_bgr, False
    pre = NIGHT_PRE if pre is None else pre
    if pre == "none":
        return frame_bgr, True
    return enhance(fit_side(frame_bgr), pre), True


class NightConfirm:
    """A night person counts only when NIGHT_CONFIRM checks in a row (each
    at most NIGHT_CONFIRM_GAP_S apart) saw one. Day checks pass at once."""

    def __init__(self, frames: int = None, gap_s: float = None):
        self.frames = NIGHT_CONFIRM if frames is None else int(frames)
        self.gap_s = NIGHT_CONFIRM_GAP_S if gap_s is None else float(gap_s)
        self.hits = 0
        self.last = None

    def check(self, found: bool, night: bool, now: float) -> bool:
        if not night or self.frames <= 1:
            self.hits, self.last = 0, None
            return bool(found)
        if not found:
            self.hits, self.last = 0, None
            return False
        if self.last is not None and now - self.last <= self.gap_s:
            self.hits += 1
        else:
            self.hits = 1
        self.last = now
        return self.hits >= self.frames

    @property
    def pending(self) -> bool:
        return 0 < self.hits < self.frames
