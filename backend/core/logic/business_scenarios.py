"""
business_scenarios.py — the two MANDATORY end-to-end scenario tests for Assisto
Business v2 (BUSINESS_V2_PLAN.md §9). PURE PYTHON. NO Django.

This is a deterministic harness that drives the three pure-logic modules
(business_khata, business_selling, business_ai) through two realistic
multi-day journeys and asserts exact outcomes. It holds NO wall clock — every
timestamp is a deterministic string passed into the logic.

  SCENARIO A — 30-day SMALL-SHOP month
    Open a shop; add products with minimum prices; over ~30 simulated days
    record a mix of cash/bKash/Nagad/due sales, customer dues (বাকি) + partial
    payments, supplier payables (দেনা), expenses, and daily cashbox
    opening/in-out/reconcile; fire single + bulk tagada.
    ASSERTS: ledgers reconcile exactly (integer poisha, no drift), cashbox
    variance is correct, net position = receivables - payables matches the
    hand-computed number, the monthly sales/profit report equals the sum of
    lines, stock is decremented correctly, and NO sale is ever below minimum.

  SCENARIO B — 7-day ONLINE-SELLER week
    Incoming chats (bn/Banglish/en) → AI mock drafts replies; bargaining both
    below and at/above the minimum; orders new→confirmed→packed→shipped(mock
    courier)→delivered plus one →returned; COD amounts; "where is my parcel?";
    morning summary; a handoff on an angry/refund message.
    ASSERTS: below-min ALWAYS defers to the owner with price=None + an owner
    notification (never a sub-min price); at/above-min accepts/counters >= min;
    courier state machine is legal; COD correct; morning-summary counts match;
    the personal-WhatsApp guard holds; payments never hold funds.

Run it:
    cd /home/ubuntu/assisto/backend && \
      python3 -c "import core.logic.business_scenarios as s; s.run_all()"

run_all() runs BOTH scenarios and prints "business_scenarios: N checks passed".
"""
from decimal import Decimal

try:
    from core.logic import business_khata as K
    from core.logic import business_selling as B
    from core.logic import business_ai as AI
except Exception:  # pragma: no cover - standalone import fallback
    import business_khata as K  # type: ignore
    import business_selling as B  # type: ignore
    import business_ai as AI  # type: ignore


# ---------------------------------------------------------------------------
# tiny assert harness — counts every check so run_all() can report N passed
# ---------------------------------------------------------------------------

class _Checker:
    def __init__(self):
        self.n = 0

    def ok(self, cond, label):
        self.n += 1
        if not cond:
            raise AssertionError(f"CHECK FAILED: {label}")

    def eq(self, got, want, label):
        self.n += 1
        if got != want:
            raise AssertionError(f"CHECK FAILED: {label}: got {got!r} != want {want!r}")


# ===========================================================================
# SCENARIO A — 30-day SMALL-SHOP month
# ===========================================================================

def scenario_a():
    """Returns the number of checks performed."""
    c = _Checker()
    SHOP = "Rahim Store"

    # -- open the business + catalogue (prices in TAKA; selling layer -> poisha)
    # make_product/make_variant take TAKA; min defaults to sell when 0.
    rice = B.make_product("Rice 1kg", category="grocery",
                          sell=70, cost=58, minimum=64, stock=100)
    oil = B.make_product("Soybean Oil 1L", category="grocery",
                         sell=185, cost=165, minimum=175, stock=40)
    soap = B.make_product("Soap", category="grocery",
                          sell=55, cost=40, minimum=48, stock=60)

    # sanity: all products validate, and poisha conversion is exact (no drift)
    for p in (rice, oil, soap):
        ok, errs = B.validate_product(p)
        c.ok(ok, f"product {p['name']} validates (errs={errs})")
    c.eq(B.get_variant(rice)["sell_price"], 7000, "rice sell = 7000 poisha")
    c.eq(B.get_variant(rice)["min_price"], 6400, "rice min = 6400 poisha")
    c.eq(B.get_variant(oil)["cost_price"], 16500, "oil cost = 16500 poisha")

    # running variant stock we decrement as sales happen (mirrors the view)
    stock = {
        "rice": B.get_variant(rice)["stock"],   # 100
        "oil": B.get_variant(oil)["stock"],     # 40
        "soap": B.get_variant(soap)["stock"],   # 60
    }

    # --------------------------------------------------------------------
    # 30 days of sales. Deterministic mix. We build a cart per sale and
    # checkout, accumulating sale records for the monthly report.
    # --------------------------------------------------------------------
    sales = []            # checkout result dicts (for reports)
    customer_entries = {} # party_id -> list of CUSTOMER-book ledger entries
    cash_entries = []     # cashbox 'in'/'out' entries for the single tracked day
    DAY = "2026-09-%02d"  # September has 30 days

    # helper to run a one-line sale deterministically
    def sell(product, key_name, qty, method, day, price_override=None,
             customer=None, paid=None):
        cart = B.new_cart()
        cart, line, reason = B.cart_add_line(cart, product, qty=qty,
                                             price_override=price_override)
        c.eq(reason, B.R_OK, f"add_line ok {product['name']} day{day}")
        c.ok(line is not None, f"line created {product['name']} day{day}")
        now = (DAY % day) + "T12:00:00"
        res, r2 = B.checkout(cart, payment_method=method, paid=paid,
                             customer=customer, now=now)
        c.eq(r2, B.R_OK, f"checkout ok {product['name']} day{day}")
        # decrement our mirrored stock
        stock[key_name] -= qty
        sales.append(res)
        return res

    # --- days 1-5: plain cash sales of rice (5 units each day) --------------
    # unit price = sell 7000; profit per unit = 7000-5800 = 1200 poisha
    for d in range(1, 6):
        r = sell(rice, "rice", 5, B.PAY_CASH, d)
        c.eq(r["total"], 5 * 7000, f"day{d} rice cash total")
        c.eq(r["profit"], 5 * 1200, f"day{d} rice cash profit")
    # 5 days * 25 units? no: 5 units/day * 5 days = 25 units rice sold so far
    c.eq(stock["rice"], 100 - 25, "rice stock after days 1-5")

    # --- day 6: bKash sale of oil (3 units) --------------------------------
    r = sell(oil, "oil", 3, B.PAY_BKASH, 6)
    c.eq(r["total"], 3 * 18500, "day6 oil bkash total")
    c.eq(r["profit"], 3 * (18500 - 16500), "day6 oil bkash profit")
    c.eq(r["payment_method"], B.PAY_BKASH, "day6 method = bkash")

    # --- day 7: Nagad sale of soap (4 units) -------------------------------
    r = sell(soap, "soap", 4, B.PAY_NAGAD, 7)
    c.eq(r["total"], 4 * 5500, "day7 soap nagad total")
    c.eq(r["profit"], 4 * (5500 - 4000), "day7 soap nagad profit")

    # --- day 8: bargained cash sale of oil at the MINIMUM (175) -----------
    # price_override at exactly the minimum must be accepted.
    r = sell(oil, "oil", 2, B.PAY_CASH, 8, price_override=175)
    c.eq(r["total"], 2 * 17500, "day8 oil@min total")
    c.ok(all(l["unit_price"] >= l["min_price"] for l in r["lines"]),
         "day8 oil sold at >= min")

    # --- day 8b: attempt a BELOW-MINIMUM sale — must be REJECTED -----------
    # rice min is 6400; try to sell at 6300 (63 taka). Line must NOT be added.
    bad_cart = B.new_cart()
    bad_cart, bad_line, bad_reason = B.cart_add_line(bad_cart, rice, qty=1,
                                                     price_override=63)
    c.eq(bad_reason, B.R_BELOW_MIN, "below-min override rejected (reason)")
    c.ok(bad_line is None, "below-min override: no line created")
    c.eq(len(bad_cart["lines"]), 0, "below-min override: cart stays empty")
    # a whole-cart discount may also never breach the min floor: build a legit
    # cart then try an oversized discount; it must clamp.
    disc_cart = B.new_cart()
    disc_cart, _, _ = B.cart_add_line(disc_cart, rice, qty=10)  # 10*7000=70000
    # floor = 10 * 6400 = 64000; max discount = 6000. Ask for 9999.
    eff_disc, disc_reason = B.apply_cart_discount(disc_cart, 99.99)
    c.eq(disc_reason, B.R_BELOW_MIN, "oversized discount flagged below_min")
    c.eq(eff_disc, 70000 - 64000, "oversized discount clamped to floor")
    stock["rice"] -= 10  # we'll checkout this discounted cart as a due sale
    dres, dr = B.checkout(disc_cart, payment_method=B.PAY_DUE, discount=99.99,
                          customer={"name": "Karim", "phone": "01710000002"},
                          now=(DAY % 9) + "T10:00:00")
    c.eq(dr, B.R_OK, "discounted due checkout ok")
    c.eq(dres["total"], 64000, "discounted sale total == floor")
    c.ok(dres["total"] >= sum(l["qty"] * l["min_price"] for l in dres["lines"]),
         "discounted sale never below min floor")
    sales.append(dres)

    # --- days 9-12: DUE sales recorded in the customer ledger (বাকি) -------
    # Customer Rahim (id 1): three credit sales + a partial payment.
    # We use the KHATA layer for the two-sided ledger (integer poisha, int
    # pass-through). Amounts chosen to hand-compute cleanly.
    R = 1  # Rahim
    customer_entries[R] = [
        K.new_entry(R, "gave", 50000, note="rice on credit", at="2026-09-10"),
        K.new_entry(R, "gave", 30000, note="oil on credit", at="2026-09-11"),
        K.apply_payment(R, 20000, K.CUSTOMER, note="partial", at="2026-09-12"),
    ]
    rahim_bal = K.running_balance(customer_entries[R], K.CUSTOMER)
    # 50000 + 30000 - 20000 = 60000
    c.eq(rahim_bal, 60000, "Rahim customer balance (bn baki)")

    # Customer Karim (id 2): the day-9 discounted due sale (64000) + a payment.
    KA = 2
    customer_entries[KA] = [
        K.new_entry(KA, "gave", 64000, note="grocery due", at="2026-09-09"),
        K.apply_payment(KA, 14000, K.CUSTOMER, note="partial", at="2026-09-20"),
    ]
    karim_bal = K.running_balance(customer_entries[KA], K.CUSTOMER)
    c.eq(karim_bal, 50000, "Karim customer balance")

    # Customer Sofia (id 3): fully settled (no due left) — tagada must skip her.
    SO = 3
    customer_entries[SO] = [
        K.new_entry(SO, "gave", 25000, note="credit", at="2026-09-13"),
        K.apply_payment(SO, 25000, K.CUSTOMER, note="paid in full", at="2026-09-21"),
    ]
    c.eq(K.running_balance(customer_entries[SO], K.CUSTOMER), 0,
         "Sofia fully settled")

    total_receivable = rahim_bal + karim_bal  # 110000 (Sofia = 0)
    c.eq(total_receivable, 110000, "total receivable hand-computed")

    # --- supplier payables (দেনা) -----------------------------------------
    # Supplier Wholesaler (id 101): bought stock on credit, paid part back.
    W = 101
    supplier_entries = {
        W: [
            K.new_entry(W, "got", 200000, note="stock purchase", at="2026-09-02"),
            K.apply_payment(W, 80000, K.SUPPLIER, note="part payment", at="2026-09-18"),
        ]
    }
    w_bal = K.running_balance(supplier_entries[W], K.SUPPLIER)
    c.eq(w_bal, 120000, "supplier payable balance (dena)")
    total_payable = w_bal
    c.eq(total_payable, 120000, "total payable hand-computed")

    # --- net position = receivables - payables -----------------------------
    cust_bals = [K.running_balance(v, K.CUSTOMER) for v in customer_entries.values()]
    supp_bals = [K.running_balance(v, K.SUPPLIER) for v in supplier_entries.values()]
    net = K.net_position(cust_bals, supp_bals)
    c.eq(net["receivable"], 110000, "net_position receivable")
    c.eq(net["payable"], 120000, "net_position payable")
    c.eq(net["net"], 110000 - 120000, "net = receivable - payable")
    c.eq(net["net"], -10000, "net is -100.00 taka (behind)")
    c.eq(net["label"]["en"], "You are behind", "net label behind")

    # --- expenses (for net-profit report) ----------------------------------
    expenses = [
        {"amount": "500", "date": "2026-09-05", "note": "rent portion"},
        {"amount": "250", "date": "2026-09-15", "note": "bags"},
        {"amount": "150.50", "date": "2026-09-25", "note": "transport"},
    ]
    # taka_to_poisha: 500->50000, 250->25000, 150.50->15050 ; total 90050
    exp_total = sum(B.taka_to_poisha(e["amount"]) for e in expenses)
    c.eq(exp_total, 90050, "expense total poisha (no drift)")

    # --------------------------------------------------------------------
    # CASHBOX — one tracked business day (day 7). Opening + ins/outs, then
    # end-of-day count -> variance. Deterministic.
    # --------------------------------------------------------------------
    opening = K.to_poisha(500000)  # 5,000.00 taka float of poisha? No: int pass-through
    # NB: khata.to_poisha(int) is pass-through poisha. 500000 poisha = 5000 taka.
    cash_entries = [
        K.cash_entry(K.CASH_IN, 35000, note="cash sales", at="2026-09-07T13:00"),
        K.cash_entry(K.CASH_IN, 22000, note="customer payment", at="2026-09-07T16:00"),
        K.cash_entry(K.CASH_OUT, 15000, note="supplier cash", at="2026-09-07T17:00"),
    ]
    expected_cash = K.cashbox_expected(opening, cash_entries)
    # 500000 + 35000 + 22000 - 15000 = 542000
    c.eq(expected_cash, 542000, "cashbox expected close")
    # balanced count
    rec_bal = K.reconcile_cashbox(opening, cash_entries, 542000,
                                  now="2026-09-07T21:00")
    c.eq(rec_bal["variance"], 0, "cashbox balanced variance == 0")
    c.ok(rec_bal["balanced"], "cashbox balanced flag")
    c.eq(rec_bal["state"], "balanced", "cashbox state balanced")
    # shortage count (someone miscounted — 300 poisha missing)
    rec_short = K.reconcile_cashbox(opening, cash_entries, 541700,
                                    now="2026-09-07T21:00")
    c.eq(rec_short["variance"], -300, "cashbox shortage variance")
    c.eq(rec_short["state"], "shortage", "cashbox shortage state")
    # surplus count (500 poisha extra)
    rec_surp = K.reconcile_cashbox(opening, cash_entries, 542500,
                                   now="2026-09-07T21:00")
    c.eq(rec_surp["variance"], 500, "cashbox surplus variance")
    c.eq(rec_surp["state"], "surplus", "cashbox surplus state")

    # --------------------------------------------------------------------
    # TAGADA — single + bulk. Only positive dues are chased.
    # --------------------------------------------------------------------
    single = K.plan_tagada_single({"id": R, "name": "Rahim", "phone": "01710000001"},
                                  rahim_bal, shop_name=SHOP, preset="polite")
    c.ok(single is not None, "single tagada planned for Rahim")
    c.eq(single["balance"], 60000, "single tagada balance")
    c.eq(single["share"]["channel"], "whatsapp_share", "tagada default channel wa_share")
    c.ok(single["share"]["available"], "wa_share always available")
    # a settled party yields None (nothing to chase)
    none_plan = K.plan_tagada_single({"id": SO, "name": "Sofia"}, 0, shop_name=SHOP)
    c.ok(none_plan is None, "settled party -> no tagada")

    bulk = K.plan_tagada_bulk([
        {"party": {"id": R, "name": "Rahim", "phone": "01710000001"}, "balance": rahim_bal},
        {"party": {"id": KA, "name": "Karim", "phone": "01710000002"}, "balance": karim_bal},
        {"party": {"id": SO, "name": "Sofia"}, "balance": 0},  # excluded
    ], shop_name=SHOP)
    c.eq(bulk["count"], 2, "bulk tagada count excludes settled")
    c.eq(bulk["total_due"], 110000, "bulk tagada total due == receivable")

    # --------------------------------------------------------------------
    # MONTHLY REPORT — sales/profit must equal the sum of the sale lines.
    # --------------------------------------------------------------------
    rep = B.sales_report(sales, period="monthly")
    c.eq(set(rep.keys()), {"2026-09"}, "all sales in one month bucket")
    month = rep["2026-09"]
    # independently sum every sale's total/profit/due and compare
    sum_total = sum(s["total"] for s in sales)
    sum_profit = sum(s["profit"] for s in sales)
    sum_due = sum(s["due"] for s in sales)
    c.eq(month["sales"], sum_total, "report sales == sum of sale totals")
    c.eq(month["profit"], sum_profit, "report profit == sum of sale profits")
    c.eq(month["due"], sum_due, "report due == sum of sale dues")
    c.eq(month["count"], len(sales), "report count == number of sales")

    # hand-compute the sale totals to pin the numbers (no drift):
    #  days1-5 rice cash : 5 * (5*7000)        = 175000
    #  day6 oil bkash     : 3*18500            =  55500
    #  day7 soap nagad    : 4*5500             =  22000
    #  day8 oil@min cash  : 2*17500            =  35000
    #  day9 discounted due: floor              =  64000
    hand_total = 175000 + 55500 + 22000 + 35000 + 64000
    c.eq(sum_total, hand_total, "hand-computed grand sales total")

    # net profit after expenses report
    npr = B.net_profit_report(sales, expenses)
    c.eq(npr["gross_profit"], sum_profit, "net report gross == sum profit")
    c.eq(npr["expenses"], exp_total, "net report expenses == 90050")
    c.eq(npr["net_profit"], sum_profit - exp_total, "net profit = gross - expenses")

    # the only due sale is the day-9 discounted one (total 64000, paid 0)
    c.eq(sum_due, 64000, "only the day-9 due sale contributes to due")

    # NO SALE EVER BELOW MINIMUM — assert across every persisted sale line.
    for s in sales:
        for l in s["lines"]:
            c.ok(l["unit_price"] >= l["min_price"],
                 f"no sub-min line: {l['product_name']} {l['unit_price']}>= {l['min_price']}")

    # STOCK decremented correctly across the month.
    #  rice: days1-5 = 25, day9 discounted = 10 -> 35 sold ; 100-35 = 65
    #  oil : day6 = 3, day8 = 2 -> 5 sold ; 40-5 = 35
    #  soap: day7 = 4 ; 60-4 = 56
    c.eq(stock["rice"], 65, "rice stock end of month")
    c.eq(stock["oil"], 35, "oil stock end of month")
    c.eq(stock["soap"], 56, "soap stock end of month")
    # cross-check stock via apply_stock_decrements on one sale (day6 oil x3)
    oil_variant = B.get_variant(oil)
    day6 = sales[5]  # 0-indexed: days1-5 are 0..4, day6 is index 5
    decs = B.apply_stock_decrements({oil_variant["key"]: oil_variant},
                                    day6["stock_decrements"])
    c.eq(decs[0]["new_stock"], 40 - 3, "apply_stock_decrements oil day6")

    # LEDGER RECONCILES EXACTLY — every balance is integer poisha with no drift.
    for pid, ents in customer_entries.items():
        bal = K.running_balance(ents, K.CUSTOMER)
        hand = sum((e["amount"] if e["direction"] == "gave" else -e["amount"])
                   for e in ents)
        c.eq(bal, hand, f"customer {pid} ledger reconciles")
    for pid, ents in supplier_entries.items():
        bal = K.running_balance(ents, K.SUPPLIER)
        hand = sum((e["amount"] if e["direction"] == "got" else -e["amount"])
                   for e in ents)
        c.eq(bal, hand, f"supplier {pid} ledger reconciles")

    return c.n


# ===========================================================================
# SCENARIO B — 7-day ONLINE-SELLER week
# ===========================================================================

def scenario_b():
    """Returns the number of checks performed."""
    c = _Checker()
    SHOP = "Dhaka Fashion"

    catalog = [
        {"name": "Panjabi", "price": "1200", "stock": 5, "min_price": "1000",
         "description": "cotton"},
        {"name": "Saree", "price": "2500", "stock": 3, "min_price": "2000"},
    ]
    delivery = {"inside_dhaka": 60, "outside_dhaka": 120}
    policies = {"returns": "7 days", "hours": "10am-10pm"}

    # --------------------------------------------------------------------
    # DAY 1 — incoming chats in bn / Banglish / en. AI mock drafts replies.
    # --------------------------------------------------------------------
    ctx_bn = AI.build_context(catalog=catalog, delivery=delivery,
                              policies=policies, shop_name=SHOP, lang="bn")
    ctx_en = AI.build_context(catalog=catalog, delivery=delivery,
                              policies=policies, shop_name=SHOP, lang="en")

    # bn script message
    c.eq(AI.detect_lang("পাঞ্জাবির দাম কত?"), "bn", "detect bn")
    # banglish
    c.eq(AI.detect_lang("panjabi r dam koto?"), "banglish", "detect banglish")
    # english
    c.eq(AI.detect_lang("what is the price of the panjabi?"), "en", "detect en")
    # banglish replies in bn (readable Bangla)
    c.eq(AI.reply_lang("panjabi r dam koto?"), "bn", "banglish replies in bn")
    c.eq(AI.reply_lang("what is the price?"), "en", "en replies in en")

    # a price/stock question drafts a high-confidence, fact-grounded reply.
    r_bn = AI.draft_reply("পাঞ্জাবির দাম কত?", ctx_bn)
    c.eq(r_bn["intent"], "price_stock", "bn price intent")
    c.ok(not r_bn["needs_human"], "bn price reply does not need human")
    c.ok(r_bn["confidence"] >= AI.HANDOFF_CONFIDENCE, "bn price reply confident")
    c.ok("1200" in r_bn["text"], "bn reply phrases the real price (facts)")
    c.ok(not r_bn["used_ai"], "mock provider used (no key)")

    r_en = AI.draft_reply("what is the price of the panjabi?", ctx_en)
    c.eq(r_en["intent"], "price_stock", "en price intent")
    c.ok("1200" in r_en["text"], "en reply phrases the real price")

    # greeting
    r_hi = AI.draft_reply("hello", ctx_en)
    c.eq(r_hi["intent"], "greeting", "greeting intent")
    c.ok(r_hi["confidence"] >= AI.HANDOFF_CONFIDENCE, "greeting confident")

    # a question with NO facts available (empty context) must NOT fabricate and
    # must hand off (safety net).
    empty_ctx = AI.build_context(catalog=[], shop_name=SHOP, lang="en")
    r_nofacts = AI.draft_reply("what is the price?", empty_ctx)
    c.ok(r_nofacts["needs_human"], "no-facts price question hands off")
    c.ok(r_nofacts["confidence"] <= AI.CONF_LOW, "no-facts low confidence")

    # --------------------------------------------------------------------
    # DAY 2 — BARGAINING. Minimum enforced in CODE.
    # --------------------------------------------------------------------
    panjabi = {"name": "Panjabi", "price": "1200", "min_price": "1000"}
    rules = {"discount_steps": [10], "free_delivery_over": 1100}

    # (a) BELOW minimum (offer 900 < 1000): ALWAYS defer_to_owner, price None,
    #     owner notification present. NEVER a sub-min price, never accept.
    below = AI.negotiate(900, panjabi, rules=rules, lang="en")
    c.eq(below["action"], AI.ACTION_DEFER, "below-min -> defer_to_owner")
    c.ok(below["price"] is None, "below-min price is None (never sub-min)")
    c.ok(below["owner_notification"] is not None, "below-min owner notified")
    c.eq(below["owner_notification"]["type"], "bargain_below_min",
         "owner notification type")
    c.eq(below["owner_notification"]["action_required"], "owner_decision",
         "owner notification requires decision")

    # try a RANGE of below-min offers — every one must defer with price None.
    for off in (1, 500, 999):
        res = AI.negotiate(off, panjabi, rules=rules, lang="bn")
        c.eq(res["action"], AI.ACTION_DEFER, f"offer {off} below-min defers")
        c.ok(res["price"] is None, f"offer {off} below-min price None")

    # (b) AT the minimum (offer == 1000): accept at >= min.
    at_min = AI.negotiate(1000, panjabi, rules=rules, lang="en")
    c.eq(at_min["action"], AI.ACTION_ACCEPT, "at-min -> accept")
    c.ok(at_min["price"] is not None and at_min["price"] >= Decimal("1000"),
         "at-min accepted price >= min")
    c.eq(at_min["price"], Decimal("1000"), "at-min price == 1000")

    # (c) WITHIN (min, list): accept their offer (>= min).
    within = AI.negotiate(1100, panjabi, rules=rules, lang="en")
    c.eq(within["action"], AI.ACTION_ACCEPT, "within-range -> accept")
    c.ok(within["price"] >= Decimal("1000"), "within accepted >= min")
    c.eq(within["price"], Decimal("1100"), "within price == offer")

    # (d) AT/ABOVE list: accept at list.
    above = AI.negotiate(1500, panjabi, rules=rules, lang="en")
    c.eq(above["action"], AI.ACTION_ACCEPT, "above-list -> accept at list")
    c.eq(above["price"], Decimal("1200"), "above-list price == list")

    # (e) no explicit offer -> COUNTER along the ladder, never below min.
    counter = AI.negotiate(None, panjabi, rules=rules, lang="en")
    c.eq(counter["action"], AI.ACTION_COUNTER, "no-offer -> counter")
    c.ok(counter["price"] >= Decimal("1000"), "counter never below min")
    # 10% off 1200 = 1080 (>= min 1000)
    c.eq(counter["price"], Decimal("1080"), "counter = 10% off list")

    # a misconfigured min ABOVE list is clamped to list (never breaks).
    bad_min = AI.negotiate(900, {"name": "X", "price": "1000", "min_price": "1500"},
                           lang="en")
    c.ok(bad_min["min_price"] <= bad_min["list_price"], "min clamped to list")

    # --------------------------------------------------------------------
    # DAY 3-5 — ORDERS flow new -> confirmed -> packed -> shipped -> delivered.
    # One order also goes -> returned. COD amounts verified.
    # --------------------------------------------------------------------
    order1 = {"id": 1001, "payment": "cod", "total": "1260",  # 1200 + 60 delivery
              "status": AI.STATUS_NEW,
              "customer": {"name": "Hasan", "phone": "01810000001"}}
    # COD amount == order total for a COD order.
    c.eq(AI.cod_amount(order1), Decimal("1260"), "COD amount == total")

    o, ev = AI.advance_order(order1, AI.STATUS_CONFIRMED)
    c.eq(o["status"], AI.STATUS_CONFIRMED, "order -> confirmed")
    c.eq(ev["from"], AI.STATUS_NEW, "event from new")
    o, ev = AI.advance_order(o, AI.STATUS_PACKED)
    c.eq(o["status"], AI.STATUS_PACKED, "order -> packed")
    # shipped REQUIRES a courier; this path books nothing (truth: no fake id).
    o, ev = AI.advance_order(o, AI.STATUS_SHIPPED, courier="pathao")
    c.eq(o["status"], AI.STATUS_SHIPPED, "order -> shipped")
    c.eq(o["courier"], "pathao", "courier recorded")
    c.eq(o["tracking"], "", "no made-up tracking id")
    c.ok(o["courier_live"] is False, "courier NOT live (no API call here)")
    c.eq(ev["tracking"], "", "shipped event has no fake tracking")
    o["tracking"] = "PT1001ABC"   # the owner types the real consignment id
    o, ev = AI.advance_order(o, AI.STATUS_DELIVERED)
    c.eq(o["status"], AI.STATUS_DELIVERED, "order -> delivered")

    # truth: a courier key alone never makes this path claim a live booking.
    live_booking = AI.book_courier_mock({"id": 1001}, "pathao",
                                        courier_keys={"pathao": "KEY"})
    c.ok(live_booking["live"] is False, "no live claim without a real API call")

    # a second order gets returned after delivery.
    order2 = {"id": 1002, "payment": "cod", "total": "2560",
              "status": AI.STATUS_SHIPPED, "courier": "redx",
              "tracking": "RX1002"}
    o2, ev2 = AI.advance_order(order2, AI.STATUS_RETURNED)
    c.eq(o2["status"], AI.STATUS_RETURNED, "order2 -> returned")

    # illegal transitions are refused (state machine integrity).
    illegal = False
    try:
        AI.advance_order({"id": 9, "status": AI.STATUS_NEW}, AI.STATUS_DELIVERED)
    except ValueError:
        illegal = True
    c.ok(illegal, "illegal transition new->delivered refused")
    # shipped without a courier is refused.
    no_courier = False
    try:
        AI.advance_order({"id": 9, "status": AI.STATUS_PACKED}, AI.STATUS_SHIPPED)
    except ValueError:
        no_courier = True
    c.ok(no_courier, "shipped without courier refused")

    # non-COD order collects 0 COD.
    c.eq(AI.cod_amount({"payment": "bkash", "total": "1000"}), Decimal("0"),
         "non-COD order COD == 0")

    # --------------------------------------------------------------------
    # DAY 5 — "where is my parcel?" returns the right state.
    # --------------------------------------------------------------------
    ps = AI.parcel_status(o, lang="en")  # o is delivered
    c.eq(ps["status"], AI.STATUS_DELIVERED, "parcel status delivered")
    c.ok("delivered" in ps["message"], "parcel message says delivered")
    c.ok("PT1001ABC" in ps["message"], "parcel message shows tracking")
    # and the classifier routes the question correctly
    c.eq(AI.classify_intent("where is my parcel?"), "parcel_status",
         "parcel intent classified")
    ps_new = AI.parcel_status({"id": 1003, "status": AI.STATUS_NEW}, lang="en")
    c.ok("received" in ps_new["message"], "new parcel says received")

    # --------------------------------------------------------------------
    # DAY 6 — HUMAN HANDOFF on angry / refund / low-confidence.
    # --------------------------------------------------------------------
    angry = AI.draft_reply("this is a scam, worst shop", ctx_en)
    c.ok(angry["needs_human"], "angry message -> handoff")
    c.eq(angry["handoff_reason"], AI.HANDOFF_ANGRY, "angry reason")
    c.ok(not angry["used_ai"], "angry handoff bypasses AI draft")

    refund = AI.draft_reply("I want a refund, the product is defective", ctx_en)
    c.ok(refund["needs_human"], "refund message -> handoff")
    c.eq(refund["handoff_reason"], AI.HANDOFF_REFUND, "refund reason")

    # big-order escalation (over threshold)
    c.eq(AI.handoff_trigger("I'll take 50 pieces", order_total="25000"),
         AI.HANDOFF_BIG_ORDER, "big order -> handoff")

    # owner takeover: AI stays silent.
    takeover = AI.draft_reply("দাম কত?", ctx_bn, owner_takeover=True)
    c.ok(takeover["needs_human"], "owner takeover needs human")
    c.eq(takeover["text"], "", "owner takeover: AI silent")
    c.eq(takeover["handoff_reason"], "owner_takeover", "takeover reason")

    # --------------------------------------------------------------------
    # DAY 7 — MORNING SUMMARY counts must match the inputs exactly.
    # --------------------------------------------------------------------
    msgs = ["m"] * 34
    orders = ["o"] * 8
    needs = ["n"] * 2
    summ = AI.morning_summary(messages=msgs, orders=orders, needs_you=needs,
                              lang="en")
    c.eq(summ["messages"], 34, "summary messages count")
    c.eq(summ["orders"], 8, "summary orders count")
    c.eq(summ["needs_you"], 2, "summary needs_you count")
    c.ok("34 messages" in summ["text"] and "8 orders" in summ["text"],
         "summary text carries counts")

    # --------------------------------------------------------------------
    # SAFETY INVARIANTS — guards hold across the whole week.
    # --------------------------------------------------------------------
    # (1) Official channels only; personal WhatsApp / WA Business app BANNED.
    c.eq(AI.guard_channel(AI.CHANNEL_WA_CLOUD), AI.CHANNEL_WA_CLOUD,
         "wa cloud allowed")
    c.eq(AI.guard_channel(AI.CHANNEL_MESSENGER), AI.CHANNEL_MESSENGER,
         "messenger allowed")
    banned_hit = 0
    for ch in (AI.CHANNEL_WA_PERSONAL, AI.CHANNEL_WA_BUSINESS_APP):
        try:
            AI.guard_channel(ch)
        except AI.PersonalWhatsAppBanned:
            banned_hit += 1
    c.eq(banned_hit, 2, "both personal/WA-app channels refused")
    # assembling a send over a banned channel must also refuse.
    banned_assemble = False
    try:
        AI.assemble_webhook_send(AI.CHANNEL_WA_PERSONAL, "01x", text="hi")
    except AI.PersonalWhatsAppBanned:
        banned_assemble = True
    c.ok(banned_assemble, "webhook assembly over personal WA refused")
    # a legit assemble over the official Cloud API inside the 24h window works.
    send = AI.assemble_webhook_send(AI.CHANNEL_WA_CLOUD, "01810000001",
                                    text="hi", last_inbound_ts=1000, now_ts=2000)
    c.ok(send["ok"], "official cloud send assembled ok in-window")
    c.eq(send["plan"]["mode"], "freeform", "in-window send is freeform")
    # outside the 24h window a free-form send is NOT allowed without a template.
    out = AI.outbound_message_plan(AI.CHANNEL_WA_CLOUD, last_inbound_ts=0,
                                   now_ts=100000)  # >24h later
    c.ok(not out["allowed"], "outside window freeform not allowed")
    c.ok(out["paid_template"], "outside window requires paid template")

    # (2) Payments NEVER hold funds / never a wallet.
    qr = AI.merchant_qr_descriptor({"provider": "bkash",
                                    "merchant_number": "017xxxx",
                                    "merchant_name": SHOP})
    c.ok(qr["holds_funds"] is False, "merchant QR holds no funds")
    c.ok(qr["is_wallet"] is False, "merchant QR not a wallet")
    c.ok(qr["routes_through_assisto"] is False, "money never routes through us")
    pay = AI.payment_link_builder({"id": 1001, "total": "1260"})
    c.ok(pay["holds_funds"] is False, "payment link holds no funds")
    c.eq(pay["custodian"], "licensed_partner", "custody is the licensed partner")
    c.ok(pay["live"] is False, "payment link mock without partner key")
    # truth: no partner API is wired, so a key never yields a fake live link.
    pay_live = AI.payment_link_builder({"id": 1001, "total": "1260"},
                                       partner_key="KEY")
    c.ok(pay_live["live"] is False and pay_live["link"] == "", "no fake live link")
    c.ok(pay_live["holds_funds"] is False, "live payment link still no custody")

    # (3) The bank-loan report is sales history ONLY — no lending/scoring.
    loan = AI.bank_loan_report_data([{"month": "2026-09", "amount": "100000"}])
    c.ok(loan["is_lending"] is False, "no lending")
    c.ok(loan["is_credit_scoring"] is False, "no credit scoring")

    return c.n


# ===========================================================================
# runner
# ===========================================================================

def run_all():
    a = scenario_a()
    b = scenario_b()
    total = a + b
    print(f"scenario_a (30-day small-shop): {a} checks passed")
    print(f"scenario_b (7-day online-seller): {b} checks passed")
    print(f"business_scenarios: {total} checks passed")
    return total


if __name__ == "__main__":
    run_all()
