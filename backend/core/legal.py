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

LAST_UPDATED = "2026-10-22"

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
             "অ্যাকাউন্ট তথ্য (নাম, ফোন/ইমেইল), এবং সম্মতি থাকলে ব্যবহারের "
             "বেনামি পরিসংখ্যান।",
             "Information you add yourself (expenses, reminders, notes, family "
             "details), account info (name, phone/email), and — only with your "
             "consent — anonymous usage statistics."),
        _sec(lang, "আমরা কী করি না", "What we do NOT do",
             "আপনার ডেটা বিক্রি করি না, আপনার তথ্য দিয়ে বিজ্ঞাপনের প্রোফাইল "
             "বানাই না, এবং পরিসংখ্যান ইভেন্টে কোনো নাম/ফোন/ইমেইল রাখি না।",
             "We do not sell your data, we build no advertising profile from "
             "it, and we store no name/phone/email in an analytics event."),
        _sec(lang, "বিজ্ঞাপন", "Ads",
             "চালু হলে শুধু ফ্রি প্ল্যানে Google AdMob-এর নন-পার্সোনালাইজড "
             "বিজ্ঞাপন; SOS, নিরাপত্তা, পেমেন্ট, লগইন বা কলের স্ক্রিনে কখনো নয়। "
             "Google-এর SDK বিজ্ঞাপন আইডি, IP ও ডিভাইস তথ্য সংগ্রহ করে।",
             "When switched on: Google AdMob non-personalised ads on the Free "
             "plan only; never on SOS, safety, payment, sign-in or call screens. "
             "Google's SDK collects the Advertising ID, IP and device info."),
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
             "ডেটা বিক্রি হয় না। বিজ্ঞাপন চালু হলে Google AdMob ডিভাইস আইডি ও "
             "বিজ্ঞাপনের তথ্য পায় (শুধু নন-পার্সোনালাইজড বিজ্ঞাপন)।",
             "Data is never sold. When ads are on, Google AdMob receives the "
             "device ID and ad interaction data (non-personalised ads only)."),
        _sec(lang, "বিজ্ঞাপন", "Ads",
             "শুধু ফ্রি প্ল্যানে, নন-পার্সোনালাইজড (Google AdMob)।",
             "Free plan only, non-personalised (Google AdMob)."),
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
    return {
        "key": key,
        "title": title,
        "draft": True,
        "stamp": _stamp(lang),
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
