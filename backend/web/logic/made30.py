"""W5 — "Made in 30 seconds": an instant, shareable SHOP POSTER.

A delightful fast generator for Bangladesh's huge small-shop / F-commerce crowd:
the visitor types a shop name, an optional tagline, a few items with prices, and
(optionally) a phone number, and instantly gets a clean, screenshot-/download-ready
poster PNG — no login, no AI, fully deterministic.

Pick one of 4 original Assisto themes (gradient + geometric decor only; no copied art).
Everything is rendered server-side with Pillow (Bangla shaped via raqm), reusing the
same card primitives as the festival/share cards so the look matches the sibling tools.

Pure + offline: parse_items() and the *_card() renderers take plain inputs and return
bytes, so they are unit-testable with no DB and no network.
"""
import re

from .cards import font, _vgrad, _decor, _footer, _center_text, _png
from PIL import ImageDraw

MAX_ITEMS = 8
NAME_MAX = 40
TAG_MAX = 60
ITEM_NAME_MAX = 30
PRICE_MAX = 16

# Original Assisto poster themes (name must be stable — used as form values).
THEMES = {
    "fresh": {"top": (16, 94, 72), "bottom": (8, 54, 42), "accent": (255, 215, 120),
              "name_bn": "সবুজ", "name_en": "Fresh green"},
    "sunset": {"top": (176, 58, 46), "bottom": (120, 34, 26), "accent": (255, 224, 150),
               "name_bn": "কমলা", "name_en": "Sunset"},
    "ocean": {"top": (14, 40, 90), "bottom": (10, 24, 60), "accent": (95, 216, 245),
              "name_bn": "নীল", "name_en": "Ocean blue"},
    "royal": {"top": (46, 24, 92), "bottom": (24, 14, 60), "accent": (255, 214, 120),
              "name_bn": "বেগুনি", "name_en": "Royal purple"},
}
DEFAULT_THEME = "fresh"

LABELS = {
    "bn": {"pricelist": "মূল্য তালিকা", "open": "আমরা খোলা আছি", "call": "অর্ডার / যোগাযোগ"},
    "en": {"pricelist": "Price list", "open": "We are open", "call": "Order / Contact"},
}

_PRICE_CLEAN = re.compile(r"[^0-9০-৯./\s৳Tttk,-]+", re.I)


def parse_items(raw, lang="bn"):
    """Turn a textarea (one 'item - price' per line) into a clean list of (name, price).

    Accepts separators '-', '–', ':', '=', '\\t', or '|'. Price is optional. Fully
    deterministic; trims to MAX_ITEMS and caps field lengths. No fabrication — a line
    with no price just carries an empty price string.
    """
    items = []
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.split(r"\s*[-–:=|\t]\s*", line, maxsplit=1)
        name = m[0].strip()[:ITEM_NAME_MAX]
        price = ""
        if len(m) == 2:
            price = _PRICE_CLEAN.sub("", m[1]).strip()[:PRICE_MAX]
        if name:
            items.append((name, price))
        if len(items) >= MAX_ITEMS:
            break
    return items


def _theme(key):
    return THEMES.get(key, THEMES[DEFAULT_THEME])


def poster_card(shop, tagline="", items=None, phone="", theme="fresh",
                story=False, lang="bn"):
    """Render the shareable poster PNG. Deterministic; no AI; no network."""
    items = items or []
    th = _theme(theme)
    L = LABELS.get(lang, LABELS["bn"])
    size = (1080, 1920) if story else (1080, 1080)
    img = _vgrad(size, th["top"], th["bottom"])
    d = ImageDraw.Draw(img)
    _decor(d, size, th["accent"])
    cx = size[0] / 2
    w, h = size

    # Shop name (headline) + optional tagline.
    y = h * (0.12 if story else 0.07)
    y = _center_text(d, cx, y, shop or L["open"], font(104), th["accent"], max_w=w - 120)
    if tagline:
        y = _center_text(d, cx, y + 8, tagline, font(46), (255, 255, 255), max_w=w - 160)

    # Section label for the list.
    y += 30
    label = L["pricelist"] if items else L["open"]
    y = _center_text(d, cx, y, label, font(52), (255, 255, 255), max_w=w - 160)
    y += 16

    # Item rows: name left, price right, within a centred column.
    row_f = font(50)
    col_left = w * 0.14
    col_right = w * 0.86
    row_gap = row_f.getmetrics()[0] + row_f.getmetrics()[1] + 26
    max_rows = 8 if story else 6
    for name, price in items[:max_rows]:
        # name may wrap, but keep posters tidy: single line, ellipsised by width.
        nm = name
        while d.textlength(nm, font=row_f) > (col_right - col_left) * 0.68 and len(nm) > 1:
            nm = nm[:-1]
        if nm != name:
            nm = nm[:-1] + "…"
        d.text((col_left, y), nm, font=row_f, fill=(245, 245, 245))
        if price:
            pw = d.textlength(price, font=row_f)
            d.text((col_right - pw, y), price, font=row_f, fill=th["accent"])
        # thin divider
        d.line([(col_left, y + row_gap - 12), (col_right, y + row_gap - 12)],
               fill=(255, 255, 255, 60), width=1)
        y += row_gap

    # Phone / contact band near the bottom.
    if phone:
        _center_text(d, cx, h * (0.82 if story else 0.8),
                     L["call"] + ": " + phone, font(50), th["accent"], max_w=w - 120)

    _footer(d, size)
    return _png(img)
