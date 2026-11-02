"""moneybar — money tools to the bar.

* Finance calculators against published reference values (any bank EMI
  calculator gives the same numbers; formulas cited in
  owner_actions/FEATURE_CARD_MONEY_TOOLS_BN.md §৪).
* TCB official price list: parser on a sheet shaped like TCB's real daily
  file, host pinning, idempotent store, honest "not connected", the endpoint.
"""
import io
import json
import os
import tempfile
from datetime import date, datetime
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import finance, tcb_prices


class EmiReferenceTests(TestCase):
    """EMI = P·r·(1+r)^n / ((1+r)^n − 1), r = annual% / 1200."""

    def test_one_lakh_12pct_12_months(self):
        r = finance.emi_schedule(100000, 12, 12)
        self.assertEqual(r["emi"], "8884.88")
        self.assertEqual(len(r["schedule"]), 12)
        self.assertEqual(r["schedule"][-1]["balance"], "0.00")
        # first month: interest = 1% of 1,00,000
        self.assertEqual(r["schedule"][0]["interest"], "1000.00")
        self.assertEqual(r["schedule"][0]["principal"], "7884.88")

    def test_ten_lakh_9pct_60_months(self):
        self.assertEqual(finance.emi_schedule(1000000, 9, 60)["emi"], "20758.36")

    def test_five_lakh_10pct_24_months(self):
        self.assertEqual(finance.emi_schedule(500000, 10, 24)["emi"], "23072.46")

    def test_schedule_principal_sums_to_loan(self):
        from decimal import Decimal
        r = finance.emi_schedule(250000, 11.5, 36)
        total_principal = sum(Decimal(row["principal"]) for row in r["schedule"])
        self.assertEqual(total_principal, Decimal("250000.00"))

    def test_flat_rate(self):
        # total interest = 1,00,000 × 10% × 1 yr = 10,000 → (110000)/12
        r = finance.emi_schedule(100000, 10, 12, mode="flat")
        self.assertEqual(r["emi"], "9166.67")
        self.assertEqual(r["interest"], "10000.00")

    def test_flat_costs_more_than_reducing_at_same_rate(self):
        c = finance.rate_compare(100000, 12, 10, 10, mode="reducing")
        flat = finance.emi_schedule(100000, 10, 12, mode="flat")
        self.assertGreater(float(flat["total"]), float(c["a"]["total"]))

    def test_zero_rate(self):
        self.assertEqual(finance.emi_schedule(12000, 0, 12)["emi"], "1000.00")

    def test_bad_input_is_zero_not_crash(self):
        self.assertEqual(finance.emi_schedule(0, 12, 12)["emi"], "0")
        self.assertEqual(finance.emi_schedule(1000, 12, 0)["schedule"], [])


class SavingsReferenceTests(TestCase):
    def test_dps_annuity_due(self):
        # FV = M·((1+r)^n − 1)/r·(1+r): 1,000 × 12.682503 × 1.01
        r = finance.dps_projection(1000, 12, 12)
        self.assertEqual(r["maturity"], "12809.33")
        self.assertEqual(r["invested"], "12000.00")
        self.assertTrue(r["estimate"])

    def test_goal_monthly(self):
        # payment = need / (((1+r)^n − 1)/r)
        self.assertEqual(finance.goal_savings(120000, 0, 12, 12)["monthly"], "9461.85")
        self.assertEqual(finance.goal_savings(120000, 0, 0, 12)["monthly"], "10000.00")

    def test_goal_already_reached(self):
        self.assertTrue(finance.goal_savings(1000, 5000, 5, 12)["reached_without_saving"])

    def test_budget_503020_resums(self):
        r = finance.budget_503020(33333)
        from decimal import Decimal
        self.assertEqual(sum(Decimal(r[k]) for k in ("needs", "wants", "savings")),
                         Decimal("33333"))


class ZakatTests(TestCase):
    def test_nisab_from_silver_price(self):
        from core.logic import tax_zakat
        n = tax_zakat.zakat_nisab(gold_price_per_gram=0, silver_price_per_gram=200)
        # 612.36 g × ৳200
        self.assertEqual(n["silver_nisab"], "122472.00")

    def test_zakat_is_2_5_pct_above_nisab(self):
        from core.logic import tax_zakat
        r = tax_zakat.zakat(cash=200000, bank=100000, debts=50000, nisab=122472)
        self.assertTrue(r["above_nisab"])
        self.assertEqual(r["zakatable"], "250000.00")
        self.assertEqual(r["zakat_due"], "6250.00")

    def test_zakat_below_nisab_is_zero(self):
        from core.logic import tax_zakat
        r = tax_zakat.zakat(cash=100000, nisab=122472)
        self.assertFalse(r["above_nisab"])
        self.assertEqual(r["zakat_due"], "0.00")

    def test_unset_nisab_is_flagged(self):
        from core.logic import tax_zakat
        r = tax_zakat.zakat(cash=1000, nisab=0)
        self.assertFalse(r["nisab_set"])


# ------------------------------------------------------------------ TCB
def _tcb_rows(day=datetime(2026, 11, 1)):
    """Rows shaped like TCB's real daily sheet (1 Nov 2026 layout)."""
    head = [None] * 12
    return [
        ["ট্রেডিং কর্পোরেশন অব বাংলাদেশ "] + head[1:],
        [" www.tcb.gov.bd"] + head[1:],
        ["পণ্যের নাম ", " মাপের একক", "অদ্যকার মূল্য(টাকায়)", None,
         "১সপ্তাহ পূর্বের মূল্য(টাকায়)", None, "১ মাস পূর্বের মূল্য(টাকায়)", None,
         "মাসিক মূল্যের", "১বছর পূর্বের মূল্য(টাকায়)", None, "বাৎসরিক"],
        [None, None, day, None, datetime(2026, 10, 25), None, datetime(2026, 10, 1),
         None, "হ্রাস/বৃদ্ধি(%)", datetime(2025, 11, 1), None, "হ্রাস/বৃদ্ধি(%)"],
        [None, None, "সর্বনিম্ন ", "সর্ব্বোচ্চ ", "সর্বনিম্ন ", "সর্ব্বোচ্চ ", "সর্বনিম্ন ",
         "সর্ব্বোচ্চ ", "(+)/(-)", "সর্বনিম্ন ", "সর্ব্বোচ্চ ", "(+)/(-)"],
        ["চাল সরু (নাজির/মিনিকেট)", "প্রতি কেজি", 70, 90, 70, 90, 72, 85, 1.9, 72, 85, 1.9],
        [" ডাল", None, None, "      ", None, "      ", None, "      ", None, None, "  ", None],
        ["মশুর ডাল (বড় দানা)", "প্রতি কেজি", 90, 100, 90, 100, 95, 100, -2.5, 95, 110, -7.3],
        ["মসলাঃ", None, None, None, None, None, None, None, None, None, None, None],
        ["পিঁয়াজ (আমদানি)", "প্রতি কেজি", 0, 0, 0, 0, 0, 0, "#DIV/0!", 0, 0, "#DIV/0!"],
        ["পিঁয়াজ (দেশী)", "প্রতি কেজি", 50, 60, 50, 60, 45, 50, 15.7, 70, 80, -26.6],
        ["পিঁয়াজ (দেশী)", "প্রতি কেজি", 1, 2, 1, 2, 1, 2, 0, 1, 2, 0],   # duplicate row
        ["যে সকল বাজার হতে তথ্য সংগ্রহ করা হয়েছেঃ-   ", None,
         " মিরপুর-৬, মোহাম্মদপুর টাউন হল বাজার।"] + head[3:],
        ["যে সকল পণ্যের মূল্য হ্রাস/বৃদ্ধি হয়েছেঃ"] + head[1:],
        ["বেগুন", "প্রতি কেজি", 70, 120, 90, 120, -9.5, "৩০-১০-২০২৬ তারিখে"] + head[8:],
    ]


def _xlsx_bytes(rows):
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    for r in rows:
        ws.append(r)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


FILE_URL = ("https://objectstorage.ap-dcc-gazipur-1.oraclecloud15.com/n/x/b/V2Ministry/o/"
            "office-tcb/2026/10/abc.xlsx")
LIST_HTML = ('<a href="https://evil.example.com/a.xlsx">x</a>'
             '<a href="%s" target="_blank">দেখুন</a>'
             '<a href="https://objectstorage.ap-dcc-gazipur-1.oraclecloud15.com/old.xlsx">old</a>'
             % FILE_URL)


class TcbParserTests(TestCase):
    def test_parse_real_layout(self):
        d = tcb_prices.parse_rows(_tcb_rows())
        self.assertEqual(d["date"], "2026-11-01")
        names = [i["name"] for i in d["items"]]
        self.assertEqual(names, ["চাল সরু (নাজির/মিনিকেট)", "মশুর ডাল (বড় দানা)",
                                 "পিঁয়াজ (দেশী)"])
        rice, lentil, onion = d["items"]
        self.assertEqual((rice["min"], rice["max"]), (70, 90))
        self.assertEqual((rice["month_min"], rice["month_max"]), (72, 85))
        self.assertEqual(lentil["group"], "ডাল")
        self.assertEqual(onion["group"], "মসলা")
        self.assertEqual((onion["min"], onion["max"]), (50, 60))   # first row wins
        self.assertIn("মিরপুর-৬", d["markets"])

    def test_unpublished_price_is_skipped_never_zero(self):
        d = tcb_prices.parse_rows(_tcb_rows())
        self.assertNotIn("পিঁয়াজ (আমদানি)", [i["name"] for i in d["items"]])

    def test_summary_section_not_duplicated(self):
        d = tcb_prices.parse_rows(_tcb_rows())
        self.assertNotIn("বেগুন", [i["name"] for i in d["items"]])

    def test_parse_xlsx_roundtrip(self):
        d = tcb_prices.parse_xlsx(_xlsx_bytes(_tcb_rows()))
        self.assertEqual(d["date"], "2026-11-01")
        self.assertEqual(len(d["items"]), 3)

    def test_host_pinned_and_newest_first(self):
        self.assertEqual(tcb_prices.latest_xlsx_url(LIST_HTML), FILE_URL)
        self.assertIsNone(tcb_prices.latest_xlsx_url('<a href="https://evil.example.com/a.xlsx">'))
        self.assertIsNone(tcb_prices.latest_xlsx_url(""))

    def test_bangla_digit_cells(self):
        self.assertEqual(tcb_prices._taka("১২০"), 120)
        self.assertIsNone(tcb_prices._taka("#DIV/0!"))
        self.assertIsNone(tcb_prices._taka(0))


class TcbStoreTests(TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "tcb.json")
        self.xlsx = _xlsx_bytes(_tcb_rows())
        self.calls = []

    def getter(self, url, verify=True):
        self.calls.append((url, verify))
        if url == tcb_prices.LIST_URL:
            return LIST_HTML.encode()
        return self.xlsx

    def test_fetch_store_then_unchanged(self):
        st, payload = tcb_prices.fetch_and_store(self.getter, self.path)
        self.assertEqual(st, "updated")
        self.assertEqual(payload["date"], "2026-11-01")
        # listing unverified (broken chain), FILE always verified
        self.assertEqual(self.calls, [(tcb_prices.LIST_URL, False), (FILE_URL, True)])
        with open(self.path, encoding="utf-8") as fh:
            first = fh.read()
        st2, _ = tcb_prices.fetch_and_store(self.getter, self.path)
        self.assertEqual(st2, "unchanged")
        with open(self.path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), first)   # idempotent: not rewritten

    def test_no_link_keeps_old_list(self):
        tcb_prices.fetch_and_store(self.getter, self.path)
        st, _ = tcb_prices.fetch_and_store(lambda u, verify=True: b"<html></html>", self.path)
        self.assertEqual(st, "no_link")
        self.assertIsNotNone(tcb_prices.load(self.path))

    def test_empty_file_is_not_stored(self):
        self.xlsx = _xlsx_bytes([["nothing"]])
        st, _ = tcb_prices.fetch_and_store(self.getter, self.path)
        self.assertEqual(st, "empty")
        self.assertIsNone(tcb_prices.load(self.path))

    def test_public_view_not_connected_and_stale(self):
        with override_settings(TCB_PRICES_PATH=self.path):
            v = tcb_prices.public_view()
            self.assertFalse(v["connected"])
            self.assertEqual(v["items"], [])
            tcb_prices.fetch_and_store(self.getter, self.path)
            fresh = tcb_prices.public_view(today=date(2026, 11, 2))
            self.assertTrue(fresh["connected"])
            self.assertFalse(fresh["stale"])
            self.assertEqual(fresh["source"], "TCB")
            old = tcb_prices.public_view(today=date(2026, 11, 20))
            self.assertTrue(old["stale"])

    def test_endpoint(self):
        user = get_user_model().objects.create_user(name="Mb", phone="01711009871", password="x-pass-1234")
        c = APIClient()
        self.assertIn(c.get("/api/v1/prices/official").status_code, (401, 403))
        c.force_authenticate(user)
        with override_settings(TCB_PRICES_PATH=self.path):
            r = c.get("/api/v1/prices/official")
            self.assertEqual(r.status_code, 200)
            self.assertFalse(r.json()["connected"])
            tcb_prices.fetch_and_store(self.getter, self.path)
            body = c.get("/api/v1/prices/official").json()
            self.assertTrue(body["connected"])
            self.assertEqual(len(body["items"]), 3)
            json.dumps(body)

    def test_command_heartbeat_and_exit(self):
        from django.core.management import call_command
        from core.models import JobHeartbeat
        with mock.patch.object(tcb_prices, "fetch_and_store",
                               return_value=("updated", {"date": "2026-11-01", "items": [1]})):
            out = io.StringIO()
            call_command("tcb_prices_fetch", stdout=out)
            self.assertIn("updated", out.getvalue())
        self.assertEqual(JobHeartbeat.objects.get(name="tcb_prices_fetch").last_rc, 0)
        with mock.patch.object(tcb_prices, "fetch_and_store", return_value=("no_link", None)):
            with self.assertRaises(SystemExit):
                call_command("tcb_prices_fetch", stdout=io.StringIO())
        self.assertEqual(JobHeartbeat.objects.get(name="tcb_prices_fetch").last_rc, 1)
