"""cctvdet stage 2: NUMBER PLATES of vehicles going in / out or parked.

Plates are not faces: a plate is a registration number on a vehicle, never
a person's face or identity, and it is only ever read on the owner's own
camera for the owner's own gate / parking.

Two readers, both optional, both honest about what they did:
  1. ON THE BOX (offline): the open-source, MIT-licensed `open-image-models`
     plate detector (YOLO ONNX, a few MB) finds the plate inside the vehicle
     box and `fast-plate-ocr` (MIT, ONNX, a few MB) reads it. Those models
     read Latin letters and digits — English plates (and the digits of a
     Bangladeshi plate written in English) only. Not installed -> skipped.
  2. ON THE SERVER: the alert's photo (the vehicle) goes through the same
     Claude vision description as every alert; for vehicle alerts the prompt
     also asks for the plate exactly as written — Bangla script included
     (core/logic/cctv_brief.py). Either text is normalised by parse_bd_plate.

Bangladesh plate format (BRTA): "<district> [মেট্রো]-<class letter> <NN>-<NNNN>",
e.g. "ঢাকা মেট্রো-গ ১২-৩৪৫৬" or in English "DHAKA METRO-GA 12-3456".
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


class PlateReader:
    """Optional on-box reader (open-image-models + fast-plate-ocr, MIT).
    `available` is False when they are not installed — the server's AI
    reading of the alert photo is then the only plate reader."""

    name = "open_image_models+fast_plate_ocr"

    def __init__(self):
        self.available = False
        self._det = self._ocr = None
        try:  # pragma: no cover - optional dependency, not on CI by default
            from open_image_models import LicensePlateDetector
            from fast_plate_ocr import LicensePlateRecognizer
            self._det = LicensePlateDetector(detection_model="yolo-v9-t-384-license-plate-end2end")
            self._ocr = LicensePlateRecognizer("cct-xs-v1-global-model")
            self.available = True
        except Exception:
            self.available = False

    def read(self, frame_bgr, box) -> Optional[dict]:
        """The plate inside the vehicle `box` (normalised) -> parsed plate
        + {"source": "box_ocr"} or None. Never raises."""
        if not self.available or frame_bgr is None:
            return None
        try:  # pragma: no cover - exercised only with the optional models
            import cv2
            h, w = frame_bgr.shape[:2]
            x1, y1 = int(max(0.0, box[0]) * w), int(max(0.0, box[1]) * h)
            x2, y2 = int(min(1.0, box[2]) * w), int(min(1.0, box[3]) * h)
            car = frame_bgr[y1:y2, x1:x2]
            if car.size == 0:
                return None
            found = self._det.predict(car)
            if not found:
                return None
            bb = found[0].bounding_box
            plate = car[max(0, int(bb.y1)):int(bb.y2), max(0, int(bb.x1)):int(bb.x2)]
            if plate.size == 0:
                return None
            text = self._ocr.run(cv2.cvtColor(plate, cv2.COLOR_BGR2GRAY))
            if isinstance(text, (list, tuple)):
                text = text[0] if text else ""
            p = parse_bd_plate(str(text).replace("_", ""))
            if p:
                p["source"] = "box_ocr"
            return p
        except Exception:
            return None
