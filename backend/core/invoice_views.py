"""invoices — business invoice API (owner PART 1 g).

  GET  business/invoice/settings          seller block + VAT setup (staff read)
  PUT|POST business/invoice/settings      owner only
  GET  business/sales/<id>/invoice        a POS sale as an invoice
  GET  business/invoices/sales            latest POS sales (to print again)
  GET  business/invoices                  manual (service) invoices, newest first
  POST business/invoices                  create a manual invoice (server math)
  GET  business/invoices/<id>             one manual invoice
  POST business/invoices/<id>/cancel      owner only; stays listed as CANCELLED
  POST business/sales/<id>/invoice/details  invdesign: the paper-only facts of
       a POS sale (template, table/token/..., per-line serial/IMEI + warranty)
       — never money; collection "biz_invoice_x"

Storage: PaCollectionItem rows of the business OWNER (collections
"biz_invoice_cfg" / "biz_invoices", NOT in GENERIC_COLLECTIONS so only these
views write them) — no migration. Money is integer poisha. The app draws the
paper (58 / 80 mm thermal or A4) from this dict; the server never renders.

A POS sale was already charged at checkout, so its invoice is always computed
VAT-INCLUSIVE from the charged total (the paper can never show a different
amount from what the customer paid). Manual invoices follow the VAT mode.
"""
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .business_views import _err, _require_business, is_owner
from .i18n import req_lang
from .logic import invoice_calc as IC

CFG = "biz_invoice_cfg"
MANUAL = "biz_invoices"
DETAILS = "biz_invoice_x"
LIST_MAX = 100


def _site():
    from .growth import site
    return site()


def _cfg_row(prof):
    from .models import PaCollectionItem
    for row in PaCollectionItem.objects.filter(user_id=prof.user_id, collection=CFG):
        if (row.data or {}).get("business_id") == prof.id:
            return row
    return None


def suggested_template(prof, settings=None):
    """invdesign: the template we suggest from the business's own facts — the
    business type it gave the marketing engine, whether it takes online
    orders, and whether it is VAT-ready. Best-effort: never fails a request."""
    btype, sells_delivery, has_orders = "", False, False
    try:
        from . import mktengine_service as MS
        ans = MS.get_answers(prof.user, prof)
        btype = str(ans.get("business_type") or "")
        sells_delivery = ans.get("delivery") in ("city", "nationwide")
    except Exception:
        pass
    try:
        from .models import Order
        has_orders = Order.objects.filter(business=prof).exists()
    except Exception:
        pass
    return IC.suggest_template(btype, has_orders,
                               bool(settings and _vat_ready(settings)), sells_delivery)


def load_settings(prof):
    row = _cfg_row(prof)
    base = IC.default_settings(prof.shop_name or "")
    if row is None:
        base["template"] = suggested_template(prof)
        return base, False
    s, _ = IC.normalize_settings({k: v for k, v in (row.data or {}).items()
                                  if k != "business_id"}, base)
    if not s.get("name"):
        s["name"] = prof.shop_name or ""
    return s, True


def _vat_ready(s):
    return s["vat_mode"] != "none" and bool("".join(c for c in s["bin"] if c.isdigit()))


def _seller(s):
    return {k: s.get(k, "") for k in ("name", "address", "phone", "bin", "signatory",
                                      "payment_link", "footer")}


def _local_iso(dt):
    return timezone.localtime(dt).isoformat()


class InvoiceSettingsView(APIView):
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        s, saved = load_settings(prof)
        return Response({"settings": s, "saved": saved, "can_edit": is_owner(role),
                         "suggested_template": suggested_template(prof, s),
                         "accents": list(IC.ACCENTS),
                         "templates": list(IC.TEMPLATES),
                         "template_fields": {k: list(v) for k, v in IC.TEMPLATE_FIELDS.items()},
                         "standard_vat_bp": IC.STANDARD_VAT_BP})

    def put(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        if not is_owner(role):
            return _err(lang, "শুধু মালিক ইনভয়েস সেটিংস বদলাতে পারেন।",
                        "Only the owner can change invoice settings.", status=403,
                        code="owner_only")
        cur, _ = load_settings(prof)
        s, errors = IC.normalize_settings(request.data, cur)
        if errors:
            return _err(lang, "কিছু ঘর ঠিক নেই।", "Some fields are not valid.",
                        status=400, code="invalid", fields=errors)
        from .models import PaCollectionItem
        row = _cfg_row(prof)
        data = dict(s, business_id=prof.id)
        if row is None:
            PaCollectionItem.objects.create(user_id=prof.user_id, collection=CFG, data=data)
        else:
            row.data = data
            row.save(update_fields=["data", "updated_at"])
        return Response({"settings": s, "saved": True, "can_edit": True})

    def post(self, request):   # the app's ApiClient has no PUT helper
        return self.put(request)


def _sale_for(prof, pk):
    from .models import Sale
    return (Sale.objects.filter(pk=pk)
            .filter(Q(business=prof) | Q(business__isnull=True, user_id=prof.user_id))
            .select_related("customer").first())


PAY_METHODS = ("cash", "bkash", "nagad", "bank")  # ledger2 money accounts


def _details_row(prof, sale_id):
    from .models import PaCollectionItem
    for row in PaCollectionItem.objects.filter(user_id=prof.user_id, collection=DETAILS):
        d = row.data or {}
        if d.get("business_id") == prof.id and d.get("sale_id") == sale_id:
            return row
    return None


def _order_facts(s):
    """The online order a delivered sale came from (bizagent record_sale):
    its courier facts and the delivery charge that is inside the sale total."""
    try:
        o = s.online_orders.order_by("id").first()
    except Exception:
        o = None
    if o is None:
        return {}, 0
    from .logic import business_selling as selling
    extras = {"order_ref": "#%d" % o.id, "delivery_address": o.address or "",
              "courier": o.courier or "",
              "tracking": o.consignment_id or o.tracking or ""}
    return ({k: IC._clip(v, IC.EXTRA_MAX) for k, v in extras.items() if v},
            selling.taka_to_poisha(o.delivery_charge or 0))


def sale_invoice(prof, s, settings):
    """A POS Sale → invoice dict (pure apart from the serial count)."""
    from .models import Sale
    serial = Sale.objects.filter(user_id=s.user_id, business_id=s.business_id,
                                 id__lte=s.id).count()
    det_row = _details_row(prof, s.id)
    det = (det_row.data or {}) if det_row else {}
    det_lines = det.get("lines") if isinstance(det.get("lines"), dict) else {}
    lines = []
    for i, l in enumerate(s.lines.all().order_by("id")):
        label = l.product_name
        tag = " / ".join(x for x in (l.size, l.colour) if x)
        if tag:
            label = "%s (%s)" % (label, tag)
        row = {"desc": label, "qty": l.qty, "unit": l.unit_price,
               "amount": l.qty * l.unit_price}
        row.update(IC.clean_line_detail(det_lines.get(str(i))))
        lines.append(row)
    order_extras, shipping = _order_facts(s)
    template = det.get("template") if det.get("template") in IC.TEMPLATES \
        else settings["template"]
    extras = dict(order_extras)
    extras.update(IC.clean_extras(template, det.get("extras")))
    mode = "inclusive" if _vat_ready(settings) else "none"
    calc = IC.compute([{"qty": l["qty"], "unit": l["unit"]} for l in lines],
                      vat_mode=mode, vat_bp=settings["vat_bp"], sd_bp=settings["sd_bp"],
                      discount=s.discount, shipping=shipping)
    # the paper must equal what was charged; a mismatch is a data bug — say so
    consistent = calc["total"] == s.total
    cust = s.customer
    return {
        "kind": "sale", "id": s.id, "number": IC.number("S", serial),
        "issued_at": _local_iso(s.created_at), "template": template,
        "seller": _seller(settings),
        "buyer": ({"name": cust.name, "phone": cust.phone, "address": cust.address,
                   "bin": ""} if cust else {}),
        "extras": extras, "lines": lines, "calc": calc,
        "details_saved": det_row is not None,
        "paid": s.paid, "change": s.change, "due": s.due,
        "payment_method": s.payment_method,
        "cancelled": s.voided_at is not None,
        "cancel_reason": s.void_reason if s.voided_at else "",
        "consistent": consistent,
        "verify_url": (_site() + IC.verify_path("s", s.id)) if settings["verify_qr"] else "",
        "payment_link": settings["payment_link"],
    }


class SaleInvoiceView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        s = _sale_for(prof, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        settings, _ = load_settings(prof)
        return Response(sale_invoice(prof, s, settings))


class SaleInvoiceDetailsView(APIView):
    """POST business/sales/<id>/invoice/details — paper-only facts of a POS
    sale: {template?, extras{}, lines{"<index>": {serial, warranty_m}}}.
    Money, VAT and the verify page never change. Any member who can see the
    sale (owner or staff who sold it) may fill them."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        s = _sale_for(prof, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data if isinstance(request.data, dict) else {}
        settings, _ = load_settings(prof)
        template = d.get("template") if d.get("template") in IC.TEMPLATES else ""
        if d.get("template") and not template:
            return _err(lang, "টেমপ্লেট ঠিক নেই।", "Unknown template.", status=400,
                        code="template")
        n_lines = s.lines.count()
        raw_lines = d.get("lines") if isinstance(d.get("lines"), dict) else {}
        lines = {}
        for k, v in raw_lines.items():
            if str(k).isdigit() and int(k) < n_lines:
                det = IC.clean_line_detail(v)
                if det:
                    lines[str(int(k))] = det
        data = {"business_id": prof.id, "sale_id": s.id, "template": template,
                "extras": IC.clean_extras(template or settings["template"], d.get("extras")),
                "lines": lines, "by": request.user.id}
        from .models import PaCollectionItem
        row = _details_row(prof, s.id)
        if row is None:
            PaCollectionItem.objects.create(user_id=prof.user_id, collection=DETAILS,
                                            data=data)
        else:
            row.data = data
            row.save(update_fields=["data", "updated_at"])
        return Response(sale_invoice(prof, s, settings))


class InvoiceSalesView(APIView):
    """GET business/invoices/sales — the latest POS sales to print again."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        from .models import Sale
        qs = (Sale.objects.filter(Q(business=prof) | Q(business__isnull=True,
                                                         user_id=prof.user_id))
              .select_related("customer").order_by("-created_at")[:50])
        return Response({"items": [
            {"id": s.id, "total": s.total, "issued_at": _local_iso(s.created_at),
             "buyer": s.customer.name if s.customer_id else "",
             "payment_method": s.payment_method,
             "cancelled": s.voided_at is not None} for s in qs]})


def _manual_rows(prof):
    from .models import PaCollectionItem
    return [r for r in PaCollectionItem.objects.filter(user_id=prof.user_id,
                                                        collection=MANUAL)
            if (r.data or {}).get("business_id") == prof.id]


def manual_out(row):
    d = dict(row.data or {})
    d.pop("business_id", None)
    d["id"] = row.id
    d["kind"] = "manual"
    return d


class ManualInvoicesView(APIView):
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        rows = _manual_rows(prof)[:LIST_MAX]
        items = [{"id": r.id, "number": r.data.get("number"),
                  "issued_at": r.data.get("issued_at"),
                  "buyer": (r.data.get("buyer") or {}).get("name", ""),
                  "total": (r.data.get("calc") or {}).get("total", 0),
                  "template": r.data.get("template"),
                  "cancelled": bool(r.data.get("cancelled"))} for r in rows]
        return Response({"items": items})

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        settings, _ = load_settings(prof)
        d = request.data if isinstance(request.data, dict) else {}
        lines = IC.clean_lines(d.get("lines"))
        if lines is None:
            return _err(lang, "অন্তত একটি সেবা/পণ্যের লাইন দিন (বিবরণ, পরিমাণ, দাম)।",
                        "Add at least one line (description, quantity, price).",
                        status=400, code="lines")
        template = d.get("template") if d.get("template") in IC.TEMPLATES \
            else settings["template"]
        buyer_raw = d.get("buyer") if isinstance(d.get("buyer"), dict) else {}
        buyer = {"name": IC._clip(buyer_raw.get("name"), 120),
                 "phone": IC._clip(buyer_raw.get("phone"), 40),
                 "address": IC._clip(buyer_raw.get("address"), 300),
                 "bin": IC._clip(buyer_raw.get("bin"), 20)}
        if not buyer["name"]:
            return _err(lang, "ক্লায়েন্টের নাম দিন।", "Add the client's name.",
                        status=400, code="buyer")
        if not IC.bin_ok(buyer["bin"]):
            return _err(lang, "ক্রেতার BIN ঠিক নেই (৯ বা ১৩ অঙ্ক)।",
                        "Buyer BIN is not valid (9 or 13 digits).", status=400,
                        code="buyer_bin")
        no_vat = bool(d.get("no_vat"))
        mode = "none" if (no_vat or not _vat_ready(settings)) else settings["vat_mode"]
        service_bp = settings["service_bp"] if template in IC.FOOD_TEMPLATES else 0
        sub = sum(IC.line_amount(l) for l in lines)
        try:
            discount = max(0, min(int(d.get("discount") or 0), sub))
        except (TypeError, ValueError):
            discount = 0
        calc = IC.compute(lines, vat_mode=mode, vat_bp=settings["vat_bp"],
                          sd_bp=settings["sd_bp"], discount=discount,
                          service_bp=service_bp)
        try:
            paid = max(0, min(int(d.get("paid") or 0), calc["total"]))
        except (TypeError, ValueError):
            paid = 0
        from .models import PaCollectionItem
        with transaction.atomic():
            serial = len(_manual_rows(prof)) + 1
            data = {
                "business_id": prof.id, "number": IC.number("SV", serial),
                "issued_at": _local_iso(timezone.now()), "template": template,
                "seller": _seller(settings), "buyer": buyer,
                "extras": IC.clean_extras(template, d.get("extras")),
                "lines": [dict(l, amount=IC.line_amount(l)) for l in lines],
                "by_hours": bool(d.get("by_hours")),
                "calc": calc, "paid": paid, "change": 0,
                "due": calc["total"] - paid,
                "payment_method": (d.get("payment_method")
                                   if d.get("payment_method") in PAY_METHODS else "cash")
                if paid else "",
                "note": IC._clip(d.get("note"), 300),
                "cancelled": False, "cancel_reason": "", "consistent": True,
                "payment_link": settings["payment_link"],
                "verify_qr": settings["verify_qr"],
                "made_by": request.user.id,
            }
            row = PaCollectionItem.objects.create(user_id=prof.user_id,
                                                  collection=MANUAL, data=data)
        out = manual_out(row)
        out["verify_url"] = (_site() + IC.verify_path("m", row.id)) if data["verify_qr"] else ""
        return Response(out, status=201)


def _manual_row(prof, pk):
    from .models import PaCollectionItem
    r = PaCollectionItem.objects.filter(pk=pk, user_id=prof.user_id,
                                        collection=MANUAL).first()
    if r is None or (r.data or {}).get("business_id") != prof.id:
        return None
    return r


class ManualInvoiceDetailView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        r = _manual_row(prof, pk)
        if r is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        out = manual_out(r)
        out["verify_url"] = (_site() + IC.verify_path("m", r.id)) \
            if r.data.get("verify_qr", True) else ""
        return Response(out)


class ManualInvoiceCancelView(APIView):
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        if not is_owner(role):
            return _err(lang, "শুধু মালিক ইনভয়েস বাতিল করতে পারেন।",
                        "Only the owner can cancel an invoice.", status=403,
                        code="owner_only")
        r = _manual_row(prof, pk)
        if r is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        reason = IC._clip(request.data.get("reason"), 200)
        if not reason:
            return _err(lang, "বাতিলের কারণ লিখুন।", "Write the reason.",
                        status=400, code="reason")
        r.data = dict(r.data, cancelled=True, cancel_reason=reason,
                      cancelled_at=_local_iso(timezone.now()))
        r.save(update_fields=["data", "updated_at"])
        return Response(manual_out(r))


def public_status(kind, pk):
    """What the public QR page may show — never the buyer, never cost/profit.
    None when the record does not exist."""
    from .models import BusinessProfile, PaCollectionItem, Sale
    if kind == "s":
        s = Sale.objects.filter(pk=pk).select_related("business").first()
        if s is None:
            return None
        prof = s.business or BusinessProfile.objects.filter(user_id=s.user_id).first()
        settings = load_settings(prof)[0] if prof else IC.default_settings()
        serial = Sale.objects.filter(user_id=s.user_id, business_id=s.business_id,
                                     id__lte=s.id).count()
        return {"shop": settings["name"] or (prof.shop_name if prof else ""),
                "bin": settings["bin"], "number": IC.number("S", serial),
                "issued_at": timezone.localtime(s.created_at), "total": s.total,
                "cancelled": s.voided_at is not None}
    r = PaCollectionItem.objects.filter(pk=pk, collection=MANUAL).first()
    if r is None:
        return None
    d = r.data or {}
    from datetime import datetime
    try:
        at = datetime.fromisoformat(d.get("issued_at"))
    except (TypeError, ValueError):
        at = r.created_at
    return {"shop": (d.get("seller") or {}).get("name", ""),
            "bin": (d.get("seller") or {}).get("bin", ""),
            "number": d.get("number", ""), "issued_at": at,
            "total": (d.get("calc") or {}).get("total", 0),
            "cancelled": bool(d.get("cancelled"))}
