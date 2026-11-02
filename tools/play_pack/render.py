#!/usr/bin/env python3
"""Play listing pack images (owner order 3 Nov) — CI ONLY (.github/workflows/
play-pack.yml), never on the server.

    python3 tools/play_pack/render.py --shots <dir>[:<dir>...] --out <dir>

* 8 phone screenshots per language, 1080 x 1920 (Play: max side <= 2 x min
  side, so 1080 x 2340 is NOT accepted), each a REAL app screen from the CI
  gallery (app/test/screenshots_test.dart -> checks.yml artifacts shots-*,
  file <name>_<lang>_light.png). When no artifact is given the website's
  committed copy of the same gallery shot is used
  (backend/web/site_assets/shots3/<name>_<lang>_720.webp).
* feature graphic 1024 x 500 per language with the website hero headline +
  slogan.
* the look of website v3: navy #0B1020, indigo -> teal gradient, Inter for
  Latin + Noto Sans Bengali for Bangla, picked per character run like the
  site's unicode-range, so the taka sign U+09F3 never falls back to a letter.
* every headline is fitted by measuring: if it cannot fit the safe area in
  2 lines at the minimum size the run FAILS (no title is ever cut). Every
  character is checked against the chosen font's cmap (no tofu boxes).
* the screenshot is never cropped or squeezed: scaled to fit, aspect kept.
Outputs JPEG (Play accepts 24-bit JPEG up to 8 MB) + preview.jpg + sources.txt.
"""
import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, features

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "owner_actions" / "PLAY_LISTING_PACK"
FONTS = ROOT / "app" / "assets" / "fonts"
ICON = ROOT / "backend" / "web" / "site_assets" / "icon-512.png"
SITE_SHOTS = ROOT / "backend" / "web" / "site_assets" / "shots3"

NAVY = (11, 16, 32)          # --navy  #0B1020
INK = (238, 241, 250)        # --ink-on-navy
INK2 = (180, 188, 214)       # --ink2-on-navy
INDIGO = (79, 70, 229)       # --grad start #4F46E5
TEAL = (15, 118, 110)        # --grad end   #0F766E
ACC_A = (165, 180, 252)      # dark-mode accents (text on navy, AA contrast)
ACC_B = (94, 234, 212)

FACE = {  # weight -> (latin, bangla)
    "bold": (FONTS / "Inter-Bold.ttf", FONTS / "NotoSansBengali-Bold.ttf"),
    "semi": (FONTS / "Inter-SemiBold.ttf", FONTS / "NotoSansBengali-SemiBold.ttf"),
    "medium": (FONTS / "Inter-Medium.ttf", FONTS / "NotoSansBengali-Medium.ttf"),
}
JPEG = dict(quality=88, subsampling=0, optimize=True, progressive=True)


def is_bn(ch):
    o = ord(ch)
    return 0x0980 <= o <= 0x09FF or o in (0x0964, 0x0965, 0x200C, 0x200D)


_CMAPS = {}


def cmap(path):
    if path not in _CMAPS:
        from fontTools.ttLib import TTFont
        _CMAPS[path] = set(TTFont(str(path)).getBestCmap().keys())
    return _CMAPS[path]


class Type:
    """Mixed Latin + Bangla text at one size: Inter for Latin runs, Noto Sans
    Bengali for Bangla runs, drawn on a shared baseline."""

    def __init__(self, weight, size):
        self.size = size
        lat, bn = FACE[weight]
        self.paths = (lat, bn)
        lay = ImageFont.Layout.RAQM
        self.f = (ImageFont.truetype(str(lat), size, layout_engine=lay),
                  ImageFont.truetype(str(bn), size, layout_engine=lay))

    def runs(self, text):
        out, cur, kind = [], "", None
        for ch in text:
            k = 1 if is_bn(ch) else (kind if ch == " " and kind is not None else 0)
            if kind is None or k == kind:
                cur += ch
            else:
                out.append((kind, cur))
                cur = ch
            kind = k
        if cur:
            out.append((kind, cur))
        for k, r in out:
            missing = [c for c in r if c != " " and ord(c) not in cmap(self.paths[k])]
            if missing:
                raise SystemExit("FAIL glyph missing in %s: %r (text %r)" % (self.paths[k].name, missing, text))
        return out

    def width(self, text):
        return sum(self.f[k].getlength(r) for k, r in self.runs(text))

    def draw(self, d, x, baseline, text, fill):
        for k, r in self.runs(text):
            d.text((x, baseline), r, font=self.f[k], fill=fill, anchor="ls")
            x += self.f[k].getlength(r)


def wrap(t, text, max_w):
    lines, cur = [], ""
    for w in text.split(" "):
        cand = (cur + " " + w).strip()
        if not cur or t.width(cand) <= max_w:
            cur = cand
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def fit(text, weight, size, min_size, max_w, max_lines):
    """Largest size <= size where text wraps into <= max_lines lines that all
    fit max_w. Fails the run instead of ever cutting a title."""
    while size >= min_size:
        t = Type(weight, size)
        lines = wrap(t, text, max_w)
        if len(lines) <= max_lines and all(t.width(ln) <= max_w for ln in lines):
            return t, lines
        size -= 2
    raise SystemExit("FAIL headline does not fit (%d lines, %dpx min): %r" % (max_lines, min_size, text))


def background(w, h):
    bg = Image.new("RGB", (w, h), NAVY)
    glow = Image.new("RGB", (w, h), NAVY)
    g = ImageDraw.Draw(glow)
    g.ellipse((-0.55 * w, -0.30 * h, 0.85 * w, 0.42 * h), fill=INDIGO)
    g.ellipse((0.30 * w, 0.62 * h, 1.55 * w, 1.35 * h), fill=TEAL)
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.28))
    return Image.blend(bg, glow, 0.42)


def gradient(w, h, a=ACC_A, b=ACC_B):
    """135-degree two-stop gradient like the site's --grad."""
    grad = Image.linear_gradient("L").rotate(-45, expand=True).resize((w, h))
    return Image.composite(Image.new("RGB", (w, h), b), Image.new("RGB", (w, h), a), grad)


def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, fill=255)
    out = im.convert("RGBA")
    out.putalpha(m)
    return out


def find_shot(name, lang, dirs):
    for d in dirs:
        hits = sorted(Path(d).rglob("%s_%s_light.png" % (name, lang)))
        if hits:
            return hits[0]
    p = SITE_SHOTS / ("%s_%s_720.webp" % (name, lang))
    if p.is_file():
        return p
    raise SystemExit("FAIL no gallery shot for %s_%s" % (name, lang))


def text_lines(img, t, lines, cx, top, fill, lh):
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(lines):
        w = t.width(ln)
        x = cx - w / 2
        assert x >= 56 and x + w <= img.width - 56, ln
        t.draw(d, x, top + t.size * 0.95 + i * lh, ln, fill)
    return top + len(lines) * lh


def phone_shot(slot, lang, dirs, out):
    W, H = 1080, 1920
    head, sub = slot[lang]
    img = background(W, H).convert("RGBA")
    d = ImageDraw.Draw(img)
    bn = lang == "bn"
    maxw = W - 2 * 80
    th, hl = fit(head, "bold", 70 if not bn else 64, 44, maxw, 2)
    ts, sl = fit(sub, "medium", 38 if not bn else 36, 26, maxw, 1)
    lh_h = th.size * (1.18 if not bn else 1.42)
    lh_s = ts.size * (1.3 if not bn else 1.5)
    block = len(hl) * lh_h + 22 + lh_s
    zone_top, zone_bot = 96, 404            # header zone, same on every shot
    top = zone_top + 26 + (zone_bot - zone_top - 26 - block) / 2
    # gradient accent pill (the site's section marker)
    pill = rounded(gradient(96, 8), 4)
    img.alpha_composite(pill, ((W - 96) // 2, zone_top))
    y = text_lines(img, th, hl, W / 2, top, INK, lh_h)
    text_lines(img, ts, sl, W / 2, y + 22, INK2, lh_s)
    # the real screen: aspect kept, never cropped, small rounded corners + soft shadow
    src = find_shot(slot["shot"], lang, dirs)
    shot = Image.open(src).convert("RGB")
    box_w, box_h = 700, H - 448 - 64
    k = min(box_w / shot.width, box_h / shot.height)
    shot = shot.resize((round(shot.width * k), round(shot.height * k)), Image.LANCZOS)
    x, y0 = (W - shot.width) // 2, 448
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((x - 6, y0 + 18, x + shot.width + 6, y0 + shot.height + 30), 44,
                                         fill=(0, 0, 0, 170))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(34)))
    ring = Image.new("RGBA", (shot.width + 4, shot.height + 4), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle((0, 0, ring.width - 1, ring.height - 1), 38,
                                           fill=(255, 255, 255, 46))
    img.alpha_composite(ring, (x - 2, y0 - 2))
    img.alpha_composite(rounded(shot, 36), (x, y0))
    assert y0 + shot.height <= H - 40
    img.convert("RGB").save(out, "JPEG", **JPEG)
    return src


def feature_graphic(spec, lang, out):
    W, H = 1024, 500
    head, slogan = spec[lang]
    bn = lang == "bn"
    img = background(W, H).convert("RGBA")
    icon = rounded(Image.open(ICON).convert("RGB").resize((208, 208), Image.LANCZOS), 46)
    halo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((40, 120, 320, 400), fill=INDIGO + (120,))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(46)))
    img.alpha_composite(icon, (76, (H - 208) // 2))
    x0, maxw = 336, W - 336 - 64
    th, hl = fit(head, "bold", 40 if not bn else 36, 26, maxw, 3)
    ts, sl = fit(slogan, "bold", 34 if not bn else 32, 22, maxw, 1)
    lh_h = th.size * (1.2 if not bn else 1.45)
    lh_s = ts.size * (1.3 if not bn else 1.5)
    block = len(hl) * lh_h + 20 + lh_s
    y = (H - block) / 2
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(hl):
        assert x0 + th.width(ln) <= W - 56, ln
        th.draw(d, x0, y + th.size * 0.95 + i * lh_h, ln, INK)
    y += len(hl) * lh_h + 20
    # slogan in the accent gradient (text mask over the gradient)
    mask = Image.new("L", (W, H), 0)
    ts.draw(ImageDraw.Draw(mask), x0, y + ts.size * 0.95, sl[0], 255)
    img.paste(gradient(W, H), (0, 0), mask)
    assert y + lh_s <= H - 24
    img.convert("RGB").save(out, "JPEG", **JPEG)


def preview(out_dir, n):
    tw = 216
    th = round(tw * 1920 / 1080)
    sheet = Image.new("RGB", (n * (tw + 12) + 12, 2 * (th + 12) + 12 + 262), (235, 238, 245))
    for r, lang in enumerate(("en", "bn")):
        for c in range(n):
            im = Image.open(out_dir / ("phone_%s_%d.jpg" % (lang, c + 1))).resize((tw, th), Image.LANCZOS)
            sheet.paste(im, (12 + c * (tw + 12), 12 + r * (th + 12)))
    for k, lang in enumerate(("en", "bn")):
        fg = Image.open(out_dir / ("feature_graphic_%s.jpg" % lang)).resize((512, 250), Image.LANCZOS)
        sheet.paste(fg, (12 + k * 524, 2 * (th + 12) + 12))
    sheet.save(out_dir / "preview.jpg", "JPEG", quality=82, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default="", help="artifact dirs holding <name>_<lang>_light.png, ':'-separated")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if not features.check_feature("raqm"):
        sys.exit("FAIL Pillow has no raqm layout: Bangla would be shaped wrong (apt-get install libraqm0)")
    dirs = [Path(p) for p in a.shots.split(":") if p and Path(p).is_dir()]
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    spec = json.loads((PACK / "screenshots.json").read_text("utf-8"))
    log = []
    for lang in ("en", "bn"):
        feature_graphic(spec["feature_graphic"], lang, out / ("feature_graphic_%s.jpg" % lang))
        for i, slot in enumerate(spec["slots"], 1):
            src = phone_shot(slot, lang, dirs, out / ("phone_%s_%d.jpg" % (lang, i)))
            log.append("phone_%s_%d.jpg <- %s" % (lang, i, src.relative_to(ROOT) if ROOT in src.parents
                                                  else src.name + " (CI gallery artifact)"))
    preview(out, len(spec["slots"]))
    # Play limits on what was written
    for p in sorted(out.glob("*.jpg")):
        if p.name == "preview.jpg":
            continue
        im = Image.open(p)
        want = (1024, 500) if p.name.startswith("feature") else tuple(spec["size"])
        assert im.size == want and im.mode == "RGB", (p.name, im.size, im.mode)
        assert p.stat().st_size < 8 * 1024 * 1024, p.name
        assert max(im.size) <= 2 * min(im.size) or p.name.startswith("feature"), p.name
    (out / "sources.txt").write_text("\n".join(log) + "\n", "utf-8")
    print("\n".join(log))
    print("play pack images: OK (%d files)" % len(list(out.glob("*.jpg"))))


if __name__ == "__main__":
    main()
