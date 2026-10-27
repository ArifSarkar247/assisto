"""remmeter — exact reminders (server backup push) + prepaid meter guard.

Push HTTP is always mocked (tests_push.FakeFCM); no network, no real keys.
"""
import os
import tempfile
from datetime import datetime, timedelta
from io import StringIO
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.management import call_command
from django.test import SimpleTestCase
from django.utils import timezone

from core.logic import prepaid_meter as PM
from core.management.commands import meter_low_alerts as MLA
from core.management.commands import push_due_reminders as PDR
from core.models import Device, PaCollectionItem, Reminder
from core.tests_push import _PushBase

DHAKA = ZoneInfo("Asia/Dhaka")


def _state():
    st = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    st.close()
    return st.name


# ------------------------------------------------------------ reminders push
class ReminderBackupPushTests(_PushBase):
    def setUp(self):
        super().setUp()
        self.state = _state()
        self.addCleanup(os.unlink, self.state)
        self.u = self.mkuser("01750000101", lang="bn")
        Device.objects.create(user=self.u, push_token="rdev")

    def run_cmd(self):
        out = StringIO()
        call_command("push_due_reminders", "--state-file", self.state, stdout=out)
        return out.getvalue()

    def test_one_off_is_data_only_with_fire_at(self):
        now = timezone.now()
        r = Reminder.objects.create(user=self.u, title="ওষুধ",
                                    due_at=now - timedelta(minutes=1))
        self.assertIn("pushed=1", self.run_cmd())
        m = self.fake.sent_payloads()[0]["message"]
        # data-only: the PHONE decides (dedupe against its own alarm)
        self.assertNotIn("notification", m)
        self.assertEqual(m["data"]["kind"], "reminder")
        self.assertEqual(m["data"]["reminder_id"], str(r.id))
        self.assertEqual(m["data"]["fire_at"], r.due_at.isoformat())
        self.assertEqual(m["android"]["priority"], "HIGH")

    def test_lead_time_fire_at(self):
        now = timezone.now()
        r = Reminder.objects.create(user=self.u, title="lead",
                                    remind_before_min=10,
                                    due_at=now + timedelta(minutes=9))
        self.assertIn("pushed=1", self.run_cmd())
        d = self.fake.sent_payloads()[0]["message"]["data"]
        self.assertEqual(d["fire_at"],
                         (r.due_at - timedelta(minutes=10)).isoformat())

    def test_recurring_daily_fires_every_day(self):
        # anchor: 3 days ago at the current Dhaka minute - 1 -> today's
        # occurrence is 1 minute ago and must be pushed (old code: never).
        now = timezone.now().replace(second=0, microsecond=0)
        local = timezone.localtime(now) - timedelta(minutes=1)
        anchor = (local - timedelta(days=3))
        r = Reminder.objects.create(
            user=self.u, title="daily", due_at=anchor,
            recurrence="daily",
            recurrence_rule={"freq": "daily", "interval": 1,
                             "time": local.strftime("%H:%M")})
        with mock.patch.object(PDR.timezone, "now", return_value=now):
            self.assertIn("pushed=1", self.run_cmd())
            self.assertIn("pushed=0 already_sent=1", self.run_cmd())
        d = self.fake.sent_payloads()[0]["message"]["data"]
        self.assertEqual(d["reminder_id"], str(r.id))
        fire = datetime.fromisoformat(d["fire_at"])
        self.assertEqual(fire.astimezone(DHAKA).strftime("%H:%M"),
                         local.strftime("%H:%M"))
        self.assertEqual(fire.astimezone(DHAKA).date(), local.date())

    def test_recurring_not_due_now_is_silent(self):
        now = timezone.now()
        local = timezone.localtime(now) + timedelta(hours=2)
        Reminder.objects.create(
            user=self.u, title="later", due_at=now - timedelta(days=2),
            recurrence="daily",
            recurrence_rule={"freq": "daily", "time": local.strftime("%H:%M")})
        self.assertIn("pushed=0", self.run_cmd())

    def test_done_and_date_only_skipped(self):
        now = timezone.now()
        Reminder.objects.create(user=self.u, title="d", done=True,
                                due_at=now - timedelta(minutes=1),
                                recurrence="daily")
        Reminder.objects.create(user=self.u, title="a", date_only=True,
                                due_at=now - timedelta(minutes=1))
        self.assertIn("pushed=0", self.run_cmd())


# ------------------------------------------------------------ meter (pure)
class MeterPureTests(SimpleTestCase):
    def test_tokens_from_sms(self):
        sms = ("Your DESCO token: 1234-5678-9012-3456-7890. KCT1: "  # gitleaks:allow (fake token)
               "1111 2222 3333 4444 5555 Amount Tk 500")
        self.assertEqual(PM.extract_tokens(sms),
                         ["12345678901234567890", "11112222333344445555"])
        self.assertEqual(PM.extract_tokens("০১২৩৪৫৬৭৮৯০১২৩৪৫৬৭৮৯"),
                         ["01234567890123456789"])
        self.assertEqual(PM.extract_tokens("ref 12345 amount 500"), [])
        self.assertEqual(
            PM.extract_tokens("Token 1234-5678-9012-3456-7890 KCT1 1111 2222 "
                              "3333 4444 5555 Tk 500"),
            ["12345678901234567890", "11112222333344445555"])
        self.assertTrue(PM.valid_token("1234 5678 9012 3456 7890"))
        self.assertFalse(PM.valid_token("1234"))

    def test_meter_number_not_format_guessed(self):
        self.assertEqual(PM.validate_meter_number("desco", "০১২৩৪৫৬৭"),
                         ("01234567", None, False))
        self.assertEqual(PM.validate_meter_number("nesco", "12ab45")[1],
                         "meter_digits_only")
        self.assertEqual(PM.validate_meter_number("dpdc", "123")[1],
                         "meter_length")
        self.assertEqual(PM.validate_meter_number("dpdc", "")[1], None)

    def test_gas_has_no_wallet_path(self):
        for k in ("titas", "karnaphuli"):
            self.assertFalse(PM.UTILITIES[k]["bkash"])
            self.assertFalse(PM.UTILITIES[k]["nagad"])

    def test_user_estimate_when_history_thin(self):
        m = {"name": "Home", "balance": "300", "balance_date": "2026-10-20",
             "daily_use": "60"}
        p = PM.project_runout(m, [], as_of="2026-10-22")
        self.assertEqual(p["rate_basis"], "user")
        self.assertEqual(p["balance"], 18000)       # 300 - 2*60
        self.assertEqual(p["days_left"], 3)
        # no estimate -> still honest unknown
        p2 = PM.project_runout({"name": "x", "balance": "300",
                                "balance_date": "2026-10-20"}, [],
                               as_of="2026-10-22")
        self.assertEqual(p2["state"], "unknown")
        self.assertEqual(p2["rate_basis"], "none")

    def test_low_alert_rules(self):
        m = {"name": "Home", "balance": "100", "balance_date": "2026-10-27",
             "daily_use": "50"}
        a = PM.low_alert(m, [], as_of="2026-10-27")
        self.assertEqual(a["level"], "low")
        self.assertIn("২", a["body"]["bn"])          # Bangla digits
        self.assertIsNone(PM.low_alert({**m, "alerts": False}, [],
                                       as_of="2026-10-27"))
        self.assertIsNone(PM.low_alert({**m, "daily_use": "5"}, [],
                                       as_of="2026-10-27"))  # 20 days left
        self.assertIsNone(PM.low_alert({"name": "empty"}, [],
                                       as_of="2026-10-27"))  # no data: no fake
        self.assertEqual(PM.alert_days({"alert_days": 30}), 7)
        self.assertTrue(PM.in_quiet_hours(22))
        self.assertTrue(PM.in_quiet_hours(3))
        self.assertFalse(PM.in_quiet_hours(10))


# ------------------------------------------------------------ meter push
class MeterLowAlertTests(_PushBase):
    def setUp(self):
        super().setUp()
        self.state = _state()
        self.addCleanup(os.unlink, self.state)
        self.u = self.mkuser("01750000102", lang="en")
        Device.objects.create(user=self.u, push_token="mdev")

    def meter(self, name, bal="100", use="50"):
        return PaCollectionItem.objects.create(
            user=self.u, collection="meter/meters",
            data={"name": name, "utility": "desco", "balance": bal,
                  "balance_date": timezone.localdate().isoformat(),
                  "daily_use": use})

    def run_at(self, hour):
        now = datetime.combine(timezone.localdate(),
                               datetime.min.time()).replace(
            hour=hour, tzinfo=DHAKA)
        out = StringIO()
        with mock.patch.object(MLA.timezone, "now", return_value=now):
            call_command("meter_low_alerts", "--state-file", self.state,
                         stdout=out)
        return out.getvalue()

    def test_low_pushed_once_not_in_quiet_hours(self):
        self.meter("Home")
        self.assertIn("pushed=0", self.run_at(22))      # quiet hours
        self.assertEqual(self.fake.send_calls, [])
        self.assertIn("pushed=1", self.run_at(10))
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["kind"], "meter_low")
        self.assertEqual(m["data"]["route"], "prepaid_meter")
        self.assertIn("Recharge", m["notification"]["body"])
        self.assertIn("pushed=0", self.run_at(11))      # once per run-out

    def test_daily_cap(self):
        for i in range(4):
            self.meter("M%d" % i)
        self.assertIn("pushed=%d" % PM.MAX_ALERTS_PER_DAY, self.run_at(10))
        self.assertIn("pushed=0", self.run_at(12))

    def test_healthy_meter_silent(self):
        self.meter("Big", bal="5000", use="50")
        self.assertIn("pushed=0", self.run_at(10))
