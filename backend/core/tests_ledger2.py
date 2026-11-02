"""ledger2 (flag accounting_v2): business accounting phase 2 on the realistic
grocery fixture (tests_ledger.ShopFixture) — VAT kept in four lines (output /
input / paid / payable; the core bug that netted VAT paid into output VAT),
payment method on khata payments, input VAT + Mushak-6.1 purchase register,
per-product VAT (exempt / owner-typed reduced rate), cashbox reclass from
Suspense, year-end close + reopen with a reason, and the cost-price-0 warning.
Every scenario ends with debits == credits and a balanced balance sheet.
"""
from datetime import date, timedelta

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ledger2_service as L2
from core import ledger_service as S
from core.logic import ledger as L
from core.models import (AuditLog, CashEntry, Expense, JournalEntry, KhataEntry,
                         LedgerBook, PaCollectionItem, Product, Sale, SaleLine)
from core.tests_ledger import ShopFixture

D = date(2026, 10, 15)


def _el(postings):
    """[(day, posting)] -> entry lines the way core.ledger_service.entry_lines
    returns them."""
    out = []
    for i, (d, p) in enumerate(postings):
        for l in p["lines"]:
            out.append({"entry": i, "date": d, "account": l["account"],
                        "debit": l["debit"], "credit": l["credit"]})
    return out


def _bal(e):
    return sum(l["debit"] for l in e["lines"]) == sum(l["credit"] for l in e["lines"])


class PureLedger2Tests(SimpleTestCase):
    def sale(self, sid, total, **kw):
        s = {"id": sid, "date": D, "total": total, "discount": 0, "due": 0,
             "payment_method": "cash", "cogs": 0, "vat_bp": 1500}
        s.update(kw)
        return L.post_sale(s)

    def test_vat_paid_never_netted_into_output_vat(self):
        sale = self.sale(1, 11500)
        pay = L.make_entry("manual:1", D, [L.line(L.OUTPUT_VAT, debit=1000),
                                           L.line(L.BANK, credit=1000)], L._m("x", "x"))
        buy = L.make_entry("acct:b", D, [L.line(L.INVENTORY, debit=4000),
                                         L.line(L.INPUT_VAT, debit=600),
                                         L.line(L.CASH, credit=4600)], L._m("x", "x"))
        v = L.vat_summary(_el([(D, sale), (D, pay), (D, buy)]), D, D)
        self.assertEqual(v["output_vat"], 1500)            # was 500 before ledger2
        self.assertEqual(v["input_vat"], 600)
        self.assertEqual(v["paid"], 1000)
        self.assertEqual(v["net_payable"], 900)
        self.assertEqual(v["still_due"], -100)             # overpaid shows honestly
        self.assertEqual((v["taxable_sales"], v["taxable_purchases"]), (10000, 4000))
        # reversing the payment un-pays it; a void lowers output VAT
        unpay = dict(pay, lines=L.mirror(pay["lines"]))
        void = dict(sale, lines=L.mirror(sale["lines"]))
        v2 = L.vat_summary(_el([(D, sale), (D, pay), (D, unpay), (D, void)]), D, D)
        self.assertEqual((v2["output_vat"], v2["paid"], v2["sale_invoices"]), (0, 0, 0))

    def test_khata_payment_method_posts_to_that_money_account(self):
        base = {"id": 1, "date": D, "amount": 5000, "party": "Karim", "note": ""}
        for method, acc in (("bkash", L.BKASH), ("nagad", L.NAGAD), ("bank", L.BANK),
                            ("cash", L.CASH), ("", L.CASH), ("junk", L.CASH)):
            got = L.post_khata(dict(base, book="customer", direction="got", method=method))
            self.assertEqual(got["lines"][0], L.line(acc, debit=5000), method)
            paid = L.post_khata(dict(base, book="supplier", direction="gave", method=method))
            self.assertIn(L.line(acc, credit=5000), paid["lines"])
        # credit rows move no money: the method is irrelevant
        gave = L.post_khata(dict(base, book="customer", direction="gave", method="bank"))
        self.assertEqual({l["account"] for l in gave["lines"]}, {L.AR, L.SALES_KHATA})
        inv = L.post_invoice({"id": 9, "date": D, "total": 1000, "paid": 1000,
                              "payment_method": "bank"})
        self.assertEqual(inv["lines"][0]["account"], L.BANK)

    def test_product_rate_history_never_changes_the_past(self):
        h = [{"from": "2026-10-10", "mode": "exempt"},
             {"from": "2026-10-20", "mode": "reduced", "vat_bp": 500}]
        self.assertEqual(L.product_rate_on(h, date(2026, 10, 9)), ("standard", None))
        self.assertEqual(L.product_rate_on(h, D), ("exempt", 0))
        self.assertEqual(L.product_rate_on(h, date(2026, 10, 25)), ("reduced", 500))
        self.assertEqual(L.product_rate_on(h + [{"from": "2026-10-30", "mode": "standard"}],
                                           date(2026, 11, 1)), ("standard", None))

    def test_sale_tax_split_exempt_reduced_standard(self):
        lines = [{"product_id": 1, "amount": 11500}, {"product_id": 2, "amount": 10000},
                 {"product_id": 3, "amount": 10500}]
        t, sd, vat, ex = L.sale_tax(32000, lines, 1500, 0,
                                    {2: ("exempt", 0), 3: ("reduced", 500)})
        self.assertEqual(ex, 10000)
        self.assertEqual(vat, 1500 + 500)
        self.assertEqual(t + sd + vat, 32000)
        # discount shared pro rata, sums stay exact
        t, sd, vat, ex = L.sale_tax(31999, lines, 1500, 200, {2: ("exempt", 0)})
        self.assertEqual(t + sd + vat, 31999)
        e = self.sale(5, 32000, tax=L.sale_tax(32000, lines, 1500, 0, {2: ("exempt", 0)}))
        self.assertTrue(_bal(e))

    def test_reclass_moves_suspense_only(self):
        c_in = {"id": 3, "date": D, "kind": "in", "amount": 5000, "note": "x"}
        e = L.post_reclass(c_in, "4100")
        self.assertEqual(e["source_key"], "reclass:3")
        self.assertIn(L.line(L.SUSPENSE, debit=5000), e["lines"])
        self.assertIn(L.line("4100", credit=5000), e["lines"])
        e = L.post_reclass(dict(c_in, kind="out"), "6010")
        self.assertIn(L.line("6010", debit=5000), e["lines"])
        with self.assertRaises(ValueError):
            L.post_reclass(c_in, "6010")                 # money in can't be rent
        with self.assertRaises(ValueError):
            L.post_reclass(dict(c_in, kind="out"), "1010")

    def test_year_close_zeroes_income_and_expense(self):
        sale = self.sale(1, 10000, vat_bp=0, cogs=6000)
        rent = L.post_expense({"id": 1, "date": D, "amount": 1500, "category": "rent"})
        lines = [dict(l, date=D) for p in (sale, rent) for l in p["lines"]]
        e = L.year_close(lines, date(2026, 12, 31))
        self.assertTrue(_bal(e))
        self.assertEqual(e["profit"], 10000 - 6000 - 1500)
        after = L.balances(lines + [dict(l, date=date(2026, 12, 31)) for l in e["lines"]])
        for code, v in after.items():
            if L.ACC[code]["type"] in (L.INCOME, L.EXPENSE):
                self.assertEqual(v, 0, code)
        self.assertEqual(after[L.RETAINED], -2500)
        self.assertIsNone(L.year_close([], date(2026, 12, 31)))
        self.assertIn("yearclose:", L.OWNER_KEYS[1])


class Ledger2DbTests(ShopFixture):
    def _vat_on(self):
        PaCollectionItem.objects.create(user=self.owner, collection=S.INVOICE_CFG, data={
            "business_id": self.biz.id, "vat_mode": "inclusive", "bin": "000123456-0101",
            "vat_bp": 1500, "sd_bp": 0})

    # ---- 1) VAT: four separate lines, one source of truth -------------------
    def test_vat_paid_kept_apart_core_and_acct_agree(self):
        self._vat_on()
        S.sync_books(self.biz, self.owner)
        before = self.o.get("/api/v1/business/books/vat").data["output_vat"]
        self.assertGreater(before, 0)
        r = self.o.post("/api/v1/business/books/journal", {
            "memo": "VAT challan", "lines": [{"code": "2100", "debit": 10000},
                                             {"code": "1040", "credit": 10000}]},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        core = self.o.get("/api/v1/business/books/vat").data
        self.assertEqual(core["output_vat"], before)        # the bug: was before - 10000
        self.assertEqual(core["paid"], 10000)
        self.assertEqual(core["still_due"], core["net_payable"] - 10000)
        acct = self.o.get("/api/v1/business/acct/vat").data
        for k in ("output_vat", "input_vat", "paid", "net_payable", "still_due"):
            self.assertEqual(acct[k], core[k], k)
        self.assert_books_balance()

    # ---- 2) payment method -------------------------------------------------
    def test_khata_payment_method_api_posts_to_bkash(self):
        r = self.o.post("/api/v1/business/khata/parties/%d/payment?business=%d"
                        % (self.karim.id, self.biz.id),
                        {"amount": 7000, "method": "bkash", "client_id": "pay-bkash-01"},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data["method"], "bkash")
        k = KhataEntry.objects.get(pk=r.data["entry_id"])
        self.assertEqual(k.method, "bkash")
        S.sync_books(self.biz, self.owner)
        self.assertEqual(self.bal(L.BKASH), 55000 + 7000)
        self.assertEqual(self.bal(L.CASH), 7000)            # untouched
        # old rows keep '' (= cash) — nothing back-filled
        self.assertEqual(KhataEntry.objects.get(pk=self.k_paid.pk).method, "")
        # an owner edit can move it to the bank (reversal + new entry)
        e = self.o.post("/api/v1/business/khata/entries/%d?business=%d" % (k.id, self.biz.id),
                        {"method": "bank"}, format="json")
        self.assertEqual(e.status_code, 200, e.content)
        out = S.sync_books(self.biz, self.owner)
        self.assertEqual(out["reversed"], 1)
        self.assertEqual(self.bal(L.BANK), 7000)
        self.assertEqual(self.bal(L.BKASH), 55000)
        self.assert_books_balance()

    # ---- 3) input VAT + purchase register + per-product VAT --------------------
    def test_purchase_vat_and_mushak_61_register(self):
        r = self.o.post("/api/v1/business/acct/entries", {
            "client_id": "buy-vat-0001", "kind": "purchase", "amount": 115000, "vat": 15000,
            "account": "bank", "bill_no": "CH-77", "supplier_bin": "000999888-0101",
            "party_name": "Akij"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        v = self.o.get("/api/v1/business/books/vat").data
        self.assertEqual(v["input_vat"], 15000)
        self.assertEqual(v["taxable_purchases"], 100000)
        row = v["purchase_register"][0]
        self.assertEqual((row["bill_no"], row["supplier_bin"], row["value"], row["vat"]),
                         ("CH-77", "000999888-0101", 100000, 15000))
        self.assert_books_balance()

    def test_exempt_product_has_no_output_vat_from_its_start_day(self):
        self._vat_on()
        oil = Product.objects.get(business=self.biz, name="Oil")
        s = self.sale(23000, 0, 0, "cash", [])
        SaleLine.objects.create(sale=s, product=oil, product_name="Oil", qty=1,
                                unit_price=23000, cost_price=15000, sell_price=23000)
        S.sync_books(self.biz, self.owner)
        v0 = self.o.get("/api/v1/business/books/vat").data["output_vat"]
        r = self.o.post("/api/v1/business/acct/vat-rates",
                        {"product_id": oil.id, "mode": "exempt",
                         "note": "প্রথম তফসিল"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        v = self.o.get("/api/v1/business/books/vat").data
        self.assertEqual(v0 - v["output_vat"], L.inclusive_tax(23000, 1500)[2])
        self.assertEqual(v["exempt_sales"], 23000)
        lst = self.o.get("/api/v1/business/acct/vat-rates").data
        self.assertEqual(lst["custom"], 1)
        self.assertEqual(lst["shop_vat_bp"], 1500)
        # reduced needs the owner's own rate; no rate is invented
        bad = self.o.post("/api/v1/business/acct/vat-rates",
                          {"product_id": oil.id, "mode": "reduced"}, format="json")
        self.assertEqual(bad.data["error"], "bad_rate")
        ok = self.o.post("/api/v1/business/acct/vat-rates",
                         {"product_id": oil.id, "mode": "reduced", "vat_bp": 500},
                         format="json")
        self.assertEqual(ok.data["vat_bp"], 500)
        self.assertTrue(AuditLog.objects.filter(action="acct.vatrate").exists())
        self.assert_books_balance()

    # ---- 4) cashbox reclass ------------------------------------------------
    def test_cashbox_row_classified_out_of_suspense(self):
        S.sync_books(self.biz, self.owner)
        cb = self.o.get("/api/v1/business/acct/cashbox").data
        self.assertEqual((cb["unclassified"], cb["unclassified_amount"]), (1, 5000))
        cid = cb["rows"][0]["id"]
        url = "/api/v1/business/acct/cashbox/%d/classify" % cid
        self.assertEqual(self.o.post(url, {"code": "6010"}, format="json").data["error"],
                         "bad_code")
        r = self.o.post(url, {"code": "4100"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.bal(L.SUSPENSE), 0)
        self.assertEqual(self.bal("4100"), -5000)
        self.assertEqual(L.profit_and_loss(self.lines())["net_profit"], 37000 + 5000)
        self.assertEqual(self.o.get("/api/v1/business/acct/cashbox").data["unclassified"], 0)
        self.o.post(url, {"code": "3010"}, format="json")       # changed: capital
        self.assertEqual(self.bal("4100"), 0)
        self.assertEqual(self.bal("3010"), -5000)
        self.assertTrue(JournalEntry.objects.filter(source_key="reclass:%d" % cid,
                                                    status="reversed").exists())
        self.o.post(url, {"code": ""}, format="json")           # cleared
        self.assertEqual(self.bal(L.SUSPENSE), -5000)
        self.assertEqual(self.bal(L.CASH), 7000)               # cash never moved
        self.assert_books_balance()

    # ---- 5) year-end close -------------------------------------------------
    def _move_back(self, days):
        then = timezone.now() - timedelta(days=days)
        Sale.objects.filter(business=self.biz).update(created_at=then)
        Sale.objects.filter(business=self.biz, voided_at__isnull=False).update(voided_at=then)
        KhataEntry.objects.filter(party__business=self.biz).update(at=then)
        Expense.objects.filter(business=self.biz).update(date=timezone.localdate(then))
        CashEntry.objects.filter(day__business=self.biz).update(at=then)

    def test_year_close_to_retained_earnings_and_reopen_with_reason(self):
        self._move_back(3)
        end = timezone.localdate() - timedelta(days=1)
        S.sync_books(self.biz, self.owner)
        r = self.o.post("/api/v1/business/acct/year-close", {"end": str(end)}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data["profit"], 37000)
        self.assertEqual(r.data["book"]["lock_date"], str(end))
        self.assertEqual(self.bal(L.RETAINED), -37000)
        for code, v in L.balances(self.lines()).items():
            if L.ACC[code]["type"] in (L.INCOME, L.EXPENSE):
                self.assertEqual(v, 0, code)
        # the year's P&L still shows the real profit (closing left out)
        pl = self.o.get("/api/v1/business/books/profit-loss?from=%s&to=%s"
                        % (end - timedelta(days=10), end)).data
        self.assertEqual(pl["net_profit"], 37000)
        cf = self.o.get("/api/v1/business/books/cash-flow?from=%s&to=%s"
                        % (end - timedelta(days=10), end)).data
        self.assertTrue(cf["reconciles"])
        bs = self.o.get("/api/v1/business/books/balance-sheet").data
        self.assertTrue(bs["balanced"])
        self.assertEqual(bs["profit_to_date"], 0)
        S.sync_books(self.biz, self.owner)                      # sync never touches it
        self.assertEqual(JournalEntry.objects.get(source_key="yearclose:%s" % end).status,
                         "posted")
        again = self.o.post("/api/v1/business/acct/year-close", {"end": str(end)},
                            format="json")
        self.assertEqual(again.data["error"], "already_closed")
        self.assertEqual(self.o.post("/api/v1/business/acct/year-close",
                                     {"end": str(timezone.localdate())},
                                     format="json").data["error"], "future_lock")
        listed = self.o.get("/api/v1/business/acct/year-close").data
        self.assertEqual(listed["closes"][0]["status"], "posted")
        # the month lock cannot reopen a closed year (the closing entry stays)
        m = self.o.post("/api/v1/business/acct/lock", {"lock_date": None,
                                                       "reason": "fix a sale"}, format="json")
        self.assertEqual((m.status_code, m.data["error"]), (409, "year_closed"))
        # reopening needs a written reason
        no = self.o.post("/api/v1/business/acct/year-reopen", {"end": str(end)}, format="json")
        self.assertEqual(no.data["error"], "reason_required")
        ok = self.o.post("/api/v1/business/acct/year-reopen",
                         {"end": str(end), "reason": "missed a supplier bill"}, format="json")
        self.assertEqual(ok.status_code, 200, ok.content)
        self.assertIsNone(ok.data["lock_date"])                 # back to no lock
        self.assertEqual(self.bal(L.RETAINED), 0)
        self.assertTrue(AuditLog.objects.filter(action="acct.yearopen",
                                                detail__reason="missed a supplier bill").exists())
        self.assertTrue(AuditLog.objects.filter(action="acct.lock").exists())
        self.assert_books_balance()
        # and it can be closed again
        self.assertEqual(self.o.post("/api/v1/business/acct/year-close", {"end": str(end)},
                                     format="json").status_code, 201)
        self.assert_books_balance()

    # ---- 6) cost price 0 ---------------------------------------------------
    def test_cost_zero_sales_listed_and_fixed_on_one_tap(self):
        rice = Product.objects.get(business=self.biz, name="Rice")
        s = self.sale(30000, 0, 0, "cash", [])
        SaleLine.objects.create(sale=s, product=rice, product_name="Rice", qty=3,
                                unit_price=10000, cost_price=0, sell_price=10000)
        Sale.objects.filter(pk=s.pk).update(profit=30000)
        g = self.o.get("/api/v1/business/acct/cost-gaps").data
        self.assertEqual((g["sales"], g["lines"], g["revenue"]), (1, 1, 30000))
        self.assertEqual(g["products"][0]["product_id"], rice.id)
        self.assertEqual(g["products"][0]["current_cost"], 5000)      # variant cost
        S.sync_books(self.biz, self.owner)
        cogs0 = self.bal(L.COGS)
        r = self.o.post("/api/v1/business/acct/cost-gaps/apply", {"product_id": rice.id},
                        format="json")
        self.assertEqual(r.data["fixed"], 1, r.content)
        self.assertEqual(SaleLine.objects.get(sale=s).cost_price, 5000)
        self.assertEqual(Sale.objects.get(pk=s.pk).profit, 30000 - 15000)
        self.assertEqual(self.bal(L.COGS) - cogs0, 15000)
        self.assertEqual(self.o.get("/api/v1/business/acct/cost-gaps").data["lines"], 0)
        self.assertTrue(AuditLog.objects.filter(action="acct.costfix").exists())
        bad = self.o.post("/api/v1/business/acct/cost-gaps/apply",
                          {"product_id": rice.id, "cost": -5}, format="json")
        self.assertEqual(bad.data["error"], "bad_cost")
        self.assert_books_balance()

    def test_cost_fix_skips_closed_periods(self):
        rice = Product.objects.get(business=self.biz, name="Rice")
        s = self.sale(10000, 0, 0, "cash", [])
        SaleLine.objects.create(sale=s, product=rice, product_name="Rice", qty=1,
                                unit_price=10000, cost_price=0, sell_price=10000)
        Sale.objects.filter(pk=s.pk).update(created_at=timezone.now() - timedelta(days=5))
        S.set_lock_date(self.biz, timezone.localdate() - timedelta(days=2), self.owner)
        r = self.o.post("/api/v1/business/acct/cost-gaps/apply", {"product_id": rice.id},
                        format="json")
        self.assertEqual((r.data["fixed"], r.data["skipped_locked"]), (0, 1))

    def test_staff_and_flag_off_blocked(self):
        st = APIClient()
        st.force_authenticate(self.staff)
        for url in ("/api/v1/business/acct/cashbox", "/api/v1/business/acct/vat-rates",
                    "/api/v1/business/acct/year-close", "/api/v1/business/acct/cost-gaps"):
            self.assertEqual(st.get(url + "?business=%d" % self.biz.id).status_code, 403, url)
        from core.tests_ledger import flag
        flag(False)
        self.assertEqual(self.o.get("/api/v1/business/acct/cashbox").status_code, 403)
        self.assertIsNotNone(LedgerBook)
        self.assertIsNotNone(L2)
