"""Mask-safe icon variants (owner bug 23 Oct: splash cropped the A).

Every launcher shape (circle, squircle, rounded square) and the Android 12+
splash mask a CIRCLE out of the icon. So the logo is placed by its smallest
enclosing circle — not its bounding box (the A's feet sit in the corners).

  adaptive fg   : enclosing circle <= 66/108 of the canvas (Android safe zone)
  splash (12+)  : enclosing circle <= 2/3 of the canvas (inner circle of 288dp)
  in-app tile   : navy square, logo circle <= 84% (ClipOval / rounded / cover)

usage: icon_fit.py <logo_transparent.png> <out_dir> <navy_hex>
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SRC, OUT, NAVY = Image.open(sys.argv[1]).convert("RGBA"), Path(sys.argv[2]), sys.argv[3]
OUT.mkdir(parents=True, exist_ok=True)
NAVY_RGB = tuple(int(NAVY.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))


def enclosing_circle(img):
    """Approximate minimal enclosing circle of the visible pixels (alpha>24):
    grid-search the centre minimising the max distance. Returns (cx, cy, r)."""
    a = np.asarray(img.getchannel("A"))
    ys, xs = np.nonzero(a > 24)
    pts = np.stack([xs, ys], 1).astype(np.float64)
    # keep only boundary-ish points (extremes per row) to make it fast
    order = np.lexsort((xs, ys))
    pts = pts[order]
    rows = {}
    for x, y in pts:
        lo, hi = rows.get(y, (x, x))
        rows[y] = (min(lo, x), max(hi, x))
    edge = np.array([(lo, y) for y, (lo, hi) in rows.items()] +
                    [(hi, y) for y, (lo, hi) in rows.items()])
    cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
    step = max(img.size) * 0.05
    best = (cx, cy, np.sqrt(((edge - (cx, cy)) ** 2).sum(1)).max())
    while step > 0.5:
        improved = False
        for dx in (-step, 0, step):
            for dy in (-step, 0, step):
                c = (best[0] + dx, best[1] + dy)
                r = np.sqrt(((edge - c) ** 2).sum(1)).max()
                if r < best[2] - 1e-6:
                    best, improved = (c[0], c[1], r), True
        if not improved:
            step /= 2
    return best


CX, CY, R = enclosing_circle(SRC)


def place(canvas, circle_frac, bg=None):
    """Logo scaled so its enclosing circle has diameter circle_frac*canvas,
    with that circle centred on the canvas."""
    k = (circle_frac * canvas / 2) / R
    lg = SRC.resize((round(SRC.width * k), round(SRC.height * k)), Image.LANCZOS)
    c = Image.new("RGBA", (canvas, canvas), (*bg, 255) if bg else (0, 0, 0, 0))
    c.alpha_composite(lg, (round(canvas / 2 - CX * k), round(canvas / 2 - CY * k)))
    return c


# Adaptive foreground. Launchers show the central 72/108 (0.667) and mask a
# circle there at the smallest; Android's strict safe zone is 66/108 (0.611).
# Owner (23 Oct): A looked small on OPPO -> as big as possible while every
# mask (circle, squircle, rounded square, teardrop) still shows the whole A:
# its enclosing circle = 0.645 of the canvas (inside the owner's 66%).
place(1024, 0.645).save(OUT / "fg.png", optimize=True)
Image.new("RGB", (1024, 1024), NAVY_RGB).save(OUT / "bg.png")
# Legacy (pre-8.0) square icon: also round-safe (some launchers round it).
place(1024, 0.80, NAVY_RGB).convert("RGB").save(OUT / "icon.png", optimize=True)
# Splash: Android 12+ shows the icon inside a circle of 2/3 of the 288dp area.
# 1152px = 288dp @ xxxhdpi; logo circle <= 2/3 with margin -> 0.62.
place(1152, 0.62).save(OUT / "splash_logo.png", optimize=True)
# In-app tile (ClipOval / rounded square / BoxFit.cover): square navy tile.
place(512, 0.84, NAVY_RGB).save(OUT / "new_logo.png", optimize=True)
# Play Store icon (Play rounds corners ~ 20%): round-safe as well.
place(512, 0.84, NAVY_RGB).save(OUT / "icon_512.png", optimize=True)


# ---- verification sheet: every mask the owner listed ----
def masked(img, shape, size=256):
    im = img.convert("RGBA").resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    if shape == "circle":
        d.ellipse((0, 0, size - 1, size - 1), fill=255)
    elif shape == "teardrop":
        d.ellipse((0, 0, size - 1, size - 1), fill=255)
        d.rectangle((size // 2, size // 2, size - 1, size - 1), fill=255)
    elif shape == "squircle":
        d.rounded_rectangle((0, 0, size - 1, size - 1), size * 0.32, fill=255)
    else:
        d.rounded_rectangle((0, 0, size - 1, size - 1), size * 0.16, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(im, (0, 0), m)
    return out


def adaptive(fg_img, size=256):
    # launchers show the central 72/108 of the 108dp layers
    full = Image.new("RGBA", fg_img.size, (*NAVY_RGB, 255))
    full.alpha_composite(fg_img)
    s = fg_img.width
    crop = full.crop((round(s * 18 / 108), round(s * 18 / 108),
                      round(s * 90 / 108), round(s * 90 / 108)))
    return crop


fg = Image.open(OUT / "fg.png")
sp = Image.open(OUT / "splash_logo.png")
sheet = Image.new("RGB", (7 * 280 + 20, 2 * 300 + 60), (232, 236, 244))
d = ImageDraw.Draw(sheet)
labels = ["launcher circle", "launcher squircle", "launcher rounded", "launcher teardrop",
          "Play 512 rounded", "in-app ClipOval", "splash 12+ circle"]
ad = adaptive(fg)
tiles = [masked(ad, "circle"), masked(ad, "squircle"), masked(ad, "rounded"), masked(ad, "teardrop"),
         masked(Image.open(OUT / "icon_512.png"), "rounded"),
         masked(Image.open(OUT / "new_logo.png"), "circle")]
# splash: navy screen, icon area 288dp shown, masked to its inner 2/3 circle
sp_bg = Image.new("RGBA", sp.size, (*NAVY_RGB, 255))
sp_bg.alpha_composite(sp)
s = sp.width
inner = sp_bg.crop((round(s / 6), round(s / 6), round(s * 5 / 6), round(s * 5 / 6)))
tiles.append(masked(inner, "circle"))
for i, t in enumerate(tiles):
    x = 20 + i * 280
    sheet.paste(t, (x, 40), t)
    d.text((x, 12), labels[i], fill=(20, 20, 40))
# phone splash mock (Android 11-: whole image centred on navy)
mock = Image.new("RGB", (240, 300), NAVY_RGB)
spm = sp.resize((180, 180), Image.LANCZOS)
mock.paste(spm, (30, 60), spm)
sheet.paste(mock, (20, 360))
d.text((20, 335), "splash Android 11 and older (full image)", fill=(20, 20, 40))
sheet.save(OUT / "mask_check.png")
# numeric proof: logo alpha that the smallest mask (72dp circle) would cut
a = np.asarray(ad.getchannel("A") if ad.mode == "RGBA" else Image.new("L", ad.size, 0))
fga = np.asarray(fg.getchannel("A")).astype(float)
s0 = fg.width
yy, xx = np.mgrid[0:s0, 0:s0]
outside = ((xx - s0 / 2) ** 2 + (yy - s0 / 2) ** 2) > (s0 * 36 / 108) ** 2
print("logo pixels outside the 72dp circle mask:", int((fga[outside] > 24).sum()),
      "| outside the 66dp safe circle:", int((fga[((xx - s0/2)**2 + (yy - s0/2)**2) > (s0*33/108)**2] > 24).sum()))
print("enclosing circle r=%.1f centre=(%.1f,%.1f) of %s" % (R, CX, CY, SRC.size))
