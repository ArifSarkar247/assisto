"""bizai — pillar 1 (AI sales agent in the in-app shop chat) + outcome card.

Scripted end-to-end: customer opens the shop link → sees the honest
disclosure (not E2E, visible to the shop and its AI) → asks a price → the
SAME agent pipeline answers from the catalog within 5 s with an "AI" label →
order → COD return-risk (high risk = no auto courier, owner told) → "Talk to
a person" → owner correction is learned → daily report "AI took N orders" →
outcome card in BDT from real rows only. Every owner rule here is a test."""
import re
import sys
import types
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.utils import timezone
from rest_framework.test import APIClient

from core import bizagent_g1_service as G1S
from core import bizagent_media as M
from core import bizagent_service as S
from core import bizai_service as BA
from core.logic import bizagent as BZ
from core.models import (BizFaq, BusinessProfile, ChatThread, CircleMember, Customer,
                         KhataEntry, KhataParty, Message, Order, RetentionAutomation,
                         RetentionSend, Sale, TagadaSend, User)
from core.tests_p1_bizagent import Base

API = "/api/v1/"
PHONE = "01712345678"
ORDER_TEXT = "Name: Karim Uddin\nPhone: %s\nAddress: House 5, Road 2, Mirpur, Dhaka" % PHONE
CATALOG_NUMBERS = {"1200", "1000", "2500", "2200", "60", "120"}


class ShopChatBase(Base):
    def setUp(self):
        super().setUp()
        self.no_llm = mock.patch.object(S, "_llm_draft", return_value=None)
        self.no_llm.start()
        self.addCleanup(self.no_llm.stop)
        self.pushes = []
        p = mock.patch("core.bizai_service.push_customer",
                       side_effect=lambda t, m: self.pushes.append(m.text) or 1)
        p.start()
        self.addCleanup(p.stop)
        self.cust = User.objects.create_user(email="buyer@example.invalid", name="Buyer",
                                             password="x")
        self.cc = APIClient()
        self.cc.force_authenticate(self.cust)
        self.code = BA.shop_code(self.biz)

    def send(self, text="", **kw):
        return self.cc.post(API + "shopchat/%s/send" % self.code, {"text": text, **kw},
                            format="json")

    def app_thread(self):
        return ChatThread.objects.get(channel="assisto", external_user_id="u%d" % self.cust.pk)


class DisclosureTests(ShopChatBase):
    def test_disclosure_before_first_message_bn_and_en(self):
        r = self.cc.get(API + "shopchat/%s" % self.code, HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["ok"])
        self.assertIn("not end-to-end encrypted", r.data["disclosure"])
        self.assertIn("visible to the shop and its AI assistant", r.data["disclosure"])
        self.assertFalse(r.data["disclosure_seen"])
        self.assertIn("এনক্রিপ্টেড নয়", BA.DISCLOSURE["bn"])
        self.assertIn("AI", BA.DISCLOSURE["bn"])
        self.send("Panjabi dam koto?")
        r = self.cc.get(API + "shopchat/%s" % self.code)
        self.assertTrue(r.data["disclosure_seen"])

    def test_ai_replies_carry_the_ai_label_and_own_messages_do_not(self):
        r = self.send("Panjabi dam koto?")
        rows = r.data["messages"]
        self.assertEqual(rows[0]["dir"], "in")
        self.assertFalse(rows[0]["ai"])
        outs = [m for m in rows if m["dir"] == "out"]
        self.assertTrue(outs and all(m["ai"] for m in outs))
        # a person's reply from the Business inbox is NOT labelled AI
        S.seller_send(self.app_thread(), "Ami Rupa, ki lagbe?")
        poll = self.cc.get(API + "shopchat/%s/messages" % self.code).data["messages"]
        human = [m for m in poll if m["text"] == "Ami Rupa, ki lagbe?"]
        self.assertEqual([m["ai"] for m in human], [False])

    def test_personal_circle_chats_are_untouched(self):
        # the shop chat is a separate ChatThread — no CircleMessage is ever made
        from core.models import CircleMessage
        self.send("Panjabi dam koto?")
        self.assertEqual(CircleMessage.objects.count(), 0)
        self.assertEqual(self.app_thread().seller_channel.kind, "assisto")


class SalesAgentTests(ShopChatBase):
    def test_price_from_catalog_within_five_seconds(self):
        r = self.send("Panjabi dam koto?")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["replied"])
        self.assertTrue(r.data["within_target"])
        self.assertLess(r.data["ms"], BA.REPLY_TARGET_MS)
        reply = [m for m in r.data["messages"] if m["dir"] == "out"][-1]["text"]
        self.assertIn("1200", BZ.norm_digits(reply))

    def test_bangla_script_question(self):
        r = self.send("পাঞ্জাবির দাম কত?")
        reply = " ".join(m["text"] for m in r.data["messages"] if m["dir"] == "out")
        self.assertTrue(re.search(r"[ঀ-৿]", reply))

    def test_never_invents_price_for_unknown_product(self):
        r = self.send("iPhone 15 er dam koto?")
        reply = BZ.norm_digits(" ".join(m["text"] for m in r.data["messages"]
                                        if m["dir"] == "out"))
        for n in re.findall(r"\d{2,}", reply):
            self.assertIn(n, CATALOG_NUMBERS | {"15"}, reply)

    def test_order_in_app_chat_becomes_a_real_order(self):
        self.send("Panjabi order korbo 1 ta")
        self.send(ORDER_TEXT)
        r = self.send("হ্যাঁ")
        o = Order.objects.get()
        self.assertEqual((o.via_agent, o.channel, o.payment, o.cod_risk),
                         (True, "assisto", "cod", "new"))
        self.p.refresh_from_db()
        self.assertEqual(self.p.stock, 9)
        texts = " ".join(m["text"] for m in r.data["messages"] if m["dir"] == "out")
        self.assertIn("#%d" % o.id, texts)
        self.assertTrue(self.pushes)                 # the customer's phone was told

    def test_shop_inbox_shows_the_chat_always_in_window(self):
        self.send("Panjabi dam koto?")
        self.c.force_authenticate(self.user)
        t = self.app_thread()
        d = self.c.get(API + "bizagent/threads/%d" % t.pk).data
        self.assertTrue(d["thread"]["in_window"] if "thread" in d else d["in_window"])

    def test_voice_note_via_shared_voice_path(self):
        fake = types.ModuleType("core.voice_transcribe")
        seen = {}

        def transcribe(user, data, lang="bn", call=None):
            seen["user"], seen["mime"] = user, data["mime"]
            return 200, {"ok": True, "text": "Panjabi dam koto", "credits": 1}
        fake.transcribe = transcribe
        with mock.patch.dict(sys.modules, {"core.voice_transcribe": fake}), \
                mock.patch.object(M, "stt_config", return_value={}):
            import core
            with mock.patch.object(core, "voice_transcribe", fake, create=True):
                up = SimpleUploadedFile("v.ogg", b"OggS" + b"\0" * 200, content_type="audio/ogg")
                r = self.cc.post(API + "shopchat/%s/send" % self.code,
                                 {"type": "audio", "file": up}, format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(seen["user"], self.user)            # the SHOP pays, not the buyer
        self.assertEqual(seen["mime"], "audio/ogg")
        inbound = Message.objects.filter(direction="in").get()
        self.assertEqual(inbound.text, "Panjabi dam koto")
        reply = [m for m in r.data["messages"] if m["dir"] == "out"][-1]["text"]
        self.assertIn("1200", BZ.norm_digits(reply))

    def test_voice_note_without_any_key_is_honest(self):
        with mock.patch.object(M, "stt_config", return_value={}), \
                mock.patch.dict(sys.modules, {"core.voice_transcribe": None}):
            up = SimpleUploadedFile("v.ogg", b"OggS" + b"\0" * 200, content_type="audio/ogg")
            r = self.cc.post(API + "shopchat/%s/send" % self.code,
                             {"type": "audio", "file": up}, format="multipart")
        reply = [m for m in r.data["messages"] if m["dir"] == "out"][-1]["text"]
        self.assertEqual(reply, G1S.voice_fallback_line("bn"))

    def test_photo_reaches_the_product_matcher_as_bytes(self):
        got = {}

        def fake(biz, agent, t, data, mime, text, lang):
            got["data"], got["mime"] = data, mime
            return {"text": "Panjabi — ৳1200", "kind": "text", "source": "rule"}
        with mock.patch.object(G1S, "compose_image", side_effect=fake):
            up = SimpleUploadedFile("p.jpg", b"\xff\xd8\xff" + b"1" * 100,
                                    content_type="image/jpeg")
            r = self.cc.post(API + "shopchat/%s/send" % self.code,
                             {"type": "image", "file": up}, format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(got["data"].startswith(b"\xff\xd8\xff"))
        self.assertEqual(got["mime"], "image/jpeg")


class GuardTests(ShopChatBase):
    def test_bad_code_own_shop_chat_off_flag_off_rate_limit(self):
        self.assertEqual(self.cc.get(API + "shopchat/1-deadbeef").status_code, 404)
        self.assertEqual(self.cc.get(API + "shopchat/%d-%s" % (
            self.biz.pk, "0" * 8)).status_code, 404)
        own = APIClient()
        own.force_authenticate(self.user)
        self.assertEqual(own.post(API + "shopchat/%s/send" % self.code, {"text": "hi"},
                                  format="json").status_code, 422)
        self.agent.app_chat_enabled = False
        self.agent.save()
        self.assertEqual(self.send("hi").status_code, 409)
        self.agent.app_chat_enabled = True
        self.agent.save()
        with mock.patch("core.feature_flags.is_on", return_value=False):
            self.assertEqual(self.cc.get(API + "shopchat/%s" % self.code).status_code, 404)
        codes = [self.send("hello %d" % i).status_code for i in range(BA.PER_MIN + 1)]
        self.assertEqual(codes[-1], 429)

    def test_talk_to_person_silences_ai_and_tells_the_shop(self):
        with mock.patch.object(S, "notify_seller") as ns:
            r = self.cc.post(API + "shopchat/%s/person" % self.code)
        self.assertTrue(r.data["with_person"])
        self.assertTrue(ns.called)
        t = self.app_thread()
        self.assertTrue(t.owner_takeover)
        before = t.messages.filter(direction="out").count()
        r = self.send("Panjabi dam koto?")
        self.assertFalse(r.data["replied"])
        self.assertEqual(r.data["messages"][-1]["dir"], "system")  # honest notice
        self.assertEqual(t.messages.filter(direction="out").count(), before)

    def test_ai_off_still_delivers_to_shop_with_honest_notice(self):
        self.agent.ai_enabled = False
        self.agent.save()
        r = self.send("Panjabi dam koto?")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)
        self.assertIn(r.data["messages"][-1]["dir"], ("system", "out"))

    def test_my_shops_lists_circle_contacts_shops(self):
        CircleMember.objects.create(user=self.cust, peer_user=self.user, state="accepted",
                                    name="Rupa")
        rows = self.cc.get(API + "shopchat/mine").data["shops"]
        self.assertEqual([(r["code"], r["circle"]) for r in rows], [(self.code, True)])
        self.send("Panjabi dam koto?")
        rows = self.cc.get(API + "shopchat/mine").data["shops"]
        self.assertEqual([(r["code"], r["circle"]) for r in rows], [(self.code, False)])


class CodRiskTests(ShopChatBase):
    def test_pure_levels(self):
        self.assertEqual(BA.risk_level(0, 0), BA.NEW)
        self.assertEqual(BA.risk_level(9, 0), BA.LOW)
        self.assertEqual(BA.risk_level(2, 1), BA.MEDIUM)
        self.assertEqual(BA.risk_level(1, 2), BA.HIGH)
        self.assertEqual(BA.risk_level(10, 2), BA.LOW)

    def test_high_risk_buyer_is_not_auto_shipped_and_owner_told(self):
        other = BusinessProfile.objects.create(
            user=User.objects.create_user(email="o2@example.invalid", name="O2", password="x"),
            shop_name="Other")
        for _ in range(2):
            Order.objects.create(user=other.user, business=other, customer_phone="+880" + PHONE[1:],
                                 status="returned", total=Decimal("900"))
        self.agent.auto_courier = True
        self.agent.default_courier = "steadfast"
        self.agent.save()
        with mock.patch.object(G1S, "auto_courier") as ac, \
                mock.patch.object(S, "notify_seller") as ns:
            self.send("Panjabi order korbo 1 ta")
            self.send(ORDER_TEXT)
            self.send("হ্যাঁ")
        o = Order.objects.get(business=self.biz)
        self.assertEqual(o.cod_risk, BA.HIGH)
        self.assertFalse(ac.called)
        risk_push = [c for c in ns.call_args_list if "COD" in str(c.args[2])]
        self.assertTrue(risk_push)
        self.assertNotIn("Other", str(risk_push))           # never another shop's name
        # the customer is never accused
        texts = " ".join(m.text for m in self.app_thread().messages.filter(direction="out"))
        self.assertNotIn("ফেরত", texts)
        self.assertNotIn("risk", texts.lower())

    def test_guard_off_ships_as_before(self):
        self.agent.cod_risk_guard = False
        self.agent.save()
        o = Order.objects.create(user=self.user, business=self.biz, customer_phone=PHONE,
                                 status="confirmed", total=Decimal("100"))
        for _ in range(2):
            Order.objects.create(user=self.user, business=self.biz, customer_phone=PHONE,
                                 status="returned", total=Decimal("100"))
        self.assertFalse(BA.check_order_risk(o, self.agent))
        self.assertEqual(o.cod_risk, BA.HIGH)


class LearningTests(ShopChatBase):
    def _pending(self, q, draft):
        self.send(q)
        t = self.app_thread()
        return Message.objects.create(thread=t, direction="out", text=draft, is_ai=True,
                                      status="pending_approval", meta={"source": "ai"})

    def test_owner_edit_becomes_an_approved_faq_used_next_time(self):
        m = self._pending("Apnara kokhon khola thaken?", "AI draft")
        S.approve(m, text="Shokal 10 ta theke rat 9 ta porjonto khola.")
        f = BizFaq.objects.get(business=self.biz)
        self.assertEqual((f.source, f.status), ("correction", "approved"))
        self.assertIn(f.id, [x["id"] for x in G1S.faqs_for(self.biz)])

    def test_a_price_in_the_correction_waits_for_the_owner(self):
        m = self._pending("Delivery charge koto?", "AI draft")
        S.approve(m, text="Dhakar moddhe ৳80")
        f = BizFaq.objects.get(business=self.biz)
        self.assertEqual((f.status, f.has_price), ("suggested", True))
        self.assertNotIn(f.id, [x["id"] for x in G1S.faqs_for(self.biz)])

    def test_unedited_approval_learns_nothing(self):
        m = self._pending("Apnara kokhon khola thaken?", "AI draft")
        S.approve(m)
        self.assertFalse(BizFaq.objects.exists())


class ReportAndOutcomeTests(ShopChatBase):
    def _ai_order(self, total, **kw):
        return Order.objects.create(user=self.user, business=self.biz, via_agent=True,
                                    status=kw.pop("status", "confirmed"), total=Decimal(total), **kw)

    def test_daily_report_headline_counts_only_ai_orders(self):
        self._ai_order("1260")
        Order.objects.create(user=self.user, business=self.biz, total=Decimal("999"))
        self._ai_order("500", status="cancelled")
        st = S.daily_stats(self.biz, timezone.localtime().date())
        self.assertEqual((st["ai_orders"], Decimal(st["ai_revenue"])), (1, Decimal("1260")))
        self.assertEqual(st["orders"], 3)
        self.assertIn("AI took 1 orders worth ৳1260", BZ.daily_report("en", st)["title"])
        self.assertIn("AI ১টি অর্ডার নিয়েছে — ৳১২৬০", BZ.daily_report("bn", st)["title"])

    def test_outcome_card_real_numbers_only(self):
        self.c.force_authenticate(self.user)
        empty = self.c.get(API + "bizai/outcomes").data
        self.assertTrue(empty["empty"])
        self.assertEqual(Decimal(empty["total_bdt"]), 0)
        self._ai_order("1200")
        self._ai_order("800", cod_risk="high", status="cancelled")
        cust = Customer.objects.create(user=self.user, business=self.biz, phone=PHONE,
                                       phone_key=PHONE)
        sale = Sale.objects.create(user=self.user, business=self.biz, customer=cust, total=150000)
        auto = RetentionAutomation.objects.create(business=self.biz, kind="winback")
        RetentionSend.objects.create(automation=auto, business=self.biz, audience_key=PHONE,
                                     ref_key="r1", purchase_sale=sale, purchase_poisha=150000)
        party = KhataParty.objects.create(business=self.biz, book="customer", name="Karim",
                                          phone=PHONE)
        TagadaSend.objects.create(business=self.biz, party=party, phone_key=PHONE,
                                  day=timezone.localtime().date(), channel="assisto",
                                  created_at=timezone.now() - timedelta(days=1))
        KhataEntry.objects.create(party=party, direction="got", amount_poisha=50000,
                                  at=timezone.now())
        # a payment with no reminder before it is NOT counted
        p2 = KhataParty.objects.create(business=self.biz, book="customer", name="Rahim")
        KhataEntry.objects.create(party=p2, direction="got", amount_poisha=99900,
                                  at=timezone.now())
        d = self.c.get(API + "bizai/outcomes").data
        rows = {r["key"]: (r["count"], Decimal(r["bdt"])) for r in d["rows"]}
        self.assertEqual(rows["ai_orders"], (1, Decimal("1200")))
        self.assertEqual(rows["customers_back"], (1, Decimal("1500")))
        self.assertEqual(rows["dues_collected"], (1, Decimal("500")))
        self.assertEqual(rows["losses_prevented"], (1, Decimal("800")))
        self.assertEqual(Decimal(d["total_bdt"]), Decimal("4000"))
        self.assertFalse(d["empty"])
        for r in d["rows"]:
            self.assertTrue(r["how_bn"] and r["how_en"])     # every number says how

    def test_outcomes_need_a_business_and_shop_link_owner_switches(self):
        self.assertIn(self.cc.get(API + "bizai/outcomes").status_code, (403, 404))
        self.c.force_authenticate(self.user)
        d = self.c.get(API + "bizai/shop-link").data
        self.assertEqual(d["code"], self.code)
        self.assertTrue(d["url"].endswith(self.code))
        d = self.c.post(API + "bizai/shop-link", {"cod_risk_guard": False}, format="json").data
        self.assertFalse(d["cod_risk_guard"])
        self.assertEqual(BA.business_for_code(d["url"]), self.biz)


class WebLandingTests(ShopChatBase):
    def test_shop_link_fallback_page_is_honest_and_reveals_only_the_name(self):
        r = self.client.get("/shop/%s" % self.code)
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertIn("Rupa Fashion", body)
        self.assertIn("not end-to-end encrypted", body)
        self.assertEqual(r["X-Robots-Tag"], "noindex, nofollow")
        self.assertNotIn(PHONE, body)
        self.assertEqual(self.client.get("/shop/1-bad").status_code, 404)
