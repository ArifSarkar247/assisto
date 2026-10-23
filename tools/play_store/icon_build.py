"""Build every icon variant from the owner's final logo.

1. Real-ESRGAN x4 (BSD, our cleared model) upscale of the 390x337 source.
2. Key the uniform dark background out (alpha from colour distance,
   colour un-premultiplied) -> clean transparent logo.
3. Emit: app/assets/icon/{icon,fg,bg}.png (1024), branding/new_logo.png,
   branding/logo.png (transparent 1024), Play icon_512.png.
"""
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort  # pip install onnxruntime numpy pillow (scratch venv)
from PIL import Image, ImageFilter

SRC, MODEL, OUT = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
OUT.mkdir(parents=True, exist_ok=True)


def upscale(img):
    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    x = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = x.shape
    tile, pad, s = 128, 8, 4   # model input is fixed 144 = 128 + 2*pad
    out = np.zeros((h * s, w * s, 3), np.float32)
    for y0 in range(0, h, tile):
        for x0 in range(0, w, tile):
            y1, x1 = min(y0 + tile, h), min(x0 + tile, w)
            ya, xa = max(y0 - pad, 0), max(x0 - pad, 0)
            yb, xb = min(y1 + pad, h), min(x1 + pad, w)
            t = x[ya:yb, xa:xb].transpose(2, 0, 1)[None]
            th, tw = t.shape[2], t.shape[3]
            # model expects the fixed tile size: pad with edge pixels
            ph, pw = tile + 2 * pad - th, tile + 2 * pad - tw
            t = np.pad(t, ((0, 0), (0, 0), (0, ph), (0, pw)), mode="edge")
            r = sess.run(None, {"input": t})[0][0].transpose(1, 2, 0)
            r = r[:th * s, :tw * s]
            oy, ox = (y0 - ya) * s, (x0 - xa) * s
            out[y0 * s:y1 * s, x0 * s:x1 * s] = r[oy:oy + (y1 - y0) * s, ox:ox + (x1 - x0) * s]
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8))


src = Image.open(SRC).convert("RGB")
big = upscale(src)
big.save(OUT / "upscaled_x4.png")

a = np.asarray(big, dtype=np.float32)
# background = median of the border ring
ring = np.concatenate([a[:6].reshape(-1, 3), a[-6:].reshape(-1, 3),
                       a[:, :6].reshape(-1, 3), a[:, -6:].reshape(-1, 3)])
bg = np.median(ring, axis=0)
print("background rgb", bg.round(1))
d = np.sqrt(((a - bg) ** 2).sum(-1))
lo, hi = 18.0, 70.0
alpha = np.clip((d - lo) / (hi - lo), 0, 1)
# inner dark outlines of the logo touch the bg colour: keep alpha where the
# pixel is enclosed by logo (closing of the alpha mask)
m = Image.fromarray((alpha * 255).astype(np.uint8))
closed = m.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MinFilter(9))
alpha = np.maximum(alpha, np.asarray(closed, np.float32) / 255.0)
af = np.clip(alpha, 1e-3, 1)[..., None]
rgb = np.clip((a - bg * (1 - af)) / af, 0, 255)
# where the closing restored opaque dark outline, keep the original dark colour
rgb = np.where(alpha[..., None] >= 0.999, a, rgb)
logo = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), "RGBA")
logo = logo.crop(logo.getbbox())
logo.save(OUT / "logo_transparent.png")
print("logo bbox size", logo.size)

BG = tuple(int(v) for v in bg)


def place(canvas, frac, bg=None):
    """Logo scaled so its larger side = frac*canvas, centred."""
    c = Image.new("RGBA", (canvas, canvas), (*bg, 255) if bg else (0, 0, 0, 0))
    k = frac * canvas / max(logo.size)
    lg = logo.resize((round(logo.width * k), round(logo.height * k)), Image.LANCZOS)
    # optical centre: the A is bottom-heavy, nudge up 2%
    c.alpha_composite(lg, ((canvas - lg.width) // 2, (canvas - lg.height) // 2 - int(0.02 * canvas)))
    return c


# Adaptive icon: 108dp canvas, safe zone = central 66dp circle -> logo <= ~58%.
place(1024, 0.56).save(OUT / "fg.png")
Image.new("RGB", (1024, 1024), BG).save(OUT / "bg.png")
# Legacy / full icon: square, logo a bit larger.
place(1024, 0.70, BG).convert("RGB").save(OUT / "icon.png")
# Play Store 512, full-bleed square (Play rounds corners itself), 32-bit PNG.
place(512, 0.72, BG).save(OUT / "icon_512.png", optimize=True)
# In-app logo (same role/aspect as the old opaque new_logo.png), 2x crisp.
k = 780 / src.width
inapp = big.resize((780, round(src.height * k)), Image.LANCZOS)
inapp.convert("RGBA").save(OUT / "new_logo.png", optimize=True)
# Transparent 1024 logo (branding/logo.png role).
place(1024, 0.86).save(OUT / "logo.png", optimize=True)
print("BG hex #%02X%02X%02X" % BG)
