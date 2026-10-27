"""
Business mode (feature 33) — reply from the REAL catalog only. Prices/stock
come from Product rows; AI (if available) only phrases a reply using those
facts, never inventing. The AI never claims to be human. Low-confidence →
human handoff. Auto-send/auto-reply is OFF by default and only runs when the
owner enabled it AND a messaging integration is connected.
"""
from decimal import Decimal

from . import ai
from .i18n import pick


def match_products(user, text):
    """Rule-based catalog match — which of the user's products the message names."""
    from .models import Product
    low = (text or "").lower()
    hits = []
    for p in Product.objects.filter(user=user):
        name = (p.name or "").lower()
        if not name:
            continue
        # match on full name or any significant word
        words = [w for w in name.split() if len(w) >= 3]
        if name in low or any(w in low for w in words):
            hits.append(p)
    return hits


def _facts(lang, products):
    price_lbl = pick(lang, "দাম", "price")
    stock_lbl = pick(lang, "স্টক", "stock")
    return "\n".join(
        f"- {p.name}: {price_lbl} ৳{p.price}, {stock_lbl} {p.stock}"
        + (f", {p.description[:80]}" if p.description else "")
        for p in products)


# NOTE for integrator: core/views.py BusinessReplyView.post calls reply_for()
# without a lang; thread it through, e.g.:
#   from .i18n import req_lang
#   reply, handoff, used_ai = business.reply_for(request.user, text, lang=req_lang(request))
def reply_for(user, incoming_text, lang="bn"):
    """Return (reply_text, needs_handoff, used_ai). Only real catalog facts."""
    from .models import BusinessProfile
    prof = getattr(user, "business", None) or BusinessProfile(user=user)
    products = match_products(user, incoming_text)

    if not products:
        # nothing matched → human handoff (never guess an answer)
        note = prof.handoff_note or pick(
            lang,
            "আমাদের একজন শীঘ্রই আপনাকে জানাবেন।",
            "Someone will get back to you shortly.")
        return (note, True, False)

    facts = _facts(lang, products)
    # Out of stock → honest
    if all(p.stock <= 0 for p in products):
        names = ", ".join(p.name for p in products)
        msg = pick(lang,
                   f"দুঃখিত, এই মুহূর্তে {names} স্টকে নেই।",
                   f"Sorry, {names} is out of stock right now.")
        return (msg, False, False)

    if not ai.available():
        # plain, factual reply (no AI needed, still honest)
        price_lbl = pick(lang, "দাম", "price")
        in_stock = pick(lang, " (স্টকে আছে)", " (in stock)")
        no_stock = pick(lang, " (স্টক নেই)", " (out of stock)")
        lines = [f"{p.name} — {price_lbl} ৳{p.price}" + (in_stock if p.stock > 0 else no_stock)
                 for p in products]
        return ("\n".join(lines), False, False)

    style = (pick(lang,
                  f"দোকানের নাম: {prof.shop_name or ''}. সুর: {prof.style_sample[:300]}",
                  f"Shop name: {prof.shop_name or ''}. Tone: {prof.style_sample[:300]}")
             if prof else "")
    task = pick(
        lang,
        ("তুমি একটি দোকানের বিনয়ী সহকারী (AI, মানুষ নয়)। নিচের <data>-এর "
         "তথ্যের বাইরে কোনো দাম/স্টক বলবে না; অনুমান করবে না। গ্রাহকের প্রশ্নের "
         "সংক্ষিপ্ত, ভদ্র উত্তর দাও শুধু এই তথ্য দিয়ে।"
         + (f" দোকানের সুর অনুসরণ করো: {style}" if style else "")),
        ("You are a shop's polite assistant (AI, not a human). Do not state any "
         "price/stock beyond the facts in <data>; never guess. Give a short, "
         "polite reply to the customer's question using only these facts."
         + (f" Follow the shop's tone: {style}" if style else "")))
    data = pick(lang,
                f"গ্রাহক: {incoming_text}\n\nক্যাটালগ তথ্য:\n{facts}",
                f"Customer: {incoming_text}\n\nCatalog facts:\n{facts}")
    try:
        text, _ = ai.generate(task=task, data=data, tier="cheap",
                               feature="business.reply", max_tokens=300, user=user)
    except ai.AIUnavailable:
        lines = [f"{p.name} — ৳{p.price}" for p in products]
        return ("\n".join(lines), False, False)
    # aieval guard: a price/number not in the catalog facts or the customer's
    # own text, a refund promise or a "I am human" claim is NEVER sent — the
    # customer gets the plain catalog facts instead (honest, no AI wording).
    from . import ai_guard
    if ai_guard.check_sales_answer(text, facts, incoming_text):
        lines = [f"{p.name} — ৳{p.price}" for p in products]
        return ("\n".join(lines), False, False)
    return (text, False, True)


# NOTE for integrator: core/views.py BusinessOrderCaptureView.post calls
# capture_order() without a lang; pass lang=req_lang(request).
def capture_order(user, text, customer_phone="", channel="manual", lang="bn"):
    """Very small rule-based order capture: matched products × qty 1 → Order(new).
    Confirmation is drafted; nothing ships without owner confirmation."""
    from .models import Order
    products = match_products(user, text)
    if not products:
        return (None, pick(lang, "কোন পণ্য শনাক্ত হয়নি", "No product identified"))
    items = [{"name": p.name, "qty": 1, "price": str(p.price)} for p in products]
    total = sum((Decimal(str(p.price)) for p in products), Decimal("0"))
    order = Order.objects.create(user=user, customer_phone=customer_phone,
                                 items=items, total=total, channel=channel)
    names = ", ".join(i["name"] for i in items)
    draft = pick(
        lang,
        f"অর্ডার #{order.id}: {names} — মোট ৳{total}. ঠিকানা ও নিশ্চিত করতে উত্তর দিন।",
        f"Order #{order.id}: {names} — total ৳{total}. Reply to confirm & share your address.")
    return (order, draft)
