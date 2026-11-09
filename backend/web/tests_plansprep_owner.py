"""plansprep: Owner Admin -> Plans & prices (book, 40 % check, the pricing_v2
switch with a typed reason, audited plan edits, change history, P&L)."""
from core import billing
from web.tests_o2_owner_admin import OwnerBase


class PlansPageTests(OwnerBase):
    def test_page_shows_book_check_flip_and_pnl(self):
        self.ready()
        r = self.c.get("/owner/plans?lang=en")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        for s in ('id="plans-book"', 'id="plans-check"', 'id="plans-flip"', 'id="plans-pnl"',
                  'id="plans-history"', "pricing_v2.on: False → True", "assisto_premium"):
            self.assertIn(s, html)

    def test_switch_needs_a_reason_and_is_audited(self):
        self.ready()
        r = self.post("/owner/plans", {"action": "v2", "value": "on", "reason": ""})
        self.assertEqual(r.status_code, 400)
        self.assertFalse(billing.cfg()["pricing_v2"]["on"])
        n0 = len(billing.get_config().audit or [])
        r = self.post("/owner/plans", {"action": "v2", "value": "on", "reason": "owner yes 9 Nov"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        self.assertTrue(billing.cfg()["pricing_v2"]["on"])
        self.assertEqual(len(billing.get_config().audit or []), n0 + 1)
        html = self.c.get("/owner/plans?lang=en").content.decode()
        self.assertIn("owner yes 9 Nov", html)          # change history
        r = self.post("/owner/plans", {"action": "v2", "value": "off", "reason": "rollback"})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(billing.cfg()["pricing_v2"]["on"])

    def test_plan_edit_is_audited_and_credits_locked_under_v2(self):
        self.ready()
        r = self.post("/owner/plans", {"action": "plans", "premium.family": "6", "free.ads": "on",
                                       "reason": "family seats"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        self.assertEqual(billing.cfg()["plans"]["premium"]["family"], 6)
        self.post("/owner/plans", {"action": "v2", "value": "on", "reason": "on"})
        self.post("/owner/plans", {"action": "plans", "premium.credits": "999", "free.ads": "on", "reason": "x"})
        self.assertNotEqual(billing.cfg()["plans"]["premium"]["credits"], 999)
