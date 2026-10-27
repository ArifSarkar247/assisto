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
RULES = (R_GREETING, R_FAQ, R_DELIVERY, R_HOURS, R_ORDER_STATUS, R_PAYMENT, R_RETURNS,
         R_PRODUCT, R_SIZES, R_HUMAN_Q, R_CATALOG)
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
                "return policy", "can i return", "return korte", "ferot", "change kora jabe",
                "বদলানো যাবে", "পরিবর্তন করা যাবে")
_ASK_STATUS = ("অর্ডার কোথায়", "আমার অর্ডার", "পার্সেল কোথায়", "পার্সেল কই", "কবে পাবো",
               "order status", "where is my order", "where is my parcel", "track my",
               "order ki obostha", "parcel koi", "kobe pabo", "amar order", "tracking")
_ASK_SIZE = ("সাইজ", "size", "কালার", "রং", "রঙ", "colour", "color", "কোন কোন", "measurement",
             "মাপ", "available size", "koto size", "ki ki color")
_ASK_PRICE = ("দাম", "কত", "price", "dam", "daam", "koto", "rate", "cost", "মূল্য", "how much",
              "pp", "প্রাইস", "price koto", "prize")
_ASK_STOCK = ("স্টক", "stock", "আছে কি", "আছে?", "পাওয়া যাবে", "available", "ache", "ase", "pawa",
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


def product_card(lang, p, *, with_cta=True):
    """Name, price, sizes, colours, stock — every value from the catalog row."""
    name = p.get("name") or ""
    stock = int(p.get("stock") or 0)
    lo, hi = _price_range(p)
    if lo is None:
        return ""
    price = (f"৳{_money(lo)}" if lo == hi else f"৳{_money(lo)}–৳{_money(hi)}")
    if stock <= 0:
        return pick(lang, f"{name} — দাম {price}। দুঃখিত, এটি এখন স্টকে নেই।",
                    f"{name} — {price}. Sorry, it is out of stock right now.")
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
    """Try every rule. Returns {"text", "rule", "product_id"?, "faq_id"?} or None
    (= call the AI). ctx keys: lang, catalog, delivery, hours_text, policies
    {returns, payment}, faqs [{id,q,a}], orders [{id,status,tracking,courier,
    payment_status}], shop_name, cod, post_product."""
    lang = ctx.get("lang") or "bn"
    low = _norm(text)
    if not low or low in ("[attachment]", "[image]", "[audio]", "[sticker]"):
        return None
    catalog = ctx.get("catalog") or []

    if BZ.asks_if_human(text):
        return {"text": bai.assistant_disclosure(lang)["full"], "rule": R_HUMAN_Q}
    if is_greeting_only(text):
        return {"text": greeting_line(lang, ctx.get("shop_name")), "rule": R_GREETING}

    # the seller's own approved FAQ beats generic rules
    f = faq_match(ctx.get("faqs"), text)
    if f and (f.get("a") or "").strip():
        return {"text": f["a"].strip(), "rule": R_FAQ, "faq_id": f.get("id")}

    p = find_product(text, catalog, ctx.get("post_product"))

    if _has(low, _ASK_STATUS):
        line = order_status_line(lang, ctx.get("orders"))
        if line:
            return {"text": line, "rule": R_ORDER_STATUS}
    asks_delivery = _has(low, _ASK_DELIVERY)
    if asks_delivery and not (p is not None and (_has(low, _ASK_PRICE) or _has(low, _ASK_STOCK))):
        line = delivery_line(lang, ctx.get("delivery"))
        if line:
            return {"text": line, "rule": R_DELIVERY}
    if _has(low, _ASK_HOURS):
        ht = ctx.get("hours_text") or ""
        if ht:
            return {"text": pick(lang, f"আমাদের দোকান খোলা: {ht}। চ্যাটে যেকোনো সময় মেসেজ দিন।",
                                 f"Shop hours: {ht}. You can message us here any time."),
                    "rule": R_HOURS}
    if _has(low, _ASK_RETURNS):
        r = ((ctx.get("policies") or {}).get("returns") or "").strip()
        if r:
            return {"text": pick(lang, "রিটার্ন/এক্সচেঞ্জ নিয়ম: ", "Return/exchange policy: ") + r,
                    "rule": R_RETURNS}
    if p is not None:
        if _has(low, _ASK_SIZE) and not _has(low, _ASK_PRICE):
            line = sizes_line(lang, p)
            if line:
                return {"text": line, "rule": R_SIZES, "product_id": p.get("id")}
        t_digits = BZ.norm_digits(text or "")
        bare = bool(_HASH_ID.search(t_digits) or _SKU_RE.search(t_digits)) or \
            set(tokens(text)) <= set(tokens(p.get("name") or ""))
        if _has(low, _ASK_PRICE) or _has(low, _ASK_STOCK) or _has(low, _ASK_SIZE) or bare:
            card = product_card(lang, p, with_cta=not asks_delivery)
            if card:
                if asks_delivery:
                    dl = delivery_line(lang, ctx.get("delivery"))
                    card = (card + " " + dl).strip() if dl else card
                return {"text": card, "rule": R_PRODUCT, "product_id": p.get("id")}
    if p is None and _has(low, _ASK_CATALOG):
        line = catalog_line(lang, catalog)
        if line:
            return {"text": line, "rule": R_CATALOG}
    if _has(low, _ASK_PAYMENT) and not p:
        pol = ctx.get("policies") or {}
        line = payment_line(lang, ctx.get("cod", True), (pol.get("payment") or "")
                            if pol.get("payment") not in ("cash on delivery",) else "")
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
