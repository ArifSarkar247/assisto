"""website v3 (owner final website order, 3 Nov): every word, every feature
and every screenshot of the new lifeassisto.com, bn + en.

SOURCE OF TRUTH (never memory): the feature list follows the real registry
(core.feature_flags.REGISTRY, mirrored in app/lib/feature_registry.dart) and
owner_actions/FEATURE_100_BOARD_BN.md; claims follow the claim-checked Play
listing (owner_actions/PLAY_LISTING_8NOV_ALL_BN.md §ক).

HONESTY RULES (enforced by web.tests_site_v3):
  * a feature is shown as available only when EVERY flag it names is on for
    an ordinary Play-build visitor right now (core.feature_flags.resolve with
    no user, play=True) — and, for AI-written answers, only when an AI
    provider is configured. Otherwise it says "Coming soon" and never carries
    the Auto badge. Flipping a flag in Owner Admin changes the site at once
    (HTML is no-cache + ETag).
  * `soon=True` marks things the code cannot do today (e.g. CCTV plans and
    prices: no live CCTV plan exists yet — the owner's planned prices are
    shown as "Coming soon").
  * NEVER medicine (tests scan every rendered page), no invented numbers,
    no reviews, no user counts.
  * every screenshot is a real CI gallery shot (app/test/screenshots_test.dart
    → shots-* artifacts → tools/website/site_shots.py → site_assets/shots3).
"""
import json

from . import site_content as SC

bn_digits = SC.bn_digits

# --------------------------------------------------------------- groups
GROUPS = (
    ("ai", "sparkle"), ("circle", "chat"), ("safety", "shield"), ("cctv", "camera"),
    ("business", "store"), ("work", "briefcase"), ("daily", "sun"),
)
GROUP_IDS = tuple(g for g, _ in GROUPS)

GROUP_TEXT = {
    "ai": {
        "bn": ("AI সহকারী ও পার্সোনাল সেক্রেটারি", "বাংলা বা ইংরেজিতে লিখুন বা বলুন — Assisto বোঝে, তারপর কাজটা করে দেয়।",
               "AI সহকারী ও পার্সোনাল সেক্রেটারি — Assisto", "বাংলা ও ইংরেজিতে কথা বোঝে এমন AI সহকারী: রিমাইন্ডার, খরচ, দৈনিক ব্রিফ, পার্সোনাল সেক্রেটারি।"),
        "en": ("AI assistant and Personal Secretary", "Type or say it in Bangla or English — Assisto understands, then does the work.",
               "AI assistant and Personal Secretary — Assisto", "An AI assistant that understands Bangla and English: reminders, expenses, a daily brief and a Personal Secretary."),
    },
    "circle": {
        "bn": ("আমার সার্কেল — চ্যাট ও কল", "কাছের মানুষের সাথে end-to-end এনক্রিপ্টেড চ্যাট, ভয়েস ও ভিডিও কল।",
               "আমার সার্কেল: এনক্রিপ্টেড চ্যাট ও কল — Assisto", "end-to-end এনক্রিপ্টেড চ্যাট, ভয়েস ও ভিডিও কল, ভাসমান বাবল, PiP, চ্যানেল ও কমিউনিটি।"),
        "en": ("My Circle — chat and calls", "End-to-end encrypted chat, voice and video calls with your people.",
               "My Circle: encrypted chat and calls — Assisto", "End-to-end encrypted chat, voice and video calls, floating bubbles, PiP, channels and communities."),
    },
    "safety": {
        "bn": ("পরিবার ও নিরাপত্তা", "বিপদে এক চাপে পরিবার জানে; যাত্রায়, স্কুলে, ফোন হারালে — Assisto নিজে থেকে সতর্ক করে।",
               "পরিবারের যত্ন ও নিরাপত্তা: SOS, নিরাপদ যাত্রা — Assisto", "SOS ও জরুরি হাব, নিরাপদ যাত্রা, শিশু ও বয়স্কদের যত্ন, হারানো ফোন, রক্তদাতা।"),
        "en": ("Family care and safety", "One tap and your family knows; on trips, at school, when a phone is lost — Assisto alerts by itself.",
               "Family care and safety: SOS, Safe Journey — Assisto", "SOS and emergency hub, Safe Journey, child and elder care, lost phone protection, blood donors."),
    },
    "cctv": {
        "bn": ("CCTV ও দোকানের পাহারা", "আপনার ক্যামেরা বা পুরনো ফোন দোকান দেখে; মানুষ এলে ছবিসহ সতর্কতা — ভিডিও দোকানের বাইরে যায় না।",
               "CCTV ও শপ বক্স: স্মার্ট সতর্কতা — Assisto", "লাইভ দেখা, স্মার্ট সতর্কতা, প্রমাণ-প্যাক, ফোনকে ক্যামেরা বানানো, ক্যাশ মেলানো।"),
        "en": ("CCTV and shop watch", "Your cameras or a spare phone watch the shop; a person shows up, you get a photo alert — no video leaves the shop.",
               "CCTV and Shop Box: smart alerts — Assisto", "Live view, smart alerts, evidence pack, a phone as a camera and the cash check."),
    },
    "business": {
        "bn": ("ব্যবসা", "হিসাব, ডিজিটাল খাতা, ইনভয়েস, CRM আর AI সেলস সহকারী — দোকান চলে, তাগাদা যায় নিজে থেকে।",
               "ব্যবসা: খাতা, ইনভয়েস, CRM, AI সেলস — Assisto", "ডিজিটাল খাতা ও তাগাদা, থার্মাল ও A4 ইনভয়েস, হিসাব, CRM, AI সেলস সহকারী, দোকান চালানো।"),
        "en": ("Business", "Accounts, a digital khata, invoices, CRM and an AI sales assistant — the shop runs, dues get chased by themselves.",
               "Business: khata, invoices, CRM, AI sales — Assisto", "Digital khata and due reminders, thermal and A4 invoices, accounts, CRM, an AI sales assistant and shop operations."),
    },
    "work": {
        "bn": ("কাজের টুল", "চাকরি খোঁজা থেকে CV, মক ইন্টারভিউ, লেখা আর কাজের তালিকা — এক জায়গায়।",
               "কাজের টুল: জব, CV, টাস্ক — Assisto", "জব হান্টার, CV বিল্ডার, মক ইন্টারভিউ, টাস্ক ম্যানেজার, চুক্তি বিশ্লেষক ও আরও।"),
        "en": ("Work tools", "From job hunting to a CV, mock interviews, writing and your task list — in one place.",
               "Work tools: jobs, CV, tasks — Assisto", "Job hunter, CV builder, mock interview, task manager, contract analyzer and more."),
    },
    "daily": {
        "bn": ("দৈনন্দিন জীবন", "রিমাইন্ডার, টাকা, বিল, ডকুমেন্ট, গাড়ি আর ছোট ছোট কাজ — মনে রাখে Assisto।",
               "দৈনন্দিন জীবন: রিমাইন্ডার, টাকা, গাড়ি — Assisto", "রিমাইন্ডার, নোট, জন্মদিন, হিসাব ও বাজেট, বাড়ি ভাড়া, প্রিপেইড মিটার, ডকুমেন্ট, গাড়ি ট্র্যাকিং ও আরও।"),
        "en": ("Daily life", "Reminders, money, bills, documents, vehicles and the small things — Assisto remembers.",
               "Daily life: reminders, money, vehicles — Assisto", "Reminders, notes, birthdays, money and budget, house rent, prepaid meters, documents, vehicle tracking and more."),
    },
}


def F(fid, icon, flags, shot, bn, en, auto=None, ai=False, soon=False):
    """One feature. bn/en = (title, two-line benefit); auto = (bn, en) — one
    line saying exactly what Assisto does BY ITSELF (shown only when live)."""
    return {"id": fid, "icon": icon, "flags": tuple(flags), "shot": shot,
            "bn": bn, "en": en, "auto": auto, "ai": ai, "soon": soon}


FEATURES = {
    "ai": [
        F("assistant", "sparkle", (), "home_v2_chat",  # "chat" once agent/aicardbn (Bangla digits on cards) is on main
          ("কথা বলে কাজ করান", "\"কাল ৮টায় মাকে ফোন\" বা \"দুপুরে ৫০০ খরচ\" — লিখুন বা বলুন, Assisto রিমাইন্ডার বা খরচ বানিয়ে দেয়। টাকা পাঠানোর মতো কাজে আগে আপনার অনুমতি নেয়।"),
          ("Get things done by talking", "Type or say \"call mum at 8 tomorrow\" or \"500 for lunch\" — Assisto makes the reminder or the expense. Anything like sending money waits for your OK."),
          auto=("একটা বাক্য থেকে নিজেই রিমাইন্ডার বা খরচের হিসাব বানায়", "Turns one sentence into a reminder or an expense by itself")),
        F("ask", "message", (), "home_v2_chat",
          ("যেকোনো প্রশ্ন, বাংলায় উত্তর", "বাংলা বা ইংরেজিতে প্রশ্ন করুন — পরিষ্কার উত্তর, চিঠি বা পোস্টের খসড়া, আপনার রিমাইন্ডার ও খরচের সারাংশ।"),
          ("Ask anything, answered in Bangla", "Ask in Bangla or English — get a clear answer, a draft letter or post, or a summary of your reminders and spending."),
          ai=True),
        F("voice", "mic", ("voice_assistant",), "voice_assistant",
          ("Assisto ভয়েস", "মাইকে চাপ দিয়ে বলুন — কল, অ্যালার্ম, টর্চ, খরচ লেখা বা SOS। বাংলা ও ইংরেজি দুটোই বোঝে।"),
          ("Assisto Voice", "Tap the mic and speak — call, alarm, torch, log an expense or send SOS. Understands Bangla and English.")),
        F("brief", "sunrise", ("daily_brief",), "daily_brief",
          ("দৈনিক ব্রিফ", "সকালে এক নজরে আজকের দিন: বাকি বিল, রিমাইন্ডার আর জন্মদিন — কোনটা আগে, তা সাজানো।"),
          ("Daily brief", "Your day at a glance each morning: bills due, reminders and birthdays — sorted by what comes first."),
          auto=("প্রতিদিন সকালে নিজেই আপনার দিনের তালিকা সাজিয়ে দেয়", "Prepares your day's list by itself every morning")),
        F("proactive", "bell", ("proactive_ai",), None,
          ("আগে থেকেই মনে করিয়ে দেয়", "পাসপোর্টের মেয়াদ শেষ হচ্ছে, বাজেট ছাড়িয়ে যাচ্ছে — আপনার নিজের তথ্য দেখে সময়মতো জানায়, সাথে \"কেন\"।"),
          ("Nudges before it's late", "Passport about to expire, budget about to run over — it tells you in time from your own data, with a \"why\"."),
          auto=("আপনার তথ্য দেখে নিজেই জরুরি বিষয় তুলে ধরে", "Spots what is urgent in your own data by itself")),
        F("memory", "brain", ("memory",), None,  # bn shot shows English digits (bn sweep) -> was "ai_knowledge"
          ("AI যা জানে, আপনি দেখেন", "Assisto কী মনে রেখেছে তা একটা পাতায় দেখুন — যেকোনোটা মুছুন, বা AI-কে পুরো বাদ দিন।"),
          ("See what the AI knows", "One page shows everything Assisto remembers — delete any item, or keep it away from AI entirely.")),
        F("ps", "user-tie", ("pa_secretary",), "pa_hub",
          ("পার্সোনাল সেক্রেটারি (পিএস)", "সময়সূচি, দর্শনার্থী ও অ্যাপয়েন্টমেন্ট, ফলো-আপ, চিঠি ও নোটিশ, কল ও ইমেইল — একজন পিএস-এর কাজ এক জায়গায়।"),
          ("Personal Secretary (PS)", "Schedule, visitors and appointments, follow-ups, letters and notices, calls and emails — a PS's desk in one place.")),
        F("inbox", "inbox", ("ai_inbox",), None,
          ("AI ইনবক্স", "আপনার মেইলবক্স জুড়লে কোনটার উত্তর দরকার আর কোনটা জরুরি, আলাদা করে দেখায়।"),
          ("AI Inbox", "Connect your mailbox and see what needs a reply and what is urgent, sorted for you."),
          ai=True),
        F("agent", "route", ("agent_core",), "ac_compose",
          ("Assisto এজেন্ট", "একটা লক্ষ্য দিন — এজেন্ট ধাপে ধাপে পরিকল্পনা করে, প্রতিটি বাইরের কাজের আগে আপনার অনুমতি নেয়।"),
          ("Assisto Agent", "Give it a goal — the agent plans it step by step and asks before every action that leaves the app."),
          auto=("লক্ষ্য থেকে নিজেই পরিকল্পনা বানিয়ে কাজ এগোয়", "Plans and moves the task forward by itself"), ai=True),
    ],
    "circle": [
        F("chat", "chat", ("my_circle",), "c3_chat_list",
          ("এনক্রিপ্টেড চ্যাট", "এক-এক ও গ্রুপ চ্যাট, ছবি, ভয়েস নোট আর ফাইল — আপনার ফোনেই তালাবদ্ধ; আমাদের সার্ভার বা AI পড়তে পারে না।"),
          ("Encrypted chat", "One-to-one and group chats, photos, voice notes and files — locked on your phone; neither our server nor our AI can read them.")),
        F("media", "image", ("my_circle",), "md1_chat",
          ("ছবি, ভয়েস ও ফাইল", "ভয়েস নোট, PDF, রসিদ আর ছবি পাঠান; একবার-দেখা ছবি আর নিজে-মুছে-যাওয়া মেসেজও আছে।"),
          ("Photos, voice and files", "Send voice notes, PDFs, receipts and photos — plus view-once photos and disappearing messages.")),
        F("calls", "video", ("calls",), "c2_call_video_connected",
          ("ভয়েস ও ভিডিও কল", "সার্কেলের মানুষকে এনক্রিপ্টেড ভয়েস ও ভিডিও কল; কল কখনো রেকর্ড হয় না।"),
          ("Voice and video calls", "Encrypted voice and video calls with your circle; calls are never recorded.")),
        F("pip", "pip", ("calls",), "callsa_float_video_chat",
          ("কলের মধ্যেও অ্যাপ চালান (PiP)", "ভিডিও কল ছোট ভাসমান জানালায় চলে — চ্যাট করুন বা অন্য অ্যাপ খুলুন, কল কাটবে না।"),
          ("Keep using your phone on a call (PiP)", "The video call shrinks into a small floating window — chat or open another app, the call stays on.")),
        F("bubbles", "bubble", ("my_circle",), None,  # real shot "bbl2_install_day_on" once agent/bubbles2 is on main
          ("ভাসমান চ্যাট বাবল", "Android ১১ বা নতুন ফোনে নতুন মেসেজ ভাসমান বাবলে আসে — যেকোনো অ্যাপের ওপর থেকেই পড়ুন ও উত্তর দিন।"),
          ("Floating chat bubbles", "On Android 11 or newer, new messages arrive as floating bubbles — read and reply on top of any app.")),
        F("status", "circle-dot", ("my_circle",), "p3_story_viewer",
          ("স্ট্যাটাস", "দিনের ছবি বা লেখা শুধু আপনার সার্কেলের সাথে শেয়ার করুন; কে দেখবে, আপনি ঠিক করেন।"),
          ("Status", "Share a photo or a line from your day with your circle only; you choose who sees it.")),
        F("channels", "megaphone", ("my_circle",), "chx_channel",
          ("চ্যানেল ও কমিউনিটি", "একসাথে অনেকের কাছে খবর পৌঁছান চ্যানেলে; এলাকা, অফিস বা পরিবারের গ্রুপগুলো একটা কমিউনিটিতে রাখুন।"),
          ("Channels and communities", "Reach many people at once with a channel; keep the groups of a neighbourhood, office or family together in a community.")),
    ],
    "safety": [
        F("sos", "sos", ("emergency",), "emergency_hub",
          ("SOS ও জরুরি হাব", "এক চাপে SOS — আপনার বেছে নেওয়া পরিবারের সদস্যরা লোকেশনসহ সতর্কতা পান; এক জায়গায় ৯৯৯, কাছের থানা ও জরুরি কার্ড।"),
          ("SOS and emergency hub", "One tap and the family members you chose get an alert with your location; 999, the nearest police station and your emergency card in one place."),
          auto=("কেউ না খুললে ২ মিনিট পরে নিজেই আবার ডাকে", "If nobody opens it, rings them again after 2 minutes by itself")),
        F("journey", "route", ("safe_journey",), "journey_live",
          ("নিরাপদ যাত্রা", "যাত্রা শুরু করুন — শুধু আপনার বেছে নেওয়া মানুষেরা যাত্রার সময় লাইভ লোকেশন পান; শেষে পথ মুছে যায়।"),
          ("Safe Journey", "Start a trip — only the people you chose see your live location, and only during the trip; the path is deleted at the end."),
          auto=("দেরি হলে নিজেই পরিবারকে সতর্ক করে", "Alerts your family by itself if you are late")),
        F("dest_alarm", "alarm", ("dest_alarm",), "dest_alarm",
          ("গন্তব্য অ্যালার্ম", "বাসে বা ট্রেনে ঘুমিয়ে পড়লেও চিন্তা নেই — নামার জায়গার কাছে এলে ফোন জাগিয়ে দেয়।"),
          ("Destination alarm", "Fall asleep on the bus or train — the phone wakes you as your stop gets close."),
          auto=("স্টপের কাছে এলে নিজেই আপনাকে জাগায়", "Wakes you by itself near your stop")),
        F("train", "train", ("train_tracker",), "train_live",
          ("ট্রেন ট্র্যাকার", "আপনার ট্রেন কোথায়, কত দেরি — যাত্রীদের শেয়ার করা অবস্থান থেকে; পরিবারও দেখতে পারে।"),
          ("Train tracker", "Where your train is and how late — from what passengers share; your family can follow too.")),
        F("family", "family", ("family",), "famcare_card",
          ("পরিবারের যত্ন", "পরিবারের জরুরি কার্ড, স্কুলের ফি ও পরীক্ষা, পরিবারের হিসাব আর শেয়ারিং — সবার জন্য এক জায়গায়।"),
          ("Family care", "Family emergency card, school fees and exams, family accounts and sharing — one place for everyone.")),
        F("kids", "child", ("kid_school",), "famcare_school",
          ("শিশুর স্কুল কর্নার", "ফি, পরীক্ষা আর স্কুলের মিটিং — তারিখ এলে মনে করিয়ে দেয়।"),
          ("Child's school corner", "Fees, exams and school meetings — reminded when the date comes.")),
        F("kids_watch", "watch", ("kids_watch",), "kids_watch",
          ("বাচ্চাদের ঘড়ি ও স্কুল-মোড", "বাচ্চার ঘড়ির শেষ লোকেশন আর স্কুল-মোড — বাবা-মা দেখেন, বাচ্চা জানে।"),
          ("Kids watch and School Mode", "Your child's watch location and School Mode — parents see it, the child knows.")),
        F("elder", "heart-hand", ("family",), None,
          ("বয়স্কদের সহজ হোম", "বড় বোতাম, অল্প কাজ: SOS, পরিবারকে কল, মেসেজ আর সাহায্য — বাবা-মায়ের ফোনে সহজে।"),
          ("Simple home for elders", "Big buttons, few choices: SOS, call family, messages and help — easy on your parents' phone.")),
        F("lost_phone", "phone-lock", ("anti_theft",), "at_protection_on",
          ("হারানো বা চুরি হওয়া ফোন", "অন্য ফোন থেকে স্ক্রিন লক, জোরে অ্যালার্ম, \"হারানো ফোন\" লেখা আর শেষ লোকেশন। ফোন চালু ও অনলাইনে থাকতে হবে।"),
          ("Lost or stolen phone", "From another phone: lock the screen, sound a loud alarm, show a \"lost phone\" message and see the last location. The phone must be on and online."),
          auto=("SIM বদল, ছিনতাই বা ফোন বন্ধ হলে নিজেই জানায়", "Alerts you by itself on a SIM change, a snatch or the phone going offline")),
        F("missing", "search-person", ("missing_alert",), "missing_hub",
          ("নিখোঁজ সতর্কতা", "কেউ নিখোঁজ হলে কাছের Assisto ব্যবহারকারীদের সতর্ক করুন; তথ্য আসে গোপনে আপনার কাছে।"),
          ("Missing person alert", "When someone goes missing, alert nearby Assisto users; information comes to you privately.")),
        F("blood", "drop", ("blood_donor",), "blood_hub",
          ("রক্তদাতা", "কাছের রক্তদাতা খুঁজুন বা নিজে দাতা হন; নম্বর গোপন থাকে, কথা হয় অ্যাপের ভেতরে।"),
          ("Blood donors", "Find donors near you or become one; numbers stay private and you talk inside the app.")),
        F("scam", "alert", ("scam_check",), "scam",
          ("প্রতারণা চেক", "সন্দেহজনক মেসেজ পেস্ট করুন — পরিচিত প্রতারণার ধরন মিলিয়ে ঝুঁকি আর কারণ দেখায়।"),
          ("Scam check", "Paste a suspicious message — it is matched against known scam patterns and you see the risk and why.")),
        F("disaster", "cloud", ("disaster_alerts",), None,
          ("দুর্যোগ সতর্কতা", "সরকারি আবহাওয়া ও দুর্যোগ সতর্কতা আপনার আর পরিবারের এলাকার জন্য, সাথে প্রস্তুতির তালিকা।"),
          ("Disaster alerts", "Official weather and disaster warnings for your area and your family's, with a preparedness checklist."),
          auto=("পরিবারের এলাকায় সতর্কতা এলে নিজেই জানায়", "Tells you by itself when a warning hits your family's area")),
        F("nominee", "key", ("nominee",), None,  # bn shot shows English digits (bn sweep) -> was "nominee"
          ("নমিনি অ্যাক্সেস", "দরকারি সময়ে পরিবারের বিশ্বস্ত কেউ যেন আপনার জরুরি তথ্য পান — আপনি ঠিক করেন কে, কী, কখন।"),
          ("Nominee access", "Make sure a trusted family member can reach your important information when it matters — you decide who, what and when.")),
        F("fall", "fall", ("fall_detect",), None,
          ("দুর্ঘটনা বা পড়ে যাওয়া শনাক্ত", "জোরে পড়ে গেলে ফোন জিজ্ঞেস করে \"আপনি ঠিক আছেন?\" — উত্তর না দিলে পরিবারকে জানায়।"),
          ("Fall detection", "After a hard fall the phone asks \"Are you OK?\" — no answer, and your family is told.")),
    ],
    "cctv": [
        F("shop_box", "phone-cam", ("cctv_watchman",), "shop_box",
          ("ফোনকেই ক্যামেরা বানান (শপ বক্স)", "একটা বাড়তি Android ফোন দোকানের ক্যামেরা হয়ে যায় — ফোনেই শনাক্ত করে, শুধু সংকেত আর দরকার হলে একটা ছবি পাঠায়।"),
          ("Turn a phone into a camera (Shop Box)", "A spare Android phone becomes the shop camera — it detects on the phone and sends only a signal and, when needed, one photo."),
          auto=("কিছু শনাক্ত করলে নিজেই একটা ছবিসহ জানায়", "Alerts you by itself with one photo when it detects something")),
        F("smart_alerts", "bell", ("home_watchman",), "wm_alerts",
          ("স্মার্ট সতর্কতা", "আপনার আঁকা জোনে মানুষ দেখলে ছবিসহ সতর্কতা; ভুল হলে \"ভুল\" চাপুন — পরের বার আরও ঠিক।"),
          ("Smart alerts", "A person in the zone you drew means a photo alert; mark a wrong one and the next one is better."),
          auto=("জোনে মানুষ দেখলে নিজেই ছবিসহ সতর্ক করে", "Spots a person in your zone and alerts you with a photo by itself")),
        F("live", "eye", ("home_watchman",), "wm_viewer",
          ("লাইভ দেখা", "Imou, Hikvision, Dahua বা ONVIF ক্যামেরা জুড়ুন — যেখানেই থাকুন, দোকান বা বাড়ি লাইভ দেখুন; পরিবারকেও দেখার অনুমতি দিন।"),
          ("Live view", "Connect Imou, Hikvision, Dahua or ONVIF cameras — watch the shop or home live from anywhere, and let family view too.")),
        F("evidence", "file-check", ("home_watchman",), "cx_alert_actions",
          ("প্রমাণ-প্যাক", "এক চাপে ছবি, সময় আর SHA-256 আঙুলছাপসহ থানার GD-র জন্য প্রমাণ-প্যাক তৈরি।"),
          ("Evidence pack", "One tap builds an evidence pack for a police GD — photos, times and SHA-256 fingerprints.")),
        F("cash_guard", "cash", ("cctv_watchman",), "shop_eod",
          ("দিনশেষের ক্যাশ মেলানো", "ড্রয়ারে কত আছে লিখুন — দিনের বিক্রির সাথে মিলিয়ে কম-বেশি সাথে সাথে দেখায়।"),
          ("End-of-day cash check", "Enter what is in the drawer — it is matched against the day's sales and any gap shows at once.")),
        F("guard_box", "shield", ("guard_box_mode",), "gb_running",
          ("গার্ড বক্স (পুরনো ফোন)", "দোকানের Wi-Fi-তে রাখা পুরনো একটা ফোন আপনার ক্যামেরা দেখে আর সতর্ক করে — আলাদা কম্পিউটার লাগে না।"),
          ("Guard Box (old phone)", "An old phone on the shop's Wi-Fi watches your cameras and alerts you — no extra computer needed.")),
    ],
    "business": [
        F("khata", "book", ("business",), "biz_khata",
          ("ডিজিটাল খাতা ও তাগাদা", "কার কাছে কত বাকি, কে কত দিল — এক পাতায়; খাতা চিরকাল ফ্রি।"),
          ("Digital khata and due reminders", "Who owes what and who paid — on one page; the khata is free forever."),
          auto=("আপনার ঠিক করা সময়ে নিজেই বাকির তাগাদা পাঠায়, টাকা পেলে থামে", "Sends due reminders on your schedule by itself, and stops once paid")),
        F("accounts", "chart", ("business",), "acct_home",
          ("ব্যবসার হিসাব", "বিক্রি, কেনা, খরচ আর বাকি এক চাপে লিখুন — লাভ-ক্ষতি, ক্যাশ ফ্লো, VAT সারাংশ তৈরি।"),
          ("Business accounts", "Log sales, purchases, expenses and credit in one tap — profit and loss, cash flow and a VAT summary are ready.")),
        F("invoices", "receipt", ("business",), "inv_paper_80",
          ("থার্মাল ও A4 ইনভয়েস", "৫৮ বা ৮০ মিমি থার্মাল প্রিন্টার বা A4 — বাংলা বা ইংরেজিতে, VAT ও QR-সহ পরিষ্কার ইনভয়েস, এক চাপে।"),
          ("Thermal and A4 invoices", "58 or 80 mm thermal or A4 — a clean invoice in Bangla or English with VAT and a QR code, in one tap.")),
        F("sales_ai", "bot", ("business_agent",), "g1_agent_answers",
          ("AI সেলস সহকারী", "আপনার নিজের পণ্য, দাম আর FAQ থেকে গ্রাহকের প্রশ্নের উত্তর দেয়; নিশ্চিত না হলে আপনাকে দেয়।"),
          ("AI sales assistant", "Answers customer questions from your own products, prices and FAQ; hands over to you when it isn't sure."),
          auto=("গ্রাহকের মেসেজের উত্তর নিজেই দেয়, অর্ডার নোট করে", "Replies to customer messages and notes the order by itself")),
        F("crm", "users", ("crm",), None,  # bn shot shows English digits (bn sweep) -> was "crm_lead_detail"
          ("CRM", "গ্রাহক, লিড, পাইপলাইন আর কোটেশন — কার সাথে কবে ফলো-আপ, ভুলে যাবেন না।"),
          ("CRM", "Customers, leads, pipeline and quotes — never miss whom to follow up and when.")),
        F("crm_auto", "repeat", ("retention_auto",), "rt_list",
          ("CRM অটোমেশন", "কেনার পরে ধন্যবাদ, অনেক দিন না এলে \"ফিরে আসুন\", জন্মদিনের শুভেচ্ছা — নিয়ম একবার ঠিক করুন।"),
          ("CRM automation", "Thank-you after a purchase, \"we miss you\" after a long gap, birthday wishes — set the rule once."),
          auto=("নিয়ম অনুযায়ী গ্রাহককে নিজেই মেসেজ পাঠায়", "Messages customers by itself on your rules")),
        F("shop_ops", "store", ("business",), "biz_reports",
          ("দোকান চালানো", "কুইক সেল, পণ্য ও স্টক, অর্ডার, ক্যাশ বক্স, স্টাফ আর দৈনিক রিপোর্ট — এক ফোনে পুরো দোকান।"),
          ("Run the shop", "Quick sell, products and stock, orders, the cash box, staff and a daily report — the whole shop on one phone."),
          auto=("স্টক কমে গেলে নিজেই জানায়", "Tells you by itself when stock runs low")),
        F("shop_agent", "sparkle", ("agent_core",), "bizops_card",
          ("ব্যবসার দৈনিক AI এজেন্ট", "সকালে দোকানের কার্ড: কালকের বিক্রি ও লাভ, আজ কাকে তাগাদা, কী শেষ হচ্ছে — এক চাপে কাজ।"),
          ("Daily business AI agent", "A morning shop card: yesterday's sales and profit, whom to remind today, what is running out — act in one tap."),
          auto=("প্রতিদিন সকালে নিজেই দোকানের হিসাব সাজিয়ে দেয়", "Prepares your shop's day by itself every morning"), ai=True),
        F("booking", "calendar", ("booking_bot",), "bkg_today",
          ("বুকিং বট", "গ্রাহক লিংক থেকে নিজেই সময় নেন; আপনি দেখেন আজ কার কখন।"),
          ("Booking bot", "Customers book a time from your link; you see who is coming when.")),
        F("books", "ledger", ("accounting_v2",), "books_pl",
          ("পূর্ণ হিসাবের খাতা", "ডাবল-এন্ট্রি খাতা, ব্যালান্স শিট আর ট্রায়াল ব্যালান্স — হিসাবরক্ষকের জন্য প্রস্তুত।"),
          ("Full books", "Double-entry books, balance sheet and trial balance — ready for your accountant.")),
    ],
    "work": [
        F("tasks", "check", ("task_manager",), None,
          ("টাস্ক ম্যানেজার", "প্রজেক্ট বানান, কাজ যোগ করুন, বোর্ডে এগোনো দেখুন।"),
          ("Task manager", "Create a project, add tasks and watch them move across the board.")),
        F("jobs", "briefcase", ("jobs",), None,  # bn shot shows English digits (bn sweep) -> was "jobs"
          ("জব হান্টার", "যে চাকরিগুলো পান, সংরক্ষণ করুন আর আবেদনের অবস্থা এক জায়গায় রাখুন।"),
          ("Job hunter", "Save the jobs you find and keep track of every application in one place.")),
        F("cv", "file", ("cv_builder",), None,
          ("CV বিল্ডার", "আপনার তথ্য দিন — পরিষ্কার, শেয়ার করার মতো CV তৈরি।"),
          ("CV builder", "Add your details and get a clean CV ready to share.")),
        F("interview", "mic", ("mock_interview",), "mock_iv",
          ("মক ইন্টারভিউ", "বিষয় বেছে প্রশ্নের উত্তর দিন — নিয়মভিত্তিক মতামত আর একটা নমুনা কাঠামো পান।"),
          ("Mock interview", "Pick a topic, answer the questions and get rule-based feedback with a model outline.")),
        F("writing", "pen", ("blog_writer",), "blog",
          ("ব্লগ ও স্ক্রিপ্ট লেখা", "ব্লগ, ভিডিও স্ক্রিপ্ট বা ক্যাপশনের কাঠামো — বাংলা, বাংলিশ বা ইংরেজিতে।"),
          ("Blog and script writing", "An outline for a blog, video script or caption — in Bangla, Banglish or English.")),
        F("estimate", "calc", ("cost_estimator",), "cost_est",
          ("খরচ ও সময় হিসাব", "কাজের ধাপ আর দাম দিন — মোট খরচ ও সময় হিসাব হয়ে যায়।"),
          ("Cost and time estimator", "Enter the steps and prices — total cost and time are worked out.")),
        F("contract", "file-check", ("contract_analyzer",), "contract",
          ("চুক্তি বিশ্লেষক", "চুক্তির লেখা পেস্ট করুন — ঝুঁকির জায়গাগুলো আলাদা করে দেখায়।"),
          ("Contract analyzer", "Paste the contract text and see the risky parts pointed out.")),
        F("scanner", "scan", ("doc_scanner",), None,
          ("ডকুমেন্ট স্ক্যানার", "কাগজের ছবি তুলে গুছিয়ে রাখুন — NID, পাসপোর্ট, সার্টিফিকেট আলাদা ট্যাগে।"),
          ("Document scanner", "Snap paper documents and keep them tidy — NID, passport and certificates under their own tags.")),
        F("meetings", "calendar", ("meetings",), None,
          ("মিটিং ও অ্যাপয়েন্টমেন্ট", "দিন, সপ্তাহ বা মাসের ভিউতে মিটিং — যাওয়ার সময়সহ মনে করিয়ে দেয়।"),
          ("Meetings and appointments", "Meetings in day, week or month view — reminded with travel time.")),
        F("quick_tools", "grid", ("quick_tools",), None,
          ("কুইক টুলস", "প্রতিদিনের ছোট দরকারি টুল, এক জায়গায়।"),
          ("Quick tools", "Small everyday tools, in one place.")),
        F("studio", "sparkle", ("agent_studio",), None,
          ("এজেন্ট স্টুডিও", "নিজের কাজের জন্য নিজের এজেন্ট বানান।"),
          ("Agent Studio", "Build your own agent for your own work.")),
    ],
    "daily": [
        F("reminders", "bell", ("reminders",), "p3_chat_reminder",
          ("রিমাইন্ডার", "এক লাইনে লিখুন বা বলুন — একবারের বা প্রতি সপ্তাহের রিমাইন্ডার, সময়মতো বাজে।"),
          ("Reminders", "Type or say one line — one-off or weekly reminders that ring on time."),
          auto=("সময়মতো নিজেই বাজে, বারবার হওয়াগুলো নিজেই চলে", "Rings on time by itself; repeating ones run on their own")),
        F("notes", "note", ("notes",), "notes_tasks",
          ("নোট ও কাজের তালিকা", "চেকলিস্ট, ট্যাগ আর রঙ — বাজারের লিস্ট থেকে ভাড়ার চুক্তি পর্যন্ত।"),
          ("Notes and to-dos", "Checklists, tags and colours — from the market list to the rent agreement.")),
        F("birthdays", "cake", ("birthdays",), "birthdays",
          ("জন্মদিন ও স্মরণীয় দিন", "কাছের মানুষের জন্মদিন আর বিশেষ দিন — কখনো ভুলবেন না।"),
          ("Birthdays and special days", "Birthdays and special days of your people — never forgotten."),
          auto=("দিনটা আসার আগে নিজেই মনে করিয়ে দেয়", "Reminds you by itself before the day")),
        F("money", "wallet", ("money",), "money",
          ("হিসাব ও অর্থ", "আয়, খরচ, ঋণ, নেট ওয়ার্থ আর মাসিক সারাংশ। Assisto কখনো আপনার টাকা রাখে না।"),
          ("Money", "Income, expenses, loans, net worth and a monthly summary. Assisto never holds your money.")),
        F("budget", "pie", ("budget",), "rhb_budget_month",
          ("বাজেট", "খাত অনুযায়ী বাজেট — কোথায় বেশি যাচ্ছে, সাথে সাথে দেখায়।"),
          ("Budget", "A budget per category — see at once where money is running over.")),
        F("money_voice", "mic", ("money_voice",), "money_voice",
          ("মুখে বলে খরচ লেখা", "\"চা ২০ টাকা\" বলুন — খরচ লেখা হয়ে যায়, আপনি নিশ্চিত করলে।"),
          ("Log money by voice", "Say \"tea 20 taka\" and the expense is written — once you confirm.")),
        F("wrapped", "spark-card", ("money_wrapped",), "money_wrapped_data",
          ("টাকার রিক্যাপ", "প্রতি মাসে আপনার টাকার গল্প এক কার্ডে — শেয়ার করার মতো।"),
          ("Money Wrapped", "Your month in money on one card — made to share."),
          auto=("মাস শেষে নিজেই রিক্যাপ বানায়", "Builds your monthly recap by itself")),
        F("subscriptions", "repeat", ("subscriptions",), "subscriptions",
          ("সাবস্ক্রিপশন ও বিল", "ইন্টারনেট, Netflix, জিম — মাসে আর বছরে কত যায়, কোনটা সামনে।"),
          ("Subscriptions and bills", "Internet, Netflix, the gym — what goes out each month and year, and what is next.")),
        F("tax", "percent", ("tax_zakat",), "money_tax",
          ("কর ও যাকাত", "আয়করের আনুমানিক হিসাব আর যাকাত ক্যালকুলেটর — সরকারি সার্কুলারের লিংকসহ।"),
          ("Tax and zakat", "An income-tax estimate and a zakat calculator — with a link to the official circular.")),
        F("split", "split", ("expense_split",), None,
          ("খরচ ভাগাভাগি", "বন্ধুদের সাথে ভ্রমণ বা খাওয়ার খরচ — কে কাকে কত দেবে, হিসাব তৈরি।"),
          ("Split expenses", "Trips and meals with friends — who owes whom is worked out.")),
        F("mess", "home", ("mess_accounting",), None,
          ("মেস ও ব্যাচেলর হিসাব", "মিল, বাজার আর জমা লিখুন — প্রতিজনের হিসাব ঠিকঠাক।"),
          ("Mess and bachelor accounts", "Log meals, groceries and deposits — everyone's balance comes out right.")),
        F("samity", "users", ("samity",), None,
          ("সমিতি", "প্রতি কিস্তির জমা আর কার পালা — সবার কাছে স্বচ্ছ। Assisto টাকা রাখে না, শুধু হিসাব রাখে।"),
          ("Samity", "Each round's contributions and whose turn it is — clear to all. Assisto keeps the record, never the money.")),
        F("rent", "building", ("house_rent",), None,  # bn shot shows English digits (bn sweep) -> was "landlord"
          ("বাড়ি ভাড়া", "প্রতিটি ফ্ল্যাটের ভাড়া, কে দিল, কার বাকি — মাস ধরে।"),
          ("House rent", "Rent per flat, who paid and who is behind — month by month.")),
        F("meter", "bolt", ("prepaid_meter",), "meter",
          ("প্রিপেইড মিটার", "বিদ্যুৎ বা গ্যাসের মিটারে আনুমানিক কত বাকি, কবে শেষ হবে।"),
          ("Prepaid meters", "How much is left on your electricity or gas meter, and when it runs out."),
          auto=("ব্যালান্স ফুরানোর আগে নিজেই সতর্ক করে", "Warns you by itself before the balance runs out")),
        F("remittance", "globe", ("budget_remittance",), "rmt_month",
          ("বাজেট ও রেমিট্যান্স", "বিদেশ থেকে আসা টাকা কে কত পাঠাল, আর কোথায় খরচ হলো — পরিবারের জন্য।"),
          ("Budget and remittance", "Money sent from abroad — who sent how much and where it went, for the family.")),
        F("documents", "lock", ("documents",), "vault",
          ("ডকুমেন্ট ভল্ট", "পাসপোর্ট, NID, লাইসেন্স — PIN-এ তালা; ফোন হারালেও ডকুমেন্ট হারায় না।"),
          ("Document vault", "Passport, NID, licence — PIN-locked; lose the phone, keep the documents.")),
        F("vehicles", "car", ("vehicle_tracking",), "veh_tracking",
          ("গাড়ি ট্র্যাকিং", "নিজের GPS ট্র্যাকার জুড়ে গাড়ি বা বাইক লাইভ দেখুন, Car Mode আর OBD রিডিং। হার্ডওয়্যার আলাদা।"),
          ("Vehicle tracking", "Connect your own GPS tracker to see a car or bike live, plus Car Mode and OBD readings. Hardware not included."),
          auto=("গতি বা সীমানা পার হলে নিজেই সতর্ক করে", "Alerts you by itself on over-speed or leaving a zone")),
        F("vehicle_papers", "file", ("vehicles",), None,
          ("আমার গাড়ির কাগজ", "ট্যাক্স টোকেন, ফিটনেস আর ইন্স্যুরেন্সের তারিখ — জরিমানার আগেই মনে করানো।"),
          ("My vehicle papers", "Tax token, fitness and insurance dates — reminded before any fine."),
          auto=("৩০, ৭ আর ১ দিন আগে নিজেই মনে করায়", "Reminds you by itself 30, 7 and 1 day before")),
        F("photo", "image", ("photo_studio",), "photo_studio_free_enhanced",
          ("ফটো স্টুডিও", "এক চাপে ছবি উজ্জ্বল ও পরিষ্কার — ফোনেই, ইন্টারনেট খরচ ছাড়াই।"),
          ("Photo Studio", "One tap makes a photo sharper and brighter — on the phone, no data needed.")),
        F("guide", "compass", ("service_guide",), "guide",
          ("সেবা গাইড", "NID, পাসপোর্ট আর সরকারি সেবা ধাপে ধাপে — অফিসিয়াল লিংকসহ।"),
          ("Service guide", "NID, passport and government services step by step — with official links.")),
        F("exam", "school", ("exam_result",), None,  # bn shot shows English digits (bn sweep) -> was "exam"
          ("পরীক্ষার ফলাফল", "SSC, HSC-র ফলাফলের পাতা Assisto দেখে রাখে — বদলালেই জানায়।"),
          ("Exam results", "Assisto keeps an eye on the SSC or HSC result page — and tells you when it changes."),
          auto=("ফলাফলের পাতা বদলালে নিজেই নোটিফিকেশন দেয়", "Notifies you by itself when the result page changes")),
        F("ride_food", "bike", ("ride_food",), None,
          ("রাইড ও খাবার", "গন্তব্য লিখুন — Uber, Pathao বা খাবারের অ্যাপ সরাসরি সেই জায়গায় খোলে।"),
          ("Ride and food", "Type where you're going — Uber, Pathao or a food app opens straight there.")),
        F("ramadan", "moon", ("ramadan",), "ramadan",
          ("রমজান মোড", "সেহরি-ইফতারের সময়, রোজার হিসাব আর যাকাত ক্যালকুলেটর।"),
          ("Ramadan mode", "Sehri and iftar times, a fasting tracker and a zakat calculator.")),
        F("price_radar", "tag", ("price_radar",), None,
          ("বাজার দাম রাডার", "TCB-র সরকারি বাজার দর আর নিজের লেখা দাম — কোনটা বাড়ছে, দেখুন।"),
          ("Market price radar", "Official TCB market prices and your own logged prices — see what is going up.")),
        F("dictionary", "book", ("dictionary",), None,
          ("অভিধান", "বাংলা ↔ ইংরেজি শব্দের মানে আর উদাহরণ।"),
          ("Dictionary", "Bangla ↔ English meanings with examples.")),
        F("unseen", "map", ("unseen_bangladesh",), None,
          ("অদেখা বাংলাদেশ", "দেশের ঘোরার জায়গা — কোন মৌসুমে কোথায় যাবেন।"),
          ("Unseen Bangladesh", "Places to visit across the country — where to go in which season.")),
        F("probashi", "globe", ("probashi",), None,
          ("প্রবাসী কর্নার", "বিদেশে থাকা বাংলাদেশিদের দরকারি তথ্য ও টুল, এক জায়গায়।"),
          ("Probashi corner", "Information and tools for Bangladeshis abroad, in one place.")),
        F("farmer", "leaf", ("farmer_mode",), None,
          ("কৃষক মোড", "কৃষকের দরকারি তথ্য ও টুল, এক জায়গায়।"),
          ("Farmer mode", "Information and tools for farmers, in one place.")),
        F("student", "school", ("student_corner",), None,
          ("স্টুডেন্ট কর্নার", "শিক্ষার্থীদের দরকারি টুল, এক জায়গায়।"),
          ("Student corner", "Handy tools for students, in one place.")),
        F("wedding", "rings", ("wedding_events",), None,
          ("বিয়ে ও অনুষ্ঠান", "বিয়ে বা অনুষ্ঠানের পরিকল্পনা, এক জায়গায়।"),
          ("Weddings and events", "Plan a wedding or an event, in one place.")),
        F("qurbani", "moon", ("qurbani",), None,
          ("কোরবানি ও ঈদ পরিকল্পনা", "কোরবানি আর ঈদের পরিকল্পনা, এক জায়গায়।"),
          ("Qurbani and Eid planner", "Plan qurbani and Eid, in one place.")),
        F("fitness", "steps", ("smartwatch",), None,
          ("স্মার্টওয়াচ ও ফিটনেস", "আপনি অনুমতি দিলে Health Connect থেকে হাঁটা ও ঘুমের হিসাব দেখায়।"),
          ("Smartwatch and fitness", "With your permission, shows your steps and sleep from Health Connect.")),
        F("language", "chat", ("language_partner",), None,
          ("ভাষা শেখার সঙ্গী", "প্রতিদিন একটু করে ভাষা অনুশীলন।"),
          ("Language partner", "Practise a language a little every day."), ai=True),
        F("travel", "map", ("travel_planner",), None,
          ("ভ্রমণ পরিকল্পনা", "ভ্রমণের পরিকল্পনা, এক জায়গায়।"),
          ("Travel planner", "Plan a trip, in one place.")),
    ],
}

# The owner's planned CCTV prices (CCTV order H, 3 Nov). No live CCTV plan
# exists in code yet → always rendered under "Coming soon", never as a buy.
CCTV_PLAN = {"base": 500, "base_cams": 2, "extra": 250, "max_cams": 10,
             "clip7": 100, "clip30": 150, "trial_days": 7}

# ------------------------------------------------------------------ copy
COPY = {
    "bn": {
        "html_lang": "bn", "title": "Assisto — নিজে থেকেই কাজ করা AI সহকারী",
        "desc": "Assisto: বাংলা ও ইংরেজি বোঝা AI সহকারী — দিন সামলায়, পরিবারকে নিরাপদ রাখে, ব্যবসা বাড়ায়, নিজে থেকেই। রিমাইন্ডার, SOS, এনক্রিপ্টেড চ্যাট, খাতা, CCTV।",
        "skip": "মূল লেখায় যান", "menu": "মেনু", "close": "বন্ধ করুন",
        "nav_features": "ফিচার", "nav_pricing": "দাম", "nav_security": "নিরাপত্তা", "nav_faq": "প্রশ্নোত্তর", "nav_help": "সাহায্য",
        "lang_name": "English", "lang_label": "Switch to English",
        "hero_kicker": "নিজে থেকেই কাজ করে",
        # owner HERO order 3 Nov 03:30 (exact meaning; "Assisto:" + colon kept)
        "hero_h1": "Assisto: চ্যাট, কল, AI সহকারী, নিরাপত্তা আর ব্যবসা —", "hero_h1_g": "এক সুপার অ্যাপে।",
        "hero_slogan": "অনেক অ্যাপ নয়, একটাই Assisto।",
        "hero_sub": "আপনজনের সাথে চ্যাট ও কল করুন, পরিবারের সাথে লাইভ লোকেশন ও SOS শেয়ার করুন, আপনার CCTV দেখুন, দোকানের হিসাব ও ইনভয়েস চালান। Assisto-র AI মনে করিয়ে দেয়, সতর্ক করে আর হিসাব গুছিয়ে রাখে।",
        "cta_play": "Google Play থেকে নিন", "cta_features": "সব ফিচার দেখুন",
        "hero_note": "Android ৮ বা নতুন · ফ্রিতে শুরু · পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি",
        "auto": "নিজে থেকে", "auto_label": "স্বয়ংক্রিয়", "soon": "শীঘ্রই আসছে",
        "auto_strip_h": "আজই যা নিজে থেকে করে",
        "what_h": "Assisto কী?",
        "what_lead": "অনেক অ্যাপের বদলে একটা অ্যাপ — যে আপনার ভাষা বোঝে, আর শুধু উত্তর না দিয়ে কাজটা করে দেয়।",
        "what": [
            ("apps", "অনেক অ্যাপের বদলে একটা", "চ্যাট ও কল, রিমাইন্ডার, টাকার হিসাব, পরিবারের নিরাপত্তা, দোকানের খাতা, CCTV — আলাদা আলাদা অ্যাপ খুঁজতে হয় না।"),
            ("mic", "বাংলা ও ইংরেজি — লিখে বা বলে", "যেভাবে কথা বলেন, সেভাবেই লিখুন বা বলুন। \"কাল ৮টায় মাকে ফোন\" — বাকিটা Assisto বোঝে।"),
            ("bolt", "শুধু উত্তর না, কাজ করে", "রিমাইন্ডার বাজায়, বাকির তাগাদা পাঠায়, দেরি হলে পরিবারকে জানায়, সকালে দিনের তালিকা আর দোকানের রিপোর্ট দেয়। টাকা পাঠানো বা পোস্ট করার আগে সবসময় আপনার অনুমতি নেয়।"),
            ("lock", "আপনার তথ্য আপনারই", "চ্যাট end-to-end এনক্রিপ্টেড — আমাদের সার্ভার বা AI পড়তে পারে না। AI কী মনে রাখে, দেখতে ও মুছতে পারেন। আমরা ডেটা বিক্রি করি না।"),
        ],
        "groups_h": "সব ফিচার, দল অনুযায়ী", "groups_lead": "প্রতিটি দলের নিজের পাতা আছে — প্রতিটি ফিচারের আসল স্ক্রিনশটসহ।",
        "see_all": "সব দেখুন", "n_features": "টি ফিচার",
        "pricing_h": "দাম", "pricing_lead": "ফ্রিতে শুরু করুন। পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি। পেইড প্ল্যান Google Play থেকে কেনা যায়।",
        "per_month": "/মাস", "per_year": "/বছর", "free": "ফ্রি", "yearly": "বার্ষিক প্ল্যান",
        "no_plans": "প্ল্যানের দাম অ্যাপের ভেতরে দেখুন।",
        "cctv_plans_h": "CCTV প্ল্যান", "cctv_plans_note": "CCTV প্ল্যান এখনো কেনা যায় না। পরিকল্পিত দাম:",
        "security_h": "নিরাপত্তা ও গোপনীয়তা", "security_lead": "কোনটা end-to-end এনক্রিপ্টেড আর কোনটা নয় — সোজা ভাষায়।",
        "never_h": "আমরা যা কখনো করি না",
        "faq_h": "প্রশ্নোত্তর", "more_h": "আরও জানুন",
        "cta_h": "আজই শুরু করুন — ফ্রিতে",
        "cta_p": "Google Play থেকে Assisto নিন। বাংলা বা ইংরেজি, আপনার পছন্দ।",
        "footer_made": "বাংলাদেশে তৈরি", "footer_company": "AXON Dynamic",
        "f_privacy": "গোপনীয়তা নীতি", "f_terms": "শর্তাবলি", "f_delete": "অ্যাকাউন্ট মুছুন", "f_help": "সাহায্য ও যোগাযোগ",
        "f_tools": "ফ্রি টুল", "not_emergency": "Assisto জরুরি সেবা নয় — বিপদে ৯৯৯-এ ফোন করুন।",
        "shot_alt": "Assisto অ্যাপের স্ক্রিনশট: ",
        "group_back": "সব ফিচার", "on_this_page": "এই পাতায়",
        "preview_banner": "প্রিভিউ — এই পাতা এখনো লাইভ নয়, সার্চ ইঞ্জিনে আসে না।",
        "ai_note": "AI ভুল করতে পারে — দরকারি তথ্য যাচাই করুন।",
        "install_now": "ইনস্টল করুন", "viewer": "স্ক্রিনশট বড় করে দেখা", "play_soon": "শীঘ্রই Play Store-এ আসছে — এখনই সরাসরি APK থেকে ইনস্টল করুন।",
        "apk_link": "সরাসরি APK ডাউনলোড", "apk_version": "সংস্করণ", "apk_size": "আকার", "apk_date": "তারিখ",
        "chips_label": "দ্রুত যান", "chip_home": "হোম", "chip_ai": "AI সহকারী", "chip_circle": "আমার সার্কেল",
        "chip_safety": "নিরাপত্তা", "chip_cctv": "CCTV", "chip_business": "ব্যবসা", "chip_pricing": "দাম", "chip_download": "ডাউনলোড",
        "to_top": "উপরে যান", "pause": "স্ক্রিনশট চলা থামান বা চালান",
        "slide_chat": "কথা বলে রিমাইন্ডার ও খরচ", "slide_emergency_hub": "SOS ও জরুরি হাব",
        "slide_wm_alerts": "CCTV স্মার্ট সতর্কতা", "slide_acct_home": "ব্যবসার হিসাব ও খাতা",
        "slide_c3_chat": "আমার সার্কেলে চ্যাট", "slide_callpip_pip_window": "ভিডিও কল, ছোট ভাসমান জানালায় (PiP)",
        "slide_location_sharing": "লাইভ লোকেশন", "slide_inv_paper_80": "ইনভয়েস",
        "slide_dest_alarm": "গন্তব্য অ্যালার্ম", "slide_ai": "AI সহকারী",
    },
    "en": {
        "html_lang": "en", "title": "Assisto — the AI assistant that does the work by itself",
        "desc": "Assisto: an AI assistant that understands Bangla and English — runs your day, keeps your family safe and grows your business, by itself. Reminders, SOS, encrypted chat, khata, CCTV.",
        "skip": "Skip to content", "menu": "Menu", "close": "Close",
        "nav_features": "Features", "nav_pricing": "Pricing", "nav_security": "Security", "nav_faq": "FAQ", "nav_help": "Help",
        "lang_name": "বাংলা", "lang_label": "বাংলায় দেখুন",
        "hero_kicker": "Does the work by itself",
        # owner HERO order 3 Nov 03:30 — EXACT text
        "hero_h1": "Assisto: Chat, calls, AI assistant, safety and business,", "hero_h1_g": "in one super app.",
        "hero_slogan": "Many apps. One Assisto.",
        "hero_sub": "Chat and call your people, share live location and SOS with family, watch your CCTV, run your shop's accounts and invoices. Assisto's AI reminds, alerts and keeps your books in order.",
        "cta_play": "Get it on Google Play", "cta_features": "See every feature",
        "hero_note": "Android 8 or newer · Start free · Family safety free on every plan",
        "auto": "Auto", "auto_label": "Automatic", "soon": "Coming soon",
        "auto_strip_h": "What it already does by itself",
        "what_h": "What is Assisto?",
        "what_lead": "One app instead of many — it understands how you talk, and instead of only answering, it does the work.",
        "what": [
            ("apps", "One app instead of many", "Chat and calls, reminders, money, family safety, a shop khata, CCTV — no hunting for a separate app for each."),
            ("mic", "Bangla and English — typed or spoken", "Write or say it the way you talk. \"Call mum at 8 tomorrow\" — Assisto understands the rest."),
            ("bolt", "It acts, not only answers", "It rings the reminder, sends the due reminder, tells your family when you are late, and brings your day's list and the shop report each morning. Before sending money or posting anything, it always asks you."),
            ("lock", "Your data stays yours", "Chats are end-to-end encrypted — neither our server nor our AI can read them. See and delete what the AI remembers. We never sell your data."),
        ],
        "groups_h": "Every feature, by group", "groups_lead": "Each group has its own page — with a real screenshot of every feature.",
        "see_all": "See all", "n_features": " features",
        "pricing_h": "Pricing", "pricing_lead": "Start free. Family safety is free on every plan. Paid plans are bought through Google Play.",
        "per_month": "/month", "per_year": "/year", "free": "Free", "yearly": "Yearly plans",
        "no_plans": "See plan prices inside the app.",
        "cctv_plans_h": "CCTV plans", "cctv_plans_note": "CCTV plans can't be bought yet. Planned prices:",
        "security_h": "Security and privacy", "security_lead": "What is end-to-end encrypted and what is not — in plain words.",
        "never_h": "What we never do",
        "faq_h": "FAQ", "more_h": "Learn more",
        "cta_h": "Start today — free",
        "cta_p": "Get Assisto on Google Play. Bangla or English, your choice.",
        "footer_made": "Made in Bangladesh", "footer_company": "AXON Dynamic",
        "f_privacy": "Privacy policy", "f_terms": "Terms", "f_delete": "Delete account", "f_help": "Help and contact",
        "f_tools": "Free tools", "not_emergency": "Assisto is not an emergency service — in danger, call 999.",
        "shot_alt": "Assisto app screenshot: ",
        "group_back": "All features", "on_this_page": "On this page",
        "preview_banner": "Preview — this page is not live yet and is hidden from search engines.",
        "ai_note": "AI can make mistakes — check important information.",
        "install_now": "Install now", "viewer": "Screenshot viewer", "play_soon": "Coming soon to Play Store — install the APK directly now.",
        "apk_link": "Download APK directly", "apk_version": "Version", "apk_size": "Size", "apk_date": "Date",
        "chips_label": "Quick links", "chip_home": "Home", "chip_ai": "AI Assistant", "chip_circle": "My Circle",
        "chip_safety": "Safety", "chip_cctv": "CCTV", "chip_business": "Business", "chip_pricing": "Pricing", "chip_download": "Download",
        "to_top": "Back to top", "pause": "Pause or play the screenshots",
        "slide_chat": "reminders and expenses by talking", "slide_emergency_hub": "SOS and emergency hub",
        "slide_wm_alerts": "CCTV smart alerts", "slide_acct_home": "business accounts and khata",
        "slide_c3_chat": "My Circle chat", "slide_callpip_pip_window": "video call in a small floating window (PiP)",
        "slide_location_sharing": "Live Location", "slide_inv_paper_80": "invoice",
        "slide_dest_alarm": "Destination Alarm", "slide_ai": "AI assistant",
    },
}

EXTRA_FAQ = {
    "bn": [("Assisto কি নিজে থেকে টাকা পাঠায় বা পোস্ট করে?", "না। রিমাইন্ডার, সতর্কতা, তাগাদা আর রিপোর্ট নিজে থেকে চলে; কিন্তু টাকা পাঠানো, পোস্ট বা আবেদনের আগে Assisto সবসময় আপনার অনুমতি নেয়।"),
           ("\"শীঘ্রই আসছে\" মানে কী?", "ফিচারটা তৈরি হচ্ছে বা পরীক্ষায় আছে — সবার জন্য চালু হলে এই পাতায় নিজে থেকেই \"শীঘ্রই আসছে\" লেখা সরে যাবে।")],
    "en": [("Does Assisto send money or post by itself?", "No. Reminders, alerts, due reminders and reports run by themselves; but before sending money, posting or applying, Assisto always asks you."),
           ("What does \"Coming soon\" mean?", "The feature is being built or tested — once it is on for everyone, \"Coming soon\" disappears from this page by itself.")],
}

MEDICINE_WORDS = ("medicine", "medicines", "ওষুধ", "pharma", "pharmacy", "prescription", "প্রেসক্রিপশন", "ফার্মেসি")


# ------------------------------------------------------------ live status
def live_flags():
    """{flag_key: bool} for an ordinary Play-build visitor right now."""
    try:
        from core import feature_flags as FF
        return FF.resolve(None, play=True)[0]
    except Exception:  # noqa: BLE001 — the site never breaks on flag trouble
        return {}


def ai_ready():
    try:
        from core import ai
        return bool(ai._providers())
    except Exception:  # noqa: BLE001
        return False


def feature_live(f, flags, ai_ok):
    if f["soon"]:
        return False
    if f["ai"] and not ai_ok:
        return False
    return all(flags.get(k, False) for k in f["flags"])


def group_features(gid, lang, flags, ai_ok):
    out = []
    for f in FEATURES[gid]:
        live = feature_live(f, flags, ai_ok)
        t = f[lang]
        out.append({"id": f["id"], "icon": f["icon"], "shot": f["shot"], "title": t[0], "body": t[1],
                    "live": live, "auto": (f["auto"][0 if lang == "bn" else 1] if (live and f["auto"]) else None),
                    "ai": f["ai"]})
    # available first, "Coming soon" after — the order inside each block stays
    return [x for x in out if x["live"]] + [x for x in out if not x["live"]]


def groups(lang, flags, ai_ok):
    res = []
    for gid, icon in GROUPS:
        g = GROUP_TEXT[gid][lang]
        feats = group_features(gid, lang, flags, ai_ok)
        res.append({"id": gid, "icon": icon, "name": g[0], "lead": g[1], "title": g[2], "desc": g[3],
                    "features": feats, "n_live": sum(1 for x in feats if x["live"]),
                    "autos": [x for x in feats if x["auto"]]})
    return res


def auto_strip(all_groups, n=6):
    """The first live automations across groups (round-robin) for the hero."""
    pools = [list(g["autos"]) for g in all_groups]
    out = []
    while len(out) < n and any(pools):
        for p in pools:
            if p and len(out) < n:
                x = p.pop(0)
                out.append(x)
    return out


def num(v, lang):
    return bn_digits(v) if lang == "bn" else str(v)


def cctv_plan(lang):
    p, bn = CCTV_PLAN, lang == "bn"
    m = lambda v: SC.money(v, "BDT", lang)  # noqa: E731
    if bn:
        return [
            "মূল প্ল্যান: %s/মাস — %s টি ক্যামেরা" % (m(p["base"]), num(p["base_cams"], lang)),
            "প্রতিটি বাড়তি ক্যামেরা: %s/মাস (%s টি পর্যন্ত; বেশি হলে যোগাযোগ করুন)" % (m(p["extra"]), num(p["max_cams"], lang)),
            "ফোনকে ক্যামেরা বানালে সেটাও একটা ক্যামেরা গোনা হবে",
            "ভিডিও-ক্লিপ অ্যাড-অন: প্রতি ক্যামেরা ৭ দিন %s বা ৩০ দিন %s /মাস" % (m(p["clip7"]), m(p["clip30"])),
            "বছরে কিনলে ঠিক ১২ মাসের দাম; প্রথমবার %s দিন ফ্রি ট্রায়াল" % num(p["trial_days"], lang),
        ]
    return [
        "Base plan: %s/month — %d cameras" % (m(p["base"]), p["base_cams"]),
        "Each extra camera: %s/month (up to %d; more — contact us)" % (m(p["extra"]), p["max_cams"]),
        "A phone used as a camera counts as one camera",
        "Video clip add-on: per camera %s for 7 days or %s for 30 days /month" % (m(p["clip7"]), m(p["clip30"])),
        "Yearly = exactly 12 months' price; %d-day free trial the first time" % p["trial_days"],
    ]


# hero auto-play, in the owner's order (HERO order 3 Nov 03:30): My Circle
# chat, video call with PiP, Live Location, SOS + emergency hub, CCTV,
# business accounts + khata, invoice, AI assistant, Destination Alarm.
# (gallery spec, alt-text key) — real CI gallery shots only.
HERO_SLIDES = (("c3_chat", "c3_chat"), ("callpip_pip_window", "callpip_pip_window"),
               ("gj_live_banner", "location_sharing"), ("emergency_hub", "emergency_hub"),
               ("wm_alerts", "wm_alerts"), ("acct_home", "acct_home"), ("inv_paper_80", "inv_paper_80"),
               ("home_v2_chat", "ai"), ("dest_alarm", "dest_alarm"))  # "chat" after agent/aicardbn


def shot_names():
    """Every screenshot the site uses (tools/website/site_shots.py manifest)."""
    names = {"home_v2"} | {n for n, _ in HERO_SLIDES}
    for feats in FEATURES.values():
        for f in feats:
            if f["shot"]:
                names.add(f["shot"])
    return sorted(names)


def jsonld(lang, site, url, page, faq_rows, crumbs=None):
    org = {"@type": "Organization", "@id": site + "/#org", "name": SC.COMPANY, "url": site + "/",
           "email": SC.EMAIL, "logo": site + "/site/icon-512.png",
           "address": {"@type": "PostalAddress", "addressCountry": "BD"}}
    app = {"@type": "SoftwareApplication", "name": "Assisto", "operatingSystem": "Android 8.0+",
           "applicationCategory": "LifestyleApplication", "url": site + "/", "inLanguage": ["bn", "en"],
           "publisher": {"@id": site + "/#org"}, "description": COPY[lang]["desc"],
           "installUrl": SC.play_url(lang), "offers": {"@type": "Offer", "price": "0", "priceCurrency": "BDT"}}
    graph = [org, app]
    if faq_rows:
        graph.append({"@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": r["q"], "acceptedAnswer": {"@type": "Answer", "text": r["a"]}}
            for r in faq_rows]})
    if crumbs:
        graph.append({"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": i + 1, "name": n, "item": u} for i, (n, u) in enumerate(crumbs)]})
    s = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False)
    return s.replace("<", "\\u003c")
