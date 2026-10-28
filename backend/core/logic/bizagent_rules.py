"""
bizagent_rules.py — G1 RULE-FIRST layer of the Business AI Agent. PURE logic.

Answers the everyday questions of an F-commerce chat WITHOUT calling an AI:
price, stock, sizes/colours, delivery charge, shop hours, payment method,
return policy, order status and the seller's own APPROVED FAQ. Instant, cost 0,
no credit used. The AI is called only when no rule matches.

Ported ideas (read-only reference: Asalify apps/chatbot/brain.py, written fresh
here): FAQ token-overlap match, shop facts from settings, a greeting never
guesses a product ("hi" must not match a product called "Hilsa"), Bangla
suffix stripping (পাঞ্জাবিটা → পাঞ্জাবি), product lookup by SKU / "#id",
in-stock products first.

Assisto keeps its stricter rules: every number in a rule reply comes from the
catalog/settings (and is still post-checked by the caller), out-of-stock is
said honestly (no fake "pre-order" spin), and the agent never claims to be
human.

No Django, no network, no clock. All customer text is bn/en via pick().
"""
import re

from . import bizagent as BZ
from . import business_ai as bai

pick = bai.pick

# rule names (Message.meta["rule"]; Owner Admin groups by these)
R_GREETING = "greeting"
R_FAQ = "faq"
R_DELIVERY = "delivery"
R_HOURS = "hours"
R_ORDER_STATUS = "order_status"
R_PAYMENT = "payment"
R_RETURNS = "returns"
R_PRODUCT = "product"
R_SIZES = "sizes"
R_HUMAN_Q = "disclosure"
R_CATALOG = "catalog"
# sales2 (28 Oct, "world best before any AI key"): more everyday questions
# answered from the seller's OWN data, deterministically
R_PRIVACY = "privacy"              # someone asks for ANOTHER customer's info
R_PIN = "pin_safety"               # "OTP lagbe?" — we never ask for PIN / OTP
R_DELIVERY_TIME = "delivery_time"  # "koto dine pabo?" — never an invented date
R_LOCATION = "location"            # "dokan kothay?" — seller FAQ / booking-page address
R_SIZE_GUIDE = "size_guide"        # size chart from the product's own description
R_THANKS = "thanks"
RULES = (R_GREETING, R_FAQ, R_DELIVERY, R_HOURS, R_ORDER_STATUS, R_PAYMENT, R_RETURNS,
         R_PRODUCT, R_SIZES, R_HUMAN_Q, R_CATALOG, R_PRIVACY, R_PIN, R_DELIVERY_TIME,
         R_LOCATION, R_SIZE_GUIDE, R_THANKS)
# rules that only INFORM (they never start / change an order): the order flow
# may answer one of these mid-order and then repeat what it still needs
INFO_RULES = (R_DELIVERY, R_HOURS, R_PAYMENT, R_RETURNS, R_PRIVACY, R_PIN, R_FAQ,
              R_DELIVERY_TIME, R_LOCATION, R_SIZE_GUIDE, R_HUMAN_Q)
CATALOG_MAX = 8

_WS = re.compile(r"[?,।!.;:()\[\]\"'\-/]+")
_BN_SUFFIX = re.compile(r"(টা|টি|টে|গুলো|গুলা|খানা|খানি|টার|টির|টাও|টিও|রে|কে|ের|র)$")
_BL_SUFFIX = re.compile(r"(ta|ti|ter|tar|gula|gulo|er)$")

STOP = {
    "দাম", "কত", "price", "টাকা", "এর", "টা", "কি", "আছে", "স্টক", "the", "of", "a", "an",
    "hi", "hello", "hey", "হাই", "হ্যালো", "salam", "সালাম", "আসসালামু", "আলাইকুম",
    "ভাই", "আপু", "স্যার", "sir", "bhai", "vai", "apu", "please", "plz", "pls", "একটু", "আমি",
    "আমার", "চাই", "দেন", "দিন", "করে", "জানতে", "বলেন", "বলুন", "is", "what", "how", "much",
    "koto", "dam", "daam", "ki", "ase", "ache", "kemon", "valo", "ok", "okay", "hmm",
    "কেমন", "আছেন", "good", "er", "ar", "ta", "ti", "gulo", "gula", "na", "to", "do", "you",
    "have", "lagbe", "hobe", "den", "din", "nibo", "kinbo", "apnader", "ekta", "akta", "eta",
    "ota", "this", "that", "it", "and", "or", "for", "in", "on", "at", "me", "my", "i",
    "your", "are", "can", "will", "jodi", "ei", "oi", "এই", "ওই", "এটা", "ওটা", "তো", "কী",
    "and", "with", "জানাবেন", "জানান", "bolben", "bolen", "janaben", "janan", "kindly",
}

# question families — bn script, Banglish and English
_ASK_DELIVERY = ("ডেলিভারি চার্জ", "ডেলিভারি খরচ", "ডেলিভারি কত", "ডেলিভারী", "শিপিং",
                 "delivery charge", "delivery cost", "delivery koto", "delivary", "delivery fee",
                 "shipping", "home delivery", "ডেলিভারি কত দিনে", "courier charge",
                 "কুরিয়ার চার্জ", "delivery", "ডেলিভারি")
_ASK_HOURS = ("কখন খোলা", "কয়টায় খোলে", "কয়টা পর্যন্ত", "খোলা থাকে", "বন্ধ কখন", "দোকানের সময়",
              "opening hours", "open hours", "shop hours", "when do you open", "what time",
              "kokhon khola", "koyta porjonto", "khola thake", "open koto", "office time",
              "are you open", "open now")
_ASK_PAYMENT = ("পেমেন্ট", "payment", "বিকাশ", "bkash", "bikash", "নগদ", "nagad", "cash on delivery",
                "ক্যাশ অন", "cod", "advance", "অগ্রিম", "পেমেন্ট কিভাবে", "kivabe payment",
                "card", "কার্ড")
_ASK_RETURNS = ("রিটার্ন পলিসি", "ফেরত দেওয়া যাবে", "ফেরত দিতে", "exchange", "এক্সচেঞ্জ",
                "রিটার্ন", "return kora", "return deya", "return dewa", "return jabe",
                "ferot deya", "ferot dewa", "ফেরত দেওয়া", "returnable", "return it",
                "return policy", "can i return", "return korte", "ferot", "change kora jabe",
                "বদলানো যাবে", "পরিবর্তন করা যাবে")
_ASK_STATUS = ("অর্ডার কোথায়", "আমার অর্ডার", "পার্সেল কোথায়", "পার্সেল কই", "কবে পাবো",
               "order status", "where is my order", "where is my parcel", "track my",
               "order ki obostha", "parcel koi", "kobe pabo", "amar order", "tracking")
_ASK_SIZE = ("সাইজ", "size", "কালার", "রং", "রঙ", "colour", "color", "কোন কোন", "measurement",
             "মাপ", "available size", "koto size", "ki ki color")
_ASK_PRICE = ("দাম", "কত", "price", "dam", "daam", "koto", "rate", "cost", "মূল্য", "how much",
              "pp", "প্রাইস", "price koto", "prize")
_ASK_STOCK = ("স্টক", "stock", "আছে কি", "আছে", "পাওয়া যাবে", "available", "ache", "ase", "pawa",
              "in stock")
# e2e-sales: "what do you sell?" — a catalog list from the seller's own rows
_ASK_CATALOG = ("ki ki ache", "ki ki ase", "ki ki product", "ki ki pawa jay", "কী কী আছে",
                "কি কি আছে", "কী কী পণ্য", "কি কি পণ্য", "কী কী পাওয়া যায়", "কি কি পাওয়া যায়",
                "catalog", "catalogue", "ক্যাটালগ", "product list", "all products",
                "সব পণ্য", "পণ্যের তালিকা", "প্রোডাক্ট লিস্ট", "what do you have", "what do you sell",
                "your products", "collection", "কালেকশন", "kalekshon", "ki bikri koren",
                "কী বিক্রি করেন", "কি বিক্রি করেন")
_GREETINGS = ("hi", "hello", "hey", "হাই", "হ্যালো", "salam", "সালাম", "আসসালামু আলাইকুম",
              "assalamu alaikum", "assalamualaikum", "আসসালামুয়ালাইকুম", "good morning",
              "good evening", "নমস্কার", "hlw", "helo")


# ---- sales2 question families ----
# delivery TIME (not charge): we never state a date / day count the seller
# did not write (the seller's own FAQ answers it when there is one)
_ASK_DTIME = ("কত দিনে", "কতদিনে", "কয় দিন", "কয়দিন", "কত দিন লাগে", "কবে পাবো", "কবে পাব",
              "কবে পাঠাবেন", "কবে দিবেন", "কবে দেবেন", "আজ পাবো", "কাল পাবো", "আজকে পাবো",
              "koto dine", "koy din", "koydin", "koto din lage", "koto din lagbe", "kobe pabo",
              "kobe pathaben", "kobe diben", "kobe deben", "aj pabo", "kal pabo", "ajke pabo",
              "how many days", "how long", "delivery time", "when will i get", "when will it",
              "same day", "next day", "ডেলিভারি টাইম", "ডেলিভারি সময়", "delivery somoy")
# where the shop is
_ASK_LOCATION = ("কোথায়", "কোথায়", "kothay", "kothai", "location", "লোকেশন", "ঠিকানা", "thikana",
                 "address", "showroom", "শোরুম", "outlet", "আউটলেট", "where are you",
                 "where is your", "visit", "ঘুরে দেখা", "physical shop", "map")
_SHOP_WORDS = ("দোকান", "dokan", "shop", "store", "showroom", "শোরুম", "outlet", "আউটলেট",
               "office", "অফিস", "আপনাদের", "apnader", "apnar", "আপনার", "your", "you",
               "apnara", "আপনারা", "location", "লোকেশন", "physical")
# a size chart / which-size question (answered from the product description)
_ASK_SIZE_GUIDE = ("size chart", "সাইজ চার্ট", "size guide", "সাইজ গাইড", "measurement",
                   "মাপ", "kon size", "কোন সাইজ", "which size", "what size", "chest", "চেস্ট",
                   "বুক", "লম্বা", "length", "inch", "ইঞ্চি", "উচ্চতা", "height", "ওজন", "weight",
                   "fit hobe", "ফিট হবে", "fit korbe", "will it fit")
# someone asks for ANOTHER customer's details — never shared
_OTHER_PERSON = ("অন্য গ্রাহক", "অন্য কাস্টমার", "অন্য ক্রেতা", "আরেকজন", "আর একজন", "অন্যের",
                 "onno customer", "onno kaster", "other customer", "another customer",
                 "someone else", "somebody else", "ar ekjon", "arekjon", "onner",
                 "tar number", "tar phone", "tar address", "tar thikana", "tar mobile",
                 "তার নম্বর", "তার ফোন", "তার ঠিকানা", "তার মোবাইল", "ওর নম্বর", "ওর ঠিকানা",
                 "ওনার নম্বর", "ওনার ঠিকানা", "onar number", "onar address", "or number",
                 "his number", "her number", "his address", "her address", "his phone",
                 "her phone", "their number", "their address", "bhai er order", "bon er order",
                 "bondhur order", "friend s order", "friends order", "ভাইয়ের অর্ডার",
                 "বোনের অর্ডার", "বন্ধুর অর্ডার", "er order er phone", "er order er number",
                 "er order er address", "এর অর্ডারের নম্বর", "এর অর্ডারের ঠিকানা")
_INFO_WORDS = ("phone", "ফোন", "mobile", "মোবাইল", "number", "nombor", "নম্বর", "নাম্বার",
               "address", "ঠিকানা", "thikana", "বাসা", "basa", "details", "detail", "তথ্য",
               "info", "kothay thake", "কোথায় থাকে")
_CUSTOMER_LIST = ("customer list", "কাস্টমার লিস্ট", "গ্রাহকের তালিকা", "গ্রাহক তালিকা",
                  "ke ke kinse", "ke ke kineche", "ke ke order", "কে কে কিনেছে", "কে কে অর্ডার",
                  "who bought", "who else bought", "who ordered", "all orders", "sob order er list",
                  "sob order list", "order list din", "order list den", "আজকের সব অর্ডার",
                  "সব অর্ডারের তালিকা", "অর্ডারের লিস্ট", "list of customers", "customers list",
                  "buyer list", "বায়ারের লিস্ট")
# PIN / OTP — we never ask for one; the customer is told so
_ASK_PIN = ("otp", "ওটিপি", "ও টি পি", "pin", "পিন", "password", "পাসওয়ার্ড", "verification code",
            "ভেরিফিকেশন কোড", "code ta", "কোডটা", "কোড টা", "secret code")
_THANKS = ("thanks", "thank you", "thank u", "thx", "tnx", "ty", "ধন্যবাদ", "dhonnobad",
           "dhonyobad", "jazakallah", "জাযাকাল্লাহ", "shukriya")
_ASK_BKASH = ("bkash", "bikash", "বিকাশ", "বিকাশে")
_ASK_NAGAD = ("nagad", "নগদ", "নগদে")
_ASK_COD = ("cod", "cash on delivery", "ক্যাশ অন", "ক্যাশ অন ডেলিভারি", "hand cash", "হাতে টাকা",
            "পণ্য হাতে পেয়ে", "condition", "কন্ডিশন")
# a POLICY question about returns ("return kora jabe?") vs a refund REQUEST
_POLICY_Q = ("policy", "পলিসি", "নিয়ম", "niyom", "jabe", "যাবে", "parbo", "পারবো", "পারব",
             "jay", "যায়", "যায়",
             "can i", "is it possible", "possible", "ki", "কি", "কী", "?", "hoy", "হয়",
             "hobe", "হবে", "korte pari", "করতে পারি", "allowed", "do you")
_COMPLAINT_Q = ("kharap", "খারাপ", "nosto", "নষ্ট", "bhanga", "ভাঙা", "ভাঙ্গা", "damaged", "broken",
                "defective", "wrong", "ভুল", "vul", "fake", "নকল", "chai", "চাই", "ferot din",
                "ferot den", "ফেরত দিন", "ফেরত দেন", "ফেরত চাই", "korun", "করুন", "এখনই", "ekhoni",
                "taka ferot", "টাকা ফেরত", "money back", "refund", "রিফান্ড", "pai nai", "পাইনি",
                "পাই নাই", "ashe nai", "আসেনি", "আসে নাই", "cancel", "i want", "give me")
# the customer wants to change / cancel an order
_ORDER_CHANGE = ("order cancel", "অর্ডার বাতিল", "অর্ডার ক্যান্সেল", "order ta cancel",
                 "order cancel korte", "cancel my order", "cancel the order", "cancel korte chai",
                 "cancel kore din", "cancel kore den", "বাতিল করতে চাই", "বাতিল করে দিন",
                 "order change", "অর্ডার পরিবর্তন", "অর্ডার চেঞ্জ", "change my order",
                 "order ta change", "size change", "সাইজ পরিবর্তন", "সাইজ বদল", "address change",
                 "ঠিকানা পরিবর্তন", "ঠিকানা বদল", "thikana change", "change the address",
                 "change korte chai", "বদলাতে চাই", "poriborton korte chai", "qty change",
                 "আরেকটা যোগ", "arekta add", "add one more")
# a scam / phishing message sent TO the page (fake Meta notice, prize, fake
# bKash agent asking for a code, "send money to this number") — the agent
# never answers it; the seller is warned
_SCAM = ("page will be disabled", "page will be deleted", "page will be unpublished",
         "your page has been", "verify your page", "verify your account", "copyright violation",
         "community standards", "meta support team", "facebook security", "meta business support",
         "appeal here", "account will be suspended", "পেজ বন্ধ হয়ে যাবে", "পেজ ডিজেবল",
         "আপনার পেজ নিষ্ক্রিয়", "লটারি জিতেছেন", "পুরস্কার জিতেছেন", "you have won", "claim your prize",
         "congratulations you won", "apni jitechen", "lottery", "লটারি", "bkash agent bolchi",
         "বিকাশ অফিস থেকে", "বিকাশ এজেন্ট বলছি", "bkash office theke", "apnar bkash account block",
         "আপনার বিকাশ অ্যাকাউন্ট বন্ধ", "otp ta din", "otp ta den", "ওটিপি টা দিন", "ওটিপি দিন",
         "code ta din", "code ta den", "কোডটা দিন", "pin ta din", "পিন নম্বর দিন", "share the otp",
         "send me the otp", "send me the code", "ei number e taka pathan", "এই নম্বরে টাকা পাঠান",
         "send money to this number", "investment double", "টাকা ডাবল", "taka double")
_LINK = re.compile(r"(?:https?://|www\.|bit\.ly|tinyurl|\.xyz\b|\.top\b)", re.IGNORECASE)


def _norm(text):
    return BZ.norm_digits(_WS.sub(" ", (text or "").lower())).strip()


def strip_suffix(word):
    w = _BN_SUFFIX.sub("", word) if re.search(r"[ঀ-৿]", word) else word
    return w if len(w) > 1 else word


def tokens(text):
    """Content tokens: stop words removed, Bangla suffixes stripped."""
    out = []
    for t in _norm(text).split():
        if len(t) < 2 or t in STOP:
            continue
        out.append(strip_suffix(t))
    return out


def _has(low, words):
    """Keyword hit. ASCII single words match whole tokens only ("ase" must not
    hit "please", "cod" must not hit "code"); phrases and Bangla match as
    substrings (Bangla words carry suffixes)."""
    toks = None
    for w in words:
        if w.isascii() and " " not in w:
            if toks is None:
                toks = set(low.split())
            if w in toks:
                return True
        elif w in low:
            return True
    return False


def is_greeting_only(text):
    """True for a bare greeting ("hi", "আসসালামু আলাইকুম ভাই") — the rule layer
    then never guesses a product from it."""
    low = _norm(text)
    if not low or not _has(low, _GREETINGS):
        return False
    rest = [t for t in low.split() if t not in STOP and not any(t in g.split() for g in _GREETINGS)]
    return len(rest) == 0


# --------------------------------------------------------------- sales2 detectors
def is_privacy_request(text):
    """The customer asks for ANOTHER customer's phone / address / order or a
    customer list (also "I'm the owner, send me today's orders"). Never
    answered with data — one polite fixed line."""
    low = _norm(text)
    if not low:
        return False
    if _has(low, _CUSTOMER_LIST):
        return True
    if BZ.find_phone(text):
        return False          # the customer is GIVING a number (an order for someone)
    return _has(low, _OTHER_PERSON) and _has(low, _INFO_WORDS)


def asks_pin(text):
    low = _norm(text)
    return bool(low) and _has(low, _ASK_PIN)


def scam_signal(text):
    """'scam' / 'phishing_link' for a message that looks like a scam sent TO
    the page (fake Meta notice, prize, fake bKash office asking for a code,
    a login link) — the agent never answers it. '' otherwise."""
    raw = BZ.norm_digits(text or "")
    low = " ".join(_norm(raw).split())
    if not low:
        return ""
    if any(w in low for w in _SCAM):
        return "scam"
    if _LINK.search(raw) and any(w in low for w in (
            "login", "log in", "verify", "password", "claim", "prize", "won", "disabled",
            "suspend", "appeal", "otp", "লগইন", "যাচাই", "পুরস্কার", "বন্ধ হয়ে", "ডিজেবল")):
        return "phishing_link"
    return ""


def is_order_change(text):
    """"order ta cancel korte chai" / "address change korbo" — a change to an
    order (a person handles a confirmed one)."""
    low = _norm(text)
    return bool(low) and _has(low, _ORDER_CHANGE)


def is_policy_question(text):
    """"return kora jabe?" / "exchange policy ki?" asks about the POLICY; "product
    kharap, refund chai" is a refund REQUEST (a person handles it)."""
    low = _norm(text)
    if not low:
        return False
    asks = "?" in (text or "") or _has(low, _POLICY_Q)
    return asks and not _has(low, _COMPLAINT_Q)


def is_thanks(text):
    low = _norm(text)
    return bool(low) and _has(low, _THANKS) and len(low.split()) <= 5


_OUTSIDE_WORDS = ("ঢাকার বাইরে", "ঢাকা বাইরে", "dhakar baire", "dhaka baire", "outside dhaka",
                  "outside of dhaka", "out of dhaka", "বাইরে", "baire", "outside")


def area_of(text):
    """('inside' | 'outside' | '', the area word as the customer wrote it)."""
    low = (text or "").lower()
    for w in BZ.OUTSIDE_DISTRICTS:
        if w in low:
            return "outside", w
    if any(w in low for w in _OUTSIDE_WORDS):
        return "outside", None
    for w in BZ.DHAKA_AREAS:
        if w in low and w not in ("dhaka", "ঢাকা"):
            return "inside", w
    if "dhaka" in low or "ঢাকা" in low:
        return "inside", None
    return "", None


def topic_faq(faqs, words):
    """The seller's approved FAQ about this TOPIC (its question uses one of
    the topic words) — the customer may phrase it any way."""
    for f in faqs or []:
        q = _norm(f.get("q") or "")
        if q and (f.get("a") or "").strip() and _has(q, words):
            return f
    return None


# --------------------------------------------------------------- product lookup
_SKU_RE = re.compile(r"\b([A-Za-z]{1,4}-?\d{2,6})\b")
_HASH_ID = re.compile(r"#\s*(\d{1,7})\b")


def find_product(text, catalog, post_product=None):
    """The product the customer means: exact/suffix-stripped name match, SKU
    ("P-0007"), "#<id>", else the product linked to the post they commented
    on. In-stock first when several match. Never guesses from a greeting."""
    if not catalog:
        return None
    if is_greeting_only(text):
        return None
    t = BZ.norm_digits(text or "")
    m = _HASH_ID.search(t)
    if m:
        pid = int(m.group(1))
        hit = next((p for p in catalog if p.get("id") == pid), None)
        if hit:
            return hit
    for m in _SKU_RE.finditer(t):
        code = m.group(1).lower().replace("-", "")
        hit = next((p for p in catalog
                    if (p.get("sku") or "").lower().replace("-", "") == code and code), None)
        if hit:
            return hit
    hits = BZ.match_products(text, catalog, limit=5)
    if not hits:
        stripped = " ".join(strip_suffix(w) for w in _norm(text).split())
        hits = BZ.match_products(stripped, catalog, limit=5)
    if hits:
        low = _norm(text)
        stripped = " ".join(strip_suffix(w) for w in low.split())
        full = [p for p in hits if _norm(p.get("name") or "") in low
                or _norm(p.get("name") or "") in stripped]
        if full:
            full.sort(key=lambda p: int(p.get("stock") or 0) <= 0)   # in stock first (stable)
            return full[0]
        if len(hits) == 1:
            return hits[0]
        return None          # several partial hits = ambiguous → the AI / a person decides
    return post_product


# --------------------------------------------------------------- FAQ
def faq_match(faqs, text, min_score=0.6):
    """Best APPROVED FAQ for `text` by token overlap (share of the FAQ
    question's content words that the customer used). Returns the faq dict or
    None. Learned-but-unapproved entries must not be passed in."""
    toks = set(tokens(text))
    if not toks:
        return None
    best, best_score = None, 0.0
    for f in faqs or []:
        # one FAQ may list several phrasings: "dokan kothay | দোকান কোথায়"
        for alt in re.split(r"[|\n]+", f.get("q") or ""):
            q = set(tokens(alt))
            if not q:
                continue
            hit = len(toks & q)
            if hit == 0 or (len(q) >= 2 and hit < 2):
                continue
            score = hit / len(q)
            if score > best_score:
                best, best_score = f, score
    return best if best is not None and best_score >= min_score else None


# --------------------------------------------------------------- reply text
def _money(v):
    return BZ._fmt_money(v)


def delivery_line(lang, delivery):
    dl = delivery or {}
    inside, outside = BZ._dec(dl.get("inside_dhaka")), BZ._dec(dl.get("outside_dhaka"))
    if not inside and not outside:
        return ""
    free = BZ._dec(dl.get("free_over"))
    s = pick(lang, f"ডেলিভারি চার্জ: ঢাকার ভিতরে ৳{_money(inside)}, ঢাকার বাইরে ৳{_money(outside)}।",
             f"Delivery charge: inside Dhaka ৳{_money(inside)}, outside Dhaka ৳{_money(outside)}.")
    if free:
        s += pick(lang, f" ৳{_money(free)} বা তার বেশি অর্ডারে ডেলিভারি ফ্রি।",
                  f" Free delivery on orders of ৳{_money(free)} or more.")
    return s


def _area_label(lang, word):
    if not word:
        return ""
    return word.title() if word.isascii() else word


def area_delivery_line(lang, delivery, area, word=None):
    """'Mirpur is inside Dhaka — delivery ৳60 (outside Dhaka ৳120).' Every
    number from the seller's delivery settings."""
    dl = delivery or {}
    inside, outside = BZ._dec(dl.get("inside_dhaka")), BZ._dec(dl.get("outside_dhaka"))
    if not inside and not outside or area not in ("inside", "outside"):
        return ""
    nm = _area_label(lang, word)
    if area == "inside":
        s = pick(lang, (f"{nm} ঢাকার ভিতরে — " if nm else "ঢাকার ভিতরে ") +
                 f"ডেলিভারি চার্জ ৳{_money(inside)}। (ঢাকার বাইরে ৳{_money(outside)})",
                 (f"{nm} is inside Dhaka — " if nm else "Inside Dhaka ") +
                 f"delivery charge ৳{_money(inside)}. (Outside Dhaka ৳{_money(outside)})")
    else:
        s = pick(lang, (f"{nm} ঢাকার বাইরে — " if nm else "ঢাকার বাইরে ") +
                 f"ডেলিভারি চার্জ ৳{_money(outside)}। (ঢাকার ভিতরে ৳{_money(inside)})",
                 (f"{nm} is outside Dhaka — " if nm else "Outside Dhaka ") +
                 f"delivery charge ৳{_money(outside)}. (Inside Dhaka ৳{_money(inside)})")
    free = BZ._dec(dl.get("free_over"))
    if free:
        s += pick(lang, f" ৳{_money(free)} বা তার বেশি অর্ডারে ডেলিভারি ফ্রি।",
                  f" Free delivery on orders of ৳{_money(free)} or more.")
    return s


def delivery_time_line(lang, delivery):
    """No invented day count / date: the seller has not written one."""
    s = pick(lang, "ডেলিভারি কত দিনে হবে তা আপনার এলাকা ও কুরিয়ারের ওপর নির্ভর করে — অর্ডার "
                   "কনফার্ম হলে দোকান থেকে সময় জানিয়ে দেওয়া হবে।",
             "Delivery time depends on your area and the courier — the shop will tell you "
             "the time once the order is confirmed.")
    dl = delivery_line(lang, delivery)
    return (s + " " + dl).strip()


def wallet_line(lang, wallets, provider):
    """Step-by-step bKash / Nagad payment to the seller's OWN number (from the
    seller's wallet settings), the owner verifies before it counts as paid."""
    w = next((x for x in wallets or [] if x.get("provider") == provider
              and (x.get("number") or "").strip()), None)
    if w is None:
        return ""
    label = pick(lang, "বিকাশ", "bKash") if provider == "bkash" else pick(lang, "নগদ", "Nagad")
    num = w["number"].strip()
    who = (" (%s)" % w["name"].strip()) if (w.get("name") or "").strip() else ""
    return pick(
        lang,
        f"{label}-এ পেমেন্টের নিয়ম: ১) {label} অ্যাপে 'Payment' বা 'Send Money' বেছে নিন; "
        f"২) নম্বর দিন {num}{who}; ৩) টাকার পরিমাণ লিখে নিজের অ্যাপে নিশ্চিত করুন; "
        "৪) TrxID বা স্ক্রিনশট এখানে পাঠান — দোকানের মালিক যাচাই করার পর পেমেন্ট ধরা হবে। "
        "কখনো কাউকে আপনার পিন বা OTP দেবেন না।",
        f"To pay by {label}: 1) open {label} and choose 'Payment' or 'Send Money'; "
        f"2) enter {num}{who}; 3) enter the amount and confirm in your own app; "
        "4) send the TrxID or a screenshot here — the owner verifies it before it counts as paid. "
        "Never share your PIN or OTP with anyone.")


def privacy_line(lang):
    return pick(lang, "দুঃখিত, অন্য কোনো গ্রাহকের নাম, নম্বর, ঠিকানা বা অর্ডারের তথ্য আমরা কাউকে দিই না — "
                      "সবার তথ্য গোপন থাকে। আপনার নিজের অর্ডারের বিষয়ে জানতে চাইলে লিখুন।",
                "Sorry, we never share another customer's name, number, address or order — "
                "everyone's details stay private. Ask me anything about your own order.")


def pin_line(lang):
    return pick(lang, "আমরা কখনো আপনার পিন, OTP বা পাসওয়ার্ড চাই না — কাউকে দেবেন না। দোকানের নাম "
                      "করে কেউ চাইলে সেটি প্রতারণা।",
                "We never ask for your PIN, OTP or password — don't share them with anyone. "
                "Anyone asking for them in our name is a scam.")


def thanks_line(lang):
    return pick(lang, "আপনাকেও ধন্যবাদ! আর কিছু জানতে চাইলে লিখুন।",
                "Thank you too! Write any time if you need anything else.")


def location_line(lang, address):
    return pick(lang, f"আমাদের ঠিকানা: {address}", f"Our address: {address}")


_SIZE_HINT = re.compile(r"(size|সাইজ|মাপ|chest|বুক|length|লম্বা|inch|ইঞ্চি|কোমর|waist|"
                        r"\b(?:xs|s|m|l|xl|xxl|xxxl|2xl|3xl)\b)", re.IGNORECASE)
_NUMS = re.compile(r"\d+(?:\.\d+)?")


def size_guide_line(lang, p):
    """(text, numbers) — the size lines of the product's OWN description (the
    seller wrote them) + the sizes in stock. ('', []) when there are none."""
    desc = p.get("description") or ""
    rows = [ln.strip(" -•") for ln in re.split(r"[\n।;|]+", desc)
            if ln.strip() and _SIZE_HINT.search(ln)]
    if not rows:
        return "", []
    name = p.get("name") or ""
    s = pick(lang, f"{name}-এর সাইজ গাইড (দোকানের দেওয়া): ", f"{name} size guide (from the shop): ")
    s += " · ".join(rows[:5]) + pick(lang, "।", ".")
    have = sizes_line(lang, p)
    if have:
        s += " " + have
    nums = _NUMS.findall(BZ.norm_digits(" ".join(rows[:5])))
    return s, nums


_SIZE_TOKENS = ("xs", "s", "m", "l", "xl", "xxl", "xxxl", "2xl", "3xl")


def variant_ask_line(lang, p, text):
    """"L size ache?" / "kalo ache?" — the exact variant's stock. '' when the
    customer did not name a size / colour of this product."""
    low = " " + _norm(text) + " "
    vs = p.get("variants") or []
    if not vs:
        return ""
    asked = {}                     # kind -> the value as the seller wrote it
    for v in vs:
        for kind in ("size", "colour"):
            part = str(v.get(kind) or "")
            k = part.lower()
            if not k or kind in asked:
                continue
            if (" %s " % k) in low or (not k.isascii() and k in low):
                asked[kind] = part
    name = p.get("name") or ""
    sizes, colours = _variant_bits(p)
    if not asked:
        # a common size token the product does not have at all ("XXL ache?")
        if sizes and _has(low, _ASK_SIZE + _ASK_STOCK):
            for t in _SIZE_TOKENS:
                if (" %s " % t) in low:
                    return pick(lang, f"দুঃখিত, {name}-এ {t.upper()} সাইজ নেই। পাওয়া যাচ্ছে: " +
                                ", ".join(sizes) + "।",
                                f"Sorry, {name} doesn't come in {t.upper()}. Available: " +
                                ", ".join(sizes) + ".")
        return ""
    ok = [v for v in vs if int(v.get("stock") or 0) > 0
          and all(str(v.get(kind) or "").lower() == val.lower() for kind, val in asked.items())]
    label = " ".join(asked[k] for k in ("size", "colour") if k in asked)
    if ok:
        price = BZ._dec(ok[0].get("price")) or BZ._dec(p.get("price"))
        return pick(lang, f"হ্যাঁ, {name} {label} স্টকে আছে — দাম ৳{_money(price)}। অর্ডার করতে নাম, "
                          "মোবাইল নম্বর ও পূর্ণ ঠিকানা লিখুন।",
                    f"Yes, {name} {label} is in stock — ৳{_money(price)}. To order, send your name, "
                    "mobile number and full address.")
    left = "; ".join(x for x in (", ".join(sizes), ", ".join(colours)) if x)
    if not left:
        return pick(lang, f"দুঃখিত, {name} এখন স্টকে নেই।", f"Sorry, {name} is out of stock right now.")
    return pick(lang, f"দুঃখিত, {name} {label} এখন নেই। এখন পাওয়া যাচ্ছে — {left}।",
                f"Sorry, {name} {label} is not available right now. Available now — {left}.")


def substitutes(p, catalog, limit=2):
    """In-stock products of the SAME category (never a guess across shelves)."""
    cat = (p.get("category") or "").strip().lower()
    if not cat:
        return []
    out = [q for q in catalog or [] if q.get("id") != p.get("id")
           and (q.get("category") or "").strip().lower() == cat
           and int(q.get("stock") or 0) > 0 and _price_range(q)[0]]
    return out[:limit]


def substitute_line(lang, subs):
    if not subs:
        return ""
    bits = []
    for q in subs:
        lo, hi = _price_range(q)
        bits.append("%s ৳%s" % (q["name"], _money(lo)) if lo == hi else
                    "%s ৳%s–৳%s" % (q["name"], _money(lo), _money(hi)))
    return pick(lang, " একই ধরনের যা এখন আছে: " + ", ".join(bits) + "।",
                " Similar items in stock now: " + ", ".join(bits) + ".")


def _variant_bits(p):
    sizes, colours = [], []
    for v in p.get("variants") or []:
        if int(v.get("stock") or 0) <= 0:
            continue
        if v.get("size") and v["size"] not in sizes:
            sizes.append(v["size"])
        if v.get("colour") and v["colour"] not in colours:
            colours.append(v["colour"])
    return sizes, colours


def _price_range(p):
    prices = [BZ._dec(v.get("price")) for v in p.get("variants") or []
              if BZ._dec(v.get("price")) is not None and int(v.get("stock") or 0) > 0]
    base = BZ._dec(p.get("price"))
    if prices:
        lo, hi = min(prices), max(prices)
        return lo, hi
    return base, base


def product_card(lang, p, *, with_cta=True, catalog=None):
    """Name, price, sizes, colours, stock — every value from the catalog row.
    sales2: out of stock -> up to two in-stock items of the same category."""
    name = p.get("name") or ""
    stock = int(p.get("stock") or 0)
    lo, hi = _price_range(p)
    if lo is None:
        return ""
    price = (f"৳{_money(lo)}" if lo == hi else f"৳{_money(lo)}–৳{_money(hi)}")
    if stock <= 0:
        return pick(lang, f"{name} — দাম {price}। দুঃখিত, এটি এখন স্টকে নেই।",
                    f"{name} — {price}. Sorry, it is out of stock right now.") + \
            substitute_line(lang, substitutes(p, catalog))
    sizes, colours = _variant_bits(p)
    s = pick(lang, f"{name} — দাম {price}, স্টকে আছে।", f"{name} — {price}, in stock.")
    if sizes:
        s += pick(lang, " সাইজ: " + ", ".join(sizes) + "।", " Sizes: " + ", ".join(sizes) + ".")
    if colours:
        s += pick(lang, " রং: " + ", ".join(colours) + "।", " Colours: " + ", ".join(colours) + ".")
    if with_cta:
        s += pick(lang, " অর্ডার করতে নাম, মোবাইল নম্বর ও পূর্ণ ঠিকানা লিখুন।",
                  " To order, send your name, mobile number and full address.")
    return s


def sizes_line(lang, p):
    sizes, colours = _variant_bits(p)
    name = p.get("name") or ""
    if not sizes and not colours:
        if int(p.get("stock") or 0) <= 0:
            return pick(lang, f"দুঃখিত, {name} এখন স্টকে নেই।", f"Sorry, {name} is out of stock.")
        return ""
    parts = []
    if sizes:
        parts.append(pick(lang, "সাইজ: " + ", ".join(sizes), "sizes: " + ", ".join(sizes)))
    if colours:
        parts.append(pick(lang, "রং: " + ", ".join(colours), "colours: " + ", ".join(colours)))
    return pick(lang, f"{name} এখন পাওয়া যাচ্ছে — " + "; ".join(parts) + "।",
                f"{name} is available in " + "; ".join(parts) + ".")


def order_status_line(lang, orders):
    if not orders:
        return ""
    o = orders[0]
    line = bai.parcel_status(o, lang)["message"]
    if o.get("payment_status") == "pending_verification":
        line += pick(lang, " পেমেন্ট যাচাইয়ের অপেক্ষায় — দোকানের মালিক যাচাই করে জানাবেন।",
                     " Payment is waiting for the owner to verify.")
    return line


def catalog_line(lang, catalog, limit=CATALOG_MAX):
    """A short list of the seller's products with their catalog prices (in
    stock first). Every number is a catalog price (post-checked by the caller);
    stock COUNTS are never stated here."""
    rows = [p for p in catalog or [] if (p.get("name") or "").strip()
            and _price_range(p)[0] is not None and (_price_range(p)[0] or 0) > 0]
    if not rows:
        return ""
    rows.sort(key=lambda p: int(p.get("stock") or 0) <= 0)
    lines = []
    for p in rows[:limit]:
        lo, hi = _price_range(p)
        price = f"৳{_money(lo)}" if lo == hi else f"৳{_money(lo)}–৳{_money(hi)}"
        out = int(p.get("stock") or 0) <= 0
        lines.append("- %s — %s%s" % (p["name"], price,
                                      pick(lang, " (স্টক নেই)", " (out of stock)") if out else ""))
    head = pick(lang, "আমাদের পণ্যগুলো:", "Here is what we have:")
    tail = pick(lang, "যেটি পছন্দ, তার নাম লিখুন — সাইজ, স্টক ও অর্ডারের নিয়ম জানিয়ে দেব।",
                "Send the name of the one you like — I'll share sizes, stock and how to order.")
    more = ""
    if len(rows) > limit:
        more = pick(lang, "\n…আরও পণ্য আছে।", "\n…and more.")
    return head + "\n" + "\n".join(lines) + more + "\n" + tail


def payment_line(lang, cod=True, note=""):
    s = pick(lang, "ক্যাশ অন ডেলিভারি — পণ্য হাতে পেয়ে টাকা দিন।",
             "Cash on delivery — pay when you receive the parcel.") if cod else ""
    if note:
        s = (s + " " + note).strip()
    if s:
        s += pick(lang, " কখনো কাউকে আপনার পিন বা OTP দেবেন না।",
                  " Never share your PIN or OTP with anyone.")
    return s


def greeting_line(lang, shop):
    shop = shop or pick(lang, "আমাদের দোকান", "our shop")
    return pick(lang, f"আসসালামু আলাইকুম! {shop}-এ স্বাগতম। কোন পণ্যটি খুঁজছেন বলুন — দাম, সাইজ ও স্টক জানিয়ে দেব।",
                f"Hello! Welcome to {shop}. Tell me which product you are looking for — I'll share the price, sizes and stock.")


# --------------------------------------------------------------- THE RULE LAYER
def answer(text, ctx):
    """Try every rule. Returns {"text", "rule", "product_id"?, "faq_id"?,
    "numbers"?} or None (= call the AI). ctx keys: lang, catalog, delivery,
    hours_text, policies {returns, payment}, faqs [{id,q,a}], orders [{id,
    status,tracking,courier,payment_status}], shop_name, cod, post_product,
    wallets [{provider, number, name}], address. `numbers` = numbers the
    reply copied from the seller's own text (size chart, wallet number) —
    the caller's post-check allows exactly those."""
    lang = ctx.get("lang") or "bn"
    low = _norm(text)
    if not low or low in ("[attachment]", "[image]", "[audio]", "[sticker]"):
        return None
    catalog = ctx.get("catalog") or []
    faqs = ctx.get("faqs")

    if BZ.asks_if_human(text):
        return {"text": bai.assistant_disclosure(lang)["full"], "rule": R_HUMAN_Q}
    if is_greeting_only(text):
        return {"text": greeting_line(lang, ctx.get("shop_name")), "rule": R_GREETING}
    # sales2: another customer's details are never shared; PIN / OTP never asked
    if is_privacy_request(text):
        return {"text": privacy_line(lang), "rule": R_PRIVACY}
    if asks_pin(text) and not _has(low, _ASK_PRICE):
        return {"text": pin_line(lang), "rule": R_PIN}

    # the seller's own approved FAQ beats generic rules
    f = faq_match(faqs, text)
    if f and (f.get("a") or "").strip():
        return {"text": f["a"].strip(), "rule": R_FAQ, "faq_id": f.get("id")}
    if is_thanks(text):
        return {"text": thanks_line(lang), "rule": R_THANKS}

    # `named` = the product the customer named; `p` falls back to the post
    # they commented on / the product this chat was just about ("L ache?")
    named = find_product(text, catalog, None)
    p = named if named is not None else (ctx.get("post_product") if not is_greeting_only(text)
                                         else None)
    asks_price = _has(low, _ASK_PRICE)
    asks_stock = _has(low, _ASK_STOCK)

    if _has(low, _ASK_STATUS):
        line = order_status_line(lang, ctx.get("orders"))
        if line:
            return {"text": line, "rule": R_ORDER_STATUS}
    # sales2: "koto dine pabo?" — the seller's FAQ, else honest (no invented day)
    if _has(low, _ASK_DTIME) and not ctx.get("orders"):
        tf = topic_faq(faqs, _ASK_DTIME)
        if tf:
            return {"text": tf["a"].strip(), "rule": R_FAQ, "faq_id": tf.get("id")}
        return {"text": delivery_time_line(lang, ctx.get("delivery")), "rule": R_DELIVERY_TIME}
    # "cash on delivery" is a PAYMENT question, not a delivery-charge one (aieval)
    asks_delivery = _has(low.replace("cash on delivery", " ").replace("ক্যাশ অন ডেলিভারি", " "),
                         _ASK_DELIVERY)
    if asks_delivery and not (named is not None and (asks_price or asks_stock)):
        area, word = area_of(text)
        line = ""
        if word or area == "outside":
            line = area_delivery_line(lang, ctx.get("delivery"), area, word)
        line = line or delivery_line(lang, ctx.get("delivery"))
        if line:
            return {"text": line, "rule": R_DELIVERY}
    if _has(low, _ASK_HOURS):
        ht = ctx.get("hours_text") or ""
        if ht:
            return {"text": pick(lang, f"আমাদের দোকান খোলা: {ht}। চ্যাটে যেকোনো সময় মেসেজ দিন।",
                                 f"Shop hours: {ht}. You can message us here any time."),
                    "rule": R_HOURS}
    # sales2: "dokan kothay?" — the seller's FAQ / booking-page address only
    if named is None and _has(low, _ASK_LOCATION) and _has(low, _SHOP_WORDS):
        tf = topic_faq(faqs, _ASK_LOCATION)
        if tf:
            return {"text": tf["a"].strip(), "rule": R_FAQ, "faq_id": tf.get("id")}
        addr = (ctx.get("address") or "").strip()
        if addr:
            return {"text": location_line(lang, addr), "rule": R_LOCATION,
                    "numbers": _NUMS.findall(BZ.norm_digits(addr))}
    if _has(low, _ASK_RETURNS):
        r = ((ctx.get("policies") or {}).get("returns") or "").strip()
        if r:
            return {"text": pick(lang, "রিটার্ন/এক্সচেঞ্জ নিয়ম: ", "Return/exchange policy: ") + r,
                    "rule": R_RETURNS}
    # sales2: bKash / Nagad / COD — also when a product is named ("Panjabi COD
    # te nite parbo?"), unless the customer asks its price / stock
    pay = _payment_answer(lang, low, ctx, with_product=named is not None)
    if pay and not (named is not None and (asks_price or asks_stock)):
        return pay
    if named is None and _has(low, _ASK_CATALOG):
        line = catalog_line(lang, catalog)
        if line:
            return {"text": line, "rule": R_CATALOG}
    if p is not None:
        if _has(low, _ASK_SIZE_GUIDE) and not asks_price:
            tf = None
            line, nums = size_guide_line(lang, p)
            if not line:
                tf = topic_faq(faqs, ("size chart", "সাইজ চার্ট", "size guide", "সাইজ গাইড",
                                      "measurement", "মাপ"))
            if tf:
                return {"text": tf["a"].strip(), "rule": R_FAQ, "faq_id": tf.get("id"),
                        "product_id": p.get("id")}
            if line:
                return {"text": line, "rule": R_SIZE_GUIDE, "product_id": p.get("id"),
                        "numbers": nums}
        vline = variant_ask_line(lang, p, text) if not asks_price else ""
        if vline:
            return {"text": vline, "rule": R_SIZES, "product_id": p.get("id")}
        if _has(low, _ASK_SIZE) and not asks_price:
            line = sizes_line(lang, p)
            if line:
                return {"text": line, "rule": R_SIZES, "product_id": p.get("id")}
        t_digits = BZ.norm_digits(text or "")
        bare = named is not None and (
            bool(_HASH_ID.search(t_digits) or _SKU_RE.search(t_digits))
            or set(tokens(text)) <= set(tokens(p.get("name") or "")))
        if asks_price or asks_stock or _has(low, _ASK_SIZE) or bare:
            card = product_card(lang, p, with_cta=not asks_delivery, catalog=catalog)
            if card:
                if asks_delivery:
                    dl = delivery_line(lang, ctx.get("delivery"))
                    card = (card + " " + dl).strip() if dl else card
                return {"text": card, "rule": R_PRODUCT, "product_id": p.get("id")}
    if pay and named is None:
        return pay
    return None


def _payment_answer(lang, low, ctx, with_product=False):
    """bKash / Nagad steps to the seller's own number, COD yes/no, or the
    general payment line. None when the customer did not ask about paying."""
    wallets = ctx.get("wallets") or []
    pol = ctx.get("policies") or {}
    note = (pol.get("payment") or "") if pol.get("payment") not in ("cash on delivery",) else ""
    cod = ctx.get("cod", True)
    for prov, words in (("bkash", _ASK_BKASH), ("nagad", _ASK_NAGAD)):
        if _has(low, words):
            line = wallet_line(lang, wallets, prov)
            if line:
                w = next(x for x in wallets if x.get("provider") == prov and
                         (x.get("number") or "").strip())
                if cod:
                    line += pick(lang, " চাইলে ক্যাশ অন ডেলিভারিও করতে পারেন।",
                                 " Cash on delivery is also available.")
                return {"text": line, "rule": R_PAYMENT,
                        "numbers": [BZ.norm_digits(w["number"]).strip()]}
    if _has(low, _ASK_COD):
        if cod:
            s = pick(lang, "হ্যাঁ, ক্যাশ অন ডেলিভারি আছে — পণ্য হাতে পেয়ে টাকা দিন।",
                     "Yes, cash on delivery is available — pay when you receive the parcel.")
            if note:
                s += " " + note
            s += pick(lang, " কখনো কাউকে আপনার পিন বা OTP দেবেন না।",
                      " Never share your PIN or OTP with anyone.")
            return {"text": s, "rule": R_PAYMENT}
        line = payment_line(lang, False, note)
        if line:
            return {"text": line, "rule": R_PAYMENT}
        return None
    if with_product:
        return None          # a bare "payment" next to a product name → the product card
    if _has(low, _ASK_PAYMENT):
        line = payment_line(lang, cod, note)
        if line and wallets:
            names = [pick(lang, "বিকাশ", "bKash") if w.get("provider") == "bkash" else
                     pick(lang, "নগদ", "Nagad") for w in wallets if (w.get("number") or "").strip()]
            if names:
                line += pick(lang, " " + " / ".join(names) + "-এও দিতে পারেন — নিয়ম জানতে \"" +
                             names[0] + "\" লিখুন।",
                             " You can also pay by " + " / ".join(names) + " — write \"" +
                             names[0] + "\" for the steps.")
        if line:
            return {"text": line, "rule": R_PAYMENT}
    return None


# --------------------------------------------------------------- stats
def rule_share(rule_n, ai_n):
    tot = int(rule_n or 0) + int(ai_n or 0)
    return round(100.0 * int(rule_n or 0) / tot, 1) if tot else 0.0


# --------------------------------------------------------------- FAQ learning
_MONEY_HINT = re.compile(r"(?:৳|tk\.?|taka|টাকা|bdt)\s*\d|\d[\d,]*\s*(?:৳|tk\b|taka|টাকা|/-)",
                         re.IGNORECASE)


def has_money(text):
    return bool(_MONEY_HINT.search(BZ.norm_digits(text or "")))


def learn_faq(pairs, existing_q=(), min_count=1, limit=20):
    """From the owner's past HUMAN replies → FAQ SUGGESTIONS the seller
    approves. `pairs` = [(customer_text, owner_reply)]. Never auto-published:
    every suggestion has status 'suggested'; an answer that states a price is
    flagged has_price=True (prices must come from the catalog, the seller must
    remove or confirm it). Greetings, very short or order-detail answers are
    skipped. Returns [{q, a, count, has_price}] most frequent first."""
    seen = {" ".join(sorted(set(tokens(q)))) for q in existing_q or ()}
    groups = {}
    for q, a in pairs or []:
        q, a = (q or "").strip(), (a or "").strip()
        if len(q) < 4 or len(a) < 8 or is_greeting_only(q):
            continue
        if BZ.find_phone(q) or BZ.find_phone(a):
            continue                      # personal order details, not an FAQ
        key_t = tokens(q)
        if not key_t or len(key_t) > 12:
            continue
        key = " ".join(sorted(set(key_t)))
        if key in seen:
            continue
        g = groups.setdefault(key, {"q": q[:300], "a": a[:1000], "count": 0})
        g["count"] += 1
        g["a"] = a[:1000]               # the latest answer wins (owner's current wording)
    out = [dict(g, has_price=has_money(g["a"])) for g in groups.values()
           if g["count"] >= min_count]
    out.sort(key=lambda g: -g["count"])
    return out[:limit]


def tone_sample(owner_replies, limit=5, max_len=400):
    """A short sample of the owner's own wording for the LLM prompt (style
    only — facts never come from here)."""
    picked = []
    for r in owner_replies or []:
        r = (r or "").strip()
        if 8 <= len(r) <= 200 and not has_money(r) and not BZ.find_phone(r):
            picked.append(r)
        if len(picked) >= limit:
            break
    return "\n".join(picked)[:max_len]
