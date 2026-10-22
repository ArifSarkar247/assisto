#!/usr/bin/env python3
"""Photo Studio quality + speed evaluation (p2-photo) on licence-clean photos.

Runs the APP'S OWN classical pipeline (app/lib/photo_studio/ps_classic.dart,
compiled with `dart compile exe app/tool/ps_eval.dart`) and the Real-ESRGAN
ONNX model with the SAME tiling as the phone (UpscaleTiler.kt, mirrored in
`tile_upscale` below), and writes small before/after thumbnails + numbers.

  python3 eval_photos.py --photos <dir with NN_*.jpg + sources.json>
      --ps-eval <compiled ps_eval> --model <realesr_general_x4v3_t144.onnx>
      --out .phaseB/photo_studio_eval [--threads 1]

Needs: numpy, Pillow, onnxruntime, opencv-python-headless (Haar face boxes for
the skin mask — a stand-in for ML Kit on the phone).

Protocol (reference = the clean source photo, long edge 800):
  A. classical: the reference is DEGRADED the way phone photos usually are
     (darker + gamma, colour cast, sensor noise σ=7, JPEG q=60), then enhanced
     at Light / Natural / Strong. PSNR vs the reference shows how much of the
     damage is undone; Laplacian variance = sharpness; cast = mean |channel
     mean − reference channel mean|.
  B. AI (the "small / old photo" case): the reference is shrunk to 1/2
     (+ JPEG q=75) and brought back to full size exactly like the phone does
     (AiPlan: target = 2x, model x4 then shrink): bicubic vs raw Real-ESRGAN vs
     the shipped AI step = Real-ESRGAN luminance detail on the original's
     colours with FACE-LOCK (25 % AI inside face ellipses; `merge_keep_faces`
     = UpscaleTiler.mergeKeepFaces). PSNR vs reference + sharpness.
"""
import argparse
import io
import json
import os
import struct
import subprocess
import sys
import time

import numpy as np
from PIL import Image

SIDE, PAD, SCALE = 144, 8, 4
TILE = SIDE - 2 * PAD


# ------------------------------------------------------------------ helpers
def to_rgba_file(img, path):
    im = img.convert("RGBA")
    with open(path, "wb") as f:
        f.write(struct.pack("<II", *im.size) + im.tobytes())


def from_rgba_file(path):
    raw = open(path, "rb").read()
    w, h = struct.unpack("<II", raw[:8])
    return Image.frombytes("RGBA", (w, h), raw[8:]).convert("RGB")


def psnr(a, b):
    a = np.asarray(a, np.float64)
    b = np.asarray(b, np.float64)
    mse = np.mean((a - b) ** 2)
    return 99.0 if mse == 0 else float(10 * np.log10(255 * 255 / mse))


def sharpness(img):
    y = np.asarray(img.convert("L"), np.float64)
    lap = (y[:-2, 1:-1] + y[2:, 1:-1] + y[1:-1, :-2] + y[1:-1, 2:] - 4 * y[1:-1, 1:-1])
    return float(lap.var())


def cast(img, ref):
    a = np.asarray(img, np.float64).reshape(-1, 3).mean(0)
    b = np.asarray(ref, np.float64).reshape(-1, 3).mean(0)
    return float(np.abs(a - b).mean())


def jpeg(img, q):
    bio = io.BytesIO()
    img.save(bio, "JPEG", quality=q)
    return Image.open(io.BytesIO(bio.getvalue())).convert("RGB")


def degrade(ref, i):
    rng = np.random.default_rng(1000 + i)
    a = np.asarray(ref, np.float64) / 255.0
    a = (a ** 1.35) * 0.82  # under-exposed
    tint = [np.array([1.07, 1.0, 0.86]), np.array([0.9, 1.0, 1.1]),
            np.array([1.0, 1.05, 0.92])][i % 3]
    a = a * tint
    a = a + rng.normal(0, 7 / 255.0, a.shape)
    a = np.clip(a, 0, 1)
    return jpeg(Image.fromarray((a * 255 + 0.5).astype(np.uint8)), 60)


# ------------------------------------------------------- tiling (= Kotlin)
def reflect(i, n):
    if n <= 1:
        return 0
    period = 2 * (n - 1)
    k = i % period
    return k if k < n else period - k


def tile_upscale(sess, img):
    """Exactly UpscaleTiler.plan/extract/place."""
    x = np.asarray(img.convert("RGB"), np.float32) / 255.0
    h, w = x.shape[:2]
    out = np.zeros((h * SCALE, w * SCALE, 3), np.float32)
    n = 0
    for y0 in range(0, h, TILE):
        th = min(TILE, h - y0)
        for x0 in range(0, w, TILE):
            tw = min(TILE, w - x0)
            ys = [reflect(y0 - PAD + k, h) for k in range(SIDE)]
            xs = [reflect(x0 - PAD + k, w) for k in range(SIDE)]
            t = x[np.ix_(ys, xs)].transpose(2, 0, 1)[None]
            o = sess.run(None, {"input": np.ascontiguousarray(t)})[0][0].transpose(1, 2, 0)
            o = o[PAD * SCALE:PAD * SCALE + th * SCALE, PAD * SCALE:PAD * SCALE + tw * SCALE]
            out[y0 * SCALE:(y0 + th) * SCALE, x0 * SCALE:(x0 + tw) * SCALE] = o
            n += 1
    q = np.clip(np.round(out * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(q), n


def merge_keep_faces(ai, base, faces, face_ai=0.25):
    """= UpscaleTiler.mergeKeepFaces (Kotlin)."""
    a = np.asarray(ai, np.float64)
    b = np.asarray(base, np.float64)
    h, w = a.shape[:2]
    ya = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    yb = 0.299 * b[..., 0] + 0.587 * b[..., 1] + 0.114 * b[..., 2]
    wt = np.ones((h, w))
    yy, xx = np.mgrid[0:h, 0:w]
    for (fx, fy, fw, fh) in faces:
        cx, cy = (fx + fw / 2) * w, (fy + fh / 2) * h
        rx, ry = fw * w * 0.62, fh * h * 0.72
        if rx < 1 or ry < 1:
            continue
        d = np.sqrt(((xx + 0.5 - cx) / rx) ** 2 + ((yy + 0.5 - cy) / ry) ** 2)
        t = np.clip((d - 0.75) / 0.25, 0, 1)
        wt = np.minimum(wt, face_ai + (1 - face_ai) * t * t * (3 - 2 * t))
    out = b + ((ya - yb) * wt)[..., None]
    return Image.fromarray(np.clip(np.round(out), 0, 255).astype(np.uint8))


def faces_of(img):
    import cv2
    g = cv2.cvtColor(np.asarray(img), cv2.COLOR_RGB2GRAY)
    c = cv2.CascadeClassifier(os.path.join(cv2.data.haarcascades,
                                           "haarcascade_frontalface_default.xml"))
    w, h = img.size
    r = c.detectMultiScale(g, 1.1, 6, minSize=(int(0.08 * min(w, h)),) * 2)
    return [(x / w, y / h, fw / w, fh / h) for (x, y, fw, fh) in r]


def thumb(images, labels, out, height=150):
    from PIL import ImageDraw
    ims = [im.resize((max(1, int(im.width * height / im.height)), height), Image.LANCZOS)
           for im in images]
    W = sum(i.width for i in ims) + 4 * (len(ims) - 1)
    sheet = Image.new("RGB", (W, height + 16), (255, 255, 255))
    x = 0
    d = ImageDraw.Draw(sheet)
    for im, lab in zip(ims, labels):
        sheet.paste(im, (x, 16))
        d.text((x + 3, 2), lab, fill=(0, 0, 0))
        x += im.width + 4
    sheet.save(out, "JPEG", quality=72, optimize=True)


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--photos", required=True)
    ap.add_argument("--ps-eval", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--work", default="/tmp/ps_eval_work")
    a = ap.parse_args()
    import onnxruntime as ort
    os.makedirs(a.work, exist_ok=True)
    os.makedirs(os.path.join(a.out, "thumbs"), exist_ok=True)
    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    so.inter_op_num_threads = 1
    sess = ort.InferenceSession(a.model, so, providers=["CPUExecutionProvider"])
    sources = json.load(open(os.path.join(a.photos, "sources.json")))
    rows = []
    for i, src in enumerate(sources):
        ref = Image.open(os.path.join(a.photos, src["file"])).convert("RGB")
        if max(ref.size) > 800:
            f = 800 / max(ref.size)
            ref = ref.resize((round(ref.width * f), round(ref.height * f)), Image.LANCZOS)
        faces = faces_of(ref)
        # ---- A: classical on a degraded copy
        deg = degrade(ref, i)
        inp = os.path.join(a.work, "in.rgba")
        to_rgba_file(deg, inp)
        fa = ";".join(",".join("%.4f" % v for v in f) for f in faces)
        res = subprocess.run([a.ps_eval, inp, os.path.join(a.work, "out"), fa],
                             capture_output=True, text=True, check=True)
        ms = {json.loads(l)["level"]: json.loads(l)["ms"] for l in res.stdout.split("\n") if l.strip()}
        lv = {k: from_rgba_file(os.path.join(a.work, "out_%s.rgba" % k))
              for k in ("light", "natural", "strong")}
        # ---- B: AI restore/upscale of a 1/2 copy (old / small photo)
        small = jpeg(ref.resize((max(1, ref.width // 2), max(1, ref.height // 2)), Image.LANCZOS), 75)
        sz = (small.width * 2, small.height * 2)
        refc = ref.crop((0, 0) + sz)
        bicc = small.resize(sz, Image.BICUBIC)
        t0 = time.time()
        sr4, ntiles = tile_upscale(sess, small)
        ai_s = time.time() - t0
        base4 = small.resize(sr4.size, Image.BILINEAR)
        sfaces = faces_of(small.resize(sz, Image.BICUBIC))
        shipped = merge_keep_faces(sr4, base4, sfaces).resize(sz, Image.LANCZOS)
        sr = sr4.resize(sz, Image.LANCZOS)
        # shipped AI + Natural classical pass (what the phone does)
        to_rgba_file(shipped, inp)
        subprocess.run([a.ps_eval, inp, os.path.join(a.work, "sr"), fa],
                       capture_output=True, text=True, check=True)
        srn = from_rgba_file(os.path.join(a.work, "sr_natural.rgba"))
        faces_sr = faces_of(shipped)
        row = {
            "file": src["file"], "kind": src["kind"], "source": src["page"],
            "licence": src["licence"], "w": ref.width, "h": ref.height,
            "faces_haar": len(faces),
            "classical": {
                "psnr_degraded": round(psnr(deg, ref), 2),
                **{"psnr_" + k: round(psnr(v, ref), 2) for k, v in lv.items()},
                "cast_degraded": round(cast(deg, ref), 2),
                **{"cast_" + k: round(cast(v, ref), 2) for k, v in lv.items()},
                "sharp_ref": round(sharpness(ref), 1),
                "sharp_degraded": round(sharpness(deg), 1),
                **{"sharp_" + k: round(sharpness(v), 1) for k, v in lv.items()},
                "ms": ms,
            },
            "ai": {
                "input": [small.width, small.height], "tiles": ntiles,
                "seconds": round(ai_s, 2),
                "psnr_bicubic": round(psnr(bicc, refc), 2),
                "psnr_esrgan_raw": round(psnr(sr, refc), 2),
                "psnr_shipped": round(psnr(shipped, refc), 2),
                "psnr_shipped_natural": round(psnr(srn, refc), 2),
                "sharp_bicubic": round(sharpness(bicc), 1),
                "sharp_esrgan_raw": round(sharpness(sr), 1),
                "sharp_shipped": round(sharpness(shipped), 1),
                "sharp_ref": round(sharpness(refc), 1),
                "faces_haar_after": len(faces_sr),
            },
        }
        rows.append(row)
        thumb([deg, lv["light"], lv["natural"], lv["strong"], bicc, shipped],
              ["degraded", "light", "natural", "strong", "1/2 -> bicubic", "1/2 -> AI step"],
              os.path.join(a.out, "thumbs", "%02d.jpg" % (i + 1)))
        print(json.dumps(row), flush=True)
    json.dump(rows, open(os.path.join(a.out, "results.json"), "w"), indent=1)


if __name__ == "__main__":
    sys.exit(main())
