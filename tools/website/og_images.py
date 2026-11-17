#!/usr/bin/env python3
"""seogrow (owner order 17 Nov 00:32, item 3): one 1200x630 share image per
feature landing page and language for Facebook / WhatsApp / X previews.

  python tools/website/og_images.py      # writes backend/web/site_assets/og/<slug>-<bn|en>.jpg

Brand style = the site-wide og-bn.jpg (diagonal blue -> green gradient, the
Assisto icon, white text) + a REAL app screenshot (the landing page's first
gallery shot that needs no extra flag, site_assets/shots3/*_720.webp) in a
phone frame. Bangla is shaped with libraqm (Pillow's RAQM layout) and the
Noto Sans Bengali font the app ships; Latin runs use Inter. Needs Pillow with
raqm (pip install Pillow; libraqm0 on the box / CI runner).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, features

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from web import site_landing as LP  # noqa: E402

ASSETS = ROOT / "backend" / "web" / "site_assets"
OUT = ASSETS / "og"
FONTS = ROOT / "app" / "assets" / "fonts"
W, H = 1200, 630
C0, C1 = (0, 122, 252), (14, 199, 121)


def _font(bn, size, bold=True):
    name = ("NotoSansBengali-Bold.ttf" if bold else "NotoSansBengali-Medium.ttf") if bn else \
        ("Inter-Bold.ttf" if bold else "Inter-Medium.ttf")
    return ImageFont.truetype(str(FONTS / name), size, layout_engine=ImageFont.Layout.RAQM)


def _is_bn(ch):
    o = ord(ch)
    return 0x0980 <= o <= 0x09FF or o in (0x0964, 0x0965, 0x200C, 0x200D)


def _runs(text):
    """Split into (is_bangla, text) runs. Bengali letters, signs and the
    danda use Noto Sans Bengali; everything else (Latin, digits, spaces,
    comma, middle dot ...) uses Inter — the Bengali font has no glyph for
    some punctuation (it drew a box for "," and "·")."""
    out = []
    for ch in text:
        kind = _is_bn(ch)
        if out and out[-1][0] == kind:
            out[-1][1] += ch
        else:
            out.append([kind, ch])
    return out


def _width(text, size, bold=True):
    return sum(_font(k, size, bold).getlength(t) for k, t in _runs(text))


def _draw(d, xy, text, size, fill, bold=True):
    x, y = xy
    for k, t in _runs(text):
        f = _font(k, size, bold)
        d.text((x, y), t, font=f, fill=fill)
        x += f.getlength(t)


def _wrap(text, size, max_w, bold=True):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if _width(t, size, bold) <= max_w or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def _gradient():
    g = Image.new("RGB", (W, H))
    px = g.load()
    for y in range(H):
        for x in range(W):
            t = (x / W * 0.65 + y / H * 0.35)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(C0, C1))
    return g


def _phone(shot):
    """Real screenshot in a dark rounded phone frame, 300 px wide."""
    im = Image.open(shot).convert("RGB")
    sw = 276
    sh = round(im.height * sw / im.width)
    im = im.resize((sw, sh), Image.LANCZOS)
    bw, bh = sw + 24, sh + 24
    frame = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle((0, 0, bw - 1, bh - 1), radius=44, fill=(14, 20, 38, 255))
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=32, fill=255)
    frame.paste(im, (12, 12), mask)
    return frame


def _shot_for(slug):
    d = LP.LANDINGS[slug]
    for s in d["shots"]:
        if not s["flags"]:
            return s["name"]
    return None


def render(slug, lang):
    d = LP.LANDINGS[slug]
    t = d[lang]
    bn = lang == "bn"
    img = _gradient()
    shot = _shot_for(slug)
    text_w = 640 if shot else 1040
    if shot:
        p = _phone(ASSETS / "shots3" / ("%s_%s_720.webp" % (shot, lang)))
        sh = Image.new("RGBA", (p.width + 60, p.height + 60), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((30, 40, p.width + 30, p.height + 30), radius=44, fill=(0, 0, 0, 90))
        sh = sh.filter(ImageFilter.GaussianBlur(14))
        img.paste(sh, (835, 40), sh)
        img.paste(p, (865, 66), p)   # bottom of the phone runs off the image, like og-bn.jpg
    logo = Image.open(ASSETS / "icon-512.png").convert("RGBA").resize((88, 88), Image.LANCZOS)
    m = Image.new("L", logo.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, 87, 87), radius=22, fill=255)
    img.paste(logo, (72, 64), m)
    d0 = ImageDraw.Draw(img)
    _draw(d0, (180, 72), "Assisto", 58, (255, 255, 255))
    # headline: the feature name; then the promise from the H1 (after ":")
    name = t["name"]
    tag = t["h1"].split(":", 1)[1].strip() if ":" in t["h1"] else t["lead"]
    tag = tag[:1].upper() + tag[1:]
    y = 210
    size = 76 if _width(name, 76) <= text_w else 60
    _draw(d0, (72, y), name, size, (255, 255, 255))
    y += int(size * 1.45)
    for line in _wrap(tag, 40, text_w)[:3]:
        _draw(d0, (72, y), line, 40, (255, 255, 255), bold=False)
        y += 62
    foot = ("বাংলায় · Android · lifeassisto.com" if bn else "Bangla + English · Android · lifeassisto.com")
    _draw(d0, (72, 548), foot, 28, (235, 245, 255), bold=False)
    return img


def main():
    if not features.check("raqm"):
        print("Pillow has no raqm: Bangla would be shaped wrongly — refusing")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for slug in LP.SLUGS:
        for lang in ("bn", "en"):
            dst = OUT / ("%s-%s.jpg" % (slug, lang))
            render(slug, lang).save(dst, "JPEG", quality=84, optimize=True, progressive=True)
            print(dst.relative_to(ROOT), dst.stat().st_size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
