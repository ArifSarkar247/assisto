"""mapscost: Owner Admin -> Maps usage (numbers only, caps + rate editable,
every edit audited, bad numbers refused)."""
from django.utils import timezone

from core import maps_cost as MC
from core.models import MapsUsage, OwnerAudit
from web.tests_o2_owner_admin import OwnerBase


class MapsUsagePageTests(OwnerBase):
    def test_card_shows_calls_cost_and_free_left(self):
        MapsUsage.objects.create(day=timezone.localdate(), api="geocode", user_id=3,
                                 count=10200, capped=4)
        self.ready()
        r = self.c.get("/owner/maps-usage")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("ম্যাপ খরচ", html)
        self.assertIn('id="maps-usage"', html)
        self.assertIn("$1.0", html)                      # 200 over x $5/1000
        self.assertIn("৳122.0", html)
        r = self.c.get("/owner/maps-usage?lang=en")
        self.assertContains(r, "Global daily cap")

    def test_edit_caps_and_rate_audited(self):
        self.ready()
        r = self.post("/owner/maps-usage", {"api": "geocode", "user_day": "7", "global_day": "90",
                                            "usd_per_1000": "5", "free_month": "10000"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        c = MC.config()["apis"]["geocode"]
        self.assertEqual((c["user_day"], c["global_day"]), (7, 90))
        self.assertTrue(OwnerAudit.objects.filter(action="maps.cost").exists())
        r = self.post("/owner/maps-usage", {"api": "_bdt", "bdt_per_usd": "125"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(MC.config()["bdt_per_usd"], 125.0)
        r = self.post("/owner/maps-usage", {"api": "geocode", "user_day": "-3"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(MC.config()["apis"]["geocode"]["user_day"], 7)

    def test_needs_login(self):
        r = self.c.get("/owner/maps-usage")
        self.assertIn(r.status_code, (302, 403))
