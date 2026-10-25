"""Business AI Agent v2 — "own Page + own number first" (owner order 25 Oct).

Webhook verify + bad signature (Messenger + WhatsApp) · duplicate message id
ignored · auto-reply only from business facts (mock AI; an invented price is
held, "I'll ask the owner" when unsure) · owner takeover stops the agent ·
hand-back + idle timeout resume · 24 h window (WhatsApp template / Messenger
blocked) · image → DRAFT order (match / no match, mock vision) and owner
confirm/cancel · per-business daily AI cap · per-chat cap + burst · Business
inbox filters (status, unread, search, channel) · features hidden with no
channel / no Meta app · audit log."""
import json
from datetime import timedelta
from unittest import mock

from django.test import override_settings
from django.utils import timezone

from core import ai
from core import bizagent_guard as GD
from core import bizagent_media as M
from core import bizagent_service as S
from core import vision_providers as VP
from core.logic import bizagent as BZ
from core.models import BizAuditLog, ChatThread, Message, Order, SellerChannel
from core.tests_g1_bizagent import G1Base, TPAGE, _png, data_url, mimage, _MEDIA
from core.tests_p1_bizagent import mpayload, wapayload

LLM_Q = "Panjabi ta ki cotton?"


def llm(text, conf=0.9):
    return mock.patch.object(S, "_llm_draft", return_value={"text": text, "confidence": conf})


class WebhookV2Tests(G1Base):
    def test_verify_and_bad_signature_both_sources(self):
        for path in ("/api/v1/bizagent/webhook/meta", "/api/v1/bizagent/webhook/whatsapp"):
            r = self.c.get(path, {"hub.mode": "subscribe", "hub.verify_token": "vtok",
                                  "hub.challenge": "777"})
            self.assertEqual((r.status_code, r.content), (200, b"777"))
            r = self.c.get(path, {"hub.mode": "subscribe", "hub.verify_token": "x",
                                  "hub.challenge": "777"})
            self.assertEqual(r.status_code, 403)
        self.assertEqual(self.post_wa(wapayload("hi", "wamid.bad"), secret="nope").status_code,
                         403)
        raw = json.dumps(mpayload("hi", "m.nosig")).encode()
        r = self.c.post("/api/v1/bizagent/webhook/meta", data=raw,
                        content_type="application/json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(Message.objects.count(), 0)

    def test_duplicate_message_ignored(self):
        self.post_meta(mpayload("hello", "m.dup"))
        self.post_meta(mpayload("hello", "m.dup"))
        self.post_wa(wapayload("hello", "wamid.dup"))
        self.post_wa(wapayload("hello", "wamid.dup"))
        self.assertEqual(Message.objects.filter(direction="in").count(), 2)


class FactsOnlyTests(G1Base):
    def test_invented_price_never_sent(self):
        with llm("Panjabi is only 750 taka today"):
            self.post_meta(mpayload(LLM_Q, "m.f1"))
        self.assertNotIn("750", "".join(self.fake.texts()))
        self.assertTrue(Message.objects.filter(status="pending_approval").exists())

    def test_true_facts_go_out(self):
        with llm("Yes, Panjabi is cotton. Price ৳1200."):
            self.post_meta(mpayload(LLM_Q, "m.f2"))
        self.assertIn("1200", "".join(self.fake.texts()))

    def test_unsure_asks_owner(self):
        with llm("hmm maybe", conf=0.1):
            self.post_meta(mpayload(LLM_Q, "m.f3"))
        out = self.outs()[0]
        self.assertEqual(out.kind, "holding")
        self.assertTrue(Message.objects.filter(status="pending_approval").exists())


class TakeoverTests(G1Base):
    def test_takeover_stops_agent_and_handback_resumes(self):
        self.post_meta(mpayload("hello", "m.t0"))
        t = self.thread()
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/threads/%d/mode" % t.id, {"mode": "human"},
                        format="json")
        self.assertEqual(r.status_code, 200)
        n = len(self.outs())
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.t1"))
        self.assertEqual(len(self.outs()), n)                    # agent silent
        self.assertTrue(BizAuditLog.objects.filter(action="takeover", thread=t).exists())
        self.c.post("/api/v1/bizagent/threads/%d/handover" % t.id, {"on": False}, format="json")
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.t2"))
        self.assertGreater(len(self.outs()), n)                  # agent back
        self.assertTrue(BizAuditLog.objects.filter(action="handback", thread=t).exists())

    def test_idle_timeout_hands_back(self):
        self.agent.takeover_idle_minutes = 30
        self.agent.save()
        self.post_meta(mpayload("hello", "m.i0"))
        t = self.thread()
        GD.take_over(t)
        ChatThread.objects.filter(pk=t.pk).update(
            takeover_at=timezone.now() - timedelta(minutes=31))
        n = len(self.outs())
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.i1"))
        t.refresh_from_db()
        self.assertFalse(t.owner_takeover)
        self.assertGreater(len(self.outs()), n)
        self.assertTrue(BizAuditLog.objects.filter(action="handback_idle").exists())

    def test_idle_zero_waits_and_owner_reply_restarts_clock(self):
        self.post_meta(mpayload("hello", "m.z0"))
        t = self.thread()
        GD.take_over(t)
        old = timezone.now() - timedelta(hours=5)
        ChatThread.objects.filter(pk=t.pk).update(takeover_at=old)
        t.refresh_from_db()
        S.seller_send(t, "Ami dekhchi")
        t.refresh_from_db()
        self.assertGreater(t.takeover_at, old)                   # owner activity
        self.agent.takeover_idle_minutes = 0
        self.agent.save()
        ChatThread.objects.filter(pk=t.pk).update(takeover_at=old)
        t.refresh_from_db()
        self.assertFalse(GD.idle_expired(self.agent, t))

    def test_sweep_answers_waiting_customer(self):
        self.agent.takeover_idle_minutes = 10
        self.agent.save()
        self.post_meta(mpayload("hello", "m.s0"))
        t = self.thread()
        GD.take_over(t)
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.s1"))
        n = len(self.outs())
        ChatThread.objects.filter(pk=t.pk).update(
            takeover_at=timezone.now() - timedelta(minutes=11))
        with llm("Panjabi ৳1200"):
            self.assertEqual(GD.sweep_idle_takeovers(), 1)
        self.assertGreater(len(self.outs()), n)


class WindowTests(G1Base):
    def test_whatsapp_outside_24h_needs_template(self):
        self.post_wa(wapayload("hello", "wamid.w0"))
        t = self.thread(self.wa)
        ChatThread.objects.filter(pk=t.pk).update(
            last_inbound_at=timezone.now() - timedelta(hours=25))
        t.refresh_from_db()
        m = S.seller_send(t, "Hi again")
        self.assertEqual((m.status, m.send_error),
                         ("blocked", "outside_24h_window_template_required"))
        m = S.send_template(t, "order_update", "bn", ["1"])
        self.assertEqual(m.status, "sent")

    def test_messenger_outside_window_blocked(self):
        self.post_meta(mpayload("hello", "m.w1"))
        t = self.thread()
        ChatThread.objects.filter(pk=t.pk).update(
            last_inbound_at=timezone.now() - timedelta(hours=25))
        t.refresh_from_db()
        n = len(self.fake.calls)
        m = S.seller_send(t, "Hi again")
        self.assertEqual((m.status, m.send_error), ("blocked", "outside_24h_window"))
        self.assertEqual(len(self.fake.calls), n)               # nothing hit Graph


@override_settings(MEDIA_ROOT=_MEDIA)
class ImageOrderTests(G1Base):
    def setUp(self):
        super().setUp()
        from django.core.files.uploadedfile import SimpleUploadedFile
        self.p.photo = SimpleUploadedFile("panjabi.png", _png((200, 30, 30)), "image/png")
        self.p.save()

    def test_match_creates_draft_owner_confirms(self):
        ch = self.tch()
        with mock.patch.object(M, "describe", side_effect=AssertionError("vision called")):
            self.post_t(mimage(data_url(_png((200, 30, 30), white_bars=True)), "img1",
                               page=TPAGE))
        t = self.thread(ch)
        o = Order.objects.get(thread=t)
        self.assertEqual((o.status, o.via_agent, str(o.total)), ("new", True, "1200.00"))
        self.assertIn("খসড়া অর্ডার", self.outs(t)[-1].text)
        self.p.refresh_from_db()
        self.assertEqual(self.p.stock, 10)                       # untouched until confirm
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/inbox?status=attention")
        self.assertEqual([x["id"] for x in r.data["threads"]], [t.id])
        r = self.c.post("/api/v1/bizagent/orders/%d/confirm" % o.id)
        self.assertEqual(r.status_code, 200)
        self.p.refresh_from_db()
        self.assertEqual(self.p.stock, 9)
        r = self.c.post("/api/v1/bizagent/orders/%d/confirm" % o.id)
        self.assertEqual(r.status_code, 409)
        self.assertTrue(BizAuditLog.objects.filter(action="draft_confirm").exists())

    def test_vision_match_draft_and_cancel(self):
        ch = self.tch()
        self.user.ai_credits = 40
        self.user.save()
        raw = json.dumps({"kind": "product", "description": "a red panjabi kurta",
                          "colours": ["red"], "best_match": "Panjabi"})
        with mock.patch.object(M, "vision_provider", return_value=("vision_claude", {}, 0.02)), \
                mock.patch.object(VP, "ask", return_value=raw):
            self.post_t(mimage(data_url(_png((120, 120, 120), "stripes", size=300)), "img2",
                               page=TPAGE))
        o = Order.objects.get(thread=self.thread(ch))
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/orders/%d/cancel" % o.id)
        self.assertEqual(r.status_code, 200)
        o.refresh_from_db()
        self.assertEqual(o.status, "cancelled")

    def test_no_match_is_honest_no_draft(self):
        ch = self.tch()
        self.user.ai_credits = 40
        self.user.save()
        raw = json.dumps({"kind": "other", "description": "a cat", "best_match": ""})
        with mock.patch.object(M, "vision_provider", return_value=("vision_claude", {}, 0.02)), \
                mock.patch.object(VP, "ask", return_value=raw), \
                mock.patch.object(M, "visual_matches", return_value=[]):
            self.post_t(mimage(data_url(_png((1, 2, 3), "stripes")), "img3", page=TPAGE))
        t = self.thread(ch)
        self.assertFalse(Order.objects.filter(thread=t).exists())
        self.assertNotIn("1200", "".join(m.text for m in self.outs(t)))

    def test_customer_confirm_reuses_draft(self):
        ch = self.tch()
        with mock.patch.object(M, "describe", side_effect=AssertionError("vision called")):
            self.post_t(mimage(data_url(_png((200, 30, 30), white_bars=True)), "img4",
                               page=TPAGE))
        t = self.thread(ch)
        o = GD.open_draft(t)
        self.assertIsNotNone(o)
        # the customer completes the order in chat → the draft becomes THE order
        t.order_draft = {"product_id": self.p.id, "product": "Panjabi", "qty": 1,
                         "name": "Rahim", "phone": "01712345678", "address": "Mirpur 10",
                         "area": "inside", "state": "awaiting_confirm", "active": True}
        t.save()
        S.confirm_order(t, self.agent, "en")
        self.assertEqual(Order.objects.filter(thread=t).count(), 1)
        o.refresh_from_db()
        self.assertEqual(o.status, "confirmed")


class CapTests(G1Base):
    def test_daily_ai_cap_holds_and_tells_owner_once(self):
        self.agent.daily_ai_cap = 1
        self.agent.save()
        with mock.patch.object(ai, "key_present", return_value=True), llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.c1"))
            self.post_meta(mpayload(LLM_Q + " ?", "m.c2", psid="u2"))
            self.post_meta(mpayload(LLM_Q + " !", "m.c3", psid="u3"))
        self.assertEqual(Message.objects.filter(reply_source="ai").count(), 1)
        held = Message.objects.filter(status="pending_approval", risk_reason="daily_ai_cap")
        self.assertEqual(held.count(), 2)
        self.assertEqual(BizAuditLog.objects.filter(action="cap_daily_ai").count(), 2)

    def test_rules_still_answer_over_cap(self):
        self.agent.daily_ai_cap = 0
        self.agent.save()
        with mock.patch.object(ai, "key_present", return_value=True), \
                mock.patch.object(S, "_llm_draft", side_effect=AssertionError("AI called")):
            self.post_meta(mpayload("Panjabi dam koto?", "m.r1"))
        self.assertIn("1200", "".join(self.fake.texts()))

    def test_thread_cap_and_burst(self):
        self.agent.thread_daily_cap = 1
        self.agent.save()
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.k1"))
            n = len(self.outs())
            self.post_meta(mpayload(LLM_Q, "m.k2"))
        self.assertEqual(len(self.outs()), n)
        self.assertTrue(BizAuditLog.objects.filter(action="cap_thread").exists())
        self.agent.thread_daily_cap = 500
        self.agent.save()
        t = self.thread()
        for i in range(GD.BURST_MAX + 1):
            Message.objects.create(thread=t, direction="in", text="x", status="received")
        self.assertEqual(GD.gate(self.agent, t), "burst")


class InboxTests(G1Base):
    def test_filters_unread_search_channel(self):
        with llm("Panjabi ৳1200"):
            self.post_meta(mpayload(LLM_Q, "m.n1", psid="ua"))
            self.post_wa(wapayload("saree ache?", "wamid.n2"))
        tm = ChatThread.objects.get(seller_channel=self.ch)
        tw = ChatThread.objects.get(seller_channel=self.wa)
        GD.take_over(tw)
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/inbox")
        self.assertEqual(r.data["counts"]["all"], 2)
        self.assertEqual(r.data["counts"]["unread"], 2)
        self.assertEqual({x["id"]: x["status"] for x in r.data["threads"]}[tw.id], "owner")
        r = self.c.get("/api/v1/bizagent/inbox?status=owner")
        self.assertEqual([x["id"] for x in r.data["threads"]], [tw.id])
        r = self.c.get("/api/v1/bizagent/inbox?channel=messenger")
        self.assertEqual([x["id"] for x in r.data["threads"]], [tm.id])
        r = self.c.get("/api/v1/bizagent/inbox?q=saree")
        self.assertEqual([x["id"] for x in r.data["threads"]], [tw.id])
        self.c.get("/api/v1/bizagent/threads/%d" % tm.id)          # opening marks read
        r = self.c.get("/api/v1/bizagent/inbox?unread=1")
        self.assertEqual([x["id"] for x in r.data["threads"]], [tw.id])
        self.c.post("/api/v1/bizagent/threads/%d/read" % tw.id)
        r = self.c.get("/api/v1/bizagent/inbox?unread=1")
        self.assertEqual(r.data["threads"], [])

    def test_owner_reply_from_inbox_audited(self):
        self.post_meta(mpayload("hello", "m.o1"))
        t = self.thread()
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/threads/%d/send" % t.id, {"text": "Ji bolun"},
                        format="json")
        self.assertTrue(r.data["ok"])
        self.assertTrue(BizAuditLog.objects.filter(action="owner_reply", thread=t).exists())
        r = self.c.get("/api/v1/bizagent/audit")
        self.assertIn("owner_reply", [a["action"] for a in r.data["audit"]])
        self.assertNotIn("Ji bolun", json.dumps(r.data))         # no message bodies

    def test_other_business_cannot_read(self):
        from core.models import BusinessProfile, User
        self.post_meta(mpayload("hello", "m.x1"))
        u2 = User.objects.create_user(email="o2@example.invalid", name="O2", password="x")
        BusinessProfile.objects.create(user=u2, shop_name="Other")
        self.c.force_authenticate(u2)
        r = self.c.get("/api/v1/bizagent/inbox")
        self.assertEqual(r.data["threads"], [])
        o = Order.objects.create(user=self.user, business=self.biz, status="new",
                                 via_agent=True, total=1)
        self.assertEqual(self.c.post("/api/v1/bizagent/orders/%d/confirm" % o.id).status_code,
                         404)


class FeatureGateTests(G1Base):
    def test_hidden_without_channel_or_meta(self):
        self.c.force_authenticate(self.user)
        f = self.c.get("/api/v1/bizagent/setup").data["features"]
        self.assertEqual((f["own_channels"], f["inbox"]), (True, True))
        SellerChannel.objects.all().delete()
        with mock.patch.object(S, "meta_app", return_value={}):
            f = self.c.get("/api/v1/bizagent/setup").data["features"]
        self.assertEqual((f["own_channels"], f["inbox"], f["image_order"], f["vision"]),
                         (False, False, False, False))

    def test_settings_caps_clamped(self):
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/settings",
                        {"takeover_idle_minutes": 999999, "daily_ai_cap": -5,
                         "thread_daily_cap": 0}, format="json")
        s = r.data["settings"]
        self.assertEqual((s["takeover_idle_minutes"], s["daily_ai_cap"], s["thread_daily_cap"]),
                         (GD.IDLE_MAX_MIN, 0, 1))
        self.assertEqual(BZ.RISK_LOW_CONF, "low_confidence")
