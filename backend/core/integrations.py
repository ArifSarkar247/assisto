"""
Integrations store — the keystone that lets the owner add API keys/accounts
later, one by one, WITHOUT code changes. Credentials are encrypted at rest
(Fernet); raw values are never returned to any client. A feature turns on
automatically when its integration's status becomes 'working'.

Security: owner-only (is_superuser), rate-limited + audit-logged at the view
layer. Fernet key lives in /home/ubuntu/.assisto_secrets.env (chmod 600), never
in git/logs.
"""
import os
import json

from django.utils import timezone

# ---------------------------------------------------------------- encryption
_FERNET = None


def _fernet():
    global _FERNET
    if _FERNET is None:
        from cryptography.fernet import Fernet
        key = os.getenv("INTEGRATIONS_FERNET_KEY")
        if not key:
            raise RuntimeError("INTEGRATIONS_FERNET_KEY missing")
        _FERNET = Fernet(key.encode())
    return _FERNET


def _encrypt(data: dict) -> str:
    return _fernet().encrypt(json.dumps(data).encode()).decode()


def _decrypt(blob: str) -> dict:
    if not blob:
        return {}
    try:
        return json.loads(_fernet().decrypt(blob.encode()).decode())
    except Exception:
        return {}


# ---------------------------------------------------------------- registry
# Each: name, category, unlocks(bn/en), guide(bn/en steps), fields, test
def _f(key, label_bn, label_en, secret=True):
    return {"key": key, "label_bn": label_bn, "label_en": label_en, "secret": secret}


# Owner "how to connect" docs live in owner_actions/. One shared note maps every
# key → the feature it unlocks; the dashboard deep-links each service to it.
# These are repo-relative anchors so the page can show an honest "read the guide"
# link even when the file isn't web-served.
_DOC = "owner_actions/integrations.md"


REGISTRY = {
    "anthropic": {
        "name": "Anthropic (Claude) AI",
        "category": "AI",
        "unlocks_bn": "স্মার্ট ব্রিফিং, রোল-প্লে, মানসিক সাপোর্ট, বিল/স্ক্যান AI, CRM AI।",
        "unlocks_en": "Smart briefing, roleplay, mental support, bill/scan AI, CRM AI.",
        "guide_bn": ["console.anthropic.com-এ যান → API Keys → Create Key",
                     "বিলিং যোগ করুন (সস্তা, Haiku)", "কি কপি করে নিচে পেস্ট করুন → Test"],
        "guide_en": ["Go to console.anthropic.com → API Keys → Create Key",
                     "Add billing (cheap, Haiku)", "Paste the key below → Test"],
        "fields": [_f("api_key", "API Key", "API Key")],
        "test": "test_anthropic",
    },
    "gemini": {
        "name": "Google Gemini AI (backup)",
        "category": "AI",
        "unlocks_bn": "Anthropic ব্যর্থ হলে ব্যাকআপ AI প্রোভাইডার।",
        "unlocks_en": "Backup AI provider when Anthropic is down.",
        "guide_bn": ["aistudio.google.com → Get API Key", "নিচে পেস্ট → Test"],
        "guide_en": ["aistudio.google.com → Get API Key", "Paste below → Test"],
        "fields": [_f("api_key", "API Key", "API Key")],
        "test": "test_gemini",
    },
    "openai": {
        "name": "OpenAI (backup)",
        "category": "AI",
        "unlocks_bn": "আরেকটি ব্যাকআপ AI প্রোভাইডার।",
        "unlocks_en": "Another backup AI provider.",
        "guide_bn": ["platform.openai.com → API keys → Create", "পেস্ট → Test"],
        "guide_en": ["platform.openai.com → API keys → Create", "Paste → Test"],
        "fields": [_f("api_key", "API Key", "API Key")],
        "test": "test_openai",
    },
    "firebase": {
        "name": "Firebase (push notifications)",
        "category": "Messaging",
        "unlocks_bn": "ক্রস-ডিভাইস push (ওষুধ মিস→সন্তানকে, ফ্যামিলি শেয়ার)।",
        "unlocks_en": "Cross-device push (missed medicine → child, family share).",
        "guide_bn": ["Firebase Console → নতুন প্রজেক্ট → Android অ্যাপ (package com.assisto.assisto)",
                     "google-services.json ডাউনলোড", "Service account JSON তৈরি করুন",
                     "দুটো JSON নিচে পেস্ট করুন → Test"],
        "guide_en": ["Firebase Console → new project → Android app (com.assisto.assisto)",
                     "Download google-services.json", "Create a service-account JSON",
                     "Paste both JSONs below → Test"],
        "fields": [_f("google_services_json", "google-services.json", "google-services.json"),
                   _f("service_account_json", "Service account JSON", "Service account JSON")],
        "test": None,
    },
    "google_places": {
        "name": "Google Places / Maps",
        "category": "Location",
        "unlocks_bn": "কাছে রেস্টুরেন্ট/ফার্মেসি/ATM/হাসপাতাল; ম্যাপ নেভিগেশন।",
        "unlocks_en": "Nearby restaurants/pharmacy/ATM/hospital; map navigation.",
        "guide_bn": ["console.cloud.google.com → APIs: Places API + Maps SDK চালু",
                     "Credentials → API key তৈরি (Bangladesh-এ ভালো কাজ করে)", "পেস্ট → Test"],
        "guide_en": ["console.cloud.google.com → enable Places API + Maps SDK",
                     "Credentials → create API key (best for Bangladesh)", "Paste → Test"],
        "fields": [_f("api_key", "API Key", "API Key")],
        "test": "test_google_places",
    },
    "spotify": {
        "name": "Spotify (new releases)",
        "category": "Media",
        "unlocks_bn": "প্রিয় শিল্পীর নতুন গান; গান চালানোর deep-link।",
        "unlocks_en": "Favourite-artist new releases; play deep-links.",
        "guide_bn": ["developer.spotify.com → Dashboard → Create app",
                     "Client ID + Client Secret কপি → পেস্ট → Test"],
        "guide_en": ["developer.spotify.com → Dashboard → Create app",
                     "Copy Client ID + Secret → paste → Test"],
        "fields": [_f("client_id", "Client ID", "Client ID", secret=False),
                   _f("client_secret", "Client Secret", "Client Secret")],
        "test": "test_spotify",
    },
    "youtube": {
        "name": "YouTube Data (optional)",
        "category": "Media",
        "unlocks_bn": "ভয়েসে “অমুকের অমুক গান চালাও” বললে ইউটিউবে সরাসরি গানটি চালু (key ছাড়া শুধু সার্চ ফল খোলে); প্রিয় শিল্পীর চ্যানেল watch।",
        "unlocks_en": "Voice “play <song> by <artist>” opens the exact YouTube video playing (without a key only search results open); artist channel watch.",
        "guide_bn": ["Google Cloud → YouTube Data API v3 চালু → API key", "key-টি শুধু YouTube Data API-তে সীমিত (restrict) করুন",
                     "পেস্ট → Test", "ফ্রি কোটা: দিনে ১০,০০০ ইউনিট; একটি সার্চ = ১০০ ইউনিট (≈১০০ সার্চ/দিন)"],
        "guide_en": ["Google Cloud → enable YouTube Data API v3 → API key", "Restrict the key to YouTube Data API",
                     "Paste → Test", "Free quota: 10,000 units/day; one search = 100 units (~100 searches/day)"],
        "fields": [_f("api_key", "API Key", "API Key")],
        "test": "test_youtube",
    },
    "admob": {
        "name": "Google AdMob",
        "category": "Monetization",
        "unlocks_bn": "non-personalized বিজ্ঞাপন + rewarded ad (১ extra স্ক্যান)। কখনো ভল্ট/হেলথ/ফ্যামিলি/ইমার্জেন্সি/পেমেন্ট স্ক্রিনে নয়।",
        "unlocks_en": "Non-personalized ads + rewarded ad (1 extra scan). Never on vault/health/family/emergency/payment screens.",
        "guide_bn": ["admob.google.com → অ্যাপ যোগ → Ad units (banner + rewarded)",
                     "App ID + unit IDs পেস্ট → Save"],
        "guide_en": ["admob.google.com → add app → Ad units (banner + rewarded)",
                     "Paste App ID + unit IDs → Save"],
        "fields": [_f("app_id", "AdMob App ID", "AdMob App ID", secret=False),
                   _f("banner_unit", "Banner unit ID", "Banner unit ID", secret=False),
                   _f("rewarded_unit", "Rewarded unit ID", "Rewarded unit ID", secret=False),
                   _f("app_open_unit", "App-open unit ID", "App-open unit ID", secret=False),
                   # ps1-photo: Photo Studio entry interstitial + SSV key note
                   _f("interstitial_unit", "Interstitial unit ID (ফটো স্টুডিও)", "Interstitial unit ID (Photo Studio)", secret=False),
                   # h1-home: the home hero NATIVE ad (image or video, free plan only)
                   _f("native_unit", "Native unit ID (হোম হিরো)", "Native unit ID (home hero)", secret=False),
                   # l1-launch: lifeassisto.com/app-ads.txt (optional — derived from the App ID when blank)
                   _f("publisher_id", "Publisher ID (app-ads.txt, যেমন pub-XXXXXXXXXXXXXXXX)", "Publisher ID (app-ads.txt, e.g. pub-XXXXXXXXXXXXXXXX)", secret=False),
                   # l3-ump: hashed device ids from logcat ("Use new ConsentDebugSettings
                   # .Builder().addTestDeviceHashedId(...)") — testing only
                   _f("ump_test_devices", "UMP টেস্ট ডিভাইস আইডি (কমা দিয়ে, শুধু পরীক্ষা)", "UMP test device IDs (comma-separated, testing only)", secret=False)],
        "test": "test_admob",
    },
    # pay1: Google Play Billing — server verification + RTDN (core/payments/play.py)
    "play_billing": {
        "name": "Google Play Billing",
        "category": "Monetization",
        "unlocks_bn": "Play স্টোর বিল্ডে Premium/Business সাবস্ক্রিপশন ও ক্রেডিট প্যাক কেনা (সার্ভারে যাচাই + RTDN)।",
        "unlocks_en": "Premium/Business subscriptions and credit packs in the Play build (server-verified + RTDN).",
        "guide_bn": ["Play Console → Monetize → Subscriptions: assisto_premium ও assisto_business (base plan: monthly, yearly); In-app products: credits_p20, credits_p50, credits_p100, credits_p200",
                     "Google Cloud → Service account → JSON key; Play Console → Users and permissions → সেই ইমেইলকে Financial data + Manage orders অনুমতি দিন",
                     "Pub/Sub topic তৈরি → Play Console → Monetization setup → RTDN topic দিন; push subscription URL: https://api.lifeassisto.com/api/v1/payments/play/rtdn (authentication চালু)",
                     "নিচে JSON, package name, push audience, push service-account ইমেইল পেস্ট করুন → Save → Test",
                     "বিস্তারিত: owner_actions/PAYMENTS_SETUP.md"],
        "guide_en": ["Play Console → Monetize → Subscriptions: assisto_premium and assisto_business (base plans monthly, yearly); In-app products: credits_p20, credits_p50, credits_p100, credits_p200",
                     "Google Cloud → service account → JSON key; Play Console → Users and permissions → give that email Financial data + Manage orders",
                     "Create a Pub/Sub topic → Play Console → Monetization setup → RTDN topic; push subscription URL https://api.lifeassisto.com/api/v1/payments/play/rtdn (enable authentication)",
                     "Paste the JSON, package name, push audience and push service-account email below → Save → Test",
                     "Details: owner_actions/PAYMENTS_SETUP.md"],
        "fields": [_f("service_account_json", "Service account JSON", "Service account JSON"),
                   _f("package_name", "প্যাকেজ নাম (com.assisto.assisto)", "Package name (com.assisto.assisto)", secret=False),
                   _f("rtdn_audience", "RTDN push audience", "RTDN push audience", secret=False),
                   _f("rtdn_sa_email", "RTDN push service-account ইমেইল", "RTDN push service-account email", secret=False),
                   _f("rtdn_token", "RTDN গোপন টোকেন (ঐচ্ছিক, ?token=)", "RTDN shared token (optional, ?token=)")],
        "test": "test_play_billing",
    },
    # pay1: EPS (Easy Payment System) hosted checkout — bKash / Nagad / cards
    "eps": {
        "name": "EPS payment gateway (bKash / Nagad / Card)",
        "category": "Payment",
        "unlocks_bn": "ওয়েবসাইট APK ও lifeassisto.com/premium-এ bKash/Nagad/কার্ডে Premium, Business ও ক্রেডিট কেনা।",
        "unlocks_en": "Premium, Business and credits via bKash/Nagad/card on the website APK and lifeassisto.com/premium.",
        "guide_bn": ["EPS মার্চেন্ট প্যানেল থেকে Merchant ID, Store ID, Username, Password, Hash Key নিন",
                     "প্রথমে mode = sandbox রাখুন, পরীক্ষা শেষে live লিখুন",
                     "EPS-কে এই URL গুলো দিন: Success/Fail/Cancel https://lifeassisto.com/pay/return , IPN https://api.lifeassisto.com/api/v1/payments/gateway/ipn",
                     "IPN key EPS দিলে সেটিও পেস্ট করুন → Save → Test",
                     "বিস্তারিত: owner_actions/PAYMENTS_SETUP.md"],
        "guide_en": ["From the EPS merchant panel: Merchant ID, Store ID, Username, Password, Hash Key",
                     "Keep mode = sandbox first; type live after testing",
                     "Give EPS these URLs: Success/Fail/Cancel https://lifeassisto.com/pay/return , IPN https://api.lifeassisto.com/api/v1/payments/gateway/ipn",
                     "Paste the IPN key if EPS gives one → Save → Test",
                     "Details: owner_actions/PAYMENTS_SETUP.md"],
        "fields": [_f("merchant_id", "Merchant ID", "Merchant ID", secret=False),
                   _f("store_id", "Store ID", "Store ID", secret=False),
                   _f("username", "Username", "Username", secret=False),
                   _f("password", "Password", "Password"),
                   _f("hash_key", "Hash Key", "Hash Key"),
                   _f("ipn_key", "IPN key (ঐচ্ছিক)", "IPN key (optional)"),
                   _f("mode", "মোড: sandbox / live", "Mode: sandbox / live", secret=False)],
        "test": "test_eps",
    },
    "bkash": {
        "name": "bKash Payment",
        "category": "Payment",
        "unlocks_bn": "বিল pay, সাবস্ক্রিপশন, ক্রেডিট টপ-আপ (bKash)।",
        "unlocks_en": "Bill pay, subscription, credit top-up (bKash).",
        "guide_bn": ["bKash merchant চুক্তি → API credentials",
                     "App key/secret + username/password পেস্ট → Test"],
        "guide_en": ["bKash merchant agreement → API credentials",
                     "Paste app key/secret + username/password → Test"],
        "fields": [_f("app_key", "App Key", "App Key"), _f("app_secret", "App Secret", "App Secret"),
                   _f("username", "Username", "Username", secret=False), _f("password", "Password", "Password")],
        "test": None,
    },
    "nagad": {"name": "Nagad Payment", "category": "Payment",
              "unlocks_bn": "বিল/সাবস্ক্রিপশন/টপ-আপ (Nagad)।", "unlocks_en": "Pay/subscribe/top-up (Nagad).",
              "guide_bn": ["Nagad merchant → API credentials → পেস্ট → Save"],
              "guide_en": ["Nagad merchant → API credentials → paste → Save"],
              "fields": [_f("merchant_id", "Merchant ID", "Merchant ID", secret=False), _f("public_key", "Public Key", "Public Key"), _f("private_key", "Private Key", "Private Key")],
              "test": None},
    "sslcommerz": {"name": "SSLCommerz", "category": "Payment",
                   "unlocks_bn": "কার্ড/MFS পেমেন্ট গেটওয়ে।", "unlocks_en": "Card/MFS payment gateway.",
                   "guide_bn": ["sslcommerz.com merchant → Store ID + Password → পেস্ট → Save"],
                   "guide_en": ["sslcommerz.com merchant → Store ID + Password → paste → Save"],
                   "fields": [_f("store_id", "Store ID", "Store ID", secret=False), _f("store_pass", "Store Password", "Store Password")],
                   "test": None},
    "ekpay": {"name": "ekPay", "category": "Payment",
              "unlocks_bn": "সরকারি/ইউটিলিটি বিল পেমেন্ট।", "unlocks_en": "Govt/utility bill payment.",
              "guide_bn": ["ekPay merchant → credentials → পেস্ট → Save"],
              "guide_en": ["ekPay merchant → credentials → paste → Save"],
              "fields": [_f("merchant_id", "Merchant ID", "Merchant ID", secret=False), _f("api_key", "API Key", "API Key")],
              "test": None},
    # o1-otp: config-driven HTTP adapter (core/sms_gateway.py) — one entry
    # covers SSL Wireless / BulkSMSBD / Alpha SMS / MiM SMS / Infobip / custom.
    "sms": {"name": "SMS Gateway", "category": "Messaging",
            "unlocks_bn": "OTP সাইন-আপ/লগইন, পাসওয়ার্ড রিসেট, অ্যাকাউন্ট ডিলিট ও সেকশন-৮ নিশ্চিতকরণ।",
            "unlocks_en": "OTP sign-up/login, password reset, account-delete and Section-8 confirmation.",
            "guide_bn": ["প্রোভাইডার লিখুন: ssl_wireless / bulksmsbd / alpha_sms / mim_sms / infobip / custom",
                         "API Key ও Sender ID (BTRC অনুমোদিত মাস্কিং নাম বা নন-মাস্কিং নম্বর) পেস্ট করুন",
                         "custom হলে API URL ও প্যারামিটারের নাম দিন",
                         "Balance URL অথবা টেস্ট ফোন নম্বর দিন → Save → Test",
                         "বিস্তারিত: owner_actions/SMS_GATEWAY_NEEDS.md"],
            "guide_en": ["Provider: ssl_wireless / bulksmsbd / alpha_sms / mim_sms / infobip / custom",
                         "Paste API key + Sender ID (BTRC-approved masking name or non-masking number)",
                         "For custom: API URL + the gateway's parameter names",
                         "Add a balance URL or a test phone → Save → Test",
                         "Details: owner_actions/SMS_GATEWAY_NEEDS.md"],
            "fields": [_f("provider", "প্রোভাইডার", "Provider", secret=False),
                       _f("api_key", "API Key / Token", "API Key / Token"),
                       _f("sender_id", "Sender ID / মাস্কিং", "Sender ID / masking", secret=False),
                       _f("username", "ইউজারনেম (যদি লাগে)", "Username (if required)", secret=False),
                       _f("api_url", "API URL (custom/override)", "API URL (custom/override)", secret=False),
                       _f("method", "মেথড GET/POST", "Method GET/POST", secret=False),
                       _f("body_format", "বডি form/json", "Body form/json", secret=False),
                       _f("param_to", "নম্বর প্যারামিটার", "Number param name", secret=False),
                       _f("param_message", "মেসেজ প্যারামিটার", "Message param name", secret=False),
                       _f("param_api_key", "কি প্যারামিটার", "Key param name", secret=False),
                       _f("param_sender", "সেন্ডার প্যারামিটার", "Sender param name", secret=False),
                       _f("body_template", "JSON বডি টেমপ্লেট", "JSON body template", secret=False),
                       _f("auth_header", "অথ হেডার", "Auth header", secret=False),
                       _f("number_format", "নম্বর ফরম্যাট 880/+880/0", "Number format 880/+880/0", secret=False),
                       _f("success_json", "সফলতা JSON (path=value)", "Success JSON (path=value)", secret=False),
                       _f("success_contains", "সফলতা টেক্সট", "Success text", secret=False),
                       _f("balance_url", "ব্যালান্স URL", "Balance URL", secret=False),
                       _f("test_phone", "টেস্ট ফোন নম্বর", "Test phone number", secret=False),
                       _f("app_hash", "Android অ্যাপ হ্যাশ (ঐচ্ছিক)", "Android app hash (optional)", secret=False)],
            "test": "test_sms"},
    "ivr": {"name": "IVR / Voice call", "category": "Messaging",
            "unlocks_bn": "ফ্যামিলি কেয়ার ভয়েস কল রিমাইন্ডার।", "unlocks_en": "Family-care voice-call reminders.",
            "guide_bn": ["ভয়েস-কল প্রোভাইডার → credentials → পেস্ট → Save"],
            "guide_en": ["Voice-call provider → credentials → paste → Save"],
            "fields": [_f("api_key", "API Key", "API Key"), _f("caller_id", "Caller ID", "Caller ID", secret=False)],
            "test": None},
    "telegram": {"name": "Telegram Bot", "category": "Messaging",
                 "unlocks_bn": "টেলিগ্রাম বট: রিমাইন্ডার/অ্যালার্ট পাঠানো, বেসিক কমান্ড (/help, /balance, /remind) — টোকেন ছাড়া নিষ্ক্রিয় (sandbox)।",
                 "unlocks_en": "Telegram bot: push reminders/alerts, basic commands (/help, /balance, /remind) — inert until a token is set (sandbox).",
                 "guide_bn": ["@BotFather → /newbot → bot token কপি করুন → পেস্ট → Save",
                              "ওয়েবহুক: https://assisto.asalify.com/api/v1/telegram/webhook"],
                 "guide_en": ["@BotFather → /newbot → copy the bot token → paste → Save",
                              "Webhook: https://assisto.asalify.com/api/v1/telegram/webhook"],
                 "fields": [_f("bot_token", "Bot Token", "Bot Token")],
                 "test": None},
    "google_oauth": {"name": "Gmail / Google OAuth", "category": "Email",
                     "unlocks_bn": "AI Inbox, ইমেইল সহকারী, জব হান্টার (নিজের Gmail থেকে)।",
                     "unlocks_en": "AI Inbox, email assistant, job hunter (from user's own Gmail).",
                     "guide_bn": ["Google Cloud → OAuth consent + Credentials (Web) → Client ID/Secret",
                                  "redirect URI: https://assisto.asalify.com/oauth/google/callback", "পেস্ট → Save"],
                     "guide_en": ["Google Cloud → OAuth consent + Credentials (Web) → Client ID/Secret",
                                  "redirect URI: https://assisto.asalify.com/oauth/google/callback", "Paste → Save"],
                     "fields": [_f("client_id", "Client ID", "Client ID", secret=False), _f("client_secret", "Client Secret", "Client Secret")],
                     "test": None},
    "whatsapp": {"name": "Meta WhatsApp Cloud + Messenger", "category": "Business",
                 "unlocks_bn": "Business mode: WhatsApp/Messenger সেলস সহকারী; CRM lead capture।",
                 "unlocks_en": "Business mode: WhatsApp/Messenger sales assistant; CRM lead capture.",
                 "guide_bn": ["developers.facebook.com → App → WhatsApp → Phone number ID + permanent token",
                              "Business verification শেষ করুন", "পেস্ট → Test"],
                 "guide_en": ["developers.facebook.com → App → WhatsApp → Phone number ID + permanent token",
                              "Finish Business verification", "Paste → Test"],
                 "fields": [_f("phone_number_id", "Phone number ID", "Phone number ID", secret=False),
                            _f("access_token", "Access token", "Access token"),
                            _f("verify_token", "Webhook verify token", "Webhook verify token")],
                 "test": None},
    "courier": {"name": "Courier (Pathao/Steadfast/RedX)", "category": "Business",
                "unlocks_bn": "অর্ডার→কুরিয়ার বুকিং ও স্ট্যাটাস (Business mode)।",
                "unlocks_en": "Order→courier booking & status (Business mode).",
                "guide_bn": ["কুরিয়ার merchant API → credentials → পেস্ট → Save"],
                "guide_en": ["Courier merchant API → credentials → paste → Save"],
                "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
                "test": None},
    "health_connect": {"name": "Health Connect", "category": "Health",
                       "unlocks_bn": "হেলথ টাইমলাইন + স্মার্টওয়াচ ডেটা (Android)।",
                       "unlocks_en": "Health timeline + smartwatch data (Android).",
                       "guide_bn": ["ফোনে Health Connect অ্যাপ + অনুমতি (অ্যাপের ভেতর থেকে)।"],
                       "guide_en": ["Health Connect app on phone + in-app permission."],
                       "fields": [_f("enabled", "Enable (yes)", "Enable (yes)", secret=False)],
                       "test": None},
    "smart_home": {"name": "Smart home (Google Home / Tuya)", "category": "Smart home",
                   "unlocks_bn": "ভয়েসে ঘরের ডিভাইস নিয়ন্ত্রণ।", "unlocks_en": "Voice control of home devices.",
                   "guide_bn": ["Tuya/Google Home developer → credentials → পেস্ট → Save"],
                   "guide_en": ["Tuya/Google Home developer → credentials → paste → Save"],
                   "fields": [_f("provider", "Provider", "Provider", secret=False), _f("access_id", "Access ID", "Access ID"), _f("access_secret", "Access Secret", "Access Secret")],
                   "test": None},
    "axon_erp": {"name": "Axon ERP (CRM onboarding)", "category": "Business",
                 "unlocks_bn": "AI CRM deal Won → Axon ERP-এ 1-click onboarding।",
                 "unlocks_en": "AI CRM deal Won → 1-click Axon ERP onboarding.",
                 "guide_bn": ["Axon ERP API base URL + token → পেস্ট → Save"],
                 "guide_en": ["Axon ERP API base URL + token → paste → Save"],
                 "fields": [_f("base_url", "Base URL", "Base URL", secret=False), _f("token", "API token", "API token")],
                 "test": None},
    "messenger": {"name": "Meta Messenger / Facebook Page", "category": "Business",
                  "unlocks_bn": "Business mode: Facebook Page/Messenger সেলস সহকারী; ইনবক্স→CRM lead।",
                  "unlocks_en": "Business mode: Facebook Page/Messenger sales assistant; inbox→CRM lead.",
                  "guide_bn": ["developers.facebook.com → App → Messenger → Page যুক্ত করুন",
                               "Page access token + Page ID + verify token কপি",
                               "webhook: https://assisto.asalify.com/webhooks/messenger", "পেস্ট → Save"],
                  "guide_en": ["developers.facebook.com → App → Messenger → add your Page",
                               "Copy Page access token + Page ID + verify token",
                               "webhook: https://assisto.asalify.com/webhooks/messenger", "Paste → Save"],
                  "fields": [_f("page_id", "Page ID", "Page ID", secret=False),
                             _f("page_name", "Page name", "Page name", secret=False),
                             _f("access_token", "Page access token", "Page access token"),
                             _f("verify_token", "Webhook verify token", "Webhook verify token")],
                  "test": None},
    "instagram": {"name": "Instagram (Business/Creator)", "category": "Business",
                  "unlocks_bn": "Business mode: Instagram DM সেলস সহকারী ও lead capture।",
                  "unlocks_en": "Business mode: Instagram DM sales assistant & lead capture.",
                  "guide_bn": ["Instagram কে একটি Facebook Page-এর সাথে যুক্ত করুন (Business/Creator)",
                               "developers.facebook.com → Instagram → access token কপি → পেস্ট → Save"],
                  "guide_en": ["Link the Instagram account to a Facebook Page (Business/Creator)",
                               "developers.facebook.com → Instagram → copy access token → paste → Save"],
                  "fields": [_f("ig_user_id", "IG user ID", "IG user ID", secret=False),
                             _f("access_token", "Access token", "Access token")],
                  "test": None},
    # ---- p1-bizagent ----
    "meta_app": {"name": "Meta app (Business AI Agent webhooks)", "category": "Business",
                 "unlocks_bn": "বিক্রেতাদের Facebook Page, Instagram ও WhatsApp মেসেজ Assisto-তে আসে; AI উত্তর দেয়।",
                 "unlocks_en": "Sellers' Facebook Page, Instagram and WhatsApp messages reach Assisto; the AI replies.",
                 "guide_bn": ["developers.facebook.com → My Apps → Create App (Business টাইপ)",
                              "App settings → Basic → App ID ও App Secret কপি",
                              "নিজের একটি verify token বানান (লম্বা র‍্যান্ডম লেখা)",
                              "Webhooks: https://api.lifeassisto.com/api/v1/bizagent/webhook/meta এবং /api/v1/bizagent/webhook/whatsapp",
                              "বিস্তারিত: owner_actions/BUSINESS_AGENT_SETUP.md"],
                 "guide_en": ["developers.facebook.com → My Apps → Create App (Business type)",
                              "App settings → Basic → copy App ID and App Secret",
                              "Make your own verify token (a long random string)",
                              "Webhooks: https://api.lifeassisto.com/api/v1/bizagent/webhook/meta and /api/v1/bizagent/webhook/whatsapp",
                              "Details: owner_actions/BUSINESS_AGENT_SETUP.md"],
                 "fields": [_f("app_id", "App ID", "App ID", secret=False),
                            _f("app_secret", "App Secret", "App Secret"),
                            _f("verify_token", "Webhook verify token", "Webhook verify token"),
                            _f("graph_version", "Graph API version (খালি = v23.0)",
                               "Graph API version (blank = v23.0)", secret=False)],
                 "test": None},
    "courier_pathao": {"name": "Pathao Courier (owner-level fallback)", "category": "Business",
                       "unlocks_bn": "যে বিক্রেতা নিজের কী দেননি, তাদের জন্য Pathao বুকিং (ঐচ্ছিক)।",
                       "unlocks_en": "Pathao booking for sellers without their own key (optional).",
                       "guide_bn": ["merchant.pathao.com → Developer's API → Merchant API credentials", "পেস্ট → Save"],
                       "guide_en": ["merchant.pathao.com → Developer's API → Merchant API credentials", "Paste → Save"],
                       "fields": [_f("client_id", "Client ID", "Client ID", secret=False),
                                  _f("client_secret", "Client secret", "Client secret"),
                                  _f("username", "Merchant e-mail", "Merchant e-mail", secret=False),
                                  _f("password", "Merchant password", "Merchant password"),
                                  _f("store_id", "Store ID", "Store ID", secret=False),
                                  _f("sandbox", "Sandbox (yes/no)", "Sandbox (yes/no)", secret=False)],
                       "test": None},
    "courier_steadfast": {"name": "Steadfast Courier (owner-level fallback)", "category": "Business",
                          "unlocks_bn": "Steadfast বুকিং ও স্ট্যাটাস (ঐচ্ছিক)।",
                          "unlocks_en": "Steadfast booking & status (optional).",
                          "guide_bn": ["portal.packzy.com → API → API key + Secret key", "পেস্ট → Save"],
                          "guide_en": ["portal.packzy.com → API → API key + Secret key", "Paste → Save"],
                          "fields": [_f("api_key", "API key", "API key"),
                                     _f("secret_key", "Secret key", "Secret key")],
                          "test": None},
    "courier_redx": {"name": "RedX (owner-level fallback)", "category": "Business",
                     "unlocks_bn": "RedX পার্সেল বুকিং ও ট্র্যাকিং (ঐচ্ছিক)।",
                     "unlocks_en": "RedX parcel booking & tracking (optional).",
                     "guide_bn": ["redx.com.bd merchant → Developer API → access token", "পেস্ট → Save"],
                     "guide_en": ["redx.com.bd merchant → Developer API → access token", "Paste → Save"],
                     "fields": [_f("access_token", "Access token", "Access token"),
                                _f("pickup_store_id", "Pickup store ID", "Pickup store ID", secret=False),
                                _f("sandbox", "Sandbox (yes/no)", "Sandbox (yes/no)", secret=False)],
                     "test": None},
    # ---- /p1-bizagent ----
    "ocr": {"name": "OCR (document scanner)", "category": "AI",
            "unlocks_bn": "ডকুমেন্ট স্ক্যানার: ছবি/রসিদ→টেক্সট (বাংলা+ইংরেজি)।",
            "unlocks_en": "Document scanner: image/receipt → text (Bangla + English).",
            "guide_bn": ["OCR প্রোভাইডার (Google Vision/OCR.space) → API key → পেস্ট → Save",
                         "key ছাড়া on-device fallback চলে (কম নির্ভুল)"],
            "guide_en": ["OCR provider (Google Vision / OCR.space) → API key → paste → Save",
                         "Without a key an on-device fallback runs (less accurate)"],
            "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
            "test": None},
    "transcription": {"name": "Speech-to-text (STT / transcription)", "category": "AI",
                      "unlocks_bn": "ভয়েস কমান্ড, কল/মিটিং ট্রান্সক্রিপশন (দুই পক্ষকে জানানো হয়)।",
                      "unlocks_en": "Voice commands, call/meeting transcription (both parties notified).",
                      "guide_bn": ["STT প্রোভাইডার (Deepgram/Google STT/Whisper) → API key → পেস্ট → Save"],
                      "guide_en": ["STT provider (Deepgram / Google STT / Whisper) → API key → paste → Save"],
                      "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
                      "test": None},
    "voice_clone": {"name": "Voice clone (TTS)", "category": "AI",
                    "unlocks_bn": "নিজের অনুমোদিত কণ্ঠে AI রিপ্লাই/ব্রিফিং (self-verified)।",
                    "unlocks_en": "AI replies/briefing in the owner's self-verified cloned voice.",
                    "guide_bn": ["TTS প্রোভাইডার (ElevenLabs ইত্যাদি) → API key + voice ID → পেস্ট → Save"],
                    "guide_en": ["TTS provider (ElevenLabs etc) → API key + voice ID → paste → Save"],
                    "fields": [_f("api_key", "API Key", "API Key"), _f("voice_id", "Voice ID", "Voice ID", secret=False)],
                    "test": None},
    "weather": {"name": "Weather", "category": "Media",
                "unlocks_bn": "সকালের ব্রিফিং-এ আবহাওয়া।", "unlocks_en": "Weather in the morning briefing.",
                "guide_bn": ["openweathermap.org (বা অনুরূপ) → API key → পেস্ট → Save"],
                "guide_en": ["openweathermap.org (or similar) → API key → paste → Save"],
                "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
                "test": None},
    # ---- a3-voice ---- Part 3: optional on-device "Hey Assisto" wake word.
    "picovoice": {"name": "Picovoice wake word (Hey Assisto)", "category": "AI",
                  "unlocks_bn": "ঐচ্ছিক “হেই অ্যাসিস্টো” ডাক — ফোনেই শনাক্ত হয়, কোনো শব্দ সার্ভারে আসে না।",
                  "unlocks_en": "Optional “Hey Assisto” wake word — detected on the phone, no audio reaches the server.",
                  "guide_bn": ["console.picovoice.ai-এ অ্যাকাউন্ট খুলুন → AccessKey কপি করুন",
                               "Porcupine → wake word “Hey Assisto” ও “Hi Assisto” → Platform: Android → দুটি .ppn ফাইল নামান",
                               ".ppn ফাইল https লিংকে রাখুন → লিংকগুলো কমা দিয়ে আলাদা করে ও AccessKey নিচে দিন → Save → Test",
                               "অ্যাপে একটি আপডেট লাগবে (Porcupine লাইব্রেরি) — integrator proposal a3-voice ধাপ ২",
                               "বাণিজ্যিক ব্যবহারে Picovoice-এর পেইড প্ল্যান লাগতে পারে — শর্ত দেখে নিন"],
                  "guide_en": ["Create an account at console.picovoice.ai → copy the AccessKey",
                               "Porcupine → wake words “Hey Assisto” and “Hi Assisto” → Platform: Android → download both .ppn files",
                               "Host the .ppn files at https URLs → paste the URLs (comma-separated) + AccessKey below → Save → Test",
                               "The app needs one update (Porcupine library) — integrator proposal a3-voice stage 2",
                               "Commercial use may need a paid Picovoice plan — check their terms"],
                  "fields": [_f("access_key", "AccessKey", "AccessKey"),
                             _f("keyword_url", "কিওয়ার্ড ফাইলের লিংক (.ppn, কমা দিয়ে একাধিক)", "Keyword file URL(s) (.ppn, comma-separated)", secret=False),
                             _f("sensitivity", "সংবেদনশীলতা (০.১–০.৯৫)", "Sensitivity (0.1–0.95)", secret=False)],
                  "test": "test_picovoice"},
    # ---- ps1-photo ---- Photo Studio cloud image providers (edit / generate /
    # heavy enhance). Switchable: the owner connects one or more and picks the
    # active one in /admin/pricing photo_studio.provider ('' = first connected).
    # "Cost per image" is REQUIRED: Profit Guard prices every job from it (the
    # larger of it and the pricing table), and a provider with no cost is never
    # used — we never run a job we cannot price.
    "photo_gemini": {"name": "Gemini image editing (Photo Studio)", "category": "AI",
                     "unlocks_bn": "ফটো স্টুডিও: প্রম্পট দিয়ে এডিট/নতুন ছবি (ব্যাকগ্রাউন্ড, আকাশ, আলো, প্রোডাক্ট ফটো)।",
                     "unlocks_en": "Photo Studio: edit / generate by prompt (background, sky, lighting, product photo).",
                     "guide_bn": ["aistudio.google.com → Get API key (বিলিং চালু রাখুন)",
                                  "মডেল: gemini-2.5-flash-image (বা আপনার অ্যাকাউন্টে যেটি আছে)",
                                  "ছবি প্রতি খরচ (USD) Google-এর মূল্য তালিকা দেখে লিখুন → Save → Test"],
                     "guide_en": ["aistudio.google.com → Get API key (billing on)",
                                  "Model: gemini-2.5-flash-image (or the image model on your account)",
                                  "Enter cost per image (USD) from Google's price list → Save → Test"],
                     "fields": [_f("api_key", "API Key", "API Key"),
                                _f("model", "মডেল", "Model", secret=False),
                                _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                     "test": "test_gemini"},
    "photo_openai": {"name": "OpenAI images (Photo Studio)", "category": "AI",
                     "unlocks_bn": "ফটো স্টুডিও: OpenAI দিয়ে প্রম্পট এডিট/নতুন ছবি।",
                     "unlocks_en": "Photo Studio: prompt edit / generate with OpenAI.",
                     "guide_bn": ["platform.openai.com → API keys → Create (Images চালু থাকতে হবে)",
                                  "মডেল: gpt-image-1 (বা আপনার অ্যাকাউন্টের ইমেজ মডেল)",
                                  "ছবি প্রতি খরচ (USD) লিখুন → Save → Test"],
                     "guide_en": ["platform.openai.com → API keys → Create (Images enabled)",
                                  "Model: gpt-image-1 (or your account's image model)",
                                  "Enter cost per image (USD) → Save → Test"],
                     "fields": [_f("api_key", "API Key", "API Key"),
                                _f("model", "মডেল", "Model", secret=False),
                                _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                     "test": "test_openai"},
    "photo_replicate": {"name": "Replicate-class image models (Photo Studio)", "category": "AI",
                        "unlocks_bn": "ফটো স্টুডিও: ভারী এনহ্যান্স/এডিট (বাণিজ্যিক লাইসেন্সের মডেলই শুধু)।",
                        "unlocks_en": "Photo Studio: heavy enhance / edit (commercial-licence models only).",
                        "guide_bn": ["replicate.com → Account → API token",
                                     "মডেল version ID দিন — শুধু বাণিজ্যিক ব্যবহারযোগ্য লাইসেন্স (.phaseB/MODEL_LICENSES.md)",
                                     "ছবি প্রতি খরচ (USD) লিখুন → Save → Test"],
                        "guide_en": ["replicate.com → Account → API token",
                                     "Model version id — commercial-use licence only (.phaseB/MODEL_LICENSES.md)",
                                     "Enter cost per image (USD) → Save → Test"],
                        "fields": [_f("api_token", "API Token", "API Token"),
                                   _f("model", "মডেল version", "Model version", secret=False),
                                   _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                        "test": "test_replicate"},
    # ---- d1-photo ---- pay-per-use GPU for the heavy restore job that our CPU
    # server is too slow for (NAFNet deblur: 16 s at 768x576, 69 s at 1024x768
    # on the server). Hidden in the app until connected AND priced.
    "photo_restore_gpu": {"name": "GPU photo repair (Replicate) — Photo Studio deblur", "category": "AI",
                          "unlocks_bn": "ফটো স্টুডিও: ঝাপসা ছবি পরিষ্কার (NAFNet, MIT লাইসেন্স) — প্রতি কাজে টাকা।",
                          "unlocks_en": "Photo Studio: remove blur (NAFNet, MIT licence) — pay per run.",
                          "guide_bn": ["replicate.com → Account → API token",
                                       "replicate.com/megvii-research/nafnet → Versions → version ID কপি করুন",
                                       "Task: Image Debluring (GoPro) (খালি রাখলে এটাই)",
                                       "প্রতি কাজের খরচ (USD) লিখুন (Replicate পেজে GPU সময় × দাম) → Save → Test"],
                          "guide_en": ["replicate.com → Account → API token",
                                       "replicate.com/megvii-research/nafnet → Versions → copy the version id",
                                       "Task: Image Debluring (GoPro) (the default when empty)",
                                       "Enter cost per run (USD) from Replicate's GPU time × price → Save → Test"],
                          "fields": [_f("api_token", "API Token", "API Token"),
                                     _f("deblur_version", "NAFNet মডেল version", "NAFNet model version", secret=False),
                                     _f("deblur_task", "Task (ঐচ্ছিক)", "Task (optional)", secret=False),
                                     _f("cost_per_run_usd", "প্রতি কাজের খরচ (USD)", "Cost per run (USD)", secret=False),
                                     _f("enhance_version", "Premium HD: Real-ESRGAN মডেল version (ঐচ্ছিক)",
                                        "Premium HD: Real-ESRGAN model version (optional)", secret=False),
                                     _f("enhance_cost_usd", "Premium HD: প্রতি ছবির খরচ (USD)",
                                        "Premium HD: cost per image (USD)", secret=False)],
                          "test": "test_replicate"},
    # ---- /d1-photo ----
    # ---- photo-final ---- server-side provider switch for HD enhance (the app
    # never calls a provider). Rollout % per provider + daily spend cap live in
    # Owner Admin → Ads/Pricing (photo_studio block). Guide: owner_actions/PHOTO_GPU_SETUP_BN.md
    "photo_enhance_replicate": {"name": "Photo Studio HD enhance — Replicate (GPU, pay per second)", "category": "AI",
                                "unlocks_bn": "ফটো স্টুডিও HD এনহ্যান্স GPU-তে: Real-ESRGAN x2 — শুধু মালিক Pricing-এ realesrgan_allowed চালু করলে (weights-এর লাইসেন্স ধূসর)। GFPGAN কখনো নয়।",
                                "unlocks_en": "Photo Studio HD enhance on GPU: Real-ESRGAN x2 — only once the owner turns realesrgan_allowed on in Pricing (weights licence grey). Never GFPGAN.",
                                "guide_bn": ["replicate.com → Account → API tokens → Create token",
                                             "replicate.com/nightmareai/real-esrgan → Versions → version ID কপি করুন",
                                             "প্রতি সেকেন্ড GPU দাম (USD) ও ছবি প্রতি আনুমানিক খরচ (USD) লিখুন → Save → Test",
                                             "Owner Admin → Ads/Pricing → photo_studio.realesrgan_allowed ও rollout_replicate (%)"],
                                "guide_en": ["replicate.com → Account → API tokens → Create token",
                                             "replicate.com/nightmareai/real-esrgan → Versions → copy the version id",
                                             "Enter the GPU price per second (USD) and the estimated cost per image (USD) → Save → Test",
                                             "Owner Admin → Ads/Pricing → photo_studio.realesrgan_allowed and rollout_replicate (%)"],
                                "fields": [_f("api_token", "API Token", "API Token"),
                                           _f("upscale_version", "Real-ESRGAN মডেল version", "Real-ESRGAN model version", secret=False),
                                           _f("usd_per_second", "GPU দাম প্রতি সেকেন্ড (USD)", "GPU price per second (USD)", secret=False),
                                           _f("cost_per_image_usd", "ছবি প্রতি আনুমানিক খরচ (USD)", "Estimated cost per image (USD)", secret=False)],
                                "test": "test_replicate"},
    "photo_runpod": {"name": "Photo Studio HD enhance — RunPod Serverless", "category": "AI",
                     "unlocks_bn": "ফটো স্টুডিও HD এনহ্যান্স RunPod Serverless-এ (প্রতি সেকেন্ডে টাকা, ব্যবহার না হলে শূন্য)।",
                     "unlocks_en": "Photo Studio HD enhance on RunPod Serverless (per second, scales to zero).",
                     "guide_bn": ["runpod.io → Settings → API Keys → Create (Read/Write)",
                                  "Serverless → endpoint (tools/photo_train/serve_handler.py) → Endpoint ID কপি",
                                  "প্রতি সেকেন্ড দাম ও ছবি প্রতি আনুমানিক খরচ (USD) লিখুন → Save"],
                     "guide_en": ["runpod.io → Settings → API Keys → Create (Read/Write)",
                                  "Serverless → endpoint (tools/photo_train/serve_handler.py) → copy the Endpoint ID",
                                  "Enter price per second and estimated cost per image (USD) → Save"],
                     "fields": [_f("api_key", "API Key", "API Key"),
                                _f("endpoint_id", "Endpoint ID", "Endpoint ID", secret=False),
                                _f("model_version", "মডেল version (লগের জন্য)", "Model version (for the log)", secret=False),
                                _f("usd_per_second", "দাম প্রতি সেকেন্ড (USD)", "Price per second (USD)", secret=False),
                                _f("cost_per_image_usd", "ছবি প্রতি আনুমানিক খরচ (USD)", "Estimated cost per image (USD)", secret=False)],
                     "test": None},
    "photo_assisto_face": {"name": "Photo Studio — Assisto Face (own model, RunPod Serverless)", "category": "AI",
                           "unlocks_bn": "আমাদের নিজের 'Assisto Face' মডেল (Phase 2) — দক্ষিণ এশীয় মুখের জন্য।",
                           "unlocks_en": "Our own 'Assisto Face' model (Phase 2) — tuned for South Asian faces.",
                           "guide_bn": ["Phase 2 (নিজস্ব মডেল) — এখনো তৈরি হয়নি; পরিকল্পনা পরে আসবে"],
                           "guide_en": ["Phase 2 (own model) — not built yet; plan comes later"],
                           "fields": [_f("api_key", "API Key", "API Key"),
                                      _f("endpoint_id", "Endpoint ID", "Endpoint ID", secret=False),
                                      _f("model_version", "মডেল version", "Model version", secret=False),
                                      _f("usd_per_second", "দাম প্রতি সেকেন্ড (USD)", "Price per second (USD)", secret=False),
                                      _f("cost_per_image_usd", "ছবি প্রতি আনুমানিক খরচ (USD)", "Estimated cost per image (USD)", secret=False)],
                           "test": None},
    "photo_fal": {"name": "Photo Studio — fal.ai (Ultra HD for Premium + optional face upscaler)", "category": "AI",
                  "unlocks_bn": "প্রিমিয়ামে Ultra HD (মাসিক কোটা — খরচ প্ল্যানের দামের বেশি হবে না) এবং মালিক বেছে নিলে HD এনহ্যান্সে ফেস-আপস্কেলার (Topaz বা Clarity Crystal)।",
                  "unlocks_en": "Premium Ultra HD (monthly quota — cost never above the plan price) and, once the owner chooses, a face upscaler for HD enhance (Topaz or Clarity Crystal).",
                  "guide_bn": ["fal.ai → Dashboard → Keys → Add key",
                               "Ultra HD মডেল: clarityai/crystal-upscaler (খালি রাখলে এটাই) বা fal-ai/topaz/upscale/image",
                               "Ultra HD দাম প্রতি মেগাপিক্সেল (USD, fal.ai পেজ থেকে) লিখুন",
                               "ফেস-আপস্কেলার: Topaz দাম/ছবি বা Crystal দাম/MP লিখুন, তারপর Pricing → photo_studio.fal_face_model = topaz বা crystal এবং rollout_fal_face (%)",
                               "Save"],
                  "guide_en": ["fal.ai → Dashboard → Keys → Add key",
                               "Ultra HD model: clarityai/crystal-upscaler (the default when empty) or fal-ai/topaz/upscale/image",
                               "Enter the Ultra HD price per megapixel (USD, from the fal.ai page)",
                               "Face upscaler: enter the Topaz price per image or the Crystal price per MP, then Pricing → photo_studio.fal_face_model = topaz or crystal and rollout_fal_face (%)",
                               "Save"],
                  "fields": [_f("api_key", "API Key", "API Key"),
                             _f("model", "Ultra HD মডেল", "Ultra HD model", secret=False),
                             _f("usd_per_megapixel", "Ultra HD দাম প্রতি মেগাপিক্সেল (USD)", "Ultra HD price per megapixel (USD)", secret=False),
                             _f("cost_per_image_usd", "Ultra HD ছবি প্রতি ন্যূনতম খরচ (USD, ঐচ্ছিক)", "Ultra HD minimum cost per image (USD, optional)", secret=False),
                             _f("scale", "স্কেল (২)", "Scale (2)", secret=False),
                             _f("input_mp", "ইনপুট সর্বোচ্চ MP (১)", "Max input MP (1)", secret=False),
                             _f("topaz_usd_per_image", "Topaz দাম প্রতি ছবি (USD, যেমন 0.08)", "Topaz price per image (USD, e.g. 0.08)", secret=False),
                             _f("crystal_usd_per_megapixel", "Crystal দাম প্রতি মেগাপিক্সেল (USD, যেমন 0.016)", "Crystal price per megapixel (USD, e.g. 0.016)", secret=False)],
                  "test": None},
    # ---- /photo-final ----
    # ---- /ps1-photo ----
    # ---- h1-home ---- Image in chat: cloud VISION providers (read a photo and
    # answer a question about it). Switchable like Photo Studio: the active one
    # is /admin/pricing chat_vision.provider ('' = first ready). "Cost per
    # image" is REQUIRED — a provider without it is never used (we never run
    # an answer we cannot price). Images are never stored.
    "vision_claude": {"name": "Claude vision (image in chat)", "category": "AI",
                      "unlocks_bn": "চ্যাটে ছবি: ওষুধের বাক্স, বিল, গাছ, নথি পড়ে বিস্তারিত উত্তর।",
                      "unlocks_en": "Image in chat: detailed answers about medicine boxes, bills, plants, documents.",
                      "guide_bn": ["console.anthropic.com → API Keys → Create Key",
                                   "মডেল: claude-sonnet-5-5 (ডিফল্ট), বেশি নিখুঁত চাইলে claude-opus-5-5, সস্তা চাইলে claude-haiku-5-5",
                                   "ছবি প্রতি খরচ (USD) লিখুন → Save → Test"],
                      "guide_en": ["console.anthropic.com → API Keys → Create Key",
                                   "Model: claude-sonnet-5-5 (default), claude-opus-5-5 for best accuracy, claude-haiku-5-5 for lowest cost",
                                   "Enter cost per image (USD) → Save → Test"],
                      "fields": [_f("api_key", "API Key", "API Key"),
                                 _f("model", "মডেল", "Model", secret=False),
                                 _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                      "test": "test_anthropic"},
    "vision_openai": {"name": "OpenAI vision (image in chat)", "category": "AI",
                      "unlocks_bn": "চ্যাটে ছবি: OpenAI দিয়ে ছবি পড়ে উত্তর।",
                      "unlocks_en": "Image in chat: answers about a photo with OpenAI.",
                      "guide_bn": ["platform.openai.com → API keys → Create",
                                   "মডেল: আপনার অ্যাকাউন্টের ভিশন-সক্ষম মডেল (যেমন gpt-4o-mini)",
                                   "ছবি প্রতি খরচ (USD) লিখুন → Save → Test"],
                      "guide_en": ["platform.openai.com → API keys → Create",
                                   "Model: a vision-capable model on your account (e.g. gpt-4o-mini)",
                                   "Enter cost per image (USD) → Save → Test"],
                      "fields": [_f("api_key", "API Key", "API Key"),
                                 _f("model", "মডেল", "Model", secret=False),
                                 _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                      "test": "test_openai"},
    "vision_gemini": {"name": "Gemini vision (image in chat)", "category": "AI",
                      "unlocks_bn": "চ্যাটে ছবি: Gemini দিয়ে ছবি পড়ে উত্তর।",
                      "unlocks_en": "Image in chat: answers about a photo with Gemini.",
                      "guide_bn": ["aistudio.google.com → Get API key (বিলিং চালু রাখুন)",
                                   "মডেল: gemini-2.5-flash (বা আপনার অ্যাকাউন্টের মডেল)",
                                   "ছবি প্রতি খরচ (USD) লিখুন → Save → Test"],
                      "guide_en": ["aistudio.google.com → Get API key (billing on)",
                                   "Model: gemini-2.5-flash (or the model on your account)",
                                   "Enter cost per image (USD) → Save → Test"],
                      "fields": [_f("api_key", "API Key", "API Key"),
                                 _f("model", "মডেল", "Model", secret=False),
                                 _f("cost_per_image_usd", "ছবি প্রতি খরচ (USD)", "Cost per image (USD)", secret=False)],
                      "test": "test_gemini"},
    # ---- /h1-home ----
    # ---- g1-bizagent ---- customer voice notes in the seller's AI agent
    "voice_transcribe": {"name": "Voice-note transcription (Business AI agent)", "category": "AI",
                         "unlocks_bn": "বিজনেস AI এজেন্ট: গ্রাহকের ভয়েস মেসেজ লেখায় রূপান্তর করে উত্তর দেয়।",
                         "unlocks_en": "Business AI agent: turns a customer's voice note into text and answers it.",
                         "guide_bn": ["platform.openai.com → API keys → Create (Audio চালু থাকতে হবে)",
                                      "মডেল: gpt-4o-mini-transcribe (ডিফল্ট) বা whisper-1",
                                      "মিনিট প্রতি খরচ (USD) লিখুন → Save → Test"],
                         "guide_en": ["platform.openai.com → API keys → Create (Audio enabled)",
                                      "Model: gpt-4o-mini-transcribe (default) or whisper-1",
                                      "Enter cost per minute (USD) → Save → Test"],
                         "fields": [_f("api_key", "API Key", "API Key"),
                                    _f("model", "মডেল", "Model", secret=False),
                                    _f("cost_per_minute_usd", "মিনিট প্রতি খরচ (USD)", "Cost per minute (USD)", secret=False)],
                         "test": "test_openai"},
    # ---- /g1-bizagent ----
    "news": {"name": "News", "category": "Media",
             "unlocks_bn": "সকালের ব্রিফিং-এ খবরের শিরোনাম।", "unlocks_en": "Headlines in the morning briefing.",
             "guide_bn": ["newsapi.org (বা অনুরূপ) → API key → পেস্ট → Save (key ছাড়া RSS fallback)"],
             "guide_en": ["newsapi.org (or similar) → API key → paste → Save (RSS fallback if no key)"],
             "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
             "test": None},
    # ---- p4-world ---- Unseen World: live web search answers, sports scores,
    # job alerts. Each is HIDDEN for users until connected (no fake data).
    "web_search": {
        "name": "Web search (live AI answers with sources)", "category": "AI",
        "unlocks_bn": "অদেখা দুনিয়া → “যেকোনো প্রশ্ন”: লাইভ ওয়েব সার্চ করে সূত্রসহ ([১][২]) বাংলা/ইংরেজি উত্তর। প্রতি উত্তরে ক্রেডিট কাটে (web_answer)।",
        "unlocks_en": "Unseen World → “Ask anything”: live web search answers with numbered sources [1][2], Bangla/English. Each answer costs credits (web_answer).",
        "guide_bn": ["প্রোভাইডার বাছুন: brave (api-dashboard.search.brave.com → API key) অথবা tavily (app.tavily.com → API key)",
                     "provider ঘরে brave বা tavily লিখুন, ওই প্রোভাইডারের key পেস্ট করুন",
                     "সার্চ প্রতি খরচ (USD) লিখুন — Brave ≈ 0.005, Tavily ≈ 0.008",
                     "AI উত্তরের জন্য Anthropic key আগে থেকেই থাকতে হবে → Save → Test",
                     "বিস্তারিত: owner_actions/UNSEEN_WORLD_KEYS_BN.md"],
        "guide_en": ["Pick a provider: brave (api-dashboard.search.brave.com → API key) or tavily (app.tavily.com → API key)",
                     "Type brave or tavily in Provider and paste that provider's key",
                     "Enter cost per search (USD) — Brave ≈ 0.005, Tavily ≈ 0.008",
                     "The Anthropic key must already be connected for the AI answer → Save → Test",
                     "Details: owner_actions/UNSEEN_WORLD_KEYS_BN.md"],
        "fields": [_f("provider", "প্রোভাইডার (brave / tavily)", "Provider (brave / tavily)", secret=False),
                   _f("brave_api_key", "Brave API key", "Brave API key"),
                   _f("tavily_api_key", "Tavily API key", "Tavily API key"),
                   _f("cost_per_search_usd", "সার্চ প্রতি খরচ (USD)", "Cost per search (USD)", secret=False)],
        "test": "test_web_search"},
    "sports_football": {
        "name": "Football live scores (API-Football)", "category": "Media",
        "unlocks_bn": "আজকের কার্ড: ফুটবলের লাইভ স্কোর (লাইসেন্সকৃত API)। key ছাড়া কার্ডটি লুকানো থাকে।",
        "unlocks_en": "Today cards: live football scores (licensed API). Hidden until a key is added.",
        "guide_bn": ["dashboard.api-football.com-এ অ্যাকাউন্ট খুলুন (ফ্রি: দিনে ১০০ কল)", "API key কপি → পেস্ট",
                     "কল প্রতি খরচ (USD) লিখুন (ফ্রি প্ল্যানে 0) → Save → Test"],
        "guide_en": ["Create an account at dashboard.api-football.com (free: 100 calls/day)", "Copy the API key → paste",
                     "Enter cost per call (USD) (0 on the free plan) → Save → Test"],
        "fields": [_f("api_key", "API Key", "API Key"),
                   _f("cost_per_call_usd", "কল প্রতি খরচ (USD)", "Cost per call (USD)", secret=False)],
        "test": "test_sports_football"},
    "sports_cricket": {
        "name": "Cricket live scores (CricketData.org)", "category": "Media",
        "unlocks_bn": "আজকের কার্ড: ক্রিকেটের লাইভ স্কোর (লাইসেন্সকৃত API)। key ছাড়া কার্ডটি লুকানো থাকে।",
        "unlocks_en": "Today cards: live cricket scores (licensed API). Hidden until a key is added.",
        "guide_bn": ["cricketdata.org-এ সাইন আপ → API key (ফ্রি: দিনে ১০০ হিট)", "key পেস্ট করুন",
                     "কল প্রতি খরচ (USD) লিখুন → Save → Test"],
        "guide_en": ["Sign up at cricketdata.org → API key (free: 100 hits/day)", "Paste the key",
                     "Enter cost per call (USD) → Save → Test"],
        "fields": [_f("api_key", "API Key", "API Key"),
                   _f("cost_per_call_usd", "কল প্রতি খরচ (USD)", "Cost per call (USD)", secret=False)],
        "test": "test_sports_cricket"},
    "jobs_careerjet": {
        "name": "Job alerts (Careerjet publisher API)", "category": "Media",
        "unlocks_bn": "চাকরির হাব: ব্যবহারকারীর বেছে নেওয়া ধরনে দিনে সর্বোচ্চ ১টি চাকরির সতর্কতা (শুধু শিরোনাম + লিংক)।",
        "unlocks_en": "Jobs hub: at most 1 job alert a day for the job types the user picked (title + link only).",
        "guide_bn": ["careerjet.com → Partners/Publishers → অ্যাকাউন্ট খুলুন", "Publisher API key কপি → পেস্ট → Save → Test"],
        "guide_en": ["careerjet.com → Partners/Publishers → create an account", "Copy the publisher API key → paste → Save → Test"],
        "fields": [_f("api_key", "Publisher API key", "Publisher API key")],
        "test": "test_jobs_careerjet"},
    # ---- /p4-world ----
    # ---- t9-turnscale ---- managed-TURN overflow (OFF by default)
    "turn_overflow": {
        "name": "Managed TURN overflow (Cloudflare Calls)", "category": "Calls",
        "unlocks_bn": "আমাদের কল-রিলে সার্ভার ভরে গেলে (বা বন্ধ থাকলে) বাড়তি কল Cloudflare-এর TURN দিয়ে চলবে। ডিফল্ট বন্ধ; এতে প্রতি GB খরচ আছে।",
        "unlocks_en": "When our own call relay is near full (or down), extra calls relay through Cloudflare's TURN. Off by default; it is billed per GB.",
        "guide_bn": ["dash.cloudflare.com → Calls → TURN → Create TURN key",
                     "Turn Token ID লিখুন (key_id) ও API Token পেস্ট করুন",
                     "mode: overflow (শুধু ভরে গেলে) বা always; threshold_pct: যেমন 70",
                     "enabled: on লিখুন → Save → Test (সফল হলে চালু হবে)",
                     "বন্ধ করতে enabled: off লিখে Save করুন"],
        "guide_en": ["dash.cloudflare.com → Calls → TURN → Create TURN key",
                     "Enter the Turn Token ID (key_id) and paste the API Token",
                     "mode: overflow (only when ours is near full) or always; threshold_pct e.g. 70",
                     "enabled: on → Save → Test (active only after a passing test)",
                     "To switch off: enabled: off → Save"],
        "fields": [_f("key_id", "Turn Token ID", "Turn Token ID", secret=False),
                   _f("api_token", "API Token", "API Token"),
                   _f("mode", "মোড (overflow/always)", "Mode (overflow/always)", secret=False),
                   _f("threshold_pct", "সীমা % (যেমন 70)", "Threshold % (e.g. 70)", secret=False),
                   _f("enabled", "চালু (on/off)", "Enabled (on/off)", secret=False)],
        "test": "test_turn_overflow"},
}


# ---------------------------------------------------------------- store API
def _row(slug):
    from .models import Integration
    obj, _ = Integration.objects.get_or_create(slug=slug)
    return obj


def get(slug: str) -> dict:
    """Decrypted config for a slug (for feature use). Empty dict if unset."""
    if slug not in REGISTRY:
        return {}
    from .models import Integration
    obj = Integration.objects.filter(slug=slug).first()
    return _decrypt(obj.enc_blob) if obj else {}


def is_enabled(slug: str) -> bool:
    """A feature should use this to decide active vs 'Available when ___'."""
    from .models import Integration
    obj = Integration.objects.filter(slug=slug).first()
    return bool(obj and obj.status == "working")


def save(slug: str, data: dict):
    if slug not in REGISTRY:
        raise ValueError("unknown integration")
    obj = _row(slug)
    # merge: keep existing secret fields the owner didn't re-enter (blank)
    cur = _decrypt(obj.enc_blob)
    merged = dict(cur)
    for k, v in data.items():
        if v != "" and v is not None:
            merged[k] = v
    obj.enc_blob = _encrypt(merged)
    obj.save(update_fields=["enc_blob", "updated_at"])
    return obj


def test(slug: str) -> tuple:
    """Run the connection test. Returns (status, detail). Honest: a feature
    without an automated test is marked 'working' only as 'saved' (verified on
    first real use)."""
    meta = REGISTRY.get(slug)
    if not meta:
        return ("failing", "unknown integration")
    cfg = get(slug)
    if not cfg:
        return ("not_set", "কোনো তথ্য দেওয়া হয়নি / nothing entered")
    fn = meta.get("test")
    obj = _row(slug)
    if not fn:
        status, detail = ("working", "সেভ হয়েছে — প্রথম ব্যবহারে যাচাই হবে / saved — verified on first use")
    else:
        try:
            ok, detail = globals()[fn](cfg)
            status = "working" if ok else "failing"
        except Exception as e:  # noqa: BLE001
            status, detail = ("failing", str(e)[:280])
    obj.status = status
    obj.detail = detail[:300]
    obj.last_tested = timezone.now()
    obj.save(update_fields=["status", "detail", "last_tested", "updated_at"])
    return (status, detail)


def _status_label(status, lang):
    """Honest, owner-readable state. 'connected' means at least one key is saved
    and the last test (if any) did not fail; features gate on is_enabled()."""
    return {
        "working": ("সংযুক্ত / CONNECTED", "CONNECTED"),
        "failing": ("ব্যর্থ — ঠিক করুন / NOT WORKING", "NOT WORKING"),
        "not_set": ("সংযুক্ত নয় / NOT CONNECTED", "NOT CONNECTED"),
    }[status][0 if lang == "bn" else 1]


def list_all(lang="bn") -> list:
    """Owner-facing list: metadata + status + last-checked + how-to-connect doc,
    NEVER raw secrets (masked). Honest states only."""
    from .models import Integration
    rows = {o.slug: o for o in Integration.objects.all()}
    out = []
    for slug, meta in REGISTRY.items():
        obj = rows.get(slug)
        cfg = _decrypt(obj.enc_blob) if obj else {}
        fields = []
        any_set = False
        for f in meta["fields"]:
            has = bool(cfg.get(f["key"]))
            any_set = any_set or has
            fields.append({
                "key": f["key"],
                "label": f["label_bn"] if lang == "bn" else f["label_en"],
                "secret": f["secret"],
                "set": has,
                "masked": "•••• " + str(cfg.get(f["key"]))[-4:] if (has and f["secret"]) else (cfg.get(f["key"]) if has else ""),
            })
        status = obj.status if obj else "not_set"
        last = obj.last_tested if obj else None
        out.append({
            "slug": slug,
            "name": meta["name"],
            "category": meta["category"],
            "unlocks": meta["unlocks_bn"] if lang == "bn" else meta["unlocks_en"],
            "guide": meta["guide_bn"] if lang == "bn" else meta["guide_en"],
            "fields": fields,
            "status": status,
            "status_label": _status_label(status, lang),
            "connected": status == "working",
            "any_key_saved": any_set,
            "detail": obj.detail if obj else "",
            "last_tested": last.isoformat() if last else "",
            "last_tested_human": (timezone.localtime(last).strftime("%Y-%m-%d %H:%M")
                                  if last else ("কখনো পরীক্ষা হয়নি / never checked"
                                                if lang == "bn" else "never checked")),
            "doc": _DOC,
            "testable": bool(meta.get("test")),
        })
    return out


def summary(lang="bn") -> dict:
    """Dashboard roll-up for the owner: counts per state + per category."""
    rows = list_all(lang)
    counts = {"connected": 0, "not_working": 0, "not_connected": 0, "total": len(rows)}
    by_cat = {}
    for r in rows:
        if r["status"] == "working":
            counts["connected"] += 1
        elif r["status"] == "failing":
            counts["not_working"] += 1
        else:
            counts["not_connected"] += 1
        c = by_cat.setdefault(r["category"], {"connected": 0, "total": 0})
        c["total"] += 1
        if r["status"] == "working":
            c["connected"] += 1
    return {"counts": counts, "by_category": by_cat}


# ---------------------------------------------------------------- tests
def test_anthropic(cfg):
    import urllib.request
    import json as _j
    key = cfg.get("api_key", "")
    if not key.startswith("sk-"):
        return (False, "কি ফরম্যাট ভুল / key format looks wrong")
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=_j.dumps({"model": "claude-haiku-4-5", "max_tokens": 1,
                       "messages": [{"role": "user", "content": "hi"}]}).encode(),
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15)
        return (True, "✓ কাজ করছে / working")
    except urllib.error.HTTPError as e:
        if e.code in (400, 429):  # reached API but maybe limited — key is valid
            return (True, "✓ কি বৈধ / key valid")
        return (False, f"HTTP {e.code}")


def test_gemini(cfg):
    import urllib.request
    key = cfg.get("api_key", "")
    url = ("https://generativelanguage.googleapis.com/v1beta/models?key=" + key)
    try:
        urllib.request.urlopen(url, timeout=15)
        return (True, "✓ working")
    except urllib.error.HTTPError as e:
        return (False, f"HTTP {e.code}")


def test_openai(cfg):
    import urllib.request
    key = cfg.get("api_key", "")
    req = urllib.request.Request("https://api.openai.com/v1/models",
                                 headers={"Authorization": f"Bearer {key}"})
    try:
        urllib.request.urlopen(req, timeout=15)
        return (True, "✓ working")
    except urllib.error.HTTPError as e:
        return (False, f"HTTP {e.code}")


def test_google_places(cfg):
    import urllib.request
    import json as _j
    key = cfg.get("api_key", "")
    url = ("https://maps.googleapis.com/maps/api/place/findplacefromtext/json"
           "?input=restaurant&inputtype=textquery&key=" + key)
    try:
        r = urllib.request.urlopen(url, timeout=15)
        body = _j.loads(r.read().decode())
        st = body.get("status")
        if st in ("OK", "ZERO_RESULTS"):
            return (True, "✓ working")
        return (False, st or "error")
    except urllib.error.HTTPError as e:
        return (False, f"HTTP {e.code}")


def test_spotify(cfg):
    import urllib.request
    import urllib.parse
    import base64
    cid = cfg.get("client_id", "")
    sec = cfg.get("client_secret", "")
    auth = base64.b64encode(f"{cid}:{sec}".encode()).decode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
        headers={"Authorization": f"Basic {auth}",
                 "Content-Type": "application/x-www-form-urlencoded"})
    try:
        urllib.request.urlopen(req, timeout=15)
        return (True, "✓ working")
    except urllib.error.HTTPError as e:
        return (False, f"HTTP {e.code}")


def test_admob(cfg):
    """Format check only (AdMob has no server-side 'ping'): App ID looks like
    ca-app-pub-<16 digits>~<digits>, each unit like ca-app-pub-<16>/<digits>.
    Google's public TEST IDs are refused so 'working' always means real IDs."""
    from .logic import ads as _ads
    ok, why = _ads.validate_admob_ids(cfg)
    return ok, why


# ---- ps1-photo ----
def test_replicate(cfg):
    import urllib.request
    tok = cfg.get("api_token", "")
    req = urllib.request.Request("https://api.replicate.com/v1/account",
                                 headers={"Authorization": f"Bearer {tok}"})
    try:
        urllib.request.urlopen(req, timeout=15)
        return (True, "✓ working")
    except urllib.error.HTTPError as e:
        return (False, f"HTTP {e.code}")


# ---- a3-voice ----
def test_picovoice(cfg):
    """Honest check: AccessKey present + the keyword file downloads over https
    and looks like a Porcupine .ppn (non-empty, small). The key itself can only
    be validated on-device by the Porcupine engine."""
    import urllib.request
    key = (cfg.get("access_key") or "").strip()
    urls = [u.strip() for u in (cfg.get("keyword_url") or "").split(",") if u.strip()]
    if not key:
        return (False, "AccessKey missing")
    if not urls or not all(u.startswith("https://") for u in urls):
        return (False, "keyword_url must be https://")
    for url in urls:
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                data = r.read(512 * 1024 + 1)
        except Exception as e:  # noqa: BLE001
            return (False, f"keyword file: {str(e)[:120]}")
        if not data or len(data) > 512 * 1024:
            return (False, "keyword file empty or too large")
    return (True, f"✓ {len(urls)} keyword file(s) reachable — key verified on first phone use")


def test_youtube(cfg):
    """a3-voice: one real search (costs 100 quota units)."""
    from . import views_voice
    key = (cfg.get("api_key") or "").strip()
    if not key:
        return (False, "API key missing")
    try:
        r = views_voice.youtube_search(key, "Bangla song")
    except Exception as e:  # noqa: BLE001
        return (False, str(e)[:200])
    return (True, "✓ working") if r else (False, "no result")


# ---- o1-otp ----
def test_sms(cfg):
    """Honest SMS gateway check (core/sms_gateway.HttpSmsAdapter.check): config
    complete + a real balance call OR one real test SMS. Never 'working' on a
    format check alone."""
    from .sms_gateway import HttpSmsAdapter
    return HttpSmsAdapter(cfg).check()


# ---- pay1 ----
def test_eps(cfg):
    from .payments import eps
    g = eps.EpsGateway()
    g.c = cfg
    return g.test()


def test_play_billing(cfg):
    """Honest: a real OAuth token exchange with the pasted service account."""
    from .payments import play
    import json as _json
    sa = cfg.get("service_account_json")
    try:
        sa = _json.loads(sa) if isinstance(sa, str) else sa
    except ValueError:
        return False, "service account JSON is not valid JSON"
    if not (isinstance(sa, dict) and sa.get("client_email") and sa.get("private_key")):
        return False, "service account JSON needs client_email + private_key"
    c = {"sa": sa, "package_name": (cfg.get("package_name") or "com.assisto.assisto")}
    try:
        play.reset_cache()
        play.access_token(c)
    except play.PlayError as e:
        return False, "Google OAuth: %s %s" % (e.reason, e.detail)
    except Exception as e:  # noqa: BLE001
        return False, "Google OAuth: %s" % type(e).__name__
    return True, "✓ Google Play API টোকেন পাওয়া গেছে / token OK (%s)" % sa["client_email"]
# ---- /pay1 ----
# ---- t9-turnscale ----
def test_turn_overflow(cfg):
    """Mint ONE short-lived (5 min) credential from Cloudflare Calls TURN with
    the saved key (real API call). Passing = the provider handed back a TURN
    entry with a username — only then can overflow switch on."""
    from . import turn_pool
    key_id = (cfg.get("key_id") or "").strip()
    token = (cfg.get("api_token") or "").strip()
    if not (key_id and token):
        return (False, "Turn Token ID and API Token are both needed")
    try:
        ice = turn_pool.cf_generate(key_id, token, 300)
    except Exception as e:  # noqa: BLE001
        return (False, ("provider error: %s" % e)[:200])
    if any("username" in e for e in ice):
        on = turn_pool._truthy(cfg.get("enabled"))
        return (True, "✓ credentials minted" + ("" if on else " — enabled is off, overflow stays OFF"))
    return (False, "no TURN credentials in the provider response")


# ---- p4-world ---- each test makes ONE real provider call via world_service.
def test_web_search(cfg):
    from . import world_service
    return world_service.test_search(cfg)


def test_sports_football(cfg):
    from . import world_service
    return world_service.test_sports("football", cfg)


def test_sports_cricket(cfg):
    from . import world_service
    return world_service.test_sports("cricket", cfg)


def test_jobs_careerjet(cfg):
    from . import world_service
    return world_service.test_careerjet(cfg)
# ---- /p4-world ----
