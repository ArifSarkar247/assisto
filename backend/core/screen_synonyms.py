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
        "আমার হিসাব", "হিসাব", "জীবনের হিসাব", "টাকা", "টাকা পয়সা", "খরচ", "আয় খরচ",
        "my account", "money", "finance", "expense", "expenses", "budget", "wallet",
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
