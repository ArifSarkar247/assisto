"""
Assisto offline app-help knowledge base (L2).

Concise, hand-written bn/en answers to "how do I use X" questions, each with the
screen route the app should offer to open. NO AI needed — this is deterministic,
honest, and sourced to the app itself. Entries are matched by keyword against the
user's question (Bangla / Banglish / English).

Keep answers short and true to what the app actually does. If you don't know the
answer, it is NOT here — Brain will escalate honestly instead of inventing one.
"""
from ..i18n import pick

# Each entry: keyword triggers (lowercased substrings, bn + banglish + en) and a
# bilingual answer + the screen route to offer. `route` matches the app's
# ChatNav route vocabulary (same as screen_synonyms.resolve output).
_ENTRIES = [
    {
        "id": "reminder",
        "route": "reminders",
        "kw": ["reminder", "রিমাইন্ডার", "মনে করিয়ে", "alarm", "অ্যালার্ম",
               "rimaindar", "mone koriye", "reminder set", "set korbo",
               "reminder kivabe", "reminder kibhabe"],
        "bn": ("রিমাইন্ডার সেট করতে: চ্যাটে লিখুন বা বলুন — যেমন "
               "'কাল সকাল ৮টায় মিটিং মনে করিয়ে দিও'। সময় বুঝতে পারলে আমি "
               "নিজেই রিমাইন্ডার বানিয়ে দেব। রিমাইন্ডার স্ক্রিন থেকেও হাতে যোগ করা যায়।"),
        "en": ("To set a reminder, just type or say it in chat — e.g. "
               "'remind me about the meeting at 8am tomorrow'. If I understand the "
               "time I'll create it for you. You can also add one by hand from the "
               "Reminders screen."),
    },
    {
        "id": "sos",
        "route": "safety",
        "kw": ["sos", "এসওএস", "এস ও এস", "বিপদ", "safety", "safe arrival",
               "emergency", "জরুরি", "জরুরী", "sos kivabe", "sos kaj", "panic"],
        "bn": ("SOS: বিপদে পড়লে Safety স্ক্রিন থেকে SOS চাপুন — আপনার Circle-এর "
               "নির্বাচিত সদস্যদের কাছে আপনার অবস্থান ও বার্তা যাবে। 'নিরাপদে পৌঁছেছি' "
               "টাইমার দিয়ে যাত্রা শেয়ার করলে সময়মতো না পৌঁছালে পরিবারকে সতর্ক করা হয়।"),
        "en": ("SOS: in danger, open the Safety screen and press SOS — your chosen "
               "Circle members get your location and message. A 'safe arrival' timer "
               "alerts your family if you don't reach on time."),
    },
    {
        "id": "expense",
        "route": "money",
        "kw": ["expense", "খরচ", "khoroch", "taka add", "টাকা যোগ", "money add",
               "hisab", "হিসাব", "khoroch likhbo", "expense add", "spending"],
        "bn": ("খরচ লিখতে চ্যাটে সরাসরি বলুন — যেমন '৫০০ টাকা বাজার' বা "
               "'৩০০ টাকা খরচ খাবার'। আমি তা Money-তে লিখে রাখব। মাসের মোট, "
               "ব্যালেন্স ও বাজেট Money স্ক্রিনে দেখা যায়।"),
        "en": ("To log an expense, just say it in chat — e.g. '500 taka bazar' or "
               "'spent 300 on food'. I'll record it in Money. Your monthly total, "
               "balance and budgets live on the Money screen."),
    },
    {
        "id": "document",
        "route": "documents",
        "kw": ["document", "ডকুমেন্ট", "vault", "ভল্ট", "passport rakhbo",
               "nid", "dolil", "দলিল", "kagoj", "কাগজ", "document rakhbo"],
        "bn": ("গুরুত্বপূর্ণ কাগজ (NID, পাসপোর্ট, সার্টিফিকেট) Documents ভল্টে রাখুন — "
               "মেয়াদের তারিখ দিলে শেষ হওয়ার আগে মনে করিয়ে দেব। ফাইল শুধু আপনিই দেখতে পাবেন।"),
        "en": ("Keep important papers (NID, passport, certificates) in the Documents "
               "vault — add an expiry date and I'll remind you before it lapses. "
               "Files are visible only to you."),
    },
    {
        "id": "medicine",
        "route": "medicine",
        "kw": ["medicine", "ওষুধ", "osudh", "medicine reminder", "dose",
               "ওষুধ মনে", "osudh add", "pill"],
        "bn": ("ওষুধ যোগ করতে বলুন — যেমন 'ওষুধ নাপা সকাল ৮টা'। সময় দিলে প্রতিদিন "
               "মনে করিয়ে দেব এবং স্টক কমে এলে রিফিল অ্যালার্ট দেব। Medicine স্ক্রিনে বিস্তারিত।"),
        "en": ("To add a medicine, say e.g. 'medicine Napa at 8am'. Give a time and "
               "I'll remind you daily and warn you to refill when stock runs low. "
               "See the Medicine screen for details."),
    },
    {
        "id": "circle",
        "route": "circle",
        "kw": ["circle", "সার্কেল", "family add", "পরিবার যোগ", "connect",
               "circle add", "relative add", "member add", "circle kivabe"],
        "bn": ("Connected Circle-এ পরিবার/বন্ধুকে যোগ করুন — তারা আপনার নিরাপত্তা "
               "অ্যালার্ট পাবে এবং আপনি তাদের। যোগ করতে Circle স্ক্রিনে গিয়ে অনুরোধ পাঠান।"),
        "en": ("Add family or friends to your Connected Circle — they get your safety "
               "alerts and you get theirs. Send a request from the Circle screen."),
    },
    {
        "id": "ai_key",
        "route": "settings",
        "kw": ["ai key", "api key", "ai chalu", "ai on", "ai enable",
               "ai assistant", "key add", "chatbot", "ai kobe"],
        "bn": ("বড় প্রশ্নের জন্য AI সহকারী চালু হয় যখন মালিক একটি AI key যোগ করেন। "
               "তখন আমি সাধারণ জ্ঞানের প্রশ্নেরও উত্তর দিতে পারব। এখনও আপনার নিজের ডেটা "
               "ও অ্যাপ নিয়ে সব প্রশ্নের উত্তর দিতে পারি।"),
        "en": ("The AI assistant for broad questions turns on once the owner adds an "
               "AI key. Then I can answer general-knowledge questions too. Even now I "
               "can answer anything about YOUR own data and the app."),
    },
]


def _norm(s):
    return (s or "").lower().strip()


def match(text, lang="bn"):
    """Return the best help entry for `text` as a dict
    {id, route, answer} localised to `lang`, or None if nothing matches."""
    low = _norm(text)
    if not low:
        return None
    best = None
    best_hits = 0
    for e in _ENTRIES:
        hits = sum(1 for k in e["kw"] if k in low or k in text)
        if hits > best_hits:
            best, best_hits = e, hits
    if not best:
        return None
    return {"id": best["id"], "route": best["route"],
            "answer": pick(lang, best["bn"], best["en"])}


def all_topics(lang="bn"):
    """Every help topic (id + one-line answer + route) — used by tests and a
    future 'what can you do' listing."""
    return [{"id": e["id"], "route": e["route"],
             "answer": pick(lang, e["bn"], e["en"])} for e in _ENTRIES]
