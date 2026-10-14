"""
business_selling_tests_snippets.py — plain-assert tests for
core.logic.business_selling. NOT a Django TestCase. Smoke locally:

    cd backend && python3 -c "import core.logic.business_selling_tests_snippets as t; t.run_all()"

Covers full §3 surface. The minimum-price enforcement tests are the CRITICAL
ones and are grouped under "MIN-PRICE ENFORCEMENT" below.
"""
from core.logic import business_selling as B


# ---------------------------------------------------------------------------
# money — integer poisha, no float drift
# ---------------------------------------------------------------------------

def test_taka_to_poisha_int_and_str():
    assert B.taka_to_poisha(10) == 1000
    assert B.taka_to_poisha("10") == 1000
    assert B.taka_to_poisha("10.50") == 1050
    assert B.taka_to_poisha("১") != 999  # non-ascii digits -> junk -> 0 path ok
    assert B.taka_to_poisha("৳1,234.50") == 123450
    assert B.taka_to_poisha("") == 0
    assert B.taka_to_poisha(None) == 0
    assert B.taka_to_poisha("abc") == 0


def test_no_float_drift():
    # 0.1 + 0.2 class problem: 3 * 19.99 must be exactly 5997 poisha
    assert B.taka_to_poisha(19.99) == 1999
    total = B.taka_to_poisha(19.99) * 3
    assert total == 5997
    assert B.poisha_to_taka(5997) == "59.97"


def test_fmt_taka():
    assert B.fmt_taka(123450) == "৳1,234.50"
    assert B.fmt_taka(0) == "৳0.00"
    assert B.fmt_taka(-500) == "-৳5.00"


# ---------------------------------------------------------------------------
# products / variants / validation
# ---------------------------------------------------------------------------

def test_variant_min_defaults_to_sell():
    v = B.make_variant(sell=100, cost=60, minimum=0, stock=5)
    assert v["sell_price"] == 10000
    assert v["min_price"] == 10000  # defaulted to sell
    assert v["cost_price"] == 6000


def test_variant_key_size_colour():
    assert B.variant_key("M", "Red") == "m|red"
    assert B.variant_key(None, None) == "__base__"


def test_validate_variant_rules():
    ok, _ = B.validate_variant(B.make_variant(sell=100, cost=60, minimum=80, stock=5))
    assert ok
    ok, code = B.validate_variant(B.make_variant(sell=100, cost=60, minimum=120, stock=5))
    assert not ok and code == "bad_min_gt_sell", code
    ok, code = B.validate_variant(B.make_variant(sell=100, cost=150, minimum=90, stock=5))
    assert not ok and code == "bad_cost_gt_sell", code
    ok, code = B.validate_variant(B.make_variant(sell=0, cost=0, stock=5))
    assert not ok and code == "bad_price", code


def test_validate_product():
    p = B.make_product("Shirt", sell=100, cost=60, minimum=80, stock=5)
    ok, errs = B.validate_product(p)
    assert ok and not errs
    p2 = B.make_product("", sell=0)
    ok, errs = B.validate_product(p2)
    assert not ok and "bad_name" in errs and "bad_price" in errs


# ---------------------------------------------------------------------------
# excel/csv import
# ---------------------------------------------------------------------------

def test_import_rows_and_merge_variants():
    rows = [
        {"Name": "Shirt", "SKU": "SH1", "Size": "M", "Colour": "Red",
         "Price": "500", "Cost": "300", "Min": "400", "Stock": "10"},
        {"name": "Shirt", "sku": "SH1", "size": "L", "colour": "Red",
         "price": "520", "cost": "300", "min": "420", "stock": "4"},
        {"পণ্য": "Mug", "দাম": "150", "ক্রয়": "80", "স্টক": "20"},
    ]
    out = B.parse_import_rows(rows)
    assert len(out["products"]) == 2, out
    shirt = out["products"][0]
    assert len(shirt["variants"]) == 2  # merged M + L
    assert out["products"][1]["name"] == "Mug"
    assert out["bad_rows"] == []


def test_import_bad_rows_reported():
    rows = [
        {"Name": "", "Price": "100"},               # no name
        {"Name": "X", "Price": "0"},                # bad price
        {"Name": "Y", "Price": "100", "Min": "200"},  # min > sell
        {"Name": "Z", "Price": "100", "Cost": "60", "Min": "80", "Stock": "3"},  # ok
    ]
    out = B.parse_import_rows(rows)
    assert len(out["products"]) == 1 and out["products"][0]["name"] == "Z"
    codes = [set(b["errors"]) for b in out["bad_rows"]]
    assert {"bad_name"} in codes
    assert {"bad_price"} in codes
    assert {"bad_min_gt_sell"} in codes


def test_import_uniqueness():
    rows = [
        {"Name": "A", "SKU": "S1", "Barcode": "111", "Price": "100", "Cost": "50", "Min": "90", "Stock": "1"},
        {"Name": "B", "SKU": "S2", "Barcode": "222", "Price": "100", "Cost": "50", "Min": "90", "Stock": "1"},
    ]
    out = B.parse_import_rows(rows)
    conflicts = B.check_import_uniqueness(out["products"],
                                          existing_barcodes={"222"},
                                          existing_skus=set())
    assert any(c["error"] == "dup_barcode" and c["value"] == "222" for c in conflicts), conflicts


# ---------------------------------------------------------------------------
# profit math
# ---------------------------------------------------------------------------

def test_profit_and_margin():
    assert B.profit_poisha(10000, 6000, 3) == 12000  # (100-60)*3
    assert B.margin_pct(10000, 6000) == 40.0
    assert B.markup_pct(10000, 6000) == round(4000 * 100.0 / 6000, 2)
    assert B.margin_pct(0, 0) == 0.0


# ---------------------------------------------------------------------------
# cart basics
# ---------------------------------------------------------------------------

def _prod(sell=500, cost=300, minimum=400, stock=10, size="M", colour="Red"):
    return B.make_product("Shirt",
                          variants=[B.make_variant(size=size, colour=colour,
                                    sell=sell, cost=cost, minimum=minimum,
                                    stock=stock, low_stock_at=2)])


def test_cart_add_remove_qty():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(), qty=2, size="M", colour="Red")
    assert r == B.R_OK and line["unit_price"] == 50000
    assert B.cart_subtotal(cart) == 100000
    cart, r = B.cart_set_qty(cart, line["id"], 3)
    assert r == B.R_OK and B.cart_subtotal(cart) == 150000
    cart, r = B.cart_remove_line(cart, line["id"])
    assert r == B.R_OK and cart["lines"] == []
    cart, r = B.cart_remove_line(cart, 999)
    assert r == B.R_LINE


def test_cart_qty_must_be_positive():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(), qty=0)
    assert line is None and r == B.R_QTY


def test_cart_stock_guard():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(stock=2), qty=5, size="M", colour="Red")
    assert line is None and r == B.R_LOW_STOCK
    cart, line, r = B.cart_add_line(cart, _prod(stock=0), qty=1, size="M", colour="Red")
    assert line is None and r == B.R_NO_STOCK


def test_cart_oversell_across_lines():
    cart = B.new_cart()
    p = _prod(stock=3)
    cart, line, r = B.cart_add_line(cart, p, qty=2, size="M", colour="Red")
    assert r == B.R_OK
    cart, line2, r = B.cart_add_line(cart, p, qty=2, size="M", colour="Red")
    assert line2 is None and r == B.R_LOW_STOCK  # 2+2 > 3


# ---------------------------------------------------------------------------
# ===== MIN-PRICE ENFORCEMENT (CRITICAL) ====================================
# ---------------------------------------------------------------------------

def test_minprice_at_min_ok():
    """Override exactly at the minimum is allowed."""
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400), qty=1,
                                    price_override="400", size="M", colour="Red")
    assert r == B.R_OK and line["unit_price"] == 40000


def test_minprice_above_min_ok():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400), qty=1,
                                    price_override="450", size="M", colour="Red")
    assert r == B.R_OK and line["unit_price"] == 45000


def test_minprice_below_min_rejected_on_add():
    """HARD RULE: adding a line below minimum must be REJECTED, not clamped."""
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400), qty=1,
                                    price_override="399", size="M", colour="Red")
    assert line is None, "below-min line must not be added"
    assert r == B.R_BELOW_MIN, r
    assert cart["lines"] == []


def test_minprice_below_min_rejected_on_edit():
    """Editing an existing line below its minimum must be rejected; price stays."""
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400), qty=1,
                                    size="M", colour="Red")
    assert r == B.R_OK
    old = line["unit_price"]
    cart, r = B.cart_set_price(cart, line["id"], "399")
    assert r == B.R_BELOW_MIN
    assert cart["lines"][0]["unit_price"] == old  # unchanged
    # at-min edit works
    cart, r = B.cart_set_price(cart, line["id"], "400")
    assert r == B.R_OK and cart["lines"][0]["unit_price"] == 40000


def test_minprice_one_poisha_below_rejected():
    """Even 1 poisha below minimum is rejected (no float fuzz)."""
    cart = B.new_cart()
    # minimum 400.00 == 40000 poisha; override 399.99 == 39999
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400), qty=1,
                                    price_override="399.99", size="M", colour="Red")
    assert line is None and r == B.R_BELOW_MIN


def test_discount_cannot_breach_min_floor():
    """A whole-cart discount/bundle can NEVER push total below the sum of line
    minimums; it is clamped and flagged."""
    cart = B.new_cart()
    # sell 500 min 400, qty 2 => subtotal 100000, floor 80000, max discount 20000
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400, sell=500), qty=2,
                                    size="M", colour="Red")
    assert r == B.R_OK
    eff, reason = B.apply_cart_discount(cart, "300")  # 30000 > 20000 allowed
    assert eff == 20000, eff
    assert reason == B.R_BELOW_MIN
    # a legal discount passes through untouched
    eff2, reason2 = B.apply_cart_discount(cart, "150")  # 15000 <= 20000
    assert eff2 == 15000 and reason2 == B.R_OK


def test_checkout_discount_clamped_never_below_min():
    """End-to-end: an abusive discount at checkout is clamped so total never
    drops below the minimum floor."""
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(minimum=400, sell=500), qty=2,
                                    size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_CASH, paid="9999",
                        discount="9999")
    assert r == B.R_OK
    # floor is 2*400 = 80000; total must not be below it
    assert res["total"] >= 80000
    assert res["total"] == 80000  # clamped exactly to floor
    assert res["discount_clamped"] is True


# ---------------------------------------------------------------------------
# checkout / payments / receipt / stock
# ---------------------------------------------------------------------------

def test_checkout_cash_change():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(sell=500, cost=300), qty=2,
                                    size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_CASH, paid="1200")
    assert r == B.R_OK
    assert res["total"] == 100000
    assert res["change"] == 20000  # 1200 - 1000
    assert res["due"] == 0
    assert res["profit"] == (50000 - 30000) * 2  # 40000
    assert res["receipt"]["payment_label"]  # localised


def test_checkout_short_payment_rejected():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(sell=500, cost=300), qty=1,
                                    size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_BKASH, paid="100")
    assert res is None and r == B.R_SHORT


def test_checkout_due_payment():
    cart = B.new_cart()
    cart, line, r = B.cart_add_line(cart, _prod(sell=500, cost=300), qty=1,
                                    size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_DUE, paid="0",
                        customer=B.make_customer("Rahim", "01710000000"))
    assert r == B.R_OK and res["due"] == 50000 and res["change"] == 0


def test_checkout_empty_and_bad_method():
    res, r = B.checkout(B.new_cart(), payment_method=B.PAY_CASH, paid="0")
    assert res is None and r == B.R_EMPTY
    cart = B.new_cart()
    cart, _, _ = B.cart_add_line(cart, _prod(), qty=1, size="M", colour="Red")
    res, r = B.checkout(cart, payment_method="paypal", paid="999")
    assert res is None and r == B.R_BAD_PAY


def test_stock_decrement_and_low_flag():
    cart = B.new_cart()
    p = _prod(stock=4)  # low_stock_at=2
    cart, line, r = B.cart_add_line(cart, p, qty=3, size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_CASH, paid="9999")
    assert r == B.R_OK
    vbk = {v["key"]: v for v in p["variants"]}
    decs = B.apply_stock_decrements(vbk, res["stock_decrements"])
    assert decs[0]["new_stock"] == 1
    assert decs[0]["low_stock"] is True
    assert decs[0]["out_of_stock"] is False


# ---------------------------------------------------------------------------
# customers
# ---------------------------------------------------------------------------

def test_phone_normalize_and_dedupe():
    assert B.normalize_phone("+8801710000000") == "01710000000"
    assert B.normalize_phone("01710000000") == "01710000000"
    custs = [
        B.make_customer("Rahim", "01710000000", area="Mirpur"),
        B.make_customer("", "+8801710000000", notes="pays late", vip=True),
        B.make_customer("Karim", "01820000000"),
    ]
    deduped = B.dedupe_customers(custs)
    assert len(deduped) == 2
    rahim = [c for c in deduped if c["phone_key"] == "01710000000"][0]
    assert rahim["name"] == "Rahim" and rahim["notes"] == "pays late" and rahim["vip"]


def test_find_or_create_customer():
    lst = []
    c, created = B.find_or_create_customer(lst, "01710000000", name="Rahim")
    assert created and len(lst) == 1
    c2, created2 = B.find_or_create_customer(lst, "+8801710000000")
    assert not created2 and c2 is c


def test_purchase_history_and_dues():
    sales = [
        {"customer": {"name": "Rahim", "phone": "01710000000"}, "total": 50000,
         "due": 20000, "created_at": "2026-10-10T10:00:00"},
        {"customer": {"name": "Rahim", "phone": "+8801710000000"}, "total": 30000,
         "due": 0, "created_at": "2026-10-11T10:00:00"},
        {"customer": {"name": "Karim", "phone": "01820000000"}, "total": 10000,
         "due": 0, "created_at": "2026-10-11T10:00:00"},
    ]
    hist = B.purchase_history(sales, "01710000000")
    assert len(hist) == 2
    assert hist[0]["created_at"] > hist[1]["created_at"]  # newest first
    assert B.customer_dues_poisha(sales, "01710000000") == 20000


# ---------------------------------------------------------------------------
# reports
# ---------------------------------------------------------------------------

def _sale(total, profit, due, when, pay=B.PAY_CASH, lines=None, cust=None):
    return {"total": total, "profit": profit, "due": due, "paid": total - due,
            "payment_method": pay, "created_at": when,
            "lines": lines or [], "customer": cust}


def test_sales_report_periods():
    sales = [
        _sale(50000, 20000, 0, "2026-10-10T10:00:00"),
        _sale(30000, 10000, 0, "2026-10-10T14:00:00"),
        _sale(20000, 8000, 0, "2026-10-11T10:00:00"),
    ]
    daily = B.sales_report(sales, "daily")
    assert daily["2026-10-10"]["sales"] == 80000
    assert daily["2026-10-10"]["count"] == 2
    monthly = B.sales_report(sales, "monthly")
    assert monthly["2026-10"]["sales"] == 100000
    weekly = B.sales_report(sales, "weekly")
    assert sum(b["sales"] for b in weekly.values()) == 100000


def test_top_products_and_customers():
    lines_a = [{"product_name": "Shirt", "qty": 5, "unit_price": 50000, "cost_price": 30000}]
    lines_b = [{"product_name": "Mug", "qty": 2, "unit_price": 15000, "cost_price": 8000}]
    r = B.make_customer("Rahim", "01710000000")
    sales = [
        _sale(250000, 100000, 0, "2026-10-10T10:00:00", lines=lines_a, cust=r),
        _sale(30000, 14000, 0, "2026-10-11T10:00:00", lines=lines_b, cust=r),
    ]
    tp = B.top_products(sales)
    assert tp[0]["name"] == "Shirt" and tp[0]["qty"] == 5
    tc = B.top_customers(sales)
    assert tc[0]["name"] == "Rahim" and tc[0]["spent"] == 280000


def test_by_payment_method():
    sales = [
        _sale(50000, 0, 0, "2026-10-10T10:00:00", pay=B.PAY_CASH),
        _sale(30000, 0, 0, "2026-10-10T10:00:00", pay=B.PAY_BKASH),
        _sale(20000, 0, 20000, "2026-10-10T10:00:00", pay=B.PAY_DUE),
    ]
    rep = B.by_payment_method(sales)
    assert rep[B.PAY_CASH]["total"] == 50000
    assert rep[B.PAY_DUE]["due"] == 20000


def test_net_profit_after_expenses():
    sales = [_sale(100000, 40000, 0, "2026-10-10T10:00:00")]
    expenses = [{"amount": "100", "date": "2026-10-10"},
                {"amount": "50", "date": "2026-10-10"}]
    rep = B.net_profit_report(sales, expenses)
    assert rep["gross_profit"] == 40000
    assert rep["expenses"] == 15000
    assert rep["net_profit"] == 25000
    per = B.net_profit_report(sales, expenses, period="daily")
    assert per["2026-10-10"]["net_profit"] == 25000


# ---------------------------------------------------------------------------
# staff role gate — redaction
# ---------------------------------------------------------------------------

def test_redact_product_for_staff():
    p = B.make_product("Shirt", sell=500, cost=300, minimum=400, stock=5)
    owner = B.redact_product(p, role=B.ROLE_OWNER)
    assert owner["variants"][0]["cost_price"] == 30000  # owner sees cost
    staff = B.redact_product(p, role=B.ROLE_STAFF)
    v = staff["variants"][0]
    assert "cost_price" not in v and "min_price" not in v
    assert v["sell_price"] == 50000  # staff still sees sell price
    # original not mutated
    assert p["variants"][0]["cost_price"] == 30000


def test_redact_sale_for_staff():
    cart = B.new_cart()
    cart, _, _ = B.cart_add_line(cart, _prod(sell=500, cost=300, minimum=400),
                                 qty=1, size="M", colour="Red")
    res, r = B.checkout(cart, payment_method=B.PAY_CASH, paid="9999")
    staff = B.redact_sale(res, role=B.ROLE_STAFF)
    assert "profit" not in staff
    for l in staff["lines"]:
        assert "cost_price" not in l and "min_price" not in l
        assert "unit_price" in l  # staff still sees the selling price charged


def test_redact_report_for_staff():
    sales = [_sale(100000, 40000, 0, "2026-10-10T10:00:00")]
    rep = B.full_report(sales, [], period="daily", role=B.ROLE_STAFF)
    # profit stripped out of the grouped sales buckets and net block
    assert "profit" not in rep["sales"]["2026-10-10"]
    assert "net_profit" not in rep["net"]
    assert "gross_profit" not in rep["net"]
    # owner version keeps them
    rep_o = B.full_report(sales, [], period="daily", role=B.ROLE_OWNER)
    assert rep_o["sales"]["2026-10-10"]["profit"] == 40000
    assert rep_o["net"]["net_profit"] == 40000


def test_staff_cannot_see_cost_helper():
    assert B.can_see_cost(B.ROLE_OWNER) is True
    assert B.can_see_cost(B.ROLE_STAFF) is False
    assert B.staff_restricted_notice("en") == "This information is restricted for staff"
    assert B.staff_restricted_notice("bn")  # non-empty bn


# ---------------------------------------------------------------------------
# i18n sanity — every MSG has both bn and en filled
# ---------------------------------------------------------------------------

def test_all_strings_bilingual():
    for key, msg in B.MSG.items():
        assert msg["bn"].strip(), "missing bn for %s" % key
        assert msg["en"].strip(), "missing en for %s" % key
    for m in B.PAYMENT_METHODS:
        assert B.payment_label(m, "bn") and B.payment_label(m, "en")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------

def run_all():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    passed = 0
    for t in tests:
        t()
        passed += 1
    min_tests = [k for k in globals() if k.startswith("test_minprice")
                 or k.startswith("test_discount_cannot")
                 or k.startswith("test_checkout_discount_clamped")]
    print("business_selling: %d tests passed (%d minimum-price enforcement)."
          % (passed, len(min_tests)))
    return passed


if __name__ == "__main__":
    run_all()
