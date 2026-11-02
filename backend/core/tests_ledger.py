"""ledger (flag accounting_v2): double-entry core, automatic posting from the
shop's real books, idempotent sync, reversals, lock date, reports.

The realistic fixture (`ShopFixture`) is one grocery day: cash / bKash / due
sales (one with a discount, one voided), the due sale's khata bridge row,
khata credit + collection, a supplier delivery + part payment, rent +
electricity, a manual cashbox row. Every number below is worked by hand in
owner_actions/FEATURE_CARD_ACCOUNTING_BN.md §8 terms: debits always equal
credits, and the books' inventory equals the catalog's stock value.
"""
from datetime import date, timedelta

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import ledger_service as S
from core.logic import ledger as L
from core.models import (BusinessProfile, BusinessStaff, CashboxDay, CashEntry, Expense,
                         FeatureFlag, JournalEntry, JournalLine, KhataEntry, KhataParty,
                         LedgerBook, Product, ProductVariant, Sale, SaleLine, User)

D = date(2026, 10, 15)


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def _bal(lines):
    return sum(l["debit"] for l in lines) == sum(l["credit"] for l in lines)


class PureRulesTests(SimpleTestCase):
    def test_cash_sale_with_discount_and_cogs_balances(self):
        e = L.post_sale({"id": 1, "date": D, "total": 55000, "discount": 5000, "due": 0,
                         "payment_method": "bkash", "cogs": 45000})
        self.assertTrue(_bal(e["lines"]))
        by = {l["account"]: l for l in e["lines"]}
        self.assertEqual(by[L.BKASH]["debit"], 55000)
        self.assertEqual(by[L.DISCOUNT]["debit"], 5000)
        self.assertEqual(by[L.SALES_POS]["credit"], 60000)
        self.assertEqual(by[L.COGS]["debit"], 45000)
        self.assertEqual(by[L.INVENTORY]["credit"], 45000)
        self.assertEqual(e["total"], 105000)

    def test_part_due_sale_splits_cash_and_receivable(self):
        e = L.post_sale({"id": 2, "date": D, "total": 40000, "discount": 0, "due": 30000,
                         "payment_method": "due", "customer": "Karim", "cogs": 0})
        by = {l["account"]: l for l in e["lines"]}
        self.assertEqual(by[L.CASH]["debit"], 10000)
        self.assertEqual(by[L.AR]["debit"], 30000)
        self.assertEqual(by[L.AR]["party"], "Karim")
        self.assertNotIn(L.COGS, by)          # zero lines dropped

    def test_void_is_exact_mirror_on_void_day(self):
        s = {"id": 3, "date": D, "void_date": D + timedelta(days=2), "total": 20000,
             "discount": 0, "due": 0, "payment_method": "cash", "cogs": 10000}
        a, b = L.post_sale(s), L.post_sale_void(s)
        self.assertEqual(b["date"], D + timedelta(days=2))
        net = L.balances([dict(l, date=D) for l in a["lines"] + b["lines"]])
        self.assertTrue(all(v == 0 for v in net.values()))

    def test_khata_bridge_rows_never_double_count(self):
        for note in ("বাকি বিক্রি [sale#9]", "বিক্রি বাতিল — বাকি বাদ [void-sale#9]"):
            self.assertIsNone(L.post_khata({"id": 1, "date": D, "book": "customer",
                                            "direction": "gave", "amount": 500, "note": note}))

    def test_khata_four_directions(self):
        cases = {("customer", "gave"): (L.AR, L.SALES_KHATA),
                 ("customer", "got"): (L.CASH, L.AR),
                 ("supplier", "got"): (L.INVENTORY, L.AP),
                 ("supplier", "gave"): (L.AP, L.CASH)}
        for (book, d), (dr, cr) in cases.items():
            e = L.post_khata({"id": 1, "date": D, "book": book, "direction": d,
                              "amount": 700, "party": "P", "note": ""})
            by = {l["account"]: l for l in e["lines"]}
            self.assertEqual(by[dr]["debit"], 700, (book, d))
            self.assertEqual(by[cr]["credit"], 700, (book, d))

    def test_expense_category_mapping_bn_en(self):
        self.assertEqual(L.expense_account("ভাড়া"), "6010")
        self.assertEqual(L.expense_account("Salary"), "6020")
        self.assertEqual(L.expense_account("", "Electricity bill"), "6030")
        self.assertEqual(L.expense_account("ডেলিভারি"), "6040")
        self.assertEqual(L.expense_account("misc"), L.OTHER_EXP)

    def test_unbalanced_entry_refused(self):
        with self.assertRaises(L.Unbalanced):
            L.make_entry("x:1", D, [L.line(L.CASH, debit=100), L.line(L.SALES_POS, credit=90)],
                         {"bn": "", "en": ""})

    def test_negative_amounts_fold_to_other_side(self):
        e = L.make_entry("x:1", D, [L.line(L.CASH, debit=-100), L.line(L.SALES_POS, credit=-100)],
                         {"bn": "", "en": ""})
        by = {l["account"]: l for l in e["lines"]}
        self.assertEqual(by[L.CASH]["credit"], 100)
        self.assertEqual(by[L.SALES_POS]["debit"], 100)

    def test_plan_sync_idempotent_changed_removed(self):
        a = L.post_expense({"id": 1, "date": D, "amount": 100, "category": "rent"})
        b = L.post_expense({"id": 2, "date": D, "amount": 200, "category": "rent"})
        active = {k: {"id": i, "fingerprint": e["fingerprint"], "date": e["date"],
                      "lines": e["lines"]} for i, (k, e) in
                  enumerate({a["source_key"]: a, b["source_key"]: b}.items(), 1)}
        same = L.plan_sync({a["source_key"]: a, b["source_key"]: b}, active)
        self.assertEqual((len(same["post"]), len(same["reverse"]), same["unchanged"]), (0, 0, 2))
        a2 = L.post_expense({"id": 1, "date": D, "amount": 150, "category": "rent"})
        p = L.plan_sync({a2["source_key"]: a2}, active)     # a changed, b deleted
        self.assertEqual(sorted(r["source_key"] for r in p["reverse"]), ["expense:1", "expense:2"])
        self.assertEqual([x["source_key"] for x in p["post"]], ["expense:1"])
        for r in p["reverse"]:
            self.assertTrue(_bal(r["lines"]))

    def test_lock_date_moves_postings_to_first_open_day(self):
        a = L.post_expense({"id": 1, "date": D, "amount": 100, "category": "rent"})
        p = L.plan_sync({a["source_key"]: a}, {}, lock_date=D)
        self.assertEqual(p["post"][0]["date"], D + timedelta(days=1))
        self.assertTrue(p["post"][0]["late"])
        # fingerprint is source-derived: moving the lock never re-posts
        act = {a["source_key"]: {"id": 1, "fingerprint": a["fingerprint"],
                                 "date": D + timedelta(days=1), "lines": a["lines"]}}
        self.assertEqual(L.plan_sync({a["source_key"]: a}, act, lock_date=D + timedelta(days=5))
                         ["unchanged"], 1)

    def test_opening_inventory_never_negative(self):
        self.assertEqual(L.opening_inventory(1000, 500, 300), (1200, None))
        amt, warn = L.opening_inventory(100, 0, 500)
        self.assertEqual(amt, 0)
        self.assertIn("bn", warn)

    def test_reports_on_pure_fixture(self):
        es = [L.post_sale({"id": 1, "date": D, "total": 100000, "discount": 0, "due": 0,
                           "payment_method": "cash", "cogs": 50000}),
              L.post_expense({"id": 1, "date": D, "amount": 30000, "category": "rent"}),
              L.post_opening_inventory(D, 80000)]
        lines = [dict(l, date=e["date"]) for e in es for l in e["lines"]]
        tb = L.trial_balance(lines)
        self.assertTrue(tb["balanced"])
        pl = L.profit_and_loss(lines)
        self.assertEqual((pl["net_sales"], pl["gross_profit"], pl["net_profit"]),
                         (100000, 50000, 20000))
        self.assertEqual(pl["gross_margin_pct"], 50.0)
        bs = L.balance_sheet(lines)
        self.assertTrue(bs["balanced"])
        self.assertEqual(bs["total_assets"], 70000 + 30000)   # cash 70k + stock 30k
        # a P&L window that excludes the day is empty
        self.assertEqual(L.profit_and_loss(lines, D + timedelta(days=1))["net_profit"], 0)


class ShopFixture(TestCase):
    """One realistic grocery shop, built from the same rows the app writes."""

    def setUp(self):
        flag(True)
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Rahman Store", phone="01710000101",
                                              password="pw-123456")
        self.staff = User.objects.create_user(name="Staff", phone="01710000102",
                                              password="pw-123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahman Store")
        BusinessStaff.objects.create(business=self.biz, member=self.staff, role="staff")
        rice = Product.objects.create(user=self.owner, business=self.biz, name="Rice",
                                      cost_price="50.00", price="100.00", stock=90)
        ProductVariant.objects.create(product=rice, vkey="__base__", cost_price="50.00",
                                      sell_price="100.00", stock=90)
        Product.objects.create(user=self.owner, business=self.biz, name="Oil",
                               cost_price="150.00", price="200.00", stock=20)
        # stock value now = 90×5000 + 20×15000 = 750000 poisha
        self.s1 = self.sale(100000, 0, 0, "cash", [("Rice", 10, 10000, 5000)])
        self.s2 = self.sale(55000, 5000, 0, "bkash", [("Oil", 3, 20000, 15000)])
        self.karim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01810000001")
        self.s3 = self.sale(40000, 0, 30000, "due", [("Rice", 4, 10000, 5000)])
        self.khata(self.karim, "gave", 30000, "বাকি বিক্রি [sale#%d]" % self.s3.id)   # POS bridge
        self.s4 = self.sale(20000, 0, 0, "cash", [("Rice", 2, 10000, 5000)])
        Sale.objects.filter(pk=self.s4.pk).update(voided_at=timezone.now(), void_reason="x")
        self.k_paid = self.khata(self.karim, "got", 10000, "cash")
        self.rahim = KhataParty.objects.create(business=self.biz, book="customer", name="Rahim")
        self.k_rahim = self.khata(self.rahim, "gave", 15000, "")
        akij = KhataParty.objects.create(business=self.biz, book="supplier", name="Akij")
        self.khata(akij, "got", 200000, "chalan 77")
        self.khata(akij, "gave", 60000, "")
        self.rent = Expense.objects.create(user=self.owner, business=self.biz, amount=50000,
                                           category="ভাড়া", date=timezone.localdate())
        self.elec = Expense.objects.create(user=self.owner, business=self.biz, amount=8000,
                                           category="Electricity bill", date=timezone.localdate())
        day = CashboxDay.objects.create(business=self.biz, day=timezone.localdate())
        CashEntry.objects.create(day=day, kind="in", amount_poisha=5000, note="change",
                                 at=timezone.now())
        self.o = APIClient()
        self.o.force_authenticate(self.owner)
        self.o.credentials(HTTP_ACCEPT_LANGUAGE="en")

    def sale(self, total, discount, due, method, lines):
        s = Sale.objects.create(user=self.owner, business=self.biz, subtotal=total + discount,
                                discount=discount, total=total, paid=total - due, due=due,
                                payment_method=method)
        for name, qty, unit, cost in lines:
            SaleLine.objects.create(sale=s, product_name=name, qty=qty, unit_price=unit,
                                    cost_price=cost, sell_price=unit)
        return s

    def khata(self, party, direction, amount, note):
        return KhataEntry.objects.create(party=party, direction=direction,
                                         amount_poisha=amount, note=note, at=timezone.now())

    def lines(self):
        return S.report_lines(self.biz)

    def bal(self, code):
        return L.balances(self.lines()).get(code, 0)

    def assert_books_balance(self):
        for je in JournalEntry.objects.filter(business=self.biz):
            ls = list(je.lines.values("debit", "credit"))
            self.assertTrue(_bal(ls), je.source_key)
            self.assertEqual(je.total, sum(l["debit"] for l in ls))
        tb = L.trial_balance(self.lines())
        self.assertTrue(tb["balanced"])
        self.assertGreater(tb["total_debit"], 0)
        bs = L.balance_sheet(self.lines())
        self.assertTrue(bs["balanced"], bs)
        return tb, bs


class LedgerSyncTests(ShopFixture):
    def test_full_shop_books_balance_and_match_hand_worked_numbers(self):
        out = S.sync_books(self.biz, self.owner)
        # s1 s2 s3 s4 + void, 4 khata (bridge skipped), 2 expenses, 1 cash, opening
        self.assertEqual(out, {"posted": 13, "reversed": 0, "unchanged": 0})
        tb, bs = self.assert_books_balance()
        self.assertEqual(LedgerBook.objects.get(business=self.biz).opening_inventory, 665000)
        self.assertEqual(self.bal(L.INVENTORY), 750000)       # = catalog stock value
        self.assertEqual(self.bal(L.AR), 35000)               # bridge NOT double counted
        self.assertEqual(self.bal(L.CASH), 7000)
        self.assertEqual(self.bal(L.BKASH), 55000)
        self.assertEqual(self.bal(L.AP), -140000)
        self.assertEqual(self.bal(L.SUSPENSE), -5000)
        pl = L.profit_and_loss(self.lines())
        self.assertEqual(pl["gross_sales"], 215000)
        self.assertEqual(pl["discounts_total"], 5000)
        self.assertEqual(pl["net_sales"], 210000)
        self.assertEqual(pl["cogs_total"], 115000)
        self.assertEqual(pl["gross_profit"], 95000)
        self.assertEqual(pl["operating_expenses_total"], 58000)
        self.assertEqual(pl["net_profit"], 37000)
        self.assertEqual(bs["total_assets"], 847000)
        self.assertEqual(bs["total_liabilities"], 145000)
        self.assertEqual(bs["profit_to_date"], 37000)

    def test_second_sync_posts_nothing(self):
        S.sync_books(self.biz, self.owner)
        n = JournalEntry.objects.count()
        self.assertEqual(S.sync_books(self.biz, self.owner),
                         {"posted": 0, "reversed": 0, "unchanged": 13})
        self.assertEqual(JournalEntry.objects.count(), n)

    def test_edit_reverses_and_reposts_never_edits(self):
        S.sync_books(self.biz, self.owner)
        first = JournalEntry.objects.get(source_key="khata:%d" % self.k_paid.id)
        first_lines = list(first.lines.values_list("debit", "credit"))
        KhataEntry.objects.filter(pk=self.k_paid.pk).update(amount_poisha=12000)
        self.assertEqual(S.sync_books(self.biz, self.owner)["reversed"], 1)
        first.refresh_from_db()
        self.assertEqual(first.status, "reversed")
        self.assertEqual(list(first.lines.values_list("debit", "credit")), first_lines)
        self.assertEqual(first.reversed_by.status, "reversal")
        live = JournalEntry.objects.get(source_key=first.source_key, status="posted")
        self.assertEqual(live.total, 12000)
        self.assertEqual(self.bal(L.AR), 33000)
        self.assertEqual(self.bal(L.CASH), 9000)
        self.assert_books_balance()

    def test_deleted_source_is_reversed_only(self):
        S.sync_books(self.biz, self.owner)
        self.elec.delete()
        self.assertEqual(S.sync_books(self.biz, self.owner)["reversed"], 1)
        self.assertEqual(L.profit_and_loss(self.lines())["net_profit"], 45000)
        self.assert_books_balance()

    def test_void_after_sync_posts_mirror(self):
        S.sync_books(self.biz, self.owner)
        Sale.objects.filter(pk=self.s1.pk).update(voided_at=timezone.now())
        out = S.sync_books(self.biz, self.owner)
        self.assertEqual((out["posted"], out["reversed"]), (1, 0))
        self.assertEqual(L.profit_and_loss(self.lines())["net_sales"], 110000)
        self.assert_books_balance()

    def test_locked_period_untouched_late_change_lands_next_day(self):
        S.sync_books(self.biz, self.owner)
        today = timezone.localdate()
        S.set_lock_date(self.biz, today, self.owner)
        KhataEntry.objects.filter(pk=self.k_rahim.pk).update(amount_poisha=16000)
        S.sync_books(self.biz, self.owner)
        new = JournalEntry.objects.get(source_key="khata:%d" % self.k_rahim.id, status="posted")
        rev = JournalEntry.objects.get(source_key=new.source_key, status="reversal")
        self.assertEqual(new.date, today + timedelta(days=1))
        self.assertEqual(rev.date, today + timedelta(days=1))
        self.assertTrue(new.late and rev.late)
        # the closed period's figures did not move
        pl_closed = L.profit_and_loss(S.report_lines(self.biz, today))
        self.assertEqual(pl_closed["gross_sales"], 215000)
        self.assert_books_balance()

    def test_one_live_entry_per_source_enforced_by_db(self):
        from django.db import IntegrityError, transaction
        S.sync_books(self.biz, self.owner)
        je = JournalEntry.objects.filter(business=self.biz, status="posted").first()
        with self.assertRaises(IntegrityError), transaction.atomic():
            JournalEntry.objects.create(business=self.biz, number=9999, date=je.date,
                                        source_key=je.source_key, status="posted")

    def test_line_cannot_carry_both_sides(self):
        from django.db import IntegrityError, transaction
        S.sync_books(self.biz, self.owner)
        je = JournalEntry.objects.filter(business=self.biz).first()
        with self.assertRaises(IntegrityError), transaction.atomic():
            JournalLine.objects.create(entry=je, account=je.lines.first().account,
                                       debit=5, credit=5)

    def test_owner_account_deletion_still_cascades(self):
        S.sync_books(self.biz, self.owner)
        self.owner.delete()
        self.assertFalse(JournalEntry.objects.exists())
        self.assertFalse(JournalLine.objects.exists())

    def test_sync_is_audited(self):
        from core.models import AuditLog
        S.sync_books(self.biz, self.owner)
        a = AuditLog.objects.filter(user=self.owner, action="ledger.sync").latest("created_at")
        self.assertEqual(a.detail["posted"], 13)


class LedgerApiTests(ShopFixture):
    def test_reports_api_sync_and_balance(self):
        r = self.o.get("/api/v1/business/books/trial-balance")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.data["balanced"])
        self.assertEqual(r.data["total_debit"], r.data["total_credit"])
        self.assertIn("Cash in hand", [x["name"] for x in r.data["rows"]])
        r = self.o.get("/api/v1/business/books/profit-loss")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["net_profit"], 37000)
        r = self.o.get("/api/v1/business/books/balance-sheet")
        self.assertTrue(r.data["balanced"])
        self.assertEqual(r.data["book"]["opening_inventory"], 665000)
        r = self.o.get("/api/v1/business/books/journal")
        self.assertEqual(len(r.data["entries"]), 13)
        self.assertFalse(r.data["has_more"])
        r = self.o.get("/api/v1/business/books/accounts")
        self.assertEqual(len(r.data["accounts"]), len(L.CHART))

    def test_bangla_names(self):
        c = APIClient()
        c.force_authenticate(self.owner)
        r = c.get("/api/v1/business/books/trial-balance", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertIn("হাতে নগদ", [x["name"] for x in r.data["rows"]])

    def test_post_sync_idempotent(self):
        a = self.o.post("/api/v1/business/books/sync").data
        b = self.o.post("/api/v1/business/books/sync").data
        self.assertEqual(a["posted"], 13)
        self.assertEqual(b["posted"], 0)

    def test_staff_blocked(self):
        c = APIClient()
        c.force_authenticate(self.staff)
        r = c.get("/api/v1/business/books/profit-loss?business=%d" % self.biz.id)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "staff_restricted")

    def test_flag_off_answers_feature_off(self):
        flag(False)
        r = self.o.get("/api/v1/business/books/trial-balance")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "feature_off")

    def test_lock_rules(self):
        r = self.o.post("/api/v1/business/books/lock",
                        {"lock_date": str(timezone.localdate())}, format="json")
        self.assertEqual(r.data["error"], "future_lock")
        r = self.o.post("/api/v1/business/books/lock", {"lock_date": "2026-13-40"}, format="json")
        self.assertEqual(r.data["error"], "bad_date")
        y = timezone.localdate() - timedelta(days=1)
        r = self.o.post("/api/v1/business/books/lock", {"lock_date": str(y)}, format="json")
        self.assertEqual(r.data["book"]["lock_date"], str(y))

    def test_bad_range(self):
        r = self.o.get("/api/v1/business/books/profit-loss?from=2026-11-02&to=2026-10-01")
        self.assertEqual(r.data["error"], "bad_date")
