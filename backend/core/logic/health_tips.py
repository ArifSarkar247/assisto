"""
health_tips.py — Assisto Health-Tips library (no AI key; pure Python,
deterministic, unit-testable). Benchmarked against the SAFE subset of
Ada / WebMD symptom-triage: we DO NOT diagnose. We surface trusted public-health
guidance, grouped by everyday topics, each tip SOURCE-NAMED.

SAFETY / LICENSING (STRICT):
  - Every tip is paraphrased general guidance from a NAMED trusted public-health
    source: DGHS (Directorate General of Health Services, Bangladesh) or WHO.
    We paraphrase public guidance; we never copy a proprietary database.
  - We NEVER diagnose and NEVER prescribe. Content is educational only.
  - Emergency / red-flag symptoms always resolve to: "call 999 / consult a
    doctor" in BOTH languages. `emergency_check()` scans free text for red-flag
    terms and returns that call-to-action — it is NOT a diagnosis.

Everything is bilingual via pick(); the UI can localise from the machine `id`
fields, or show the bn/en strings directly.

Run self-tests:
    python3 -c "import core.logic.health_tips_tests_snippets as t; t.run_all()"
"""
import re


def pick(lang, bn, en):
    return en if lang == "en" else bn


# Named, trusted sources. The UI shows source + a short disclaimer on every tip.
SOURCE_DGHS = "DGHS"   # Directorate General of Health Services, Bangladesh
SOURCE_WHO = "WHO"     # World Health Organization


# ---------------------------------------------------------------------------
# topics (categories) — bilingual labels, stable machine ids
# ---------------------------------------------------------------------------

TOPICS = [
    {"id": "general", "bn": "সাধারণ সুস্থতা", "en": "General wellness", "icon": "favorite"},
    {"id": "nutrition", "bn": "খাদ্য ও পুষ্টি", "en": "Food & nutrition", "icon": "restaurant"},
    {"id": "hydration", "bn": "পানি ও হাইড্রেশন", "en": "Water & hydration", "icon": "water_drop"},
    {"id": "hygiene", "bn": "স্বাস্থ্যবিধি", "en": "Hygiene", "icon": "wash"},
    {"id": "mother_child", "bn": "মা ও শিশু", "en": "Mother & child", "icon": "child_care"},
    {"id": "dengue_mosquito", "bn": "ডেঙ্গু ও মশা", "en": "Dengue & mosquitoes", "icon": "bug_report"},
    {"id": "diabetes_bp", "bn": "ডায়াবেটিস ও রক্তচাপ", "en": "Diabetes & blood pressure", "icon": "monitor_heart"},
    {"id": "mental", "bn": "মানসিক স্বাস্থ্য", "en": "Mental wellbeing", "icon": "self_improvement"},
    {"id": "elderly", "bn": "বয়স্কদের যত্ন", "en": "Elderly care", "icon": "elderly"},
    {"id": "emergency", "bn": "জরুরি অবস্থা", "en": "Emergencies", "icon": "emergency"},
]

# emergency red-flag symptom terms (bn + en, lowercased). Matching ANY of these
# NEVER yields a diagnosis — it yields the "call 999 / see a doctor" action.
EMERGENCY_TERMS = [
    # breathing / chest
    "chest pain", "breathless", "shortness of breath", "can't breathe", "cannot breathe",
    "বুকে ব্যথা", "শ্বাস নিতে কষ্ট", "শ্বাসকষ্ট",
    # stroke / neuro
    "unconscious", "fainted", "seizure", "convulsion", "slurred speech", "stroke",
    "face droop", "sudden weakness", "অজ্ঞান", "খিঁচুনি", "কথা জড়িয়ে",
    "হঠাৎ দুর্বল", "স্ট্রোক",
    # bleeding / trauma
    "heavy bleeding", "severe bleeding", "vomiting blood", "coughing blood",
    "প্রচণ্ড রক্তক্ষরণ", "রক্তবমি", "রক্ত কাশি",
    # other red flags
    "suicide", "suicidal", "poison", "overdose", "high fever convulsion",
    "stiff neck", "আত্মহত্যা", "বিষ খেয়েছে", "বিষপান", "বিষ পান", "অতিরিক্ত ওষুধ",
    # pregnancy
    "severe abdominal pain", "তীব্র পেটে ব্যথা",
]


# ---------------------------------------------------------------------------
# curated tips  (paraphrased trusted public-health guidance, SOURCE-NAMED)
# ---------------------------------------------------------------------------
# Each tip: id, topic, source (SOURCE_* constant), bn/en title, bn/en body.
# Bodies are general, non-diagnostic, actionable. Red-flag situations always
# point to a doctor / 999.

TIPS = [
    # ---- general wellness ----
    {"id": "sleep_7_8", "topic": "general", "source": SOURCE_WHO,
     "title_bn": "পর্যাপ্ত ঘুম", "title_en": "Get enough sleep",
     "body_bn": "প্রাপ্তবয়স্কদের রাতে ৭–৮ ঘণ্টা ঘুম দরকার। ঘুমের সময় নিয়মিত রাখুন এবং ঘুমানোর আগে মোবাইলের স্ক্রিন কমান।",
     "body_en": "Adults generally need 7–8 hours of sleep a night. Keep a regular bedtime and cut down on phone screens before sleep."},
    {"id": "move_daily", "topic": "general", "source": SOURCE_WHO,
     "title_bn": "প্রতিদিন হাঁটাচলা", "title_en": "Move every day",
     "body_bn": "সপ্তাহে অন্তত ১৫০ মিনিট মাঝারি ব্যায়াম বা হাঁটা শরীর ও মন ভালো রাখে। লিফটের বদলে সিঁড়ি ব্যবহার করুন।",
     "body_en": "Aim for at least 150 minutes of moderate activity or walking a week. Take the stairs instead of the lift when you can."},
    {"id": "no_tobacco", "topic": "general", "source": SOURCE_WHO,
     "title_bn": "তামাক ও ধূমপান বর্জন", "title_en": "Avoid tobacco",
     "body_bn": "ধূমপান ও তামাক (জর্দা/গুল) হৃদরোগ ও ক্যান্সারের ঝুঁকি বাড়ায়। ছাড়তে চাইলে ডাক্তারের পরামর্শ নিন।",
     "body_en": "Smoking and smokeless tobacco raise the risk of heart disease and cancer. If you want to quit, ask a doctor for help."},

    # ---- nutrition ----
    {"id": "balanced_plate", "topic": "nutrition", "source": SOURCE_DGHS,
     "title_bn": "সুষম খাবার", "title_en": "Eat a balanced plate",
     "body_bn": "প্রতিবেলায় ভাত/রুটি, ডাল বা মাছ-মাংস, আর শাকসবজি রাখুন। রঙিন সবজি ও মৌসুমি ফল যোগ করুন।",
     "body_en": "Include a carbohydrate (rice/bread), a protein (lentils, fish or meat) and vegetables at each meal. Add colourful vegetables and seasonal fruit."},
    {"id": "less_salt", "topic": "nutrition", "source": SOURCE_WHO,
     "title_bn": "লবণ কম খান", "title_en": "Cut down on salt",
     "body_bn": "দিনে ৫ গ্রামের (এক চা-চামচ) বেশি লবণ নয়। টেবিলে আলাদা লবণ ও বেশি লবণযুক্ত ভাজা খাবার এড়িয়ে চলুন।",
     "body_en": "Keep salt under about 5 g (one teaspoon) a day. Avoid adding extra salt at the table and limit salty fried snacks."},
    {"id": "less_sugar", "topic": "nutrition", "source": SOURCE_WHO,
     "title_bn": "চিনি ও মিষ্টি পানীয় কমান", "title_en": "Limit sugary drinks",
     "body_bn": "কোমল পানীয় ও অতিরিক্ত চিনি ওজন ও ডায়াবেটিসের ঝুঁকি বাড়ায়। পানি বা চিনি ছাড়া পানীয় বেছে নিন।",
     "body_en": "Soft drinks and added sugar raise the risk of weight gain and diabetes. Choose water or unsweetened drinks instead."},

    # ---- hydration ----
    {"id": "safe_water", "topic": "hydration", "source": SOURCE_DGHS,
     "title_bn": "নিরাপদ পানি পান", "title_en": "Drink safe water",
     "body_bn": "পানি ফুটিয়ে বা বিশুদ্ধ করে পান করুন। খাবার আগে ও টয়লেটের পরে সাবান দিয়ে হাত ধুয়ে নিন।",
     "body_en": "Drink water that has been boiled or purified. Wash hands with soap before eating and after using the toilet."},
    {"id": "ors_diarrhea", "topic": "hydration", "source": SOURCE_DGHS,
     "title_bn": "ডায়রিয়ায় খাবার স্যালাইন", "title_en": "ORS for diarrhoea",
     "body_bn": "ডায়রিয়া হলে প্রতিবার পাতলা পায়খানার পর খাবার স্যালাইন (ORS) খাওয়ান। রক্ত বা টানা বমি হলে দ্রুত ডাক্তার দেখান।",
     "body_en": "For diarrhoea, give oral rehydration salts (ORS) after each loose stool. If there is blood or constant vomiting, see a doctor quickly."},

    # ---- hygiene ----
    {"id": "handwash", "topic": "hygiene", "source": SOURCE_WHO,
     "title_bn": "সঠিকভাবে হাত ধোয়া", "title_en": "Wash hands properly",
     "body_bn": "সাবান দিয়ে অন্তত ২০ সেকেন্ড হাত ধুয়ে নিন—খাওয়ার আগে, রান্নার আগে ও টয়লেটের পরে। রোগ ছড়ানো কমে।",
     "body_en": "Wash hands with soap for at least 20 seconds — before eating, before cooking and after the toilet. It cuts the spread of illness."},
    {"id": "food_safety", "topic": "hygiene", "source": SOURCE_DGHS,
     "title_bn": "খাবার নিরাপদে রাখুন", "title_en": "Keep food safe",
     "body_bn": "রান্না করা খাবার ঢেকে রাখুন, বাসি খাবার গরম করে খান এবং কাঁচা-রান্না খাবার আলাদা রাখুন।",
     "body_en": "Cover cooked food, reheat leftovers thoroughly, and keep raw and cooked food separate."},

    # ---- mother & child ----
    {"id": "exclusive_bf", "topic": "mother_child", "source": SOURCE_WHO,
     "title_bn": "৬ মাস শুধু বুকের দুধ", "title_en": "Breastfeed for 6 months",
     "body_bn": "জন্মের প্রথম ৬ মাস শিশুকে শুধু মায়ের দুধ দিন—পানি বা অন্য খাবার নয়। এরপর বাড়তি খাবার শুরু করুন।",
     "body_en": "For the first 6 months give the baby only breast milk — no water or other food. Then start complementary foods alongside breast milk."},
    {"id": "child_vaccine", "topic": "mother_child", "source": SOURCE_DGHS,
     "title_bn": "শিশুর টিকা সময়মতো", "title_en": "Keep child vaccines on time",
     "body_bn": "EPI সূচি অনুযায়ী শিশুর সব টিকা সময়মতো দিন। টিকা কার্ড সংরক্ষণ করুন ও নিকটস্থ কেন্দ্রে যান।",
     "body_en": "Give all child vaccines on time per the EPI schedule. Keep the vaccination card and visit your nearest centre."},

    # ---- dengue & mosquito ----
    {"id": "dengue_water", "topic": "dengue_mosquito", "source": SOURCE_DGHS,
     "title_bn": "জমা পানি ফেলে দিন", "title_en": "Clear standing water",
     "body_bn": "ডেঙ্গুর এডিস মশা পরিষ্কার জমা পানিতে ডিম পাড়ে। ফুলের টব, ছাদ, ড্রাম—৩ দিনে একবার জমা পানি ফেলে দিন।",
     "body_en": "Dengue's Aedes mosquito breeds in clean standing water. Empty flower pots, rooftops and drums at least once every 3 days."},
    {"id": "dengue_warning", "topic": "dengue_mosquito", "source": SOURCE_DGHS,
     "title_bn": "ডেঙ্গুর বিপদ-চিহ্ন", "title_en": "Dengue warning signs",
     "body_bn": "জ্বরের সাথে তীব্র পেটে ব্যথা, বারবার বমি, রক্তক্ষরণ বা খুব দুর্বলতা দেখা দিলে দেরি না করে ডাক্তার দেখান।",
     "body_en": "With fever, if there is severe abdominal pain, repeated vomiting, bleeding or extreme weakness, see a doctor without delay."},

    # ---- diabetes & blood pressure ----
    {"id": "bp_check", "topic": "diabetes_bp", "source": SOURCE_WHO,
     "title_bn": "রক্তচাপ পরিমাপ করুন", "title_en": "Check your blood pressure",
     "body_bn": "উচ্চ রক্তচাপ প্রায়ই উপসর্গ ছাড়াই থাকে। নিয়মিত রক্তচাপ মাপুন, লবণ কমান, আর ওষুধ নিজে থেকে বন্ধ করবেন না।",
     "body_en": "High blood pressure often has no symptoms. Check it regularly, cut down on salt, and never stop your medicine on your own."},
    {"id": "diabetes_feet", "topic": "diabetes_bp", "source": SOURCE_WHO,
     "title_bn": "ডায়াবেটিসে পায়ের যত্ন", "title_en": "Diabetes foot care",
     "body_bn": "ডায়াবেটিস থাকলে প্রতিদিন পা পরীক্ষা করুন, খালি পায়ে হাঁটবেন না। ঘা বা কাটা সারতে দেরি হলে ডাক্তার দেখান।",
     "body_en": "If you have diabetes, check your feet daily and don't walk barefoot. If a wound or cut is slow to heal, see a doctor."},

    # ---- mental wellbeing ----
    {"id": "talk_stress", "topic": "mental", "source": SOURCE_WHO,
     "title_bn": "চাপ নিয়ে কথা বলুন", "title_en": "Talk about stress",
     "body_bn": "দুশ্চিন্তা বা মন খারাপ দীর্ঘস্থায়ী হলে বিশ্বস্ত কারও সাথে কথা বলুন। প্রয়োজনে পেশাদার সাহায্য নিন—এতে লজ্জা নেই।",
     "body_en": "If worry or low mood lasts a long time, talk to someone you trust. Seek professional help if needed — there is no shame in it."},
    {"id": "screen_breaks", "topic": "mental", "source": SOURCE_WHO,
     "title_bn": "বিশ্রাম ও ভারসাম্য", "title_en": "Rest and balance",
     "body_bn": "কাজের ফাঁকে বিরতি নিন, পরিবারের সাথে সময় কাটান এবং ঘুম ঠিক রাখুন—মানসিক স্বাস্থ্যের জন্য জরুরি।",
     "body_en": "Take breaks during work, spend time with family and protect your sleep — all important for mental health."},

    # ---- elderly ----
    {"id": "fall_prevent", "topic": "elderly", "source": SOURCE_WHO,
     "title_bn": "পড়ে যাওয়া প্রতিরোধ", "title_en": "Prevent falls",
     "body_bn": "বয়স্কদের ঘরে আলো বাড়ান, ভেজা মেঝে ও আলগা কার্পেট সরান এবং বাথরুমে ধরার হাতল বসান।",
     "body_en": "For older people, add lighting at home, remove wet floors and loose rugs, and fit grab bars in the bathroom."},
    {"id": "elderly_meds", "topic": "elderly", "source": SOURCE_DGHS,
     "title_bn": "নিয়মিত ওষুধ ও চেকআপ", "title_en": "Regular medicines & checkups",
     "body_bn": "বয়স্কদের ওষুধ সময়মতো দিন, নিয়মিত চেকআপ করান এবং একাধিক ডাক্তারের ওষুধ একসাথে নেওয়ার আগে পরামর্শ নিন।",
     "body_en": "Give older people their medicines on time, arrange regular checkups, and check before combining medicines from different doctors."},

    # ---- emergency (always doctor / 999) ----
    {"id": "emergency_999", "topic": "emergency", "source": SOURCE_DGHS,
     "title_bn": "জরুরি অবস্থায় ৯৯৯", "title_en": "In an emergency call 999",
     "body_bn": "বুকে ব্যথা, শ্বাসকষ্ট, অজ্ঞান, খিঁচুনি, প্রচণ্ড রক্তক্ষরণ বা স্ট্রোকের লক্ষণে অপেক্ষা না করে ৯৯৯-এ কল করুন বা দ্রুত ডাক্তার দেখান।",
     "body_en": "For chest pain, breathing trouble, fainting, seizures, severe bleeding or stroke signs, don't wait — call 999 or see a doctor urgently."},
]


# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

def source_name(source, lang="bn"):
    """Human-readable, localised source name for a SOURCE_* constant."""
    if source == SOURCE_DGHS:
        return pick(lang, "স্বাস্থ্য অধিদপ্তর (DGHS)", "Directorate General of Health Services (DGHS)")
    if source == SOURCE_WHO:
        return pick(lang, "বিশ্ব স্বাস্থ্য সংস্থা (WHO)", "World Health Organization (WHO)")
    return source


def disclaimer(lang="bn"):
    """The non-diagnostic disclaimer shown on the library (both languages)."""
    return pick(lang,
                "এই তথ্য শুধু সাধারণ সচেতনতার জন্য, কোনো রোগ নির্ণয় বা চিকিৎসা নয়। "
                "সমস্যা হলে ডাক্তারের পরামর্শ নিন।",
                "This is general awareness only — not a diagnosis or treatment. "
                "Consult a doctor for any health problem.")


def emergency_action(lang="bn"):
    """The single, fixed emergency call-to-action (NEVER a diagnosis)."""
    return pick(lang,
                "এটি জরুরি হতে পারে। দেরি না করে ৯৯৯-এ কল করুন বা দ্রুত ডাক্তার দেখান।",
                "This may be an emergency. Call 999 now or see a doctor urgently.")


def topics(lang="bn"):
    """Localised topic list: [{id, label, icon}]."""
    return [{"id": t["id"], "label": pick(lang, t["bn"], t["en"]), "icon": t["icon"]}
            for t in TOPICS]


def _localize_tip(tip, lang):
    return {
        "id": tip["id"],
        "topic": tip["topic"],
        "source": tip["source"],
        "source_name": source_name(tip["source"], lang),
        "title": pick(lang, tip["title_bn"], tip["title_en"]),
        "body": pick(lang, tip["body_bn"], tip["body_en"]),
    }


def tips(lang="bn", topic=None, query=None):
    """Localised tips, optionally filtered by topic id and/or a free-text query.
    Query matches title/body case-insensitively in the active language."""
    out = []
    q = (query or "").strip().lower()
    for t in TIPS:
        if topic and t["topic"] != topic:
            continue
        lt = _localize_tip(t, lang)
        if q and q not in lt["title"].lower() and q not in lt["body"].lower():
            continue
        out.append(lt)
    return out


def tip_by_id(tip_id, lang="bn"):
    for t in TIPS:
        if t["id"] == tip_id:
            return _localize_tip(t, lang)
    return None


def _norm(s):
    return " ".join(str(s or "").lower().split())


# Matches an ASCII letter/digit (Latin "word" character) — used to decide
# whether a term is Latin (needs \b word boundaries) or non-Latin (e.g. Bangla).
_LATIN_WORD = re.compile(r"[a-z0-9]")


def _term_matches(term, norm):
    """True if `term` occurs in the normalised text `norm` with proper
    token/word boundaries (not as a sub-token of a larger word).

    - Latin terms (contain a-z/0-9) match only on \\b word boundaries, so
      'stroke' does NOT match 'strokeplay' and 'poison' does NOT match
      'poisonous'. Multi-word phrases ('chest pain') are anchored at both ends.
    - Non-Latin terms (e.g. Bangla) have no ASCII word boundaries, so we require
      a whitespace/start/end boundary on each side (token boundary) so 'বিষ পান'
      matches as whole tokens and benign words like 'বিষয়' never match a short
      sub-string. (The short ambiguous 'বিষ' was replaced with longer phrases.)
    """
    t = _norm(term)
    if not t:
        return False
    if _LATIN_WORD.search(t):
        # Latin / mixed term -> ASCII word boundaries.
        return re.search(r"\b" + re.escape(t) + r"\b", norm) is not None
    # Non-Latin term (Bangla): \b is unreliable for Bangla script, so anchor on
    # a non-"word" character (or string edge) on each side. \w (Unicode) matches
    # Bangla letters, so this blocks 'বিষ' matching inside 'বিষয়' while allowing
    # punctuation/space (comma, danda, etc.) to act as a boundary.
    return re.search(r"(?<!\w)" + re.escape(t) + r"(?!\w)", norm) is not None


def emergency_check(text, lang="bn"):
    """Scan free text for red-flag emergency terms.

    This is NOT a diagnosis and NOT triage. It only decides whether to surface
    the fixed 'call 999 / see a doctor' action. Returns:
      {"emergency": bool, "matched": [terms], "action": <string or "">}

    Matching is WORD/TOKEN-boundary based (see `_term_matches`) so benign text
    like 'strokeplay', 'poisonous' or the Bangla 'বিষয়' (topic) never trips a
    false 999 banner, while real red flags ('chest pain', 'বুকে ব্যথা') do.
    """
    norm = _norm(text)
    matched = [term for term in EMERGENCY_TERMS if _term_matches(term, norm)]
    if matched:
        return {"emergency": True, "matched": matched, "action": emergency_action(lang)}
    return {"emergency": False, "matched": [], "action": ""}


def library(lang="bn", topic=None, query=None):
    """Full localised payload for the Health-Tips screen.
    Shape: {topics, tips, disclaimer, sources}."""
    return {
        "topics": topics(lang),
        "tips": tips(lang, topic=topic, query=query),
        "disclaimer": disclaimer(lang),
        "sources": [source_name(SOURCE_DGHS, lang), source_name(SOURCE_WHO, lang)],
    }
