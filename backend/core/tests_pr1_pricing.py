"""pr1 — owner decisions (2026-10):
  (1) nothing is unlimited in any plan: Premium = 90 AI credits per month,
      Business = 240; every AI action debits credits (safety stays free);
  (2) Owner Admin disk alert at 80% (banner + de-duplicated owner alert).
"""
import shutil
import tempfile
from datetime import datetime, timedelta, timezone as dt_tz
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing, disk_alert, plans
from core.logic import pricing as P
from core.models import CreditLedger, FamilyAlert, User


def _du(total_gb, used_gb):
    g = 10 ** 9
    return shutil._ntuple_diskusage(total_gb * g, used_gb * g, (total_gb - used_gb) * g)


# ===================================================================== pricing
class NothingUnlimitedLogicTests(SimpleTestCase):
    def test_every_public_plan_is_not_unlimited_and_premium_is_90(self):
        for lang in ("bn", "en"):
            out = P.plan_public(lang, P.DEFAULTS())
            for p in out:
                self.assertFalse(p["unlimited_ai"], p["id"])
                self.assertNotIn("nlimited", " ".join(p["benefits"]) + p["desc"])
                self.assertNotIn("আনলিমিটেড", " ".join(p["benefits"]) + p["desc"])
            by = {p["id"]: p for p in out}
            self.assertEqual(by["premium"]["credits"], 90)
            self.assertEqual(by["annual"]["credits"], 90)
            self.assertEqual(by["business"]["credits"], 240)
        en = {p["id"]: p for p in P.plan_public("en", P.DEFAULTS())}
        self.assertIn("90 AI credits / month", en["premium"]["benefits"][0])
        bn = {p["id"]: p for p in P.plan_public("bn", P.DEFAULTS())}
        self.assertIn("৯০", bn["premium"]["benefits"][0])

    def test_normalize_forces_false_even_for_a_stored_true(self):
        raw = P.DEFAULTS()
        for pid in raw["plans"]:
            raw["plans"][pid]["unlimited_ai"] = True
        c = P.normalize(raw)
        self.assertTrue(all(not r["unlimited_ai"] for r in c["plans"].values()))
        self.assertFalse(any(p["unlimited_ai"] for p in P.plan_public("en", raw)))

    def test_validate_edit_refuses_unlimited(self):
        self.assertIn("unlimited_not_allowed",
                      P.validate_edit({"plans": {"premium": {"unlimited_ai": True}}}))
        self.assertNotIn("unlimited_not_allowed",
                         P.validate_edit({"plans": {"premium": {"unlimited_ai": False}}}))

    def test_literal_plans_are_never_unlimited(self):
        for pid, s in plans.PLANS.items():
            self.assertFalse(s["unlimited_ai"], pid)
            if pid != "free":
                self.assertGreater(s["credits"], 0, pid)
            text = " ".join(s["benefits_en"] + s["benefits_bn"]) + s["desc_en"] + s["desc_bn"]
            self.assertNotIn("nlimited", text, pid)
            self.assertNotIn("আনলিমিটেড", text, pid)


class PremiumMonthlyPoolTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Prem", phone="01830009001",
                                          password="x123456")
        self.u.plan = "premium"
        self.u.plan_until = timezone.now() + timedelta(days=30)
        self.u.save()

    def test_plans_public_endpoint_premium_90_nothing_unlimited(self):
        self.assertTrue(all(not p["unlimited_ai"] for p in plans.plans_public("en")))
        prem = next(p for p in plans.plans_public("en") if p["id"] == "premium")
        self.assertEqual(prem["credits"], 90)
        self.assertFalse(billing._has_unlimited(self.u))
        self.assertFalse(plans.entitlements(self.u, "en")["unlimited_ai"])

    def test_premium_gets_90_once_per_month_and_charge_debits(self):
        self.assertEqual(billing.grant_monthly_pool(self.u), 90)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 90)
        self.assertEqual(billing.grant_monthly_pool(self.u), 0)   # idempotent
        need = P.credits_for("ai_msg_cheap", 1, billing.cfg())
        r = billing.charge(self.u, "ai_msg_cheap")
        self.assertTrue(r["ok"])
        self.assertEqual(r["reason"], "ok")
        self.assertEqual(r["charged"], need)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 90 - need)
        self.assertTrue(CreditLedger.objects.filter(
            user=self.u, reason="consume", delta=-need).exists())

    def test_charge_grants_the_pool_on_first_touch(self):
        self.assertEqual(self.u.ai_credits, 0)
        r = billing.charge(self.u, "ai_msg_cheap")
        self.assertTrue(r["ok"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 90 - r["charged"])

    def test_premium_out_of_credits_is_refused(self):
        billing.grant_monthly_pool(self.u)
        self.u.refresh_from_db()
        self.u.ai_credits = 0
        self.u.save()
        r = billing.charge(self.u, "ai_msg_strong")
        self.assertFalse(r["ok"])
        self.assertEqual(r["reason"], "insufficient")

    def test_safety_still_free_for_premium(self):
        billing.grant_monthly_pool(self.u)
        self.u.refresh_from_db()
        r = billing.charge(self.u, "sos_sms")
        self.assertEqual((r["ok"], r["reason"], r["charged"]), (True, "exempt", 0))

    def test_next_month_resets_pool_but_keeps_purchased_credits(self):
        oct_ = datetime(2026, 10, 15, 12, 0, tzinfo=dt_tz.utc)
        nov_ = datetime(2026, 11, 3, 12, 0, tzinfo=dt_tz.utc)
        self.u.plan_until = datetime(2027, 1, 1, tzinfo=dt_tz.utc)
        self.u.save()
        with mock.patch("django.utils.timezone.now", return_value=oct_):
            billing.grant_monthly_pool(self.u, now=oct_)
            billing.credit(self.u, "topup", 35, note="pack:p30")   # purchased
            CreditLedger.objects.create(user=self.u, delta=-10, reason="consume",
                                        note="ai_msg_medium")
            User.objects.filter(pk=self.u.pk).update(ai_credits=90 + 35 - 10)
        self.u.refresh_from_db()
        with mock.patch("django.utils.timezone.now", return_value=nov_):
            self.assertEqual(billing.grant_monthly_pool(self.u, now=nov_), 90)
        self.u.refresh_from_db()
        # 80 unused pool expired (no rollover), 35 purchased kept, +90 new pool
        self.assertEqual(self.u.ai_credits, 35 + 90)
        self.assertTrue(CreditLedger.objects.filter(
            user=self.u, reason="expire", delta=-80).exists())

    def test_trial_and_free_get_no_paid_pool(self):
        f = User.objects.create_user(name="F", phone="01830009002", password="x123456")
        f.trial_until = timezone.now() + timedelta(days=7)
        f.save()
        self.assertEqual(plans.effective_plan(f), "premium")   # trial
        self.assertEqual(billing.grant_monthly_pool(f), 0)
        f.trial_until = timezone.now() - timedelta(days=1)
        f.save()
        self.assertEqual(billing.grant_monthly_pool(f), 0)

    def test_business_and_founder_pools(self):
        b = User.objects.create_user(name="B", phone="01830009003", password="x123456")
        b.plan = "business"
        b.plan_until = timezone.now() + timedelta(days=30)
        b.save()
        self.assertEqual(billing.grant_monthly_pool(b), 240)
        f = User.objects.create_user(name="Fo", phone="01830009004", password="x123456")
        f.is_founder = True
        f.save()
        self.assertEqual(plans.effective_plan(f), "founder")
        self.assertEqual(billing.grant_monthly_pool(f), 90)

    def test_daily_sweep_grants_paid_users(self):
        out = StringIO()
        call_command("profit_guard_rollover", stdout=out)
        self.assertIn("pools_granted=1", out.getvalue())
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 90)


# ================================================================ disk alert
class DiskAlertTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            name="Owner", phone="01830009010", password="x123456",
            is_staff=True, is_superuser=True)

    def _check(self, used, state, now=None):
        n = mock.Mock()
        with mock.patch("core.disk_alert.disk_usage", return_value=_du(100, used)):
            st = disk_alert.check_and_alert(state, now=now, notify=n)
        return st, n

    def test_79_percent_no_alert(self):
        state = {}
        st, n = self._check(79, state)
        self.assertFalse(st["alert"])
        self.assertEqual(n.call_count, 0)
        self.assertFalse(FamilyAlert.objects.filter(kind="disk_alert").exists())
        from .models import NotifEvent
        self.assertFalse(NotifEvent.objects.filter(type="admin").exists())

    def test_80_percent_alerts_with_pct_and_free_gb(self):
        state = {}
        st, n = self._check(80, state)
        self.assertTrue(st["alert"] and st["alerted"])
        self.assertEqual(n.call_count, 1)
        title, body = n.call_args[0]
        self.assertIn("80.0%", title)
        self.assertIn("20.0 GB free", body)
        self.assertIn("disk_alert_at", state)
        # owner 25 Oct: disk alerts are ADMIN notifications, never Family alerts
        from .models import NotifEvent
        self.assertFalse(FamilyAlert.objects.filter(kind="disk_alert").exists())
        a = NotifEvent.objects.get(user=self.owner, type="admin", meta__kind="disk_alert")
        self.assertIn("৮০", a.title_bn)

    def test_dedupe_once_per_6h_and_rearm_after_recovery(self):
        t0 = datetime(2026, 10, 23, 1, 0, tzinfo=dt_tz.utc)
        state = {}
        _, n1 = self._check(85, state, now=t0)
        _, n2 = self._check(86, state, now=t0 + timedelta(minutes=2))
        _, n3 = self._check(86, state, now=t0 + timedelta(hours=5, minutes=58))
        self.assertEqual((n1.call_count, n2.call_count, n3.call_count), (1, 0, 0))
        _, n4 = self._check(86, state, now=t0 + timedelta(hours=6))
        self.assertEqual(n4.call_count, 1)
        # back under the limit clears the marker; a new crossing alerts at once
        self._check(70, state, now=t0 + timedelta(hours=6, minutes=2))
        self.assertNotIn("disk_alert_at", state)
        _, n5 = self._check(81, state, now=t0 + timedelta(hours=6, minutes=4))
        self.assertEqual(n5.call_count, 1)
        from .models import NotifEvent
        self.assertEqual(NotifEvent.objects.filter(type="admin", meta__kind="disk_alert").count(), 3)

    def test_threshold_is_admin_editable(self):
        row = billing.get_config()
        row.data.setdefault("limits", {})["disk_alert_pct"] = 90
        row.save()
        st, n = self._check(85, {})
        self.assertEqual(st["threshold"], 90)
        self.assertFalse(st["alert"])
        self.assertEqual(n.call_count, 0)

    def test_uptime_check_raises_and_dedupes_via_state_file(self):
        tmp = tempfile.mkdtemp()
        m = "core.management.commands.uptime_check"
        with override_settings(BASE_DIR=tmp), \
                mock.patch(m + "._http_ok", return_value=(True, "200")), \
                mock.patch(m + "._cert_days", return_value=60), \
                mock.patch("core.disk_alert.disk_usage", return_value=_du(100, 82)), \
                mock.patch("core.push.notify_owner", return_value={}) as n:
            for _ in range(3):
                call_command("uptime_check", stdout=StringIO())
        self.assertEqual(n.call_count, 1)
        self.assertIn("disk", n.call_args[0][0].lower())


class DiskStatusTests(SimpleTestCase):
    def test_status_under_and_over(self):
        with mock.patch("core.disk_alert.disk_usage", return_value=_du(100, 79)):
            self.assertFalse(disk_alert.status(threshold=80)["alert"])
        with mock.patch("core.disk_alert.disk_usage", return_value=_du(100, 80)):
            st = disk_alert.status(threshold=80)
        self.assertTrue(st["alert"])
        self.assertEqual((st["used_pct"], st["free_gb"], st["threshold"]), (80.0, 20.0, 80))
