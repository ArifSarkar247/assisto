"""Pillow share-card + festival-card generation (Bangla via raqm shaping)."""
import io
from PIL import Image, ImageDraw, ImageFont

from pathlib import Path as _P
# repo-relative (was a server-only absolute path; broke on CI and any other host)
FONT_PATH = str(_P(__file__).resolve().parents[3] / "app" / "assets" / "fonts" / "NotoSansBengali.ttf")
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


def _decor(d, size, accent):
    """Tasteful, original geometric flourish (corner arcs + dots). No copied art."""
    w, h = size
    r = int(w * 0.18)
    d.arc([-r, -r, r, r], 0, 90, fill=accent, width=10)
    d.arc([w - r, h - r, w + r, h + r], 180, 270, fill=accent, width=10)
    for i, cx in enumerate((w * 0.2, w * 0.5, w * 0.8)):
        d.ellipse([cx - 6, h * 0.1 - 6, cx + 6, h * 0.1 + 6], fill=accent)


CV_CARD_TEXT = {
    "bn": {"title": "আমার CV স্কোর", "out_of": "/ ১০০",
           "tag": "তোমার CV স্কোর কত?", "cta": "তুমিও যাচাই করো — ফ্রি"},
    "en": {"title": "My CV score", "out_of": "/ 100",
           "tag": "What's your CV score?", "cta": "Check yours — free"},
}
SCAM_CARD_CTA = {
    "bn": "সন্দেহজনক মেসেজ? Assisto-তে যাচাই করুন",
    "en": "Suspicious message? Check it on Assisto",
}
SCAM_SAFE_LABELS = {"সম্ভবত নিরাপদ", "Likely safe"}


# ---------- share cards ----------
def cv_card(score, story=False, lang="bn"):
    T = CV_CARD_TEXT.get(lang, CV_CARD_TEXT["bn"])
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, (14, 40, 90), (10, 24, 60))
    d = ImageDraw.Draw(img)
    _decor(d, size, (95, 216, 245))
    cx = size[0] / 2
    y = size[1] * (0.18 if story else 0.1)
    _center_text(d, cx, y, T["title"], font(70), (255, 255, 255))
    big = font(300)
    s = str(score)
    w = d.textlength(s, font=big)
    d.text((cx - w / 2, size[1] * (0.33 if story else 0.28)), s, font=big, fill=(95, 216, 245))
    small = font(60)
    w2 = d.textlength(T["out_of"], font=small)
    d.text((cx - w2 / 2, size[1] * (0.55 if story else 0.52)), T["out_of"], font=small, fill=(230, 230, 230))
    _center_text(d, cx, size[1] * (0.66 if story else 0.64), T["tag"], font(54),
                 (255, 224, 138), max_w=size[0] - 160)
    _center_text(d, cx, size[1] * (0.78 if story else 0.78),
                 T["cta"], font(44), (210, 230, 255), max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)


def scam_card(label, emoji, story=False, lang="bn"):
    size = (1080, 1920) if story else (1080, 1080)
    danger = label not in SCAM_SAFE_LABELS
    img = _vgrad(size, (120, 20, 20) if danger else (18, 70, 40),
                 (70, 10, 10) if danger else (10, 40, 24))
    d = ImageDraw.Draw(img)
    _decor(d, size, (255, 235, 180))
    cx = size[0] / 2
    d_emoji = font(240)
    w = d.textlength(emoji, font=d_emoji)
    d.text((cx - w / 2, size[1] * (0.22 if story else 0.16)), emoji, font=d_emoji, fill=(255, 255, 255))
    _center_text(d, cx, size[1] * (0.45 if story else 0.42), label, font(110), (255, 255, 255))
    _center_text(d, cx, size[1] * (0.6 if story else 0.6),
                 SCAM_CARD_CTA.get(lang, SCAM_CARD_CTA["bn"]), font(46),
                 (255, 235, 180), max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)


# ---------- festival cards ----------
# Original Assisto designs only (gradient + geometric decor); no copied/third-party art.
FESTIVALS = {
    "eid": {"title": "ঈদ মুবারক", "sub": "ঈদের শুভেচ্ছা",
            "title_en": "Eid Mubarak", "sub_en": "Eid greetings",
            "top": (16, 94, 72), "bottom": (8, 54, 42), "accent": (255, 215, 120)},
    "boishakh": {"title": "শুভ নববর্ষ", "sub": "পহেলা বৈশাখের শুভেচ্ছা",
                 "title_en": "Shubho Noboborsho", "sub_en": "Pohela Boishakh greetings",
                 "top": (176, 58, 46), "bottom": (120, 34, 26), "accent": (255, 224, 150)},
    "ekushe": {"title": "অমর একুশে", "sub": "ভাষা শহিদদের প্রতি শ্রদ্ধা",
               "title_en": "Amar Ekushe", "sub_en": "Tribute to the Language Martyrs",
               "top": (30, 30, 34), "bottom": (12, 12, 14), "accent": (210, 60, 60)},
    "victory": {"title": "বিজয় দিবস", "sub": "মহান বিজয় দিবসের শুভেচ্ছা",
                "title_en": "Victory Day", "sub_en": "Happy Victory Day",
                "top": (16, 94, 60), "bottom": (120, 30, 30), "accent": (255, 224, 150)},
    "independence": {"title": "স্বাধীনতা দিবস", "sub": "মহান স্বাধীনতা দিবসের শুভেচ্ছা",
                     "title_en": "Independence Day", "sub_en": "Happy Independence Day",
                     "top": (16, 94, 60), "bottom": (120, 30, 30), "accent": (255, 224, 150)},
    "durga_puja": {"title": "শুভ শারদীয়া", "sub": "দুর্গা পূজার শুভেচ্ছা",
                   "title_en": "Shubho Sharodiya", "sub_en": "Durga Puja greetings",
                   "top": (150, 36, 96), "bottom": (90, 20, 60), "accent": (255, 214, 120)},
    "christmas": {"title": "শুভ বড়দিন", "sub": "বড়দিনের শুভেচ্ছা",
                  "title_en": "Merry Christmas", "sub_en": "Christmas greetings",
                  "top": (16, 80, 48), "bottom": (120, 28, 28), "accent": (255, 224, 150)},
    "new_year": {"title": "শুভ নববর্ষ", "sub": "নতুন বছরের শুভেচ্ছা",
                 "title_en": "Happy New Year", "sub_en": "New Year greetings",
                 "top": (26, 20, 74), "bottom": (10, 24, 60), "accent": (255, 224, 138)},
    "birthday": {"title": "শুভ জন্মদিন", "sub": "জন্মদিনের শুভেচ্ছা",
                 "title_en": "Happy Birthday", "sub_en": "Birthday wishes",
                 "top": (40, 60, 150), "bottom": (120, 40, 120), "accent": (255, 214, 120)},
}


def festival_card(key, name="", message="", story=False, lang="bn"):
    f = FESTIVALS.get(key, FESTIVALS["eid"])
    title = f["title"] if lang == "bn" else f["title_en"]
    sub = f["sub"] if lang == "bn" else f["sub_en"]
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, f["top"], f["bottom"])
    d = ImageDraw.Draw(img)
    _decor(d, size, f["accent"])
    cx = size[0] / 2
    y = size[1] * (0.2 if story else 0.14)
    y = _center_text(d, cx, y, title, font(130), f["accent"], max_w=size[0] - 120)
    y = _center_text(d, cx, y + 20, sub, font(52), (255, 255, 255), max_w=size[0] - 160)
    if message:
        y = _center_text(d, cx, y + 50, message, font(50), (245, 245, 245), max_w=size[0] - 180)
    if name:
        _center_text(d, cx, size[1] * (0.8 if story else 0.78), "— " + name, font(56),
                     f["accent"], max_w=size[0] - 160)
    _footer(d, size)
    return _png(img)


def wrapped_card(title, badges, story=False):
    """Feature 19 — monthly Wrapped card. No money amounts, only badges."""
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, (26, 20, 74), (10, 24, 60))
    d = ImageDraw.Draw(img)
    cx = size[0] / 2
    y = size[1] * (0.14 if story else 0.08)
    y = _center_text(d, cx, y, title or "আমার মাস", font(80), (255, 224, 138),
                     max_w=size[0] - 120)
    y += 30
    for b in badges[:6]:
        y = _center_text(d, cx, y + 14, b, font(50), (235, 245, 255), max_w=size[0] - 140)
    _center_text(d, cx, size[1] * (0.86 if story else 0.84),
                 "Assisto দিয়ে তৈরি", font(44), (170, 200, 255))
    _footer(d, size)
    return _png(img)
