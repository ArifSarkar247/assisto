"""
business_ai.py — ONLINE-SELLING + AI SALES ASSISTANT pure-logic layer for
Assisto Business v2 (BUSINESS_V2_PLAN §4, §5, §6).

PURE PYTHON. NO Django. Everything here takes plain dicts / scalars and returns
plain dicts / tuples, so it is trivially unit-testable in isolation. The Django
layer (models/views/urls) binds this logic late — see .phaseB/biz_ai_integration.md.

================================ HARD CONSTRAINTS ============================
These are encoded here and locked by tests in business_ai_tests_snippets.py:

 1. MINIMUM PRICE IS ENFORCED IN CODE, NOT AI. negotiate() can NEVER return a
    counter below a product's minimum price. The AI mock NEVER sets price —
    price/discount decisions come only from this module. If a customer offer is
    below minimum, negotiate() returns action "defer_to_owner" (it never
    accepts). See test_negotiate_* .

 2. WE NEVER HOLD MONEY / NEVER ACT AS A WALLET (would need a Bangladesh Bank
    licence). payments_* helpers ONLY describe the owner's OWN merchant QR or
    build a payment LINK that delegates to a licensed partner (key-gated/mock).
    No balance custody anywhere. See test_payments_never_holds_funds.

 3. OFFICIAL CHANNELS ONLY. webhook assembly targets the official WhatsApp
    Business Cloud API (Graph) and Messenger Platform ONLY. Automating a
    PERSONAL WhatsApp number or the WhatsApp Business *app* is a ban risk and is
    explicitly refused — see guard_channel() / test_no_personal_whatsapp.
    Respect the 24h customer-service window + paid message templates — see
    within_service_window() / outbound_message_plan().

 4. AI IS A MOCK + KEY-GATED. reply_provider defaults to a deterministic mock.
    A real provider (LLM) only runs when a key is present. The AI NEVER
    fabricates stock or price; it only phrases facts handed to it.

All user-facing strings are {bn, en}. The assistant replies in bn / Banglish /
en matching the customer's input language (detect_lang()).
=============================================================================
"""
import re
from decimal import Decimal, InvalidOperation

# Optional reuse of sibling pure-logic (voice entry / notification matching).
# These are import-light and Django-free; guarded so this module imports even
# if run standalone.
try:  # pragma: no cover - import plumbing
    from core.logic import money_parse as _money_parse
except Exception:  # pragma: no cover
    try:
        import money_parse as _money_parse  # type: ignore
    except Exception:
        _money_parse = None

try:  # pragma: no cover - import plumbing
    from core.logic import nlp_datetime as _nlp_datetime
except Exception:  # pragma: no cover
    try:
        import nlp_datetime as _nlp_datetime  # type: ignore
    except Exception:
        _nlp_datetime = None


# ===========================================================================
# i18n — every user-facing string is {bn, en}. See biz_ai_arb.json for the
# canonical arb. pick() mirrors core.i18n.pick but is dependency-free here.
# ===========================================================================

def pick(lang, bn, en):
    return bn if (lang or "bn").lower().startswith("bn") else en


_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _norm_digits(s):
    return (s or "").translate(_BN_DIGITS)


def _to_decimal(v):
    """Tolerant Decimal coercion: accepts Decimal/int/float/str (with ৳,commas)."""
    if v is None:
        return None
    if isinstance(v, Decimal):
        return v
    if isinstance(v, (int,)):
        return Decimal(v)
    if isinstance(v, float):
        return Decimal(str(v))
    t = _norm_digits(str(v))
    t = t.replace(",", "")
    out = "".join(ch for ch in t if ch.isdigit() or ch == ".")
    if out in ("", "."):
        return None
    try:
        return Decimal(out)
    except InvalidOperation:
        return None


# ===========================================================================
# language detection — bn / banglish / en (determines reply language)
# ===========================================================================

def detect_lang(text):
    """Return 'bn' (has Bangla script), 'en', or 'banglish' (latin but Bangla
    words). Used so the assistant replies in the customer's language."""
    t = text or ""
    if any("ঀ" <= ch <= "৿" for ch in t):
        return "bn"
    low = t.lower()
    banglish_markers = (
        "koto", "kemon", "ache", "dam", "daam", "pathao", "ki ", "kivabe",
        "kobe", "order", "lagbe", "nibo", "dibo", "takbe", "porabe", "koto taka",
        "bikash", "bkash", "nagad", "delivery koto", "ekta", "dorkar",
        # e2e-sales: everyday bargaining / ordering Banglish
        "diben", "deben", "dile ", "hobe", "taka te", "takay", "korben", "korbo",
        "koren", "bhai", "vaiya", "apu ", "naki", "dite paren", "kom ", "chai ",
    )
    toks = re.findall(r"[a-z']+", low)
    # sales2: an English sentence that happens to contain a marker ("I want to
    # ORDER", "pay by BKASH", "DAMaged") is English: count English function
    # words against whole Banglish words
    en = sum(1 for w in toks if w in _EN_FUNC)
    bl = sum(1 for w in toks if w in _BANGLISH_TOKENS or w in _BANGLISH_STRONG)
    if en >= 2 and en > bl:
        return "en"
    if any(m in low for m in banglish_markers):
        return "banglish"
    # sales2: everyday Banglish WORDS (whole tokens only — "ase" must not hit
    # "please", "ami" must not hit "Miami")
    if set(toks) & _BANGLISH_TOKENS:
        return "banglish"
    return "en"


_EN_FUNC = {"i", "i'm", "you", "the", "a", "an", "is", "are", "was", "to", "my", "me", "want",
            "can", "could", "how", "what", "please", "do", "does", "have", "has", "with", "for",
            "of", "this", "it", "will", "would", "your", "where", "when", "which", "need", "send",
            "give", "pay", "get", "there", "any", "and", "or", "if", "it's", "don't", "doesn't"}
_BANGLISH_STRONG = {"koto", "kemon", "ache", "dam", "daam", "ki", "kivabe", "kobe", "lagbe",
                    "nibo", "dibo", "diben", "deben", "hobe", "korbo", "korben", "koren", "naki",
                    "kom", "ekta", "dorkar", "taka", "te", "er", "ta", "e"}


_BANGLISH_TOKENS = {
    "salam", "assalamu", "assalamualaikum", "walaikum", "dokan", "dokaner", "kothay", "kothai",
    "kokhon", "khola", "jabe", "kharap", "nai", "hoye", "gelo", "apnader", "apnara", "apni",
    "amar", "ami", "bolen", "thake", "korte", "kora", "ase", "koi", "vai", "bhaiya", "accha",
    "thik", "dhonnobad", "lagbe", "pabo", "chai", "den", "din", "dao", "deya", "dewa", "newa",
    "nite", "parbo", "hobena", "keno", "tumi", "apu", "bhai", "ekhon", "kalke", "ajke"}


def reply_lang(text):
    """Language to REPLY in. Banglish customers get bn (readable Bangla)."""
    d = detect_lang(text)
    return "en" if d == "en" else "bn"


# ===========================================================================
# §4 — REPLY PIPELINE (AI mocked, key-gated; never fabricates stock/price)
# ===========================================================================

# Confidence levels
CONF_HIGH = 0.95
CONF_MED = 0.7
CONF_LOW = 0.3

# handoff / confidence threshold under which a human is pulled in
HANDOFF_CONFIDENCE = 0.5


def default_mock_provider(prompt):
    """Deterministic MOCK LLM provider (the default reply_provider).

    Contract for ANY provider (mock or real): it receives a `prompt` dict with
      {"lang", "customer_text", "intent", "facts", "policies", "shop_name",
       "style"}
    and returns {"text": str, "confidence": float}. It MUST NOT invent price or
    stock — it only phrases the `facts` string it is handed. This mock proves
    the pipeline works offline; the real (key-gated) LLM provider is a drop-in.
    """
    lang = prompt.get("lang", "bn")
    shop = prompt.get("shop_name") or pick(lang, "আমাদের দোকান", "our shop")
    facts = prompt.get("facts", "")
    intent = prompt.get("intent")
    disclosure = assistant_disclosure(lang)["short"]
    if intent == "greeting":
        return {"text": pick(lang,
                             f"আসসালামু আলাইকুম! {shop}-এ স্বাগতম। কী সাহায্য করতে পারি?",
                             f"Hello! Welcome to {shop}. How can I help?"),
                "confidence": CONF_HIGH}
    if intent == "price_stock" and facts:
        body = pick(lang,
                    f"{disclosure} এই তথ্য অনুযায়ী:\n{facts}",
                    f"{disclosure} Here's what I have:\n{facts}")
        return {"text": body, "confidence": CONF_HIGH}
    # no facts / unknown intent → low confidence (pipeline will hand off)
    return {"text": pick(lang,
                         "আমি নিশ্চিত নই, একজন দেখে জানাবে।",
                         "I'm not sure — someone will check."),
            "confidence": CONF_LOW}


def classify_intent(text):
    """Cheap rule-based intent for routing the mock/real provider."""
    low = _norm_digits((text or "").lower())
    # sales2: whole words ("hi" inside "Shirt" / "Hilsa" is not a greeting)
    if re.search(r"(?<![a-z])(?:hi|hello|assalamu\w*|salam)(?![a-z])|আসসালাম|হ্যালো|নমস্কার", low):
        if len(low.split()) <= 3:
            return "greeting"
    if any(w in low for w in ("where is my parcel", "parcel", "koi", "কোথায়", "track",
                              "ট্র্যাক", "order status", "status", "পার্সেল")):
        return "parcel_status"
    if any(w in low for w in ("price", "dam", "daam", "দাম", "koto", "কত", "stock", "স্টক",
                              "available", "আছে কি", "ache")):
        return "price_stock"
    if any(w in low for w in ("discount", "ছাড়", "kom", "কম", "offer", "বেশি দাম",
                              "dam beshi", "komun", "negotiate", "দর")):
        return "bargain"
    if any(w in low for w in ("order", "অর্ডার", "nibo", "নিবো", "lagbe", "লাগবে", "chai", "চাই")):
        return "order"
    return "unknown"


def is_human(provider_or_flag):
    """A reply provider may be flagged non-AI; never used to claim humanity."""
    return bool(getattr(provider_or_flag, "is_human", False))


def assistant_disclosure(lang="bn"):
    """"I am the shop's AI assistant" — used when asked, and on first contact."""
    return {
        "short": pick(lang, "আমি দোকানের এআই সহকারী।",
                      "I'm the shop's AI assistant."),
        "full": pick(lang,
                     "আমি একজন মানুষ নই — আমি এই দোকানের এআই সহকারী। প্রয়োজনে "
                     "দোকানের মালিক নিজে উত্তর দেবেন।",
                     "I'm not a human — I'm this shop's AI assistant. The owner "
                     "will step in when needed."),
    }


def build_context(catalog=None, delivery=None, policies=None, shop_name="",
                  style="", lang="bn"):
    """Assemble the fact context the provider is allowed to phrase.

    catalog:  [{name, price, stock, min_price?, description?}]
    delivery: {"inside_dhaka": amount, "outside_dhaka": amount, "free_over": amount?}
    policies: {"returns": str, "payment": str, "hours": str, ...} (free text per shop)
    Returns a dict with a rendered `facts` string + structured pieces. The
    provider NEVER sees anything beyond this, so it cannot invent price/stock.
    """
    catalog = catalog or []
    lines = []
    price_lbl = pick(lang, "দাম", "price")
    stock_lbl = pick(lang, "স্টক", "stock")
    for p in catalog:
        price = _to_decimal(p.get("price"))
        stock = int(p.get("stock") or 0)
        instock = pick(lang, "স্টকে আছে", "in stock") if stock > 0 else pick(
            lang, "স্টক নেই", "out of stock")
        line = f"- {p.get('name')}: {price_lbl} ৳{price}, {stock_lbl} {stock} ({instock})"
        if p.get("description"):
            line += f" — {str(p['description'])[:80]}"
        lines.append(line)
    if delivery:
        inside = _to_decimal(delivery.get("inside_dhaka"))
        outside = _to_decimal(delivery.get("outside_dhaka"))
        if inside is not None or outside is not None:
            lines.append(pick(
                lang,
                f"- ডেলিভারি: ঢাকার ভিতরে ৳{inside}, ঢাকার বাইরে ৳{outside}",
                f"- Delivery: inside Dhaka ৳{inside}, outside Dhaka ৳{outside}"))
    for k, v in (policies or {}).items():
        if v:
            lines.append(f"- {k}: {v}")
    return {
        "facts": "\n".join(lines),
        "catalog": catalog,
        "delivery": delivery or {},
        "policies": policies or {},
        "shop_name": shop_name,
        "style": style,
        "lang": lang,
    }


def draft_reply(customer_text, context, reply_provider=None, ai_key=None,
                owner_takeover=False):
    """THE REPLY PIPELINE. Returns a dict:

        {"text", "lang", "confidence", "needs_human", "handoff_reason",
         "used_ai", "disclosure", "intent"}

    - reply_provider defaults to the deterministic mock. A REAL LLM provider is
      only used when `ai_key` is present (key-gated); otherwise the mock runs.
    - The provider is handed ONLY the context facts; it can never invent price
      or stock.
    - If the owner has taken over the chat, the AI stays silent (owner replies).
    - Low confidence OR a hard handoff trigger → needs_human=True.
    """
    lang = context.get("lang") or reply_lang(customer_text)
    intent = classify_intent(customer_text)

    # Owner takeover: AI must not reply over the owner.
    if owner_takeover:
        return {"text": "", "lang": lang, "confidence": 0.0,
                "needs_human": True, "handoff_reason": "owner_takeover",
                "used_ai": False, "disclosure": assistant_disclosure(lang),
                "intent": intent}

    # Hard handoff triggers checked BEFORE drafting (angry/refund/big order).
    trig = handoff_trigger(customer_text)
    if trig:
        return {"text": handoff_message(lang, trig), "lang": lang,
                "confidence": 0.0, "needs_human": True, "handoff_reason": trig,
                "used_ai": False, "disclosure": assistant_disclosure(lang),
                "intent": intent}

    # Key-gate the real provider; otherwise deterministic mock.
    used_ai = False
    if reply_provider is not None and ai_key:
        provider = reply_provider
        used_ai = True
    else:
        provider = default_mock_provider

    prompt = {
        "lang": lang,
        "customer_text": customer_text,
        "intent": intent,
        "facts": context.get("facts", ""),
        "policies": context.get("policies", {}),
        "shop_name": context.get("shop_name", ""),
        "style": context.get("style", ""),
    }
    out = provider(prompt) or {}
    text = out.get("text", "")
    confidence = float(out.get("confidence", CONF_LOW))

    # Safety net: the provider is NOT trusted to set price/stock. If the context
    # carried no facts but the provider emitted a price-looking reply, we drop
    # to low confidence and hand off (never ship a fabricated number).
    if not context.get("facts") and intent in ("price_stock", "order", "bargain"):
        confidence = min(confidence, CONF_LOW)

    needs_human = confidence < HANDOFF_CONFIDENCE
    reason = "low_confidence" if needs_human else None
    # aieval guard: a REAL model draft is post-checked — a price/number that is
    # not in the facts or the customer's own text, a refund promise or a
    # "human" claim never goes out as-is; the owner reviews it.
    problems = []
    if used_ai and text:
        from .. import ai_guard
        problems = ai_guard.check_sales_answer(
            text, context.get("facts", ""), customer_text,
            extra=[v for v in (context.get("delivery") or {}).values()])
        if problems:
            needs_human, reason = True, "unverified_numbers"
            confidence = min(confidence, CONF_LOW)
    out = {
        "text": text, "lang": lang, "confidence": confidence,
        "needs_human": needs_human, "handoff_reason": reason,
        "used_ai": used_ai, "disclosure": assistant_disclosure(lang),
        "intent": intent,
    }
    if problems:
        out["problems"] = problems
    return out


# ===========================================================================
# §4 — BARGAINING. MINIMUM PRICE ENFORCED IN CODE, NOT AI.
# ===========================================================================
# The negotiate() counter can NEVER go below the product minimum. The AI mock
# does not participate here at all — this is deterministic arithmetic.

ACTION_ACCEPT = "accept"
ACTION_COUNTER = "counter"
ACTION_DEFER = "defer_to_owner"


def negotiate(offer, product, rules=None, lang="bn"):
    """Enforce bargaining in CODE. Returns a dict:

        {"action": accept|counter|defer_to_owner,
         "price": Decimal|None,          # the price WE agree to (>= minimum, always)
         "message": str,                 # customer-facing {bn/en via lang}
         "owner_notification": dict|None,# descriptor when deferring
         "min_price": Decimal, "list_price": Decimal, "offer": Decimal}

    product: {"name", "price"(list), "min_price"}
    rules:   {"discount_steps": [pct,...] or [amount,...],  # allowed ladder
              "free_delivery_over": amount?,                # bundle/offer rules
              "bundle_min_qty": int?}
    offer:   the customer's offered unit price.

    INVARIANT (locked by tests): the returned `price` is NEVER below min_price.
    If the customer's offer is below minimum, we DO NOT counter below min and we
    DO NOT accept — we DEFER to the owner ("I'll check with the owner").
    """
    rules = rules or {}
    list_price = _to_decimal(product.get("price"))
    min_price = _to_decimal(product.get("min_price"))
    offer_d = _to_decimal(offer)
    name = product.get("name", "")

    if list_price is None:
        raise ValueError("product.price required")
    # A missing/invalid minimum defaults to the list price (no discount allowed).
    if min_price is None:
        min_price = list_price
    # Defensive: a misconfigured min above list is clamped to list.
    if min_price > list_price:
        min_price = list_price

    # Offer at or above list → accept at list (never overcharge beyond list).
    if offer_d is not None and offer_d >= list_price:
        return {
            "action": ACTION_ACCEPT, "price": list_price,
            "message": pick(lang,
                            f"ধন্যবাদ! {name} ৳{list_price}-এ কনফার্ম করছি।",
                            f"Thank you! Confirming {name} at ৳{list_price}."),
            "owner_notification": None,
            "min_price": min_price, "list_price": list_price, "offer": offer_d,
        }

    # Offer BELOW minimum → defer to owner. NEVER counter below min, NEVER accept.
    if offer_d is not None and offer_d < min_price:
        note = owner_bargain_notification(name, offer_d, min_price, list_price)
        return {
            "action": ACTION_DEFER, "price": None,
            "message": pick(lang,
                            "আমি মালিকের সাথে কথা বলে জানাচ্ছি।",
                            "I'll check with the owner."),
            "owner_notification": note,
            "min_price": min_price, "list_price": list_price, "offer": offer_d,
        }

    # Offer within [min, list): accept their offer, OR counter down a ladder step
    # but NEVER below minimum. We accept the customer's offer if it is >= min
    # (they offered more than our floor), since any accepted price >= min.
    if offer_d is not None and min_price <= offer_d < list_price:
        return {
            "action": ACTION_ACCEPT, "price": offer_d,
            "message": pick(lang,
                            f"ঠিক আছে, {name} ৳{offer_d}-এ দিতে পারি।",
                            f"Alright, I can do {name} at ৳{offer_d}."),
            "owner_notification": None,
            "min_price": min_price, "list_price": list_price, "offer": offer_d,
        }

    # No explicit offer → make a counter along the allowed discount ladder,
    # clamped so it can never dip below minimum.
    counter = _ladder_counter(list_price, min_price, rules.get("discount_steps"))
    assert counter >= min_price, "INVARIANT: counter below minimum"
    extras = []
    fdo = _to_decimal(rules.get("free_delivery_over"))
    if fdo is not None and counter >= fdo:
        extras.append(pick(lang, " ফ্রি ডেলিভারি সহ।", " with free delivery."))
    msg = pick(lang,
               f"সর্বোচ্চ ছাড় দিয়ে {name} ৳{counter}-এ দিতে পারি।" + "".join(extras),
               f"Best I can do on {name} is ৳{counter}." + "".join(extras))
    return {
        "action": ACTION_COUNTER, "price": counter,
        "message": msg, "owner_notification": None,
        "min_price": min_price, "list_price": list_price, "offer": offer_d,
    }


def _ladder_counter(list_price, min_price, steps):
    """Apply the FIRST allowed discount step, clamped at the minimum floor.
    steps are percentages (<=100) or absolute Taka amounts. A None/empty ladder
    means 'no discount' → counter at list price."""
    if not steps:
        return list_price
    step = steps[0]
    step_d = _to_decimal(step)
    if step_d is None:
        return list_price
    if step_d <= Decimal("100"):  # treat as percentage
        candidate = (list_price * (Decimal("100") - step_d) / Decimal("100"))
    else:  # treat as absolute Taka off
        candidate = list_price - step_d
    candidate = candidate.quantize(Decimal("1"))
    # HARD FLOOR: never below minimum.
    return candidate if candidate >= min_price else min_price


def owner_bargain_notification(product_name, offer, min_price, list_price):
    """Descriptor the Django layer turns into a push/WhatsApp alert to the owner
    when a customer's offer is below the floor."""
    return {
        "type": "bargain_below_min",
        "product": product_name,
        "customer_offer": str(offer) if offer is not None else None,
        "min_price": str(min_price),
        "list_price": str(list_price),
        "action_required": "owner_decision",
    }


# ===========================================================================
# §4 — HUMAN HANDOFF triggers
# ===========================================================================

HANDOFF_ANGRY = "angry"
HANDOFF_REFUND = "refund"
HANDOFF_BIG_ORDER = "big_order"
HANDOFF_ABUSE = "abuse"          # AF-4: abusive / threatening customer -> a person, AI cools down

_ANGRY_WORDS = ("scam", "cheat", "fraud", "worst", "terrible", "angry", "ভুয়া",
                "প্রতারণা", "বাজে", "খারাপ", "রাগ", "ঠকিয়েছ", "faltu", "baje",
                "complain", "অভিযোগ")
_REFUND_WORDS = ("refund", "return", "money back", "ফেরত", "রিটার্ন",
                 "ferot", "taka ferot", "cancel order", "wrong product", "defective",
                 "নষ্ট", "ভাঙা")

BIG_ORDER_THRESHOLD = Decimal("20000")  # orders over this escalate to a human


def handoff_trigger(customer_text, order_total=None, confidence=None):
    """Return a handoff reason string, or None. Big-order escalation uses
    order_total; low confidence is handled by the pipeline but accepted here too."""
    low = _norm_digits((customer_text or "").lower())
    if any(w in low for w in _REFUND_WORDS):
        return HANDOFF_REFUND
    if any(w in low for w in _ANGRY_WORDS):
        return HANDOFF_ANGRY
    total = _to_decimal(order_total)
    if total is not None and total >= BIG_ORDER_THRESHOLD:
        return HANDOFF_BIG_ORDER
    if confidence is not None and float(confidence) < HANDOFF_CONFIDENCE:
        return "low_confidence"
    return None


def handoff_message(lang, reason):
    m = {
        HANDOFF_ANGRY: pick(lang,
                            "দুঃখিত অসুবিধার জন্য। আমি এখনই দোকানের একজনকে যুক্ত করছি।",
                            "Sorry for the trouble. I'm bringing in someone from the shop now."),
        HANDOFF_REFUND: pick(lang,
                             "রিটার্ন/রিফান্ডের জন্য দোকানের একজন আপনাকে সাহায্য করবেন।",
                             "For returns/refunds a team member will assist you."),
        HANDOFF_BIG_ORDER: pick(lang,
                                "বড় অর্ডারের জন্য মালিক নিজে কথা বলবেন।",
                                "For a large order the owner will speak with you directly."),
        "low_confidence": pick(lang,
                               "আমি নিশ্চিত নই — দোকানের একজন শীঘ্রই জানাবেন।",
                               "I'm not certain — someone from the shop will reply shortly."),
        HANDOFF_ABUSE: pick(lang,
                            "আপনার অসুবিধার জন্য দুঃখিত। কী সমস্যা হয়েছে জানালে আমরা সমাধানের চেষ্টা করব।",
                            "Sorry for the trouble. Tell us what went wrong and we will try to fix it."),
    }
    return m.get(reason, m["low_confidence"])


# ===========================================================================
# §4 — ORDER STATE MACHINE + courier (key-gated/mock) + COD + parcel status
# ===========================================================================

STATUS_NEW = "new"
STATUS_CONFIRMED = "confirmed"
STATUS_PACKED = "packed"
STATUS_SHIPPED = "shipped"
STATUS_DELIVERED = "delivered"
STATUS_RETURNED = "returned"
STATUS_CANCELLED = "cancelled"

# Allowed transitions. 'shipped' requires a courier (key-gated).
_TRANSITIONS = {
    STATUS_NEW: {STATUS_CONFIRMED, STATUS_CANCELLED},
    STATUS_CONFIRMED: {STATUS_PACKED, STATUS_CANCELLED},
    STATUS_PACKED: {STATUS_SHIPPED, STATUS_CANCELLED},
    STATUS_SHIPPED: {STATUS_DELIVERED, STATUS_RETURNED},
    STATUS_DELIVERED: {STATUS_RETURNED},
    STATUS_RETURNED: set(),
    STATUS_CANCELLED: set(),
}

COURIERS = ("pathao", "steadfast", "redx")


def can_transition(current, target):
    return target in _TRANSITIONS.get(current, set())


def advance_order(order, target, courier=None, courier_keys=None, lang="bn"):
    """Pure state-machine step. `order` is a dict (never a Django model).
    Returns (new_order_dict, event_dict). Raises ValueError on illegal moves.

    Moving to 'shipped' REQUIRES a courier. truth: this path books nothing
    with the courier, so it never invents a tracking id and always sets
    courier_live=False (the owner adds the real consignment id).
    """
    cur = order.get("status", STATUS_NEW)
    if not can_transition(cur, target):
        raise ValueError(f"illegal transition {cur} -> {target}")
    new = dict(order)
    new["status"] = target
    event = {"from": cur, "to": target}

    if target == STATUS_SHIPPED:
        if courier not in COURIERS:
            raise ValueError(f"shipped requires a courier in {COURIERS}")
        booking = book_courier_mock(order, courier, courier_keys, lang=lang)
        new["courier"] = courier
        new["tracking"] = booking["tracking"]
        new["courier_live"] = booking["live"]
        event["courier"] = courier
        event["tracking"] = booking["tracking"]
        event["courier_live"] = booking["live"]
    return new, event


def book_courier_mock(order, courier, courier_keys=None, lang="bn"):
    """Courier hand-over record for the manual order flow.

    truth (owner FINAL ORDER 27 Oct, no fake data): this path does NOT call a
    courier API (the real Pathao/Steadfast/RedX booking lives in
    bizagent_service / couriers.py). So it never invents a tracking id and is
    never `live`, key or no key: tracking stays empty until the owner types
    the real consignment id from the courier, and the note says so.
    `courier_keys` is accepted for API compatibility only.
    """
    if courier not in COURIERS:
        raise ValueError("unknown courier")
    return {
        "courier": courier,
        "tracking": "",
        "live": False,
        "cod_amount": str(cod_amount(order)),
        "note": pick(lang,
                     "কুরিয়ারে এখনো বুক করা হয়নি — কুরিয়ারের অ্যাপে বুক করে ট্র্যাকিং নম্বর লিখুন।",
                     "Not booked with the courier yet — book it in the courier's app and add the tracking number."),
    }


def cod_amount(order):
    """Cash-on-delivery amount to collect = order total for COD orders, else 0."""
    if (order.get("payment") or "cod").lower() not in ("cod", "cash", "ক্যাশ"):
        return Decimal("0")
    return _to_decimal(order.get("total")) or Decimal("0")


def parcel_status(order, lang="bn"):
    """"Where is my parcel?" lookup → customer-facing status line."""
    status = order.get("status", STATUS_NEW)
    tracking = order.get("tracking", "")
    courier = order.get("courier", "")
    labels = {
        STATUS_NEW: pick(lang, "অর্ডার নেওয়া হয়েছে", "order received"),
        STATUS_CONFIRMED: pick(lang, "কনফার্ম হয়েছে", "confirmed"),
        STATUS_PACKED: pick(lang, "প্যাক করা হয়েছে", "packed"),
        STATUS_SHIPPED: pick(lang, "কুরিয়ারে পাঠানো হয়েছে", "shipped via courier"),
        STATUS_DELIVERED: pick(lang, "ডেলিভারি সম্পন্ন", "delivered"),
        STATUS_RETURNED: pick(lang, "ফেরত এসেছে", "returned"),
        STATUS_CANCELLED: pick(lang, "বাতিল হয়েছে", "cancelled"),
    }
    label = labels.get(status, status)
    oid = order.get("id", "")
    base = pick(lang, f"অর্ডার #{oid}: {label}", f"Order #{oid}: {label}")
    if status in (STATUS_SHIPPED, STATUS_DELIVERED) and tracking:
        base += pick(lang, f" ({courier} ট্র্যাকিং: {tracking})",
                     f" ({courier} tracking: {tracking})")
    return {"status": status, "message": base, "tracking": tracking, "courier": courier}


# ===========================================================================
# §4 — MORNING SUMMARY builder
# ===========================================================================

def morning_summary(messages=None, orders=None, needs_you=None, lang="bn"):
    """Build the overnight summary. Counts only — no spam, opt-in broadcast is
    a separate concern. `needs_you` = items flagged for the owner (handoffs,
    below-min bargains, big orders)."""
    n_msgs = len(messages or [])
    n_orders = len(orders or [])
    n_need = len(needs_you or [])
    text = pick(
        lang,
        f"সুপ্রভাত! রাতারাতি: {n_msgs} মেসেজ, {n_orders} অর্ডার, {n_need}টি আপনার নজর চায়।",
        f"Good morning! Overnight: {n_msgs} messages, {n_orders} orders, "
        f"{n_need} need you.")
    return {"messages": n_msgs, "orders": n_orders, "needs_you": n_need, "text": text}


# ===========================================================================
# §4 — OFFICIAL CHANNEL GUARD + 24h window + paid templates + webhook assembly
# ===========================================================================

CHANNEL_WA_CLOUD = "whatsapp_cloud"       # official WhatsApp Business Cloud API (Graph)
CHANNEL_MESSENGER = "messenger"           # Messenger Platform via Page/Graph API
# The following are BANNED — automating them risks an account ban.
CHANNEL_WA_PERSONAL = "whatsapp_personal"
CHANNEL_WA_BUSINESS_APP = "whatsapp_business_app"

_ALLOWED_CHANNELS = {CHANNEL_WA_CLOUD, CHANNEL_MESSENGER}
_BANNED_CHANNELS = {CHANNEL_WA_PERSONAL, CHANNEL_WA_BUSINESS_APP}

SERVICE_WINDOW_HOURS = 24


class PersonalWhatsAppBanned(Exception):
    """Raised if anything tries to automate a personal WhatsApp / WA Business app.
    Automating those is a Meta ToS violation and a ban risk — official Cloud API
    / Messenger Platform ONLY."""


def guard_channel(channel):
    """Allow ONLY official channels. Refuse personal WhatsApp / WA Business app."""
    if channel in _BANNED_CHANNELS:
        raise PersonalWhatsAppBanned(
            "Automating personal WhatsApp / the WhatsApp Business app is a ban "
            "risk and is not supported. Use the official WhatsApp Business Cloud "
            "API or Messenger Platform.")
    if channel not in _ALLOWED_CHANNELS:
        raise ValueError(f"unknown/unsupported channel: {channel}")
    return channel


def within_service_window(last_inbound_ts, now_ts, window_hours=SERVICE_WINDOW_HOURS):
    """24h customer-service window. Inputs are epoch seconds (pure/arithmetic).
    Returns True while free-form messages are allowed."""
    if last_inbound_ts is None:
        return False
    return (now_ts - last_inbound_ts) <= window_hours * 3600


def outbound_message_plan(channel, last_inbound_ts, now_ts, template_name=None):
    """Decide how an outbound message may be sent.

    Inside the 24h window → free-form allowed.
    Outside → ONLY a pre-approved PAID template (template_name required). We
    model the paid-template flag so the integrator bills/sends correctly.
    """
    guard_channel(channel)
    in_window = within_service_window(last_inbound_ts, now_ts)
    if in_window:
        return {"channel": channel, "mode": "freeform", "paid_template": False,
                "template_name": None, "allowed": True}
    if template_name:
        return {"channel": channel, "mode": "template", "paid_template": True,
                "template_name": template_name, "allowed": True}
    return {"channel": channel, "mode": "template", "paid_template": True,
            "template_name": None, "allowed": False,
            "reason": "outside_24h_window_requires_approved_template"}


def assemble_webhook_send(channel, to, text=None, template_name=None,
                          last_inbound_ts=None, now_ts=0):
    """Build the request descriptor the integrator posts to the OFFICIAL Graph
    endpoint. We do NOT send here (no network); we only assemble a safe payload.
    Guards the channel (no personal WhatsApp) and the 24h/template rule."""
    plan = outbound_message_plan(channel, last_inbound_ts, now_ts, template_name)
    if not plan["allowed"]:
        return {"ok": False, "plan": plan}
    if channel == CHANNEL_WA_CLOUD:
        endpoint = "graph.facebook.com/v21.0/<PHONE_NUMBER_ID>/messages"  # 🔑 Meta
        if plan["mode"] == "freeform":
            body = {"messaging_product": "whatsapp", "to": to,
                    "type": "text", "text": {"body": text or ""}}
        else:
            body = {"messaging_product": "whatsapp", "to": to,
                    "type": "template",
                    "template": {"name": template_name, "language": {"code": "bn"}}}
    else:  # messenger
        endpoint = "graph.facebook.com/v21.0/me/messages"  # 🔑 Meta Page token
        body = {"recipient": {"id": to}, "message": {"text": text or ""}}
    return {"ok": True, "endpoint": endpoint, "body": body, "plan": plan,
            "needs_key": True}  # Meta access token required to actually send


# ===========================================================================
# §5 — AI EXTRAS (all MOCK, key-gated). Reuse money_parse / nlp_datetime.
# ===========================================================================

def voice_entry_parse(text, now=None, lang="bn"):
    """Voice/typed entry → a DRAFT ledger entry (review step before saving).

    MOCK transcription: the audio→text step is key-gated (a transcription
    provider). Here `text` is the already-transcribed string. We reuse
    money_parse concepts for the amount and a light name/direction heuristic.
    Returns a DRAFT (needs_review=True) — nothing is written.
    """
    raw = text or ""
    amount = _extract_amount(raw)
    low = _norm_digits(raw.lower())
    # direction: "বাকি"/"due"/"debit" → receivable; "পেলাম"/"received" → payment
    if any(w in low for w in ("বাকি", "due", "baki", "dena", "দেনা")):
        kind = "due"
    elif any(w in low for w in ("পেলাম", "received", "পেয়েছি", "পাঠিয়েছে", "joma", "জমা")):
        kind = "payment"
    else:
        kind = "sale"
    name = _extract_name(raw)
    return {
        "draft": {"kind": kind, "amount": str(amount) if amount is not None else None,
                  "counterparty": name, "raw": raw},
        "needs_review": True,
        "confidence": CONF_MED if amount is not None else CONF_LOW,
        "message": pick(lang, "খসড়া তৈরি — যাচাই করে সেভ করুন।",
                        "Draft ready — review and save."),
        "transcription_mock": True,  # 🔑 real transcription provider gated
    }


def _extract_amount(text):
    import re
    t = _norm_digits(text or "")
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)", t)
    return _to_decimal(m.group(1)) if m else None


def _extract_name(text):
    """Grab a likely person name before 'এর খাতায়' / 'er khatay' etc. Best-effort."""
    import re
    t = (text or "").strip()
    m = re.match(r"^([^\d,]+?)\s*(?:এর|er|'s|র)\s", t)
    if m:
        return m.group(1).strip()
    first = t.split()
    return first[0] if first and not first[0].isdigit() else None


def paper_khata_parse(mock_rows=None, lang="bn"):
    """Photo of a paper khata → structured DRAFT entries with a REVIEW step.

    MOCK: real OCR/vision is key-gated. `mock_rows` simulates the vision output
    [{name, amount, kind?}]. Returns drafts (never auto-saved)."""
    rows = mock_rows or []
    drafts = []
    for r in rows:
        drafts.append({
            "name": r.get("name"),
            "amount": str(_to_decimal(r.get("amount")) or Decimal("0")),
            "kind": r.get("kind", "due"),
        })
    return {
        "entries": drafts,
        "count": len(drafts),
        "needs_review": True,
        "message": pick(lang, f"{len(drafts)}টি এন্ট্রি পাওয়া গেছে — যাচাই করুন।",
                        f"Found {len(drafts)} entries — please review."),
        "ocr_mock": True,  # 🔑 real OCR/vision provider gated
    }


def match_payment_to_due(notification, open_dues, lang="bn"):
    """Incoming bKash/Nagad notification → match to an open due + confirm prompt.

    notification: raw SMS/notif string. Parsed via money_parse if available.
    open_dues: [{id, name, phone?, amount}]. Returns best match + a confirm
    prompt. NEVER auto-deducts — asks the owner to confirm. We NEVER hold funds;
    this only reconciles the owner's OWN records against their OWN wallet notif.
    """
    parsed = None
    if _money_parse is not None and hasattr(_money_parse, "parse_sms"):
        try:
            parsed = _money_parse.parse_sms(notification)
        except Exception:
            parsed = None
    amount = (_to_decimal(parsed.get("amount")) if parsed else None) or \
        _extract_amount(notification)
    counterparty = (parsed.get("counterparty") if parsed else None)
    number = (parsed.get("counterparty_number") if parsed else None)

    best = None
    for d in open_dues or []:
        d_amt = _to_decimal(d.get("amount"))
        score = 0.0
        if amount is not None and d_amt is not None and amount == d_amt:
            score += 0.6
        if number and d.get("phone") and number[-6:] == str(d["phone"])[-6:]:
            score += 0.4
        if counterparty and d.get("name") and \
                counterparty.lower() in str(d["name"]).lower():
            score += 0.3
        if best is None or score > best[1]:
            best = (d, score)

    if best and best[1] >= 0.6:
        d = best[0]
        prompt = pick(
            lang,
            f"{d.get('name','')} ৳{amount} পাঠিয়েছে — খাতা থেকে বাদ দেব?",
            f"{d.get('name','')} sent ৳{amount} — deduct from the ledger?")
        return {"matched": True, "due_id": d.get("id"), "amount": str(amount),
                "confidence": round(best[1], 2), "confirm_prompt": prompt,
                "auto_apply": False}  # ALWAYS owner-confirmed
    return {"matched": False, "amount": str(amount) if amount else None,
            "confidence": round(best[1], 2) if best else 0.0,
            "confirm_prompt": pick(lang, "মিল পাওয়া যায়নি — ম্যানুয়ালি দেখুন।",
                                   "No match found — please review manually."),
            "auto_apply": False}


def insights(records, now_days=0, lang="bn"):
    """Rules over records (NO AI) → owner insights.

    records: {"sales_by_product": {name: {"this": n, "prev": n}},
              "dues": [{name, age_days, amount}]}
    Flags: sales down >=20%, dues older than 45 days. Deterministic.
    """
    out = []
    for name, v in (records.get("sales_by_product") or {}).items():
        prev = _to_decimal(v.get("prev")) or Decimal("0")
        this = _to_decimal(v.get("this")) or Decimal("0")
        if prev > 0:
            change = (this - prev) / prev
            if change <= Decimal("-0.20"):
                pct = int(abs(change) * 100)
                out.append({
                    "kind": "sales_down",
                    "product": name,
                    "pct": pct,
                    "text": pick(lang, f"{name} বিক্রি {pct}% কমেছে।",
                                 f"{name} sales down {pct}%."),
                })
    for d in (records.get("dues") or []):
        age = int(d.get("age_days") or 0)
        if age >= 45:
            out.append({
                "kind": "old_due",
                "name": d.get("name"),
                "age_days": age,
                "text": pick(lang, f"{d.get('name')}-এর বাকি {age} দিন পুরনো।",
                             f"{d.get('name')}'s due is {age} days old."),
            })
    return out


def bank_loan_report_data(sales_rows, lang="bn"):
    """DATA for a bank-loan application report — SALES HISTORY ONLY.

    *** WE DO NO LENDING. NO CREDIT SCORING. *** This returns the owner's own
    aggregated sales so THEY can hand it to a bank. We never score, approve, or
    lend anything.
    """
    rows = sales_rows or []
    total = sum((_to_decimal(r.get("amount")) or Decimal("0") for r in rows), Decimal("0"))
    months = {}
    for r in rows:
        m = r.get("month", "?")
        months[m] = (months.get(m, Decimal("0"))) + (_to_decimal(r.get("amount")) or Decimal("0"))
    n_months = len(months) or 1
    return {
        "total_sales": str(total),
        "months": {k: str(v) for k, v in sorted(months.items())},
        "avg_monthly_sales": str((total / n_months).quantize(Decimal("1"))),
        "disclaimer": pick(
            lang,
            "শুধুমাত্র বিক্রির তথ্য — আমরা কোনো ঋণ দিই না, ক্রেডিট স্কোর করি না।",
            "Sales data only — we do NOT lend money or do credit scoring."),
        "is_lending": False,
        "is_credit_scoring": False,
    }


# ===========================================================================
# §6 — PAYMENTS. NEVER HOLD MONEY / NEVER A WALLET. No balance custody.
# ===========================================================================

def merchant_qr_descriptor(owner_wallet, lang="bn"):
    """Describe the OWNER's OWN bKash/Nagad merchant QR. We only render a
    descriptor pointing at the owner's own merchant account — we NEVER create a
    balance, custody funds, or route money through us.

    owner_wallet: {"provider": "bkash"|"nagad", "merchant_number": "...",
                   "merchant_name": "..."}
    """
    provider = (owner_wallet.get("provider") or "").lower()
    if provider not in ("bkash", "nagad"):
        raise ValueError("only owner's own bkash/nagad merchant supported")
    return {
        "provider": provider,
        "merchant_number": owner_wallet.get("merchant_number"),
        "merchant_name": owner_wallet.get("merchant_name", ""),
        "holds_funds": False,       # INVARIANT: we never custody money
        "is_wallet": False,
        "routes_through_assisto": False,
        "label": pick(lang, f"{provider} মার্চেন্টে সরাসরি পরিশোধ করুন।",
                      f"Pay directly to the {provider} merchant."),
    }


def payment_link_builder(order, partner_key=None, lang="bn"):
    """Payment LINK through a LICENSED payment partner — NOT wired yet.

    We NEVER hold the money. truth (owner FINAL ORDER 27 Oct): no partner
    checkout API is called here, so we never return a made-up URL (it used to
    be a non-working example.com link flagged live once a key existed). The
    answer is always `live: False` with an empty link and `needs_key` /
    `not_wired` so the app shows the honest "not available yet" state; the
    owner's own bKash/Nagad merchant QR (merchant_qr_descriptor) is the real
    way to get paid today.
    """
    amount = _to_decimal(order.get("total")) or Decimal("0")
    return {
        "link": "",
        "amount": str(amount),
        "live": False,
        "holds_funds": False,      # INVARIANT: funds flow partner<->owner, not us
        "custodian": "licensed_partner",  # never 'assisto'
        "label": pick(lang, "অনলাইন পেমেন্ট লিংক এখনো চালু হয়নি — আপনার বিকাশ/নগদ মার্চেন্ট QR ব্যবহার করুন।",
                      "Online payment links are not available yet — use your bKash/Nagad merchant QR."),
        "needs_key": not partner_key,
        "not_wired": True,
    }
