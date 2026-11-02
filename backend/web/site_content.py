"""website: every word on the lifeassisto.com marketing pages, bn + en.

RULES (owner 2 Nov): claims must match what really works in the Play build —
source of truth owner_actions/PLAY_LISTING_8NOV_ALL_BN.md (claim table §ক).
No reviews, user counts or invented numbers. End-to-end encryption is claimed
ONLY for My Circle messages/media; calls are "encrypted"; the document vault is
PIN-locked and recoverable (never "end-to-end"). Medicine/health features are
hidden in the Play build, so they are not advertised here. No surveillance
wording ("watching", "নজর রাখছি") anywhere.
"""
import json

THEME_COLOR = "#0A6CF0"
COMPANY = "AXON Dynamic"
EMAIL = "assistoaiagent@gmail.com"
PLAY_ID = "com.assisto.assisto"

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(s):
    return str(s).translate(_BN_DIGITS)


def money(amount, cur, lang):
    try:
        n = int(amount) if float(amount) == int(amount) else float(amount)
    except (TypeError, ValueError):
        return ""
    txt = "{:,}".format(n)
    if cur == "BDT":
        return ("৳" + bn_digits(txt)) if lang == "bn" else ("৳" + txt)
    if cur == "USD":
        return "$" + (bn_digits(txt) if lang == "bn" else txt)
    return txt + " " + cur


def play_url(lang):
    return "https://play.google.com/store/apps/details?id=%s&hl=%s" % (PLAY_ID, "bn" if lang == "bn" else "en")


PAGES = {
    "home": {"path": "/",
             "title": {"bn": "Assisto — চ্যাট, AI, নিরাপত্তা ও ব্যবসা এক অ্যাপে",
                       "en": "Assisto — Chat, AI, safety and business in one app"},
             "desc": {"bn": "পরিবারের SOS ও নিরাপদ যাত্রা, এনক্রিপ্টেড চ্যাট ও কল, রিমাইন্ডার, হিসাব আর দোকানের খাতা — বাংলায়, এক অ্যাপে। বাংলাদেশে তৈরি।",
                      "en": "Family SOS and Safe Journey, encrypted chat and calls, reminders, money and a shop khata — in Bangla and English, in one app. Made in Bangladesh."}},
    "pricing": {"path": "/pricing",
                "title": {"bn": "দাম ও প্ল্যান — Assisto", "en": "Pricing and plans — Assisto"},
                "desc": {"bn": "Assisto-র ফ্রি, প্রিমিয়াম ও বিজনেস প্ল্যান। পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি।",
                         "en": "Assisto Free, Premium and Business plans. Family safety is free on every plan."}},
    "security": {"path": "/security",
                 "title": {"bn": "নিরাপত্তা ও গোপনীয়তা — Assisto", "en": "Security and privacy — Assisto"},
                 "desc": {"bn": "Assisto আপনার ডেটা কীভাবে রক্ষা করে: কোনটা end-to-end এনক্রিপ্টেড, কোনটা নয় — সোজা ভাষায়।",
                          "en": "How Assisto protects your data: what is end-to-end encrypted and what is not — in plain words."}},
    "help": {"path": "/help",
             "title": {"bn": "সাহায্য, প্রশ্নোত্তর ও যোগাযোগ — Assisto", "en": "Help, FAQ and contact — Assisto"},
             "desc": {"bn": "Assisto নিয়ে সাধারণ প্রশ্নের উত্তর, অ্যাকাউন্ট মোছা আর আমাদের সাথে যোগাযোগ।",
                      "en": "Answers to common questions about Assisto, deleting your account, and how to contact us."}},
}

COPY = {
    "bn": {
        "meta_desc": PAGES["home"]["desc"]["bn"],
        "og_title_default": PAGES["home"]["title"]["bn"],
        "og_image_alt": "Assisto লোগো আর অ্যাপের হোম স্ক্রিন",
        "skip": "মূল লেখায় যান",
        "nav_features": "ফিচার", "nav_security": "নিরাপত্তা", "nav_pricing": "দাম",
        "nav_tools": "ফ্রি টুল", "nav_help": "সাহায্য", "nav_menu": "মেনু",
        "lang_other": "English", "lang_other_code": "en", "lang_other_q": "?lang=en",
        "hero_kicker": "বাংলাদেশে তৈরি · বাংলা ও ইংরেজিতে",
        "hero_h1": "পরিবার, চ্যাট, হিসাব আর ব্যবসা — এক অ্যাপে, বাংলায়",
        "hero_sub": "বিপদে এক চাপে পরিবারকে SOS, যাত্রায় লাইভ লোকেশন, কাছের মানুষের সাথে এনক্রিপ্টেড চ্যাট ও কল, রিমাইন্ডার, টাকার হিসাব আর দোকানের ডিজিটাল খাতা।",
        "hero_free": "ফ্রি ডাউনলোড · Android ৮ বা নতুন · পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি",
        "badge_alt": "Google Play-তে পাবেন",
        "apk_alt": "বা সরাসরি APK নিন",
        "shot_alt_home": "Assisto অ্যাপের হোম স্ক্রিন: শর্টকাট, আমার সার্কেল, নিরাপদ যাত্রা ও ডিজিটাল খাতা",
        "features_h": "Assisto দিয়ে যা করতে পারবেন",
        "features_sub": "প্রতিটি ছবি আসল অ্যাপের স্ক্রিন।",
        "trust_h": "আপনার ডেটা, আপনার নিয়ন্ত্রণে",
        "trust_more": "নিরাপত্তার পুরো বিবরণ",
        "pricing_h": "দাম",
        "pricing_sub": "শুরু করুন ফ্রিতে। পরিবারের নিরাপত্তা কখনো টাকার পেছনে আটকানো নয়।",
        "per_mo": "/মাস", "per_yr": "/বছর", "free_label": "ফ্রি",
        "ads_yes": "বিজ্ঞাপন থাকে", "ads_no": "বিজ্ঞাপন নেই",
        "pricing_note": "দাম বাংলাদেশি টাকায়। প্ল্যান কেনা হয় Google Play দিয়ে; Play-তে দেখানো দামই চূড়ান্ত, আর অন্য দেশে দাম আলাদা হতে পারে। যেকোনো সময় Play থেকে বাতিল করা যায়।",
        "pricing_yearly": "বছরে নিলে:",
        "pricing_empty": "দামের তালিকা এই মুহূর্তে লোড হয়নি। অ্যাপের ভেতরে প্ল্যান পাতায় সবসময় সর্বশেষ দাম দেখা যায়।",
        "pricing_web": "ওয়েবসাইট থেকে কিনতে চান?",
        "tools_h": "ফ্রি টুল — অ্যাপ ছাড়াই",
        "tools_sub": "লগইন লাগবে না।",
        "faq_h": "প্রশ্ন ও উত্তর",
        "faq_more": "আরও প্রশ্ন ও সাহায্য",
        "cta_h": "আজই Assisto নিন",
        "cta_sub": "ফ্রি। বাংলা ও ইংরেজি। আপনার ফোনেই।",
        "contact_h": "যোগাযোগ",
        "contact_body": "প্রশ্ন, সমস্যা বা পরামর্শ থাকলে ইমেইল করুন।",
        "contact_app": "অ্যাপের ভেতর থেকে: মেনু › সাহায্য ও মতামত।",
        "company_line": "Assisto তৈরি করেছে AXON Dynamic, বাংলাদেশ।",
        "emergency": "Assisto জরুরি সেবা নয়। বিপদে ৯৯৯-এ ফোন করুন।",
        "footer_product": "অ্যাপ", "footer_company": "কোম্পানি", "footer_legal": "নীতিমালা",
        "privacy": "গোপনীয়তা নীতি", "terms": "শর্তাবলী", "refund": "রিফান্ড নীতি",
        "delete": "অ্যাকাউন্ট ও ডেটা মোছা", "get_apk": "APK ডাউনলোড",
        "khata_free": "খাতা চিরকাল ফ্রি — প্রতিশ্রুতি",
        "play_tm": "Google Play ও Google Play লোগো Google LLC-এর ট্রেডমার্ক।",
        "made_in": "বাংলাদেশে তৈরি",
        "learn_more": "আরও জানুন",
        "home": "হোম",
        "help_lead": "সবচেয়ে বেশি যে প্রশ্নগুলো আসে, তার উত্তর। উত্তর না পেলে আমাদের লিখুন।",
        "help_delete_h": "অ্যাকাউন্ট ও ডেটা মুছতে চান?",
        "help_delete_body": "অ্যাপে: মেনু › সেটিংস › \"আমার অ্যাকাউন্ট মুছে ফেলুন…\"। অ্যাপ না থাকলে ওয়েবসাইটের ফর্ম দিয়েও অনুরোধ করা যায়।",
        "security_lead": "কোনটা কীভাবে সুরক্ষিত — বাড়িয়ে না বলে, সোজা ভাষায়। কিছু না মিললে আমাদের জানান।",
        "security_never_h": "যা আমরা কখনো করি না",
    },
    "en": {
        "meta_desc": PAGES["home"]["desc"]["en"],
        "og_title_default": PAGES["home"]["title"]["en"],
        "og_image_alt": "The Assisto logo and the app's home screen",
        "skip": "Skip to content",
        "nav_features": "Features", "nav_security": "Security", "nav_pricing": "Pricing",
        "nav_tools": "Free tools", "nav_help": "Help", "nav_menu": "Menu",
        "lang_other": "বাংলা", "lang_other_code": "bn", "lang_other_q": "?lang=bn",
        "hero_kicker": "Made in Bangladesh · Bangla and English",
        "hero_h1": "Family, chat, money and business — in one app",
        "hero_sub": "One-tap SOS to your family, live location on a trip, encrypted chat and calls with your people, reminders, money tracking and a digital khata for your shop.",
        "hero_free": "Free download · Android 8 or newer · Family safety is free on every plan",
        "badge_alt": "Get it on Google Play",
        "apk_alt": "or download the APK directly",
        "shot_alt_home": "Assisto home screen: shortcuts for My Circle, Safe Journey and the digital khata",
        "features_h": "What you can do with Assisto",
        "features_sub": "Every picture is a real screen from the app.",
        "trust_h": "Your data, under your control",
        "trust_more": "Full security details",
        "pricing_h": "Pricing",
        "pricing_sub": "Start free. Family safety is never behind a paywall.",
        "per_mo": "/month", "per_yr": "/year", "free_label": "Free",
        "ads_yes": "Shows ads", "ads_no": "No ads",
        "pricing_note": "Prices in Bangladeshi taka. Plans are bought through Google Play; the price Play shows you is final and may differ outside Bangladesh. Cancel any time in Play.",
        "pricing_yearly": "Yearly:",
        "pricing_empty": "The price list did not load just now. The Plans screen inside the app always shows the latest prices.",
        "pricing_web": "Prefer to buy on the website?",
        "tools_h": "Free tools — no app needed",
        "tools_sub": "No login needed.",
        "faq_h": "Questions and answers",
        "faq_more": "More questions and help",
        "cta_h": "Get Assisto today",
        "cta_sub": "Free. Bangla and English. On your phone.",
        "contact_h": "Contact",
        "contact_body": "Questions, problems or ideas — email us.",
        "contact_app": "Inside the app: Menu › Help & feedback.",
        "company_line": "Assisto is made by AXON Dynamic, Bangladesh.",
        "emergency": "Assisto is not an emergency service. In danger, call 999.",
        "footer_product": "App", "footer_company": "Company", "footer_legal": "Policies",
        "privacy": "Privacy policy", "terms": "Terms", "refund": "Refund policy",
        "delete": "Delete account and data", "get_apk": "Download APK",
        "khata_free": "Khata free forever — our promise",
        "play_tm": "Google Play and the Google Play logo are trademarks of Google LLC.",
        "made_in": "Made in Bangladesh",
        "learn_more": "Learn more",
        "home": "Home",
        "help_lead": "Answers to the questions we hear most. Can't find yours? Write to us.",
        "help_delete_h": "Want to delete your account and data?",
        "help_delete_body": "In the app: Menu › Settings › \"Delete my account…\". No app? Use the form on our website.",
        "security_lead": "How each part is protected — plainly, without overclaiming. If anything doesn't match, tell us.",
        "security_never_h": "What we never do",
    },
}

_FEATURES = [
    {"id": "safety", "shot": "safety", "shot2": None, "link": None,
     "bn": {"kicker": "পরিবার ও নিরাপত্তা", "h": "বিপদে এক চাপে পরিবারকে খবর",
            "body": "SOS চাপলে আপনার বেছে নেওয়া পরিবারের সদস্যরা আপনার লোকেশনসহ সতর্কতা পান।",
            "points": ["এক চাপে SOS, সাথে আপনার লোকেশন",
                       "হাত না লাগিয়ে ভয়েস SOS — আপনি চালু করলে তবেই; চালু থাকলে নোটিফিকেশন দেখা যায়, কথা ফোনেই থাকে",
                       "জরুরি কার্ড, নকল কল আর স্ক্যাম চেক",
                       "পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি"],
            "alt": "Assisto-র নিরাপত্তা পাতা: SOS বোতাম, নিরাপদ যাত্রা ও ভয়েস SOS"},
     "en": {"kicker": "Family and safety", "h": "Tell your family in one tap",
            "body": "Press SOS and the family members you chose get an alert with your location.",
            "points": ["One-tap SOS with your location",
                       "Hands-free Voice SOS — only if you turn it on; a notification shows the whole time and speech stays on your phone",
                       "Emergency card, fake call and scam check",
                       "Family safety is free on every plan"],
            "alt": "Assisto Safety screen with the SOS button, Safe Journey and Voice SOS"}},
    {"id": "journey", "shot": "journey_live", "shot2": None, "link": None,
     "bn": {"kicker": "নিরাপদ যাত্রা", "h": "পৌঁছালে পরিবার জানে",
            "body": "যাত্রা শুরু করুন — শুধু আপনার বেছে নেওয়া মানুষেরা যাত্রার সময় আপনার লাইভ লোকেশন পান।",
            "points": ["পৌঁছে এক চাপে \"পৌঁছে গেছি\"; দেরি হলে পরিবার সতর্কতা পায়",
                       "CNG নম্বর বা গাড়ির প্লেট যোগ করুন, ছবি তুলুন",
                       "যাত্রা শেষে পথের লোকেশন মুছে যায়",
                       "যাঁরা দেখতে পান, তা আপনার স্ক্রিনে সবসময় লেখা থাকে"],
            "alt": "চলমান যাত্রার পাতা: SOS, পৌঁছে গেছি, নকল কল ও যাত্রা থামানোর বোতাম"},
     "en": {"kicker": "Safe Journey", "h": "Your family knows when you arrive",
            "body": "Start a trip — only the people you choose get your live location, and only during the trip.",
            "points": ["Tap \"I've arrived\"; if you're late, your family is alerted",
                       "Add the CNG number or car plate and a ride photo",
                       "The trip's path is deleted when it ends",
                       "Your screen always shows who can see the trip"],
            "alt": "Journey in progress screen with SOS, I've arrived, fake call and stop journey buttons"}},
    {"id": "circle", "shot": "c3_chat_list", "shot2": "incoming_call", "link": None,
     "bn": {"kicker": "আমার সার্কেল", "h": "কাছের মানুষের সাথে এনক্রিপ্টেড চ্যাট ও কল",
            "body": "একজনের সাথে বা গ্রুপে চ্যাট, ভয়েস ও ভিডিও কল — শুধু যাঁদের আপনি সার্কেলে যোগ করেছেন।",
            "points": ["মেসেজ, ছবি, ভয়েস নোট আর ফাইল end-to-end এনক্রিপ্টেড; আমাদের সার্ভার শুধু তালাবদ্ধ রূপটা রাখে",
                       "এনক্রিপ্টেড ভয়েস ও ভিডিও কল",
                       "আপনি অনুমতি দিলে তবেই কন্টাক্ট থেকে বন্ধু খোঁজা (নম্বর হ্যাশ করা থাকে)",
                       "সন্দেহজনক মেসেজে স্ক্যাম সতর্কতা"],
            "alt": "আমার সার্কেলের চ্যাট তালিকা", "alt2": "আসা ভিডিও কলের পাতা"},
     "en": {"kicker": "My Circle", "h": "Encrypted chat and calls with your people",
            "body": "One-to-one and group chat, voice and video calls — only with the people you add to your Circle.",
            "points": ["Messages, photos, voice notes and files are end-to-end encrypted; our server keeps only the locked form",
                       "Encrypted voice and video calls",
                       "Find friends in your contacts only if you allow it (numbers are hashed)",
                       "Scam warnings on suspicious messages"],
            "alt": "My Circle chat list", "alt2": "Incoming video call screen"}},
    {"id": "business", "shot": "biz_khata", "shot2": "crm_dashboard", "link": "/khata-free",
     "bn": {"kicker": "ব্যবসা", "h": "দোকানের খাতা, CRM আর কোটেশন",
            "body": "বাকি, জমা আর তাগাদা — কাগজের খাতার চেয়ে সহজ। বড় হলে CRM দিয়ে লিড আর বিক্রি সামলান।",
            "points": ["ডিজিটাল খাতা চিরকাল ফ্রি: গ্রাহকের বাকি, জমা, তাগাদা",
                       "PDF হিসাব-বিবরণী, দ্রুত বিক্রি, পণ্য, অর্ডার, ক্যাশবাক্স ও রিপোর্ট",
                       "CRM: গ্রাহক, লিড, পাইপলাইন",
                       "দামের কোটেশন লিংকে পাঠান — গ্রাহক অ্যাপ ছাড়াই গ্রহণ করতে পারেন"],
            "alt": "ডিজিটাল খাতা: গ্রাহকের বাকি ও তাগাদা", "alt2": "CRM ড্যাশবোর্ড: পাইপলাইন ও বিক্রি"},
     "en": {"kicker": "Business", "h": "Shop khata, CRM and price quotes",
            "body": "Dues, payments and reminders — easier than a paper khata. As you grow, run leads and sales in the CRM.",
            "points": ["Digital khata free forever: customer dues, payments, reminders",
                       "PDF statements, quick sell, products, orders, cash box and reports",
                       "CRM: customers, leads and pipeline",
                       "Send a price quote as a link — the customer can accept without the app"],
            "alt": "Digital khata with customer dues and reminders", "alt2": "CRM dashboard with pipeline and sales"}},
    {"id": "cctv", "shot": "wm_alerts", "shot2": "veh_tracking", "link": None,
     "bn": {"kicker": "CCTV ও গাড়ি", "h": "দোকান, বাড়ি আর গাড়ির খবর ফোনে",
            "body": "নিজের CCTV ক্যামেরা যুক্ত করুন, বা একটা বাড়তি Android ফোনকে দোকানের ক্যামেরা বানান (শপ বক্স)।",
            "points": ["সন্দেহজনক কিছু হলে একটি ছবিসহ সতর্কতা; শপ বক্স থেকে কোনো ভিডিও দোকানের বাইরে যায় না",
                       "নেটওয়ার্ক CCTV-র জন্য আপনার জায়গায় একটা কম্পিউটার-গেটওয়ে লাগে; শপ বক্স বিজনেস প্ল্যানে",
                       "নিজের GPS ট্র্যাকার দিয়ে গাড়ির লাইভ অবস্থান (Sinotrack, Concox, Coban, Teltonika)",
                       "ব্লুটুথ ELM327 OBD দিয়ে গাড়ির রিডিং — যন্ত্র আলাদা কিনতে হয়"],
            "alt": "CCTV সতর্কতার তালিকা", "alt2": "গাড়ির লাইভ ট্র্যাকিং তালিকা"},
     "en": {"kicker": "CCTV and vehicles", "h": "Your shop, home and vehicles — on your phone",
            "body": "Connect your own CCTV cameras, or turn a spare Android phone into a shop camera (Shop Box).",
            "points": ["An alert with one photo when something looks wrong; no video ever leaves the shop from a Shop Box",
                       "Network CCTV needs a small computer gateway at your place; Shop Box is on the Business plan",
                       "Live vehicle location with your own GPS tracker (Sinotrack, Concox, Coban, Teltonika)",
                       "Car readings with a Bluetooth ELM327 OBD adapter — hardware not included"],
            "alt": "CCTV alerts list", "alt2": "Vehicle live tracking list"}},
    {"id": "ai", "shot": "ps_assistant", "shot2": "voice_assistant", "link": None,
     "bn": {"kicker": "AI সহকারী", "h": "লিখুন বা বলুন — বাকিটা Assisto করে",
            "body": "\"৫০০ টাকা দুপুরের খাবার\" লিখলে খরচ হয়ে যায়, \"রাত ৮টায় আম্মুকে ফোন\" বললে রিমাইন্ডার।",
            "points": ["বাংলা বা ইংরেজিতে, লিখে বা কথা বলে",
                       "যেকোনো প্রশ্ন করুন, পরিষ্কার উত্তর পান",
                       "ব্যবসার AI সহকারী গ্রাহকের উত্তর লিখে দেয় — পাঠানোর আগে আপনি দেখে নেন",
                       "AI ভুল করতে পারে; জরুরি তথ্য যাচাই করে নিন"],
            "alt": "Assisto চ্যাট: খরচ লেখা ও রিমাইন্ডার বানানো", "alt2": "Assisto ভয়েস: কথা বলে কাজ"},
     "en": {"kicker": "AI assistant", "h": "Type it or say it — Assisto does the rest",
            "body": "Type \"500 for lunch\" and it's logged as an expense; say \"Call mum at 8 tonight\" and it's a reminder.",
            "points": ["In Bangla or English, by typing or by voice",
                       "Ask anything and get a clear answer",
                       "Business AI helper drafts replies to customers — you approve before anything is sent",
                       "AI can make mistakes; check important information"],
            "alt": "Assisto chat logging an expense and setting a reminder", "alt2": "Assisto Voice: do things by speaking"}},
    {"id": "protect", "shot": "at_protection_on", "shot2": None, "link": None,
     "bn": {"kicker": "ফোন সুরক্ষা", "h": "ফোন হারালে বা ছিনতাই হলে",
            "body": "অন্য ফোন থেকে বা বিশ্বস্ত পরিবারের সদস্য দিয়ে হারানো ফোন লক করুন, জোরে অ্যালার্ম বাজান, শেষ লোকেশন জানুন।",
            "points": ["সিম বদল, ফোন অফলাইন বা ছিনতাই হলে সতর্কতা — চালু থাকলে নোটিফিকেশন দেখা যায়",
                       "লক করতে Device admin লাগে, যা শুধু আপনি চালু করতে পারেন",
                       "ফোন চালু ও অনলাইন থাকতে হয়",
                       "Assisto কখনো ফোন মুছে দেয় না; মুছতে Google Find Hub ব্যবহার করুন"],
            "alt": "সবসময়-চালু সুরক্ষার পাতা"},
     "en": {"kicker": "Phone protection", "h": "If your phone is lost or snatched",
            "body": "From another phone or through a trusted family member: lock it, sound a loud alarm and see its last location.",
            "points": ["Alerts for SIM change, the phone going offline or a snatch — a notification shows while it runs",
                       "Locking needs Device admin, which only you can turn on",
                       "The phone must be on and online",
                       "Assisto never erases a phone; use Google Find Hub for that"],
            "alt": "Always-on protection screen"}},
]


def features(lang):
    out = []
    for f in _FEATURES:
        t = f[lang]
        out.append(dict(t, id=f["id"], shot=f["shot"], shot2=f["shot2"], link=f["link"]))
    return out


_TRUST = {
    "bn": [
        ("চ্যাট end-to-end এনক্রিপ্টেড", "আমার সার্কেলের মেসেজ, ছবি, ভয়েস নোট, ভিডিও আর ফাইল আপনার ফোনেই তালাবদ্ধ হয়। আমাদের সার্ভার শুধু তালাবদ্ধ রূপ রাখে, পড়তে পারে না — আমাদের AI-ও না।"),
        ("কল এনক্রিপ্টেড", "সার্কেলের ভয়েস ও ভিডিও কল পথে এনক্রিপ্টেড থাকে আর কখনো রেকর্ড হয় না।"),
        ("ডকুমেন্ট ভল্ট: PIN-এ তালা, হারায় না", "ভল্ট আপনার অ্যাকাউন্টের সাথে রাখা থাকে, তাই ফোন হারালেও ডকুমেন্ট হারায় না। PIN শুধু আপনার ফোনে থাকে। PIN ভুলে গেলে পরিচয় প্রমাণ করে ফেরত পাওয়া যায় — তাই এটা end-to-end নয়, এটা ফেরতযোগ্য।"),
        ("টাকা আমরা রাখি না", "Assisto-তে কোনো ওয়ালেট নেই। বিল দিতে আপনার নিজের ব্যাংক, bKash বা Nagad অ্যাপ খোলে — পাঠান আপনি নিজে।"),
        ("প্রতিটি অনুমতি আপনার হাতে", "লোকেশন, মাইক, ক্যামেরা, কন্টাক্ট — যে ফিচার দরকার, শুধু সেটা চালুর সময় জিজ্ঞেস করি। যেকোনো সময় বন্ধ করতে পারেন।"),
        ("মুছতে চাইলে মুছে যায়", "অ্যাপের সেটিংস থেকে বা ওয়েবসাইটের ফর্মে অ্যাকাউন্ট ও ডেটা মোছার অনুরোধ করুন। আমরা আপনার ডেটা বিক্রি করি না।"),
    ],
    "en": [
        ("Chats are end-to-end encrypted", "Messages, photos, voice notes, videos and files in My Circle are locked on your phone. Our server keeps only the locked form and cannot read it — neither can our AI."),
        ("Calls are encrypted", "My Circle voice and video calls are encrypted in transit and never recorded."),
        ("Document vault: PIN-locked, never lost", "The vault is kept with your account, so a lost phone doesn't lose your documents. Your PIN stays on your phone. Forgot it? Prove it's you and recover access — so the vault is recoverable, not end-to-end encrypted."),
        ("We never hold your money", "Assisto has no wallet. To pay a bill it opens your own bank, bKash or Nagad app — you press Send yourself."),
        ("You decide every permission", "Location, microphone, camera, contacts — we ask only when you turn on the feature that needs it. Turn any of them off any time."),
        ("Delete means delete", "Ask to delete your account and data from Settings in the app or with the form on our website. We never sell your data."),
    ],
}

_NEVER = {
    "bn": ["আপনার ডেটা বিক্রি করা", "আপনার এনক্রিপ্টেড চ্যাট পড়া", "আপনার অনুমতি ছাড়া পোস্ট, পেমেন্ট বা আবেদন করা",
           "SOS, নিরাপত্তা, কল, চ্যাট, পেমেন্ট বা লগইন পাতায় বিজ্ঞাপন দেখানো", "কোনো ফোন দূর থেকে মুছে ফেলা"],
    "en": ["Sell your data", "Read your encrypted chats", "Post, pay or apply without your go-ahead",
           "Show ads on SOS, safety, call, chat, payment or login screens", "Erase anyone's phone remotely"],
}

_SECURITY_MORE = {
    "bn": [
        ("ফাইল ও ছবি সার্ভারে কীভাবে থাকে", "আপলোড করা ফাইল সার্ভারের প্রাইভেট জায়গায় থাকে, সরাসরি কোনো লিংকে খোলা যায় না। দেখতে হলে অল্প সময়ের জন্য স্বাক্ষর-করা লিংক লাগে।"),
        ("সংযোগ", "অ্যাপ আর সার্ভারের মধ্যে সব যোগাযোগ HTTPS (TLS)-এ এনক্রিপ্টেড।"),
        ("যাত্রার লোকেশন", "নিরাপদ যাত্রার পথের লোকেশন যাত্রা শেষে মুছে যায়। যাঁরা দেখতে পান, তা আপনার স্ক্রিনে সবসময় লেখা থাকে।"),
        ("শপ বক্স ও CCTV", "শপ বক্স ফোনেই শনাক্ত করে; শুধু সংকেত আর দরকার হলে একটি ছবি পাঠায় — কোনো ভিডিও দোকানের বাইরে যায় না।"),
        ("ভয়েস SOS", "আপনার কথা ফোনেই লেখায় রূপ নেয়। কোনো অডিও আপলোড বা সংরক্ষণ হয় না; শুধু SOS সতর্কতা (লোকেশনসহ) যায়।"),
        ("বিজ্ঞাপন ও সম্মতি", "ফ্রি প্ল্যানে বিজ্ঞাপন থাকে (Google AdMob), পেইড প্ল্যানে থাকে না। যেখানে আইন চায় (যেমন EEA ও UK), আগে Google-এর সম্মতি-ফর্ম আসে; সেটিংস থেকে বদলানো যায়।"),
        ("AI", "AI নিজে থেকে কখনো পোস্ট, পেমেন্ট বা আবেদন করে না। AI যা মনে রাখে, তা আপনি দেখতে ও মুছতে পারেন। এনক্রিপ্টেড চ্যাট AI পড়তে পারে না।"),
    ],
    "en": [
        ("How files and photos are stored", "Uploaded files sit in private storage on our server and are never reachable by a public link. Viewing one needs a short-lived signed link."),
        ("Connection", "Everything between the app and our server travels over HTTPS (TLS)."),
        ("Trip location", "A Safe Journey's path is deleted when the trip ends. Your screen always shows who can see it."),
        ("Shop Box and CCTV", "Shop Box detects on the phone itself and sends only a signal and, when needed, one photo — no video leaves the shop."),
        ("Voice SOS", "Your speech is turned into text on your phone. No audio is uploaded or stored; only the SOS alert (with location) is sent."),
        ("Ads and consent", "The Free plan shows ads (Google AdMob); paid plans show none. Where the law requires it (for example the EEA and UK), Google's consent form asks first; change it any time in Settings."),
        ("AI", "AI never posts, pays or applies on its own. You can see and delete what it remembers. AI cannot read encrypted chats."),
    ],
}


def trust(lang):
    return {"items": [{"h": h, "b": b} for h, b in _TRUST[lang]],
            "never": _NEVER[lang],
            "more": [{"h": h, "b": b} for h, b in _SECURITY_MORE[lang]]}


_TOOLS = {
    "bn": [("/cv", "CV স্কোর", "আপনার CV ১০০-তে কত, আর কী ঠিক করলে ভালো হবে।"),
           ("/scam", "স্ক্যাম চেকার", "সন্দেহজনক মেসেজ প্রতারণা কিনা, কারণসহ দেখুন।"),
           ("/photo", "পাসপোর্ট ও ভিসা ছবি", "নিজের ছবি সঠিক মাপে কাটুন — পাসপোর্ট, ভিসা, NID, চাকরি।"),
           ("/festival", "উৎসবের কার্ড", "ঈদ, পহেলা বৈশাখ, পূজা, বিজয় দিবস, জন্মদিন।"),
           ("/made30", "৩০ সেকেন্ডে পোস্টার", "দোকানের নাম আর দাম দিন, শেয়ার করার মতো পোস্টার পান।"),
           ("/khata-free", "ডিজিটাল খাতা — চিরকাল ফ্রি", "আমাদের লিখিত প্রতিশ্রুতি পড়ুন।")],
    "en": [("/cv", "CV score", "How your CV scores out of 100, and what to fix."),
           ("/scam", "Scam checker", "Check whether a suspicious message is a scam, with reasons."),
           ("/photo", "Passport and visa photo", "Crop your own photo to the right size — passport, visa, NID, job."),
           ("/festival", "Festival cards", "Eid, Pohela Boishakh, Puja, Victory Day, birthdays."),
           ("/made30", "Poster in 30 seconds", "Shop name and prices in, a shareable poster out."),
           ("/khata-free", "Digital khata — free forever", "Read our written promise.")],
}


def tools(lang):
    return [{"path": p, "h": h, "b": b} for p, h, b in _TOOLS[lang]]


_FAQ = {
    "bn": [
        ("Assisto কী?", "Assisto একটি Android অ্যাপ, যেখানে এক জায়গায় পাবেন পরিবারের নিরাপত্তা (SOS, নিরাপদ যাত্রা), কাছের মানুষের সাথে এনক্রিপ্টেড চ্যাট ও কল, রিমাইন্ডার, টাকার হিসাব আর দোকানের ডিজিটাল খাতা — বাংলা ও ইংরেজিতে।"),
        ("Assisto কি ফ্রি?", "হ্যাঁ, ফ্রিতে শুরু করা যায়, আর পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি। ফ্রি প্ল্যানে বিজ্ঞাপন থাকে। বেশি AI ও বিজ্ঞাপন ছাড়া চাইলে প্রিমিয়াম বা বিজনেস প্ল্যান Google Play থেকে কেনা যায়।"),
        ("কোন ফোনে চলে?", "Android ৮ বা তার নতুন যেকোনো ফোনে — Samsung, Xiaomi, Realme, Oppo, Vivo, Symphony, Walton ইত্যাদি। iPhone সংস্করণ এখনো নেই।"),
        ("আমার চ্যাট কি কেউ পড়তে পারে?", "না। আমার সার্কেলের মেসেজ ও মিডিয়া end-to-end এনক্রিপ্টেড — আমাদের সার্ভার বা AI পড়তে পারে না।"),
        ("Assisto কি জরুরি সেবা?", "না। SOS আপনার বেছে নেওয়া পরিবারের সদস্যদের জানায়। বিপদে সবসময় ৯৯৯-এ ফোন করুন।"),
        ("অ্যাকাউন্ট কীভাবে মুছব?", "অ্যাপে মেনু › সেটিংস › \"আমার অ্যাকাউন্ট মুছে ফেলুন…\"। অ্যাপ না থাকলে lifeassisto.com/delete-account ফর্ম দিয়ে অনুরোধ করুন।"),
    ],
    "en": [
        ("What is Assisto?", "Assisto is an Android app that brings together family safety (SOS, Safe Journey), encrypted chat and calls with your people, reminders, money tracking and a digital khata for your shop — in Bangla and English."),
        ("Is Assisto free?", "Yes, you can start free, and family safety is free on every plan. The Free plan shows ads. For more AI and no ads, Premium or Business can be bought through Google Play."),
        ("Which phones does it run on?", "Any Android 8 or newer phone — Samsung, Xiaomi, Realme, Oppo, Vivo, Symphony, Walton and more. There is no iPhone version yet."),
        ("Can anyone read my chats?", "No. My Circle messages and media are end-to-end encrypted — neither our server nor our AI can read them."),
        ("Is Assisto an emergency service?", "No. SOS alerts the family members you chose. In danger, always call 999."),
        ("How do I delete my account?", "In the app: Menu › Settings › \"Delete my account…\". No app? Request it with the form at lifeassisto.com/delete-account."),
    ],
}


def faq(lang):
    return [{"q": q, "a": a} for q, a in _FAQ[lang]]


def jsonld(lang, site, url, page):
    """Organization + SoftwareApplication (+ FAQPage on home/help). No rating:
    we have no real public rating to show."""
    org = {"@type": "Organization", "@id": site + "/#org", "name": COMPANY,
           "url": site + "/", "email": EMAIL, "logo": site + "/site/icon-512.png",
           "address": {"@type": "PostalAddress", "addressCountry": "BD"}}
    app = {"@type": "SoftwareApplication", "name": "Assisto", "operatingSystem": "Android 8.0+",
           "applicationCategory": "LifestyleApplication", "url": site + "/",
           "inLanguage": ["bn", "en"], "publisher": {"@id": site + "/#org"},
           "description": PAGES["home"]["desc"][lang],
           "installUrl": play_url(lang),
           "offers": {"@type": "Offer", "price": "0", "priceCurrency": "BDT"}}
    graph = [org, app]
    if page in ("home", "help"):
        graph.append({"@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
            for q, a in _FAQ[lang]]})
    s = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False)
    return s.replace("<", "\\u003c")
