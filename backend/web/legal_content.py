"""l1-launch — public Privacy Policy, Terms of Service and Data Deletion pages
for https://lifeassisto.com (Google Play + AdMob listing requirements).

Written from an audit of what the app ACTUALLY does (manifest patch in
.github/workflows/android.yml, core/models.py, the purge crons, the AdMob
bridge, the e2e module). Keep it truthful: when a feature changes, change the
matching line here and in core/legal.py (the in-app summary).

Every string is a (bn, en) pair so the two languages can never drift apart.
Body strings are trusted constants and may carry a little inline HTML (<b>,
<a>). Owner-only facts (legal entity, address, contact email, grievance
officer, governing law) come from environment variables and are escaped; an
unset fact renders as an honest "(to be added)" marker — see PLACEHOLDERS.
"""
import os

from django.conf import settings
from django.utils.html import escape
from django.utils.safestring import mark_safe

LAST_UPDATED = "2026-10-22"

# env var -> what the owner must provide. Listed in the l1-launch report and
# in owner_actions/PLAY_STORE_PACK.md.
PLACEHOLDERS = {
    "LEGAL_ENTITY_NAME": "Legal name of the business that publishes Assisto (as on the Play developer account)",
    "LEGAL_ADDRESS": "Registered postal address",
    "LEGAL_CONTACT_EMAIL": "Privacy / support contact email (also used on the Play listing)",
    "LEGAL_GRIEVANCE_OFFICER": "Name (or role) of the person responsible for privacy requests (DPO / grievance officer)",
    "LEGAL_GOVERNING_LAW": "Governing law + courts for the Terms (e.g. 'the laws of Bangladesh; courts of Dhaka')",
    "LEGAL_HOSTING": "Where the servers are hosted (provider + country/region)",
}

_MISSING = ("(শিগগিরই যোগ করা হবে)", "(to be added)")


# Owner-approved public facts (22 Oct 2026). A server setting / env var with the
# same name still overrides them. The address is pending from the owner.
_OWNER_DEFAULTS = {
    "LEGAL_ENTITY_NAME": "AXON ERP Software",
    "LEGAL_ADDRESS": "[ADDRESS]",
    "LEGAL_CONTACT_EMAIL": "axonadmin001@gmail.com",
    "LEGAL_GRIEVANCE_OFFICER": "Arif (owner) — axonadmin001@gmail.com",
    "LEGAL_GOVERNING_LAW": "the laws of Bangladesh",
    "LEGAL_HOSTING": "Amazon Web Services (AWS), ap-south-1 region (Mumbai, India)",
}


def _fact(key, lang):
    v = (getattr(settings, key, "") or os.getenv(key, "") or
         _OWNER_DEFAULTS.get(key, "") or "").strip()
    if v:
        return escape(v)
    return _MISSING[0] if lang == "bn" else _MISSING[1]


def facts(lang):
    site = getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")
    return {
        "entity": _fact("LEGAL_ENTITY_NAME", lang),
        "address": _fact("LEGAL_ADDRESS", lang),
        "email": _fact("LEGAL_CONTACT_EMAIL", lang),
        "officer": _fact("LEGAL_GRIEVANCE_OFFICER", lang),
        "law": _fact("LEGAL_GOVERNING_LAW", lang),
        "hosting": _fact("LEGAL_HOSTING", lang),
        "site": site,
        "updated": LAST_UPDATED,
    }


def missing_facts():
    """Env keys the owner has not set yet (for tests / the report)."""
    out = []
    for k in PLACEHOLDERS:
        v = (getattr(settings, k, "") or os.getenv(k, "") or
             _OWNER_DEFAULTS.get(k, "")).strip()
        if not v or v.startswith("["):     # "[ADDRESS]" = still pending
            out.append(k)
    return out


# ---------------------------------------------------------------- builders
def P(bn, en):
    return {"t": "p", "bn": bn, "en": en}


def UL(*items):
    return {"t": "ul", "items": list(items)}


def S(sid, h_bn, h_en, *blocks):
    return {"id": sid, "h": (h_bn, h_en), "blocks": list(blocks)}


def PERM_TABLE():
    return {"t": "perms"}


# ---------------------------------------------------------------- permissions
# (android permission(s), name, what it is used for, when it is asked, revoke)
# The order follows the Play "sensitive first" order the reviewer looks for.
_REVOKE_STD = ("Android সেটিংস → অ্যাপ → Assisto → অনুমতি (Permissions) থেকে যেকোনো সময় বন্ধ করুন।",
               "Any time: Android Settings → Apps → Assisto → Permissions.")

PERMISSIONS = [
    {
        "id": "camera",
        "perm": "CAMERA",
        "name": ("ক্যামেরা", "Camera"),
        "why": ("ডকুমেন্ট ভল্টে কাগজের ছবি, ফটো স্টুডিও (পাসপোর্ট/ভিসা ছবি), প্রোফাইল ও স্ট্যাটাস ছবি/ভিডিও, "
                "ভিডিও কল, পুরনো ফোনকে দোকানের ক্যামেরা (Shop Box) বানানো, এবং আপনি চালু করলে চুরি-সুরক্ষার "
                "\"অনুপ্রবেশকারীর ছবি\"।",
                "Photos of papers for the Document Vault, Photo Studio (passport/visa photos), profile and "
                "status photos/videos, video calls, turning an old phone into a shop camera (Shop Box), and — "
                "only if you turn it on — the anti-theft \"intruder photo\"."),
        "when": ("প্রথমবার এসব ফিচার খোলার সময়। লঞ্চের সময় কখনো নয়।",
                 "The first time you open one of these features. Never at app launch."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "microphone",
        "perm": "RECORD_AUDIO",
        "name": ("মাইক্রোফোন", "Microphone"),
        "why": ("ভয়েস দিয়ে লেখা/কমান্ড (Assisto Voice), ভয়েস ও ভিডিও কল, ভিডিওর সাথে শব্দ, হ্যান্ডস-ফ্রি ভয়েস SOS, "
                "এবং ঐচ্ছিক \"Hey Assisto\" ওয়েক-ওয়ার্ড। ওয়েক-ওয়ার্ড শোনা পুরোপুরি ফোনের ভেতরে হয় — সেই অডিও "
                "কোথাও পাঠানো হয় না।",
                "Voice typing and commands (Assisto Voice), voice and video calls, sound for videos you record, "
                "hands-free voice SOS, and the optional \"Hey Assisto\" wake word. Wake-word listening runs "
                "entirely on your phone — that audio is never sent anywhere."),
        "when": ("প্রথমবার মাইক বোতাম, কল বা ভয়েস SOS চালু করার সময়।",
                 "The first time you tap a mic button, place a call or switch on voice SOS."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "location",
        "perm": "ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION",
        "name": ("লোকেশন", "Location"),
        "why": ("SOS-এ আপনার অবস্থান পাঠানো, Safe Journey (আপনি যাদের বেছে নেন তারা আপনার যাত্রা দেখতে পান), "
                "পরিচিত নিরাপদ জায়গা (সংবেদনশীল কাজে বাড়তি সুরক্ষা), এবং কাছাকাছি জায়গা খোঁজা। আমরা \"সবসময়\" "
                "(ব্যাকগ্রাউন্ড) লোকেশন অনুমতি চাই না — অ্যাপ খোলা থাকলে বা চলমান SOS/যাত্রার নোটিফিকেশন দেখা "
                "গেলে তবেই লোকেশন নেওয়া হয়।",
                "Sending your position in an SOS, Safe Journey (the people you choose can follow your trip), "
                "trusted places (extra protection for sensitive actions), and finding places nearby. We do not "
                "ask for \"all the time\" (background) location — location is read only while the app is open "
                "or while a visible SOS/journey notification is running."),
        "when": ("প্রথমবার SOS, Safe Journey বা কাছাকাছি খোঁজা ব্যবহারের সময়।",
                 "The first time you use SOS, Safe Journey or a nearby search."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "contacts",
        "perm": "READ_CONTACTS",
        "name": ("কন্টাক্টস (শুধু পড়া)", "Contacts (read only)"),
        "why": ("আপনার কোন পরিচিতজন Assisto ব্যবহার করেন তা খুঁজে বের করা। নম্বরগুলো আপনার ফোনেই একটি গোপন "
                "\"হ্যাশ\" কোডে রূপান্তর করা হয়; শুধু সেই হ্যাশ আমাদের সার্ভারে যায়, মিলিয়ে দেখা হয় এবং যারা "
                "Assisto ব্যবহারকারী নন তাদের হ্যাশ কোথাও সংরক্ষণ করা হয় না। নাম বা ফোনবুক কখনো আপলোড হয় না। "
                "আমরা কন্টাক্টে কিছু লিখি না।",
                "Finding which of your contacts use Assisto. Numbers are turned into a secret \"hash\" code on "
                "your phone; only those hashes reach our server, are compared, and hashes of people who are not "
                "Assisto users are not stored anywhere. Names and the phonebook itself are never uploaded. We "
                "never write to your contacts."),
        "when": ("Contacts স্ক্রিনে, অ্যাপের নিজস্ব ব্যাখ্যা দেখানোর পরে — আপনি রাজি হলে তবেই।",
                 "On the Contacts screen, after our own explanation screen — only if you agree."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "notifications",
        "perm": "POST_NOTIFICATIONS",
        "name": ("নোটিফিকেশন", "Notifications"),
        "why": ("রিমাইন্ডার, ওষুধের সময়, বার্তা, ইনকামিং কল, পরিবারের সতর্কবার্তা ও SOS জানানো।",
                "Reminders, medicine times, messages, incoming calls, family alerts and SOS."),
        "when": ("অ্যাপে প্রথম লগইনের পর বা প্রথম রিমাইন্ডার সেট করার সময় (Android 13+)।",
                 "After your first sign-in or when you set your first reminder (Android 13+)."),
        "revoke": ("Android সেটিংস → অ্যাপ → Assisto → নোটিফিকেশন।",
                   "Android Settings → Apps → Assisto → Notifications."),
    },
    {
        "id": "fullscreen",
        "perm": "USE_FULL_SCREEN_INTENT",
        "name": ("ফুল-স্ক্রিন নোটিফিকেশন (কল)", "Full-screen notifications (calls)"),
        "why": ("ফোন লক থাকলেও ইনকামিং ভয়েস/ভিডিও কলের স্ক্রিন দেখানো — শুধু বাজতে থাকা কলের জন্য। এর মাধ্যমে "
                "লক স্ক্রিনে আপনার চ্যাট বা ভল্ট কখনো দেখানো হয় না।",
                "Showing the incoming voice/video call screen when the phone is locked — only for a ringing "
                "call. It never shows your chats or vault on the lock screen."),
        "when": ("Android 14+-এ এটি একটি বিশেষ অনুমতি; সেটিংস → নোটিফিকেশন ও কল থেকে আপনি চালু করেন।",
                 "On Android 14+ it is a special permission you turn on from Settings → Notifications & calls."),
        "revoke": ("Android সেটিংস → অ্যাপ → বিশেষ অ্যাপ অ্যাক্সেস → ফুল-স্ক্রিন নোটিফিকেশন → Assisto।",
                   "Android Settings → Apps → Special app access → Full-screen notifications → Assisto."),
    },
    {
        "id": "fgs",
        "perm": "FOREGROUND_SERVICE, FOREGROUND_SERVICE_MICROPHONE, FOREGROUND_SERVICE_LOCATION",
        "name": ("ফোরগ্রাউন্ড সার্ভিস (মাইক্রোফোন, লোকেশন)", "Foreground service (microphone, location)"),
        "why": ("হ্যান্ডস-ফ্রি ভয়েস SOS এবং ঐচ্ছিক \"Hey Assisto\" ওয়েক-ওয়ার্ড স্ক্রিন বন্ধ থাকলেও শোনার জন্য, "
                "এবং SOS-এ লোকেশন পাঠানোর জন্য। চলার সময় সবসময় একটি নোটিফিকেশন দেখা যায়, সেখান থেকেই বন্ধ করা যায়।",
                "Letting hands-free voice SOS and the optional \"Hey Assisto\" wake word listen while the screen "
                "is off, and sending location during an SOS. While it runs a notification is always visible, "
                "with a Stop button."),
        "when": ("শুধু আপনি নিজে ভয়েস SOS বা ওয়েক-ওয়ার্ড চালু করলে। লঞ্চ বা রিস্টার্টে নিজে থেকে চালু হয় না।",
                 "Only when you switch voice SOS or the wake word on yourself. It never starts by itself at "
                 "launch or after a restart."),
        "revoke": ("নোটিফিকেশনের Stop বোতাম, অথবা অ্যাপের সেটিংসে সুইচ বন্ধ করুন।",
                   "The notification's Stop button, or switch it off in the app's settings."),
    },
    {
        "id": "fgs_antitheft",
        "perm": "FOREGROUND_SERVICE_CAMERA (FOREGROUND_SERVICE_LOCATION)",
        "name": ("সার্বক্ষণিক চুরি-সুরক্ষা (লোকেশন, ক্যামেরা)", "Always-on anti-theft (location, camera)"),
        "why": ("আপনার নিজের ফোন হারালে/চুরি হলে শেষ লোকেশন, সিম বদল ও অফলাইন হওয়ার খবর আপনাকে ও আপনার অনুমোদিত "
                "পরিবারকে জানানো। ক্যামেরা শুধু তখনই ব্যবহার হয় যদি আপনি \"অনুপ্রবেশকারীর ছবি\" চালু করেন: কয়েকবার "
                "ভুল স্ক্রিন-আনলক চেষ্টার পর সামনের ক্যামেরায় একটি ছবি, এনক্রিপ্ট করা, শুধু আপনি ও অনুমোদিত পরিবার "
                "দেখতে পারেন। চলার সময় সবসময় একটি নোটিফিকেশন দেখা যায়।",
                "Telling you and the family you approved the last location, a SIM change or the phone going "
                "offline if your own phone is lost or stolen. The camera is used only if you turn on \"intruder "
                "photo\": one front-camera photo after several wrong screen-unlock attempts, encrypted, visible "
                "only to you and your approved family. A notification is always visible while it runs."),
        "when": ("শুধু আপনি সিকিউরিটি পিন দিয়ে সুরক্ষা চালু করলে। লঞ্চ বা রিস্টার্টে নিজে থেকে চালু হয় না।",
                 "Only when you turn protection on with your Security PIN. It never starts by itself at launch "
                 "or after a restart."),
        "revoke": ("অ্যাপে সার্বক্ষণিক সুরক্ষা বন্ধ করুন (সিকিউরিটি পিন), অথবা ক্যামেরার অনুমতি তুলে নিন।",
                   "Turn always-on protection off in the app (Security PIN), or remove the camera permission."),
    },
    {
        "id": "call_phone",
        "perm": "CALL_PHONE",
        "name": ("ফোন কল করা", "Make phone calls"),
        "why": ("আপনি Assisto Voice-কে কাউকে ফোন করতে বললে এবং নিশ্চিত করলে সেই নম্বরে সরাসরি কল দেওয়া। "
                "আপনার নিশ্চিতকরণ ছাড়া বা ব্যাকগ্রাউন্ডে কখনো কল হয় না।",
                "Placing a call when you ask Assisto Voice to call someone and confirm it. A call is never "
                "made without your confirmation or in the background."),
        "when": ("প্রথমবার ভয়েস দিয়ে কল নিশ্চিত করার সময়। না দিলে ফোনের ডায়ালার খুলে নম্বর বসিয়ে দেওয়া হয়।",
                 "The first time you confirm a voice call. If you refuse, the phone's dialer opens with the "
                 "number filled in instead."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "alarm",
        "perm": "SET_ALARM",
        "name": ("অ্যালার্ম সেট করা", "Set alarms"),
        "why": ("আপনি বললে ফোনের ক্লক অ্যাপে অ্যালার্ম বসানো।",
                "Setting an alarm in your clock app when you ask for one."),
        "when": ("এটি সাধারণ অনুমতি — আলাদা করে জিজ্ঞেস করা হয় না।",
                 "A normal permission — no separate prompt."),
        "revoke": ("অ্যাপ আনইনস্টল করলে বা ক্লক অ্যাপ থেকে অ্যালার্ম মুছে।",
                   "Delete the alarm in your clock app, or uninstall Assisto."),
    },
    {
        "id": "bluetooth",
        "perm": "BLUETOOTH_CONNECT (Android 12+); BLUETOOTH, BLUETOOTH_ADMIN (Android 11 ও আগের / and older)",
        "name": ("ব্লুটুথ (গাড়ির OBD)", "Bluetooth (car OBD)"),
        "why": ("আপনার আগে থেকে পেয়ার করা ELM327 OBD-II ডঙ্গলের সাথে যুক্ত হয়ে গাড়ির রিডিং (যেমন ইঞ্জিন কোড) দেখানো। "
                "আমরা আশেপাশের ডিভাইস স্ক্যান করি না, লোকেশনের জন্য ব্লুটুথ ব্যবহার করি না।",
                "Connecting to an ELM327 OBD-II dongle you have already paired, to show your car's readings "
                "(such as engine codes). We never scan for nearby devices and never use Bluetooth for location."),
        "when": ("গাড়ির OBD স্ক্রিন খুলে \"Connect\" চাপলে।",
                 "When you open the car OBD screen and tap Connect."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "health",
        "perm": "health.READ_STEPS, health.READ_HEART_RATE, health.READ_SLEEP, health.READ_ACTIVE_CALORIES_BURNED, ACTIVITY_RECOGNITION",
        "name": ("Health Connect (ধাপ, হার্ট রেট, ঘুম, ক্যালোরি) — শুধু পড়া", "Health Connect (steps, heart rate, sleep, calories) — read only"),
        "why": ("স্মার্টওয়াচ ও ফিটনেস স্ক্রিনে আজকের ও গত ৭ দিনের সারসংক্ষেপ দেখানো। এই ডেটা শুধু আপনার ফোনে "
                "দেখানো হয় — আমাদের সার্ভারে পাঠানো হয় না, বিজ্ঞাপন বা অন্য কোনো কাজে ব্যবহার হয় না, কারও সাথে শেয়ার হয় না। "
                "আমরা Health Connect-এ কিছু লিখি না।",
                "Showing today's and the last 7 days' summary on the Smartwatch & Fitness screen. This data is "
                "only shown on your phone — it is not sent to our servers, not used for ads or anything else, "
                "and not shared with anyone. We never write to Health Connect."),
        "when": ("স্মার্টওয়াচ ও ফিটনেস স্ক্রিন খুলে \"Connect\" চাপলে, Health Connect-এর নিজস্ব অনুমতি স্ক্রিনে।",
                 "When you open Smartwatch & Fitness and tap Connect, on Health Connect's own permission screen."),
        "revoke": ("Health Connect অ্যাপ → অ্যাপ অনুমতি → Assisto।",
                   "Health Connect app → App permissions → Assisto."),
    },
    {
        "id": "media",
        "perm": "READ_MEDIA_IMAGES, READ_MEDIA_VIDEO (READ_EXTERNAL_STORAGE Android 12 ও আগের / and older)",
        "name": ("ছবি ও ভিডিও", "Photos and videos"),
        "why": ("আপনার বেছে নেওয়া ছবি/ভিডিও ভল্ট, চ্যাট, স্ট্যাটাস বা ফটো স্টুডিওতে যোগ করা। আপনি যা বেছে নেন শুধু সেটাই।",
                "Adding the photos/videos you pick to the vault, chats, status or Photo Studio. Only what you pick."),
        "when": ("প্রথমবার গ্যালারি থেকে কিছু বাছাই করার সময়।",
                 "The first time you pick something from your gallery."),
        "revoke": _REVOKE_STD,
    },
    {
        "id": "device_admin",
        "perm": "BIND_DEVICE_ADMIN (Device administrator)",
        "name": ("ডিভাইস অ্যাডমিন (চুরি-সুরক্ষা)", "Device administrator (anti-theft)"),
        "why": ("ফোন হারালে/চুরি হলে দূর থেকে স্ক্রিন লক করা, স্ক্রিন লক বাধ্যতামূলক করা এবং ভুল আনলক চেষ্টা টের পাওয়া। "
                "আমরা ফোনের ডেটা মুছে ফেলার (wipe) ক্ষমতা চাই না। চালু থাকলে Android আগে অ্যাডমিন বন্ধ না করে "
                "অ্যাপ আনইনস্টল করতে দেয় না — যাতে চোর সহজে সুরক্ষা সরাতে না পারে।",
                "If the phone is lost or stolen: lock the screen remotely, require a screen lock and notice "
                "wrong unlock attempts. We do not ask for the power to wipe your phone. While it is on, Android "
                "asks you to switch it off before uninstalling — so a thief can't simply remove the protection."),
        "when": ("শুধু আপনি চুরি-সুরক্ষা সেটআপে \"Enable\" চাপলে, Android-এর নিজস্ব সম্মতি স্ক্রিনে।",
                 "Only when you tap Enable in anti-theft setup, on Android's own consent screen."),
        "revoke": ("Android সেটিংস → নিরাপত্তা → ডিভাইস অ্যাডমিন অ্যাপ → Assisto বন্ধ করুন।",
                   "Android Settings → Security → Device admin apps → turn Assisto off."),
    },
    {
        "id": "assistant",
        "perm": "BIND_VOICE_INTERACTION (default digital assistant)",
        "name": ("ডিফল্ট ডিজিটাল অ্যাসিস্ট্যান্ট (ঐচ্ছিক)", "Default digital assistant (optional)"),
        "why": ("আপনি চাইলে Assisto-কে ফোনের অ্যাসিস্ট্যান্ট বানাতে পারেন — তখন পাওয়ার/হোম বোতাম চেপে ধরলে Assisto Voice খোলে।",
                "If you choose, Assisto can be your phone's assistant — long-pressing power/home then opens Assisto Voice."),
        "when": ("শুধু আপনি Android-এর \"Default apps\" সেটিংসে Assisto বেছে নিলে।",
                 "Only if you pick Assisto in Android's Default apps settings."),
        "revoke": ("Android সেটিংস → অ্যাপ → ডিফল্ট অ্যাপ → ডিজিটাল অ্যাসিস্ট্যান্ট।",
                   "Android Settings → Apps → Default apps → Digital assistant."),
    },
    {
        "id": "install",
        "perm": "REQUEST_INSTALL_PACKAGES",
        "name": ("অ্যাপ আপডেট ইনস্টল (শুধু ওয়েবসাইট সংস্করণ)", "Install updates (website version only)"),
        "why": ("lifeassisto.com থেকে সরাসরি নামানো সংস্করণ নিজের নতুন আপডেট ইনস্টল করতে বলতে পারে — সবসময় আপনার সম্মতিতে। "
                "Google Play সংস্করণ এই অনুমতি ব্যবহার করে না; সেটি শুধু Google Play থেকেই আপডেট হয়।",
                "The version downloaded directly from lifeassisto.com can offer to install its own updates — always "
                "with your OK. The Google Play version does not use this permission; it updates only through Google Play."),
        "when": ("আপডেট স্ক্রিনে \"Install\" চাপলে Android জিজ্ঞেস করে।",
                 "Android asks when you tap Install on the update screen."),
        "revoke": ("Android সেটিংস → অ্যাপ → বিশেষ অ্যাপ অ্যাক্সেস → অজানা অ্যাপ ইনস্টল → Assisto।",
                   "Android Settings → Apps → Special app access → Install unknown apps → Assisto."),
    },
    {
        "id": "normal",
        "perm": "INTERNET, ACCESS_NETWORK_STATE, CHANGE_NETWORK_STATE, MODIFY_AUDIO_SETTINGS, VIBRATE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED",
        "name": ("সাধারণ অনুমতি", "Normal permissions"),
        "why": ("সার্ভারের সাথে যোগাযোগ, কলের সংযোগ ও স্পিকার/ইয়ারপিস বদল, চুরি-অ্যালার্মের কম্পন, রিমাইন্ডার বাজার সময় ফোন "
                "জাগানো, এবং ফোন রিস্টার্টের পরে আপনার রিমাইন্ডারগুলো আবার সেট করা।",
                "Talking to our server, keeping calls connected and switching speaker/earpiece, vibration for the "
                "anti-theft alarm, waking the phone when a reminder is due, and re-setting your reminders after "
                "the phone restarts."),
        "when": ("Android এগুলোর জন্য আলাদা করে জিজ্ঞেস করে না।",
                 "Android does not prompt for these."),
        "revoke": ("অ্যাপ আনইনস্টল করলে।", "Uninstall the app."),
    },
]


# ---------------------------------------------------------------- privacy
PRIVACY = [
    S("summary", "সংক্ষেপে", "In short",
      UL(("আমরা আপনার ডেটা <b>বিক্রি করি না</b>।", "We <b>do not sell</b> your data."),
         ("আপনার ব্যক্তিগত ও গ্রুপ চ্যাটের লেখা বার্তা আপনার ফোনেই এনক্রিপ্ট হয় (end-to-end); আমাদের সার্ভার সেগুলো পড়তে পারে না।",
          "Text messages in your personal and group chats are encrypted on your phone (end-to-end); our server cannot read them."),
         ("Health Connect-এর স্বাস্থ্য তথ্য ফোনেই থাকে, সার্ভারে যায় না। কন্টাক্ট মেলাতে শুধু হ্যাশ কোড যায়।",
          "Health Connect data stays on your phone. Contact matching sends only hash codes."),
         ("বিজ্ঞাপন (চালু হলে) শুধু ফ্রি প্ল্যানে, শুধু নন-পার্সোনালাইজড, এবং কখনো SOS, নিরাপত্তা, পেমেন্ট, লগইন বা কল স্ক্রিনে নয়।",
          "Ads (when switched on) appear only on the Free plan, are non-personalised only, and never on SOS, safety, payment, sign-in or call screens."),
         ("অ্যাপ থেকে (সেটিংস → আমার অ্যাকাউন্ট মুছে ফেলুন) বা <a href=\"/delete-account\">ওয়েব ফর্ম</a> থেকে অ্যাকাউন্ট ও সব ডেটা মুছতে পারেন।",
          "You can delete your account and all data in the app (Settings → Delete my account) or with the <a href=\"/delete-account?lang=en\">web form</a>."))),
    S("who", "আমরা কারা", "Who we are",
      P("Assisto (Android অ্যাপ <code>com.assisto.assisto</code> এবং ওয়েবসাইট {site}) পরিচালনা করে {entity}, ঠিকানা: {address}। "
        "এই নীতিতে \"আমরা\" মানে তারাই। গোপনীয়তা বিষয়ক অনুরোধের দায়িত্বে: {officer}।",
        "Assisto (the Android app <code>com.assisto.assisto</code> and the website {site}) is operated by {entity}, "
        "address: {address}. \"We\" in this policy means them. Person responsible for privacy requests: {officer}.")),
    S("collect", "আমরা কী তথ্য রাখি", "What we collect and store",
      P("আপনার অ্যাকাউন্ট চালাতে ও আপনার চাওয়া ফিচার দিতে আমাদের সার্ভারে নিচের তথ্য রাখা হয়:",
        "To run your account and the features you ask for, our server stores:"),
      UL(("<b>অ্যাকাউন্ট:</b> নাম, মোবাইল নম্বর ও/অথবা ইমেইল, পাসওয়ার্ড (শুধু এনক্রিপ্টেড হ্যাশ), ভাষা, প্ল্যান ও ক্রেডিট, ঐচ্ছিক প্রোফাইল ছবি, রেফারেল কোড।",
          "<b>Account:</b> name, mobile number and/or email, password (only as an encrypted hash), language, plan and credits, optional profile photo, referral code."),
         ("<b>আপনি যা যোগ করেন:</b> রিমাইন্ডার, নোট, কাজের তালিকা, মেমরি, জন্মদিন, খরচ-আয়ের হিসাব, বাজেট, ধার, সঞ্চয়, সাবস্ক্রিপশন, ডকুমেন্ট ভল্টের ফাইল ও তথ্য (যেমন পাসপোর্টের মেয়াদ), পরিবারের সদস্য, ইমার্জেন্সি কার্ড।",
          "<b>What you add:</b> reminders, notes, to-dos, memories, birthdays, income/expense records, budgets, loans, savings, subscriptions, Document Vault files and details (e.g. passport expiry), family members, emergency card."),
         ("<b>স্বাস্থ্য তথ্য যা আপনি নিজে লেখেন:</b> ডাক্তার, প্রেসক্রিপশন, ওষুধ ও ওষুধ খাওয়ার রেকর্ড। (Health Connect-এর ডেটা নয় — সেটি ফোনেই থাকে।)",
          "<b>Health details you type in yourself:</b> doctors, prescriptions, medicines and dose logs. (Not Health Connect data — that stays on the phone.)"),
         ("<b>বার্তা ও কল:</b> ব্যক্তিগত ও গ্রুপ চ্যাটের লেখা বার্তা এনক্রিপ্টেড আকারে (আমরা পড়তে পারি না) এবং ডেলিভারির জন্য প্রয়োজনীয় তথ্য (কে, কাকে, কখন)। চ্যানেলের পোস্ট, কমিউনিটি ও ব্যবসায়িক ইনবক্স end-to-end এনক্রিপ্টেড নয়। পাঠানো ছবি/ফাইল প্রাপক নামাতে পারার জন্য সার্ভারে থাকে। কলের রেকর্ড (কে, কখন, কতক্ষণ) — কলের অডিও/ভিডিও আমরা রেকর্ড করি না।",
          "<b>Messages and calls:</b> text messages of personal and group chats in encrypted form (we cannot read them) plus what is needed to deliver them (who, to whom, when). Channel posts, communities and the business inbox are not end-to-end encrypted. Photos/files you send are kept on the server so recipients can download them. Call records (who, when, how long) — we never record call audio or video."),
         ("<b>নিরাপত্তা ফিচার:</b> SOS ও Safe Journey-র লোকেশন, আপনার বেছে নেওয়া পরিচিত নিরাপদ জায়গা, চেক-ইন, বিশ্বস্ত পরিচিতজন।",
          "<b>Safety features:</b> SOS and Safe Journey locations, the trusted places you choose, check-ins, your trusted contacts."),
         ("<b>চুরি-সুরক্ষা (আপনি চালু করলে):</b> সুরক্ষিত ফোনের তথ্য (মডেল, IMEI যা আপনি দেন), নিয়মিত \"আমি ঠিক আছি\" সংকেত, এবং ফোন হারানো অবস্থায় ধরা ঘটনা — যেমন SIM বদল, ভুল আনলক, লোকেশন এবং অনুপ্রবেশকারীর ছবি। এগুলো শুধু আপনি দেখতে পান।",
          "<b>Anti-theft (if you turn it on):</b> details of the protected phone (model, the IMEI you enter), regular \"I'm OK\" heartbeats, and events captured while the phone is lost — such as SIM change, wrong unlocks, location and an intruder photo. Only you can see them."),
         ("<b>গাড়ি ট্র্যাকিং (আপনি ট্র্যাকার যোগ করলে):</b> আপনার GPS ট্র্যাকারের অবস্থান, গতি ও ইগনিশন অবস্থা।",
          "<b>Vehicle tracking (if you add a tracker):</b> your GPS tracker's positions, speed and ignition state."),
         ("<b>ব্যবসা মোড ও Shop Box (আপনি ব্যবহার করলে):</b> পণ্য, গ্রাহক, বিক্রি, খাতা, খরচ, কুরিয়ার তথ্য; দোকানের ক্যামেরার ঘটনার স্ন্যাপশট (লাইভ ভিডিও রেকর্ড হয় না)।",
          "<b>Business mode and Shop Box (if you use them):</b> products, customers, sales, ledger (khata), expenses, courier details; snapshots of shop-camera events (live video is not recorded)."),
         ("<b>AI ও ফটো স্টুডিও:</b> AI চ্যাটে আপনি যা লেখেন, AI দিয়ে বিশ্লেষণ করতে দেওয়া ছবি/ডকুমেন্ট।",
          "<b>AI and Photo Studio:</b> what you write to the AI chat, and photos/documents you ask the AI to analyse."),
         ("<b>সাপোর্ট:</b> আপনার পাঠানো সাপোর্ট বার্তা ও ঐচ্ছিক স্ক্রিনশট।",
          "<b>Support:</b> support messages you send and an optional screenshot."),
         ("<b>ডিভাইস ও প্রযুক্তিগত তথ্য:</b> পুশ নোটিফিকেশন টোকেন, অ্যাপ ভার্সন, প্ল্যাটফর্ম; নিরাপত্তার জন্য সার্ভার লগে IP ঠিকানা ও সময়; সংবেদনশীল কাজের অডিট লগ; অ্যাপ ক্র্যাশ রিপোর্ট (প্রযুক্তিগত ত্রুটি তথ্য)।",
          "<b>Device and technical data:</b> push-notification token, app version, platform; IP address and time in server logs for security; an audit log of sensitive actions; app crash reports (technical error details)."),
         ("<b>পরিসংখ্যান (শুধু আপনার সম্মতিতে):</b> কোন ফিচার ব্যবহার হলো তার বেনামি গণনা — একটি এলোমেলো কোড দিয়ে, নাম/ফোন/ইমেইল ছাড়া। সেটিংস থেকে বন্ধ করা যায়।",
          "<b>Analytics (only with your consent):</b> anonymous counts of which features are used — keyed by a random code, with no name/phone/email. You can turn it off in Settings."))),
    S("device_only", "যা আপনার ফোনেই থাকে", "What stays on your phone",
      UL(("Health Connect-এর ধাপ, হার্ট রেট, ঘুম ও ক্যালোরি — শুধু ফোনে দেখানো হয়।",
          "Health Connect steps, heart rate, sleep and calories — only shown on the phone."),
         ("আপনার ফোনবুক — শুধু নম্বরের হ্যাশ মেলানোর জন্য যায়, নাম কখনো নয়।",
          "Your phonebook — only number hashes are sent for matching, never names."),
         ("\"Hey Assisto\" ওয়েক-ওয়ার্ড শোনার অডিও।", "The audio the \"Hey Assisto\" wake word listens to."),
         ("চ্যাট এনক্রিপশনের চাবি — এগুলো কখনো ফোন ছাড়ে না।", "Your chat encryption keys — they never leave the phone."),
         ("ভয়েস টাইপিং ফোনের নিজস্ব স্পিচ সার্ভিস (যেমন Google) দিয়ে হয়, সেই সার্ভিসের নিজস্ব নীতিমালায়।",
          "Voice typing uses your phone's own speech service (for example Google's), under that service's own terms."))),
    S("permissions", "অ্যাপের অনুমতিগুলো — কী, কেন, কখন, কীভাবে বন্ধ করবেন", "App permissions — what, why, when, how to turn off",
      P("অ্যাপ চালু হওয়ার সময় কোনো অনুমতি চাওয়া হয় না। নোটিফিকেশনের অনুমতি একবার চাওয়া হয় আপনি লগইন করার পরে; বাকি প্রতিটি অনুমতি চাওয়া হয় যে ফিচারের দরকার সেটি প্রথমবার ব্যবহারের সময়। কোনো অনুমতি না দিলেও বাকি অ্যাপ চলবে; শুধু সেই ফিচারটি কাজ করবে না।",
        "No permission is requested while the app starts. Notifications are asked once, after you sign in; every other permission is asked the first time you use the feature that needs it. If you say no, the rest of the app keeps working; only that feature won't."),
      PERM_TABLE()),
    S("use", "তথ্য কীভাবে ব্যবহার করি", "How we use information",
      UL(("আপনার চাওয়া ফিচার চালাতে: রিমাইন্ডার পাঠানো, হিসাব দেখানো, বার্তা পৌঁছানো, SOS সতর্কবার্তা পাঠানো ইত্যাদি।",
          "To run the features you ask for: sending reminders, showing your records, delivering messages, sending SOS alerts and so on."),
         ("লগইন যাচাই ও অ্যাকাউন্ট সুরক্ষা: OTP, সন্দেহজনক কাজ শনাক্ত, চুরি-সুরক্ষার বিলম্ব।",
          "Sign-in checks and account security: OTPs, spotting suspicious actions, anti-theft delays."),
         ("প্ল্যান, ক্রেডিট ও খরচের হিসাব রাখা।", "Keeping track of plans, credits and usage costs."),
         ("ত্রুটি ঠিক করা ও অ্যাপ উন্নত করা (সম্মতি থাকলে বেনামি পরিসংখ্যান দিয়ে)।",
          "Fixing errors and improving the app (with anonymous analytics, if you consent)."),
         ("আইন মেনে চলা ও অপব্যবহার ঠেকানো।", "Meeting legal obligations and preventing abuse."),
         ("আমরা আপনার ব্যক্তিগত তথ্য দিয়ে বিজ্ঞাপনের প্রোফাইল বানাই না।", "We do not build advertising profiles from your personal data."))),
    S("ai", "AI ফিচার", "AI features",
      P("আপনি AI ফিচার (AI চ্যাট, ডকুমেন্ট/বিল পড়া, CV/স্ক্যাম বিশ্লেষণ, ফটো স্টুডিওর AI এডিট ইত্যাদি) ব্যবহার করলে শুধু সেই কাজের জন্য দরকারি লেখা বা ছবি আমাদের সার্ভার থেকে একটি AI প্রদানকারীর কাছে পাঠানো হয় এবং উত্তর ফেরত আসে। "
        "প্রদানকারী হতে পারে Anthropic (Claude), OpenAI, Google (Gemini) বা ছবির জন্য Replicate — যেটি আমরা সেই সময় চালু রেখেছি। তারা তাদের API শর্ত অনুযায়ী তথ্য প্রক্রিয়া করে। "
        "আপনার end-to-end এনক্রিপ্টেড বার্তা AI-তে কখনো যায় না। AI ভুল করতে পারে — গুরুত্বপূর্ণ সিদ্ধান্তের আগে যাচাই করুন।",
        "When you use an AI feature (AI chat, reading a document or bill, CV/scam analysis, Photo Studio AI edits and so on), only the text or image needed for that task is sent from our server to an AI provider, and the answer comes back. "
        "The provider may be Anthropic (Claude), OpenAI, Google (Gemini) or, for images, Replicate — whichever we have switched on at the time. They process it under their API terms. "
        "Your end-to-end encrypted messages are never sent to AI. AI can be wrong — check before important decisions.")),
    S("ads", "বিজ্ঞাপন (Google AdMob)", "Advertising (Google AdMob)",
      P("ফ্রি প্ল্যানে আমরা Google AdMob-এর মাধ্যমে বিজ্ঞাপন দেখাতে পারি (এই ফিচার মালিক চালু করলে)। আমরা শুধু <b>নন-পার্সোনালাইজড</b> বিজ্ঞাপন চাই — অর্থাৎ আপনার আগ্রহ বা ইতিহাস দেখে বিজ্ঞাপন বাছাই করা হয় না। "
        "তবুও বিজ্ঞাপন দেখাতে, সংখ্যা সীমিত রাখতে, প্রতারণা ঠেকাতে ও সমষ্টিগত রিপোর্টের জন্য Google-এর SDK কিছু তথ্য সংগ্রহ করে: ডিভাইসের বিজ্ঞাপন আইডি (Advertising ID), IP ঠিকানা (আনুমানিক এলাকা), ডিভাইস ও অ্যাপের তথ্য এবং বিজ্ঞাপনে ট্যাপ/দেখার তথ্য। "
        "বিস্তারিত: <a href=\"https://policies.google.com/technologies/ads\" rel=\"noopener\">Google কীভাবে বিজ্ঞাপনে তথ্য ব্যবহার করে</a>।",
        "On the Free plan we may show ads through Google AdMob (once the owner switches this on). We request <b>non-personalised</b> ads only — ads are not chosen from your interests or history. "
        "Even so, to show ads, limit how often they appear, prevent fraud and produce aggregate reports, Google's SDK collects some data: the device Advertising ID, IP address (approximate area), device and app information, and ad taps/views. "
        "Details: <a href=\"https://policies.google.com/technologies/ads\" rel=\"noopener\">how Google uses information from ads</a>."),
      UL(("বিজ্ঞাপন কখনো SOS, নিরাপত্তা, যাত্রা, চুরি-সুরক্ষা, পেমেন্ট/প্ল্যান, লগইন/OTP বা কলের স্ক্রিনে দেখানো হয় না।",
          "Ads are never shown on SOS, safety, journey, anti-theft, payment/plan, sign-in/OTP or call screens."),
         ("পেইড প্ল্যানে অ্যাপ খোলার বিজ্ঞাপন নেই। \"বিজ্ঞাপন দেখে ক্রেডিট\" সবসময় ঐচ্ছিক — আপনি নিজে চাপলে তবেই।",
          "Paid plans get no app-open ads. \"Watch an ad for credits\" is always optional — only when you tap it."),
         ("Discover-এ \"স্পনসরড\" কার্ড সব প্ল্যানে দেখা যেতে পারে এবং সবসময় \"স্পনসরড\" লেখা থাকে।",
          "\"Sponsored\" cards in Discover can appear on every plan and are always labelled \"Sponsored\"."),
         ("বিজ্ঞাপন আইডি রিসেট বা মুছতে: Android সেটিংস → গোপনীয়তা → বিজ্ঞাপন (Ads)।",
          "To reset or delete your Advertising ID: Android Settings → Privacy → Ads."),
         ("আমরা কখনো পার্সোনালাইজড বিজ্ঞাপন চালু করলে আগে আপনার সম্মতি চাইব।",
          "If we ever switch to personalised ads, we will ask for your consent first."))),
    S("sharing", "কার সাথে তথ্য শেয়ার হয়", "Who we share information with",
      P("আমরা কাউকে আপনার তথ্য বিক্রি করি না, ভাড়াও দিই না। তথ্য শুধু এই ক্ষেত্রে যায়:",
        "We never sell or rent your information. It only goes to:"),
      UL(("<b>আপনি যাদের বেছে নেন:</b> আপনার সার্কেল/পরিবার, Safe Journey-র পর্যবেক্ষক, SOS-এর বিশ্বস্ত পরিচিতজন, যাদের বার্তা পাঠান।",
          "<b>People you choose:</b> your circle/family, Safe Journey watchers, SOS trusted contacts, the people you message."),
         ("<b>Google Firebase Cloud Messaging:</b> পুশ নোটিফিকেশন পৌঁছাতে (ডিভাইস টোকেন ও নোটিফিকেশনের লেখা)।",
          "<b>Google Firebase Cloud Messaging:</b> to deliver push notifications (device token and notification text)."),
         ("<b>Google AdMob:</b> ফ্রি প্ল্যানের বিজ্ঞাপন, উপরের অংশ দেখুন।", "<b>Google AdMob:</b> Free-plan ads, see above."),
         ("<b>AI প্রদানকারী</b> (Anthropic, OpenAI, Google Gemini, Replicate): শুধু আপনি AI ফিচার ব্যবহার করলে।",
          "<b>AI providers</b> (Anthropic, OpenAI, Google Gemini, Replicate): only when you use an AI feature."),
         ("<b>SMS গেটওয়ে</b> (বাংলাদেশি SMS প্রদানকারী): OTP ও SMS সতর্কবার্তা পাঠাতে — আপনার নম্বর ও বার্তার লেখা।",
          "<b>SMS gateway</b> (a Bangladeshi SMS provider): to send OTPs and SMS alerts — your number and the message text."),
         ("<b>Picovoice:</b> \"Hey Assisto\" ইঞ্জিন চালু করতে লাইসেন্স কী ও কীওয়ার্ড ফাইল নামানো হয়; আপনার অডিও যায় না।",
          "<b>Picovoice:</b> a licence key and keyword file are downloaded to run the \"Hey Assisto\" engine; your audio is not sent."),
         ("<b>কল:</b> ভয়েস/ভিডিও কল সরাসরি দুই ফোনের মধ্যে (WebRTC) চলে; সম্ভব না হলে আমাদের নিজস্ব রিলে (TURN) সার্ভার দিয়ে — এনক্রিপ্টেড, রেকর্ড ছাড়া।",
          "<b>Calls:</b> voice/video calls run directly between the two phones (WebRTC); when that isn't possible, through our own relay (TURN) server — encrypted, never recorded."),
         ("<b>আপনি নিজে যুক্ত করেন এমন সার্ভিস:</b> যেমন WhatsApp Business/Facebook/Instagram, Telegram, কুরিয়ার, পেমেন্ট প্রদানকারী — শুধু আপনি সংযোগ দিলে, সেই কাজের জন্য।",
          "<b>Services you connect yourself:</b> e.g. WhatsApp Business/Facebook/Instagram, Telegram, couriers, payment providers — only if you connect them, for that task."),
         ("<b>হোস্টিং:</b> আমাদের সার্ভার — {hosting}।", "<b>Hosting:</b> our servers — {hosting}."),
         ("<b>আইনগত কারণে:</b> বৈধ আইনি অনুরোধ, অথবা কারও জীবন বা নিরাপত্তা রক্ষায় প্রয়োজন হলে।",
          "<b>Legal reasons:</b> a valid legal request, or when needed to protect someone's life or safety."))),
    S("retention", "কতদিন রাখা হয়", "How long we keep it",
      UL(("অ্যাকাউন্ট ও আপনার যোগ করা তথ্য: যতদিন অ্যাকাউন্ট আছে। মুছতে চাইলে ৭ দিনের অপেক্ষার পর স্থায়ীভাবে মুছে যায় (<a href=\"/delete-account\">বিস্তারিত</a>)।",
          "Account and what you add: as long as the account exists. When you ask to delete, it is permanently erased after a 7-day waiting period (<a href=\"/delete-account?lang=en\">details</a>)."),
         ("ডিসঅ্যাপিয়ারিং মেসেজ: আপনার বেছে নেওয়া সময় পার হলে সার্ভার থেকে মুছে যায় (প্রতি ১৫ মিনিটে পরিষ্কার হয়)। গ্রুপ এক্সপোর্ট ফাইল: ২ ঘণ্টা।",
          "Disappearing messages: deleted from the server once the timer you chose passes (cleaned every 15 minutes). Group export files: 2 hours."),
         ("ওয়েবসাইটের পাসপোর্ট-ছবি টুল: আসল ছবি রাখা হয় না; তৈরি ছবি সর্বোচ্চ ১ ঘণ্টা, তারপর নিজে থেকে মুছে যায়।",
          "Website passport-photo tool: the original upload is not kept; the finished photo is kept at most 1 hour, then deleted automatically."),
         ("Safe Journey-র রুট পয়েন্ট: যাত্রার গোপনীয়তা-সময় (ডিফল্ট: প্রত্যাশিত পৌঁছানোর ২৪ ঘণ্টা পর) শেষ হলে মুছে যায়।",
          "Safe Journey route points: deleted when the journey's privacy window ends (default: 24 hours after the expected arrival)."),
         ("গাড়ির অবস্থানের ইতিহাস: ডিফল্ট ৩০ দিন। দোকানের ক্যামেরার স্ন্যাপশট: দোকানের সেটিং অনুযায়ী।",
          "Vehicle position history: 30 days by default. Shop-camera snapshots: per the shop's setting."),
         ("OTP কোড: কয়েক মিনিটে মেয়াদ শেষ।", "OTP codes: expire within minutes."),
         ("এনক্রিপ্টেড ব্যাকআপ: মুছে ফেলা তথ্য সর্বোচ্চ প্রায় ১৪ দিন পর্যন্ত এনক্রিপ্টেড ব্যাকআপে থেকে যেতে পারে, তারপর ব্যাকআপ ঘুরে নতুন হলে তা চলে যায়।",
          "Encrypted backups: deleted data can remain in encrypted backups for up to about 14 days, until those backups rotate out."))),
    S("security", "নিরাপত্তা", "Security",
      UL(("অ্যাপ ও সার্ভারের মধ্যে সব যোগাযোগ HTTPS (TLS) দিয়ে এনক্রিপ্টেড।", "All traffic between the app and our server is encrypted with HTTPS (TLS)."),
         ("ব্যক্তিগত ও গ্রুপ চ্যাটের লেখা বার্তা end-to-end এনক্রিপ্টেড; চাবি আপনার ফোনেই থাকে।", "Personal and group chat text messages are end-to-end encrypted; keys stay on your phone."),
         ("পাসওয়ার্ড শুধু হ্যাশ হিসেবে রাখা হয়। সংযুক্ত সার্ভিসের চাবি সার্ভারে এনক্রিপ্ট করে রাখা হয়। ব্যাকআপ AES-256 দিয়ে এনক্রিপ্টেড।",
          "Passwords are stored only as hashes. Keys for connected services are stored encrypted on the server. Backups are AES-256 encrypted."),
         ("ভল্টের ফাইল ও চুরি-সুরক্ষার ছবি শুধু লগইন করা মালিককে দেখানো হয়, কখনো পাবলিক লিংকে নয়।", "Vault files and anti-theft photos are served only to the signed-in owner, never through a public link."),
         ("অ্যাকাউন্ট মোছার মতো সংবেদনশীল কাজে পাসওয়ার্ড, OTP ও সিকিউরিটি PIN লাগে এবং বিলম্ব থাকে।", "Sensitive actions such as deleting the account need your password, OTP and Security PIN, and are delayed."),
         ("কোনো ব্যবস্থাই ১০০% নিরাপদ নয়; কোনো সমস্যা হলে আমরা আইন অনুযায়ী আপনাকে জানাব।", "No system is 100% secure; if something goes wrong we will tell you as the law requires."))),
    S("rights", "আপনার অধিকার ও নিয়ন্ত্রণ", "Your rights and choices",
      UL(("দেখা ও সংশোধন: অ্যাপের ভেতরে আপনার সব তথ্য দেখতে ও বদলাতে পারেন।", "See and correct: you can view and edit your information inside the app."),
         ("এক্সপোর্ট: সেটিংস থেকে আপনার ডেটার কপি নিতে পারেন।", "Export: get a copy of your data from Settings."),
         ("মুছে ফেলা: অ্যাকাউন্ট ও সব ডেটা — <a href=\"/delete-account\">কীভাবে</a>।", "Delete: your account and all data — <a href=\"/delete-account?lang=en\">how</a>."),
         ("অনুমতি ও পরিসংখ্যান: যেকোনো অনুমতি ও বেনামি পরিসংখ্যান যেকোনো সময় বন্ধ করতে পারেন।", "Permissions and analytics: turn any permission or anonymous analytics off at any time."),
         ("প্রশ্ন বা অভিযোগ: নিচের যোগাযোগে লিখুন; আমরা ৩০ দিনের মধ্যে উত্তর দিতে চেষ্টা করি।", "Questions or complaints: write to the contact below; we aim to reply within 30 days."))),
    S("children", "শিশুদের গোপনীয়তা", "Children's privacy",
      P("Assisto ১৮ বছর বা তার বেশি বয়সীদের জন্য এবং শিশুদের লক্ষ্য করে তৈরি নয়। আমরা জেনেশুনে ১৩ বছরের কম (বা আপনার দেশের আইনে নির্ধারিত বয়সের কম) কারও তথ্য সংগ্রহ করি না। "
        "পরিবারের সদস্য হিসেবে শিশুর নাম বা জন্মদিন যোগ করলে সেটি একজন প্রাপ্তবয়স্ক অভিভাবক যোগ করেন এবং শুধু তাঁর অ্যাকাউন্টে থাকে। কোনো শিশুর তথ্য ভুলবশত আমাদের কাছে আছে মনে হলে জানান — আমরা মুছে দেব।",
        "Assisto is meant for people aged 18 or over and is not directed at children. We do not knowingly collect data from anyone under 13 (or the minimum age in your country). "
        "If an adult guardian adds a child's name or birthday as a family member, it stays only in that adult's account. If you think a child's data has reached us by mistake, tell us and we will delete it.")),
    S("changes", "এই নীতির পরিবর্তন", "Changes to this policy",
      P("নীতি বদলালে এই পাতায় তারিখসহ জানানো হবে; বড় পরিবর্তন হলে অ্যাপেও জানাব।",
        "If this policy changes we will update this page with a new date; for significant changes we will also tell you in the app.")),
    S("contact", "যোগাযোগ", "Contact",
      UL(("অ্যাপে: সেটিংস → সাহায্য / সমস্যা রিপোর্ট।", "In the app: Settings → Help / report a problem."),
         ("ইমেইল: {email}", "Email: {email}"),
         ("ঠিকানা: {entity}, {address}", "Post: {entity}, {address}"),
         ("অ্যাকাউন্ট মোছার অনুরোধ: <a href=\"/delete-account\">lifeassisto.com/delete-account</a>", "Account deletion requests: <a href=\"/delete-account?lang=en\">lifeassisto.com/delete-account</a>"))),
]


# ---------------------------------------------------------------- terms
TERMS = [
    S("accept", "শর্তে সম্মতি", "Agreeing to these terms",
      P("Assisto অ্যাপ বা {site} ব্যবহার করে আপনি এই শর্তাবলী ও আমাদের <a href=\"/privacy\">গোপনীয়তা নীতি</a> মেনে নিচ্ছেন। পরিষেবাটি দেয় {entity}।",
        "By using the Assisto app or {site} you agree to these terms and our <a href=\"/privacy?lang=en\">Privacy Policy</a>. The service is provided by {entity}.")),
    S("eligibility", "কারা ব্যবহার করতে পারবেন", "Who can use Assisto",
      P("আপনার বয়স কমপক্ষে ১৮ বছর হতে হবে। অ্যাকাউন্টের তথ্য সঠিক রাখা এবং পাসওয়ার্ড, OTP ও সিকিউরিটি PIN গোপন রাখা আপনার দায়িত্ব।",
        "You must be at least 18. You are responsible for keeping your account details accurate and your password, OTPs and Security PIN secret.")),
    S("service", "পরিষেবা কী, কী নয়", "What the service is — and is not",
      UL(("Assisto একটি ব্যক্তিগত সহকারী: রিমাইন্ডার, হিসাব, ভল্ট, পরিবার, বার্তা, নিরাপত্তা ও ব্যবসার টুল।",
          "Assisto is a personal assistant: reminders, records, vault, family, messaging, safety and business tools."),
         ("<b>টাকা:</b> Assisto কখনো আপনার টাকা রাখে না, পাঠায় না বা পেমেন্ট প্রক্রিয়া করে না — এটি শুধু আপনার নিজের হিসাবের খাতা।",
          "<b>Money:</b> Assisto never holds, transfers or processes your money — it is only a ledger for your own records."),
         ("<b>স্বাস্থ্য:</b> এটি চিকিৎসা পরামর্শ নয়; ওষুধ বা চিকিৎসার সিদ্ধান্তে ডাক্তারের পরামর্শ নিন।",
          "<b>Health:</b> this is not medical advice; ask a doctor about medicines or treatment."),
         ("<b>আইন:</b> আইনি তথ্য শুধু সচেতনতার জন্য, আইনি পরামর্শ নয়।", "<b>Law:</b> legal information is for awareness only, not legal advice."),
         ("<b>জরুরি অবস্থা:</b> SOS, Safe Journey ও চুরি-সুরক্ষা সহায়ক টুল — ইন্টারনেট, ব্যাটারি, ফোনের সেটিং বা নেটওয়ার্কের কারণে ব্যর্থ হতে পারে। এগুলো পুলিশ, অ্যাম্বুলেন্স বা ফায়ার সার্ভিসের বিকল্প নয় — বাংলাদেশে জরুরি প্রয়োজনে ৯৯৯-এ কল করুন।",
          "<b>Emergencies:</b> SOS, Safe Journey and anti-theft are helper tools — they can fail because of internet, battery, phone settings or network. They do not replace the police, ambulance or fire service — in Bangladesh call 999 in an emergency."),
         ("<b>AI:</b> AI-এর উত্তর ভুল হতে পারে; গুরুত্বপূর্ণ বিষয়ে যাচাই করুন।", "<b>AI:</b> AI answers can be wrong; check anything important."))),
    S("acceptable", "গ্রহণযোগ্য ব্যবহার", "Acceptable use",
      P("আপনি যা করবেন না:", "You must not:"),
      UL(("বেআইনি কাজ, প্রতারণা, স্প্যাম, হয়রানি, ঘৃণা বা হুমকি।", "do anything unlawful, or scam, spam, harass, threaten or spread hate;"),
         ("কারও অনুমতি ছাড়া তাকে ট্র্যাক করা — লোকেশন, গাড়ি ট্র্যাকিং ও চুরি-সুরক্ষা শুধু নিজের ফোন/গাড়ি বা যাঁরা জেনে সম্মতি দিয়েছেন তাঁদের জন্য।",
          "track anyone without their knowledge — location, vehicle tracking and anti-theft are only for your own phone/vehicle or people who knowingly agreed;"),
         ("দোকানের ক্যামেরা দিয়ে এমন জায়গা রেকর্ড করা যেখানে মানুষের গোপনীয়তার প্রত্যাশা আছে (যেমন বাথরুম, চেঞ্জিং রুম)।",
          "point a shop camera at places where people expect privacy (such as toilets or changing rooms);"),
         ("শিশুদের ক্ষতি করে এমন, যৌন নিপীড়নমূলক বা সহিংস কন্টেন্ট।", "share content that harms children, is sexually abusive or violent;"),
         ("অন্যের পরিচয় নেওয়া, ছবিতে কারও পরিচয় বদলানো বা জাল কাগজ তৈরি।", "impersonate others, alter someone's identity in photos, or make forged documents;"),
         ("অ্যাপ বা সার্ভার হ্যাক, রিভার্স-ইঞ্জিনিয়ার, ওভারলোড বা অপব্যবহারের চেষ্টা।", "try to hack, reverse-engineer, overload or abuse the app or servers."))),
    S("content", "আপনার কন্টেন্ট", "Your content",
      P("আপনি যা তৈরি করেন তার মালিক আপনি। শুধু পরিষেবাটি চালাতে (সংরক্ষণ, প্রদর্শন, আপনার বেছে নেওয়া মানুষের কাছে পৌঁছানো) যতটুকু দরকার ততটুকু ব্যবহারের সীমিত অনুমতি আপনি আমাদের দেন। "
        "নিয়ম ভাঙে এমন কন্টেন্ট রিপোর্ট করা যায়, এবং আমরা তা সরাতে বা অ্যাকাউন্ট সীমিত করতে পারি।",
        "You own what you create. You give us a limited permission to use it only as needed to run the service (store it, show it, deliver it to the people you choose). "
        "Content that breaks these rules can be reported, and we may remove it or limit the account.")),
    S("plans", "প্ল্যান, ক্রেডিট ও বিজ্ঞাপন", "Plans, credits and ads",
      UL(("ফ্রি প্ল্যানে কিছু ফিচার সীমিত এবং বিজ্ঞাপন থাকতে পারে। পেইড প্ল্যান ও ক্রেডিটের দাম ও সুবিধা কেনার আগে অ্যাপে দেখানো হয়।",
          "The Free plan has some limits and may show ads. Paid plan and credit prices and benefits are shown in the app before you buy."),
         ("ক্রেডিট দিয়ে AI-এর মতো খরচসাপেক্ষ কাজ চলে; কেনা ক্রেডিটের মেয়াদ কেনার সময় দেখানো হয়।",
          "Credits pay for costly actions such as AI; the expiry of purchased credits is shown when you buy."),
         ("Google Play-র মাধ্যমে কেনাকাটায় Google Play-র ফেরত নীতি প্রযোজ্য।", "Purchases made through Google Play follow Google Play's refund policy."),
         ("আমরা কখনো আসল পেমেন্ট ছাড়া পেইড সুবিধা বা বিজ্ঞাপন না দেখে পুরস্কার দেওয়ার ভান করি না।", "We never pretend to grant paid benefits without a real payment, or ad rewards without a completed ad."))),
    S("third", "তৃতীয় পক্ষের সার্ভিস", "Third-party services",
      P("কিছু ফিচার অন্যের সার্ভিসে চলে (যেমন Google, AI প্রদানকারী, SMS, কুরিয়ার, পেমেন্ট)। সেগুলোর নিজস্ব শর্ত প্রযোজ্য এবং সেগুলো বন্ধ বা বদলে গেলে সংশ্লিষ্ট ফিচার কাজ না-ও করতে পারে।",
        "Some features run on other companies' services (e.g. Google, AI providers, SMS, couriers, payments). Their own terms apply, and if they stop or change the related feature may not work.")),
    S("termination", "অ্যাকাউন্ট বন্ধ", "Ending your account",
      P("আপনি যেকোনো সময় অ্যাকাউন্ট মুছতে পারেন (<a href=\"/delete-account\">কীভাবে</a>)। এই শর্ত গুরুতরভাবে ভাঙলে আমরা অ্যাকাউন্ট স্থগিত বা বন্ধ করতে পারি, এবং সম্ভব হলে আগে জানাব।",
        "You can delete your account at any time (<a href=\"/delete-account?lang=en\">how</a>). If these terms are seriously broken we may suspend or close the account, telling you first where we can.")),
    S("liability", "দায়বদ্ধতা", "Disclaimers and liability",
      P("পরিষেবাটি \"যেমন আছে\" ভিত্তিতে দেওয়া হয়। আইন যতটা অনুমতি দেয়, পরোক্ষ ক্ষতি, তথ্য হারানো বা কোনো ফিচার (যেমন রিমাইন্ডার বা SOS) সময়মতো কাজ না করার জন্য আমরা দায়ী নই। আইনে যে অধিকার বাদ দেওয়া যায় না, তা এতে বাদ যায় না।",
        "The service is provided \"as is\". To the extent the law allows, we are not liable for indirect loss, lost data, or a feature (such as a reminder or SOS) not working in time. Nothing here removes rights the law does not allow us to remove.")),
    S("law", "প্রযোজ্য আইন ও পরিবর্তন", "Governing law and changes",
      P("প্রযোজ্য আইন ও আদালত: {law}। শর্ত বদলালে এই পাতায় নতুন তারিখসহ জানানো হবে; বড় পরিবর্তন অ্যাপেও জানানো হবে।",
        "Governing law and courts: {law}. If these terms change we will update this page with a new date; significant changes will also be announced in the app.")),
    S("contact", "যোগাযোগ", "Contact",
      UL(("অ্যাপে: সেটিংস → সাহায্য / সমস্যা রিপোর্ট।", "In the app: Settings → Help / report a problem."),
         ("ইমেইল: {email}", "Email: {email}"),
         ("ঠিকানা: {entity}, {address}", "Post: {entity}, {address}"))),
]


# ---------------------------------------------------------------- deletion
DELETION = [
    S("in_app", "অ্যাপ থেকে মুছুন (সবচেয়ে দ্রুত)", "Delete from the app (fastest)",
      UL(("Assisto খুলে বাম পাশের মেনু থেকে <b>সেটিংস</b>-এ যান।", "Open Assisto and go to <b>Settings</b> from the side menu."),
         ("নিচে <b>আমার অ্যাকাউন্ট মুছে ফেলুন…</b> চাপুন।", "Tap <b>Delete my account…</b> near the bottom."),
         ("কী কী মুছবে তার তালিকা দেখুন; চাইলে আগে ডেটা এক্সপোর্ট করুন।", "Review the list of what will be deleted; export your data first if you want a copy."),
         ("পাসওয়ার্ড, OTP (SMS চালু থাকলে) ও সিকিউরিটি PIN (সেট করা থাকলে) দিয়ে নিশ্চিত করুন।", "Confirm with your password, an OTP (when SMS is available) and your Security PIN (if set)."))),
    S("web", "অ্যাপ নেই? ওয়েব থেকে অনুরোধ করুন", "No app? Request it on the web",
      P("নিচের ফর্মে আপনার অ্যাকাউন্টের মোবাইল নম্বর বা ইমেইল দিন। এতে সঙ্গে সঙ্গে কিছু মোছা হয় না — আমাদের টিম আগে নিশ্চিত হবে অনুরোধটি সত্যিই অ্যাকাউন্টের মালিকের (সাধারণত ওই নম্বরে কল/SMS করে)। "
        "যাচাই হলে অ্যাপের মতোই ৭ দিনের অপেক্ষা শুরু হয় এবং অ্যাকাউন্টের মালিক ও বিশ্বস্ত পরিচিতজনরা বাতিলের লিংকসহ নোটিশ পান। যাচাই না হলে কিছুই মোছা হয় না।",
        "Enter your account's mobile number or email in the form below. Nothing is deleted straight away — our team first checks the request really comes from the account owner (usually by calling/texting that number). "
        "Once verified, the same 7-day wait as in the app starts, and the account owner and their trusted contacts get a notice with a cancel link. If it can't be verified, nothing is deleted.")),
    S("what", "কী মুছে যায়", "What is deleted",
      UL(("অ্যাকাউন্ট, প্রোফাইল ও প্রোফাইল ছবি।", "Your account, profile and profile photo."),
         ("রিমাইন্ডার, নোট, মেমরি, হিসাব, বাজেট, ধার, ভল্টের সব ফাইল, স্বাস্থ্য রেকর্ড, পরিবারের তথ্য।", "Reminders, notes, memories, money records, budgets, loans, every vault file, health records, family details."),
         ("আপনার পাঠানো বার্তা ও ফাইল আমাদের সার্ভার থেকে, সার্কেল সংযোগ, কলের রেকর্ড।", "Messages and files you sent (from our server), circle connections, call records."),
         ("চুরি-সুরক্ষার তথ্য ও ছবি, গাড়ি ট্র্যাকার ও অবস্থান, ব্যবসার তথ্য, সাপোর্ট টিকিট ও স্ক্রিনশট।", "Anti-theft data and photos, vehicle trackers and positions, business data, support tickets and screenshots."),
         ("আপনার সব অডিট লগ ও ডিভাইস টোকেন।", "All your audit logs and device tokens."))),
    S("kept", "কী থেকে যেতে পারে", "What may remain",
      UL(("অন্যদের ফোনে আগে থেকে পৌঁছানো বার্তার কপি তাদের ফোনেই থাকে — সেগুলো আমরা মুছতে পারি না।", "Copies of messages already delivered to other people's phones stay on their phones — we cannot delete those."),
         ("এনক্রিপ্টেড ব্যাকআপে সর্বোচ্চ প্রায় ১৪ দিন, তারপর ব্যাকআপ ঘুরে চলে যায়।", "Encrypted backups, for up to about 14 days, until they rotate out."),
         ("সার্ভারের মোছার লগে এক লাইনের প্রমাণ (অ্যাকাউন্ট নম্বর ও লগইনের ফোন/ইমেইল, সময়) — মোছা সত্যিই হয়েছে তা দেখাতে।", "A one-line record in the server's deletion log (account number, the sign-in phone/email, time) — proof that the deletion happened."),
         ("পরিচয়হীন খরচ-হিসাব (যেমন কতগুলো AI অনুরোধ হয়েছিল) — আপনার সাথে আর যুক্ত থাকে না।", "Anonymous cost counters (such as how many AI requests were made) — no longer linked to you."),
         ("আইন মানতে বাধ্য হলে যতটুকু রাখতে হয়, ততটুকু, সেই সময় পর্যন্ত।", "Anything the law requires us to keep, for as long as it requires."))),
    S("timing", "সময়সূচি ও বাতিল", "Timing and cancelling",
      P("অনুরোধের ৭ দিন পর প্রতি ঘণ্টার পরিষ্কার-প্রক্রিয়া অ্যাকাউন্টটি স্থায়ীভাবে মুছে দেয়। এর আগে অ্যাপে সেটিংস থেকে বা নোটিশের \"এটা আমি না\" লিংক থেকে বাতিল করা যায়। "
        "চুরি-সুরক্ষার সতর্কতা সক্রিয় থাকলে চোর যাতে আপনার ডেটা মুছতে না পারে, সেজন্য অনুরোধ আটকে থাকে।",
        "7 days after the request, an hourly clean-up permanently deletes the account. Before then you can cancel in the app's Settings or with the \"This wasn't me\" link in the notice. "
        "While an anti-theft alert is active the request is blocked, so a thief can't wipe your data.")),
    S("data_only", "শুধু কিছু তথ্য মুছতে চান?", "Want to delete only some data?",
      P("অ্যাকাউন্ট না মুছেও অ্যাপের ভেতরে যেকোনো রিমাইন্ডার, নোট, হিসাব, ভল্টের ফাইল, বার্তা বা ছবি আলাদাভাবে মুছতে পারেন; চ্যাটে ডিসঅ্যাপিয়ারিং মেসেজও চালু করতে পারেন। অ্যাপ ছাড়া এমন অনুরোধ করতে নিচের ফর্মের \"কারণ\" ঘরে লিখুন।",
        "Without deleting the account you can delete any reminder, note, record, vault file, message or photo inside the app, and you can turn on disappearing messages in a chat. To ask for this without the app, write it in the \"Reason\" box of the form below.")),
]


PAGES = {
    "privacy": {"path": "/privacy", "sections": PRIVACY,
                "title": ("গোপনীয়তা নীতি", "Privacy Policy"),
                "desc": ("Assisto কী তথ্য রাখে, কেন, কার সাথে শেয়ার হয়, প্রতিটি অ্যাপ অনুমতির কারণ, বিজ্ঞাপন, সংরক্ষণকাল ও মোছার উপায়।",
                         "What Assisto stores, why, who it is shared with, the reason for every app permission, ads, retention and how to delete.")},
    "terms": {"path": "/terms", "sections": TERMS,
              "title": ("ব্যবহারের শর্তাবলী", "Terms of Service"),
              "desc": ("Assisto অ্যাপ ও lifeassisto.com ব্যবহারের শর্তাবলী।", "The terms for using the Assisto app and lifeassisto.com.")},
    "deletion": {"path": "/delete-account", "sections": DELETION,
                 "title": ("অ্যাকাউন্ট ও ডেটা মুছে ফেলা", "Delete your account and data"),
                 "desc": ("অ্যাপ থেকে বা ওয়েবে অনুরোধ করে Assisto অ্যাকাউন্ট ও সব ডেটা মুছুন — কী মুছবে, কী থাকবে, কত দিনে।",
                          "Delete your Assisto account and all data from the app or by web request — what is deleted, what remains, and when.")},
}


def render_sections(key, lang):
    """Sections for one page in one language, ready for the template:
    [{id, heading, blocks:[{t:'p', html} | {t:'ul', items:[html]} | {t:'perms', rows}]}]"""
    i = 0 if lang == "bn" else 1
    F = facts(lang)
    out = []
    for s in PAGES[key]["sections"]:
        blocks = []
        for b in s["blocks"]:
            if b["t"] == "p":
                blocks.append({"t": "p", "html": mark_safe(b[lang].format(**F))})
            elif b["t"] == "ul":
                blocks.append({"t": "ul", "items": [mark_safe(it[i].format(**F)) for it in b["items"]]})
            elif b["t"] == "perms":
                blocks.append({"t": "perms", "rows": [
                    {"id": p["id"], "perm": p["perm"], "name": p["name"][i],
                     "why": p["why"][i], "when": p["when"][i], "revoke": p["revoke"][i]}
                    for p in PERMISSIONS]})
        out.append({"id": s["id"], "heading": s["h"][i], "blocks": blocks})
    return out
