"""
business_selling.py — pure, unit-testable SELLING logic for Assisto Business v2.

NO Django imports. Every function takes plain dicts / ints / strings so the
behaviour can be reasoned about and tested in isolation; the views layer feeds
it rows from the ORM (Product / Customer / Sale / SaleLine / Expense) and persists
whatever these functions return. Mirrors the pure-function design of
money_engine.py.

MONEY: integers in POISHA (1 taka = 100 poisha). Never floats — no drift.
Converters: taka_to_poisha() / poisha_to_taka() / fmt_taka().

Covers (BUSINESS_V2_PLAN §3):
  - Product model-logic: variants (size/colour), selling/cost/MINIMUM price,
    stock per variant, categories, barcode, Excel-import row parser.
  - Profit math (selling - cost) + margin.
  - Quick-sell cart engine: lines, qty, per-line price override that can
    NEVER go below the product/variant MINIMUM price (hard rule, enforced in
    code with a machine reason), payment method, totals, change due, receipt
    data dict, stock decrement + low-stock flag.
  - Customers: profile, purchase history, dues link, dedupe by phone.
  - Reports: daily/weekly/monthly sales, profit, top products, top customers,
    by-payment-method, net profit after expenses.
  - STAFF ROLE gate: redactor that strips cost/profit/minimum for staff.

All user-facing strings are {bn, en} dicts (see MSG / *_LABELS).
"""
from collections import defaultdict
from datetime import date, datetime

# ---------------------------------------------------------------------------
# money — integer poisha, zero float drift
# ---------------------------------------------------------------------------

POISHA_PER_TAKA = 100


def taka_to_poisha(v):
    """Coerce taka (str/int/float/None/'৳1,234.50') to integer poisha.

    Floats are rounded at 2dp via string to avoid binary drift. Junk -> 0.
    """
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v * POISHA_PER_TAKA
    if isinstance(v, float):
        # round to 2dp deterministically (half-up) then to poisha
        neg = v < 0
        cents = int(round(abs(v) * 100 + 1e-9))
        return -cents if neg else cents
    s = str(v).strip()
    # strip currency symbol, commas, spaces
    for ch in ("৳", "Tk", "tk", "TK", ",", " "):
        s = s.replace(ch, "")
    if not s:
        return 0
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    try:
        if "." in s:
            whole, frac = s.split(".", 1)
            frac = (frac + "00")[:2]
            cents = int(whole or "0") * 100 + int(frac)
        else:
            cents = int(s) * 100
    except (ValueError, TypeError):
        return 0
    return -cents if neg else cents


def poisha_to_taka(p):
    """Integer poisha -> Decimal-free taka float ONLY for display helpers.

    Returns a string so callers never reintroduce float money. Use fmt_taka
    for user-facing text.
    """
    p = int(p)
    neg = p < 0
    p = abs(p)
    out = "%d.%02d" % (p // 100, p % 100)
    return "-" + out if neg else out


def fmt_taka(p, lang="bn"):
    """User-facing '৳1,234.50' style string from integer poisha."""
    p = int(p)
    neg = p < 0
    p = abs(p)
    whole = p // 100
    frac = p % 100
    # thousands grouping (plain, works for both langs)
    grouped = "{:,}".format(whole)
    body = "৳%s.%02d" % (grouped, frac)
    return ("-" + body) if neg else body


# ---------------------------------------------------------------------------
# strings — every user-facing message as {bn, en}
# ---------------------------------------------------------------------------

def L(bn, en):
    return {"bn": bn, "en": en}


def pick(msg, lang="bn"):
    """Pick bn/en from an L() dict; falls back to bn then en."""
    if not isinstance(msg, dict):
        return msg
    return msg.get(lang) or msg.get("bn") or msg.get("en") or ""


MSG = {
    # product / import
    "bad_name": L("পণ্যের নাম দরকার", "Product name is required"),
    "bad_price": L("বিক্রয় মূল্য সঠিক নয়", "Selling price is invalid"),
    "bad_min_gt_sell": L("ন্যূনতম মূল্য বিক্রয় মূল্যের চেয়ে বেশি হতে পারে না",
                         "Minimum price cannot exceed selling price"),
    "bad_cost_gt_sell": L("ক্রয়মূল্য বিক্রয় মূল্যের চেয়ে বেশি (লোকসান)",
                          "Cost price is above selling price (loss)"),
    "bad_stock": L("স্টক সংখ্যা সঠিক নয়", "Stock quantity is invalid"),
    "dup_barcode": L("এই বারকোড আগেই আছে", "This barcode already exists"),
    "dup_sku": L("এই SKU আগেই আছে", "This SKU already exists"),
    # cart / sale
    "line_not_found": L("লাইন পাওয়া যায়নি", "Line not found"),
    "qty_positive": L("পরিমাণ শূন্যের বেশি হতে হবে", "Quantity must be greater than zero"),
    "out_of_stock": L("স্টকে নেই", "Out of stock"),
    "insufficient_stock": L("যথেষ্ট স্টক নেই", "Not enough stock"),
    "below_min": L("ন্যূনতম মূল্যের নিচে বিক্রি করা যাবে না",
                   "Cannot sell below the minimum price"),
    "empty_cart": L("কার্ট খালি", "Cart is empty"),
    "short_payment": L("পরিশোধিত টাকা মোটের চেয়ে কম", "Paid amount is less than the total"),
    "sale_ok": L("বিক্রয় সম্পন্ন", "Sale completed"),
    # payment methods
    "pay_cash": L("নগদ টাকা", "Cash"),
    "pay_bkash": L("বিকাশ", "bKash"),
    "pay_nagad": L("নগদ (অ্যাপ)", "Nagad"),
    "pay_due": L("বাকি", "Due"),
    # staff
    "staff_restricted": L("এই তথ্য স্টাফের জন্য সীমিত",
                          "This information is restricted for staff"),
    # receipt / report labels
    "receipt_title": L("রসিদ", "Receipt"),
    "subtotal": L("উপমোট", "Subtotal"),
    "discount": L("ছাড়", "Discount"),
    "total": L("মোট", "Total"),
    "paid": L("পরিশোধিত", "Paid"),
    "change": L("ফেরত", "Change"),
    "due": L("বাকি", "Due"),
}


# payment methods
PAY_CASH = "cash"
PAY_BKASH = "bkash"
PAY_NAGAD = "nagad"
PAY_DUE = "due"
PAYMENT_METHODS = (PAY_CASH, PAY_BKASH, PAY_NAGAD, PAY_DUE)
PAYMENT_LABELS = {
    PAY_CASH: MSG["pay_cash"],
    PAY_BKASH: MSG["pay_bkash"],
    PAY_NAGAD: MSG["pay_nagad"],
    PAY_DUE: MSG["pay_due"],
}


def payment_label(method, lang="bn"):
    return pick(PAYMENT_LABELS.get(method, L(method, method)), lang)


# machine reason codes (stable; UI maps to MSG)
R_OK = "ok"
R_BELOW_MIN = "below_min"
R_QTY = "qty_positive"
R_NO_STOCK = "out_of_stock"
R_LOW_STOCK = "insufficient_stock"
R_LINE = "line_not_found"
R_EMPTY = "empty_cart"
R_SHORT = "short_payment"
R_BAD_PAY = "bad_payment_method"


# default: flag a variant as low-stock at/under this many units
DEFAULT_LOW_STOCK = 3


# ---------------------------------------------------------------------------
# variants — a product may have size/colour combos, each with own price/stock
# ---------------------------------------------------------------------------

def variant_key(size=None, colour=None):
    """Stable key for a size/colour combo. None/'' collapse to a base key."""
    s = (size or "").strip()
    c = (colour or "").strip()
    if not s and not c:
        return "__base__"
    return "%s|%s" % (s.lower(), c.lower())


def make_variant(size=None, colour=None, sell=0, cost=0, minimum=0, stock=0,
                 barcode="", low_stock_at=DEFAULT_LOW_STOCK):
    """Build a normalised variant dict (all money in poisha)."""
    sell_p = taka_to_poisha(sell)
    cost_p = taka_to_poisha(cost)
    # minimum defaults to selling price if not given / zero
    min_p = taka_to_poisha(minimum)
    if min_p <= 0:
        min_p = sell_p
    return {
        "key": variant_key(size, colour),
        "size": (size or "").strip(),
        "colour": (colour or "").strip(),
        "sell_price": sell_p,
        "cost_price": cost_p,
        "min_price": min_p,
        "stock": int(stock or 0),
        "barcode": (barcode or "").strip(),
        "low_stock_at": int(low_stock_at),
    }


def make_product(name, category="", sku="", barcode="", description="",
                 variants=None, sell=0, cost=0, minimum=0, stock=0,
                 low_stock_at=DEFAULT_LOW_STOCK):
    """Build a normalised product dict. If no variants given, a single base
    variant is created from the top-level sell/cost/minimum/stock."""
    name = (name or "").strip()
    vs = list(variants or [])
    if not vs:
        vs = [make_variant(sell=sell, cost=cost, minimum=minimum, stock=stock,
                           barcode=barcode, low_stock_at=low_stock_at)]
    return {
        "name": name,
        "category": (category or "").strip(),
        "sku": (sku or "").strip(),
        "barcode": (barcode or "").strip(),
        "description": (description or "").strip(),
        "variants": vs,
    }


def get_variant(product, key=None, size=None, colour=None):
    """Find a variant in a product by key or by size/colour. None if absent."""
    if key is None:
        key = variant_key(size, colour)
    for v in product.get("variants", []):
        if v.get("key") == key:
            return v
    # fall back to base if only one variant
    vs = product.get("variants", [])
    if len(vs) == 1:
        return vs[0]
    return None


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_variant(v):
    """Return (ok, reason_code|None). Enforces price sanity incl. min<=sell."""
    if v["sell_price"] <= 0:
        return (False, "bad_price")
    if v["min_price"] > v["sell_price"]:
        return (False, "bad_min_gt_sell")
    if v["cost_price"] > v["sell_price"]:
        return (False, "bad_cost_gt_sell")
    if v["stock"] < 0:
        return (False, "bad_stock")
    return (True, None)


def validate_product(p):
    """Return (ok, [reason_codes]). Full product validation."""
    errs = []
    if not p.get("name"):
        errs.append("bad_name")
    if not p.get("variants"):
        errs.append("bad_price")
    for v in p.get("variants", []):
        ok, code = validate_variant(v)
        if not ok:
            errs.append(code)
    return (not errs, errs)


# ---------------------------------------------------------------------------
# Excel / CSV import — list[dict] rows -> validated products + bad-row report
# ---------------------------------------------------------------------------

# accepted header aliases (lower-cased) -> canonical field
_IMPORT_ALIASES = {
    "name": "name", "product": "name", "নাম": "name", "পণ্য": "name",
    "category": "category", "cat": "category", "ক্যাটাগরি": "category",
    "sku": "sku", "code": "sku",
    "barcode": "barcode", "বারকোড": "barcode",
    "size": "size", "সাইজ": "size",
    "colour": "colour", "color": "colour", "রঙ": "colour",
    "sell": "sell", "price": "sell", "selling price": "sell",
    "sell price": "sell", "mrp": "sell", "বিক্রয়": "sell", "দাম": "sell",
    "cost": "cost", "cost price": "cost", "buy": "cost", "ক্রয়": "cost",
    "min": "minimum", "minimum": "minimum", "min price": "minimum",
    "minimum price": "minimum", "ন্যূনতম": "minimum",
    "stock": "stock", "qty": "stock", "quantity": "stock", "স্টক": "stock",
    "description": "description", "desc": "description", "বিবরণ": "description",
}


def _canon_row(row):
    """Normalise a raw import row's keys to canonical field names."""
    out = {}
    for k, v in row.items():
        ck = _IMPORT_ALIASES.get(str(k).strip().lower())
        if ck:
            out[ck] = v
    return out


def parse_import_rows(rows, low_stock_at=DEFAULT_LOW_STOCK):
    """Parse an Excel/CSV import (list[dict]) into validated products.

    Rows sharing the same (name, sku) are merged into one product with
    multiple variants (size/colour). Returns:
        {"products": [product, ...],
         "bad_rows": [{"row": int, "errors": [code...], "data": raw}, ...]}
    """
    products = {}          # (name, sku) -> product dict
    order = []             # preserve first-seen order
    bad = []
    for i, raw in enumerate(rows):
        c = _canon_row(raw)
        name = (c.get("name") or "").strip()
        errs = []
        if not name:
            errs.append("bad_name")
        v = make_variant(
            size=c.get("size"), colour=c.get("colour"),
            sell=c.get("sell"), cost=c.get("cost"), minimum=c.get("minimum"),
            stock=c.get("stock") or 0, barcode=c.get("barcode"),
            low_stock_at=low_stock_at,
        )
        ok, code = validate_variant(v)
        if not ok:
            errs.append(code)
        if errs:
            bad.append({"row": i, "errors": errs, "data": raw})
            continue
        pk = (name.lower(), (c.get("sku") or "").strip().lower())
        if pk not in products:
            products[pk] = {
                "name": name,
                "category": (c.get("category") or "").strip(),
                "sku": (c.get("sku") or "").strip(),
                "barcode": (c.get("barcode") or "").strip(),
                "description": (c.get("description") or "").strip(),
                "variants": [],
            }
            order.append(pk)
        # avoid duplicate variant keys within one product
        existing = {x["key"] for x in products[pk]["variants"]}
        if v["key"] in existing:
            bad.append({"row": i, "errors": ["dup_variant"], "data": raw})
            continue
        products[pk]["variants"].append(v)
    return {"products": [products[k] for k in order], "bad_rows": bad}


def check_import_uniqueness(products, existing_barcodes=(), existing_skus=()):
    """Flag products/variants whose barcode or sku collides with the catalog or
    with each other. Returns list of {index, field, value, error}."""
    seen_bc = set(x for x in existing_barcodes if x)
    seen_sku = set(x for x in existing_skus if x)
    conflicts = []
    for idx, p in enumerate(products):
        sku = p.get("sku")
        if sku:
            if sku in seen_sku:
                conflicts.append({"index": idx, "field": "sku",
                                  "value": sku, "error": "dup_sku"})
            seen_sku.add(sku)
        for v in p.get("variants", []):
            bc = v.get("barcode")
            if bc:
                if bc in seen_bc:
                    conflicts.append({"index": idx, "field": "barcode",
                                      "value": bc, "error": "dup_barcode"})
                seen_bc.add(bc)
    return conflicts


# ---------------------------------------------------------------------------
# profit math (selling - cost) and margin
# ---------------------------------------------------------------------------

def profit_poisha(sell_p, cost_p, qty=1):
    """Gross profit in poisha for qty units."""
    return (int(sell_p) - int(cost_p)) * int(qty)


def margin_pct(sell_p, cost_p):
    """Profit margin as a percentage of SELLING price (0..100), 2dp float.
    Returns 0.0 if sell_price is 0."""
    sell_p = int(sell_p)
    if sell_p <= 0:
        return 0.0
    return round((sell_p - int(cost_p)) * 100.0 / sell_p, 2)


def markup_pct(sell_p, cost_p):
    """Markup as a percentage of COST price. 0.0 if cost is 0."""
    cost_p = int(cost_p)
    if cost_p <= 0:
        return 0.0
    return round((int(sell_p) - cost_p) * 100.0 / cost_p, 2)


# ---------------------------------------------------------------------------
# quick-sell cart engine
# ---------------------------------------------------------------------------

def new_cart():
    """An empty cart. Lines are added via cart_add_line()."""
    return {"lines": [], "_next_id": 1}


def _price_for(variant, override):
    """Resolve a line's unit price (poisha) given an optional override.

    HARD RULE: a per-line override can NEVER go below the variant's minimum
    price. Below-min overrides are REJECTED (not silently clamped) with reason
    R_BELOW_MIN so the caller must show the below-min message and either keep
    the minimum or abort. Returns (price_p, ok, reason).
    """
    min_p = int(variant["min_price"])
    if override is None or override == "":
        return (int(variant["sell_price"]), True, R_OK)
    ov = taka_to_poisha(override)
    if ov < min_p:
        # reject: selling below minimum must be impossible here
        return (min_p, False, R_BELOW_MIN)
    return (ov, True, R_OK)


def cart_add_line(cart, product, variant_key=None, qty=1, price_override=None,
                  size=None, colour=None):
    """Add a line to the cart. Returns (cart, line|None, reason_code).

    Enforces: qty>0, stock available, and price override >= variant minimum.
    If the override is below minimum the line is NOT added; reason=R_BELOW_MIN.
    """
    qty = int(qty or 0)
    if qty <= 0:
        return (cart, None, R_QTY)
    variant = get_variant(product, key=variant_key, size=size, colour=colour)
    if variant is None:
        return (cart, None, R_LINE)
    if variant["stock"] <= 0:
        return (cart, None, R_NO_STOCK)
    # existing qty for this variant already in the cart (prevent oversell)
    already = sum(l["qty"] for l in cart["lines"]
                  if l["variant_key"] == variant["key"])
    if qty + already > variant["stock"]:
        return (cart, None, R_LOW_STOCK)
    unit_p, ok, reason = _price_for(variant, price_override)
    if not ok:
        return (cart, None, reason)
    line = {
        "id": cart["_next_id"],
        "product_name": product.get("name", ""),
        "variant_key": variant["key"],
        "size": variant.get("size", ""),
        "colour": variant.get("colour", ""),
        "qty": qty,
        "unit_price": unit_p,       # poisha
        "min_price": int(variant["min_price"]),
        "cost_price": int(variant["cost_price"]),
        "sell_price": int(variant["sell_price"]),
    }
    cart["_next_id"] += 1
    cart["lines"].append(line)
    return (cart, line, R_OK)


def cart_remove_line(cart, line_id):
    """Remove a line by id. Returns (cart, reason_code)."""
    before = len(cart["lines"])
    cart["lines"] = [l for l in cart["lines"] if l["id"] != line_id]
    if len(cart["lines"]) == before:
        return (cart, R_LINE)
    return (cart, R_OK)


def cart_set_qty(cart, line_id, qty, stock=None):
    """Change a line's quantity. qty must be >0; if stock given, must fit.
    Returns (cart, reason_code)."""
    qty = int(qty or 0)
    if qty <= 0:
        return (cart, R_QTY)
    for l in cart["lines"]:
        if l["id"] == line_id:
            if stock is not None and qty > int(stock):
                return (cart, R_LOW_STOCK)
            l["qty"] = qty
            return (cart, R_OK)
    return (cart, R_LINE)


def cart_set_price(cart, line_id, price_override):
    """Override a line's unit price. REJECTED if below that line's minimum.
    Returns (cart, reason_code). The line price is unchanged on rejection."""
    for l in cart["lines"]:
        if l["id"] == line_id:
            ov = taka_to_poisha(price_override)
            if ov < l["min_price"]:
                return (cart, R_BELOW_MIN)
            l["unit_price"] = ov
            return (cart, R_OK)
    return (cart, R_LINE)


def cart_subtotal(cart):
    """Sum of qty*unit_price over all lines (poisha)."""
    return sum(l["qty"] * l["unit_price"] for l in cart["lines"])


def apply_cart_discount(cart, discount):
    """Apply a whole-cart discount (poisha or taka str). HARD RULE: a discount
    can NEVER push the cart total below the sum of line MINIMUMS. If it would,
    the discount is CLAMPED to the largest allowed value and a reason is
    returned. Returns (effective_discount_poisha, reason_code).

    (Per-line minimums are already enforced on unit_price; this guards against
    a blanket discount/bundle silently breaching the floor.)
    """
    disc = taka_to_poisha(discount)
    if disc < 0:
        disc = 0
    subtotal = cart_subtotal(cart)
    floor = sum(l["qty"] * l["min_price"] for l in cart["lines"])
    max_disc = max(0, subtotal - floor)
    if disc > max_disc:
        return (max_disc, R_BELOW_MIN)
    return (disc, R_OK)


def checkout(cart, payment_method=PAY_CASH, paid=None, discount=0,
             customer=None, now=None, lang="bn"):
    """Finalise a sale. Returns (result_dict, reason_code).

    result_dict on success: totals (poisha), profit, change/due, payment,
    per-line stock decrements, low-stock flags, and a receipt data dict.

    Guards: non-empty cart, valid payment method, discount cannot breach the
    minimum floor (clamped), and for non-due payments paid >= total.
    """
    if payment_method not in PAYMENT_METHODS:
        return (None, R_BAD_PAY)
    if not cart["lines"]:
        return (None, R_EMPTY)

    subtotal = cart_subtotal(cart)
    eff_disc, disc_reason = apply_cart_discount(cart, discount)
    total = subtotal - eff_disc

    # profit = (unit - cost)*qty summed, minus the discount we actually gave
    gross = sum(profit_poisha(l["unit_price"], l["cost_price"], l["qty"])
                for l in cart["lines"])
    net_profit = gross - eff_disc

    if payment_method == PAY_DUE:
        paid_p = taka_to_poisha(paid) if paid not in (None, "") else 0
    else:
        paid_p = taka_to_poisha(paid) if paid not in (None, "") else total
        if paid_p < total:
            return (None, R_SHORT)

    change_p = max(0, paid_p - total) if payment_method != PAY_DUE else 0
    due_p = max(0, total - paid_p)

    # stock decrements aggregated per variant key
    dec = defaultdict(int)
    for l in cart["lines"]:
        dec[l["variant_key"]] += l["qty"]
    stock_decrements = [{"variant_key": k, "qty": q} for k, q in dec.items()]

    when = now or datetime.utcnow()
    result = {
        "ok": True,
        "payment_method": payment_method,
        "subtotal": subtotal,
        "discount": eff_disc,
        "discount_clamped": disc_reason == R_BELOW_MIN,
        "total": total,
        "paid": paid_p,
        "change": change_p,
        "due": due_p,
        "profit": net_profit,
        "lines": [dict(l) for l in cart["lines"]],
        "stock_decrements": stock_decrements,
        "customer": customer,
        "created_at": when.isoformat() if hasattr(when, "isoformat") else when,
        "receipt": build_receipt({
            "payment_method": payment_method, "subtotal": subtotal,
            "discount": eff_disc, "total": total, "paid": paid_p,
            "change": change_p, "due": due_p,
            "lines": cart["lines"], "customer": customer, "when": when,
        }, lang=lang),
    }
    return (result, R_OK)


def apply_stock_decrements(variants_by_key, stock_decrements,
                           low_stock_at=DEFAULT_LOW_STOCK):
    """Given a {variant_key: variant} map and a checkout's stock_decrements,
    return a list of {variant_key, new_stock, low_stock} the view can persist.
    Pure: does not mutate the input."""
    out = []
    for d in stock_decrements:
        k = d["variant_key"]
        v = variants_by_key.get(k)
        if v is None:
            continue
        new_stock = int(v["stock"]) - int(d["qty"])
        threshold = int(v.get("low_stock_at", low_stock_at))
        out.append({
            "variant_key": k,
            "new_stock": new_stock,
            "low_stock": new_stock <= threshold,
            "out_of_stock": new_stock <= 0,
        })
    return out


# ---------------------------------------------------------------------------
# receipt data (rendering is optional; this is the structured payload)
# ---------------------------------------------------------------------------

def build_receipt(sale, lang="bn"):
    """Produce a localised receipt DATA dict from a sale-like dict. No render."""
    lines = []
    for l in sale.get("lines", []):
        label = l.get("product_name", "")
        if l.get("size") or l.get("colour"):
            tag = " / ".join(x for x in (l.get("size"), l.get("colour")) if x)
            label = "%s (%s)" % (label, tag)
        lines.append({
            "label": label,
            "qty": l["qty"],
            "unit_price": l["unit_price"],
            "unit_price_text": fmt_taka(l["unit_price"], lang),
            "line_total": l["qty"] * l["unit_price"],
            "line_total_text": fmt_taka(l["qty"] * l["unit_price"], lang),
        })
    when = sale.get("when")
    return {
        "title": pick(MSG["receipt_title"], lang),
        "payment_method": sale.get("payment_method"),
        "payment_label": payment_label(sale.get("payment_method"), lang),
        "customer": (sale.get("customer") or {}).get("name") if sale.get("customer") else "",
        "lines": lines,
        "rows": [
            {"label": pick(MSG["subtotal"], lang), "value": sale.get("subtotal", 0),
             "text": fmt_taka(sale.get("subtotal", 0), lang)},
            {"label": pick(MSG["discount"], lang), "value": sale.get("discount", 0),
             "text": fmt_taka(sale.get("discount", 0), lang)},
            {"label": pick(MSG["total"], lang), "value": sale.get("total", 0),
             "text": fmt_taka(sale.get("total", 0), lang)},
            {"label": pick(MSG["paid"], lang), "value": sale.get("paid", 0),
             "text": fmt_taka(sale.get("paid", 0), lang)},
            {"label": pick(MSG["change"], lang), "value": sale.get("change", 0),
             "text": fmt_taka(sale.get("change", 0), lang)},
            {"label": pick(MSG["due"], lang), "value": sale.get("due", 0),
             "text": fmt_taka(sale.get("due", 0), lang)},
        ],
        "when": when.isoformat() if hasattr(when, "isoformat") else when,
    }


# ---------------------------------------------------------------------------
# customers — profile, dedupe by phone, purchase history, dues link
# ---------------------------------------------------------------------------

def normalize_phone(phone):
    """Normalise a BD phone to a comparable key. Keeps digits; maps a leading
    880/+880 to a local 0-prefixed 11-digit form where possible."""
    if not phone:
        return ""
    digits = "".join(ch for ch in str(phone) if ch.isdigit())
    if digits.startswith("880") and len(digits) == 13:
        digits = "0" + digits[3:]
    elif digits.startswith("88") and len(digits) == 13:
        digits = digits[2:]
    return digits


def make_customer(name="", phone="", address="", area="", notes="", vip=False):
    return {
        "name": (name or "").strip(),
        "phone": (phone or "").strip(),
        "phone_key": normalize_phone(phone),
        "address": (address or "").strip(),
        "area": (area or "").strip(),
        "notes": (notes or "").strip(),
        "vip": bool(vip),
    }


def dedupe_customers(customers):
    """Collapse customers sharing a phone_key. Later entries fill blanks and
    OR the vip flag. Phone-less rows are kept as-is (can't dedupe)."""
    by_key = {}
    out = []
    for c in customers:
        c = make_customer(**{k: c.get(k) for k in
                             ("name", "phone", "address", "area", "notes", "vip")})
        key = c["phone_key"]
        if not key:
            out.append(c)
            continue
        if key in by_key:
            m = by_key[key]
            for f in ("name", "address", "area", "notes"):
                if not m[f] and c[f]:
                    m[f] = c[f]
            m["vip"] = m["vip"] or c["vip"]
        else:
            by_key[key] = c
            out.append(c)
    return out


def find_or_create_customer(customers, phone, name="", **kw):
    """Return (customer, created). Matches by normalized phone; creates if new.
    Operates on a plain list (the view mirrors this against the Customer table)."""
    key = normalize_phone(phone)
    if key:
        for c in customers:
            if c.get("phone_key") == key or normalize_phone(c.get("phone")) == key:
                return (c, False)
    c = make_customer(name=name, phone=phone, **kw)
    customers.append(c)
    return (c, True)


def purchase_history(sales, phone):
    """All sale records for a customer (matched by phone), newest first."""
    key = normalize_phone(phone)
    rows = [s for s in sales
            if normalize_phone((s.get("customer") or {}).get("phone")) == key]
    return sorted(rows, key=lambda s: s.get("created_at", ""), reverse=True)


def customer_dues_poisha(sales, phone):
    """Total outstanding due (poisha) for a customer across their sales."""
    return sum(int(s.get("due", 0)) for s in purchase_history(sales, phone))


# ---------------------------------------------------------------------------
# reports engine — from lists of sale/expense records
# ---------------------------------------------------------------------------

def _sale_date(s):
    """date object from a sale record's created_at (ISO str or date/datetime)."""
    v = s.get("created_at") or s.get("date")
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    if isinstance(v, str) and v:
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).date()
        except ValueError:
            try:
                return date.fromisoformat(v[:10])
            except ValueError:
                return None
    return None


def _period_key(d, period):
    if d is None:
        return None
    if period == "daily":
        return d.isoformat()
    if period == "weekly":
        iso = d.isocalendar()
        return "%04d-W%02d" % (iso[0], iso[1])
    if period == "monthly":
        return "%04d-%02d" % (d.year, d.month)
    return d.isoformat()


def sales_report(sales, period="daily"):
    """Group sales by period. Returns {period_key: {sales, profit, count,
    due}} with money in poisha. Sales total uses each sale's 'total'."""
    out = {}
    for s in sales:
        d = _sale_date(s)
        k = _period_key(d, period)
        if k is None:
            continue
        b = out.setdefault(k, {"sales": 0, "profit": 0, "count": 0, "due": 0})
        b["sales"] += int(s.get("total", 0))
        b["profit"] += int(s.get("profit", 0))
        b["due"] += int(s.get("due", 0))
        b["count"] += 1
    return out


def top_products(sales, limit=5):
    """Rank products by units sold and revenue across a sale list."""
    agg = defaultdict(lambda: {"name": "", "qty": 0, "revenue": 0, "profit": 0})
    for s in sales:
        for l in s.get("lines", []):
            key = l.get("product_name", "")
            a = agg[key]
            a["name"] = key
            a["qty"] += int(l.get("qty", 0))
            a["revenue"] += int(l.get("qty", 0)) * int(l.get("unit_price", 0))
            a["profit"] += profit_poisha(l.get("unit_price", 0),
                                         l.get("cost_price", 0), l.get("qty", 0))
    ranked = sorted(agg.values(), key=lambda a: (a["qty"], a["revenue"]),
                    reverse=True)
    return ranked[:limit]


def top_customers(sales, limit=5):
    """Rank customers by total spend (poisha)."""
    agg = defaultdict(lambda: {"name": "", "phone": "", "spent": 0,
                               "count": 0, "due": 0})
    for s in sales:
        cust = s.get("customer") or {}
        key = normalize_phone(cust.get("phone")) or (cust.get("name") or "?")
        a = agg[key]
        a["name"] = cust.get("name", "") or a["name"]
        a["phone"] = cust.get("phone", "") or a["phone"]
        a["spent"] += int(s.get("total", 0))
        a["due"] += int(s.get("due", 0))
        a["count"] += 1
    ranked = sorted(agg.values(), key=lambda a: a["spent"], reverse=True)
    return ranked[:limit]


def by_payment_method(sales):
    """Totals (poisha) and counts grouped by payment method."""
    out = {}
    for s in sales:
        m = s.get("payment_method", PAY_CASH)
        b = out.setdefault(m, {"total": 0, "count": 0, "paid": 0, "due": 0})
        b["total"] += int(s.get("total", 0))
        b["paid"] += int(s.get("paid", 0))
        b["due"] += int(s.get("due", 0))
        b["count"] += 1
    return out


def net_profit_report(sales, expenses, period=None):
    """Net profit after expenses. If period given, returns per-period rows;
    else a single summary. All money poisha."""
    def _exp_date(e):
        v = e.get("date") or e.get("created_at")
        if isinstance(v, (date, datetime)):
            return v.date() if isinstance(v, datetime) else v
        if isinstance(v, str) and v:
            try:
                return date.fromisoformat(v[:10])
            except ValueError:
                return None
        return None

    if period:
        rows = {}
        for s in sales:
            k = _period_key(_sale_date(s), period)
            if k is None:
                continue
            b = rows.setdefault(k, {"gross_profit": 0, "expenses": 0,
                                    "net_profit": 0, "sales": 0})
            b["gross_profit"] += int(s.get("profit", 0))
            b["sales"] += int(s.get("total", 0))
        for e in expenses:
            k = _period_key(_exp_date(e), period)
            if k is None:
                continue
            b = rows.setdefault(k, {"gross_profit": 0, "expenses": 0,
                                    "net_profit": 0, "sales": 0})
            b["expenses"] += taka_to_poisha(e.get("amount"))
        for b in rows.values():
            b["net_profit"] = b["gross_profit"] - b["expenses"]
        return rows

    gross = sum(int(s.get("profit", 0)) for s in sales)
    exp = sum(taka_to_poisha(e.get("amount")) for e in expenses)
    sales_total = sum(int(s.get("total", 0)) for s in sales)
    return {
        "sales": sales_total,
        "gross_profit": gross,
        "expenses": exp,
        "net_profit": gross - exp,
    }


def full_report(sales, expenses, period="daily", lang="bn", role="owner"):
    """One structured report dict covering every §3 report. Staff-redacted when
    role == 'staff' (no cost/profit/net fields)."""
    rep = {
        "period": period,
        "sales": sales_report(sales, period),
        "top_products": top_products(sales),
        "top_customers": top_customers(sales),
        "by_payment_method": by_payment_method(sales),
        "net": net_profit_report(sales, expenses),
        "labels": report_labels(lang),
    }
    if role == "staff":
        return redact_report(rep)
    return rep


def report_labels(lang="bn"):
    return {
        "sales": pick(L("বিক্রয়", "Sales"), lang),
        "profit": pick(L("লাভ", "Profit"), lang),
        "net_profit": pick(L("খরচ বাদে নিট লাভ", "Net profit after expenses"), lang),
        "top_products": pick(L("শীর্ষ পণ্য", "Top products"), lang),
        "top_customers": pick(L("শীর্ষ গ্রাহক", "Top customers"), lang),
        "by_payment": pick(L("পেমেন্ট অনুযায়ী", "By payment method"), lang),
        "expenses": pick(L("খরচ", "Expenses"), lang),
    }


# ---------------------------------------------------------------------------
# STAFF ROLE gate — redact cost / profit / minimum for staff
# ---------------------------------------------------------------------------

ROLE_OWNER = "owner"
ROLE_STAFF = "staff"

# fields staff must never see
_STAFF_HIDDEN_FIELDS = ("cost_price", "min_price", "minimum", "profit",
                        "gross_profit", "net_profit", "margin", "markup")


def _strip(obj):
    if isinstance(obj, dict):
        return {k: _strip(v) for k, v in obj.items()
                if k not in _STAFF_HIDDEN_FIELDS}
    if isinstance(obj, list):
        return [_strip(x) for x in obj]
    return obj


def redact_for_role(obj, role=ROLE_OWNER):
    """Deep-strip cost/profit/minimum from any dict/list if role is staff.
    Owner sees everything. Returns a NEW object; input is not mutated."""
    if role == ROLE_STAFF:
        return _strip(obj)
    return obj


def redact_product(product, role=ROLE_OWNER):
    """Product view for a role. Staff: no cost/min on product or variants."""
    return redact_for_role(product, role)


def redact_sale(sale, role=ROLE_OWNER):
    """Sale/receipt view for a role. Staff never sees per-line cost or profit."""
    return redact_for_role(sale, role)


def redact_report(report, role=ROLE_STAFF):
    """Report view for staff — drops profit / net / cost everywhere."""
    return redact_for_role(report, role)


def staff_restricted_notice(lang="bn"):
    return pick(MSG["staff_restricted"], lang)


def can_see_cost(role):
    return role != ROLE_STAFF
