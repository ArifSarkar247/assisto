"""t9-turnscale: Owner Admin → Call relay page (bn/en, empty state honest,
server list validation + audit, thresholds) and the P&L relay-cost block."""
from django.test import override_settings
from django.utils import timezone

from core.models import OwnerAudit, TurnConfig, TurnSample
from web.tests_o2_owner_admin import OwnerBase


@override_settings(TURN_SERVERS="", TURN_TOTAL_QUOTA=600, TURN_BPS_CAPACITY=31250000,
                   TURN_MAX_BPS=250000)
class CallRelayPanelTests(OwnerBase):
    def test_requires_login(self):
        r = self.c.get("/owner/calls")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r["Location"], "/owner/login")

    def test_empty_state_and_bn_en(self):
        self.ready()
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, "No samples yet")
        self.assertContains(r, "No list set")
        self.assertContains(r, "real allocation ceiling 125")
        self.assertContains(r, "Cost per relayed minute")
        r = self.c.get("/owner/calls?lang=bn")
        self.assertContains(r, "কল রিলে (TURN)")

    def test_sample_shown_with_percent(self):
        self.ready()
        TurnSample.objects.create(at=timezone.now(), allocations=100, nic_out_bps=1_250_000,
                                  turn_cpu_pct=4.5, quota_errors=2, sources="ss,nic")
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, "80%")          # 100 / 125
        self.assertContains(r, "Whole-server network traffic")

    def test_save_list_validates_and_audits(self):
        self.ready()
        r = self.post("/owner/calls", {"action": "servers", "servers_text": "bad host!!"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(TurnConfig.load().servers_text, "")
        r = self.post("/owner/calls", {"action": "servers",
                                       "servers_text": "turn.lifeassisto.com\nturn2.lifeassisto.com|w=2"})
        self.assertEqual(r.status_code, 302)
        self.assertIn("turn2", TurnConfig.load().servers_text)
        self.assertTrue(OwnerAudit.objects.filter(action="turn.servers").exists())
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, "turn2.lifeassisto.com")
        self.assertContains(r, "this page")

    def test_thresholds(self):
        self.ready()
        r = self.post("/owner/calls", {"action": "thresholds", "alloc_pct": "abc"})
        self.assertEqual(r.status_code, 400)
        r = self.post("/owner/calls", {"action": "thresholds", "alloc_pct": "50"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(TurnConfig.load().thresholds, {"alloc_pct": 50.0})

    def test_pnl_shows_relay_cost(self):
        self.ready()
        r = self.c.get("/owner/pnl?lang=en")
        self.assertContains(r, "Relay cost per minute")
        self.assertContains(r, "estimate")
