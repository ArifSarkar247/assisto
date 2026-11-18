"""pdfbn — ONE Bangla-correct text layer for every server-made PDF.

Why: reportlab draws a TrueType font glyph-by-glyph from the cmap, so without
complex-script shaping Bangla conjuncts (ক্ষ, জ্ঞ, ন্ত্র), reph (র্), ya-phala
(্য) and pre-base vowel signs (ি, ে, ৈ) come out broken. reportlab already has
HarfBuzz shaping built in — it only needs the small `uharfbuzz` wheel (no apt
package, no service, ~5 MB). This module turns it on and adds what the PDFs
need on top:

* script runs — Bangla text in Noto Sans Bengali (shaped), everything else in
  Inter (the app's own Latin face), so mixed bn/en lines read right;
* width / wrap — measured on the SHAPED glyphs; breaks at spaces and, for an
  over-long word, only between Bangla grapheme clusters (never inside a
  conjunct or before a vowel sign);
* Bangla digits and ৳ money with Bangladeshi (lakh) grouping;
* `Doc` — a small flowing page writer (brand bar, title, headings, wrapped
  lines, label/amount rows, page numbers) every report-style PDF shares;
* `Doc.table` — a simple ruled table (header, right-aligned numbers, last
  row bold) for reports. (platypus Paragraph is NOT used: it shapes a whole
  word with its first font, which breaks "৳১০,২৩৫.৫০".)

Fonts: app/assets/fonts (SIL OFL 1.1). reportlab embeds a subset of each font,
so a PDF stays small. If uharfbuzz is missing the text still draws (never a
500) but `shaping_ok()` is False and the CI test fails loudly.
"""
from __future__ import annotations

import io
import logging
import pathlib
import re

log = logging.getLogger(__name__)

FONT_DIR = pathlib.Path(__file__).resolve().parents[2] / "app" / "assets" / "fonts"
_FILES = {
    "AsBn": "NotoSansBengali-Regular.ttf",
    "AsBn-Bold": "NotoSansBengali-Bold.ttf",
    "AsLat": "Inter-Regular.ttf",
    "AsLat-Bold": "Inter-Bold.ttf",
}
BN, BN_BOLD, LAT, LAT_BOLD = "AsBn", "AsBn-Bold", "AsLat", "AsLat-Bold"

_registered = None


def ensure_fonts():
    """Register the four faces once per process. -> True when they loaded."""
    global _registered
    if _registered is not None:
        return _registered
    try:
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont
        from reportlab.lib.fonts import addMapping
        have = set(pdfmetrics.getRegisteredFontNames())
        for name, fn in _FILES.items():
            if name not in have:
                f = TTFont(name, str(FONT_DIR / fn))
                # the app's Bengali Bold file keeps the PostScript name
                # "NotoSansBengali-Regular"; reportlab de-duplicates embedded
                # faces by that name, so give each face its own.
                f.face.name = ("Assisto" + name).encode()
                pdfmetrics.registerFont(f)
        addMapping(LAT, 0, 0, LAT)
        addMapping(LAT, 1, 0, LAT_BOLD)
        addMapping(LAT, 0, 1, LAT)
        addMapping(LAT, 1, 1, LAT_BOLD)
        addMapping(BN, 0, 0, BN)
        addMapping(BN, 1, 0, BN_BOLD)
        addMapping(BN, 0, 1, BN)
        addMapping(BN, 1, 1, BN_BOLD)
        _registered = True
    except Exception:  # noqa: BLE001 — never a 500 for a missing font file
        log.exception("pdf_bn: font registration failed")
        _registered = False
    return _registered


def shaping_ok():
    """True when HarfBuzz shaping is really active for the Bangla face."""
    if not ensure_fonts():
        return False
    try:
        from reportlab.pdfbase import pdfmetrics
        return bool(pdfmetrics.getFont(BN).shapable)
    except Exception:  # noqa: BLE001
        return False


# ------------------------------------------------------------------ script runs

_BN_CH = re.compile("[ঀ-৿।॥]")
_NEUTRAL = frozenset("  ‌‍")
# chars that never START a grapheme cluster (signs that attach to the left)
_ATTACH = frozenset([chr(c) for c in range(0x0981, 0x0984)] + ["়"]
                    + [chr(c) for c in range(0x09BE, 0x09C5)]
                    + ["ে", "ৈ", "ো", "ৌ", "্", "ৗ",
                       "ৢ", "ৣ", "৾", "‌", "‍"])
_VIRAMA = "্"


def has_bn(text):
    return bool(_BN_CH.search(text or ""))


def _is_bn(ch):
    return bool(_BN_CH.match(ch))


def runs(text, bold=False):
    """-> [(segment, font_name, shaped)] — Bangla runs shaped in Noto Sans
    Bengali, others plain in Inter. Spaces/ZWJ/ZWNJ join the current run."""
    text = str(text or "")
    out, cur, kind = [], [], None
    for ch in text:
        if ch in _NEUTRAL:
            k = kind
        else:
            k = "bn" if _is_bn(ch) else "lat"
        if kind is None and k is None:
            cur.append(ch)
            continue
        if kind is None:
            kind = k
        if k != kind:
            out.append(("".join(cur), kind))
            cur, kind = [ch], k
        else:
            cur.append(ch)
    if cur:
        out.append(("".join(cur), kind or "lat"))
    res = []
    for seg, k in out:
        if k == "bn":
            res.append((seg, BN_BOLD if bold else BN, True))
        else:
            res.append((seg, LAT_BOLD if bold else LAT, False))
    return res


_CACHE = {}


def _shape(seg, font, size, shaped):
    key = (seg, font, size, shaped)
    hit = _CACHE.get(key)
    if hit is None:
        if len(_CACHE) > 4000:
            _CACHE.clear()
        hit = _CACHE[key] = _shape1(seg, font, size, shaped)
    return hit


def _shape1(seg, font, size, shaped):
    """-> (text, width). Calls reportlab's HarfBuzz shaper directly (canvas
    drawString only shapes when the optional rlbidi package is present)."""
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase import ttfonts
    if shaped and getattr(pdfmetrics.getFont(font), "shapable", False):
        s = ttfonts.shapeStr(seg, font, size, force=True)
        sd = getattr(s, "__shapeData__", None)
        if sd:
            return s, sum(g.x_advance for g in sd) * size / 1000.0
        return s, pdfmetrics.stringWidth(str(s), font, size)
    return seg, pdfmetrics.stringWidth(seg, font, size)


def width(text, size, bold=False):
    if not ensure_fonts():
        from reportlab.pdfbase.pdfmetrics import stringWidth
        return stringWidth(str(text or ""), "Helvetica", size)
    return sum(_shape(s, f, size, sh)[1] for s, f, sh in runs(text, bold))


def draw(c, x, y, text, size=10, bold=False, align="left"):
    """Draw one line on canvas `c`; align left|center|right. -> its width."""
    text = str(text or "")
    if not ensure_fonts():
        c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        {"center": c.drawCentredString, "right": c.drawRightString}.get(
            align, c.drawString)(x, y, text)
        return width(text, size, bold)
    parts = [(s, f, sh, _shape(s, f, size, sh)) for s, f, sh in runs(text, bold)]
    total = sum(p[3][1] for p in parts)
    if align == "center":
        x -= total / 2.0
    elif align == "right":
        x -= total
    for s, f, sh, (shaped, w) in parts:
        c.setFont(f, size)
        t = c.beginText(x, y)
        t.textLine(shaped)
        span = sh and _actual_text_ok(c)
        if span:
            # career: shaped conjunct glyphs have no 1:1 Unicode mapping, so a
            # copy / ATS parser read garbage. An ActualText span carries the
            # real Bangla text for the run (same pixels, correct text layer).
            c._code.append("/Span << /ActualText <FEFF%s> >> BDC" % s.encode("utf-16-be").hex().upper())
        c.drawText(t)
        if span:
            c._code.append("EMC")
        x += w
    return total


def _actual_text_ok(c):
    return isinstance(getattr(c, "_code", None), list)


def clusters(word):
    """Split a word into grapheme clusters (a conjunct + its signs stay one)."""
    out = []
    for ch in word:
        if out and (ch in _ATTACH or out[-1].endswith(_VIRAMA) or out[-1].endswith("‍")):
            out[-1] += ch
        else:
            out.append(ch)
    return out


def wrap(text, size, max_w, bold=False):
    """Greedy line breaking on shaped widths. Keeps explicit newlines."""
    lines = []
    for para in str(text or "").split("\n"):
        words = para.split(" ")
        cur = ""
        for wd in words:
            cand = wd if not cur else cur + " " + wd
            if width(cand, size, bold) <= max_w:
                cur = cand
                continue
            if cur:
                lines.append(cur)
                cur = ""
            if width(wd, size, bold) <= max_w:
                cur = wd
                continue
            piece = ""  # an over-long word: break between clusters only
            for cl in clusters(wd):
                if piece and width(piece + cl, size, bold) > max_w:
                    lines.append(piece)
                    piece = cl
                else:
                    piece += cl
            cur = piece
        lines.append(cur)
    return lines


# ------------------------------------------------------------------ numbers

_BN_DIG = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(s):
    return str(s).translate(_BN_DIG)


def digits(s, lang):
    return bn_digits(s) if lang == "bn" else str(s)


def group(n):
    """Bangladeshi grouping: 1023550 -> 10,23,550."""
    s = str(int(n))
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts + [tail])


def taka(amount, lang="bn", decimals=2):
    """৳ amount with lakh grouping; Bangla digits in Bangla."""
    from decimal import Decimal, ROUND_HALF_UP
    try:
        d = Decimal(str(amount if amount is not None else 0))
    except Exception:  # noqa: BLE001
        d = Decimal(0)
    neg = d < 0
    d = abs(d).quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)
    whole, _, frac = ("%.*f" % (decimals, d)).partition(".")
    s = group(whole) + ("." + frac if decimals else "")
    s = ("-" if neg else "") + "৳" + s
    return digits(s, lang)


# ------------------------------------------------------------------ Doc writer

BRAND = ((0.0, 0.74, 0.83), (0.15, 0.39, 0.92), (0.49, 0.23, 0.93))
INK = (0.07, 0.09, 0.15)
MUTED = (0.38, 0.42, 0.50)


class Doc:
    """A flowing A4 writer: brand bar, title, headings, wrapped text, label /
    amount rows, page numbers ("পৃষ্ঠা ১" / "Page 1"). `.pdf()` -> bytes."""

    def __init__(self, title, lang="bn", pagesize=None, margin=48):
        from reportlab.lib.pagesizes import A4
        from reportlab.pdfgen import canvas
        ensure_fonts()
        self.lang = "bn" if lang == "bn" else "en"
        self.buf = io.BytesIO()
        self.c = canvas.Canvas(self.buf, pagesize=pagesize or A4)
        self.c.setTitle(str(title or "Assisto"))
        self.c.setAuthor("Assisto")
        self.w, self.h = pagesize or A4
        self.m = margin
        self.page = 1
        self._top()

    # page furniture
    def _top(self):
        c, seg = self.c, (self.w - 2 * self.m) / 3.0
        for i, col in enumerate(BRAND):
            c.setFillColorRGB(*col)
            c.rect(self.m + i * seg, self.h - 30, seg, 4, stroke=0, fill=1)
        c.setFillColorRGB(*INK)
        self.y = self.h - 60

    def _foot(self):
        c = self.c
        c.setFillColorRGB(*MUTED)
        word = "পৃষ্ঠা" if self.lang == "bn" else "Page"
        draw(c, self.w - self.m, 28, "%s %s" % (word, digits(self.page, self.lang)), 8.5,
             align="right")
        draw(c, self.m, 28, "Assisto", 8.5)
        c.setFillColorRGB(*INK)

    def need(self, h):
        if self.y - h < 56:
            self._foot()
            self.c.showPage()
            self.page += 1
            self._top()

    # content
    def _lines(self, text, size, indent=0, bold=False, color=INK, lead=1.55):
        avail = self.w - 2 * self.m - indent
        for ln in wrap(text, size, avail, bold):
            self.need(size * lead)
            self.c.setFillColorRGB(*color)
            draw(self.c, self.m + indent, self.y - size, ln, size, bold)
            self.y -= size * lead
        self.c.setFillColorRGB(*INK)

    def title(self, text):
        self._lines(text, 18, bold=True, lead=1.45)
        self.y -= 2

    def meta(self, text):
        self._lines(text, 9.5, color=MUTED)

    def heading(self, text):
        self.need(40)
        self.y -= 8
        self._lines(text, 12.5, bold=True, lead=1.5)
        self.c.setStrokeColorRGB(0.85, 0.87, 0.91)
        self.c.setLineWidth(0.6)
        self.c.line(self.m, self.y + 4, self.w - self.m, self.y + 4)
        self.y -= 4

    def text(self, text, size=10, indent=0, bold=False):
        self._lines(text, size, indent=indent, bold=bold)

    def bullet(self, text, size=10, indent=8):
        self._lines("• " + str(text or ""), size, indent=indent)

    def row(self, label, value, size=10, bold=False):
        """label on the left, value right-aligned (amounts). A long value
        (an address, a note) falls back to one wrapped "label: value" line."""
        value = str(value if value is not None else "")
        full = self.w - 2 * self.m - 8
        vw = width(value, size, bold)
        if vw > full * 0.5:
            self._lines("%s: %s" % (label, value), size, indent=8, bold=bold)
            return
        avail = full - vw - 16
        lines = wrap(label, size, avail, bold) or [""]
        for i, ln in enumerate(lines):
            self.need(size * 1.55)
            draw(self.c, self.m + 8, self.y - size, ln, size, bold)
            if i == 0:
                draw(self.c, self.w - self.m, self.y - size, value, size, bold, align="right")
            self.y -= size * 1.55

    def table(self, header, rows, widths, align=None, size=9.5, bold_last=False):
        """Ruled table; widths are fractions of the text width; align is a
        per-column 'left'|'right'. Cells wrap; the header repeats per page."""
        tw = self.w - 2 * self.m
        cols = [f * tw for f in widths]
        align = align or ["left"] * len(cols)
        pad, lead = 5, size * 1.5

        def put_row(cells, bold, fill=None, ink=INK):
            wrapped = [wrap(str(v), size, cw - 2 * pad, bold) or [""] for v, cw in zip(cells, cols)]
            hgt = max(len(x) for x in wrapped) * lead + 2 * pad - (lead - size)
            fresh = self.y - hgt < 56
            self.need(hgt)
            if fresh and cells is not header:
                put_row(header, True, fill=(0.12, 0.25, 0.69), ink=(1, 1, 1))
            top, x = self.y, self.m
            if fill:
                self.c.setFillColorRGB(*fill)
                self.c.rect(self.m, top - hgt, tw, hgt, stroke=0, fill=1)
            self.c.setStrokeColorRGB(0.6, 0.62, 0.66)
            self.c.setLineWidth(0.4)
            self.c.rect(self.m, top - hgt, tw, hgt, stroke=1, fill=0)
            for i, (lines, cw) in enumerate(zip(wrapped, cols)):
                if i:
                    self.c.line(x, top, x, top - hgt)
                self.c.setFillColorRGB(*ink)
                for j, ln in enumerate(lines):
                    yy = top - pad - size - j * lead + 1.5
                    if align[i] == "right":
                        draw(self.c, x + cw - pad, yy, ln, size, bold, align="right")
                    else:
                        draw(self.c, x + pad, yy, ln, size, bold)
                x += cw
            self.c.setFillColorRGB(*INK)
            self.y = top - hgt

        put_row(header, True, fill=(0.12, 0.25, 0.69), ink=(1, 1, 1))
        for k, r in enumerate(rows):
            put_row(r, bold_last and k == len(rows) - 1)
        self.y -= 6

    def gap(self, n=8):
        self.y -= n

    def pdf(self):
        self._foot()
        self.c.showPage()
        self.c.save()
        return self.buf.getvalue()


def report(title, meta=(), sections=(), lang="bn", note=None):
    """The shared report PDF: sections = [(heading, items)], an item is a str
    (wrapped line), ("b", str) bullet, ("row", label, value) or ("sub", str)."""
    d = Doc(title, lang)
    d.title(title)
    for m in meta:
        d.meta(m)
    for head, items in sections:
        d.heading(head)
        for it in items:
            if isinstance(it, (tuple, list)):
                kind = it[0]
                if kind == "row":
                    d.row(it[1], it[2], bold=len(it) > 3 and bool(it[3]))
                elif kind == "b":
                    d.bullet(it[1])
                elif kind == "sub":
                    d.text(it[1], 9.5, indent=18)
                else:
                    d.text(str(it[-1]))
            else:
                d.text(it)
    if note:
        d.gap(10)
        d.meta(note)
    return d.pdf()
