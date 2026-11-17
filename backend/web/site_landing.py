"""seogrow (owner order 17 Nov 00:32): one landing page per main feature,
Bangla (bare path) and English (?lang=en), at /features/<slug>.

HONESTY (same rules as web.site_v3, enforced by web.tests_seogrow):
  * a page exists (HTTP 200) only while every app feature flag it names is
    ON for an ordinary Play-build visitor (core.feature_flags.resolve, play);
    otherwise 404 and it is left out of the sitemap — never a "coming soon"
    page. Every point / screenshot that needs an extra flag (or a configured
    AI provider) is dropped while that flag is off.
  * only real CI gallery screenshots (site_assets/shots3, see
    tools/website/site_shots.py), no reviews, no ratings, no user counts,
    no competitor names, no medicine words.
GO-LIVE ("site_seo_growth_live", default OFF): stored inverted as the
AdminFlagState flag `site_seo_growth_preview` (default ON, like
website_classic, so every flag-catalog default stays ON). Not live = the
pages answer at their final URLs but carry noindex (meta + X-Robots-Tag) and
are not in the sitemap or the site navigation, so the owner can review them.
ON (Owner Admin -> Website, one tap) = indexable, in the sitemap and linked
from the footer and the features page.
"""
PREVIEW_FLAG = "site_seo_growth_preview"   # ON (default) = not live yet


def growth_live():
    try:
        from core.billing import flag_on
        return not flag_on(PREVIEW_FLAG, True)
    except Exception:  # noqa: BLE001 — flag trouble keeps the pages hidden
        return False


def P(bn, en, flags=(), ai=False):
    """One point: (heading, body) per language; dropped while a flag is off."""
    return {"bn": bn, "en": en, "flags": tuple(flags), "ai": ai}


def S(name, bn_alt, en_alt, flags=(), pt=0):
    """One real gallery screenshot (site_assets/shots3/<name>_<lang>_<w>.webp)
    shown next to point number `pt` (the screen that point talks about)."""
    return {"name": name, "bn": bn_alt, "en": en_alt, "flags": tuple(flags), "pt": pt}


# Order = footer / sitemap / features-page order.
LANDINGS = {
    "family-care": {
        "flags": ("family",), "icon": "family", "group": "safety",
        "related": ("safe-journey", "blood-donor", "my-circle"),
        "bn": {"name": "ফ্যামিলি কেয়ার",
               "title": "পরিবারের নিরাপত্তা অ্যাপ: জরুরি কার্ড, SOS ও স্কুল — Assisto ফ্যামিলি কেয়ার",
               "desc": "পরিবারের সবার জরুরি কার্ড, এক চাপে SOS, বাচ্চার স্কুলের ফি ও পরীক্ষার রিমাইন্ডার আর বাবা-মায়ের জন্য সহজ হোম — বাংলায়, এক অ্যাপে।",
               "h1": "ফ্যামিলি কেয়ার: পুরো পরিবারের যত্ন এক জায়গায়",
               "lead": "বাবা-মা, সন্তান আর আপনি — সবার জরুরি তথ্য, স্কুলের তারিখ আর বিপদের সময়ের এক চাপের সাহায্য Assisto-তে একসাথে থাকে।"},
        "en": {"name": "Family Care",
               "title": "Family safety app: emergency card, SOS and school dates — Assisto",
               "desc": "A family safety app: an emergency card for everyone, one-tap SOS that shares your location with family, school reminders and a simple home for elders.",
               "h1": "Family Care: your whole family looked after in one place",
               "lead": "Parents, children and you — everyone's emergency details, school dates and one-tap help in an emergency live together in Assisto."},
        "points": [
            P(("পরিবারের জরুরি কার্ড", "জরুরি নম্বর, ঠিকানা আর দরকারি তথ্য প্রতিজনের কার্ডে থাকে — বিপদের সময় খুঁজতে হয় না, ছবি বা লেখা হিসেবে শেয়ারও করা যায়।"),
              ("Family emergency card", "Emergency numbers, address and key details sit on each person's card — nothing to hunt for in an emergency, and it can be shared as a picture or text.")),
            P(("এক চাপে SOS", "SOS চাপলে আপনার বেছে নেওয়া পরিবারের সদস্যরা লোকেশনসহ সতর্কতা পান; কেউ না খুললে ২ মিনিট পরে আবার ডাকে। ৯৯৯ আর কাছের থানাও এক জায়গায়।"),
              ("One-tap SOS", "Tap SOS and the family members you chose get an alert with your location; if nobody opens it, they are alerted again after 2 minutes. 999 and the nearest police station are one tap away."),
              flags=("emergency",)),
            P(("বাচ্চার স্কুল কর্নার", "স্কুলের ফি, পরীক্ষা আর অভিভাবক সভার তারিখ লিখে রাখুন — দিন এলে Assisto মনে করিয়ে দেয়।"),
              ("Child's school corner", "Note school fees, exams and parent meetings — Assisto reminds you when the day comes."),
              flags=("kid_school",)),
            P(("বয়স্কদের জন্য সহজ হোম", "বড় বোতাম আর অল্প কাজ: SOS, পরিবারকে কল, মেসেজ আর সাহায্য — বাবা-মায়ের ফোনে সহজে চালানো যায়।"),
              ("A simple home for elders", "Big buttons and few choices: SOS, call family, messages and help — easy to use on your parents' phone.")),
        ],
        "shots": [S("famcare_card", "ফ্যামিলি কেয়ার: পরিবারের জরুরি কার্ড", "Family Care: family emergency card"),
                  S("famcare_school", "বাচ্চার স্কুল কর্নার", "Child's school corner", ("kid_school",), pt=2),
                  S("emergency_hub", "SOS ও জরুরি হাব", "SOS and emergency hub", ("emergency",), pt=1)],
        "faq": {
            "bn": [("ফ্যামিলি কেয়ার কি ফ্রি?", "হ্যাঁ, পরিবারের জরুরি কার্ড, SOS আর স্কুলের রিমাইন্ডার ফ্রি। নিরাপত্তার কোনো ফিচার কখনো টাকার পেছনে আটকানো হয় না।"),
                   ("পরিবারের কে আমার তথ্য দেখতে পায়?", "শুধু আপনি যাদের বেছে নেন। কাকে কী দেখাবেন, তা আপনি ঠিক করেন এবং যেকোনো সময় বদলাতে পারেন।"),
                   ("Assisto কি ৯৯৯-এর বদলে কাজ করে?", "না। Assisto পরিবারকে দ্রুত জানাতে সাহায্য করে, কিন্তু জীবন-ঝুঁকিতে সবসময় ৯৯৯-এ ফোন করুন।")],
            "en": [("Is Family Care free?", "Yes. The family emergency card, SOS and school reminders are free. Safety features are never put behind a payment."),
                   ("Who in my family can see my details?", "Only the people you choose. You decide who sees what, and you can change it at any time."),
                   ("Does Assisto replace 999?", "No. Assisto helps you reach your family fast, but in a life-threatening emergency always call 999.")],
        },
    },
    "safe-journey": {
        "flags": ("safe_journey",), "icon": "route", "group": "safety",
        "related": ("family-care", "city-service", "my-circle"),
        "bn": {"name": "নিরাপদ যাত্রা",
               "title": "নিরাপদ যাত্রা অ্যাপ: যাত্রায় লাইভ লোকেশন শেয়ার ও SOS — Assisto",
               "desc": "যাত্রা শুরু করুন — শুধু আপনার বেছে নেওয়া মানুষেরা যাত্রার সময় লাইভ লোকেশন দেখেন; দেরি হলে Assisto নিজেই পরিবারকে জানায়, শেষে পথ মুছে যায়।",
               "h1": "নিরাপদ যাত্রা: পথে থাকলে পরিবার জানে আপনি কোথায়",
               "lead": "নারী, শিক্ষার্থী আর সবার জন্য যাত্রার নিরাপত্তা ও SOS: অফিস থেকে বাসা, রাতের বাস বা দূরের সফর — যাত্রার সময়টুকুই পরিবার আপনার লাইভ লোকেশন দেখে।"},
        "en": {"name": "Safe Journey",
               "title": "Safe Journey: travel safety app with live location and SOS — Assisto",
               "desc": "Start a trip and only the people you chose see your live location while it lasts; if you are late Assisto alerts your family, and the path is deleted at the end.",
               "h1": "Safe Journey: your family knows where you are on the way",
               "lead": "A travel safety and SOS app for women, students and everyone: office to home, a late bus or a long trip — your family sees your live location only while the trip lasts."},
        "points": [
            P(("শুধু যাত্রার সময় লাইভ লোকেশন", "যাত্রা শুরু করলে আপনার বেছে নেওয়া মানুষেরা লাইভ লোকেশন পান; যাত্রা শেষ হলে শেয়ার বন্ধ হয় আর পথ মুছে যায়।"),
              ("Live location only during the trip", "When you start a trip, the people you chose get your live location; when it ends, sharing stops and the path is deleted.")),
            P(("দেরি হলে নিজে থেকেই সতর্কতা", "ঠিক সময়ে না পৌঁছালে Assisto আগে আপনাকে জিজ্ঞেস করে \"ঠিক আছেন?\" — উত্তর না দিলে নিজেই আপনার পরিবারকে জানায়, ফোন বন্ধ থাকলেও।"),
              ("An alert by itself if you are late", "If you do not arrive in time, Assisto first asks you \"Are you OK?\" — with no answer it alerts your family by itself, even if your phone is off.")),
            P(("গন্তব্য অ্যালার্ম", "বাসে বা ট্রেনে ঘুমিয়ে পড়লেও চিন্তা নেই — নামার জায়গার কাছে এলে ফোন আপনাকে জাগিয়ে দেয়।"),
              ("Destination alarm", "Fall asleep on the bus or train — the phone wakes you as your stop gets close."),
              flags=("dest_alarm",)),
            P(("বিপদে এক চাপে SOS", "যাত্রার মাঝে বিপদ মনে হলে এক চাপে SOS — পরিবার লোকেশনসহ সতর্কতা পায়।"),
              ("One-tap SOS on the way", "If something feels wrong on the way, one tap sends SOS — your family gets an alert with your location."),
              flags=("emergency",)),
        ],
        "shots": [S("journey_live", "নিরাপদ যাত্রা: লাইভ যাত্রা", "Safe Journey: a live trip", pt=1),
                  S("gj_live_banner", "যাত্রায় লাইভ লোকেশন শেয়ার", "Live location shared during a trip", pt=0),
                  S("dest_alarm", "গন্তব্য অ্যালার্ম", "Destination alarm", ("dest_alarm",), pt=2)],
        "faq": {
            "bn": [("আমার লোকেশন কি সবসময় শেয়ার হয়?", "না। শুধু আপনি যাত্রা শুরু করলে, শুধু আপনার বেছে নেওয়া মানুষের কাছে, আর যাত্রা শেষ হওয়া পর্যন্ত।"),
                   ("যাত্রা শেষে পথের তথ্য কোথায় যায়?", "যাত্রা শেষ হলে পথটা মুছে যায় — পরে কেউ সেই পথ দেখতে পারে না।"),
                   ("যাকে লোকেশন পাঠাব, তার কি Assisto লাগবে?", "না, বাধ্যতামূলক নয়। অ্যাপ ছাড়াও তিনি একটা গোপন লিংক থেকে ব্রাউজারে আপনার যাত্রা দেখতে পারেন; লিংকের মেয়াদ শেষ হলে বা যাত্রা শেষ হলে আর লোকেশন দেখায় না।")],
            "en": [("Is my location shared all the time?", "No. Only after you start a trip, only with the people you chose, and only until the trip ends."),
                   ("What happens to the path after the trip?", "When the trip ends the path is deleted — nobody can look at it later."),
                   ("Do the people I share with need Assisto?", "No, it is not required. Without the app they can follow your trip in a browser from a private link; once the link expires or the trip ends, it shows no location.")],
        },
    },
    "cctv-app": {
        "flags": ("home_watchman",), "icon": "camera", "group": "cctv",
        "related": ("business-khata", "family-care", "my-circle"),
        "bn": {"name": "CCTV",
               "title": "CCTV মোবাইল অ্যাপ: ছবিসহ স্মার্ট সতর্কতা ও লাইভ দেখা — Assisto",
               "desc": "দোকান বা বাড়ির CCTV ও IP ক্যামেরা ফোনে লাইভ দেখুন; আপনার আঁকা জোনে মানুষ এলে ছবিসহ সতর্কতা, এক চাপে প্রমাণ-প্যাক। বাড়তি ফোনও ক্যামেরা হয়।",
               "h1": "CCTV মোবাইল অ্যাপ: দোকান ও বাড়ি দেখুন ফোনেই",
               "lead": "আপনার CCTV ক্যামেরা বা একটা বাড়তি Android ফোন দোকান আর বাড়ি পাহারা দেয় — জোনে মানুষ এলে ছবিসহ সতর্কতা আসে আপনার ফোনে।"},
        "en": {"name": "CCTV",
               "title": "CCTV mobile app: smart photo alerts and live view — Assisto",
               "desc": "A CCTV mobile app for your IP cameras: live view on your phone, a photo alert when a person enters your zone and a one-tap evidence pack. A spare phone can be the camera.",
               "h1": "CCTV mobile app: watch your shop and home from your phone",
               "lead": "Your CCTV cameras or a spare Android phone watch the shop and home — a person in your zone sends a photo alert to your phone."},
        "points": [
            P(("জোনে মানুষ এলে ছবিসহ সতর্কতা", "ক্যামেরার ছবিতে জোন আঁকুন — সেখানে মানুষ দেখলে ছবিসহ সতর্কতা আসে। ভুল সতর্কতায় \"ভুল\" চাপুন, পরের বার আরও ঠিক হয়।"),
              ("Photo alerts when a person enters your zone", "Draw a zone on the camera picture — a person there sends a photo alert. Mark a wrong alert and the next one is better.")),
            P(("যেখানেই থাকুন, লাইভ দেখুন", "Imou, Hikvision, Dahua বা ONVIF ক্যামেরা জুড়ুন — দোকান বা বাড়ি লাইভ দেখুন, পরিবারকেও দেখার অনুমতি দিন।"),
              ("Live view from anywhere", "Connect Imou, Hikvision, Dahua or ONVIF cameras — watch the shop or home live and let family view too.")),
            P(("থানার GD-র জন্য প্রমাণ-প্যাক", "এক চাপে ছবি, সময় আর SHA-256 আঙুলছাপসহ প্রমাণ-প্যাক তৈরি হয়।"),
              ("An evidence pack for a police GD", "One tap builds an evidence pack with photos, times and SHA-256 fingerprints.")),
            P(("বাড়তি ফোনকেই ক্যামেরা বানান", "একটা বাড়তি Android ফোন দোকানের ক্যামেরা হয়ে যায় — ফোনেই শনাক্ত করে, শুধু সংকেত আর দরকার হলে একটা ছবি পাঠায়।"),
              ("Turn a spare phone into a camera", "A spare Android phone becomes the shop camera — it detects on the phone and sends only a signal and, when needed, one photo."),
              flags=("cctv_watchman",)),
        ],
        "shots": [S("wm_alerts", "CCTV: ছবিসহ স্মার্ট সতর্কতা", "CCTV: smart photo alerts"),
                  S("wm_viewer", "CCTV লাইভ দেখা", "CCTV live view", pt=1),
                  S("shop_box", "বাড়তি ফোনকে ক্যামেরা বানানো", "A spare phone as a camera", ("cctv_watchman",), pt=3)],
        "faq": {
            "bn": [("কোন ক্যামেরা চলে?", "Imou, Hikvision, Dahua আর ONVIF সমর্থিত ক্যামেরা জোড়া যায়; ক্যামেরা না থাকলে একটা বাড়তি Android ফোনও ক্যামেরা হতে পারে।"),
                   ("ভিডিও কি আপনাদের সার্ভারে যায়?", "ফোন-ক্যামেরা ফোনেই শনাক্ত করে, শুধু সংকেত আর দরকার হলে একটা ছবি পাঠায় — পুরো ভিডিও দোকানের বাইরে যায় না।"),
                   ("CCTV ফিচারের দাম কত?", "দাম ও প্ল্যান Assisto-র মূল্য পাতায় লেখা থাকে; অ্যাপে কেনার আগে দাম পরিষ্কার দেখায়।")],
            "en": [("Which cameras work?", "Imou, Hikvision, Dahua and ONVIF cameras can be connected; without a camera, a spare Android phone can be one."),
                   ("Does video go to your server?", "A phone camera detects on the phone and sends only a signal and, when needed, one photo — the full video does not leave the shop."),
                   ("How much does CCTV cost?", "Prices and plans are on the Assisto pricing page; the app shows the price clearly before you buy.")],
        },
    },
    "my-circle": {
        "flags": ("my_circle",), "icon": "chat", "group": "circle",
        "related": ("family-care", "safe-journey", "ai-assistant"),
        "bn": {"name": "আমার সার্কেল",
               "title": "আমার সার্কেল: পরিবারের এনক্রিপ্টেড গ্রুপ চ্যাট, ভয়েস ও ভিডিও কল — Assisto",
               "desc": "কাছের মানুষের সাথে end-to-end এনক্রিপ্টেড চ্যাট, ভয়েস ও ভিডিও কল, ভয়েস নোট, ছবি আর স্ট্যাটাস — আমাদের সার্ভার বা AI আপনার মেসেজ পড়তে পারে না।",
               "h1": "আমার সার্কেল: কাছের মানুষের সাথে নিরাপদ চ্যাট ও কল",
               "lead": "পরিবার, বন্ধু আর কাজের মানুষের সাথে এক-এক ও গ্রুপ চ্যাট, ভয়েস ও ভিডিও কল — সব end-to-end এনক্রিপ্টেড।"},
        "en": {"name": "My Circle",
               "title": "My Circle: encrypted family group chat, voice and video calls — Assisto",
               "desc": "End-to-end encrypted chat, voice and video calls, voice notes, photos and status with your people — neither our server nor our AI can read your messages.",
               "h1": "My Circle: private chat and calls with your people",
               "lead": "One-to-one and group chats, voice and video calls with family, friends and colleagues — all end-to-end encrypted."},
        "points": [
            P(("end-to-end এনক্রিপ্টেড চ্যাট", "এক-এক ও গ্রুপ চ্যাট, ছবি, ভয়েস নোট আর ফাইল — আপনার ফোনেই তালাবদ্ধ; আমাদের সার্ভার বা AI পড়তে পারে না।"),
              ("End-to-end encrypted chat", "One-to-one and group chats, photos, voice notes and files — locked on your phone; neither our server nor our AI can read them.")),
            P(("ভয়েস ও ভিডিও কল", "সার্কেলের মানুষকে এনক্রিপ্টেড ভয়েস ও ভিডিও কল; কল কখনো রেকর্ড হয় না। কলের মধ্যে ভিডিও ছোট ভাসমান জানালায় চলে।"),
              ("Voice and video calls", "Encrypted voice and video calls with your circle; calls are never recorded. During a call the video can shrink into a small floating window."),
              flags=("calls",)),
            P(("একবার-দেখা ছবি ও নিজে-মুছে-যাওয়া মেসেজ", "যা থাকা দরকার নেই, তা একবার দেখার পর বা সময় শেষে নিজেই মুছে যায়।"),
              ("View-once photos and disappearing messages", "What does not need to stay disappears after one view or when its time is up.")),
            P(("স্ট্যাটাস, চ্যানেল ও কমিউনিটি", "দিনের ছবি শুধু সার্কেলের সাথে শেয়ার করুন; চ্যানেলে অনেকের কাছে খবর পৌঁছান, এলাকা বা অফিসের গ্রুপ এক কমিউনিটিতে রাখুন।"),
              ("Status, channels and communities", "Share a photo from your day with your circle only; reach many people with a channel and keep a neighbourhood's or office's groups in one community.")),
        ],
        "shots": [S("c3_chat_list", "আমার সার্কেল: চ্যাট তালিকা", "My Circle: chat list"),
                  S("c2_call_video_connected", "এনক্রিপ্টেড ভিডিও কল", "Encrypted video call", ("calls",), pt=1),
                  S("p3_story_viewer", "সার্কেলের স্ট্যাটাস", "Circle status", pt=3)],
        "faq": {
            "bn": [("Assisto কি আমার মেসেজ পড়তে পারে?", "না। চ্যাট end-to-end এনক্রিপ্টেড — শুধু আপনি আর যাকে পাঠান তিনি পড়তে পারেন; আমাদের সার্ভার বা AI নয়।"),
                   ("কল কি রেকর্ড হয়?", "না, আমার সার্কেলের কল কখনো রেকর্ড হয় না।"),
                   ("চ্যাট ও কল কি ফ্রি?", "চ্যাট ফ্রি। কোনো কিছুর জন্য টাকা লাগলে তার দাম মূল্য পাতায় লেখা থাকে, আর অ্যাপ কেনার আগেই দাম দেখায়।")],
            "en": [("Can Assisto read my messages?", "No. Chats are end-to-end encrypted — only you and the person you send to can read them, not our server or our AI."),
                   ("Are calls recorded?", "No, My Circle calls are never recorded."),
                   ("Are chat and calls free?", "Chat is free. Anything that costs money has its price on the pricing page, and the app shows the price before you buy.")],
        },
    },
    "ai-assistant": {
        "flags": (), "icon": "sparkle", "group": "ai",
        "related": ("business-khata", "language-partner", "my-circle"),
        "bn": {"name": "AI সহকারী",
               "title": "বাংলা AI সহকারী অ্যাপ: কথা বলে রিমাইন্ডার, খরচ ও দৈনিক ব্রিফ — Assisto",
               "desc": "বাংলা বা ইংরেজিতে লিখুন বা বলুন — Assisto রিমাইন্ডার বা খরচের হিসাব বানায়, সকালে দিনের তালিকা সাজায়। টাকা পাঠানোর মতো কাজে আগে আপনার অনুমতি নেয়।",
               "h1": "বাংলা AI সহকারী: বলুন, কাজটা হয়ে যাক",
               "lead": "\"কাল ৮টায় মাকে ফোন\" বা \"দুপুরে ৫০০ খরচ\" — বাংলা বা ইংরেজিতে লিখুন বা বলুন, Assisto বোঝে আর কাজটা করে দেয়।"},
        "en": {"name": "AI assistant",
               "title": "Bangla AI assistant app: reminders, expenses and a daily brief — Assisto",
               "desc": "Type or say it in Bangla or English — Assisto makes the reminder or logs the expense and lays out your day each morning. Anything like sending money waits for your OK.",
               "h1": "A Bangla AI assistant: say it, get it done",
               "lead": "\"Call mum at 8 tomorrow\" or \"500 for lunch\" — type or say it in Bangla or English, Assisto understands and does the work."},
        "points": [
            P(("একটা বাক্যেই রিমাইন্ডার বা খরচ", "সাধারণ কথায় লিখুন বা বলুন — Assisto নিজেই রিমাইন্ডার বা খরচের হিসাব বানায়। টাকা পাঠানোর মতো কাজে আগে আপনার অনুমতি নেয়।"),
              ("A reminder or an expense from one sentence", "Type or say it in plain words — Assisto makes the reminder or logs the expense by itself. Anything like sending money waits for your OK.")),
            P(("যেকোনো প্রশ্নের বাংলা উত্তর", "বাংলা বা ইংরেজিতে প্রশ্ন করুন — পরিষ্কার উত্তর, চিঠি বা পোস্টের খসড়া, আপনার রিমাইন্ডার ও খরচের সারাংশ।"),
              ("Answers in Bangla to any question", "Ask in Bangla or English — get a clear answer, a draft letter or post, or a summary of your reminders and spending."),
              ai=True),
            P(("Assisto ভয়েস", "মাইকে চাপ দিয়ে বলুন — কল, অ্যালার্ম, টর্চ, খরচ লেখা বা SOS। বাংলা ও ইংরেজি দুটোই বোঝে।"),
              ("Assisto Voice", "Tap the mic and speak — call, alarm, torch, log an expense or send SOS. It understands Bangla and English."),
              flags=("voice_assistant",)),
            P(("প্রতিদিন সকালের ব্রিফ", "সকালে এক নজরে আজকের দিন: বাকি বিল, রিমাইন্ডার আর জন্মদিন — কোনটা আগে, তা সাজানো।"),
              ("A brief every morning", "Your day at a glance each morning: bills due, reminders and birthdays — sorted by what comes first."),
              flags=("daily_brief",)),
        ],
        "shots": [S("chat", "AI সহকারীর সাথে চ্যাট", "Chat with the AI assistant"),
                  S("voice_assistant", "Assisto ভয়েস", "Assisto Voice", ("voice_assistant",), pt=2),
                  S("daily_brief", "দৈনিক ব্রিফ", "Daily brief", ("daily_brief",), pt=3)],
        "faq": {
            "bn": [("AI কি বাংলা বোঝে?", "হ্যাঁ। বাংলা হরফে, রোমান হরফে বাংলা (যেমন \"kal 8 tay ma ke phone\") বা ইংরেজি — যেভাবে লেখেন, সেই ভাষায় উত্তর দেয়।"),
                   ("Assisto কি নিজে থেকে টাকা পাঠায় বা পোস্ট করে?", "না। রিমাইন্ডার আর সারাংশ নিজে বানায়, কিন্তু টাকা পাঠানো, পোস্ট বা আবেদনের আগে সবসময় আপনার অনুমতি নেয়।"),
                   ("AI আমার কোন তথ্য মনে রাখে?", "অ্যাপের একটা পাতায় দেখা যায় AI কী মনে রেখেছে — যেকোনোটা মুছতে পারেন।")],
            "en": [("Does the AI understand Bangla?", "Yes. Bangla script, Bangla in Roman letters (like \"kal 8 tay ma ke phone\") or English — it answers in the language you write in."),
                   ("Does Assisto send money or post by itself?", "No. It makes reminders and summaries by itself, but before sending money, posting or applying it always asks you."),
                   ("What does the AI remember about me?", "One page in the app shows what the AI remembers — you can delete any item.")],
        },
    },
    "business-khata": {
        "flags": ("business",), "icon": "book", "group": "business",
        "related": ("cctv-app", "ai-assistant", "mess"),
        "bn": {"name": "ব্যবসা ও খাতা",
               "title": "বাকির খাতা অ্যাপ: ডিজিটাল খাতা, দোকানের হিসাব ও ইনভয়েস — Assisto",
               "desc": "কার কাছে কত বাকি, কে কত দিল — এক পাতায়; ঠিক করা সময়ে বাকির তাগাদা তৈরি, থার্মাল ও A4 ইনভয়েস, বিক্রি ও লাভের রিপোর্ট। খাতা চিরকাল ফ্রি।",
               "h1": "ডিজিটাল খাতা ও ব্যবসার হিসাব, এক ফোনে",
               "lead": "বাকি, জমা, বিক্রি আর খরচ এক চাপে লিখুন — ঠিক সময়ে বাকির তাগাদা তৈরি থাকে, ইনভয়েস হয় এক চাপে।"},
        "en": {"name": "Business & khata",
               "title": "Digital khata app: baki khata, due reminders and invoices — Assisto",
               "desc": "Who owes what and who paid, on one page; due reminders ready on your schedule, thermal and A4 invoices and sales and profit reports. The khata is free forever.",
               "h1": "A digital khata and business accounts on one phone",
               "lead": "Log credit, payments, sales and expenses in one tap — due reminders are ready on time and an invoice takes one tap."},
        "points": [
            P(("ডিজিটাল খাতা, চিরকাল ফ্রি", "কার কাছে কত বাকি আর কে কত দিল — এক পাতায়। খাতার জন্য কখনো টাকা লাগবে না।"),
              ("A digital khata, free forever", "Who owes what and who paid — on one page. The khata will never cost money.")),
            P(("সময়মতো বাকির তাগাদা", "আপনার ঠিক করা সময়ে Assisto তাগাদার মেসেজ তৈরি করে আপনাকে জানায় — এক চাপে চ্যাট অ্যাপ বা SMS-এ পাঠান; বাকি শোধ হলে তাগাদা থামে।"),
              ("Due reminders on your schedule", "On the schedule you set, Assisto prepares the reminder and tells you — send it by a chat app or SMS in one tap; it stops once the due is paid.")),
            P(("থার্মাল ও A4 ইনভয়েস", "৫৮ বা ৮০ মিমি থার্মাল প্রিন্টার বা A4 — বাংলা বা ইংরেজিতে, VAT ও QR-সহ ইনভয়েস, এক চাপে।"),
              ("Thermal and A4 invoices", "58 or 80 mm thermal or A4 — an invoice in Bangla or English with VAT and a QR code, in one tap.")),
            P(("বিক্রি ও লাভের রিপোর্ট", "বিক্রি, লাভ আর সবচেয়ে বেশি বিক্রি হওয়া পণ্য — এক নজরে।"),
              ("Sales and profit reports", "Sales, profit and your best-selling products at a glance.")),
            P(("পূর্ণ হিসাব: লাভ-ক্ষতি ও VAT", "সাধারণ কথায় বিক্রি, কেনা, খরচ আর বাকি লিখুন — লাভ-ক্ষতি, ব্যালান্স শিট, VAT আর হিসাবরক্ষকের জন্য Excel তৈরি হয়।"),
              ("Full accounts: profit and loss and VAT", "Write sales, purchases, expenses and dues in plain words — get profit and loss, a balance sheet, VAT and an Excel file for your accountant."),
              flags=("accounting_v2",)),
        ],
        "shots": [S("biz_khata", "ডিজিটাল খাতা", "Digital khata"),
                  S("inv_paper_80", "৮০ মিমি থার্মাল ইনভয়েস", "80 mm thermal invoice", pt=2),
                  S("acct_home", "ব্যবসার পূর্ণ হিসাব", "Full business accounts", ("accounting_v2",), pt=4)],
        "faq": {
            "bn": [("খাতা কি সত্যিই ফ্রি?", "হ্যাঁ। ডিজিটাল খাতা চিরকাল ফ্রি — এটা আমাদের লিখিত প্রতিশ্রুতি।"),
                   ("গ্রাহক কীভাবে তাগাদা পান?", "আপনি এক চাপে চ্যাট অ্যাপ বা SMS-এ তাগাদা পাঠান; মেসেজে বাকির একটা লিংক থাকে, যেখানে গ্রাহক তাঁর হিসাব দেখতে পান। বাকি শোধ হলে তাগাদা থেমে যায়।"),
                   ("কোন প্রিন্টারে ইনভয়েস ছাপা যায়?", "৫৮ মিমি ও ৮০ মিমি থার্মাল প্রিন্টার আর সাধারণ A4 কাগজ।")],
            "en": [("Is the khata really free?", "Yes. The digital khata is free forever — that is our written promise."),
                   ("How does the customer get the reminder?", "You send it by a chat app or SMS in one tap; the message carries a link where the customer can see what they owe. The reminders stop once they pay."),
                   ("Which printers can print the invoice?", "58 mm and 80 mm thermal printers and ordinary A4 paper.")],
        },
    },
    "mess": {
        "flags": ("mess_accounting",), "icon": "home", "group": "daily",
        "related": ("business-khata", "my-circle", "ai-assistant"),
        "bn": {"name": "মেস ও ব্যাচেলর",
               "title": "মেস ম্যানেজার অ্যাপ: মিল রেট, বাজার ও জমার হিসাব — Assisto",
               "desc": "মেসের সদস্য, মিল, বাজার আর জমা লিখুন — মিল রেট আর প্রতিজনের দেনা-পাওনা নিজেই হিসাব হয়, শেষে সব মিলে শূন্য। মেসের হিসাব ফ্রি।",
               "h1": "মেস ও ব্যাচেলর হিসাব: মিল রেট নিয়ে আর তর্ক নয়",
               "lead": "মাস শেষে কে কত দেবে, কে কত ফেরত পাবে — মিল, বাজার আর জমা লিখলেই Assisto নিখুঁতভাবে হিসাব করে দেয়।"},
        "en": {"name": "Mess & bachelor",
               "title": "Mess manager app: meal rate calculator, bazar and deposits — Assisto",
               "desc": "Log the mess members, meals, bazar and deposits — the meal rate and everyone's balance are worked out for you and add up to zero. Mess accounts are free.",
               "h1": "Mess and bachelor accounts: no more arguments over the meal rate",
               "lead": "Who pays how much and who gets money back at the end of the month — log meals, bazar and deposits and Assisto does the exact math."},
        "points": [
            P(("মিল রেট নিজেই হিসাব", "মোট বাজার ÷ মোট মিল = মিল রেট। অর্ধেক মিলও (০.৫) লেখা যায়।"),
              ("The meal rate, worked out for you", "Total bazar ÷ total meals = the meal rate. Half meals (0.5) can be logged too.")),
            P(("প্রতিজনের দেনা-পাওনা", "জমা থেকে মিল খরচ আর অন্য খরচ বাদ দিয়ে কে দেবে আর কে ফেরত পাবে, তা পরিষ্কার দেখায়; পুরো হিসাব মিলে শূন্য হয়।"),
              ("Everyone's balance", "Deposits minus meal cost and other charges shows who pays and who gets money back; the whole month adds up to zero.")),
            P(("ভাড়া, গ্যাস, বিদ্যুৎ ভাগ", "বাসা ভাড়া, গ্যাস বা বিদ্যুতের মতো সাধারণ খরচ সবার মধ্যে সমান ভাগ হয়, বা নির্দিষ্ট একজনের নামে লেখা যায়।"),
              ("Rent, gas and electricity split", "Common costs like rent, gas or electricity are split equally, or charged to one member.")),
            P(("টাকা আপনাদের হাতেই", "Assisto কোনো টাকা রাখে না — শুধু আপনাদের দেওয়া তথ্য থেকে হিসাব করে।"),
              ("The money stays with you", "Assisto holds no money — it only does the math from what you enter.")),
        ],
        "shots": [S("mess_acct", "মেস ও ব্যাচেলর হিসাব", "Mess and bachelor accounts")],
        "faq": {
            "bn": [("মেসের হিসাব কি ফ্রি?", "হ্যাঁ, মেস ও ব্যাচেলর হিসাব সবার জন্য ফ্রি।"),
                   ("মিল রেট কীভাবে হিসাব হয়?", "মাসের মোট বাজার খরচকে মোট মিল দিয়ে ভাগ করে। প্রতিজনের মিল খরচ = তাঁর মিল × মিল রেট।"),
                   ("Assisto কি মেসের টাকা রাখে?", "না। টাকা আপনাদের কাছেই থাকে; Assisto শুধু হিসাব রাখে আর দেখায়।")],
            "en": [("Are mess accounts free?", "Yes, mess and bachelor accounts are free for everyone."),
                   ("How is the meal rate worked out?", "The month's total bazar cost divided by the total meals. Each member's meal cost = their meals × the meal rate."),
                   ("Does Assisto hold the mess money?", "No. The money stays with you; Assisto only keeps and shows the accounts.")],
        },
    },
    "language-partner": {
        "flags": ("language_partner",), "icon": "chat", "group": "daily",
        "related": ("ai-assistant", "quran", "my-circle"),
        "bn": {"name": "ভাষা শেখার সঙ্গী",
               "title": "ইংরেজি শেখার অ্যাপ: বাংলা অর্থসহ শব্দ ও ফ্ল্যাশকার্ড — Assisto ভাষা সঙ্গী",
               "desc": "বাংলা অর্থ ও উদাহরণসহ ইংরেজি শব্দ, ফ্ল্যাশকার্ড, ভুলে যাওয়ার আগে আবার দেখানো (spaced repetition) আর দৈনিক লক্ষ্য — প্রতিদিন অল্প অল্প অনুশীলন।",
               "h1": "ভাষা শেখার সঙ্গী: প্রতিদিন একটু করে ইংরেজি",
               "lead": "বাংলা অর্থসহ শব্দ আর ফ্ল্যাশকার্ড — যে শব্দ ভুলে যাচ্ছেন, Assisto সেটা ঠিক সময়ে আবার দেখায়।"},
        "en": {"name": "Language Partner",
               "title": "English learning app: words with Bangla meanings and flashcards — Assisto Language Partner",
               "desc": "English words with Bangla meanings and examples, flashcards, spaced repetition that brings words back before you forget them, and a daily goal — a little practice every day.",
               "h1": "Language Partner: a little English every day",
               "lead": "Words with Bangla meanings and flashcards — the words you are forgetting come back at the right time."},
        "points": [
            P(("বাংলা অর্থসহ শব্দ", "দরকারি ইংরেজি শব্দ, বাংলা অর্থ আর উদাহরণ — বিষয় ধরে সাজানো, নেট ছাড়াও চলে।"),
              ("Words with Bangla meanings", "Useful English words with Bangla meanings and examples — grouped by topic, works offline.")),
            P(("ফ্ল্যাশকার্ড ও spaced repetition", "আগে মনে মনে অর্থ বলুন, তারপর মিলিয়ে দেখুন। যে শব্দ জানেন তা ২, ৪, ৭ আর ১৫ দিন পরে আসে, যেটা ভুলছেন তা আবার আসে — Leitner পদ্ধতিতে।"),
              ("Flashcards and spaced repetition", "Say the meaning in your head first, then check. Words you know come back after 2, 4, 7 and 15 days, words you are forgetting come back sooner — using the Leitner method.")),
            P(("দৈনিক লক্ষ্য ও স্ট্রিক", "প্রতিদিন ১০টা নতুন শব্দ — কত দিন টানা শিখছেন, তা স্ট্রিকে দেখা যায়।"),
              ("A daily goal and streak", "Ten new words a day — your streak shows how many days in a row you have practised.")),
            P(("IELTS-ধাঁচের অনুশীলন", "Speaking, Writing আর Reading অনুশীলন, বাংলা ব্যাখ্যাসহ। স্কোর অনুশীলনের মাপ — অফিসিয়াল IELTS ব্যান্ড নয়।"),
              ("IELTS-style practice", "Speaking, Writing and Reading practice with explanations in Bangla. Scores are a practice measure — not an official IELTS band."),
              flags=("language_packs",)),
        ],
        "shots": [S("lang_partner", "ভাষা শেখার সঙ্গী", "Language Partner", ("language_packs",), pt=3)],
        "faq": {
            "bn": [("ভাষা শেখার সঙ্গী কি ফ্রি?", "হ্যাঁ, বাংলা অর্থসহ শব্দ আর ফ্ল্যাশকার্ড ফ্রি।"),
                   ("প্রতিদিন কতক্ষণ লাগে?", "কয়েক মিনিটই যথেষ্ট — অল্প অল্প নিয়মিত অনুশীলনই spaced repetition-এর মূল কথা।"),
                   ("এটা কি অফিসিয়াল কোনো পরীক্ষার স্কোর দেয়?", "না। Assisto-র যেকোনো স্কোর শুধু অনুশীলনের মাপ — কোনো অফিসিয়াল পরীক্ষার ফল নয়।")],
            "en": [("Is Language Partner free?", "Yes, the words with Bangla meanings and the flashcards are free."),
                   ("How much time does it take each day?", "A few minutes is enough — short, regular practice is the whole idea of spaced repetition."),
                   ("Does it give an official exam score?", "No. Any Assisto score is only a practice measure — never an official exam result.")],
        },
    },
    "quran": {
        "flags": ("quran",), "icon": "moon", "group": "daily",
        "related": ("language-partner", "ai-assistant", "family-care"),
        "bn": {"name": "কুরআন",
               "title": "কুরআন অ্যাপ: আরবি উসমানি লেখা, সূরা খোঁজা ও বুকমার্ক — Assisto",
               "desc": "পুরো কুরআনের আরবি উসমানি লেখা (Tanzil), সূরার তালিকা বাংলা অঙ্কে, নাম বা নম্বরে খোঁজা, বড় অক্ষর আর আয়াত বুকমার্ক — বিজ্ঞাপন ছাড়া।",
               "h1": "কুরআন: পরিষ্কার আরবি লেখায় পড়ুন, যেখানে ছিলেন সেখান থেকে",
               "lead": "সূরার তালিকা থেকে বেছে নিন, বড় অক্ষরে পড়ুন, আয়াত বুকমার্ক করুন — আবার খুললে যেখানে থেমেছিলেন সেখান থেকেই শুরু।"},
        "en": {"name": "Quran",
               "title": "Quran app: Uthmani Arabic text, surah search and bookmarks — Assisto",
               "desc": "The full Quran in Uthmani Arabic script (Tanzil), the surah list, search by name or number, large text and ayah bookmarks — with no ads.",
               "h1": "Quran: read clear Arabic text, right where you left off",
               "lead": "Pick a surah, read in large text and bookmark ayahs — open it again and you continue where you stopped."},
        "points": [
            P(("পরিষ্কার আরবি উসমানি লেখা", "Tanzil-এর উসমানি (হাফস) লেখা, ডান থেকে বাম, বড় অক্ষরে।"),
              ("Clear Uthmani Arabic text", "Tanzil's Uthmani (Hafs) text, right to left, in large letters.")),
            P(("সূরা খোঁজা", "সূরার নাম, নম্বর বা একটা শব্দ লিখে খুঁজুন; আরবিতে হরকত ছাড়াও খোঁজা যায়।"),
              ("Surah search", "Search by surah name, number or a word; Arabic search works without diacritics.")),
            P(("বুকমার্ক ও পড়া চালিয়ে যান", "আয়াত বুকমার্ক করুন; আবার খুললে শেষ পড়া জায়গা থেকেই শুরু।"),
              ("Bookmarks and continue reading", "Bookmark ayahs; open it again and you continue from where you stopped.")),
            P(("কুরআন পড়া শেখা (পরীক্ষামূলক)", "কায়দা থেকে নাজেরা: হরফ, হরকত, জোড়া হরফ আর ছোট সূরা — ধাপে ধাপে, বাংলা ব্যাখ্যাসহ। শিক্ষকের বিকল্প নয়।"),
              ("Learn to read the Quran (experimental)", "From Qaida to Nazera: letters, vowel marks, joined letters and short surahs — step by step, explained in Bangla. Not a replacement for a teacher."),
              flags=("quran_learn",)),
        ],
        "shots": [S("quran_list", "কুরআন: সূরার তালিকা", "Quran: surah list"),
                  S("quran_learn", "কুরআন পড়া শিখি", "Learn to read the Quran", ("quran_learn",), pt=3)],
        "faq": {
            "bn": [("বাংলা অনুবাদ আছে?", "এখনো নেই। বাংলা অনুবাদের লিখিত অনুমতি পাওয়ার পরেই যোগ হবে; আজ আরবি লেখা আর পাবলিক-ডোমেইন ইংরেজি অনুবাদ আছে।"),
                   ("তিলাওয়াতের অডিও আছে?", "না, এখনো নেই — লাইসেন্স পরিষ্কার এমন উৎস ছাড়া আমরা অডিও যোগ করি না।"),
                   ("কুরআনের পাতায় কি বিজ্ঞাপন দেখায়?", "না। কুরআনের পাতায় কখনো বিজ্ঞাপন দেখানো হয় না।")],
            "en": [("Is there a Bangla translation?", "Not yet. It will be added only after written permission for a Bangla translation; today there is the Arabic text and a public-domain English translation."),
                   ("Is there recitation audio?", "Not yet — we add audio only from a source with a clear licence."),
                   ("Are there ads on the Quran pages?", "No. Ads are never shown on the Quran pages.")],
        },
    },
    "city-service": {
        "flags": ("city_service",), "icon": "map", "group": "daily",
        "related": ("safe-journey", "family-care", "ai-assistant"),
        "bn": {"name": "সিটি সার্ভিস",
               "title": "ঢাকার বাস রুট ও মেট্রো রেল: কোন বাস, কত ভাড়া, কোন গেট — Assisto",
               "desc": "কোথায় যাবেন বলুন — কোন বাস বা মেট্রো, কোথায় উঠবেন ও নামবেন, ভাড়া (উৎসের লেবেলসহ), মেট্রো স্টেশনের কোন গেট। ঢাকা দিয়ে শুরু।",
               "h1": "সিটি সার্ভিস: শহরে কোন বাস, কোন মেট্রো, কত ভাড়া",
               "lead": "কোথায় যাবেন লিখুন বা বলুন — সবচেয়ে সস্তা আর সবচেয়ে দ্রুত পথ, ধাপে ধাপে হাঁটা, বাস আর মেট্রো, সঙ্গে ভাড়া।"},
        "en": {"name": "City Service",
               "title": "Dhaka bus route finder and metro rail routes: fares and gates — Assisto",
               "desc": "Say where you are going — which bus or metro, where to get on and off, the fare (with its source labelled) and which metro station gate to use. Starting with Dhaka.",
               "h1": "City Service: which bus, which metro and what fare in the city",
               "lead": "Type or say where you are going — the cheapest and the fastest way, step by step on foot, by bus and by metro, with fares."},
        "points": [
            P(("পুরো পথের পরিকল্পনা", "সবচেয়ে সস্তা, সবচেয়ে দ্রুত, কম বদল বা রাতে নিরাপদ — বাস ও মেট্রো মিলিয়ে ধাপে ধাপে পথ।"),
              ("The whole route planned", "Cheapest, fastest, fewest changes or safer at night — step by step by bus and metro.")),
            P(("উৎসসহ ভাড়া", "প্রতিটি ভাড়ার পাশে লেখা থাকে সেটা সরকারি, ব্যবহারকারীদের জানানো নাকি আনুমানিক, আর কবে যাচাই করা।"),
              ("Fares with their source", "Every fare says whether it is official, reported by users or estimated, and when it was checked.")),
            P(("মেট্রোর কোন গেট", "স্টেশন, গেট, কাছে কী আছে আর সময়সূচি — নেমে কোন গেট দিয়ে বের হবেন, তা দেখায়।"),
              ("Which metro gate", "Stations, gates, what is nearby and the timetable — it shows which gate to leave by.")),
            P(("এক চাপে নিরাপদ যাত্রা", "পথ বেছে নিয়ে \"নিরাপদ যাত্রা হিসেবে শুরু\" চাপলে পরিবার আপনার লাইভ লোকেশন দেখে।"),
              ("Safe Journey in one tap", "Pick a route and start it as a Safe Journey — your family sees your live location."),
              flags=("safe_journey",)),
        ],
        "shots": [S("city_start", "সিটি সার্ভিস: কোথায় যাবেন", "City Service: where to?")],
        "faq": {
            "bn": [("কোন শহরে চলে?", "ঢাকা দিয়ে শুরু। যে শহরের তথ্য এখনো নেই, সেখানে অ্যাপ সৎভাবে তা জানায়।"),
                   ("ভাড়া কতটা ঠিক?", "প্রতিটি ভাড়ার পাশে উৎস (সরকারি, ব্যবহারকারীদের জানানো বা আনুমানিক) আর যাচাইয়ের তারিখ লেখা থাকে, যাতে আপনি নিজে বিচার করতে পারেন।"),
                   ("সিটি সার্ভিস কি ফ্রি?", "হ্যাঁ, পথ খোঁজা আর ভাড়া দেখা ফ্রি।")],
            "en": [("Which cities does it cover?", "It starts with Dhaka. Where a city has no data yet, the app says so honestly."),
                   ("How accurate are the fares?", "Every fare shows its source (official, reported by users or estimated) and the date it was checked, so you can judge it yourself."),
                   ("Is City Service free?", "Yes, finding routes and seeing fares is free.")],
        },
    },
    "blood-donor": {
        "flags": ("blood_donors",), "icon": "drop", "group": "safety",
        "related": ("family-care", "safe-journey", "my-circle"),
        "bn": {"name": "রক্তদাতা",
               "title": "ব্লাড ডোনার অ্যাপ: কাছের রক্তদাতা খুঁজুন, নম্বর গোপন — Assisto",
               "desc": "রক্তের গ্রুপ আর এলাকা দিয়ে কাছের রক্তদাতা খুঁজুন বা নিজে দাতা হন; ফোন নম্বর গোপন থাকে, কথা হয় অ্যাপের ভেতরে। সম্পূর্ণ ফ্রি।",
               "h1": "রক্তদাতা: জরুরি সময়ে কাছের দাতা খুঁজুন",
               "lead": "রক্ত লাগলে কাছের রক্তদাতা খুঁজুন, আর চাইলে নিজেও দাতা হিসেবে যুক্ত হন — নম্বর প্রকাশ না করেই।"},
        "en": {"name": "Blood donor",
               "title": "Blood donor app for Bangladesh: find a donor near you — Assisto",
               "desc": "Find blood donors near you by blood group and area, or become one; phone numbers stay private and you talk inside the app. Completely free.",
               "h1": "Blood donors: find a donor nearby when it matters",
               "lead": "When blood is needed, find donors near you — and join as a donor yourself — without sharing your number."},
        "points": [
            P(("কাছের রক্তদাতা খুঁজুন", "রক্তের গ্রুপ আর এলাকা দিয়ে কাছের দাতা খুঁজুন।"),
              ("Find donors near you", "Search for donors near you by blood group and area.")),
            P(("নম্বর গোপন থাকে", "দাতা আর গ্রহীতার ফোন নম্বর প্রকাশ হয় না — কথা হয় অ্যাপের ভেতরে।"),
              ("Your number stays private", "Neither donor's nor patient's phone number is shown — you talk inside the app.")),
            P(("নিজে দাতা হন", "রক্তের গ্রুপ দিয়ে দাতা হিসেবে যুক্ত হন; কখন পাওয়া যাবেন, তা আপনি ঠিক করেন।"),
              ("Become a donor", "Join as a donor with your blood group; you decide when you are available.")),
        ],
        "shots": [S("blood_hub", "রক্তদাতা খোঁজা", "Finding blood donors")],
        "faq": {
            "bn": [("রক্তদাতা খোঁজা কি ফ্রি?", "হ্যাঁ, সম্পূর্ণ ফ্রি। জীবন বাঁচানোর কোনো ফিচারে কখনো টাকা লাগে না।"),
                   ("আমার ফোন নম্বর কি অন্যরা দেখতে পায়?", "না। নম্বর গোপন থাকে; যোগাযোগ হয় অ্যাপের ভেতরের মেসেজে।"),
                   ("Assisto কি রক্ত সরবরাহ করে?", "না। Assisto শুধু দাতা আর রক্তপ্রার্থীকে যুক্ত হতে সাহায্য করে; রক্ত নেওয়ার আগে হাসপাতালে পরীক্ষা করে নিন।")],
            "en": [("Is finding a donor free?", "Yes, completely free. Life-saving features never cost money."),
                   ("Can others see my phone number?", "No. Your number stays private; you talk through in-app messages."),
                   ("Does Assisto supply blood?", "No. Assisto only helps donors and patients connect; get blood screened at the hospital before a transfusion.")],
        },
    },
}
SLUGS = tuple(LANDINGS)


def _ok(flags, live):
    return all(live.get(k, False) for k in flags)


def page_live(slug, live=None):
    """True when the app feature behind this page is ON for a Play visitor."""
    d = LANDINGS.get(slug)
    if d is None:
        return False
    if live is None:
        from . import site_v3 as V3
        live = V3.live_flags()
    return _ok(d["flags"], live)


def live_slugs(live=None):
    if live is None:
        from . import site_v3 as V3
        live = V3.live_flags()
    return [s for s in SLUGS if page_live(s, live)]


def path(slug):
    return "/features/%s" % slug


def url_for(slug, lang):
    """Public path of a live landing page (for the blog and other pages), or
    None when the page does not exist right now."""
    if not page_live(slug):
        return None
    return path(slug) + ("?lang=en" if lang == "en" else "")


def sitemap_paths():
    """Landing paths for the sitemap — only once the owner made them live."""
    if not growth_live():
        return []
    return [path(s) for s in live_slugs()]


def nav(lang, live=None):
    """[{name, url}] for the footer / features page (only once live)."""
    if not growth_live():
        return []
    q = "?lang=en" if lang == "en" else ""
    return [{"name": LANDINGS[s][lang]["name"], "url": path(s) + q, "slug": s} for s in live_slugs(live)]


# Copy without any Google Play wording, used while the owner keeps the Play
# badge hidden (site_play_badge_hidden ON): never "Get it on Play" next to
# "coming soon to Play" (lead review 17 Nov).
NO_PLAY_COPY = {
    "bn": {"cta_p": "ফোনে Assisto নিন। বাংলা বা ইংরেজি, আপনার পছন্দ।",
           "apk_note": "আগে ওয়েবসাইটের পুরনো APK বসিয়ে থাকলে একবার আনইনস্টল করে এটি বসান।",
           "pricing_lead": "ফ্রিতে শুরু করুন। পরিবারের নিরাপত্তা সব প্ল্যানে ফ্রি।"},
    "en": {"cta_p": "Get Assisto on your phone. Bangla or English, your choice.",
           "apk_note": "Installed an older APK from this website? Uninstall it once and install this one.",
           "pricing_lead": "Start free. Family safety is free on every plan."},
}
NO_PLAY_TEXT = (  # sentence swaps inside shared FAQ answers
    ("প্রিমিয়াম বা বিজনেস প্ল্যান Google Play থেকে কেনা যায়।", "প্রিমিয়াম বা বিজনেস প্ল্যান অ্যাপ থেকেই কেনা যায়।"),
    ("Premium or Business can be bought through Google Play.", "Premium or Business can be bought in the app."),
)


def no_play(text):
    for a, b in NO_PLAY_TEXT:
        text = text.replace(a, b)
    return text


def shot_names():
    return sorted({s["name"] for d in LANDINGS.values() for s in d["shots"]})


def build(slug, lang, live, ai_ok):
    """Everything the template needs for one page (live flags already known)."""
    d = LANDINGS[slug]
    t = d[lang]
    shot_at = {s["pt"]: {"name": s["name"], "alt": s[lang]} for s in d["shots"] if _ok(s["flags"], live)}
    points = [{"h": p[lang][0], "b": p[lang][1], "shot": shot_at.get(i)} for i, p in enumerate(d["points"])
              if _ok(p["flags"], live) and (ai_ok or not p["ai"])]
    shots = [x["shot"] for x in points if x["shot"]]
    q = "?lang=en" if lang == "en" else ""
    related = [{"name": LANDINGS[r][lang]["name"], "lead": LANDINGS[r][lang]["lead"], "icon": LANDINGS[r]["icon"],
                "url": path(r) + q} for r in d["related"] if page_live(r, live)]
    faq = [{"q": a, "a": b} for a, b in d["faq"][lang]]
    return dict(t, slug=slug, icon=d["icon"], group=d["group"], points=points, shots=shots,
                related=related, faq=faq)
