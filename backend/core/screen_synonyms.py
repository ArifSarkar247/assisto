"""
Canonical synonym -> screen-route map for "open the right screen from chat".

Owner renamed modules (My Account / Documents), but chat must still understand the
old and natural words. This is INPUT vocabulary (what the user may type/say), not
user-facing output, so it is intentionally bilingual. The AI command layer and the
in-app open-from-chat feature (Phase B) both resolve against this map.

resolve("আমার হিসাব দেখাও") -> "money";  resolve("show my docs") -> "documents"
"""

SCREEN_SYNONYMS = {
    # route : natural/old/new words the user might use (bn + en), lowercased
    "money": [
        "আমার হিসাব", "হিসাব", "জীবনের হিসাব", "আমার একাউন্ট", "একাউন্ট", "অ্যাকাউন্ট",
        "টাকা", "টাকা পয়সা", "খরচ", "আয় খরচ",
        "my account", "account", "money", "finance", "expense", "expenses", "budget", "wallet",
    ],
    "documents": [
        "ডকুমেন্টস", "ডকুমেন্ট", "কাগজপত্র", "কাগজ", "ভল্ট", "নথি",
        "documents", "docs", "vault", "papers", "files",
    ],
    "family": [
        "পরিবার", "ফ্যামিলি", "ওষুধ", "আম্মুর ওষুধ", "আব্বুর ওষুধ", "medicine", "medicines",
        "family", "family care", "mom's medicine", "dad's medicine",
    ],
    "reminders": ["রিমাইন্ডার", "মনে করিয়ে", "অ্যালার্ম", "reminder", "reminders", "remind me"],
    "emergency": ["ইমার্জেন্সি", "জরুরি", "sos", "emergency", "help"],
    "plans": ["প্ল্যান", "প্রিমিয়াম", "আপগ্রেড", "সাবস্ক্রিপশন প্ল্যান", "plans", "premium", "upgrade", "pricing", "subscription plan"],
    "scam": ["প্রতারণা", "স্ক্যাম", "ফ্রড", "scam", "fraud", "scam check", "is this a scam"],
    "safety": ["নিরাপত্তা", "সেফটি", "পৌঁছেছি", "safety", "safe arrival", "check-in", "checkin"],
    "crm": ["সেলস", "সিআরএম", "পাইপলাইন", "লিড", "sales crm", "crm", "pipeline", "leads", "sales"],
    # ----- module 5 (P13+) -----
    "medicine_db": ["ওষুধের তথ্য", "ওষুধ খুঁজুন", "ওষুধের তথ্যভান্ডার",
                     "medicine database", "medicine info", "drug lookup"],
    "health_tips": ["স্বাস্থ্য টিপস", "স্বাস্থ্য পরামর্শ", "health tips", "health tip"],
    "birthdays": ["জন্মদিন", "বার্ষিকী", "স্মরণীয় দিন",
                   "birthdays", "birthday", "anniversary", "memorable days"],
    "meetings": ["মিটিং", "অ্যাপয়েন্টমেন্ট", "সাক্ষাৎ",
                  "meetings", "meeting", "appointments", "appointment"],
    "dictionary": ["অভিধান", "শব্দের অর্থ", "ডিকশনারি",
                    "dictionary", "word meaning", "translate word"],
    "ride_food": ["রাইড", "খাবার", "উবার", "পাঠাও", "ফুডপান্ডা",
                   "ride", "food", "uber", "pathao", "foodpanda"],
    "ramadan": ["রমজান", "সেহরি", "ইফতার", "নামাজের সময়",
                 "ramadan", "sehri", "iftar", "prayer times"],
    "exam": ["পরীক্ষার ফল", "ফলাফল", "রেজাল্ট",
              "exam result", "result", "exam"],
    "unseen": ["অদেখা বাংলাদেশ", "ভ্রমণ", "ঘুরতে যাওয়া", "পর্যটন",
                "unseen bangladesh", "travel", "destinations", "tourism"],
    "photo_enhance": ["ছবি উন্নত", "ছবি এনহ্যান্স", "ছবি ভালো করা",
                       "enhance photo", "photo enhance", "improve photo"],
    "circle": ["সার্কেল", "পরিবার সার্কেল", "পরিবার-বন্ধু",
                "connected circle", "circle", "family chat"],
    "legal": ["আইনি", "গোপনীয়তা নীতি", "নীতিমালা", "ব্যবহারের শর্ত",
               "legal", "privacy policy", "terms", "policies"],
    # ----- build-61 wave: every sidebar module is chat-openable -----
    "subscriptions": ["সাবস্ক্রিপশন", "নিয়মিত বিল", "subscriptions", "subscription", "recurring"],
    "finance": ["ফিন্যান্স টুল", "ঋণ", "সঞ্চয়", "finance tools", "loan", "savings", "calculator"],
    "notes": ["নোট", "টাস্ক", "কাজের তালিকা", "notes", "tasks", "todo", "to-do", "note"],
    "memory": ["মেমোরি", "এআই যা জানে", "মনে রাখা", "memory", "ai knows", "remember"],
    "nominee": ["নমিনি", "উত্তরাধিকার", "nominee", "nominee access", "inheritance"],
    "contacts": ["কন্টাক্টস", "কন্টাক্ট", "ফোনবুক", "contacts", "contact", "phonebook"],
    "agent_studio": ["এজেন্ট স্টুডিও", "অটোমেশন", "agent studio", "agent", "automation"],
    "jobs": ["চাকরি", "জব হান্টার", "ক্যারিয়ার", "jobs", "job hunter", "career", "cv"],
    "inbox": ["এআই ইনবক্স", "ইনবক্স", "ai inbox", "inbox", "mail"],
    "guide": ["সরকারি সেবা", "সেবা গাইড", "government service", "service guide", "guide"],
    "nearby": ["কাছাকাছি", "আশেপাশে", "nearby", "around me", "places nearby"],
    "watch_feed": ["ওয়াচ ফিড", "সতর্কতা ফিড", "watch feed", "alerts feed", "watch alerts"],
    "business": ["ব্যবসা", "দোকান", "অর্ডার", "business", "shop", "store", "orders"],
    "bargain_rules": ["দরদাম", "দরদামের নিয়ম", "দর কষাকষি", "সর্বনিম্ন দাম", "ছাড়ের নিয়ম",
                       "bargaining rules", "bargain rules", "bargaining", "bargain",
                       "price floor", "minimum price", "discount rules", "negotiation rules"],
    "business_plans": ["বিজনেস প্ল্যান", "ব্যবসার প্ল্যান", "ফ্রি বনাম প্রিমিয়াম",
                        "business plans", "business plan", "free vs premium",
                        "upgrade business", "premium business", "plan comparison"],
    "journey": ["নিরাপদ যাত্রা", "যাত্রা", "লাইভ লোকেশন", "safe journey", "journey", "track me", "live location"],
    "referral": ["রেফারেল", "রেফার", "পয়েন্ট", "বন্ধু আমন্ত্রণ", "referral", "refer", "points", "invite friend"],
    "circle_privacy": ["প্রাইভেসি", "কল প্রাইভেসি", "ব্লক", "circle privacy", "privacy controls", "block"],
    "circle_calls": ["কল হিস্ট্রি", "কল লগ", "call history", "call log", "circle calls"],
    # ---- a3-voice ---- Part 3 Assisto Voice + its settings
    "voice_assistant": ["ভয়েস অ্যাসিস্ট্যান্ট", "অ্যাসিস্টো ভয়েস", "ভয়েস মোড", "হেই অ্যাসিস্টো",
                        "voice assistant", "assisto voice", "hey assisto", "voice mode", "talk to assisto"],
    "voice_settings": ["ডিফল্ট অ্যাসিস্ট্যান্ট", "ডিজিটাল অ্যাসিস্ট্যান্ট", "ওয়েক ওয়ার্ড",
                       "default assistant", "digital assistant", "wake word", "voice settings"],
    "vaultpin": [],  # reserved
}

# flattened lookup: word -> route (longer phrases win)
_INDEX = []
for _route, _words in SCREEN_SYNONYMS.items():
    for _w in _words:
        _INDEX.append((_w.lower(), _route))
_INDEX.sort(key=lambda t: -len(t[0]))


def resolve(text):
    """Return the best-matching screen route for a free-text chat phrase, or None."""
    if not text:
        return None
    t = text.lower()
    for word, route in _INDEX:
        if word and word in t:
            return route
    return None
