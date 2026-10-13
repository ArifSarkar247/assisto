"""
Legal pages (launch gap C) — privacy policy, terms of service, health
disclaimer, and a Play data-safety summary. These are DRAFTS for the owner to
review with counsel; every page is stamped with a draft banner in both
languages. The app ships an in-app viewer only (web pages come later per the
platform order).

Nothing here is legal advice; the stamp makes that explicit in-product.
"""
from .i18n import pick

DRAFT_STAMP_BN = "খসড়া — মালিকের পর্যালোচনা প্রয়োজন"
DRAFT_STAMP_EN = "DRAFT — TO REVIEW BY OWNER"

# machine keys the app references; keep in lock-step with the Dart legal screen.
PAGES = ("privacy", "terms", "health_disclaimer", "data_safety")

LAST_UPDATED = "2026-10-13"


def _stamp(lang):
    return pick(lang, DRAFT_STAMP_BN, DRAFT_STAMP_EN)


def _privacy(lang):
    title = pick(lang, "গোপনীয়তা নীতি", "Privacy Policy")
    body = pick(
        lang,
        ("Assisto আপনার ব্যক্তিগত ডেটা আপনাকে সহায়তা করতেই ব্যবহার করে।\n\n"
         "আমরা কী সংগ্রহ করি: আপনি যে তথ্য নিজে যোগ করেন (খরচ, রিমাইন্ডার, "
         "নোট, পরিবারের তথ্য), অ্যাকাউন্ট তথ্য (নাম, ফোন/ইমেইল), এবং অ্যাপ "
         "ব্যবহারের বেনামি পরিসংখ্যান (আপনার সম্মতি থাকলে)।\n\n"
         "আমরা কী করি না: আমরা আপনার ডেটা বিক্রি করি না এবং তৃতীয় পক্ষের "
         "বিজ্ঞাপন ট্র্যাকার ব্যবহার করি না।\n\n"
         "পরিসংখ্যান: ব্যবহারের পরিসংখ্যান বেনামি—কোনো ফোন নম্বর, ইমেইল বা "
         "নাম ইভেন্টে রাখা হয় না, এবং আপনি এটি বন্ধ করতে পারেন।\n\n"
         "আপনার নিয়ন্ত্রণ: আপনি যেকোনো সময় আপনার ডেটা দেখতে, এক্সপোর্ট করতে "
         "বা অ্যাকাউন্ট মুছতে পারেন।\n\n"
         "যোগাযোগ: অ্যাপের সাপোর্ট থেকে আমাদের জানান।"),
        ("Assisto uses your personal data only to help you.\n\n"
         "What we collect: information you add yourself (expenses, reminders, "
         "notes, family details), account info (name, phone/email), and "
         "anonymous usage statistics (only if you consent).\n\n"
         "What we do NOT do: we do not sell your data and we use no "
         "third-party advertising trackers.\n\n"
         "Analytics: usage statistics are anonymous — no phone number, email "
         "or name is stored in an event, and you can turn it off.\n\n"
         "Your control: you can view, export or delete your data at any time.\n\n"
         "Contact: reach us from Support inside the app."),
    )
    return title, body


def _terms(lang):
    title = pick(lang, "ব্যবহারের শর্তাবলী", "Terms of Service")
    body = pick(
        lang,
        ("Assisto ব্যবহার করে আপনি এই শর্তাবলীতে সম্মত হচ্ছেন।\n\n"
         "পরিষেবা: Assisto একটি ব্যক্তিগত সহকারী অ্যাপ। আমরা যথাসাধ্য সঠিক "
         "তথ্য দেওয়ার চেষ্টা করি, তবে আর্থিক, আইনি বা চিকিৎসা সিদ্ধান্তের "
         "আগে পেশাদারের পরামর্শ নিন।\n\n"
         "আপনার দায়িত্ব: সঠিক তথ্য দেওয়া এবং অ্যাকাউন্ট নিরাপদ রাখা।\n\n"
         "গ্রহণযোগ্য ব্যবহার: বেআইনি কাজ বা অন্যের ক্ষতির জন্য অ্যাপ ব্যবহার "
         "করা যাবে না।\n\n"
         "দায়বদ্ধতা: পরিষেবাটি 'যেমন আছে' ভিত্তিতে দেওয়া হয়।"),
        ("By using Assisto you agree to these terms.\n\n"
         "The service: Assisto is a personal assistant app. We try to be "
         "accurate, but consult a professional before financial, legal or "
         "medical decisions.\n\n"
         "Your responsibilities: provide accurate information and keep your "
         "account secure.\n\n"
         "Acceptable use: do not use the app for unlawful activity or to harm "
         "others.\n\n"
         "Liability: the service is provided on an 'as is' basis."),
    )
    return title, body


def _health_disclaimer(lang):
    title = pick(lang, "স্বাস্থ্য সংক্রান্ত দাবিত্যাগ", "Health Disclaimer")
    body = pick(
        lang,
        ("Assisto-এর স্বাস্থ্য ও ওষুধ সংক্রান্ত ফিচার (রিমাইন্ডার, রেকর্ড) "
         "শুধুমাত্র সহায়ক তথ্যের জন্য—এটি চিকিৎসা পরামর্শ নয়।\n\n"
         "Assisto কোনো রোগ নির্ণয় করে না এবং চিকিৎসার পরামর্শ দেয় না।\n\n"
         "ওষুধ, ডোজ বা চিকিৎসা সংক্রান্ত সিদ্ধান্তের জন্য সর্বদা একজন "
         "যোগ্য চিকিৎসকের পরামর্শ নিন।\n\n"
         "জরুরি অবস্থায় দ্রুত নিকটস্থ স্বাস্থ্যসেবা বা জরুরি নম্বরে যোগাযোগ করুন।"),
        ("Assisto's health and medicine features (reminders, records) are for "
         "supportive information only — they are not medical advice.\n\n"
         "Assisto does not diagnose any condition or recommend treatment.\n\n"
         "Always consult a qualified doctor for decisions about medicines, "
         "doses or treatment.\n\n"
         "In an emergency, contact nearby healthcare or an emergency number "
         "immediately."),
    )
    return title, body


def _data_safety(lang):
    """A plain-language summary matching the Play Console Data safety form —
    so the owner can transcribe it accurately when filling the form."""
    title = pick(lang, "ডেটা নিরাপত্তা সারসংক্ষেপ (Play)",
                 "Data Safety Summary (Play)")
    body = pick(
        lang,
        ("Play Data Safety ফর্মের জন্য সারসংক্ষেপ:\n\n"
         "• সংগৃহীত ডেটা: অ্যাপ কার্যকারিতা ও অ্যাকাউন্টের জন্য ব্যবহারকারীর "
         "যোগ করা তথ্য ও অ্যাকাউন্ট তথ্য।\n"
         "• ভাগাভাগি: তৃতীয় পক্ষের সাথে বিক্রি/ভাগ করা হয় না।\n"
         "• বিজ্ঞাপন ট্র্যাকার: নেই।\n"
         "• এনক্রিপশন: ডেটা ট্রানজিটে এনক্রিপ্ট করা হয়।\n"
         "• মুছে ফেলা: ব্যবহারকারী ডেটা/অ্যাকাউন্ট মুছতে পারেন।\n"
         "• পরিসংখ্যান: বেনামি, সম্মতিভিত্তিক, কোনো PII নয়।"),
        ("Summary for the Play Data safety form:\n\n"
         "• Data collected: user-entered content and account info, for app "
         "functionality and account management.\n"
         "• Sharing: not sold or shared with third parties.\n"
         "• Ad trackers: none.\n"
         "• Encryption: data is encrypted in transit.\n"
         "• Deletion: users can delete their data/account.\n"
         "• Analytics: anonymous, consent-based, no PII."),
    )
    return title, body


_BUILDERS = {
    "privacy": _privacy,
    "terms": _terms,
    "health_disclaimer": _health_disclaimer,
    "data_safety": _data_safety,
}


def page(key, lang="bn"):
    """One legal page: title, draft stamp, body, last-updated. None if unknown."""
    b = _BUILDERS.get(key)
    if not b:
        return None
    title, body = b(lang)
    return {
        "key": key,
        "title": title,
        "draft": True,
        "stamp": _stamp(lang),
        "last_updated": LAST_UPDATED,
        "body": body,
    }


def index(lang="bn"):
    """List of pages for the in-app legal menu."""
    return [{"key": k, "title": page(k, lang)["title"], "stamp": _stamp(lang)}
            for k in PAGES]
