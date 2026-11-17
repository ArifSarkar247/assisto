#!/usr/bin/env python3
"""bnreview — BANGLA GLOSSARY gate (owner_actions/BANGLA_GLOSSARY_BN.md).

One word for one concept: fails (exit 1) when a bn ARB value, or the Bangla
text of the backend's user-facing message modules below, uses a BANNED variant
from the glossary. Each finding prints key/file, the banned word and the
glossary word to use instead. Run from app/ (or pass the app dir):
  python3 tool/bn_glossary_gate.py
Keep this table in step with the glossary doc (same rows, same order).
"""
import json
import os
import re
import sys

APP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BN_ARB = os.path.join(APP, "lib", "l10n", "app_bn.arb")
BACKEND = os.path.join(APP, "..", "backend")
B = "ঀ-৿"
NB = r"(?<![" + B + r"])"  # not inside a longer Bangla word on the left

# (banned regex, use instead)
BANNED = [
    (r"কিভাবে", "কীভাবে"),
    (r"এখনও", "এখনো"),
    (r"কখনও", "কখনো"),
    (r"জরুরী", "জরুরি"),
    (r"ইমার্জেন্সি", "জরুরি"),
    (r"শ্রেণী", "শ্রেণি"),
    (r"ঘন্টা", "ঘণ্টা"),
    (r"লিঙ্ক", "লিংক"),
    (r"সিংক", "সিঙ্ক"),
    (r"ডাটা", "ডেটা"),
    (r"লগ ইন", "লগইন"),
    (r"পুনরায়", "আবার"),
    (r"অনুগ্রহ করে", "দয়া করে"),
    (r"নির্বাচন করুন", "বেছে নিন"),
    (r"বিজ্ঞপ্তি", "নোটিফিকেশন"),
    (r"ডিলিট", "মুছুন / মুছে ফেলা"),
    (r"মেম্বার", "সদস্য"),
    (r"কাস্টমার(?! কেয়ার)", "গ্রাহক"),
    (r"মাই সার্কেল|My Circle", "আমার সার্কেল"),
    (r"সেফ জার্নি|Safe Journey", "নিরাপদ যাত্রা"),
    (NB + r"এআই", "AI"),
    (NB + r"এসওএস", "SOS"),
    (NB + r"কিউআর", "QR"),
    (NB + r"ওটিপি", "OTP"),
    (NB + r"এসএমএস", "SMS"),
    (NB + r"জিপিএস", "GPS"),
    (NB + r"পিডিএফ", "PDF"),
    (r"Wi-Fi|ওয়াইফাই", "ওয়াই-ফাই"),
    (r"অ্যাসিস্টো", "Assisto"),
    (r"(?<![A-Za-z])Premium(?![A-Za-z]| Pro)", "প্রিমিয়াম"),  # "Premium Pro" = a store SKU name
    (r"(?<![A-Za-z])Integrations(?![A-Za-z])", "ইন্টিগ্রেশন"),
    (r"[" + B + r"]\s*\.\.\.", "…"),
]
BANNED = [(re.compile(p), p, use) for p, use in BANNED]
LONE = re.compile(r"এআই|এসওএস|কিউআর|ওটিপি|এসএমএস|জিপিএস|পিডিএফ|অ্যাসিস্টো|[\s·—,./:-]")  # script-choice terms + separators

# Keys that are NOT UI prose: search-keyword banks, user-speech synonym lists,
# brand handles. Variants there are on purpose (users type/say them).
SKIP_KEY = re.compile(r"(Kw|Keywords|Months|ToneP|Synonym|Lexicon)")
# The wake phrase is said aloud: "হেই অ্যাসিস্টো" stays in Bangla script.
WAKE = re.compile(r"(হেই|হাই|ওকে) অ্যাসিস্টো")
# Reviewed exceptions: "<key>|<banned regex>" (the reason goes in the glossary).
ALLOW = {
    "paLetPhraseNotice|বিজ্ঞপ্তি",  # a formal letter's "Notice" heading
}
# Backend modules whose Bangla strings are shown to users as-is (pushes, emails,
# owner admin labels, AI system prompt). Matcher/keyword modules are NOT listed.
BACKEND_FILES = [
    "core/ai_prompt.py", "core/email_templates.py", "core/push.py",
    "core/budget_push.py", "core/agentcore/approval_push.py",
    "core/logic/ad_control.py", "core/feature_flags.py", "web/owner/i18n.py",
]
BN_LITERAL = re.compile(r"\"([^\"\n]*[" + B + r"][^\"\n]*)\"|'([^'\n]*[" + B + r"][^'\n]*)'")


def scan(where, text, out):
    if WAKE.search(text):
        text = WAKE.sub("", text)
        rules = [r for r in BANNED if r[1] != "অ্যাসিস্টো"]
    else:
        rules = BANNED
    for rx, pat, use in rules:
        if "%s|%s" % (where.split(":")[0], pat) in ALLOW:
            continue
        m = rx.search(text)
        if m:
            out.append("%s: '%s' → use '%s'" % (where, m.group(0).strip(), use))


def main():
    out = []
    bn = json.load(open(BN_ARB, encoding="utf-8"))
    for k, v in bn.items():
        if k.startswith("@") or not isinstance(v, str) or SKIP_KEY.search(k):
            continue
        if not re.search("[" + B + "]", v):
            continue  # a pure brand/format string, not Bangla prose
        if not re.search("[" + B + "]", LONE.sub("", v)):
            continue  # a lone term label ("এসএমএস"): Bangla script on purpose,
            # a Latin-only bn label would read as untranslated English
        scan(k, v, out)
    for rel in BACKEND_FILES:
        p = os.path.join(BACKEND, rel)
        if not os.path.exists(p):
            continue
        for i, line in enumerate(open(p, encoding="utf-8"), 1):
            for m in BN_LITERAL.finditer(line):
                scan("%s:%d" % (rel, i), m.group(1) or m.group(2), out)
    for o in out:
        print("GLOSSARY", o)
    print("bn glossary gate: %d finding(s)" % len(out))
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
