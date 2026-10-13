"""
Name / trademark research helper for "Assisto" (launch gap D). This is a
CHECKLIST + findings surface, NOT legal clearance. It produces the structured
data behind the in-app "About the name" note; the full research write-up lives
in owner_actions/name_check.md.

We never claim the name is cleared or available — only list what the owner must
check and record what research has (and hasn't) been done.
"""
from .i18n import pick

APP_NAME = "Assisto"

# Nice/trademark classes most relevant to a software assistant app.
RELEVANT_CLASSES = [
    {"class": 9, "note_bn": "সফটওয়্যার, মোবাইল অ্যাপ, ডাউনলোডযোগ্য প্রোগ্রাম",
     "note_en": "Software, mobile apps, downloadable programs"},
    {"class": 42, "note_bn": "SaaS, সফটওয়্যার ডিজাইন ও ডেভেলপমেন্ট",
     "note_en": "SaaS, software design and development"},
    {"class": 38, "note_bn": "টেলিযোগাযোগ / মেসেজিং পরিষেবা (যদি প্রযোজ্য)",
     "note_en": "Telecom / messaging services (if applicable)"},
    {"class": 35, "note_bn": "ব্যবসা সহায়তা (CRM/বিজনেস মোড অংশের জন্য)",
     "note_en": "Business assistance (for the CRM/Business-mode part)"},
]


def checklist(lang="bn"):
    """Ordered research steps the OWNER must complete. Each item is advisory."""
    items = [
        pick(lang,
             "BD DPDT (শিল্প নকশা ও পেটেন্ট অধিদপ্তর) ট্রেডমার্ক ডাটাবেসে 'Assisto' সার্চ করুন।",
             "Search 'Assisto' in the BD DPDT (trademark) database."),
        pick(lang,
             "প্রাসঙ্গিক Nice ক্লাসে (9, 42, 35, 38) আলাদাভাবে সার্চ করুন।",
             "Search separately within the relevant Nice classes (9, 42, 35, 38)."),
        pick(lang,
             "Global: WIPO Global Brand Database ও USPTO/EUIPO-তে সার্চ করুন।",
             "Global: search WIPO Global Brand Database and USPTO/EUIPO."),
        pick(lang,
             "Google Play ও Apple App Store-এ 'Assisto' নামের অ্যাপ কলিশন দেখুন।",
             "Check Google Play and Apple App Store for 'Assisto' app-name collisions."),
        pick(lang,
             "ডোমেইন ও সোশ্যাল হ্যান্ডেল (assisto.*) পাওয়া যায় কিনা দেখুন।",
             "Check domain and social handle availability (assisto.*)."),
        pick(lang,
             "একজন ট্রেডমার্ক আইনজীবীর সাথে ফাইলিংয়ের আগে পরামর্শ করুন।",
             "Consult a trademark attorney before filing."),
    ]
    return items


def disclaimer(lang="bn"):
    return pick(
        lang,
        "এটি একটি গবেষণা চেকলিস্ট মাত্র—আইনি ছাড়পত্র নয়। নাম চূড়ান্ত করার আগে "
        "মালিককে উপরের ধাপগুলো সম্পন্ন করতে হবে এবং আইনজীবীর পরামর্শ নিতে হবে।",
        "This is a research checklist only — not legal clearance. The owner must "
        "complete the steps above and consult an attorney before finalising the name.")


def about_the_name(lang="bn"):
    """Structured payload for the in-app 'About the name' note."""
    return {
        "name": APP_NAME,
        "meaning": pick(lang,
                        "'Assisto' অর্থ সহায়তা করা—অ্যাপের উদ্দেশ্যকেই তুলে ধরে।",
                        "'Assisto' means to assist — reflecting the app's purpose."),
        "classes": [{"class": c["class"], "note": pick(lang, c["note_bn"], c["note_en"])}
                    for c in RELEVANT_CLASSES],
        "checklist": checklist(lang),
        "status": pick(lang, "গবেষণা চলমান—ছাড়পত্র দাবি করা হয়নি।",
                       "Research pending — no clearance claimed."),
        "disclaimer": disclaimer(lang),
    }
