"""Owner FINAL brand icon "C": white logo on a #007AFF -> #10C978 diagonal
gradient (owner files in ~/assisto_icon_C/). Builds every app asset from it.

The owner's adaptive_foreground_white_1024.png reached 0.371 of the canvas from
the centre (a circle launcher shows 0.333), so circle masks would cut the A's
feet. The foreground is therefore rebuilt from logo_white_transparent.png by
its smallest enclosing circle (same method as icon_fit.py).

usage: icon_c.py <owner_dir> <repo_app_dir> <check_out_dir>
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SRC_DIR, APP, CHECK = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
CHECK.mkdir(parents=True, exist_ok=True)
BG = Image.open(SRC_DIR / "adaptive_background_1024.png").convert("RGB")
WHITE = Image.open(SRC_DIR / "logo_white_transparent.png").convert("RGBA")
SPLASH12 = (0x0A, 0x9B, 0xD0)


def enclosing_circle(img):
    a = np.asarray(img.getchannel("A"))
    ys, xs = np.nonzero(a > 24)
    rows = {}
    for x, y in zip(xs, ys):
        lo, hi = rows.get(y, (x, x))
        rows[y] = (min(lo, x), max(hi, x))
    edge = np.array([(lo, y) for y, (lo, hi) in rows.items()] +
                    [(hi, y) for y, (lo, hi) in rows.items()], dtype=np.float64)
    best = ((xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2, 0.0)
    best = (best[0], best[1], np.sqrt(((edge - best[:2]) ** 2).sum(1)).max())
    step = max(img.size) * 0.05
    while step > 0.5:
        moved = False
        for dx in (-step, 0, step):
            for dy in (-step, 0, step):
                c = (best[0] + dx, best[1] + dy)
                r = np.sqrt(((edge - c) ** 2).sum(1)).max()
                if r < best[2] - 1e-6:
                    best, moved = (c[0], c[1], r), True
        if not moved:
            step /= 2
    return best


CX, CY, R = enclosing_circle(WHITE)


def place(logo, canvas, circle_frac, under=None):
    k = (circle_frac * canvas / 2) / R
    lg = logo.resize((round(logo.width * k), round(logo.height * k)), Image.LANCZOS)
    c = under.copy().convert("RGBA") if under is not None else Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    c.alpha_composite(lg, (round(canvas / 2 - CX * k), round(canvas / 2 - CY * k)))
    return c


icon = APP / "assets" / "icon"
brand = APP / "assets" / "branding"
# adaptive: gradient background + white foreground (circle 0.645 of canvas)
BG.save(icon / "bg.png", optimize=True)
fg = place(WHITE, 1024, 0.645)
fg.save(icon / "fg.png", optimize=True)
fg.save(icon / "monochrome.png", optimize=True)          # themed icon (Android 13+)
# legacy square/round icon: gradient + logo, round-safe
place(WHITE, 1024, 0.80, BG.resize((1024, 1024))).convert("RGB").save(icon / "icon.png", optimize=True)
# splash 12+: white logo inside the inner 2/3 circle, transparent (bg colour from pubspec)
place(WHITE, 1152, 0.62).save(brand / "splash_logo.png", optimize=True)
# splash <12: gradient background image (full screen) + same white logo image
BG.resize((1080, 1080)).save(brand / "splash_bg.png", optimize=True)
# in-app tile: gradient square + white logo, safe for ClipOval/rounded/cover
tile = place(WHITE, 512, 0.84, BG.resize((512, 512)))
tile.save(brand / "new_logo.png", optimize=True)
tile.save(icon / "new_logo.png", optimize=True)
place(WHITE, 1024, 0.86).save(brand / "logo.png", optimize=True)   # white, transparent
# notification small icon: white silhouette on transparent, Android sizes (24dp)
res = APP / "android_overlay" / "app" / "src" / "main" / "res"
for d, px in {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}.items():
    out = res / f"drawable-{d}"
    out.mkdir(parents=True, exist_ok=True)
    place(WHITE, px * 4, 0.92).resize((px, px), Image.LANCZOS).save(out / "ic_stat_assisto.png", optimize=True)


# ---- verification sheet + numeric proof ----
def mask(img, shape, size=256):
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
    o = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    o.paste(im, (0, 0), m)
    return o


full = BG.convert("RGBA").resize((1024, 1024))
full.alpha_composite(fg)
s = 1024
ad = full.crop((round(s * 18 / 108), round(s * 18 / 108), round(s * 90 / 108), round(s * 90 / 108)))
sp = Image.new("RGBA", (1152, 1152), (*SPLASH12, 255))
sp.alpha_composite(Image.open(brand / "splash_logo.png"))
sp_in = sp.crop((192, 192, 960, 960))
tiles = [("launcher circle", mask(ad, "circle")), ("squircle (Samsung/ColorOS)", mask(ad, "squircle")),
         ("rounded square (Xiaomi)", mask(ad, "rounded")), ("teardrop", mask(ad, "teardrop")),
         ("in-app ClipOval", mask(tile, "circle")), ("splash 12+ (#0A9BD0)", mask(sp_in, "circle"))]
sheet = Image.new("RGB", (len(tiles) * 280 + 20, 640), (232, 236, 244))
d = ImageDraw.Draw(sheet)
for i, (lab, t) in enumerate(tiles):
    sheet.paste(t, (20 + i * 280, 40), t)
    d.text((20 + i * 280, 14), lab, fill=(20, 20, 40))
legacy = BG.resize((240, 300))
lg = Image.open(brand / "splash_logo.png").resize((180, 180), Image.LANCZOS)
legacy.paste(lg, (30, 60), lg)
sheet.paste(legacy, (20, 330))
d.text((20, 310), "splash Android 11 and older (gradient)", fill=(20, 20, 40))
mono = Image.new("RGBA", (256, 256), (40, 44, 52, 255))
mono.alpha_composite(mask(Image.open(icon / "monochrome.png").resize((1024, 1024)).crop(
    (round(s * 18 / 108),) * 2 + (round(s * 90 / 108),) * 2), "circle"))
sheet.paste(mono, (300, 330))
d.text((300, 310), "themed (monochrome) icon", fill=(20, 20, 40))
n = Image.open(res / "drawable-xxxhdpi" / "ic_stat_assisto.png")
nb = Image.new("RGBA", (120, 120), (60, 60, 60, 255))
nb.alpha_composite(n.resize((96, 96), Image.NEAREST), (12, 12))
sheet.paste(nb, (580, 330))
d.text((580, 310), "notification icon", fill=(20, 20, 40))
sheet.save(CHECK / "mask_check_C.png")
a = np.asarray(fg.getchannel("A")).astype(float)
yy, xx = np.mgrid[0:s, 0:s]
d2 = (xx - s / 2) ** 2 + (yy - s / 2) ** 2
print("fg px outside 72dp circle:", int((a[d2 > (s * 36 / 108) ** 2] > 24).sum()))
