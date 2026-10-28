"""Server-side final-answer health filter for agent runs (WP-MEMORY gap fix).

The health topic's "no medical advice" rule used to live only in the topic
instructions and the evals — i.e. it relied on the model obeying. This filter
runs on EVERY agent run's final answer in code (runner._finish), whatever the
topic and whatever the model said:

  * reuses core/ai_guard.scrub_medical_claims (cure promises, self-dosing);
  * adds what an agent answer must never contain: a diagnosis ("you have
    diabetes", "আপনার জ্বর হয়েছে", "apnar gastric hoyeche"), a medicine or a
    dose ("Napa 500 খান", "paracetamol 2 ta", "din e 3 bar"), or a therapy
    ("ইনসুলিন নিন", "start physiotherapy", "antibiotic course");
  * a sentence that does is REMOVED (never rewritten into something else);
  * the doctor / 999 line is appended once — always for the health topic,
    and for any topic whenever something was removed.

PURE: no DB, no network, no AI call.
"""
import re

from .. import ai_guard as G

DOCTOR_999_LINE = {
    "bn": "অসুস্থ বোধ করলে ডাক্তারের পরামর্শ নিন; জরুরি অবস্থায় এখনই ৯৯৯-এ কল করুন।",
    "en": "If you feel unwell, please see a doctor; in an emergency call 999 now.",
}

# medicine names commonly sold in Bangladesh (generic + brand). A name on its
# own is not advice (the user's own reminder "নাপা খাওয়া" is fine); a name
# with "take / খান / নিন / try" next to it, or any dose, is.
_MEDS = (
    r"paracetamol|acetaminophen|napa|ibuprofen|aspirin|omeprazole|esomeprazole|pantoprazole|"
    r"seclo|sergel|maxpro|losectil|antacid|ranitidine|metformin|insulin|glimepiride|amlodipine|"
    r"losartan|atenolol|azithromycin|amoxicillin|ciprofloxacin|cefixime|metronidazole|flagyl|"
    r"antibiotics?|steroids?|prednisolone|cetirizine|fexofenadine|fexo|histacin|"
    r"montelukast|salbutamol|domperidone|ondansetron|orsaline|oral saline|saline|vitamin [a-z]\d*|"
    r"sleeping pills?|painkillers?|pain killers?|diazepam|clonazepam|tablets?|pills?|medicines?|"
    r"প্যারাসিটামল|নাপা|আইবুপ্রোফেন|অ্যাসপিরিন|ওমিপ্রাজল|সেকলো|সার্জেল|ম্যাক্সপ্রো|"
    r"অ্যান্টাসিড|মেটফরমিন|ইনসুলিন|অ্যান্টিবায়োটিক|অ্যান্টিবায়োটিক|অ্যাজিথ্রোমাইসিন|"
    r"অ্যামোক্সিসিলিন|সিপ্রোফ্লক্সাসিন|ফ্ল্যাজিল|স্টেরয়েড|স্টেরয়েড|হিস্টাসিন|ফেক্সো|"
    r"সালবিউটামল|ডমপেরিডন|স্যালাইন|ঘুমের ওষুধ|ঘুমের বড়ি|ব্যথার ওষুধ|পেইনকিলার|ওষুধ|ঔষধ|"
    r"ট্যাবলেট|বড়ি|oshudh|osudh|oshud"
)
_TAKE = (r"খান|খাবেন|খেয়ে নিন|খেতে পারেন|খেয়ে দেখুন|নিন|নিতে পারেন|নিয়ে নিন|সেবন|"
         r"take|try|use|have some|khan|khaben|khete paren|kheye nin|nin|niye nin|nite paren")
_MED_RX = re.compile(
    r"(?<![a-z])(?:%s)[^.।!?\n]{0,40}?(?<![a-z])(?:%s)(?![a-z])|"
    r"(?<![a-z])(?:%s)(?![a-z])[^.।!?\n]{0,30}?(?<![a-z])(?:%s)" % (_MEDS, _TAKE, _TAKE, _MEDS),
    re.I)

# a dose / schedule of taking something
_DOSE_RX = re.compile(
    r"[\d০-৯]+\s*(?:mg|ml|mcg|মিগ্রা|মিলিগ্রাম|মিলি|ট্যাবলেট|tablets?|tabs?\b|ক্যাপসুল|capsules?|"
    r"বড়ি|চামচ সিরাপ|ফোঁটা|drops)|"
    r"দিনে\s*(?:[\d০-৯]+|এক|দুই|তিন|চার)\s*(?:বার|বেলা)|"
    r"(?:din|dine|din e|dine e)\s*\d+\s*(?:bar|bela)|"
    r"(?:once|twice|thrice|\d+ times) (?:a|per) day|every \d+ hours|"
    r"খাবারের (?:আগে|পরে) খাবেন|(?:before|after) meals?|"
    r"(?:[\d০-৯]|দুই|তিন)\s*(?:টা|ta)\s*(?:খান|khan|khaben|খাবেন)",
    re.I)

# a diagnosis: telling the user what they have / probably have
_COND_BN = (r"ডায়াবেটিস|ডায়াবেটিস|জ্বর|ডেঙ্গু|টাইফয়েড|টাইফয়েড|গ্যাস্ট্রিক|আলসার|"
            r"হাই প্রেশার|প্রেশার|ইনফেকশন|সংক্রমণ|মাইগ্রেন|অ্যাজমা|হাঁপানি|রক্তশূন্যতা|জন্ডিস|"
            r"নিউমোনিয়া|নিউমোনিয়া|ক্যান্সার|ক্যানসার|ডিপ্রেশন|বিষণ্ণতা|চর্মরোগ|রোগ|অসুখ|ভাইরাস|সুগার|"
            r"হার্টের সমস্যা|কিডনির সমস্যা")
_COND_EN = (r"diabetes|hypertension|high blood pressure|an? infection|infection|the flu|flu|dengue|"
            r"typhoid|covid|gastritis|gastric|an? ulcer|ulcer|migraine|asthma|anemia|anaemia|"
            r"depression|anxiety disorder|cancer|pneumonia|jaundice|a fever|fever|[a-z]+itis|"
            r"(?:a |an )?[a-z]+ (?:disease|disorder|syndrome)")
_COND_BL = (r"dengue|typhoid|gastric|jor|jondis|jaundice|diabetes|sugar|pressure|infection|"
            r"ulcer|migraine|asthma|cancer|depression|rog|oshukh")
_DIAG_RX = re.compile(
    r"আপনার\s+(?:[^\s।.!?]{1,15}\s+)?(?:%s)\s*(?:হয়েছে|হয়েছে|আছে|হতে পারে|বলে মনে হচ্ছে|মনে হচ্ছে)|"
    r"(?:সম্ভবত|মনে হচ্ছে|এটা|এটি)\s+(?:[^\s।.!?]{1,15}\s+)?(?:%s)(?:\s|$|[।.!?])|"
    r"you(?:'ve| have| probably have| may have| might have| likely have| seem to have| could have)"
    r" (?:got )?(?:%s)\b|"
    r"(?:it|this|that)(?:'s| is| sounds like| looks like| could be| might be| seems like| is probably)"
    r" (?:%s)\b|"
    r"apnar\s+(?:\w+\s+)?(?:%s)\s+(?:hoyeche|hoise|hoyse|ache|ase|hote pare)|"
    r"(?:%s)\s+(?:hoyeche|hoise|hoyse|hote pare)" % (_COND_BN, _COND_BN, _COND_EN, _COND_EN,
                                                      _COND_BL, _COND_BL),
    re.I)

# a therapy / treatment instruction
_THERAPY_RX = re.compile(
    r"physiotherapy|chemotherapy|psychotherapy|\btherapy\b|\bcbt\b|counsel?ling sessions?|"
    r"treatment plan|start taking|stop taking|course of (?:antibiotics?|medicine|treatment)|"
    r"(?:take|get|give) (?:an |the |a )?injections?|nebuli[sz]e|"
    r"থেরাপি|ফিজিওথেরাপি|কেমো|চিকিৎসা (?:নিন|শুরু করুন)|ইনজেকশন|ইনহেলার নিন|নেবুলাইজ|"
    r"সেবন করুন|"
    r"oshudh (?:khan|khaben|nin)|osudh khan|medicine (?:khan|khaben|nin)",
    re.I)

# what the user themself wrote (quoted in a tool summary) is not advice
_QUOTED = re.compile(r"“[^”]*”|\"[^\"]*\"")


_SPLIT = re.compile(r"(?<=[.!?।\n])\s*")


def advice_hits(text):
    """Every piece of medical advice found in `text` (empty list = clean)."""
    t = _QUOTED.sub(" ", text or "")
    hits = list(G.medical_claims(t))
    for rx in (_MED_RX, _DOSE_RX, _DIAG_RX, _THERAPY_RX):
        m = rx.search(t)
        if m:
            hits.append(m.group(0))
    return hits


def filter_answer(text, topic="", lang="bn"):
    """-> (clean_text, removed_sentence_count). Drops every sentence with a
    diagnosis, a medicine/dose or a therapy; appends the doctor/999 line once
    for the health topic or when anything was removed."""
    text = text or ""
    lang = "en" if lang == "en" else "bn"
    kept, removed = [], 0
    for s in _SPLIT.split(text):
        if not s.strip():
            continue
        if advice_hits(s):
            removed += 1
            continue
        kept.append(s.strip())
    out = " ".join(kept).strip() if removed else text.strip()
    line = DOCTOR_999_LINE[lang]
    if (topic == "health" or removed) and line not in out:
        if removed and not out:
            out = ("আমি রোগ নির্ণয়, ওষুধ, ডোজ বা চিকিৎসার পরামর্শ দিই না।" if lang == "bn" else
                   "I do not give diagnoses, medicines, doses or treatment advice.")
        out = (out + ("\n\n" if out else "") + line).strip()
    return out, removed
