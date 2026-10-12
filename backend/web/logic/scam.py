"""W2 — scam / fraud message checker (rule-based, honest, Bangla)."""
import re

URL = re.compile(r"(https?://[^\s]+|\b[\w\-]+\.(?:com|net|xyz|top|info|link|ml|tk|ga)\b)", re.I)
SHORTENERS = ["bit.ly", "tinyurl", "cutt.ly", "t.me", "wa.me", "is.gd", "shorturl", "rb.gy"]
MFS = ["bkash", "বিকাশ", "nagad", "নগদ", "rocket", "রকেট", "upay", "উপায়"]

RULES = [
    # (weight, bangla_reason, patterns)
    (35, "PIN/OTP/পাসওয়ার্ড চাওয়া হয়েছে — কোনো আসল প্রতিষ্ঠান কখনো এগুলো চায় না",
     [r"\bpin\b", r"\botp\b", r"ও\s*টি\s*পি", r"পিন", r"পাসওয়ার্ড", r"password", r"ভেরিফিকেশন কোড", r"verification code"]),
    (30, "লটারি/পুরস্কার জেতার লোভ দেখানো হয়েছে",
     [r"লটারি", r"lottery", r"পুরস্কার", r"prize", r"জিতেছেন", r"বিজয়ী", r"winner", r"congratulation", r"অভিনন্দন.*জিত"]),
    (20, "দ্রুত/এখনই চাপ দেওয়া হচ্ছে (তাড়াহুড়ার কৌশল)",
     [r"এখনই", r"আজই", r"দ্রুত", r"তাড়াতাড়ি", r"urgent", r"immediately", r"within \d+ (hour|minute|min)", r"শেষ সুযোগ", r"account.*(block|suspend|বন্ধ)"]),
    (25, "টাকা পাঠাতে বলা হচ্ছে",
     [r"টাকা পাঠা", r"send money", r"ক্যাশ ইন", r"cash in", r"ফি দিন", r"fee", r"চার্জ দিন", r"পেমেন্ট করুন", r"\b\d{3,}\s*(টাকা|tk|taka)\b"]),
    (20, "সরকারি/কোম্পানির পরিচয়ে প্রতারণার চেষ্টা",
     [r"অফিস থেকে বলছি", r"official", r"হেড অফিস", r"customer care", r"কাস্টমার কেয়ার", r"helpline থেকে"]),
    (15, "সন্দেহজনক/শর্ট লিংক আছে — ক্লিক করবেন না", []),  # handled separately
]


def check_message(text):
    t = (text or "").strip()
    low = t.lower()
    score = 0
    reasons = []
    for weight, reason, pats in RULES[:-1]:
        if any(re.search(p, low) for p in pats):
            score += weight
            reasons.append(reason)
    # link rule
    urls = URL.findall(low)
    if urls:
        if any(s in low for s in SHORTENERS) or "http://" in low:
            score += 20
            reasons.append("সন্দেহজনক/শর্ট লিংক আছে — ক্লিক করবেন না")
        else:
            score += 8
            reasons.append("মেসেজে লিংক আছে — পাঠানো পরিচয় যাচাই না করে ক্লিক করবেন না")
    # mfs + money combo intensifies
    if any(m in low for m in MFS) and re.search(r"\d{4,}", low):
        score += 10
        reasons.append("মোবাইল ব্যাংকিং নম্বর/লেনদেন উল্লেখ আছে — যাচাই করুন")

    score = min(100, score)
    if score >= 60:
        verdict, label, emoji = "scam", "প্রতারণা", "⚠️"
    elif score >= 25:
        verdict, label, emoji = "suspicious", "সন্দেহজনক", "🟡"
    else:
        verdict, label, emoji = "safe", "সম্ভবত নিরাপদ", "✅"

    advice = {
        "scam": "এটা প্রতারণা হতে পারে। কোনো PIN/OTP/পাসওয়ার্ড দেবেন না, টাকা পাঠাবেন না, লিংকে ক্লিক করবেন না। "
                "পরিবারের বড়দের সাবধান করুন।",
        "suspicious": "সাবধান থাকুন। পরিচয় যাচাই না করে কোনো তথ্য বা টাকা দেবেন না।",
        "safe": "স্পষ্ট প্রতারণার লক্ষণ পাওয়া যায়নি। তবুও অচেনা উৎস হলে সতর্ক থাকুন।",
    }[verdict]

    if not reasons:
        reasons = ["স্পষ্ট প্রতারণার লক্ষণ পাওয়া যায়নি।"]
    return {"score": score, "verdict": verdict, "label": label, "emoji": emoji,
            "reasons": reasons[:5], "advice": advice}
