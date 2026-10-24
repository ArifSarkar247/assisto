#!/usr/bin/env python3
"""Phase 2 "Assisto Face" — synthetic degradation pipeline (NOT RUN here).

Turns a clean face crop into the photos our users really have, so the model
learns to undo exactly that:
  cheap phone camera   sensor noise (shot + read), over-sharpening halo,
                       beauty-mode smear, small resolution
  low light            gamma darkening, colour cast, strong chroma noise
  WhatsApp             1-2 rounds of resize to <= 1600 px + JPEG q35-70
  old album            sepia/fade, dust, scratches, paper grain, blur
  motion / focus       small motion kernel or Gaussian blur
Skin colour is NEVER shifted lighter in the target: targets are the clean
originals as they are (no whitening is learned).

  python3 degrade.py <clean_dir> <out_dir> [--per-image 4] [--seed 1]
"""
import argparse
import io
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def _jpeg(im, q):
    b = io.BytesIO()
    im.save(b, "JPEG", quality=int(q))
    return Image.open(io.BytesIO(b.getvalue())).convert("RGB")


def cheap_camera(a, rng):
    h, w = a.shape[:2]
    a = a + rng.normal(0, rng.uniform(0.01, 0.04), a.shape) * np.sqrt(np.clip(a, 0.02, 1))
    im = Image.fromarray(np.uint8(np.clip(a, 0, 1) * 255))
    if rng.random() < 0.5:                                 # phone over-sharpening
        im = im.filter(ImageFilter.UnsharpMask(radius=2, percent=int(rng.uniform(80, 200)), threshold=2))
    if rng.random() < 0.4:                                 # "beauty mode" smear
        im = im.filter(ImageFilter.SMOOTH_MORE)
    f = rng.uniform(0.35, 0.8)
    return im.resize((max(16, int(w * f)), max(16, int(h * f))), Image.BILINEAR)


def low_light(a, rng):
    g = rng.uniform(1.6, 2.6)
    k = rng.uniform(0.25, 0.55)
    cast = 1 + rng.uniform(-0.08, 0.08, 3)
    a = (a ** g) * k * cast
    a = a + rng.normal(0, rng.uniform(0.02, 0.05), a.shape)
    return Image.fromarray(np.uint8(np.clip(a, 0, 1) * 255))


def whatsapp(im, rng):
    for _ in range(int(rng.integers(1, 3))):
        m = max(im.size)
        if m > 1600:
            f = 1600 / m
            im = im.resize((int(im.width * f), int(im.height * f)), Image.BILINEAR)
        im = _jpeg(im, rng.uniform(35, 70))
    return im


def old_album(a, rng):
    y = a @ np.array([0.299, 0.587, 0.114])
    sep = np.stack([y + 0.06, y * 0.9 + 0.04, y * 0.72 + 0.02], -1)
    sep = rng.uniform(0.08, 0.2) + rng.uniform(0.6, 0.8) * np.clip(sep, 0, 1)
    im = Image.fromarray(np.uint8(np.clip(sep, 0, 1) * 255))
    d = ImageDraw.Draw(im)
    w, h = im.size
    for _ in range(int(rng.integers(2, 10))):
        x0 = int(rng.integers(0, w))
        d.line([(x0, 0), (x0 + int(rng.integers(-40, 40)), h)], fill=(235, 230, 215), width=1)
    for _ in range(int(rng.integers(40, 200))):
        x, yy, r = int(rng.integers(0, w)), int(rng.integers(0, h)), int(rng.integers(1, 3))
        d.ellipse([x - r, yy - r, x + r, yy + r], fill=(30, 25, 20) if rng.random() < .5 else (240, 235, 225))
    return im.filter(ImageFilter.GaussianBlur(rng.uniform(0.5, 1.5)))


def blur(im, rng):
    return im.filter(ImageFilter.GaussianBlur(rng.uniform(0.8, 2.5)))


def degrade(clean, rng):
    a = np.asarray(clean.convert("RGB"), np.float32) / 255.0
    kind = rng.choice(["camera", "low_light", "old", "blur"], p=[0.4, 0.25, 0.15, 0.2])
    im = {"camera": lambda: cheap_camera(a, rng), "low_light": lambda: low_light(a, rng),
          "old": lambda: old_album(a, rng),
          "blur": lambda: blur(clean.convert("RGB"), rng)}[kind]()
    if rng.random() < 0.7:
        im = whatsapp(im, rng)
    return im, kind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clean")
    ap.add_argument("out")
    ap.add_argument("--per-image", type=int, default=4)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    os.makedirs(os.path.join(a.out, "lq"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "hq"), exist_ok=True)
    for n in sorted(os.listdir(a.clean)):
        try:
            clean = Image.open(os.path.join(a.clean, n)).convert("RGB")
        except Exception:
            continue
        stem = os.path.splitext(n)[0]
        clean.save(os.path.join(a.out, "hq", stem + ".png"))
        for i in range(a.per_image):
            lq, kind = degrade(clean, rng)
            lq.save(os.path.join(a.out, "lq", "%s_%d_%s.jpg" % (stem, i, kind)), quality=95)


if __name__ == "__main__":
    main()
