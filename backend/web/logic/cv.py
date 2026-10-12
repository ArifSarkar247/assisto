"""W1 — CV score (rule-based, honest). Optional AI enhancement when a key exists."""
import re

CONTACT_EMAIL = re.compile(r"[\w.\-]+@[\w\-]+\.\w+")
CONTACT_PHONE = re.compile(r"(?:\+?88)?01[3-9]\d{8}")
NUMBERS = re.compile(r"\b\d+(\.\d+)?%?\b")

SECTION_WORDS = {
    "education": ["education", "শিক্ষা", "educational", "degree", "bsc", "ssc", "hsc", "ডিগ্রি"],
    "experience": ["experience", "অভিজ্ঞতা", "work history", "employment", "চাকরি", "কর্ম"],
    "skills": ["skills", "দক্ষতা", "competenc", "proficien"],
    "summary": ["summary", "objective", "profile", "সারসংক্ষেপ", "লক্ষ্য", "career objective"],
}
ACTION_VERBS = ["led", "managed", "built", "created", "developed", "improved", "designed",
                "achieved", "increased", "reduced", "launched", "delivered", "organized",
                "পরিচালনা", "তৈরি", "উন্নত", "নেতৃত্ব", "বৃদ্ধি"]


def score_cv(text):
    t = (text or "").strip()
    low = t.lower()
    words = re.findall(r"\S+", t)
    wc = len(words)
    parts = []  # (label, got, max, tip_if_missing)

    # contact
    has_email = bool(CONTACT_EMAIL.search(t))
    has_phone = bool(CONTACT_PHONE.search(t))
    c = (10 if has_email else 0) + (10 if has_phone else 0)
    parts.append(("যোগাযোগ (ইমেইল+ফোন)", c, 20,
                  None if c == 20 else "ইমেইল আর ফোন নম্বর পরিষ্কারভাবে উপরে দিন।"))

    # length
    if wc < 120:
        ln, tip = 6, "CV খুব ছোট — অভিজ্ঞতা ও দক্ষতা আরও বিস্তারিত লিখুন (অন্তত ১৫০+ শব্দ)।"
    elif wc > 900:
        ln, tip = 10, "CV বেশি বড় — দরকারি অংশ রেখে ১-২ পাতায় নামিয়ে আনুন।"
    else:
        ln, tip = 15, None
    parts.append(("দৈর্ঘ্য", ln, 15, tip))

    # sections
    sec_got = 0
    missing = []
    for name, kws in SECTION_WORDS.items():
        if any(k in low for k in kws):
            sec_got += 1
        else:
            missing.append(name)
    sec_score = int(sec_got / len(SECTION_WORDS) * 25)
    bn = {"education": "শিক্ষা", "experience": "অভিজ্ঞতা", "skills": "দক্ষতা", "summary": "সারসংক্ষেপ"}
    parts.append(("গুরুত্বপূর্ণ সেকশন", sec_score, 25,
                  None if not missing else
                  "এই সেকশনগুলো যোগ করুন: " + ", ".join(bn[m] for m in missing) + "।"))

    # action verbs
    av = sum(1 for v in ACTION_VERBS if v in low)
    av_score = min(15, av * 3)
    parts.append(("অ্যাকশন শব্দ", av_score, 15,
                  None if av_score >= 9 else
                  "অর্জন বোঝাতে শক্তিশালী শব্দ ব্যবহার করুন (পরিচালনা করেছি, তৈরি করেছি, বৃদ্ধি করেছি)।"))

    # quantification
    nums = len(NUMBERS.findall(t))
    q_score = min(15, nums * 2)
    parts.append(("সংখ্যায় অর্জন", q_score, 15,
                  None if q_score >= 8 else
                  "অর্জন সংখ্যায় দেখান (যেমন: বিক্রি ৩০% বাড়িয়েছি, ১০ জনের টিম চালিয়েছি)।"))

    # formatting hygiene (bullets, consistent lines)
    bullets = t.count("•") + len(re.findall(r"^\s*[-*]\s", t, re.M))
    fmt = 10 if bullets >= 3 else (6 if bullets >= 1 else 3)
    parts.append(("ফরম্যাট (বুলেট পয়েন্ট)", fmt, 10,
                  None if fmt == 10 else "বুলেট পয়েন্ট দিয়ে পরিষ্কারভাবে সাজান।"))

    total = sum(p[1] for p in parts)
    total = max(0, min(100, total))
    tips = [p[3] for p in parts if p[3]]
    # always return 5 improvements; pad with generic good-practice if fewer
    extras = [
        "চাকরির বিজ্ঞাপনের কিওয়ার্ড CV-তে মিলিয়ে দিন (ATS স্ক্যানে সাহায্য করে)।",
        "বানান ও গ্রামার আরেকবার যাচাই করুন।",
        "সবচেয়ে প্রাসঙ্গিক অভিজ্ঞতা উপরে রাখুন।",
        "একটি ছোট প্রফেশনাল সারসংক্ষেপ দিয়ে শুরু করুন।",
        "রেফারেন্স/লিংকডইন লিংক যোগ করুন।",
    ]
    for e in extras:
        if len(tips) >= 5:
            break
        if e not in tips:
            tips.append(e)
    return {"score": total, "word_count": wc, "breakdown": parts, "tips": tips[:5]}
