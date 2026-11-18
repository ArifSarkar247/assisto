"""preview-testers: "where in the app" for every feature that is hidden by
default (owner 17 Nov "tell me where each feature is in the app so I can
find it"). Exact taps as of app build 10374 (commit 25f02670), traced from
app/lib (widgets/sidebar_sections.dart, the hub screens). Shown in Owner Admin
→ Features under each feature, and used by owner_actions/SWITCHES_STATUS_BN.md.
Update a line whenever a screen moves. key -> (English, Bangla)."""

NO_ENTRY_EN = "No screen in app build 10374 (nothing appears when switched on)."
NO_ENTRY_BN = "অ্যাপ বিল্ড ১০৩৭৪-এ কোনো পাতা নেই (চালু করলেও কিছু দেখা যাবে না)।"

WHERE = {
    "budget_remittance": (
        "Menu ☰ → Account & Finance → Budget and Remittance (replaces plain Budget)",
        "মেনু ☰ → হিসাব ও অর্থ → বাজেট ও রেমিট্যান্স (সাধারণ \"বাজেট\"-এর জায়গায়)"),
    "fall_detect": (
        "Menu ☰ → Family & Safety → Emergency → \"Accident / fall detection\" tile",
        "মেনু ☰ → পরিবার ও নিরাপত্তা → জরুরি → \"দুর্ঘটনা/পতন শনাক্তকরণ\" টাইল"),
    "guard_box_mode": (
        "Menu ☰ → Family & Safety → CCTV watch → Smart Cash Guard → \"Guard Box (old phone)\" card; "
        "also CCTV watch → Use this phone as a camera → \"Watch a Wi-Fi IP camera with this phone\"",
        "মেনু ☰ → পরিবার ও নিরাপত্তা → CCTV পাহারা → স্মার্ট ক্যাশ গার্ড → \"গার্ড বক্স (পুরনো ফোন)\" কার্ড; "
        "আরও: CCTV পাহারা → এই ফোনকে ক্যামেরা বানান → \"এই ফোন দিয়ে ওয়াই-ফাই আইপি ক্যামেরা দেখুন\""),
    "kids_watch": (
        "Menu ☰ → Kids → Kids watch & School Mode",
        "মেনু ☰ → শিশু → বাচ্চাদের ঘড়ি ও স্কুল-মোড"),
    "missing_alert": (
        "Menu ☰ → Kids → Missing person alert; also Emergency → \"Missing person alert\" tile",
        "মেনু ☰ → শিশু → নিখোঁজ সতর্কতা; আরও: জরুরি → \"নিখোঁজ ব্যক্তির সতর্কতা\" টাইল"),
    "blood_donors": (
        "Menu ☰ → Health → Blood donor; also Emergency → \"Blood needed\"; Settings → \"I am a blood donor\"",
        "মেনু ☰ → স্বাস্থ্য → রক্তদাতা; আরও: জরুরি → \"রক্ত দরকার\"; সেটিংস → \"আমি রক্তদাতা\""),
    "train_tracker": (
        "Menu ☰ → Travel & city → Train Tracker; or Family & Safety → Safe Journey → Train Tracker card",
        "মেনু ☰ → যাতায়াত ও শহর → ট্রেন ট্র্যাকার; বা পরিবার ও নিরাপত্তা → নিরাপদ যাত্রা → ট্রেন ট্র্যাকার কার্ড"),
    "dest_alarm": (
        "Menu ☰ → Travel & city → Destination Alarm; or Safe Journey → Destination Alarm card",
        "মেনু ☰ → যাতায়াত ও শহর → গন্তব্য অ্যালার্ম; বা নিরাপদ যাত্রা → গন্তব্য অ্যালার্ম কার্ড"),
    "trip_recorder": (
        "Destination Alarm screen → top-bar icon \"Trip recorder (owner only)\" — owner tool",
        "গন্তব্য অ্যালার্ম পাতা → ওপরের আইকন \"ট্রিপ রেকর্ডার (শুধু মালিক)\" — মালিকের টুল"),
    "train_schedule_verified": (
        "No screen of its own: when on, train times stop showing \"schedule not verified yet\" "
        "(you verify times in Owner Admin → Train schedule).",
        "নিজের পাতা নেই: চালু হলে ট্রেনের সময়ে \"সময়সূচি যাচাই বাকি\" লেখা আর থাকে না "
        "(সময় যাচাই করবেন মালিকের প্যানেল → ট্রেনের সময়সূচি-তে)।"),
    "child_emergency_audio": (
        "Menu ☰ → Kids → Child emergency audio (on the child's phone it also enables listening for the parent's request)",
        "মেনু ☰ → শিশু → শিশুর জরুরি অডিও (শিশুর ফোনে বাবা-মায়ের অনুরোধ শোনার ব্যবস্থাও চালু হয়)"),
    "nearby_sponsored": (
        "Menu ☰ → Travel & city → Nearby → pick a category → \"Sponsored\" rows above the results (only when an approved sponsor exists)",
        "মেনু ☰ → যাতায়াত ও শহর → কাছেপিঠে → একটি ধরন বাছুন → ফলের ওপরে “স্পনসর” সারি (অনুমোদিত স্পনসর থাকলে)"),
    "quran": (
        "Menu ☰ → Faith → Quran",
        "মেনু ☰ → ইবাদত → কুরআন"),
    "quran_learn": (
        "Menu ☰ → Faith → Learn to read Quran",
        "মেনু ☰ → ইবাদত → কুরআন পড়া শিখি"),
    "vehicle_engine_cut": (
        "Menu ☰ → Home & life → My Vehicles → Live tracking → a tracker → \"Cut engine\" button "
        "(stopped vehicle only, two confirmations, every command logged)",
        "মেনু ☰ → ঘর ও জীবন → আমার গাড়ি → লাইভ ট্র্যাকিং → একটি ট্র্যাকার → \"ইঞ্জিন বন্ধ করুন\" বোতাম "
        "(শুধু থামা গাড়ি, দুইবার নিশ্চিত, প্রতিটি আদেশ লগে)"),
    "official_corners": (
        "Menu ☰ → Home & life → Probashi corner → \"Help\" tab; Jobs & learning → Student corner → \"Study timer\" and \"Official dates\" tabs",
        "মেনু ☰ → ঘর ও জীবন → প্রবাসী কর্নার → \"সহায়তা\" ট্যাব; চাকরি ও শেখা → স্টুডেন্ট কর্নার → \"পড়ার টাইমার\" ও \"অফিশিয়াল তারিখ\" ট্যাব"),
    "food_calories": (
        "Menu ☰ → Health → Food calories",
        "মেনু ☰ → স্বাস্থ্য → খাবারের ক্যালরি"),
    "language_packs": (
        "Menu ☰ → Home & life → Probashi corner → Clock tab → \"Learn the language for work abroad\" card",
        "মেনু ☰ → ঘর ও জীবন → প্রবাসী কর্নার → সময় ট্যাব → \"বিদেশে কাজের ভাষা শিখুন\" কার্ড"),
    "learning_certificate": (
        "Menu ☰ → Jobs & learning → My certificates; also a certificate button after finishing a course",
        "মেনু ☰ → চাকরি ও শেখা → আমার সনদ; আরও: কোর্স শেষ হলে সনদের বোতাম"),
    "area_community": (
        "Not visible in build 10374 even when on (a build constant keeps it off: posts are not shared yet).",
        "বিল্ড ১০৩৭৪-এ চালু করলেও দেখা যাবে না (বিল্ডের ভেতরের একটি সেটিং বন্ধ রাখে: পোস্ট এখনো অন্যদের কাছে যায় না)।"),
    "daily_tools": (
        "Menu ☰ → Tools → Daily tools; also Work → Quick tools → calculator icon",
        "মেনু ☰ → টুলস → দৈনন্দিন টুল; আরও: কাজ → কুইক টুলস → ক্যালকুলেটর আইকন"),
    "agent_studio": (
        "Not visible in build 10374 even when on (a build constant keeps it off: automations do not run).",
        "বিল্ড ১০৩৭৪-এ চালু করলেও দেখা যাবে না (বিল্ডের ভেতরের একটি সেটিং বন্ধ রাখে: অটোমেশন চলে না)।"),
    "agent_core": (
        "Menu ☰ → Work → Assisto Agent",
        "মেনু ☰ → কাজ → Assisto এজেন্ট"),
    "career_plus": (
        "Menu ☰ → Jobs & learning → Job hunter (find-jobs card), CV Builder (career bar), Mock interview (\"Practice for a job role\")",
        "মেনু ☰ → চাকরি ও শেখা → জব হান্টার (চাকরি খোঁজার কার্ড), সিভি বিল্ডার (ক্যারিয়ার বার), মক ইন্টারভিউ (\"পদ ধরে অনুশীলন\")"),
    "ps_secretary": (
        "Menu ☰ → Work → Personal Secretary (PS) → top row \"Today's brief\"",
        "মেনু ☰ → কাজ → পার্সোনাল সেক্রেটারি (পিএস) → ওপরের সারি \"আজকের ব্রিফ\""),
    "ai_daily_planner": (
        "Menu ☰ → Work → AI daily planner; also Task manager → calendar icon",
        "মেনু ☰ → কাজ → AI দৈনিক পরিকল্পনা; আরও: টাস্ক ম্যানেজার → ক্যালেন্ডার আইকন"),
    "accounting_v2": (
        "Menu ☰ → My Business → My Business → \"Accounts\" card",
        "মেনু ☰ → আমার ব্যবসা → আমার ব্যবসা → \"হিসাব-নিকাশ\" কার্ড"),
    "booking_bot": (
        "Menu ☰ → My Business → Bookings (my business); Reminders & Memory → My bookings",
        "মেনু ☰ → আমার ব্যবসা → বুকিং (আমার ব্যবসা); রিমাইন্ডার ও মেমোরি → আমার বুকিং"),
    "retention_auto": (
        "Menu ☰ → My Business → Retention automation; Shopping → Messages from shops; business hub → \"Bring customers back\"",
        "মেনু ☰ → আমার ব্যবসা → রিটেনশন অটোমেশন; কেনাকাটা → দোকানের মেসেজ; ব্যবসার হাব → \"গ্রাহক ফিরিয়ে আনুন\""),
    "marketing_engine": (
        "Menu ☰ → My Business → Marketing engine (also a card in the business hub)",
        "মেনু ☰ → আমার ব্যবসা → মার্কেটিং ইঞ্জিন (ব্যবসার হাবে কার্ডও আছে)"),
    "invoice_designs": (
        "Menu ☰ → My Business → My Business → Invoices → New invoice (or invoice settings) → design picker",
        "মেনু ☰ → আমার ব্যবসা → আমার ব্যবসা → ইনভয়েস → নতুন ইনভয়েস (বা ইনভয়েস সেটিং) → ডিজাইন বাছাই"),
    "plans_v2": (
        "Menu ☰ → My Business → CRM → new \"Contacts\" tab; new plan limits and upgrade sheets",
        "মেনু ☰ → আমার ব্যবসা → CRM → নতুন \"কন্টাক্ট\" ট্যাব; নতুন প্ল্যান-সীমা ও আপগ্রেড পাতা"),
    "probashi_plan": (
        "Menu ☰ → Family & Safety → Family → More → \"Probashi family plan\" (only when a family member is abroad)",
        "মেনু ☰ → পরিবার ও নিরাপত্তা → পরিবার → আরও → \"প্রবাসী পরিবার প্ল্যান\" (পরিবারের কেউ বিদেশে থাকলে)"),
    "corporate_meetings": (NO_ENTRY_EN, NO_ENTRY_BN),
    "remote_support": (NO_ENTRY_EN, NO_ENTRY_BN),
    "marketing": ("Old name; the app uses Marketing engine. " + NO_ENTRY_EN,
                  "পুরোনো নাম; অ্যাপে এখন মার্কেটিং ইঞ্জিন। " + NO_ENTRY_BN),
    "retention": ("Old name; the app uses Retention automation. " + NO_ENTRY_EN,
                  "পুরোনো নাম; অ্যাপে এখন রিটেনশন অটোমেশন। " + NO_ENTRY_BN),
    "booking": ("Old name; the app uses Booking bot. " + NO_ENTRY_EN,
                "পুরোনো নাম; অ্যাপে এখন বুকিং বট। " + NO_ENTRY_BN),
    "vault_e2e": (
        "Menu ☰ → Tools → Documents → \"End-to-end lock\" card",
        "মেনু ☰ → টুলস → ডকুমেন্টস → \"এন্ড-টু-এন্ড তালা\" কার্ড"),
    "assisto_market": (
        "Menu ☰ → Shopping → Assisto Market",
        "মেনু ☰ → কেনাকাটা → Assisto মার্কেট"),
    "safe_plans": (
        "Menu ☰ → Plans & points → \"Safety plans\" section",
        "মেনু ☰ → প্ল্যান ও পয়েন্ট → \"নিরাপত্তা প্ল্যান\" অংশ"),
    "family_auto_arrival": (
        "No new button: arrival news also works with the app closed. Member switch: Family → More → Privacy & alerts",
        "নতুন বোতাম নেই: অ্যাপ বন্ধ থাকলেও পৌঁছানোর খবর যায়। সদস্যের সুইচ: পরিবার → আরও → গোপনীয়তা ও সতর্কতা"),
    "unseen_world": (
        "The travel feature is not built; " + NO_ENTRY_EN,
        "ভ্রমণ ফিচার তৈরি হয়নি; " + NO_ENTRY_BN),
    "dictionary": (
        "Menu ☰ → Tools → Dictionary (also a Home quick button)",
        "মেনু ☰ → টুলস → অভিধান (হোমে দ্রুত-বোতামও)"),
    "ai_inbox": (
        "Menu ☰ → Work → AI Inbox",
        "মেনু ☰ → কাজ → AI ইনবক্স"),
}


def where(key, lang="bn"):
    """The 'where in the app' line for `key` ('' when unknown)."""
    w = WHERE.get(key)
    if not w:
        return ""
    return w[0] if lang == "en" else w[1]
