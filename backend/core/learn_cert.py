"""learncert — ASSISTO LEARNING CERTIFICATE (owner order 3 Nov 11:45, part C).

A standalone module the Language Partner (agent/p2lang) and Learn-to-read-
Quran (agent/quranread) features call when a learner finishes a course step.
Flag `learning_certificate` (OFF until the owner's real-phone proof) gates the
app API; the public verify page always answers, so a certificate that was
issued keeps verifying.

SEAMS for the other features
  * server side, after the server graded a result:
        learn_cert.issue_certificate(user, course, level, score)
  * when the APP shows the result and should offer the certificate:
        token = learn_cert.result_token(user, course, level, score)
    return `token` in the grade response; the app calls
    courseResult(context, course:, level:, score:, token:) which POSTs
    /learn/certs/claim. The app can never mint a certificate without a token
    signed here (no forged levels / scores).

Storage: the generic per-user PaCollectionItem table, collection `learn_cert`
(NOT in the user-writable GENERIC_COLLECTIONS list) — no migration.

Verify code: "ALC-XXXX-XXXX-CCCC" — 8 random letters + 4 letters of an HMAC
(SECRET_KEY) over them. Letters only (no 0/O, 1/I mix-ups; no ASCII digits on
Bangla screens). A guessed code fails the HMAC before any DB lookup.

Honesty rules (owner, enforced by core.tests_learncert):
  * every certificate / page / PDF carries DISCLAIMER (bn/en);
  * exam names (IELTS, TOPIK, JLPT, Goethe, DELF, DELE, HSK) appear only as
    "<NAME>-style practice" / "<NAME>-ধাঁচের অনুশীলন" — never a logo, never a
    claimed official score;
  * Quran certificates say only "Qaida completed" / "Nazera reading
    completed" — never an ijazah or a Qari title.
"""
import datetime
import hashlib
import hmac
import re
import secrets

from django.conf import settings
from django.core import signing
from django.utils import timezone

COLL = "learn_cert"
FLAG = "learning_certificate"
SALT = "learncert.result.v1"
TOKEN_MAX_AGE = 7 * 24 * 3600
MAX_PER_DAY = 20
NAME_MAX = 60

DISCLAIMER = {
    "en": "Assisto learning certificate — not an official qualification",
    "bn": "Assisto শেখার সনদ — এটি কোনো অফিসিয়াল যোগ্যতা নয়",
}

# Official exam names we may only mention inside "-style practice" wording.
EXAM_NAMES = ("IELTS", "TOPIK", "JLPT", "Goethe", "DELF", "DELE", "HSK", "PTE")
# Titles a Quran-reading certificate must never carry.
QURAN_FORBIDDEN = ("ijazah", "ijaza", "ইজাযাহ", "ইজাযা", "ইজাজা", "qari", "ক্বারী")

_CEFR = ("A1", "A2", "B1", "B2", "C1", "C2")


def _lang(key, en, bn, extra=None, style=None):
    return {"kind": "language", "en": en, "bn": bn,
            "levels": _CEFR + tuple(extra or ()), "style": style}


# course id -> title + allowed level codes. Extra (exam-style) level codes are
# rendered "<level> (<EXAM>-style practice)".
COURSES = {
    "lang_en": _lang("lang_en", "English — Language Partner", "ইংরেজি — ভাষা শেখার সঙ্গী"),
    "lang_ko": _lang("lang_ko", "Korean — Language Partner", "কোরিয়ান — ভাষা শেখার সঙ্গী",
                     ("L1", "L2", "L3", "L4", "L5", "L6"), "TOPIK"),
    "lang_ja": _lang("lang_ja", "Japanese — Language Partner", "জাপানি — ভাষা শেখার সঙ্গী",
                     ("N5", "N4", "N3", "N2", "N1"), "JLPT"),
    "lang_ar": _lang("lang_ar", "Arabic for work — Language Partner", "কাজের আরবি — ভাষা শেখার সঙ্গী"),
    "lang_de": _lang("lang_de", "German — Language Partner", "জার্মান — ভাষা শেখার সঙ্গী"),
    "lang_fr": _lang("lang_fr", "French — Language Partner", "ফরাসি — ভাষা শেখার সঙ্গী"),
    "lang_es": _lang("lang_es", "Spanish — Language Partner", "স্প্যানিশ — ভাষা শেখার সঙ্গী"),
    "lang_zh": _lang("lang_zh", "Chinese — Language Partner", "চাইনিজ — ভাষা শেখার সঙ্গী",
                     ("H1", "H2", "H3", "H4", "H5", "H6"), "HSK"),
    "quran_qaida": {"kind": "quran", "en": "Learn to read Quran — Qaida",
                    "bn": "কুরআন পড়া শেখা — কায়দা", "levels": ("qaida",), "style": None},
    "quran_nazera": {"kind": "quran", "en": "Learn to read Quran — Nazera",
                     "bn": "কুরআন পড়া শেখা — নাযেরা", "levels": ("nazera",), "style": None},
}

QURAN_LEVEL = {
    "qaida": {"en": "Qaida completed", "bn": "কায়দা সম্পন্ন"},
    "nazera": {"en": "Nazera reading completed", "bn": "নাযেরা পড়া সম্পন্ন"},
}

_BN_RE = re.compile("[\u0980-\u09FF]")
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
              "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")
_EN_MONTHS = ("January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December")

TXT = {
    "en": {"title": "Assisto Learning Certificate", "awarded": "This is to certify that",
           "completed": "completed practice in", "level": "Level", "score": "Score",
           "date": "Date", "code": "Verify code", "check": "Check it at",
           "estimated": "estimated", "practice": "Assisto practice",
           "style": "%s-style practice", "level_n": "Level %s"},
    "bn": {"title": "Assisto শেখার সনদ", "awarded": "এই মর্মে জানানো যাচ্ছে যে",
           "completed": "অনুশীলন শেষ করেছেন —", "level": "লেভেল", "score": "স্কোর",
           "date": "তারিখ", "code": "যাচাই কোড", "check": "যাচাই করুন",
           "estimated": "আনুমানিক", "practice": "Assisto অনুশীলন",
           "style": "%s-ধাঁচের অনুশীলন", "level_n": "লেভেল %s"},
}


class CertError(ValueError):
    """A bad course / level / score / name. `.reason` is a stable code."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# ---------------------------------------------------------------- text helpers

def bn_digits(s):
    return str(s).translate(_BN)


def date_text(dt, lang):
    d = timezone.localtime(dt) if timezone.is_aware(dt) else dt
    if lang == "bn":
        return "%s %s %s" % (bn_digits(d.day), _BN_MONTHS[d.month - 1], bn_digits(d.year))
    return "%d %s %d" % (d.day, _EN_MONTHS[d.month - 1], d.year)


def course_title(course, lang):
    c = COURSES.get(course)
    return c[lang] if c else ""


def level_text(course, level, lang):
    """The level line, e.g. "B1 · Assisto practice · estimated" or
    "Qaida completed". Bangla gets Bangla digits."""
    c = COURSES[course]
    if c["kind"] == "quran":
        return QURAN_LEVEL[level][lang]
    T = TXT[lang]
    if level in _CEFR:
        head = level
    else:
        n = level[1:]
        head = (T["level_n"] % n) if level[0] in "LH" else level
        head = "%s (%s)" % (head, T["style"] % c["style"])
    s = "%s · %s · %s" % (head, T["practice"], T["estimated"])
    return bn_digits(s) if lang == "bn" else s


def score_text(score, lang):
    if score is None:
        return ""
    s = "%d/100" % score
    return bn_digits(s) if lang == "bn" else s


# ---------------------------------------------------------------- the code

_ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZ"   # 24 letters: no I/O, no digits


def _key():
    return getattr(settings, "SECRET_KEY", "").encode() + b"|learncert"


def _check(body):
    mac = hmac.new(_key(), body.encode(), hashlib.sha256).digest()
    return "".join(_ALPHA[b % len(_ALPHA)] for b in mac[:4])


def new_code():
    body = "".join(secrets.choice(_ALPHA) for _ in range(8))
    return "ALC-%s-%s-%s" % (body[:4], body[4:], _check(body))


def normalize_code(raw):
    """'alc-abcd efgh-wxyz' -> 'ALC-ABCD-EFGH-WXYZ' when the HMAC matches,
    else None (no DB lookup for a guessed / mistyped code)."""
    s = re.sub(r"[^A-Za-z]", "", str(raw or "")).upper()
    if s.startswith("ALC"):
        s = s[3:]
    if len(s) != 12 or any(ch not in _ALPHA for ch in s):
        return None
    body, chk = s[:8], s[8:]
    if not hmac.compare_digest(chk, _check(body)):
        return None
    return "ALC-%s-%s-%s" % (body[:4], body[4:], chk)


def verify_url(code):
    base = getattr(settings, "PUBLIC_BASE_URL", "") or "https://lifeassisto.com"
    return "%s/verify/%s" % (base.rstrip("/"), code)


# ---------------------------------------------------------------- validation

def _check_course_level(course, level):
    c = COURSES.get(course)
    if c is None:
        raise CertError("bad_course")
    lv = str(level or "").strip()
    if c["kind"] == "language":
        lv = lv.upper()
    else:
        lv = lv.lower()
    if lv not in c["levels"]:
        raise CertError("bad_level")
    return lv


def _check_score(score):
    if score is None or score == "":
        return None
    try:
        f = float(score)
    except (TypeError, ValueError):
        raise CertError("bad_score")
    if f != f or f < 0 or f > 100:
        raise CertError("bad_score")
    return int(round(f))


def forbidden_in(text):
    """Names / titles a certificate text must not carry, outside the allowed
    "-style practice" wording. Returns the offending words ([] = clean)."""
    t = str(text or "")
    found = []
    for name in EXAM_NAMES:
        pat = r"(?<![A-Za-z])%s(?![A-Za-z])" % re.escape(name)
        for m in re.finditer(pat, t, flags=re.IGNORECASE):
            tail = t[m.end():m.end() + 24]
            if not (tail.startswith("-style practice") or tail.startswith("-ধাঁচের অনুশীলন")):
                found.append(name)
                break
    for word in QURAN_FORBIDDEN:
        if word.isascii():
            hit = re.search(r"(?<![A-Za-z])%s" % word, t, flags=re.IGNORECASE)
        else:
            hit = word in t
        if hit:
            found.append(word)
    return found


def clean_name(raw):
    name = re.sub(r"\s+", " ", str(raw or "")).strip()
    if len(name) < 2 or len(name) > NAME_MAX:
        raise CertError("bad_name")
    if re.search(r"(https?:|www\.|\.com\b|[<>{}\[\]@#/\\|=_*$%^~`])", name, flags=re.I):
        raise CertError("bad_name")
    if re.search(r"[0-9০-৯]", name):
        raise CertError("bad_name")
    if forbidden_in(name) or re.search(r"\b(band|official|certified)\b", name, re.I):
        raise CertError("bad_name")
    return name


# ---------------------------------------------------------------- seams

def result_token(user, course, level, score=None):
    """Signed proof that the SERVER graded this result for this user. Hand it
    to the app; the app claims the certificate with it (7 days)."""
    lv = _check_course_level(course, level)
    sc = _check_score(score)
    return signing.dumps({"u": user.pk, "c": course, "l": lv, "s": sc}, salt=SALT,
                         compress=True)


def read_token(user, token):
    try:
        d = signing.loads(str(token or ""), salt=SALT, max_age=TOKEN_MAX_AGE)
    except signing.BadSignature:
        raise CertError("bad_token")
    if not isinstance(d, dict) or d.get("u") != user.pk:
        raise CertError("bad_token")
    return d["c"], d["l"], d.get("s")


def _rows(user=None):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(collection=COLL)
    return qs.filter(user=user) if user is not None else qs


def issue_certificate(user, course, level, score=None, name=None):
    """Issue (or return the existing) certificate. Same course + level that is
    still valid -> the existing one (score raised if the new one is higher).
    Returns the row as `as_dict(row, lang)`-ready PaCollectionItem."""
    from .models import PaCollectionItem
    lv = _check_course_level(course, level)
    sc = _check_score(score)
    nm = clean_name(name if name else (getattr(user, "name", "") or ""))
    for row in _rows(user):
        d = row.data or {}
        if d.get("course") == course and d.get("level") == lv and not d.get("revoked_at"):
            changed = False
            if sc is not None and (d.get("score") is None or sc > d["score"]):
                d["score"] = sc
                changed = True
            if name and nm != d.get("name"):
                d["name"] = nm
                changed = True
            if changed:
                row.data = d
                row.save(update_fields=["data", "updated_at"])
            return row
    since = timezone.now() - datetime.timedelta(days=1)
    if _rows(user).filter(created_at__gte=since).count() >= MAX_PER_DAY:
        raise CertError("too_many")
    code = new_code()
    while _rows().filter(data__code=code).exists():   # astronomically rare
        code = new_code()
    return PaCollectionItem.objects.create(user=user, collection=COLL, data={
        "code": code, "course": course, "level": lv, "score": sc, "name": nm,
        "issued_at": timezone.now().isoformat(), "revoked_at": None})


def find(code):
    c = normalize_code(code)
    if c is None:
        return None
    return _rows().filter(data__code=c).first()


def revoke(row, by="owner"):
    d = row.data or {}
    if not d.get("revoked_at"):
        d["revoked_at"] = timezone.now().isoformat()
        d["revoked_by"] = by
        row.data = d
        row.save(update_fields=["data", "updated_at"])
    return row


def _issued(row):
    from django.utils.dateparse import parse_datetime
    return parse_datetime((row.data or {}).get("issued_at") or "") or row.created_at


def as_dict(row, lang="bn"):
    """Everything the app's certificate card shows (both languages, so the
    card follows the app language without another call)."""
    d = row.data or {}
    out = {"id": row.id, "code": d.get("code"), "course": d.get("course"),
           "level": d.get("level"), "score": d.get("score"), "name": d.get("name"),
           "issued_at": d.get("issued_at"), "valid": not d.get("revoked_at"),
           "revoked_at": d.get("revoked_at"), "verify_url": verify_url(d.get("code")),
           "kind": COURSES.get(d.get("course"), {}).get("kind", "")}
    for lg in ("bn", "en"):
        out[lg] = card_text(row, lg)
    return out


def card_text(row, lang):
    """Every visible line of the certificate in one language."""
    d = row.data or {}
    T = TXT[lang]
    return {"title": T["title"], "awarded": T["awarded"], "completed": T["completed"],
            "name": d.get("name") or "",
            "course": course_title(d.get("course"), lang),
            "level": level_text(d["course"], d["level"], lang) if d.get("course") in COURSES else "",
            "score": score_text(d.get("score"), lang),
            "date": date_text(_issued(row), lang),
            "level_label": T["level"], "score_label": T["score"], "date_label": T["date"],
            "code_label": T["code"], "disclaimer": DISCLAIMER[lang]}


def public_view(row, lang):
    """The minimal public facts for /verify/<code>: name, course, level, date,
    valid. Never the score, phone, email or user id."""
    t = card_text(row, lang)
    return {"name": t["name"], "course": t["course"], "level": t["level"],
            "date": t["date"], "valid": not (row.data or {}).get("revoked_at"),
            "code": (row.data or {}).get("code")}


# ---------------------------------------------------------------- PDF

def pdf_bytes(row, lang):
    """A one-page landscape A4 certificate (reportlab, the same tooling as the
    doctor-visit PDF). Honest limit: reportlab joins Bangla conjuncts only
    with uharfbuzz (not installed today); the app card is always right."""
    import io
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.pdfgen import canvas
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont

    font = "Helvetica"
    try:
        from .views import _NOTO_BN_TTF
        if "NotoBn" not in pdfmetrics.getRegisteredFontNames():
            pdfmetrics.registerFont(TTFont("NotoBn", _NOTO_BN_TTF))
        font = "NotoBn"
    except Exception:  # noqa: BLE001 — Latin fallback, never a 500
        font = "Helvetica"
    if font == "Helvetica" and lang == "bn":
        lang = "en"
    t = card_text(row, lang)
    code = (row.data or {}).get("code") or ""
    buf = io.BytesIO()
    page = landscape(A4)
    c = canvas.Canvas(buf, pagesize=page)
    c.setTitle(t["title"])
    c.setAuthor("Assisto")
    w, h = page
    # brand frame (cyan -> blue -> purple)
    for i, col in enumerate(((0.0, 0.74, 0.83), (0.15, 0.39, 0.92), (0.49, 0.23, 0.93))):
        c.setStrokeColorRGB(*col)
        c.setLineWidth(4)
        c.rect(24 + i * 6, 24 + i * 6, w - 48 - i * 12, h - 48 - i * 12)
    c.setFillColorRGB(0.07, 0.09, 0.15)

    def put(size, x, y, text, center=True):
        # Bangla text -> Noto Bengali; Latin -> Helvetica (always has Latin glyphs)
        c.setFont(font if _BN_RE.search(text) else "Helvetica", size)
        (c.drawCentredString if center else c.drawString)(x, y, text)

    y = h - 110
    put(30, w / 2, y, t["title"]); y -= 50
    put(14, w / 2, y, t["awarded"]); y -= 42
    put(28, w / 2, y, t["name"][:NAME_MAX]); y -= 40
    put(14, w / 2, y, t["completed"]); y -= 28
    put(20, w / 2, y, t["course"]); y -= 34
    put(16, w / 2, y, "%s: %s" % (t["level_label"], t["level"])); y -= 24
    if t["score"]:
        put(16, w / 2, y, "%s: %s" % (t["score_label"], t["score"])); y -= 24
    put(16, w / 2, y, "%s: %s" % (t["date_label"], t["date"])); y -= 34
    # QR -> public verify page
    try:
        from reportlab.graphics import renderPDF
        from reportlab.graphics.barcode.qr import QrCodeWidget
        from reportlab.graphics.shapes import Drawing
        q = QrCodeWidget(verify_url(code))
        x0, y0, x1, y1 = q.getBounds()
        size = 92
        dr = Drawing(size, size, transform=[size / (x1 - x0), 0, 0, size / (y1 - y0), 0, 0])
        dr.add(q)
        renderPDF.draw(dr, c, w - 60 - size, 60)
    except Exception:  # noqa: BLE001
        pass
    c.setFillColorRGB(0.07, 0.09, 0.15)
    put(11, 60, 92, "%s: %s" % (t["code_label"], code), center=False)
    put(11, 60, 76, "%s: %s" % (TXT[lang]["check"], verify_url(code)), center=False)
    c.setFillColorRGB(0.55, 0.11, 0.07)
    put(12, 60, 56, t["disclaimer"], center=False)
    c.showPage()
    c.save()
    return buf.getvalue()
