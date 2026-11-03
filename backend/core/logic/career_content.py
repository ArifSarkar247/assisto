"""career_content.py — pure, stdlib-only content + rules behind the p2career
work (CV Builder formats, the ATS check, the role-based mock-interview bank
and its key-free rubric). No Django, no DB, no network, no AI.

Everything here is Assisto's OWN authored text (no scraped or licensed
question banks). Flag: career_plus (OFF until proven).
"""
import re

# ===================================================================== CV
CV_FORMATS = ("fresher", "experienced", "govt")
CV_LANGS = ("en", "bn")

# Section headings per CV language. ATS parsers look for these plain words,
# so the English set uses the most common standard headings.
HEADINGS = {
    "en": {"objective": "Career Objective", "summary": "Professional Summary",
           "experience": "Work Experience", "education": "Education",
           "skills": "Skills", "personal": "Personal Information",
           "declaration": "Declaration", "contact": "Contact"},
    "bn": {"objective": "ক্যারিয়ার উদ্দেশ্য", "summary": "পেশাগত সারাংশ",
           "experience": "কাজের অভিজ্ঞতা", "education": "শিক্ষাগত যোগ্যতা",
           "skills": "দক্ষতা", "personal": "ব্যক্তিগত তথ্য",
           "declaration": "প্রত্যয়ন", "contact": "যোগাযোগ"},
}

PERSONAL_FIELDS = ("father", "mother", "dob", "nationality", "religion",
                   "permanent_address")
PERSONAL_LABELS = {
    "en": {"father": "Father's name", "mother": "Mother's name",
           "dob": "Date of birth", "nationality": "Nationality",
           "religion": "Religion", "permanent_address": "Permanent address"},
    "bn": {"father": "পিতার নাম", "mother": "মাতার নাম", "dob": "জন্ম তারিখ",
           "nationality": "জাতীয়তা", "religion": "ধর্ম",
           "permanent_address": "স্থায়ী ঠিকানা"},
}

DECLARATION = {
    "en": "I hereby declare that the information given above is true and "
          "correct to the best of my knowledge.",
    "bn": "আমি এই মর্মে প্রত্যয়ন করছি যে, উপরে প্রদত্ত সকল তথ্য আমার জানামতে "
          "সত্য ও সঠিক।",
}


def _s(v, limit=600):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:limit]


def _bullets(v):
    if isinstance(v, list):
        items = [str(x) for x in v]
    else:
        items = str(v or "").splitlines()
    out = []
    for line in items:
        line = _s(line.lstrip("-•*· \t"), 300)
        if line:
            out.append(line)
    return out[:12]


def normalize_cv(row):
    """The stored `cv` row -> a clean dict (all strings, bounded sizes)."""
    row = row if isinstance(row, dict) else {}
    personal = row.get("personal") if isinstance(row.get("personal"), dict) else {}
    edu = [e for e in (row.get("education") or []) if isinstance(e, dict)][:12]
    exp = [e for e in (row.get("experience") or []) if isinstance(e, dict)][:15]
    fmt = row.get("format") if row.get("format") in CV_FORMATS else "fresher"
    return {
        "name": _s(row.get("name"), 120), "headline": _s(row.get("headline"), 160),
        "phone": _s(row.get("phone"), 40), "email": _s(row.get("email"), 120),
        "location": _s(row.get("location"), 200),
        "summary": _s(row.get("summary"), 900),
        "format": fmt,
        "education": [{"degree": _s(e.get("degree"), 160),
                       "institution": _s(e.get("institution"), 160),
                       "year": _s(e.get("year"), 40),
                       "result": _s(e.get("result"), 40)} for e in edu],
        "experience": [{"title": _s(e.get("title"), 160), "org": _s(e.get("org"), 160),
                        "dates": _s(e.get("dates"), 60),
                        "bullets": _bullets(e.get("bullets"))} for e in exp],
        "skills": [_s(x, 60) for x in (row.get("skills") or []) if _s(x, 60)][:40],
        "personal": {k: _s(personal.get(k), 200) for k in PERSONAL_FIELDS},
    }


def section_order(fmt):
    """Which sections, in which order, for each BD CV format."""
    if fmt == "experienced":
        return ["summary", "experience", "skills", "education"]
    if fmt == "govt":
        return ["objective", "education", "experience", "skills", "personal",
                "declaration"]
    return ["objective", "education", "skills", "experience"]  # fresher


def cv_blocks(cv, lang="en"):
    """A normalized CV -> ordered render blocks [{kind, heading, lines}].
    Shared by the PDF and the print page so both say exactly the same."""
    lang = lang if lang in CV_LANGS else "en"
    H = HEADINGS[lang]
    out = []
    for sec in section_order(cv["format"]):
        if sec in ("objective", "summary"):
            if cv["summary"]:
                out.append({"kind": "para", "heading": H[sec], "lines": [cv["summary"]]})
        elif sec == "experience":
            items = []
            for e in cv["experience"]:
                head = " — ".join(x for x in (e["title"], e["org"]) if x)
                if e["dates"]:
                    head = (head + " (" + e["dates"] + ")") if head else e["dates"]
                if head or e["bullets"]:
                    items.append({"head": head, "bullets": e["bullets"]})
            if items:
                out.append({"kind": "items", "heading": H[sec], "items": items})
        elif sec == "education":
            lines = []
            for e in cv["education"]:
                bits = [x for x in (e["degree"], e["institution"]) if x]
                line = ", ".join(bits)
                tail = [x for x in (e["result"], e["year"]) if x]
                if tail:
                    line = (line + " — " if line else "") + ", ".join(tail)
                if line:
                    lines.append(line)
            if lines:
                out.append({"kind": "list", "heading": H[sec], "lines": lines})
        elif sec == "skills":
            if cv["skills"]:
                out.append({"kind": "para", "heading": H[sec],
                            "lines": [", ".join(cv["skills"])]})
        elif sec == "personal":
            L = PERSONAL_LABELS[lang]
            lines = ["%s: %s" % (L[k], cv["personal"][k]) for k in PERSONAL_FIELDS
                     if cv["personal"].get(k)]
            if lines:
                out.append({"kind": "list", "heading": H[sec], "lines": lines})
        elif sec == "declaration":
            out.append({"kind": "declaration", "heading": H[sec],
                        "lines": [DECLARATION[lang]]})
    return out


def contact_line(cv):
    return " | ".join(x for x in (cv["phone"], cv["email"], cv["location"]) if x)


_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[a-z]{2,}", re.I)
_DIGIT = re.compile(r"[0-9০-৯]")


def ats_check(cv):
    """Rule-based ATS checklist (key-free). -> {score, checks:[{id, ok}]}.
    The app owns the bn/en wording for each check id."""
    exp_bullets = [b for e in cv["experience"] for b in e["bullets"]]
    checks = [
        ("name", bool(cv["name"])),
        ("phone", len(re.sub(r"\D", "", cv["phone"].translate(_BN2EN))) >= 10),
        ("email", bool(_EMAIL.fullmatch(cv["email"] or ""))),
        ("summary", len(cv["summary"].split()) >= 12),
        ("education", bool(cv["education"])),
        ("skills", len(cv["skills"]) >= 5),
        # experienced / govt CVs need work history; a fresher may skip it
        ("experience", bool(cv["experience"]) or cv["format"] == "fresher"),
        ("numbers", (not exp_bullets) or any(_DIGIT.search(b) for b in exp_bullets)),
        ("length", sum(len(b.split()) for b in exp_bullets) <= 450),
    ]
    ok = sum(1 for _, v in checks if v)
    return {"score": round(100 * ok / len(checks)),
            "checks": [{"id": i, "ok": v} for i, v in checks]}


_BN2EN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


# ============================================================ INTERVIEW
# Role-based question sets. Each question: id, bn, en, keys (topic words in
# both languages; the rubric checks how many the answer touches), outline
# (a model-answer STRUCTURE — never a script to memorise).
def _q(qid, bn, en, keys, outline_bn, outline_en):
    return {"id": qid, "bn": bn, "en": en, "keys": keys,
            "outline": {"bn": outline_bn, "en": outline_en}}


_INTRO_OUT_BN = "বর্তমান অবস্থা → প্রাসঙ্গিক পড়াশোনা/অভিজ্ঞতা → একটা অর্জন → কেন এই পদ"
_INTRO_OUT_EN = "Present → relevant study/experience → one achievement → why this role"
_STAR_BN = "পরিস্থিতি → দায়িত্ব → আপনি কী করলেন → ফল (সংখ্যায়)"
_STAR_EN = "Situation → Task → Action you took → Result (with a number)"

ROLES = [
    {"id": "fresher", "bn": "ফ্রেশার (প্রথম চাকরি)", "en": "Fresher (first job)", "qs": [
        _q("fr1", "নিজের সম্পর্কে বলুন।", "Tell me about yourself.",
           ["study", "university", "project", "skill", "goal", "পড়াশোনা", "বিশ্ববিদ্যালয়", "প্রজেক্ট", "দক্ষতা", "লক্ষ্য"],
           _INTRO_OUT_BN, _INTRO_OUT_EN),
        _q("fr2", "অভিজ্ঞতা নেই — আপনাকে কেন নেব?", "You have no experience — why should we hire you?",
           ["learn", "internship", "project", "team", "quick", "শিখ", "ইন্টার্নশিপ", "প্রজেক্ট", "দল", "দ্রুত"],
           "শেখার প্রমাণ (প্রজেক্ট/ইন্টার্নশিপ) → এই কাজে লাগবে এমন দক্ষতা → প্রথম ৩ মাসে কী দেবেন",
           "Proof you learn fast (project/internship) → skills that fit this job → what you deliver in 3 months"),
        _q("fr3", "আপনার সবচেয়ে বড় দুর্বলতা কী?", "What is your greatest weakness?",
           ["improve", "working on", "course", "practice", "উন্নতি", "চেষ্টা", "কোর্স", "অনুশীলন"],
           "একটা আসল কিন্তু ছোট দুর্বলতা → কীভাবে ঠিক করছেন → এখন পর্যন্ত উন্নতি",
           "A real but small weakness → how you are fixing it → progress so far"),
        _q("fr4", "৫ বছর পরে নিজেকে কোথায় দেখতে চান?", "Where do you see yourself in five years?",
           ["grow", "responsibility", "skill", "company", "lead", "দায়িত্ব", "দক্ষতা", "প্রতিষ্ঠান", "নেতৃত্ব", "বড়"],
           "এই পদে দক্ষ হওয়া → বড় দায়িত্ব → প্রতিষ্ঠানের সাথে বেড়ে ওঠা", "Master this role → bigger responsibility → grow with the company"),
        _q("fr5", "দলে কাজ করার একটা অভিজ্ঞতা বলুন।", "Describe a time you worked in a team.",
           ["team", "role", "deadline", "result", "conflict", "দল", "ভূমিকা", "সময়", "ফল", "মতভেদ"],
           _STAR_BN, _STAR_EN),
        _q("fr6", "আপনার কি কোনো প্রশ্ন আছে?", "Do you have any questions for us?",
           ["training", "team", "expect", "growth", "first", "প্রশিক্ষণ", "দল", "প্রত্যাশা", "উন্নতি", "প্রথম"],
           "প্রশিক্ষণ, প্রথম ৩ মাসের প্রত্যাশা, দলের গঠন নিয়ে ১–২টি প্রশ্ন",
           "1–2 questions on training, first-3-month expectations, team structure"),
    ]},
    {"id": "bank", "bn": "ব্যাংক অফিসার", "en": "Bank officer", "qs": [
        _q("bk1", "ব্যাংকে কেন চাকরি করতে চান?", "Why do you want to work in a bank?",
           ["customer", "finance", "career", "trust", "service", "গ্রাহক", "আর্থিক", "ক্যারিয়ার", "আস্থা", "সেবা"],
           _INTRO_OUT_BN, _INTRO_OUT_EN),
        _q("bk2", "KYC কী এবং কেন দরকার?", "What is KYC and why does it matter?",
           ["identity", "customer", "money laundering", "risk", "nid", "পরিচয়", "গ্রাহক", "মানি লন্ডারিং", "ঝুঁকি", "এনআইডি"],
           "সংজ্ঞা → কী কী কাগজ → মানি লন্ডারিং/প্রতারণা রোধ → ঝুঁকি-ভিত্তিক পর্যালোচনা",
           "Definition → which documents → stops laundering/fraud → risk-based review"),
        _q("bk3", "একজন রাগী গ্রাহককে কীভাবে সামলাবেন?", "How would you handle an angry customer?",
           ["listen", "calm", "solution", "apolog", "follow", "শুন", "শান্ত", "সমাধান", "দুঃখ", "ফলো"],
           "মন দিয়ে শোনা → সহানুভূতি → সমাধান/সময়সীমা → পরে খোঁজ নেওয়া",
           "Listen → empathise → solution with a timeline → follow up"),
        _q("bk4", "CRR আর SLR-এর পার্থক্য বলুন।", "Explain the difference between CRR and SLR.",
           ["cash", "reserve", "liquidity", "central bank", "deposit", "নগদ", "সংরক্ষণ", "তারল্য", "কেন্দ্রীয় ব্যাংক", "আমানত"],
           "CRR = কেন্দ্রীয় ব্যাংকে নগদ রাখা → SLR = নিজের কাছে তরল সম্পদ → উদ্দেশ্য: তারল্য ও মুদ্রানীতি",
           "CRR = cash kept with the central bank → SLR = liquid assets held by the bank → purpose: liquidity + monetary policy"),
        _q("bk5", "টার্গেটের চাপ কীভাবে সামলান?", "How do you handle sales targets and pressure?",
           ["plan", "target", "daily", "priorit", "result", "পরিকল্পনা", "টার্গেট", "প্রতিদিন", "অগ্রাধিকার", "ফল"],
           _STAR_BN, _STAR_EN),
        _q("bk6", "একজন সহকর্মী নিয়ম ভাঙছে দেখলে কী করবেন?", "What would you do if a colleague broke a compliance rule?",
           ["report", "policy", "manager", "integrity", "compliance", "জানা", "নীতি", "ম্যানেজার", "সততা", "কমপ্লায়েন্স"],
           "নীতি মনে করিয়ে দেওয়া → নিয়ম অনুযায়ী ঊর্ধ্বতনকে জানানো → সততার গুরুত্ব",
           "Remind of the policy → report through the proper channel → why integrity matters"),
    ]},
    {"id": "sales", "bn": "সেলস / মার্কেটিং", "en": "Sales / marketing", "qs": [
        _q("sl1", "এই কলমটা আমার কাছে বিক্রি করুন।", "Sell me this pen.",
           ["need", "question", "benefit", "price", "close", "প্রয়োজন", "প্রশ্ন", "সুবিধা", "দাম", "রাজি"],
           "প্রশ্ন করে প্রয়োজন বোঝা → সুবিধা মেলানো → আপত্তির উত্তর → বিক্রি চূড়ান্ত",
           "Ask questions to find the need → match benefits → handle objection → close"),
        _q("sl2", "আপনার সেরা বিক্রির গল্প বলুন।", "Tell me about your best sale.",
           ["customer", "target", "percent", "result", "relationship", "গ্রাহক", "টার্গেট", "শতাংশ", "ফল", "সম্পর্ক"],
           _STAR_BN, _STAR_EN),
        _q("sl3", "\"না\" শুনলে কী করেন?", "How do you handle rejection?",
           ["learn", "follow", "reason", "next", "positive", "শিখ", "আবার", "কারণ", "পরের", "ইতিবাচক"],
           "কারণ জানা → শেখা → ভদ্রভাবে পরে যোগাযোগ → পরের গ্রাহকে মনোযোগ",
           "Find the reason → learn → polite follow-up later → move to the next lead"),
        _q("sl4", "নতুন এলাকায় বাজার কীভাবে ধরবেন?", "How would you open a new market area?",
           ["research", "dealer", "competitor", "plan", "visit", "গবেষণা", "ডিলার", "প্রতিযোগী", "পরিকল্পনা", "ভিজিট"],
           "বাজার যাচাই → প্রতিযোগী দেখা → ডিলার/রিটেইলার তালিকা → সাপ্তাহিক ভিজিট পরিকল্পনা → মাপা",
           "Research → competitors → dealer/retailer list → weekly visit plan → measure"),
        _q("sl5", "ডিজিটাল মার্কেটিং-এ কোন মেট্রিক দেখেন?", "Which metrics do you track in digital marketing?",
           ["reach", "conversion", "cost", "roi", "click", "রিচ", "কনভার্সন", "খরচ", "লাভ", "ক্লিক"],
           "লক্ষ্য → রিচ/ক্লিক → কনভার্সন → প্রতি বিক্রির খরচ → ROI", "Goal → reach/clicks → conversion → cost per sale → ROI"),
        _q("sl6", "মাসের টার্গেট পিছিয়ে থাকলে কী করবেন?", "You are behind on the monthly target — what do you do?",
           ["plan", "lead", "priorit", "manager", "daily", "পরিকল্পনা", "গ্রাহক", "অগ্রাধিকার", "ম্যানেজার", "প্রতিদিন"],
           "ফাঁক মাপা → সেরা সম্ভাবনার গ্রাহক আগে → দৈনিক লক্ষ্য → ম্যানেজারকে আগেই জানানো",
           "Size the gap → best leads first → daily goals → tell the manager early"),
    ]},
    {"id": "it", "bn": "আইটি / সফটওয়্যার", "en": "IT / software", "qs": [
        _q("it1", "আপনার একটা প্রজেক্ট বুঝিয়ে বলুন।", "Walk me through a project you built.",
           ["problem", "stack", "database", "challenge", "result", "সমস্যা", "টেকনোলজি", "ডাটাবেস", "চ্যালেঞ্জ", "ফল"],
           "সমস্যা → আপনার ভূমিকা → টেকনোলজি → সবচেয়ে কঠিন অংশ → ফল/ব্যবহারকারী",
           "Problem → your role → stack → hardest part → result/users"),
        _q("it2", "একটা বাগ খুঁজে বের করার ধাপ বলুন।", "How do you debug a production bug?",
           ["reproduce", "log", "test", "root cause", "fix", "পুনরায়", "লগ", "টেস্ট", "মূল কারণ", "ঠিক"],
           "পুনরায় ঘটানো → লগ/মেট্রিক → মূল কারণ → ঠিক + টেস্ট → আবার না হয় তার ব্যবস্থা",
           "Reproduce → logs/metrics → root cause → fix + test → prevent recurrence"),
        _q("it3", "SQL আর NoSQL কখন কোনটা?", "When would you choose SQL vs NoSQL?",
           ["relation", "schema", "scale", "transaction", "document", "সম্পর্ক", "স্কিমা", "স্কেল", "ট্রানজেকশন", "ডকুমেন্ট"],
           "ডেটার গঠন → ট্রানজেকশনের দরকার → স্কেল → উদাহরণ", "Data shape → transaction needs → scale → an example"),
        _q("it4", "কোড রিভিউতে কী দেখেন?", "What do you look for in a code review?",
           ["readab", "test", "security", "performance", "naming", "পড়া", "টেস্ট", "নিরাপত্তা", "গতি", "নাম"],
           "ঠিক কাজ করে কিনা → টেস্ট → নিরাপত্তা → পড়তে সহজ → গতি", "Correctness → tests → security → readability → performance"),
        _q("it5", "ডেডলাইনে কাজ শেষ না হলে কী করেন?", "What do you do when you will miss a deadline?",
           ["communicat", "early", "scope", "priorit", "team", "জানা", "আগে", "পরিধি", "অগ্রাধিকার", "দল"],
           "আগেই জানানো → কী ছাড়া যায় ঠিক করা → নতুন সময় → শেখা", "Tell early → cut scope → new date → lesson learned"),
        _q("it6", "নতুন টেকনোলজি কীভাবে শেখেন?", "How do you learn a new technology?",
           ["documentation", "project", "practice", "course", "community", "ডকুমেন্টেশন", "প্রজেক্ট", "অনুশীলন", "কোর্স", "কমিউনিটি"],
           "অফিশিয়াল ডক → ছোট প্রজেক্ট → ভুল থেকে শেখা → উদাহরণ", "Official docs → small project → learn from mistakes → example"),
    ]},
    {"id": "teacher", "bn": "শিক্ষক", "en": "Teacher", "qs": [
        _q("tc1", "কেন শিক্ষকতা করতে চান?", "Why do you want to teach?",
           ["student", "learn", "inspire", "subject", "future", "শিক্ষার্থী", "শেখা", "অনুপ্রাণিত", "বিষয়", "ভবিষ্যৎ"],
           _INTRO_OUT_BN, _INTRO_OUT_EN),
        _q("tc2", "দুর্বল শিক্ষার্থীকে কীভাবে সাহায্য করবেন?", "How do you help a weak student?",
           ["individual", "practice", "parent", "patience", "progress", "আলাদা", "অনুশীলন", "অভিভাবক", "ধৈর্য", "উন্নতি"],
           "কোথায় দুর্বল খোঁজা → আলাদা সময়/অনুশীলন → অভিভাবকের সাথে কথা → উন্নতি মাপা",
           "Find the gap → extra practice → talk to parents → track progress"),
        _q("tc3", "ক্লাসে শৃঙ্খলা কীভাবে রাখবেন?", "How do you manage classroom discipline?",
           ["rule", "respect", "engage", "consistent", "positive", "নিয়ম", "সম্মান", "অংশগ্রহণ", "নিয়মিত", "ইতিবাচক"],
           "শুরুতেই নিয়ম → সবার অংশগ্রহণ → ধারাবাহিকতা → ইতিবাচক উৎসাহ",
           "Rules on day one → engagement → consistency → positive reinforcement"),
        _q("tc4", "একটা কঠিন বিষয় সহজে কীভাবে পড়াবেন?", "How would you teach a difficult topic simply?",
           ["example", "daily life", "step", "question", "visual", "উদাহরণ", "দৈনন্দিন", "ধাপ", "প্রশ্ন", "ছবি"],
           "দৈনন্দিন উদাহরণ → ধাপে ধাপে → ছবি/চার্ট → প্রশ্ন করে যাচাই", "Everyday example → step by step → visuals → check with questions"),
        _q("tc5", "সৃজনশীল প্রশ্ন কীভাবে তৈরি করেন?", "How do you prepare creative (srijonshil) questions?",
           ["knowledge", "comprehension", "application", "higher", "stem", "জ্ঞান", "অনুধাবন", "প্রয়োগ", "উচ্চতর", "উদ্দীপক"],
           "উদ্দীপক → জ্ঞান → অনুধাবন → প্রয়োগ → উচ্চতর দক্ষতা", "Stimulus → knowledge → comprehension → application → higher order"),
        _q("tc6", "অভিভাবক অভিযোগ করলে কী করবেন?", "What do you do when a parent complains?",
           ["listen", "meet", "fact", "solution", "respect", "শুন", "দেখা", "তথ্য", "সমাধান", "সম্মান"],
           "শান্তভাবে শোনা → তথ্য যাচাই → সমাধান প্রস্তাব → পরে জানানো", "Listen calmly → check facts → propose a fix → follow up"),
    ]},
    {"id": "ngo", "bn": "এনজিও প্রোগ্রাম", "en": "NGO programme", "qs": [
        _q("ng1", "এই প্রতিষ্ঠানে কেন কাজ করতে চান?", "Why do you want to work with our organisation?",
           ["mission", "community", "impact", "experience", "value", "লক্ষ্য", "কমিউনিটি", "প্রভাব", "অভিজ্ঞতা", "মূল্যবোধ"],
           _INTRO_OUT_BN, _INTRO_OUT_EN),
        _q("ng2", "মাঠ পর্যায়ে কোনো সমস্যা সমাধানের গল্প বলুন।", "Tell me about solving a problem in the field.",
           ["community", "beneficiar", "plan", "result", "stakeholder", "কমিউনিটি", "উপকারভোগী", "পরিকল্পনা", "ফল", "অংশীজন"],
           _STAR_BN, _STAR_EN),
        _q("ng3", "মনিটরিং ও মূল্যায়ন (M&E) কীভাবে করেন?", "How do you do monitoring and evaluation?",
           ["indicator", "baseline", "data", "report", "target", "সূচক", "বেসলাইন", "তথ্য", "রিপোর্ট", "লক্ষ্য"],
           "সূচক ঠিক করা → বেসলাইন → নিয়মিত তথ্য → বিশ্লেষণ → রিপোর্ট", "Indicators → baseline → regular data → analysis → report"),
        _q("ng4", "দাতা সংস্থার রিপোর্ট দেরি হলে কী করবেন?", "A donor report is late — what do you do?",
           ["communicat", "donor", "priorit", "team", "deadline", "জানা", "দাতা", "অগ্রাধিকার", "দল", "সময়"],
           "আগেই দাতাকে জানানো → কাজ ভাগ → নতুন সময় → ভবিষ্যতে পরিকল্পনা", "Tell the donor early → split work → new date → plan ahead"),
        _q("ng5", "সুরক্ষা (safeguarding) বলতে কী বোঝেন?", "What does safeguarding mean to you?",
           ["protect", "child", "report", "policy", "abuse", "সুরক্ষা", "শিশু", "জানানো", "নীতি", "নির্যাতন"],
           "সংজ্ঞা → ঝুঁকিপূর্ণ মানুষ → আচরণবিধি → অভিযোগ জানানোর পথ", "Definition → vulnerable people → code of conduct → reporting path"),
        _q("ng6", "কমিউনিটির আস্থা কীভাবে অর্জন করেন?", "How do you build community trust?",
           ["listen", "local", "transparen", "respect", "leader", "শোনা", "স্থানীয়", "স্বচ্ছ", "সম্মান", "নেতা"],
           "স্থানীয় নেতাদের সাথে কথা → শোনা → স্বচ্ছতা → কথা রাখা", "Meet local leaders → listen → be transparent → keep promises"),
    ]},
    {"id": "garments", "bn": "গার্মেন্টস মার্চেন্ডাইজার", "en": "Garments merchandiser", "qs": [
        _q("gm1", "মার্চেন্ডাইজারের মূল কাজ কী?", "What are a merchandiser's main duties?",
           ["buyer", "costing", "sample", "shipment", "production", "বায়ার", "কস্টিং", "স্যাম্পল", "শিপমেন্ট", "প্রোডাকশন"],
           "বায়ারের সাথে যোগাযোগ → কস্টিং → স্যাম্পল → প্রোডাকশন ফলো → সময়মতো শিপমেন্ট",
           "Buyer communication → costing → samples → production follow-up → on-time shipment"),
        _q("gm2", "একটা টি-শার্টের কস্টিং কীভাবে করবেন?", "How would you cost a basic T-shirt?",
           ["fabric", "consumption", "cm", "trims", "profit", "ফেব্রিক", "কনজাম্পশন", "সিএম", "ট্রিমস", "লাভ"],
           "ফেব্রিক কনজাম্পশন → ফেব্রিক দাম → ট্রিমস → CM → ওভারহেড + লাভ", "Fabric consumption → fabric price → trims → CM → overhead + profit"),
        _q("gm3", "শিপমেন্ট দেরি হওয়ার ঝুঁকি দেখলে কী করবেন?", "You see a shipment delay risk — what do you do?",
           ["buyer", "production", "plan", "overtime", "communicat", "বায়ার", "প্রোডাকশন", "পরিকল্পনা", "ওভারটাইম", "জানা"],
           "কারণ খোঁজা → প্রোডাকশন পরিকল্পনা বদল → বায়ারকে আগেই জানানো → বিকল্প (এয়ার/আংশিক)",
           "Find the cause → re-plan production → inform the buyer early → options (air/partial)"),
        _q("gm4", "AQL কী?", "What is AQL?",
           ["quality", "sample", "defect", "inspection", "level", "মান", "নমুনা", "ত্রুটি", "পরিদর্শন", "লেভেল"],
           "সংজ্ঞা → নমুনা আকার → গ্রহণযোগ্য ত্রুটি সংখ্যা → উদাহরণ", "Definition → sample size → accepted defects → example"),
        _q("gm5", "কঠিন বায়ারকে কীভাবে সামলান?", "How do you handle a difficult buyer?",
           ["listen", "email", "solution", "relationship", "record", "শোনা", "ইমেইল", "সমাধান", "সম্পর্ক", "রেকর্ড"],
           _STAR_BN, _STAR_EN),
        _q("gm6", "কমপ্লায়েন্স কেন জরুরি?", "Why does compliance matter in garments?",
           ["safety", "worker", "audit", "buyer", "law", "নিরাপত্তা", "শ্রমিক", "অডিট", "বায়ার", "আইন"],
           "শ্রমিকের নিরাপত্তা → বায়ার অডিট → আইন → ব্যবসার সুনাম", "Worker safety → buyer audits → law → business reputation"),
    ]},
    {"id": "govt_viva", "bn": "সরকারি চাকরির ভাইভা (BCS-ধাঁচ)", "en": "Government job viva (BCS style)", "qs": [
        _q("gv1", "নিজের পরিচয় দিন (নাম, জেলা, পড়াশোনা)।", "Introduce yourself (name, district, education).",
           ["district", "university", "subject", "family", "goal", "জেলা", "বিশ্ববিদ্যালয়", "বিষয়", "পরিবার", "লক্ষ্য"],
           "নাম → জেলা ও তার একটা বৈশিষ্ট্য → পড়াশোনা → কেন সরকারি চাকরি", "Name → district + one fact → education → why public service"),
        _q("gv2", "আপনার জেলার বিখ্যাত কী এবং কেন?", "What is your district famous for, and why?",
           ["history", "product", "person", "river", "culture", "ইতিহাস", "পণ্য", "ব্যক্তি", "নদী", "সংস্কৃতি"],
           "ইতিহাস → বিখ্যাত পণ্য/ব্যক্তি → নদী/ভূগোল → আজকের গুরুত্ব", "History → famous product/person → river/geography → importance today"),
        _q("gv3", "প্রথম পছন্দ এই ক্যাডার কেন?", "Why is this cadre your first choice?",
           ["serve", "people", "role", "skill", "country", "সেবা", "জনগণ", "দায়িত্ব", "দক্ষতা", "দেশ"],
           "ক্যাডারের কাজ → আপনার পড়াশোনা/দক্ষতার মিল → জনসেবার উদাহরণ", "What the cadre does → fit with your study/skills → a public-service example"),
        _q("gv4", "মুক্তিযুদ্ধের একটা গুরুত্বপূর্ণ ঘটনা বলুন।", "Describe an important event of the Liberation War.",
           ["1971", "march", "december", "sector", "independence", "১৯৭১", "মার্চ", "ডিসেম্বর", "সেক্টর", "স্বাধীনতা"],
           "তারিখ → কী ঘটেছিল → কেন গুরুত্বপূর্ণ → আজকের শিক্ষা", "Date → what happened → why it mattered → lesson today"),
        _q("gv5", "দুর্নীতি কমাতে মাঠ পর্যায়ে কী করবেন?", "As an officer, how would you reduce corruption?",
           ["transparen", "digital", "accountab", "citizen", "law", "স্বচ্ছ", "ডিজিটাল", "জবাবদিহি", "নাগরিক", "আইন"],
           "স্বচ্ছতা → ডিজিটাল সেবা → জবাবদিহি → নাগরিকের অভিযোগের পথ → নিজে উদাহরণ",
           "Transparency → digital services → accountability → citizen complaint path → lead by example"),
        _q("gv6", "চলতি একটা জাতীয় ইস্যুতে আপনার মত দিন।", "Give your view on a current national issue.",
           ["data", "cause", "solution", "policy", "balance", "তথ্য", "কারণ", "সমাধান", "নীতি", "ভারসাম্য"],
           "ইস্যু → তথ্য/সংখ্যা → কারণ → ভারসাম্যপূর্ণ সমাধান (দলীয় মত নয়)", "Issue → facts/figures → causes → balanced solution (no party line)"),
    ]},
]

ROLE_IDS = tuple(r["id"] for r in ROLES)

FILLERS = ("um", "uh", "umm", "like", "actually", "basically", "you know",
           "মানে", "আসলে", "ইয়ে", "তো", "আর কি")
EXAMPLE_MARKERS = ("for example", "for instance", "once", "when i", "result",
                   "as a result", "যেমন", "উদাহরণ", "একবার", "ফলে", "ফলাফল", "তখন আমি")

RUBRIC_VERSION = "career-rubric-1"


def roles_public(lang):
    lang = "bn" if lang == "bn" else "en"
    return [{"id": r["id"], "name": r[lang], "count": len(r["qs"])} for r in ROLES]


def role_questions(role_id, lang):
    lang = "bn" if lang == "bn" else "en"
    role = next((r for r in ROLES if r["id"] == role_id), None)
    if role is None:
        return None
    return {"id": role["id"], "name": role[lang],
            "questions": [{"id": q["id"], "text": q[lang], "outline": q["outline"][lang]}
                          for q in role["qs"]]}


def find_question(qid):
    for r in ROLES:
        for q in r["qs"]:
            if q["id"] == qid:
                return r, q
    return None, None


def _count_fillers(low):
    n = 0
    for f in FILLERS:
        if re.fullmatch(r"[a-z ]+", f):
            n += len(re.findall(r"\b" + re.escape(f) + r"\b", low))
        else:
            n += low.count(f)
    return n


def rubric(qid, answer):
    """Key-free rubric. -> {score 0-100, words, hits:[...], missing:[...],
    has_example, fillers, tips:[tip ids], outline:{bn,en}} or None for an
    unknown question. The app owns the bn/en wording of each tip id."""
    _role, q = find_question(qid)
    if q is None:
        return None
    text = _s(answer, 6000)
    low = text.lower()
    words = len(text.split())
    keys = q["keys"]
    half = len(keys) // 2
    # keys come as 5 English stems then their 5 Bangla partners: a concept
    # counts once whichever language the answer uses.
    hits = []
    for i in range(half):
        en_k, bn_k = keys[i], keys[i + half]
        if en_k.lower() in low or bn_k in text:
            hits.append(i)
    has_example = bool(_DIGIT.search(text)) or any(m in low for m in EXAMPLE_MARKERS)
    fillers = _count_fillers(low)

    if words < 15:
        length_pts = 10
    elif words < 40:
        length_pts = 25
    elif words <= 220:
        length_pts = 35
    else:
        length_pts = 25
    cover_pts = round(35 * len(hits) / max(1, half))
    example_pts = 20 if has_example else 0
    filler_pts = 10 if fillers < 3 else (5 if fillers < 6 else 0)
    score = max(0, min(100, length_pts + cover_pts + example_pts + filler_pts))
    if not text:
        score = 0

    tips = []
    if words < 40:
        tips.append("longer")
    elif words > 220:
        tips.append("shorter")
    if len(hits) < max(2, half // 2 + 1):
        tips.append("cover_topics")
    if not has_example:
        tips.append("add_example")
    if fillers >= 3:
        tips.append("fewer_fillers")
    if not tips:
        tips.append("keep_going")
    return {
        "score": score, "words": words, "has_example": has_example,
        "fillers": fillers,
        "hits": [{"bn": keys[i + half], "en": keys[i]} for i in hits],
        "missing": [{"bn": keys[i + half], "en": keys[i]} for i in range(half) if i not in hits],
        "tips": tips[:3], "outline": q["outline"], "rubric": RUBRIC_VERSION,
    }
