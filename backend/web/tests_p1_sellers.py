"""p1-bizagent: Owner Admin → Sellers (list, per-channel status + disable,
global kill switch, seller plans edited through the margin-checked pricing
engine, WhatsApp-cost-unset warning)."""
from datetime import timedelta

from django.utils import timezone

from core import billing
from core.models import BusinessProfile, OwnerAudit, SellerAgent, SellerChannel, User
from web.tests_o2_owner_admin import OwnerBase


class SellersPanelTests(OwnerBase):
    def _seller(self):
        u = User.objects.create_user(email="shop@example.invalid", name="Shop Owner", password="x")
        b = BusinessProfile.objects.create(user=u, shop_name="Nila Boutique")
        SellerAgent.objects.create(business=b, plan="starter", ai_enabled=True,
                                   period_end=timezone.now() + timedelta(days=20), replies_used=12)
        ch = SellerChannel.objects.create(business=b, kind="messenger", external_id="77",
                                          status="connected")
        return b, ch

    def test_requires_login(self):
        r = self.c.get("/owner/sellers")
        self.assertEqual(r.status_code, 302)

    def test_list_warning_and_bn_en(self):
        self._seller()
        self.ready()
        r = self.c.get("/owner/sellers?lang=en")
        self.assertContains(r, "Nila Boutique")
        self.assertContains(r, "12 / 1000")
        self.assertContains(r, "WhatsApp cost per message is not set")
        self.assertContains(r, "/api/v1/bizagent/webhook/meta")
        r = self.c.get("/owner/sellers?lang=bn")
        self.assertContains(r, "বিক্রেতা (AI এজেন্ট)")

    def test_kill_switch_and_channel_disable_audited(self):
        b, ch = self._seller()
        self.ready()
        r = self.post("/owner/sellers", {"action": "kill", "kill_whatsapp_cloud": "on",
                                         "reason": "meta outage"})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(billing.cfg()["seller_agent"]["kill"]["whatsapp_cloud"])
        self.assertFalse(billing.cfg()["seller_agent"]["kill"]["messenger"])
        r = self.post("/owner/sellers", {"action": "channel", "channel": ch.id})
        ch.refresh_from_db()
        self.assertFalse(ch.enabled)
        self.assertTrue(OwnerAudit.objects.filter(action="bizagent.channel").exists())

    def test_plan_edit_margin_enforced(self):
        self.ready()
        base = {"action": "config", "price_starter": "1490", "replies_starter": "1000",
                "price_pro": "3990", "replies_pro": "3000", "trial_days": "7",
                "trial_replies": "100", "low_stock_default": "3", "wa_marketing": "1.5",
                "wa_utility": "0", "wa_authentication": "0", "wa_service": "0"}
        r = self.post("/owner/sellers", dict(base, price_pro="1500"))
        self.assertEqual(r.status_code, 400)
        self.assertContains(r, "লক্ষ্য মার্জিন", status_code=400)
        r = self.post("/owner/sellers", base)
        self.assertEqual(r.status_code, 302)
        sa = billing.cfg()["seller_agent"]
        self.assertEqual(sa["wa_cost_bdt"]["marketing"], 1.5)
        r = self.c.get("/owner/sellers?lang=en")
        self.assertNotContains(r, "WhatsApp cost per message is not set")
