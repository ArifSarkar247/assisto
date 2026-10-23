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
SERVER_FEATURES = ("colorize", "old_restore")
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
    if feature in SERVER_FEATURES:
        if not _runtime_ok():
            return {"ready": False, "where": "server", "cost_usd": 0.0,
                    "needs": pick(lang, "সার্ভারে onnxruntime ইনস্টল করতে হবে (pip install onnxruntime)।",
                                  "Install onnxruntime on the server (pip install onnxruntime).")}
        need_role = "server_colorize" if feature == "colorize" else "upscale"
        if not PM.server_model(need_role):
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


def is_grey(rgb, thr=0.06):
    """Black & white (or faded sepia) photo? Mean chroma below `thr`."""
    import numpy as np
    small = rgb[::4, ::4] if min(rgb.shape[:2]) > 64 else rgb
    return float(np.mean(small.max(axis=-1) - small.min(axis=-1))) < thr


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


def scratch_cleanup(rgb, thr=0.10):
    """Old-photo dust & scratch removal (ours): pixels that differ from their
    5x5 median by more than `thr` in lightness, in thin structures, are
    replaced by the median. Returns (rgb, share_of_pixels_fixed)."""
    import numpy as np
    from PIL import Image, ImageFilter
    y = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    y8 = Image.fromarray((y * 255).astype(np.uint8), "L")
    ymed = np.asarray(y8.filter(ImageFilter.MedianFilter(5)), dtype=np.float32) / 255.0
    defect = (np.abs(y - ymed) > thr).astype(np.uint8) * 255
    mask = np.asarray(Image.fromarray(defect, "L").filter(ImageFilter.MaxFilter(3))) > 0
    share = float(mask.mean())
    if share <= 0 or share > 0.25:   # nothing to fix / this is texture, not damage
        return rgb, 0.0 if share <= 0 else share
    rgb8 = Image.fromarray((rgb * 255).astype(np.uint8), "RGB")
    med = np.asarray(rgb8.filter(ImageFilter.MedianFilter(5)), dtype=np.float32) / 255.0
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
    if colorize and is_grey(src) and color_sess is not None:
        src = colorize_rgb(src, color_sess)
        info["colorized"] = True
    if up_sess is None:
        raise RestoreError("upscale_model_missing")
    ai = upscale_x4(src, up_sess)
    h, w = ai.shape[:2]
    if max(w, h) > RESTORE_OUT_LONG:
        f = RESTORE_OUT_LONG / max(w, h)
        w, h = max(1, round(w * f)), max(1, round(h * f))
        ai = _resize(ai, w, h)
    base = _resize(src, w, h)
    return merge_keep_faces(ai, base, faces), info


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
        if not paths.get("upscale"):
            raise RestoreError("upscale_model_missing")
        cs = None
        if colorize and paths.get("server_colorize") and is_grey(_fit(rgb, RESTORE_INPUT_LONG)):
            cs = session(paths["server_colorize"])
        out, info = old_restore_rgb(rgb, colorize=colorize, faces=faces,
                                    up_sess=session(paths["upscale"]), color_sess=cs)
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
