"""bizai pillar 3 — Assisto Market: verified sellers (Business plan), owner
invite link approves at once, bulk tier unlocks when the group pool fills
(10,000 single → 7,000 bulk), negotiation asks sellers to meet the buyer's
limit (never above it), the seller's deal fee 1.5 % / 2 % (min / max), and an
unfilled pool expires with an honest "nothing was charged" (COD)."""
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone

from core import market as MK
from core.models import BusinessProfile, MarketBid, MarketDeal, MarketNeed, MarketSeller
from django.test import TestCase

from core.tests_amarket import NEED, MarketApiTests, api, mk


class PureTests(SimpleTestCase):
    def test_deal_fee_single_and_group_with_min_max(self):
        self.assertEqual(MK.deal_fee(100000), 1500)        # 1.5 % of ৳1,000 = ৳15
        self.assertEqual(MK.deal_fee(1000), 1500)          # min ৳15
        self.assertEqual(MK.deal_fee(10_000_000), 40000)   # max ৳400
        self.assertEqual(MK.deal_fee(1_000_000, group=True), 20000)   # 2 % capped ৳200
        self.assertEqual(MK.deal_fee(0), 0)

    def test_bulk_bid_validation(self):
        ok, err = MK.clean_bid({"unit_price": 10000, "delivery_hours": 24,
                                "bulk_unit_price": 7000, "bulk_min_qty": 10})
        self.assertIsNone(err)
        self.assertEqual((ok["bulk_price"], ok["bulk_min_qty"]), (700000, 10))
        for bad in ({"bulk_unit_price": 12000, "bulk_min_qty": 10},
                    {"bulk_unit_price": 7000, "bulk_min_qty": 1},
                    {"bulk_unit_price": 7000}):
            self.assertEqual(MK.clean_bid({"unit_price": 10000, "delivery_hours": 24, **bad})[1],
                             "bad_bulk")

    def test_invite_codes(self):
        c = MK.invite_code(3)
        self.assertTrue(MK.invite_valid(c))
        self.assertTrue(MK.invite_valid(MK.invite_link(3)))
        self.assertFalse(MK.invite_valid("S3-00000000"))
        self.assertFalse(MK.invite_valid("hello"))


class MarketBizaiTests(TestCase):
    # the Market API fixtures (sellers on the Business plan) without re-running
    # every inherited Market test
    setUp = MarketApiTests.setUp
    approve = MarketApiTests.approve
    post_need = MarketApiTests.post_need

    def test_seller_needs_business_plan_unless_staff(self):
        u = mk("NoPlan")
        BusinessProfile.objects.create(user=u, shop_name="X")
        r = api(u).post("/api/v1/market/seller", {"area": "mirpur", "categories": ["grocery"]},
                        format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (402, "need_business_plan"))

    def test_invite_link_approves_on_apply(self):
        r = api(self.s1).post("/api/v1/market/seller",
                              {"area": "mirpur", "categories": ["grocery"],
                               "invite": MK.invite_link(7)}, format="json")
        self.assertEqual(r.json()["seller"]["status"], "approved")
        r = api(self.s2).post("/api/v1/market/seller",
                              {"area": "mirpur", "categories": ["grocery"],
                               "invite": "S7-deadbeef"}, format="json")
        self.assertEqual(r.json()["seller"]["status"], "pending")
        staff = mk("Staff")
        staff.is_staff = True
        staff.save()
        self.assertEqual(api(self.buyer).post("/api/v1/market/invites", {"n": 1},
                                              format="json").status_code, 404)
        r = api(staff).post("/api/v1/market/invites", {"n": 1}, format="json")
        self.assertTrue(MK.invite_valid(r.json()["code"]))

    def test_bulk_tier_unlocks_when_pool_fills_and_fee_recorded(self):
        self.approve(self.s1)
        nid = self.post_need(quantity=4, group_open=True, budget_max=None)
        r = api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                              {"unit_price": 10000, "delivery_hours": 24,
                               "bulk_unit_price": 7000, "bulk_min_qty": 10}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        bid_id = r.json()["bid"]["id"]
        need = MarketNeed.objects.get(pk=nid)
        b = MarketBid.objects.get(pk=bid_id)
        self.assertFalse(MK.pool_state(need, b)["unlocked"])
        self.assertEqual(MK.pool_state(need, b)["needed"], 6)
        r = api(self.joiner).post("/api/v1/market/needs/%d/join" % nid, {"quantity": 6},
                                  format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(MK.pool_state(need, b)["unlocked"])
        r = api(self.buyer).post("/api/v1/market/needs/%d/accept" % nid, {"bid_id": bid_id},
                                 format="json")
        self.assertEqual(r.status_code, 200, r.content)
        deals = {d.buyer_id: d for d in MarketDeal.objects.filter(need_id=nid)}
        self.assertEqual(deals[self.buyer.pk].unit_price, 700000)     # bulk price for all
        self.assertEqual(deals[self.joiner.pk].total, 700000 * 6)
        self.assertEqual(deals[self.buyer.pk].fee, MK.deal_fee(700000 * 4, group=True))
        self.assertEqual(deals[self.buyer.pk].order.total, Decimal("28000"))

    def test_negotiation_asks_within_the_buyer_limit_only(self):
        self.approve(self.s1)
        self.approve(self.s2)
        nid = self.post_need(quantity=25, budget_max=2000)        # ৳80 / kg limit
        api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 95, "delivery_hours": 24}, format="json")
        api(self.s2).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 78, "delivery_hours": 24}, format="json")
        with mock.patch.object(MK, "_push_counter"):
            r = api(self.buyer).post("/api/v1/market/needs/%d/negotiate" % nid, format="json")
        self.assertEqual(r.json()["asked"], 1)                       # only the one above
        b1 = MarketBid.objects.get(need_id=nid, seller=self.s1)
        self.assertEqual(b1.counter_price, 8000)                    # ৳80, never above
        self.assertIsNone(MarketBid.objects.get(need_id=nid, seller=self.s2).counter_price)
        r = api(self.buyer).post("/api/v1/market/needs/%d/negotiate" % nid, format="json")
        self.assertEqual(r.json()["asked"], 0)                       # once per offer
        r = api(self.s1).post("/api/v1/market/needs/%d/counter" % nid, format="json")
        self.assertEqual(r.json()["bid"]["unit_price"], 8000)
        self.assertEqual(api(self.joiner).post("/api/v1/market/needs/%d/negotiate" % nid,
                                               format="json").status_code, 404)

    def test_negotiation_needs_a_budget(self):
        nid = self.post_need(budget_max=None)
        r = api(self.buyer).post("/api/v1/market/needs/%d/negotiate" % nid, format="json")
        self.assertEqual(r.json()["reason"], "need_budget")

    def test_unfilled_pool_expires_and_tells_joiners_nothing_charged(self):
        nid = self.post_need(group_open=True)
        api(self.joiner).post("/api/v1/market/needs/%d/join" % nid, {"quantity": 2},
                              format="json")
        MarketNeed.objects.filter(pk=nid).update(deadline=timezone.now() - timedelta(days=5))
        with mock.patch("core.push.push_to_user") as p:
            self.assertEqual(MK.pool_sweep(), 1)
            self.assertEqual(MK.pool_sweep(), 0)
        self.assertEqual(MarketNeed.objects.get(pk=nid).status, "expired")
        self.assertEqual(p.call_count, 2)                            # buyer + joiner
        self.assertIn("no money was taken", p.call_args_list[0].args[5])
        self.assertFalse(MarketDeal.objects.exists())
