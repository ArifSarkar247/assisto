"""
mock_interview.py — the deterministic, key-free engine behind Assisto's
MOCK INTERVIEW practice tool (#131, SPEC v2.1 §21, ADVANCED).

The user picks a CATEGORY (job / HR / technical-basics / viva), the tool serves
BILINGUAL interview questions ONE AT A TIME from a built-in bank, the user types
(or records→text) an answer, and we return RULE-BASED feedback — length check,
keyword coverage, structure tips — plus a MODEL-ANSWER OUTLINE. The user tracks
a session history of asked questions + self-scores.

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. It is a DETERMINISTIC RUBRIC — same inputs
always give the same feedback — so the on-device Dart mirror produces an
identical result offline and the tests can pin it.

HONEST AI, KEY-GATED
--------------------
The feedback here is an HONEST RULE-BASED RUBRIC, not an AI grade. It never
claims to be a real interviewer. It measures what can be measured without a
model — answer length, whether the question's own keywords appear, and whether
the answer looks structured — and offers a fixed model-answer OUTLINE. When an
AI key is present (Integrations → `core.ai.generate`), the app MAY route the
same {question, answer} to the real provider for a richer, conversational
critique. `live_interview_seam()` documents that request shape and always
returns `ai_required=True, mock=True` so callers stay honest about which path
produced the text. Nothing in this file calls a model.

CONTENT
-------
The bank below is REAL, commonly-asked interview questions with genuine model
outlines — not filler. ≥15 questions across four categories, each bilingual
(bn + en), each with keyword hints and a short model-answer outline. The engine
never fabricates a "correct" answer; the outline is a study aid labelled as a
guide, and the score is a self-measured rubric, not a verdict.

Everything is plain stdlib and hand-verified in mock_interview_tests_snippets.py.
"""

# ---------------------------------------------------------------- categories
# Neutral English category keys the UI localises. The bank groups by these.
CATEGORIES = ("job", "hr", "technical", "viva")

# The honest marker key every feedback result carries. The UI renders the
# localised "Rule-based — not an AI grade" chip from this.
MARKER_KEY = "rubric_review"

# Feedback status keys the UI localises (never prose from the engine).
# too_short → answer is thin; ok → covers some; strong → covers most + structured.
FEEDBACK_LEVELS = ("too_short", "ok", "strong")

# Rubric thresholds (deterministic). Word counts are generous for spoken-style
# answers typed out; coverage is the fraction of the question's keyword hints
# that appear (case-insensitive substring) in the answer.
_MIN_WORDS_OK = 20
_MIN_WORDS_STRONG = 45
_COVERAGE_STRONG = 0.5   # at least half the keyword hints present


# ---------------------------------------------------------------- the bank
# Each item:
#   id          stable string id (used by the session history + tests)
#   category    one of CATEGORIES
#   q_bn, q_en  the question, bilingual (both real)
#   keywords    lowercase English hint words the rubric looks for in the answer
#   outline_bn, outline_en  a short model-answer OUTLINE (study aid, not a grade)
#
# Content is genuine, commonly-asked interview material. Keyword hints are the
# concepts a good answer tends to mention; they drive the deterministic coverage
# score only — they are never presented as the "right answer".
BANK = [
    # ---- job / general ----
    {"id": "job_tellme", "category": "job",
     "q_bn": "নিজের সম্পর্কে কিছু বলুন।",
     "q_en": "Tell me about yourself.",
     "keywords": ["experience", "skill", "role", "strength", "goal"],
     "outline_bn": "বর্তমান ভূমিকা → প্রাসঙ্গিক অভিজ্ঞতা → একটি মূল দক্ষতা → "
                   "এই পদের সাথে কেন মানানসই। সংক্ষিপ্ত রাখুন (৩০–৬০ সেকেন্ড)।",
     "outline_en": "Current role → relevant experience → one core skill → why "
                   "it fits this job. Keep it to 30–60 seconds."},
    {"id": "job_strength", "category": "job",
     "q_bn": "আপনার সবচেয়ে বড় শক্তি কী?",
     "q_en": "What is your greatest strength?",
     "keywords": ["strength", "example", "result", "team", "learn"],
     "outline_bn": "একটি শক্তি নাম দিন → একটি বাস্তব উদাহরণ → তা থেকে পাওয়া ফল। "
                   "সাধারণ কথা নয়, একটি প্রমাণ দিন।",
     "outline_en": "Name one strength → give a concrete example → the result it "
                   "produced. Prove it, don't just claim it."},
    {"id": "job_weakness", "category": "job",
     "q_bn": "আপনার একটি দুর্বলতা কী, এবং আপনি তা নিয়ে কী করছেন?",
     "q_en": "What is a weakness, and what are you doing about it?",
     "keywords": ["weakness", "improve", "learn", "feedback", "progress"],
     "outline_bn": "একটি সত্য (কিন্তু চাকরি-ধ্বংসী নয়) দুর্বলতা → তা ঠিক করতে "
                   "আপনি কী করছেন → অগ্রগতির একটি চিহ্ন।",
     "outline_en": "One honest (not deal-breaking) weakness → the concrete steps "
                   "you take to improve → a sign of progress."},
    {"id": "job_why", "category": "job",
     "q_bn": "আপনি কেন এই কোম্পানিতে কাজ করতে চান?",
     "q_en": "Why do you want to work here?",
     "keywords": ["company", "mission", "role", "grow", "contribute"],
     "outline_bn": "কোম্পানি সম্পর্কে একটি নির্দিষ্ট তথ্য → তা আপনার সাথে কীভাবে "
                   "মেলে → আপনি কী অবদান রাখবেন।",
     "outline_en": "One specific thing about the company → how it matches you → "
                   "what you will contribute."},
    {"id": "job_fiveyears", "category": "job",
     "q_bn": "পাঁচ বছর পর নিজেকে কোথায় দেখতে চান?",
     "q_en": "Where do you see yourself in five years?",
     "keywords": ["grow", "skill", "role", "goal", "team"],
     "outline_bn": "বাস্তবসম্মত বৃদ্ধি → কোন দক্ষতা গড়বেন → তা এই পদের সাথে "
                   "কীভাবে সংযুক্ত। অতিরঞ্জিত নয়।",
     "outline_en": "Realistic growth → which skills you'll build → how it ties "
                   "back to this role. Avoid wild claims."},

    # ---- HR / behavioural ----
    {"id": "hr_conflict", "category": "hr",
     "q_bn": "সহকর্মীর সাথে মতবিরোধের একটি উদাহরণ দিন এবং আপনি কীভাবে তা সামলেছেন।",
     "q_en": "Describe a conflict with a coworker and how you handled it.",
     "keywords": ["situation", "listen", "resolve", "outcome", "respect"],
     "outline_bn": "পরিস্থিতি (S) → কাজ (T) → আপনি কী করলেন (A) → ফল (R)। "
                   "দোষারোপ নয়, সমাধানে মনোযোগ।",
     "outline_en": "Situation → Task → Action → Result (STAR). Focus on how you "
                   "resolved it, not on blaming anyone."},
    {"id": "hr_pressure", "category": "hr",
     "q_bn": "চাপের মধ্যে কাজ করার একটি সময়ের কথা বলুন।",
     "q_en": "Tell me about a time you worked under pressure.",
     "keywords": ["deadline", "prioritise", "calm", "result", "plan"],
     "outline_bn": "চাপের উৎস → আপনি কীভাবে অগ্রাধিকার দিলেন → শান্ত থাকলেন → ফল।",
     "outline_en": "What caused the pressure → how you prioritised → stayed "
                   "calm → the result (STAR)."},
    {"id": "hr_mistake", "category": "hr",
     "q_bn": "আপনার একটি ভুল এবং তা থেকে আপনি কী শিখেছেন তা বলুন।",
     "q_en": "Tell me about a mistake you made and what you learned.",
     "keywords": ["mistake", "responsibility", "fix", "learn", "change"],
     "outline_bn": "দায়িত্ব স্বীকার → আপনি কীভাবে ঠিক করলেন → কী শিখলেন → "
                   "পরে কী বদলালেন।",
     "outline_en": "Own the mistake → how you fixed it → what you learned → what "
                   "you changed afterwards."},
    {"id": "hr_teamwork", "category": "hr",
     "q_bn": "দলগত কাজের একটি সফল উদাহরণ দিন।",
     "q_en": "Give an example of successful teamwork.",
     "keywords": ["team", "role", "goal", "communicate", "result"],
     "outline_bn": "দলের লক্ষ্য → আপনার ভূমিকা → যোগাযোগ → যৌথ ফল।",
     "outline_en": "The team goal → your specific role → how you communicated → "
                   "the shared result."},
    {"id": "hr_salary", "category": "hr",
     "q_bn": "আপনার প্রত্যাশিত বেতন কত?",
     "q_en": "What are your salary expectations?",
     "keywords": ["range", "research", "role", "flexible", "value"],
     "outline_bn": "একটি যুক্তিসঙ্গত পরিসর (গবেষণার ভিত্তিতে) → নমনীয়তা দেখান → "
                   "পুরো প্যাকেজ বিবেচনায় খোলা।",
     "outline_en": "Give a researched range → show some flexibility → note you're "
                   "open to the full package, not just base pay."},

    # ---- technical basics ----
    {"id": "tech_variable", "category": "technical",
     "q_bn": "ভেরিয়েবল এবং কনস্ট্যান্টের মধ্যে পার্থক্য কী?",
     "q_en": "What is the difference between a variable and a constant?",
     "keywords": ["variable", "constant", "change", "value", "memory"],
     "outline_bn": "ভেরিয়েবলের মান পরিবর্তন করা যায়; কনস্ট্যান্টের মান একবার সেট "
                   "হলে স্থির থাকে। উদাহরণ দিন।",
     "outline_en": "A variable's value can change; a constant's value is fixed "
                   "once set. Give a small code example."},
    {"id": "tech_loop", "category": "technical",
     "q_bn": "for লুপ এবং while লুপের মধ্যে পার্থক্য কী?",
     "q_en": "What is the difference between a for loop and a while loop?",
     "keywords": ["loop", "condition", "iterate", "count", "repeat"],
     "outline_bn": "for সাধারণত জানা সংখ্যক বার চলে; while শর্ত সত্য থাকা পর্যন্ত "
                   "চলে। কখন কোনটি ব্যবহার করবেন বলুন।",
     "outline_en": "for usually runs a known number of times; while runs while a "
                   "condition holds. Say when you'd pick each."},
    {"id": "tech_sql", "category": "technical",
     "q_bn": "একটি ডাটাবেস (SQL) কী এবং কেন ব্যবহার করা হয়?",
     "q_en": "What is a database (SQL) and why is it used?",
     "keywords": ["database", "table", "query", "store", "relation"],
     "outline_bn": "কাঠামোবদ্ধ টেবিলে ডেটা সংরক্ষণ → query দিয়ে খোঁজা → টেবিলের "
                   "মধ্যে সম্পর্ক। একটি সহজ উদাহরণ।",
     "outline_en": "Stores structured data in tables → fetched with queries → "
                   "relations between tables. Give a simple example."},
    {"id": "tech_api", "category": "technical",
     "q_bn": "API কী? সহজ ভাষায় ব্যাখ্যা করুন।",
     "q_en": "What is an API? Explain in simple terms.",
     "keywords": ["api", "request", "response", "interface", "service"],
     "outline_bn": "দুই সফটওয়্যারের মধ্যে কথা বলার চুক্তি → request পাঠান, "
                   "response পান → একটি বাস্তব উদাহরণ (আবহাওয়া API)।",
     "outline_en": "A contract letting two programs talk → send a request, get a "
                   "response → a real example (a weather API)."},
    {"id": "tech_debug", "category": "technical",
     "q_bn": "একটি বাগ খুঁজে বের করতে আপনি কীভাবে এগোবেন?",
     "q_en": "How do you approach finding a bug?",
     "keywords": ["reproduce", "log", "isolate", "test", "fix"],
     "outline_bn": "সমস্যাটি পুনরায় ঘটান → লগ/প্রিন্ট দেখুন → ছোট অংশে আলাদা করুন "
                   "→ ঠিক করে টেস্ট করুন।",
     "outline_en": "Reproduce it → read logs/prints → isolate to a small part → "
                   "fix, then test it stays fixed."},

    # ---- viva / academic ----
    {"id": "viva_project", "category": "viva",
     "q_bn": "আপনার প্রজেক্টের মূল উদ্দেশ্য সংক্ষেপে বলুন।",
     "q_en": "Briefly state the main objective of your project.",
     "keywords": ["objective", "problem", "solution", "result", "scope"],
     "outline_bn": "কোন সমস্যা সমাধান করে → আপনার পদ্ধতি → মূল ফল → সীমাবদ্ধতা।",
     "outline_en": "What problem it solves → your approach → the main result → "
                   "one limitation."},
    {"id": "viva_tools", "category": "viva",
     "q_bn": "আপনি কোন টুল/প্রযুক্তি ব্যবহার করেছেন এবং কেন?",
     "q_en": "Which tools/technologies did you use, and why?",
     "keywords": ["tool", "reason", "alternative", "fit", "experience"],
     "outline_bn": "প্রতিটি টুল নাম দিন → কেন বেছে নিলেন → বিকল্প কী ছিল।",
     "outline_en": "Name each tool → why you chose it → what the alternative was."},
    {"id": "viva_challenge", "category": "viva",
     "q_bn": "প্রজেক্টে সবচেয়ে বড় চ্যালেঞ্জ কী ছিল?",
     "q_en": "What was the biggest challenge in your project?",
     "keywords": ["challenge", "problem", "solve", "learn", "overcome"],
     "outline_bn": "চ্যালেঞ্জটি → আপনি কীভাবে কাটিয়ে উঠলেন → কী শিখলেন।",
     "outline_en": "The challenge → how you overcame it → what you learned."},
    {"id": "viva_improve", "category": "viva",
     "q_bn": "আরও সময় পেলে প্রজেক্টে কী উন্নতি করতেন?",
     "q_en": "What would you improve in the project with more time?",
     "keywords": ["improve", "future", "feature", "test", "scale"],
     "outline_bn": "একটি সৎ সীমাবদ্ধতা → একটি নির্দিষ্ট উন্নতি → তা কেন গুরুত্বপূর্ণ।",
     "outline_en": "One honest limitation → one specific improvement → why it "
                   "would matter."},
]


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _words(text):
    """Whitespace word list of cleaned text."""
    t = _clean(text)
    return t.split() if t else []


def categories():
    """The category keys, in stable order (UI localises each)."""
    return list(CATEGORIES)


def questions_for(category):
    """All bank questions for a category, in stable bank order. Empty list for
    an unknown category (the UI guards, but the engine stays total)."""
    return [q for q in BANK if q["category"] == category]


def next_question(category, asked_ids=None):
    """Serve the NEXT unasked question for a category, deterministically.

    `asked_ids` is the list of question ids already shown this session. We walk
    the bank in order and return the first one not yet asked. When every
    question has been asked we wrap to the start (so practice can continue) and
    flag `wrapped=True`. Returns None-shaped dict only when the category is
    empty. Deterministic: same (category, asked_ids) → same question."""
    pool = questions_for(category)
    if not pool:
        return {"question": None, "remaining": 0, "wrapped": False,
                "total": 0, "problems": ["bad_category"]}
    asked = set(asked_ids or [])
    unasked = [q for q in pool if q["id"] not in asked]
    wrapped = False
    if not unasked:
        unasked = pool
        wrapped = True
    q = unasked[0]
    return {
        "question": {"id": q["id"], "category": q["category"],
                     "q_bn": q["q_bn"], "q_en": q["q_en"]},
        "remaining": len(unasked) - (0 if wrapped else 0) if not wrapped
                     else len(pool),
        "answered": len([i for i in asked if any(x["id"] == i for x in pool)]),
        "total": len(pool),
        "wrapped": wrapped,
        "problems": [],
    }


def model_outline(question_id):
    """The study-aid OUTLINE for a question id, bilingual. Honest: a GUIDE, not
    a graded correct answer. Empty strings for an unknown id."""
    for q in BANK:
        if q["id"] == question_id:
            return {"id": q["id"], "outline_bn": q["outline_bn"],
                    "outline_en": q["outline_en"],
                    "keywords": list(q["keywords"])}
    return {"id": question_id, "outline_bn": "", "outline_en": "",
            "keywords": []}


def feedback(question_id, answer):
    """RULE-BASED feedback on an answer to a bank question. DETERMINISTIC.

    Honest: this is NOT an AI grade. It measures only what a rubric can:
      * word count vs thresholds (too_short / ok / strong)
      * keyword coverage — fraction of the question's hint words present
      * a structure hint — whether the answer has >1 sentence
    and returns tip KEYS the UI localises, plus the matched/missing keywords so
    the user can self-review against the model outline.

    Returns:
        {question_id, words, level, coverage, matched, missing,
         structured, tips:[keys], ai_required:False, mock:True, marker,
         problems:[...]}
    Unknown question id ⇒ problems=['bad_question'] and a neutral result."""
    q = next((x for x in BANK if x["id"] == question_id), None)
    ans = _clean(answer)
    words = _words(ans)
    n = len(words)
    low = ans.lower()

    if q is None:
        return {"question_id": question_id, "words": n, "level": "too_short",
                "coverage": 0.0, "matched": [], "missing": [],
                "structured": False, "tips": ["bad_question"],
                "ai_required": False, "mock": True, "marker": MARKER_KEY,
                "problems": ["bad_question"]}

    hints = q["keywords"]
    matched = [k for k in hints if k in low]
    missing = [k for k in hints if k not in low]
    coverage = (len(matched) / len(hints)) if hints else 0.0
    # count sentence-ish breaks for a structure hint
    structured = sum(low.count(c) for c in ".!?।") >= 1 and n >= _MIN_WORDS_OK

    if n < _MIN_WORDS_OK:
        level = "too_short"
    elif n >= _MIN_WORDS_STRONG and coverage >= _COVERAGE_STRONG:
        level = "strong"
    else:
        level = "ok"

    # deterministic tip KEYS (UI localises). Ordered, de-duped.
    tips = []
    if level == "too_short":
        tips.append("tip_longer")
    if missing:
        tips.append("tip_cover_keywords")
    if not structured and n >= _MIN_WORDS_OK:
        tips.append("tip_structure")
    if level == "strong":
        tips.append("tip_strong")
    if not tips:
        tips.append("tip_ok")

    return {
        "question_id": question_id,
        "words": n,
        "level": level,
        "coverage": round(coverage, 2),
        "matched": matched,
        "missing": missing,
        "structured": structured,
        "tips": tips,
        "ai_required": False,   # the rubric is deterministic + key-free
        "mock": True,           # HONEST: rule-based, not an AI grade
        "marker": MARKER_KEY,
        "problems": [],
    }


def session_progress(category, asked_ids=None):
    """Deterministic roll-up for the session header: how many of a category's
    questions have been practised. Pure counting."""
    pool = questions_for(category)
    asked = set(asked_ids or [])
    done = len([q for q in pool if q["id"] in asked])
    total = len(pool)
    return {"category": category, "done": done, "total": total,
            "percent": round(100 * done / total) if total else 0}


# -------------------------------------------------------------- AI seam (gated)

def live_interview_seam(question_id, answer):
    """DOCUMENTED key-gated seam for a LIVE AI interviewer — NOT built here.

    This returns the request SHAPE the app would route to `core.ai.generate`
    when an AI key is connected (a conversational critique + a follow-up
    question that reacts to THIS answer). With no key, the app shows the honest
    "connect an AI key for a live AI interviewer" state and the rule-based
    `feedback()` above still works fully. Always `ai_required=True, mock=True`;
    never calls a model."""
    q = next((x for x in BANK if x["id"] == question_id), None)
    return {
        "action": "live_interview",
        "question_id": question_id,
        "question_en": q["q_en"] if q else "",
        "answer": _clean(answer),
        "followup": "",          # a real model would react with a follow-up
        "critique": "",          # a real model would give a conversational note
        "ai_required": True,     # honest: the live interviewer needs the key
        "mock": True,
        "marker": MARKER_KEY,
    }
