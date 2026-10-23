#!/usr/bin/env python3
"""d1-photo: Photo Studio vs. (optionally) Remini — honest side-by-side on 20
licence-clean photos.

We cannot run Remini here and must not copy it. This tool runs OUR pipeline
(the app's own code paths) on 20 photos made from licence-clean originals with
KNOWN, synthetic damage, so we can measure against the clean original:

  category   photos       damage (deterministic)                 our pipeline
  portrait   01-05        ½ size, JPEG q55, soft blur            app ENHANCE with AI step
                                                                 (Real-ESRGAN tiles + face-lock
                                                                 + classical Natural)
  old        06-08,11,12  B&W, sepia fade, scratches, dust,      server OLD-PHOTO RESTORE
                          grain, blur, ½ size                    (scratch cleanup + Real-ESRGAN
                                                                 + DDColor colour)
  blurry     09,10,13-15  Gaussian blur σ=2.2 + noise σ=4       app ENHANCE with AI step
                                                                 (deblur NAFNet is GPU-only and
                                                                 not connected -> not used)
  low light  16-20        gamma 2.0 × 0.45, noise σ=7, JPEG q70  app LOW-LIGHT tool (classical)

Metrics vs the clean original (outputs resized to the original size):
PSNR (dB), SSIM (luminance, 7x7 Gaussian), sharpness (Laplacian variance;
the original's is shown too), mean |ΔL| lightness error, colourfulness.
Faces: OpenCV Haar count before/after (a weak stand-in for ML Kit).

REMINI COLUMN: put the owner's Remini outputs (made on the phone from the
files in <out>/inputs/) in a folder, named like the inputs (01_portrait.jpg
…), and pass --remini <folder>: the sheet then shows clean | damaged | Assisto
| Remini with the same metrics. Without it the column says "not run".

Usage (scratch venv: numpy, pillow, opencv-python-headless, onnxruntime):
  python3 tools/photo_eval/run_eval.py --src <20 originals> --out <dir> \
     --ps-eval <compiled app/tool/ps_eval.dart> --upscale <realesr .onnx> \
     [--colorize <ddcolor_tiny_512.onnx>] [--remini <folder>]
Originals: .phaseB/photo_studio_eval/sources.json (Wikimedia Commons: 10 US
Congress portraits = public domain, 10 CC0 photos); fetch_sources.py downloads
them politely.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

CATS = {
    "portrait": ["01", "02", "03", "04", "05"],
    "old": ["06", "07", "08", "11", "12"],
    "blurry": ["09", "10", "13", "14", "15"],
    "low_light": ["16", "17", "18", "19", "20"],
}
LONG = 800  # originals are scaled to this long edge (eval speed, comparable)


def load_restore():
    spec = importlib.util.spec_from_file_location(
        "photo_restore_eval", os.path.join(ROOT, "backend", "core", "photo_restore.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


R = load_restore()


# ------------------------------------------------------------------ helpers
def f32(im):
    return np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0


def u8(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")


def jpeg(a, q):
    import io
    b = io.BytesIO()
    u8(a).save(b, "JPEG", quality=q)
    return f32(Image.open(io.BytesIO(b.getvalue())))


def resize(a, w, h):
    return f32(u8(a).resize((w, h), Image.BICUBIC))


def psnr(a, b):
    mse = float(np.mean((a - b) ** 2))
    return 99.0 if mse <= 1e-12 else 10 * np.log10(1.0 / mse)


def luma(a):
    return a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def ssim(a, b):
    x, y = luma(a).astype(np.float64), luma(b).astype(np.float64)
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    g = lambda z: cv2.GaussianBlur(z, (7, 7), 1.5)  # noqa: E731
    mx, my = g(x), g(y)
    sxx, syy, sxy = g(x * x) - mx * mx, g(y * y) - my * my, g(x * y) - mx * my
    m = ((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx * mx + my * my + c1) * (sxx + syy + c2))
    return float(m.mean())


def sharpness(a):
    return float(cv2.Laplacian((luma(a) * 255).astype(np.float64), cv2.CV_64F).var())


def colourfulness(a):
    rg = a[..., 0] - a[..., 1]
    yb = 0.5 * (a[..., 0] + a[..., 1]) - a[..., 2]
    return float(np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2)) * 100


_HAAR = None


def faces(a):
    global _HAAR
    if _HAAR is None:
        _HAAR = cv2.CascadeClassifier(os.path.join(cv2.data.haarcascades,
                                                   "haarcascade_frontalface_default.xml"))
    g = (luma(a) * 255).astype(np.uint8)
    fs = _HAAR.detectMultiScale(g, 1.1, 5, minSize=(max(24, g.shape[1] // 12),) * 2)
    h, w = g.shape
    return [[x / w, y / h, fw / w, fh / h] for (x, y, fw, fh) in fs]


# ------------------------------------------------------------------ damage
def damage(clean, cat, seed):
    rng = np.random.default_rng(seed)
    h, w = clean.shape[:2]
    if cat == "portrait":
        small = resize(clean, w // 2, h // 2)
        small = f32(u8(small).filter(ImageFilter.GaussianBlur(0.8)))
        return jpeg(small, 55)
    if cat == "old":
        y = luma(clean)
        sep = np.stack([y * 1.0 + 0.06, y * 0.9 + 0.04, y * 0.72 + 0.02], -1)
        sep = 0.12 + 0.75 * np.clip(sep, 0, 1)            # faded contrast
        img = u8(sep)
        d = ImageDraw.Draw(img)
        for _ in range(7):                                  # scratches
            x0 = int(rng.integers(0, w))
            d.line([(x0, 0), (x0 + int(rng.integers(-40, 40)), h)], fill=(235, 230, 215),
                   width=1)
        for _ in range(120):                                # dust
            x, yy = int(rng.integers(0, w)), int(rng.integers(0, h))
            r = int(rng.integers(1, 3))
            d.ellipse([x - r, yy - r, x + r, yy + r], fill=(30, 25, 20) if rng.random() < .5 else (240, 235, 225))
        a = f32(img.filter(ImageFilter.GaussianBlur(1.0)))
        a = a + rng.normal(0, 0.03, a.shape).astype(np.float32)
        return jpeg(resize(np.clip(a, 0, 1), w // 2, h // 2), 70)
    if cat == "blurry":
        a = f32(u8(clean).filter(ImageFilter.GaussianBlur(2.2)))
        return jpeg(np.clip(a + rng.normal(0, 4 / 255, a.shape).astype(np.float32), 0, 1), 85)
    if cat == "low_light":
        a = (clean ** 2.0) * 0.45
        a = a + rng.normal(0, 7 / 255, a.shape).astype(np.float32)
        return jpeg(np.clip(a, 0, 1), 70)
    raise ValueError(cat)


# ------------------------------------------------------------------ our pipeline
def ps_eval(bin_path, a, levels, fa, work):
    h, w = a.shape[:2]
    arr = np.asarray(u8(a), dtype=np.uint8)
    rgba = np.concatenate([arr, np.full((h, w, 1), 255, np.uint8)], -1)
    inp = os.path.join(work, "in.rgba")
    with open(inp, "wb") as f:
        f.write(np.array([w, h], dtype="<u4").tobytes())
        f.write(rgba.tobytes())
    fs = ";".join(",".join("%.4f" % v for v in b) for b in fa)
    r = subprocess.run([bin_path, inp, os.path.join(work, "o"), fs, levels],
                       capture_output=True, text=True, check=True)
    ms = [json.loads(line)["ms"] for line in r.stdout.splitlines() if line.startswith("{")]
    raw = open(os.path.join(work, "o_%s.rgba" % levels.split(",")[0]), "rb").read()
    ow, oh = np.frombuffer(raw[:8], "<u4")
    out = np.frombuffer(raw[8:], np.uint8).reshape(oh, ow, 4)[..., :3].astype(np.float32) / 255
    return out, (ms[0] if ms else 0)


def app_enhance(dmg, sess, bin_path, work):
    """The app's ENHANCE with the AI step: plan by the phone's first-run
    budget (6 tiles), Real-ESRGAN tiles, luminance + face-lock merge, then the
    classical Natural pass — same order as StudioEnhanceEngine.enhance."""
    h, w = dmg.shape[:2]
    long = max(w, h)
    want = min(long * 2, 2560)
    inp = max(32, min(long, 640, -(-want // 2)))
    tiles = lambda L: -(-round(w * L / long) // 128) * -(-round(h * L / long) // 128)  # noqa: E731
    while inp > 32 and tiles(inp) > 6:
        inp = max(32, int(inp * 0.92))
    target = min(want, inp * 4)
    src = R._fit(dmg, inp)
    fa = faces(dmg)
    t = time.perf_counter()
    ai = R.upscale_x4(src, sess)
    ai_ms = (time.perf_counter() - t) * 1000
    th = round(ai.shape[0] * target / max(ai.shape[:2]))
    tw = round(ai.shape[1] * target / max(ai.shape[:2]))
    ai = resize(ai, tw, th)
    base = resize(dmg, tw, th)
    merged = R.merge_keep_faces(ai, base, fa)
    out, c_ms = ps_eval(bin_path, merged, "natural", fa, work)
    return out, {"ai_tiles": tiles(inp), "ai_ms": round(ai_ms), "classic_ms": c_ms,
                 "faces_in": len(fa)}


def run_one(cat, dmg, a, sessions, work):
    if cat in ("portrait", "blurry"):
        return app_enhance(dmg, sessions["upscale"], a.ps_eval, work)
    if cat == "low_light":
        out, ms = ps_eval(a.ps_eval, dmg, "lowlight", faces(dmg), work)
        return out, {"classic_ms": ms}
    if cat == "old":
        t = time.perf_counter()
        out, info = R.old_restore_rgb(dmg, colorize=True, faces=faces(dmg),
                                      up_sess=sessions["upscale"], color_sess=sessions.get("colorize"))
        info["server_ms"] = round((time.perf_counter() - t) * 1000)
        return out, info
    raise ValueError(cat)


# ------------------------------------------------------------------ sheet
def font(sz):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def sheet(rows, out_path, cell=220):
    cols = ["clean original", "damaged (input)", "Assisto", "Remini"]
    W = cell * 4 + 10 * 5
    H = 40 + len(rows) * (cell + 46)
    s = Image.new("RGB", (W, H), (250, 250, 250))
    d = ImageDraw.Draw(s)
    f, fs = font(16), font(12)
    for i, c in enumerate(cols):
        d.text((10 + i * (cell + 10), 12), c, fill=(20, 20, 20), font=f)
    for r, row in enumerate(rows):
        y0 = 40 + r * (cell + 46)
        for i in range(4):
            x0 = 10 + i * (cell + 10)
            im = row["imgs"][i]
            if im is None:
                d.rectangle([x0, y0, x0 + cell, y0 + cell], outline=(180, 180, 180))
                d.text((x0 + 12, y0 + cell // 2 - 8), "not run (owner)", fill=(120, 120, 120), font=fs)
            else:
                t = u8(im)
                t.thumbnail((cell, cell))
                s.paste(t, (x0 + (cell - t.width) // 2, y0 + (cell - t.height) // 2))
            cap = row["caps"][i]
            d.text((x0, y0 + cell + 4), cap, fill=(40, 40, 40), font=fs)
        d.text((10, y0 + cell + 22), "%s · %s" % (row["name"], row["cat"]), fill=(90, 90, 90), font=fs)
    s.save(out_path, quality=82)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ps-eval", required=True)
    ap.add_argument("--upscale", required=True)
    ap.add_argument("--colorize", default="")
    ap.add_argument("--remini", default="")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "inputs"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "assisto"), exist_ok=True)
    work = os.path.join(a.out, "_work")
    os.makedirs(work, exist_ok=True)
    sessions = {"upscale": R._lean_session(a.upscale)}
    if a.colorize:
        sessions["colorize"] = R._lean_session(a.colorize)
    results, rows = [], []
    names = sorted(f for f in os.listdir(a.src) if f.lower().endswith((".jpg", ".png")))
    for cat, ids in CATS.items():
        for n in ids:
            name = next(x for x in names if x.startswith(n + "_"))
            clean = R._fit(f32(Image.open(os.path.join(a.src, name))), LONG)
            h, w = clean.shape[:2]
            dmg = damage(clean, cat, seed=int(n))
            u8(dmg).save(os.path.join(a.out, "inputs", name), quality=92)
            t = time.perf_counter()
            ours, info = run_one(cat, dmg, a, sessions, work)
            info["total_ms"] = round((time.perf_counter() - t) * 1000)
            u8(ours).save(os.path.join(a.out, "assisto", name), quality=92)
            cmp = {"damaged": resize(dmg, w, h), "assisto": resize(ours, w, h)}
            rem = None
            if a.remini:
                rp = os.path.join(a.remini, name)
                alt = [x for x in os.listdir(a.remini) if x.startswith(n + "_")] if os.path.isdir(a.remini) else []
                if not os.path.exists(rp) and alt:
                    rp = os.path.join(a.remini, alt[0])
                if os.path.exists(rp):
                    rem = f32(Image.open(rp))
                    cmp["remini"] = resize(rem, w, h)
            m = {k: {"psnr": round(psnr(v, clean), 2), "ssim": round(ssim(v, clean), 4),
                     "sharp": round(sharpness(v)), "dL": round(float(np.mean(np.abs(
                         R.rgb_to_lab(v)[..., 0] - R.rgb_to_lab(clean)[..., 0]))), 2),
                     "colour": round(colourfulness(v), 1),
                     "faces": len(faces(v))} for k, v in cmp.items()}
            m["clean"] = {"sharp": round(sharpness(clean)), "colour": round(colourfulness(clean), 1),
                          "faces": len(faces(clean))}
            results.append({"photo": name, "category": cat, "metrics": m, "run": info,
                             "out_size": [int(ours.shape[1]), int(ours.shape[0])]})
            cap = lambda k: "PSNR %.1f  SSIM %.3f" % (m[k]["psnr"], m[k]["ssim"])  # noqa: E731
            rows.append({"name": name, "cat": cat,
                         "imgs": [clean, dmg, ours, rem],
                         "caps": ["sharp %d" % m["clean"]["sharp"], cap("damaged"), cap("assisto"),
                                  cap("remini") if "remini" in m else ""]})
            print(name, cat, m["damaged"]["psnr"], "->", m["assisto"]["psnr"], info, flush=True)
    for i in range(0, len(rows), 5):
        sheet(rows[i:i + 5], os.path.join(a.out, "sheet_%d.jpg" % (i // 5 + 1)))
    summ = {}
    for cat in CATS:
        rs = [r for r in results if r["category"] == cat]
        summ[cat] = {}
        for k in ("damaged", "assisto", "remini"):
            v = [r["metrics"][k] for r in rs if k in r["metrics"]]
            if v:
                summ[cat][k] = {q: round(float(np.mean([x[q] for x in v])), 3)
                                for q in ("psnr", "ssim", "sharp", "dL", "colour")}
                summ[cat][k]["n"] = len(v)
                if k == "assisto":
                    summ[cat][k]["improved_psnr"] = sum(
                        1 for r in rs if r["metrics"]["assisto"]["psnr"] > r["metrics"]["damaged"]["psnr"])
        summ[cat]["clean_sharp"] = round(float(np.mean([r["metrics"]["clean"]["sharp"] for r in rs])))
        summ[cat]["ms_mean"] = round(float(np.mean([r["run"]["total_ms"] for r in rs])))
    json.dump({"summary": summ, "photos": results}, open(os.path.join(a.out, "results.json"), "w"),
              indent=1)
    print(json.dumps(summ, indent=1))


if __name__ == "__main__":
    main()
