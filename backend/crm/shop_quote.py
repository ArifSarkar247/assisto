"""crm100 — shop price quotes: build from the seller's OWN catalog, share a
public signed link (/q/<token>, no login), the customer accepts or declines.

Rules (owner final order 27 Oct, "quote → accept page"):
  * Prices come from core.Product / ProductVariant only. The client sends
    product ids, variant keys and quantities; a per-line price is optional
    and may never go below the line's minimum price (the seller's own
    bargaining floor, business_selling._price_for).
  * A whole-quote discount may never push the total below the sum of the
    line minimums (business_selling.apply_cart_discount) — refused, not
    silently clamped, so the seller sees why.
  * Validity 1..30 days. Past `valid_until` the quote is EXPIRED: the page
    says so and accepting is impossible; the seller can extend it.
  * Accept = ONE core.Order (status "new" for the seller to pack), stock
    taken atomically (never below 0; out of stock → nothing is created),
    payment COD / bKash / Nagad / already paid. Accepting twice returns the
    same order (idempotent, row lock). The seller gets a push.
  * The link is <nonce>.<signature> (django.core.signing, own salt): a
    guessed or edited link fails the signature check before any DB lookup.

Money is integer poisha everywhere here; core.Order stores taka Decimals.
"""
import secrets
from datetime import timedelta
from decimal import Decimal

from django.core import signing
from django.db import transaction
from django.utils import timezone

SALT = "crm.shopquote.v1"
MAX_LINES = 30
MAX_QTY = 999
MIN_DAYS, MAX_DAYS, DEFAULT_DAYS = 1, 30, 3
MAX_DELIVERY_POISHA = 10_000_00          # ৳10,000
PAYMENTS = ("cod", "bkash", "nagad", "paid")
OPEN_STATES = ("issued", "viewed")


class QuoteError(Exception):
    """A refusal the API turns into a 400 with a stable `code`."""

    def __init__(self, code, **extra):
        super().__init__(code)
        self.code = code
        self.extra = extra


# ------------------------------------------------------------------ token
def _signer():
    return signing.Signer(salt=SALT, sep=".")


def new_nonce():
    return secrets.token_urlsafe(18)          # 144 bits


def token_for(nonce):
    return _signer().sign(nonce)


def nonce_from(token):
    """The nonce of a valid link, else None (bad / edited / guessed)."""
    try:
        val = _signer().unsign(str(token or "")[:120])
    except signing.BadSignature:
        return None
    return val or None


def public_path(quote):
    return "/q/" + token_for(quote.nonce)


# ------------------------------------------------------------------ helpers
def _p(v):
    from core.logic.business_selling import taka_to_poisha
    return taka_to_poisha(v)


def _variant_rows(product):
    """[(vkey, size, colour, sell_p, min_p, stock)] — the base row when the
    product has no variants (same as business_views._product_dict)."""
    vs = list(product.variants.all())
    if vs:
        return [(v.vkey, v.size, v.colour, _p(v.sell_price), _p(v.min_price), v.stock)
                for v in vs]
    return [("", "", "", _p(product.price), _p(product.min_price), product.stock)]


def _int(v, default=0):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def price_lines(prof, raw_items):
    """Validate + price the requested lines from the seller's catalog.
    Returns (lines, subtotal_p, floor_p, warnings). Raises QuoteError."""
    from core.models import Product
    if not isinstance(raw_items, list) or not raw_items:
        raise QuoteError("no_items")
    if len(raw_items) > MAX_LINES:
        raise QuoteError("too_many_items", max=MAX_LINES)
    ids = [_int((r or {}).get("product_id")) for r in raw_items if isinstance(r, dict)]
    products = {p.id: p for p in Product.objects.filter(
        user=prof.user, pk__in=[i for i in ids if i > 0]).prefetch_related("variants")}
    lines, subtotal, floor, warnings = [], 0, 0, []
    for idx, r in enumerate(raw_items):
        r = r if isinstance(r, dict) else {}
        p = products.get(_int(r.get("product_id")))
        if p is None or (p.business_id not in (None, prof.id)):
            raise QuoteError("unknown_product", line=idx)
        qty = _int(r.get("qty"), 1)
        if qty < 1 or qty > MAX_QTY:
            raise QuoteError("bad_qty", line=idx)
        rows = _variant_rows(p)
        want = str(r.get("variant") or r.get("vkey") or "")
        row = next((x for x in rows if x[0] == want), None)
        if row is None:
            if len(rows) == 1 and not want:
                row = rows[0]
            else:
                raise QuoteError("unknown_variant", line=idx)
        vkey, size, colour, sell_p, min_p, stock = row
        if sell_p <= 0:
            raise QuoteError("no_price", line=idx)
        unit = sell_p
        override = r.get("unit_price")
        if override not in (None, ""):
            ov = _p(override)
            if ov <= 0:
                raise QuoteError("bad_price", line=idx)
            if ov < min_p:
                raise QuoteError("below_min", line=idx)
            unit = ov
        if stock < qty:
            warnings.append({"code": "low_stock", "line": idx, "stock": max(0, stock)})
        name = p.name + ((" " + " ".join(x for x in (size, colour) if x)) if (size or colour) else "")
        lines.append({"product_id": p.id, "variant": vkey, "name": name[:160],
                      "size": size, "colour": colour, "qty": qty,
                      "unit_poisha": unit, "list_poisha": sell_p})
        subtotal += unit * qty
        floor += min_p * qty
    return lines, subtotal, floor, warnings


def build(prof, user, data, now=None):
    """Create a ShopQuote from request data. Raises QuoteError."""
    from core.logic.business_selling import normalize_phone
    from .models import Lead, ShopQuote
    now = now or timezone.now()
    lines, subtotal, floor, warnings = price_lines(prof, data.get("items"))
    disc = max(0, _p(data.get("discount") or 0))
    max_disc = max(0, subtotal - floor)
    if disc > max_disc:
        raise QuoteError("discount_too_big", max_poisha=max_disc)
    delivery = max(0, _p(data.get("delivery") or 0))
    if delivery > MAX_DELIVERY_POISHA:
        raise QuoteError("bad_delivery")
    days = _int(data.get("valid_days"), DEFAULT_DAYS)
    if days < MIN_DAYS or days > MAX_DAYS:
        raise QuoteError("bad_validity", min=MIN_DAYS, max=MAX_DAYS)
    payment = str(data.get("payment") or "cod")
    if payment not in PAYMENTS:
        raise QuoteError("bad_payment")
    phone = str(data.get("customer_phone") or "").strip()[:40]
    lead = None
    if data.get("lead"):
        lead = Lead.objects.filter(pk=_int(data.get("lead")),
                                   org__members__user=user).first()
    lang = "en" if data.get("lang") == "en" else "bn"
    q = ShopQuote.objects.create(
        business=prof, created_by=user, lead=lead,
        customer_name=str(data.get("customer_name") or "").strip()[:120],
        customer_phone=phone, phone_key=normalize_phone(phone), lang=lang,
        items=lines, subtotal_poisha=subtotal, discount_poisha=disc,
        delivery_poisha=delivery, total_poisha=subtotal - disc + delivery,
        payment=payment, note=str(data.get("note") or "").strip()[:300],
        valid_until=now + timedelta(days=days), nonce=new_nonce())
    return q, warnings


def effective_state(q, now=None):
    """The state with expiry applied (issued/viewed past valid_until →
    expired). Persists the change so the seller's list agrees."""
    now = now or timezone.now()
    if q.state in OPEN_STATES and q.valid_until <= now:
        type(q).objects.filter(pk=q.pk, state__in=OPEN_STATES).update(state="expired")
        q.state = "expired"
    return q.state


def mark_viewed(q, now=None):
    now = now or timezone.now()
    if effective_state(q, now) == "issued":
        n = type(q).objects.filter(pk=q.pk, state="issued").update(state="viewed",
                                                                   viewed_at=now)
        if n:
            q.state, q.viewed_at = "viewed", now
    return q


def _order_items(q):
    return [{"product_id": it["product_id"], "name": it["name"], "qty": it["qty"],
             "price": str(Decimal(it["unit_poisha"]) / 100), "variant": it.get("variant", ""),
             "source": "quote"} for it in (q.items or [])]


def accept(q, name="", address="", now=None):
    """Customer accepts. Returns the core.Order. Idempotent. Raises
    QuoteError: expired | not_open | out_of_stock (with the item name)."""
    from core import bizagent_service as BS
    from .models import ShopQuote
    now = now or timezone.now()
    err = None
    order = None
    with transaction.atomic():
        locked = ShopQuote.objects.select_for_update().get(pk=q.pk)
        if locked.state == ShopQuote.ACCEPTED and locked.order_id:
            return locked.order
        if locked.state in OPEN_STATES and locked.valid_until <= now:
            locked.state = ShopQuote.EXPIRED
            locked.save(update_fields=["state", "updated_at"])
            err = QuoteError("expired")
        elif locked.state not in OPEN_STATES:
            err = QuoteError("not_open", state=locked.state)
        else:
            items = _order_items(locked)
            sid = transaction.savepoint()
            for it in items:
                if not BS._decrement_stock(it):
                    transaction.savepoint_rollback(sid)
                    err = QuoteError("out_of_stock", item=it["name"])
                    break
            if err is None:
                transaction.savepoint_commit(sid)
                order = _create_order(locked, name, address, items, now)
    if err is not None:
        raise err
    _notify_seller(locked, order)
    return order


def _create_order(locked, name, address, items, now):
    from core.models import Customer, Order
    from core.logic.business_selling import normalize_phone
    prof = locked.business
    pay = locked.payment
    order = Order.objects.create(
        user=prof.user, business=prof,
        customer_name=(name or locked.customer_name)[:120],
        customer_phone=locked.customer_phone, address=(address or "")[:600],
        items=items, total=Decimal(locked.total_poisha) / 100,
        delivery_charge=Decimal(locked.delivery_poisha) / 100,
        status="new", payment=pay,
        payment_status="verified" if pay == "paid" else "",
        channel="quote")
    locked.state = "accepted"
    locked.decided_at = now
    locked.order = order
    locked.accept_name = (name or "")[:120]
    locked.accept_address = (address or "")[:600]
    locked.save(update_fields=["state", "decided_at", "order", "accept_name",
                               "accept_address", "updated_at"])
    key = normalize_phone(locked.customer_phone)
    if key and not Customer.objects.filter(user=prof.user, business=prof,
                                           phone_key=key).exists():
        Customer.objects.create(user=prof.user, business=prof,
                                name=(name or locked.customer_name)[:120],
                                phone=locked.customer_phone, phone_key=key,
                                address=(address or "")[:600])
    return order


def decline(q, reason="", now=None):
    from .models import ShopQuote
    now = now or timezone.now()
    err = None
    with transaction.atomic():
        locked = ShopQuote.objects.select_for_update().get(pk=q.pk)
        if locked.state == ShopQuote.DECLINED:
            return locked
        if locked.state in OPEN_STATES and locked.valid_until <= now:
            locked.state = ShopQuote.EXPIRED
            locked.save(update_fields=["state", "updated_at"])
            err = QuoteError("expired")
        elif locked.state not in OPEN_STATES:
            err = QuoteError("not_open", state=locked.state)
        else:
            locked.state = ShopQuote.DECLINED
            locked.decided_at = now
            locked.decline_reason = str(reason or "").strip()[:200]
            locked.save(update_fields=["state", "decided_at", "decline_reason",
                                       "updated_at"])
    if err is not None:
        raise err
    _notify_seller(locked, None)
    return locked


def extend(q, days, now=None):
    """Seller: a new validity window from now (also re-opens an expired
    quote). Accepted / declined / revoked quotes cannot be re-opened."""
    now = now or timezone.now()
    days = _int(days, DEFAULT_DAYS)
    if days < MIN_DAYS or days > MAX_DAYS:
        raise QuoteError("bad_validity", min=MIN_DAYS, max=MAX_DAYS)
    effective_state(q, now)
    if q.state not in OPEN_STATES + ("expired",):
        raise QuoteError("not_open", state=q.state)
    q.valid_until = now + timedelta(days=days)
    if q.state == "expired":
        q.state = "viewed" if q.viewed_at else "issued"
    q.save(update_fields=["valid_until", "state", "updated_at"])
    return q


def revoke(q):
    from .models import ShopQuote
    n = ShopQuote.objects.filter(pk=q.pk, state__in=OPEN_STATES + ("expired",)).update(
        state=ShopQuote.REVOKED, updated_at=timezone.now())
    if not n:
        raise QuoteError("not_open", state=q.state)
    q.state = ShopQuote.REVOKED
    return q


def _notify_seller(q, order):
    """A push to the shop owner (and the staff member who made the quote).
    Best effort: a push failure never undoes the customer's decision."""
    try:
        from core import push
        from core.logic.business_khata import taka_str
        who = q.accept_name or q.customer_name or q.customer_phone or ""
        amt_bn = "৳" + taka_str(q.total_poisha, "bn")
        amt_en = "৳" + taka_str(q.total_poisha, "en")
        if order is not None:
            t_bn, t_en = "দামের প্রস্তাব গ্রহণ হয়েছে", "Quote accepted"
            b_bn = "%s %s-এর প্রস্তাব গ্রহণ করেছেন — নতুন অর্ডার এসেছে।" % (who, amt_bn)
            b_en = "%s accepted the %s quote — a new order is in." % (who, amt_en)
        else:
            t_bn, t_en = "দামের প্রস্তাব ফিরিয়ে দিয়েছেন", "Quote declined"
            b_bn = "%s %s-এর প্রস্তাব নেননি।" % (who, amt_bn)
            b_en = "%s declined the %s quote." % (who, amt_en)
        data = {"type": "crm_quote", "quote": str(q.pk),
                "order": str(order.pk) if order is not None else ""}
        users = [q.business.user]
        if q.created_by_id and q.created_by_id != q.business.user_id:
            users.append(q.created_by)
        for u in users:
            push.push_to_user_async(u, "shop_alert", t_bn, t_en, b_bn, b_en, data=data)
    except Exception:  # noqa: BLE001
        pass


def as_dict(q, now=None, role="owner"):
    st = effective_state(q, now)
    return {"id": q.id, "state": st, "customer_name": q.customer_name,
            "customer_phone": q.customer_phone, "lead": q.lead_id, "lang": q.lang,
            "items": [{k: v for k, v in it.items()} for it in (q.items or [])],
            "subtotal_poisha": q.subtotal_poisha, "discount_poisha": q.discount_poisha,
            "delivery_poisha": q.delivery_poisha, "total_poisha": q.total_poisha,
            "payment": q.payment, "note": q.note,
            "valid_until": q.valid_until.isoformat(),
            "created_at": q.created_at.isoformat() if q.created_at else None,
            "viewed_at": q.viewed_at.isoformat() if q.viewed_at else None,
            "decided_at": q.decided_at.isoformat() if q.decided_at else None,
            "decline_reason": q.decline_reason, "order": q.order_id,
            "path": public_path(q)}
