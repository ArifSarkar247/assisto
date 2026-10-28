"""crm100 — lifeassisto.com/q/<token>: a shop's price quote for ONE customer.

No login: the signed link IS the permission (crm.shop_quote.token_for). One
language per page (?lang=en / ?lang=bn, default the language the seller made
the quote in), noindex, no-store, no ads, no JS, rate-limited per IP.

States, never a guess:
  open      issued / viewed, inside its validity → Accept (name + address)
            or Decline (optional reason)
  accepted  → the order number; nothing can be accepted twice
  declined  → says so
  expired   past valid_until → "ask the shop for a new quote"
  revoked   the seller withdrew it
  bad       forged / edited / unknown link → 404
Accepting creates the order (stock taken, payment status set) and pushes the
seller — crm.shop_quote.accept.
"""
from datetime import timedelta

from django.core.cache import cache
from django.http import HttpResponseRedirect
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .views import _ip_hash

GET_PER_MIN = 30
POST_PER_10MIN = 8

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
              "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")
_EN_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
              "Nov", "Dec")

TXT = {
    "bn": {
        "title": "দামের প্রস্তাব", "for": "যাঁর জন্য", "item": "পণ্য", "qty": "পরিমাণ",
        "price": "দাম", "subtotal": "মোট দাম", "discount": "ছাড়", "delivery": "ডেলিভারি চার্জ",
        "total": "সর্বমোট", "valid": "এই দাম থাকবে", "left_h": "আর {n} ঘণ্টা",
        "left_d": "আর {n} দিন", "note": "দোকানের কথা", "pay": "পেমেন্ট",
        "pay_cod": "ক্যাশ অন ডেলিভারি — পণ্য হাতে পেয়ে টাকা দেবেন",
        "pay_bkash": "অগ্রিম bKash — দোকান নম্বর জানাবে, টাকা পাঠানোর পর দোকান যাচাই করবে",
        "pay_nagad": "অগ্রিম Nagad — দোকান নম্বর জানাবে, টাকা পাঠানোর পর দোকান যাচাই করবে",
        "pay_paid": "টাকা আগেই দেওয়া হয়েছে",
        "name": "আপনার নাম", "address": "ডেলিভারির ঠিকানা",
        "address_need": "ডেলিভারির ঠিকানা লিখুন।",
        "accept": "প্রস্তাব গ্রহণ করে অর্ডার দিন",
        "accept_hint": "গ্রহণ করলে এই দামে অর্ডার হবে এবং দোকান আপনার সাথে যোগাযোগ করবে।",
        "decline": "এই প্রস্তাব নেব না", "reason": "কেন নিচ্ছেন না? (ইচ্ছা হলে)",
        "ok_h": "ধন্যবাদ! অর্ডার হয়েছে", "ok_b": "অর্ডার নম্বর #{n}। দোকান শিগগিরই যোগাযোগ করবে।",
        "declined": "আপনি এই প্রস্তাবটি নেননি। দোকানকে জানানো হয়েছে।",
        "expired": "এই দামের প্রস্তাবের মেয়াদ শেষ। নতুন প্রস্তাবের জন্য দোকানকে জানান।",
        "revoked": "দোকান এই প্রস্তাবটি তুলে নিয়েছে।",
        "bad": "লিংকটি ঠিক নেই।",
        "stock": "দুঃখিত, \"{item}\" এর স্টক শেষ — অর্ডার হয়নি। দোকানের সাথে যোগাযোগ করুন।",
        "limited": "অনেকবার চেষ্টা হয়েছে। কয়েক মিনিট পরে আবার খুলুন।",
        "privacy": "আপনার নাম ও ঠিকানা শুধু এই দোকান দেখবে। এখানে কোনো টাকা নেওয়া হয় না।",
        "by": "Assisto দিয়ে পাঠানো",
        "p_title": "প্রপোজাল", "tax": "ভ্যাট/কর",
        "p_accept": "প্রপোজাল গ্রহণ করুন",
        "p_hint": "গ্রহণ করলে বিক্রেতাকে জানানো হবে; অর্ডার ও পেমেন্টের ধাপ বিক্রেতা আপনার সাথে ঠিক করবেন।",
        "p_ok": "ধন্যবাদ! আপনি প্রপোজালটি গ্রহণ করেছেন। বিক্রেতাকে জানানো হয়েছে।",
        "p_privacy": "এই লিংক শুধু আপনার জন্য। এখানে কোনো টাকা নেওয়া হয় না।",
    },
    "en": {
        "title": "Price quote", "for": "For", "item": "Item", "qty": "Qty", "price": "Price",
        "subtotal": "Subtotal", "discount": "Discount", "delivery": "Delivery charge",
        "total": "Total", "valid": "This price holds until", "left_h": "{n} hours left",
        "left_d": "{n} days left", "note": "From the shop", "pay": "Payment",
        "pay_cod": "Cash on delivery — pay when you get the goods",
        "pay_bkash": "Advance on bKash — the shop will share the number and check the payment",
        "pay_nagad": "Advance on Nagad — the shop will share the number and check the payment",
        "pay_paid": "Already paid",
        "name": "Your name", "address": "Delivery address",
        "address_need": "Please write the delivery address.",
        "accept": "Accept and place the order",
        "accept_hint": "Accepting places an order at this price and the shop will contact you.",
        "decline": "No thanks", "reason": "Why not? (optional)",
        "ok_h": "Thank you! Your order is placed", "ok_b": "Order number #{n}. The shop will contact you soon.",
        "declined": "You declined this quote. The shop has been told.",
        "expired": "This quote has expired. Please ask the shop for a new one.",
        "revoked": "The shop withdrew this quote.",
        "bad": "This link is not valid.",
        "stock": "Sorry, \"{item}\" is out of stock — no order was made. Please contact the shop.",
        "limited": "Too many tries. Please open it again in a few minutes.",
        "privacy": "Only this shop sees your name and address. No money is taken on this page.",
        "by": "Sent with Assisto",
        "p_title": "Proposal", "tax": "VAT / tax",
        "p_accept": "Accept the proposal",
        "p_hint": "Accepting tells the seller; they will agree the order and payment steps with you.",
        "p_ok": "Thank you! You accepted the proposal. The seller has been told.",
        "p_privacy": "This link is only for you. No money is taken on this page.",
    },
}


def money(poisha, lang):
    p = int(poisha or 0)
    taka, rem = divmod(abs(p), 100)
    s = "{:,}".format(taka) + (".%02d" % rem if rem else "")
    s = ("-" if p < 0 else "") + "৳" + s
    return s.translate(_BN_DIGITS) if lang == "bn" else s


def num(n, lang):
    s = str(n)
    return s.translate(_BN_DIGITS) if lang == "bn" else s


def when(dt, lang):
    from core.logic import msg_guard as MG
    d = MG.local(dt)
    if lang == "bn":
        return "%s %s %s" % (num(d.day, "bn"), _BN_MONTHS[d.month - 1], num(d.year, "bn"))
    return "%d %s %d" % (d.day, _EN_MONTHS[d.month - 1], d.year)


def _lang(request, q=None):
    v = request.GET.get("lang")
    if v in ("bn", "en"):
        return v
    return q.lang if q is not None and q.lang in ("bn", "en") else "bn"


def _rate_ok(request, kind, limit, window_s, extra=""):
    bucket = int(timezone.now().timestamp() // window_s)
    key = "q:%s:%s:%s:%d" % (kind, _ip_hash(request), extra, bucket)
    try:
        n = cache.get(key, 0) + 1
        cache.set(key, n, window_s + 30)
        return n <= limit
    except Exception:  # noqa: BLE001
        return True


def _render(request, ctx, status=200):
    resp = render(request, "web/quote.html", ctx, status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


def _ctx(request, q, lang, now):
    from crm import shop_quote as SQ
    B = TXT[lang]
    state = SQ.effective_state(q, now)
    left = q.valid_until - now
    if left <= timedelta(0):
        left_txt = ""
    elif left < timedelta(hours=48):
        left_txt = B["left_h"].format(n=num(max(1, int(left.total_seconds() // 3600)), lang))
    else:
        left_txt = B["left_d"].format(n=num(left.days, lang))
    items = [{"name": it.get("name", ""), "qty": num(it.get("qty", 1), lang),
              "unit": money(it.get("unit_poisha", 0), lang),
              "line": money(int(it.get("unit_poisha", 0)) * int(it.get("qty", 1)), lang)}
             for it in (q.items or [])]
    return {"lang": lang, "B": B, "q": q, "state": state, "items": items,
            "shop": (q.business.shop_name or "").strip() or "Assisto",
            "subtotal": money(q.subtotal_poisha, lang),
            "discount": money(q.discount_poisha, lang) if q.discount_poisha else "",
            "delivery": money(q.delivery_poisha, lang) if q.delivery_poisha else "",
            "total": money(q.total_poisha, lang), "valid_until": when(q.valid_until, lang),
            "left": left_txt, "pay_text": B.get("pay_" + q.payment, B["pay_cod"]),
            "order_no": num(q.order_id, lang) if q.order_id else "",
            "qlang": "?lang=" + lang, "post_base": "/q/",
            "need_address": q.payment != "paid"}


@require_http_methods(["GET", "POST"])
def quote_page(request, token):
    from crm import shop_quote as SQ
    from crm.models import ShopQuote
    now = timezone.now()
    nonce = SQ.nonce_from(token)
    q = ShopQuote.objects.filter(nonce=nonce).select_related("business").first() \
        if nonce else None
    lang = _lang(request, q)
    B = TXT[lang]
    if q is None:
        return _render(request, {"lang": lang, "B": B, "state": "bad", "qlang": ""}, 404)
    if request.method == "GET":
        if not _rate_ok(request, "g", GET_PER_MIN, 60):
            return _render(request, {"lang": lang, "B": B, "state": "limited",
                                     "qlang": ""}, 429)
        SQ.mark_viewed(q, now)
        ctx = _ctx(request, q, lang, now)
        ctx.update(done=request.GET.get("done", ""), q_token=token)
        return _render(request, ctx)
    if not _rate_ok(request, "p", POST_PER_10MIN, 600, q.nonce[:8]):
        return _render(request, {"lang": lang, "B": B, "state": "limited", "qlang": ""}, 429)
    action = request.POST.get("action", "")
    name = (request.POST.get("name") or "").strip()[:120]
    address = (request.POST.get("address") or "").strip()[:600]
    error = ""
    try:
        if action == "accept":
            if not address and q.payment != "paid":
                error = B["address_need"]
            else:
                SQ.accept(q, name=name, address=address, now=now)
                return HttpResponseRedirect("/q/%s?lang=%s&done=accepted" % (token, lang))
        elif action == "decline":
            SQ.decline(q, reason=request.POST.get("reason", ""), now=now)
            return HttpResponseRedirect("/q/%s?lang=%s&done=declined" % (token, lang))
    except SQ.QuoteError as e:
        if e.code == "out_of_stock":
            error = B["stock"].format(item=e.extra.get("item", ""))
        # expired / not_open: the page below shows the real state
    q.refresh_from_db()
    ctx = _ctx(request, q, lang, now)
    ctx.update(error=error, form={"name": name, "address": address}, q_token=token)
    return _render(request, ctx, 400 if error else 200)


def _taka_p(v):
    try:
        return int(round(float(v or 0) * 100))
    except (TypeError, ValueError):
        return 0


@require_http_methods(["GET", "POST"])
def proposal_page(request, token):
    """crm100: lifeassisto.com/qp/<token> — a B2B CRM proposal the buyer
    accepts or declines (random token, crm.views.proposal_decide)."""
    from crm.models import QuoteAcceptance
    from crm.views import proposal_decide, proposal_expired
    now = timezone.now()
    acc = (QuoteAcceptance.objects.filter(token=str(token or "")[:64])
           .select_related("proposal__lead__org").first())
    lang = _lang(request)
    B = TXT[lang]
    if acc is None or not _rate_ok(request, "pg" if request.method == "GET" else "pp",
                                   GET_PER_MIN if request.method == "GET" else POST_PER_10MIN,
                                   60 if request.method == "GET" else 600):
        st = "bad" if acc is None else "limited"
        return _render(request, {"lang": lang, "B": B, "state": st, "qlang": ""},
                       404 if acc is None else 429)
    prop = acc.proposal
    if request.method == "POST":
        act = request.POST.get("action", "")
        if act in ("accept", "decline"):
            proposal_decide(acc, act, now)
            return HttpResponseRedirect("/qp/%s?lang=%s" % (token, lang))
    if acc.state in ("issued", "viewed") and proposal_expired(prop, now):
        QuoteAcceptance.objects.filter(pk=acc.pk, state__in=("issued", "viewed")).update(
            state="expired")
        acc.state = "expired"
    if acc.state == "issued":
        QuoteAcceptance.objects.filter(pk=acc.pk, state="issued").update(
            state="viewed", viewed_at=now)
        acc.state = "viewed"
    items = []
    for li in prop.line_items or []:
        qty = int(li.get("qty") or 1)
        unit = _taka_p(li.get("unit_price"))
        items.append({"name": li.get("label") or li.get("sku") or "", "qty": num(qty, lang),
                      "unit": money(unit, lang),
                      "line": money(_taka_p(li.get("amount")) or unit * qty, lang)})
    valid = None
    if prop.valid_days:
        from datetime import datetime, time as dtime
        d = prop.created_at.date() + timedelta(days=int(prop.valid_days))
        valid = when(timezone.make_aware(datetime.combine(d, dtime(12, 0))), lang)
    disc = _taka_p(prop.discount_amount)
    tax = _taka_p(prop.tax_amount)
    ctx = {"lang": lang, "B": B, "b2b": True, "state": acc.state, "items": items,
           "shop": prop.lead.org.name,
           "q": {"customer_name": prop.lead.company or prop.lead.name, "note": prop.title},
           "subtotal": money(_taka_p(prop.subtotal), lang),
           "discount": money(disc, lang) if disc else "",
           "tax": money(tax, lang) if tax else "", "delivery": "",
           "total": money(_taka_p(prop.total), lang), "valid_until": valid or "",
           "left": "", "pay_text": "", "order_no": "", "need_address": False,
           "qlang": "?lang=" + lang, "q_token": token, "post_base": "/qp/"}
    return _render(request, ctx)
