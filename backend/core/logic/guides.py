"""
Govt-service + religious guides (feature 30). Original, factual, bilingual
summaries of public processes — not copied from any source. Steps are general
guidance; the app links users to the official portal to confirm current rules.
"""

GOVT_SERVICES = [
    {"key": "nid", "name_bn": "NID (জাতীয় পরিচয়পত্র)", "name_en": "National ID",
     "portal": "services.nidw.gov.bd",
     "steps_bn": ["অনলাইনে রেজিস্টার/লগইন", "ফর্ম পূরণ + ছবি/তথ্য", "ফি পরিশোধ",
                  "সংশোধন হলে কাগজ আপলোড", "স্ট্যাটাস ট্র্যাক করুন"]},
    {"key": "passport", "name_bn": "ই-পাসপোর্ট", "name_en": "e-Passport",
     "portal": "epassport.gov.bd",
     "steps_bn": ["অনলাইন আবেদন", "ফি পরিশোধ (ব্যাংক/অনলাইন)", "বায়োমেট্রিক অ্যাপয়েন্টমেন্ট",
                  "পুলিশ ভেরিফিকেশন", "ডেলিভারি ট্র্যাক"]},
    {"key": "birth", "name_bn": "জন্ম নিবন্ধন", "name_en": "Birth registration",
     "portal": "bdris.gov.bd",
     "steps_bn": ["অনলাইন আবেদন", "প্রয়োজনীয় কাগজ আপলোড", "ইউনিয়ন/সিটি অফিসে যাচাই"]},
    {"key": "tin", "name_bn": "TIN / আয়কর", "name_en": "TIN / income tax",
     "portal": "etaxnbr.gov.bd",
     "steps_bn": ["eTIN রেজিস্ট্রেশন", "রিটার্ন ফর্ম পূরণ", "অনলাইনে জমা"]},
    {"key": "driving", "name_bn": "ড্রাইভিং লাইসেন্স", "name_en": "Driving licence",
     "portal": "bsp.brta.gov.bd",
     "steps_bn": ["লার্নার আবেদন", "ফি + মেডিকেল", "পরীক্ষা", "স্মার্ট কার্ড সংগ্রহ"]},
    {"key": "utility", "name_bn": "ইউটিলিটি বিল (বিদ্যুৎ/গ্যাস/পানি)",
     "name_en": "Utility bills", "portal": "ekpay / bKash / Nagad",
     "steps_bn": ["অ্যাকাউন্ট/মিটার নম্বর রাখুন", "অনলাইনে/MFS-এ পরিশোধ",
                  "শেষ তারিখের আগে — Assisto মনে করিয়ে দেবে"]},
]

# Original, brief reminders (user toggles these). Not scripture text.
RELIGIOUS_TIPS = [
    {"key": "salah", "bn": "নামাজের সময় মনে করিয়ে দিতে বললে রিমাইন্ডার সেট করি।",
     "en": "Set prayer-time reminders on request."},
    {"key": "zakat", "bn": "যাকাত হিসাব করতে Finance → যাকাত ব্যবহার করুন।",
     "en": "Use Finance → Zakat to calculate zakat."},
    {"key": "ramadan", "bn": "রমজানে সেহরি/ইফতার রিমাইন্ডার যোগ করা যায়।",
     "en": "Add sehri/iftar reminders in Ramadan."},
    {"key": "charity", "bn": "নিয়মিত দান একটি লক্ষ্য হিসেবে সেট করতে পারেন।",
     "en": "Set regular charity as a savings goal."},
]
