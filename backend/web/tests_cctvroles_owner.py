"""cctvroles (CCTV Guard V3 J + K): Owner Admin -> CCTV installer partners.
Approve / suspend with a reason (audited), the commission rules shown as
OWNER-DECIDED (cctvprice, 17 Nov 12:35), the ledger (owed -> paid by a person,
audited), and never any camera media on the page."""
from django.utils import timezone

from core.models import CctvInstallerLink, CctvPartner, OwnerAudit, ShopCamera, ShopSite, User
from web.tests_o2_owner_admin import OwnerBase


class CctvPartnersPageTests(OwnerBase):
    def test_list_approve_and_proposal_only(self):
        tech = User.objects.create_user(name="Rana", phone="01710007301", password="pw")
        shop = User.objects.create_user(name="Dokan", phone="01710007302", password="pw")
        p = CctvPartner.objects.create(user=tech, name="Rana CCTV", area="Mirpur")
        site = ShopSite.objects.create(owner=shop, name="Secret shop name", last_seen=timezone.now())
        ShopCamera.objects.create(site=site, name="Gate", kind="shopbox")
        CctvInstallerLink.objects.create(site=site, partner=p, code_hash="x" * 64,
                                         status="active", accepted_at=timezone.now(),
                                         expires_at=timezone.now())
        self.ready()
        r = self.c.get("/owner/cctv-partners")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn('id="cctv-partners"', html)
        self.assertIn("Rana CCTV", html)
        self.assertIn("OWNER-DECIDED", html)
        self.assertNotIn("PROPOSAL", html)
        self.assertIn("মালিকের সিদ্ধান্ত", html)
        self.assertIn('id="cctv-ledger-sums"', html)
        self.assertIn('id="cctv-payouts"', html)
        # setup facts only: no place name, no media link
        self.assertNotIn("Secret shop name", html)
        for bad in ("/m/", "/media/", "snapshot", ".jpg"):
            self.assertNotIn(bad, html)
        # no reason -> nothing changes
        self.post("/owner/cctv-partners", {"partner": p.id, "action": "approve"})
        p.refresh_from_db()
        self.assertEqual(p.status, "pending")
        self.post("/owner/cctv-partners", {"partner": p.id, "action": "approve",
                                           "reason": "met in person"})
        p.refresh_from_db()
        self.assertEqual(p.status, "approved")
        self.assertTrue(OwnerAudit.objects.filter(action="cctv_partner.approve").exists())
        r = self.c.get("/owner/cctv-partners?lang=en")
        self.assertNotContains(r, "needs owner approval")
        self.assertContains(r, "never on the base 500 Tk")
        self.assertContains(r, "No lines yet")

    def test_ledger_mark_paid_needs_reference_and_reason_and_is_audited(self):
        from core.models import CctvCommissionEntry
        tech = User.objects.create_user(name="Rana", phone="01710007311", password="pw")
        p = CctvPartner.objects.create(user=tech, name="Rana CCTV", area="Mirpur",
                                       status="approved")
        e = CctvCommissionEntry.objects.create(partner=p, order_id="GPA.L-1", month="2026-12",
                                               cameras=2, premium_ai_net_bdt=591.30,
                                               amount_bdt=59)
        self.ready()
        r = self.c.get("/owner/cctv-partners?lang=en")
        self.assertContains(r, 'id="cctv-ledger"')
        self.assertContains(r, "Total owed: <b>59</b>")
        # no reference -> still owed (never a blind "paid")
        self.post("/owner/cctv-partners", {"entry": e.id, "action": "mark_paid",
                                           "reason": "paid"})
        e.refresh_from_db()
        self.assertEqual(e.status, "owed")
        self.post("/owner/cctv-partners", {"entry": e.id, "action": "mark_paid",
                                           "reason": "paid by bKash", "paid_ref": "TX123"})
        e.refresh_from_db()
        self.assertEqual((e.status, e.paid_ref), ("paid", "TX123"))
        self.assertTrue(OwnerAudit.objects.filter(action="cctv_commission.mark_paid").exists())
        r = self.c.get("/owner/cctv-partners?lang=en")
        self.assertContains(r, "Total paid: <b>59</b>")

    def test_needs_login(self):
        r = self.c.get("/owner/cctv-partners")
        self.assertIn(r.status_code, (302, 403))
