"""
Govt-service + religious guides (feature 30). Original, factual, bilingual
summaries of public processes — not copied from any source. Steps are general
guidance; the app links users to the official portal to confirm current rules.
"""

from ..i18n import localise

GOVT_SERVICES = [
    {"key": "nid", "name_bn": "NID (জাতীয় পরিচয়পত্র)", "name_en": "National ID",
     "portal": "services.nidw.gov.bd",
     "steps_bn": ["অনলাইনে রেজিস্টার/লগইন", "ফর্ম পূরণ + ছবি/তথ্য", "ফি পরিশোধ",
                  "সংশোধন হলে কাগজ আপলোড", "স্ট্যাটাস ট্র্যাক করুন"],
     "steps_en": ["Register / log in online", "Fill the form + photo/details", "Pay the fee",
                  "Upload documents if correcting", "Track your status"]},
    {"key": "passport", "name_bn": "ই-পাসপোর্ট", "name_en": "e-Passport",
     "portal": "epassport.gov.bd",
     "steps_bn": ["অনলাইন আবেদন", "ফি পরিশোধ (ব্যাংক/অনলাইন)", "বায়োমেট্রিক অ্যাপয়েন্টমেন্ট",
                  "পুলিশ ভেরিফিকেশন", "ডেলিভারি ট্র্যাক"],
     "steps_en": ["Apply online", "Pay the fee (bank / online)", "Biometric appointment",
                  "Police verification", "Track delivery"]},
    {"key": "birth", "name_bn": "জন্ম নিবন্ধন", "name_en": "Birth registration",
     "portal": "bdris.gov.bd",
     "steps_bn": ["অনলাইন আবেদন", "প্রয়োজনীয় কাগজ আপলোড", "ইউনিয়ন/সিটি অফিসে যাচাই"],
     "steps_en": ["Apply online", "Upload the required documents",
                  "Verification at the union / city office"]},
    {"key": "tin", "name_bn": "TIN / আয়কর", "name_en": "TIN / income tax",
     "portal": "etaxnbr.gov.bd",
     "steps_bn": ["eTIN রেজিস্ট্রেশন", "রিটার্ন ফর্ম পূরণ", "অনলাইনে জমা"],
     "steps_en": ["eTIN registration", "Fill the return form", "Submit online"]},
    {"key": "driving", "name_bn": "ড্রাইভিং লাইসেন্স", "name_en": "Driving licence",
     "portal": "bsp.brta.gov.bd",
     "steps_bn": ["লার্নার আবেদন", "ফি + মেডিকেল", "পরীক্ষা", "স্মার্ট কার্ড সংগ্রহ"],
     "steps_en": ["Learner's application", "Fee + medical", "Examination",
                  "Collect the smart card"]},
    {"key": "utility", "name_bn": "ইউটিলিটি বিল (বিদ্যুৎ/গ্যাস/পানি)",
     "name_en": "Utility bills (electricity / gas / water)", "portal": "ekpay / bKash / Nagad",
     "steps_bn": ["অ্যাকাউন্ট/মিটার নম্বর রাখুন", "অনলাইনে/MFS-এ পরিশোধ",
                  "শেষ তারিখের আগে — Assisto মনে করিয়ে দেবে"],
     "steps_en": ["Keep your account / meter number handy", "Pay online or via MFS",
                  "Before the due date — Assisto will remind you"]},
]

# Original, brief reminders (user toggles these). Not scripture text.
RELIGIOUS_TIPS = [
    {"key": "salah", "tip_bn": "নামাজের সময় মনে করিয়ে দিতে বললে রিমাইন্ডার সেট করি।",
     "tip_en": "Set prayer-time reminders on request."},
    {"key": "zakat", "tip_bn": "যাকাত হিসাব করতে Finance → যাকাত ব্যবহার করুন।",
     "tip_en": "Use Finance → Zakat to calculate zakat."},
    {"key": "ramadan", "tip_bn": "রমজানে সেহরি/ইফতার রিমাইন্ডার যোগ করা যায়।",
     "tip_en": "Add sehri / iftar reminders in Ramadan."},
    {"key": "charity", "tip_bn": "নিয়মিত দান একটি লক্ষ্য হিসেবে সেট করতে পারেন।",
     "tip_en": "Set regular charity as a savings goal."},
]


def localized(lang):
    """Return the guides content with user-facing fields localised to `lang`
    ('bn'|'en'). Keeps all other keys (key, portal) untouched.

    NOTE for integrator: core/views.py `govt_guide` currently returns the raw
    GOVT_SERVICES / RELIGIOUS_TIPS (no lang threaded). Update it to resolve the
    request language and return this instead, e.g.:
        from ..i18n import req_lang
        lang = req_lang(request)
        return Response(guides.localized(lang))

    NOTE for integrator: this flattens the response to single localised keys
    `name` / `steps` (services) and `tip` (religious). The current Flutter
    screen (app/lib/screens/guide_screen.dart) reads `name_en`/`name_bn`,
    `steps_bn` and the religious `en`/`bn` keys directly — update it to read the
    flattened `name` / `steps` / `tip`, OR keep returning the raw dicts if the
    app is meant to localise client-side. The raw GOVT_SERVICES / RELIGIOUS_TIPS
    are now fully bilingual either way (religious keys renamed bn/en -> tip_bn/
    tip_en; steps_en added).
    """
    return {
        "services": [localise(lang, s, "name", "steps") for s in GOVT_SERVICES],
        "religious": [localise(lang, t, "tip") for t in RELIGIOUS_TIPS],
    }
