#!/usr/bin/env python3
"""staging (owner order 17 Nov): put an orange "TEST" badge on the launcher
icon sources of the "Assisto Test" app, IN PLACE, inside the CI checkout only
(the staging job runs it before `dart run flutter_launcher_icons`). Never run
it on a production build and never commit its output.

usage: staging_icon_badge.py <app/assets/icon dir>

  icon.png        legacy square icon   -> badge across the bottom
  fg.png          adaptive foreground  -> badge inside the 66/108 safe circle
  monochrome.png  themed (Android 13+) -> same shape, solid (system tints it)
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ORANGE = (255, 122, 0, 255)      # #FF7A00
WHITE = (255, 255, 255, 255)
FONTS = ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
         "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf")


def _font(px):
    for f in FONTS:
        if os.path.exists(f):
            return ImageFont.truetype(f, px)
    return ImageFont.load_default(size=px)   # Pillow >= 10.1


def badge(path, box, solid=False):
    """box = (cx, cy, w, h) as fractions of the canvas."""
    im = Image.open(path).convert("RGBA")
    W, H = im.size
    cx, cy, bw, bh = box
    w, h = int(W * bw), int(H * bh)
    x0, y0 = int(W * cx - w / 2), int(H * cy - h / 2)
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # white outline ring so the badge reads on the brand gradient too
    ring = max(4, h // 12)
    d.rounded_rectangle((x0 - ring, y0 - ring, x0 + w + ring, y0 + h + ring),
                        radius=(h + 2 * ring) // 2, fill=WHITE)
    d.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=h // 2,
                        fill=WHITE if solid else ORANGE)
    f = _font(int(h * 0.62))
    t = "TEST"
    l, tp, r, b = d.textbbox((0, 0), t, font=f)
    tx = x0 + (w - (r - l)) / 2 - l
    ty = y0 + (h - (b - tp)) / 2 - tp
    if solid:
        # monochrome: punch the letters out (themed icons are one colour)
        # (ImageDraw replaces RGBA pixels, so alpha 0 cuts the text out)
        d.text((tx, ty), t, font=f, fill=(0, 0, 0, 0))
    else:
        d.text((tx, ty), t, font=f, fill=WHITE)
    out = Image.alpha_composite(im, layer)
    if Image.open(path).mode == "RGB":
        out = out.convert("RGB")
    out.save(path)
    print("TEST badge ->", path)


def main(d):
    badge(os.path.join(d, "icon.png"), (0.5, 0.84, 0.62, 0.17))
    # adaptive: the launcher masks to the central 66/108 (61%) circle; keep
    # the badge inside it (centre 0.5 +- 0.305) so no mask clips "TEST".
    badge(os.path.join(d, "fg.png"), (0.5, 0.70, 0.40, 0.11))
    mono = os.path.join(d, "monochrome.png")
    if os.path.exists(mono):
        badge(mono, (0.5, 0.70, 0.40, 0.11), solid=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "app/assets/icon")
