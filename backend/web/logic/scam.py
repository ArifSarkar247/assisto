"""W2 — scam / fraud message checker (rule-based, honest, bn/en).

Advanced detection (SPEC v2.1 §21, web-adapted) — BD-specific patterns:
  - OTP / PIN / password phishing
  - bKash / Nagad / Rocket "wrong send, refund me" + agent-number fraud
  - Fake prize / lottery / gift
  - Job scam ("pay a fee to get hired", "data entry, 2000tk/day")
  - Loan scam ("instant loan, no documents")
  - Urgency / account-block pressure
  - Impersonation (official / customer care / govt)
  - Link analysis (shorteners, raw http, risky TLDs, look-alike domains)

Honest framing: this is a RULE-BASED SCREEN, not a legal verdict — it can miss
new scams and can over-flag. Sources are noted (patterns derived from public
BD fraud-awareness guidance from Bangladesh Bank / bKash / police cyber units;
no facts invented). Output localized (bn|en).

AI SEAM: views.py may add a one-line AI explanation when a key exists; the
rule-based verdict below is the always-available baseline.
"""
import re

URL = re.compile(r"(https?://[^\s]+|\b[\w\-]+\.(?:com|net|xyz|top|info|link|ml|tk|ga|ru|cn|club|online|site)\b)", re.I)
SHORTENERS = ["bit.ly", "tinyurl", "cutt.ly", "t.me", "wa.me", "is.gd", "shorturl",
              "rb.gy", "ow.ly", "buff.ly", "shorte.st", "linktr.ee"]
RISKY_TLD = re.compile(r"\.(xyz|top|tk|ml|ga|cf|gq|ru|cn|click|work|click)\b", re.I)
LOOKALIKE = re.compile(r"(bkash|nagad|rocket|bikash|bakash|nogod)[\-\.]?(login|verify|pay|secure|update|gift|bonus|offer)", re.I)
MFS = ["bkash", "বিকাশ", "nagad", "নগদ", "rocket", "রকেট", "upay", "উপায়", "বিকাস"]

# (weight, key, bn_reason, en_reason, patterns)
RULES = [
    (35, "otp",
     "PIN/OTP/পাসওয়ার্ড চাওয়া হয়েছে — কোনো আসল প্রতিষ্ঠান কখনো এগুলো চায় না",
     "Your PIN/OTP/password is being asked — no genuine company ever asks for these",
     [r"\bpin\b", r"\botp\b", r"ও\s*টি\s*পি", r"পিন", r"পাসওয়ার্ড", r"password",
      r"ভেরিফিকেশন কোড", r"verification code", r"কোড\s*টা?\s*দিন", r"কোড পাঠান"]),
    (30, "prize",
     "লটারি/পুরস্কার/গিফট জেতার লোভ দেখানো হয়েছে",
     "You're baited with a lottery / prize / gift win",
     [r"লটারি", r"lottery", r"পুরস্কার", r"prize", r"জিতেছেন", r"বিজয়ী", r"winner",
      r"congratulation", r"অভিনন্দন.*জিত", r"গিফট", r"\bgift\b", r"ফ্রি.*(টাকা|বোনাস|bonus)"]),
    (28, "refund",
     "\"ভুলে টাকা চলে গেছে, ফেরত দিন\" — bKash/Nagad রিফান্ড প্রতারণার চেনা কৌশল",
     "\"Money sent by mistake, please refund\" — a classic bKash/Nagad refund scam",
     [r"ভুল(ে|বশত).*(টাকা|পাঠ)", r"টাকা.*ফেরত", r"refund", r"wrong.*(number|send)",
      r"ভুল নম্বরে", r"সেন্ড মানি.*ভুল", r"ফিরিয়ে দিন"]),
    (25, "job",
     "চাকরির নামে আগে টাকা/ফি চাওয়া হচ্ছে — প্রায় সব ক্ষেত্রেই প্রতারণা",
     "A 'job' asking for an up-front fee — almost always a scam",
     [r"(চাকরি|job|নিয়োগ).*(ফি|fee|জামানত|রেজিস্ট্রেশন|নিবন্ধন|আগে.*টাকা)",
      r"data entry.*(\d+).*(টাকা|tk)", r"ঘরে বসে.*আয়", r"earn.*from home",
      r"part.?time.*(income|আয়)", r"দৈনিক.*(income|আয়).*(\d+)"]),
    (25, "loan",
     "\"কোনো কাগজ ছাড়াই তাৎক্ষণিক লোন\" — ভুয়া লোন প্রতারণার লক্ষণ",
     "\"Instant loan, no documents\" — a fake-loan scam signal",
     [r"(instant|তাৎক্ষণিক|সহজ).*(loan|লোন|ঋণ)", r"লোন.*(কাগজ|ডকুমেন্ট).*(ছাড়া|লাগবে না)",
      r"no.?document.*loan", r"কোনো জামানত.*(ছাড়া|নেই)"]),
    (20, "urgency",
     "দ্রুত/এখনই চাপ দেওয়া হচ্ছে (তাড়াহুড়ার কৌশল)",
     "You're being pressured to act fast (urgency tactic)",
     [r"এখনই", r"আজই", r"দ্রুত", r"তাড়াতাড়ি", r"urgent", r"immediately",
      r"within \d+ (hour|minute|min)", r"শেষ সুযোগ", r"last chance",
      r"account.*(block|suspend|বন্ধ|ব্লক|স্থগিত)",
      r"(একাউন্ট|অ্যাকাউন্ট|হিসাব).*(বন্ধ|ব্লক|স্থগিত|বাতিল)",
      r"\d+ (মিনিট|ঘণ্টা).*(মধ্যে|within)"]),
    (22, "money",
     "টাকা পাঠাতে/ক্যাশ ইন করতে বলা হচ্ছে",
     "You're told to send money / cash-in",
     [r"টাকা পাঠা", r"send money", r"ক্যাশ ইন", r"cash.?in", r"ফি দিন",
      r"চার্জ দিন", r"পেমেন্ট করুন", r"\b\d{3,}\s*(টাকা|tk|taka)\b", r"সেন্ড মানি"]),
    (18, "impersonate",
     "সরকারি/কোম্পানির পরিচয়ে প্রতারণার চেষ্টা",
     "Impersonating an official / company to gain trust",
     [r"অফিস থেকে বলছি", r"official", r"হেড অফিস", r"customer care", r"কাস্টমার কেয়ার",
      r"helpline থেকে", r"head office", r"(বিকাশ|নগদ|bkash|nagad).*(অফিস|office|team|টিম)"]),
]

ADVICE = {
    "bn": {
        "scam": "এটা প্রতারণা হতে পারে। কোনো PIN/OTP/পাসওয়ার্ড দেবেন না, টাকা পাঠাবেন না, "
                "লিংকে ক্লিক করবেন না। পরিবারের বড়দের সাবধান করুন।",
        "suspicious": "সাবধান থাকুন। পরিচয় যাচাই না করে কোনো তথ্য বা টাকা দেবেন না।",
        "safe": "স্পষ্ট প্রতারণার লক্ষণ পাওয়া যায়নি। তবুও অচেনা উৎস হলে সতর্ক থাকুন।",
        "report": "রিপোর্ট করুন: জরুরি হলে ৯৯৯; বিকাশ প্রতারণা → ১৬২৪৭; নগদ → ১৬১৬৭; "
                  "সাইবার অপরাধ → পুলিশের সাইবার ইউনিট / cyberpolice.gov.bd।",
        "no_reason": "স্পষ্ট প্রতারণার লক্ষণ পাওয়া যায়নি।",
        "link_bad": "সন্দেহজনক/শর্ট/ঝুঁকিপূর্ণ লিংক আছে — ক্লিক করবেন না",
        "link_lookalike": "আসল প্রতিষ্ঠানের মতো দেখতে ভুয়া লিংক (যেমন bkash-login.xyz) — ক্লিক করবেন না",
        "link_plain": "মেসেজে লিংক আছে — পাঠানো পরিচয় যাচাই না করে ক্লিক করবেন না",
        "mfs": "মোবাইল ব্যাংকিং নম্বর/লেনদেন উল্লেখ আছে — সরাসরি অফিসিয়াল হেল্পলাইনে যাচাই করুন",
        "disclaimer": "এটি একটি স্বয়ংক্রিয় স্ক্রিন, চূড়ান্ত রায় নয় — নতুন প্রতারণা ধরা না-ও পড়তে পারে।",
    },
    "en": {
        "scam": "This looks like a scam. Do NOT share any PIN/OTP/password, do NOT send money, "
                "do NOT click links. Warn the elders in your family.",
        "suspicious": "Be careful. Don't share any info or money without verifying the sender.",
        "safe": "No clear scam signals found. Still, stay cautious with unknown senders.",
        "report": "Report it: emergencies → 999; bKash fraud → 16247; Nagad → 16167; "
                  "cybercrime → Police Cyber Unit / cyberpolice.gov.bd.",
        "no_reason": "No clear scam signals found.",
        "link_bad": "A suspicious / shortened / risky link is present — do not click it",
        "link_lookalike": "A fake look-alike link (e.g. bkash-login.xyz) — do not click it",
        "link_plain": "There's a link in the message — don't click without verifying the sender",
        "mfs": "A mobile-banking number / transaction is mentioned — verify via the official helpline",
        "disclaimer": "This is an automated screen, not a final verdict — it can miss new scams.",
    },
}

VERDICT_LABEL = {
    "bn": {"scam": ("প্রতারণা", "⚠️"), "suspicious": ("সন্দেহজনক", "🟡"),
           "safe": ("সম্ভবত নিরাপদ", "✅")},
    "en": {"scam": ("Scam", "⚠️"), "suspicious": ("Suspicious", "🟡"),
           "safe": ("Likely safe", "✅")},
}


def check_message(text, lang="bn"):
    A = ADVICE.get(lang, ADVICE["bn"])
    labels = VERDICT_LABEL.get(lang, VERDICT_LABEL["bn"])
    t = (text or "").strip()
    low = t.lower()
    score = 0
    reasons = []

    for weight, _key, bn_r, en_r, pats in RULES:
        if any(re.search(p, low) for p in pats):
            score += weight
            reasons.append(bn_r if lang == "bn" else en_r)

    # link analysis
    urls = URL.findall(low)
    if urls:
        if LOOKALIKE.search(low):
            score += 50
            reasons.append(A["link_lookalike"])
        elif any(s in low for s in SHORTENERS) or "http://" in low or RISKY_TLD.search(low):
            score += 20
            reasons.append(A["link_bad"])
        else:
            score += 8
            reasons.append(A["link_plain"])

    # MFS + number combo intensifies
    if any(m in low for m in MFS) and re.search(r"\d{4,}", low):
        score += 10
        reasons.append(A["mfs"])

    score = min(100, score)
    if score >= 50:
        verdict = "scam"
    elif score >= 22:
        verdict = "suspicious"
    else:
        verdict = "safe"
    label, emoji = labels[verdict]

    advice = A[verdict]
    if not reasons:
        reasons = [A["no_reason"]]

    return {"score": score, "verdict": verdict, "label": label, "emoji": emoji,
            "reasons": reasons[:6], "advice": advice, "report": A["report"],
            "disclaimer": A["disclaimer"], "lang": lang}
