"""
Business v2 — DRF wiring for the three pure-logic modules:

    core/logic/business_khata.py    (Digital Khata + Cashbox)
    core/logic/business_selling.py  (Catalog + quick-sell + reports)
    core/logic/business_ai.py       (AI sales assistant, courier, payments)

ALL business logic + enforcement lives in the pure layer. These views ONLY:
  * resolve + scope the business the requester owns / is staff of,
  * feed ORM rows in as plain dicts,
  * persist what the pure fn returns,
  * enforce the hard gates by SURFACING the pure fn's reason codes / exceptions.

HARD GATES (each enforced in code, never optional):
  - MINIMUM PRICE  — cart/checkout/negotiate below min → 422 below_min / defer.
  - STAFF ROLE     — redact cost/profit/min + block supplier book for staff.
  - NEVER HOLD MONEY — payment views return descriptors/links only, no balance.
  - CHANNEL GUARD  — guard_channel / assemble_webhook_send; personal WA → 400.
  - PLAN GATE      — AI endpoints require a PAID Business plan; khata/selling free.
  - LIVE KEYS      — AI/courier/payment/LLM/OCR/transcription mocked + key-gated.
  - MULTI-BUSINESS — every endpoint scoped to a business the requester may touch.
All user strings bilingual via i18n.req_lang / pick and the pure layer's pairs.

MONEY CONVENTIONS (two modules, two contracts — never mix them):
  * business_selling  — taka_to_poisha(int) treats an int as TAKA (× 100);
    poisha_to_taka(poisha) returns a TAKA string. Its catalog/report inputs are
    TAKA (Product/ProductVariant/Order Decimal fields), its outputs are POISHA
    (checkout result: subtotal/total/paid/due/profit, SaleLine prices).
  * business_khata    — to_poisha(int) treats an int as ALREADY POISHA
    (pass-through). Every khata amount (KhataEntry.amount_poisha, CashboxDay
    opening, CashEntry) is POISHA end-to-end; khata endpoints accept POISHA.

  BOUNDARY RULE (the single place the two conventions meet): the due-sale →
  khata bridge in CheckoutView. `res["due"]` is already selling-side POISHA and
  khata.new_entry stores POISHA, so the due crosses with NO ×100 conversion —
  pass the poisha int straight through. Never route a selling poisha value via
  taka_to_poisha, and never route a khata poisha value via poisha_to_taka unless
  a pure fn re-coerces it with taka_to_poisha (the Expense/AI display round-trip
  below does exactly that, so it is intentionally value-preserving).
"""
from datetime import datetime, timedelta

from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import business_khata as khata
from .logic import business_selling as selling
from .logic import business_ai as bai


# ---------------------------------------------------------------------------
# shared helpers: business scoping + role + plan + key gates
# ---------------------------------------------------------------------------

def _err(lang, bn, en, status=400, **extra):
    d = {"error": extra.pop("code", "error"), "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


def resolve_business(request):
    """Return (business, role) for the requester, or (None, None).

    role is 'owner' if the requester owns the BusinessProfile, 'staff' if an
    active BusinessStaff membership exists. Multi-business: the business id may
    be given via ?business=<id> / body `business`; otherwise the requester's own
    profile (owner) is used. Rejects businesses the requester may not touch.
    """
    from .models import BusinessProfile, BusinessStaff
    # bizbar: several app calls (cashbox, net position, schedules) send
    # `business_id`; it was ignored, so a STAFF member's cashbox silently
    # landed in an empty shop auto-created for them.
    bid = (request.query_params.get("business")
           or request.query_params.get("business_id"))
    if not bid and request.method in ("POST", "PUT", "PATCH", "DELETE"):
        try:
            bid = request.data.get("business") or request.data.get("business_id")
        except Exception:
            bid = None
    if bid:
        prof = BusinessProfile.objects.filter(pk=bid).first()
        if prof is None:
            return (None, None)
        if prof.user_id == request.user.id:
            return (prof, selling.ROLE_OWNER)
        mem = BusinessStaff.objects.filter(business=prof, member=request.user,
                                           active=True).first()
        if mem:
            return (prof, mem.role)
        return (None, None)   # not owner, not staff → reject
    # default: the requester's own shop (owner)
    prof = getattr(request.user, "business", None)
    if prof is None:
        prof = BusinessProfile.objects.create(user=request.user)
    return (prof, selling.ROLE_OWNER)


def _require_business(request):
    prof, role = resolve_business(request)
    if prof is None:
        lang = req_lang(request)
        return (None, None, _err(lang, "এই ব্যবসায় আপনার অ্যাক্সেস নেই।",
                                 "You don't have access to this business.",
                                 status=403, code="forbidden_business"))
    return (prof, role, None)


def is_owner(role):
    return role == selling.ROLE_OWNER


def _owner_only(request, role):
    """Return an owner-only 403 Response, or None if the requester is owner."""
    if is_owner(role):
        return None
    lang = req_lang(request)
    return Response({"error": "staff_restricted",
                     "detail": pick(lang, *_notice_pair())},
                    status=403)


def _notice_pair():
    return ("শুধু মালিক এটি দেখতে পারেন।", "Only the owner can see this.")


# ---- plan gate: AI endpoints need a PAID Business-tier plan ---------------
# khata + selling + tagada + reports + QR are FREE; only AI features are paid.
_PAID_PLANS = {"business", "premium", "family", "probashi", "annual", "founder",
               "plus", "premium_pro"}


def paid_plan_ok(user):
    """True if the user's effective plan unlocks AI business features."""
    from . import plans
    return plans.effective_plan(user) in _PAID_PLANS


def _plan_gate(request, prof=None, cap="ledger_ai_addons", read_ok=False):
    """Return an upgrade Response if the plan lacks this feature, else None.

    plans-v2 ON (for the shop OWNER): the owner's tier decides through the
    central entitlement module (core.entitlements_service) — a staff
    member's own plan never matters, founder counts as Business, a running
    trial as the trial plan. `read_ok` endpoints (GET of existing threads /
    rules) always answer so nobody loses their data.
    plans-v2 OFF: exactly the old rule (the requester's paid plan)."""
    owner = getattr(prof, "user", None) if prof is not None else None
    if owner is not None:
        from . import entitlements_service as ES
        if ES.on(owner):
            if read_ok and request.method == "GET":
                return None
            if ES.allows(owner, cap):
                return None
            return ES.response(cap, owner, req_lang(request))
    if paid_plan_ok(request.user):
        return None
    lang = req_lang(request)
    from . import plans
    return Response({
        "error": "upgrade_required",
        "plan_required": "business",
        "current_plan": plans.effective_plan(request.user),
        "detail": pick(lang,
                       "এই এআই ফিচারটি ব্যবহার করতে বিজনেস প্ল্যান দরকার।",
                       "This AI feature needs the Business plan."),
        "upgrade": True,
    }, status=402)


def _v2_owner(prof):
    from . import entitlements_service as ES
    return ES.on(getattr(prof, "user", None))


# ---- live-key gates (all AI/courier/payment paths mocked until a key) -----

def _ai_key():
    """The owner's LLM key (via core.ai), or '' when absent → deterministic mock."""
    from . import ai
    try:
        return ai.active_api_key()
    except Exception:
        return ""


def _courier_keys():
    """{provider: key} from the owner's configured courier integration, else {}."""
    from . import integrations
    cfg = integrations.get("courier")
    prov = (cfg.get("provider") or "").lower()
    key = cfg.get("api_key") or ""
    return {prov: key} if prov and key else {}


def _meta_token():
    from . import integrations
    return integrations.get("whatsapp").get("access_token") or ""


def _payment_partner_key():
    from . import integrations
    # licensed partner: reuse sslcommerz creds as the partner key presence signal
    cfg = integrations.get("sslcommerz")
    return cfg.get("store_id") or ""


def _sms_enabled():
    """smsotp: a CONNECTED SMS gateway (any entry whose Test passed)."""
    from . import sms_service
    return sms_service.ready()


def _now_iso():
    return timezone.now().isoformat()


def _epoch(dt):
    return dt.timestamp() if dt else None


# ---------------------------------------------------------------------------
# helpers to turn ORM rows into the plain dicts the pure layer expects
# ---------------------------------------------------------------------------

def _tk(v):   # taka Decimal → poisha int
    return selling.taka_to_poisha(v)


def _variant_dict(v):
    return {"key": v.vkey, "size": v.size, "colour": v.colour,
            "sell_price": _tk(v.sell_price), "cost_price": _tk(v.cost_price),
            "min_price": _tk(v.min_price), "stock": v.stock,
            "barcode": v.barcode, "low_stock_at": v.low_stock_at}


def _product_dict(p):
    """ORM Product → the pure make_product-shaped dict (poisha variants)."""
    variants = list(p.variants.all())
    if variants:
        vs = [_variant_dict(v) for v in variants]
    else:
        # single base variant synthesised from the Product's own fields
        vs = [selling.make_variant(sell=p.price, cost=p.cost_price,
                                   minimum=p.min_price, stock=p.stock,
                                   barcode=p.barcode, low_stock_at=p.low_stock_at)]
    return {"id": p.id, "name": p.name, "category": p.category, "sku": p.sku,
            "barcode": p.barcode, "description": p.description, "variants": vs}


def _shop_products(prof):
    """bizbar: the SHOP's catalog (owner's rows). Views used
    request.user.products, so a staff member saw an empty catalog and every
    staff cart add was a 404."""
    from .models import Product
    return Product.objects.filter(user_id=prof.user_id)


def _product_out(p, role):
    """_product_dict + the flat fields the app list reads (price/stock/
    cost/min in POISHA from the base variant; stock summed), redacted."""
    d = _product_dict(p)
    vs = d["variants"] or [{}]
    base = next((v for v in vs if v.get("key") == "__base__"), vs[0])
    d.update({"price": int(base.get("sell_price") or 0),
              "cost_price": int(base.get("cost_price") or 0),
              "min_price": int(base.get("min_price") or 0),
              "stock": sum(int(v.get("stock") or 0) for v in d["variants"]),
              "low_stock_at": int(base.get("low_stock_at") or 3)})
    d["low_stock"] = 0 < d["stock"] <= d["low_stock_at"]
    d["out_of_stock"] = d["stock"] <= 0
    # aileft: the catalog photo (Photo Studio "Add to catalog"), signed URL
    try:
        d["photo"] = p.photo.url if p.photo else ""
    except Exception:  # noqa: BLE001
        d["photo"] = ""
    return selling.redact_product(d, role)


def _sale_record(s):
    """ORM Sale → the plain dict the reports/history pure fns consume."""
    return {
        "id": s.id, "total": s.total, "paid": s.paid, "due": s.due,
        "profit": s.profit, "discount": s.discount, "subtotal": s.subtotal,
        "payment_method": s.payment_method, "created_at": s.created_at.isoformat(),
        "voided": s.voided_at is not None,
        "customer": ({"name": s.customer.name, "phone": s.customer.phone}
                     if s.customer_id else {}),
        "lines": [{"product_name": l.product_name, "qty": l.qty,
                   "unit_price": l.unit_price, "cost_price": l.cost_price}
                  for l in s.lines.all()],
    }


def _void_fields(s, lang):
    """VOID marker for receipts/history (a2-cctv)."""
    if s.voided_at is None:
        return {"voided": False}
    return {"voided": True, "voided_at": s.voided_at.isoformat(),
            "void_reason": s.void_reason,
            "status_text": pick(lang, "বাতিল (VOID)", "VOID")}


def _order_dict(o):
    return {"id": o.id, "status": o.status, "payment": o.payment,
            "total": str(o.total), "courier": o.courier, "tracking": o.tracking,
            "courier_live": o.courier_live}


# ===========================================================================
# BUSINESS PROFILES (plan §1) — list / create / select
# ===========================================================================

_BIZ_TYPES = {"online_seller", "small_shop", "service", "food", "wholesaler", "b2b"}


def _profile_row(prof, role, selected_id):
    """Shape one BusinessProfile for the profiles list. `type`/`config` have no
    model field (never add one) so they ride inside style_sample's handoff slot
    only via shop_name; here we surface the stable facts the client needs."""
    return {
        "id": prof.id,
        "name": prof.shop_name or "",
        "type": "small_shop",            # no model field; stable default
        "role": role,
        "is_premium": bool(paid_plan_ok(prof.user)),
        "currency": "BDT",
        "selected": (selected_id is not None and prof.id == selected_id),
    }


class ProfilesView(APIView):
    """GET — every business the requester owns OR staffs. POST — create/rename
    the requester's own shop (BusinessProfile is OneToOne with the user, so a
    create updates the single owned profile's name; type/config are echoed, not
    persisted, because adding a model field is out of scope)."""
    def get(self, request):
        from .models import BusinessProfile, BusinessStaff
        selected = self._selected_id(request)
        rows = []
        own = getattr(request.user, "business", None)
        if own is None:
            own = BusinessProfile.objects.create(user=request.user)
        if selected is None:
            selected = own.id
        rows.append(_profile_row(own, selling.ROLE_OWNER, selected))
        for mem in BusinessStaff.objects.filter(member=request.user, active=True):
            rows.append(_profile_row(mem.business, mem.role, selected))
        return Response({"businesses": rows, "selected_id": selected})

    def post(self, request):
        from .models import BusinessProfile
        lang = req_lang(request)
        d = request.data
        btype = (d.get("type") or "small_shop")
        if btype not in _BIZ_TYPES:
            return _err(lang, "ব্যবসার ধরন ভুল।", "Invalid business type.",
                        status=422, code="bad_type")
        prof = getattr(request.user, "business", None)
        if prof is None:
            prof = BusinessProfile.objects.create(user=request.user)
        name = (d.get("name") or "").strip()
        if name:
            prof.shop_name = name
            prof.save(update_fields=["shop_name"])
        row = _profile_row(prof, selling.ROLE_OWNER, prof.id)
        row["type"] = btype            # echo requested type (not persisted)
        if d.get("config") is not None:
            row["config"] = d.get("config")
        return Response(row, status=201)

    @staticmethod
    def _selected_id(request):
        v = request.query_params.get("selected") or request.query_params.get("business")
        try:
            return int(v) if v else None
        except (TypeError, ValueError):
            return None


class ProfileSelectView(APIView):
    """POST profiles/select {business_id} — validate the requester may touch it
    and echo it back for the client to persist. No model field is written (the
    chosen id is a per-client preference; every subsequent call re-scopes via
    resolve_business's ?business= guard)."""
    def post(self, request):
        from .models import BusinessProfile, BusinessStaff
        lang = req_lang(request)
        bid = request.data.get("business_id") or request.data.get("business")
        try:
            bid = int(bid)
        except (TypeError, ValueError):
            return _err(lang, "ব্যবসা নির্দিষ্ট করুন।", "Business id required.",
                        status=422, code="bad_business")
        prof = BusinessProfile.objects.filter(pk=bid).first()
        role = None
        if prof is not None:
            if prof.user_id == request.user.id:
                role = selling.ROLE_OWNER
            else:
                mem = BusinessStaff.objects.filter(business=prof, member=request.user,
                                                   active=True).first()
                role = mem.role if mem else None
        if prof is None or role is None:
            return _err(lang, "এই ব্যবসায় আপনার অ্যাক্সেস নেই।",
                        "You don't have access to this business.",
                        status=403, code="forbidden_business")
        return Response({"selected_id": prof.id,
                         "business": _profile_row(prof, role, prof.id)})


# ===========================================================================
# SELLING (§3)
# ===========================================================================

class ProductsView(APIView):
    """GET list (staff-redacted) / POST create (owner only)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        qs = _shop_products(prof).prefetch_related("variants")
        q = (request.query_params.get("q") or "").strip()
        if q:
            from django.db.models import Q
            qs = qs.filter(Q(name__icontains=q) | Q(sku__iexact=q)
                           | Q(barcode=q) | Q(category__icontains=q))
        cat = (request.query_params.get("category") or "").strip()
        if cat:
            qs = qs.filter(category=cat)
        out = [_product_out(p, role) for p in qs]       # STAFF ROLE gate
        if request.query_params.get("low") in ("1", "true"):
            out = [d for d in out if d["stock"] <= d["low_stock_at"]]
        return Response({"products": out, "role": role,
                         "low_stock_count": sum(1 for d in out
                                                if d["stock"] <= d["low_stock_at"])})

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)       # owner writes cost/min
        if guard:
            return guard
        lang = req_lang(request)
        d = request.data
        prod = selling.make_product(
            name=d.get("name", ""), category=d.get("category", ""),
            sku=d.get("sku", ""), barcode=d.get("barcode", ""),
            description=d.get("description", ""),
            sell=d.get("sell") or d.get("price") or 0,
            # the app sends cost_price (m2-reality: was silently dropped -> 0)
            cost=d.get("cost") or d.get("cost_price") or 0,
            minimum=d.get("minimum") or d.get("min_price") or 0,
            stock=d.get("stock") or 0, low_stock_at=d.get("low_stock_at", 3))
        ok, errs = selling.validate_product(prod)
        if not ok:
            return _err(lang, "পণ্যের তথ্য ভুল।", "Invalid product.", status=422,
                        code="invalid_product", errors=errs)
        base = prod["variants"][0]
        from .models import Product, ProductVariant
        obj = Product.objects.create(
            user=request.user, business=prof, name=prod["name"],
            category=prod["category"], sku=prod["sku"], barcode=prod["barcode"],
            description=prod["description"],
            price=selling.poisha_to_taka(base["sell_price"]),
            cost_price=selling.poisha_to_taka(base["cost_price"]),
            min_price=selling.poisha_to_taka(base["min_price"]),
            stock=base["stock"], low_stock_at=base["low_stock_at"])
        for v in prod["variants"]:
            ProductVariant.objects.create(
                product=obj, vkey=v["key"], size=v["size"], colour=v["colour"],
                sell_price=selling.poisha_to_taka(v["sell_price"]),
                cost_price=selling.poisha_to_taka(v["cost_price"]),
                min_price=selling.poisha_to_taka(v["min_price"]),
                stock=v["stock"], barcode=v["barcode"],
                low_stock_at=v["low_stock_at"])
        return Response(_product_out(obj, role), status=201)


class ProductDetailView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p = _shop_products(prof).filter(pk=pk).first()
        if not p:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(_product_out(p, role))

    # m2-reality: the app's product EDIT posts here (was 405 -> edit never saved)
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        p = request.user.products.filter(pk=pk).first()
        if not p:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data
        prod = selling.make_product(
            name=d.get("name", p.name), category=d.get("category", p.category),
            sku=d.get("sku", p.sku), barcode=d.get("barcode", p.barcode),
            description=d.get("description", p.description),
            sell=d.get("sell") or d.get("price") or p.price,
            cost=d.get("cost") or d.get("cost_price") or p.cost_price,
            minimum=d.get("minimum") or d.get("min_price") or p.min_price,
            stock=d.get("stock", p.stock),
            low_stock_at=d.get("low_stock_at", p.low_stock_at))
        ok, errs = selling.validate_product(prod)
        if not ok:
            return _err(lang, "পণ্যের তথ্য ভুল।", "Invalid product.", status=422,
                        code="invalid_product", errors=errs)
        base = prod["variants"][0]
        p.name, p.category, p.sku = prod["name"], prod["category"], prod["sku"]
        p.barcode, p.description = prod["barcode"], prod["description"]
        p.price = selling.poisha_to_taka(base["sell_price"])
        p.cost_price = selling.poisha_to_taka(base["cost_price"])
        p.min_price = selling.poisha_to_taka(base["min_price"])
        p.stock, p.low_stock_at = base["stock"], base["low_stock_at"]
        p.save()
        # bizbar: the list/till read the VARIANT rows (created with the
        # product), so an edit of price/stock/cost/min never showed and the
        # till kept selling at the old price. Keep the base row in step.
        vrows = list(p.variants.all())
        bv = next((v for v in vrows if v.vkey == "__base__"), None)
        if bv is None and len(vrows) == 1:
            bv = vrows[0]
        if bv is not None:
            bv.sell_price, bv.cost_price, bv.min_price = p.price, p.cost_price, p.min_price
            bv.stock, bv.low_stock_at = p.stock, p.low_stock_at
            bv.barcode = p.barcode
            bv.save(update_fields=["sell_price", "cost_price", "min_price",
                                   "stock", "low_stock_at", "barcode"])
        return Response(_product_out(p, role))

    def delete(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        request.user.products.filter(pk=pk).delete()
        return Response(status=204)


class ProductImportView(APIView):
    """Owner-only Excel/CSV import → parse + uniqueness report (no auto-write)."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        rows = request.data.get("rows") or []
        parsed = selling.parse_import_rows(rows)
        existing_bc = list(request.user.products.exclude(barcode="")
                           .values_list("barcode", flat=True))
        existing_sku = list(request.user.products.exclude(sku="")
                            .values_list("sku", flat=True))
        conflicts = selling.check_import_uniqueness(
            parsed["products"], existing_bc, existing_sku)
        return Response({"products": parsed["products"],
                         "bad_rows": parsed["bad_rows"], "conflicts": conflicts})


class ProductVariantView(APIView):
    """Owner-only: add a variant to a product."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        p = request.user.products.filter(pk=pk).first()
        if not p:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data
        v = selling.make_variant(size=d.get("size"), colour=d.get("colour"),
                                 sell=d.get("sell") or 0, cost=d.get("cost") or 0,
                                 minimum=d.get("minimum") or 0,
                                 stock=d.get("stock") or 0,
                                 barcode=d.get("barcode", ""),
                                 low_stock_at=d.get("low_stock_at", 3))
        ok, code = selling.validate_variant(v)
        if not ok:
            return _err(lang, "ভ্যারিয়েন্ট ভুল।", "Invalid variant.", status=422,
                        code="invalid_variant", reason=code)
        from .models import ProductVariant
        obj = ProductVariant.objects.create(
            product=p, vkey=v["key"], size=v["size"], colour=v["colour"],
            sell_price=selling.poisha_to_taka(v["sell_price"]),
            cost_price=selling.poisha_to_taka(v["cost_price"]),
            min_price=selling.poisha_to_taka(v["min_price"]),
            stock=v["stock"], barcode=v["barcode"], low_stock_at=v["low_stock_at"])
        return Response(selling.redact_for_role(_variant_dict(obj), role), status=201)


# ---- cart: stateless; the client holds the cart dict, server validates ----

def _below_min(lang):
    return Response({"error": "below_min",
                     "detail": pick(lang, "ন্যূনতম দামের নিচে বিক্রি করা যাবে না।",
                                    "Cannot sell below the minimum price.")},
                    status=422)


def _stale_cart(lang):
    return _err(lang, "কার্টের একটা পণ্য বদলে গেছে বা মুছে গেছে — কার্ট খালি করে আবার যোগ করুন।",
                "An item in the cart changed or was removed — clear the cart and add it again.",
                status=409, code="cart_stale")


def _rehydrate_cart(prof, raw):
    """bizbar: the cart is held by the phone, so NEVER trust its money
    fields. Every line's name/sell/min/cost/stock is re-read from the shop's
    catalog (by product id + variant key); only qty and the chosen unit price
    come from the phone (a unit price under the DB minimum is refused by
    checkout / cart_set_price). Lines whose product is gone (or an old cart
    without product ids) make the cart stale. Returns (cart, stale)."""
    cart = selling.normalize_cart(raw if isinstance(raw, dict) else None)
    lines = [l for l in cart["lines"] if isinstance(l, dict)]
    pids = {l.get("product_id") for l in lines}
    if None in pids or "" in pids:
        return cart, bool(lines)
    prods = {p.id: _product_dict(p) for p in
             _shop_products(prof).filter(pk__in=pids).prefetch_related("variants")}
    for l in lines:
        pd = prods.get(l.get("product_id"))
        v = selling.get_variant(pd, key=l.get("variant_key")) if pd else None
        if v is None:
            return cart, True
        try:
            l["qty"] = max(1, int(l.get("qty") or 1))
            l["unit_price"] = int(l.get("unit_price") or v["sell_price"])
        except (TypeError, ValueError):
            return cart, True
        l["product_name"] = pd["name"]
        l["variant_key"] = v["key"]
        l["min_price"] = int(v["min_price"])
        l["cost_price"] = int(v["cost_price"])
        l["sell_price"] = int(v["sell_price"])
        l["_stock"] = int(v["stock"])
    cart["lines"] = lines
    return cart, False


def _cart_out(cart, role, discount=0):
    """The cart the phone keeps: totals the app shows (it read `total` and
    always got ৳0) + staff never sees cost/min on a line."""
    out = dict(cart)
    out["lines"] = [{k: v for k, v in l.items() if k != "_stock"}
                    for l in cart["lines"]]
    sub = selling.cart_subtotal(cart)
    out["subtotal"] = sub
    out["discount"] = int(discount or 0)
    out["total"] = max(0, sub - int(discount or 0))
    out["item_count"] = sum(int(l.get("qty") or 0) for l in cart["lines"])
    return selling.redact_for_role(out, role)


class CartAddView(APIView):
    """POST cart/add — MINIMUM PRICE gate: below-min → 422 below_min."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        cart, stale = _rehydrate_cart(prof, request.data.get("cart"))
        if stale:
            return _stale_cart(lang)
        p = _shop_products(prof).filter(pk=request.data.get("product")).first()
        if not p:
            return _err(lang, "পণ্য পাওয়া যায়নি।", "Product not found.", status=404)
        d = request.data
        cart, line, reason = selling.cart_add_line(
            cart, _product_dict(p), variant_key=d.get("variant_key"),
            qty=d.get("qty", 1),
            # the app sends unit_price (was ignored)
            price_override=d.get("price_override") or d.get("unit_price"),
            size=request.data.get("size"), colour=request.data.get("colour"))
        if reason == selling.R_BELOW_MIN:
            return _below_min(lang)       # HARD GATE
        if line is None:
            if reason in (selling.R_NO_STOCK, selling.R_LOW_STOCK):
                return _err(lang, "স্টকে এতগুলো নেই।", "Not enough in stock.",
                            status=422, code=reason)
            return _err(lang, "যোগ করা যায়নি।", "Could not add.", status=422,
                        code=reason)
        return Response({"cart": _cart_out(cart, role),
                         "line": selling.redact_for_role(line, role)})


class CartSetPriceView(APIView):
    """POST cart/line/<id>/price — below-min → 422, price UNCHANGED."""
    def post(self, request, line_id):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        cart, stale = _rehydrate_cart(prof, request.data.get("cart"))
        if stale:
            return _stale_cart(lang)
        d = request.data
        price = d.get("unit_price") if d.get("unit_price") not in (None, "") else d.get("price")
        if price in (None, ""):
            return _err(lang, "দাম লিখুন।", "Enter a price.", status=422,
                        code="no_price")
        cart, reason = selling.cart_set_price(cart, int(line_id), price)
        if reason == selling.R_BELOW_MIN:
            return _below_min(lang)       # HARD GATE (line unchanged by pure fn)
        if reason != selling.R_OK:
            return _err(lang, "লাইন পাওয়া যায়নি।", "Line not found.", status=404)
        return Response({"cart": _cart_out(cart, role)})


class CartSetQtyView(APIView):
    def post(self, request, line_id):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        cart, stale = _rehydrate_cart(prof, request.data.get("cart"))
        if stale:
            return _stale_cart(lang)
        line = next((l for l in cart["lines"] if l["id"] == int(line_id)), None)
        stock = line.get("_stock") if line else None    # the DB stock, not the phone's
        cart, reason = selling.cart_set_qty(cart, int(line_id),
                                            request.data.get("qty"), stock=stock)
        if reason != selling.R_OK:
            if reason == selling.R_LOW_STOCK:
                return _err(lang, "স্টকে এতগুলো নেই।", "Not enough in stock.",
                            status=422, code=reason)
            return _err(lang, "পরিবর্তন করা যায়নি।", "Could not update.",
                        status=422, code=reason)
        return Response({"cart": _cart_out(cart, role)})


class CartRemoveView(APIView):
    def delete(self, request, line_id):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        cart, _ = _rehydrate_cart(prof, request.data.get("cart"))
        cart, reason = selling.cart_remove_line(cart, int(line_id))
        if reason != selling.R_OK:
            return _err(lang, "লাইন পাওয়া যায়নি।", "Line not found.", status=404)
        return Response({"cart": _cart_out(cart, role)})


class CartRemovePostView(APIView):
    """POST cart/line/<id>/remove — stateless-cart twin of DELETE cart/line/<id>.
    Takes {cart}, returns the recomputed {cart} (the client holds the cart, so a
    POST with a body is cleaner than a DELETE-with-body for this path)."""
    def post(self, request, line_id):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        cart, _ = _rehydrate_cart(prof, request.data.get("cart"))
        cart, reason = selling.cart_remove_line(cart, int(line_id))
        if reason != selling.R_OK:
            return _err(lang, "লাইন পাওয়া যায়নি।", "Line not found.", status=404)
        return Response({"cart": _cart_out(cart, role)})


class CartDiscountPreviewView(APIView):
    """POST cart/discount/preview — clamp to floor → discount_clamped + below_min."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        cart, stale = _rehydrate_cart(prof, request.data.get("cart"))
        if stale:
            return _stale_cart(req_lang(request))
        d = request.data
        # the app sends `amount` (taka); `discount` kept for older callers
        raw = d.get("discount") if d.get("discount") not in (None, "") else d.get("amount", 0)
        eff, reason = selling.apply_cart_discount(cart, raw)
        out = _cart_out(cart, role, discount=eff)
        out["discount_clamped"] = reason == selling.R_BELOW_MIN
        return Response({"cart": out, "discount": eff,
                         "discount_clamped": reason == selling.R_BELOW_MIN,
                         "reason": reason})


class CheckoutView(APIView):
    """POST sales/checkout — persist Sale/SaleLine + stock. Discount clamp +
    minimum-price enforced in checkout(); staff may complete, response redacted."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        d = request.data
        cart, stale = _rehydrate_cart(prof, d.get("cart"))
        if stale:
            return _stale_cart(lang)
        # HARD GATE on the DB minimum (the phone's min_price is ignored)
        if any(l["unit_price"] < l["min_price"] for l in cart["lines"]):
            return _below_min(lang)
        need = {}
        for l in cart["lines"]:
            k = selling.line_stock_key(l)
            need[k] = (need.get(k, (0, l["_stock"]))[0] + l["qty"], l["_stock"])
        if any(q > st for q, st in need.values()):
            return _err(lang, "স্টকে এতগুলো নেই।", "Not enough in stock.",
                        status=422, code=selling.R_LOW_STOCK)
        for l in cart["lines"]:
            l.pop("_stock", None)
        if d.get("payment_method") == selling.PAY_DUE and not (
                (d.get("customer_phone") or "").strip()
                or (d.get("customer_name") or "").strip()):
            # bizbar: an unnamed due sale landed in ONE shared "Customer"
            # khata page for every buyer — a due must say whose it is.
            return _err(lang, "বাকিতে বিক্রির জন্য গ্রাহকের নাম বা ফোন দিন।",
                        "A sale on due needs the customer's name or phone.",
                        status=422, code="due_needs_customer")

        # resolve / create the customer (find_or_create mirrors the ORM table)
        from .models import Customer
        cust_obj = None
        cust_dict = None
        phone = (d.get("customer_phone") or "").strip()
        if phone or d.get("customer_name"):
            key = selling.normalize_phone(phone)
            cust_obj = (Customer.objects.filter(user_id=prof.user_id, business=prof,
                                                phone_key=key).first()
                        if key else None)
            if cust_obj is None:
                cust_obj = Customer.objects.create(
                    user_id=prof.user_id, business=prof,
                    name=d.get("customer_name", ""), phone=phone, phone_key=key,
                    area=d.get("customer_area", ""))
            cust_dict = {"name": cust_obj.name, "phone": cust_obj.phone}

        res, reason = selling.checkout(
            cart, payment_method=d.get("payment_method", selling.PAY_CASH),
            paid=d.get("paid"), discount=d.get("discount", 0),
            customer=cust_dict, now=timezone.now(), lang=lang)
        if res is None:
            if reason == selling.R_SHORT:
                return _err(lang, "পরিশোধ কম হয়েছে।", "Payment is short.",
                            status=422, code=reason)
            if reason == selling.R_EMPTY:
                return _err(lang, "কার্ট খালি।", "Cart is empty.", status=422,
                            code=reason)
            return _err(lang, "চেকআউট ব্যর্থ।", "Checkout failed.", status=422,
                        code=reason)

        # persist the sale + lines (never a line below min — checkout guarantees it)
        from .models import Sale, SaleLine, ProductVariant
        # the sale belongs to the SHOP (owner) — a staff sale was saved under
        # the staff user and vanished from the owner's reports
        sale = Sale.objects.create(
            user_id=prof.user_id, business=prof, customer=cust_obj, staff=request.user,
            subtotal=res["subtotal"], discount=res["discount"], total=res["total"],
            paid=res["paid"], change=res["change"], due=res["due"],
            profit=res["profit"], payment_method=res["payment_method"],
            discount_clamped=res["discount_clamped"])
        # resolve the catalog variants first so each SaleLine records the one
        # whose stock it decrements (a void restores exactly that).
        # bizbar: resolve by (product, variant key). Every simple product's
        # key is "__base__", so the old lookup by key alone decremented the
        # FIRST product's stock for every sale.
        vobjs = {}
        vmap = {}
        for l in res["lines"]:
            lk = selling.line_stock_key(l)
            if lk in vobjs:
                continue
            v = (ProductVariant.objects.filter(product__user_id=prof.user_id,
                                               product_id=l.get("product_id"),
                                               vkey=l["variant_key"]).first()
                 if l.get("product_id") else None)
            if v:
                vobjs[lk] = v
                vmap[lk] = _variant_dict(v)
        for l in res["lines"]:
            vobj = vobjs.get(selling.line_stock_key(l))
            SaleLine.objects.create(
                sale=sale, product_name=l["product_name"], size=l.get("size", ""),
                colour=l.get("colour", ""), qty=l["qty"],
                unit_price=l["unit_price"], min_price=l["min_price"],
                cost_price=l["cost_price"], sell_price=l["sell_price"],
                variant=vobj, product_id=(vobj.product_id if vobj else None),
                variant_key=(l.get("variant_key") or "")[:120])

        # apply stock decrements across the catalog variants
        decs = selling.apply_stock_decrements(vmap, res["stock_decrements"])
        from django.db.models import F
        for dd in decs:
            v = vobjs.get(dd["variant_key"])
            if v:
                # F(): two tills selling the last items at once both count
                ProductVariant.objects.filter(pk=v.pk).update(
                    stock=F("stock") - dd["qty"])
                v.refresh_from_db(fields=["stock"])
                dd["new_stock"] = v.stock
                dd["low_stock"] = v.stock <= v.low_stock_at
                dd["out_of_stock"] = v.stock <= 0
                dd["product_name"] = v.product.name
                if v.product.variants.count() == 1:     # keep Product.stock in step
                    type(v.product).objects.filter(pk=v.product_id).update(stock=v.stock)

        # DUE-SALE → KHATA BRIDGE. A due (or partially-due) sale leaves a
        # receivable the owner must chase; selling.checkout does NOT touch the
        # khata, so mirror the due into the CUSTOMER book here exactly once.
        # BOUNDARY: res["due"] is selling-side POISHA and khata.new_entry stores
        # POISHA -> pass it through with NO ×100. The Sale.due and this single
        # khata entry are the SAME debt surfaced on two screens (history/report
        # vs khata book); neither report sums the other, so no double-count.
        khata_entry_id = self._bridge_due_to_khata(request, prof, sale, cust_obj, res)

        # CCTV Part 4: mirror into the owner's Shop Box sites (pos_link). An
        # explicit call (not a signal); it can never break checkout.
        try:
            from .shop_ops_views import mirror_sale
            mirror_sale(prof, sale)
        except Exception:
            pass

        out = dict(res)
        out["sale_id"] = sale.id
        out["low_stock"] = decs
        if khata_entry_id is not None:
            out["khata_entry_id"] = khata_entry_id
        return Response(selling.redact_sale(out, role))   # STAFF ROLE gate

    @staticmethod
    def _bridge_due_to_khata(request, prof, sale, cust_obj, res):
        """Mirror a due sale's receivable into the customer's khata book once.

        Returns the KhataEntry id (new or already-existing), or None when the
        sale carries no due. Idempotent on the Sale: the entry note embeds a
        '[sale#<id>]' marker so a retried checkout never double-books the debt.
        Customer resolution mirrors the till Customer: find-or-create the
        CUSTOMER-book KhataParty by normalised phone (falling back to name).
        """
        due = res.get("due", 0)
        if res.get("payment_method") != selling.PAY_DUE or not due or due <= 0:
            return None

        from .models import KhataParty, KhataEntry
        marker = "[sale#%d]" % sale.id
        phone = (getattr(cust_obj, "phone", "") or "").strip()
        name = (getattr(cust_obj, "name", "") or "").strip() or phone or "Customer"

        # find-or-create the party in the CUSTOMER book (dedupe by phone)
        party = None
        if phone:
            party = prof.khata_parties.filter(book=khata.CUSTOMER,
                                              phone=phone).first()
        if party is None and not phone:
            party = prof.khata_parties.filter(book=khata.CUSTOMER,
                                              name=name).first()
        if party is None:
            party = KhataParty.objects.create(
                business=prof, book=khata.CUSTOMER, name=name, phone=phone,
                area=(getattr(cust_obj, "area", "") or ""))

        # idempotency: if this sale already bridged, reuse that entry
        existing = party.entries.filter(note__contains=marker).first()
        if existing is not None:
            return existing.id

        # CUSTOMER book: owner 'gave' goods on credit -> customer owes MORE.
        # amount is POISHA (khata.to_poisha passes the int through unchanged).
        entry = khata.new_entry(party.id, "gave", due,
                                note=("বাকি বিক্রি %s" % marker),
                                at=_now_iso())
        obj = KhataEntry.objects.create(
            party=party, direction=entry["direction"],
            amount_poisha=entry["amount"], note=entry["note"],
            at=timezone.now())
        return obj.id


class ReceiptView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Sale
        s = Sale.objects.filter(user=request.user, pk=pk).first()
        if not s:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        sale = {
            "payment_method": s.payment_method, "subtotal": s.subtotal,
            "discount": s.discount, "total": s.total, "paid": s.paid,
            "change": s.change, "due": s.due,
            "customer": {"name": s.customer.name} if s.customer_id else None,
            "when": s.created_at,
            "lines": [{"product_name": l.product_name, "size": l.size,
                       "colour": l.colour, "qty": l.qty,
                       "unit_price": l.unit_price} for l in s.lines.all()],
        }
        out = selling.build_receipt(sale, lang=lang)
        out.update(_void_fields(s, lang))
        return Response(out)


class ReceiptPdfView(APIView):
    """GET sales/<id>/receipt.pdf — the same receipt data with a `pdf` flag.

    We keep this HONEST: there is no server PDF library wired for the business
    module, so we return the structured receipt dict (identical to ReceiptView)
    plus `pdf: False` + a `format: "json"` marker. The client's saleReceiptPdf
    falls back to a text/structured share when the payload is not raw PDF bytes
    (its docstring already documents that fallback)."""
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Sale
        s = Sale.objects.filter(user=request.user, pk=pk).first()
        if not s:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        sale = {
            "payment_method": s.payment_method, "subtotal": s.subtotal,
            "discount": s.discount, "total": s.total, "paid": s.paid,
            "change": s.change, "due": s.due,
            "customer": {"name": s.customer.name} if s.customer_id else None,
            "when": s.created_at,
            "lines": [{"product_name": l.product_name, "size": l.size,
                       "colour": l.colour, "qty": l.qty,
                       "unit_price": l.unit_price} for l in s.lines.all()],
        }
        out = selling.build_receipt(sale, lang=lang)
        out.update(_void_fields(s, lang))
        out["pdf"] = False
        out["format"] = "json"
        return Response(out)


class CustomersView(APIView):
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        from .models import Customer, Sale
        from django.db.models import Sum
        qs = Customer.objects.filter(user_id=prof.user_id, business=prof)
        q = (request.query_params.get("q") or "").strip()
        if q:
            from django.db.models import Q
            digits = "".join(ch for ch in khata.normalize_digits(q) if ch.isdigit())
            cond = Q(name__icontains=q)
            if len(digits) >= 3:
                cond |= Q(phone_key__contains=digits[-10:])
            qs = qs.filter(cond)
        # bizbar: the list's dues column was dead (never sent) — one query
        dues = dict(Sale.objects.filter(business=prof, voided_at__isnull=True,
                                        customer__in=qs)
                    .values_list("customer_id").annotate(d=Sum("due")))
        rows = [{"id": c.id, "name": c.name, "phone": c.phone, "area": c.area,
                 "vip": c.vip, "dues_poisha": int(dues.get(c.id) or 0)}
                for c in qs[:500]]
        return Response({"customers": rows})


    # m2-reality: the customer form saves here (was 405 -> never saved).
    # Create-or-update keyed by the normalised phone (same rule as checkout).
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Customer
        d = request.data
        name = str(d.get("name", "")).strip()[:120]
        phone = str(d.get("phone", "")).strip()[:40]
        if not name and not phone:
            return _err(lang, "নাম বা ফোন দিন।", "Enter a name or phone.",
                        status=422, code="invalid_customer")
        key = selling.normalize_phone(phone) if phone else ""
        c = None
        if d.get("id"):
            c = Customer.objects.filter(user_id=prof.user_id, business=prof,
                                        pk=d.get("id")).first()
        if c is None and key:
            c = Customer.objects.filter(user_id=prof.user_id, business=prof,
                                        phone_key=key).first()
        if c is None:
            c = Customer(user_id=prof.user_id, business=prof)
        c.name, c.phone, c.phone_key = name, phone, key
        c.address = str(d.get("address", "")).strip()
        c.area = str(d.get("area", "")).strip()[:80]
        c.notes = str(d.get("notes", "")).strip()
        c.vip = bool(d.get("vip"))
        c.save()
        return Response({"id": c.id, "name": c.name, "phone": c.phone,
                         "address": c.address, "area": c.area,
                         "notes": c.notes, "vip": c.vip}, status=201)


class CustomerDedupeView(APIView):
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        rows = [{"name": c.name, "phone": c.phone, "address": c.address,
                 "area": c.area, "notes": c.notes, "vip": c.vip}
                for c in prof.user.sale_customers.filter(business=prof)]
        return Response({"customers": selling.dedupe_customers(rows)})


class CustomerHistoryView(APIView):
    def get(self, request, phone):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        from .models import Sale
        sales = [_sale_record(s) for s in
                 Sale.objects.filter(business=prof)
                 .prefetch_related("lines")]
        hist = selling.purchase_history(sales, phone)
        # a VOIDED sale stays in history (marked) but owes nothing
        dues = selling.customer_dues_poisha(
            [x for x in sales if not x.get("voided")], phone)
        out = {"history": [selling.redact_sale(h, role) for h in hist],
               "dues_poisha": dues}
        return Response(out)


class ReportsView(APIView):
    """GET reports/?period=daily|weekly|monthly — staff strips profit/cost/net."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        period = request.query_params.get("period", "daily")
        # plans-v2: the day's totals are "Digital Ledger basic" (free); weekly
        # and monthly reports are a Business feature (shop owner's plan).
        if period != "daily":
            gate = _plan_gate(request, prof, "reports") if _v2_owner(prof) else None
            if gate:
                return gate
        from .models import Sale, Expense
        # bizbar: the report is for the CURRENT window (today / last 7 days /
        # this month, Dhaka) and the SHOP (staff sales included) — it summed
        # all-time rows of the requesting user only, and the app read flat
        # keys the server never sent (always ৳0).
        today = timezone.localdate()
        start = (today if period == "daily" else
                 today - timedelta(days=6) if period == "weekly" else
                 today.replace(day=1))
        start_dt = timezone.make_aware(datetime.combine(start, datetime.min.time()))
        sales = [_sale_record(s) for s in
                 Sale.objects.filter(business=prof, voided_at__isnull=True,
                                     created_at__gte=start_dt)   # VOID excluded
                 .prefetch_related("lines")]
        exp_rows = list(Expense.objects.filter(business=prof, date__gte=start))
        expenses = [{"amount": selling.poisha_to_taka(e.amount),
                     "date": e.date.isoformat(), "category": e.category}
                    for e in exp_rows]
        rep = selling.full_report(sales, expenses, period=period, lang=lang,
                                  role=role)   # STAFF ROLE gate baked into pure fn
        total = sum(int(x.get("total", 0)) for x in sales)
        flat = {"role": role, "from": start.isoformat(), "to": today.isoformat(),
                "sales_total": total, "sale_count": len(sales),
                "expenses": sum(int(e.amount) for e in exp_rows)}
        if role != selling.ROLE_STAFF:
            gross = sum(int(x.get("profit", 0)) for x in sales)
            flat.update({"profit": gross, "net_profit": gross - flat["expenses"]})
        rep.update(flat)
        rep["sales_by_period"] = rep.pop("sales", {})
        rep["sales"] = total
        return Response(rep)


# ===========================================================================
# DIGITAL KHATA + CASHBOX
# ===========================================================================

def _party_balance(party):
    entries = [{"direction": e.direction, "amount": e.amount_poisha}
               for e in party.entries.all()]
    return khata.running_balance(entries, party.book)


def _book_balances(prof, book):
    """ledger100: every party's balance in ONE aggregate query (a shop with
    500 customers was 501 queries). Same sign rule as khata._signed."""
    from django.db.models import Q, Sum
    from .models import KhataEntry
    plus = "gave" if book == khata.CUSTOMER else "got"
    rows = (KhataEntry.objects.filter(party__business=prof, party__book=book)
            .values("party_id")
            .annotate(up=Sum("amount_poisha", filter=Q(direction=plus)),
                      down=Sum("amount_poisha", filter=~Q(direction=plus))))
    return {r["party_id"]: int(r["up"] or 0) - int(r["down"] or 0) for r in rows}


def _balance_fields(bal, book, lang):
    """Both the legacy keys and the app's *_poisha/_display/_status keys
    (ledger100: the app read balance_display while the server only sent
    balance_fmt, so every balance showed blank)."""
    fmt = khata.fmt_amount(bal)
    st = khata.balance_status(bal, book, lang)
    return {"balance": bal, "balance_fmt": fmt, "status": st,
            "balance_poisha": bal, "balance_display": fmt, "balance_status": st}


def _party_row(p, bal, lang):
    row = {"id": p.id, "name": p.name, "phone": p.phone, "area": p.area,
           "vip": p.vip, "book": p.book,
           "phone_ok": bool(khata.bd_msisdn(p.phone))}
    row.update(_balance_fields(bal, p.book, lang))
    return row


class KhataPartiesView(APIView):
    """GET list (book=customer|supplier; supplier owner-only) / POST create.
    The digital khata core is FREE on every plan (no plan gate, no credits)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        book = request.query_params.get("book", khata.CUSTOMER)
        if book == khata.SUPPLIER and not is_owner(role):
            return _owner_only(request, role)   # supplier book owner-only
        lang = req_lang(request)
        bals = _book_balances(prof, book)
        rows = [_party_row(p, bals.get(p.id, 0), lang)
                for p in prof.khata_parties.filter(book=book, archived=False)
                .order_by("name", "id")]
        return Response({"parties": rows, "role": role, "free": True})

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        book = request.data.get("book", khata.CUSTOMER)
        if book not in (khata.CUSTOMER, khata.SUPPLIER):
            return _err(lang, "খাতার ধরন ভুল।", "Unknown book.", status=422,
                        code="bad_book")
        if book == khata.SUPPLIER and not is_owner(role):
            return _owner_only(request, role)   # create supplier party owner-only
        name = str(request.data.get("name") or "").strip()[:120]
        if not name:
            return _err(lang, "নাম লিখুন।", "Enter a name.", status=422,
                        code="name_required")
        from .models import KhataParty
        from .phone import canonical_phone
        phone = str(request.data.get("phone") or "")[:40]
        # bizbar: never a twin. The same phone in the same book is the same
        # person (TallyKhata warns too), and a party queued offline is
        # replayed with its client_id until the phone hears back — a replay
        # after a lost answer returns the party already made.
        canon = canonical_phone(phone) or ""
        ex = None
        if canon:
            ex = prof.khata_parties.filter(book=book, phone_canon=canon,
                                           archived=False).first()
        cid = _client_id(request)
        marker = "[cid:%s]" % cid if cid else ""
        if ex is None and marker:
            ex = prof.khata_parties.filter(book=book, note__contains=marker).first()
        if ex is not None:
            out = _party_row(ex, _party_balance(ex), lang)
            out["existing"] = True
            return Response(out, status=200)
        p = KhataParty.objects.create(
            business=prof, book=book, name=name, phone=phone,
            area=str(request.data.get("area") or "")[:80],
            # the client_id rides in the (never shown) note so a replay
            # finds this row — no schema change
            note=(str(request.data.get("note") or "") + marker).strip(),
            vip=bool(request.data.get("vip")))
        out = _party_row(p, 0, lang)
        return Response(out, status=201)


def _get_party(request, prof, role, pk):
    """Return (party, err_response). Enforces supplier-book owner-only."""
    p = prof.khata_parties.filter(pk=pk).first()
    if not p:
        return (None, _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404))
    if p.book == khata.SUPPLIER and not is_owner(role):
        return (None, _owner_only(request, role))
    return (p, None)


_LINKED_MARKERS = ("[sale#", "[void")


def _entry_editable(e):
    """A row mirrored from a sale / a void is changed from the sale, never
    by hand (it would split the sale and the khata)."""
    return not any(m in (e.note or "") for m in _LINKED_MARKERS)


def _entry_dicts(p):
    return [{"id": e.id, "direction": e.direction, "amount": e.amount_poisha,
             "note": e.note, "at": e.at.isoformat(), "version": e.version,
             "client_id": e.client_id, "editable": _entry_editable(e),
             "method": e.method or "",
             "bill_photo_ref": e.bill_photo.url if e.bill_photo else None}
            for e in p.entries.all()]


# ===========================================================================
# bizbar — STAFF (one shop, several phones). The role model existed
# (BusinessStaff + every staff redaction) but nothing could create a row, so
# "staff accounts" were unreachable. Owner adds an Assisto user by number.
# ===========================================================================

def _staff_row(m):
    from .phone import mask, canonical_phone
    u = m.member
    return {"id": m.id, "name": getattr(u, "name", "") or "",
            "phone_masked": mask(canonical_phone(u.phone or "") or ""),
            "role": m.role, "active": m.active,
            "since": m.created_at.isoformat()}


STAFF_MAX = 10


class StaffView(APIView):
    """GET staff (owner) / POST {phone} add an Assisto user as staff."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        rows = [_staff_row(m) for m in prof.staff.filter(active=True)
                .select_related("member").order_by("created_at")]
        return Response({"staff": rows, "max": STAFF_MAX})

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        from .models import BusinessStaff
        from .phone import find_user, is_discoverable
        u = find_user(str(request.data.get("phone") or ""))
        if u is None or not is_discoverable(u):
            return _err(lang,
                        "এই নম্বরে Assisto অ্যাকাউন্ট পাওয়া যায়নি। আগে তাঁকে Assisto-তে যোগ দিতে বলুন, তারপর আবার যোগ করুন।",
                        "No Assisto account on this number. Ask them to join Assisto first, then add them again.",
                        status=404, code="staff_not_on_assisto")
        if u.id == prof.user_id:
            return _err(lang, "আপনি নিজেই মালিক।", "You are the owner.",
                        status=422, code="staff_is_owner")
        if prof.staff.filter(active=True).exclude(member=u).count() >= STAFF_MAX:
            return _err(lang, "সর্বোচ্চ %d জন কর্মচারী।" % STAFF_MAX,
                        "At most %d staff." % STAFF_MAX, status=422,
                        code="staff_limit")
        m, _ = BusinessStaff.objects.get_or_create(
            business=prof, member=u, defaults={"role": "staff"})
        if not m.active or m.role != "staff":
            m.active, m.role = True, "staff"
            m.save(update_fields=["active", "role"])
        # no push: there is no business push kind yet — the owner's screen
        # tells them where the shop appears (Business -> Switch shop)
        return Response(_staff_row(m), status=201)


class StaffRemoveView(APIView):
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        n = prof.staff.filter(pk=pk, active=True).update(active=False)
        if not n:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        return Response({"ok": True})


class KhataExportView(APIView):
    """GET khata/export — bizbar: the owner's own copy of the WHOLE khata
    (both books, every entry) as CSV text in JSON {filename, csv, parties,
    entries}. Owner-only (the supplier book shows cost). Two queries."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        parties = list(prof.khata_parties.filter(archived=False)
                       .order_by("book", "name", "id")
                       .prefetch_related("entries"))
        rows = [{"book": p.book, "name": p.name, "phone": p.phone, "area": p.area,
                 "entries": [{"direction": e.direction, "amount": e.amount_poisha,
                              "note": e.note, "at": e.at.isoformat()}
                             for e in p.entries.all()]}
                for p in parties]
        day = timezone.localdate().isoformat()
        return Response({
            "filename": "assisto-khata-%s.csv" % day,
            "csv": khata.khata_export_csv(rows, lang),
            "parties": len(rows),
            "entries": sum(len(r["entries"]) for r in rows),
        })


class KhataStatementView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p, err = _get_party(request, prof, role, pk)
        if err:
            return err
        lang = req_lang(request)
        stmt = khata.party_statement(
            {"id": p.id, "name": p.name, "phone": p.phone}, _entry_dicts(p), p.book, lang)
        stmt["lines"] = khata.statement_lines(stmt, p.book)
        stmt["party"] = _party_row(p, stmt["balance"], lang)
        stmt.update(_balance_fields(stmt["balance"], p.book, lang))
        return Response(stmt)


def _parse_at(raw):
    """ledger100: the owner-picked entry date (was ignored — every entry got
    'now', so a back-dated or offline entry landed on the wrong day). ISO
    date or datetime; naive = Dhaka. Junk / >1 day in the future / before
    2000 → now."""
    from django.utils.dateparse import parse_date, parse_datetime
    now = timezone.now()
    s = str(raw or "").strip()
    if not s:
        return now
    dt = None
    try:
        dt = parse_datetime(s)
        if dt is None:
            d = parse_date(s[:10])
            if d is not None:
                dt = datetime(d.year, d.month, d.day, 12, 0)
    except (ValueError, TypeError):
        dt = None
    if dt is None:
        return now
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt)
    if dt > now + timedelta(days=1) or dt.year < 2000:
        return now
    return dt


def _client_id(request):
    import re
    cid = str(request.data.get("client_id") or "").strip()[:64]
    return cid if re.fullmatch(r"[A-Za-z0-9_.:-]{6,64}", cid or "") else ""


def _pay_method(raw):
    """ledger2: cash | bkash | nagad | bank, else '' (= cash in the books)."""
    m = str(raw or "").strip().lower()
    return m if m in ("cash", "bkash", "nagad", "bank") else ""


def _persist_entry(request, p, entry):
    """Create the KhataEntry once per client_id. Returns (obj, duplicate)."""
    from django.db import IntegrityError, transaction
    from .models import KhataEntry
    cid = _client_id(request)
    if cid:
        ex = p.entries.filter(client_id=cid).first()
        if ex is not None:
            return ex, True
    try:
        with transaction.atomic():
            obj = KhataEntry.objects.create(
                party=p, direction=entry["direction"], amount_poisha=entry["amount"],
                note=(entry["note"] or "")[:200], at=_parse_at(request.data.get("at")),
                client_id=cid, method=_pay_method(request.data.get("method")))
    except IntegrityError:
        ex = p.entries.filter(client_id=cid).first() if cid else None
        if ex is None:
            raise
        return ex, True
    return obj, False


def _entry_out(p, obj, lang, duplicate=False):
    bal = _party_balance(p)
    out = {"entry_id": obj.id, "id": obj.id, "client_id": obj.client_id,
           "version": obj.version, "duplicate": duplicate,
           "at": obj.at.isoformat(), "method": obj.method or ""}
    out.update(_balance_fields(bal, p.book, lang))
    return out


class KhataEntryView(APIView):
    """POST party/<id>/entries — new_entry() validates, view persists.
    ledger100: `client_id` makes a replayed offline entry idempotent (200 +
    duplicate:true, nothing booked twice); `at` is honoured."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p, err = _get_party(request, prof, role, pk)
        if err:
            return err
        lang = req_lang(request)
        try:
            entry = khata.new_entry(
                p.id, request.data.get("direction"), request.data.get("amount"),
                note=request.data.get("note", ""), at=_now_iso())
        except ValueError as e:
            return _err(lang, "এন্ট্রি ভুল।", "Invalid entry.", status=422,
                        code="invalid_entry", reason=str(e))
        obj, dup = _persist_entry(request, p, entry)
        out = _entry_out(p, obj, lang, dup)
        if request.data.get("notify_customer") and p.book == khata.CUSTOMER and not dup:
            out["entry_added_message"] = khata.entry_added_message(
                {"name": p.name}, entry, shop_name=prof.shop_name)
        return Response(out, status=200 if dup else 201)


class KhataPaymentView(APIView):
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p, err = _get_party(request, prof, role, pk)
        if err:
            return err
        lang = req_lang(request)
        try:
            entry = khata.apply_payment(
                p.id, request.data.get("amount"), p.book,
                note=request.data.get("note", ""), at=_now_iso())
        except ValueError as e:
            return _err(lang, "পেমেন্ট ভুল।", "Invalid payment.", status=422,
                        code="invalid_payment", reason=str(e))
        obj, dup = _persist_entry(request, p, entry)
        return Response(_entry_out(p, obj, lang, dup), status=200 if dup else 201)


class KhataEntryEditView(APIView):
    """ledger100: POST/PATCH business/khata/entries/<id> {amount?, note?,
    at?, base_version?} — OWNER edits one entry (staff can add, not change
    money already booked). Balances are always recomputed from the rows, so
    an edit can never double-count. `base_version` (the version the phone
    saw, e.g. when the edit was made offline) must still be current, else
    409 conflict with the server's row — never a silent overwrite. Rows
    mirrored from a sale / void are refused (409 linked_entry)."""
    def post(self, request, pk):
        from django.db import transaction
        from .models import KhataEntry
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        with transaction.atomic():
            e = (KhataEntry.objects.select_for_update()
                 .filter(pk=pk, party__business=prof).first())
            if e is None:
                return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
            if not _entry_editable(e):
                return _err(lang, "বিক্রি থেকে আসা এন্ট্রি বিক্রি থেকেই বদলান।",
                            "This entry came from a sale — change it from the sale.",
                            status=409, code="linked_entry")
            base = request.data.get("base_version")
            if base not in (None, "") and str(base) != str(e.version):
                return _err(lang, "এই এন্ট্রি অন্য কোথাও বদলানো হয়েছে — নতুনটা দেখে আবার করুন।",
                            "This entry was changed elsewhere — check the new one and try again.",
                            status=409, code="conflict",
                            current={"entry_id": e.id, "version": e.version,
                                     "amount": e.amount_poisha, "note": e.note,
                                     "at": e.at.isoformat()})
            if "amount" in request.data:
                amt = khata.to_poisha(request.data.get("amount"))
                if amt <= 0:
                    return _err(lang, "টাকার পরিমাণ ভুল।", "Invalid amount.", status=422,
                                code="invalid_entry", reason="amount must be positive")
                e.amount_poisha = amt
            if "note" in request.data:
                e.note = str(request.data.get("note") or "")[:200]
            if request.data.get("at"):
                e.at = _parse_at(request.data.get("at"))
            if "method" in request.data:
                e.method = _pay_method(request.data.get("method"))
            e.version = e.version + 1
            e.edited_at = timezone.now()
            e.save(update_fields=["amount_poisha", "note", "at", "version", "edited_at",
                                  "method"])
        return Response(_entry_out(e.party, e, lang))

    patch = post


class KhataNetPositionView(APIView):
    """GET net-position — customers always; supplier figures owner-only (zeroed)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        live = set(prof.khata_parties.filter(archived=False).values_list("id", flat=True))
        cust = [b for k, b in _book_balances(prof, khata.CUSTOMER).items() if k in live]
        if is_owner(role):
            supp = [b for k, b in _book_balances(prof, khata.SUPPLIER).items()
                    if k in live]
        else:
            supp = []       # staff never sees supplier figures
        np = khata.net_position(cust, supp)
        np.update({"receivable_display": np["receivable_fmt"],
                   "payable_display": np["payable_fmt"],
                   "net_display": np["net_fmt"], "net_status": np["label"],
                   "ahead": np["net"] >= 0,
                   "due_customers": sum(1 for b in cust if b > 0)})
        if not is_owner(role):
            np["supplier_hidden"] = True
        return Response(np)


# ---- tagada (due reminders) ------------------------------------------------
#
# FREE on every plan: the message, the WhatsApp link and the phone's own SMS
# composer (the user sends; nothing leaves without their tap). PAID: only an
# SMS that ASSISTO sends (credits per segment, shown before sending).

def _pay_hint(raw):
    if not isinstance(raw, dict):
        return None
    num = khata.normalize_digits(str(raw.get("number") or "")).strip()[:20]
    if not num:
        return None
    method = str(raw.get("method") or "bKash").strip()[:12] or "bKash"
    return {"method": method, "number": num}


def _reminder_row(p, bal, prof, preset, pay_hint, lang, role=None, wallet=None, pre=None):
    text = khata.tagada_message({"name": p.name}, bal, shop_name=prof.shop_name,
                                preset=preset, pay_hint=pay_hint, lang=lang)
    from . import sms_segments
    from . import tagada_engine as TE
    seg = sms_segments.segments(text)
    row = {"party_id": p.id, "name": p.name, "phone": p.phone,
           "phone_ok": bool(khata.bd_msisdn(p.phone)),
           "balance_poisha": bal, "balance_display": khata.fmt_amount(bal),
           "message": text, "wa_url": khata.wa_link(p.phone, text),
           "sms_uri": khata.sms_uri(p.phone, text),
           # tagada2: Assisto SMS is paid in SMS PARTS (1 part = 1 segment)
           "sms_segments": seg, "sms_credits": seg}
    # tagada2: the server-decided send order for this customer
    f = TE.facts(prof, p, owner=role is None or is_owner(role), text=text, wallet=wallet,
                 pre=pre)
    row.update(TE.row_fields(prof, p, f))
    return row


def _sms_offer(request, role, prof=None):
    """What the Assisto-SMS option looks like for this requester. tagada2:
    the balance is SMS PARTS (Business allowance + packs), never AI credits."""
    from . import tagada_engine as TE
    if prof is None:
        prof, _ = resolve_business(request)
    return TE.sms_offer(prof, is_owner(role))


class TagadaSingleView(APIView):
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p = prof.khata_parties.filter(pk=pk, book=khata.CUSTOMER).first()
        if not p:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        lang = req_lang(request)
        bal = _party_balance(p)
        preset = request.data.get("preset", "polite")
        hint = _pay_hint(request.data.get("pay_hint"))
        plan = khata.plan_tagada_single(
            {"id": p.id, "name": p.name, "phone": p.phone}, bal,
            shop_name=prof.shop_name, preset=preset, pay_hint=hint,
            channel=request.data.get("channel", "whatsapp_share"),
            sms_enabled=_sms_enabled(), lang=lang)
        out = {"plan": plan, "sms": _sms_offer(request, role, prof)}
        if plan:
            row = _reminder_row(p, bal, prof, preset, hint, lang, role)
            out.update({"reminder": row, "message": plan["message"],
                        "share": {"whatsapp": {"available": True, "url": row["wa_url"]},
                                  "sms": {"available": bool(row["sms_uri"]),
                                          "uri": row["sms_uri"]}}})
        else:
            out["no_due"] = True
        return Response(out)


class TagadaBulkView(APIView):
    """ledger100: ONE reminder per customer (its own amount, the shop name,
    the optional pay-to number) — never a merged list. `party_ids` picks the
    customers (was ignored: everyone with a due was always returned)."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        preset = request.data.get("preset", "polite")
        hint = _pay_hint(request.data.get("pay_hint"))
        qs = prof.khata_parties.filter(book=khata.CUSTOMER, archived=False)
        ids = request.data.get("party_ids")
        if isinstance(ids, list) and ids:
            qs = qs.filter(pk__in=[int(i) for i in ids if str(i).isdigit()][:1000])
        bals = _book_balances(prof, khata.CUSTOMER)
        parties = list(qs.order_by("name", "id"))
        rows, reminders, skipped = [], [], []
        from . import sms_wallet
        from . import tagada_engine as TE
        wallet = sms_wallet.state(prof.user) if is_owner(role) and prof.user_id else None
        pre = TE.prefetch(prof, parties)
        for p in parties:
            bal = bals.get(p.id, 0)
            rows.append({"party": {"id": p.id, "name": p.name, "phone": p.phone},
                         "balance": bal})
            if bal > max(0, khata.to_poisha(request.data.get("min_due", 0))):
                reminders.append(_reminder_row(p, bal, prof, preset, hint, lang, role,
                                               wallet=wallet, pre=pre))
            else:
                skipped.append({"party_id": p.id, "name": p.name, "reason": "no_due"})
        res = khata.plan_tagada_bulk(
            rows, shop_name=prof.shop_name, preset=preset, pay_hint=hint,
            channel=request.data.get("channel", "whatsapp_share"),
            sms_enabled=_sms_enabled(), lang=lang,
            min_due=request.data.get("min_due", 0))
        res.update({"reminders": reminders, "skipped": skipped,
                    "sms": _sms_offer(request, role, prof),
                    "shop_name": prof.shop_name})
        return Response(res)


class TagadaSmsSendView(APIView):
    """smsotp: POST business/khata/tagada/sms/<pk> {preset?, pay_hint?} —
    the SERVER sends the due reminder by SMS. tagada2: now the
    "gateway_sms" step of the send order (core/tagada_engine): owner only,
    paid in SMS PARTS (Business allowance first, then SMS packs; never AI
    credits; never sent without balance; parts back on a gateway failure),
    max 1 tagada per customer per day across every channel, STOP opt-out,
    quiet hours 21:00-09:00 and the SMS caps. Kept for older app builds; the
    new screen uses business/khata/tagada/send/<pk>."""

    def post(self, request, pk):
        from . import tagada_engine as TE
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        p = prof.khata_parties.filter(pk=pk, book=khata.CUSTOMER).first()
        if not p:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        st, body = TE.send(prof, p, channel="gateway_sms", owner=True,
                           preset=request.data.get("preset", "polite"),
                           pay_hint=_pay_hint(request.data.get("pay_hint")),
                           lang=lang, by=request.user)
        sms = body.get("sms") or TE.sms_offer(prof, True)
        body.setdefault("segments", body.get("parts", 0))
        body["credits"] = body.get("parts", 0)
        body["balance"] = sms["parts_left"]
        return Response(body, status=st)


def _schedule_row(s, bal, lang):
    return {"id": s.id, "party": s.party_id, "party_id": s.party_id,
            "party_name": s.party.name, "preset": s.preset,
            "channel": s.channel,
            "mode": s.channel if s.channel in ("sms", "assisto") else "push",
            "next_at": s.next_at.isoformat(), "next_display": khata.day_label(
                timezone.localtime(s.next_at).isoformat()),
            "interval_days": s.interval_days, "until_paid": s.until_paid,
            "enabled": s.enabled, "pay_hint": s.pay_hint or {},
            "last_fired_at": s.last_fired_at.isoformat() if s.last_fired_at else None,
            "last_result": s.last_result, "fire_count": s.fire_count,
            "awaiting_owner": s.awaiting_owner,
            "balance_poisha": bal, "balance_display": khata.fmt_amount(bal)}


class TagadaScheduleView(APIView):
    """GET list / POST create-or-update a scheduled reminder (owner).

    ledger100 body: {party, next_at (ISO), interval_days (0 = once, 1..90 =
    every N days), until_paid (default true), channel 'sms' (Assisto SMS,
    credits) | anything else (a push to the owner: "time to remind X" — the
    owner sends it with one tap), preset, pay_hint}. One schedule per
    customer: posting again updates it. Fired by `manage.py tagada_sweep`."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        from .models import TagadaSchedule
        lang = req_lang(request)
        bals = _book_balances(prof, khata.CUSTOMER)
        qs = (TagadaSchedule.objects.filter(party__business=prof)
              .select_related("party").order_by("next_at", "id"))
        if request.query_params.get("party"):
            qs = qs.filter(party_id=request.query_params.get("party"))
        rows = [_schedule_row(s, bals.get(s.party_id, 0), lang) for s in qs]
        return Response({"schedules": rows,
                         "awaiting": [r for r in rows if r["awaiting_owner"]],
                         "sms": _sms_offer(request, role, prof)})

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        p = prof.khata_parties.filter(pk=request.data.get("party") or
                                      request.data.get("party_id") or 0,
                                      book=khata.CUSTOMER).first()
        if not p:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        try:
            interval = int(request.data.get("interval_days", 7))
        except (TypeError, ValueError):
            interval = -1
        if not 0 <= interval <= khata.SCHEDULE_MAX_INTERVAL_DAYS:
            return _err(lang, "দিনের সংখ্যা ০ থেকে ৯০ এর মধ্যে দিন।",
                        "Pick 0 to 90 days.", status=422, code="bad_interval")
        nxt = _parse_at(request.data.get("next_at")) if request.data.get("next_at") \
            else timezone.now()
        if nxt < timezone.now() - timedelta(minutes=5):
            nxt = timezone.now()
        raw_ch = request.data.get("channel")
        # tagada2: "assisto" = send it in the app (free) when the customer is a
        # verified Assisto user, else push the owner; "sms" also falls back to
        # the paid gateway SMS (SMS parts).
        channel = "sms" if raw_ch in ("sms", "assisto_sms") else \
            ("assisto" if raw_ch == "assisto" else "push")
        preset = request.data.get("preset") or "reminder"
        if preset not in khata.TAGADA_PRESETS or preset == "thanks":
            preset = "reminder"
        from .models import TagadaSchedule
        s = TagadaSchedule.objects.filter(party=p).order_by("-id").first()
        fields = dict(preset=preset, channel=channel, next_at=nxt,
                      interval_days=interval,
                      until_paid=request.data.get("until_paid", True) is not False,
                      pay_hint=_pay_hint(request.data.get("pay_hint")) or {},
                      enabled=True, awaiting_owner=False)
        created = s is None
        if created:
            s = TagadaSchedule.objects.create(party=p, **fields)
        else:
            for k, v in fields.items():
                setattr(s, k, v)
            s.save()
        return Response(_schedule_row(s, _party_balance(p), lang),
                        status=201 if created else 200)


class TagadaScheduleDetailView(APIView):
    """ledger100: DELETE schedule/<id> (stop it) · POST {ack:true} (the owner
    sent the reminder the push asked for) · POST {enabled:bool}."""
    def _get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return None, None, bad
        guard = _owner_only(request, role)
        if guard:
            return None, None, guard
        from .models import TagadaSchedule
        s = (TagadaSchedule.objects.filter(pk=pk, party__business=prof)
             .select_related("party").first())
        if s is None:
            return None, None, _err(req_lang(request), "পাওয়া যায়নি।", "Not found.",
                                    status=404)
        return s, prof, None

    def delete(self, request, pk):
        s, prof, bad = self._get(request, pk)
        if bad:
            return bad
        s.delete()
        return Response({"ok": True, "deleted": pk})

    def post(self, request, pk):
        s, prof, bad = self._get(request, pk)
        if bad:
            return bad
        if request.data.get("ack"):
            s.awaiting_owner = False
            s.last_result = "owner_sent"
        if "enabled" in request.data:
            s.enabled = bool(request.data.get("enabled"))
        s.save()
        return Response(_schedule_row(s, _party_balance(s.party), req_lang(request)))


class KhataStatementPdfView(APIView):
    """POST party/<id>/statement.pdf — returns the PDF DATA dict (render layer
    turns it into a file). Supplier owner-only."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        p, err = _get_party(request, prof, role, pk)
        if err:
            return err
        lang = req_lang(request)
        entries = [{"direction": e.direction, "amount": e.amount_poisha,
                    "note": e.note, "at": e.at.isoformat()}
                   for e in p.entries.all()]
        data = khata.statement_pdf_data(
            {"shop_name": prof.shop_name},
            {"id": p.id, "name": p.name, "phone": p.phone, "area": p.area},
            entries, book=p.book, now=_now_iso(), lang=lang)
        return Response(data)


def _cashbox_day(day):
    """'YYYY-MM-DD' -> (date, aware start, aware end) in Dhaka time, or None."""
    from datetime import date as _d, time as _t
    try:
        d = _d.fromisoformat(str(day))
    except ValueError:
        return None
    start = timezone.make_aware(datetime.combine(d, _t.min),
                                timezone.get_current_timezone())
    return d, start, start + timedelta(days=1)


def _cashbox_auto(prof, start, end):
    """bizbar: money the shop already booked today elsewhere -> cash-close
    lines (never typed twice). POS cash = paid − change of cash sales and the
    paid part of due sales (bKash/Nagad sales are not drawer cash; voided
    sales never count). Khata: customer payments got = in, supplier payments
    gave = out. Expenses dated today = out."""
    from django.db.models import Count, Sum
    from .models import Expense, KhataEntry, Sale
    sales = (Sale.objects.filter(business=prof, created_at__gte=start,
                                 created_at__lt=end, voided_at__isnull=True,
                                 payment_method__in=("cash", "due"))
             .aggregate(paid=Sum("paid"), change=Sum("change"), n=Count("id")))
    ke = KhataEntry.objects.filter(party__business=prof, at__gte=start, at__lt=end)
    dues = ke.filter(party__book=khata.CUSTOMER, direction="got").aggregate(
        s=Sum("amount_poisha"), n=Count("id"))
    supp = ke.filter(party__book=khata.SUPPLIER, direction="gave").aggregate(
        s=Sum("amount_poisha"), n=Count("id"))
    exp = Expense.objects.filter(business=prof, date=start.date()).aggregate(
        s=Sum("amount"), n=Count("id"))
    return {
        "cash_sales": max(0, (sales["paid"] or 0) - (sales["change"] or 0)),
        "cash_sales_count": sales["n"] or 0,
        "dues_collected": dues["s"] or 0, "dues_collected_count": dues["n"] or 0,
        "supplier_paid": supp["s"] or 0, "supplier_paid_count": supp["n"] or 0,
        "expenses": exp["s"] or 0, "expenses_count": exp["n"] or 0,
    }


def _cashbox_payload(request, prof, day, lang, cb=None):
    """The cashbox screen's ONE contract (khata.cashbox_close_view) for a day.
    No row yet -> the opening is carried from the last counted close."""
    from .models import CashboxDay
    d, start, end = _cashbox_day(day)
    if cb is None:
        cb = CashboxDay.objects.filter(business=prof, day=d).first()
    carried = False
    if cb is not None:
        opening = cb.opening_poisha
        entries = [{"id": e.id, "kind": e.kind, "amount": e.amount_poisha,
                    "note": e.note, "ref": e.ref, "at": e.at.isoformat()}
                   for e in cb.entries.all()]
    else:
        opening, entries = _carried_opening(prof, d), []
        carried = opening > 0
    out = khata.cashbox_close_view(
        opening, entries, auto=_cashbox_auto(prof, start, end),
        counted=cb.counted_poisha if cb is not None else None,
        reconciled_at=(cb.reconciled_at.isoformat()
                       if cb is not None and cb.reconciled_at else None),
        opening_carried=carried)
    out["day"] = d.isoformat()
    out["share_text"] = khata.cashbox_share_text(
        out, d.isoformat(), prof.shop_name or "", lang)
    return out


def _carried_opening(prof, d):
    """Yesterday's counted cash is today's opening (TallyKhata-style)."""
    from .models import CashboxDay
    prev = (CashboxDay.objects.filter(business=prof, day__lt=d,
                                      counted_poisha__isnull=False)
            .order_by("-day").first())
    return int(prev.counted_poisha) if prev is not None else 0


def _cashbox_row(prof, d):
    """get_or_create the day row; a NEW row starts from the carried opening."""
    from .models import CashboxDay
    cb = CashboxDay.objects.filter(business=prof, day=d).first()
    if cb is None:
        cb, _ = CashboxDay.objects.get_or_create(
            business=prof, day=d,
            defaults={"opening_poisha": _carried_opening(prof, d)})
    return cb


def _bad_day(lang):
    return _err(lang, "তারিখ ভুল।", "bad day (YYYY-MM-DD)", status=400,
                code="bad_day")


class CashboxView(APIView):
    """GET cashbox/<day> — the day-close payload (owner+staff)."""
    def get(self, request, day):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        if _cashbox_day(day) is None:   # a bad day used to 500 in the ORM filter
            return _bad_day(lang)
        return Response(_cashbox_payload(request, prof, day, lang))


class CashboxOpeningView(APIView):
    """POST cashbox/<day>/opening {opening} — set the day's opening cash
    (poisha), then return the fresh payload."""
    def post(self, request, day):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        dd = _cashbox_day(day)
        if dd is None:
            return _bad_day(lang)
        try:
            opening = int(request.data.get("opening") or 0)
        except (TypeError, ValueError):
            opening = -1
        if opening < 0:
            return _err(lang, "শুরুর ক্যাশ ভুল।", "Invalid opening amount.",
                        status=422, code="bad_opening")
        cb = _cashbox_row(prof, dd[0])
        if cb.opening_poisha != opening:
            cb.opening_poisha = opening
            cb.save(update_fields=["opening_poisha"])
        return Response(_cashbox_payload(request, prof, day, lang, cb=cb),
                        status=201)


class CashboxEntryView(APIView):
    """POST cashbox/<day>/entries {kind, amount(poisha), note} — returns the
    fresh payload + entry_id (the app replaces its screen state with it; it
    used to get only {entry_id} and blanked the screen)."""
    def post(self, request, day):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        dd = _cashbox_day(day)
        if dd is None:
            return _bad_day(lang)
        try:
            e = khata.cash_entry(request.data.get("kind"),
                                 request.data.get("amount"),
                                 note=request.data.get("note", ""), at=_now_iso(),
                                 ref=request.data.get("ref"))
        except ValueError as ex:
            return _err(lang, "এন্ট্রি ভুল।", "Invalid entry.", status=422,
                        code="invalid_cash_entry", reason=str(ex))
        from .models import CashEntry
        cb = _cashbox_row(prof, dd[0])
        obj = CashEntry.objects.create(
            day=cb, kind=e["kind"], amount_poisha=e["amount"],
            note=(e["note"] or "")[:200], ref=(e.get("ref") or "")[:60],
            at=timezone.now())
        out = _cashbox_payload(request, prof, day, lang, cb=cb)
        out["entry_id"] = obj.id
        return Response(out, status=201)


class CashboxReconcileView(APIView):
    """POST cashbox/<day>/reconcile {counted} — the day close. Can be done
    again (re-count); returns the payload with counted + variance."""
    def post(self, request, day):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        dd = _cashbox_day(day)
        if dd is None:
            return _bad_day(lang)
        raw = request.data.get("counted")
        counted = khata.to_poisha(raw) if isinstance(raw, str) else raw
        try:
            counted = int(counted)
        except (TypeError, ValueError):
            counted = -1
        if counted < 0:
            return _err(lang, "গোনা টাকা ভুল।", "Invalid counted amount.",
                        status=422, code="bad_counted")
        cb = _cashbox_row(prof, dd[0])
        cb.counted_poisha = counted
        cb.reconciled_at = timezone.now()
        cb.save(update_fields=["counted_poisha", "reconciled_at"])
        return Response(_cashbox_payload(request, prof, day, lang, cb=cb))


# ===========================================================================
# AI SALES ASSISTANT (§4) — all PAID + mostly key-gated
# ===========================================================================

class AiReplyView(APIView):
    """POST ai/reply — PAID; LLM key-gated (else deterministic mock)."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate       # PLAN GATE
        lang = req_lang(request)
        catalog = [{"name": p.name, "price": str(p.price), "stock": p.stock,
                    "min_price": str(p.min_price), "description": p.description}
                   for p in request.user.products.all()]
        pol = prof.policies.first() if hasattr(prof, "policies") else None
        delivery = ({"inside_dhaka": str(pol.delivery_inside),
                     "outside_dhaka": str(pol.delivery_outside),
                     "free_over": str(pol.free_delivery_over or "")}
                    if pol else None)
        policies = ({"returns": pol.returns, "hours": pol.hours,
                     "payment": pol.payment_note} if pol else None)
        ctx = bai.build_context(catalog=catalog, delivery=delivery,
                                policies=policies, shop_name=prof.shop_name,
                                style=prof.style_sample, lang=lang)
        key = _ai_key()
        state = {}
        # credit-leak fix: the AI reply is charged to the SHOP OWNER's credits
        # through billing (ai.generate user=...), like every other AI call.
        provider = _llm_provider(prof.user, state) if key else None   # LIVE KEY gate
        res = bai.draft_reply(request.data.get("text", ""), ctx,
                              reply_provider=provider, ai_key=key or None,
                              owner_takeover=bool(request.data.get("owner_takeover")))
        if state.get("credits"):
            from . import credits_out
            need = credits_out.need_for_tier(prof.user, "cheap")
            if credits_out.supported(request):
                return credits_out.response(prof.user, lang, need)
            # older app: the honest rule-based draft + the honest line
            res = bai.draft_reply(request.data.get("text", ""), ctx,
                                  reply_provider=None, ai_key=None,
                                  owner_takeover=bool(request.data.get("owner_takeover")))
            res["credits_out"] = True
            res["credits_message"] = credits_out.body(prof.user, lang, need)["message"]
        res["mock"] = not res.get("used_ai")
        return Response(res)


def ai_reply_task(prompt):
    """aieval: the trusted instruction for the shop's AI draft. Before this the
    model got ONLY the facts list as its instruction (no rules at all)."""
    lang = "Bangla (Bengali script)" if prompt.get("lang") == "bn" else "English"
    return ("You are the polite assistant (an AI, not a human) of the shop \"%s\" in "
            "Bangladesh. Reply to the customer's message in %s, in at most 3 short "
            "sentences, using ONLY the FACTS below. Never state a price, stock count, "
            "delivery charge or discount that is not written in the FACTS, never promise "
            "a refund, and never ask for a PIN or password. If the FACTS do not answer "
            "the question, say someone from the shop will reply.\n\nFACTS:\n%s"
            % (prompt.get("shop_name") or "shop", lang,
               prompt.get("facts") or "(no catalog yet)"))


def _llm_provider(user=None, state=None):
    """Adapter: prompt dict → {text, confidence} via core.ai. MUST NOT invent
    price/stock (the pure layer only passes it the context facts). `user` is
    charged (credits + Profit Guard); out of credits sets state["credits"]."""
    from . import ai

    def provider(prompt):
        try:
            text, _ = ai.generate(task=ai_reply_task(prompt),
                                  data=prompt.get("customer_text", ""),
                                  tier="cheap", feature="business.ai_reply",
                                  max_tokens=300, user=user,
                                  pii=True)     # AF-2: customer text masked
            return {"text": text, "confidence": 0.8}
        except ai.AIUnavailable as e:
            if state is not None and e.reason == "credits":
                state["credits"] = True
            return {"text": "", "confidence": 0.0}
        except Exception:
            return {"text": "", "confidence": 0.0}
    return provider


class AiBargainView(APIView):
    """POST ai/bargain — PAID; NO key (pure arithmetic, never AI). Minimum price
    is the enforced floor: below-min → defer_to_owner (never a sub-min price)."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        lang = req_lang(request)
        p = request.user.products.filter(pk=request.data.get("product")).first()
        if not p:
            return _err(lang, "পণ্য পাওয়া যায়নি।", "Product not found.", status=404)
        from .models import BargainRule
        br = BargainRule.objects.filter(product=p).first()
        rules = ({"discount_steps": br.discount_steps,
                  "free_delivery_over": str(br.free_delivery_over) if br.free_delivery_over else None,
                  "bundle_min_qty": br.bundle_min_qty} if br else None)
        res = bai.negotiate(request.data.get("offer"),
                            {"name": p.name, "price": str(p.price),
                             "min_price": str(p.min_price)}, rules=rules, lang=lang)
        # serialise Decimal → str for JSON
        res["price"] = str(res["price"]) if res["price"] is not None else None
        res["min_price"] = str(res["min_price"])
        res["list_price"] = str(res["list_price"])
        res["offer"] = str(res["offer"]) if res["offer"] is not None else None
        return Response(res)


class AiDiscloseView(APIView):
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        return Response(bai.assistant_disclosure(req_lang(request)))


class OrderAdvanceView(APIView):
    """POST orders/<id>/advance — FREE (status). 'shipped' booking is courier
    key-gated: without a key book_courier_mock → live=False (no fabrication)."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        o = request.user.orders.filter(pk=pk).first()
        if not o:
            return _err(lang, "অর্ডার পাওয়া যায়নি।", "Order not found.", status=404)
        try:
            new, event = bai.advance_order(
                _order_dict(o), request.data.get("target"),
                courier=request.data.get("courier"),
                courier_keys=_courier_keys(), lang=lang)   # LIVE KEY gate
        except ValueError as e:
            return _err(lang, "অবৈধ পরিবর্তন।", "Invalid transition.", status=422,
                        code="illegal_transition", reason=str(e))
        o.status = new["status"]
        if new.get("courier"):
            o.courier = new["courier"]
            o.tracking = new.get("tracking", "")
            o.courier_live = new.get("courier_live", False)
            from .models import CourierShipment
            CourierShipment.objects.create(
                order=o, courier=new["courier"], tracking=o.tracking,
                live=o.courier_live, cod_amount=bai.cod_amount(_order_dict(o)))
        o.save()
        event["courier_live"] = o.courier_live
        return Response({"order": _order_dict(o), "event": event,
                         "mock": (not o.courier_live) if new.get("courier") else False})


class OrderParcelView(APIView):
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        o = request.user.orders.filter(pk=pk).first()
        if not o:
            return _err(req_lang(request), "অর্ডার পাওয়া যায়নি।",
                        "Order not found.", status=404)
        return Response(bai.parcel_status(_order_dict(o), req_lang(request)))


class OrdersListView(APIView):
    """GET orders — the requester's orders, newest first (FREE, scoped)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        rows = []
        for o in request.user.orders.all().order_by("-created_at"):
            d = _order_dict(o)
            d["customer_name"] = o.customer_name
            d["cod_amount"] = str(bai.cod_amount(_order_dict(o)))
            d["created_at"] = o.created_at.isoformat()
            rows.append(d)
        return Response({"orders": rows})


class OrderDetailView(APIView):
    """GET orders/<id> — one order (items + courier/tracking). FREE, scoped."""
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        o = request.user.orders.filter(pk=pk).first()
        if not o:
            return _err(req_lang(request), "অর্ডার পাওয়া যায়নি।",
                        "Order not found.", status=404)
        d = _order_dict(o)
        d["customer_name"] = o.customer_name
        d["customer_phone"] = o.customer_phone
        d["address"] = o.address
        d["items"] = o.items
        d["channel"] = o.channel
        d["cod_amount"] = str(bai.cod_amount(_order_dict(o)))
        d["created_at"] = o.created_at.isoformat()
        d["parcel"] = bai.parcel_status(_order_dict(o), req_lang(request))
        return Response(d)


class PoliciesView(APIView):
    """GET/POST policies — the shop's OwnerPolicy (delivery/returns/hours). FREE;
    feeds AI context. Owner-only to WRITE (staff can read for context)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        pol = prof.policies.first() if hasattr(prof, "policies") else None
        if not pol:
            return Response({"delivery_inside": "0", "delivery_outside": "0",
                             "free_delivery_over": None, "returns": "",
                             "hours": "", "payment_note": ""})
        return Response(self._shape(pol))

    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        from .models import OwnerPolicy
        d = request.data
        pol = prof.policies.first() if hasattr(prof, "policies") else None
        if pol is None:
            pol = OwnerPolicy(user=request.user, business=prof)
        if "delivery_inside" in d:
            pol.delivery_inside = d.get("delivery_inside") or 0
        if "delivery_outside" in d:
            pol.delivery_outside = d.get("delivery_outside") or 0
        if "free_delivery_over" in d:
            pol.free_delivery_over = d.get("free_delivery_over") or None
        if "returns" in d:
            pol.returns = d.get("returns") or ""
        if "hours" in d:
            pol.hours = d.get("hours") or ""
        if "payment_note" in d:
            pol.payment_note = d.get("payment_note") or ""
        pol.save()
        return Response(self._shape(pol), status=201)

    @staticmethod
    def _shape(pol):
        return {"delivery_inside": str(pol.delivery_inside),
                "delivery_outside": str(pol.delivery_outside),
                "free_delivery_over": (str(pol.free_delivery_over)
                                       if pol.free_delivery_over is not None else None),
                "returns": pol.returns, "hours": pol.hours,
                "payment_note": pol.payment_note}


class MorningSummaryView(APIView):
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        lang = req_lang(request)
        since = timezone.now() - timedelta(hours=16)
        from .models import Message, Order
        msgs = list(Message.objects.filter(
            thread__user=request.user, direction="in", created_at__gte=since))
        orders = list(request.user.orders.filter(created_at__gte=since))
        needs = [m for m in msgs if m.needs_human]
        return Response(bai.morning_summary(msgs, orders, needs, lang))


class OutboundPlanView(APIView):
    """POST outbound/plan — PAID; CHANNEL GUARD + 24h window + paid-template."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        lang = req_lang(request)
        try:
            plan = bai.outbound_message_plan(
                request.data.get("channel"),
                request.data.get("last_inbound_ts"),
                timezone.now().timestamp(),
                template_name=request.data.get("template"))
        except bai.PersonalWhatsAppBanned as e:   # CHANNEL GUARD
            return _err(lang, "ব্যক্তিগত হোয়াটসঅ্যাপ অটোমেশন অনুমোদিত নয়।",
                        str(e), status=400, code="personal_whatsapp_banned")
        except ValueError as e:
            return _err(lang, "অজানা চ্যানেল।", str(e), status=400,
                        code="bad_channel")
        return Response(plan)


class WebhookSendView(APIView):
    """POST webhook/send (internal) — PAID; CHANNEL GUARD. Assembles the Graph
    payload only; Meta token key-gated (needs_key=True, we never send here)."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        lang = req_lang(request)
        try:
            desc = bai.assemble_webhook_send(   # CHANNEL GUARD inside
                request.data.get("channel"), request.data.get("to"),
                text=request.data.get("text"),
                template_name=request.data.get("template"),
                last_inbound_ts=request.data.get("last_inbound_ts"),
                now_ts=timezone.now().timestamp())
        except bai.PersonalWhatsAppBanned as e:
            return _err(lang, "ব্যক্তিগত হোয়াটসঅ্যাপ অটোমেশন অনুমোদিত নয়।",
                        str(e), status=400, code="personal_whatsapp_banned")
        except ValueError as e:
            return _err(lang, "অজানা চ্যানেল।", str(e), status=400,
                        code="bad_channel")
        # LIVE KEY: a Meta token is required to actually POST to Graph
        desc["has_meta_key"] = bool(_meta_token())
        desc["mock"] = not desc["has_meta_key"]
        return Response(desc)


class WebhookIncomingView(APIView):
    """POST webhook/incoming (Meta callback) — official channels only. Verifies
    the hub handshake (GET), records inbound + drafts an AI reply (PAID)."""
    permission_classes = [AllowAny]

    def get(self, request):
        from . import integrations
        cfg = integrations.get("whatsapp")
        if (request.query_params.get("hub.mode") == "subscribe"
                and request.query_params.get("hub.verify_token") == cfg.get("verify_token")):
            from django.http import HttpResponse
            return HttpResponse(request.query_params.get("hub.challenge", ""))
        from django.http import HttpResponse
        return HttpResponse("forbidden", status=403)

    def post(self, request):
        from . import integrations
        if not integrations.is_enabled("whatsapp"):
            return Response({"ok": True, "note": "whatsapp not connected",
                             "mock": True})
        # Official channel only — store inbound. (Drafting reuses AiReplyView.)
        return Response({"ok": True})


class VoiceEntryView(APIView):
    """POST ai/voice-entry — PAID; transcription key-gated (text already
    transcribed here). Returns a DRAFT (needs_review) — nothing is written."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ledger_ai_addons")
        if gate:
            return gate
        res = bai.voice_entry_parse(request.data.get("text", ""),
                                    now=_now_iso(), lang=req_lang(request))
        res["mock"] = res.get("transcription_mock", True)
        return Response(res)


class PaperKhataView(APIView):
    """POST ai/paper-khata — PAID; OCR/vision key-gated (mock_rows simulate it).
    Returns DRAFTS (needs_review) — nothing auto-saved."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ledger_ai_addons")
        if gate:
            return gate
        res = bai.paper_khata_parse(request.data.get("mock_rows"),
                                    lang=req_lang(request))
        res["mock"] = res.get("ocr_mock", True)
        return Response(res)


class MatchPaymentView(APIView):
    """POST ai/match-payment — PAID; no key. NEVER auto-deducts (owner confirms).
    We never hold funds — reconciles owner's OWN records vs OWN wallet notif."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ledger_ai_addons")
        if gate:
            return gate
        lang = req_lang(request)
        open_dues = []
        for p in prof.khata_parties.filter(book=khata.CUSTOMER, archived=False):
            bal = _party_balance(p)
            if bal > 0:
                open_dues.append({"id": p.id, "name": p.name, "phone": p.phone,
                                  "amount": selling.poisha_to_taka(bal)})
        res = bai.match_payment_to_due(request.data.get("notification", ""),
                                       open_dues, lang=lang)
        return Response(res)


class InsightsView(APIView):
    """GET ai/insights — PAID; rules only (NO AI)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "reports")
        if gate:
            return gate
        # records built from recent sales/dues (rules decide the flags)
        records = {"sales_by_product": {}, "dues": []}
        for p in prof.khata_parties.filter(book=khata.CUSTOMER, archived=False):
            bal = _party_balance(p)
            if bal > 0:
                first = p.entries.order_by("at").first()
                age = (timezone.now() - first.at).days if first else 0
                records["dues"].append({"name": p.name, "age_days": age,
                                        "amount": selling.poisha_to_taka(bal)})
        return Response({"insights": bai.insights(records, lang=req_lang(request))})


# ---- AI chat inbox + channels + bargain rules (all PAID + key-gated mock) --

class AiChannelsView(APIView):
    """GET ai/channels — connected OFFICIAL channels + needs-key state. PAID.
    Reads the owner's integration config (whatsapp Cloud + messenger); a channel
    is 'connected' only when its live key/token is present (else needs_key)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent", read_ok=True)
        if gate:
            return gate
        from . import integrations
        wa = integrations.get("whatsapp")
        fb = integrations.get("messenger")
        wa_tok = wa.get("access_token") or ""
        fb_tok = fb.get("access_token") or fb.get("page_token") or ""
        return Response({
            "whatsapp_cloud": {"connected": bool(wa_tok),
                               "needs_key": not bool(wa_tok),
                               "number": wa.get("phone_number") or None},
            "messenger": {"connected": bool(fb_tok),
                          "needs_key": not bool(fb_tok),
                          "page": fb.get("page_name") or None},
        })


def _thread_row(t):
    last = t.messages.order_by("-created_at").first()
    unread = t.messages.filter(direction="in", needs_human=True).count()
    return {"id": t.id, "customer_phone": t.customer_phone,
            "customer_name": t.customer_phone, "channel": t.channel,
            "last_inbound_at": t.last_inbound_at.isoformat() if t.last_inbound_at else None,
            "owner_takeover": t.owner_takeover, "lang": t.lang,
            "unread": unread,
            "last_text": (last.text if last else ""),
            "needs_human": bool(last and last.needs_human)}


class AiThreadsView(APIView):
    """GET ai/threads — official-channel conversations list. PAID."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent", read_ok=True)
        if gate:
            return gate
        rows = [_thread_row(t) for t in request.user.chat_threads.all()]
        return Response({"threads": rows})


class AiThreadDetailView(APIView):
    """GET ai/threads/<id> — thread + its messages. PAID."""
    def get(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent", read_ok=True)
        if gate:
            return gate
        t = request.user.chat_threads.filter(pk=pk).first()
        if not t:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        msgs = [{"id": m.id, "direction": m.direction, "text": m.text,
                 "is_ai": m.is_ai, "confidence": m.confidence,
                 "needs_human": m.needs_human, "handoff_reason": m.handoff_reason,
                 "created_at": m.created_at.isoformat()}
                for m in t.messages.all()]
        return Response({"thread": _thread_row(t), "messages": msgs})


class AiThreadTakeoverView(APIView):
    """POST ai/threads/<id>/takeover {on} — owner takes over / hands back. PAID.
    While on, the AI drafts nothing (only the owner's typed replies go out)."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        t = request.user.chat_threads.filter(pk=pk).first()
        if not t:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        t.owner_takeover = bool(request.data.get("on", True))
        t.save(update_fields=["owner_takeover"])
        return Response({"owner_takeover": t.owner_takeover})


class AiThreadSendView(APIView):
    """POST ai/threads/<id>/send {text, from_ai?} — queue the owner's approved
    reply. PAID; Meta token KEY-gated: without a token the message is recorded
    as queued/mock (needs_key=True) — we never POST to Graph without a key."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        lang = req_lang(request)
        t = request.user.chat_threads.filter(pk=pk).first()
        if not t:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        text = (request.data.get("text") or "").strip()
        if not text:
            return _err(lang, "বার্তা খালি।", "Message is empty.", status=422,
                        code="empty_message")
        from .models import Message
        msg = Message.objects.create(
            thread=t, direction="out", text=text,
            is_ai=bool(request.data.get("from_ai")))
        has_key = bool(_meta_token())
        return Response({"sent": has_key, "needs_key": not has_key,
                         "mock": not has_key, "message_id": msg.id}, status=201)


class BargainRulesView(APIView):
    """GET bargain/rules — per-product bargaining ladders. PAID. min_price is the
    READ-ONLY floor from the Product (never writable through bargaining)."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent", read_ok=True)
        if gate:
            return gate
        from .models import BargainRule
        rows = []
        for p in request.user.products.all():
            br = BargainRule.objects.filter(product=p).first()
            rows.append({
                "product_id": p.id, "name": p.name,
                "list_price": str(p.price), "min_price": str(p.min_price),
                "discount_steps": br.discount_steps if br else [],
                "free_delivery_over": (str(br.free_delivery_over)
                                       if br and br.free_delivery_over is not None else None),
                "bundle_min_qty": br.bundle_min_qty if br else None,
            })
        return Response({"rules": rows})


class BargainRuleSaveView(APIView):
    """POST bargain/rules/<product_pk> — save a per-product ladder. PAID, owner.
    min_price is NOT accepted here: it is the Product's enforced floor and is
    ignored even if sent, so bargaining can never lower it."""
    def post(self, request, pk):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "ai_sales_agent")
        if gate:
            return gate
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        p = request.user.products.filter(pk=pk).first()
        if not p:
            return _err(lang, "পণ্য পাওয়া যায়নি।", "Product not found.", status=404)
        from .models import BargainRule
        d = request.data
        br, _ = BargainRule.objects.get_or_create(product=p)
        if "discount_steps" in d:
            br.discount_steps = d.get("discount_steps") or []
        if "free_delivery_over" in d:
            br.free_delivery_over = d.get("free_delivery_over") or None
        if "bundle_min_qty" in d:
            br.bundle_min_qty = d.get("bundle_min_qty") or None
        br.save()
        return Response({
            "product_id": p.id, "name": p.name,
            "list_price": str(p.price), "min_price": str(p.min_price),  # read-only floor
            "discount_steps": br.discount_steps,
            "free_delivery_over": (str(br.free_delivery_over)
                                   if br.free_delivery_over is not None else None),
            "bundle_min_qty": br.bundle_min_qty,
        }, status=201)


class BankLoanReportView(APIView):
    """GET reports/bank-loan — PAID; DATA ONLY. NO lending / NO credit scoring."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        gate = _plan_gate(request, prof, "reports")
        if gate:
            return gate
        from .models import Sale
        rows = []
        for s in Sale.objects.filter(user=request.user, business=prof,
                                     voided_at__isnull=True):
            rows.append({"month": s.created_at.strftime("%Y-%m"),
                         "amount": selling.poisha_to_taka(s.total)})
        return Response(bai.bank_loan_report_data(rows, lang=req_lang(request)))


class MerchantQrView(APIView):
    """GET payments/qr — FREE; owner's OWN merchant. NEVER a balance/custody."""
    def get(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        w = prof.wallets.first() if hasattr(prof, "wallets") else None
        if not w:
            return Response({"error": "needs_setup", "mock": True,
                             "detail": pick(lang,
                                            "মার্চেন্ট ওয়ালেট যুক্ত করা হয়নি।",
                                            "No merchant wallet configured yet.")},
                            status=200)
        return Response(bai.merchant_qr_descriptor(
            {"provider": w.provider, "merchant_number": w.merchant_number,
             "merchant_name": w.merchant_name}, lang))

    # m2-reality: the Payments screen saves the owner's merchant POINTER here
    # (was 405). Never a balance; we never hold funds.
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        guard = _owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        from .models import OwnerWallet
        d = request.data
        provider = str(d.get("provider", "")).strip().lower()
        number = str(d.get("merchant_number", "")).strip()[:40]
        if provider not in ("bkash", "nagad") or not number:
            return _err(lang, "প্রোভাইডার ও মার্চেন্ট নম্বর দিন।",
                        "Choose a provider and enter the merchant number.",
                        status=422, code="invalid_wallet")
        w = prof.wallets.first()
        if w is None:
            w = OwnerWallet(user=request.user, business=prof)
        w.provider, w.merchant_number = provider, number
        w.merchant_name = str(d.get("merchant_name", "")).strip()[:120]
        w.save()
        return Response(bai.merchant_qr_descriptor(
            {"provider": w.provider, "merchant_number": w.merchant_number,
             "merchant_name": w.merchant_name}, lang), status=201)


class PaymentLinkView(APIView):
    """POST payments/link — licensed-partner key-gated. We NEVER hold funds."""
    def post(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        o = request.user.orders.filter(pk=request.data.get("order")).first()
        if not o:
            return _err(lang, "অর্ডার পাওয়া যায়নি।", "Order not found.", status=404)
        key = _payment_partner_key()     # LIVE KEY gate
        res = bai.payment_link_builder({"id": o.id, "total": str(o.total)},
                                       partner_key=key or None, lang=lang)
        res["mock"] = not res.get("live")
        return Response(res)
