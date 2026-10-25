"""
photo_restore.py — d1-photo: the HEAVY Photo Studio restore jobs.

Where each job runs (decided by MEASURED speed on this server, a 2-vCPU
t3.large-class box without GPU — .phaseB/D1_EVAL.md):

  colorize     OUR server CPU: DDColor-tiny (Apache-2.0 code + weights) as a
               fixed 512x512 ONNX graph, ~3.4 s per photo. Only the colour
               (Lab a/b) comes from the model; the photo's own lightness L is
               kept pixel for pixel, so a face cannot change shape.
  old_restore  OUR server CPU: scratch/dust cleanup (median-based, ours) ->
               Real-ESRGAN general x4v3 (BSD-3) tiled at <= 512 px input for
               denoise + detail (luminance only, faces get 25 % = face-lock) ->
               optional DDColor colour for black & white photos (coloured
               at 512 px BEFORE the x4 detail step). ~9 s, ~15 s with colour.
  deblur       NAFNet (MIT) is 16 s at 768x576 and 69 s at 1024x768 on this
               CPU (> 20 s): it runs ONLY on a pay-per-use GPU API (Replicate)
               behind the Admin key `photo_restore_gpu`, hidden until the
               owner connects it and sets the cost per run.
  face restore NOT offered: no licence-clean model (GFPGAN weights /
               CodeFormer are non-commercial) — see .phaseB/MODEL_LICENSES.md.

Money: decided BEFORE we get here (photo_studio_service.quote/create_job:
ads or credits taken, Profit Guard: never a loss). This module only computes
pixels or raises RestoreError — never a fake result. One heavy job at a time
per server (file lock) so the live API stays responsive.
"""
import base64
import contextlib
import fcntl
import io
import json
import math
import os
import time

from django.conf import settings

GPU_SLUG = "photo_restore_gpu"
SERVER_FEATURES = ("colorize", "old_restore", "enhance_server")
GPU_FEATURES = ("deblur",)
FEATURES = SERVER_FEATURES + GPU_FEATURES

MAX_SIDE_IN = 4096          # decoded input long edge cap (memory)
RESTORE_INPUT_LONG = 512    # Real-ESRGAN input for old photos (<= 12 tiles, ~8.5 s here)
RESTORE_OUT_LONG = 2048
COLOR_OUT_LONG = 2048
DD_SIDE = 512
LOCK_WAIT_S = 25
GPU_TIMEOUT_S = 90
DEFAULT_DEBLUR_TASK = "Image Debluring (GoPro)"


class RestoreError(Exception):
    """A real failure (the caller keeps the job funded for a retry)."""


class RestoreBusy(RestoreError):
    pass


# ------------------------------------------------------------------ status
def _runtime_ok():
    try:
        import numpy  # noqa: F401
        import onnxruntime  # noqa: F401
        from PIL import Image  # noqa: F401
        return True
    except Exception:
        return False


def _gpu_conf():
    from . import integrations
    try:
        if not integrations.is_enabled(GPU_SLUG):
            return None
        return integrations.get(GPU_SLUG) or {}
    except Exception:
        return None


def _num(v):
    try:
        return max(0.0, float(v or 0))
    except (TypeError, ValueError):
        return 0.0


def status(feature, lang="bn"):
    """{ready, where, cost_usd, needs} — honest, no side effects."""
    from .i18n import pick
    from . import photo_models as PM
    if feature in SERVER_FEATURES + GPU_FEATURES:
        from . import photo_worker
        if not photo_worker.enabled():
            return {"ready": False, "where": "worker", "cost_usd": 0.0,
                    "needs": pick(lang, "ফটো ওয়ার্কার সার্ভিস চালু হয়নি (deploy/photo_worker/install.sh)।",
                                  "The photo worker service is not installed (deploy/photo_worker/install.sh).")}
    if feature in SERVER_FEATURES:
        if not _runtime_ok():
            return {"ready": False, "where": "server", "cost_usd": 0.0,
                    "needs": pick(lang, "সার্ভারে onnxruntime ইনস্টল করতে হবে (pip install onnxruntime)।",
                                  "Install onnxruntime on the server (pip install onnxruntime).")}
        # photo-final: with Real-ESRGAN not cleared (realesrgan_allowed off)
        # enhance + old-photo restore run the clean non-ML path instead
        up = ("upscale",) if PM.realesrgan_allowed() else ()
        need = {"colorize": ("server_colorize",), "old_restore": up,
                "enhance_server": up + ("server_face",)}[feature]
        if feature == "enhance_server":
            try:
                import cv2  # noqa: F401  (YuNet face detection + seamless paste)
            except Exception:
                return {"ready": False, "where": "server", "cost_usd": 0.0,
                        "needs": pick(lang, "সার্ভারে opencv-python-headless ইনস্টল করতে হবে।",
                                      "Install opencv-python-headless on the server.")}
        if not all(PM.server_model(r) for r in need):
            return {"ready": False, "where": "server", "cost_usd": 0.0,
                    "needs": pick(lang, "সার্ভারে মডেল ইনস্টল হয়নি (tools/photo_model/install_d1_models.py)।",
                                  "The server model is not installed (tools/photo_model/install_d1_models.py).")}
        return {"ready": True, "where": "server", "cost_usd": 0.0, "needs": ""}
    if feature in GPU_FEATURES:
        conf = _gpu_conf()
        cost = _num((conf or {}).get("cost_per_run_usd"))
        if conf is None or not (conf.get("api_token") and conf.get("deblur_version")) or cost <= 0:
            return {"ready": False, "where": "gpu", "cost_usd": cost,
                    "needs": pick(lang, "Integrations-এ GPU key (Replicate), NAFNet মডেল version ও প্রতি কাজের খরচ দিন।",
                                  "Add the GPU key (Replicate), the NAFNet model version and the cost per run in Integrations.")}
        return {"ready": True, "where": "gpu", "cost_usd": cost, "needs": ""}
    return {"ready": False, "where": "", "cost_usd": 0.0, "needs": ""}


# ------------------------------------------------------------------ one at a time
@contextlib.contextmanager
def _heavy_lock(wait_s=LOCK_WAIT_S):
    d = os.path.join(str(settings.MEDIA_ROOT), "photo_studio")
    os.makedirs(d, exist_ok=True)
    fh = open(os.path.join(d, ".restore.lock"), "w")
    t0 = time.monotonic()
    try:
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() - t0 > wait_s:
                    raise RestoreBusy("busy")
                time.sleep(0.25)
        yield
    finally:
        with contextlib.suppress(Exception):
            fcntl.flock(fh, fcntl.LOCK_UN)
        fh.close()


# ------------------------------------------------------------------ image helpers
def _decode(raw):
    import numpy as np
    from PIL import Image, ImageOps
    try:
        im = Image.open(io.BytesIO(raw))
        im = ImageOps.exif_transpose(im).convert("RGB")
    except Exception:
        raise RestoreError("decode")
    if max(im.size) > MAX_SIDE_IN:
        im.thumbnail((MAX_SIDE_IN, MAX_SIDE_IN), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def _encode(rgb):
    """JPEG q95 (a 3 MP PNG took 1.6 s to write on this CPU; JPEG ~0.1 s)."""
    import numpy as np
    from PIL import Image
    im = Image.fromarray((np.clip(rgb, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGB")
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=95, subsampling=0)
    return buf.getvalue()


def _resize(rgb, w, h):
    import numpy as np
    from PIL import Image
    chans = [np.asarray(Image.fromarray(rgb[..., c].astype(np.float32), "F").resize(
        (w, h), Image.BICUBIC), dtype=np.float32) for c in range(rgb.shape[2])]
    return np.clip(np.stack(chans, axis=-1), 0, 1)


def _fit(rgb, long_max):
    h, w = rgb.shape[:2]
    if max(w, h) <= long_max:
        return rgb
    f = long_max / max(w, h)
    return _resize(rgb, max(1, round(w * f)), max(1, round(h * f)))


# ---- sRGB <-> CIE Lab (D65), same convention as OpenCV's float COLOR_RGB2Lab
_M = ((0.412453, 0.357580, 0.180423),
      (0.212671, 0.715160, 0.072169),
      (0.019334, 0.119193, 0.950227))
_WX, _WZ = 0.950456, 1.088754


def rgb_to_lab(rgb):
    import numpy as np
    c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m = np.asarray(_M, dtype=np.float32)
    xyz = c @ m.T
    x, y, z = xyz[..., 0] / _WX, xyz[..., 1], xyz[..., 2] / _WZ

    def f(t):
        return np.where(t > 0.008856, np.cbrt(t), 7.787 * t + 16.0 / 116.0)
    fx, fy, fz = f(x), f(y), f(z)
    L = np.where(y > 0.008856, 116.0 * np.cbrt(y) - 16.0, 903.3 * y)
    return np.stack([L, 500.0 * (fx - fy), 200.0 * (fy - fz)], axis=-1).astype(np.float32)


def lab_to_rgb(lab):
    import numpy as np
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16.0) / 116.0
    fx, fz = fy + a / 500.0, fy - b / 200.0

    def finv(t):
        return np.where(t > 0.206893, t ** 3, (t - 16.0 / 116.0) / 7.787)
    y = np.where(L > 7.9996, fy ** 3, L / 903.3)
    xyz = np.stack([finv(fx) * _WX, y, finv(fz) * _WZ], axis=-1)
    minv = np.linalg.inv(np.asarray(_M, dtype=np.float64)).astype(np.float32)
    c = np.clip(xyz @ minv.T, 0, 1)
    rgb = np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1 / 2.4) - 0.055)
    return np.clip(rgb, 0, 1).astype(np.float32)


def is_grey(rgb, thr=0.06, tone_thr=3.0):
    """Black & white or one-tone (sepia / faded) photo?

    Either the chroma is tiny, or the colour is (almost) a FUNCTION of the
    lightness — a sepia print has a/b that follow L, a real colour photo does
    not. Residual std of a, b after a linear fit on L < `tone_thr` (Lab
    units) = monochrome."""
    import numpy as np
    small = rgb[::4, ::4] if min(rgb.shape[:2]) > 64 else rgb
    if float(np.mean(small.max(axis=-1) - small.min(axis=-1))) < thr:
        return True
    lab = rgb_to_lab(small).reshape(-1, 3).astype(np.float64)
    X = np.stack([lab[:, 0], np.ones(len(lab))], axis=1)
    for ch in (1, 2):
        coef, *_ = np.linalg.lstsq(X, lab[:, ch], rcond=None)
        if float(np.std(lab[:, ch] - X @ coef)) >= tone_thr:
            return False
    return True


def restore_levels(rgb, lo_pct=1.0, hi_pct=99.0, max_gain=1.6):
    """Faded old prints: stretch the lightness to its 1 / 99 % points (at
    most 1.6x, never inverted). Lightness only — no geometry change."""
    import numpy as np
    y = luma_of(rgb)
    lo, hi = np.percentile(y, [lo_pct, hi_pct])
    span = max(float(hi - lo), 1.0 / max_gain)
    gain = 1.0 / span
    y2 = np.clip((y - lo) * gain, 0, 1)
    return np.clip(rgb + (y2 - y)[..., None], 0, 1)


def luma_of(rgb):
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


# ------------------------------------------------------------------ models
_SESS = {}


def _session(path, cache=True):
    import onnxruntime as ort
    s = _SESS.get(path) if cache else None
    if s is None:
        o = ort.SessionOptions()
        o.intra_op_num_threads = 2
        o.inter_op_num_threads = 1
        try:
            s = ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])
        except Exception as e:
            raise RestoreError("ort_session:%s" % type(e).__name__)
        if cache:
            _SESS[path] = s
    return s


def _fixed_side(sess):
    shp = sess.get_inputs()[0].shape
    try:
        return int(shp[2]), int(shp[3])
    except (TypeError, ValueError, IndexError):
        return None


def colorize_rgb(rgb, sess=None):
    """DDColor: colour from the model, LIGHTNESS from the photo (identity-safe)."""
    import numpy as np
    if sess is None:
        from . import photo_models as PM
        path = PM.server_model("server_colorize")
        if not path:
            raise RestoreError("colorize_model_missing")
        sess = _session(path, cache=False)  # ~270 MB: never kept between jobs
    side = _fixed_side(sess)
    if side != (DD_SIDE, DD_SIDE):
        raise RestoreError("model_shape")
    h, w = rgb.shape[:2]
    L = rgb_to_lab(rgb)[..., :1]
    small = _resize(rgb, DD_SIDE, DD_SIDE)
    Ls = rgb_to_lab(small)[..., :1]
    grey = lab_to_rgb(np.concatenate([Ls, np.zeros_like(Ls), np.zeros_like(Ls)], axis=-1))
    x = np.ascontiguousarray(grey.transpose(2, 0, 1)[None], dtype=np.float32)
    name = sess.get_inputs()[0].name
    try:
        ab = sess.run(None, {name: x})[0][0]          # (2, 512, 512)
    except Exception as e:
        raise RestoreError("ort_run:%s" % type(e).__name__)
    ab = np.stack([_resize_plane(ab[0], w, h), _resize_plane(ab[1], w, h)], axis=-1)
    return lab_to_rgb(np.concatenate([L, ab], axis=-1))


def _resize_plane(p, w, h):
    import numpy as np
    from PIL import Image
    return np.asarray(Image.fromarray(p.astype(np.float32), "F").resize((w, h), Image.BILINEAR),
                      dtype=np.float32)


def scratch_cleanup(rgb, thr=0.07):
    """Old-photo dust & scratch removal (ours): pixels that differ from their
    7x7 median by more than max(`thr`, 3 x the local texture level) in
    lightness (thin scratches up to ~3 px and dust specks) are replaced by
    the median. Returns (rgb, share of pixels replaced)."""
    import numpy as np
    from PIL import Image, ImageFilter
    y = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    y8 = Image.fromarray((y * 255).astype(np.uint8), "L")
    ymed = np.asarray(y8.filter(ImageFilter.MedianFilter(7)), dtype=np.float32) / 255.0
    dev = np.abs(y - ymed)
    # local texture level (median absolute deviation, 7x7): eyes, hair and
    # fabric deviate a lot everywhere, a scratch only along a thin line —
    # the threshold rises with the texture so real detail is left alone
    dev8 = Image.fromarray(np.clip(dev * 1020.0, 0, 255).astype(np.uint8), "L")
    mad = np.asarray(dev8.filter(ImageFilter.MedianFilter(7)), dtype=np.float32) / 1020.0
    defect = (dev > np.maximum(thr, 3.0 * mad)).astype(np.uint8) * 255
    mask = np.asarray(Image.fromarray(defect, "L").filter(ImageFilter.MaxFilter(3))) > 0
    share = float(mask.mean())
    if share <= 0 or share > 0.25:   # nothing to fix / this is texture, not damage
        return rgb, 0.0
    rgb8 = Image.fromarray((rgb * 255).astype(np.uint8), "RGB")
    med = np.asarray(rgb8.filter(ImageFilter.MedianFilter(7)), dtype=np.float32) / 255.0
    out = rgb.copy()
    out[mask] = med[mask]
    return out, share


def upscale_x4(rgb, sess, tile=128, pad=8, scale=4):
    """Real-ESRGAN with the phone's tiling (UpscaleTiler.kt): FIXED 144x144
    input, `pad` px mirrored context, only the centre of each output kept."""
    import numpy as np
    side = tile + 2 * pad
    if _fixed_side(sess) not in ((side, side),):
        raise RestoreError("model_shape")
    h, w = rgb.shape[:2]
    if min(h, w) < 2:
        raise RestoreError("too_small")
    ty, tx = math.ceil(h / tile), math.ceil(w / tile)
    padded = np.pad(rgb, ((pad, pad + ty * tile - h), (pad, pad + tx * tile - w), (0, 0)),
                    mode="symmetric" if min(h, w) <= pad else "reflect")
    out = np.zeros((h * scale, w * scale, 3), dtype=np.float32)
    name = sess.get_inputs()[0].name
    for j in range(ty):
        for i in range(tx):
            t = padded[j * tile:j * tile + side, i * tile:i * tile + side]
            x = np.ascontiguousarray(t.transpose(2, 0, 1)[None], dtype=np.float32)
            try:
                o = sess.run(None, {name: x})[0][0].transpose(1, 2, 0)
            except Exception as e:
                raise RestoreError("ort_run:%s" % type(e).__name__)
            th, tw = min(tile, h - j * tile), min(tile, w - i * tile)
            out[j * tile * scale:(j * tile + th) * scale, i * tile * scale:(i * tile + tw) * scale] = \
                o[pad * scale:(pad + th) * scale, pad * scale:(pad + tw) * scale]
    return np.clip(out, 0, 1)


def clean_upscale(rgb, scale=2, amount=0.6, sigma=1.0):
    """The commercially CLEAN upscaler (no ML weights at all): Lanczos resize
    + an unsharp mask on luminance. Used whenever Real-ESRGAN is not cleared
    (photo_studio.realesrgan_allowed off)."""
    import numpy as np
    from PIL import Image, ImageFilter
    h, w = rgb.shape[:2]
    tw, th = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    im = Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    up = im.resize((tw, th), Image.LANCZOS)
    sharp = up.filter(ImageFilter.UnsharpMask(radius=max(0.5, sigma * scale / 2),
                                              percent=int(amount * 100), threshold=2))
    return np.asarray(sharp, dtype=np.float32) / 255.0


def merge_keep_faces(ai, base, faces, face_ai=0.25):
    """Same maths as UpscaleTiler.mergeKeepFaces: colours from `base`, only
    LUMINANCE detail from `ai`, and inside each face ellipse just `face_ai`
    of it (face-lock). faces = [[x, y, w, h] 0..1]."""
    import numpy as np
    h, w = base.shape[:2]
    wt = np.ones((h, w), dtype=np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    for f in faces or []:
        try:
            fx, fy, fw, fh = [float(v) for v in f][:4]
        except (TypeError, ValueError):
            continue
        cx, cy = (fx + fw / 2) * w, (fy + fh / 2) * h
        rx, ry = fw * w * 0.62, fh * h * 0.72
        if rx < 1 or ry < 1:
            continue
        d = np.sqrt(((xx + 0.5 - cx) / rx) ** 2 + ((yy + 0.5 - cy) / ry) ** 2)
        t = np.clip((d - 0.75) / 0.25, 0, 1)
        s = t * t * (3 - 2 * t)
        wt = np.minimum(wt, face_ai + (1 - face_ai) * s)
    k = np.asarray([0.299, 0.587, 0.114], dtype=np.float32)
    dy = ((ai @ k) - (base @ k)) * wt
    return np.clip(base + dy[..., None], 0, 1)


def old_restore_rgb(rgb, *, colorize=True, faces=None, up_sess=None, color_sess=None):
    """Old photo: dust/scratch cleanup -> (colour at the model's own 512 px
    when it is black & white and the user asked) -> Real-ESRGAN x4 detail,
    luminance only, face-locked -> <= 2048 px."""
    info = {"scratch_share": 0.0, "colorized": False}
    src = _fit(rgb, RESTORE_INPUT_LONG)
    src, info["scratch_share"] = scratch_cleanup(src)
    src = restore_levels(src)
    if colorize and is_grey(src) and color_sess is not None:
        src = colorize_rgb(src, color_sess)
        info["colorized"] = True
    if up_sess is None:
        # photo-final: Real-ESRGAN not cleared -> clean non-ML detail path
        ai = clean_upscale(src, 4)
    else:
        ai = upscale_x4(src, up_sess)
    h, w = ai.shape[:2]
    if max(w, h) > RESTORE_OUT_LONG:
        f = RESTORE_OUT_LONG / max(w, h)
        w, h = max(1, round(w * f)), max(1, round(h * f))
        ai = _resize(ai, w, h)
    base = _resize(src, w, h)
    return merge_keep_faces(ai, base, faces), info


# ------------------------------------------------------------------ HD enhance (v2)
ENH_IN_CAP = {"free": 768, "premium": 1024}      # Real-ESRGAN input (30 / 48 tiles)
ENH_OUT_CAP = {"free": 2048, "premium": 4096}
FACE_DETAIL_MAX = 320     # faces smaller than this (px, long side) get the face pass
FACE_DETAIL_WEIGHT = 0.6  # share of AI luminance detail inside the face ellipse


def _norm_boxes(faces, w, h):
    return [[f["box"][0] / w, f["box"][1] / h, f["box"][2] / w, f["box"][3] / h] for f in faces]


def face_detail_pass(out, orig, faces, sess):
    """No licence-clean face-RESTORATION model exists (GFPGAN / CodeFormer
    weights are non-commercial), so the face gets the best clean thing we
    have: Real-ESRGAN on the face crop at its NATIVE resolution (the global
    pass may have shrunk it first), luminance only, blended inside the face
    ellipse — geometry is the model's input geometry, and FACE LOCK checks it."""
    import numpy as np
    H, W = out.shape[:2]
    sx, sy = W / orig.shape[1], H / orig.shape[0]
    for f in faces:
        x, y, w, h = f["box"]
        if max(w, h) > FACE_DETAIL_MAX or min(w, h) < 12:
            continue
        cx, cy, r = x + w / 2, y + h / 2, max(w, h) * 0.85
        x0, y0 = max(0, int(cx - r)), max(0, int(cy - r))
        x1, y1 = min(orig.shape[1], int(cx + r)), min(orig.shape[0], int(cy + r))
        crop = orig[y0:y1, x0:x1]
        if min(crop.shape[:2]) < 16:
            continue
        ai = upscale_x4(crop, sess)
        tw, th = max(1, round((x1 - x0) * sx)), max(1, round((y1 - y0) * sy))
        tx, ty = round(x0 * sx), round(y0 * sy)
        tw, th = min(tw, W - tx), min(th, H - ty)
        if tw < 8 or th < 8:
            continue
        ai = _resize(ai, tw, th)
        region = out[ty:ty + th, tx:tx + tw]
        yy, xx = np.mgrid[0:th, 0:tw].astype(np.float32)
        d = np.sqrt(((xx + 0.5 - tw / 2) / (tw * 0.40)) ** 2 + ((yy + 0.5 - th / 2) / (th * 0.48)) ** 2)
        t = np.clip((1.0 - d) / 0.35, 0, 1)
        wt = (t * t * (3 - 2 * t)) * FACE_DETAIL_WEIGHT
        k = np.asarray([0.299, 0.587, 0.114], dtype=np.float32)
        dy = ((ai @ k) - (region @ k)) * wt
        out[ty:ty + th, tx:tx + tw] = np.clip(region + dy[..., None], 0, 1)
    return out


def enhance_rgb(rgb, up_sess, faces, tier="free"):
    """HD enhance on the worker: full-image Real-ESRGAN (x4, tiled, luminance
    detail, face-locked at 25 %) for photos that need pixels, the face detail
    pass, a gentle fade fix. Big sharp photos keep their own pixels (no
    downscale-then-upscale). FACE LOCK runs after this (photo_worker)."""
    h, w = rgb.shape[:2]
    long = max(w, h)
    out_cap, in_cap = ENH_OUT_CAP[tier], ENH_IN_CAP[tier]
    info = {"tier": tier, "faces": len(faces), "global_ai": False}
    if long * 1.5 <= out_cap:
        inp = min(long, in_cap)
        src = _fit(rgb, inp)
        ai = upscale_x4(src, up_sess)
        target = min(out_cap, inp * 4)
        tw = round(w * target / long)
        th = round(h * target / long)
        ai = _resize(ai, tw, th)
        base = _resize(rgb, tw, th)
        out = merge_keep_faces(ai, base, _norm_boxes(faces, w, h))
        info.update(global_ai=True, tiles=math.ceil(src.shape[1] / 128) * math.ceil(src.shape[0] / 128))
    else:
        out = _fit(rgb, out_cap).copy()
    out = face_detail_pass(out, rgb, faces, up_sess)
    y = luma_of(out)
    import numpy as np
    lo, hi = np.percentile(y, [1, 99])
    if hi - lo < 0.8:   # only a faded / flat photo gets the levels fix
        out = restore_levels(out, max_gain=1.3)
    info["out_size"] = [int(out.shape[1]), int(out.shape[0])]
    return out, info


def process(feature, raw, paths, *, faces=None, colorize=True, session=None):
    """The whole CPU job (runs in the isolated worker process). `paths` =
    {role: model path}; `session(path)` opens a model (tests inject fakes)."""
    session = session or _lean_session
    rgb = _decode(raw)
    if feature == "colorize":
        if not paths.get("server_colorize"):
            raise RestoreError("colorize_model_missing")
        out = colorize_rgb(_fit(rgb, COLOR_OUT_LONG), session(paths["server_colorize"]))
        info = {"colorized": True}
    elif feature == "old_restore":
        cs = None
        if colorize and paths.get("server_colorize") and is_grey(_fit(rgb, RESTORE_INPUT_LONG)):
            cs = session(paths["server_colorize"])
        up = session(paths["upscale"]) if paths.get("upscale") else None
        out, info = old_restore_rgb(rgb, colorize=colorize, faces=faces,
                                    up_sess=up, color_sess=cs)
        info["upscaler"] = "real-esrgan" if up is not None else "lanczos+unsharp"
    else:
        raise RestoreError("unknown_feature")
    return _encode(out), info


def _lean_session(path):
    """CPU session without the memory arena (DDColor peaks at ~1.3 GB instead
    of ~1.8 GB) — fine in the short-lived worker process."""
    import onnxruntime as ort
    o = ort.SessionOptions()
    o.intra_op_num_threads = 2
    o.inter_op_num_threads = 1
    o.enable_cpu_mem_arena = False
    o.enable_mem_pattern = False
    try:
        return ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])
    except Exception as e:
        raise RestoreError("ort_session:%s" % type(e).__name__)


# ------------------------------------------------------------------ worker process
WORKER_TIMEOUT_S = 75
MEM_NEED_MB = {"colorize": 1600, "old_restore": 1700}


def _mem_available_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        pass
    return 1 << 20


def _run_worker(feature, raw, paths, faces, colorize):
    """Run process() in a SHORT-LIVED child so its ~1.3 GB model memory is
    returned to the OS at once and a stuck job can be killed (timeout)."""
    import subprocess
    import sys
    import tempfile
    worker = os.path.join(os.path.dirname(os.path.abspath(__file__)), "photo_restore_worker.py")
    d = os.path.join(str(settings.MEDIA_ROOT), "photo_studio", "tmp")
    os.makedirs(d, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=d) as td:
        inp, outp = os.path.join(td, "in.bin"), os.path.join(td, "out.png")
        with open(inp, "wb") as fh:
            fh.write(raw)
        job = json.dumps({"feature": feature, "in": inp, "out": outp, "paths": paths,
                          "faces": faces or [], "colorize": bool(colorize)})
        try:
            r = subprocess.run([sys.executable, "-I", worker, job], capture_output=True,
                               timeout=WORKER_TIMEOUT_S, text=True)
        except subprocess.TimeoutExpired:
            raise RestoreError("timeout")
        try:
            res = json.loads((r.stdout or "").strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise RestoreError("worker_exit_%d" % r.returncode)
        if not res.get("ok"):
            raise RestoreError(str(res.get("error") or "worker_failed")[:60])
        with open(outp, "rb") as fh:
            return fh.read(), res.get("info") or {}


# ------------------------------------------------------------------ GPU (deblur)
def _http():
    import requests
    return requests


def gpu_deblur(raw, conf, mime="image/jpeg"):
    """NAFNet on Replicate (pay-per-use GPU). Request shape per Replicate's
    public predictions API; unit-tested with a mocked HTTP layer only — the
    first real call happens when the owner connects the key."""
    rq = _http()
    version = str(conf.get("deblur_version") or "").strip()
    if not version:
        raise RestoreError("no_model")
    inp = {"image": "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode()),
           "task_type": str(conf.get("deblur_task") or DEFAULT_DEBLUR_TASK)}
    try:
        r = rq.post("https://api.replicate.com/v1/predictions", timeout=GPU_TIMEOUT_S,
                    headers={"Authorization": "Bearer %s" % conf.get("api_token", ""),
                             "Prefer": "wait=60", "Content-Type": "application/json"},
                    data=json.dumps({"version": version, "input": inp}))
    except Exception as e:  # noqa: BLE001
        raise RestoreError("gpu_net:%s" % type(e).__name__)
    if r.status_code not in (200, 201):
        raise RestoreError("gpu_http_%d" % r.status_code)
    j = r.json()
    if j.get("status") != "succeeded":
        raise RestoreError("gpu_not_finished_%s" % (j.get("status") or "unknown"))
    out = j.get("output")
    if isinstance(out, list):
        out = out[0] if out else None
    if not isinstance(out, str) or not out.startswith("https://"):
        raise RestoreError("gpu_no_image")
    try:
        g = rq.get(out, timeout=GPU_TIMEOUT_S)
    except Exception as e:  # noqa: BLE001
        raise RestoreError("gpu_net:%s" % type(e).__name__)
    if g.status_code != 200 or not g.content:
        raise RestoreError("gpu_download_%d" % g.status_code)
    return g.content


def gpu_enhance_conf():
    """Paid fast path for HD enhance: the same GPU key + an enhance model
    version + cost per run. None = not connected (CPU worker is used)."""
    conf = _gpu_conf()
    if not conf or not conf.get("api_token") or not conf.get("enhance_version"):
        return None
    if _num(conf.get("enhance_cost_usd")) <= 0:
        return None
    return {**conf, "cost_per_run_usd": conf.get("enhance_cost_usd")}


def gpu_enhance(raw, conf):
    """Real-ESRGAN (BSD-3) on a pay-per-use GPU (Replicate), x4 then capped
    at 4K by the caller's FACE LOCK step; face_enhance is NEVER requested
    (that would run GFPGAN — non-commercial weights)."""
    rq = _http()
    inp = {"image": "data:%s;base64,%s" % ("image/jpeg", base64.b64encode(raw).decode()),
           "scale": 4, "face_enhance": False}
    try:
        r = rq.post("https://api.replicate.com/v1/predictions", timeout=GPU_TIMEOUT_S,
                    headers={"Authorization": "Bearer %s" % conf.get("api_token", ""),
                             "Prefer": "wait=60", "Content-Type": "application/json"},
                    data=json.dumps({"version": conf.get("enhance_version"), "input": inp}))
    except Exception as e:  # noqa: BLE001
        raise RestoreError("gpu_net:%s" % type(e).__name__)
    if r.status_code not in (200, 201):
        raise RestoreError("gpu_http_%d" % r.status_code)
    j = r.json()
    out = j.get("output")
    if j.get("status") != "succeeded" or not isinstance(out, str) or not out.startswith("https://"):
        raise RestoreError("gpu_not_finished")
    g = rq.get(out, timeout=GPU_TIMEOUT_S)
    if g.status_code != 200 or not g.content:
        raise RestoreError("gpu_download_%d" % g.status_code)
    rgb = _fit(_decode(g.content), 4096)
    return _encode(rgb)


# ------------------------------------------------------------------ entry
def run(feature, raw, *, face_boxes=None, colorize=True, mime="image/jpeg"):
    """Encoded photo in -> (encoded image, info), or RestoreError. Never a
    fake result: a failure raises and the caller keeps the job funded."""
    from . import photo_models as PM
    if feature not in FEATURES:
        raise RestoreError("unknown_feature")
    st = status(feature, "en")
    if not st["ready"]:
        raise RestoreError("not_ready")
    t0 = time.monotonic()
    if feature == "deblur":
        out = gpu_deblur(raw, _gpu_conf() or {}, mime=mime)
        _decode(out)  # never trust a remote image blindly: it must decode
        return out, {"where": "gpu", "ms": int((time.monotonic() - t0) * 1000)}
    paths = {r: PM.server_model(r) for r in ("upscale", "server_colorize")}
    with _heavy_lock():
        if _mem_available_mb() < MEM_NEED_MB.get(feature, 1600):
            raise RestoreBusy("memory")
        png, info = _run_worker(feature, raw, paths, face_boxes, colorize)
    info.update({"where": "server", "ms": int((time.monotonic() - t0) * 1000)})
    return png, info
