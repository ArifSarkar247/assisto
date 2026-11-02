"""acctui (flag accounting_v2): the SIMPLE ENTRY layer — sale / purchase /
expense / due / money in-out / transfer turned into balanced postings with the
right money account; khata + expense rows stay the one truth; offline replay
is idempotent; void = reversal; opening wizard; cash flow ties to the books;
VAT summary; audit trail; owner only.
"""
from datetime import date, timedelta

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import ledger_service as S
from core.logic import ledger as L
from core.logic import ledger_entry as E
from core.models import (AuditLog, BusinessProfile, BusinessStaff, Expense, FeatureFlag,
                         JournalEntry, KhataEntry, KhataParty, LedgerBook, User)

T = date(2026, 11, 2)


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def _v(**kw):
    d = {"client_id": "abcdef12", "kind": "sale", "amount": 10000, "account": "cash"}
    d.update(kw)
    return E.validate(d, T)


def _bal(posting):
    return (sum(l["debit"] for l in posting["lines"]),
            sum(l["credit"] for l in posting["lines"]))


def _codes(posting):
    return {l["account"]: l["debit"] - l["credit"] for l in posting["lines"]}


class PureEntryTests(SimpleTestCase):
    def test_every_kind_balances_and_hits_the_right_accounts(self):
        cases = [
            (dict(kind="sale", account="bkash", vat=1500, cost=6000),
             {"1020": 11500 - 1500 + 1500, "4010": -10000, "2100": -1500, "5010": 6000,
              "1200": -6000}, 11500),
            (dict(kind="purchase", account="bank", vat=1000),
             {"1200": 9000, "1310": 1000, "1040": -10000}, 10000),
            (dict(kind="purchase", pay="due", party_name="Akij"),
             {"1200": 10000, "2010": -10000}, 10000),
            (dict(kind="expense", account="nagad", category="6010"),
             {"6010": 10000, "1030": -10000}, 10000),
            (dict(kind="due", party_id=7, cost=4000),
             {"1100": 10000, "4020": -10000, "5010": 4000, "1200": -4000}, 10000),
            (dict(kind="money_in", purpose="customer", party_name="Karim", account="bkash"),
             {"1020": 10000, "1100": -10000}, 10000),
            (dict(kind="money_in", purpose="capital"), {"1010": 10000, "3010": -10000}, 10000),
            (dict(kind="money_in", purpose="loan", account="bank"),
             {"1040": 10000, "2300": -10000}, 10000),
            (dict(kind="money_out", purpose="drawings"), {"3020": 10000, "1010": -10000}, 10000),
            (dict(kind="money_out", purpose="vat", account="bank"),
             {"2100": 10000, "1040": -10000}, 10000),
            (dict(kind="money_out", purpose="supplier", party_name="Akij"),
             {"2010": 10000, "1010": -10000}, 10000),
            (dict(kind="transfer", account="cash", to_account="bank"),
             {"1040": 10000, "1010": -10000}, 10000),
        ]
        for kw, want, amount in cases:
            kw.setdefault("amount", amount)
            e, err = _v(**kw)
            self.assertIsNone(err, kw)
            p = E.post_entry(e)
            dr, cr = _bal(p)
            self.assertEqual(dr, cr, kw)
            self.assertEqual(_codes(p), want, kw)
            self.assertTrue(p["source_key"].startswith("acct:"))

    def test_validation_errors(self):
        self.assertEqual(_v(kind="gift")[1], "bad_kind")
        self.assertEqual(_v(amount=0)[1], "bad_amount")
        self.assertEqual(_v(amount="x")[1], "bad_amount")
        self.assertEqual(_v(client_id="a")[1], "bad_client_id")
        self.assertEqual(_v(account="wallet")[1], "bad_account")
        self.assertEqual(_v(kind="transfer", to_account="cash")[1], "same_account")
        self.assertEqual(_v(vat=10000)[1], "bad_vat")
        self.assertEqual(_v(kind="due")[1], "need_party")
        self.assertEqual(_v(kind="money_out", purpose="gift")[1], "bad_purpose")
        self.assertEqual(_v(kind="expense", category="4010")[1], "bad_category")
        self.assertEqual(_v(date=str(T + timedelta(days=1)))[1], "bad_date")
        self.assertEqual(E.validate({"client_id": "abcdef12", "kind": "sale", "amount": 5,
                                     "date": str(T - timedelta(days=3))},
                                    T, lock_date=T - timedelta(days=2))[1], "locked_period")
        # a party is only demanded where the khata needs one
        self.assertIsNone(_v(kind="money_in", purpose="capital")[1])
        self.assertEqual(_v(kind="money_in", purpose="customer")[1], "need_party")

    def test_khata_direction(self):
        self.assertEqual(E.khata_direction(_v(kind="due", party_id=1)[0]), "gave")
        self.assertEqual(E.khata_direction(_v(kind="money_in", party_id=1)[0]), "got")
        self.assertEqual(E.khata_direction(_v(kind="purchase", pay="due", party_id=1)[0]), "got")
        self.assertEqual(E.khata_direction(_v(kind="money_out", party_id=1)[0]), "gave")
        self.assertIsNone(E.khata_direction(_v()[0]))

    def test_linked_row_wins_and_void_posts_nothing(self):
        e, _ = _v(kind="due", party_id=3)
        p = E.post_entry(e, {"amount": 7000, "date": T - timedelta(days=1)})
        self.assertEqual(p["total"], 7000)
        self.assertEqual(p["date"], T - timedelta(days=1))
        self.assertIsNone(E.post_entry(e, {"gone": True}))
        self.assertIsNone(E.post_entry(dict(e, void={"at": "x"})))

    def _lines(self, entries):
        out = []
        for i, (d, p) in enumerate(entries):
            for l in p["lines"]:
                out.append({"entry": i, "date": d, "account": l["account"],
                            "debit": l["debit"], "credit": l["credit"]})
        return out

    def test_vat_summary_with_payment_and_reversal(self):
        sale = E.post_entry(_v(kind="sale", amount=11500, vat=1500)[0])
        buy = E.post_entry(_v(kind="purchase", amount=5750, vat=750, client_id="abcdef13")[0])
        pay = E.post_entry(_v(kind="money_out", purpose="vat", amount=500,
                              client_id="abcdef14")[0])
        sale2 = E.post_entry(_v(kind="sale", amount=2300, vat=300, client_id="abcdef15")[0])
        rev = dict(sale2, lines=L.mirror(sale2["lines"]))
        v = E.vat_summary(self._lines([(T, sale), (T, buy), (T, pay), (T, sale2), (T, rev)]),
                          T.replace(day=1), T)
        self.assertEqual((v["output_vat"], v["input_vat"], v["paid"]), (1500, 750, 500))
        self.assertEqual(v["net_payable"], 750)
        self.assertEqual(v["still_due"], 250)
        self.assertEqual(v["taxable_sales"], 10000)
        self.assertEqual(v["taxable_purchases"], 5000)
        self.assertEqual((v["sale_invoices"], v["purchase_bills"]), (1, 1))

    def test_period_ranges(self):
        self.assertEqual(E.period_range("month", T), (date(2026, 11, 1), T))
        self.assertEqual(E.period_range("month", date(2026, 1, 9), -1),
                         (date(2025, 12, 1), date(2025, 12, 31)))
        self.assertEqual(E.period_range("quarter", T), (date(2026, 10, 1), T))
        self.assertEqual(E.period_range("quarter", date(2026, 2, 1), -1),
                         (date(2025, 10, 1), date(2025, 12, 31)))
        self.assertEqual(E.period_range("year", T, -1), (date(2025, 1, 1), date(2025, 12, 31)))


class AcctApiTests(TestCase):
    def setUp(self):
        flag(True)
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Rahman Store", phone="01710000201",
                                              password="pw-123456")
        self.staff = User.objects.create_user(name="Staff", phone="01710000202",
                                              password="pw-123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahman Store")
        BusinessStaff.objects.create(business=self.biz, member=self.staff, role="staff")
        self.karim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01810000001")
        self.o = APIClient()
        self.o.force_authenticate(self.owner)
        self.o.credentials(HTTP_ACCEPT_LANGUAGE="en")
        self.n = 0

    def post(self, **kw):
        self.n += 1
        body = {"client_id": "c%07d" % self.n, "amount": 10000, "account": "cash"}
        body.update(kw)
        return self.o.post("/api/v1/business/acct/entries", body, format="json")

    def bal(self, code):
        return L.balances(S.report_lines(self.biz)).get(code, 0)

    def tb_ok(self):
        r = self.o.get("/api/v1/business/books/trial-balance")
        self.assertTrue(r.data["balanced"])
        return r

    def test_sale_on_bkash_and_offline_replay_is_idempotent(self):
        r = self.post(kind="sale", account="bkash", amount=11500, vat=1500, client_id="offline01")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.data["created"])
        r2 = self.post(kind="sale", account="bkash", amount=11500, vat=1500, client_id="offline01")
        self.assertEqual(r2.status_code, 200)
        self.assertFalse(r2.data["created"])
        self.assertEqual(self.bal("1020"), 11500)
        self.assertEqual(self.bal("2100"), -1500)
        self.assertEqual(JournalEntry.objects.filter(source_key="acct:offline01").count(), 1)
        self.tb_ok()

    def test_due_from_crm_contact_writes_the_khata_once(self):
        r = self.post(kind="due", amount=30000, party_name="Rahim", party_phone="01910000009")
        self.assertEqual(r.status_code, 201, r.content)
        p = KhataParty.objects.get(business=self.biz, phone="01910000009")
        k = KhataEntry.objects.get(party=p)
        self.assertEqual((k.direction, k.amount_poisha), ("gave", 30000))
        self.assertIn("[acct#", k.note)
        self.assertEqual(self.bal("1100"), 30000)
        # the core never posts the marked khata row a second time
        self.assertFalse(JournalEntry.objects.filter(source_key="khata:%d" % k.id).exists())
        # paid back on bKash: khata down, bKash up — not cash
        r = self.post(kind="money_in", purpose="customer", party_id=p.id, account="bkash",
                      amount=10000)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.bal("1100"), 20000)
        self.assertEqual(self.bal("1020"), 10000)
        self.assertEqual(self.bal("1010"), 0)
        self.tb_ok()

    def test_khata_edit_follows_and_void_reverses(self):
        r = self.post(kind="due", party_id=self.karim.id, amount=5000)
        cid = r.data["entry"]["client_id"]
        k = KhataEntry.objects.get(pk=r.data["entry"]["khata_entry_id"])
        KhataEntry.objects.filter(pk=k.pk).update(amount_poisha=6000)
        S.sync_books(self.biz, self.owner)
        self.assertEqual(self.bal("1100"), 6000)
        r = self.o.post("/api/v1/business/acct/entries/%s/void" % cid, {"reason": "typo"},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(KhataEntry.objects.filter(pk=k.pk).exists())
        self.assertEqual(self.bal("1100"), 0)
        je = JournalEntry.objects.filter(source_key="acct:%s" % cid)
        self.assertEqual(je.filter(status="reversal").count(), 2)    # 5000 then 6000 undone
        self.assertTrue(AuditLog.objects.filter(action="acct.void").exists())
        self.assertEqual(self.o.post("/api/v1/business/acct/entries/nope0000/void").status_code,
                         404)

    def test_expense_on_nagad_is_in_expenses_and_books_once(self):
        r = self.post(kind="expense", account="nagad", category="6030", amount=8000)
        self.assertEqual(r.status_code, 201, r.content)
        x = Expense.objects.get(business=self.biz)
        self.assertEqual(x.amount, 8000)
        self.assertFalse(JournalEntry.objects.filter(source_key="expense:%d" % x.id).exists())
        self.assertEqual(self.bal("6030"), 8000)
        self.assertEqual(self.bal("1030"), -8000)

    def test_locked_period_is_refused(self):
        S.sync_books(self.biz, self.owner)
        y = timezone.localdate() - timedelta(days=1)
        self.o.post("/api/v1/business/books/lock", {"lock_date": str(y)}, format="json")
        r = self.post(kind="sale", date=str(y))
        self.assertEqual(r.data["error"], "locked_period")
        self.assertEqual(self.o.get("/api/v1/business/acct/entries").data["shop"], "Rahman Store")
        self.assertIn("locked", r.data["detail"])

    def test_close_and_reopen_needs_a_reason(self):
        S.sync_books(self.biz, self.owner)
        y = timezone.localdate() - timedelta(days=1)
        r = self.o.post("/api/v1/business/acct/lock", {"lock_date": str(y)}, format="json")
        self.assertEqual(r.data["book"]["lock_date"], str(y))
        self.assertEqual(self.o.post("/api/v1/business/acct/lock",
                                     {"lock_date": str(timezone.localdate())},
                                     format="json").data["error"], "future_lock")
        r = self.o.post("/api/v1/business/acct/lock", {"lock_date": None}, format="json")
        self.assertEqual(r.data["error"], "reason_required")
        r = self.o.post("/api/v1/business/acct/lock",
                        {"lock_date": None, "reason": "late supplier bill"}, format="json")
        self.assertIsNone(r.data["book"]["lock_date"])
        ev = self.o.get("/api/v1/business/acct/audit").data["events"]
        self.assertEqual(ev[0]["action"], "acct.lock")
        self.assertEqual(ev[0]["detail"]["reason"], "late supplier bill")

    def test_hints_and_core_opening_balance_together(self):
        self.post(kind="due", party_id=self.karim.id, amount=12000)
        h = self.o.get("/api/v1/business/acct/hints").data
        self.assertEqual(h["khata"]["receivable"], 12000)       # never typed twice
        self.assertEqual(h["shop"], "Rahman Store")
        start = h["start_date"]
        r = self.o.post("/api/v1/business/books/opening",
                        {"date": start, "cash": 50000, "bkash": 20000, "inventory": 300000,
                         "payables": [{"party": "", "amount": 15000}]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.post(kind="sale", account="bkash", amount=5000)
        self.assertEqual(self.bal("1020"), 25000)
        self.assertEqual(self.bal("1010"), 50000)
        self.assertTrue(self.o.get("/api/v1/business/books/balance-sheet").data["balanced"])
        self.tb_ok()

    def test_core_cash_flow_and_vat_detail(self):
        today = str(timezone.localdate())
        self.o.post("/api/v1/business/books/opening", {"date": today, "cash": 50000}, format="json")
        self.post(kind="sale", amount=23000, vat=3000)
        self.post(kind="purchase", amount=11500, vat=1500, account="bank")
        self.post(kind="money_out", purpose="vat", amount=1000)
        self.post(kind="transfer", amount=4000, to_account="nagad")
        cf = self.o.get("/api/v1/business/books/cash-flow").data
        self.assertTrue(cf["reconciles"], cf)
        self.assertEqual(cf["closing_cash"], sum(self.bal(c) for c in E.CASH_CODES))
        v = self.o.get("/api/v1/business/acct/vat").data
        self.assertEqual((v["output_vat"], v["input_vat"], v["paid"], v["still_due"]),
                         (3000, 1500, 1000, 500))
        self.assertEqual((v["sale_invoices"], v["purchase_bills"]), (1, 1))
        self.assertEqual(self.o.get("/api/v1/business/acct/vat?from=2026-12-01&to=2026-11-01")
                         .data["error"], "bad_date")

    def test_audit_shows_who_and_reversal_pairs(self):
        r = self.post(kind="sale", amount=5000)
        self.o.post("/api/v1/business/acct/entries/%s/void" % r.data["entry"]["client_id"])
        a = self.o.get("/api/v1/business/acct/audit").data
        nums = {e["number"]: e for e in a["entries"]}
        rev = [e for e in a["entries"] if e["status"] == "reversal"][0]
        self.assertIn(rev["reversal_of"], nums)
        self.assertEqual(nums[rev["reversal_of"]]["reversed_by"], rev["number"])
        self.assertEqual(rev["who"], "Rahman Store")
        self.assertIn("acct.void", [e["action"] for e in a["events"]])
        self.o.post("/api/v1/business/acct/export-log", {"what": "xlsx"}, format="json")
        self.assertIn("acct.export",
                      [e["action"] for e in self.o.get("/api/v1/business/acct/audit").data["events"]])

    def test_list_entries(self):
        self.post(kind="sale", amount=5000)
        self.post(kind="expense", amount=2000, category="6900")
        r = self.o.get("/api/v1/business/acct/entries")
        self.assertEqual([e["kind"] for e in r.data["entries"]], ["expense", "sale"])
        self.assertEqual(r.data["entries"][0]["by_name"], "Rahman Store")

    def test_errors_are_translated(self):
        c = APIClient()
        c.force_authenticate(self.owner)
        r = c.post("/api/v1/business/acct/entries",
                   {"client_id": "c0000099", "kind": "due", "amount": 100}, format="json",
                   HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.data["error"], "need_party")
        self.assertIn("খাতা", r.data["detail"])

    def test_staff_and_flag_off_blocked(self):
        c = APIClient()
        c.force_authenticate(self.staff)
        r = c.post("/api/v1/business/acct/entries?business=%d" % self.biz.id,
                   {"client_id": "c0000099", "kind": "sale", "amount": 100}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "staff_restricted")
        flag(False)
        self.assertEqual(self.o.get("/api/v1/business/acct/audit").status_code, 403)
