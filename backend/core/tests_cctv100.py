"""cctv100 — CCTV rows closed in code before the owner's real-camera run.

* Extra-camera billing: 95 days of the real daily cron against the real
  credit engine — every charge has a ledger row, the balance always equals the
  ledger, nothing is charged twice, the camera is turned off (honestly) on the
  day credits run out, included cameras are never charged.
* End-of-day cash count: the same count sent twice (double tap / app retry on
  a weak network) is ONE check and ONE alert.
"""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import tests_shop_ops as SO


class BillingMonthsLedgerTests(SO._Base):
    def setUp(self):
        super().setUp()
        self.owner.plan_until = timezone.now() + timedelta(days=400)
        self.owner.save()

    def test_95_days_of_daily_runs_match_the_ledger(self):
        from core import shop_views as SV
        from core.management.commands.shop_camera_billing import run_billing
        from core.models import CreditLedger, ShopCamera
        included = SV._included_cameras(self.owner)
        need = SV._extra_camera_credits()
        self.assertGreater(need, 0)
        n_total = included + 2                         # exactly two extra cameras
        for i in range(n_total - 1):
            ShopCamera.objects.create(site=self.site, name="c%d" % i, kind="shopbox")
        self.owner.refresh_from_db()
        start_balance = int(self.owner.ai_credits)
        start = timezone.now() + timedelta(seconds=5)
        renewed = disabled = 0
        charged_days = []
        for d in range(0, 95):
            res = run_billing(now=start + timedelta(days=d))
            renewed += res["renewed"]
            disabled += res["disabled"]
            if res["credits"]:
                charged_days.append(d)
        self.owner.refresh_from_db()
        spent = start_balance - int(self.owner.ai_credits)
        ledger = sum(-r.delta for r in CreditLedger.objects.filter(
            user=self.owner, delta__lt=0, note__startswith="shop camera #"))
        # money truth: what left the balance == what the ledger says == renewals x price
        self.assertEqual(spent, ledger)
        self.assertEqual(spent, renewed * need)
        self.assertGreaterEqual(int(self.owner.ai_credits), 0)
        # each paid month starts on day 30/60/90 — never charged on other days
        self.assertTrue(set(charged_days) <= {30, 60, 90}, charged_days)
        # 100 credits at 20 each: 5 renewals, then one camera turned off
        months_affordable = start_balance // need
        self.assertEqual(renewed, min(months_affordable, 6))
        if months_affordable < 6:
            self.assertEqual(disabled, 1)
            self.assertEqual(ShopCamera.objects.filter(site=self.site, enabled=False).count(), 1)
        # the included cameras (oldest) were never touched
        for cam in SV.owner_enabled_cameras(self.owner)[:included]:
            self.assertTrue(cam.enabled)

    def test_cron_outage_never_double_charges(self):
        from core import shop_views as SV
        from core.management.commands.shop_camera_billing import run_billing
        from core.models import ShopCamera
        included = SV._included_cameras(self.owner)
        for i in range(included):
            ShopCamera.objects.create(site=self.site, name="c%d" % i, kind="shopbox")
        self.owner.ai_credits = 500
        self.owner.save()
        self.owner.refresh_from_db()
        before = int(self.owner.ai_credits)
        # the cron was down for 70 days: one run must charge ONE period only
        res = run_billing(now=timezone.now() + timedelta(days=70))
        self.assertEqual(res["renewed"], 1)
        self.owner.refresh_from_db()
        self.assertEqual(before - int(self.owner.ai_credits), SV._extra_camera_credits())
        self.assertEqual(run_billing(now=timezone.now() + timedelta(days=71))["renewed"], 0)


class EodDuplicateTests(SO._Base):
    def test_same_count_twice_is_one_check_one_alert(self):
        from core.models import ShopEodCheck, ShopEvent
        url = "/api/v1/shop/sites/%d/eod" % self.site.id
        with mock.patch("core.shop_ops_views.todays_cash_sales", return_value=(250000, 3)):
            r1 = self.client.post(url, {"counted_cash": 100000}, format="json")
            r2 = self.client.post(url, {"counted_cash": 100000}, format="json")
            r3 = self.client.post(url, {"counted_cash": 250000}, format="json")
        self.assertEqual(r1.status_code, 201, r1.data)
        self.assertEqual(r1.data["status"], "short")
        self.assertEqual((r2.status_code, r2.data["duplicate"], r2.data["id"]),
                         (200, True, r1.data["id"]))
        self.assertEqual(r2.data["message"], r1.data["message"])
        self.assertEqual(ShopEvent.objects.filter(type="eod_mismatch").count(), 1)
        # a real re-count (different amount) is a new check
        self.assertEqual((r3.status_code, r3.data["status"]), (201, "ok"))
        self.assertEqual(ShopEodCheck.objects.count(), 2)
