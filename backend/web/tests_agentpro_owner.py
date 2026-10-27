"""agent-proactive: Owner Admin -> Agent runs shows per-trigger nudge stats."""
from datetime import date

from django.utils import timezone

from core.models import AgentNudge, AgentNudgePrefs, User
from web.tests_o2_owner_admin import OwnerBase


class NudgeStatsPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        u = User.objects.create_user(name="Rina", phone="01711000412", password="x")
        d = date(2026, 11, 10)
        AgentNudge.objects.create(user=u, trigger="stock_low", dedupe_key="a", for_date=d,
                                  delivery="push", pushed_at=timezone.now(), opened_at=timezone.now())
        AgentNudge.objects.create(user=u, trigger="stock_low", dedupe_key="b", for_date=d,
                                  delivery="brief", reason="cap")
        AgentNudge.objects.create(user=u, trigger="brief_morning", dedupe_key="c", for_date=d,
                                  delivery="card", dismissed_at=timezone.now())
        AgentNudgePrefs.objects.create(user=u, off=["stock_low", "camera_alert"])
        self.ready()

    def test_stats_table(self):
        r = self.c.get("/owner/agent-runs?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Proactive nudges (no AI, no credits)")
        html = r.content.decode()
        row = html.split("<td>stock_low</td>", 1)[1].split("</tr>", 1)[0]
        self.assertEqual(row.replace("<td>", "").replace("</td>", " ").split(),
                         ["2", "1", "1", "1", "0", "1"])
        cam = html.split("<td>camera_alert</td>", 1)[1].split("</tr>", 1)[0]
        self.assertTrue(cam.strip().endswith("<td>1</td>"))
        r = self.c.get("/owner/agent-runs?lang=bn")
        self.assertContains(r, "প্রোঅ্যাকটিভ নাজ")
