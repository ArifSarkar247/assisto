"""amarket (3 Nov): Owner Admin -> Market (seller approve / suspend / reject,
Market report queue remove / restore, audit, bn/en, owner only)."""
from django.utils import timezone
from datetime import timedelta

from core.models import (BusinessProfile, MarketBid, MarketNeed, MarketSeller,
                         ModerationItem, OwnerAudit, User)
from web.tests_o2_owner_admin import OwnerBase, SClient


class MarketOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.seller = User.objects.create_user(name="Seller", phone="01788100001", password="x")
        self.buyer = User.objects.create_user(name="Buyer", phone="01788100002", password="x")
        biz = BusinessProfile.objects.create(user=self.seller, shop_name="Rahim Store")
        self.s = MarketSeller.objects.create(user=self.seller, business=biz, area="mirpur",
                                             categories=["grocery"])
        self.need = MarketNeed.objects.create(
            buyer=self.buyer, category="grocery", title="Rice 25kg", quantity=25, unit="kg",
            area="mirpur", deadline=timezone.now() + timedelta(days=2))
        self.item = ModerationItem.objects.create(target_kind="mkt_need",
                                                  target_id=str(self.need.pk),
                                                  categories=["spam"], content_status="hidden")
        self.ready()

    def test_page_lists_pending_and_reports(self):
        r = self.c.get("/owner/market?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Rahim Store")
        self.assertContains(r, "Rice 25kg")
        r = self.c.get("/owner/market?lang=bn&status=approved")
        self.assertContains(r, "বিক্রেতার আবেদন")
        self.assertNotContains(r, "Rahim Store")

    def test_approve_then_suspend_audited(self):
        r = self.post("/owner/market/sellers/%d/act" % self.s.pk, {"decision": "approved"})
        self.assertEqual(r.status_code, 302)
        self.s.refresh_from_db()
        self.assertEqual((self.s.status, self.s.decided_by_id), ("approved", self.owner.pk))
        MarketBid.objects.create(need=self.need, seller=self.seller, unit_price=8000)
        self.post("/owner/market/sellers/%d/act" % self.s.pk, {"decision": "suspended"})
        self.assertEqual(MarketBid.objects.get(seller=self.seller).status, "withdrawn")
        self.assertTrue(OwnerAudit.objects.filter(action="market_seller.suspended").exists())
        self.assertEqual(self.post("/owner/market/sellers/%d/act" % self.s.pk,
                                   {"decision": "bogus"}).status_code, 404)

    def test_report_remove_and_restore(self):
        self.post("/owner/market/reports/%d/act" % self.item.pk, {"action": "remove"})
        self.need.refresh_from_db()
        self.assertEqual((self.need.content_status, self.need.status), ("removed", "closed"))
        self.item.refresh_from_db()
        self.assertEqual(self.item.queue_state, "resolved")
        it2 = ModerationItem.objects.create(target_kind="mkt_need", target_id=str(self.need.pk),
                                            categories=["spam"], content_status="hidden")
        self.post("/owner/market/reports/%d/act" % it2.pk, {"action": "restore"})
        self.need.refresh_from_db()
        self.assertEqual(self.need.content_status, "restored")
        self.assertTrue(OwnerAudit.objects.filter(action="market_report.restore").exists())

    def test_requires_owner(self):
        r = SClient().get("/owner/market")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
