"""
AF-10 — the HANDOFF CARD (Agentforce "handoff with context" parity).

When the live AI sales agent hands a chat to the seller (approval queue,
complaint, refund, big order, abuse, low confidence, out of replies …) the
seller gets a short, rule-made summary instead of having to scroll the chat:

  line 1  what the customer wants + the products / qty / price discussed
  line 2  the customer's last question (phones / e-mails / long numbers
          partly hidden: 017•••••678, a•••@mail.com, ••••4321)
  line 3  why it was handed over + the customer's mood

Deterministic from the thread (0 credits, no AI call), bn AND en (Bangla
digits in bn). The same card rides on the seller's push and on the Business
inbox thread / approval rows. An abusive customer's words are NEVER quoted
on the card (the seller reads them in the chat itself).

PURE: no DB, no network. Callers pass plain dicts.
"""
import re

from . import bizagent as BZ
from . import business_ai as bai

_BN_DIG = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")

REASON_LABEL = {
    BZ.RISK_COMPLAINT: ("অভিযোগ / অসন্তুষ্ট গ্রাহক", "complaint / unhappy customer"),
    BZ.RISK_REFUND: ("রিটার্ন বা রিফান্ড চান", "wants a return or refund"),
    BZ.RISK_BELOW_MIN: ("সর্বনিম্ন দামের নিচে দাম চাইছেন", "asks below your minimum price"),
    BZ.RISK_UNKNOWN_PRODUCT: ("পণ্যটি ক্যাটালগে পাওয়া যায়নি", "product not found in the catalog"),
    BZ.RISK_LOW_CONF: ("AI নিশ্চিত নয়", "the AI was not sure"),
    BZ.RISK_NUMBERS: ("উত্তরে যাচাই-না-করা সংখ্যা ছিল", "the draft had an unchecked number"),
    BZ.RISK_BIG_ORDER: ("বড় অর্ডার", "big order"),
    BZ.RISK_APPROVE_ALL: ("আপনি সব উত্তর নিজে অনুমোদন করেন", "you approve every reply"),
    BZ.RISK_ABUSE: ("গালিগালাজ / হুমকি — AI কিছুক্ষণ চুপ থাকবে",
                    "abuse / threat — the AI stays quiet for a while"),
    BZ.RISK_UNSAFE: ("AI-এর উত্তর নিরাপদ ছিল না — পাঠানো হয়নি",
                     "the AI draft was not safe — not sent"),
    BZ.RISK_SCAM: ("সম্ভাব্য প্রতারণা / ফিশিং — লিংকে ক্লিক করবেন না, কোনো কোড দেবেন না",
                   "possible scam / phishing — don't click links or share any code"),
    BZ.RISK_ORDER_CHANGE: ("অর্ডার বদল / বাতিল চান", "wants to change / cancel an order"),
    "daily_ai_cap": ("আজকের AI সীমা শেষ", "today's AI limit is used up"),
    "out_of_replies": ("AI উত্তরের কোটা শেষ", "out of AI replies"),
}
MOOD_LABEL = {
    "abusive": ("রাগান্বিত, অশালীন ভাষা", "angry, abusive language"),
    "unhappy": ("অসন্তুষ্ট", "unhappy"),
    "positive": ("খুশি", "happy"),
    "neutral": ("স্বাভাবিক", "neutral"),
}
WANT_LABEL = {
    "order": ("অর্ডার করতে চান", "wants to order"),
    "price_stock": ("দাম / স্টক জানতে চান", "asks price / stock"),
    "bargain": ("দাম কমাতে চান", "wants a lower price"),
    "parcel_status": ("পার্সেলের খবর চান", "asks about the parcel"),
    "refund": ("রিটার্ন / রিফান্ড চান", "wants a return / refund"),
    "complaint": ("অভিযোগ করছেন", "has a complaint"),
    "greeting": ("কথা শুরু করেছেন", "started the chat"),
    "unknown": ("একটি প্রশ্ন করেছেন", "asked a question"),
}
_Q_CUES = re.compile(
    r"\?|？|(?<![ঀ-৿])কি(?![ঀ-৿])|কী|কত|কবে|কখন|কোথায়|কোথায়|কিভাবে|কীভাবে|কেন|আছে কি|পাবো|পাব|"
    r"(?<![a-z])(?:ki|koto|kobe|kokhon|kothay|kivabe|keno|ache|how|what|when|where|why|"
    r"price|dam|can|do you|is it)(?![a-z])", re.I)
_POSITIVE = re.compile(r"ধন্যবাদ|থ্যাংক|ভালো লেগেছে|সুন্দর|দারুণ|অসাধারণ|(?<![a-z])(?:thanks|thank you|"
                       r"thx|great|nice|love it|awesome|dhonnobad|valo laglo|sundor|darun)(?![a-z])|"
                       r"😊|❤|👍|🥰", re.I)


def _pick(lang, pair):
    return pair[0] if lang == "bn" else pair[1]


_EN_DIG = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _digits(lang, s):
    """Strict digits per language: Bangla digits in bn, ASCII in en."""
    return str(s).translate(_BN_DIG) if lang == "bn" else str(s).translate(_EN_DIG)


def _money(v):
    try:
        return BZ._fmt_money(v)
    except Exception:  # noqa: BLE001
        return str(v)


def hide_contact(text):
    """Phones / NID / account numbers / e-mails partly hidden (enough for the
    seller to recognise, never the full value on a push)."""
    from ..agentcore import trust as T
    out = str(text or "")

    def part(kind, v):
        if kind == "EMAIL" and "@" in v:
            name, dom = v.split("@", 1)
            return (name[:1] + "•••@" + dom) if name else v
        digits = [c for c in v if c.isdigit()]
        if kind == "PHONE" and len(digits) >= 6:
            return "".join(digits[:3]) + "•••••" + "".join(digits[-3:])
        return "••••" + "".join(digits[-4:]) if len(digits) >= 4 else "••••"

    for kind, rx in T._PATTERNS:
        out = rx.sub(lambda m, k=kind: part(k, m.group(0)), out)
    return out


def _short(text, n=90):
    t = re.sub(r"\s+", " ", str(text or "")).strip()
    return t if len(t) <= n else t[: n - 1].rstrip() + "…"


def sentiment(customer_texts):
    """abusive | unhappy | positive | neutral — from the customer's own words."""
    from .. import ai_guard as G
    joined = "\n".join(customer_texts or [])
    tox = G.toxicity(joined)
    if tox["severity"] >= 2:
        return "abusive"
    recent = "\n".join((customer_texts or [])[-3:])
    trig = bai.handoff_trigger(recent)
    if tox["severity"] == 1 or trig in (bai.HANDOFF_ANGRY, bai.HANDOFF_REFUND):
        return "unhappy"
    if _POSITIVE.search(recent):
        return "positive"
    return "neutral"


def _want(customer_texts, draft, reason):
    last = (customer_texts or [""])[-1]
    if reason == BZ.RISK_REFUND:
        return "refund"
    if reason in (BZ.RISK_COMPLAINT, BZ.RISK_ABUSE):
        return "complaint"
    if reason == BZ.RISK_BELOW_MIN:
        return "bargain"
    if reason == BZ.RISK_ORDER_CHANGE:
        return "order"
    if (draft or {}).get("active") or (draft or {}).get("state") == "awaiting_confirm" or \
            reason == BZ.RISK_BIG_ORDER:
        return "order"
    intent = bai.classify_intent(last)
    if intent == "greeting" and not _GREETING.search((last or "").lower()):
        # classify_intent matches "hi" inside "Hilsa" on short texts: a real
        # greeting needs a whole greeting word; otherwise judge the rest
        intent = bai.classify_intent((last or "") + " . . .")
    return intent if intent in WANT_LABEL else "unknown"


_GREETING = re.compile(r"(?<![a-z])(?:hi|hello|salam|assalamu\w*)(?![a-z])|আসসালাম|হ্যালো|নমস্কার")


def _items(customer_texts, catalog, draft):
    """[{name, qty, price}] — the order draft's product first, then products
    the customer named (catalog prices only; never a guessed number)."""
    draft = draft or {}
    out, seen = [], set()
    by_id = {p.get("id"): p for p in catalog or []}
    agreed = draft.get("agreed") or {}
    if draft.get("product"):
        p = by_id.get(draft.get("product_id")) or {}
        price = agreed.get("price") if agreed.get("product_id") == draft.get("product_id") \
            else p.get("price")
        name = draft["product"] + ((" (" + draft["variant_label"] + ")")
                                   if draft.get("variant_label") else "")
        out.append({"name": name, "qty": int(draft.get("qty") or 1),
                    "price": _money(price) if price not in (None, "") else ""})
        seen.add(draft.get("product_id"))
    for t in reversed(customer_texts[-4:] if customer_texts else []):
        for p in BZ.match_products(t, catalog or []):
            if p.get("id") in seen:
                continue
            seen.add(p.get("id"))
            out.append({"name": p.get("name") or "", "qty": BZ.find_qty(t) or 1,
                        "price": _money(p.get("price")) if p.get("price") not in (None, "") else ""})
        if len(out) >= 3:
            break
    return out[:3]


def _last_question(customer_texts):
    for t in reversed(customer_texts or []):
        if t and not t.startswith("[") and _Q_CUES.search(t):
            return t
    for t in reversed(customer_texts or []):
        if t and not t.startswith("["):
            return t
    return ""


def build(messages, catalog=None, draft=None, reason="", problems=None):
    """messages: [{"direction": "in"|"out", "text": str}] oldest -> newest.
    -> {"reason", "want", "items", "total", "sentiment", "last_question",
        "lines": {"bn": [3], "en": [3]}} — masked, bn + en."""
    cust = [str(m.get("text") or "") for m in messages or [] if m.get("direction") == "in"]
    cust = [c for c in cust if c.strip()]
    draft = draft or {}
    mood = sentiment(cust)
    want = _want(cust, draft, reason)
    items = _items(cust, catalog, draft)
    total = draft.get("total") or ""
    q = "" if mood == "abusive" else _short(hide_contact(_last_question(cust)))
    lines = {}
    for lang in ("bn", "en"):
        bits = ", ".join(
            "%s × %s%s" % (i["name"], _digits(lang, i["qty"]),
                           (" (৳%s)" % _digits(lang, i["price"])) if i["price"] else "")
            for i in items)
        l1 = (bai.pick(lang, "চান: ", "Wants: ") + _pick(lang, WANT_LABEL[want])
              + ((" — " + bits) if bits else "")
              + ((bai.pick(lang, " · মোট ৳", " · total ৳") + _digits(lang, _money(total)))
                 if total else ""))
        if mood == "abusive":
            l2 = bai.pick(lang, "শেষ মেসেজ: অশালীন ভাষা — চ্যাটে দেখুন",
                          "Last message: abusive language — see the chat")
        elif q:
            l2 = bai.pick(lang, "শেষ প্রশ্ন: “%s”", "Last question: “%s”") % _digits(lang, q)
        else:
            l2 = bai.pick(lang, "শেষ প্রশ্ন: —", "Last question: —")
        rl = REASON_LABEL.get(reason) or REASON_LABEL[BZ.RISK_LOW_CONF]
        l3 = (bai.pick(lang, "কারণ: ", "Why: ") + _pick(lang, rl) + " · "
              + bai.pick(lang, "মেজাজ: ", "Mood: ") + _pick(lang, MOOD_LABEL[mood]))
        lines[lang] = [l1, l2, l3]
    return {"reason": reason or BZ.RISK_LOW_CONF, "want": want, "items": items,
            "total": _money(total) if total else "", "sentiment": mood,
            "last_question": q, "problems": [p.get("type") for p in problems or []
                                             if isinstance(p, dict)][:5],
            "lines": lines}
