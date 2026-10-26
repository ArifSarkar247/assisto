"""budget-remittance — two accounts end to end (flag budget_remittance).

Record money received from abroad (rate the user got, taka, sender from My
Circle or a name, legal channel) · idempotent offline sync on client_id ·
ENCRYPTED AT REST (the raw DB row holds no amount / name) · the existing
Budget rows are the plan, the existing Money expenses are the actual (80/100%
states) · savings goal (the existing SavingsGoal) · bills + paid → expense ·
expected-remittance status + once-a-month alert · monthly report text · year
view maths · export CSV/text · delete-all · flag OFF → 403 · another user can
never read or touch these rows · daily cap."""
from datetime import date, timedelta
from decimal import Decimal
from unittest import mock

from django.db import connection
from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import remittance_service as S
from core.logic import remittance as L
from core.models import (Budget, CircleMember, FeatureFlag, RemittanceEntry,
                         RemittanceProfile, SavingsGoal, Transaction, User)


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


class _Base(TestCase):
    def setUp(self):
        flag(True)
        self.addCleanup(FF.invalidate)
        S.reset_crypto()
        self.addCleanup(S.reset_crypto)
        self.u = User.objects.create_user(name="Rahim", phone="01710000101", password="pw")
        self.v = User.objects.create_user(name="Karim", phone="01810000102", password="pw")
        self.a = APIClient()
        self.a.force_authenticate(self.u)
        self.b = APIClient()
        self.b.force_authenticate(self.v)
        self.n = 0

    def cid(self):
        self.n += 1
        return "cid-test-%04d" % self.n

    def add(self, c=None, **kw):
        body = {"client_id": self.cid(), "amount": "500", "currency": "SAR", "rate": "32.50",
                "channel": "bkash", "sender_name": "Bhai", "received_on": S.today().isoformat()}
        body.update(kw)
        return (c or self.a).post("/api/v1/remit/entries", body, format="json")


class EntryTests(_Base):
    def test_create_computes_taka_and_lists(self):
        r = self.add()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["taka"], "16250.00")
        self.assertEqual(r.data["channel"], "bkash")
        r = self.a.get("/api/v1/remit/entries?month=" + L.month_key(S.today()))
        self.assertEqual(len(r.data["results"]), 1)

    def test_taka_given_rate_derived(self):
        r = self.add(rate="", taka="16000")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["rate"], "32.0000")

    def test_bdt_needs_no_rate(self):
        r = self.add(currency="BDT", amount="20000", rate=None)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual((r.data["taka"], r.data["rate"]), ("20000.00", "1"))

    def test_validation(self):
        self.assertEqual(self.add(amount="0").data["error"], "bad_amount")
        self.assertEqual(self.add(amount="abc").data["error"], "bad_number")
        self.assertEqual(self.add(rate="", taka="").data["error"], "need_rate")
        self.assertEqual(self.add(rate="5000").data["error"], "bad_rate")
        self.assertEqual(self.add(channel="hundi").data["error"], "bad_channel")
        self.assertEqual(self.add(currency="RIYAL").data["error"], "bad_currency")
        future = (S.today() + timedelta(days=5)).isoformat()
        self.assertEqual(self.add(received_on=future).data["error"], "bad_date")
        self.assertEqual(self.add(client_id="x").data["error"], "bad_client_id")
        self.assertEqual(RemittanceEntry.objects.count(), 0)

    def test_only_legal_channels(self):
        self.assertEqual(set(L.CHANNELS), {"bank", "bkash", "nagad", "rocket",
                                           "western_union", "moneygram", "other"})

    def test_idempotent_client_id(self):
        body = {"client_id": "offline-0001", "amount": "100", "currency": "AED", "rate": "33",
                "channel": "bank", "sender_name": "Abba"}
        r1 = self.a.post("/api/v1/remit/entries", body, format="json")
        r2 = self.a.post("/api/v1/remit/entries", body, format="json")
        self.assertEqual((r1.status_code, r2.status_code), (201, 200))
        self.assertTrue(r2.data["duplicate"])
        self.assertEqual(r1.data["id"], r2.data["id"])
        self.assertEqual(RemittanceEntry.objects.filter(user=self.u).count(), 1)
        # the same client id from ANOTHER user is a different entry
        self.assertEqual(self.b.post("/api/v1/remit/entries", body, format="json").status_code, 201)

    def test_sender_from_my_circle(self):
        m = CircleMember.objects.create(user=self.u, name="Bhaiya", state="accepted")
        r = self.add(sender_member_id=m.pk, sender_name="")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual((r.data["sender_member_id"], r.data["sender_name"]), (m.pk, "Bhaiya"))
        other = CircleMember.objects.create(user=self.v, name="Not yours", state="accepted")
        self.assertEqual(self.add(sender_member_id=other.pk).data["error"], "bad_sender")
        pend = CircleMember.objects.create(user=self.u, name="Pending", state="pending")
        self.assertEqual(self.add(sender_member_id=pend.pk).data["error"], "bad_sender")

    def test_patch_and_delete(self):
        r = self.add()
        pk = r.data["id"]
        r = self.a.patch("/api/v1/remit/entries/%d" % pk, {"rate": "33"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["taka"], "16500.00")
        r = self.a.patch("/api/v1/remit/entries/%d" % pk, {"note": "Eid"}, format="json")
        self.assertEqual((r.data["taka"], r.data["note"]), ("16500.00", "Eid"))
        self.assertEqual(self.a.delete("/api/v1/remit/entries/%d" % pk).status_code, 200)
        self.assertFalse(RemittanceEntry.objects.filter(pk=pk).exists())


class PrivacyTests(_Base):
    def test_encrypted_at_rest_raw_row(self):
        self.add(amount="777", rate="31.25", sender_name="Secret Brother", note="hospital bill")
        with connection.cursor() as cur:
            cur.execute("SELECT * FROM core_remittanceentry")
            raw = " ".join(str(x) for x in cur.fetchone())
        for leak in ("777", "31.25", "24281", "Secret Brother", "hospital", "bkash", "SAR"):
            self.assertNotIn(leak, raw)
        row = RemittanceEntry.objects.get()
        self.assertTrue(row.enc.startswith("gAAAA"))     # a Fernet token
        self.assertEqual(S.unseal(row.enc)["sender_name"], "Secret Brother")

    def test_profile_encrypted(self):
        self.a.post("/api/v1/remit/settings", {"expected_taka": "45678", "expected_day": 10,
                                               "expected_sender": "Mama"}, format="json")
        self.a.post("/api/v1/remit/bills", {"name": "Electricity DESCO", "amount": "1234",
                                            "due_day": 5, "category": "other"}, format="json")
        with connection.cursor() as cur:
            cur.execute("SELECT enc FROM core_remittanceprofile")
            raw = cur.fetchone()[0]
        for leak in ("45678", "Mama", "DESCO", "1234"):
            self.assertNotIn(leak, raw)

    def test_older_key_still_readable(self):
        from cryptography.fernet import Fernet
        k1 = Fernet.generate_key().decode()
        with mock.patch.dict("os.environ", {"INTEGRATIONS_FERNET_KEY": k1, "FINANCE_FERNET_KEY": ""}):
            S.reset_crypto()
            blob = S.seal({"a": 1})
        with mock.patch.dict("os.environ", {"INTEGRATIONS_FERNET_KEY": k1,
                                            "FINANCE_FERNET_KEY": Fernet.generate_key().decode()}):
            S.reset_crypto()
            self.assertEqual(S.unseal(blob), {"a": 1})

    def test_other_user_cannot_read_or_touch(self):
        pk = self.add().data["id"]
        self.assertEqual(self.b.get("/api/v1/remit/entries").data["results"], [])
        self.assertEqual(self.b.patch("/api/v1/remit/entries/%d" % pk, {"note": "x"},
                                      format="json").status_code, 404)
        self.assertEqual(self.b.delete("/api/v1/remit/entries/%d" % pk).status_code, 404)
        self.assertEqual(self.b.get("/api/v1/remit/overview").data["count"], 0)
        self.assertEqual(self.b.get("/api/v1/remit/year").data["total"], "0.00")
        self.b.post("/api/v1/remit/delete-all", {"confirm": True}, format="json")
        self.assertTrue(RemittanceEntry.objects.filter(pk=pk).exists())

    def test_flag_off_403_everywhere(self):
        flag(False)
        for path in ("overview", "entries", "year", "report", "export"):
            r = self.a.get("/api/v1/remit/" + path)
            self.assertEqual(r.status_code, 403, path)
            self.assertEqual(r.data["error"], "feature_off")
        self.assertEqual(self.add().status_code, 403)
        self.assertEqual(self.a.post("/api/v1/remit/delete-all", {"confirm": True},
                                     format="json").status_code, 403)
        # the owner (staff) still previews it
        self.u.is_staff = True
        self.u.save()
        FF.invalidate()
        self.assertEqual(self.a.get("/api/v1/remit/overview").status_code, 200)

    def test_play_hidden_separately(self):
        flag(True)
        FeatureFlag.objects.filter(key=S.FLAG).update(enabled_play=False)
        FF.invalidate()
        self.assertEqual(self.a.get("/api/v1/remit/overview").status_code, 200)
        r = self.a.get("/api/v1/remit/overview", HTTP_X_ASSISTO_FLAVOUR="play")
        self.assertEqual(r.status_code, 403)

    def test_registry_default_off(self):
        self.assertFalse(FF.meta(S.FLAG)["default_on"])
        self.assertEqual(FF.meta(S.FLAG)["routes"], ["remittance"])

    def test_unauthenticated(self):
        self.assertIn(APIClient().get("/api/v1/remit/overview").status_code, (401, 403))


class BudgetTests(_Base):
    def test_plan_uses_existing_budget_and_actual_uses_money(self):
        self.add(currency="BDT", amount="30000")
        r = self.a.post("/api/v1/remit/plan", {"lines": {"food": "10000", "rent": "8000",
                                                         "savings": "5000"}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(Budget.objects.get(user=self.u, category="food").monthly_limit, Decimal("10000"))
        # spending made here + an expense the user typed in Money ("খাবার")
        r = self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "food",
                                                "amount": "6000"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        acc = Transaction.objects.get(ref__startswith="rm:").account
        Transaction.objects.create(user=self.u, account=acc, kind="expense", amount=Decimal("2500"),
                                   category="খাবার", date=S.today())
        self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "rent",
                                            "amount": "9000"}, format="json")
        card = self.a.get("/api/v1/remit/overview").data
        lines = {ln["key"]: ln for ln in card["plan"]["lines"]}
        self.assertEqual((lines["food"]["actual"], lines["food"]["pct"], lines["food"]["state"]),
                         ("8500.00", 85, "near"))
        self.assertEqual(lines["rent"]["state"], "over")
        self.assertEqual(lines["savings"]["state"], "ok")
        self.assertEqual(lines["education"]["state"], "none")
        self.assertEqual(card["plan"]["spent"], "17500.00")
        self.assertEqual(card["plan"]["left"], "12500.00")
        self.assertEqual(card["received"], "30000.00")
        # zero removes the plan row
        self.a.post("/api/v1/remit/plan", {"lines": {"rent": "0"}}, format="json")
        self.assertFalse(Budget.objects.filter(user=self.u, category="rent").exists())
        self.assertEqual(self.a.post("/api/v1/remit/plan", {"lines": {"cinema": "1"}},
                                     format="json").data["error"], "bad_category")

    def test_spend_idempotent(self):
        body = {"client_id": "spend-0001", "category": "health", "amount": "700"}
        self.a.post("/api/v1/remit/spend", body, format="json")
        r = self.a.post("/api/v1/remit/spend", body, format="json")
        self.assertTrue(r.data["duplicate"])
        self.assertEqual(Transaction.objects.filter(user=self.u).count(), 1)

    def test_savings_goal_progress(self):
        self.assertEqual(self.a.post("/api/v1/remit/goal/add", {"client_id": self.cid(), "amount": "1"},
                                     format="json").data["error"], "no_goal")
        r = self.a.post("/api/v1/remit/goal", {"title": "Roof repair", "target": "100000"}, format="json")
        self.assertEqual((r.data["pct"], r.data["target"]), (0, "100000.00"))
        self.assertTrue(SavingsGoal.objects.filter(user=self.u, title="Roof repair").exists())
        r = self.a.post("/api/v1/remit/goal/add", {"client_id": "goal-0001", "amount": "25000"}, format="json")
        self.assertEqual((r.status_code, r.data["pct"], r.data["saved"]), (201, 25, "25000.00"))
        r = self.a.post("/api/v1/remit/goal/add", {"client_id": "goal-0001", "amount": "25000"}, format="json")
        self.assertEqual((r.data["pct"], r.data["duplicate"]), (25, True))
        card = self.a.get("/api/v1/remit/overview").data
        self.assertEqual(card["goal"]["pct"], 25)
        self.assertEqual({ln["key"]: ln["actual"] for ln in card["plan"]["lines"]}["savings"], "25000.00")

    def test_bills_paid_creates_expense_once(self):
        r = self.a.post("/api/v1/remit/bills", {"name": "School fee", "amount": "3000", "due_day": 7,
                                                "category": "education"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        bid = r.data["id"]
        month = L.month_key(S.today())
        r = self.a.post("/api/v1/remit/bills/%d/paid" % bid, {"client_id": "bill-0001", "month": month},
                        format="json")
        self.assertEqual(r.status_code, 201, r.data)
        r = self.a.post("/api/v1/remit/bills/%d/paid" % bid, {"client_id": "bill-0002", "month": month},
                        format="json")
        self.assertTrue(r.data["duplicate"])
        self.assertEqual(Transaction.objects.filter(user=self.u, category="education").count(), 1)
        card = self.a.get("/api/v1/remit/overview").data
        self.assertTrue(card["bills"][0]["paid"])
        r = self.a.patch("/api/v1/remit/bills/%d" % bid, {"amount": "3500"}, format="json")
        self.assertEqual(r.data["amount"], "3500.00")
        self.assertEqual(self.a.delete("/api/v1/remit/bills/%d" % bid).status_code, 200)
        self.assertEqual(self.a.get("/api/v1/remit/overview").data["bills"], [])
        self.assertEqual(self.a.post("/api/v1/remit/bills", {"name": "", "amount": "1", "due_day": 1},
                                     format="json").data["error"], "bad_bill")

    def test_category_synonyms(self):
        self.assertEqual(L.category_of("Groceries"), "food")
        self.assertEqual(L.category_of("বাসা ভাড়া"), "rent")
        self.assertEqual(L.category_of("কিস্তি"), "loan")
        self.assertEqual(L.category_of("ওষুধ"), "health")
        self.assertEqual(L.category_of("cinema"), "other")


class ExpectedTests(_Base):
    def test_status_logic(self):
        m = "2026-10"
        st = L.expected_status
        self.assertEqual(st(date(2026, 10, 5), m, 0, 10, 0), "none")
        self.assertEqual(st(date(2026, 10, 5), m, 2_000_000, 10, 0), "waiting")
        self.assertEqual(st(date(2026, 10, 10), m, 2_000_000, 10, 0), "waiting")
        self.assertEqual(st(date(2026, 10, 11), m, 2_000_000, 10, 0), "missing")
        self.assertEqual(st(date(2026, 10, 11), m, 2_000_000, 10, 500_000), "partial")
        self.assertEqual(st(date(2026, 10, 11), m, 2_000_000, 10, 2_000_000), "arrived")
        self.assertEqual(st(date(2026, 9, 30), m, 2_000_000, 10, 0), "future")
        # day 31 in a 30-day month -> the last day
        self.assertEqual(L.due_date("2026-11", 31), date(2026, 11, 30))
        self.assertEqual(st(date(2026, 2, 28), "2026-02", 100, 31, 0), "waiting")

    def test_alert_once_per_month(self):
        self.a.post("/api/v1/remit/settings", {"expected_taka": "20000", "expected_day": 1}, format="json")
        d = date(2026, 10, 20)
        with mock.patch.object(S, "today", return_value=d):
            r1 = self.a.get("/api/v1/remit/overview?month=2026-10").data
            r2 = self.a.get("/api/v1/remit/overview?month=2026-10").data
        self.assertEqual(r1["expected"]["status"], "missing")
        self.assertTrue(r1["expected"]["alert_now"])
        self.assertFalse(r2["expected"]["alert_now"])
        self.assertEqual(RemittanceProfile.objects.get(user=self.u).missing_alert_month, "2026-10")
        with mock.patch.object(S, "today", return_value=date(2026, 11, 2)):
            r3 = self.a.get("/api/v1/remit/overview").data
        self.assertTrue(r3["expected"]["alert_now"])      # a new month, a new reminder

    def test_arrived_no_alert(self):
        self.a.post("/api/v1/remit/settings", {"expected_taka": "15000", "expected_day": 1}, format="json")
        self.add()      # 16,250 today
        r = self.a.get("/api/v1/remit/overview").data
        self.assertEqual(r["expected"]["status"], "arrived")
        self.assertFalse(r["expected"]["alert_now"])

    def test_settings_validation(self):
        self.assertEqual(self.a.post("/api/v1/remit/settings", {"expected_day": 40},
                                     format="json").data["error"], "bad_day")
        r = self.a.post("/api/v1/remit/settings", {"guide_done": True}, format="json")
        self.assertTrue(r.data["guide_done"])
        self.assertTrue(self.a.get("/api/v1/remit/overview").data["guide_done"])


class ReportYearTests(_Base):
    def test_report_text_bn_and_en(self):
        self.add(currency="BDT", amount="20000", sender_name="Bhai")
        self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "food",
                                            "amount": "5000"}, format="json")
        r = self.a.get("/api/v1/remit/report?lang=bn").data
        self.assertIn("এসেছে: ৳২০,০০০ (১ বার)", r["text"])
        self.assertIn("খাবার: ৳৫,০০০", r["text"])
        self.assertIn("হাতে আছে: ৳১৫,০০০", r["text"])
        r = self.a.get("/api/v1/remit/report?lang=en").data
        self.assertIn("Received: ৳20,000 (1 time)", r["text"])
        self.assertIn("Food: ৳5,000", r["text"])
        # building the report never sends anything anywhere
        from core.models import Message
        self.assertEqual(Message.objects.count(), 0)

    def test_taka_format(self):
        self.assertEqual(L.taka("en", 1234567890), "৳1,23,45,678.90")
        self.assertEqual(L.taka("bn", 2000000), "৳২০,০০০")
        self.assertEqual(L.taka("en", 50000), "৳500")

    def test_year_view_maths(self):
        y = S.today().year
        rows = [("%d-01-05" % y, "BDT", "10000", None, "Bhai", "bkash"),
                ("%d-01-20" % y, "SAR", "100", "32", "Bhai", "bank"),
                ("%d-03-02" % y, "AED", "200", "33", "Abba", "western_union"),
                ("%d-12-31" % (y - 1), "BDT", "99999", None, "Old", "nagad")]
        for d, cur, amt, rate, who, ch in rows:
            if date.fromisoformat(d) > S.today():
                continue
            r = self.add(received_on=d, currency=cur, amount=amt, rate=rate, sender_name=who, channel=ch)
            self.assertEqual(r.status_code, 201, r.data)
        r = self.a.get("/api/v1/remit/year?year=%d" % y).data
        jan = 10000 + 3200
        mar = 6600 if S.today() >= date(y, 3, 2) else 0
        self.assertEqual(r["total"], "%d.00" % (jan + mar))
        self.assertEqual(r["months"][0], "%d.00" % jan)
        senders = {s["name"]: s for s in r["by_sender"]}
        self.assertEqual((senders["Bhai"]["total"], senders["Bhai"]["count"]), ("13200.00", 2))
        self.assertNotIn("Old", senders)
        chans = {c["key"]: c["total"] for c in r["by_channel"]}
        self.assertEqual(chans["bkash"], "10000.00")
        self.assertEqual(chans["bank"], "3200.00")

    def test_year_savings_built(self):
        self.a.post("/api/v1/remit/goal", {"title": "Home", "target": "50000"}, format="json")
        self.a.post("/api/v1/remit/goal/add", {"client_id": self.cid(), "amount": "4000"}, format="json")
        self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "savings",
                                            "amount": "1000"}, format="json")
        r = self.a.get("/api/v1/remit/year").data
        self.assertEqual(r["savings"], "5000.00")


class ExportDeleteTests(_Base):
    def test_export_csv_and_text(self):
        self.add(sender_name="ভাই", note="ঈদ")
        r = self.a.get("/api/v1/remit/export?fmt=csv")
        self.assertEqual(r.status_code, 200)
        body = r.content.decode("utf-8")
        self.assertTrue(body.startswith("﻿date,amount"))
        self.assertIn("ভাই", body)
        self.assertIn("16250.00", body)
        r = self.a.get("/api/v1/remit/export?fmt=txt&as=json", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertIn("বিকাশ", r.data["text"])
        self.assertEqual(r.data["filename"], "assisto-remittance.txt")
        # the account-wide export carries it too
        r = self.a.get("/api/v1/export")
        if r.status_code == 200:
            self.assertEqual(r.data["remittance"][0]["sender_name"], "ভাই")

    def test_export_daily_cap(self):
        from django.core.cache import cache
        cache.clear()
        with mock.patch.object(S, "knob", side_effect=lambda k: 2 if k == "remit_exports_per_day" else S.KNOBS[k]):
            codes = [self.a.get("/api/v1/remit/export").status_code for _ in range(3)]
        self.assertEqual(codes, [200, 200, 429])
        cache.clear()

    def test_delete_all(self):
        self.add()
        self.a.post("/api/v1/remit/plan", {"lines": {"food": "100"}}, format="json")
        self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "food", "amount": "50"},
                    format="json")
        self.a.post("/api/v1/remit/goal", {"title": "G", "target": "100"}, format="json")
        self.a.post("/api/v1/remit/bills", {"name": "Gas", "amount": "900", "due_day": 3}, format="json")
        # an unrelated Money budget + expense of the user must survive
        Budget.objects.create(user=self.u, category="shopping", monthly_limit=1)
        other_goal = SavingsGoal.objects.create(user=self.u, title="Bike", target_amount=5)
        # another user's data must survive
        self.add(c=self.b)
        self.assertEqual(self.a.post("/api/v1/remit/delete-all", {}, format="json").data["error"], "confirm")
        r = self.a.post("/api/v1/remit/delete-all", {"confirm": True}, format="json")
        self.assertTrue(r.data["ok"])
        self.assertFalse(RemittanceEntry.objects.filter(user=self.u).exists())
        self.assertFalse(RemittanceProfile.objects.filter(user=self.u).exists())
        self.assertFalse(Transaction.objects.filter(user=self.u, ref__startswith="rm:").exists())
        self.assertFalse(Budget.objects.filter(user=self.u, category="food").exists())
        self.assertTrue(Budget.objects.filter(user=self.u, category="shopping").exists())
        self.assertTrue(SavingsGoal.objects.filter(pk=other_goal.pk).exists())
        self.assertFalse(SavingsGoal.objects.filter(user=self.u, title="G").exists())
        self.assertEqual(RemittanceEntry.objects.filter(user=self.v).count(), 1)
        self.assertEqual(self.a.get("/api/v1/remit/overview").data["count"], 0)

    def test_account_delete_cascades(self):
        self.add()
        self.u.delete()
        self.assertEqual(RemittanceEntry.objects.count(), 0)


class LimitTests(_Base):
    def test_daily_cap(self):
        with mock.patch.object(S, "knob", side_effect=lambda k: 3 if k == "remit_entries_per_day" else S.KNOBS[k]):
            codes = [self.add().status_code for _ in range(3)]
            codes.append(self.a.post("/api/v1/remit/spend", {"client_id": self.cid(), "category": "food",
                                                             "amount": "1"}, format="json").status_code)
        self.assertEqual(codes, [201, 201, 201, 429])

    def test_bills_cap(self):
        with mock.patch.object(S, "knob", side_effect=lambda k: 1 if k == "remit_bills_max" else S.KNOBS[k]):
            a = self.a.post("/api/v1/remit/bills", {"name": "A", "amount": "1", "due_day": 1}, format="json")
            b = self.a.post("/api/v1/remit/bills", {"name": "B", "amount": "1", "due_day": 1}, format="json")
        self.assertEqual((a.status_code, b.status_code), (201, 429))

    def test_knobs_bounded_in_pricing(self):
        from core.logic import pricing as P
        for k in S.KNOBS:
            self.assertIn(k, P._SHOP_DEFAULTS)
            self.assertIn(k, P._SHOP_BOUNDS)
            self.assertEqual(P._SHOP_DEFAULTS[k], S.KNOBS[k])


class SpeedTests(_Base):
    def test_overview_and_year_fast_with_long_history(self):
        """DoD 4 (server side): a heavy user — 3 years of Money expenses and
        a full year of remittances — still gets the month card and the year
        view well under 0.3 s each (p95 target), decryption included."""
        import time
        from core.models import Account
        acc = Account.objects.create(user=self.u, name="Cash")
        d0 = S.today()
        Transaction.objects.bulk_create([
            Transaction(user=self.u, account=acc, kind="expense", amount=Decimal("120"),
                        category=("food", "rent", "খাবার", "shopping")[i % 4],
                        date=d0 - timedelta(days=i % 1000)) for i in range(3000)])
        rows = []
        for i in range(120):
            d = d0 - timedelta(days=i * 3)
            rows.append(RemittanceEntry(user=self.u, client_id="speed-%04d" % i, received_on=d,
                                        month=L.month_key(d), enc=S.seal({
                                            "amount": "500", "currency": "SAR", "rate": "32",
                                            "taka": "16000", "channel": "bank", "sender_name": "Bhai"})))
        RemittanceEntry.objects.bulk_create(rows)
        self.a.get("/api/v1/remit/overview")      # warm caches (flags)
        times = []
        for path in ("overview", "year", "report"):
            for _ in range(5):
                t0 = time.perf_counter()
                r = self.a.get("/api/v1/remit/" + path)
                times.append(time.perf_counter() - t0)
                self.assertEqual(r.status_code, 200)
        times.sort()
        p95 = times[int(len(times) * 0.95) - 1]
        self.assertLess(p95, 0.3, "p95 %.3fs" % p95)
