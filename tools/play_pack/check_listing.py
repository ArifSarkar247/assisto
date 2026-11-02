#!/usr/bin/env python3
"""Play listing pack gate (owner order 3 Nov): every limit + every banned word.

    python3 tools/play_pack/check_listing.py      # exit 1 on any problem

Checks every text file in owner_actions/PLAY_LISTING_PACK (main listing and
the custom store listings) plus the screenshot / feature-graphic headlines:
  * Play limits: app name <= 30, short description <= 80, full description
    <= 4000, also with the "after AI is on" add-on block appended;
  * Play metadata policy: no ranking or "best" claims, no calls to action,
    no emoji, no keyword stuffing, no price claims that could change,
    no ALL-CAPS words in the name / short description;
  * owner rules: never medicine, no competitor or third-party app names,
    no feature that is switched off ("Coming soon" on lifeassisto.com,
    3 Nov), strict language (no Bangla script in en-US; Bangla digits only
    in bn-BD).
Run in CI (play-pack.yml, and backend/web/tests_play_pack.py in checks.yml);
never on the server.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "owner_actions" / "PLAY_LISTING_PACK"

LIMITS = {"title.txt": 30, "short_description.txt": 80, "full_description.txt": 4000}

# ranking / superlative / call-to-action words (Play metadata policy)
BANNED_EN = [
    r"best", r"#\s*1", r"no\.\s*1", r"number one", r"top", r"top-rated", r"leading",
    r"ranked", r"award\w*", r"million", r"most popular", r"fastest", r"cheapest",
    r"ultimate", r"guaranteed?", r"download now", r"install now", r"try now",
    r"sale", r"discount", r"\d+\s*% off", r"lowest price", r"free download",
    r"revolutionary", r"world'?s first", r"#\w+",
]
BANNED_BN = ["সেরা", "এক নম্বর", "১ নম্বর", "শীর্ষ", "সবচেয়ে ভালো", "সবচেয়ে জনপ্রিয়", "সর্বশ্রেষ্ঠ",
             "ছাড়", "ডিসকাউন্ট", "এখনই ডাউনলোড", "এখনই ইনস্টল", "লাখ ব্যবহারকারী"]
# never medicine (owner rule) — superset of web.site_v3.MEDICINE_WORDS
MEDICINE = ["medicine", "medicines", "medication", "pill", "pills", "doctor", "prescription",
            "pharma", "pharmacy", "drug", "ওষুধ", "ঔষধ", "ডাক্তার", "প্রেসক্রিপশন", "ফার্মেসি"]
# competitor / third-party app names (owner rule: none in the listing)
COMPETITORS = ["whatsapp", "messenger", "facebook", "imo", "viber", "telegram", "tiktok", "pathao",
               "uber", "foodpanda", "truecaller", "life360", "bkash", "nagad", "rocket", "hikvision",
               "dahua", "imou", "netflix", "হোয়াটসঅ্যাপ", "মেসেঞ্জার", "ফেসবুক", "ইমো", "পাঠাও",
               "উবার", "বিকাশ", "নগদ", "ভাইবার", "টেলিগ্রাম"]
COMPETITORS_CASED = [r"\bSignal\b"]   # the word "signal" itself is fine
# features "Coming soon" on lifeassisto.com (3 Nov, Play build flags) — never
# claimed as available. full_description_ai_addon.txt is the one exception
# for "ask anything" and is pasted only after the owner sees a real AI answer.
SOON = ["destination alarm", "train tracker", "kids watch", "school mode", "missing person",
        "fall detection", "fall detect", "guard box", "booking bot", "crm automation", "full books",
        "agent studio", "dictionary", "language partner", "ai inbox", "assisto agent", "remittance",
        "ask anything", "গন্তব্য", "ট্রেন ট্র্যাকার", "হারানো মানুষ", "নিখোঁজ", "পড়ে যাওয়া", "গার্ড বক্স",
        "বুকিং বট", "রেমিট্যান্স", "অভিধান", "এজেন্ট স্টুডিও", "যা খুশি জিজ্ঞেস"]
# price claims that could change
PRICE = [r"[৳$€£]", r"\b(?:tk|bdt|usd|aed|sar|myr|rm)\b", r"\d[\d,.]*\s*(?:taka|টাকা)",
         r"[০-৯][০-৯,]*\s*টাকা", r"per month", r"/\s*month", r"a month\b", r"মাসে\s*[০-৯\d]", r"per year"]
CAPS_OK = {"AI", "SOS", "CCTV", "VAT", "QR", "PIN", "GPS", "CRM", "CV", "IP", "A4", "OK"}
STOP = {"your", "and", "with", "from", "the", "for", "that", "only", "plan", "plans", "one", "in",
        "আর", "ও", "আপনার", "থেকে", "এক", "জায়গায়"}
EMOJI = re.compile("[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0000FE0F\U0001F900-\U0001F9FF"
                   "\U00002B00-\U00002BFF\U0000200D\U000023E9-\U000023FA]")
BN_SCRIPT = re.compile("[ঀ-৿]")


def _hits(text, lang, extra_soon=True):
    low = text.lower()
    out = []
    for w in BANNED_EN:
        if re.search(r"(?<![\w#])" + w + r"(?!\w)", low):
            out.append("ranking/CTA word '%s'" % w)
    for w in BANNED_BN + MEDICINE + COMPETITORS:
        if re.fullmatch(r"[a-z0-9 ]+", w):
            if re.search(r"\b" + re.escape(w) + r"\b", low):
                out.append("banned word '%s'" % w)
        elif w in text:
            out.append("banned word '%s'" % w)
    for w in COMPETITORS_CASED:
        if re.search(w, text):
            out.append("competitor name %s" % w)
    if extra_soon:
        for w in SOON:
            if w in low:
                out.append("switched-off feature '%s'" % w)
    for w in PRICE:
        if re.search(w, low):
            out.append("price claim /%s/" % w)
    if EMOJI.search(text):
        out.append("emoji")
    if lang == "en-US" and BN_SCRIPT.search(text):
        out.append("Bangla script in en-US text")
    if lang == "bn-BD":
        for m in re.finditer(r"[A-Za-z]*[0-9]+[A-Za-z]*", text):
            if m.group(0) not in ("A4",):
                out.append("ASCII digits in bn-BD text: '%s' (use Bangla digits)" % m.group(0))
    return out


def _stuffing(text):
    words = re.findall(r"[\wঀ-৿]+", text.lower())
    out = []
    for w in set(words):
        n = words.count(w)
        limit = 12 if w == "assisto" else 8
        if len(w) >= 4 and w not in STOP and n > limit:
            out.append("keyword stuffing: '%s' x%d (max %d)" % (w, n, limit))
    return out


def listing_dirs():
    return sorted(p.parent for p in PACK.rglob("title.txt"))


def check_all():
    problems = []
    dirs = listing_dirs()
    if len(dirs) < 2:
        problems.append("no listing folders found")
    for d in dirs:
        lang = d.name
        if lang not in ("en-US", "bn-BD"):
            problems.append("%s: unknown language folder" % d)
            continue
        addon = (PACK / "listing" / lang / "full_description_ai_addon.txt").read_text("utf-8")
        for fn, limit in LIMITS.items():
            p = d / fn
            rel = p.relative_to(ROOT)
            if not p.is_file():
                problems.append("%s missing" % rel)
                continue
            txt = p.read_text("utf-8").rstrip("\n")
            if not txt.strip():
                problems.append("%s empty" % rel)
            if len(txt) > limit:
                problems.append("%s: %d chars > %d" % (rel, len(txt), limit))
            if fn == "full_description.txt" and len(txt) + len(addon.rstrip("\n")) > limit:
                problems.append("%s + AI add-on: %d chars > %d" % (rel, len(txt) + len(addon), limit))
            if fn != "full_description.txt":
                if "\n" in txt:
                    problems.append("%s must be one line" % rel)
                for w in re.findall(r"\b[A-Z]{2,}\b", txt):
                    if w not in CAPS_OK:
                        problems.append("%s: ALL-CAPS word '%s'" % (rel, w))
            if fn == "title.txt" and not txt.startswith("Assisto"):
                problems.append("%s: app name must start with Assisto" % rel)
            if fn == "full_description.txt":
                problems += ["%s: %s" % (rel, h) for h in _stuffing(txt)]
                first = txt.split("\n", 1)[0]
                if not first.startswith("Assisto:"):
                    problems.append("%s: must open with the website hero headline" % rel)
            problems += ["%s: %s" % (rel, h) for h in _hits(txt, lang)]
        a_rel = (PACK / "listing" / lang / "full_description_ai_addon.txt").relative_to(ROOT)
        if d == PACK / "listing" / lang:
            problems += ["%s: %s" % (a_rel, h) for h in _hits(addon, lang, extra_soon=False)]
    spec = json.loads((PACK / "screenshots.json").read_text("utf-8"))
    if len(spec["slots"]) != 8:
        problems.append("screenshots.json: need exactly 8 slots")
    for i, s in enumerate(spec["slots"], 1):
        for lang, key in (("en-US", "en"), ("bn-BD", "bn")):
            for line in s[key]:
                problems += ["screenshot %d %s: %s" % (i, key, h) for h in _hits(line, lang)]
                if len(line) > 48:
                    problems.append("screenshot %d %s: headline too long (%d > 48)" % (i, key, len(line)))
    for lang, key in (("en-US", "en"), ("bn-BD", "bn")):
        for line in spec["feature_graphic"][key]:
            problems += ["feature graphic %s: %s" % (key, h) for h in _hits(line, lang)]
    for name, order in spec["custom_order"].items():
        if sorted(order) != list(range(1, 9)):
            problems.append("custom_order %s must use each screenshot 1-8 once" % name)
    return problems


def main():
    problems = check_all()
    for d in listing_dirs():
        print("%-45s " % d.relative_to(PACK) + "  ".join(
            "%s=%d" % (f.split("_")[0].split(".")[0], len((d / f).read_text("utf-8").rstrip("\n")))
            for f in LIMITS if (d / f).is_file()))
    for p in problems:
        print("FAIL", p)
    print("play listing pack: %d problem(s)" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
