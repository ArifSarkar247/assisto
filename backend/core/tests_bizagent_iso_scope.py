"""bizagent-iso (owner order, widened scope): business A can NEVER see or
use business B's products, prices (incl. minimum prices), customers, chats,
FAQ, orders or reports — in any bizagent API endpoint, in the AI prompt, in
dedupe/cache keys or in search / FAQ retrieval. Plus (B) the owner's "AI
didn't know" list and (C) the off-topic decline. Made-up sample data only."""
import json
import os
import re
from decimal import Decimal
from unittest import mock

from django.test import SimpleTestCase

from core import bizagent_g1_service as G1S
from core import bizagent_service as S
from core.logic import bizagent as BZ
from core.logic import bizagent_rules as R
from core.models import (BizFaq, BizPostLink, BusinessProfile, ChatThread, Customer, Message,
                         Order, Product, SellerChannel, User)
from core.tests_p1_bizagent import Base, mpayload, setUpModule, tearDownModule  # noqa: F401

B_PRODUCT = "Jamdani Zxqv"
B_PRICE = "7777"
B_MIN = "6666"
B_FAQ = "BSECRETANSWER"
B_CUST = "Rahima Qwzx"
B_PHONE = "01999999990"
B_MSG = "BSECRETMSG"
MARKERS = (B_PRODUCT, B_PRICE, B_MIN, B_FAQ, B_CUST, B_PHONE, B_MSG)


class TwoShops(Base):
    def setUp(self):
        super().setUp()
        self.u2 = User.objects.create_user(email="shopb@example.invalid", password="x")
        self.b2 = BusinessProfile.objects.create(user=self.u2, shop_name="Shop B")
        self.p2b = Product.objects.create(user=self.u2, business=self.b2, name=B_PRODUCT,
                                          price=Decimal(B_PRICE), min_price=Decimal(B_MIN),
                                          stock=3)
        self.faq_b = BizFaq.objects.create(business=self.b2, question="gift wrap koren?",
                                           answer=B_FAQ, status="approved")
        self.unk_b = BizFaq.objects.create(business=self.b2, question="B unknown question",
                                           answer=B_FAQ, status=S.UNKNOWN_STATUS)
        self.ch_b = SellerChannel.objects.create(business=self.b2, kind="messenger",
                                                 external_id="8800000008", status="connected")
        self.t_b = ChatThread.objects.create(user=self.u2, business=self.b2,
                                             seller_channel=self.ch_b, external_user_id="psb",
                                             channel="messenger", customer_name=B_CUST,
                                             customer_phone=B_PHONE)
        Message.objects.create(thread=self.t_b, direction="in", text=B_MSG, status="received")
        self.m_b = Message.objects.create(thread=self.t_b, direction="out", text=B_MSG,
                                          status="pending_approval", risk_reason="low_confidence")
        self.o_b = Order.objects.create(user=self.u2, business=self.b2, thread=self.t_b,
                                        customer_name=B_CUST, customer_phone=B_PHONE,
                                        items=[{"product_id": self.p2b.id, "name": B_PRODUCT,
                                                "qty": 1, "price": B_PRICE}],
                                        total=Decimal(B_PRICE), status="new", via_agent=True)
        self.l_b = BizPostLink.objects.create(business=self.b2, post_id="post_b",
                                              product=self.p2b)
        Customer.objects.create(user=self.u2, business=self.b2, name=B_CUST, phone=B_PHONE,
                                phone_key=B_PHONE[-10:])
        self.c.force_authenticate(self.user)

    def assertClean(self, data, where):
        dump = json.dumps(data, ensure_ascii=False, default=str)
        for m in MARKERS:
            self.assertNotIn(m, dump, "%s leaked %s" % (where, m))


class EndpointIsolationTests(TwoShops):
    def test_every_id_endpoint_404s_for_a_foreign_id(self):
        V = "/api/v1/bizagent/"
        t, m, o, f, u, ln, ch = (self.t_b.pk, self.m_b.pk, self.o_b.pk, self.faq_b.pk,
                                 self.unk_b.pk, self.l_b.pk, self.ch_b.pk)
        gets = ["threads/%d" % t, "threads/%d/quick-replies" % t]
        posts = [("threads/%d/handover" % t, {"on": True}),
                 ("threads/%d/send" % t, {"text": "hi"}),
                 ("threads/%d/template" % t, {"name": "order_update"}),
                 ("threads/%d/mode" % t, {"mode": "human"}),
                 ("threads/%d/read" % t, {}),
                 ("approvals/%d/approve" % m, {}), ("approvals/%d/reject" % m, {}),
                 ("orders/%d/book" % o, {"courier": "pathao"}),
                 ("orders/%d/status" % o, {"status": "cancelled"}),
                 ("orders/%d/payment" % o, {"status": "paid"}),
                 ("orders/%d/confirm" % o, {}), ("orders/%d/cancel" % o, {}),
                 ("faqs/%d" % f, {"answer": "hijack"}), ("faqs/%d/delete" % f, {}),
                 ("unknown/%d/answer" % u, {"answer": "hijack"}),
                 ("unknown/%d/ignore" % u, {}),
                 ("post-links/%d/delete" % ln, {}),
                 ("channels/%d/toggle" % ch, {"enabled": False}),
                 ("channels/%d/delete" % ch, {})]
        for path in gets:
            r = self.c.get(V + path)
            self.assertEqual(r.status_code, 404, path)
            self.assertClean(r.data, path)
        for path, body in posts:
            r = self.c.post(V + path, body, format="json")
            self.assertEqual(r.status_code, 404, path)
            self.assertClean(r.data, path)
        # nothing of B's changed
        self.faq_b.refresh_from_db()
        self.unk_b.refresh_from_db()
        self.o_b.refresh_from_db()
        self.m_b.refresh_from_db()
        self.ch_b.refresh_from_db()
        self.t_b.refresh_from_db()
        self.assertEqual((self.faq_b.answer, self.unk_b.status), (B_FAQ, S.UNKNOWN_STATUS))
        self.assertEqual((self.o_b.status, self.m_b.status), ("new", "pending_approval"))
        self.assertTrue(self.ch_b.enabled)
        self.assertFalse(self.t_b.owner_takeover)
        self.assertTrue(BizPostLink.objects.filter(pk=ln).exists())
        self.assertEqual(Product.objects.get(pk=self.p2b.pk).stock, 3)

    def test_lists_and_reports_show_only_own_data(self):
        V = "/api/v1/bizagent/"
        for path in ("setup", "threads", "inbox", "inbox?q=" + B_CUST[:6],
                     "inbox?q=" + B_MSG, "approvals", "faqs", "unknown", "post-links",
                     "reports", "agent-report", "audit"):
            r = self.c.get(V + path)
            self.assertLess(r.status_code, 500, path)
            self.assertClean(r.data, path)
        for path in ("/api/v1/bizai/crm/segments", "/api/v1/bizai/daily"):
            r = self.c.get(path)
            self.assertLess(r.status_code, 500, path)
            self.assertClean(r.data, path)


class PromptIsolationTests(TwoShops):
    def test_prompt_for_a_has_none_of_b(self):
        a = S.agent_for(self.biz)
        for lang in ("bn", "en"):
            ctx = S.context_for(self.biz, a, lang)
            task = BZ.llm_task(ctx, lang, a.tone)
            self.assertClean({"task": task, "ctx": ctx}, "prompt " + lang)
            self.assertIn("Panjabi", task)          # A's own catalog IS there
            t_a = ChatThread.objects.get_or_create(
                user=self.user, business=self.biz, seller_channel=self.ch,
                external_user_id="psa", channel="messenger")[0]
            rctx = G1S.rules_ctx(self.biz, a, t_a, lang, S.catalog_for(self.biz))
            self.assertClean(rctx, "rules ctx " + lang)

    def test_llm_sees_only_a_even_when_customer_names_b(self):
        seen = {}

        def fake(ctx, lang, tone, text, history):
            seen["ctx"] = ctx
            return {"text": "Someone from the shop will reply.", "confidence": 0.9}
        with mock.patch.object(S, "_llm_draft", side_effect=fake):
            self.post_meta(mpayload("%s ache? %s" % (B_PRODUCT, B_FAQ), "iso.p1"))
        if "ctx" in seen:
            self.assertClean({"facts": seen["ctx"].get("facts"),
                              "catalog": seen["ctx"].get("catalog")}, "llm ctx")
        self.assertClean([m.text for m in self.outs()], "replies")


class RetrievalIsolationTests(TwoShops):
    def test_faq_retrieval_and_inbox_search_are_per_shop(self):
        # B's approved FAQ question, asked in A's chat: never B's answer
        self.post_meta(mpayload("gift wrap koren?", "iso.r1"))
        self.assertClean([m.text for m in self.outs()], "faq retrieval")
        self.assertEqual([f["a"] for f in G1S.faqs_for(self.biz) if f["a"] == B_FAQ], [])
        from core import bizagent_guard as GD
        rows, _ = GD.inbox(self.biz, q=B_MSG)
        self.assertEqual(rows, [])
        rows, _ = GD.inbox(self.biz, q=B_PHONE)
        self.assertEqual(rows, [])

    def test_scoped_product_helper(self):
        self.assertFalse(S.own_products(self.biz).filter(pk=self.p2b.pk).exists())
        self.assertTrue(S.own_products(self.b2).filter(pk=self.p2b.pk).exists())
        # a forged order item with B's product id can never move B's stock
        self.assertFalse(S._decrement_stock({"product_id": self.p2b.pk, "qty": 1}, self.biz))
        self.assertEqual(Product.objects.get(pk=self.p2b.pk).stock, 3)


class KeyScopeScanTests(SimpleTestCase):
    """Every dedupe / cache key built in the business-agent code carries the
    seller, channel, agent, thread or event id — never a bare global key."""
    FILES = ("bizagent_service.py", "bizagent_g1_service.py", "bizagent_guard.py",
             "bizagent_crm.py", "bizagent_media.py", "bizai_service.py", "bizai_crm.py",
             "bizai_daily.py", "bizai_prochar.py", "views_bizagent.py", "views_bizagent_g1.py",
             "views_bizagent_v2.py", "views_bizai.py")
    SCOPE = re.compile(r"\.pk|\.id\b|_id\b|\bpk\b|business|channel|agent|thread|wamid|"
                       r"event_id")

    def test_key_builders_are_scoped(self):
        here = os.path.dirname(os.path.abspath(S.__file__))
        found = 0
        for name in self.FILES:
            src = open(os.path.join(here, name), encoding="utf-8").read()
            self.assertNotRegex(src, r"\bcache\.(get|set|add|get_or_set|incr|delete)\(",
                                "%s uses the shared cache: scope its keys" % name)
            for m in re.finditer(r"_once_today\(([^\n]*)|message_id=([^\n]*)", src):
                expr = m.group(1) or m.group(2)
                if expr.startswith("key)") or "% (key, _day_start" in expr:
                    continue          # the generic wrapper: its callers are checked
                found += 1
                self.assertRegex(expr, self.SCOPE, "%s: unscoped key %r" % (name, expr))
        self.assertGreater(found, 2)


# ======================================================== (B) AI didn't know
class UnknownListTests(TwoShops):
    def test_unanswered_question_goes_to_owner_then_becomes_faq(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Maybe.", "confidence": 0.1}):
            self.post_meta(mpayload("Is the fabric suitable for sensitive skin?", "iso.u1"))
        r = self.c.get("/api/v1/bizagent/unknown")
        items = r.data["items"]
        self.assertEqual([i["question"] for i in items], ["Is the fabric suitable for sensitive skin?"])
        self.assertEqual(items[0]["suggested"], "Maybe.")
        self.assertTrue(items[0]["at"])
        self.assertClean(r.data, "unknown list")       # never B's open question
        # the FAQ list does not mix in open questions
        self.assertNotIn("fabric suitable", json.dumps(self.c.get("/api/v1/bizagent/faqs").data))
        r = self.c.post("/api/v1/bizagent/unknown/%d/answer" % items[0]["id"],
                        {"answer": "Yes, it is soft cotton and gentle on sensitive skin."}, format="json")
        self.assertEqual((r.status_code, r.data["faq"]["status"]), (200, "approved"))
        self.assertEqual(self.c.get("/api/v1/bizagent/unknown").data["items"], [])
        # next time the shop's own answer is used (rule, cost 0)
        self.post_meta(mpayload("Is the fabric suitable for sensitive skin?", "iso.u2"))
        self.assertIn("gentle on sensitive skin", self.outs()[-1].text)

    def test_ignore_and_validation(self):
        f = BizFaq.objects.create(business=self.biz, question="q one?", answer="",
                                  status=S.UNKNOWN_STATUS)
        r = self.c.post("/api/v1/bizagent/unknown/%d/answer" % f.pk, {"answer": ""},
                        format="json")
        self.assertEqual(r.status_code, 422)
        self.assertEqual(self.c.post("/api/v1/bizagent/unknown/%d/ignore" % f.pk).status_code,
                         200)
        f.refresh_from_db()
        self.assertEqual(f.status, "rejected")
        self.assertEqual(self.c.get("/api/v1/bizagent/unknown").data["items"], [])


# ======================================================== (C) off-topic
class OffTopicTests(SimpleTestCase):
    def test_prompt_limits_to_this_shop(self):
        t = BZ.llm_task({"shop_name": "Rupa", "facts": ""}, "en")
        self.assertIn("Answer ONLY about this shop", t)
        self.assertIn("politely say you can only help", t)

    def test_rule_declines_off_topic(self):
        cat = [{"id": 1, "name": "Panjabi", "price": "1200", "stock": 3}]
        for q, lang in (("can you write my homework essay?", "en"),
                        ("who will win the election?", "en"),
                        ("আজকের আবহাওয়া কেমন?", "bn")):
            r = R.answer(q, {"lang": lang, "catalog": cat, "shop_name": "Rupa"})
            self.assertEqual((r or {}).get("rule"), R.R_OFF_TOPIC, q)
        r = R.answer("write a poem for me", {"lang": "en", "catalog": cat, "shop_name": "Rupa"})
        self.assertIn("only help with Rupa", r["text"])

    def test_shop_selling_the_word_is_not_off_topic(self):
        cat = [{"id": 9, "name": "Essay Book", "price": "300", "stock": 4}]
        r = R.answer("do you have an essay book?", {"lang": "en", "catalog": cat})
        self.assertNotEqual((r or {}).get("rule"), R.R_OFF_TOPIC)


class OffTopicFlowTests(Base):
    def test_declined_even_with_rules_off_and_no_ai_call(self):
        self.agent.rules_enabled = False
        self.agent.save()
        with mock.patch.object(S, "_llm_draft") as llm:
            self.post_meta(mpayload("please do my math problem homework", "iso.o1"))
        llm.assert_not_called()
        self.assertIn("Rupa Fashion", self.outs()[-1].text)
