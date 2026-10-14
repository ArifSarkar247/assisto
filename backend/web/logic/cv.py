"""W1 — CV score (rule-based, honest, bn/en). Optional AI enhancement when a key exists.

Advanced rubric (SPEC v2.1 §21, web-adapted):
  - Contact completeness (email + BD phone + optional LinkedIn)
  - Length sanity (too short / ideal / too long)
  - Key sections present (summary, experience, education, skills)
  - Action verbs (strong, achievement-oriented language)
  - Quantified achievements (numbers / %)
  - Formatting hygiene (bullets)
  - BD job-market relevance (in-demand keywords actually found)
  - Red flags (first-person "I", unprofessional email, dated terms, photo/age/marital
    status over-sharing) — each costs points and yields a concrete tip.

Scoring is rule-based and fully offline. Honest framing: this is GUIDANCE, not a
guarantee of getting a job. Output is localized (bn|en) so pages stay single-language.

AI SEAM: views.py calls core.ai only when a key exists; the rule-based result below
is always the baseline and is never blocked on a key.
"""
import re

CONTACT_EMAIL = re.compile(r"[\w.\-]+@[\w\-]+\.\w+")
CONTACT_PHONE = re.compile(r"(?:\+?88)?01[3-9]\d{8}")
LINKEDIN = re.compile(r"linkedin\.com/|github\.com/", re.I)
NUMBERS = re.compile(r"\b\d+(?:\.\d+)?%?\b")
UNPRO_EMAIL = re.compile(r"[\w.\-]*(cool|cute|sexy|babu|king|queen|hero|pagla|420|69)"
                         r"[\w.\-]*@", re.I)

SECTION_WORDS = {
    "summary": ["summary", "objective", "profile", "সারসংক্ষেপ", "লক্ষ্য", "career objective"],
    "experience": ["experience", "অভিজ্ঞতা", "work history", "employment", "চাকরি", "কর্ম"],
    "education": ["education", "শিক্ষা", "educational", "degree", "bsc", "ssc", "hsc", "ডিগ্রি"],
    "skills": ["skills", "দক্ষতা", "competenc", "proficien"],
}
ACTION_VERBS = ["led", "managed", "built", "created", "developed", "improved", "designed",
                "achieved", "increased", "reduced", "launched", "delivered", "organized",
                "implemented", "coordinated", "trained",
                "পরিচালনা", "তৈরি", "উন্নত", "নেতৃত্ব", "বৃদ্ধি", "বাস্তবায়ন"]

# BD job-market in-demand keywords (2025-era, general). Rule-based signal only.
BD_KEYWORDS = [
    "excel", "python", "sql", "digital marketing", "facebook ads", "seo", "graphic design",
    "accounts", "accounting", "tally", "garments", "merchandising", "supply chain",
    "customer service", "sales", "ielts", "communication", "ms office", "data entry",
    "php", "javascript", "react", "flutter", "android", "wordpress", "autocad",
    "nursing", "pharma", "agronomy", "project management", "bkash", "erp",
]

# Red flags: (pattern, bn_tip, en_tip, penalty)
RED_FLAGS = [
    (re.compile(r"\bi\s+(am|have|was|did|worked|led)\b", re.I),
     "প্রথম পুরুষে (\"I am…\") না লিখে অ্যাকশন শব্দ দিয়ে শুরু করুন (যেমন: \"Managed…\")।",
     "Avoid first-person (\"I am…\"); start bullets with action verbs (e.g. \"Managed…\").", 4),
    (UNPRO_EMAIL,
     "ইমেইল ঠিকানাটি অপেশাদার মনে হচ্ছে — নাম-ভিত্তিক পেশাদার ইমেইল ব্যবহার করুন।",
     "Your email looks unprofessional — use a name-based professional address.", 5),
    (re.compile(r"(marital status|বৈবাহিক|religion|ধর্ম|date of birth|জন্ম তারিখ|father'?s name|পিতার নাম)", re.I),
     "ব্যক্তিগত তথ্য (ধর্ম/বৈবাহিক অবস্থা/জন্মতারিখ) বাদ দিন — নিয়োগদাতার দরকার নেই।",
     "Drop personal details (religion / marital status / DOB) — recruiters don't need them.", 3),
    (re.compile(r"(references available on request|রেফারেন্স.*অনুরোধ)", re.I),
     "\"References available on request\" লাইনটি জায়গা নষ্ট করে — বাদ দিন।",
     "\"References available on request\" wastes space — remove it.", 2),
]

LABELS = {
    "bn": {
        "contact": "যোগাযোগ (ইমেইল+ফোন)",
        "length": "দৈর্ঘ্য",
        "sections": "গুরুত্বপূর্ণ সেকশন",
        "verbs": "অ্যাকশন শব্দ",
        "quant": "সংখ্যায় অর্জন",
        "format": "ফরম্যাট (বুলেট পয়েন্ট)",
        "bdkw": "চাকরি-বাজার কিওয়ার্ড",
        "sec_names": {"summary": "সারসংক্ষেপ", "experience": "অভিজ্ঞতা",
                      "education": "শিক্ষা", "skills": "দক্ষতা"},
        "tip_contact": "ইমেইল আর ফোন নম্বর পরিষ্কারভাবে উপরে দিন।",
        "tip_contact_linkedin": "LinkedIn/GitHub লিংক যোগ করলে আরও ভালো।",
        "tip_short": "CV খুব ছোট — অভিজ্ঞতা ও দক্ষতা আরও বিস্তারিত লিখুন (অন্তত ১৫০+ শব্দ)।",
        "tip_long": "CV বেশি বড় — দরকারি অংশ রেখে ১-২ পাতায় নামিয়ে আনুন।",
        "tip_sections": "এই সেকশনগুলো যোগ করুন: {}।",
        "tip_verbs": "অর্জন বোঝাতে শক্তিশালী শব্দ ব্যবহার করুন (পরিচালনা করেছি, তৈরি করেছি, বৃদ্ধি করেছি)।",
        "tip_quant": "অর্জন সংখ্যায় দেখান (যেমন: বিক্রি ৩০% বাড়িয়েছি, ১০ জনের টিম চালিয়েছি)।",
        "tip_format": "বুলেট পয়েন্ট দিয়ে পরিষ্কারভাবে সাজান।",
        "tip_bdkw": "চাকরির বিজ্ঞাপনের প্রাসঙ্গিক দক্ষতা/কিওয়ার্ড যোগ করুন (Excel, SQL, Digital Marketing ইত্যাদি)।",
        "extras": [
            "চাকরির বিজ্ঞাপনের কিওয়ার্ড CV-তে মিলিয়ে দিন (ATS স্ক্যানে সাহায্য করে)।",
            "বানান ও গ্রামার আরেকবার যাচাই করুন।",
            "সবচেয়ে প্রাসঙ্গিক অভিজ্ঞতা উপরে রাখুন।",
            "একটি ছোট প্রফেশনাল সারসংক্ষেপ দিয়ে শুরু করুন।",
            "প্রতিটি কাজের ফলাফল এক লাইনে পরিষ্কার করে লিখুন।",
        ],
    },
    "en": {
        "contact": "Contact (email + phone)",
        "length": "Length",
        "sections": "Key sections",
        "verbs": "Action verbs",
        "quant": "Quantified achievements",
        "format": "Formatting (bullets)",
        "bdkw": "Job-market keywords",
        "sec_names": {"summary": "Summary", "experience": "Experience",
                      "education": "Education", "skills": "Skills"},
        "tip_contact": "Put a clear email and phone number at the top.",
        "tip_contact_linkedin": "Add a LinkedIn / GitHub link for extra credibility.",
        "tip_short": "CV is very short — expand experience and skills (aim for 150+ words).",
        "tip_long": "CV is too long — trim to 1–2 pages, keep only what matters.",
        "tip_sections": "Add these sections: {}.",
        "tip_verbs": "Use strong achievement verbs (managed, built, increased).",
        "tip_quant": "Show results with numbers (e.g. grew sales 30%, led a team of 10).",
        "tip_format": "Use bullet points for a clean, scannable layout.",
        "tip_bdkw": "Add relevant in-demand skills/keywords (Excel, SQL, Digital Marketing, etc.).",
        "extras": [
            "Mirror keywords from the job ad (helps with ATS scanning).",
            "Proofread for spelling and grammar.",
            "Put your most relevant experience first.",
            "Open with a short professional summary.",
            "State the result of each job in one clear line.",
        ],
    },
}


def score_cv(text, lang="bn"):
    L = LABELS.get(lang, LABELS["bn"])
    sn = L["sec_names"]
    t = (text or "").strip()
    low = t.lower()
    words = re.findall(r"\S+", t)
    wc = len(words)
    parts = []  # (label, got, max, tip_if_missing)

    # contact (email + phone + linkedin bonus)
    has_email = bool(CONTACT_EMAIL.search(t))
    has_phone = bool(CONTACT_PHONE.search(t))
    has_link = bool(LINKEDIN.search(t))
    c = (8 if has_email else 0) + (8 if has_phone else 0) + (4 if has_link else 0)
    if c >= 16:
        c_tip = None
    elif has_email and has_phone:
        c_tip = L["tip_contact_linkedin"]
    else:
        c_tip = L["tip_contact"]
    parts.append((L["contact"], c, 20, c_tip))

    # length
    if wc < 120:
        ln, tip = 6, L["tip_short"]
    elif wc > 900:
        ln, tip = 10, L["tip_long"]
    else:
        ln, tip = 15, None
    parts.append((L["length"], ln, 15, tip))

    # sections
    sec_got, missing = 0, []
    for name, kws in SECTION_WORDS.items():
        if any(k in low for k in kws):
            sec_got += 1
        else:
            missing.append(name)
    sec_score = int(sec_got / len(SECTION_WORDS) * 20)
    parts.append((L["sections"], sec_score, 20,
                  None if not missing else
                  L["tip_sections"].format(", ".join(sn[m] for m in missing))))

    # action verbs
    av = sum(1 for v in ACTION_VERBS if v in low)
    av_score = min(12, av * 3)
    parts.append((L["verbs"], av_score, 12, None if av_score >= 9 else L["tip_verbs"]))

    # quantification
    nums = len(NUMBERS.findall(t))
    q_score = min(13, nums * 2)
    parts.append((L["quant"], q_score, 13, None if q_score >= 8 else L["tip_quant"]))

    # formatting hygiene (bullets)
    bullets = t.count("•") + len(re.findall(r"^\s*[-*]\s", t, re.M))
    fmt = 10 if bullets >= 3 else (6 if bullets >= 1 else 3)
    parts.append((L["format"], fmt, 10, None if fmt == 10 else L["tip_format"]))

    # BD job-market keyword relevance
    kw_hits = sorted({k for k in BD_KEYWORDS if k in low})
    kw_score = min(10, len(kw_hits) * 3)
    parts.append((L["bdkw"], kw_score, 10, None if kw_score >= 6 else L["tip_bdkw"]))

    total = sum(p[1] for p in parts)

    # red flags (penalties + tips)
    red_flags = []
    penalty = 0
    for pat, bn_tip, en_tip, pen in RED_FLAGS:
        if pat.search(t):
            red_flags.append(bn_tip if lang == "bn" else en_tip)
            penalty += pen
    total = max(0, min(100, total - penalty))

    tips = [p[3] for p in parts if p[3]]
    tips = red_flags + tips  # surface red-flag fixes first (highest impact)
    for e in L["extras"]:
        if len(tips) >= 5:
            break
        if e not in tips:
            tips.append(e)

    return {"score": total, "word_count": wc, "breakdown": parts,
            "tips": tips[:5], "red_flags": red_flags,
            "keywords_found": kw_hits, "penalty": penalty, "lang": lang}
