"""amarket (owner master order 3 Nov, P3-E): Assisto Market v1.
Pure rules (ranking never hides the cheapest, transparent weights, plain
Bangla, Dhaka gate, banned goods), the flag, seller approval, SEALED bids,
group-buy, accept -> COD deals + seller Business orders + My Circle chat,
deal delivered/rate/cancel, report auto-hide, block, limits."""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import market as MK
from core.models import (BusinessProfile, CircleMember, FeatureFlag, MarketBid,
                         MarketDeal, MarketNeed, MarketSeller, ModerationItem,
                         Order, User)

_n = [0]


def _bd():
    _n[0] += 1
    return "0171%07d" % (7700000 + _n[0])


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=MK.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def api(u):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=u)[0].key)
    return c


def mk(name):
    return User.objects.create_user(name=name, phone=_bd(), password="x")


def bid(price, hours, rating=None, count=0, km=None, i=1, name=""):
    return {"id": i, "unit_price": price, "delivery_hours": hours,
            "rating_avg": rating, "rating_count": count, "km": km, "seller_name": name}


NEED = {"category": "grocery", "title": "মিনিকেট চাল", "description": "ভালো মানের",
        "quantity": 25, "unit": "kg", "area": "mirpur", "deadline_hours": 72,
        "budget_max": 2000}


# ======================================================================= pure
class RankingTests(TestCase):
    def test_cheapest_never_hidden_and_marked(self):
        out = MK.rank_bids([bid(9000, 2, 5.0, 20, 1.0, 1, "Fast"),
                            bid(6000, 72, 2.0, 3, 20.0, 2, "Cheap"),
                            bid(7000, 24, None, 0, None, 3, "New")], 10)
        ids = [b["id"] for b in out["bids"]]
        self.assertEqual(sorted(ids), [1, 2, 3])            # nothing dropped
        cheap = [b for b in out["bids"] if b["cheapest"]]
        self.assertEqual([b["id"] for b in cheap], [2])
        self.assertIn("সবচেয়ে কম দাম", cheap[0]["reasons"][0])
        self.assertEqual(sum(1 for b in out["bids"] if b["recommended"]), 1)
        self.assertEqual(out["weights"], {"price": 50, "delivery": 20, "rating": 20, "distance": 10})

    def test_summary_names_cheapest_when_not_recommended(self):
        out = MK.rank_bids([bid(10000, 1, 5.0, 50, 0.0, 1, "Fast"),
                            bid(9500, 240, 1.0, 5, 24.0, 2, "Cheap")], 2, lang="bn")
        top = out["bids"][0]
        self.assertEqual(top["id"], 1)
        self.assertFalse(top["cheapest"])
        self.assertIn("সবচেয়ে কম দাম: Cheap", out["summary"])
        self.assertIn("৳১০", out["summary"])                  # Bangla digits, total diff
        self.assertIn("দাম ৫০%", out["summary"])
        en = MK.rank_bids([bid(10000, 1, 5.0, 50, 0.0, 1, "Fast"),
                           bid(9500, 240, 1.0, 5, 24.0, 2, "Cheap")], 2, lang="en")
        self.assertIn("Lowest price: Cheap", en["summary"])

    def test_new_seller_neutral_and_explained(self):
        out = MK.rank_bids([bid(5000, 24, None, 0, None)], 1)
        b = out["bids"][0]
        self.assertEqual(b["parts"]["rating"], 10.0)          # 0.5 * 20
        self.assertTrue(any("নতুন বিক্রেতা" in r for r in b["reasons"]))
        self.assertTrue(b["recommended"] and b["cheapest"])

    def test_over_budget_flagged_not_hidden(self):
        out = MK.rank_bids([bid(5000, 24), bid(6000, 24, i=2)], 10, budget_max=50000)
        flags = {b["id"]: b["over_budget"] for b in out["bids"]}
        self.assertEqual(flags, {1: False, 2: True})
        allover = MK.rank_bids([bid(9000, 24)], 10, budget_max=100)
        self.assertIn("বাজেটের চেয়ে বেশি", allover["summary"])

    def test_empty(self):
        self.assertEqual(MK.rank_bids([], 3)["bids"], [])

    def test_distance_and_taka(self):
        self.assertEqual(MK.distance_km("mirpur", "mirpur"), 0.0)
        self.assertGreater(MK.distance_km("uttara", "jatrabari"), 15)
        self.assertIsNone(MK.distance_km("mirpur", "chittagong"))
        self.assertEqual(MK.taka(123456700, "en"), "৳1,234,567")
        self.assertEqual(MK.taka(150, "bn"), "৳১.৫০")


class CleanTests(TestCase):
    def test_need_rules(self):
        c, err = MK.clean_need(NEED)
        self.assertIsNone(err)
        self.assertEqual(c["budget_max"], 200000)              # taka -> poisha
        self.assertFalse(c["show_budget"])
        self.assertEqual(MK.clean_need({**NEED, "area": "chittagong"})[1], "dhaka_only")
        self.assertEqual(MK.clean_need({**NEED, "quantity": 0})[1], "bad_quantity")
        self.assertEqual(MK.clean_need({**NEED, "deadline_hours": 24 * 31})[1], "bad_deadline")
        self.assertEqual(MK.clean_need({**NEED, "budget_min": 5000})[1], "bad_budget")
        self.assertEqual(MK.clean_need({**NEED, "title": "ইয়াবা চাই"})[1], "banned_item")
        self.assertEqual(MK.clean_need({**NEED, "title": "need a pistol"})[1], "banned_item")
        self.assertIsNone(MK.clean_need({**NEED, "title": "begun 5 kg"})[1])   # eggplant

    def test_bid_rules(self):
        c, err = MK.clean_bid({"unit_price": 80, "delivery_hours": 24, "notes": "fresh"})
        self.assertEqual((c["unit_price"], err), (8000, None))
        self.assertEqual(MK.clean_bid({"unit_price": 0, "delivery_hours": 24})[1], "bad_price")
        self.assertEqual(MK.clean_bid({"unit_price": 10, "delivery_hours": 0})[1], "bad_delivery")


# ======================================================================= api
class MarketApiTests(TestCase):
    def setUp(self):
        flag(True)
        self.buyer = mk("Buyer")
        self.joiner = mk("Joiner")
        self.s1, self.s2 = mk("Seller1"), mk("Seller2")
        for s, shop in ((self.s1, "Rahim Store"), (self.s2, "Karim Traders")):
            BusinessProfile.objects.create(user=s, shop_name=shop)
            # bizai (owner 4 Nov): verified sellers are on the Business plan
            s.plan, s.plan_until = "business", timezone.now() + timedelta(days=60)
            s.save(update_fields=["plan", "plan_until"])

    def approve(self, u, area="mirpur", cats=("grocery",)):
        r = api(u).post("/api/v1/market/seller", {"area": area, "categories": list(cats)},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["seller"]["status"], "pending")
        s = MarketSeller.objects.get(user=u)
        MK.decide_seller(None, s.pk, "approved")

    def post_need(self, **kw):
        r = api(self.buyer).post("/api/v1/market/needs", {**NEED, **kw}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["need"]["id"]

    def test_flag_off_is_404(self):
        flag(False)
        r = api(self.buyer).get("/api/v1/market")
        self.assertEqual((r.status_code, r.json()["reason"]), (404, "off"))

    def test_overview(self):
        r = api(self.buyer).get("/api/v1/market", HTTP_ACCEPT_LANGUAGE="bn")
        d = r.json()
        self.assertEqual(r.status_code, 200)
        self.assertFalse(d["has_business"])
        self.assertIsNone(d["seller"])
        self.assertTrue(d["cod_only"])
        self.assertEqual(d["fee"], 0)
        self.assertIn({"key": "mirpur", "label": "মিরপুর"}, d["areas"])

    def test_seller_needs_business_and_approval(self):
        r = api(self.buyer).post("/api/v1/market/seller", {"area": "mirpur",
                                                          "categories": ["grocery"]}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "need_business"))
        api(self.s1).post("/api/v1/market/seller", {"area": "mirpur", "categories": ["grocery"]},
                          format="json")
        nid = self.post_need()
        r = api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                              {"unit_price": 80, "delivery_hours": 24}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "not_seller"))
        self.assertEqual(api(self.s1).get("/api/v1/market/sell").json()["needs"], [])

    def test_sealed_bids_ranking_and_accept(self):
        self.approve(self.s1)
        self.approve(self.s2, area="uttara")
        nid = self.post_need(group_open=True)
        # seller feed shows the need, without the buyer's name or budget
        feed = api(self.s1).get("/api/v1/market/sell").json()["needs"]
        self.assertEqual([n["id"] for n in feed], [nid])
        self.assertNotIn("budget_max", feed[0])
        self.assertNotIn("Buyer", str(feed[0]))
        # group-buy: a joiner adds 15 kg
        r = api(self.joiner).post("/api/v1/market/needs/%d/join" % nid, {"quantity": 15}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        # sealed bids
        api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 80, "delivery_hours": 24, "notes": "fresh"}, format="json")
        api(self.s2).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 75, "delivery_hours": 72}, format="json")
        d1 = api(self.s1).get("/api/v1/market/needs/%d" % nid).json()["need"]
        self.assertEqual(d1["my_bid"]["unit_price"], 8000)
        self.assertNotIn("ranking", d1)
        self.assertNotIn("Karim", str(d1))                    # never the rival
        self.assertNotIn("bid_count", d1)
        # buyer sees every bid ranked, total = unit price x (25 + 15)
        nd = api(self.buyer).get("/api/v1/market/needs/%d" % nid).json()["need"]
        self.assertEqual(nd["total_quantity"], 40)
        rk = nd["ranking"]
        self.assertEqual(len(rk["bids"]), 2)
        cheap = [b for b in rk["bids"] if b["cheapest"]][0]
        self.assertEqual((cheap["seller_name"], cheap["total"]), ("Karim Traders", 300000))
        self.assertTrue(rk["summary"])
        # the joiner sees the ranking too, but cannot accept
        jd = api(self.joiner).get("/api/v1/market/needs/%d" % nid).json()["need"]
        self.assertFalse(jd["can_accept"])
        r = api(self.joiner).post("/api/v1/market/needs/%d/accept" % nid,
                                  {"bid_id": cheap["id"]}, format="json")
        self.assertEqual(r.status_code, 404)
        # accept -> COD deals for buyer + joiner, orders for the seller, chat
        with self.captureOnCommitCallbacks(execute=True):
            r = api(self.buyer).post("/api/v1/market/needs/%d/accept" % nid,
                                     {"bid_id": cheap["id"]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        deals = MarketDeal.objects.filter(need_id=nid)
        self.assertEqual(sorted((d.buyer.name, d.quantity, d.total, d.payment, d.fee) for d in deals),
                         [("Buyer", 25, 187500, "cod", 0), ("Joiner", 15, 112500, "cod", 0)])
        orders = Order.objects.filter(user=self.s2, channel="market")
        self.assertEqual(orders.count(), 2)
        self.assertTrue(all(o.payment == "cod" and o.status == "new" for o in orders))
        self.assertEqual(MarketBid.objects.get(seller=self.s1, need_id=nid).status, "lost")
        self.assertTrue(CircleMember.objects.filter(user=self.buyer, peer_user=self.s2,
                                                    state="accepted").exists())
        self.assertTrue(CircleMember.objects.filter(user=self.s2, peer_user=self.joiner,
                                                    state="accepted").exists())
        # a second accept is refused
        r = api(self.buyer).post("/api/v1/market/needs/%d/accept" % nid,
                                 {"bid_id": cheap["id"]}, format="json")
        self.assertEqual(r.status_code, 409)
        # deal chat returns the My Circle member for the app
        deal = deals.get(buyer=self.buyer)
        r = api(self.buyer).post("/api/v1/market/deals/%d/chat" % deal.pk)
        self.assertEqual((r.status_code, r.json()["state"]), (200, "accepted"))
        # delivered -> rate once -> seller rating
        api(self.s2).post("/api/v1/market/deals/%d/act" % deal.pk, {"action": "delivered"}, format="json")
        r = api(self.buyer).post("/api/v1/market/deals/%d/act" % deal.pk,
                                 {"action": "rate", "rating": 4}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        s = MarketSeller.objects.get(user=self.s2)
        self.assertEqual((s.rating_sum, s.rating_count), (4, 1))
        r = api(self.buyer).post("/api/v1/market/deals/%d/act" % deal.pk,
                                 {"action": "rate", "rating": 5}, format="json")
        self.assertEqual(r.status_code, 409)
        # the joiner cancels theirs -> their seller order is cancelled
        jdeal = deals.get(buyer=self.joiner)
        api(self.joiner).post("/api/v1/market/deals/%d/act" % jdeal.pk, {"action": "cancel"}, format="json")
        jdeal.refresh_from_db()
        self.assertEqual((jdeal.status, jdeal.cancelled_by), ("cancelled", "buyer"))
        self.assertEqual(Order.objects.get(pk=jdeal.order_id).status, "cancelled")
        self.assertEqual(len(api(self.s2).get("/api/v1/market/deals").json()["deals"]), 2)

    def test_other_category_and_stranger_cannot_see(self):
        self.approve(self.s1, cats=("electronics",))
        nid = self.post_need()
        self.assertEqual(api(self.s1).get("/api/v1/market/sell").json()["needs"], [])
        self.assertEqual(api(self.s1).get("/api/v1/market/needs/%d" % nid).status_code, 404)
        r = api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                              {"unit_price": 10, "delivery_hours": 2}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(api(self.joiner).get("/api/v1/market/needs/%d" % nid).status_code, 404)

    def test_group_feed_and_join_rules(self):
        nid = self.post_need(group_open=True)
        closed = self.post_need()
        feed = api(self.joiner).get("/api/v1/market/group?area=pallabi").json()["needs"]
        self.assertEqual([n["id"] for n in feed], [nid])
        r = api(self.joiner).post("/api/v1/market/needs/%d/join" % closed, {"quantity": 2}, format="json")
        self.assertEqual(r.status_code, 409)
        r = api(self.buyer).post("/api/v1/market/needs/%d/join" % nid, {"quantity": 2}, format="json")
        self.assertEqual(r.json()["reason"], "own_need")
        api(self.joiner).post("/api/v1/market/needs/%d/join" % nid, {"quantity": 2}, format="json")
        api(self.joiner).post("/api/v1/market/needs/%d/leave" % nid)
        self.assertEqual(MarketNeed.objects.get(pk=nid).joins.count(), 0)

    def test_limits(self):
        for _ in range(MK.LIMITS["needs_per_day"]):
            self.post_need()
        r = api(self.buyer).post("/api/v1/market/needs", NEED, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (429, "rate_limited"))
        self.assertTrue(r.json()["detail"])

    def test_cancel_need_and_deadline_closes_bidding(self):
        self.approve(self.s1)
        nid = self.post_need()
        MarketNeed.objects.filter(pk=nid).update(deadline=timezone.now() - timedelta(hours=1))
        r = api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                              {"unit_price": 10, "delivery_hours": 2}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(api(self.buyer).post("/api/v1/market/needs/%d/cancel" % nid).status_code, 200)
        self.assertEqual(MarketNeed.objects.get(pk=nid).status, "cancelled")

    def test_report_auto_hides_after_three(self):
        self.approve(self.s1)
        nid = self.post_need()
        r = api(self.buyer).post("/api/v1/market/report", {"kind": "need", "id": nid,
                                                          "category": "spam"}, format="json")
        self.assertEqual(r.json()["reason"], "own_item")
        for u in (self.s1, self.joiner, mk("X")):
            r = api(u).post("/api/v1/market/report", {"kind": "need", "id": nid,
                                                     "category": "spam"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
        it = ModerationItem.objects.get(target_kind="mkt_need", target_id=str(nid))
        self.assertEqual((it.report_count, it.content_status), (3, "hidden"))
        self.assertEqual(MarketNeed.objects.get(pk=nid).content_status, "hidden")
        self.assertEqual(api(self.s1).get("/api/v1/market/sell").json()["needs"], [])
        # a bid can only be reported by someone who can see it
        r = api(self.joiner).post("/api/v1/market/report", {"kind": "bid", "id": 999},
                                  format="json")
        self.assertEqual(r.status_code, 404)

    def test_block_separates_buyer_and_seller(self):
        self.approve(self.s1)
        nid = self.post_need()
        api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 10, "delivery_hours": 2}, format="json")
        b = MarketBid.objects.get(seller=self.s1)
        r = api(self.buyer).post("/api/v1/market/block", {"kind": "bid", "id": b.pk}, format="json")
        self.assertEqual(r.status_code, 200)
        b.refresh_from_db()
        self.assertEqual(b.status, "lost")
        self.assertEqual(api(self.s1).get("/api/v1/market/sell").json()["needs"], [])
        self.post_need()
        self.assertEqual(api(self.s1).get("/api/v1/market/sell").json()["needs"], [])

    def test_suspend_withdraws_open_bids(self):
        self.approve(self.s1)
        nid = self.post_need()
        api(self.s1).post("/api/v1/market/needs/%d/bid" % nid,
                          {"unit_price": 10, "delivery_hours": 2}, format="json")
        MK.decide_seller(None, MarketSeller.objects.get(user=self.s1).pk, "suspended")
        self.assertEqual(MarketBid.objects.get(seller=self.s1).status, "withdrawn")
        nd = api(self.buyer).get("/api/v1/market/needs/%d" % nid).json()["need"]
        self.assertEqual(nd["ranking"]["bids"], [])

    def test_owner_preview_while_flag_off(self):
        flag(False)
        boss = User.objects.create_superuser(name="Boss", phone=_bd(), password="x")
        self.assertEqual(api(boss).get("/api/v1/market").status_code, 200)
