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
                   _f("app_open_unit", "App-open unit ID", "App-open unit ID", secret=False)],
        "test": "test_admob",
    },
    "play_billing": {
        "name": "Google Play Billing",
        "category": "Monetization",
        "unlocks_bn": "অ্যাপে সাবস্ক্রিপশন/ক্রেডিট কেনা।",
        "unlocks_en": "In-app subscriptions / credit purchase.",
        "guide_bn": ["Play Console → Monetize → Products (subs + credit packs)",
                     "Service account JSON তৈরি → পেস্ট → Save"],
        "guide_en": ["Play Console → Monetize → Products (subs + credit packs)",
                     "Create service-account JSON → paste → Save"],
        "fields": [_f("service_account_json", "Service account JSON", "Service account JSON")],
        "test": None,
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
    "news": {"name": "News", "category": "Media",
             "unlocks_bn": "সকালের ব্রিফিং-এ খবরের শিরোনাম।", "unlocks_en": "Headlines in the morning briefing.",
             "guide_bn": ["newsapi.org (বা অনুরূপ) → API key → পেস্ট → Save (key ছাড়া RSS fallback)"],
             "guide_en": ["newsapi.org (or similar) → API key → paste → Save (RSS fallback if no key)"],
             "fields": [_f("provider", "Provider", "Provider", secret=False), _f("api_key", "API Key", "API Key")],
             "test": None},
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
