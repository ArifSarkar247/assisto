"""
Legal / policy centre (launch gap C → ADVANCED, SPEC v2.1 §21/§22).

A proper in-app legal centre: Privacy Policy, Terms of Service, Health
Disclaimer, Community Guidelines, Content Policy, Play Data-safety summary, an
18+ age note, a data-rights (export/delete) page, and a "what admins can see"
transparency page.

Every page is a DRAFT for the owner to review with counsel; each is stamped in
both languages (§22: never present unreviewed legal text as final). Pages are
returned as ordered SECTIONS ({heading, body}) so the app can render clear,
searchable, bilingual pages — plus a flat `body` for back-compat with the old
viewer. Each page carries a last-updated date and a contact line.

Section-22 mandatory disclaimers are centralised in MANDATORY_DISCLAIMERS and
surfaced on the relevant pages (not-medical-advice, not-legal-advice,
never-hold-money, data-rights) so they can be asserted by tests and can never be
silently dropped.

Nothing here is legal advice; the stamp makes that explicit in-product.
"""
from .i18n import pick

# §22 — the draft stamp. Never present unreviewed legal text as final.
DRAFT_STAMP_BN = "খসড়া — মালিক/আইনজীবী কর্তৃক পর্যালোচনা প্রয়োজন"
DRAFT_STAMP_EN = "DRAFT — to be reviewed by owner/lawyer"

# machine keys the app references; keep in lock-step with the Dart legal screen.
PAGES = (
    "privacy",
    "terms",
    "health_disclaimer",
    "community_guidelines",
    "content_policy",
    "data_safety",
    "age_note",
    "data_rights",
    "admin_transparency",
)

LAST_UPDATED = "2026-10-26"   # cctv1: CCTV watchman section

CONTACT_BN = "প্রশ্ন বা অনুরোধ: অ্যাপের ভেতরে সাপোর্ট থেকে আমাদের জানান।"
CONTACT_EN = "Questions or requests: reach us from Support inside the app."

# -------------------------------------------------------------------------
# §22 mandatory disclaimers — the four that MUST always be present. Each is a
# (key -> (bn, en)) pair; tests assert these exact lines appear on their pages.
# -------------------------------------------------------------------------
MANDATORY_DISCLAIMERS = {
    "not_medical_advice": (
        "এটি চিকিৎসা পরামর্শ নয় — Assisto কোনো রোগ নির্ণয় বা চিকিৎসার "
        "পরামর্শ দেয় না; সিদ্ধান্তের আগে যোগ্য চিকিৎসকের পরামর্শ নিন।",
        "This is NOT medical advice — Assisto does not diagnose any condition "
        "or recommend treatment; consult a qualified doctor before any decision.",
    ),
    "not_legal_advice": (
        "এটি আইনি পরামর্শ নয় — এখানে দেওয়া তথ্য শুধু সচেতনতার জন্য; "
        "আইনি সিদ্ধান্তের আগে একজন আইনজীবীর পরামর্শ নিন।",
        "This is NOT legal advice — the information here is for awareness only; "
        "consult a lawyer before any legal decision.",
    ),
    "never_hold_money": (
        "Assisto কখনোই আপনার টাকা রাখে না, স্থানান্তর করে না বা পরিশোধ "
        "প্রক্রিয়া করে না — এটি শুধু আপনার নিজের হিসাব লেখার একটি খাতা।",
        "Assisto NEVER holds, transfers or processes your money — it is only a "
        "ledger for recording your own accounts.",
    ),
    "data_rights": (
        "আপনার ডেটার অধিকার — আপনি যেকোনো সময় আপনার ডেটা দেখতে, এক্সপোর্ট "
        "করতে এবং অ্যাকাউন্টসহ স্থায়ীভাবে মুছতে পারেন।",
        "Your data rights — you can view, export and permanently delete your "
        "data (and account) at any time.",
    ),
}


def _disc(lang, key):
    bn, en = MANDATORY_DISCLAIMERS[key]
    return pick(lang, bn, en)


def _stamp(lang):
    return pick(lang, DRAFT_STAMP_BN, DRAFT_STAMP_EN)


# Owner 25 Oct: the in-app privacy summary was checked against what the app
# really collects and against lifeassisto.com/privacy -> no DRAFT stamp.
REVIEWED_PAGES = {"privacy"}


def _reviewed_line(lang):
    return pick(lang, "হালনাগাদ ২৫ অক্টোবর ২০২৬ · পুরো নীতি: lifeassisto.com/privacy",
                "Updated 25 Oct 2026 · Full policy: lifeassisto.com/privacy")


def _contact(lang):
    return pick(lang, CONTACT_BN, CONTACT_EN)


def _sec(lang, heading_bn, heading_en, body_bn, body_en):
    return {"heading": pick(lang, heading_bn, heading_en),
            "body": pick(lang, body_bn, body_en)}


# =========================================================================
# Page builders — each returns (title, [sections]). Sections are small so the
# app can show them as expandable/searchable blocks.
# =========================================================================
def _privacy(lang):
    title = pick(lang, "গোপনীয়তা নীতি", "Privacy Policy")
    sections = [
        _sec(lang, "সারকথা", "In short",
             "Assisto আপনার ব্যক্তিগত ডেটা শুধু আপনাকে সহায়তা করতেই ব্যবহার "
             "করে। আমরা ডেটা বিক্রি করি না। পুরো নীতি, প্রতিটি অনুমতির কারণসহ: "
             "lifeassisto.com/privacy",
             "Assisto uses your personal data only to help you. We do not sell "
             "your data. The full policy, with the reason for every permission: "
             "lifeassisto.com/privacy"),
        _sec(lang, "আমরা কী সংগ্রহ করি", "What we collect",
             "আপনি নিজে যোগ করা তথ্য (খরচ, রিমাইন্ডার, নোট, পরিবারের তথ্য), "
             "অ্যাকাউন্ট তথ্য (নাম, ফোন/ইমেইল), আর শুধু যে ফিচার আপনি ব্যবহার "
             "করেন তার জন্য: লোকেশন (SOS, Safe Journey, হারানো/চুরি সুরক্ষা), "
             "কন্টাক্ট (সার্কেলে পরিচিতদের খুঁজতে, আগে জানিয়ে), মাইক্রোফোন ও "
             "ক্যামেরা (ভয়েস, কল, ভয়েস নোট, ছবি), আপনার বাছাই করা ছবি (ফটো "
             "স্টুডিওতে আমাদের সার্ভারে প্রসেস হয়), Health Connect-এর হাঁটা/হার্ট "
             "রেট/ঘুম (শুধু পড়া)। My Circle-এর মেসেজ ও কল এন্ড-টু-এন্ড "
             "এনক্রিপ্টেড — সার্ভারে শুধু তালাবদ্ধ ডেটা আর সময়/প্রেরকের মতো "
             "তথ্য থাকে। নিরাপত্তা ও কল পৌঁছানোর জন্য ফোনের মডেল, Android "
             "সংস্করণ ও একটি লুকানো ইনস্টল-আইডি; সমস্যা ঠিক করতে ক্র্যাশ রিপোর্ট "
             "(কোনো মেসেজ বা ব্যক্তিগত লেখা নয়); সম্মতি থাকলে বেনামি পরিসংখ্যান।",
             "Information you add yourself (expenses, reminders, notes, family "
             "details), account info (name, phone/email), and only for the "
             "features you use: location (SOS, Safe Journey, Lost/Stolen "
             "protection), contacts (to find people for your circle, after an "
             "in-app notice), microphone and camera (voice, calls, voice notes, "
             "photos), photos you pick (processed on our server in Photo "
             "Studio), Health Connect steps/heart rate/sleep (read only). My "
             "Circle messages and calls are end-to-end encrypted — the server "
             "keeps only the encrypted data plus details such as time and "
             "sender. For security and call delivery: phone model, Android "
             "version and a hidden install ID; crash reports to fix bugs (no "
             "message or personal text); anonymous usage statistics only with "
             "your consent."),
        _sec(lang, "সিসিটিভি ওয়াচম্যান", "CCTV watchman",
             "বাড়ি বা দোকানের ক্যামেরা যুক্ত করলে ভিডিও আপনার গেটওয়েতেই "
             "(পুরনো ফোন, Shop Box বা কম্পিউটার) থাকে ও সেখানেই বিশ্লেষণ হয় — "
             "আমাদের সার্ভারে কখনো ভিডিও রাখা হয় না। সার্ভারে আসে শুধু ঘটনার "
             "ধরন, সময়, আত্মবিশ্বাস আর প্রতি ঘটনায় একটি ছোট ছবি (আপনার বেছে "
             "নেওয়া ০–৩০ দিন, ডিফল্ট ৩ দিন, তারপর মুছে যায়), আর জোন আঁকার "
             "জন্য একটি পরীক্ষার ছবি। ক্যামেরার পাসওয়ার্ড একবার গেটওয়েতে পৌঁছে "
             "দিয়ে সার্ভার থেকে মুছে ফেলা হয়। দেখেন শুধু আপনি ও আপনার যোগ করা "
             "পরিবারের সদস্য। মুখ চেনা নেই, শব্দ রেকর্ড নেই; লাইভ ভিউ সরাসরি "
             "আপনার ফোনে যায় ও রেকর্ড হয় না।",
             "If you connect cameras at your home or shop, the video stays on "
             "your gateway (an old phone, the Shop Box or a computer) and is "
             "analysed there — our server never keeps video. The server gets "
             "only the event type, time, confidence and one small photo per "
             "event (kept for the 0–30 days you choose, 3 by default, then "
             "deleted), plus one check photo for drawing zones. The camera "
             "password is handed to the gateway once and then deleted from the "
             "server. Only you and the family members you add can see it. No "
             "face recognition, no sound recording; live view goes straight to "
             "your phone and is never recorded."),
        _sec(lang, "আমরা কী করি না", "What we do NOT do",
             "আপনার ডেটা বিক্রি করি না, আপনার তথ্য দিয়ে বিজ্ঞাপনের প্রোফাইল "
             "বানাই না, এবং পরিসংখ্যান ইভেন্টে কোনো নাম/ফোন/ইমেইল রাখি না।",
             "We do not sell your data, we build no advertising profile from "
             "it, and we store no name/phone/email in an analytics event."),
        _sec(lang, "বিজ্ঞাপন", "Ads",
             "ফ্রি প্ল্যানে Google AdMob-এর বিজ্ঞাপন দেখানো হয়; প্রিমিয়াম ও বিজনেসে কোনো "
             "বিজ্ঞাপন নেই। বিজ্ঞাপন দেখাতে, সীমা রাখতে ও প্রতারণা ঠেকাতে Google-এর SDK "
             "ফোনের Advertising ID, IP ঠিকানা, ডিভাইস তথ্য ও বিজ্ঞাপন দেখা/ট্যাপের তথ্য "
             "Google-কে পাঠায়। ইউরোপ/যুক্তরাজ্য ও যুক্তরাষ্ট্রের যেসব রাজ্যে আইন চায়, "
             "সেখানে প্রথম বিজ্ঞাপনের আগে Google-এর সম্মতি ফর্ম (UMP) দেখানো হয়। "
             "ডিফল্টভাবে শুধু নন-পার্সোনালাইজড বিজ্ঞাপন; পার্সোনালাইজড বিজ্ঞাপন কখনো "
             "চালু হলেও শুধু আপনার সম্মতি থাকলে। SOS, নিরাপত্তা, চুরি-সুরক্ষা, পরিবারের "
             "সতর্কতা, কল, চ্যাট, পেমেন্ট, লগইন বা অনুমতির স্ক্রিনে কখনো বিজ্ঞাপন নেই। "
             "বন্ধ/বদল: Android সেটিংস → গোপনীয়তা → বিজ্ঞাপন → বিজ্ঞাপন আইডি মুছুন বা "
             "রিসেট করুন, অথবা অ্যাপের সেটিংস → \"বিজ্ঞাপনের গোপনীয়তা\" (যেখানে দেখায়)।",
             "The Free plan shows Google AdMob ads; Premium and Business have no "
             "ads. To show ads, cap them and prevent fraud, Google's SDK sends "
             "the phone's Advertising ID, IP address, device information and ad "
             "views/taps to Google. In the EEA/UK and in US states whose laws "
             "require it, Google's consent form (UMP) is shown before the first "
             "ad. Non-personalised ads by default; personalised ads, if ever "
             "switched on, only with your consent. Never any ad on SOS, safety, "
             "anti-theft, family alert, call, chat, payment, sign-in or "
             "permission screens. Opt out or change: Android Settings → Privacy "
             "→ Ads → delete or reset the Advertising ID, or the app's Settings "
             "→ \"Ad privacy choices\" (where shown)."),
        _sec(lang, "পরিসংখ্যান", "Analytics",
             "ব্যবহারের পরিসংখ্যান বেনামি ও সম্মতিভিত্তিক — আপনি সেটিংস থেকে "
             "যেকোনো সময় বন্ধ করতে পারেন।",
             "Usage statistics are anonymous and consent-based — you can turn "
             "them off at any time from Settings."),
        _sec(lang, "আপনার অধিকার", "Your rights",
             _disc(lang, "data_rights"),
             _disc(lang, "data_rights")),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _terms(lang):
    title = pick(lang, "ব্যবহারের শর্তাবলী", "Terms of Service")
    sections = [
        _sec(lang, "পরিষেবা", "The service",
             "Assisto একটি ব্যক্তিগত সহকারী অ্যাপ। আমরা যথাসাধ্য সঠিক তথ্য "
             "দেওয়ার চেষ্টা করি, তবে আর্থিক, আইনি বা চিকিৎসা সিদ্ধান্তের আগে "
             "পেশাদারের পরামর্শ নিন।",
             "Assisto is a personal assistant app. We try to be accurate, but "
             "consult a professional before financial, legal or medical "
             "decisions."),
        _sec(lang, "টাকা সম্পর্কে", "About money",
             _disc(lang, "never_hold_money"),
             _disc(lang, "never_hold_money")),
        _sec(lang, "আপনার দায়িত্ব", "Your responsibilities",
             "সঠিক তথ্য দেওয়া এবং আপনার অ্যাকাউন্ট নিরাপদ রাখা আপনার দায়িত্ব।",
             "You are responsible for providing accurate information and "
             "keeping your account secure."),
        _sec(lang, "গ্রহণযোগ্য ব্যবহার", "Acceptable use",
             "বেআইনি কাজ বা অন্যের ক্ষতির জন্য অ্যাপ ব্যবহার করা যাবে না। "
             "বিস্তারিত কমিউনিটি নির্দেশিকা দেখুন।",
             "Do not use the app for unlawful activity or to harm others. See "
             "the Community Guidelines for detail."),
        _sec(lang, "দায়বদ্ধতা", "Liability",
             "পরিষেবাটি 'যেমন আছে' ভিত্তিতে দেওয়া হয়।",
             "The service is provided on an 'as is' basis."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _health_disclaimer(lang):
    title = pick(lang, "স্বাস্থ্য সংক্রান্ত দাবিত্যাগ", "Health Disclaimer")
    sections = [
        _sec(lang, "গুরুত্বপূর্ণ", "Important",
             _disc(lang, "not_medical_advice"),
             _disc(lang, "not_medical_advice")),
        _sec(lang, "ফিচারগুলো কী", "What the features are",
             "Assisto-এর স্বাস্থ্য ও ওষুধ সংক্রান্ত ফিচার (রিমাইন্ডার, রেকর্ড) "
             "শুধুমাত্র সহায়ক তথ্যের জন্য।",
             "Assisto's health and medicine features (reminders, records) are "
             "for supportive information only."),
        _sec(lang, "সবসময় চিকিৎসকের পরামর্শ নিন", "Always consult a doctor",
             "ওষুধ, ডোজ বা চিকিৎসা সংক্রান্ত সিদ্ধান্তের জন্য সর্বদা একজন "
             "যোগ্য চিকিৎসকের পরামর্শ নিন।",
             "Always consult a qualified doctor for decisions about medicines, "
             "doses or treatment."),
        _sec(lang, "জরুরি অবস্থা", "Emergencies",
             "জরুরি অবস্থায় দ্রুত নিকটস্থ স্বাস্থ্যসেবা বা জরুরি নম্বরে "
             "যোগাযোগ করুন।",
             "In an emergency, contact nearby healthcare or an emergency number "
             "immediately."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _community_guidelines(lang):
    title = pick(lang, "কমিউনিটি নির্দেশিকা", "Community Guidelines")
    sections = [
        _sec(lang, "সম্মান", "Respect",
             "সবার সাথে সম্মানের সাথে আচরণ করুন। হয়রানি, ঘৃণা বা হুমকি বরদাস্ত "
             "করা হয় না।",
             "Treat everyone with respect. Harassment, hate and threats are not "
             "tolerated."),
        _sec(lang, "নিরাপত্তা", "Safety",
             "অন্যের ব্যক্তিগত তথ্য অনুমতি ছাড়া শেয়ার করবেন না; শিশুদের "
             "ঝুঁকিতে ফেলে এমন কিছু নিষিদ্ধ।",
             "Do not share others' personal information without consent; "
             "anything that endangers children is prohibited."),
        _sec(lang, "কোনো স্প্যাম নয়", "No spam or scams",
             "স্প্যাম, প্রতারণা বা বিভ্রান্তিকর প্রচার নিষিদ্ধ।",
             "Spam, scams and misleading promotion are prohibited."),
        _sec(lang, "প্রয়োগ", "Enforcement",
             "নিয়ম ভাঙলে কন্টেন্ট সরানো বা অ্যাকাউন্ট সীমিত করা হতে পারে। "
             "আপত্তিকর কিছু দেখলে রিপোর্ট করুন।",
             "Breaking the rules may lead to content removal or account limits. "
             "Report anything that breaks them."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _content_policy(lang):
    title = pick(lang, "কন্টেন্ট নীতি", "Content Policy")
    sections = [
        _sec(lang, "আপনার কন্টেন্ট আপনার", "Your content is yours",
             "আপনি যা তৈরি করেন তার মালিক আপনি। অ্যাপটি চালু রাখতে প্রয়োজনীয় "
             "সীমিত অনুমতি ছাড়া আমরা আপনার কন্টেন্টের মালিকানা নিই না।",
             "You own what you create. We take no ownership of your content "
             "beyond the limited permission needed to run the app for you."),
        _sec(lang, "নিষিদ্ধ কন্টেন্ট", "Prohibited content",
             "বেআইনি, সহিংস, ঘৃণাত্মক, যৌন নিপীড়নমূলক বা শিশুদের ক্ষতিকর "
             "কন্টেন্ট নিষিদ্ধ।",
             "Illegal, violent, hateful, sexually abusive, or child-harming "
             "content is prohibited."),
        _sec(lang, "রিপোর্ট ও অপসারণ", "Reporting and removal",
             "নীতিভঙ্গকারী কন্টেন্ট রিপোর্ট করা যায় এবং তা সরানো হতে পারে।",
             "Content that breaks this policy can be reported and may be "
             "removed."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _data_safety(lang):
    """A plain-language summary matching the Play Console Data safety form —
    so the owner can transcribe it accurately when filling the form."""
    title = pick(lang, "ডেটা নিরাপত্তা সারসংক্ষেপ (Play)",
                 "Data Safety Summary (Play)")
    sections = [
        _sec(lang, "সংগৃহীত ডেটা", "Data collected",
             "অ্যাপ কার্যকারিতা ও অ্যাকাউন্টের জন্য ব্যবহারকারীর যোগ করা তথ্য "
             "ও অ্যাকাউন্ট তথ্য।",
             "User-entered content and account info, for app functionality and "
             "account management."),
        _sec(lang, "ভাগাভাগি", "Sharing",
             "ডেটা বিক্রি হয় না। ফ্রি প্ল্যানে Google AdMob বিজ্ঞাপনের জন্য ডিভাইসের "
             "Advertising ID ও বিজ্ঞাপন দেখা/ট্যাপের তথ্য পায়।",
             "Data is never sold. On the Free plan, Google AdMob receives the "
             "device Advertising ID and ad interaction data, for advertising."),
        _sec(lang, "বিজ্ঞাপন", "Ads",
             "শুধু ফ্রি প্ল্যানে (Google AdMob); ডিফল্টভাবে নন-পার্সোনালাইজড, "
             "সম্মতি ফর্ম Google UMP। নিরাপত্তা, কল, চ্যাট, পেমেন্ট ও লগইনের "
             "স্ক্রিনে কখনো নয়।",
             "Free plan only (Google AdMob); non-personalised by default, "
             "consent via Google UMP. Never on safety, call, chat, payment or "
             "sign-in screens."),
        _sec(lang, "এনক্রিপশন", "Encryption",
             "ডেটা ট্রানজিটে এনক্রিপ্ট করা হয়।",
             "Data is encrypted in transit."),
        _sec(lang, "মুছে ফেলা", "Deletion",
             "ব্যবহারকারী ডেটা/অ্যাকাউন্ট মুছতে পারেন।",
             "Users can delete their data/account."),
        _sec(lang, "পরিসংখ্যান", "Analytics",
             "বেনামি, সম্মতিভিত্তিক, কোনো PII নয়।",
             "Anonymous, consent-based, no PII."),
    ]
    return title, sections


def _age_note(lang):
    title = pick(lang, "বয়স (১৮+) নোট", "Age (18+) note")
    sections = [
        _sec(lang, "১৮+", "18+",
             "Assisto ১৮ বছর বা তার বেশি বয়সীদের জন্য। আপনি নিশ্চিত করছেন যে "
             "আপনার বয়স ১৮ বছরের বেশি।",
             "Assisto is intended for people aged 18 or older. By using it you "
             "confirm you are over 18."),
        _sec(lang, "অভিভাবক", "Guardians",
             "অপ্রাপ্তবয়স্ক কারও পক্ষে অ্যাপ ব্যবহার করলে একজন প্রাপ্তবয়স্ক "
             "অভিভাবকের তত্ত্বাবধানে করুন।",
             "If used on behalf of a minor, do so under the supervision of an "
             "adult guardian."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _data_rights(lang):
    title = pick(lang, "আপনার ডেটার অধিকার", "Your data rights")
    sections = [
        _sec(lang, "সারকথা", "In short",
             _disc(lang, "data_rights"),
             _disc(lang, "data_rights")),
        _sec(lang, "দেখুন", "View",
             "আপনার সংরক্ষিত সমস্ত তথ্য অ্যাপের ভেতর থেকে যেকোনো সময় দেখতে "
             "পারেন।",
             "You can view all your stored information from inside the app at "
             "any time."),
        _sec(lang, "এক্সপোর্ট", "Export",
             "সেটিংস থেকে আপনার ডেটার একটি কপি ডাউনলোড/এক্সপোর্ট করতে পারেন।",
             "From Settings you can download/export a copy of your data."),
        _sec(lang, "মুছে ফেলা", "Delete",
             "আপনি অ্যাকাউন্টসহ আপনার ডেটা স্থায়ীভাবে মুছতে পারেন। মুছে ফেলা "
             "অপরিবর্তনীয়।",
             "You can permanently delete your data, including your account. "
             "Deletion is irreversible."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


def _admin_transparency(lang):
    title = pick(lang, "অ্যাডমিন কী দেখতে পারে", "What admins can see")
    sections = [
        _sec(lang, "স্বচ্ছতা", "Transparency",
             "আমরা খোলাখুলি জানাই অ্যাপের পরিচালকরা কী দেখতে পারেন এবং কী "
             "পারেন না।",
             "We are open about what the app's operators can and cannot see."),
        _sec(lang, "যা অ্যাডমিন সাধারণত দেখেন না", "What admins normally cannot see",
             "আপনার ব্যক্তিগত নোট, খরচ, রিমাইন্ডার ও বার্তার বিষয়বস্তু "
             "স্বাভাবিকভাবে অ্যাডমিন পড়েন না।",
             "Admins normally do not read the contents of your private notes, "
             "expenses, reminders and messages."),
        _sec(lang, "যা অ্যাডমিন দেখতে পারেন", "What admins can see",
             "অ্যাকাউন্ট তথ্য, সীমিত টেকনিক্যাল লগ, এবং আইন বা নিরাপত্তার "
             "প্রয়োজনে সীমিত ক্ষেত্রে রিপোর্ট করা কন্টেন্ট।",
             "Account info, limited technical logs, and — in limited cases "
             "required by law or safety — reported content."),
        _sec(lang, "লগ", "Audit logs",
             "সংবেদনশীল পদক্ষেপ অডিট লগে রাখা হয় যাতে অপব্যবহার শনাক্ত করা যায়।",
             "Sensitive actions are kept in an audit log so misuse can be "
             "detected."),
        _sec(lang, "যোগাযোগ", "Contact", _contact(lang), _contact(lang)),
    ]
    return title, sections


_BUILDERS = {
    "privacy": _privacy,
    "terms": _terms,
    "health_disclaimer": _health_disclaimer,
    "community_guidelines": _community_guidelines,
    "content_policy": _content_policy,
    "data_safety": _data_safety,
    "age_note": _age_note,
    "data_rights": _data_rights,
    "admin_transparency": _admin_transparency,
}


def _flatten(sections):
    """Back-compat flat body (old viewer) from structured sections."""
    return "\n\n".join(f"{s['heading']}\n{s['body']}" for s in sections)


def page(key, lang="bn"):
    """One legal page. Returns title, draft stamp, ordered sections, a flat
    body (back-compat), last-updated and a contact line. None if unknown."""
    b = _BUILDERS.get(key)
    if not b:
        return None
    title, sections = b(lang)
    reviewed = key in REVIEWED_PAGES
    return {
        "key": key,
        "title": title,
        "draft": not reviewed,
        "stamp": _reviewed_line(lang) if reviewed else _stamp(lang),
        "last_updated": LAST_UPDATED,
        "sections": sections,
        "body": _flatten(sections),
        "contact": _contact(lang),
        # l1-launch: the full public page on lifeassisto.com (None = in-app only)
        "web_url": web_url(key, lang),
    }


# l1-launch — public web versions (backend/web/views_legal.py)
WEB_PAGES = {"privacy": "/privacy", "terms": "/terms", "data_safety": "/privacy",
             "data_rights": "/delete-account"}


def web_url(key, lang="bn"):
    from django.conf import settings
    path = WEB_PAGES.get(key)
    if not path:
        return None
    site = getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")
    return site + path + ("?lang=en" if lang == "en" else "")


def index(lang="bn"):
    """List of pages for the in-app legal menu (key, title, stamp)."""
    return [{"key": k, "title": page(k, lang)["title"], "stamp": _stamp(lang)}
            for k in PAGES]
