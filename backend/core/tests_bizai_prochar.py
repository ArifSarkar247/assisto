"""bizai pillar 5 — Prochar closes the loop: tracked post code → shop chat →
AI order carries the code → "this post brought N orders worth ৳X"; codes
typed in any chat count; unknown codes never; best time to post from real
inbound chats; weekly Bangla report (real numbers, idempotent per week)."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import bizagent_service as S
from core import bizai_prochar as BP
from core import mktengine_service as MS
from core.models import ChatThread, Message, Order, PaCollectionItem
from core.tests_bizai import API, ORDER_TEXT, ShopChatBase
from core.tests_p1_bizagent import mpayload


class ProcharTests(ShopChatBase):
    def setUp(self):
        super().setUp()
        MS._store_plan(self.user, self.biz, {"items": [
            {"id": "post1", "section": "content", "kind": "post", "title": "Post: Panjabi",
             "body": "Eid Panjabi — ৳1200", "product": "Panjabi", "status": "approved"},
            {"id": "post2", "section": "content", "kind": "post", "title": "Post: Saree",
             "body": "Saree", "product": "Saree"}]})
        self.ref = BP.post_ref(self.biz, "post1")

    def test_tracked_post_has_code_and_shop_link(self):
        self.c.force_authenticate(self.user)
        d = self.c.get(API + "bizai/prochar/tracked/post1").data
        self.assertEqual(d["ref"], self.ref)
        self.assertTrue(self.ref.startswith("P") and len(self.ref) == 5)
        self.assertIn("/shop/%s?p=%s" % (self.code, self.ref), d["link"])
        self.assertIn(self.ref, d["text"])
        self.assertIn("Eid Panjabi", d["text"])
        self.assertNotEqual(BP.post_ref(self.biz, "post2"), self.ref)
        self.assertEqual(self.c.get(API + "bizai/prochar/tracked/nope").status_code, 404)

    def test_post_link_to_order_to_attribution(self):
        self.cc.post(API + "shopchat/%s/send" % self.code,
                     {"text": "Panjabi order korbo 1 ta", "ref": self.ref}, format="json")
        self.send(ORDER_TEXT)
        self.send("হ্যাঁ")
        o = Order.objects.get()
        self.assertEqual(o.source_ref, self.ref)
        self.c.force_authenticate(self.user)
        d = self.c.get(API + "bizai/prochar").data
        best = d["attribution"]["best"]
        self.assertEqual((best["ref"], best["orders"], best["title"]),
                         (self.ref, 1, "Post: Panjabi"))
        self.assertEqual(float(best["bdt"]), float(o.total))
        self.assertEqual(d["attribution"]["suggestion"]["product"], "Panjabi")

    def test_code_typed_in_messenger_counts_and_unknown_never(self):
        self.post_meta(mpayload("ami %s dekhe esechi, dam koto?" % self.ref.lower(), "m1"))
        t = ChatThread.objects.get(seller_channel=self.ch)
        self.assertEqual(t.source_ref, self.ref)
        self.post_meta(mpayload("PZZZZ", "m2", psid="u2"))
        t2 = ChatThread.objects.get(seller_channel=self.ch, external_user_id="u2")
        self.assertEqual(t2.source_ref, "")
        # the first code wins (no re-attribution by a later code)
        self.assertEqual(BP.capture(t, BP.post_ref(self.biz, "post2")), "")

    def test_best_hours_needs_real_volume(self):
        self.assertEqual(BP.best_hours(self.biz), [])
        self.send("Panjabi dam koto?")
        t = self.app_thread()
        at = timezone.now().replace(hour=14, minute=0) - timedelta(days=1)
        for i in range(6):
            m = Message.objects.create(thread=t, direction="in", text="hi %d" % i)
            Message.objects.filter(pk=m.pk).update(created_at=at)
        hours = BP.best_hours(self.biz)
        self.assertTrue(hours)

    def test_weekly_report_real_numbers_and_once_per_week(self):
        self.cc.post(API + "shopchat/%s/send" % self.code,
                     {"text": "Panjabi order korbo 1 ta", "ref": self.ref}, format="json")
        self.send(ORDER_TEXT)
        self.send("হ্যাঁ")
        en = BP.weekly_report(self.biz, "en")
        self.assertIn("The AI took 1 orders", " ".join(en["lines"]))
        self.assertIn("Best post: Post: Panjabi", " ".join(en["lines"]))
        self.assertTrue(en["plan"])
        bn = BP.weekly_report(self.biz, "bn")
        self.assertIn("AI নিজে ১টি অর্ডার", " ".join(bn["lines"]))
        with mock.patch.object(S, "notify_seller") as ns:
            self.assertEqual(BP.run_weekly(), 1)
            self.assertEqual(BP.run_weekly(), 0)
        self.assertEqual(ns.call_count, 1)
        self.assertEqual(PaCollectionItem.objects.filter(collection=BP.COL_WEEKLY).count(), 1)

    def test_report_with_no_data_never_invents(self):
        bn = BP.weekly_report(self.biz, "bn")
        self.assertIn("বিক্রি: ০টি", bn["lines"][0])
        self.assertIsNone(bn["best_post"])
        self.assertEqual(len(bn["plan"]) >= 1, True)
