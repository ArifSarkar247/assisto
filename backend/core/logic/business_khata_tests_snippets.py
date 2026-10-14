"""
business_khata_tests_snippets.py — plain-assert tests for business_khata.py.

NOT a Django TestCase (no DB). Every function takes no args and raises
AssertionError on failure. Smoke them with:

    python3 -c "import core.logic.business_khata_tests_snippets as t; t.run_all()"

Covers every public function in business_khata (money helpers, two-sided
ledger, tagada planners, cashbox, statement PDF data model).
"""
from decimal import Decimal

from core.logic import business_khata as K


# ---------------------------------------------------------------------------
# money helpers
# ---------------------------------------------------------------------------

def test_to_poisha_types():
    assert K.to_poisha(12550) == 12550              # int = poisha pass-through
    assert K.to_poisha(Decimal("125.50")) == 12550  # taka Decimal
    assert K.to_poisha("125.50") == 12550
    assert K.to_poisha("৳১২৫.৫০") == 12550          # Bangla + currency marker
    assert K.to_poisha(125.5) == 12550              # float, rounded via Decimal(str)
    assert K.to_poisha("Tk 1,000") == 100000
    assert K.to_poisha(None) == 0
    assert K.to_poisha("") == 0
    assert K.to_poisha("junk") == 0
    assert K.to_poisha(True) == 0                   # bool guarded


def test_to_poisha_no_float_drift():
    # classic float-drift trap: 0.1 + 0.2 in taka must be exactly 30 poisha
    total = K.to_poisha("0.10") + K.to_poisha("0.20")
    assert total == 30, total


def test_taka_str_and_fmt():
    assert K.taka_str(12550, "en") == "125.50"
    assert K.taka_str(12550, "bn") == "১২৫.৫০"
    assert K.taka_str(-500, "en") == "-5.00"
    assert K.taka_str(5, "en") == "0.05"
    f = K.fmt_amount(12550)
    assert f == {"bn": "৳১২৫.৫০", "en": "৳125.50"}, f


def test_normalize_digits_both_ways():
    assert K.normalize_digits("১২৩") == "123"
    assert K.normalize_digits_out("123") == "১২৩"


def test_bn_en():
    assert K.bn_en("ক", "a") == {"bn": "ক", "en": "a"}


# ---------------------------------------------------------------------------
# two-sided ledger — customer (বাকি)
# ---------------------------------------------------------------------------

def _cust_entries():
    return [
        {"party_id": 1, "direction": "gave", "amount": 50000, "at": "2026-10-01"},  # ৳500 credit
        {"party_id": 1, "direction": "gave", "amount": 30000, "at": "2026-10-03"},  # ৳300 credit
        {"party_id": 1, "direction": "got", "amount": 20000, "at": "2026-10-05"},   # ৳200 paid
    ]


def test_customer_running_balance():
    bal = K.running_balance(_cust_entries(), K.CUSTOMER)
    assert bal == 60000, bal  # 500 + 300 - 200 = ৳600 owed


def test_customer_statement_running():
    party = {"id": 1, "name": "Rahim", "phone": "01712345678"}
    st = K.party_statement(party, _cust_entries(), K.CUSTOMER, lang="en")
    assert st["balance"] == 60000
    # running balance after each row
    assert [r["balance"] for r in st["entries"]] == [50000, 80000, 60000]
    assert st["balance_fmt"]["en"] == "৳600.00"
    assert st["status"] == K.bn_en("বাকি ৳৬০০.০০", "Due ৳600.00")
    assert st["owes_label"]["en"] == "Customer owes you"


def test_partial_payment_customer():
    pay = K.apply_payment(1, "200", K.CUSTOMER, at="2026-10-05")
    assert pay["direction"] == "got"
    assert pay["amount"] == 20000
    entries = _cust_entries()[:2] + [pay]
    assert K.running_balance(entries, K.CUSTOMER) == 60000


def test_customer_advance_negative():
    # customer paid more than owed -> advance (negative balance)
    entries = [{"party_id": 2, "direction": "gave", "amount": 10000, "at": "2026-10-01"},
               {"party_id": 2, "direction": "got", "amount": 15000, "at": "2026-10-02"}]
    bal = K.running_balance(entries, K.CUSTOMER)
    assert bal == -5000
    st = K.party_statement({"id": 2, "name": "X"}, entries, K.CUSTOMER)
    assert st["status"] == K.bn_en("অগ্রিম ৳৫০.০০", "Advance ৳50.00")
    assert st["owes_label"]["en"] == "You owe the customer"


# ---------------------------------------------------------------------------
# two-sided ledger — supplier (দেনা)
# ---------------------------------------------------------------------------

def test_supplier_running_balance():
    entries = [
        {"party_id": 9, "direction": "got", "amount": 100000, "at": "2026-10-01"},  # got goods ৳1000
        {"party_id": 9, "direction": "gave", "amount": 40000, "at": "2026-10-04"},  # paid ৳400
    ]
    bal = K.running_balance(entries, K.SUPPLIER)
    assert bal == 60000, bal  # owner still owes ৳600
    st = K.party_statement({"id": 9, "name": "Wholesaler"}, entries, K.SUPPLIER)
    assert st["status"] == K.bn_en("দেনা ৳৬০০.০০", "Payable ৳600.00")
    assert st["owes_label"]["en"] == "You owe the supplier"


def test_supplier_payment_helper():
    pay = K.apply_payment(9, "400", K.SUPPLIER)
    assert pay["direction"] == "gave"  # owner pays supplier
    assert pay["amount"] == 40000


# ---------------------------------------------------------------------------
# new_entry validation
# ---------------------------------------------------------------------------

def test_new_entry_validation():
    e = K.new_entry(1, "gave", "500", note="rice", at="2026-10-01",
                    bill_photo_ref="img/1.jpg")
    assert e == {"party_id": 1, "direction": "gave", "amount": 50000,
                 "note": "rice", "at": "2026-10-01", "bill_photo_ref": "img/1.jpg"}
    for bad in (lambda: K.new_entry(1, "sideways", 100),
                lambda: K.new_entry(1, "gave", 0),
                lambda: K.new_entry(1, "gave", -5)):
        try:
            bad()
            assert False, "expected ValueError"
        except ValueError:
            pass


# ---------------------------------------------------------------------------
# net position across all parties
# ---------------------------------------------------------------------------

def test_net_position():
    # customers owe 600 + 200; one customer advance -50. Suppliers owe 600.
    np = K.net_position(customer_balances=[60000, 20000, -5000],
                        supplier_balances=[60000])
    assert np["receivable"] == 80000
    assert np["customer_advances"] == 5000
    assert np["payable"] == 60000
    # net = (receivable 80000 + supplier_advances 0) - (payable 60000 + cust_adv 5000)
    assert np["net"] == 15000
    assert np["label"]["en"] == "You are ahead"


def test_net_position_behind():
    np = K.net_position(customer_balances=[10000], supplier_balances=[90000])
    assert np["net"] == -80000
    assert np["label"]["en"] == "You are behind"


# ---------------------------------------------------------------------------
# tagada planners
# ---------------------------------------------------------------------------

def test_tagada_message_bilingual():
    party = {"id": 1, "name": "Rahim", "phone": "01712345678"}
    pair = K.tagada_message(party, 60000, shop_name="Rahim Store", preset="polite")
    assert "৳৬০০.০০" in pair["bn"]
    assert "৳600.00" in pair["en"]
    assert "Rahim Store" in pair["en"]
    # single-language convenience
    bn_only = K.tagada_message(party, 60000, shop_name="S", lang="bn")
    assert isinstance(bn_only, str) and "৳৬০০.০০" in bn_only


def test_tagada_message_pay_hint():
    party = {"name": "Karim"}
    pair = K.tagada_message(party, 50000, shop_name="S", preset="reminder",
                            pay_hint={"method": "bKash", "number": "01711111111"})
    assert "bKash" in pair["en"] and "01711111111" in pair["en"]
    assert "bKash" in pair["bn"] and "০১৭১১১১১১১১" in pair["bn"]  # bn digits


def test_share_descriptor_whatsapp_always():
    d = K.share_descriptor("whatsapp_share", "01712345678", "hi")
    assert d["available"] is True and d["channel"] == "whatsapp_share"


def test_share_descriptor_sms_gated():
    off = K.share_descriptor("sms", "01712345678", "hi", sms_enabled=False)
    assert off["available"] is False and "reason" in off
    on = K.share_descriptor("sms", "01712345678", "hi", sms_enabled=True)
    assert on["available"] is True
    try:
        K.share_descriptor("telegram", "x", "y")
        assert False
    except ValueError:
        pass


def test_plan_tagada_single():
    party = {"id": 1, "name": "Rahim", "phone": "01712345678"}
    plan = K.plan_tagada_single(party, 60000, shop_name="S", lang="bn")
    assert plan["party_id"] == 1
    assert plan["share"]["channel"] == "whatsapp_share"
    assert plan["share"]["text"] == plan["message"]["bn"]
    # no due -> skipped
    assert K.plan_tagada_single(party, 0) is None
    assert K.plan_tagada_single(party, -100) is None


def test_plan_tagada_bulk_filters():
    rows = [
        {"party": {"id": 1, "name": "A", "phone": "011"}, "balance": 60000},
        {"party": {"id": 2, "name": "B", "phone": "012"}, "balance": 0},       # settled
        {"party": {"id": 3, "name": "C", "phone": "013"}, "balance": -500},    # advance
        {"party": {"id": 4, "name": "D", "phone": "014"}, "balance": 5000},    # ৳50, below ৳100
    ]
    res = K.plan_tagada_bulk(rows, shop_name="S", min_due="100")  # ৳100 threshold
    ids = [p["party_id"] for p in res["plans"]]
    assert ids == [1], ids  # only ৳600 due clears the ৳100 threshold
    assert res["count"] == 1
    assert res["total_due"] == 60000
    # no threshold -> every positive due (1 and 4), settled/advance excluded
    res2 = K.plan_tagada_bulk(rows, shop_name="S")
    assert [p["party_id"] for p in res2["plans"]] == [1, 4]
    assert res2["total_due"] == 65000


def test_plan_tagada_scheduled():
    party = {"id": 1, "name": "A", "phone": "011"}
    sched = {"next_at": "2026-10-10T09:00:00"}
    # before the scheduled time -> not due
    r = K.plan_tagada_scheduled(party, 50000, sched, now="2026-10-09T09:00:00")
    assert r["due"] is False and r["plan"] is None
    # at/after -> due, plan built
    r2 = K.plan_tagada_scheduled(party, 50000, sched, now="2026-10-10T09:00:00")
    assert r2["due"] is True and r2["plan"]["party_id"] == 1
    # due time passed but nothing owed -> not fired
    r3 = K.plan_tagada_scheduled(party, 0, sched, now="2026-10-11T00:00:00")
    assert r3["due"] is False


def test_entry_added_message():
    party = {"name": "Rahim"}
    e = K.new_entry(1, "gave", "500")
    msg = K.entry_added_message(party, e, shop_name="S")
    assert "৳৫০০.০০" in msg["bn"] and "৳500.00" in msg["en"]
    # a payment ('got') produces no courtesy add message
    assert K.entry_added_message(party, K.new_entry(1, "got", "500")) is None
    single = K.entry_added_message(party, e, lang="en")
    assert isinstance(single, str)


# ---------------------------------------------------------------------------
# cashbox
# ---------------------------------------------------------------------------

def _cash_entries():
    return [
        {"kind": "in", "amount": 150000, "note": "sale", "at": "2026-10-10T10:00"},
        {"kind": "in", "amount": 50000, "note": "sale", "at": "2026-10-10T12:00"},
        {"kind": "out", "amount": 30000, "note": "supplier", "at": "2026-10-10T14:00"},
    ]


def test_cash_entry_validation():
    e = K.cash_entry("in", "1500", note="sale", at="t", ref="r1")
    assert e == {"kind": "in", "amount": 150000, "note": "sale", "at": "t", "ref": "r1"}
    for bad in (lambda: K.cash_entry("sideways", 100),
                lambda: K.cash_entry("in", 0)):
        try:
            bad(); assert False
        except ValueError:
            pass


def test_cashbox_expected_and_summary():
    opening = 100000  # ৳1000
    exp = K.cashbox_expected(opening, _cash_entries())
    assert exp == 270000, exp  # 1000 + 1500 + 500 - 300 = ৳2700
    s = K.cashbox_summary(opening, _cash_entries())
    assert s["total_in"] == 200000
    assert s["total_out"] == 30000
    assert s["expected"] == 270000
    assert [r["balance"] for r in s["ledger"]] == [250000, 300000, 270000]
    assert s["expected_fmt"]["en"] == "৳2700.00"


def test_reconcile_balanced():
    r = K.reconcile_cashbox(100000, _cash_entries(), counted_cash=270000)
    assert r["balanced"] is True and r["state"] == "balanced"
    assert r["variance"] == 0


def test_reconcile_shortage_and_surplus():
    short = K.reconcile_cashbox(100000, _cash_entries(), counted_cash="2650")
    assert short["state"] == "shortage" and short["variance"] == -5000
    assert "ঘাটতি" in short["status"]["bn"]
    surplus = K.reconcile_cashbox(100000, _cash_entries(), counted_cash="2750")
    assert surplus["state"] == "surplus" and surplus["variance"] == 5000
    assert "Surplus" in surplus["status"]["en"]


# ---------------------------------------------------------------------------
# statement PDF data model
# ---------------------------------------------------------------------------

def test_statement_pdf_data_full():
    biz = {"shop_name": "Rahim Store", "phone": "01700000000"}
    party = {"id": 1, "name": "Rahim", "phone": "01712345678", "area": "Mirpur"}
    data = K.statement_pdf_data(biz, party, _cust_entries(), book=K.CUSTOMER,
                                now="2026-10-12T00:00:00")
    assert data["doc_type"] == "customer_statement"
    assert data["shop"]["name"] == "Rahim Store"
    assert data["opening_balance"] == 0
    assert len(data["lines"]) == 3
    # debit/credit split: gave -> debit, got -> credit
    assert data["lines"][0]["debit"] == 50000 and data["lines"][0]["credit"] == 0
    assert data["lines"][2]["credit"] == 20000 and data["lines"][2]["debit"] == 0
    assert data["totals"]["gave"] == 80000
    assert data["totals"]["got"] == 20000
    assert data["totals"]["closing_balance"] == 60000
    assert data["headers"]["title"]["en"] == "Customer Statement"
    assert "money" in data["footer"]["en"].lower()


def test_statement_pdf_data_period_opening():
    party = {"id": 1, "name": "R"}
    data = K.statement_pdf_data({}, party, _cust_entries(), book=K.CUSTOMER,
                                period={"from": "2026-10-03", "to": "2026-10-31"})
    # ৳500 entry on 10-01 is BEFORE the period -> becomes opening balance
    assert data["opening_balance"] == 50000
    assert len(data["lines"]) == 2  # only 10-03 and 10-05 rows in period
    assert data["totals"]["closing_balance"] == 60000  # opening still rolls forward


def test_statement_pdf_data_supplier():
    entries = [{"party_id": 9, "direction": "got", "amount": 100000, "at": "2026-10-01"}]
    data = K.statement_pdf_data({"shop_name": "S"}, {"id": 9, "name": "W"},
                                entries, book=K.SUPPLIER)
    assert data["doc_type"] == "supplier_statement"
    assert data["headers"]["title"]["bn"] == "সরবরাহকারী বিবরণী"
    assert data["totals"]["closing_balance"] == 100000


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"OK — {len(fns)} business_khata tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
