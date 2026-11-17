"""bizagent-guard (sales-brain audit slice 2): the AI sales agent never
invents non-numeric claims (colour / size / delivery time / guarantee / free
delivery), stays on this shop's topics, cannot be bargain-probed down to the
minimum price, and never shows an unset delivery charge as ৳0 or "free"."""
from decimal import Decimal
from unittest import mock

from django.test import SimpleTestCase

from core import bizagent_service as S
from core.logic import bizagent as BZ
from core.logic import bizagent_rules as R
from core.logic import business_ai as bai
from core.models import Message, OwnerPolicy
from core.tests_p1_bizagent import Base, mpayload, setUpModule, tearDownModule  # noqa: F401

CTX = {
    "catalog": [{"id": 1, "name": "Panjabi", "price": "1200", "stock": 7,
                 "description": "cotton", "variants": [
                     {"vkey": "m-white", "size": "M", "colour": "White", "stock": 3,
                      "price": "1200"},
                     {"vkey": "l-black", "size": "L", "colour": "Black", "stock": 0,
                      "price": "1200"}]}],
    "policies": {"delivery_time": "ঢাকায় ২-৩ দিনে ডেলিভারি"},
    "delivery": {"inside_dhaka": "60", "outside_dhaka": "120", "free_over": ""},
    "facts": "",
}


def types(problems):
    return sorted({p["type"] for p in problems})


# ============================================================== (a) claims
class ClaimCheckTests(SimpleTestCase):
    def test_invented_colour_is_caught(self):
        self.assertEqual(types(BZ.check_claims("Yes, red is in stock!", CTX)), ["colour_claim"])
        self.assertEqual(types(BZ.check_claims("জি, লাল রঙে আছে", CTX)), ["colour_claim"])
        self.assertEqual(BZ.check_claims("White is available in M.", CTX), [])

    def test_out_of_stock_colour_said_available(self):
        self.assertEqual(types(BZ.check_claims("Black is available", CTX)), ["stock_claim"])
        self.assertEqual(BZ.check_claims("Sorry, black is out of stock.", CTX), [])

    def test_size_must_exist(self):
        self.assertEqual(types(BZ.check_claims("XL is available", CTX)), ["size_claim"])

    def test_delivery_time_only_from_shop_data(self):
        self.assertEqual(types(BZ.check_claims("It delivers in 2 days.", CTX)),
                         ["delivery_time_claim"])
        self.assertEqual(types(BZ.check_claims("Delivery tomorrow!", CTX)),
                         ["delivery_time_claim"])
        self.assertEqual(BZ.check_claims("ঢাকায় ২-৩ দিনে পাবেন।", CTX), [])
        self.assertEqual(BZ.check_claims("Inside Dhaka it takes 2-3 days.", CTX), [])

    def test_guarantee_and_free_delivery(self):
        self.assertEqual(types(BZ.check_claims("It has a 1 year warranty.", CTX)),
                         ["guarantee_claim"])
        self.assertEqual(types(BZ.check_claims("ফ্রি ডেলিভারি পাবেন!", CTX)),
                         ["free_delivery_claim"])
        ctx = dict(CTX, delivery={"inside_dhaka": "60", "free_over": "3000"})
        self.assertEqual(BZ.check_claims("Free delivery on orders over 3000.", ctx), [])

    def test_plain_reply_passes(self):
        self.assertEqual(BZ.check_claims("Panjabi is ৳1200. Shall I place the order?", CTX), [])


class ClaimIntegrationTests(Base):
    def test_invented_claim_is_held_and_customer_gets_honest_line(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Yes! Red one is in stock and we deliver "
                                                     "in 2 days.", "confidence": 0.95}):
            self.post_meta(mpayload("apnara gift wrap koren?", "g.c1"))
        sent = " ".join(m.text for m in self.outs() if m.status != "pending_approval")
        self.assertNotIn("Red", sent)
        self.assertNotIn("2 days", sent)
        pend = Message.objects.get(status="pending_approval")
        self.assertIn("Red", pend.text)


# (b) off-topic scope: moved to the P0 branch (tests_bizagent_iso_scope.OffTopicTests)
class ClaimPromptTests(SimpleTestCase):
    def test_prompt_forbids_invented_claims(self):
        t = BZ.llm_task({"shop_name": "Rupa", "facts": ""}, "en")
        self.assertIn("NEVER claim a colour", t)
        self.assertIn("never say delivery is free or ৳0", t)


# ============================================================== (c) bargaining
class BargainGuardPureTests(SimpleTestCase):
    def test_margin_and_cap(self):
        self.assertEqual(BZ.bargain_margin(1200, 1000), Decimal(50))
        self.assertEqual(BZ.bargain_margin(500, 450), Decimal(20))
        self.assertEqual(BZ.bargain_margin(500, 500), Decimal(0))
        st = None
        floors = []
        for offer in (800, 900, 1000, 1100):
            f, st = BZ.bargain_guard(st, offer, 1200, 1000)
            floors.append(f)
        self.assertEqual(floors, [Decimal(1000), Decimal(1050), Decimal(1050), None])
        # an offer at/above list is never counted
        f, st2 = BZ.bargain_guard({"n": 3}, 1200, 1200, 1000)
        self.assertEqual((f, st2), (Decimal(1000), {"n": 3}))


class BargainProbeTests(Base):
    def test_stepping_up_cannot_find_the_minimum(self):
        self.post_meta(mpayload("Panjabi 800 te diben? discount", "g.b1"))
        self.post_meta(mpayload("Panjabi 1000 te diben? discount", "g.b2"))
        # the real minimum (1000) is NOT accepted on a stepped-up offer
        self.assertNotIn("agreed", self.thread().order_draft)
        self.assertEqual(Message.objects.filter(status="pending_approval",
                                                risk_reason=BZ.RISK_BELOW_MIN).count(), 2)
        self.post_meta(mpayload("Panjabi 1050 te diben? discount", "g.b3"))
        self.assertEqual(self.thread().order_draft["agreed"]["price"], "1050")
        # 4th offer: the owner decides, even above the floor
        self.post_meta(mpayload("Panjabi 1100 te diben? discount", "g.b4"))
        self.assertEqual(self.thread().order_draft["agreed"]["price"], "1050")
        self.assertEqual(Message.objects.filter(status="pending_approval",
                                                risk_reason=BZ.RISK_BELOW_MIN).count(), 3)
        sent = " ".join(m.text for m in self.outs() if m.status != "pending_approval")
        self.assertNotIn("1000", sent)

    def test_first_offer_at_minimum_still_accepted(self):
        self.post_meta(mpayload("Panjabi 1000 te diben? discount", "g.b9"))
        self.assertEqual(self.thread().order_draft["agreed"]["price"], "1000")


# ============================================================== (d) delivery unset
class DeliveryUnsetPureTests(SimpleTestCase):
    UNSET = {"inside_dhaka": "", "outside_dhaka": "", "free_over": ""}

    def test_rule_lines_never_say_zero_or_free(self):
        for lang in ("bn", "en"):
            for line in (R.delivery_line(lang, self.UNSET),
                         R.area_delivery_line(lang, self.UNSET, "inside", "Mirpur"),
                         R.delivery_line(lang, {"inside_dhaka": "0", "outside_dhaka": "0"})):
                self.assertNotIn("৳0", line)
                self.assertNotIn("free", line.lower())
                self.assertNotIn("ফ্রি", line)
                self.assertTrue(line)
        self.assertIn("the shop will confirm", R.delivery_line("en", self.UNSET).lower())
        half = R.delivery_line("en", {"inside_dhaka": "60", "outside_dhaka": ""})
        self.assertIn("৳60", half)
        self.assertIn("the shop will confirm", half)

    def test_facts_never_show_zero(self):
        ctx = bai.build_context(catalog=[], delivery={"inside_dhaka": "0", "outside_dhaka": "0"},
                                lang="en")
        self.assertNotIn("৳0", ctx["facts"])
        self.assertIn("the shop will confirm", ctx["facts"])

    def test_order_summary_and_invoice(self):
        cat = [{"id": 1, "name": "Panjabi", "price": "1200", "stock": 5}]
        draft = {"product_id": 1, "qty": 1, "area": "inside", "name": "Karim",
                 "phone": "01700000000", "address": "Mirpur"}
        priced = BZ.price_order(draft, cat, self.UNSET)
        self.assertTrue(priced["delivery_unset"])
        summ = BZ.order_summary("en", draft, priced)
        self.assertNotIn("৳0", summ)
        self.assertIn("the shop will confirm the delivery charge", summ)
        inv = BZ.invoice_text("en", {"id": 5, "items": [{"name": "Panjabi", "qty": 1,
                                                         "price": "1200"}],
                                     "delivery_charge": 0, "total": 1200,
                                     "delivery_unset": True})
        self.assertNotIn("Delivery: ৳0", inv)
        # set charge / free-over reached → a real number, no "confirm" line
        self.assertFalse(BZ.price_order(draft, cat, {"inside_dhaka": "60"})["delivery_unset"])
        self.assertFalse(BZ.price_order(draft, cat, {"free_over": "1000"})["delivery_unset"])


class DeliveryUnsetIntegrationTests(Base):
    def test_zero_policy_is_unset_end_to_end(self):
        OwnerPolicy.objects.filter(business=self.biz).update(delivery_inside=Decimal(0),
                                                             delivery_outside=Decimal(0))
        self.assertEqual(S.delivery_for(self.biz),
                         {"inside_dhaka": "", "outside_dhaka": "", "free_over": ""})
        self.post_meta(mpayload("delivery charge koto?", "g.d1"))
        txt = self.outs()[-1].text
        self.assertNotIn("৳0", txt)
        self.assertNotIn("ফ্রি", txt)
        self.assertIn("নিশ্চিত", txt)
