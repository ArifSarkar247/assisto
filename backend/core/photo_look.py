"""
photo_look.py — photo-final: the "look" stage of HD enhance, the part that
makes a portrait visibly better (owner compared Remini: sharp face, natural
smooth skin, warm bright tone, portrait background blur; ours looked almost
unchanged). Runs on our photo worker (numpy + OpenCV, no new model weights):

  auto_tone      exposure lift for UNDER-exposed photos only (global median,
                 never the skin -> no whitening), gentle levels, CLAHE local
                 contrast on L, partial grey-world white balance + a little
                 warmth, vibrance that spares skin.
  face_crisp     Real-ESRGAN (BSD-3) on each face crop at a small size
                 (<= 192 px) -> clean, crisp face detail, luminance only,
                 blended inside the face ellipse (fidelity = preset weight).
                 Not a GAN face prior (no licence-clean one exists); FACE LOCK
                 checks identity afterwards.
  skin_smooth    edge-preserving (bilateral) smoothing on a SKIN mask inside
                 the face regions, eyes/brows/mouth excluded, 30-40 % of the
                 fine texture added back -> natural, never "plastic"; colour
                 and lightness of the skin are not changed.
  bg_blur        portrait background blur from the U^2-Net-p mask (Apache-2.0,
                 already shipped), faces forced into the subject, normalised
                 blur so the subject never bleeds into the background.
  detail         denoise (only when the photo is noisy) + luminance unsharp.

Presets: "natural" (default) and "strong". Every step is optional and
reports what it did; nothing here can change who the person is.
"""
import math

import numpy as np

PRESETS = {
    "natural": {"gain": 1.20, "gamma_min": 0.80, "clahe": 1.3, "clahe_mix": 0.45,
                "wb": 0.45, "warm": 1.5, "vib": 0.10, "crisp": 0.45, "skin": 0.45,
                "keep_tex": 0.40, "blur_sigma": 0.010, "sharp": 0.30, "dn": 1.0},
    "strong": {"gain": 1.40, "gamma_min": 0.68, "clahe": 1.9, "clahe_mix": 0.65,
               "wb": 0.65, "warm": 3.0, "vib": 0.18, "crisp": 0.62, "skin": 0.62,
               "keep_tex": 0.32, "blur_sigma": 0.018, "sharp": 0.50, "dn": 1.4},
}
CRISP_SIDE = 192
MAX_FACES = 6


def _cv2():
    import cv2
    return cv2


def _u8(rgb):
    return (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)


def _f32(u8):
    return u8.astype(np.float32) / 255.0


def luma(rgb):
    return rgb @ np.asarray([0.299, 0.587, 0.114], dtype=np.float32)


def face_ellipses(shape, faces, grow=1.0, soft=0.35):
    """0..1 mask of soft ellipses around the face boxes."""
    h, w = shape[:2]
    m = np.zeros((h, w), np.float32)
    for f in faces[:MAX_FACES * 2]:
        x, y, bw, bh = f["box"]
        cx, cy = x + bw / 2, y + bh / 2 + bh * 0.05
        rx, ry = bw * 0.55 * grow, bh * 0.68 * grow
        x0, x1 = max(0, int(cx - rx * 1.4)), min(w, int(cx + rx * 1.4) + 1)
        y0, y1 = max(0, int(cy - ry * 1.4)), min(h, int(cy + ry * 1.4) + 1)
        if x1 <= x0 or y1 <= y0:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
        d = np.sqrt(((xx - cx) / max(rx, 1)) ** 2 + ((yy - cy) / max(ry, 1)) ** 2)
        t = np.clip((1.0 - d) / soft + 1.0, 0, 1)
        t = t * t * (3 - 2 * t)
        m[y0:y1, x0:x1] = np.maximum(m[y0:y1, x0:x1], t)
    return m


# ------------------------------------------------------------------ tone
def auto_tone(rgb, p):
    cv2 = _cv2()
    out = rgb.astype(np.float32)
    y = luma(out)
    lo, hi = np.percentile(y, [0.5, 99.5])
    gain = min(p["gain"], 1.0 / max(0.05, hi - lo))
    if gain > 1.02:
        out = (out - lo) * gain
    out = np.clip(out, 0, 1)
    # exposure: only under-exposed scenes are lifted (global median, not skin)
    med = float(np.median(luma(out)))
    if 0.02 < med < 0.40:
        g = max(p["gamma_min"], math.log(0.42) / math.log(med))
        out = np.power(out, g)
    # local contrast (CLAHE on L) + white balance + warmth in Lab
    lab = cv2.cvtColor(_u8(out), cv2.COLOR_RGB2LAB)
    L = lab[..., 0]
    cl = cv2.createCLAHE(clipLimit=p["clahe"], tileGridSize=(8, 8)).apply(L)
    L2 = (L.astype(np.float32) * (1 - p["clahe_mix"]) + cl.astype(np.float32) * p["clahe_mix"])
    a = lab[..., 1].astype(np.float32)
    b = lab[..., 2].astype(np.float32)
    # partial grey-world on the bright-ish, low-chroma pixels only
    chroma = np.hypot(a - 128, b - 128)
    sel = (chroma < 18) & (L > 60)
    if sel.mean() > 0.02:
        a -= (float(a[sel].mean()) - 128) * p["wb"]
        b -= (float(b[sel].mean()) - 128) * p["wb"]
    b += p["warm"]
    a += p["warm"] * 0.25
    lab2 = np.dstack([np.clip(L2, 0, 255), np.clip(a, 0, 255), np.clip(b, 0, 255)]).astype(np.uint8)
    out = _f32(cv2.cvtColor(lab2, cv2.COLOR_LAB2RGB))
    return out


def vibrance(rgb, p, skin=None):
    mx = rgb.max(axis=2, keepdims=True)
    mn = rgb.min(axis=2, keepdims=True)
    sat = mx - mn
    amt = p["vib"] * (1.0 - np.clip(sat * 2.0, 0, 1))
    if skin is not None:
        amt = amt * (1.0 - 0.7 * skin[..., None])
    y = luma(rgb)[..., None]
    return np.clip(y + (rgb - y) * (1.0 + amt), 0, 1)


# ------------------------------------------------------------------ skin
def skin_mask(rgb, faces):
    """Skin pixels (YCrCb range wide enough for dark and light skin) inside
    the grown face regions, minus eyes / mouth. 0..1, feathered."""
    cv2 = _cv2()
    if not faces:
        return None
    region = face_ellipses(rgb.shape, faces, grow=1.25)
    if region.max() <= 0:
        return None
    ycc = cv2.cvtColor(_u8(rgb), cv2.COLOR_RGB2YCrCb).astype(np.float32)
    cr, cb = ycc[..., 1], ycc[..., 2]
    sk = ((cr > 132) & (cr < 182) & (cb > 76) & (cb < 135)).astype(np.float32)
    m = sk * region
    for f in faces[:MAX_FACES * 2]:
        bw = f["box"][2]
        pts = f.get("pts") or []
        for i, (px, py) in enumerate(pts[:5]):
            if i == 2:      # nose tip: keep smoothing there
                continue
            r = max(3, int(bw * (0.13 if i < 2 else 0.11)))
            cv2.circle(m, (int(px), int(py)), r, 0.0, -1)
        if len(pts) >= 5:   # mouth band between the corners
            (lx, ly), (rx, ry) = pts[3], pts[4]
            cv2.ellipse(m, (int((lx + rx) / 2), int((ly + ry) / 2)),
                        (max(3, int(abs(rx - lx) * 0.65)), max(3, int(bw * 0.09))),
                        0, 0, 360, 0.0, -1)
    k = max(3, int(max(rgb.shape[:2]) * 0.006) | 1)
    return cv2.GaussianBlur(m, (k, k), 0)


def skin_smooth(rgb, faces, p, mask=None):
    cv2 = _cv2()
    m = mask if mask is not None else skin_mask(rgb, faces)
    if m is None or m.max() <= 0:
        return rgb, 0.0
    fw = max(f["box"][2] for f in faces)
    sig_s = max(2.0, fw / 45.0)
    src = _u8(rgb)
    sm = _f32(cv2.bilateralFilter(src, d=0, sigmaColor=16, sigmaSpace=sig_s))
    # put fine texture back (pores, stubble) -> natural, not plastic
    k = max(3, int(fw / 90) * 2 + 1)
    fine = rgb - _f32(cv2.GaussianBlur(src, (k, k), 0))
    sm = sm + fine * p["keep_tex"]
    w = (m * p["skin"])[..., None]
    return np.clip(rgb * (1 - w) + sm * w, 0, 1), float(m.mean())


# ------------------------------------------------------------------ face crisp
def face_crisp(out, faces, up_sess, p, upscale_x4):
    """Real-ESRGAN detail on each face, luminance only, inside the ellipse."""
    cv2 = _cv2()
    if up_sess is None or not faces:
        return out, 0
    H, W = out.shape[:2]
    done = 0
    k = np.asarray([0.299, 0.587, 0.114], dtype=np.float32)
    for f in faces[:MAX_FACES]:
        x, y, bw, bh = f["box"]
        if min(bw, bh) < 16:
            continue
        cx, cy, r = x + bw / 2, y + bh / 2, max(bw, bh) * 0.8
        x0, y0 = max(0, int(cx - r)), max(0, int(cy - r))
        x1, y1 = min(W, int(cx + r)), min(H, int(cy + r))
        crop = out[y0:y1, x0:x1]
        ch, cw = crop.shape[:2]
        if min(ch, cw) < 16:
            continue
        s = min(1.0, CRISP_SIDE / max(ch, cw))
        small = cv2.resize(crop, (max(8, round(cw * s)), max(8, round(ch * s))),
                           interpolation=cv2.INTER_AREA) if s < 1 else crop
        ai = upscale_x4(small, up_sess)
        ai = cv2.resize(ai, (cw, ch), interpolation=cv2.INTER_AREA if ai.shape[1] > cw
                        else cv2.INTER_CUBIC)
        ell = face_ellipses(crop.shape, [{"box": [x - x0, y - y0, bw, bh]}], grow=1.05)
        wgt = ell * p["crisp"]
        dy = ((ai @ k) - (crop @ k)) * wgt
        out[y0:y1, x0:x1] = np.clip(crop + dy[..., None], 0, 1)
        done += 1
    return out, done


# ------------------------------------------------------------------ background
def subject_mask(rgb, seg_sess, faces):
    """U^2-Net-p (320x320, ImageNet norm, min-max output) -> 0..1 mask at
    full size; faces always count as subject. None if the mask is not usable."""
    cv2 = _cv2()
    if seg_sess is None:
        return None
    h, w = rgb.shape[:2]
    x = cv2.resize(rgb, (320, 320), interpolation=cv2.INTER_AREA)
    x = (x - np.asarray([0.485, 0.456, 0.406], np.float32)) / np.asarray([0.229, 0.224, 0.225], np.float32)
    inp = x.transpose(2, 0, 1)[None].astype(np.float32)
    name = seg_sess.get_inputs()[0].name
    o = seg_sess.run(None, {name: inp})[0]
    o = np.asarray(o, np.float32).reshape(o.shape[-2], o.shape[-1])
    o = (o - o.min()) / max(1e-6, float(o.max() - o.min()))
    m = cv2.resize(o, (w, h), interpolation=cv2.INTER_LINEAR)
    m = np.clip((m - 0.35) / 0.3, 0, 1)
    if faces:
        m = np.maximum(m, face_ellipses(rgb.shape, faces, grow=1.1))
    frac = float(m.mean())
    if frac < 0.03 or frac > 0.88:
        return None
    k = max(3, int(max(h, w) * 0.008) | 1)
    return cv2.GaussianBlur(m, (k, k), 0)


def bg_blur(rgb, mask, p):
    cv2 = _cv2()
    if mask is None:
        return rgb, False
    sig = max(1.5, max(rgb.shape[:2]) * p["blur_sigma"])
    bgw = (1.0 - mask)[..., None]
    num = cv2.GaussianBlur(rgb * bgw, (0, 0), sig)
    den = cv2.GaussianBlur(bgw, (0, 0), sig)
    if den.ndim == 2:
        den = den[..., None]
    blurred = np.where(den > 1e-3, num / np.maximum(den, 1e-3), rgb)
    m = mask[..., None]
    return np.clip(rgb * m + blurred * (1 - m), 0, 1).astype(np.float32), True


# ------------------------------------------------------------------ detail
def noise_sigma(rgb):
    y = luma(rgb)
    hp = y[1:-1, 1:-1] * 4 - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:]
    return float(np.median(np.abs(hp)) * 1.4826 / math.sqrt(20))


def detail(rgb, p):
    cv2 = _cv2()
    out = rgb
    sig = noise_sigma(rgb)
    den = False
    if sig > 0.012:
        h = min(9.0, sig * 255 * 0.9 * p["dn"])
        out = _f32(cv2.fastNlMeansDenoisingColored(_u8(rgb), None, h, h, 5, 15))
        den = True
    blur = cv2.GaussianBlur(out, (0, 0), max(1.0, max(out.shape[:2]) / 900.0))
    k = np.asarray([0.299, 0.587, 0.114], dtype=np.float32)
    dy = ((out - blur) @ k) * p["sharp"]
    return np.clip(out + dy[..., None], 0, 1), {"denoise": den, "noise": round(sig, 4)}


def keep_face_tone(before, after, faces, max_lift=1.03):
    """Skin tone guard: after the global tone pass a face may come out darker
    (contrast) or lighter (exposure). Its mean lightness is brought back to
    within [0.98, max_lift] x the original — never whitened, never darkened."""
    if not faces:
        return after, 1.0
    m = face_ellipses(after.shape, faces, grow=1.0)
    sel = m > 0.6
    if sel.sum() < 50:
        return after, 1.0
    yb = float(luma(before)[sel].mean())
    ya = float(luma(after)[sel].mean())
    if ya <= 1e-4:
        return after, 1.0
    # the face may follow the WHOLE scene's exposure change (a dark photo gets
    # lighter everywhere) but never more — skin is not lightened on its own
    g = float(luma(after).mean()) / max(1e-4, float(luma(before).mean()))
    lo, hi = 0.98 * min(1.0, g), max(max_lift, g)
    q = ya / max(yb, 1e-4)
    k = lo / q if q < lo else (hi / q if q > hi else 1.0)
    if abs(k - 1.0) < 0.005:
        return after, 1.0
    wgt = face_ellipses(after.shape, faces, grow=1.35, soft=0.6)[..., None]
    out = np.clip(after * (1 + (k - 1) * wgt), 0, 1).astype(np.float32)
    return out, round(k, 3)


# ------------------------------------------------------------------ entry
def apply(rgb, faces, *, preset="natural", up_sess=None, seg_sess=None, blur=False,
          upscale_x4=None, crisp=True):
    """The whole look stage. Returns (rgb float32, report)."""
    p = PRESETS.get(preset, PRESETS["natural"])
    rep = {"preset": preset if preset in PRESETS else "natural"}
    out, rep["detail"] = detail(rgb.astype(np.float32), p)
    if crisp and upscale_x4 is not None:
        out, rep["faces_crisp"] = face_crisp(out, faces, up_sess, p, upscale_x4)
    sk = skin_mask(out, faces)
    out, rep["skin_area"] = skin_smooth(out, faces, p, mask=sk)
    before = out
    out = auto_tone(out, p)
    out = vibrance(out, p, skin=sk)
    out, rep["face_tone"] = keep_face_tone(before, out, faces)
    rep["bg_blur"] = False
    if blur and faces:
        out, rep["bg_blur"] = bg_blur(out, subject_mask(out, seg_sess, faces), p)
    return out.astype(np.float32), rep
