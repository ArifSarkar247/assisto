"""
Business mode (feature 33) — reply from the REAL catalog only. Prices/stock
come from Product rows; AI (if available) only phrases a reply using those
facts, never inventing. The AI never claims to be human. Low-confidence →
human handoff. Auto-send/auto-reply is OFF by default and only runs when the
owner enabled it AND a messaging integration is connected.
"""
from decimal import Decimal

from . import ai


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


def _facts(products):
    return "\n".join(
        f"- {p.name}: দাম ৳{p.price}, স্টক {p.stock}"
        + (f", {p.description[:80]}" if p.description else "")
        for p in products)


def reply_for(user, incoming_text):
    """Return (reply_text, needs_handoff, used_ai). Only real catalog facts."""
    from .models import BusinessProfile
    prof = getattr(user, "business", None) or BusinessProfile(user=user)
    products = match_products(user, incoming_text)

    if not products:
        # nothing matched → human handoff (never guess an answer)
        note = prof.handoff_note or "আমাদের একজন শীঘ্রই আপনাকে জানাবেন। / Someone will get back to you shortly."
        return (note, True, False)

    facts = _facts(products)
    # Out of stock → honest
    if all(p.stock <= 0 for p in products):
        names = ", ".join(p.name for p in products)
        return (f"দুঃখিত, এই মুহূর্তে {names} স্টকে নেই। / Sorry, {names} is out of stock right now.",
                False, False)

    if not ai.available():
        # plain, factual reply (no AI needed, still honest)
        lines = [f"{p.name} — দাম ৳{p.price}" + (" (স্টকে আছে)" if p.stock > 0 else " (স্টক নেই)")
                 for p in products]
        return ("\n".join(lines), False, False)

    style = f"দোকানের নাম: {prof.shop_name or ''}. সুর: {prof.style_sample[:300]}" if prof else ""
    task = ("তুমি একটি দোকানের বিনয়ী সহকারী (AI, মানুষ নয়)। নিচের <data>-এর "
            "তথ্যের বাইরে কোনো দাম/স্টক বলবে না; অনুমান করবে না। গ্রাহকের প্রশ্নের "
            "সংক্ষিপ্ত, ভদ্র উত্তর দাও শুধু এই তথ্য দিয়ে।"
            + (f" দোকানের সুর অনুসরণ করো: {style}" if style else ""))
    data = f"গ্রাহক: {incoming_text}\n\nক্যাটালগ তথ্য:\n{facts}"
    try:
        text, _ = ai.generate(task=task, data=data, tier="cheap",
                               feature="business.reply", max_tokens=300, user=user)
        return (text, False, True)
    except ai.AIUnavailable:
        lines = [f"{p.name} — ৳{p.price}" for p in products]
        return ("\n".join(lines), False, False)


def capture_order(user, text, customer_phone="", channel="manual"):
    """Very small rule-based order capture: matched products × qty 1 → Order(new).
    Confirmation is drafted; nothing ships without owner confirmation."""
    from .models import Order
    products = match_products(user, text)
    if not products:
        return (None, "কোন পণ্য শনাক্ত হয়নি / no product identified")
    items = [{"name": p.name, "qty": 1, "price": str(p.price)} for p in products]
    total = sum((Decimal(str(p.price)) for p in products), Decimal("0"))
    order = Order.objects.create(user=user, customer_phone=customer_phone,
                                 items=items, total=total, channel=channel)
    names = ", ".join(i["name"] for i in items)
    draft = (f"অর্ডার #{order.id}: {names} — মোট ৳{total}. "
             f"ঠিকানা ও নিশ্চিত করতে উত্তর দিন। / Reply to confirm & share address.")
    return (order, draft)
