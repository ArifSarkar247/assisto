"""safe_link.py — local "is this link risky?" heuristics (circlea).

Pure, no network.  The SAME rules run on the phone
(app/lib/messaging/safe_link.dart) so end-to-end-encrypted chats are checked
without the URL ever leaving the phone; the server copy is used for channel
posts (plaintext) where it can also resolve shorteners and ask Google Safe
Browsing when a key is configured (core.link_preview / views_circlea).

verdict:  "bad"  -> lookalike of a payment / login brand, or "user@host"
          "warn" -> punycode / non-ASCII host, raw IP host, URL shortener,
                    plain http, suspicious TLD
          "ok"   -> none of the above
"""
from __future__ import annotations

import ipaddress
from urllib.parse import urlsplit

SHORTENERS = frozenset({
    "bit.ly", "bitly.com", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd",
    "buff.ly", "cutt.ly", "rb.gy", "shorturl.at", "rebrand.ly", "tiny.cc", "s.id",
    "t.ly", "lnkd.in", "shorte.st", "adf.ly", "v.gd", "bl.ink", "short.io",
    "tr.im", "qr.ae", "surl.li", "u.to", "clck.ru", "shrtco.de",
})

SUSPICIOUS_TLDS = frozenset({
    "zip", "mov", "xyz", "top", "click", "country", "gq", "tk", "ml", "cf", "ga",
    "work", "loan", "men", "rest", "cam", "icu", "buzz", "monster", "cyou", "sbs",
    "cfd", "quest", "bond", "lol", "support", "beauty",
})

# brand token -> official registrable domains
BRANDS = {
    "bkash": ("bkash.com",),
    "nagad": ("nagad.com.bd",),
    "rocket": ("dutchbanglabank.com",),
    "upay": ("upaybd.com",),
    "dbbl": ("dutchbanglabank.com",),
    "sonalibank": ("sonalibank.com.bd",),
    "bracbank": ("bracbank.com",),
    "facebook": ("facebook.com", "fb.com", "fb.watch", "fb.me", "messenger.com"),
    "whatsapp": ("whatsapp.com", "wa.me", "whatsapp.net"),
    "google": ("google.com", "google.com.bd", "goo.gl", "youtube.com", "g.co"),
    "youtube": ("youtube.com", "youtu.be"),
    "instagram": ("instagram.com",),
    "tiktok": ("tiktok.com",),
    "paypal": ("paypal.com",),
    "assisto": ("lifeassisto.com",),
    "daraz": ("daraz.com.bd",),
}
# generic words: flagged only next to a login / money word
AMBIGUOUS = frozenset({"rocket", "upay", "google", "assisto", "daraz"})
LOGIN_WORDS = ("login", "signin", "verify", "secure", "account", "update", "bonus",
               "reward", "gift", "free", "otp", "pin", "wallet", "kyc")

_SECOND_LEVEL = {"com", "net", "org", "gov", "edu", "ac", "co", "mil", "info"}
_LEET = str.maketrans({"0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t",
                       "@": "a", "$": "s"})


def registrable(host):
    parts = [p for p in (host or "").lower().strip(".").split(".") if p]
    if len(parts) >= 3 and parts[-2] in _SECOND_LEVEL and len(parts[-1]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def _is_ip(host):
    try:
        ipaddress.ip_address(host.strip("[]"))
        return True
    except ValueError:
        return False


def _near(a, b):
    """Levenshtein distance <= 1 (typo-squats: b1kash, bkassh, nagadd)."""
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]:
        i += 1
    return (a[i + 1:] == b[i + 1:] or a[i:] == b[i + 1:] or a[i + 1:] == b[i:])


def check(url):
    """{verdict, reasons:[...], host, brand}.  Never raises."""
    reasons = []
    brand = ""
    try:
        p = urlsplit((url or "").strip())
    except ValueError:
        return {"verdict": "bad", "reasons": ["bad_url"], "host": "", "brand": ""}
    if not p.scheme and not p.netloc:
        p = urlsplit("http://" + (url or "").strip())
    scheme = (p.scheme or "").lower()
    netloc = p.netloc or ""
    if "@" in netloc:
        reasons.append("userinfo")
    host = (p.hostname or "").lower().strip(".")
    if scheme not in ("http", "https"):
        reasons.append("scheme")
    elif scheme == "http":
        reasons.append("not_https")
    if not host:
        return {"verdict": "bad", "reasons": reasons or ["bad_url"], "host": "", "brand": ""}
    if _is_ip(host):
        reasons.append("ip_host")
    if "xn--" in host or any(ord(c) > 127 for c in host):
        reasons.append("punycode")
    reg = registrable(host)
    if host in SHORTENERS or reg in SHORTENERS:
        reasons.append("shortener")
    tld = host.rsplit(".", 1)[-1] if "." in host else ""
    if tld in SUSPICIOUS_TLDS:
        reasons.append("suspicious_tld")
    flat = host.translate(_LEET).replace("-", "").replace(".", "")
    host_login = any(w in flat for w in LOGIN_WORDS)
    for b, official in BRANDS.items():
        if b in flat and reg not in official and (b not in AMBIGUOUS or host_login):
            brand = b
            reasons.append("lookalike")
            break
    if not brand:
        # typo-squat of a brand in any host label ("b1kash", "nagadd")
        for label in host.split("."):
            lab = label.replace("-", "")
            for b, official in BRANDS.items():
                if (len(b) >= 5 and b not in AMBIGUOUS and reg not in official
                        and (_near(lab, b) or _near(lab.translate(_LEET), b))):
                    brand = b
                    reasons.append("lookalike")
                    break
            if brand:
                break
    if not brand:
        # brand in the PATH of a non-official host + a login word
        path = (p.path or "").lower().translate(_LEET)
        for b, official in BRANDS.items():
            if b in path and reg not in official and any(w in path for w in LOGIN_WORDS):
                brand = b
                reasons.append("lookalike")
                break
    if "lookalike" in reasons or "userinfo" in reasons or "scheme" in reasons:
        verdict = "bad"
    elif reasons:
        verdict = "warn"
    else:
        verdict = "ok"
    return {"verdict": verdict, "reasons": reasons, "host": host, "brand": brand}
