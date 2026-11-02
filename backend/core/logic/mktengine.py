"""mktengine — Assisto Marketing Engine v1 (owner P3-D, 3 Nov; flag
`marketing_engine`). PURE: no DB, no network. core/mktengine_service.py
feeds it the business's REAL numbers and stores what it returns.

  questionnaire  10 Bangla-first steps (QUESTIONS) -> validate_answers()
  facts          real sales / catalog / CRM numbers (built by the service)
  build_plan()   -> the marketing SYSTEM as approvable items, four sections:
                    content | strategy | campaign | conversion
                    every item lists the facts it used (`uses`) so the owner
                    sees which numbers it came from.
  calendar       30 days from a start date around Bangladesh dates. Fixed
                 civic dates are exact; lunar / lunisolar ones (Ramadan, both
                 Eids, Durga Puja) come from an ESTIMATE table and are always
                 marked estimated — never shown as a fixed date.

Honesty rules (owner): prices only from the catalog; no invented sales
counts, reviews or testimonials; ad budgets are ranges labelled estimate;
AI polish may never add a number that was not in the text (numbers_ok()).
"""
import re
from datetime import date, timedelta

LANGS = ("bn", "en")
SECTIONS = ("content", "strategy", "campaign", "conversion")
STATUSES = ("draft", "approved", "rejected")
MAX_BODY = 4000
MAX_TEXT_ANSWER = 200

# retention kinds a follow-up item may turn into (core.logic.retention.KINDS)
FOLLOWUP_KINDS = ("thanks_review", "reorder", "winback", "quote_followup")


def _o(value, bn, en):
    return (value, bn, en)


# ----------------------------------------------------------------- questions
QUESTIONS = (
    {"key": "business_type", "type": "single", "required": True,
     "bn": "আপনার ব্যবসা কী ধরনের?", "en": "What kind of business is it?",
     "options": (
         _o("grocery", "মুদি / নিত্যপণ্য", "Grocery / daily needs"),
         _o("fashion", "পোশাক / ফ্যাশন", "Clothing / fashion"),
         _o("cosmetics", "কসমেটিকস / বিউটি", "Cosmetics / beauty"),
         _o("electronics", "ইলেকট্রনিক্স / মোবাইল", "Electronics / mobile"),
         _o("food", "খাবার / রেস্টুরেন্ট / হোম-কুক", "Food / restaurant / home-cook"),
         _o("pharmacy", "ফার্মেসি", "Pharmacy"),
         _o("service", "সার্ভিস (সেলুন, পার্লার, মেরামত)", "Service (salon, parlour, repair)"),
         _o("education", "কোচিং / প্রশিক্ষণ", "Coaching / training"),
         _o("other", "অন্য কিছু", "Something else"))},
    {"key": "area", "type": "text", "required": True,
     "bn": "দোকান কোথায়? (এলাকা, শহর)", "en": "Where is the shop? (area, city)",
     "hint_bn": "যেমন: মিরপুর ১০, ঢাকা", "hint_en": "e.g. Mirpur 10, Dhaka"},
    {"key": "delivery", "type": "single", "required": True,
     "bn": "কোথায় বিক্রি করেন?", "en": "Where do you sell?",
     "options": (
         _o("local", "শুধু আশেপাশে / দোকানে", "Only nearby / in the shop"),
         _o("city", "পুরো শহরে ডেলিভারি", "Delivery across the city"),
         _o("nationwide", "সারা দেশে ডেলিভারি", "Delivery across Bangladesh"))},
    {"key": "customers", "type": "multi", "required": True,
     "bn": "আপনার গ্রাহক মূলত কারা?", "en": "Who are your customers mostly?",
     "options": (
         _o("families", "পরিবার / গৃহিণী", "Families / homemakers"),
         _o("students", "ছাত্রছাত্রী", "Students"),
         _o("young", "তরুণ-তরুণী", "Young adults"),
         _o("office", "অফিসের চাকরিজীবী", "Office workers"),
         _o("women", "নারী ক্রেতা", "Women shoppers"),
         _o("elderly", "বয়স্ক মানুষ", "Older people"),
         _o("business", "অন্য দোকান / ব্যবসা", "Other shops / businesses"))},
    {"key": "price_level", "type": "single", "required": True,
     "bn": "দামের দিক থেকে আপনার দোকান কেমন?", "en": "How are your prices?",
     "options": (
         _o("budget", "কম দামে ভালো জিনিস", "Good things at low prices"),
         _o("mid", "মাঝারি দাম, ভালো মান", "Fair prices, good quality"),
         _o("premium", "প্রিমিয়াম / উঁচু মান", "Premium / top quality"))},
    {"key": "goals", "type": "multi", "required": True,
     "bn": "এই মাসে সবচেয়ে বেশি কী চান?", "en": "What do you want most this month?",
     "options": (
         _o("more_sales", "বিক্রি বাড়ানো", "More sales"),
         _o("new_customers", "নতুন গ্রাহক", "New customers"),
         _o("repeat", "পুরোনো গ্রাহক বারবার আসুক", "Old customers coming back"),
         _o("launch", "নতুন পণ্য চালু", "Launch a new product"),
         _o("clear_stock", "জমে থাকা মাল বিক্রি", "Clear slow stock"),
         _o("brand", "নাম পরিচিত করা", "Make the name known"))},
    {"key": "budget", "type": "single", "required": True,
     "bn": "বিজ্ঞাপনে মাসে কত খরচ করতে পারবেন?", "en": "How much can you spend on ads per month?",
     "options": (
         _o("0", "এখন কিছু না (ফ্রি পোস্ট)", "Nothing now (free posts only)"),
         _o("lt2k", "৳২,০০০-এর কম", "Under ৳2,000"),
         _o("2k_5k", "৳২,০০০–৫,০০০", "৳2,000–5,000"),
         _o("5k_15k", "৳৫,০০০–১৫,০০০", "৳5,000–15,000"),
         _o("15k_plus", "৳১৫,০০০-এর বেশি", "Over ৳15,000"))},
    {"key": "channels", "type": "multi", "required": True,
     "bn": "কোথায় কোথায় আছেন / থাকতে চান?", "en": "Where are you (or want to be)?",
     "options": (
         _o("facebook", "Facebook পেজ", "Facebook Page"),
         _o("instagram", "Instagram", "Instagram"),
         _o("whatsapp", "WhatsApp", "WhatsApp"),
         _o("tiktok", "TikTok", "TikTok"),
         _o("youtube", "YouTube", "YouTube"),
         _o("in_store", "দোকানে (পোস্টার, ব্যানার)", "In the shop (posters, banners)"))},
    {"key": "tone", "type": "single", "required": True,
     "bn": "আপনার কথার ধরন কেমন হবে?", "en": "How should you sound?",
     "options": (
         _o("friendly", "বন্ধুর মতো, আপন", "Friendly, warm"),
         _o("trust", "ভরসার, বিশেষজ্ঞের মতো", "Trustworthy, expert"),
         _o("premium", "রুচিশীল, প্রিমিয়াম", "Classy, premium"),
         _o("fun", "মজার, হাসিখুশি", "Fun, cheerful"))},
    {"key": "offers", "type": "multi", "required": True,
     "bn": "কোন অফার দিতে রাজি?", "en": "Which offers are you OK to give?",
     "options": (
         _o("discount", "ছাড় (%)", "Discount (%)"),
         _o("free_delivery", "ফ্রি ডেলিভারি", "Free delivery"),
         _o("combo", "কম্বো / একসাথে কিনলে কম", "Combo / bundle price"),
         _o("gift", "সাথে ছোট উপহার", "Small free gift"),
         _o("loyalty", "নিয়মিত গ্রাহকের জন্য বিশেষ সুবিধা", "Regular-customer perk"),
         _o("none", "এখন কোনো অফার না", "No offers now"))},
    {"key": "usp", "type": "text", "required": False,
     "bn": "আপনাকে অন্যদের থেকে আলাদা করে কী? (না লিখলেও চলবে)",
     "en": "What makes you different? (optional)",
     "hint_bn": "যেমন: ১০ বছরের পুরোনো দোকান, নিজের হাতে বানানো, এক দামে",
     "hint_en": "e.g. 10-year-old shop, handmade, fixed price"},
)
Q_BY_KEY = {q["key"]: q for q in QUESTIONS}
N_STEPS = len(QUESTIONS)


def questions_for(lang):
    """The questionnaire in one language, ready for the app."""
    out = []
    for q in QUESTIONS:
        row = {"key": q["key"], "type": q["type"], "required": q["required"],
               "label": q["en"] if lang == "en" else q["bn"]}
        if "hint_bn" in q:
            row["hint"] = q["hint_en"] if lang == "en" else q["hint_bn"]
        if "options" in q:
            row["options"] = [{"value": v, "label": en if lang == "en" else bn}
                              for v, bn, en in q["options"]]
        out.append(row)
    return out


def validate_answers(raw, partial=False):
    """Owner answers -> (clean, problems). `partial` allows saving a draft
    mid-way (only known keys / values are kept)."""
    d = raw if isinstance(raw, dict) else {}
    clean, problems = {}, []
    for q in QUESTIONS:
        k = q["key"]
        v = d.get(k)
        if q["type"] == "text":
            s = re.sub(r"\s+", " ", str(v or "")).strip()[:MAX_TEXT_ANSWER]
            if s:
                clean[k] = s
        elif q["type"] == "single":
            allowed = {o[0] for o in q["options"]}
            if v in allowed:
                clean[k] = v
            elif v not in (None, ""):
                problems.append("bad_" + k)
        else:
            allowed = [o[0] for o in q["options"]]
            vals = v if isinstance(v, (list, tuple)) else []
            picked = [x for x in allowed if x in vals]
            if any(x not in allowed for x in vals):
                problems.append("bad_" + k)
            if k == "offers" and "none" in picked and len(picked) > 1:
                picked = [x for x in picked if x != "none"]
            if picked:
                clean[k] = picked
        if not partial and q["required"] and k not in clean and "bad_" + k not in problems:
            problems.append("missing_" + k)
    return clean, problems


def is_complete(answers):
    return not validate_answers(answers)[1]


def label(key, value, lang):
    q = Q_BY_KEY.get(key) or {}
    for v, bn, en in q.get("options", ()):
        if v == value:
            return en if lang == "en" else bn
    return str(value or "")


# ----------------------------------------------------------------- numbers
_BN0 = 0x09E6


def bn_digits(s):
    return "".join(chr(_BN0 + int(c)) if c.isdigit() and c.isascii() else c for c in str(s))


def ascii_digits(s):
    return "".join(str(ord(c) - _BN0) if _BN0 <= ord(c) <= _BN0 + 9 else c for c in str(s))


def num(n, lang):
    s = "{:,}".format(int(n))
    return s if lang == "en" else bn_digits(s)


def taka(amount, lang):
    """Catalog price (taka, Decimal/float/int) -> '৳1,250' (Bangla digits in bn).
    Paisa are kept only when not whole."""
    try:
        a = float(amount)
    except (TypeError, ValueError):
        return ""
    if abs(a - round(a)) < 0.005:
        s = "{:,}".format(int(round(a)))
    else:
        s = "{:,.2f}".format(a)
    return "৳" + (s if lang == "en" else bn_digits(s))


_NUM_RE = re.compile(r"\d[\d,]*(?:\.\d+)?")


def numbers_in(text):
    """Every number in a text (Bangla or Latin digits), commas removed."""
    t = ascii_digits(text or "")
    return {m.group(0).replace(",", "").rstrip(".") for m in _NUM_RE.finditer(t)}


def numbers_ok(original, rewritten):
    """AI polish guard: the rewrite may drop numbers but never add one
    (a new price, a fake '500 customers', a different date)."""
    return numbers_in(rewritten) <= numbers_in(original)


# ----------------------------------------------------------------- calendar
# Fixed civic / commercial dates (exact every year).
FIXED_DATES = (
    (1, 1, "new_year", "ইংরেজি নববর্ষ", "New Year's Day"),
    (2, 14, "falgun", "পহেলা ফাল্গুন ও ভালোবাসা দিবস", "Pohela Falgun & Valentine's Day"),
    (2, 21, "ekushe", "২১ ফেব্রুয়ারি — শহীদ দিবস ও আন্তর্জাতিক মাতৃভাষা দিবস",
     "21 February — Language Martyrs' Day"),
    (3, 26, "independence", "২৬ মার্চ — স্বাধীনতা দিবস", "26 March — Independence Day"),
    (4, 14, "boishakh", "পহেলা বৈশাখ — বাংলা নববর্ষ", "Pohela Boishakh — Bangla New Year"),
    (11, 11, "1111", "১১.১১ অনলাইন সেল দিবস", "11.11 online sale day"),
    (12, 16, "victory", "১৬ ডিসেম্বর — বিজয় দিবস", "16 December — Victory Day"),
)
# Respectful days: no "sale" push, a tribute post only.
SOLEMN = {"ekushe"}

# Lunar / lunisolar dates — ESTIMATES (astronomical calculation; the moon
# sighting committee / panjika decides). Always shown with estimated=True
# and a "may move by 1–2 days" note. Never used as a fixed date.
ESTIMATED_DATES = (
    (date(2026, 2, 18), "ramadan", "রমজান শুরু", "Ramadan begins"),
    (date(2026, 3, 20), "eid_fitr", "ঈদুল ফিতর", "Eid ul-Fitr"),
    (date(2026, 5, 27), "eid_adha", "ঈদুল আজহা", "Eid ul-Adha"),
    (date(2026, 10, 20), "durga_puja", "দুর্গাপূজা (বিজয়া দশমী)", "Durga Puja (Bijoya Dashami)"),
    (date(2027, 2, 8), "ramadan", "রমজান শুরু", "Ramadan begins"),
    (date(2027, 3, 10), "eid_fitr", "ঈদুল ফিতর", "Eid ul-Fitr"),
    (date(2027, 5, 17), "eid_adha", "ঈদুল আজহা", "Eid ul-Adha"),
    (date(2027, 10, 9), "durga_puja", "দুর্গাপূজা (বিজয়া দশমী)", "Durga Puja (Bijoya Dashami)"),
    (date(2028, 1, 28), "ramadan", "রমজান শুরু", "Ramadan begins"),
    (date(2028, 2, 27), "eid_fitr", "ঈদুল ফিতর", "Eid ul-Fitr"),
    (date(2028, 5, 5), "eid_adha", "ঈদুল আজহা", "Eid ul-Adha"),
)
EST_NOTE = ("চাঁদ দেখা / পঞ্জিকা অনুযায়ী ১–২ দিন আগে-পিছে হতে পারে — আনুমানিক",
            "May move 1–2 days with moon sighting / almanac — estimated")


def _nth_weekday(y, m, weekday, n):
    d = date(y, m, 1)
    d += timedelta(days=(weekday - d.weekday()) % 7)
    return d + timedelta(weeks=n - 1)


def computed_dates(year):
    """Dates that follow a weekday rule (exact)."""
    thanksgiving = _nth_weekday(year, 11, 3, 4)          # 4th Thursday of Nov
    return (
        (thanksgiving + timedelta(days=1), "black_friday", "ব্ল্যাক ফ্রাইডে সেল", "Black Friday sale"),
        (_nth_weekday(year, 5, 6, 2), "mothers_day", "মা দিবস", "Mother's Day"),
        (_nth_weekday(year, 6, 6, 3), "fathers_day", "বাবা দিবস", "Father's Day"),
        # Bangladesh's school year starts in January: prep from 20 Dec.
        (date(year, 12, 20), "school", "নতুন ক্লাসের প্রস্তুতি (স্কুল খোলার মৌসুম)",
         "Back-to-school season (new class year)"),
    )


def events_between(start, end, lang="bn"):
    """Every special date in [start, end] sorted, each
    {date, key, title, estimated, note, solemn}."""
    out = []
    for y in range(start.year, end.year + 1):
        for m, d, key, bn, en in FIXED_DATES:
            out.append((date(y, m, d), key, bn, en, False))
        for dt, key, bn, en in computed_dates(y):
            out.append((dt, key, bn, en, False))
    for dt, key, bn, en in ESTIMATED_DATES:
        out.append((dt, key, bn, en, True))
    rows = []
    for dt, key, bn, en, est in sorted(out, key=lambda r: r[0]):
        if start <= dt <= end:
            rows.append({"date": dt.isoformat(), "key": key,
                         "title": en if lang == "en" else bn,
                         "estimated": est,
                         "note": (EST_NOTE[1] if lang == "en" else EST_NOTE[0]) if est else "",
                         "solemn": key in SOLEMN})
    return rows


# ----------------------------------------------------------------- helpers
def _L(lang, bn, en):
    return en if lang == "en" else bn


def _tone_word(tone, lang):
    return {
        "friendly": _L(lang, "আপনজনের মতো", "warm"),
        "trust": _L(lang, "ভরসার", "trusted"),
        "premium": _L(lang, "রুচিশীল", "classy"),
        "fun": _L(lang, "হাসিখুশি", "cheerful"),
    }.get(tone, _L(lang, "আপনজনের মতো", "warm"))


def _shop(facts, lang):
    return (facts.get("shop") or "").strip() or _L(lang, "আমাদের দোকান", "our shop")


def _offer_line(answers, lang):
    o = answers.get("offers") or []
    if "free_delivery" in o:
        return _L(lang, "এই সপ্তাহে ফ্রি ডেলিভারি (শর্ত দোকান ঠিক করবে)",
                  "Free delivery this week (shop's terms apply)")
    if "combo" in o:
        return _L(lang, "একসাথে কিনলে কম দাম — কম্বো জিজ্ঞেস করুন", "Buy together, pay less — ask for the combo")
    if "gift" in o:
        return _L(lang, "কেনাকাটায় সাথে ছোট উপহার", "A small free gift with your order")
    if "discount" in o:
        return _L(lang, "বিশেষ ছাড় চলছে — ছাড়ের হার আপনি বসিয়ে নিন",
                  "Special discount on — put your own % here")
    if "loyalty" in o:
        return _L(lang, "নিয়মিত গ্রাহকের জন্য বিশেষ সুবিধা", "A perk for our regular customers")
    return ""


def _cta(answers, lang):
    ch = answers.get("channels") or []
    if "whatsapp" in ch:
        return _L(lang, "অর্ডার করতে ইনবক্স বা WhatsApp করুন।", "Order by inbox or WhatsApp.")
    if answers.get("delivery") == "local":
        return _L(lang, "আজই দোকানে চলে আসুন।", "Drop by the shop today.")
    return _L(lang, "অর্ডার করতে ইনবক্স করুন।", "Inbox us to order.")


def _hashtags(answers, facts, lang):
    tags = []
    area = (answers.get("area") or "").split(",")[0].strip().replace(" ", "")
    if area:
        tags.append("#" + area)
    shop = (facts.get("shop") or "").replace(" ", "")
    if shop:
        tags.append("#" + shop)
    tags.append("#" + {"grocery": "BazarList", "fashion": "BDFashion", "cosmetics": "BeautyBD",
                       "electronics": "GadgetBD", "food": "FoodieBD", "pharmacy": "HealthBD",
                       "service": "ServiceBD", "education": "LearnBD"}.get(
                           answers.get("business_type"), "ShopBD"))
    return " ".join(tags)


def _products_for_posts(facts):
    """Real catalog products with a price, best sellers first."""
    seen, out = set(), []
    for p in (facts.get("top_products") or []) + (facts.get("catalog") or []):
        n = (p.get("name") or "").strip()
        if not n or n in seen or not p.get("price"):
            continue
        seen.add(n)
        out.append(p)
    return out


def _item(iid, section, kind, title, body, uses, **extra):
    d = {"id": iid, "section": section, "kind": kind, "title": title[:160],
         "body": body[:MAX_BODY], "uses": list(uses), "status": "draft"}
    d.update(extra)
    return d


# ----------------------------------------------------------------- content
def _post_body(p, answers, facts, lang, idx):
    shop, tone = _shop(facts, lang), answers.get("tone", "friendly")
    price = taka(p["price"], lang)
    name = p["name"]
    best = int(p.get("qty") or 0) >= 3
    hooks = {
        "friendly": _L(lang, "এটা না দেখলে মিস করবেন!", "You don't want to miss this!"),
        "trust": _L(lang, "যাচাই করা মান, ন্যায্য দাম।", "Checked quality, fair price."),
        "premium": _L(lang, "রুচির সাথে কোনো আপস নয়।", "No compromise on taste."),
        "fun": _L(lang, "মন ভালো করার মতো একটা জিনিস!", "Something to make your day!"),
    }
    hook = hooks.get(tone, hooks["friendly"])
    if best:
        hook = _L(lang, "আমাদের দোকানে সবচেয়ে বেশি চলা জিনিসগুলোর একটা: ",
                  "One of the most-bought items in our shop: ") + name
    lines = [hook, "",
             "%s — %s" % (name, price)]
    if p.get("description"):
        lines.append(str(p["description"])[:160])
    off = _offer_line(answers, lang) if idx == 0 else ""
    if off:
        lines.append(off)
    lines += ["", _cta(answers, lang) + " — " + shop, "", _hashtags(answers, facts, lang)]
    return "\n".join(lines)


def content_items(answers, facts, lang):
    items, prods = [], _products_for_posts(facts)
    shop = _shop(facts, lang)
    for i, p in enumerate(prods[:3]):
        uses = ["catalog_price"] + (["top_products"] if p in (facts.get("top_products") or []) else [])
        items.append(_item("post%d" % (i + 1), "content", "post",
                           _L(lang, "পোস্ট: ", "Post: ") + p["name"],
                           _post_body(p, answers, facts, lang, i), uses,
                           product=p["name"], price=float(p["price"])))
    if not prods:
        items.append(_item("post1", "content", "post",
                           _L(lang, "পোস্ট: আমাদের দোকানের পরিচয়", "Post: meet our shop"),
                           "\n".join([
                               _L(lang, "আমরা %s।" % shop, "We are %s." % shop),
                               (answers.get("usp") or _L(lang, "এলাকার মানুষের ভরসার দোকান।",
                                                         "A shop the neighbourhood trusts.")),
                               _cta(answers, lang), "", _hashtags(answers, facts, lang)]),
                           ["questionnaire"], needs=_L(lang, "ক্যাটালগে পণ্য ও দাম যোগ করলে পণ্যের পোস্ট তৈরি হবে",
                                                      "Add products with prices to the catalog to get product posts")))
    # hooks
    first = prods[0]["name"] if prods else _L(lang, "আমাদের পণ্য", "our products")
    hooks = [
        _L(lang, "%s কেনার আগে এই ৩টা জিনিস দেখে নিন" % first, "3 things to check before you buy %s" % first),
        _L(lang, "দোকানে সবাই যেটা জিজ্ঞেস করে…", "The question every customer asks us…"),
        _L(lang, "%s-এর দাম এক মিনিটে" % first, "%s price in one minute" % first),
        _L(lang, "আমাদের দোকানের একটা দিন — পেছনের গল্প", "A day in our shop — behind the scenes"),
        _L(lang, "ভুল জিনিস কিনে ঠকবেন না — এভাবে চিনুন", "Don't get the wrong one — here's how to tell"),
    ]
    items.append(_item("hooks", "content", "hooks", _L(lang, "৫টা হুক (প্রথম লাইন)", "5 hooks (opening lines)"),
                       "\n".join("%s. %s" % (num(i + 1, lang), h) for i, h in enumerate(hooks)),
                       ["catalog_price"] if prods else ["questionnaire"]))
    # reels ideas
    reels = [
        _L(lang, "আনবক্সিং: %s খুলে দেখান, দাম স্ক্রিনে লিখুন" % first,
           "Unboxing: open %s on camera, price on screen" % first),
        _L(lang, "গ্রাহকের সবচেয়ে কমন প্রশ্নের উত্তর (১৫ সেকেন্ড)", "Answer the most common customer question (15 s)"),
        _L(lang, "সকালে দোকান খোলার দৃশ্য — %s" % shop, "Opening the shop in the morning — %s" % shop),
    ]
    if "fashion" == answers.get("business_type") or "cosmetics" == answers.get("business_type"):
        reels.append(_L(lang, "একই পণ্য ৩ ভাবে ব্যবহার / পরা", "One item, 3 ways to wear / use"))
    items.append(_item("reels", "content", "reels", _L(lang, "রিল / ভিডিওর আইডিয়া", "Reel / short video ideas"),
                       "\n".join("• " + r for r in reels), ["questionnaire"]))
    # short scripts
    if prods:
        p = prods[0]
        script = "\n".join([
            _L(lang, "০–৩ সেকেন্ড (হুক): ", "0–3 s (hook): ") + hooks[2],
            _L(lang, "৩–১০ সেকেন্ড: পণ্যটা হাতে নিয়ে কাছ থেকে দেখান — %s" % p["name"],
               "3–10 s: hold the item close to camera — %s" % p["name"]),
            _L(lang, "১০–১৮ সেকেন্ড: দাম বলুন — %s" % taka(p["price"], lang),
               "10–18 s: say the price — %s" % taka(p["price"], "en")),
            _L(lang, "১৮–২৫ সেকেন্ড: ", "18–25 s: ") + _cta(answers, lang),
        ])
        items.append(_item("script1", "content", "script",
                           _L(lang, "২৫ সেকেন্ডের ভিডিও স্ক্রিপ্ট: ", "25-second video script: ") + p["name"],
                           script, ["catalog_price"], product=p["name"]))
    # poster text (slow mover first: that's the stock to move)
    slow = [s for s in (facts.get("slow_movers") or []) if s.get("price")]
    pp = slow[0] if slow else (prods[0] if prods else None)
    if pp:
        off = _offer_line(answers, lang)
        body = "\n".join(x for x in [
            _L(lang, "শিরোনাম: ", "Headline: ") + pp["name"],
            _L(lang, "দাম: ", "Price: ") + taka(pp["price"], lang),
            (_L(lang, "অফার: ", "Offer: ") + off) if off else "",
            _L(lang, "নিচে: ", "Footer: ") + shop + ((" · " + answers["area"]) if answers.get("area") else ""),
        ] if x)
        items.append(_item("poster1", "content", "poster",
                           _L(lang, "পোস্টারের লেখা: ", "Poster text: ") + pp["name"], body,
                           ["catalog_price"] + (["slow_movers"] if slow else []), product=pp["name"]))
    return items


def calendar_item(answers, facts, lang, start):
    """30 days from `start`: post slots (Sat / Mon / Wed + a reel on Thu)
    plus every special date inside the window (and a lead-in post 5 days
    before when that falls inside too)."""
    end = start + timedelta(days=29)
    events = events_between(start, end, lang)
    prods = _products_for_posts(facts)
    rows = []
    rot = [_L(lang, "পণ্যের পোস্ট: %s", "Product post: %s"),
           _L(lang, "টিপস পোস্ট (কীভাবে ভালো জিনিস চিনবেন)", "Tip post (how to pick a good one)"),
           _L(lang, "গ্রাহকের প্রশ্নের উত্তর", "Answer a customer question")]
    reel_on = bool({"facebook", "instagram", "tiktok", "youtube"} & set(answers.get("channels") or []))
    k = 0
    for i in range(30):
        d = start + timedelta(days=i)
        if d.weekday() in (5, 0, 2):            # Sat, Mon, Wed
            t = rot[k % len(rot)]
            if "%s" in t:
                t = t % (prods[(k // len(rot)) % len(prods)]["name"] if prods
                         else _L(lang, "দোকানের পরিচয়", "about the shop"))
            rows.append({"date": d.isoformat(), "type": "post", "title": t, "estimated": False})
            k += 1
        elif d.weekday() == 3 and reel_on:      # Thu
            rows.append({"date": d.isoformat(), "type": "reel",
                         "title": _L(lang, "রিল (আইডিয়া তালিকা থেকে একটা)", "Reel (one from the ideas list)"),
                         "estimated": False})
    for e in events:
        ed = date.fromisoformat(e["date"])
        lead = ed - timedelta(days=5)
        if lead >= start and not e["solemn"]:
            rows.append({"date": lead.isoformat(), "type": "lead_in",
                         "title": _L(lang, "%s আসছে — আগাম অফারের পোস্ট" % e["title"],
                                     "%s is coming — early offer post" % e["title"]),
                         "estimated": e["estimated"], "note": e["note"]})
        rows.append({"date": e["date"], "type": "special",
                     "title": (_L(lang, "শ্রদ্ধা জানিয়ে পোস্ট (বিক্রির কথা নয়): ",
                                  "Tribute post (no selling): ") if e["solemn"]
                               else _L(lang, "উৎসবের পোস্ট: ", "Festival post: ")) + e["title"],
                     "estimated": e["estimated"], "note": e["note"]})
    rows.sort(key=lambda r: r["date"])
    upcoming = events_between(end + timedelta(days=1), end + timedelta(days=120), lang)
    body_lines = []
    for r in rows:
        d = date.fromisoformat(r["date"])
        ds = "%s/%s" % (num(d.day, lang), num(d.month, lang))
        est = _L(lang, " (আনুমানিক)", " (estimated)") if r.get("estimated") else ""
        body_lines.append("%s — %s%s" % (ds, r["title"], est))
    return _item("calendar", "content", "calendar",
                 _L(lang, "৩০ দিনের কনটেন্ট ক্যালেন্ডার", "30-day content calendar"),
                 "\n".join(body_lines), ["bd_calendar", "questionnaire"] + (["catalog_price"] if prods else []),
                 entries=rows, upcoming=upcoming, start=start.isoformat(), end=end.isoformat())


# ----------------------------------------------------------------- strategy
_PLATFORM = {
    "facebook": ("Facebook: সপ্তাহে ৩টা পোস্ট + ১টা রিল। পণ্যের ছবিতে দাম লিখুন। কমেন্টে দাম জিজ্ঞেস করলে ইনবক্সে উত্তর দিন।",
                 "Facebook: 3 posts + 1 reel a week. Put the price on product photos. Answer price comments in the inbox."),
    "instagram": ("Instagram: রিল আর ক্যারোসেল বেশি। প্রথম লাইনেই হুক। বায়োতে WhatsApp নম্বর।",
                  "Instagram: more reels and carousels. Hook in the first line. WhatsApp number in the bio."),
    "whatsapp": ("WhatsApp: শুধু যাঁরা রাজি হয়েছেন তাঁদের কাছে, সপ্তাহে সর্বোচ্চ ১টা আপডেট। Status-এ নতুন মাল।",
                 "WhatsApp: only people who agreed, max 1 update a week. New stock on Status."),
    "tiktok": ("TikTok: ১৫–২৫ সেকেন্ডের ভিডিও, ট্রেন্ডিং সাউন্ড, পণ্য হাতে নিয়ে দেখান।",
               "TikTok: 15–25 s videos, trending sound, show the item in hand."),
    "youtube": ("YouTube: মাসে ১–২টা Shorts, আর একটা লম্বা ভিডিও (পণ্য তুলনা বা কীভাবে ব্যবহার করবেন)।",
                "YouTube: 1–2 Shorts a month plus one longer video (compare or how-to)."),
    "in_store": ("দোকানে: কাউন্টারে দামসহ পোস্টার, QR দিয়ে Facebook পেজ, রসিদে WhatsApp নম্বর।",
                 "In store: price poster at the counter, a QR to your Page, WhatsApp number on the receipt."),
}


def strategy_items(answers, facts, lang):
    shop = _shop(facts, lang)
    cust = ", ".join(label("customers", c, lang) for c in (answers.get("customers") or []))
    price = label("price_level", answers.get("price_level"), lang)
    usp = answers.get("usp") or ""
    area = answers.get("area") or _L(lang, "আপনার এলাকা", "your area")
    pos = _L(lang,
             "%s — %s-এ %s জন্য একটি %s দোকান। দামের ধরন: %s।%s" % (
                 shop, area, (cust + "-এর") if cust else "সবার", _tone_word(answers.get("tone"), lang),
                 price, (" আমাদের আলাদা দিক: " + usp) if usp else ""),
             "%s is a %s shop in %s for %s. Prices: %s.%s" % (
                 shop, _tone_word(answers.get("tone"), lang), area,
                 cust or "everyone", price.lower(), (" What sets us apart: " + usp) if usp else ""))
    items = [_item("positioning", "strategy", "positioning",
                   _L(lang, "পজিশনিং (আপনি কে, কার জন্য)", "Positioning (who you are, for whom)"),
                   pos, ["questionnaire"])]
    plat = [(_PLATFORM[c][1] if lang == "en" else _PLATFORM[c][0])
            for c in (answers.get("channels") or []) if c in _PLATFORM]
    items.append(_item("platforms", "strategy", "platform_plan",
                       _L(lang, "প্ল্যাটফর্ম পরিকল্পনা", "Platform plan"),
                       "\n".join("• " + p for p in plat) + "\n\n" + _L(
                           lang, "এগুলো সাধারণ পরামর্শ; আপনার নিজের ফলাফল দেখে বদলান।",
                           "General guidance; adjust to your own results."), ["questionnaire"]))
    funnel = [
        _L(lang, "১. জানা (Awareness): ক্যালেন্ডারের পোস্ট ও রিল; বাজেট থাকলে ছোট বুস্ট।",
           "1. Awareness: calendar posts and reels; a small boost if you have budget."),
        _L(lang, "২. আগ্রহ (Interest): দাম জিজ্ঞেস করলে AI সেলস এজেন্ট / আপনি ইনবক্সে আসল দাম বলেন; লিড CRM-এ ওঠে।",
           "2. Interest: price questions get the real price in the inbox (AI sales agent or you); the lead lands in CRM."),
        _L(lang, "৩. অর্ডার (Order): COD / বিকাশে অর্ডার; POS-এ বিক্রি লেখা।",
           "3. Order: COD / bKash order; sale recorded in POS."),
        _L(lang, "৪. আবার কেনা (Repeat): ধন্যবাদ, আবার লাগবে কি না, অনেক দিন না এলে মনে করানো — নিচের ফলো-আপ।",
           "4. Repeat: thank-you, reorder nudge, we-miss-you — the follow-ups below."),
    ]
    uses = ["questionnaire"]
    if facts.get("sales_90d_count"):
        funnel.append(_L(lang, "আপনার আসল হিসাব (গত ৯০ দিন): %s বিক্রি, %s জন বারবার কেনা গ্রাহক।" % (
            num(facts["sales_90d_count"], lang), num(facts.get("repeat_customers", 0), lang)),
            "Your real numbers (last 90 days): %s sales, %s repeat customers." % (
            num(facts["sales_90d_count"], lang), num(facts.get("repeat_customers", 0), lang))))
        uses += ["sales_90d", "repeat_customers"]
    items.append(_item("funnel", "strategy", "funnel", _L(lang, "বিক্রির ফানেল", "Sales funnel"),
                       "\n".join(funnel), uses))
    return items


# ----------------------------------------------------------------- campaigns
BUDGET_RANGE = {"0": (0, 0), "lt2k": (500, 2000), "2k_5k": (2000, 5000),
                "5k_15k": (5000, 15000), "15k_plus": (15000, 40000)}


def campaign_items(answers, facts, lang, start):
    items, prods = [], _products_for_posts(facts)
    goals = set(answers.get("goals") or [])
    shop = _shop(facts, lang)
    if prods and ("launch" in goals or "new_customers" in goals or "brand" in goals):
        p = facts.get("newest") if facts.get("newest", {}).get("price") else prods[0]
        items.append(_item("launch", "campaign", "launch",
                           _L(lang, "লঞ্চ ক্যাম্পেইন: ", "Launch campaign: ") + p["name"],
                           "\n".join([
                               _L(lang, "দিন ১: টিজার — \"নতুন কিছু আসছে\" (ছবি আধা ঢাকা)", "Day 1: teaser — \"something new is coming\""),
                               _L(lang, "দিন ৩: উন্মোচন — %s, দাম %s" % (p["name"], taka(p["price"], lang)),
                                  "Day 3: reveal — %s at %s" % (p["name"], taka(p["price"], lang))),
                               _L(lang, "দিন ৪–৭: রিল + গ্রাহকের প্রশ্নের উত্তর", "Day 4–7: reel + answer customer questions"),
                               _L(lang, "দিন ৮: যাঁরা জিজ্ঞেস করেছেন তাঁদের ফলো-আপ (CRM)", "Day 8: follow up everyone who asked (CRM)"),
                           ]), ["catalog_price"], product=p["name"]))
    slow = [s for s in (facts.get("slow_movers") or []) if s.get("price")]
    offers = answers.get("offers") or []
    if slow and "none" not in offers:
        names = ", ".join("%s (%s)" % (s["name"], taka(s["price"], lang)) for s in slow[:3])
        items.append(_item("clearance", "campaign", "offer",
                           _L(lang, "অফার ক্যাম্পেইন: জমে থাকা মাল", "Offer campaign: slow stock"),
                           "\n".join([
                               _L(lang, "এই পণ্যগুলো গত ৬০ দিনে বিক্রি হয়নি অথচ স্টকে আছে: ", "These are in stock but did not sell in the last 60 days: ") + names,
                               _offer_line(answers, lang) or _L(lang, "কম্বো বা ছোট উপহার দিয়ে চেষ্টা করুন", "Try a combo or a small gift"),
                               _L(lang, "৭ দিন চালান, তারপর বিক্রি দেখে থামান বা চালিয়ে যান।", "Run 7 days, then keep or stop based on sales."),
                           ]), ["slow_movers", "catalog_price"]))
    nxt = [e for e in events_between(start, start + timedelta(days=60), lang) if not e["solemn"]]
    if nxt:
        e = nxt[0]
        ed = date.fromisoformat(e["date"])
        top = prods[0]["name"] if prods else _L(lang, "জনপ্রিয় পণ্য", "popular items")
        est = (" — " + e["note"]) if e["estimated"] else ""
        items.append(_item("seasonal", "campaign", "seasonal",
                           _L(lang, "মৌসুমি ক্যাম্পেইন: ", "Seasonal campaign: ") + e["title"],
                           "\n".join([
                               _L(lang, "তারিখ: %s/%s/%s%s" % (num(ed.day, lang), num(ed.month, lang), num(ed.year, lang), est),
                                  "Date: %s%s" % (ed.isoformat(), est)),
                               _L(lang, "১০ দিন আগে থেকে প্রস্তুতি: %s-এর স্টক দেখুন" % top,
                                  "Prepare 10 days ahead: check stock of %s" % top),
                               _L(lang, "৫ দিন আগে: আগাম অফারের পোস্ট", "5 days before: early-offer post"),
                               _L(lang, "দিনের দিন: শুভেচ্ছা পোস্ট + দোকানের সময়", "On the day: greeting post + shop hours"),
                           ]), ["bd_calendar"] + (["catalog_price"] if prods else []),
                           event=e))
    lo, hi = BUDGET_RANGE.get(answers.get("budget"), (0, 0))
    if hi == 0:
        body = _L(lang, "এখন বিজ্ঞাপনের বাজেট নেই — শুধু ফ্রি পোস্ট, রিল আর গ্রাহকের ফলো-আপ। বিক্রি বাড়লে ছোট বাজেট (দিনে ৳২০০–৩০০) দিয়ে শুরু করবেন।",
                  "No ad budget now — free posts, reels and customer follow-ups only. When sales grow, start small (৳200–300 a day).")
    else:
        body = "\n".join([
            _L(lang, "মাসিক বাজেট (আপনার উত্তর): %s–%s" % (taka(lo, lang), taka(hi, lang)),
               "Monthly budget (your answer): %s–%s" % (taka(lo, lang), taka(hi, lang))),
            _L(lang, "ভাগ (অনুমান): ৬০% সবচেয়ে ভালো পোস্টের বুস্ট, ৩০% মেসেজ-বিজ্ঞাপন (ইনবক্সে অর্ডার), ১০% নতুন কিছু পরীক্ষা",
               "Split (estimate): 60% boost your best post, 30% message ads (orders in inbox), 10% testing something new"),
            _L(lang, "দৈনিক (অনুমান): %s–%s" % (taka(lo // 30, lang), taka(hi // 30, lang)),
               "Per day (estimate): %s–%s" % (taka(lo // 30, lang), taka(hi // 30, lang))),
            _L(lang, "মাপুন অর্ডার দিয়ে, লাইক দিয়ে নয়: যে বিজ্ঞাপনে ইনবক্স থেকে অর্ডার আসে, সেটাই রাখুন।",
               "Judge by orders, not likes: keep the ad whose inbox messages turn into orders."),
            _L(lang, "এগুলো অনুমান; Meta-র আসল খরচ এলাকা ও সময়ভেদে আলাদা।",
               "These are estimates; real Meta costs vary by area and season."),
        ])
    items.append(_item("ads", "campaign", "ads", _L(lang, "বিজ্ঞাপনের পরামর্শ (অনুমান)", "Ad recommendation (estimate)"),
                       body, ["questionnaire"], estimate=True, budget_min=lo, budget_max=hi))
    return items


# ----------------------------------------------------------------- conversion
_FOLLOW_TPL = {
    "thanks_review": {
        "friendly": ("{name}, {shop} থেকে কেনার জন্য অনেক ধন্যবাদ! {product} কেমন লাগল? এক লাইনে জানালে খুশি হব।",
                     "{name}, thanks a lot for buying at {shop}! How is the {product}? One line from you makes our day."),
        "premium": ("প্রিয় {name}, {shop}-কে বেছে নেওয়ার জন্য কৃতজ্ঞতা। {product} নিয়ে আপনার মতামত জানালে আমরা আরও ভালো করতে পারব।",
                    "Dear {name}, thank you for choosing {shop}. Your thoughts on the {product} help us do even better."),
    },
    "reorder": {
        "friendly": ("{name}, আপনি সাধারণত প্রতি {days} দিনে {product} নেন — আবার লাগবে? উত্তর দিলেই {shop} রেখে দেবে।",
                     "{name}, you usually get {product} every {days} days — need it again? Reply and {shop} will keep it ready."),
        "premium": ("{name}, আপনার {product} প্রায় শেষ হওয়ার সময় হলো ({days} দিন)। চাইলে {shop} আগেই রেখে দেবে।",
                    "{name}, your {product} may be running low ({days} days). {shop} can keep one ready for you."),
    },
    "winback": {
        "friendly": ("{name}, অনেক দিন দেখা হয়নি! {shop}-এ নতুন জিনিস এসেছে — সময় পেলে একবার ঘুরে যাবেন।",
                     "{name}, we miss you! New things have arrived at {shop} — drop by when you can."),
        "premium": ("{name}, {shop}-এ নতুন সংগ্রহ এসেছে। আপনার জন্য বেছে রাখতে পারলে খুশি হব।",
                    "{name}, a new collection has arrived at {shop}. We'd be glad to set something aside for you."),
    },
    "quote_followup": {
        "friendly": ("{name}, {shop}-এর দামের প্রস্তাব (৳{total}) এখনো আপনার জন্য রাখা আছে: {link} কোনো প্রশ্ন থাকলে উত্তর দিন।",
                     "{name}, {shop}'s quote (৳{total}) is still held for you: {link} Reply with any question."),
        "premium": ("{name}, আপনার জন্য {shop}-এর প্রস্তাব (৳{total}) এখনো বহাল: {link} যেকোনো প্রশ্নে আমরা আছি।",
                    "{name}, {shop}'s offer for you (৳{total}) still stands: {link} We're here for any question."),
    },
}
_FOLLOW_META = {
    "thanks_review": ("কেনার ২ দিন পর ধন্যবাদ + মতামত", "Thank-you + feedback 2 days after a purchase",
                      {"days_after": 2}),
    "reorder": ("আবার কেনার সময় হলে মনে করানো", "Reorder nudge when it's due again",
                {"min_purchases": 2, "days_before": 1}),
    "winback": ("৪৫ দিন না এলে \"ফিরে আসুন\"", "\"We miss you\" after 45 days away",
                {"days_without": 45}),
    "quote_followup": ("দামের প্রস্তাবের ২ দিন পর ফলো-আপ", "Quote follow-up after 2 days",
                       {"days_after": 2}),
}


def followup_template(kind, tone):
    t = _FOLLOW_TPL[kind]
    return t["premium"] if tone in ("premium", "trust") else t["friendly"]


def conversion_items(answers, facts, lang):
    shop = _shop(facts, lang)
    ch = answers.get("channels") or []
    inbox = "WhatsApp" if "whatsapp" in ch else "Messenger"
    items = [_item("leadflow", "conversion", "lead_flow",
                   _L(lang, "লিড ফ্লো: প্রশ্ন থেকে অর্ডার", "Lead flow: from question to order"),
                   "\n".join([
                       _L(lang, "১. পোস্ট / বিজ্ঞাপন দেখে কেউ %s-এ দাম জিজ্ঞেস করেন" % inbox,
                          "1. Someone sees a post / ad and asks the price on %s" % inbox),
                       _L(lang, "২. AI সেলস এজেন্ট (চালু থাকলে) বা আপনি ক্যাটালগের আসল দাম ও স্টক বলেন",
                          "2. The AI sales agent (if on) or you answer with the real catalog price and stock"),
                       _L(lang, "৩. নাম-নম্বর CRM-এ লিড হিসেবে ওঠে", "3. Name and number land in CRM as a lead"),
                       _L(lang, "৪. অর্ডার নিশ্চিত → POS-এ বিক্রি → ২ দিন পর ধন্যবাদ মেসেজ (নিচে)",
                          "4. Order confirmed → sale in POS → thank-you 2 days later (below)"),
                       _L(lang, "৫. কেউ কেনেননি? ২৪ ঘণ্টার মধ্যে নিজে একবার ফলো-আপ করুন (CRM টাস্ক)",
                          "5. No order? Follow up once yourself within 24 h (CRM task)"),
                   ]), ["questionnaire"] + (["crm_leads"] if facts.get("leads_total") else []))]
    tone = answers.get("tone", "friendly")
    goals = set(answers.get("goals") or [])
    kinds = ["thanks_review", "reorder", "winback"]
    if facts.get("open_quotes"):
        kinds.append("quote_followup")
    if "repeat" in goals:
        kinds.remove("reorder")
        kinds.insert(0, "reorder")
    for k in kinds:
        bn_t, en_t = followup_template(k, tone)
        bn_l, en_l, params = _FOLLOW_META[k]
        uses = ["sales_90d"] if k != "quote_followup" else ["open_quotes"]
        if k == "reorder" and facts.get("repeat_customers"):
            uses.append("repeat_customers")
        items.append(_item("fu_" + k, "conversion", "followup", _L(lang, "ফলো-আপ: ", "Follow-up: ") + _L(lang, bn_l, en_l),
                           (en_t if lang == "en" else bn_t) + "\n\n" + _L(
                               lang, "পাঠানো হয় রিটেনশন অটোমেশন দিয়ে: STOP, দিনের সীমা, রাত ৯টা–সকাল ৯টা বন্ধ।",
                               "Sent by retention automation: STOP honoured, daily caps, nothing 21:00–09:00."),
                           uses, followup_kind=k, template_bn=bn_t, template_en=en_t, params=params))
    items.append(_item("journey", "conversion", "journey",
                       _L(lang, "গ্রাহকের যাত্রাপথ", "Customer journey map"),
                       "\n".join([
                           _L(lang, "দেখা → %s-এ প্রশ্ন → অর্ডার → হাতে পাওয়া → ধন্যবাদ ও মতামত → আবার কেনা → নিয়মিত গ্রাহক" % inbox,
                              "Sees → asks on %s → orders → receives → thank-you & feedback → buys again → regular" % inbox),
                           _L(lang, "প্রতিটা ধাপে Assisto-র কী কাজ করে: পোস্ট/ক্যালেন্ডার → সেলস এজেন্ট → POS → ফলো-আপ → CRM স্কোর",
                              "What Assisto does at each step: posts/calendar → sales agent → POS → follow-ups → CRM score"),
                           _L(lang, "%s-এর লক্ষ্য: প্রতি ১০ জন ক্রেতার অন্তত কয়েকজন যেন আবার আসেন — নিচের সংখ্যা দেখে মাপুন।" % shop,
                              "%s's aim: more first-time buyers coming back — measure it with the numbers shown." % shop),
                       ]), ["questionnaire"] + (["repeat_customers"] if facts.get("sales_90d_count") else [])))
    return items


# ----------------------------------------------------------------- facts / plan
FACT_LABELS = {
    "questionnaire": ("আপনার প্রশ্নমালার উত্তর", "Your questionnaire answers"),
    "catalog_price": ("ক্যাটালগের আসল দাম", "Real catalog prices"),
    "top_products": ("সবচেয়ে বেশি বিক্রি (গত ৯০ দিন, POS)", "Best sellers (last 90 days, POS)"),
    "slow_movers": ("স্টকে আছে কিন্তু ৬০ দিন বিক্রি নেই", "In stock, no sale for 60 days"),
    "sales_90d": ("গত ৯০ দিনের বিক্রি (POS)", "Sales, last 90 days (POS)"),
    "repeat_customers": ("বারবার কেনা গ্রাহক (৯০ দিনে ২+ বার)", "Repeat customers (2+ buys in 90 days)"),
    "crm_leads": ("CRM-এর লিড", "CRM leads"),
    "open_quotes": ("খোলা দামের প্রস্তাব", "Open price quotes"),
    "bd_calendar": ("বাংলাদেশের উৎসব ও দিবস", "Bangladesh festivals and days"),
}


def facts_shown(facts, lang):
    """The real numbers, as the owner sees them ('which numbers it used')."""
    rows = []

    def add(key, value):
        bn, en = FACT_LABELS[key]
        rows.append({"key": key, "label": en if lang == "en" else bn, "value": value})
    tp = facts.get("top_products") or []
    add("top_products", "; ".join("%s × %s" % (p["name"], num(p.get("qty", 0), lang)) for p in tp[:5])
        or _L(lang, "এখনো কোনো বিক্রি নেই", "No sales yet"))
    sm = facts.get("slow_movers") or []
    add("slow_movers", "; ".join("%s (%s %s)" % (s["name"], _L(lang, "স্টক", "stock"), num(s.get("stock", 0), lang))
                                 for s in sm[:5]) or _L(lang, "নেই", "None"))
    add("sales_90d", _L(lang, "%s টি বিক্রি, মোট %s" % (num(facts.get("sales_90d_count", 0), lang),
                                                       taka(facts.get("sales_90d_total", 0), lang)),
                        "%s sales, total %s" % (num(facts.get("sales_90d_count", 0), lang),
                                                taka(facts.get("sales_90d_total", 0), lang))))
    add("repeat_customers", _L(lang, "%s জন (মোট গ্রাহক %s)" % (num(facts.get("repeat_customers", 0), lang),
                                                              num(facts.get("customers_90d", 0), lang)),
                               "%s (of %s buyers)" % (num(facts.get("repeat_customers", 0), lang),
                                                      num(facts.get("customers_90d", 0), lang))))
    add("crm_leads", _L(lang, "মোট %s, গত ৩০ দিনে নতুন %s, জেতা %s" % (
        num(facts.get("leads_total", 0), lang), num(facts.get("leads_new_30d", 0), lang),
        num(facts.get("leads_won", 0), lang)),
        "%s total, %s new in 30 days, %s won" % (
        num(facts.get("leads_total", 0), lang), num(facts.get("leads_new_30d", 0), lang),
        num(facts.get("leads_won", 0), lang))))
    add("catalog_price", _L(lang, "%s টি পণ্যে দাম আছে" % num(facts.get("catalog_priced", 0), lang),
                            "%s products with a price" % num(facts.get("catalog_priced", 0), lang)))
    add("open_quotes", num(facts.get("open_quotes", 0), lang))
    return rows


def build_plan(answers, facts, lang="bn", start=None):
    """The whole marketing system: list of items + the facts it used."""
    lang = "en" if lang == "en" else "bn"
    start = start or date.today()
    items = content_items(answers, facts, lang)
    items.append(calendar_item(answers, facts, lang, start))
    items += strategy_items(answers, facts, lang)
    items += campaign_items(answers, facts, lang, start)
    items += conversion_items(answers, facts, lang)
    for it in items:
        it["uses_labels"] = [(FACT_LABELS[u][1] if lang == "en" else FACT_LABELS[u][0])
                             for u in it["uses"] if u in FACT_LABELS]
    return {"lang": lang, "start": start.isoformat(), "items": items,
            "facts": facts_shown(facts, lang)}


def merge_regenerated(old_items, new_items):
    """Regenerate keeps what the owner already decided: an approved / edited
    item with the same id stays as it was; drafts are replaced."""
    keep = {i["id"]: i for i in (old_items or [])
            if i.get("status") == "approved" or i.get("edited")}
    return [keep.get(i["id"], i) for i in new_items]


def apply_edit(item, data):
    """Owner action on one item -> (item, problems)."""
    probs = []
    st = data.get("status")
    if st is not None:
        if st not in STATUSES:
            probs.append("bad_status")
        else:
            item["status"] = st
    if "body" in data:
        body = str(data.get("body") or "").strip()
        if not body:
            probs.append("empty")
        elif len(body) > MAX_BODY:
            probs.append("too_long")
        elif body != item.get("body"):
            item["body"] = body
            item["edited"] = True
            item.pop("polished", None)
    return item, probs
