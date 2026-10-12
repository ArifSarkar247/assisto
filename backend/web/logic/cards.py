"""Pillow share-card + festival-card generation (Bangla via raqm shaping)."""
import io
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/home/ubuntu/assisto/app/assets/fonts/NotoSansBengali.ttf"
try:
    _LAYOUT = ImageFont.Layout.RAQM
except Exception:  # pragma: no cover
    _LAYOUT = ImageFont.Layout.BASIC

_cache = {}


def font(size):
    key = int(size)
    if key not in _cache:
        _cache[key] = ImageFont.truetype(FONT_PATH, key, layout_engine=_LAYOUT)
    return _cache[key]


def _wrap(draw, text, fnt, max_w):
    lines, cur = [], ""
    for word in text.split():
        trial = (cur + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def _center_text(draw, cx, y, text, fnt, fill, max_w=None):
    if max_w:
        lines = _wrap(draw, text, fnt, max_w)
    else:
        lines = [text]
    for ln in lines:
        w = draw.textlength(ln, font=fnt)
        asc, desc = fnt.getmetrics()
        draw.text((cx - w / 2, y), ln, font=fnt, fill=fill)
        y += asc + desc + 8
    return y


def _png(img):
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def _vgrad(size, top, bottom):
    # Build a 1px-wide vertical gradient column, then stretch — fast (no WxH loop).
    w, h = size
    col = Image.new("RGB", (1, h))
    px = col.load()
    tr, tg, tb = top
    br, bg, bb = bottom
    for y in range(h):
        t = y / max(1, h - 1)
        px[0, y] = (int(tr + (br - tr) * t), int(tg + (bg - tg) * t), int(tb + (bb - tb) * t))
    return col.resize((w, h))


def _footer(draw, size):
    w, h = size
    f = font(34)
    txt = "Assisto · assisto.asalify.com"
    tw = draw.textlength(txt, font=f)
    draw.text((w / 2 - tw / 2, h - 70), txt, font=f, fill=(255, 255, 255))


# ---------- share cards ----------
def cv_card(score, tagline="তোমার CV স্কোর কত?", story=False):
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, (14, 40, 90), (10, 24, 60))
    d = ImageDraw.Draw(img)
    cx = size[0] / 2
    y = size[1] * (0.18 if story else 0.1)
    _center_text(d, cx, y, "আমার CV স্কোর", font(70), (255, 255, 255))
    # big score
    big = font(300)
    s = str(score)
    w = d.textlength(s, font=big)
    d.text((cx - w / 2, size[1] * (0.33 if story else 0.28)), s, font=big, fill=(95, 216, 245))
    small = font(60)
    w2 = d.textlength("/ ১০০", font=small)
    d.text((cx - w2 / 2, size[1] * (0.55 if story else 0.52)), "/ ১০০", font=small, fill=(230, 230, 230))
    _center_text(d, cx, size[1] * (0.66 if story else 0.64), tagline, font(54),
                 (255, 224, 138), max_w=size[0] - 160)
    _center_text(d, cx, size[1] * (0.78 if story else 0.78),
                 "তুমিও যাচাই করো — ফ্রি", font(44), (210, 230, 255), max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)


def scam_card(label, emoji, story=False):
    size = (1080, 1920) if story else (1080, 1080)
    danger = label != "সম্ভবত নিরাপদ"
    img = _vgrad(size, (120, 20, 20) if danger else (18, 70, 40),
                 (70, 10, 10) if danger else (10, 40, 24))
    d = ImageDraw.Draw(img)
    cx = size[0] / 2
    d_emoji = font(240)
    w = d.textlength(emoji, font=d_emoji)
    d.text((cx - w / 2, size[1] * (0.22 if story else 0.16)), emoji, font=d_emoji, fill=(255, 255, 255))
    _center_text(d, cx, size[1] * (0.45 if story else 0.42), label, font(110), (255, 255, 255))
    _center_text(d, cx, size[1] * (0.6 if story else 0.6),
                 "সন্দেহজনক মেসেজ? Assisto-তে যাচাই করুন", font(46),
                 (255, 235, 180), max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)


# ---------- festival cards ----------
FESTIVALS = {
    "eid": {"title": "ঈদ মুবারক", "sub": "ঈদের শুভেচ্ছা",
            "top": (16, 94, 72), "bottom": (8, 54, 42), "accent": (255, 215, 120)},
    "boishakh": {"title": "শুভ নববর্ষ", "sub": "পহেলা বৈশাখের শুভেচ্ছা",
                 "top": (176, 58, 46), "bottom": (120, 34, 26), "accent": (255, 224, 150)},
    "ekushe": {"title": "অমর একুশে", "sub": "ভাষা শহিদদের প্রতি শ্রদ্ধা",
               "top": (30, 30, 34), "bottom": (12, 12, 14), "accent": (210, 60, 60)},
    "victory": {"title": "বিজয় দিবস", "sub": "মহান বিজয় দিবসের শুভেচ্ছা",
                "top": (16, 94, 60), "bottom": (120, 30, 30), "accent": (255, 224, 150)},
}


def festival_card(key, name="", message="", story=False):
    f = FESTIVALS.get(key, FESTIVALS["eid"])
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, f["top"], f["bottom"])
    d = ImageDraw.Draw(img)
    cx = size[0] / 2
    y = size[1] * (0.2 if story else 0.14)
    y = _center_text(d, cx, y, f["title"], font(130), f["accent"], max_w=size[0] - 120)
    y = _center_text(d, cx, y + 20, f["sub"], font(52), (255, 255, 255), max_w=size[0] - 160)
    if message:
        y = _center_text(d, cx, y + 50, message, font(50), (245, 245, 245), max_w=size[0] - 180)
    if name:
        _center_text(d, cx, size[1] * (0.8 if story else 0.78), "— " + name, font(56),
                     f["accent"], max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)
