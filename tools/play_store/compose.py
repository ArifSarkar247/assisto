"""order5: Play Store phone screenshots (1080x1920) + feature graphics (1024x500).

Every phone screen is a REAL app screen rendered by the app's own widget
gallery (test/screenshots_test.dart) with Bangladeshi demo data.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS = [Path(p) for p in sys.argv[1].split(":")]   # dirs searched in order
OUT = Path(sys.argv[2])
ICON = Path(sys.argv[3])          # transparent logo
INTER = sys.argv[4]               # InterDisplay-Bold.ttf
INTER_M = sys.argv[5]             # Inter-Medium.ttf
BN = sys.argv[6]                  # NotoSansBengali variable
OUT.mkdir(parents=True, exist_ok=True)

NAVY = (3, 11, 40)

SLOTS = [
    ("home_top", "light", "Your super app — everything in one place",
     "আপনার সুপার অ্যাপ — সব এক জায়গায়"),
    ("ps_circle_media", "light", "Free chat — end-to-end encrypted",
     "ফ্রি চ্যাট — এন্ড-টু-এন্ড এনক্রিপ্টেড"),
    ("b1_call_video_upgraded", "dark", "HD voice & video calls",
     "HD ভয়েস ও ভিডিও কল"),
    ("ps_assistant", "light", "Just say it — Assisto does it",
     "শুধু বলুন — Assisto করে দেবে"),
    ("money", "light", "Track spending & budgets with ease",
     "খরচ আর বাজেটের হিসাব — খুব সহজে"),
    ("biz_hub", "light", "Run your shop from your phone",
     "ফোন থেকেই দোকান চালান"),
    ("photo_studio_premium", "light", "Photo Studio — enhance & passport photos",
     "ফটো স্টুডিও — ছবি উন্নত ও পাসপোর্ট ছবি"),
    ("safety", "light", "Family care & one-tap SOS",
     "পরিবারের যত্ন ও এক চাপে SOS"),
]


def font(path, size, bold=True):
    f = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.RAQM)
    try:
        f.set_variation_by_name("Bold" if bold else "Medium")
    except Exception:  # static font
        pass
    return f


def find_shot(name, lang, theme):
    for d in SHOTS:
        p = d / f"{name}_{lang}_{theme}.png"
        if p.exists():
            return p
    raise FileNotFoundError(f"{name}_{lang}_{theme}")


def background(w, h):
    bg = Image.new("RGB", (w, h), NAVY)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse((-w * 0.45, -h * 0.25, w * 0.75, h * 0.45), fill=(14, 120, 220))
    g.ellipse((w * 0.35, h * 0.55, w * 1.5, h * 1.3), fill=(16, 170, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.22))
    bg = Image.blend(bg, glow, 0.55)
    # gentle vertical darkening so text and phone pop
    shade = Image.linear_gradient("L").resize((w, h)).point(lambda v: int(v * 0.35))
    return Image.composite(Image.new("RGB", (w, h), NAVY), bg, shade)


def wrap(draw, text, f, max_w):
    words, lines, cur = text.split(" "), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if draw.textlength(t, font=f) <= max_w:
            cur = t
        else:
            lines.append(cur)
            cur = wd
    lines.append(cur)
    return lines


def phone(screen, width):
    k = width / screen.width
    scr = screen.resize((width, round(screen.height * k)), Image.LANCZOS)
    pad, r = 16, 58
    fw, fh = scr.width + 2 * pad, scr.height + 2 * pad
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), r, fill=(12, 16, 28, 255),
                        outline=(70, 90, 130, 255), width=3)
    m = Image.new("L", scr.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, scr.width - 1, scr.height - 1), r - pad, fill=255)
    frame.paste(scr, (pad, pad), m)
    return frame


def store_shot(i, slot, lang):
    name, theme, en, bn = slot
    W, H = 1080, 1920
    img = background(W, H).convert("RGBA")
    d = ImageDraw.Draw(img)
    text = en if lang == "en" else bn
    size = 76 if lang == "en" else 70
    f = font(INTER if lang == "en" else BN, size)
    lines = wrap(d, text, f, W - 2 * 90)
    while len(lines) > 2:
        size -= 4
        f = font(INTER if lang == "en" else BN, size)
        lines = wrap(d, text, f, W - 2 * 90)
    lh = size * (1.22 if lang == "en" else 1.45)   # Bangla needs taller lines
    top = 150 + (2 - len(lines)) * lh / 2
    for n, ln in enumerate(lines):
        tw = d.textlength(ln, font=f)
        d.text(((W - tw) / 2, top + n * lh), ln, font=f, fill=(255, 255, 255))
    ph = phone(Image.open(find_shot(name, lang, theme)).convert("RGB"), 600)
    sh = Image.new("RGBA", (ph.width + 120, ph.height + 120), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((60, 70, ph.width + 60, ph.height + 70), 60, fill=(0, 0, 0, 150))
    sh = sh.filter(ImageFilter.GaussianBlur(28))
    x, y = (W - ph.width) // 2, 470
    img.alpha_composite(sh, (x - 60, y - 60))
    img.alpha_composite(ph, (x, y))
    out = OUT / f"phone_{lang}_{i}.png"
    img.convert("RGB").save(out, optimize=True)
    return out


def feature(lang):
    W, H = 1024, 500
    img = background(W, H).convert("RGBA")
    logo = Image.open(ICON).convert("RGBA")
    k = 300 / logo.height
    logo = logo.resize((round(logo.width * k), 300), Image.LANCZOS)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((40, 60, 400, 440), fill=(40, 170, 230, 70))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(50)))
    img.alpha_composite(logo, (70, (H - 300) // 2))
    d = ImageDraw.Draw(img)
    x0, maxw = 70 + logo.width + 50, W - (70 + logo.width + 50) - 60
    if lang == "en":
        head, sub = "Chat, call & grow your business — with AI", \
            "Chat · Calls · AI Agent · Business · Family · Safety"
        hf, hs, sf = INTER, 50, font(INTER_M, 22, bold=False)
    else:
        head, sub = "চ্যাট, কল আর ব্যবসা — সব এক অ্যাপে, AI সাথে", \
            "চ্যাট · কল · AI এজেন্ট · ব্যবসা · পরিবার · নিরাপত্তা"
        hf, hs, sf = BN, 46, font(BN, 22, bold=False)
    f = font(hf, hs)
    lines = wrap(d, head, f, maxw)
    while len(lines) > 3:
        hs -= 3
        f = font(hf, hs)
        lines = wrap(d, head, f, maxw)
    lh = hs * (1.18 if lang == "en" else 1.42)
    block = len(lines) * lh + 24 + 30
    y = (H - block) / 2
    d.text((x0, y - 34), "Assisto", font=font(INTER, 24), fill=(120, 220, 230))
    for n, ln in enumerate(lines):
        d.text((x0, y + n * lh), ln, font=f, fill=(255, 255, 255))
    y += len(lines) * lh + 24
    while d.textlength(sub, font=sf) > maxw and sf.size > 14:
        sf = font(INTER_M if lang == "en" else BN, sf.size - 1, bold=False)
    d.text((x0, y), sub, font=sf, fill=(180, 230, 210))
    out = OUT / f"feature_graphic_{lang}.png"
    img.convert("RGB").save(out, optimize=True)
    return out


if __name__ == "__main__":
    for lang in ("en", "bn"):
        feature(lang)
        for i, s in enumerate(SLOTS, 1):
            store_shot(i, s, lang)
    # contact sheet
    cols, tw = 8, 270
    th = round(tw * 1920 / 1080)
    sheet = Image.new("RGB", (cols * tw + 9 * 12, 2 * th + 3 * 12 + 2 * 250 + 24), (235, 238, 245))
    for r, lang in enumerate(("en", "bn")):
        for c in range(cols):
            im = Image.open(OUT / f"phone_{lang}_{c + 1}.png").resize((tw, th), Image.LANCZOS)
            sheet.paste(im, (12 + c * (tw + 12), 12 + r * (th + 12)))
    for k, lang in enumerate(("en", "bn")):
        fg = Image.open(OUT / f"feature_graphic_{lang}.png").resize((512, 250), Image.LANCZOS)
        sheet.paste(fg, (12 + k * 524, 2 * th + 36))
    ic = Image.open(OUT / "icon_512.png").convert("RGB").resize((250, 250))
    sheet.paste(ic, (12 + 2 * 524, 2 * th + 36))
    sheet.save(OUT / "preview.png", optimize=True)
    print("done")
