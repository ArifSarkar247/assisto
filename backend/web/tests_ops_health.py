"""ops-watch: Owner Admin → System health + Crash rate pages (owner-only,
bn/en, jobs / services / missing cron lines / backups, crash-rate tables)."""
from datetime import timedelta
from unittest import mock

from django.contrib.auth import get_user_model
from django.utils import timezone

from core import ops_health as H
from core.models import ActiveDay, ClientErrorReport, JobHeartbeat
from web.tests_o2_owner_admin import OwnerBase

User = get_user_model()
SVC = "LoadState=loaded\nActiveState=active\nSubState=running"


class SystemHealthPageTests(OwnerBase):
    def get(self, path):
        cron = "\n".join(j.cron_line() for j in H.JOBS if j.name != "antitheft_escalate")
        with mock.patch("core.ops_health.installed_cron_text", return_value=cron), \
                mock.patch("core.ops_health._systemctl_show", return_value=SVC):
            return self.c.get(path)

    def test_requires_owner_login(self):
        r = self.c.get("/owner/system")
        self.assertEqual(r.status_code, 302)
        r = self.c.get("/owner/vitals/crash-rate")
        self.assertEqual(r.status_code, 302)

    def test_normal_user_cannot_log_in(self):
        User.objects.create_user(phone="+8801700000444", password="pw-12345678", name="U")
        r = self.c.post("/owner/login", {"phone": "+8801700000444", "password": "pw-12345678"})
        self.assertNotEqual(r.get("Location"), "/owner/enrol")
        self.assertEqual(self.c.get("/owner/system").status_code, 302)

    def test_page_en_bn(self):
        self.ready()
        now = timezone.now()
        JobHeartbeat.objects.create(name="billing_daily", last_start=now, last_finish=now,
                                    last_rc=1, last_error="KeyError", last_duration_ms=42)
        r = self.get("/owner/system?lang=en")
        self.assertContains(r, "System health")
        self.assertContains(r, "billing_daily")
        self.assertContains(r, "FAILING")
        self.assertContains(r, "Jobs with no cron line")
        self.assertContains(r, H.JOB_BY_NAME["antitheft_escalate"].cron_line().replace(">", "&gt;").replace("&&", "&amp;&amp;"))
        self.assertContains(r, "coturn")
        r = self.get("/owner/system?lang=bn")
        self.assertContains(r, "সিস্টেমের অবস্থা")
        self.assertContains(r, 'href="/owner/system"')


class CrashRatePageTests(OwnerBase):
    def test_too_few_users_and_tables(self):
        self.ready()
        u = User.objects.create_user(phone="+8801700000555", password="pw-12345678", name="P")
        today = timezone.localdate()
        ActiveDay.objects.create(user=u, day=today, cohort_day=today)
        now = timezone.now()
        ClientErrorReport.objects.create(
            fingerprint="a" * 20, day=today, user=u, fatal=True, error_type="StateError",
            brand="realme", model="RMX3491", android="13", version="1.0.200",
            first_at=now, last_at=now)
        r = self.c.get("/owner/vitals/crash-rate?lang=en&days=7")
        self.assertContains(r, "Too few users")
        self.assertContains(r, "By phone brand")
        self.assertContains(r, "realme")
        self.assertContains(r, "RMX3491")
        self.assertContains(r, "100.0%")           # 1 crashed of 1 active today
        self.assertContains(r, "/owner/reports/errors/" + "a" * 20)
        r = self.c.get("/owner/vitals/crash-rate?lang=bn")
        self.assertContains(r, "ক্র্যাশের হার")
        self.assertContains(self.c.get("/owner/vitals?lang=en"), "/owner/vitals/crash-rate")

    def test_empty(self):
        self.ready()
        r = self.c.get("/owner/vitals/crash-rate?lang=en&days=30")
        self.assertContains(r, "No crashes or ANRs in this period.")
        self.assertEqual(self.c.get("/owner/vitals/crash-rate?days=abc").status_code, 200)
