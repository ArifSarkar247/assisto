"""sales2 — live seller inbox payloads.

* GET threads/<id> carries ONE "handoff_card" = the newest UNRESOLVED handoff
  (pending approval; or rejected/held with no seller reply and no hand-back
  since), with message_id / pending / reason_label; resolved → None; an old
  row without a stored card gets it rebuilt (rule-made).
* GET threads/<id>/quick-replies: catalog price/stock cards (products the
  customer named first, then in-stock items), delivery + payment lines —
  every number from the catalog / the shop's settings, nothing sent.
No real AI / Meta call (FakeGraph transport from the p1 base)."""
import json
import re
from decimal import Decimal

from core import bizagent_guard as GD
from core.logic import bizagent as BZ
from core.logic import bizagent_handoff as HC
from core.models import BusinessProfile, ChatThread, Message, Product, SellerChannel, User
from core.tests_p1_bizagent import Base


class _S2(Base):
    def setUp(self):
        super().setUp()
        self.c.force_authenticate(self.user)
        self.t = ChatThread.objects.create(
            user=self.user, business=self.biz, seller_channel=self.ch, channel="messenger",
            external_user_id="psid-s2", customer_name="Karim", lang="en")

    def inbound(self, text):
        return Message.objects.create(thread=self.t, direction="in", text=text,
                                      status="received")

    def handoff(self, status="pending_approval", risk=BZ.RISK_COMPLAINT, with_card=True):
        meta = {}
        if with_card:
            meta["card"] = HC.build([{"direction": "in", "text": "Panjabi asheni keno?"}],
                                    [{"id": self.p.id, "name": "Panjabi", "price": "1200"}],
                                    {}, risk)
        return Message.objects.create(thread=self.t, direction="out", text="draft", is_ai=True,
                                      status=status, risk_reason=risk, needs_human=True,
                                      handoff_reason=risk, meta=meta)

    def detail(self):
        r = self.c.get("/api/v1/bizagent/threads/%d" % self.t.id)
        self.assertEqual(r.status_code, 200)
        json.dumps(r.data, ensure_ascii=False)          # plain JSON all the way down
        return r.data


class HandoffCardTests(_S2):
    def test_no_handoff_no_card(self):
        self.inbound("hi")
        self.assertIsNone(self.detail()["thread"]["handoff_card"])

    def test_pending_handoff_is_one_card_with_context(self):
        self.inbound("Panjabi asheni keno?")
        m = self.handoff()
        card = self.detail()["thread"]["handoff_card"]
        self.assertEqual(card["message_id"], m.id)
        self.assertTrue(card["pending"])
        self.assertEqual(card["reason"], BZ.RISK_COMPLAINT)
        self.assertEqual(len(card["lines"]["bn"]), 3)
        self.assertEqual(len(card["lines"]["en"]), 3)
        self.assertEqual(card["reason_label"]["en"], HC.REASON_LABEL[BZ.RISK_COMPLAINT][1])
        self.assertFalse(re.search(r"[0-9]", "\n".join(card["lines"]["bn"])))

    def test_newest_handoff_wins(self):
        self.handoff(status="rejected", risk=BZ.RISK_REFUND)
        m2 = self.handoff(risk=BZ.RISK_BIG_ORDER)
        self.assertEqual(self.detail()["thread"]["handoff_card"]["message_id"], m2.id)

    def test_rejected_handoff_stays_open_until_seller_replies(self):
        self.handoff(status="rejected")
        card = self.detail()["thread"]["handoff_card"]
        self.assertIsNotNone(card)
        self.assertFalse(card["pending"])
        Message.objects.create(thread=self.t, direction="out", text="Ami dekhchi", is_ai=False,
                               status="sent")
        self.assertIsNone(self.detail()["thread"]["handoff_card"])

    def test_approved_and_sent_is_resolved(self):
        self.handoff(status="sent")
        self.assertIsNone(self.detail()["thread"]["handoff_card"])

    def test_take_over_keeps_card_give_back_resolves_it(self):
        self.handoff(status="rejected")
        r = self.c.post("/api/v1/bizagent/threads/%d/mode" % self.t.id, {"mode": "human"},
                        format="json")
        self.assertEqual(r.status_code, 200)
        d = self.detail()["thread"]
        self.assertTrue(d["handover"])
        self.assertIsNotNone(d["handoff_card"])
        self.c.post("/api/v1/bizagent/threads/%d/mode" % self.t.id, {"mode": "ai"},
                    format="json")
        d = self.detail()["thread"]
        self.assertFalse(d["handover"])
        self.assertIsNone(d["handoff_card"])

    def test_pending_draft_stays_open_after_give_back(self):
        self.handoff()
        GD.hand_back(self.t)
        self.assertTrue(self.detail()["thread"]["handoff_card"]["pending"])

    def test_old_row_without_card_is_rebuilt(self):
        self.inbound("Panjabi 2 ta lagbe, dam koto?")
        self.handoff(risk=BZ.RISK_BIG_ORDER, with_card=False)
        card = self.detail()["thread"]["handoff_card"]
        self.assertEqual(card["reason"], BZ.RISK_BIG_ORDER)
        self.assertEqual(len(card["lines"]["en"]), 3)

    def test_unknown_reason_has_no_label_but_still_a_card(self):
        self.handoff(risk="something_new")
        card = self.detail()["thread"]["handoff_card"]
        self.assertIsNotNone(card)
        self.assertIsNone(card["reason_label"])


class QuickRepliesTests(_S2):
    URL = "/api/v1/bizagent/threads/%d/quick-replies"

    def setUp(self):
        super().setUp()
        self.p3 = Product.objects.create(user=self.user, business=self.biz, name="Pajama",
                                         price=Decimal("500"), min_price=Decimal("450"),
                                         stock=30)

    def get(self, **qp):
        r = self.c.get(self.URL % self.t.id, qp)
        self.assertEqual(r.status_code, 200)
        json.dumps(r.data, ensure_ascii=False)
        return r.data

    def test_named_product_first_then_in_stock_with_catalog_numbers(self):
        self.inbound("Panjabi ta ache? dam koto")
        n_out = Message.objects.filter(direction="out").count()
        d = self.get()
        self.assertEqual(d["lang"], "en")
        prods = [r for r in d["replies"] if r["kind"] == "product"]
        self.assertEqual(prods[0]["product_id"], self.p.id)
        self.assertTrue(prods[0]["mentioned"])
        self.assertEqual(prods[0]["price"], "1200")
        self.assertIn("৳1200", prods[0]["text"])
        self.assertIn(self.p3.id, [r["product_id"] for r in prods])
        # out of stock and never named → not offered
        self.assertNotIn(self.p2.id, [r["product_id"] for r in prods])
        dl = next(r for r in d["replies"] if r["kind"] == "delivery")
        self.assertIn("৳60", dl["text"])
        self.assertIn("৳120", dl["text"])
        self.assertTrue(any(r["kind"] == "payment" for r in d["replies"]))
        # every number in every text comes from the catalog / delivery settings
        allowed = {"1200", "500", "60", "120", "2500"}
        for r in d["replies"]:
            for num in re.findall(r"\d+", r["text"]):
                self.assertIn(num, allowed, r["text"])
        # nothing was sent
        self.assertEqual(Message.objects.filter(direction="out").count(), n_out)
        self.assertEqual(self.fake.texts(), [])

    def test_named_out_of_stock_product_is_honest(self):
        self.inbound("Saree ache?")
        prods = [r for r in self.get()["replies"] if r["kind"] == "product"]
        saree = next(r for r in prods if r["product_id"] == self.p2.id)
        self.assertFalse(saree["in_stock"])
        self.assertIn("out of stock", saree["text"])

    def test_lang_param_and_thread_language(self):
        bn = self.get(lang="bn")
        self.assertEqual(bn["lang"], "bn")
        self.assertIn("স্টকে আছে", next(r for r in bn["replies"] if r["kind"] == "product")["text"])
        ChatThread.objects.filter(pk=self.t.pk).update(lang="bn")
        self.assertEqual(self.get()["lang"], "bn")

    def test_no_price_no_card_and_no_delivery_settings_no_line(self):
        Product.objects.filter(user=self.user).update(stock=0)
        self.biz.policies.all().delete()
        d = self.get()
        self.assertEqual([r for r in d["replies"] if r["kind"] == "product"], [])
        self.assertFalse(any(r["kind"] == "delivery" for r in d["replies"]))

    def test_other_shops_chat_is_404(self):
        u2 = User.objects.create_user(email="other@example.invalid", name="O", password="x")
        b2 = BusinessProfile.objects.create(user=u2, shop_name="Other")
        ch2 = SellerChannel.objects.create(business=b2, kind="messenger", external_id="77",
                                           status="connected")
        t2 = ChatThread.objects.create(user=u2, business=b2, seller_channel=ch2,
                                       channel="messenger", external_user_id="x")
        self.assertEqual(self.c.get(self.URL % t2.id).status_code, 404)

    def test_needs_sign_in(self):
        self.c.force_authenticate(None)
        self.assertIn(self.c.get(self.URL % self.t.id).status_code, (401, 403))
