"""G1 — Business AI Agent advanced ("Night Salesman") tests.

Rule-first layer (no AI, 0 credits) + FAQ (approved only, learned → suggested,
stale price skipped) · takeover (Page echo / app reply pauses ONE chat, resume
after the timeout when the customer still waits, per-chat toggle, business
mode always/outside_hours/off, single-flight lease, a human reply during
compose drops the AI reply) · autonomous order (summary + confirm → order +
stock − + invoice with order number + upsell + bundle never below min +
auto courier MOCK on test channels) · payment screenshots → payment-pending,
owner verifies · photos (free perceptual match, paid vision with refund on
failure, closest 2-3 with photos, data: URLs only on test channels) · voice
notes (no key = honest fallback; key = transcript → rules) · website widget
(key, origin, rate limit, same pipeline) · comment-to-DM with post→product ·
follow-ups (once, 24 h window, opt-out) · quiet hours + morning summary ·
agent report · Owner Admin rules-vs-AI stats."""
import base64
import io
import json
import shutil
import tempfile
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.utils import timezone

from core import bizagent_g1_service as G1S
from core import bizagent_media as M
from core import bizagent_service as S
from core import integrations
from core import vision_providers as VP
from core.logic import bizagent as BZ
from core.logic import bizagent_g1 as G1
from core.logic import bizagent_rules as R
from core.models import (BizFaq, BizPostLink, ChatThread, CreditLedger, Message, Order,
                         Product, SellerChannel)
from core.tests_p1_bizagent import Base, PAGE, mpayload, wapayload

TPAGE = "990000000000111"
_MEDIA = tempfile.mkdtemp(prefix="g1media")


def tearDownModule():
    shutil.rmtree(_MEDIA, ignore_errors=True)


def _png(color, shape="circle", size=400, white_bars=False):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (size, size), color)
    d = ImageDraw.Draw(im)
    if shape == "circle":
        d.ellipse((size // 4, size // 4, 3 * size // 4, 3 * size // 4), fill=(20, 40, 200))
    else:
        for x in range(0, size, size // 10):
            d.rectangle((x, 0, x + size // 20, size), fill=(250, 250, 30))
    if white_bars:
        sc = Image.new("RGB", (360, 640), (255, 255, 255))
        sc.paste(im.resize((360, 360)), (0, 140))
        im = sc
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


def data_url(raw, mime="image/png"):
    return "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode())


def mimage(url, mid, psid="u1", page=PAGE, text=None, typ="image"):
    ts = int(timezone.now().timestamp() * 1000)
    msg = {"mid": mid, "attachments": [{"type": typ, "payload": {"url": url}}]}
    if text:
        msg["text"] = text
    return {"object": "page", "entry": [{"id": page, "time": ts, "messaging": [
        {"sender": {"id": psid}, "recipient": {"id": page}, "timestamp": ts, "message": msg}]}]}


def echo(text, mid, page=PAGE, psid="u1"):
    return {"object": "page", "entry": [{"id": page, "messaging": [
        {"sender": {"id": page}, "recipient": {"id": psid}, "timestamp": 1,
         "message": {"mid": mid, "text": text, "is_echo": True, "app_id": 999}}]}]}


class G1Base(Base):
    def setUp(self):
        super().setUp()
        self.no_llm = mock.patch.object(S, "_llm_draft", side_effect=AssertionError("AI called"))

    def tch(self):
        """A TEST-MODE Messenger channel (self-test style: never hits Graph)."""
        ch = SellerChannel.objects.create(business=self.biz, kind="messenger", external_id=TPAGE,
                                          status="connected", test_mode=True)
        ch.test_secret_enc = S.enc({"secret": "tsec"})
        ch.save()
        return ch

    def post_t(self, payload):
        return self.post_meta(payload, secret="tsec")


# ======================================================================= pure
class PureTests(TestCase):
    CAT = [{"id": 1, "name": "Panjabi", "price": "1200", "stock": 10, "sku": "P-0007",
            "category": "men", "min_price": "1000",
            "variants": [{"size": "M", "colour": "White", "price": "1200", "stock": 3}]},
           {"id": 2, "name": "Saree", "price": "2500", "stock": 0, "category": "women"},
           {"id": 3, "name": "Hilsa", "price": "900", "stock": 5, "category": "fish"},
           {"id": 4, "name": "Pajama", "price": "500", "stock": 4, "category": "men"}]

    def ctx(self, **kw):
        c = {"lang": "bn", "catalog": self.CAT,
             "delivery": {"inside_dhaka": "60", "outside_dhaka": "120", "free_over": "3000"},
             "hours_text": "10:00–22:00", "policies": {"returns": "৭ দিনে এক্সচেঞ্জ"},
             "faqs": [], "orders": [], "shop_name": "Rupa"}
        c.update(kw)
        return c

    def test_rules_answer_families(self):
        a = R.answer
        self.assertEqual(a("hi", self.ctx())["rule"], R.R_GREETING)        # never "Hilsa"
        self.assertEqual(a("Hilsa dam koto?", self.ctx())["product_id"], 3)
        self.assertEqual(a("পাঞ্জাবিটার দাম কত?", self.ctx(catalog=[
            {"id": 9, "name": "পাঞ্জাবি", "price": "1300", "stock": 2}]))["product_id"], 9)
        self.assertEqual(a("delivery charge koto?", self.ctx())["rule"], R.R_DELIVERY)
        self.assertIn("ফ্রি", a("delivery charge koto?", self.ctx())["text"])
        self.assertIn("স্টকে নেই", a("Saree ache?", self.ctx())["text"])
        self.assertEqual(a("Panjabi size ki ki?", self.ctx())["rule"], R.R_SIZES)
        self.assertEqual(a("P-0007", self.ctx())["product_id"], 1)
        self.assertEqual(a("#3 price", self.ctx())["product_id"], 3)
        self.assertEqual(a("dokan kokhon khola", self.ctx())["rule"], R.R_HOURS)
        self.assertEqual(a("return policy?", self.ctx())["rule"], R.R_RETURNS)
        self.assertEqual(a("amar order kobe pabo?", self.ctx(orders=[
            {"id": 12, "status": "shipped", "tracking": "T1", "courier": "steadfast"}]))["rule"],
            R.R_ORDER_STATUS)
        self.assertIsNone(a("please help me", self.ctx()))          # 'ase' ⊄ 'please'
        self.assertIsNone(a("Panjabi ta ki cotton?", self.ctx()))   # → the AI
        self.assertIsNone(a("refund chai", self.ctx()))
        self.assertIn("PIN", R.answer("payment kivabe?", self.ctx(lang="en"))["text"])

    def test_partial_name_never_overrides_chosen_product(self):
        # found by the live-proof run: "Name: Selftest Buyer" partially matched
        # "Selftest Pajama" and replaced the product the customer chose by photo
        cat = [{"id": 1, "name": "Selftest Panjabi", "price": "1200", "stock": 5},
               {"id": 2, "name": "Selftest Pajama", "price": "500", "stock": 5}]
        d = BZ.extract_order("2 ta nibo. Name: Selftest Buyer, phone 01900000000",
                             {"product_id": 1, "product": "Selftest Panjabi"}, cat)
        self.assertEqual((d["product_id"], d["qty"]), (1, 2))
        self.assertNotIn("product_id", BZ.extract_order("Name: Selftest Buyer", {}, cat))
        self.assertEqual(BZ.extract_order("Selftest Pajama 1 ta", {"product_id": 1}, cat)
                         ["product_id"], 2)                  # a FULL name still switches
        self.assertIsNone(R.find_product("Selftest dam koto", cat))   # ambiguous → AI

    def test_faq_alternatives_and_threshold(self):
        faqs = [{"id": 5, "q": "dokan kothay | আপনাদের দোকান কোথায়", "a": "মিরপুর ১০"}]
        self.assertEqual(R.answer("apnader dokan kothay?", self.ctx(faqs=faqs))["faq_id"], 5)
        self.assertEqual(R.answer("আপনাদের দোকান কোথায়?", self.ctx(faqs=faqs))["rule"], R.R_FAQ)
        self.assertIsNone(R.faq_match(faqs, "kothay jabo"))

    def test_learn_faq_never_publishes_prices(self):
        out = R.learn_faq([("dokan kothay?", "Mirpur 10 e amader dokan."),
                           ("Panjabi dam?", "৳1200 taka"), ("hi", "hello"),
                           ("ami order dibo 01712345678", "ok noted bhai")])
        self.assertEqual([o["has_price"] for o in out], [False, True])

    def test_who_replies(self):
        now = 1_000_000
        ok = dict(mode="always", ai_enabled=True, in_business_hours=False, human_mode=False,
                  paused_until_ts=None, now_ts=now)
        self.assertEqual(G1.may_ai_reply(**ok), (True, "ok"))
        self.assertEqual(G1.may_ai_reply(**dict(ok, paused_until_ts=now + 5))[1], "paused")
        self.assertTrue(G1.may_ai_reply(**dict(ok, paused_until_ts=now - 5))[0])
        self.assertEqual(G1.may_ai_reply(**dict(ok, human_mode=True))[1], "human_mode")
        self.assertEqual(G1.may_ai_reply(**dict(ok, mode="off"))[1], "mode_off")
        self.assertEqual(G1.may_ai_reply(**dict(ok, mode="outside_hours",
                                                in_business_hours=True))[1], "business_hours")
        self.assertTrue(G1.may_ai_reply(**dict(ok, mode="outside_hours"))[0])
        self.assertEqual(G1.pause_until_ts(0, None), 15 * 60)
        self.assertTrue(G1.customer_waiting([{"direction": "out", "status": "sent"},
                                             {"direction": "in", "status": "received"}]))
        self.assertFalse(G1.customer_waiting([{"direction": "in", "status": "received"},
                                              {"direction": "out", "status": "sent"}]))

    def test_quiet_window_wraps_midnight(self):
        q = {"start": "23:00", "end": "08:00"}
        self.assertTrue(G1.in_window(q, 23 * 60 + 30))
        self.assertTrue(G1.in_window(q, 7 * 60))
        self.assertFalse(G1.in_window(q, 12 * 60))
        self.assertFalse(G1.in_window({}, 0))

    def test_bundle_never_below_min_and_upsell(self):
        rules = [{"min_qty": 2, "off_pct": 10}, {"min_qty": 3, "off_pct": 40}]
        self.assertEqual(G1.bundle_unit_price("1200", "1000", 2, rules)[0], Decimal("1080"))
        self.assertEqual(G1.bundle_unit_price("1200", "1000", 3, rules)[0], Decimal("1000"))
        self.assertEqual(G1.bundle_unit_price("1200", "0", 3, rules)[1], None)   # no min = no discount
        self.assertEqual(G1.normalize_bundle_rules([{"min_qty": 1, "off_pct": 5},
                                                    {"min_qty": 2, "off_pct": 90}]), [])
        self.assertEqual(G1.pick_upsell(self.CAT, 1)["id"], 4)       # same category, in stock
        self.assertIsNone(G1.pick_upsell(self.CAT, 3))

    def test_payment_proof_detection(self):
        self.assertTrue(G1.is_payment_proof("bkash e payment korechi"))
        self.assertTrue(G1.is_payment_proof("", "TrxID: 9A7B6C5D4E"))
        self.assertTrue(G1.is_payment_proof("", "", "payment"))
        self.assertFalse(G1.is_payment_proof("ei ta ache?"))

    def test_followup_rules(self):
        base = dict(enabled=True, opted_out=False, human_mode=False, paused=False, quiet=False,
                    last_dir="out", last_out_kind="order", last_at_ts=0, last_inbound_ts=0,
                    now_ts=4 * 3600, sent=0, max_n=1, after_hours=3)
        self.assertTrue(G1.followup_due(**dict(base, last_at_ts=1, last_inbound_ts=1)))
        self.assertFalse(G1.followup_due(**dict(base, last_at_ts=1, last_inbound_ts=1, sent=1)))
        self.assertFalse(G1.followup_due(**dict(base, last_at_ts=1, last_inbound_ts=1,
                                                opted_out=True)))
        self.assertFalse(G1.followup_due(**dict(base, last_at_ts=1, last_inbound_ts=1,
                                                now_ts=25 * 3600)))       # outside 24 h
        self.assertTrue(G1.is_opt_out("stop"))
        self.assertTrue(G1.is_opt_out("আর মেসেজ দিবেন না"))

    def test_vision_parse_and_text_match(self):
        v = G1.parse_vision('```json {"kind":"product","description":"white cotton panjabi",'
                            '"colours":["white"],"best_match":"Panjabi","phone":"০১৭১২৩৪৫৬৭৮"} ```')
        self.assertEqual(v["kind"], "product")
        self.assertEqual(v["phone"], "01712345678")
        self.assertEqual(G1.text_match_scores(v, self.CAT)[0][1]["id"], 1)
        self.assertEqual(G1.parse_vision("not json")["kind"], "other")

    def test_widget_origin_and_visitor(self):
        self.assertTrue(G1.origin_allowed("https://shop.example", ""))
        self.assertFalse(G1.origin_allowed("http://evil.example", ""))
        self.assertTrue(G1.origin_allowed("https://a.example", "https://a.example"))
        self.assertFalse(G1.origin_allowed("https://b.example", "https://a.example"))
        self.assertTrue(G1.valid_visitor("v" + "a" * 20))
        self.assertFalse(G1.valid_visitor("<script>"))

    def test_perceptual_match(self):
        a = M.signature(_png((200, 30, 30)))
        shot = M.signature(_png((200, 30, 30), white_bars=True))
        other = M.signature(_png((30, 160, 60), "stripes"))
        self.assertGreater(M.similarity(a, shot), 0.9)
        self.assertLess(M.similarity(other, shot), 0.6)
        self.assertIsNone(M.signature(b"not an image"))


# ======================================================================= rule-first
class RuleFirstTests(G1Base):
    def test_everyday_questions_answered_without_ai_or_credits(self):
        self.user.ai_credits = 50
        self.user.save()
        with self.no_llm:
            for i, q in enumerate(("Panjabi dam koto?", "delivery charge koto?",
                                   "Saree ache?", "hello")):
                self.post_meta(mpayload(q, "r%d" % i))
        outs = self.outs()
        self.assertEqual(len(outs), 4)
        self.assertTrue(all(o.reply_source == "rule" and o.status == "sent" for o in outs))
        self.assertEqual([o.meta.get("rule") for o in outs],
                         [R.R_PRODUCT, R.R_DELIVERY, R.R_PRODUCT, R.R_GREETING])
        self.agent.refresh_from_db()
        self.user.refresh_from_db()
        self.assertEqual((self.agent.replies_used, self.user.ai_credits), (0, 50))
        self.assertFalse(CreditLedger.objects.filter(user=self.user).exists())

    def test_rules_off_goes_to_ai(self):
        self.agent.rules_enabled = False
        self.agent.save()
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Panjabi ৳1200.", "confidence": 0.9}) as m:
            self.post_meta(mpayload("Panjabi dam koto?", "ro1"))
        self.assertTrue(m.called)
        self.assertEqual(self.outs()[-1].reply_source, "ai")

    def test_faq_only_when_approved_and_stale_price_skipped(self):
        f = BizFaq.objects.create(business=self.biz, question="dokan kothay",
                                  answer="Mirpur 10 e", status="suggested", source="learned")
        with mock.patch.object(S, "_llm_draft", return_value=None):
            self.post_meta(mpayload("apnader dokan kothay?", "f1"))
        self.assertNotEqual(self.outs()[-1].meta.get("rule"), R.R_FAQ)
        f.status = "approved"
        f.save()
        with self.no_llm:
            self.post_meta(mpayload("apnader dokan kothay?", "f2"))
        self.assertEqual(self.outs()[-1].meta.get("rule"), R.R_FAQ)
        self.assertIn("Mirpur 10", self.outs()[-1].text)
        f.refresh_from_db()
        self.assertEqual(f.hits, 1)
        BizFaq.objects.create(business=self.biz, question="combo offer ki",
                              answer="Combo only 999 taka", status="approved")
        with mock.patch.object(S, "_llm_draft", return_value=None):
            self.post_meta(mpayload("combo offer ki?", "f3"))
        self.assertNotIn("999", "".join(self.fake.texts()))     # stale price never sent

    def test_rules_stats_and_owner_admin_numbers(self):
        with self.no_llm:
            self.post_meta(mpayload("Panjabi dam koto?", "s1"))
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Yes, pure cotton.", "confidence": 0.9}):
            self.post_meta(mpayload("Panjabi ta ki cotton?", "s2"))
        st = G1S.rules_stats()
        self.assertEqual((st["rule"], st["ai"], st["rule_pct"]), (1, 1, 50.0))
        self.assertEqual(st["saved_seller_credits"], 3)
        self.assertGreater(st["saved_provider_bdt"], 0)
        self.assertEqual(st["by_rule"], {"product": 1})


# ======================================================================= takeover
class TakeoverTests(G1Base):
    def test_echo_pauses_then_ai_resumes_for_waiting_customer(self):
        self.post_meta(mpayload("hello", "t0"))
        self.post_meta(echo("Ami owner, dekhchi", "t.e1"))
        t = self.thread()
        self.assertIsNotNone(t.ai_paused_until)
        n = len(self.outs())
        self.post_meta(mpayload("Panjabi dam koto?", "t1"))     # customer waits
        self.assertEqual(len(self.outs()), n)                    # AI silent while paused
        ChatThread.objects.filter(pk=t.pk).update(
            ai_paused_until=timezone.now() - timedelta(seconds=1))
        self.assertEqual(G1S.resume_waiting(), 1)
        last = self.outs()[-1]
        self.assertTrue(last.is_ai)
        self.assertIn("1200", last.text)
        self.assertIsNone(ChatThread.objects.get(pk=t.pk).ai_paused_until)
        self.assertEqual(G1S.resume_waiting(), 0)                # once

    def test_resume_skips_when_human_answered(self):
        self.post_meta(mpayload("Panjabi dam koto?", "h0"))
        t = self.thread()
        self.post_meta(mpayload("ar ki color ache?", "h1x"))
        S.seller_send(t, "White ache bhai")                      # the person answered
        t.refresh_from_db()
        self.assertEqual(t.paused_by, "app")
        ChatThread.objects.filter(pk=t.pk).update(
            ai_paused_until=timezone.now() - timedelta(seconds=1))
        n = len(self.outs())
        self.assertEqual(G1S.resume_waiting(), 0)                # nobody is waiting
        self.assertEqual(len(self.outs()), n)

    def test_resume_timeout_is_seller_setting(self):
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/settings", {"resume_minutes": 5}, format="json")
        self.assertEqual(r.data["settings"]["resume_minutes"], 5)
        self.post_meta(mpayload("hello", "rt0"))
        before = timezone.now()
        self.post_meta(echo("hi", "rt.e"))
        until = self.thread().ai_paused_until
        self.assertLess(until, before + timedelta(minutes=5, seconds=5))

    def test_per_chat_toggle(self):
        self.post_meta(mpayload("hello", "pc0"))
        t = self.thread()
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/threads/%d/mode" % t.id, {"mode": "human"},
                        format="json")
        self.assertEqual(r.data["reply_mode"], "human")
        n = len(self.outs())
        self.post_meta(mpayload("Panjabi dam koto?", "pc1"))
        self.assertEqual(len(self.outs()), n)
        ChatThread.objects.filter(pk=t.pk).update(
            ai_paused_until=timezone.now() - timedelta(seconds=1))
        self.assertEqual(G1S.resume_waiting(), 0)                # human mode: never resumes
        r = self.c.get("/api/v1/bizagent/threads/%d" % t.id)
        self.assertEqual(r.data["thread"]["reply_mode"], "human")
        self.c.post("/api/v1/bizagent/threads/%d/mode" % t.id, {"mode": "ai"}, format="json")
        self.post_meta(mpayload("Panjabi dam koto?", "pc2"))
        self.assertTrue(self.outs()[-1].is_ai)
        r = self.c.post("/api/v1/bizagent/threads/%d/mode" % t.id, {"mode": "x"}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_business_mode_switch(self):
        self.c.force_authenticate(self.user)
        self.c.post("/api/v1/bizagent/settings", {"ai_mode": "off"}, format="json")
        self.post_meta(mpayload("Panjabi dam koto?", "bm1"))
        self.assertEqual(len(self.outs()), 0)
        self.c.post("/api/v1/bizagent/settings",
                    {"ai_mode": "outside_hours", "hours": {"start": "00:00", "end": "23:59"}},
                    format="json")
        self.post_meta(mpayload("Panjabi dam koto?", "bm2"))
        self.assertEqual(len(self.outs()), 0)                    # inside business hours
        self.c.post("/api/v1/bizagent/settings", {"ai_mode": "always"}, format="json")
        self.post_meta(mpayload("Panjabi dam koto?", "bm3"))
        self.assertEqual(len(self.outs()), 1)
        r = self.c.post("/api/v1/bizagent/settings", {"ai_mode": "night"}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_single_flight_never_two_replies(self):
        self.post_meta(mpayload("hello", "sf0"))
        t = self.thread()
        self.assertTrue(G1S.acquire(t))                          # another worker is replying
        self.post_meta(mpayload("Panjabi dam koto?", "sf1"))
        n = len(self.outs())
        inbound = t.messages.filter(direction="in").order_by("-id").first()
        self.assertTrue(inbound.meta.get("deferred"))
        self.assertFalse(G1S.acquire(t))
        G1S.release(t)
        Message.objects.filter(pk=inbound.pk).update(
            created_at=timezone.now() - timedelta(seconds=30))
        self.assertEqual(G1S.process_deferred(), 1)
        self.assertEqual(len(self.outs()), n + 1)
        self.assertEqual(G1S.process_deferred(), 0)

    def test_human_reply_during_compose_drops_ai_reply(self):
        self.post_meta(mpayload("hello", "hc0"))
        t = self.thread()

        def human_meanwhile(*a, **k):
            S.seller_send(t, "Ami answer dicchi")
            return {"text": "Pure cotton.", "confidence": 0.9}
        with mock.patch.object(S, "_llm_draft", side_effect=human_meanwhile):
            self.post_meta(mpayload("Panjabi ta ki cotton?", "hc1"))
        last = self.outs()[-1]
        self.assertFalse(last.is_ai)
        self.assertEqual(last.text, "Ami answer dicchi")
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.replies_used, 0)


# ======================================================================= orders
@override_settings(MEDIA_ROOT=_MEDIA)
class AutonomousOrderTests(G1Base):
    def test_summary_confirm_order_stock_invoice_upsell_bundle_mock_courier(self):
        ch = self.tch()
        Product.objects.create(user=self.user, business=self.biz, name="Pajama",
                               price=Decimal("500"), stock=4, category="men")
        self.p.category = "men"
        self.p.save()
        self.agent.bundle_rules = [{"min_qty": 2, "off_pct": 5}]
        self.agent.auto_courier = True
        self.agent.default_courier = "steadfast"
        self.agent.save()
        self.post_t(mpayload("Panjabi order korbo 2 ta", "o1", page=TPAGE))
        self.post_t(mpayload("Name: Karim Uddin\nPhone: 01712345678\nAddress: House 5, Road 2, "
                             "Mirpur, Dhaka", "o2", page=TPAGE))
        t = self.thread(ch)
        summary = self.outs(t)[-1].text
        self.assertIn("2280", summary)                   # 2 × (1200 − 5 %) = 2280
        self.assertIn("1140", summary)                   # bundle unit price shown
        self.assertIn("2340", summary)                   # + ৳60 inside Dhaka
        self.assertEqual(self.outs(t)[-1].reply_source, "rule")
        self.post_t(mpayload("হ্যাঁ", "o3", page=TPAGE))
        o = Order.objects.get()
        self.assertEqual((o.total, o.via_agent, o.payment, o.payment_status),
                         (Decimal("2340"), True, "cod", ""))
        self.p.refresh_from_db()
        self.assertEqual(self.p.stock, 8)
        texts = [m.text for m in self.outs(t)]
        inv = next(x for x in texts if ("#%d" % o.id) in x and "Pajama" in x)
        self.assertIn("2340", inv)
        # courier: TEST mode = mock, clearly labelled, never live
        self.assertEqual((o.status, o.courier_live), ("shipped", False))
        self.assertTrue(o.tracking.startswith("TEST-STEADFAST-"))
        self.assertIn("টেস্ট মোড", texts[-1])
        self.assertEqual(self.fake.calls, [])            # nothing went to Graph
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.replies_used, 0)     # the whole sale cost 0 credits

    def test_real_channel_auto_courier_needs_keys(self):
        self.agent.auto_courier = True
        self.agent.default_courier = "pathao"
        self.agent.save()
        self.post_meta(mpayload("Panjabi order 1 ta. Name: Rina, 01812345678, Address: "
                                "House 1, Road 3, Uttara, Dhaka", "rc1"))
        self.post_meta(mpayload("yes", "rc2"))
        o = Order.objects.get()
        self.assertEqual((o.status, o.courier_live, o.tracking), ("confirmed", False, ""))

    def test_payment_screenshot_is_only_pending(self):
        ch = self.tch()
        self.post_t(mpayload("Panjabi order 1 ta. Name: Rina, 01812345678, Address: House 1, "
                             "Road 3, Uttara, Dhaka", "ps1", page=TPAGE))
        self.post_t(mpayload("yes", "ps2", page=TPAGE))
        o = Order.objects.get()
        self.post_t(mimage(data_url(_png((9, 9, 9))), "ps3", page=TPAGE,
                           text="bkash e payment korechi"))
        o.refresh_from_db()
        self.assertEqual((o.payment_status, o.payment), ("pending_verification", "cod"))
        last = self.outs(self.thread(ch))[-1].text
        self.assertIn("যাচাই", last)
        self.assertNotIn("পরিশোধিত হয়েছে", last)
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/orders/%d/payment" % o.id, {"status": "verified"},
                        format="json")
        self.assertEqual(r.data["payment_status"], "verified")


# ======================================================================= photos
@override_settings(MEDIA_ROOT=_MEDIA)
class PhotoTests(G1Base):
    def setUp(self):
        super().setUp()
        self.p.photo = SimpleUploadedFile("panjabi.png", _png((200, 30, 30)), "image/png")
        self.p.save()
        self.p2.photo = SimpleUploadedFile("saree.png", _png((30, 160, 60), "stripes"),
                                           "image/png")
        self.p2.save()

    def test_screenshot_matches_catalog_free(self):
        ch = self.tch()
        self.user.ai_credits = 40
        self.user.save()
        with mock.patch.object(M, "describe", side_effect=AssertionError("vision called")):
            self.post_t(mimage(data_url(_png((200, 30, 30), white_bars=True)), "i1",
                               page=TPAGE))
        t = self.thread(ch)
        out = self.outs(t)[-1]
        self.assertIn("Panjabi", out.text)
        self.assertIn("1200", out.text)
        self.assertEqual((out.reply_source, out.meta.get("rule")), ("rule", "image_match"))
        self.assertEqual(t.order_draft.get("product_id"), self.p.id)
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 40)

    def test_vision_paid_match_and_profit_guard_cost(self):
        ch = self.tch()
        self.user.ai_credits = 40
        self.user.save()
        raw = json.dumps({"kind": "product", "description": "a red panjabi kurta",
                          "colours": ["red"], "best_match": "Panjabi"})
        with mock.patch.object(M, "vision_provider", return_value=("vision_claude", {}, 0.02)), \
                mock.patch.object(VP, "ask", return_value=raw):
            self.post_t(mimage(data_url(_png((120, 120, 120), "stripes", size=300)), "i2",
                               page=TPAGE))
        out = self.outs(self.thread(ch))[-1]
        self.assertEqual(out.meta.get("rule"), "image_vision")
        self.assertIn("1200", out.text)
        self.assertEqual(out.credits, 6)                         # ai_sales_vision
        self.assertGreater(out.cost_bdt, 0)                      # cost per image booked
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 34)
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.replies_used, 0)             # one charge, not two
        st = G1S.rules_stats()
        self.assertEqual(st["vision_images"], 1)
        self.assertGreater(st["vision_cost_per_image"], 0)

    def test_vision_failure_refunds_and_no_fake_answer(self):
        self.tch()
        self.user.ai_credits = 10
        self.user.save()
        with mock.patch.object(M, "vision_provider", return_value=("vision_claude", {}, 0.02)), \
                mock.patch.object(VP, "ask", side_effect=VP.VisionError("http_500")):
            self.post_t(mimage(data_url(_png((120, 120, 120), "stripes", size=300)), "i3",
                               page=TPAGE))
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 10)              # refunded
        out = Message.objects.filter(direction="out").exclude(status="pending_approval").last()
        self.assertNotEqual(out.meta.get("rule"), "image_vision")   # never a fake answer
        self.assertEqual(out.credits, 0)

    def test_closest_products_with_photos(self):
        ch = self.tch()
        raw = json.dumps({"kind": "product", "description": "some clothing", "best_match": ""})
        self.user.ai_credits = 10
        self.user.save()
        with mock.patch.object(M, "vision_provider", return_value=("vision_openai", {}, 0.01)), \
                mock.patch.object(VP, "ask", return_value=raw), \
                mock.patch.object(M, "visual_matches",
                                  return_value=[(0.6, self.p.id), (0.58, self.p2.id)]):
            self.post_t(mimage(data_url(_png((1, 2, 3))), "i4", page=TPAGE))
        outs = self.outs(self.thread(ch))
        imgs = [o for o in outs if o.kind == "image"]
        self.assertGreaterEqual(len(imgs), 1)
        self.assertTrue(imgs[0].meta["image_url"].startswith("https://"))

    def test_address_screenshot_fills_order(self):
        ch = self.tch()
        self.user.ai_credits = 10
        self.user.save()
        self.post_t(mpayload("Panjabi order 1 ta", "a1", page=TPAGE))
        raw = json.dumps({"kind": "address", "text": "Name: Sumi",
                          "phone": "01912345678", "address": "House 9, Road 1, Dhanmondi, Dhaka"})
        with mock.patch.object(M, "vision_provider", return_value=("vision_gemini", {}, 0.01)), \
                mock.patch.object(VP, "ask", return_value=raw):
            self.post_t(mimage(data_url(_png((5, 5, 5), size=200)), "a2", page=TPAGE))
        t = self.thread(ch)
        d = t.order_draft
        self.assertEqual((d.get("phone"), d.get("area"), d.get("state")),
                         ("01912345678", "inside", "awaiting_confirm"))

    def test_data_url_refused_on_real_channel(self):
        self.post_meta(mimage(data_url(_png((200, 30, 30))), "i5"))
        self.assertEqual(Message.objects.get(status="pending_approval").risk_reason,
                         BZ.RISK_UNKNOWN_PRODUCT)

    def test_messenger_cdn_fetch(self):
        prev = M.set_fetch(lambda url, headers=None: (200, _png((200, 30, 30), white_bars=True),
                                                      "image/png"))
        self.addCleanup(M.set_fetch, prev)
        self.post_meta(mimage("https://cdn.example/x.png", "i6"))
        self.assertEqual(self.outs()[-1].meta.get("rule"), "image_match")


# ======================================================================= voice
class VoiceTests(G1Base):
    def test_no_key_honest_fallback(self):
        ch = self.tch()
        self.post_t(mimage(data_url(b"OggS....", "audio/ogg"), "v1", page=TPAGE, typ="audio"))
        out = self.outs(self.thread(ch))[-1]
        self.assertEqual(out.meta.get("rule"), "voice_unavailable")
        self.assertIn("লিখে", out.text)

    def test_transcript_goes_through_rules_and_is_charged(self):
        ch = self.tch()
        integrations.save("voice_transcribe", {"api_key": "sk-test", "cost_per_minute_usd": "0.003"})
        from core.models import Integration
        Integration.objects.filter(slug="voice_transcribe").update(status="working")
        self.user.ai_credits = 10
        self.user.save()
        prev = M.set_transcriber(lambda conf, data, mime, lang: "Panjabi dam koto?")
        self.addCleanup(M.set_transcriber, prev)
        self.post_t(mimage(data_url(b"OggS....", "audio/ogg"), "v2", page=TPAGE, typ="audio"))
        t = self.thread(ch)
        inbound = t.messages.filter(direction="in").last()
        self.assertEqual((inbound.text, inbound.kind), ("Panjabi dam koto?", "voice"))
        out = self.outs(t)[-1]
        self.assertIn("1200", out.text)
        self.assertEqual(out.credits, 3)                          # ai_sales_voice
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 7)


# ======================================================================= widget
class WidgetTests(G1Base):
    def test_widget_end_to_end(self):
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/widget",
                        {"enabled": True, "origins": "https://rupa.example"}, format="json")
        key = r.data["key"]
        self.assertTrue(key.startswith("w_"))
        self.assertIn('data-key="%s"' % key, r.data["snippet"])
        js = self.client.get("/api/v1/bizagent/chat.js")
        self.assertEqual(js.status_code, 200)
        self.assertIn(b"assisto", js.content.lower())
        self.c.logout()
        url = "/api/v1/bizagent/widget/%s/send" % key
        vis = "vtest_visitor_123456"
        bad = self.client.post(url, json.dumps({"visitor": vis, "text": "hi"}),
                               content_type="application/json", HTTP_ORIGIN="https://evil.example")
        self.assertEqual(bad.status_code, 403)
        ok = self.client.post(url, json.dumps({"visitor": vis, "text": "Panjabi dam koto?"}),
                              content_type="application/json", HTTP_ORIGIN="https://rupa.example")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok["Access-Control-Allow-Origin"], "https://rupa.example")
        self.assertIn("1200", ok.json()["messages"][-1]["text"])
        poll = self.client.get("/api/v1/bizagent/widget/%s/messages?visitor=%s" % (key, vis),
                               HTTP_ORIGIN="https://rupa.example")
        self.assertEqual([m["dir"] for m in poll.json()["messages"]], ["in", "out"])
        for i in range(10):
            last = self.client.post(url, json.dumps({"visitor": vis, "text": "hello %d" % i}),
                                    content_type="application/json",
                                    HTTP_ORIGIN="https://rupa.example")
        self.assertEqual(last.status_code, 429)                  # rate-limited
        self.assertEqual(self.client.get("/api/v1/bizagent/widget/nope/messages?visitor=" + vis)
                         .status_code, 404)


# ======================================================================= comments
class CommentDmTests(G1Base):
    def comment(self, cid, text, post="p_1"):
        return {"object": "page", "entry": [{"id": PAGE, "time": 1, "changes": [
            {"field": "feed", "value": {"item": "comment", "verb": "add", "comment_id": cid,
                                        "post_id": post, "message": text,
                                        "from": {"id": "fan1", "name": "Fan"}}}]}]}

    def test_price_comment_gets_linked_product_in_inbox_once(self):
        BizPostLink.objects.create(business=self.biz, post_id="p_1", product=self.p)
        with self.no_llm:
            self.post_meta(self.comment("c1", "price?"))
        bodies = [b for _, _, b in self.fake.calls if b]
        private = [b for b in bodies if (b.get("recipient") or {}).get("comment_id") == "c1"]
        self.assertEqual(len(private), 1)
        self.assertIn("1200", private[0]["message"]["text"])
        public = [b for b in bodies if "recipient" not in b]
        self.assertTrue(public and "1200" not in public[0]["message"])
        self.post_meta(self.comment("c1", "price?"))              # redelivery
        self.assertEqual(len([b for _, _, b in self.fake.calls if b and
                              (b.get("recipient") or {}).get("comment_id") == "c1"]), 1)

    def test_comment_dm_switch(self):
        self.agent.comment_dm = False
        self.agent.save()
        self.post_meta(self.comment("c2", "price?"))
        self.assertEqual(self.fake.calls, [])


# ======================================================================= follow-ups / morning
class FollowupMorningTests(G1Base):
    def test_followup_once_inside_window_and_opt_out(self):
        self.agent.followups_enabled = True
        self.agent.save()
        self.post_meta(mpayload("Panjabi order korbo", "fu1"))
        t = self.thread()
        Message.objects.filter(thread=t).update(created_at=timezone.now() - timedelta(hours=4))
        ChatThread.objects.filter(pk=t.pk).update(last_inbound_at=timezone.now() - timedelta(hours=4))
        self.assertEqual(G1S.run_followups(), 1)
        self.assertEqual(self.outs()[-1].kind, "followup")
        self.assertEqual(G1S.run_followups(), 0)                 # capped at 1
        self.post_meta(mpayload("stop", "fu2"))
        self.assertTrue(ChatThread.objects.get(pk=t.pk).opted_out)

    def test_quiet_hours_hold_push_and_morning_summary_once(self):
        now = timezone.localtime()
        self.agent.quiet_hours = {"start": "00:00", "end": "23:59"}
        self.agent.morning_hour = 0
        self.agent.save()
        with mock.patch("core.push.safe_push") as push:
            self.post_meta(mpayload("refund chai", "qh1"))       # approval → push held
            self.assertFalse(push.called)
            self.assertEqual(G1S.run_morning(), 1)
            self.assertEqual(push.call_count, 1)                 # the summary always goes
            self.assertEqual(G1S.run_morning(), 0)               # once a day
        rep = self.biz.agent_reports.get(day=now.date())
        self.assertEqual(rep.data["morning"]["pending_approvals"], 1)


# ======================================================================= report / learn
class ReportLearnTests(G1Base):
    def test_agent_report_revenue_cost_profit(self):
        self.p.cost_price = Decimal("700")
        self.p.save()
        self.post_meta(mpayload("Panjabi order 1 ta. Name: Rina, 01812345678, Address: House 1, "
                                "Road 3, Uttara, Dhaka", "ar1"))
        self.post_meta(mpayload("yes", "ar2"))
        Order.objects.create(user=self.user, business=self.biz, total=Decimal("999"))  # manual
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/agent-report")
        rep = r.data["report"]
        self.assertEqual((rep["orders"], rep["revenue"], rep["gross_profit"]), (1, 1260.0, 500.0))
        self.assertEqual(rep["ai_cost"], 0.0)
        self.assertEqual(rep["profit"], 500.0)
        self.assertGreater(r.data["rules"]["rule"], 0)

    def test_learn_from_owner_replies_suggests_only(self):
        self.post_meta(mpayload("apnader dokan kothay?", "l1"))
        t = self.thread()
        S.seller_send(t, "Mirpur 10 e amader dokan, golir mathay.")
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/faqs/learn")
        self.assertEqual(r.data["suggested"], 1)
        f = BizFaq.objects.get()
        self.assertEqual((f.status, f.source), ("suggested", "learned"))
        r = self.c.get("/api/v1/bizagent/faqs")
        self.assertEqual(r.data["faqs"][0]["status"], "suggested")
        self.c.post("/api/v1/bizagent/faqs/%d" % f.id, {"status": "approved"}, format="json")
        self.assertEqual(BizFaq.objects.get().status, "approved")
        r = self.c.post("/api/v1/bizagent/faqs", {"question": "cash on delivery ache?",
                                                  "answer": "Ji, sara deshe."}, format="json")
        self.assertEqual(r.status_code, 201)

    def test_setup_exposes_g1_state(self):
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/setup")
        g = r.data["g1"]
        self.assertEqual((g["vision_ready"], g["voice_ready"], g["vision_credits"]),
                         (False, False, 6))
        self.assertEqual(r.data["settings"]["ai_mode"], "always")
        self.assertEqual(r.data["settings"]["resume_minutes"], 15)


@override_settings(BIZAGENT_SYNC=True)
class WhatsAppMediaParseTests(TestCase):
    def test_image_caption_and_media_id(self):
        p = wapayload("x", "wamid.img")
        m = p["entry"][0]["changes"][0]["value"]["messages"][0]
        m.pop("text")
        m["type"] = "image"
        m["image"] = {"id": "MEDIA1", "mime_type": "image/jpeg", "caption": "ei ta ache?"}
        ev = BZ.parse_whatsapp(p)[0]
        self.assertEqual(ev["text"], "ei ta ache?")
        self.assertEqual(ev["attachments"], [{"type": "image", "media_id": "MEDIA1",
                                              "mime": "image/jpeg"}])
