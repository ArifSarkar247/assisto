"""dl1 — Owner Admin -> Pricing: the "Free calls (testing)" switch (audited)."""
from django.test import override_settings

from core.models import OwnerAudit
from web.tests_o2_owner_admin import OwnerBase


@override_settings(CALLS_FREE_TESTING_DEFAULT=True)
class FreeCallsSwitchTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_pricing_page_shows_and_flips_the_switch(self):
        from core.calls_free import calls_free
        r = self.c.get("/owner/pricing")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'id="calls_free"')
        # a cost switch: no reason -> refused, still ON
        r = self.post("/owner/pricing", {"action": "calls_free"})
        self.assertEqual(r.status_code, 400)
        self.assertTrue(calls_free())
        r = self.post("/owner/pricing", {"action": "calls_free", "reason": "launch"})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(calls_free())
        a = OwnerAudit.objects.get(action="flag.flip")
        self.assertEqual(a.before, {"calls_free_testing": True})
        self.assertFalse(a.after["calls_free_testing"])
        r = self.post("/owner/pricing", {"action": "calls_free", "value": "on",
                                         "reason": "beta"})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(calls_free())

    def test_pnl_still_renders(self):
        r = self.c.get("/owner/pnl")
        self.assertEqual(r.status_code, 200)
