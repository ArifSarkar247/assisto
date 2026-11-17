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

LAST_UPDATED = "2026-11-18"   # AI reply section (18 Nov) + legal name + address from the trade licence (17 Nov) + Axon Dynamics details (24 Oct) + AdMob ads (25 Oct) + CCTV watchman snapshots + appointment booking + budget and remittance (26 Oct) + health & fitness section (27 Oct)

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
    "LEGAL_ENTITY_NAME": "Axon Dynamics",
    "LEGAL_ADDRESS": "Cha-63/3, Uttar Badda, Badda, Dhaka 1212, Bangladesh",
    "LEGAL_CONTACT_EMAIL": "assistoaiagent@gmail.com",
    "LEGAL_GRIEVANCE_OFFICER": "Axon Dynamics, assistoaiagent@gmail.com",
    "LEGAL_GOVERNING_LAW": "Bangladesh",
    "LEGAL_HOSTING": "Amazon Web Services (AWS), ap-south-1 region (Mumbai, India)",
}


# Owner 17 Nov (trade licence in hand): the legal name, address and grievance
# line are exactly what the licence says, so an older server setting or env
# value can never show the old name/address again.
_LICENSED = ("LEGAL_ENTITY_NAME", "LEGAL_ADDRESS", "LEGAL_GRIEVANCE_OFFICER")


def _fact(key, lang):
    if key in _LICENSED:
        return escape(_OWNER_DEFAULTS[key])
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
        **_refund_window(),
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
                "ভিডিও কল, পুরনো ফোনকে দোকানের ক্যামেরা (Shop Box) বানানো, এবং আপনি সম্মতি দিয়ে চালু করলে "
                "চুরি-সুরক্ষার \"অনুপ্রবেশকারীর ছবি\" — শুধু Assisto খোলা থাকা অবস্থায় অ্যাপের ভেতরে ভুল "
                "সিকিউরিটি পিন দিলে, শাটার-শব্দসহ একটি সামনের ক্যামেরার ছবি (ব্যাকগ্রাউন্ডে কখনো নয়)।",
                "Photos of papers for the Document Vault, Photo Studio (passport/visa photos), profile and "
                "status photos/videos, video calls, turning an old phone into a shop camera (Shop Box), and — "
                "only if you agree and turn it on — the anti-theft \"intruder photo\": one front-camera photo, "
                "with a shutter sound, when a wrong Security PIN is typed while Assisto is open on screen "
                "(never in the background)."),
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
        "name": ("ফুল-স্ক্রিন নোটিফিকেশন (কল ও পরিবারের SOS)", "Full-screen notifications (calls and family SOS)"),
        "why": ("ফোন লক থাকলেও ইনকামিং ভয়েস/ভিডিও কলের স্ক্রিন বা পরিবারের কারো SOS অ্যালার্ম পাতা দেখানো — শুধু ঐ "
                "কল বা অ্যালার্মের জন্য। এর মাধ্যমে লক স্ক্রিনে আপনার চ্যাট বা ভল্ট কখনো দেখানো হয় না।",
                "Showing the incoming voice/video call screen, or a family member's SOS alarm page, when the "
                "phone is locked — only for that call or alarm. It never shows your chats or vault on the lock screen."),
        "when": ("Android 14+-এ এটি একটি বিশেষ অনুমতি; সেটিংস → নোটিফিকেশন ও কল থেকে আপনি চালু করেন।",
                 "On Android 14+ it is a special permission you turn on from Settings → Notifications & calls."),
        "revoke": ("Android সেটিংস → অ্যাপ → বিশেষ অ্যাপ অ্যাক্সেস → ফুল-স্ক্রিন নোটিফিকেশন → Assisto।",
                   "Android Settings → Apps → Special app access → Full-screen notifications → Assisto."),
    },
    {
        "id": "dnd",
        "perm": "ACCESS_NOTIFICATION_POLICY",
        "name": ("\"বিরক্ত করবেন না\" অ্যাক্সেস (পরিবারের SOS)", "Do Not Disturb access (family SOS)"),
        "why": ("শুধু আপনি অনুমতি দিলে: পরিবারের কেউ SOS পাঠালে আপনার ফোনে \"বিরক্ত করবেন না\" চালু থাকলেও অ্যালার্ম "
                "বাজানো। Assisto আপনার DND সেটিং বদলায় না, শুধু SOS অ্যালার্ম ওপারে যেতে দেয়।",
                "Only if you allow it: ringing a family member's SOS alarm on your phone even when Do Not "
                "Disturb is on. Assisto never changes your Do Not Disturb settings; it only lets SOS alarms through."),
        "when": ("জরুরি পাতার \"SOS তৈরি রাখুন\" কার্ডে \"অনুমতি দিন\" চাপলে Android-এর তালিকা খোলে; সেখানে আপনি চালু করেন।",
                 "When you tap Allow on the \"Get SOS ready\" card (Emergency page), Android's list opens and you turn it on."),
        "revoke": ("Android সেটিংস → অ্যাপ → বিশেষ অ্যাপ অ্যাক্সেস → \"বিরক্ত করবেন না\" অ্যাক্সেস → Assisto।",
                   "Android Settings → Apps → Special app access → Do Not Disturb access → Assisto."),
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
        "when": ("শুধু আপনি নিজে ভয়েস SOS বা ওয়েক-ওয়ার্ড চালু করলে। আপনি চালু রাখলে, অ্যান্ড্রয়েড বন্ধ করে দিলে "
                 "Assisto খুললে আবার চালু হয়; ফোন রিস্টার্টের পর নিজে থেকে মাইক চালু হয় না — শুধু একটি নোটিফিকেশন "
                 "আসে, ট্যাপ করলে তবেই চালু হয়। কল চলাকালীন, ব্যাটারি ১৫%-এর নিচে, বা অন্য অ্যাপ মাইক ব্যবহার "
                 "করলে ওয়েক-ওয়ার্ড নিজে থেকে থেমে থাকে।",
                 "Only when you switch voice SOS or the wake word on yourself. If you left it on and Android "
                 "stopped it, it starts again when you open Assisto; after a phone restart the microphone is "
                 "never turned on by itself — you only get a notification, and it starts when you tap it. The "
                 "wake word pauses itself during calls, below 15% battery, and while another app uses the mic."),
        "revoke": ("নোটিফিকেশনের Stop বোতাম, অথবা অ্যাপের সেটিংসে সুইচ বন্ধ করুন।",
                   "The notification's Stop button, or switch it off in the app's settings."),
    },
    {
        "id": "fgs_antitheft",
        "perm": "FOREGROUND_SERVICE_LOCATION (always-on anti-theft)",
        "name": ("সার্বক্ষণিক চুরি-সুরক্ষা (লোকেশন)", "Always-on anti-theft (location)"),
        "why": ("আপনার নিজের ফোন হারালে/চুরি হলে শেষ লোকেশন, সিম বদল ও অফলাইন হওয়ার খবর আপনার বেছে নেওয়া "
                "বিশ্বস্ত মানুষদের জানানো, আর আপনি বা তাঁরা দূর থেকে হারানো মোড, অ্যালার্ম, লক বা লক-স্ক্রিন বার্তা "
                "পাঠালে তা গ্রহণ করা। এই সার্ভিস ক্যামেরা ব্যবহার করে না। চলার সময় সবসময় একটি নোটিফিকেশন দেখা যায়।",
                "Telling the trusted contacts you chose the last location, a SIM change or the phone going "
                "offline if your own phone is lost or stolen, and receiving the lost mode, alarm, lock or "
                "lock-screen message that you or they send from another phone. This service never uses the "
                "camera. A notification is always visible while it runs."),
        "when": ("শুধু আপনি সিকিউরিটি পিন দিয়ে সুরক্ষা চালু করলে। সুরক্ষা চালু থাকলে ফোন রিস্টার্ট, অ্যাপ আপডেট "
                 "বা অ্যাপ খোলার পরে এটি আবার চালু হয়, যাতে সুরক্ষা চুপচাপ বন্ধ না থাকে। সুরক্ষা বন্ধ থাকলে "
                 "কখনো নিজে থেকে চালু হয় না।",
                 "Only when you turn protection on with your Security PIN. While protection is on, it comes "
                 "back after a phone restart, an app update or when you open the app, so protection never "
                 "silently stops. With protection off it never starts by itself."),
        "revoke": ("অ্যাপে সার্বক্ষণিক সুরক্ষা বন্ধ করুন (সিকিউরিটি পিন), অথবা লোকেশনের অনুমতি তুলে নিন।",
                   "Turn always-on protection off in the app (Security PIN), or remove the location permission."),
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
        "id": "own_calls",
        "perm": "MANAGE_OWN_CALLS",
        "name": ("নিজের কল পরিচালনা (My Circle কল)", "Manage own calls (My Circle calls)"),
        "why": ("My Circle-এর আসা ভয়েস/ভিডিও কল Android-এর নিজের কল ব্যবস্থায় জানানো, যাতে অ্যাপ বন্ধ বা অন্য অ্যাপ খোলা থাকলেও, "
                "লক স্ক্রিনেও কল বাজে — WhatsApp-এর মতো। এটা শুধু Assisto-র নিজের কল; আপনার ফোনের সাধারণ কল, কল লগ বা নম্বর পড়া হয় না।",
                "Telling Android's own call system about incoming My Circle voice/video calls, so they ring even when the app "
                "is closed, another app is open or the screen is locked — like WhatsApp. Only Assisto's own calls; your phone's "
                "regular calls, call log or numbers are never read."),
        "when": ("অ্যাপ ইনস্টলের সময় Android নিজেই দেয় (সাধারণ অনুমতি, আলাদা প্রশ্ন আসে না)।",
                 "Granted by Android at install time (a normal permission; no separate prompt)."),
        "revoke": ("অ্যাপ আনইনস্টল করলে সরে যায়; কল বাজা বন্ধ করতে Android সেটিংস → অ্যাপ → Assisto → নোটিফিকেশন → \"Calls\" বন্ধ করুন।",
                   "Removed when you uninstall the app; to stop call ringing turn off Android Settings → Apps → Assisto → Notifications → \"Calls\"."),
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
        "id": "exact_alarm",
        "perm": "SCHEDULE_EXACT_ALARM",
        "name": ("অ্যালার্ম ও রিমাইন্ডার (ঠিক সময়ে)", "Alarms & reminders (exact time)"),
        "why": ("আপনার বসানো রিমাইন্ডার ঠিক মিনিটে বাজানো। অনুমতি না দিলে রিমাইন্ডার কয়েক মিনিট দেরিতে আসতে পারে।",
                "Ringing the reminders you set on the exact minute. Without it, reminders may arrive a few minutes late."),
        "when": ("শুধু সময়সহ রিমাইন্ডার বানানোর সময় কারণসহ জিজ্ঞেস করা হয় (Android 14+-এ শুরুতে বন্ধ থাকে)।",
                 "Only when you create a timed reminder, with an explanation (off by default on Android 14+)."),
        "revoke": ("ফোনের সেটিংস → অ্যাপ → Assisto → অ্যালার্ম ও রিমাইন্ডার → বন্ধ।",
                   "Phone Settings → Apps → Assisto → Alarms & reminders → off."),
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
        "perm": "health.READ_STEPS, health.READ_HEART_RATE, health.READ_SLEEP, health.READ_ACTIVE_CALORIES_BURNED",
        "name": ("Health Connect (ধাপ, হার্ট রেট, ঘুম, ক্যালোরি) — শুধু পড়া", "Health Connect (steps, heart rate, sleep, calories) — read only"),
        "why": ("স্মার্টওয়াচ ও ফিটনেস স্ক্রিনে আজকের সারসংক্ষেপ ও ৭, ৩০ বা ৯০ দিনের প্রবণতা দেখানো। এই ডেটা শুধু আপনার ফোনে "
                "দেখানো হয় — আমাদের সার্ভারে পাঠানো হয় না, বিজ্ঞাপন বা অন্য কোনো কাজে ব্যবহার হয় না, কারও সাথে শেয়ার হয় না। "
                "আমরা Health Connect-এ কিছু লিখি না।",
                "Showing today's summary and a 7-, 30- or 90-day trend on the Smartwatch & Fitness screen. This data is "
                "only shown on your phone — it is not sent to our servers, not used for ads or anything else, "
                "and not shared with anyone. We never write to Health Connect."),
        "when": ("স্মার্টওয়াচ ও ফিটনেস স্ক্রিন খুলে \"Connect\" চাপলে, Health Connect-এর নিজস্ব অনুমতি স্ক্রিনে।",
                 "When you open Smartwatch & Fitness and tap Connect, on Health Connect's own permission screen."),
        "revoke": ("Health Connect অ্যাপ → অ্যাপ অনুমতি → Assisto।",
                   "Health Connect app → App permissions → Assisto."),
    },
    {
        "id": "media",
        "perm": "No permission — Android Photo Picker / কোনো অনুমতি নয় — Android Photo Picker",
        "name": ("ছবি ও ভিডিও (অনুমতি লাগে না)", "Photos and videos (no permission needed)"),
        "why": ("ভল্ট, চ্যাট, স্ট্যাটাস বা ফটো স্টুডিওতে ছবি/ভিডিও যোগ করতে আপনি Android-এর নিজস্ব Photo Picker-এ "
                "নিজে একটা একটা করে বেছে নেন; Assisto শুধু সেটুকুই পায়, আপনার গ্যালারি কখনো পড়ে না।",
                "To add photos/videos to the vault, chats, status or Photo Studio you choose each one in Android's own "
                "Photo Picker; Assisto receives only what you choose and never reads your gallery."),
        "when": ("প্রতিবার গ্যালারি/সংযুক্ত বাটন চাপলে Photo Picker খোলে — কোনো অনুমতির প্রশ্ন নেই।",
                 "Each time you tap Gallery/Attach the Photo Picker opens — no permission prompt."),
        "revoke": ("বন্ধ করার কিছু নেই — Assisto-র গ্যালারিতে কোনো অনুমতি নেই।",
                   "Nothing to turn off — Assisto has no access to your gallery."),
    },
    {
        "id": "device_admin",
        "perm": "BIND_DEVICE_ADMIN (Device administrator)",
        "name": ("ডিভাইস অ্যাডমিন (চুরি-সুরক্ষা)", "Device administrator (anti-theft)"),
        "why": ("ফোন হারালে/চুরি হলে আপনি বা আপনার বিশ্বস্ত মানুষ দূর থেকে স্ক্রিন লক করতে পারেন, আর ভুল আনলক চেষ্টা টের পাওয়া যায়। "
                "আমরা ফোনের ডেটা মুছে ফেলার (wipe) ক্ষমতা চাই না। চালু থাকলে Android আগে অ্যাডমিন বন্ধ না করে "
                "অ্যাপ আনইনস্টল করতে দেয় না — যাতে চোর সহজে সুরক্ষা সরাতে না পারে।",
                "If the phone is lost or stolen: you or your trusted contact can lock the screen remotely, and "
                "wrong unlock attempts are noticed. We do not ask for the power to wipe your phone. While it is on, Android "
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
        "perm": "INTERNET, ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_NETWORK_STATE, MODIFY_AUDIO_SETTINGS, VIBRATE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED",
        "name": ("সাধারণ অনুমতি", "Normal permissions"),
        "why": ("সার্ভারের সাথে যোগাযোগ, কলের সংযোগ ও স্পিকার/ইয়ারপিস বদল, চুরি-অ্যালার্মের কম্পন, রিমাইন্ডার বাজার সময় ফোন "
                "জাগানো, ফোন রিস্টার্টের পরে আপনার রিমাইন্ডারগুলো আবার সেট করা, এবং চুরি-সুরক্ষা চালু থাকলে ফোনটি আপনার "
                "রাখা বাসার ওয়াই-ফাইতে আছে কি না দেখা (শুধু একটি কোড, ওয়াই-ফাইয়ের নাম কখনো সংরক্ষণ বা পাঠানো হয় না)।",
                "Talking to our server, keeping calls connected and switching speaker/earpiece, vibration for the "
                "anti-theft alarm, waking the phone when a reminder is due, re-setting your reminders after "
                "the phone restarts, and, while anti-theft protection is on, checking whether the phone is on the "
                "home Wi-Fi you saved (only a code; the Wi-Fi name is never stored or sent)."),
        "when": ("Android এগুলোর জন্য আলাদা করে জিজ্ঞেস করে না।",
                 "Android does not prompt for these."),
        "revoke": ("অ্যাপ আনইনস্টল করলে।", "Uninstall the app."),
    },
    {
        # admob (owner 25 Oct): merged in by the Google Mobile Ads SDK
        "id": "ad_id",
        "perm": "com.google.android.gms.permission.AD_ID",
        "name": ("বিজ্ঞাপন আইডি (Advertising ID)", "Advertising ID"),
        "why": ("শুধু ফ্রি প্ল্যানে Google AdMob-এর বিজ্ঞাপন দেখাতে, একই বিজ্ঞাপন বারবার না দেখাতে, প্রতারণা ঠেকাতে ও "
                "বিজ্ঞাপনের সমষ্টিগত হিসাবের জন্য Google-এর বিজ্ঞাপন SDK ফোনের রিসেটযোগ্য বিজ্ঞাপন আইডি পড়ে। "
                "Assisto নিজে এই আইডি সংরক্ষণ করে না।",
                "Google's ads SDK reads the phone's resettable Advertising ID to show Google AdMob ads on the "
                "Free plan only, to avoid repeating the same ad, to prevent fraud and for aggregate ad "
                "reporting. Assisto itself does not store this ID."),
        "when": ("Android এটির জন্য আলাদা করে জিজ্ঞেস করে না। ইউরোপ/যুক্তরাজ্যে ও যেখানে আইন চায় সেখানে প্রথম "
                 "বিজ্ঞাপনের আগে Google-এর সম্মতি ফর্ম দেখানো হয়।",
                 "Android does not prompt for it. In the EEA/UK and wherever the law requires it, Google's "
                 "consent form is shown before the first ad."),
        "revoke": ("Android সেটিংস → গোপনীয়তা → বিজ্ঞাপন (Ads) → বিজ্ঞাপন আইডি মুছুন বা রিসেট করুন; "
                   "অ্যাপের সেটিংস → \"বিজ্ঞাপনের গোপনীয়তা\" থেকেও সম্মতি বদলাতে পারেন (যেখানে দেখায়)।",
                   "Android Settings → Privacy → Ads → delete or reset the Advertising ID; you can also change "
                   "your consent in the app's Settings → \"Ads privacy\" (where shown)."),
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
         ("বিজ্ঞাপন (Google AdMob) শুধু ফ্রি প্ল্যানে; প্রিমিয়াম ও বিজনেসে কোনো বিজ্ঞাপন নেই। SOS, নিরাপত্তা, চুরি-সুরক্ষা, পরিবারের সতর্কতা, কল, চ্যাট, পেমেন্ট, লগইন বা অনুমতির স্ক্রিনে কখনো নয়।",
          "Ads (Google AdMob) appear only on the Free plan; Premium and Business have no ads. Never on SOS, safety, anti-theft, family alert, call, chat, payment, sign-in or permission screens."),
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
         ("<b>পানি, ঘুম, খাবার ও ফিটনেস (আপনি লিখলে):</b> দিনে কত গ্লাস পানি, কত ঘণ্টা ঘুম, খাবারের নোট, আপনার লক্ষ্য, ব্যায়ামের লগ (ধরন, সময়, পদক্ষেপ, ঐচ্ছিক ক্যালরি) ও ওজন — যাতে অন্য ফোনেও আপনার অগ্রগতি দেখতে পান।",
          "<b>Water, sleep, food and fitness (if you log them):</b> glasses of water, hours of sleep, food notes, your goals, workout logs (type, minutes, steps, optional calories) and weight — so you can see your progress on any phone."),
         ("<b>বার্তা ও কল:</b> ব্যক্তিগত ও গ্রুপ চ্যাটের লেখা বার্তা এনক্রিপ্টেড আকারে (আমরা পড়তে পারি না) এবং ডেলিভারির জন্য প্রয়োজনীয় তথ্য (কে, কাকে, কখন)। চ্যানেলের পোস্ট, কমিউনিটি ও ব্যবসায়িক ইনবক্স end-to-end এনক্রিপ্টেড নয়। পাঠানো ছবি/ফাইল প্রাপক নামাতে পারার জন্য সার্ভারে থাকে। কলের রেকর্ড (কে, কখন, কতক্ষণ) — কলের অডিও/ভিডিও আমরা রেকর্ড করি না।",
          "<b>Messages and calls:</b> text messages of personal and group chats in encrypted form (we cannot read them) plus what is needed to deliver them (who, to whom, when). Channel posts, communities and the business inbox are not end-to-end encrypted. Photos/files you send are kept on the server so recipients can download them. Call records (who, when, how long) — we never record call audio or video."),
         ("<b>নিরাপত্তা ফিচার:</b> SOS ও Safe Journey-র লোকেশন, আপনার বেছে নেওয়া পরিচিত নিরাপদ জায়গা, চেক-ইন, বিশ্বস্ত পরিচিতজন।",
          "<b>Safety features:</b> SOS and Safe Journey locations, the trusted places you choose, check-ins, your trusted contacts."),
         ("<b>চুরি-সুরক্ষা (আপনি চালু করলে):</b> সুরক্ষিত ফোনের তথ্য (মডেল, IMEI যা আপনি দেন), নিয়মিত \"আমি ঠিক আছি\" সংকেত, এবং ফোন হারানো অবস্থায় ধরা ঘটনা — যেমন SIM বদল, ভুল আনলক, লোকেশন, আপনি বা আপনার বিশ্বস্ত মানুষেরা দূর থেকে যা পাঠিয়েছেন (হারানো মোড, অ্যালার্ম, লক, বার্তা — কে পাঠিয়েছেন ও ফল কী) এবং শুধু আপনি সম্মতি দিলে অনুপ্রবেশকারীর ছবি। এগুলো শুধু আপনি ও আপনার বেছে নেওয়া বিশ্বস্ত মানুষেরা দেখতে পান; ঘটনা ও ছবি ৩০ দিন পরে মুছে যায়।",
          "<b>Anti-theft (if you turn it on):</b> details of the protected phone (model, the IMEI you enter), regular \"I'm OK\" heartbeats, and events captured while the phone is lost — such as SIM change, wrong unlocks, location, the remote switches you or your trusted contacts sent (lost mode, alarm, lock, message — with who sent them and the result) and, only if you agreed to it, an intruder photo. Only you and the trusted contacts you chose can see them; events and photos are deleted after 30 days."),
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
         ("মন ও প্রাণশক্তির ডায়েরি (মুড, প্রাণশক্তির রেটিং ও নোট) — কোনো অডিও রাখা হয় না।",
          "Your Mood & energy journal (mood, energy rating and notes) — no audio is ever kept."),
         ("আপনার ফোনবুক — শুধু নম্বরের হ্যাশ মেলানোর জন্য যায়, নাম কখনো নয়।",
          "Your phonebook — only number hashes are sent for matching, never names."),
         ("\"Hey Assisto\" ওয়েক-ওয়ার্ড শোনার অডিও।", "The audio the \"Hey Assisto\" wake word listens to."),
         ("চ্যাট এনক্রিপশনের চাবি — এগুলো কখনো ফোন ছাড়ে না।", "Your chat encryption keys — they never leave the phone."),
         ("ভয়েস টাইপিং ফোনের নিজস্ব স্পিচ সার্ভিস (যেমন Google) দিয়ে হয়, সেই সার্ভিসের নিজস্ব নীতিমালায়।",
          "Voice typing uses your phone's own speech service (for example Google's), under that service's own terms."))),
    S("health_fitness", "স্বাস্থ্য ও ফিটনেস ফিচার", "Health and fitness features",
      P("পানি-ঘুম-খাবার, ফিটনেস সঙ্গী, স্মার্টওয়াচ ও ফিটনেস এবং মন ও প্রাণশক্তির ডায়েরি — এগুলো শুধু নিজের যত্ন ও অভ্যাসের হিসাব রাখার টুল। "
        "<b>এটি চিকিৎসা-পরামর্শ নয়।</b> Assisto কোনো রোগ চেনে না, চিকিৎসা বা ওষুধের কথা বলে না; স্বাস্থ্য নিয়ে চিন্তা থাকলে ডাক্তারের সাথে কথা বলুন। "
        "মন ও প্রাণশক্তির ডায়েরি শুধু নিজের অনুভূতি লিখে রাখা ও বিশ্রামের (শ্বাসের ব্যায়াম) জন্য; এটি কোনো কাউন্সেলিং সেবা নয়। কখনো নিজেকে অনিরাপদ মনে হলে ৯৯৯-এ কল করুন।",
        "Water, sleep and food, Fitness partner, Smartwatch and fitness, and the Mood and energy journal are self-care and habit-tracking tools only. "
        "<b>This is not medical advice.</b> Assisto does not identify any illness and does not suggest treatment or medicine; talk to a doctor about any health concern. "
        "The Mood and energy journal is only for noting how you feel and for relaxation (a breathing exercise); it is not a counselling service. If you ever feel unsafe, call 999."),
      UL(("<b>Health Connect:</b> আপনি অনুমতি দিলে আমরা শুধু <b>পড়ি</b> — পদক্ষেপ, হার্ট রেট, ঘুম ও সক্রিয় ক্যালরি — এবং স্মার্টওয়াচ ও ফিটনেস স্ক্রিনে দেখাই। এই ডেটা ফোনেই থাকে: আমাদের সার্ভারে যায় না, আমরা Health Connect-এ কিছু লিখি না।",
          "<b>Health Connect:</b> if you allow it, we only <b>read</b> steps, heart rate, sleep and active calories and show them on the Smartwatch and fitness screen. This data stays on your phone: it is not sent to our server, and we never write to Health Connect."),
         ("<b>আপনার লেখা পানি/ঘুম/খাবার/ফিটনেস লগ</b> আমাদের সার্ভারে আপনার অ্যাকাউন্টে থাকে, যাতে অন্য ফোনেও দেখতে পান; দেখেন শুধু আপনি। মন ও প্রাণশক্তির ডায়েরি শুধু এই ফোনে থাকে।",
          "<b>Water/sleep/food/fitness logs you enter</b> are kept on our server in your account so you can see them on another phone; only you can see them. The Mood and energy journal stays only on this phone."),
         ("স্বাস্থ্য ও ফিটনেসের কোনো তথ্য আমরা <b>বিক্রি করি না, বিজ্ঞাপনে বা বিজ্ঞাপনের প্রোফাইলে ব্যবহার করি না</b>, ঋণ বা বিমার যোগ্যতা যাচাইয়ে ব্যবহার করি না, এবং কারও সাথে শেয়ার করি না। Health Connect থেকে পাওয়া তথ্যের ব্যবহার Health Connect-এর অনুমতি নীতির (Limited Use) শর্ত মেনে চলে।",
          "We <b>never sell health and fitness data, never use it for ads or advertising profiles</b>, never use it to decide credit or insurance eligibility, and never share it with anyone. Use of information received from Health Connect follows the Health Connect Permissions policy, including its Limited Use requirements."),
         ("যেকোনো সময় মুছতে পারেন: প্রতিটি স্ক্রিনে লগ মুছুন, মন ও প্রাণশক্তির ডায়েরিতে \"সব তথ্য মুছুন\", Health Connect অ্যাপ থেকে অনুমতি তুলে নিন, অথবা পুরো অ্যাকাউন্ট মুছে ফেলুন।",
          "Delete any time: delete logs on each screen, use \"Delete all data\" in the Mood and energy journal, revoke access in the Health Connect app, or delete your whole account."))),
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
        "আপনার end-to-end এনক্রিপ্টেড বার্তা কখনো AI-তে পাঠানো হয় না — তবে কোনো চ্যাটে আপনি AI উত্তর চালু করলে শুধু সেই চ্যাটের বার্তা, শুধু উত্তর তৈরির জন্য পাঠানো হয়; সেগুলো জমা রাখা বা প্রশিক্ষণে ব্যবহার করা হয় না। AI ভুল করতে পারে — গুরুত্বপূর্ণ সিদ্ধান্তের আগে যাচাই করুন। "
        "কোনো AI উত্তর আপত্তিকর, ক্ষতিকর বা ভুল মনে হলে অ্যাপে উত্তরের পাশের পতাকা চিহ্ন বা লম্বা চাপ দিয়ে সেটি রিপোর্ট করতে পারেন। রিপোর্টে থাকে শুধু উত্তরের লেখা (কোনো ছবি নয়), কারণ, আপনার ঐচ্ছিক মন্তব্য, আপনার অ্যাকাউন্ট ও সময়; Assisto টিম রিপোর্ট করা উত্তরগুলো পর্যালোচনা করে AI-এর ভুল ঠিক করতে ও অপব্যবহার ঠেকাতে।",
        "When you use an AI feature (AI chat, reading a document or bill, CV/scam analysis, Photo Studio AI edits and so on), only the text or image needed for that task is sent from our server to an AI provider, and the answer comes back. "
        "The provider may be Anthropic (Claude), OpenAI, Google (Gemini) or, for images, Replicate — whichever we have switched on at the time. They process it under their API terms. "
        "Your end-to-end encrypted messages are never sent to AI, unless you turn on AI reply for a chat. Then only the messages in that chat are sent, only to write the reply; they are not stored or used for training. AI can be wrong — check before important decisions. "
        "If an AI answer seems offensive, harmful or wrong, you can report it in the app with the flag next to the answer or by long-pressing it. A report keeps only the text of the answer (never a photo), the reason, your optional note, your account and the time; the Assisto team reviews reported answers to fix AI mistakes and prevent misuse.")),
    S("ai_reply", "AI উত্তর (প্রস্তাব, ব্যস্ত মোড, পুরো অটো)", "AI reply (suggestions, Busy mode, Full auto)",
      P("আপনি চালু করলে Assisto আপনার পাওয়া মেসেজের জন্য ২–৩টি ছোট উত্তর প্রস্তাব করে, আর আপনার বেছে নেওয়া মানুষের "
        "জন্য ব্যস্ত মোডে বা পুরো অটোতে আপনার হয়ে উত্তর দিতে পারে। এটি শুরুতে বন্ধ থাকে।",
        "When you turn it on, Assisto suggests 2–3 short replies to messages you receive and, for people you "
        "choose, can reply for you in Busy mode or Full auto. It is off by default."),
      UL(("উত্তর বানাতে আপনার ফোন পাওয়া মেসেজের লেখা ও আগের কয়েকটি লাইন আমাদের সার্ভারে পাঠায়। লেখাটি শুধু সেই "
          "মুহূর্তে উত্তর বানাতে ব্যবহার হয় — আমরা তা সংরক্ষণ করি না, লগ করি না, AI প্রশিক্ষণে ব্যবহার করি না, "
          "আমাদের কর্মী বা অ্যাডমিন দেখতে পারেন না।",
          "To make a reply, your phone sends the received message text and a few earlier lines to our server. "
          "The text is used only at that moment to make the reply — we do not store it, log it or use it to "
          "train AI, and our staff and admins cannot see it."),
         ("উত্তর বানাতে লেখাটি আমাদের AI সেবাদাতার (যেমন Anthropic, Google, OpenAI) কাছে যায়; ফোন নম্বর, "
          "অ্যাকাউন্ট নম্বর ও ইমেইল আগে ঢেকে দেওয়া হয়। সেবাদাতারা চুক্তি অনুযায়ী এই ডেটায় প্রশিক্ষণ দেয় না।",
          "To make a reply the text goes to our AI provider (such as Anthropic, Google or OpenAI); phone "
          "numbers, account numbers and e-mails are masked first. Under our contracts providers do not train "
          "on this data."),
         ("আপনার ঢঙ শেখা আলাদা সম্মতিতে: শুধু আপনার নিজের পাঠানো My Circle মেসেজ থেকে একটি ছোট প্রোফাইল "
          "(গড় দৈর্ঘ্য, ইমোজি, আপনি/তুমি, ভাষা, কয়েকটি সাধারণ শব্দ) রাখা হয়, আসল মেসেজ নয়। সম্মতি বন্ধ করলে "
          "প্রোফাইল সাথে সাথে মুছে যায়।",
          "Learning your style needs separate consent: from your OWN sent My Circle messages only, we keep a "
          "small profile (typical length, emoji use, formal/informal, language, a few common words), never "
          "the messages. Turning consent off deletes the profile at once."),
         ("AI কখনো টাকা-পয়সা, ঠিকানা, দেখা করা, স্বাস্থ্য-জরুরি, প্রতিশ্রুতি বা বড় সিদ্ধান্তের মেসেজের উত্তর দেয় না, "
          "OTP/ব্যাংক/SOS লেখায় কিছু প্রস্তাব করে না, এবং শিশু অ্যাকাউন্টে কাজ করে না।",
          "The AI never answers messages about money, addresses, meeting in person, health emergencies, "
          "promises or big decisions, suggests nothing for OTP/bank/SOS texts, and never works on child accounts."),
         ("AI-এর পাঠানো মেসেজের নিচে প্রাপক \"Assisto AI উত্তর\" ট্যাগ দেখেন (আপনি প্রতি মানুষে বন্ধ করতে পারেন)। "
          "কোন মেসেজ AI পাঠিয়েছে, কতগুলো উত্তর ও ক্রেডিট — শুধু এই হিসাব (লেখা ছাড়া) রাখা হয়।",
          "People see an \"Assisto AI reply\" tag under messages the AI sent (you can turn it off per person). "
          "We keep only which messages the AI sent and counts of replies and credits — never the text."),
         ("নোটিফিকেশনে প্রস্তাব (অন্য অ্যাপ): আপনি Notification access দিলে শুধু আপনার বেছে নেওয়া অ্যাপের মেসেজ "
          "নোটিফিকেশন পড়া হয়; আপনি ট্যাপ না করলে কিছুই পাঠানো হয় না। SOS, ব্যাংক, OTP ও পেমেন্ট নোটিফিকেশন কখনো নয়।",
          "Suggestions on notifications (other apps): only if you grant Notification access, only for apps you "
          "choose; nothing is ever sent unless you tap. Never for SOS, bank, OTP or payment notifications.")),
    ),
    S("ads", "বিজ্ঞাপন (Google AdMob)", "Advertising (Google AdMob)",
      P("ফ্রি প্ল্যানে অ্যাপে <b>Google AdMob</b>-এর বিজ্ঞাপন দেখানো হয় — এভাবেই ফ্রি প্ল্যান চলে। <b>প্রিমিয়াম ও বিজনেস প্ল্যানে কোনো বিজ্ঞাপন নেই।</b> "
        "বিজ্ঞাপন দেখাতে, একই বিজ্ঞাপন কতবার দেখানো হলো তা সীমিত রাখতে, প্রতারণা ঠেকাতে ও সমষ্টিগত রিপোর্টের জন্য Google-এর বিজ্ঞাপন SDK এই তথ্য সংগ্রহ ও Google-কে পাঠায়: "
        "ডিভাইসের রিসেটযোগ্য বিজ্ঞাপন আইডি (<b>Advertising ID</b>), IP ঠিকানা (আনুমানিক এলাকা), ডিভাইস ও অ্যাপের তথ্য, বিজ্ঞাপনের সাথে অ্যাপে কী করা হলো (কোন বিজ্ঞাপন দেখা বা ট্যাপ করা হলো) এবং SDK-র ডায়াগনস্টিক তথ্য (যেমন বিজ্ঞাপন লোডের সময় ও ত্রুটি)। "
        "Assisto এই আইডি সংরক্ষণ করে না। দৈনিক সীমা ও বিজ্ঞাপন-ক্রেডিটের হিসাবের জন্য আমরা আপনার অ্যাকাউন্টে কয়টি বিজ্ঞাপন দেখানো হলো তা রাখি; আর বিজ্ঞাপনের জায়গা ঠিক করতে শুধু প্রতিটি জায়গার মোট দেখানো/ট্যাপ ও Google-এর জানানো আনুমানিক আয় রাখি — কোনো ব্যবহারকারী বা ডিভাইস আইডি ছাড়া। "
        "আপনার মেসেজ, কন্টাক্ট, সুনির্দিষ্ট (GPS) অবস্থান, স্বাস্থ্য তথ্য বা ছবি কখনো বিজ্ঞাপনদাতা বা Google-কে বিজ্ঞাপনের জন্য দেওয়া হয় না। "
        "বিস্তারিত: <a href=\"https://policies.google.com/technologies/ads\" rel=\"noopener\">Google কীভাবে বিজ্ঞাপনে তথ্য ব্যবহার করে</a>।",
        "On the Free plan the app shows ads from <b>Google AdMob</b> — that is how the Free plan is paid for. <b>Premium and Business plans have no ads.</b> "
        "To show ads, limit how often the same ad appears, prevent fraud and produce aggregate reports, Google's ads SDK collects and sends to Google: "
        "the device's resettable advertising identifier (<b>Advertising ID</b>), IP address (approximate area), device and app information, app interactions with ads (which ads were viewed or tapped) and SDK diagnostics (such as ad load times and errors). "
        "Assisto does not store this ID. For the daily caps and the ad-credit wallet we keep a count of the ads shown to your account; to tune ad placements we keep only totals per placement (times shown/tapped and the estimated value Google reports) — with no user or device ID. "
        "Your messages, contacts, precise (GPS) location, health data and photos are never given to advertisers or to Google for ads. "
        "Details: <a href=\"https://policies.google.com/technologies/ads\" rel=\"noopener\">how Google uses information from ads</a>."),
      P("<b>সম্মতি (Google UMP):</b> ইউরোপীয় অর্থনৈতিক এলাকা, যুক্তরাজ্য ও সুইজারল্যান্ডে (GDPR) এবং যুক্তরাষ্ট্রের যেসব রাজ্যের গোপনীয়তা আইন চায়, সেখানে প্রথম বিজ্ঞাপনের আগে Google-এর সার্টিফায়েড সম্মতি ফর্ম দেখানো হয়; আপনি সম্মতি দিতে, না দিতে বা আপনার তথ্য বিক্রি/শেয়ার না করতে বলতে পারেন। "
        "<b>পার্সোনালাইজড বনাম নন-পার্সোনালাইজড:</b> পার্সোনালাইজড বিজ্ঞাপন আপনার আগ্রহ অনুযায়ী বাছাই হয়; নন-পার্সোনালাইজড বিজ্ঞাপন শুধু প্রসঙ্গ (যেমন অ্যাপ ও আনুমানিক এলাকা) দেখে বাছাই হয়। "
        "Assisto ডিফল্টভাবে শুধু <b>নন-পার্সোনালাইজড</b> বিজ্ঞাপন চায়। কখনো পার্সোনালাইজড বিজ্ঞাপন চালু হলেও তা শুধু সেখানেই হবে যেখানে আপনার সম্মতি সেটা অনুমতি দেয় এবং আপনি বন্ধ করেননি; নন-পার্সোনালাইজড বিজ্ঞাপনেও ফ্রিকোয়েন্সি সীমা ও প্রতারণা ঠেকাতে Advertising ID ব্যবহার হতে পারে।",
        "<b>Consent (Google UMP):</b> in the European Economic Area, the UK and Switzerland (GDPR), and in US states whose privacy laws require it, Google's certified consent form is shown before the first ad; you can consent, refuse, or opt out of the sale/sharing of your information. "
        "<b>Personalised vs non-personalised:</b> personalised ads are chosen from your interests; non-personalised ads are chosen only from context (such as the app and your approximate area). "
        "By default Assisto requests <b>non-personalised</b> ads only. If personalised ads are ever switched on, they are used only where your consent choice allows them and you have not opted out; even non-personalised ads may use the Advertising ID for frequency capping and fraud prevention."),
      UL(("বিজ্ঞাপন কখনো SOS, নিরাপত্তা, Safe Journey, চুরি-সুরক্ষা, পরিবারের সতর্কতা, কল, চ্যাট ও চ্যাট লক, পেমেন্ট/প্ল্যান, লগইন/OTP, শুরুর ধাপ (অনবোর্ডিং) বা অনুমতির স্ক্রিনে দেখানো হয় না।",
          "Ads are never shown on SOS, safety, Safe Journey, anti-theft, family alert, call, chat and chat-lock, payment/plan, sign-in/OTP, first-run (onboarding) or permission screens."),
         ("নোটিফিকেশন, SOS, নিরাপত্তা সতর্কতা, কল, অ্যালার্ম/রিমাইন্ডার, উইজেট বা লিংক থেকে অ্যাপ খুললে অ্যাপ খোলার বিজ্ঞাপন দেখানো হয় না; প্রথমবার অ্যাপ খোলায় বা লগইনের ঠিক পরেও নয়।",
          "No app-open ad when the app is opened from a notification, SOS, a safety alert, a call, an alarm/reminder, the widget or a link — and never on the very first launch or right after you sign in."),
         ("\"বিজ্ঞাপন দেখে ক্রেডিট / আনলক\" সবসময় ঐচ্ছিক — আপনি নিজে চাপলে তবেই; পুরস্কার দেওয়া হয় শুধু Google সার্ভার থেকে যাচাই হওয়ার পর।",
          "\"Watch an ad for credits / an unlock\" is always optional — only when you tap it; the reward is given only after Google's server confirms the ad."),
         ("Discover-এ \"স্পনসরড\" কার্ড সব প্ল্যানে দেখা যেতে পারে এবং সবসময় \"স্পনসরড\" লেখা থাকে।",
          "\"Sponsored\" cards in Discover can appear on every plan and are always labelled \"Sponsored\"."),
         ("<b>যেভাবে বন্ধ/বদল করবেন:</b> Android সেটিংস → গোপনীয়তা → বিজ্ঞাপন (Ads) → বিজ্ঞাপন আইডি মুছুন বা রিসেট করুন; অ্যাপের সেটিংস → \"বিজ্ঞাপনের গোপনীয়তা\" থেকে সম্মতি বদলান (যেখানে আইন অনুযায়ী দেখায়); অথবা প্রিমিয়াম/বিজনেস প্ল্যানে কোনো বিজ্ঞাপনই নেই।",
          "<b>How to opt out or change:</b> Android Settings → Privacy → Ads → delete or reset your Advertising ID; change your consent in the app's Settings → \"Ads privacy\" (shown where the law requires it); or use Premium/Business, which have no ads at all."))),
    S("sharing", "কার সাথে তথ্য শেয়ার হয়", "Who we share information with",
      P("আমরা কাউকে আপনার তথ্য বিক্রি করি না, ভাড়াও দিই না। তথ্য শুধু এই ক্ষেত্রে যায়:",
        "We never sell or rent your information. It only goes to:"),
      UL(("<b>আপনি যাদের বেছে নেন:</b> আপনার সার্কেল/পরিবার, Safe Journey-র পর্যবেক্ষক, SOS-এর বিশ্বস্ত পরিচিতজন, যাদের বার্তা পাঠান।",
          "<b>People you choose:</b> your circle/family, Safe Journey watchers, SOS trusted contacts, the people you message."),
         ("<b>Google Firebase Cloud Messaging:</b> পুশ নোটিফিকেশন পৌঁছাতে (ডিভাইস টোকেন ও নোটিফিকেশনের লেখা)।",
          "<b>Google Firebase Cloud Messaging:</b> to deliver push notifications (device token and notification text)."),
         ("<b>Google Firebase Crashlytics:</b> অ্যাপ ক্র্যাশ ও ত্রুটির প্রযুক্তিগত তথ্য (ত্রুটির ধরন, কোডের জায়গা, ফোনের মডেল ও Android ভার্সন, একটি ছদ্মনাম আইডি) — শুধু সাইন-ইন ও শুরুর ধাপ শেষ হওয়ার পরে; মেসেজ, নাম বা নম্বর পাঠানো হয় না।",
          "<b>Google Firebase Crashlytics:</b> technical details of app crashes and errors (error type, code location, phone model and Android version, a pseudonymous id) — only after you sign in and finish the first-run steps; never messages, names or numbers."),
         ("<b>Google AdMob:</b> শুধু ফ্রি প্ল্যানের বিজ্ঞাপন — Advertising ID, IP ঠিকানা, ডিভাইস তথ্য ও বিজ্ঞাপন দেখা/ট্যাপের তথ্য; উপরের \"বিজ্ঞাপন\" অংশ দেখুন।", "<b>Google AdMob:</b> Free-plan ads only — Advertising ID, IP address, device information and ad views/taps; see \"Advertising\" above."),
         ("<b>AI প্রদানকারী</b> (Anthropic, OpenAI, Google Gemini, Replicate): শুধু আপনি AI ফিচার ব্যবহার করলে।",
          "<b>AI providers</b> (Anthropic, OpenAI, Google Gemini, Replicate): only when you use an AI feature."),
         ("<b>SMS গেটওয়ে</b> (বাংলাদেশি SMS প্রদানকারী): OTP ও SMS সতর্কবার্তা পাঠাতে — আপনার নম্বর ও বার্তার লেখা।",
          "<b>SMS gateway</b> (a Bangladeshi SMS provider): to send OTPs and SMS alerts — your number and the message text."),
         ("<b>\"Hey Assisto\" মডেল:</b> ফোনে ওয়েক-ওয়ার্ড চেনার ছোট মডেল ফাইল (open-source openWakeWord ভিত্তিক, আমাদের নিজস্ব) আমাদের সার্ভার থেকে নামানো হয়; আপনার অডিও কোথাও যায় না।",
          "<b>\"Hey Assisto\" wake-word model:</b> a small on-device model file (our own, built on open-source openWakeWord) is downloaded from our server; your audio is never sent."),
         ("<b>কল:</b> ভয়েস/ভিডিও কল সরাসরি দুই ফোনের মধ্যে (WebRTC) চলে; সম্ভব না হলে আমাদের নিজস্ব রিলে (TURN) সার্ভার দিয়ে — এনক্রিপ্টেড, রেকর্ড ছাড়া।",
          "<b>Calls:</b> voice/video calls run directly between the two phones (WebRTC); when that isn't possible, through our own relay (TURN) server — encrypted, never recorded."),
         ("<b>আপনি নিজে যুক্ত করেন এমন সার্ভিস:</b> যেমন WhatsApp Business/Facebook/Instagram, Telegram, কুরিয়ার, পেমেন্ট প্রদানকারী — শুধু আপনি সংযোগ দিলে, সেই কাজের জন্য।",
          "<b>Services you connect yourself:</b> e.g. WhatsApp Business/Facebook/Instagram, Telegram, couriers, payment providers — only if you connect them, for that task."),
         ("<b>হোস্টিং:</b> আমাদের সার্ভার — {hosting}।", "<b>Hosting:</b> our servers — {hosting}."),
         ("<b>আইনগত কারণে:</b> বৈধ আইনি অনুরোধ, অথবা কারও জীবন বা নিরাপত্তা রক্ষায় প্রয়োজন হলে।",
          "<b>Legal reasons:</b> a valid legal request, or when needed to protect someone's life or safety."))),
    S("cctv", "সিসিটিভি ওয়াচম্যান (বাড়ি ও দোকান)", "CCTV watchman (home and shop)",
      P("আপনি নিজের বাড়ি বা দোকানের ক্যামেরা যুক্ত করলে, ক্যামেরার ভিডিও আপনার গেটওয়েতেই (পুরনো ফোন, Shop Box বা আপনার কম্পিউটার) থাকে ও সেখানেই বিশ্লেষণ হয়। "
        "আমাদের সার্ভারে <b>কখনো ভিডিও রাখা হয় না</b> — ভিডিও আপলোড সার্ভার গ্রহণই করে না।",
        "When you connect cameras at your own home or shop, the camera video stays on your gateway (an old phone, the Shop Box or your computer) and is analysed there. "
        "Our server <b>never keeps video</b> — it does not even accept a video upload."),
      UL(("<b>যা আমাদের সার্ভারে আসে:</b> কোনো কিছু সন্দেহজনক মনে হলে ঘটনার ধরন, সময়, আত্মবিশ্বাসের সংখ্যা এবং প্রতি ঘটনায় <b>একটি ছোট স্থির ছবি (স্ন্যাপশট)</b>; জোন আঁকার জন্য ক্যামেরা-পরীক্ষার একটি ছবি; ক্যামেরার নাম, ব্র্যান্ড ও নেটওয়ার্ক ঠিকানা (IP)। ক্যামেরার পাসওয়ার্ড/সেফটি কোড একবার আপনার গেটওয়েতে পৌঁছে দেওয়া হয়, তারপর আমাদের সার্ভার থেকে মুছে যায়।",
          "<b>What reaches our server:</b> when something looks unusual, the event type, time, a confidence number and <b>one small still photo (snapshot)</b> per event; one still from the camera check for drawing zones; the camera's name, brand and network address (IP). The camera password / safety code is handed to your gateway once and then deleted from our server."),
         ("<b>কতদিন:</b> স্ন্যাপশট আপনার বেছে নেওয়া সময় পর্যন্ত (০–৩০ দিন, নতুন জায়গায় ডিফল্ট ৩ দিন), তারপর প্রতিদিনের পরিষ্কারে মুছে যায়; ০ দিলে কোনো ছবিই রাখা হয় না। ঘটনার লেখা-তথ্য (ছবি ছাড়া) অ্যাকাউন্ট থাকা পর্যন্ত থাকে।",
          "<b>How long:</b> snapshots are kept for the time you choose (0–30 days, 3 days by default for a new place), then removed by the daily clean-up; with 0 no photo is kept at all. The event text (without the photo) stays while the account exists."),
         ("<b>কে দেখে:</b> শুধু আপনি এবং যে পরিবারের সদস্যদের আপনি যোগ করেন (শুধু দেখার অনুমতি)। লাইভ ভিউ সরাসরি গেটওয়ে থেকে আপনার ফোনে যায় (প্রয়োজনে আমাদের রিলে দিয়ে, কিন্তু কখনো রেকর্ড হয় না)।",
          "<b>Who sees it:</b> only you and the family members you add (view-only). Live view goes straight from the gateway to your phone (through our relay when needed, but it is never recorded)."),
         ("<b>যা আমরা করি না:</b> মুখ চেনা নেই, শব্দ রেকর্ড নেই, কাউকে দোষী বলা নেই — প্রতিটি সতর্কতা শুধু \"সন্দেহজনক — একটু দেখে নিন\"। Imou ক্লাউড সতর্কতা চালু করলে ক্যামেরার নিজের অ্যালার্ম ও তার ছবি Imou থেকে আসে।",
          "<b>What we do not do:</b> no face recognition, no sound recording, no accusations — every alert only says \"Suspicious — please check\". If you turn on Imou cloud alarms, the camera's own alarm and its photo come from Imou."),
         ("<b>আপনার দায়িত্ব:</b> শুধু নিজের জায়গায় ক্যামেরা লাগান, কর্মচারী/অতিথিদের জানান (অ্যাপে নোটিশের নমুনা আছে), আর টয়লেট বা পোশাক বদলানোর জায়গার দিকে কখনো ক্যামেরা রাখবেন না।",
          "<b>Your part:</b> use cameras only at your own place, tell staff/visitors (the app has a notice template), and never point a camera at toilets or changing areas."))),
    S("booking", "অ্যাপয়েন্টমেন্ট বুকিং", "Appointment booking",
      P("কোনো ব্যবসার বুকিং-লিংক (lifeassisto.com/b/…), Assisto অ্যাপ বা ব্যবসার চ্যাট থেকে সময় বুক করলে আমরা বুকিংটি ওই ব্যবসার জন্য রাখি।",
        "When you book a time with a business through its booking link (lifeassisto.com/b/…), the Assisto app or the business' chat, we keep the booking for that business."),
      UL(("<b>যা রাখা হয়:</b> আপনার নাম, মোবাইল নম্বর, বেছে নেওয়া সেবা ও সময়, বুকিংয়ের অবস্থা (অনুরোধ, নিশ্চিত, সম্পন্ন, আসেননি, বাতিল) ও ইতিহাস, আর অপব্যবহার ঠেকাতে IP ঠিকানার একটি হ্যাশ (আসল IP নয়)।",
          "<b>What is kept:</b> your name, mobile number, the service and time you chose, the booking's status (requested, confirmed, done, no-show, cancelled) and its history, and a hash of your IP address (not the IP itself) to stop abuse."),
         ("<b>কে দেখে:</b> শুধু যে ব্যবসায় বুক করেছেন সেই ব্যবসা (মালিক ও তাদের কর্মী)। আপনার নম্বর অন্য কোনো ব্যবসা বা ব্যবহারকারী দেখেন না। ব্যবসা Assisto CRM ব্যবহার করলে বুকিংটি তাদের গ্রাহক-তালিকায় যোগ হতে পারে।",
          "<b>Who sees it:</b> only the business you booked with (the owner and their staff). No other business or user sees your number. If the business uses the Assisto CRM, the booking may be added to its customer list."),
         ("<b>বার্তা:</b> শুধু আপনার বুকিং নিয়ে — নিশ্চিত, সময় বদল, বাতিল, আর সর্বোচ্চ ২টি রিমাইন্ডার (২৪ ঘণ্টা ও ২ ঘণ্টা আগে), রাত ১০টা থেকে সকাল ৮টার মধ্যে কখনো নয়। কোনো মার্কেটিং, বিজ্ঞাপন বা ঠান্ডা কল নয়। চ্যাটে STOP লিখলে বা বুকিং-পেজে “রিমাইন্ডার বন্ধ” চাপলে রিমাইন্ডার বন্ধ হয়।",
          "<b>Messages:</b> only about your booking — confirmed, moved, cancelled, and at most 2 reminders (24 hours and 2 hours before), never between 10 pm and 8 am. No marketing, ads or cold calls. Reply STOP in the chat or tap “Stop reminders” on the booking page to stop reminders."),
         ("<b>যাচাই:</b> অ্যাপে লগইন না করে বুক করলে নম্বর যাচাইয়ের জন্য একটি SMS কোড পাঠানো হয়।",
          "<b>Checking:</b> if you book without signing in to the app, we send one SMS code to check the number."),
         ("<b>কতদিন:</b> ব্যবসার অ্যাকাউন্ট থাকা পর্যন্ত, অথবা ব্যবসা বা আপনি মুছে ফেলতে বললে।",
          "<b>How long:</b> while the business' account exists, or until the business or you ask us to delete it."))),
    S("remittance", "বাজেট ও রেমিট্যান্স", "Budget and Remittance",
      P("বিদেশে থাকা আত্মীয়ের পাঠানো টাকা ও পরিবারের বাজেট আপনি নিজে লিখলে তবেই আমরা রাখি — শুধু আমাদের সার্ভারে।",
        "We keep the money your relative abroad sends and your family budget only when you write them down — on our server only."),
      UL(("<b>যা রাখা হয়:</b> পরিমাণ, মুদ্রা, আপনার আসলে পাওয়া রেট (আপনি নিজে লেখেন), টাকায় কত, তারিখ, কে পাঠাল (My Circle থেকে বা নাম), কোন বৈধ পথে (ব্যাংক, বিকাশ, নগদ, রকেট, Western Union, MoneyGram, অন্যান্য), নোট, প্রত্যাশিত মাসিক টাকা, বিল, বাজেটের পরিকল্পনা ও খরচ, সঞ্চয়-লক্ষ্য।",
          "<b>What is kept:</b> amount, currency, the rate you actually got (you type it), taka, date, who sent it (from My Circle or a name), which legal channel (bank, bKash, Nagad, Rocket, Western Union, MoneyGram, other), note, the expected monthly amount, bills, the budget plan and spending, and a savings goal."),
         ("<b>সুরক্ষা:</b> টাকার অংশ ও প্রেরকের নাম ডাটাবেসে এনক্রিপ্ট করে রাখা হয়। সত্যি কথা: চাবিটি একই সার্ভারে থাকে — তাই এটা ডাটাবেস বা ব্যাকআপ ফাঁস হলে রক্ষা করে, পুরো সার্ভার দখল হলে নয়।",
          "<b>Protection:</b> amounts and sender names are encrypted in the database. Honestly: the key is on the same server — so this protects a leaked database or backup, not a fully taken-over server."),
         ("<b>যা করি না:</b> SMS পড়ি না; মুখে বললে লেখায় বদলানো ফোনেই হয়, অডিও সার্ভারে আসে না। এই তথ্য বিজ্ঞাপন, পরিসংখ্যান বা AI-তে কখনো ব্যবহার হয় না, কারো সাথে শেয়ার বা বিক্রি হয় না।",
          "<b>What we do not do:</b> we never read SMS; voice becomes text on your phone and no audio reaches us. This data is never used for ads, analytics or AI, and never shared or sold."),
         ("<b>শেয়ার:</b> মাসিক রিপোর্ট শুধু আপনি “শেয়ার” চাপলে আপনার বেছে নেওয়া My Circle সদস্যের কাছে সাধারণ এনক্রিপ্টেড মেসেজ হিসেবে যায় — কখনো নিজে থেকে নয়।",
          "<b>Sharing:</b> the monthly report goes to the My Circle member you choose, as a normal encrypted message, only when you tap “Share” — never by itself."),
         ("<b>আপনার নিয়ন্ত্রণ:</b> অ্যাপ থেকেই সব ডাউনলোড (CSV বা লেখা) করতে ও সব মুছতে পারবেন; অ্যাকাউন্ট মুছলে এগুলোও মুছে যায়।",
          "<b>Your control:</b> download everything (CSV or text) and delete all of it from the app; deleting your account deletes it too."))),
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
         ("সিসিটিভি স্ন্যাপশট: আপনার বেছে নেওয়া ০–৩০ দিন (নতুন জায়গায় ডিফল্ট ৩ দিন)। ভিডিও: কখনো রাখা হয় না।",
          "CCTV snapshots: the 0–30 days you choose (3 days by default for a new place). Video: never kept."),
         ("অ্যাপ ক্র্যাশ ও ত্রুটির রিপোর্ট: আমাদের সার্ভারে ৩০ দিন।",
          "App crash and error reports: 30 days on our server."),
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
        "যাচাই হলে অ্যাপের মতোই ৭ দিনের অপেক্ষা শুরু হয়; অ্যাকাউন্টের মালিক অ্যাপে একটি নোটিশ পান, যেখান থেকে এক চাপে মুছে ফেলা বাতিল করা যায়, আর বিশ্বস্ত পরিচিতজনরা একটি সাধারণ নোটিশ পান। যাচাই না হলে কিছুই মোছা হয় না।",
        "Enter your account's mobile number or email in the form below. Nothing is deleted straight away — our team first checks the request really comes from the account owner (usually by calling/texting that number). "
        "Once verified, the same 7-day wait as in the app starts: the account owner gets an in-app notice with a one-tap \"Cancel deletion\" button, and their trusted contacts get a plain heads-up. If it can't be verified, nothing is deleted.")),
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
      P("অনুরোধের ৭ দিন পর প্রতি ঘণ্টার পরিষ্কার-প্রক্রিয়া অ্যাকাউন্টটি স্থায়ীভাবে মুছে দেয়। এর আগে অ্যাপে নোটিশ বা সেটিংস থেকে \"মুছে ফেলা বাতিল করুন\" চেপে, কিংবা আবার সাইন ইন করে বাতিল করা যায়। "
        "চুরি-সুরক্ষার সতর্কতা সক্রিয় থাকলে চোর যাতে আপনার ডেটা মুছতে না পারে, সেজন্য অনুরোধ আটকে থাকে।",
        "7 days after the request, an hourly clean-up permanently deletes the account. Before then you can cancel in the app — tap \"Cancel deletion\" in the notice or in Settings, or simply sign in again. "
        "While an anti-theft alert is active the request is blocked, so a thief can't wipe your data.")),
    S("contact", "কে আপনার অনুরোধ দেখে", "Who handles your request",
      UL(("প্রতিষ্ঠান: {entity}", "Company: {entity}"),
         ("ঠিকানা: {address}", "Address: {address}"),
         ("ইমেইল: {email}", "Email: {email}"),
         ("গোপনীয়তা অনুরোধের দায়িত্বে: {officer}", "Responsible for privacy requests: {officer}"))),
    S("data_only", "শুধু কিছু তথ্য মুছতে চান?", "Want to delete only some data?",
      P("অ্যাকাউন্ট না মুছেও অ্যাপের ভেতরে যেকোনো রিমাইন্ডার, নোট, হিসাব, ভল্টের ফাইল, বার্তা বা ছবি আলাদাভাবে মুছতে পারেন; চ্যাটে ডিসঅ্যাপিয়ারিং মেসেজও চালু করতে পারেন। অ্যাপ ছাড়া এমন অনুরোধ করতে নিচের ফর্মের \"কারণ\" ঘরে লিখুন।",
        "Without deleting the account you can delete any reminder, note, record, vault file, message or photo inside the app, and you can turn on disappearing messages in a chat. To ask for this without the app, write it in the \"Reason\" box of the form below.")),
]


# ---------------------------------------------------------------- refund (billing-v2, owner order 27 Oct, rule M)
REFUND = [
    S("google", "Google Play-র কেনাকাটা", "Google Play purchases",
      P("Google Play-তে কেনা প্ল্যান ও ক্রেডিট প্যাকের টাকা Google তার নিজের নিয়মে কেনার ৪৮ ঘণ্টার মধ্যে ফেরত দিতে পারে (play.google.com-এ \"Request a refund\")। Google টাকা ফেরত দিলে সেই কেনাকাটার প্ল্যান ও ক্রেডিট আমরা সরিয়ে দিই।",
        "Google may refund Google Play purchases of plans and credit packs within 48 hours under Google's own rules (\"Request a refund\" on play.google.com). When Google refunds a purchase, we remove the plan and credits that purchase gave.")),
    S("in_app", "অ্যাপ থেকে রিফান্ড চাওয়া", "Asking us for a refund in the app",
      UL(("কেনা বা নবায়নের {window_bn} ঘণ্টার মধ্যে অ্যাপের <b>প্ল্যান ও ক্রেডিট</b> বা <b>সাহায্য</b> স্ক্রিন থেকে \"রিফান্ড চান\" চেপে কারণ লিখে অনুরোধ করুন।",
          "Within {window} hours of a purchase or renewal, tap \"Request a refund\" on the <b>Plan &amp; credits</b> or <b>Help</b> screen and write the reason."),
         ("অনুরোধ নিজে থেকে টাকা ফেরত দেয় না; আমরা দেখে সিদ্ধান্ত নিই এবং অ্যাপে জানাই।",
          "A request does not refund by itself; we review it and tell you the decision in the app."),
         ("শুধু <b>অব্যবহৃত অংশ</b> ফেরত হয়: ব্যবহার করা ক্রেডিট ও ব্যবহার করা দিন ফেরত হয় না। প্রস্তাবিত পরিমাণ = দাম × (অব্যবহৃত ক্রেডিটের ভাগ ও অব্যবহৃত দিনের ভাগের মধ্যে যেটা কম)।",
          "Only the <b>unused part</b> is refunded: used credits and used days are not. The suggested amount = price × the lower of the unused-credits share and the unused-days share."))),
    S("after", "সময়সীমার পরে", "After the refund window",
      P("{window_bn} ঘণ্টার পরে রিফান্ড হয় না। ব্যতিক্রম শুধু দুটি, এবং মালিকের অনুমোদনে: একই কেনাকাটার জন্য দুবার টাকা কাটা (ডুপ্লিকেট চার্জ), অথবা আমাদের ভুলে টাকা দেওয়া কোনো ফিচার কাজ না করা।",
        "There is no refund after {window} hours. The only exceptions, with the owner's approval: a duplicate charge for the same purchase, or a paid feature that did not work because of our fault.")),
    S("cancel", "বাতিল করা রিফান্ড নয়", "Cancelling is not a refund",
      P("সাবস্ক্রিপশন বাতিল করলে পরের নবায়ন বন্ধ হয়; চলতি মেয়াদ শেষ পর্যন্ত প্ল্যান থাকে। বাতিল করা মানে রিফান্ড নয়।",
        "Cancelling a subscription stops the next renewal; the plan stays until the current period ends. Cancelling is not a refund.")),
    S("credits", "ক্রেডিট নিয়ে", "About credits",
      UL(("ক্রেডিট নগদ টাকা নয়, তোলা বা কাউকে দেওয়া যায় না।", "Credits are not cash and cannot be withdrawn or transferred."),
         ("প্ল্যানের মাসিক ক্রেডিট প্রতিটি মেয়াদ শেষে শেষ হয়ে যায়, পরের মাসে জমা হয় না। কেনা ক্রেডিট প্যাক কখনো শেষ হয় না।",
          "A plan's monthly credits end with each paid period and do not roll over. Bought credit packs never expire."),
         ("নতুন মেয়াদের শুরুতে প্ল্যানের ক্রেডিটের একটি অংশ সঙ্গে সঙ্গে পাওয়া যায়, বাকিটা কিছু সময় পরে নিজে থেকে খুলে যায়।",
          "At the start of each new paid period part of the plan credits is usable at once and the rest unlocks automatically a little later."),
         ("রিফান্ড হওয়া কেনাকাটার ক্রেডিট আগেই খরচ হয়ে থাকলে ব্যালান্স শূন্যের নিচে যেতে পারে; তখন শূন্যে না ফেরা পর্যন্ত ক্রেডিটের ফিচার বন্ধ থাকে।",
          "If credits from a refunded purchase were already spent, the balance can go below zero; credit features stay off until it is back to zero."))),
    S("abuse", "অপব্যবহার", "Abuse",
      P("বারবার রিফান্ড নিলে (যেমন দ্বিতীয় রিফান্ডের পরে) নতুন কেনাকাটা বা অ্যাকাউন্ট সীমিত করা হতে পারে।",
        "Repeated refunds (for example after a second refund) can lead to new purchases or the account being restricted.")),
    S("contact", "যোগাযোগ", "Contact",
      UL(("অ্যাপে: সেটিংস → সাহায্য / সমস্যা রিপোর্ট।", "In the app: Settings → Help / report a problem."),
         ("ইমেইল: {email}", "Email: {email}"),
         ("প্রতিষ্ঠান: {entity}", "Company: {entity}"))),
]


# ------------------------------------------------------- privacy v2 (preview)
# privacyupd (owner Play decision 7, 9 Nov): the NEXT privacy policy. It is
# served ONLY at /preview/privacy (noindex) until the owner says OK and flips
# the AdminFlagState switch "privacy_classic" OFF (Owner Admin → Website); then
# /privacy serves it. Built FROM the live PRIVACY above, so the live text stays
# byte-for-byte unchanged. Facts checked against the code (see
# owner_actions/PRIVACY_POLICY_PREVIEW_BN.md for sources and open questions).
LAST_UPDATED_V2 = "2026-11-09"   # AI providers, money from notifications, Care Call, train sharing, City Service trips, Silent Watch

_NOTIF_PERM = {
    "id": "notif_access",
    "perm": "BIND_NOTIFICATION_LISTENER_SERVICE",
    "name": ("নোটিফিকেশন অ্যাক্সেস (Notification access)", "Notification access"),
    "why": ("শুধু দুটি ঐচ্ছিক ফিচারের জন্য: \"নোটিফিকেশন থেকে টাকার হিসাব\" (ওয়ালেট/ব্যাংক অ্যাপের ও ব্যাংক/ওয়ালেট "
            "প্রেরকের SMS নোটিফিকেশন থেকে লেনদেন চেনা) এবং \"কলের পরে নোট\" (কল শেষ হয়েছে কি না — শুধু কল-নোটিফিকেশনের "
            "ধরন থেকে, নাম বা নম্বর না পড়ে)। অন্য সব নোটিফিকেশন খোলা হয় না, পড়াও হয় না। Assisto কখনো SMS-এর অনুমতি "
            "(READ_SMS) চায় না।",
            "Only for two optional features: \"Money from notifications\" (spotting transactions in notifications from "
            "wallet/bank apps and in SMS notifications from bank/wallet senders) and \"After-call note\" (noticing that a "
            "call ended — from the call notification's type only, without reading a name or number). Every other "
            "notification is ignored unread. Assisto never asks for the SMS permission (READ_SMS)."),
    "when": ("আপনি অ্যাপে এই ফিচার চালু করে ছোট ব্যাখ্যায় রাজি হলে Android নিজের সেটিংস পাতা খোলে, সেখানে আপনি অনুমতি দেন।",
             "Only after you turn one of these features on in the app and agree to a short explanation; Android then "
             "opens its own Settings page where you allow it."),
    "revoke": ("অ্যাপে ফিচারটি বন্ধ করুন, অথবা Android সেটিংস → অ্যাপ → বিশেষ অ্যাপ অ্যাক্সেস → নোটিফিকেশন অ্যাক্সেস → Assisto বন্ধ করুন।",
               "Turn the feature off in the app, or Android Settings → Apps → Special app access → Notification access "
               "→ Assisto."),
}
PERMISSIONS_V2 = PERMISSIONS + [_NOTIF_PERM]

_AI_V2 = S("ai", "AI ফিচার", "AI features",
    P("আপনি AI ফিচার (AI চ্যাট, ডকুমেন্ট/বিল পড়া, CV/স্ক্যাম বিশ্লেষণ, ফটো স্টুডিওর AI এডিট ইত্যাদি) ব্যবহার করলে শুধু সেই "
      "কাজের জন্য দরকারি লেখা বা ছবি আমাদের সার্ভার থেকে একটি AI প্রদানকারীর কাছে পাঠানো হয় এবং উত্তর ফেরত আসে।",
      "When you use an AI feature (AI chat, reading a document or bill, CV/scam analysis, Photo Studio AI edits and so "
      "on), only the text or image needed for that task is sent from our server to an AI provider, and the answer "
      "comes back."),
    UL(("<b>এখন:</b> Anthropic (Claude) — লেখা উত্তর ও ছবি বোঝার জন্য।",
        "<b>Now:</b> Anthropic (Claude) — for text answers and for understanding images."),
       ("<b>শুধু চালু করলে:</b> Google (Gemini) — এখন বন্ধ; আমরা চালু করলেই কেবল ব্যবহার হবে। আমাদের সার্ভার OpenAI ও "
        "ছবি এডিটের জন্য Replicate-ও সমর্থন করে, কিন্তু সেগুলোও শুধু আমরা চালু করলে ব্যবহার হয়। কোনো প্রদানকারী চালু বা "
        "বন্ধ হলে এই পাতা হালনাগাদ করা হবে।",
        "<b>Only when switched on:</b> Google (Gemini) — switched off now; it is used only if we switch it on. Our "
        "server also supports OpenAI and, for image edits, Replicate, but they too are used only if we switch them on. "
        "When a provider is switched on or off, this page is updated."),
       ("প্রদানকারীরা তাদের API শর্ত অনুযায়ী তথ্য প্রক্রিয়া করে। আপনার end-to-end এনক্রিপ্টেড বার্তা, কেয়ার কলের রেকর্ড "
        "করা গলা এবং নোটিফিকেশন থেকে পড়া লেনদেনের লেখা AI-তে কখনো যায় না।",
        "Providers process the data under their API terms. Your end-to-end encrypted messages, Care Call voice "
        "recordings and the text of notifications read for money are never sent to AI."),
       ("AI ভুল করতে পারে — গুরুত্বপূর্ণ সিদ্ধান্তের আগে যাচাই করুন। কোনো AI উত্তর আপত্তিকর, ক্ষতিকর বা ভুল মনে হলে অ্যাপে "
        "উত্তরের পাশের পতাকা চিহ্ন বা লম্বা চাপ দিয়ে সেটি রিপোর্ট করতে পারেন। রিপোর্টে থাকে শুধু উত্তরের লেখা (কোনো ছবি নয়), "
        "কারণ, আপনার ঐচ্ছিক মন্তব্য, আপনার অ্যাকাউন্ট ও সময়; Assisto টিম রিপোর্ট করা উত্তরগুলো পর্যালোচনা করে AI-এর ভুল ঠিক "
        "করতে ও অপব্যবহার ঠেকাতে।",
        "AI can be wrong — check before important decisions. If an AI answer seems offensive, harmful or wrong, you "
        "can report it in the app with the flag next to the answer or by long-pressing it. A report keeps only the "
        "text of the answer (never a photo), the reason, your optional note, your account and the time; the Assisto "
        "team reviews reported answers to fix AI mistakes and prevent misuse.")))

_MONEY_NOTIF = S("money_notif", "নোটিফিকেশন থেকে টাকার হিসাব", "Money from notifications",
    P("এটি বন্ধ থাকে, যতক্ষণ না আপনি অ্যাপে (\"কলের নোট ও টাকার হিসাব\") চালু করে ছোট ব্যাখ্যায় রাজি হন এবং Android সেটিংসে "
      "Assisto-কে \"নোটিফিকেশন অ্যাক্সেস\" দেন। Assisto কখনো SMS-এর অনুমতি (READ_SMS) চায় না এবং আপনার SMS ইনবক্স খোলে না।",
      "It stays off until you turn it on in the app (\"Call notes & money alerts\"), agree to a short explanation and "
      "give Assisto \"Notification access\" in Android settings. Assisto never asks for the SMS permission (READ_SMS) "
      "and never opens your SMS inbox."),
    UL(("<b>কী পড়া হয়:</b> শুধু এই ওয়ালেট ও ব্যাংক অ্যাপের নোটিফিকেশন — বিকাশ, নগদ, রকেট (DBBL), DBBL NexusPay, "
        "ইসলামী ব্যাংক CellFin, সিটি ব্যাংক Citytouch; এবং আপনার SMS অ্যাপ যে নোটিফিকেশন দেখায়, শুধু তখন যখন প্রেরক একটি "
        "নির্দিষ্ট ব্যাংক/ওয়ালেট প্রেরক আইডি (যেমন BKASH, NAGAD, 16216 বা কোনো ব্যাংকের নাম) — প্রেরক আগে মেলানো হয়। অন্য প্রেরক বা অন্য অ্যাপের "
        "নোটিফিকেশনের লেখা পড়াই হয় না। OTP, PIN ও প্রচারের বার্তা বাদ দেওয়া হয়।",
        "<b>What is read:</b> only notifications from these wallet and bank apps — bKash, Nagad, Rocket (DBBL), DBBL "
        "NexusPay, Islami Bank CellFin, City Bank Citytouch; and notifications your SMS app shows, only when the "
        "sender is one of a fixed list of bank/wallet sender ids (for example BKASH, NAGAD, 16216 or a bank's name) — the sender is checked first. "
        "The text of any other sender's or app's notification is never read. OTP, PIN and promotional messages are "
        "dropped."),
       ("<b>ফোনেই বোঝা হয়:</b> লেখা থেকে টাকার পরিমাণ, আয় না খরচ, ওয়ালেট, অন্য পক্ষ, TrxID ও তারিখ আপনার ফোনেই বের করা হয়। "
        "অপেক্ষমাণ বার্তা শুধু এই ফোনে অ্যাপের নিজস্ব জায়গায় থাকে — সর্বোচ্চ ৪০টি, ৩০ দিনের পুরনো হলে মুছে যায় — যতক্ষণ না আপনি "
        "সেভ বা বাদ দেন।",
        "<b>Understood on your phone:</b> the amount, income or expense, wallet, the other party, TrxID and date are "
        "worked out on your phone. Waiting messages stay only in the app's private storage on this phone — at most 40, "
        "removed once older than 30 days — until you save or dismiss them."),
       ("<b>কী পাঠানো হয়:</b> আপনি \"সেভ\" না চাপা পর্যন্ত (বা নিজে স্বয়ংক্রিয় সেভ চালু না করা পর্যন্ত) কিছুই না। তখন শুধু "
        "খাতার একটি এন্ট্রি আমাদের সার্ভারে যায়: পরিমাণ, আয়/খরচ, তারিখ, ওয়ালেট অ্যাকাউন্ট, ওয়ালেটের নাম ও অন্য পক্ষের নাম বা "
        "নম্বরসহ একটি নোট, এবং TrxID। পুরো বার্তার লেখা কখনো আমাদের সার্ভারে যায় না, AI-তে যায় না, বিজ্ঞাপনে ব্যবহার হয় না।",
        "<b>What is sent:</b> nothing until you tap Save (or turn on automatic saving yourself). Then only one khata "
        "entry goes to our server: amount, income/expense, date, the wallet account, a note with the wallet name and "
        "the other party's name or number, and the TrxID. The full message text is never sent to our server, never "
        "given to AI and never used for ads."),
       ("<b>সার্ভারের সুইচ:</b> ব্যাংক/ওয়ালেট প্রেরকের SMS নোটিফিকেশন পড়ার অংশটি আমরা সবার জন্য বন্ধ করতে পারি। বন্ধ থাকলে "
        "ফোন এগুলো না পড়েই উপেক্ষা করে এবং অপেক্ষমাণগুলো কিছু না পাঠিয়ে মুছে দেয় — পরের বার অ্যাপ খুললেই (খোলা থাকলে প্রতি "
        "৩ ঘণ্টায়ও দেখে) কার্যকর হয়। ওয়ালেট অ্যাপের নিজের নোটিফিকেশনে এর প্রভাব নেই।",
        "<b>Server switch:</b> we can turn off, for everyone, the part that reads SMS notifications from bank/wallet "
        "senders. While it is off, phones ignore them unread and delete waiting ones without sending anything — this "
        "takes effect the next time the app opens (and is re-checked every 3 hours while it is open). Notifications "
        "from the wallet apps themselves are not affected."),
       ("<b>আপনার নিয়ন্ত্রণ:</b> অ্যাপে যেকোনো সময় বন্ধ করুন (অপেক্ষমাণ বার্তা তখনই ফোন থেকে মুছে যায়) বা Android সেটিংসে "
        "নোটিফিকেশন অ্যাক্সেস তুলে নিন। সেভ করা এন্ট্রি অন্য যেকোনো এন্ট্রির মতো বদলানো বা মোছা যায়।",
        "<b>Your control:</b> turn it off in the app any time (waiting messages are deleted from the phone at once) "
        "or remove Notification access in Android settings. Saved entries can be edited or deleted like any other "
        "entry."),
       ("<b>কলের পরে নোট:</b> একই অ্যাক্সেস দিয়ে এই ঐচ্ছিক ফিচার শুধু বোঝে একটি কল শেষ হয়েছে (কল-নোটিফিকেশনের ধরন থেকে, নাম "
        "বা নম্বর না পড়ে) এবং নোট লেখার প্রস্তাব দেয়। কলের অডিও কখনো রেকর্ড হয় না।",
        "<b>After-call note:</b> with the same access this optional feature only notices that a call ended (from the "
        "call notification's type, without reading a name or number) and offers to write a note. Call audio is never "
        "recorded.")))

_CARECALL = S("carecall", "কেয়ার কল", "Care Call",
    P("কেয়ার কলে পরিবারের একজন (যিনি সেট করেন) প্রিয়জনের জন্য রিমাইন্ডার কল ঠিক করেন; প্রিয়জন একবার রাজি হলে তবেই তাঁর ফোনে "
      "কল বাজে, এবং তিনি যেকোনো সময় বন্ধ করতে পারেন।",
      "With Care Call a family member (the setter) schedules reminder calls for a loved one; the loved one's phone "
      "rings only after they have accepted Care Calls from that person once, and they can stop them any time."),
    UL(("<b>কী রেকর্ড হয়:</b> শুধু সেটার কেয়ার কল স্ক্রিনে ইচ্ছা করে যে ছোট বার্তা নিজের গলায় রেকর্ড করেন (ডিফল্ট সর্বোচ্চ "
        "৩০ সেকেন্ড)। প্রিয়জনের ফোন কিছুই রেকর্ড করে না, কলটিও রেকর্ড হয় না — তিনি শুধু \"হয়ে গেছে\" বা \"পরে মনে করাও\" "
        "চাপেন। রেকর্ড থেকে কোনো AI কণ্ঠ বানানো হয় না, রেকর্ড AI-তে যায় না।",
        "<b>What is recorded:</b> only the short message the setter records on purpose in their own voice on the Care "
        "Call screen (up to 30 seconds by default). The loved one's phone records nothing and the call itself is not "
        "recorded — they only tap Done or Snooze. No AI voice is made from the recording and it is never sent to AI."),
       ("<b>কে শোনেন:</b> শুধু সেটার নিজে এবং প্রিয়জন (যতক্ষণ তিনি সেই সেটারের কেয়ার কল গ্রহণ করে রেখেছেন)। আমাদের সার্ভার "
        "রেকর্ডটি শুধু এই দুজন সাইন-ইন করা মানুষকেই দেয়।",
        "<b>Who hears it:</b> only the setter and the loved one (while they accept Care Calls from that setter). Our "
        "server gives the recording only to these two signed-in people."),
       ("<b>কী রাখা হয়:</b> সময়সূচি, লেখা, রেকর্ড এবং প্রতিটি কলের ফল (হয়ে গেছে, পরে, ধরেননি) — যাতে সেটার \"নিশ্চিত\" বা "
        "\"ধরেননি\" দেখতে পান। ইন্টারনেট ছাড়াও যেন বাজে, তাই প্রিয়জনের ফোনে রেকর্ডটির একটি কপি অ্যাপের নিজস্ব জায়গায় থাকে।",
        "<b>What is kept:</b> the schedule, the text, the recording and each ring's result (done, snoozed, missed) — "
        "so the setter can see \"confirmed\" or \"did not answer\". So that it can ring without internet, the loved "
        "one's phone keeps a copy of the recording in the app's private storage."),
       ("<b>কতদিন:</b> সেটার রেকর্ড বদলানো বা মোছা, কেয়ার কলটি মোছা, বা দুজনের কেউ অ্যাকাউন্ট মোছা পর্যন্ত। প্রিয়জন কেয়ার কল "
        "বন্ধ করলে অপেক্ষমাণ কল তখনই বাতিল হয়।",
        "<b>How long:</b> until the setter replaces or deletes the recording, deletes the Care Call, or either person "
        "deletes their account. If the loved one stops Care Calls, waiting rings are cancelled at once.")))

_TRAIN = S("train", "ট্রেন শেয়ারিং (ট্রেন ট্র্যাকার)", "Train sharing (Train Tracker)",
    P("যাত্রীরা \"আমি এই ট্রেনে আছি\" শেয়ার করলে পথের সবাই ট্রেনটি কোথায় আছে দেখতে পান।",
      "When passengers share \"I am on this train\", everyone on the route can see where the train is."),
    UL(("<b>সম্মতি:</b> আপনি \"শেয়ার\" চেপে রাজি হলে তবেই শুরু হয়; শুধু শেয়ার চালু থাকা অবস্থায় চলে, একটি নোটিফিকেশন ও "
        "\"বন্ধ\" বোতামসহ, এবং পৌঁছালে বা যাত্রা শেষে নিজে থেকে থেমে যায়।",
        "<b>Consent:</b> it starts only when you tap Share and agree; it runs only while sharing is on, with a "
        "notification and a Stop button, and stops by itself on arrival or at the end of the trip."),
       ("<b>কী পাঠানো হয়:</b> ফোনের GPS অবস্থান, গতি ও সময়, ছোট ছোট দলে। সার্ভার প্রতিটি অবস্থান রেললাইন ও সময়সূচির সাথে "
        "মিলিয়ে দেখে এবং শুধু আপনার শেষ গ্রহণযোগ্য অবস্থানটি রাখে — কোনো পথরেখা নয়।",
        "<b>What is sent:</b> your phone's GPS position, speed and time, in small batches. The server checks each fix "
        "against the rail line and the timetable and keeps only your latest accepted position — no track."),
       ("<b>বেনামি:</b> অন্যরা দেখেন একটি মিলিত ট্রেন-অবস্থান ও কতজন শেয়ার করছেন — আপনি কে, তা কখনো না। ট্রেনের চ্যাটে শুধু "
        "ডাকনাম দেখা যায়; নাম, নম্বর বা প্রোফাইল নয়।",
        "<b>Anonymous:</b> others see one combined train position and how many people share — never who you are. The "
        "train chat shows nicknames only; no name, number or profile."),
       ("<b>কতদিন:</b> আপনার শেয়ার, ট্রেনের চ্যাট ও রুম সময়সূচি অনুযায়ী পৌঁছানোর ৬ ঘণ্টা পরে মুছে যায়। অপব্যবহার সামলাতে "
        "রিপোর্ট করা চ্যাট-বার্তা ৩০ দিন রাখা হয়।",
        "<b>How long:</b> your share, the train's chat and its room are deleted 6 hours after the timetable arrival. "
        "Reported chat messages are kept for 30 days to deal with abuse.")))

_CITY_TRIPS = S("city_trips", "সিটি সার্ভিস: যাত্রা থেকে শেখা", "City Service: learning from trips",
    P("বাসের রুট, স্টপ ও আসল যাত্রার সময় জানতে সিটি সার্ভিস যাত্রীদের যাত্রা থেকে শেখে — শুধু আপনি রাজি হলে।",
      "To learn bus routes, stops and real travel times, City Service learns from passengers' trips — only if you "
      "agree."),
    UL(("<b>কখন:</b> শুধু আপনি সম্মতির পাতায় রাজি হলে, শুধু সিটি সার্ভিস থেকে শুরু করা যাত্রায়, শুধু বাস বা লেগুনার অংশে, এবং "
        "শুধু যাত্রার পাতা খোলা থাকা অবস্থায়। ব্যাকগ্রাউন্ডে কখনো নয়, কোনো নতুন অনুমতি লাগে না।",
        "<b>When:</b> only after you agree on the consent sheet, only on a journey started from City Service, only on "
        "its bus or leguna part, and only while the journey screen is open. Never in the background; no extra "
        "permission is used."),
       ("<b>কী পাঠানো হয়:</b> সেই যাত্রার GPS বিন্দু — প্রতি ১৫ সেকেন্ডে একটি (সময় ও অবস্থান), যাত্রা শেষে একবারে। আপনার বাসা ও "
        "গন্তব্য যেন না থাকে, তাই প্রথম ও শেষ ৩০০ মিটার সার্ভারে পৌঁছানোর সাথে সাথেই কেটে ফেলা হয়।",
        "<b>What is sent:</b> the GPS points of that trip — one every 15 seconds (time and position), sent together. "
        "So that your home and destination are not kept, the first and last 300 m are cut off as soon as the trip "
        "reaches our server."),
       ("<b>নাম ছাড়া:</b> যাত্রা রাখা হয় আপনার অ্যাকাউন্ট থেকে বানানো একটি এলোমেলো-দেখতে কোডে — নাম বা নম্বরে নয় — এবং কাউকে "
        "দেখানো হয় না।",
        "<b>No names:</b> a trip is stored under a random-looking code made from your account — not your name or "
        "number — and is never shown to anyone."),
       ("<b>কতদিন:</b> যাত্রা প্রক্রিয়া হলেই (সাধারণত এক ঘণ্টার মধ্যে) GPS বিন্দু মুছে যায়, আর প্রতিটি যাত্রার রেকর্ড সর্বোচ্চ "
        "৭ দিনে মুছে যায়। থাকে শুধু যা শেখা হলো — একটি স্টপ, রাস্তার অংশ বা যাত্রার সময় — এবং অন্তত ৩ জন আলাদা মানুষের যাত্রা "
        "না মেলা পর্যন্ত তা \"যাত্রীদের জানানো\" হিসেবেই থাকে।",
        "<b>How long:</b> the GPS points are erased as soon as the trip has been processed (normally within an hour), "
        "and every trip record is deleted within 7 days. What remains is only what was learned — a stop, a road "
        "segment, a travel time — and it stays \"Reported by users\" until trips of at least 3 different people "
        "confirm it."),
       ("<b>কখনো নয়:</b> লোকেশন ডেটা বিক্রি বা শেয়ার করা হয় না। যেকোনো সময় বন্ধ করতে পারেন।",
        "<b>Never:</b> location data is never sold or shared. You can switch it off any time.")))

_SILENT_WATCH = S("silent_watch", "বয়স্কদের নীরব পাহারা (Silent Watch)", "Silent Watch for elders",
    P("ঐচ্ছিক। সন্তান সামনে বসে QR দিয়ে বয়স্ক মানুষের ফোন সেট করেন, আর বয়স্ক মানুষটি নিজে বাংলায় বলা সম্মতির পর্দায় "
      "\"হ্যাঁ\" বললে তবেই তাঁর ফোনে চালু হয়। এটি সবসময় ফ্রি, কোনো বিজ্ঞাপন নেই।",
      "Optional. A son or daughter sets up the elder's phone in person with a QR code, and it starts only after the "
      "elder says \"Yes\" on a spoken Bangla consent screen. Always free, never any ads."),
    UL(("<b>কোন সংকেত (শুধু ফোনে):</b> দিনের নির্ধারিত সময়ে প্রায় প্রতি ১৫ মিনিটে ফোন দেখে — স্ক্রিন জ্বলে আনলক আছে কি না, "
        "চার্জার লাগানো বা খোলা হয়েছে কি না, Assisto চলেছে কি না, এবং (যেখানে Android অনুমতি ছাড়াই দেয়) ফোন নড়েছে কি না। "
        "লোকেশন, মাইক্রোফোন, ক্যামেরা, বার্তা বা অন্য অ্যাপের ব্যবহার দেখা হয় না; কোনো নতুন অনুমতি লাগে না।",
        "<b>Which signals (on the phone only):</b> about every 15 minutes inside the elder's day window the phone checks "
        "whether it is in use (screen on and unlocked), whether the charger was plugged in or pulled out, whether "
        "Assisto ran and — where Android allows it without a permission — whether the phone moved. Location, "
        "microphone, camera, messages and other apps' use are not looked at; no extra permission is used."),
       ("<b>ফোনেই থাকে:</b> এই সংকেতের লগ (৮ দিন) আর বয়স্ক মানুষটির স্বাভাবিক দিন (৭ দিনে শেখা) শুধু ফোনেই থাকে। আমাদের "
        "সার্ভারে আনলকের সময়, অ্যাপ ব্যবহার বা কোনো নিয়মিত সংকেত যায় না।",
        "<b>Stays on the phone:</b> the signal log (8 days) and the elder's normal day (learned over 7 days) stay only "
        "on the phone. Our server never receives unlock times, app use or any regular check-in."),
       ("<b>কখন কী যায়:</b> অস্বাভাবিক নীরবতা হলে প্রথমে বয়স্ক মানুষটির ফোনে \"আপনি ঠিক আছেন?\" ৪ বার বাজে (৫ মিনিট পরপর)। "
        "কেউ সাড়া না দিলে তবেই ফোন সার্ভারে একটি খবর পাঠায় — কত মিনিট নীরব। কেয়ার কল বারবার না ধরলেও সার্ভার আগে বয়স্ক "
        "মানুষটিকে জিজ্ঞেস করে। তারপর ১৫ মিনিট পরপর: যে সন্তান সেট করেছেন → পুরো পরিবার → বেছে নেওয়া কাছের একজন।",
        "<b>What is sent and when:</b> after an unusual silence the elder's own phone first rings \"Are you OK?\" 4 "
        "times, 5 minutes apart. Only if nobody answers does the phone send one alert to our server — how many "
        "minutes it has been quiet. If Care Calls go unanswered, the server also asks the elder first. Then, 15 "
        "minutes apart: the child who set it up → all family → the chosen nearby person."),
       ("<b>নিয়ন্ত্রণ ও সংরক্ষণ:</b> \"আমি ঠিক আছি\" বা পরিবারের \"আমি দেখছি\" এক চাপেই থামায়; বয়স্ক মানুষটি বা সন্তান যেকোনো "
        "সময় বন্ধ করতে পারেন। সতর্কতার রেকর্ড (কখন, কতক্ষণ নীরব, কাকে জানানো হলো, কে সাড়া দিলেন) ৯০ দিন রাখা হয়, "
        "যাতে পরিবার ইতিহাস দেখতে পারে; নীরব পাহারা বন্ধ করলে বা পরিবার ছাড়লে সঙ্গে সঙ্গে মুছে যায়।",
        "<b>Control and retention:</b> \"I am OK\" or a family member's \"I am checking\" stops it in one tap; the elder "
        "or the child can turn it off any time. Alert records (when, how long it was quiet, who was told, who "
        "answered) are kept 90 days so the family can see the history, and are deleted at once when Silent Watch is "
        "turned off or the setter leaves the family.")))

_SUMMARY_V2 = (
    "Assisto কখনো SMS-এর অনুমতি চায় না। \"নোটিফিকেশন থেকে টাকার হিসাব\" আপনি চালু করলে তবেই শুধু ওয়ালেট/ব্যাংকের বার্তা "
    "পড়ে, ফোনেই বোঝে, আর আপনি সেভ না করা পর্যন্ত কিছুই পাঠায় না।",
    "Assisto never asks for the SMS permission. \"Money from notifications\" reads only wallet/bank alerts, only after "
    "you turn it on, understands them on your phone and sends nothing until you save an entry.")

_SHARING_AI_V2 = ("<b>AI প্রদানকারী:</b> এখন Anthropic (Claude); Google Gemini, OpenAI বা Replicate শুধু আমরা চালু করলে — "
                  "এবং শুধু আপনি AI ফিচার ব্যবহার করলে।",
                  "<b>AI providers:</b> Anthropic (Claude) now; Google Gemini, OpenAI or Replicate only if we switch "
                  "them on — and only when you use an AI feature.")

_RETENTION_V2 = (
    ("নোটিফিকেশন থেকে টাকার হিসাব: অপেক্ষমাণ বার্তা শুধু ফোনে, সর্বোচ্চ ৪০টি ও ৩০ দিন; সেভ করা এন্ট্রি অন্য হিসাবের মতোই।",
     "Money from notifications: waiting messages only on the phone, at most 40 and 30 days; saved entries like any "
     "other record."),
    ("কেয়ার কলের রেকর্ড: সেটার মোছা, কেয়ার কল মোছা বা কারও অ্যাকাউন্ট মোছা পর্যন্ত।",
     "Care Call recordings: until the setter deletes it or the Care Call, or either account is deleted."),
    ("ট্রেন শেয়ার, চ্যাট ও রুম: সময়সূচি অনুযায়ী পৌঁছানোর ৬ ঘণ্টা পরে মুছে যায়; রিপোর্ট করা চ্যাট-বার্তা ৩০ দিন।",
     "Train shares, chat and rooms: deleted 6 hours after the timetable arrival; reported chat messages 30 days."),
    ("সিটি সার্ভিসের যাত্রা: GPS বিন্দু প্রক্রিয়ার পরেই (সাধারণত এক ঘণ্টার মধ্যে) মোছে; যাত্রার রেকর্ড সর্বোচ্চ ৭ দিন।",
     "City Service trips: GPS points erased right after processing (normally within an hour); trip records at most "
     "7 days."),
    ("নীরব পাহারা: সংকেতের লগ শুধু ফোনে ৮ দিন; সতর্কতার রেকর্ড ৯০ দিন, বন্ধ করলেই সঙ্গে সঙ্গে মোছা।",
     "Silent Watch: the signal log only on the phone, 8 days; alert records kept 90 days, deleted at once when Silent Watch is turned off."),
)


def _privacy_v2():
    """PRIVACY with the 9 Nov changes; PRIVACY itself is never modified."""
    out = []
    for s in PRIVACY:
        sid = s["id"]
        if sid == "ai":
            out.append(_AI_V2)
            continue
        blocks = [dict(b) for b in s["blocks"]]
        if sid == "summary":
            blocks[0]["items"] = blocks[0]["items"][:3] + [_SUMMARY_V2] + blocks[0]["items"][3:]
        elif sid == "permissions":
            blocks = [{"t": "perms", "v2": True} if b["t"] == "perms" else b for b in blocks]
        elif sid == "sharing":
            for b in blocks:
                if b["t"] == "ul":
                    b["items"] = [_SHARING_AI_V2 if "<b>AI providers</b>" in it[1] else it for it in b["items"]]
        elif sid == "retention":
            for b in blocks:
                if b["t"] == "ul":
                    b["items"] = b["items"][:-1] + list(_RETENTION_V2) + b["items"][-1:]
        out.append({"id": sid, "h": s["h"], "blocks": blocks})
        if sid == "remittance":
            out += [_MONEY_NOTIF, _CARECALL, _TRAIN, _CITY_TRIPS, _SILENT_WATCH]
    return out


PRIVACY_V2 = _privacy_v2()


PAGES = {
    "privacy": {"path": "/privacy", "sections": PRIVACY,
                "title": ("গোপনীয়তা নীতি", "Privacy Policy"),
                "desc": ("Assisto কী তথ্য রাখে, কেন, কার সাথে শেয়ার হয়, প্রতিটি অ্যাপ অনুমতির কারণ, বিজ্ঞাপন, সংরক্ষণকাল ও মোছার উপায়।",
                         "What Assisto stores, why, who it is shared with, the reason for every app permission, ads, retention and how to delete.")},
    # privacyupd: preview-only until the owner turns privacy_classic OFF
    "privacy_v2": {"path": "/privacy", "sections": PRIVACY_V2, "updated": LAST_UPDATED_V2,
                   "title": ("গোপনীয়তা নীতি", "Privacy Policy"),
                   "desc": ("Assisto কী তথ্য রাখে, কেন, কার সাথে শেয়ার হয়, প্রতিটি অ্যাপ অনুমতির কারণ, বিজ্ঞাপন, সংরক্ষণকাল ও মোছার উপায়।",
                            "What Assisto stores, why, who it is shared with, the reason for every app permission, ads, retention and how to delete.")},
    "terms": {"path": "/terms", "sections": TERMS,
              "title": ("ব্যবহারের শর্তাবলী", "Terms of Service"),
              "desc": ("Assisto অ্যাপ ও lifeassisto.com ব্যবহারের শর্তাবলী।", "The terms for using the Assisto app and lifeassisto.com.")},
    "refund": {"path": "/refund-policy", "sections": REFUND,
               "title": ("রিফান্ড নীতি", "Refund policy"),
               "desc": ("Assisto-র প্ল্যান ও ক্রেডিট প্যাকের রিফান্ড: কখন, কতটা, কীভাবে চাইবেন।",
                        "Refunds for Assisto plans and credit packs: when, how much and how to ask.")},
    "deletion": {"path": "/delete-account", "sections": DELETION,
                 "title": ("অ্যাকাউন্ট ও ডেটা মুছে ফেলা", "Delete your account and data"),
                 "desc": ("অ্যাপ থেকে বা ওয়েবে অনুরোধ করে Assisto অ্যাকাউন্ট ও সব ডেটা মুছুন — কী মুছবে, কী থাকবে, কত দিনে।",
                          "Delete your Assisto account and all data from the app or by web request — what is deleted, what remains, and when.")},
}


def _refund_window():
    """billing-v2: the owner-editable refund window (24 or 48 h)."""
    try:
        from core import credits as CR
        w = int(CR.bcfg()["refund_window_hours"])
    except Exception:
        w = 48
    return {"window": w, "window_bn": str(w).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))}


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
                    for p in (PERMISSIONS_V2 if b.get("v2") else PERMISSIONS)]})
        out.append({"id": s["id"], "heading": s["h"][i], "blocks": blocks})
    return out
