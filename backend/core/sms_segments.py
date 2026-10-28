"""
SMS segment counting (smsotp) — pure, no Django.

  * GSM-7 (3GPP TS 23.038 default alphabet): 160 chars in one SMS, 153 per
    part when multipart (7 septets go to the UDH). Characters of the
    extension table ( ^ { } \\ [ ~ ] | € and form feed) cost TWO septets.
  * Anything outside GSM-7 — Bangla always — goes as UCS-2: 70 chars in one
    SMS, 67 per part when multipart. UCS-2 counts UTF-16 code units, so an
    emoji (outside the BMP) costs 2.

    info("Assisto: আপনার কোড ১২৩৪৫৬") -> {"encoding": "ucs2", "units": 25,
                                         "segments": 1, "per_segment": 70}
"""

_GSM_BASIC = set(
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
_GSM_EXT = set("^{}\\[~]|€\f")

GSM_SINGLE, GSM_MULTI = 160, 153
UCS2_SINGLE, UCS2_MULTI = 70, 67


def is_gsm7(text):
    return all(ch in _GSM_BASIC or ch in _GSM_EXT for ch in (text or ""))


def _ucs2_units(text):
    return len((text or "").encode("utf-16-le")) // 2


def info(text):
    """{encoding, units, segments, per_segment} for `text`."""
    text = text or ""
    if is_gsm7(text):
        units = sum(2 if ch in _GSM_EXT else 1 for ch in text)
        single, multi, enc = GSM_SINGLE, GSM_MULTI, "gsm7"
    else:
        units = _ucs2_units(text)
        single, multi, enc = UCS2_SINGLE, UCS2_MULTI, "ucs2"
    if units <= single:
        return {"encoding": enc, "units": units, "segments": 1 if units else 0,
                "per_segment": single}
    return {"encoding": enc, "units": units, "segments": -(-units // multi),
            "per_segment": multi}


def segments(text):
    return info(text)["segments"]
