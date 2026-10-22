"""Rebuild the Play Store feature graphics + framed phone screenshots.

    ~/assisto/.venv/bin/python owner_actions/play_store/make_graphics.py <shots_dir>

<shots_dir> = output of the screenshot gallery test
(ASSISTO_SHOT_DIR=… flutter test test/screenshots_test.dart). Pure Pillow,
brand gradient cyan #22D3EE -> blue #3B6EF6 -> purple #9B4DF0 on ink #05060A.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
BN_FONT = os.path.join(REPO, "app/assets/fonts/NotoSansBengali.ttf")
EN_FONT_DIRS = [os.path.expanduser("~/assisto/tools/flutter/bin/cache/artifacts/material_fonts"),
                "/usr/share/fonts/truetype/dejavu"]
LOGO = os.path.join(REPO, "app/assets/icon/fg.png")

CYAN, BLUE, PURPLE, INK = (0x22, 0xD3, 0xEE), (0x3B, 0x6E, 0xF6), (0x9B, 0x4D, 0xF0), (0x05, 0x06, 0x0A)

SHOTS = [  # (gallery name, bn caption, en caption)
    ("home_welcome", "সব কাজ এক জায়গায় —\nআপনার AI সহকারী", "Your AI assistant —\neverything in one place"),
    ("chat", "বাংলায় বলুন,\nAssisto লিখে রাখে", "Just say it —\nAssisto logs it for you"),
    ("money", "খরচ, আয়, বাজেট —\nএক নজরে", "Spending, income and\nbudgets at a glance"),
    ("voice_assistant", "কণ্ঠেই কল, অ্যালার্ম\nআর খরচের হিসাব", "Calls, alarms and\nexpenses — by voice"),
    ("safety", "নিরাপদ যাত্রা, SOS\nআর কণ্ঠে SOS", "Safe Journey, SOS\nand voice SOS"),
    ("family", "পরিবারের ওষুধ\nসময়মতো", "Family medicines,\non time"),
    ("biz_hub", "দোকানের খাতা,\nবিক্রি ও ক্যাশবক্স", "Shop ledger, sales\nand cashbox"),
    ("shop_cameras", "পুরনো ফোন দিয়েই\nদোকানের ক্যামেরা", "Turn an old phone into\na shop camera"),
]


def en_font(size, bold=True):
    for d in EN_FONT_DIRS:
        for n in (("Roboto-Bold.ttf", "DejaVuSans-Bold.ttf") if bold else ("Roboto-Medium.ttf", "DejaVuSans.ttf")):
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def bn_font(size, weight=b"Bold"):
    f = ImageFont.truetype(BN_FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def font(lang, size, bold=True):
    return bn_font(size, b"Bold" if bold else b"Medium") if lang == "bn" else en_font(size, bold)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def brand_gradient(w, h, horizontal=True):
    """cyan -> blue -> purple, slightly diagonal."""
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            t = (x / (w - 1) * 0.8 + y / (h - 1) * 0.2) if horizontal else (y / (h - 1) * 0.75 + x / (w - 1) * 0.25)
            px[x, y] = lerp(CYAN, BLUE, t / 0.5) if t < 0.5 else lerp(BLUE, PURPLE, (t - 0.5) / 0.5)
    return im


def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, im.size[0] - 1, im.size[1] - 1), r, fill=255)
    out = im.convert("RGBA")
    out.putalpha(m)
    return out


def shadow(size, r, blur, alpha=110):
    pad = blur * 3
    s = Image.new("RGBA", (size[0] + 2 * pad, size[1] + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle((pad, pad, pad + size[0], pad + size[1]), r, fill=(0, 0, 0, alpha))
    return s.filter(ImageFilter.GaussianBlur(blur)), pad


def feature_graphic(lang, out):
    S = 2                                  # supersample
    W, H = 1024 * S, 500 * S
    bg = brand_gradient(W // 4, H // 4).resize((W, H), Image.BICUBIC).convert("RGBA")
    # soft dark vignette on the right so white text keeps contrast on purple
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    for i in range(60):
        a = int(70 * i / 60)
        d.rectangle((int(W * 0.38) + i * S * 10, 0, W, H), fill=(5, 6, 10, a // 6))
    bg = Image.alpha_composite(bg, ov)
    # logo on a dark rounded tile (the mark itself is blue/purple)
    tile = 300 * S
    tx, ty = 70 * S, (H - tile) // 2
    sh, pad = shadow((tile, tile), 64 * S, 18 * S, 120)
    bg.alpha_composite(sh, (tx - pad, ty - pad + 8 * S))
    t = Image.new("RGBA", (tile, tile), INK + (255,))
    t = rounded(t, 64 * S)
    logo = Image.open(LOGO).convert("RGBA").resize((int(tile * 0.92), int(tile * 0.92)), Image.LANCZOS)
    t.alpha_composite(logo, ((tile - logo.size[0]) // 2, (tile - logo.size[1]) // 2))
    bg.alpha_composite(t, (tx, ty))
    d = ImageDraw.Draw(bg)
    x = tx + tile + 56 * S
    d.text((x, 118 * S), "Assisto", font=en_font(104 * S), fill="white")
    tag = ("জীবন আপনি চালান,\nমনে রাখার দায়িত্ব আমার" if lang == "bn"
           else "You live your life —\nremembering is my job")
    d.multiline_text((x, 250 * S), tag, font=font(lang, 34 * S, True), fill="white", spacing=10 * S)
    sub = ("রিমাইন্ডার · হিসাব · পরিবার · নিরাপত্তা · AI" if lang == "bn"
           else "Reminders · Money · Family · Safety · AI")
    d.text((x, 370 * S), sub, font=font(lang, 22 * S, False), fill=(235, 240, 255))
    bg.convert("RGB").resize((1024, 500), Image.LANCZOS).save(out, optimize=True)


def framed(shot_path, caption, lang, out):
    W, H = 1080, 1920
    bg = brand_gradient(W // 6, H // 6, horizontal=False).resize((W, H), Image.BICUBIC).convert("RGBA")
    d = ImageDraw.Draw(bg)
    f = font(lang, 64 if lang == "en" else 66, True)
    d.multiline_text((W // 2, 150), caption, font=f, fill="white", anchor="mm", align="center",
                     spacing=14)
    shot = Image.open(shot_path).convert("RGB")
    ph = 1500
    pw = int(shot.size[0] * ph / shot.size[1])
    shot = shot.resize((pw, ph), Image.LANCZOS)
    bez = 16
    dev = Image.new("RGBA", (pw + 2 * bez, ph + 2 * bez), INK + (255,))
    dev = rounded(dev, 56)
    dev.alpha_composite(rounded(shot, 42), (bez, bez))
    x, y = (W - dev.size[0]) // 2, 300
    sh, pad = shadow(dev.size, 56, 22, 120)
    bg.alpha_composite(sh, (x - pad, y - pad + 14))
    bg.alpha_composite(dev, (x, y))
    bg.convert("RGB").save(out, optimize=True)


def main():
    shots = sys.argv[1] if len(sys.argv) > 1 else None
    for lang in ("bn", "en"):
        feature_graphic(lang, os.path.join(HERE, "feature_graphic_%s.png" % lang))
    if shots:
        for i, (name, cbn, cen) in enumerate(SHOTS, 1):
            for lang, cap in (("bn", cbn), ("en", cen)):
                src = os.path.join(shots, "%s_%s_light.png" % (name, lang))
                framed(src, cap, lang, os.path.join(HERE, "phone_%s_%d_%s.png" % (lang, i, name)))
    print("done")


if __name__ == "__main__":
    main()
