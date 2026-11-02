"""remhbud (board group 13) — Budget & Remittance launch fixes.

* who sent how much: one row per person (My Circle member even if the typed
  name differs; typed names case/space-insensitive; "?" when none), whole
  percents that ALWAYS add up to 100 — in the month card, the year and (with
  2+ senders) the report for the sender;
* export: CSV keeps the UTF-8 BOM (Excel opens Bangla), oldest first, and a
  typed name/note that looks like a formula is neutralised (CSV injection);
  the text export prints "x rate =" only for a converted entry;
* the budget-over alert names the family category in the user's language with
  Bangla digits (it printed the raw key "'food' ... (500%)").
"""
from django.test import TestCase
from rest_framework.test import APIClient

from core import remittance_service as S
from core.logic import remittance as L
from core.models import Budget, CircleMember, User

from core.tests_budget_remittance import flag


class SharesMathTests(TestCase):
    def test_percents_always_add_to_100(self):
        self.assertEqual(L.shares_pct([100, 100, 100]), [34, 33, 33])
        self.assertEqual(sum(L.shares_pct([1, 1, 1, 1, 1, 1, 1])), 100)
        self.assertEqual(L.shares_pct([2000000, 1625000]), [55, 45])
        self.assertEqual(L.shares_pct([5, 0]), [100, 0])
        self.assertEqual(L.shares_pct([0, 0]), [0, 0])
        self.assertEqual(L.shares_pct([]), [])

    def test_sender_grouping(self):
        rows = L.sender_shares([
            {"sender_member_id": 7, "sender_name": "Karim", "taka": "10000"},
            {"sender_member_id": 7, "sender_name": "Karim bhai", "taka": "5000"},   # same person
            {"sender_member_id": None, "sender_name": "Abba ", "taka": "3000"},
            {"sender_member_id": None, "sender_name": "abba", "taka": "2000"},        # same name
            {"sender_member_id": None, "sender_name": "", "taka": "1000"},           # nobody written
        ])
        self.assertEqual([(r["name"], r["member_id"], r["total_p"], r["count"]) for r in rows],
                         [("Karim", 7, 1500000, 2), ("Abba", None, 500000, 2), ("?", None, 100000, 1)])
        self.assertEqual([r["pct"] for r in rows], [71, 24, 5])  # 71.4 / 23.8 / 4.8
        self.assertEqual(sum(r["pct"] for r in rows), 100)

    def test_report_lists_senders_only_when_two_or_more(self):
        one = L.sender_shares([{"sender_name": "Bhai", "taka": "20000"}])
        two = L.sender_shares([{"sender_name": "Bhai", "taka": "20000"},
                               {"sender_name": "Abba", "taka": "16250"}])
        t1 = L.report_text("bn", "2026-10", 2000000, 1, [], senders=one)
        self.assertNotIn("কে কত পাঠাল", t1)
        t2 = L.report_text("bn", "2026-10", 3625000, 2, [], senders=two)
        self.assertIn("কে কত পাঠাল:", t2)
        self.assertIn("• Bhai: ৳২০,০০০ (৫৫%)", t2)
        self.assertIn("• Abba: ৳১৬,২৫০ (৪৫%)", t2)
        t3 = L.report_text("en", "2026-10", 3625000, 2, [], senders=two)
        self.assertIn("• Bhai: ৳20,000 (55%)", t3)


class _Api(TestCase):
    def setUp(self):
        flag(True)
        from core import feature_flags as FF
        self.addCleanup(FF.invalidate)
        S.reset_crypto()
        self.addCleanup(S.reset_crypto)
        self.u = User.objects.create_user(name="Rahim", phone="01710000201", password="pw")
        self.a = APIClient()
        self.a.force_authenticate(self.u)
        self.n = 0

    def add(self, **kw):
        self.n += 1
        body = {"client_id": "rhb-%04d" % self.n, "amount": "20000", "currency": "BDT",
                "channel": "bkash", "sender_name": "Bhai", "received_on": S.today().isoformat()}
        body.update(kw)
        r = self.a.post("/api/v1/remit/entries", body, format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        return r


class SharesApiTests(_Api):
    def test_month_card_and_year_carry_shares(self):
        m = CircleMember.objects.create(user=self.u, name="Karim", state="accepted")
        self.add(amount="500", currency="SAR", rate="32.50", sender_name="", sender_member_id=m.pk)
        self.add(amount="20000", sender_name="Bhai")
        card = self.a.get("/api/v1/remit/overview").data
        rows = {r["name"]: r for r in card["by_sender"]}
        self.assertEqual((rows["Bhai"]["total"], rows["Bhai"]["pct"]), ("20000.00", 55))
        self.assertEqual((rows["Karim"]["total"], rows["Karim"]["pct"], rows["Karim"]["member_id"]),
                         ("16250.00", 45, m.pk))
        year = self.a.get("/api/v1/remit/year").data
        self.assertEqual(sum(r["pct"] for r in year["by_sender"]), 100)
        self.assertEqual(year["by_sender"][0]["name"], "Bhai")
        rep = self.a.get("/api/v1/remit/report?lang=bn").data["text"]
        self.assertIn("কে কত পাঠাল", rep)

    def test_empty_month_has_no_shares(self):
        self.assertEqual(self.a.get("/api/v1/remit/overview").data["by_sender"], [])


class ExportTests(_Api):
    def test_csv_bom_order_and_no_formula(self):
        self.add(sender_name="=HYPERLINK(\"http://x\")", note="+1 taka", received_on=S.today().isoformat())
        self.add(sender_name="ভাই", note="-", amount="100")
        body = self.a.get("/api/v1/remit/export?fmt=csv").content.decode("utf-8")
        self.assertTrue(body.startswith("﻿date,"))       # Excel opens Bangla
        self.assertIn("ভাই", body)
        self.assertNotIn(",=HYPERLINK", body)
        self.assertIn("'=HYPERLINK", body)
        self.assertIn("'+1 taka", body)

    def test_text_export_rate_only_when_converted(self):
        self.add(amount="20000", currency="BDT")
        self.add(amount="500", currency="SAR", rate="32.50")
        txt = self.a.get("/api/v1/remit/export?fmt=txt&as=json", HTTP_ACCEPT_LANGUAGE="en").data["text"]
        lines = [ln for ln in txt.splitlines() if "৳" in ln and ln[:4].isdigit()]
        bdt = [ln for ln in lines if "20,000" in ln][0]
        sar = [ln for ln in lines if "SAR" in ln][0]
        self.assertNotIn(" x ", bdt)
        self.assertIn("500.00 SAR x 32.50 = ৳16,250", sar)


class BudgetAlertTests(_Api):
    def test_over_budget_alert_in_bangla(self):
        from core.views import _build_alerts
        Budget.objects.create(user=self.u, category="food", monthly_limit=1000)
        r = self.a.post("/api/v1/remit/spend", {"client_id": "rhb-spend-1", "category": "food",
                                                "amount": "5000"}, format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        bn = [a["text"] for a in _build_alerts(self.u, "bn") if a["type"] == "budget"]
        self.assertEqual(bn, ["'খাবার' বাজেট শেষ (৫০০%)।"])
        en = [a["text"] for a in _build_alerts(self.u, "en") if a["type"] == "budget"]
        self.assertEqual(en, ["'Food' budget is used up (500%)."])

    def test_typed_category_shown_as_typed(self):
        from core.views import _build_alerts
        Budget.objects.create(user=self.u, category="Transport", monthly_limit=100)
        self.a.post("/api/v1/remit/spend", {"client_id": "rhb-spend-2", "category": "other",
                                            "amount": "50"}, format="json")
        # spending in another category: no Transport alert
        self.assertFalse([a for a in _build_alerts(self.u, "bn") if a["type"] == "budget"])
