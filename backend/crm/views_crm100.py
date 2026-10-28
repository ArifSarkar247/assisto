"""crm100 API — one customer history page, shop price quotes, send from CRM.

    GET  crm/customers/?q=&only=&offset=&limit=&business=     merged list
    GET  crm/customers/history/?phone=|party=|lead=|customer=|order=
             &before=&limit=&kinds=khata,order,...             one timeline
    GET  crm/shop-quotes/?phone=&state=                        seller's quotes
    POST crm/shop-quotes/                                      create (catalog)
    GET  crm/shop-quotes/<id>/                                 one quote
    POST crm/shop-quotes/<id>/extend/ {days}  |  /revoke/
    GET  crm/shop-quotes/catalog/?q=                           picker
    POST crm/send/preview  {phone|party|lead, text}            links + SMS cost
    POST crm/send/log      {.., channel: whatsapp_link|sms_app, text}
    POST crm/send/sms      {.., text, credits}                 Assisto SMS
    POST crm/send/bulk     {targets:[{phone|party|lead}], text} per-customer cards

Public (no login): /q/<token> — web/views_quote.py.
"""
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from core.i18n import pick, req_lang

from . import customer360 as C
from . import send_paths as SP
from . import shop_quote as SQ
from .views import CrmErrorMixin


def _err(request, bn, en, status=400, code="error", **extra):
    d = {"error": code, "detail": pick(req_lang(request), bn, en)}
    d.update(extra)
    return Response(d, status=status)


def _scope(request):
    scope, bad = C.scope_for(request)
    return scope, bad


def _person(request, scope, src):
    p, why = C.resolve(scope, src)
    if p is None:
        return None, _err(request, "এই গ্রাহককে পাওয়া যায়নি।", "Customer not found.",
                          status=404, code="not_found")
    return p, None


def _known(p):
    """A real customer of this shop / CRM (not a typed stranger)."""
    return bool(p.party_ids or p.customer_ids or p.order_ids or p.thread_ids or p.lead_ids)


class CustomerListView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        qp = request.query_params
        data = C.directory(scope, q=qp.get("q", ""), limit=C._int(qp.get("limit"), 50),
                           offset=C._int(qp.get("offset"), 0), only=qp.get("only") or None)
        data.update(has_business=scope.business is not None, has_crm=bool(scope.org_ids),
                    role=scope.role or "")
        return Response(data)


class CustomerHistoryView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        p, bad = _person(request, scope, request.query_params)
        if bad is not None:
            return bad
        qp = request.query_params
        before = C.parse_before(qp.get("before"))
        kinds = [k for k in (qp.get("kinds") or "").split(",") if k] or None
        items, nxt = C.timeline(scope, p, before=before, limit=C._int(qp.get("limit"), 40),
                                kinds=kinds)
        out = {"items": items, "next_before": nxt, "server_time": timezone.now().isoformat()}
        if before is None:
            out["summary"] = C.summary(scope, p)
        return Response(out)


# ------------------------------------------------------------------ quotes
_Q_ERR = {
    "no_items": ("অন্তত একটি পণ্য বেছে নিন।", "Pick at least one product."),
    "too_many_items": ("একটি প্রস্তাবে সর্বোচ্চ ৩০টি পণ্য।", "At most 30 products in one quote."),
    "unknown_product": ("এই পণ্যটি আপনার ক্যাটালগে নেই।", "This product is not in your catalog."),
    "unknown_variant": ("এই সাইজ/রং পাওয়া যায়নি।", "This size/colour was not found."),
    "bad_qty": ("পরিমাণ ১ থেকে ৯৯৯-এর মধ্যে দিন।", "Quantity must be 1 to 999."),
    "no_price": ("এই পণ্যের বিক্রির দাম দেওয়া নেই — আগে ক্যাটালগে দাম দিন।",
                 "This product has no selling price — set it in the catalog first."),
    "bad_price": ("দাম ঠিক নেই।", "The price is not valid."),
    "below_min": ("এই দাম আপনার সর্বনিম্ন দামের চেয়ে কম — দেওয়া যাবে না।",
                  "This price is below your lowest allowed price."),
    "discount_too_big": ("এত ছাড় দেওয়া যাবে না — সর্বনিম্ন দামের নিচে চলে যায়।",
                         "This discount is too big — it goes below your lowest prices."),
    "bad_delivery": ("ডেলিভারি চার্জ ঠিক নেই।", "The delivery charge is not valid."),
    "bad_validity": ("মেয়াদ ১ থেকে ৩০ দিনের মধ্যে দিন।", "Validity must be 1 to 30 days."),
    "bad_payment": ("পেমেন্টের ধরন ঠিক নেই।", "The payment type is not valid."),
    "not_open": ("এই প্রস্তাব এখন আর বদলানো যায় না।", "This quote can't be changed now."),
    "expired": ("এই প্রস্তাবের মেয়াদ শেষ।", "This quote has expired."),
    "out_of_stock": ("স্টক শেষ — অর্ডার হয়নি।", "Out of stock — no order was made."),
}


def _quote_err(request, e, role):
    bn, en = _Q_ERR.get(e.code, ("প্রস্তাবটি তৈরি করা যায়নি।", "Couldn't make the quote."))
    extra = dict(e.extra)
    if e.code == "discount_too_big" and role != "owner":
        extra.pop("max_poisha", None)      # the floor is owner-only
    return _err(request, bn, en, status=400, code=e.code, **extra)


def _require_shop(request, scope):
    if scope.business is None:
        return _err(request, "আগে ব্যবসা চালু করুন — তারপর দামের প্রস্তাব পাঠানো যাবে।",
                    "Set up your business first — then you can send quotes.",
                    status=409, code="no_business")
    return None


def _quote_gate(request, scope):
    """plans-v2: a new quote is a new CRM record → crm_write (the SHOP
    owner's plan decides). No-op while plans_v2 is off for that owner."""
    from core import entitlements_service as ES
    return ES.check(scope.owner, "crm_write", req_lang(request))


def _abs(path):
    from core.journey_watch import site
    return site() + path


def _quote_out(q, role):
    d = SQ.as_dict(q, role=role)
    d["url"] = _abs(d["path"])
    return d


class ShopQuoteListView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import ShopQuote
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        if scope.business is None:
            return Response({"results": [], "has_business": False})
        qs = ShopQuote.objects.filter(business=scope.business)
        k = C.phone_key(request.query_params.get("phone"))
        if k:
            qs = qs.filter(phone_key=k)
        rows = [_quote_out(q, scope.role) for q in qs[:200]]
        st = request.query_params.get("state")
        if st:
            rows = [r for r in rows if r["state"] == st]
        return Response({"results": rows, "has_business": True})

    def post(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        bad = _require_shop(request, scope) or _quote_gate(request, scope)
        if bad is not None:
            return bad
        try:
            q, warnings = SQ.build(scope.business, request.user, request.data)
        except SQ.QuoteError as e:
            return _quote_err(request, e, scope.role)
        out = _quote_out(q, scope.role)
        out["warnings"] = warnings
        return Response(out, status=201)


class ShopQuoteDetailView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def _get(self, request, pk):
        from .models import ShopQuote
        scope, bad = _scope(request)
        if bad is not None:
            return None, None, bad
        q = (ShopQuote.objects.filter(business=scope.business, pk=pk).first()
             if scope.business is not None else None)
        if q is None:
            return None, None, _err(request, "প্রস্তাবটি পাওয়া যায়নি।", "Quote not found.",
                                    status=404, code="not_found")
        return scope, q, None

    def get(self, request, pk, op=None):
        scope, q, bad = self._get(request, pk)
        return bad or Response(_quote_out(q, scope.role))

    def post(self, request, pk, op=None):
        scope, q, bad = self._get(request, pk)
        if bad is not None:
            return bad
        try:
            if op == "extend":
                SQ.extend(q, request.data.get("days"))
            elif op == "revoke":
                SQ.revoke(q)
            else:
                return _err(request, "অজানা কাজ।", "Unknown action.", status=400)
        except SQ.QuoteError as e:
            return _quote_err(request, e, scope.role)
        return Response(_quote_out(q, scope.role))


class ShopQuoteCatalogView(CrmErrorMixin, APIView):
    """The seller's own products for the quote picker. Minimum price only
    for the owner (staff never see the floor)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from core.models import Product
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        if scope.business is None:
            return Response({"results": [], "has_business": False})
        from django.db.models import Q
        qs = Product.objects.filter(user=scope.business.user).filter(
            Q(business=scope.business) | Q(business__isnull=True))
        term = (request.query_params.get("q") or "").strip()
        if term:
            qs = qs.filter(name__icontains=term[:60])
        owner = scope.role == "owner"
        out = []
        for p in qs.prefetch_related("variants").order_by("name")[:300]:
            vs = []
            for vkey, size, colour, sell, mn, stock in SQ._variant_rows(p):
                v = {"key": vkey, "size": size, "colour": colour,
                     "sell_poisha": sell, "stock": stock}
                if owner:
                    v["min_poisha"] = mn
                vs.append(v)
            out.append({"id": p.id, "name": p.name, "category": p.category,
                        "variants": vs})
        return Response({"results": out, "has_business": True, "role": scope.role})


# ------------------------------------------------------------------ send
_SMS_ERR = {
    "sms_not_configured": (503, "SMS গেটওয়ে এখনো যুক্ত নেই — WhatsApp বা ফোনের SMS দিয়ে পাঠান।",
                           "No SMS gateway yet — send it on WhatsApp or your phone's SMS."),
    "insufficient_credits": (402, "ক্রেডিট নেই — SMS পাঠাতে ক্রেডিট লাগে।",
                             "Not enough credits — an SMS needs credits."),
    "opted_out": (409, "এই গ্রাহক মেসেজ বন্ধ করেছেন (STOP)।", "This customer opted out (STOP)."),
    "quiet_hours": (409, "রাত ৯টা থেকে সকাল ৯টা SMS পাঠানো হয় না।", "No SMS between 9 pm and 9 am."),
    "phone_daily_cap": (429, "এই গ্রাহককে আজ আর SMS পাঠানো যাবে না।",
                        "No more SMS to this customer today."),
    "business_daily_cap": (429, "আজকের ব্যবসার SMS সীমা শেষ।", "Today's business SMS limit is reached."),
    "user_daily_cap": (429, "আজকের SMS সীমা শেষ।", "Today's SMS limit is reached."),
    "global_daily_cap": (429, "আজকের SMS সীমা শেষ। কাল আবার চেষ্টা করুন।",
                         "Today's SMS limit is reached. Try tomorrow."),
    "purpose_off": (503, "CRM থেকে SMS এখন বন্ধ।", "SMS from the CRM is off right now."),
    "bad_phone": (400, "গ্রাহকের সঠিক মোবাইল নম্বর নেই।", "This customer has no valid mobile number."),
    "too_long": (400, "মেসেজ বেশি লম্বা।", "The message is too long."),
    "send_failed": (502, "SMS পাঠানো যায়নি — ক্রেডিট ফেরত দেওয়া হয়েছে।",
                    "The SMS failed — credits were refunded."),
    "owner_only": (403, "শুধু ব্যবসার মালিক Assisto SMS পাঠাতে পারেন (ক্রেডিট মালিকের)।",
                   "Only the business owner can send an Assisto SMS (the credits are theirs)."),
    "no_business": (409, "Assisto SMS পাঠাতে আগে ব্যবসা চালু করুন।",
                    "Set up your business first to send an Assisto SMS."),
    "not_your_customer": (403, "শুধু আপনার নিজের গ্রাহককে পাঠানো যায়।",
                          "You can only message your own customers."),
    "price_changed": (409, "খরচ বদলে গেছে — নতুন খরচ দেখে আবার চাপুন।",
                      "The cost changed — check the new cost and tap again."),
    "empty_text": (400, "মেসেজ লিখুন।", "Write a message."),
}


def _sms_err(request, reason, **extra):
    st, bn, en = _SMS_ERR.get(reason, (400, "SMS পাঠানো যায়নি।", "Couldn't send the SMS."))
    return _err(request, bn, en, status=st, code=reason, reason=reason, **extra)


def _text(request):
    return str(request.data.get("text") or "").strip()[:SP.MAX_TEXT]


def _lang(request):
    v = request.data.get("lang")
    return v if v in ("bn", "en") else req_lang(request)


class SendPreviewView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        p, bad = _person(request, scope, request.data)
        if bad is not None:
            return bad
        text = _text(request)
        out = {"name": p.name, "phone": p.phone, "known": _known(p),
               **SP.links(p, text)}
        if text:
            out["sms"] = SP.sms_offer(request, scope, p, text, _lang(request))
            if not _known(p):
                out["sms"].update(available=False, blocked="not_your_customer")
        return Response(out)


class SendLogView(CrmErrorMixin, APIView):
    """The seller opened WhatsApp / the phone's SMS app with this text. We
    record 'opened' — their own phone does the sending."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        p, bad = _person(request, scope, request.data)
        if bad is not None:
            return bad
        ch = request.data.get("channel")
        if ch not in ("whatsapp_link", "sms_app"):
            return _err(request, "পথ ঠিক নেই।", "Unknown channel.", status=400, code="bad_channel")
        row = SP.log(scope, p, ch, "opened", _text(request),
                     purpose=request.data.get("purpose") or "message",
                     lead_id=C._int(request.data.get("lead")) or None,
                     bulk_id=str(request.data.get("bulk_id") or ""))
        return Response({"ok": True, "id": row.id, "status": "opened"})


class SendSmsView(CrmErrorMixin, APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from core import sms_service
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        p, bad = _person(request, scope, request.data)
        if bad is not None:
            return bad
        text = _text(request)
        if not text:
            return _sms_err(request, "empty_text")
        if scope.business is None:
            return _sms_err(request, "no_business")
        if scope.role != "owner":
            return _sms_err(request, "owner_only")
        if not _known(p):
            return _sms_err(request, "not_your_customer")
        lang = _lang(request)
        final = SP.sms_text(scope, text, lang)
        q = SP.sms_quote(final)
        shown = request.data.get("credits")
        if shown is not None and C._int(shown, -1) != q["credits"]:
            return _sms_err(request, "price_changed", credits=q["credits"],
                            segments=q["segments"])
        r = sms_service.send_sms(p.key or p.phone, final, "crm", user=request.user,
                                 business=scope.business)
        status = "sent" if r["ok"] else ("failed" if r["reason"] == "send_failed" else "blocked")
        SP.log(scope, p, "assisto_sms", status, text, purpose=request.data.get("purpose")
               or "message", reason="" if r["ok"] else r["reason"], credits=r.get("credits", 0),
               lead_id=C._int(request.data.get("lead")) or None,
               bulk_id=str(request.data.get("bulk_id") or ""))
        request.user.refresh_from_db(fields=["ai_credits"])
        left = int(getattr(request.user, "ai_credits", 0) or 0)
        if r["ok"]:
            return Response({"ok": True, "status": "sent", "segments": r["segments"],
                             "credits": r["credits"], "balance": left})
        return _sms_err(request, r["reason"], segments=r.get("segments", 0), balance=left)


class SendBulkView(CrmErrorMixin, APIView):
    """One card per customer — each with its own name in the text and its
    own buttons. Nothing is sent here."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        scope, bad = _scope(request)
        if bad is not None:
            return bad
        targets = request.data.get("targets")
        if not isinstance(targets, list) or not targets:
            return _err(request, "অন্তত একজন গ্রাহক বেছে নিন।", "Pick at least one customer.",
                        status=400, code="no_targets")
        text = _text(request)
        if not text:
            return _sms_err(request, "empty_text")
        lang = _lang(request)
        bulk_id = SP.new_bulk_id()
        cards, skipped, seen = [], [], set()
        for t in targets[:SP.MAX_BULK]:
            if not isinstance(t, dict):
                continue
            p, _why = C.resolve(scope, t)
            if p is None:
                skipped.append({"target": t, "reason": "not_found"})
                continue
            dedupe = p.key or "p%s-l%s" % (p.party_ids, p.lead_ids)
            if dedupe in seen:
                skipped.append({"target": t, "reason": "duplicate"})
                continue
            seen.add(dedupe)
            body = SP.fill(text, p.name)
            card = {"name": p.name, "phone": p.phone, "target": t, "text": body,
                    **SP.links(p, body)}
            card["sms"] = SP.sms_offer(request, scope, p, body, lang)
            cards.append(card)
        return Response({"bulk_id": bulk_id, "cards": cards, "skipped": skipped,
                         "truncated": len(targets) > SP.MAX_BULK})
