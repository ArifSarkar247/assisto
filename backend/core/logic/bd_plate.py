"""bd_plate.py — PURE Bangladesh number-plate parser (cctvdet stage 2): the
SAME code as edge/shopbox/shopbox/plates.py parse_bd_plate (a backend test
runs both on the shared cases). Used on the plate text the alert photo's AI
description reads (Bangla or English). Plates are not faces.
"""
from __future__ import annotations

import re
from typing import Optional

_BN_DIGITS = "০১২৩৪৫৬৭৮৯"
_TO_EN = str.maketrans(_BN_DIGITS, "0123456789")
_TO_BN = str.maketrans("0123456789", _BN_DIGITS)

# district / metro words (Bangla, English) — the common ones on BD plates
CITIES = {
    "ঢাকা": "DHAKA", "চট্টগ্রাম": "CHATTOGRAM", "চট্ট": "CHATTA", "খুলনা": "KHULNA",
    "রাজশাহী": "RAJSHAHI", "সিলেট": "SYLHET", "বরিশাল": "BARISHAL", "রংপুর": "RANGPUR",
    "ময়মনসিংহ": "MYMENSINGH", "গাজীপুর": "GAZIPUR", "নারায়ণগঞ্জ": "NARAYANGANJ",
    "কুমিল্লা": "CUMILLA", "বগুড়া": "BOGURA", "যশোর": "JASHORE",
}
METRO_BN, METRO_EN = "মেট্রো", "METRO"
# BRTA class letters (Bangla) and their usual English spelling on plates
CLASS_LETTERS = {"ক": "KA", "খ": "KHA", "গ": "GA", "ঘ": "GHA", "চ": "CHA", "ছ": "CHHA",
                 "জ": "JA", "ঝ": "JHA", "ত": "TA", "থ": "THA", "ঢ": "DHA", "ড": "DA",
                 "ট": "TTA", "ঠ": "THHA", "দ": "DA", "ন": "NA", "প": "PA", "ফ": "FA",
                 "ব": "BA", "ভ": "BHA", "ম": "MA", "য": "JA", "র": "RA", "ল": "LA",
                 "শ": "SHA", "স": "SA", "হ": "HA", "উ": "U", "এ": "E"}
_EN_CLASS = {v: k for k, v in CLASS_LETTERS.items()}

_BN_RE = re.compile(r"(?P<city>[ঀ-৿]+)\s*(?P<metro>মেট্রো)?\s*[-–‐]?\s*"
                    r"(?P<cls>[ক-হ])\s*[-–‐]?\s*"
                    r"(?P<a>[০-৯0-9]{2})\s*[-–‐]\s*(?P<b>[০-৯0-9]{4})")
_EN_RE = re.compile(r"(?P<city>[A-Z]+)\s*(?P<metro>METRO)?\s*[-–]?\s*(?P<cls>[A-Z]{1,4})\s*[-–]?\s*"
                    r"(?P<a>\d{2})\s*[-–]?\s*(?P<b>\d{4})")
_NUM_ONLY = re.compile(r"(?<!\d)(?P<a>\d{2})\s*[-–]?\s*(?P<b>\d{4})(?!\d)")


def parse_bd_plate(text: Optional[str]) -> Optional[dict]:
    """Free text (OCR / AI) -> {"bn", "en", "number", "city", "metro", "class",
    "partial"} or None. A full Bangla or English BD plate is normalised to
    both scripts; a bare "12-3456" is kept as a partial number."""
    if not text or not isinstance(text, str):
        return None
    t = " ".join(text.replace("\n", " ").split())
    m = _BN_RE.search(t)
    if m and m.group("cls") in CLASS_LETTERS:
        city_bn = m.group("city")
        city_en = CITIES.get(city_bn)
        a, b = m.group("a").translate(_TO_EN), m.group("b").translate(_TO_EN)
        metro = bool(m.group("metro"))
        cls_bn = m.group("cls")
        return _out(city_bn, city_en or "", metro, cls_bn, CLASS_LETTERS[cls_bn], a, b)
    up = t.upper()
    m = _EN_RE.search(up)
    if m and m.group("cls") in _EN_CLASS:
        city_en = m.group("city")
        city_bn = next((k for k, v in CITIES.items() if v == city_en), "")
        if city_bn or m.group("metro"):
            return _out(city_bn, city_en, bool(m.group("metro")), _EN_CLASS[m.group("cls")],
                        m.group("cls"), m.group("a"), m.group("b"))
    m = _NUM_ONLY.search(t.translate(_TO_EN))
    if m:
        num = "%s-%s" % (m.group("a"), m.group("b"))
        return {"bn": num.translate(_TO_BN), "en": num, "number": num, "city": "",
                "metro": False, "class": "", "partial": True}
    return None


def _out(city_bn, city_en, metro, cls_bn, cls_en, a, b):
    num = "%s-%s" % (a, b)
    bn = "%s%s-%s %s" % (city_bn, (" " + METRO_BN) if metro else "", cls_bn, num.translate(_TO_BN))
    en = "%s%s-%s %s" % (city_en, (" " + METRO_EN) if metro else "", cls_en, num)
    return {"bn": bn.strip(), "en": en.strip(), "number": num, "city": city_en,
            "metro": metro, "class": cls_en, "partial": not (city_bn or city_en)}
