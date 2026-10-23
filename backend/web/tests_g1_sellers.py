"""g1-bizagent: Owner Admin → Sellers shows the share of replies answered by
RULES (no AI, cost 0) vs the AI, the money saved, and the vision cost per
image (Profit Guard)."""
from datetime import timedelta

from django.utils import timezone

from core.models import (BusinessProfile, ChatThread, Message, SellerAgent, SellerChannel, User)
from web.tests_o2_owner_admin import OwnerBase


class RulesStatsPanelTests(OwnerBase):
    def test_rules_vs_ai_and_vision_cost(self):
        u = User.objects.create_user(email="g1shop@example.invalid", name="G1", password="x")
        b = BusinessProfile.objects.create(user=u, shop_name="Kona Shop")
        SellerAgent.objects.create(business=b, plan="starter", ai_enabled=True,
                                   period_end=timezone.now() + timedelta(days=20))
        ch = SellerChannel.objects.create(business=b, kind="messenger", external_id="88",
                                          status="connected")
        t = ChatThread.objects.create(user=u, business=b, seller_channel=ch, channel="messenger",
                                      external_user_id="x1")
        for i in range(3):
            Message.objects.create(thread=t, direction="out", text="r", is_ai=True, status="sent",
                                   reply_source="rule", meta={"rule": "product"})
        Message.objects.create(thread=t, direction="out", text="a", is_ai=True, status="sent",
                               reply_source="ai", credits=6, cost_bdt=2.4,
                               meta={"image": True, "rule": "image_vision"})
        self.ready()
        r = self.c.get("/owner/sellers?lang=en")
        self.assertContains(r, "Rule-first answers vs AI")
        self.assertContains(r, "75.0%")                 # 3 rule / 4 automatic
        self.assertContains(r, "৳2.4")                  # cost per image
        r = self.c.get("/owner/sellers?lang=bn")
        self.assertContains(r, "নিয়মে উত্তর বনাম AI")
