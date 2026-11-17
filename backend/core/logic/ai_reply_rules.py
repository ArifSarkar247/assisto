"""ai-reply-core (owner order 17 Nov): the PURE rules of AI reply — no DB,
no network, no logging of text.

* classify(text) -> category | ""   deterministic safety screen (first pass)
* detect_lang(text) -> "bn" | "roman" | "en"
* style_profile(samples) -> compact dict (numbers + allow-listed phrases;
  never a raw sentence)
* style_hint(profile) -> one short instruction line for the model
* parse_model(raw) -> (hold, category, replies) from the model's JSON
* busy_template(lang, until_label) -> a free fallback busy reply

Categories that make the AI HOLD a message (never answer it):
  otp       OTP / PIN / password / bank or card numbers (refused outright)
  sos       danger / help / SOS-like
  health    health emergency (hospital, accident, unconscious ...)
  money     money / payments / bKash / Nagad / loans
  address   address / location / where are you
  meet      meeting in person
  promise   promises / commitments
  decision  big life decisions (marriage, job, land, contracts ...)
"""
import json
import re
import unicodedata

CATEGORIES = ("otp", "sos", "health", "money", "address", "meet", "promise", "decision")
MODES = ("off", "suggest", "busy", "auto")
GROUP_MODES = ("off", "suggest")
BUSY_MINUTES = (30, 60, 120, 0)        # 0 = until I turn it off

# Limits (server-enforced; owner order D "rate limit")
AUTO_MIN_GAP_S = 30          # <= 1 auto reply per chat per 30 s
AUTO_PER_CHAT_HOUR = 10
AUTO_PER_USER_HOUR = 30
AUTO_PER_USER_DAY = 150
SUGGEST_PER_USER_HOUR = 60
SUGGEST_MIN_GAP_S = 2
STALE_INCOMING_S = 15 * 60   # an incoming message older than this gets no auto reply
LOOP_WINDOW = 6              # last N messages: alternating AI marks = a loop

TEXT_MAX = 1000
CONTEXT_MAX = 5
CONTEXT_LINE_MAX = 300
SAMPLES_MAX = 200
REPLY_MAX_CHARS = 160
OUT_TOKENS = 220

# --------------------------------------------------------------- patterns
# Latin / romanized: word-bounded. Bangla: plain substrings (Bangla vowel
# signs are not \w, so \b would split words).
_EN = {
    "otp": r"\b(otp|one[- ]?time ?(pass(word)?|code)|verification code|security code|pin( ?code| ?number)?|"
           r"password|passcode|cvv|cvc|card (no|number)|account (no|number)|a/c|bank account|routing number|"
           r"iban|swift|login code)\b|\bcode\b[^\n]{0,20}\b\d{4,8}\b|\b\d{4,8}\b[^\n]{0,20}\bcode\b",
    "sos": r"\b(sos|help me|save me|emergency|danger|kidnap(ped)?|attack(ed)?|rape|harass(ed|ing)?|"
           r"bachao|bacao|bipod|bipode|joruri)\b",
    "health": r"\b(hospital|haspatal|ambulance|accident|injur(ed|y)|bleeding|unconscious|fainted|"
              r"heart attack|stroke|chest pain|can'?t breathe|overdose|suicide|kill (my|him|her)self|"
              r"dying|poison(ed)?|oggan|ojnan|ajnan|attohotta|accidnt)\b",
    "money": r"\b(money|taka|tk|bdt|usd|dollars?|payments?|pay|paid|paying|loan|lend|borrow|debt|owe|"
             r"bkash|bikash|nagad|rocket|upay|transfer|cash|invoice|bill|price|cost|rent|salary|fees?|"
             r"dues?|dhar|paona|beton|vara|bhara|daam|dam koto|send money)\b|\d+\s?(tk|taka)\b",
    "address": r"\b(address|location|where (are|r) (you|u)|where do (you|u) live|your (home|house|place|flat)|"
               r"which (area|road|house|flat|building)|live location|gps|coordinates|map link|"
               r"thikana|kothay|kothai|koi acho|koi aso|basa kothay|bari kothay)\b",
    "meet": r"\b(meet|meet up|meetup|come over|pick (me|you) up|hang ?out|visit (me|you|us)|"
            r"let'?s meet|date night|go out|dekha kor\w*|dekha hobe|chole asho|chole aso|basay asho|"
            r"ghurte jabo|dekha korte)\b",
    "promise": r"\b(promise|swear|guarantee|commit(ment)?|word of hono(u)?r|"
               r"will you (do|come|pay|help|give|marry)|can you (lend|pay|give|come)|"
               r"kotha dao|kotha dicch\w*|kosom|pakka)\b",
    "decision": r"\b(marry|marriage|wedding|propos(e|al)|divorce|resign|quit (my|the|your) job|job offer|"
                r"sell (the|my|our) (house|land|flat|car)|buy (a|the) (house|land|flat|car)|invest(ment)?|"
                r"contract|sign (the|this)|lawsuit|court case|abortion|surgery|operation|"
                r"biye|talak|chakri charb\w*|jomi)\b",
}
_BN = {
    "otp": ("ওটিপি", "পিন", "পাসওয়ার্ড", "পাসওয়ার্ড", "ভেরিফিকেশন", "অ্যাকাউন্ট নম্বর", "একাউন্ট নম্বর",
            "অ্যাকাউন্ট নাম্বার", "একাউন্ট নাম্বার", "কার্ড নম্বর", "কার্ড নাম্বার", "ব্যাংক অ্যাকাউন্ট",
            "ব্যাংক একাউন্ট", "গোপন কোড"),
    "sos": ("বাঁচাও", "বাচাও", "বিপদ", "জরুরি", "জরুরী", "উদ্ধার", "অপহরণ", "সাহায্য করো", "হেল্প করো"),
    "health": ("হাসপাতাল", "অ্যাম্বুলেন্স", "এম্বুলেন্স", "দুর্ঘটনা", "এক্সিডেন্ট", "রক্ত পড়", "রক্তক্ষরণ",
               "অজ্ঞান", "বুকে ব্যথা", "শ্বাস নিতে", "স্ট্রোক", "হার্ট অ্যাটাক", "আত্মহত্যা", "মরে যা", "বিষ খে"),
    "money": ("টাকা", "৳", "বিকাশ", "নগদ", "রকেট", "পেমেন্ট", "ধার দা", "ধার দে", "ধার চা", "ধার নি", "ধার লাগ", "লোন", "ঋণ", "পাওনা", "দেনা",
              "বেতন", "ভাড়া", "দাম", "খরচ", "ক্যাশ", "বিল "),
    "address": ("ঠিকানা", "লোকেশন", "কোথায় আছ", "কোথায় থাক", "কই আছ", "কোন এলাকা", "বাসা কোথায়",
                "বাড়ি কোথায়", "বাসার নম্বর", "কোথায় তুমি", "কোথায় আপনি"),
    "meet": ("দেখা কর", "দেখা হবে", "চলে আস", "বাসায় আস", "নিতে আস", "ঘুরতে যা", "মিট কর", "দেখা করবে"),
    "promise": ("কথা দাও", "কথা দিচ্ছ", "কথা দেন", "প্রমিস", "প্রতিশ্রুতি", "কসম", "পাক্কা"),
    "decision": ("বিয়ে", "বিয়ে", "বিবাহ", "তালাক", "ডিভোর্স", "চাকরি ছাড়", "রিজাইন", "জমি কিন", "জমি বিক্রি", "জমির", "বাড়ি বিক্রি",
                 "ফ্ল্যাট কিন", "বিনিয়োগ", "চুক্তি", "মামলা", "অপারেশন", "সার্জারি"),
}
_EN_RE = {k: re.compile(v, re.I) for k, v in _EN.items()}
# NFC: য় / ড় / ঢ় are composition exclusions (NFC writes them as two code
# points), so the word lists are normalized exactly like the incoming text.
_BN = {k: tuple(dict.fromkeys(unicodedata.normalize("NFC", w) for w in v)) for k, v in _BN.items()}
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _norm(text):
    t = unicodedata.normalize("NFC", str(text or ""))
    return t.translate(_BN_DIGITS)


def classify(text):
    """The first matching hold category ('' = nothing sensitive found).
    Severity order: otp, sos, health, money, address, meet, promise, decision."""
    t = _norm(text)
    if not t.strip():
        return ""
    low = t.lower()
    for cat in CATEGORIES:
        if _EN_RE[cat].search(low):
            return cat
        for w in _BN[cat]:
            if w in t:
                return cat
    return ""


# --------------------------------------------------------------- language
_ROMAN_WORDS = {
    "ami", "tumi", "apni", "tui", "kemon", "acho", "aso", "achi", "asi", "ache", "ase", "ki", "kii", "na",
    "hobe", "korbo", "kori", "koro", "kore", "bhai", "vai", "valo", "bhalo", "accha", "acha", "thik",
    "kothay", "keno", "kobe", "ekhon", "pore", "jabo", "jaba", "khaiso", "khaicho", "nai", "nei", "hoy",
    "hoise", "hoyeche", "tomar", "amar", "apu", "dost", "shono", "bolo", "dekhi", "kal", "aj", "ajke",
}
_BN_CHAR = re.compile(r"[ঀ-৿]")
_WORD = re.compile(r"[a-z']+")


def detect_lang(text):
    """'bn' (Bangla script), 'roman' (romanized Bangla) or 'en'."""
    t = str(text or "")
    if _BN_CHAR.search(t):
        return "bn"
    words = _WORD.findall(t.lower())
    if words and sum(1 for w in words if w in _ROMAN_WORDS) >= max(1, len(words) // 4):
        return "roman"
    return "en"


# --------------------------------------------------------------- style
_EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
# ONLY these short, common phrases may be kept (never free text).
PHRASES = (
    "ok", "okay", "hmm", "hm", "ji", "accha", "acha", "thik ache", "thik ase", "bhai", "vai", "apu",
    "inshallah", "insha allah", "alhamdulillah", "assalamualaikum", "salam", "thanks", "thank you",
    "tnx", "np", "lol", "haha", "hehe", "sure", "done", "on the way", "ok bhai", "ok vai",
    "ঠিক আছে", "আচ্ছা", "জি", "জ্বি", "ওকে", "ভাই", "আপু", "ইনশাআল্লাহ", "আলহামদুলিল্লাহ",
    "আসসালামু আলাইকুম", "সালাম", "ধন্যবাদ", "হুম", "হাহা", "আসছি", "পরে কথা বলি",
)
PHRASES = tuple(unicodedata.normalize("NFC", p) for p in PHRASES)
_FORMAL_BN = ("আপনি", "আপনার", "আপনাকে")
_INFORMAL_BN = ("তুমি", "তোমার", "তোমাকে", "তুই", "তোর")
_FORMAL_RO = re.compile(r"\b(apni|apnar|apnake|please|kindly|regards|sir|madam)\b", re.I)
_INFORMAL_RO = re.compile(r"\b(tumi|tomar|tomake|tui|tor|bro|dude|yaar)\b", re.I)


def style_profile(samples):
    """Compact profile from the user's OWN sent messages. Returns only numbers,
    shares and allow-listed phrases: no sentence of the input survives."""
    msgs = [_norm(s)[:CONTEXT_LINE_MAX] for s in (samples or [])][:SAMPLES_MAX]
    msgs = [m for m in msgs if m.strip()]
    n = len(msgs)
    if not n:
        return {}
    lens = sorted(len(m.split()) for m in msgs)
    langs = {"bn": 0, "roman": 0, "en": 0}
    emoji_msgs = 0
    emoji_count = {}
    formal = informal = 0
    exclaim = question = period = 0
    phrase_count = {}
    for m in msgs:
        langs[detect_lang(m)] += 1
        es = _EMOJI.findall(m)
        if es:
            emoji_msgs += 1
            for e in es:
                emoji_count[e] = emoji_count.get(e, 0) + 1
        formal += sum(m.count(w) for w in _FORMAL_BN) + len(_FORMAL_RO.findall(m))
        informal += sum(m.count(w) for w in _INFORMAL_BN) + len(_INFORMAL_RO.findall(m))
        s = m.rstrip()
        exclaim += s.endswith("!")
        question += s.endswith("?")
        period += s.endswith((".", "।"))
        low = m.lower()
        for p in PHRASES:
            if (_BN_CHAR.search(p) and p in m) or (not _BN_CHAR.search(p)
                                                    and re.search(r"\b%s\b" % re.escape(p), low)):
                phrase_count[p] = phrase_count.get(p, 0) + 1
    top_lang = max(langs, key=lambda k: langs[k])
    return {
        "v": 1, "n": n,
        "words_median": lens[n // 2],
        "short_pct": round(100.0 * sum(1 for x in lens if x <= 4) / n),
        "lang": top_lang,
        "lang_pct": {k: round(100.0 * v / n) for k, v in langs.items()},
        "emoji_pct": round(100.0 * emoji_msgs / n),
        "emojis": [e for e, _ in sorted(emoji_count.items(), key=lambda x: -x[1])[:3]],
        "formality": ("formal" if formal > informal * 1.5 else
                      "informal" if informal > formal * 1.5 else "mixed"),
        "exclaim_pct": round(100.0 * exclaim / n),
        "period_pct": round(100.0 * period / n),
        "phrases": [p for p, c in sorted(phrase_count.items(), key=lambda x: -x[1]) if c >= 2][:6],
    }


def style_hint(profile):
    """One instruction line for the model ('' = no profile / no consent)."""
    p = profile or {}
    if not p.get("n"):
        return ""
    bits = ["Write like this person: replies usually about %d words" % max(1, int(p.get("words_median") or 4))]
    ep = int(p.get("emoji_pct") or 0)
    if ep >= 30:
        bits.append("often uses emojis (%s)" % " ".join(p.get("emojis") or []))
    elif ep >= 10:
        bits.append("sometimes uses an emoji")
    else:
        bits.append("almost never uses emojis")
    f = p.get("formality")
    if f == "formal":
        bits.append("polite/formal (apni)")
    elif f == "informal":
        bits.append("casual (tumi)")
    if int(p.get("period_pct") or 0) < 20:
        bits.append("rarely ends with a full stop")
    if p.get("phrases"):
        bits.append("common words: " + ", ".join(p["phrases"]))
    return "; ".join(bits) + "."


# --------------------------------------------------------------- model I/O
_JSON = re.compile(r"\{.*\}", re.S)


def clean_reply(s):
    s = re.sub(r"\s+", " ", str(s or "")).strip().strip('"').strip()
    if not s or len(s) > REPLY_MAX_CHARS:
        return ""
    return s


def parse_model(raw):
    """(hold, category, replies). Any unparsable answer -> (None, '', [])
    — the caller treats it as a failed (never charged) answer."""
    m = _JSON.search(str(raw or ""))
    if not m:
        return None, "", []
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None, "", []
    if not isinstance(d, dict):
        return None, "", []
    hold = bool(d.get("hold"))
    cat = str(d.get("category") or "")[:20]
    if cat not in CATEGORIES:
        cat = "other" if hold else ""
    out = []
    for r in d.get("replies") or []:
        r = clean_reply(r)
        if r and r not in out and not classify(r):   # a reply never touches a held topic
            out.append(r)
    return hold, cat, out[:3]


def busy_template(lang, until_label=""):
    """Free fallback busy reply (no AI)."""
    if lang == "bn":
        return ("এখন একটু ব্যস্ত আছি, %s পরে কথা বলছি।" % until_label).replace("  ", " ") if until_label \
            else "এখন একটু ব্যস্ত আছি, পরে কথা বলছি।"
    if lang == "roman":
        return ("Ekhon ektu busy, %s por kotha boli." % until_label) if until_label \
            else "Ekhon ektu busy, pore kotha boli."
    return ("I'm busy right now, I'll get back to you after %s." % until_label) if until_label \
        else "I'm busy right now, I'll get back to you soon."
