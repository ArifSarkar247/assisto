"""P1 — Business AI Agent tests: webhook signature (good/bad), idempotency,
24 h window, price/stock post-check, approval queue, human handover, order
extraction + real Order, courier clients (recorded fake responses, no
network), billing per reply + out-of-replies behaviour, trial once, Profit
Guard, seller-plan margin validation, WhatsApp billable charge, comments,
echo handover, Owner Admin seller page."""
import json
import os
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from cryptography.fernet import Fernet
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import bizagent_graph as G
from core import bizagent_service as S
from core import couriers as C
from core import integrations
from core.logic import bizagent as BZ
from core.logic import pricing
from core.models import (BizWebhookEvent, BusinessProfile, ChatThread, Message, Order,
                         OwnerPolicy, PricingConfig, Product, Sale, SellerChannel, User)

APP_SECRET = "test-app-secret-not-real"
PAGE = "1000000000001"
WA = "2000000000002"
IG = "3000000000003"
_KEY = Fernet.generate_key().decode()


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    integrations._FERNET = None


def tearDownModule():
    integrations._FERNET = None


class FakeGraph:
    def __init__(self):
        self.calls = []
        self.fail = False

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, body))
        if self.fail:
            return 400, {"error": {"message": "(#10) not allowed", "code": 10}}
        if url.endswith("/me?fields=id,name"):
            return 200, {"id": PAGE, "name": "Test Page"}
        if "fields=display_phone_number" in url:
            return 200, {"display_phone_number": "+880 000", "verified_name": "Test WA"}
        if url.endswith("/subscribed_apps"):
            return 200, {"success": True}
        if url.endswith("/comments") or url.endswith("/replies"):
            return 200, {"id": "pub_%d" % len(self.calls)}
        if "/messages" in url and body and body.get("messaging_product") == "whatsapp":
            return 200, {"messages": [{"id": "wamid.%d" % len(self.calls)}]}
        return 200, {"recipient_id": "x", "message_id": "m_%d" % len(self.calls)}

    def texts(self):
        out = []
        for _, _, b in self.calls:
            if not b:
                continue
            if "message" in b and isinstance(b["message"], dict):
                out.append(b["message"].get("text", ""))
            elif b.get("text"):
                out.append(b["text"].get("body", ""))
            elif "message" in b:
                out.append(b["message"])
        return out


def mpayload(text, mid, psid="u1", page=PAGE, ts=None):
    ts = ts or int(timezone.now().timestamp() * 1000)
    return {"object": "page", "entry": [{"id": page, "time": ts, "messaging": [
        {"sender": {"id": psid}, "recipient": {"id": page}, "timestamp": ts,
         "message": {"mid": mid, "text": text}}]}]}


def wapayload(text, wamid, frm="8801000000000", pnid=WA):
    return {"object": "whatsapp_business_account", "entry": [{"id": "WABA", "changes": [
        {"field": "messages", "value": {
            "messaging_product": "whatsapp",
            "metadata": {"phone_number_id": pnid},
            "contacts": [{"profile": {"name": "Rahim"}, "wa_id": frm}],
            "messages": [{"from": frm, "id": wamid, "timestamp": str(int(timezone.now().timestamp())),
                          "type": "text", "text": {"body": text}}]}}]}]}


@override_settings(BIZAGENT_SYNC=True)
class Base(TestCase):
    def setUp(self):
        integrations._FERNET = None
        integrations.save("meta_app", {"app_id": "111", "app_secret": APP_SECRET,
                                       "verify_token": "vtok"})
        self.fake = FakeGraph()
        self._prev = G.set_transport(self.fake)
        self.addCleanup(G.set_transport, self._prev)
        self.user = User.objects.create_user(email="seller@example.invalid", name="Seller",
                                             password="x")
        self.biz = BusinessProfile.objects.create(user=self.user, shop_name="Rupa Fashion")
        self.p = Product.objects.create(user=self.user, business=self.biz, name="Panjabi",
                                        price=Decimal("1200"), min_price=Decimal("1000"),
                                        stock=10, low_stock_at=3)
        self.p2 = Product.objects.create(user=self.user, business=self.biz, name="Saree",
                                         price=Decimal("2500"), min_price=Decimal("2200"),
                                         stock=0)
        OwnerPolicy.objects.create(user=self.user, business=self.biz,
                                   delivery_inside=Decimal("60"), delivery_outside=Decimal("120"))
        self.ch = SellerChannel.objects.create(business=self.biz, kind="messenger",
                                               external_id=PAGE, status="connected",
                                               token_enc=S.enc({"token": "PAGE_TOKEN"}))
        self.wa = SellerChannel.objects.create(business=self.biz, kind="whatsapp_cloud",
                                               external_id=WA, status="connected",
                                               token_enc=S.enc({"token": "WA_TOKEN"}))
        self.agent = S.agent_for(self.biz)
        self.agent.ai_enabled = True
        self.agent.plan = "starter"
        self.agent.period_start = timezone.now()
        self.agent.period_end = timezone.now() + timedelta(days=30)
        self.agent.save()
        self.c = APIClient()

    def post_meta(self, payload, secret=APP_SECRET, path="/api/v1/bizagent/webhook/meta"):
        raw = json.dumps(payload).encode()
        return self.c.post(path, data=raw, content_type="application/json",
                           HTTP_X_HUB_SIGNATURE_256=BZ.sign(secret, raw))

    def post_wa(self, payload, secret=APP_SECRET):
        return self.post_meta(payload, secret, "/api/v1/bizagent/webhook/whatsapp")

    def thread(self, ch=None):
        return ChatThread.objects.filter(seller_channel=ch or self.ch).first()

    def outs(self, t=None):
        return list((t or self.thread()).messages.filter(direction="out").order_by("id"))


# ------------------------------------------------------------------ webhook
class WebhookTests(Base):
    def test_handshake_good_and_bad(self):
        r = self.c.get("/api/v1/bizagent/webhook/meta",
                       {"hub.mode": "subscribe", "hub.verify_token": "vtok", "hub.challenge": "42"})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.content, b"42")
        r = self.c.get("/api/v1/bizagent/webhook/whatsapp",
                       {"hub.mode": "subscribe", "hub.verify_token": "nope", "hub.challenge": "42"})
        self.assertEqual(r.status_code, 403)

    def test_signature_good_and_bad(self):
        raw = b'{"object":"page"}'
        self.assertTrue(BZ.verify_signature("s", raw, BZ.sign("s", raw)))
        self.assertFalse(BZ.verify_signature("s", raw, BZ.sign("other", raw)))
        self.assertFalse(BZ.verify_signature("s", raw, ""))
        self.assertFalse(BZ.verify_signature("", raw, BZ.sign("", raw)))
        r = self.post_meta(mpayload("hi", "m1"), secret="wrong")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(Message.objects.count(), 0)
        r = self.post_meta(mpayload("hello", "m1"))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)

    def test_idempotent_by_message_id(self):
        self.post_meta(mpayload("Panjabi dam koto?", "mid.1"))
        self.post_meta(mpayload("Panjabi dam koto?", "mid.1"))
        self.assertEqual(BizWebhookEvent.objects.count(), 1)
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)
        self.assertEqual(Message.objects.filter(direction="out", is_ai=True).count(), 1)

    def test_price_question_mock_reply_with_disclosure_and_billing(self):
        self.post_meta(mpayload("Panjabi dam koto?", "mid.2"))
        out = self.outs()
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].status, "sent")
        self.assertIn("1200", out[0].text)
        self.assertEqual(out[0].text.count(BZ.bai.assistant_disclosure("bn")["short"]), 1)
        self.assertTrue(self.thread().ai_disclosed)
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.replies_used, 1)
        # the Graph Send API was called with the page token, RESPONSE type
        method, url, body = self.fake.calls[-1]
        self.assertIn("/%s/messages" % PAGE, url)
        self.assertEqual(body["messaging_type"], "RESPONSE")
        self.assertIn(G.GRAPH_VERSION, url)

    def test_whatsapp_message_and_statuses(self):
        self.post_wa(wapayload("Panjabi ache?", "wamid.in1"))
        t = self.thread(self.wa)
        self.assertEqual(t.customer_name, "Rahim")
        out = self.outs(t)
        self.assertEqual(out[-1].status, "sent")
        wamid = out[-1].external_id
        st = {"object": "whatsapp_business_account", "entry": [{"changes": [{"field": "messages",
              "value": {"metadata": {"phone_number_id": WA}, "statuses": [
                  {"id": wamid, "status": "delivered", "timestamp": "1", "recipient_id": "x"}]}}]}]}
        self.post_wa(st)
        out[-1].refresh_from_db()
        self.assertEqual(out[-1].status, "delivered")

    def test_unknown_account_is_ignored(self):
        self.post_meta(mpayload("hi", "m9", page="999"))
        self.assertEqual(Message.objects.count(), 0)
        self.assertEqual(BizWebhookEvent.objects.get().status, "done")

    def test_kill_switch_per_channel(self):
        row = PricingConfig.objects.get_or_create(key="global")[0]
        d = pricing.normalize(row.data)
        d["seller_agent"]["kill"]["messenger"] = True
        row.data = d
        row.save()
        self.post_meta(mpayload("Panjabi dam koto?", "mid.k"))
        self.assertEqual(len(self.outs()), 0)
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)

    def test_selftest_channel_own_secret_only(self):
        tch = SellerChannel.objects.create(business=self.biz, kind="messenger",
                                           external_id="990000000000001", status="connected",
                                           test_mode=True,
                                           test_secret_enc=S.enc({"secret": "tsecret"}))
        r = self.post_meta(mpayload("Panjabi koto?", "t1", page=tch.external_id), secret="tsecret")
        self.assertEqual(r.status_code, 200)
        t = ChatThread.objects.get(seller_channel=tch)
        self.assertEqual(self.outs(t)[0].status, "sent")
        self.assertTrue(self.outs(t)[0].meta.get("test_mode"))
        self.assertEqual(self.fake.calls, [])        # never sent to Graph
        # the test secret can NOT be used to inject into a real channel
        r = self.post_meta(mpayload("hi", "t2", page=PAGE), secret="tsecret")
        self.assertEqual(r.status_code, 403)


# ------------------------------------------------------------------ window
class WindowTests(Base):
    def test_outside_24h_blocked_and_template_only(self):
        self.post_wa(wapayload("hello", "wamid.w1"))
        t = self.thread(self.wa)
        t.last_inbound_at = timezone.now() - timedelta(hours=25)
        t.save()
        m = S.seller_send(t, "are you there?")
        self.assertEqual(m.status, "blocked")
        self.assertEqual(m.send_error, "outside_24h_window_template_required")
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/threads/%d/template" % t.id,
                        {"name": "order_update", "params": ["12"]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["message"]["status"], "sent")
        self.assertEqual(self.fake.calls[-1][2]["type"], "template")

    def test_messenger_outside_window_blocked(self):
        self.post_meta(mpayload("hello", "m.w2"))
        t = self.thread()
        t.last_inbound_at = timezone.now() - timedelta(hours=30)
        t.save()
        self.assertEqual(S.seller_send(t, "hi").send_error, "outside_24h_window")


# ------------------------------------------------------------------ post-check + approvals
class PostCheckTests(Base):
    def test_pure_number_check(self):
        ctx = S.context_for(self.biz, self.agent, "en")
        self.assertEqual(BZ.check_numbers("Panjabi is ৳1200, delivery ৳60.", ctx), [])
        bad = BZ.check_numbers("Panjabi is only ৳950 today!", ctx)
        self.assertEqual(bad[0]["type"], "money")
        self.assertEqual(BZ.check_numbers("We have 7 pcs left", ctx)[0]["type"], "stock")
        self.assertEqual(BZ.check_numbers("Saree is available now", ctx)[0]["type"], "stock_claim")
        self.assertEqual(BZ.check_numbers("১২০০ টাকা", ctx), [])

    def test_invented_price_blocked_to_approval(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Panjabi is only 900 taka!", "confidence": 0.9}):
            self.post_meta(mpayload("Panjabi er dam koto?", "m.pc"))
        outs = self.outs()
        self.assertEqual(outs[0].kind, "holding")
        self.assertEqual(outs[0].status, "sent")
        pend = Message.objects.get(status="pending_approval")
        self.assertEqual(pend.risk_reason, BZ.RISK_NUMBERS)
        self.assertNotIn("900", "".join(self.fake.texts()))
        # seller approves an edited reply → sent as a human message
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/approvals")
        self.assertEqual(len(r.data["approvals"]), 1)
        self.assertEqual(r.data["approvals"][0]["problems"][0]["value"], "900")
        r = self.c.post("/api/v1/bizagent/approvals/%d/approve" % pend.id,
                        {"text": "Panjabi ৳1200"}, format="json")
        self.assertTrue(r.data["ok"])
        self.assertEqual(Message.objects.filter(status="sent", is_ai=False,
                                                text="Panjabi ৳1200").count(), 1)
        r = self.c.post("/api/v1/bizagent/approvals/%d/approve" % pend.id, {}, format="json")
        self.assertEqual(r.status_code, 409)

    def test_correct_llm_reply_goes_out(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Panjabi ৳1200, delivery inside Dhaka ৳60.",
                                             "confidence": 0.9}):
            self.post_meta(mpayload("Panjabi dam?", "m.ok"))
        self.assertEqual(self.outs()[-1].status, "sent")
        self.assertFalse(Message.objects.filter(status="pending_approval").exists())

    def test_complaint_and_refund_and_unknown_product_queue(self):
        self.post_meta(mpayload("worst service, refund chai", "m.r1"))
        self.post_meta(mpayload("Lungi er dam koto?", "m.r2", psid="u2"))
        reasons = set(Message.objects.filter(status="pending_approval")
                      .values_list("risk_reason", flat=True))
        self.assertEqual(reasons, {BZ.RISK_REFUND, BZ.RISK_UNKNOWN_PRODUCT})

    def test_reject(self):
        self.post_meta(mpayload("refund chai", "m.rj"))
        pend = Message.objects.get(status="pending_approval")
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/approvals/%d/reject" % pend.id)
        self.assertTrue(r.data["ok"])
        pend.refresh_from_db()
        self.assertEqual(pend.status, "rejected")

    def test_bargain_below_min_goes_to_owner_never_below(self):
        self.post_meta(mpayload("Panjabi 800 te diben? discount", "m.b1"))
        pend = Message.objects.get(status="pending_approval")
        self.assertEqual(pend.risk_reason, BZ.RISK_BELOW_MIN)
        self.assertNotIn("800", "".join(self.fake.texts()))

    def test_bargain_at_or_above_min_accepted_and_used_in_order(self):
        self.post_meta(mpayload("Panjabi 1100 e diben? discount", "m.b2"))
        self.assertIn("1100", self.outs()[-1].text)
        self.assertEqual(self.thread().order_draft["agreed"]["price"], "1100")

    def test_approve_all_mode(self):
        self.agent.approve_all = True
        self.agent.save()
        with mock.patch.object(S, "_llm_draft", return_value={"text": "Hello!", "confidence": 0.9}):
            self.post_meta(mpayload("when do you open?", "m.aa"))
        self.assertEqual(Message.objects.get(status="pending_approval").risk_reason,
                         BZ.RISK_APPROVE_ALL)


# ------------------------------------------------------------------ handover
class HandoverTests(Base):
    def test_handover_pauses_ai_until_resumed(self):
        self.post_meta(mpayload("hello", "m.h1"))
        t = self.thread()
        n = len(self.outs())
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/threads/%d/handover" % t.id, {"on": True}, format="json")
        self.assertTrue(r.data["handover"])
        self.post_meta(mpayload("Panjabi dam?", "m.h2"))
        self.assertEqual(len(self.outs()), n)            # AI silent
        r = self.c.post("/api/v1/bizagent/threads/%d/send" % t.id, {"text": "Ami dekhchi"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        self.assertFalse(Message.objects.get(text="Ami dekhchi").is_ai)
        self.c.post("/api/v1/bizagent/threads/%d/handover" % t.id, {"on": False}, format="json")
        self.post_meta(mpayload("Panjabi dam?", "m.h3"))
        self.assertEqual(self.outs()[-1].is_ai, True)

    def test_page_inbox_echo_hands_over(self):
        self.post_meta(mpayload("hello", "m.e0"))
        echo = {"object": "page", "entry": [{"id": PAGE, "messaging": [
            {"sender": {"id": PAGE}, "recipient": {"id": "u1"}, "timestamp": 1,
             "message": {"mid": "m.echo1", "text": "I'm the owner", "is_echo": True,
                         "app_id": 999}}]}]}
        self.post_meta(echo)
        self.assertTrue(self.thread().owner_takeover)
        # our own echo (app_id = our app) is ignored
        echo["entry"][0]["messaging"][0]["message"].update(mid="m.echo2", app_id=111)
        self.post_meta(echo)
        self.assertFalse(Message.objects.filter(external_id="m.echo2").exists())

    def test_ai_off_only_records(self):
        self.agent.ai_enabled = False
        self.agent.save()
        self.post_meta(mpayload("Panjabi dam?", "m.off"))
        self.assertEqual(len(self.outs()), 0)


# ------------------------------------------------------------------ orders
class OrderTests(Base):
    def test_pure_extraction(self):
        cat = S.catalog_for(self.biz)
        d = BZ.extract_order("Panjabi 2 ta nibo", {}, cat)
        self.assertEqual((d["product"], d["qty"]), ("Panjabi", 2))
        d = BZ.extract_order("Name: Karim Uddin\nphone ০১৭১২-৩৪৫৬৭৮\naddress: House 5, Road 3, "
                             "Mirpur, Dhaka", d, cat)
        self.assertEqual(d["phone"], "01712345678")
        self.assertEqual(d["name"], "Karim Uddin")
        self.assertEqual(d["area"], "inside")
        self.assertIn("Mirpur", d["address"])
        self.assertEqual(BZ.missing_fields(d), [])
        self.assertEqual(BZ.normalize_bd_phone("+8801812345678"), "01812345678")
        self.assertEqual(BZ.normalize_bd_phone("01212345678"), "")
        self.assertEqual(BZ.detect_area("Savar, Dhaka"), "outside")
        self.assertEqual(BZ.find_qty("দুইটা দিবেন"), 2)
        bad = BZ.extract_order("phone 0171234", {"product": "x"}, cat)
        self.assertTrue(bad.get("phone_invalid"))

    def test_full_order_flow_creates_real_order(self):
        self.post_meta(mpayload("Panjabi 2 ta order korbo", "o1"))
        self.assertIn("XXXXXXXXX", self.outs()[-1].text)        # asks for details
        self.post_meta(mpayload("Name: Karim Uddin, phone 01712345678, address: House 5, "
                                "Road 3, Chittagong", "o2"))
        summary = self.outs()[-1].text
        self.assertIn("2400", summary)     # 2 × 1200
        self.assertIn("120", summary)      # outside Dhaka delivery
        self.assertIn("2520", summary)     # COD total
        self.post_meta(mpayload("yes", "o3"))
        o = Order.objects.get()
        self.assertEqual((o.status, o.total, o.area, o.payment), ("confirmed", Decimal("2520"),
                                                                  "outside", "cod"))
        self.assertEqual(o.business, self.biz)
        self.p.refresh_from_db()
        self.assertEqual(self.p.stock, 8)
        self.assertIsNotNone(o.invoice_sent_at)
        self.assertIn("#%d" % o.id, self.outs()[-1].text)
        self.assertEqual(self.thread().order_draft, {})
        # manual delivered → a real Sale in the books
        self.c.force_authenticate(self.user)
        self.c.post("/api/v1/bizagent/orders/%d/status" % o.id, {"status": "packed"}, format="json")
        o.status = "shipped"
        o.save()
        r = self.c.post("/api/v1/bizagent/orders/%d/status" % o.id, {"status": "delivered"},
                        format="json")
        self.assertTrue(r.data["sale_id"])
        self.assertEqual(Sale.objects.get().total, 252000)

    def test_out_of_stock_never_ordered(self):
        self.post_meta(mpayload("Saree 1 ta order korbo", "o9"))
        self.assertIn("out of stock" if "out" in self.outs()[-1].text else "স্টকে নেই",
                      self.outs()[-1].text)
        self.assertEqual(Order.objects.count(), 0)


# ------------------------------------------------------------------ couriers
class FakeCourier:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, method, url, headers, body):
        self.calls.append((method, url, headers, body))
        for frag, resp in self.responses:
            if frag in url:
                return resp
        return 404, {"message": "not found"}


PATHAO = {"client_id": "cid", "client_secret": "cs", "username": "m@example.invalid",
          "password": "pw", "store_id": "77", "sandbox": "yes"}


class CourierTests(Base):
    def _fake(self, resp):
        f = FakeCourier(resp)
        prev = C.set_transport(f)
        self.addCleanup(C.set_transport, prev)
        return f

    def test_pathao_token_create_status(self):
        f = self._fake([("/issue-token", (200, {"access_token": "T", "expires_in": 3600})),
                        ("/aladdin/api/v1/orders/CN1/info", (200, {"data": {"order_status": "Delivered"}})),
                        ("/aladdin/api/v1/orders", (200, {"data": {"consignment_id": "CN1",
                                                                     "order_status": "Pending",
                                                                     "delivery_fee": 60}}))])
        r = C.create("pathao", PATHAO, {"id": 5, "name": "K", "phone": "01712345678",
                                         "address": "House 5", "cod": "1260"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["consignment_id"], "CN1")
        self.assertTrue(f.calls[0][1].startswith(C.PATHAO_SANDBOX))
        self.assertEqual(f.calls[1][2]["Authorization"], "Bearer T")
        self.assertEqual(f.calls[1][3]["amount_to_collect"], 1260)
        s = C.status("pathao", PATHAO, "CN1")
        self.assertEqual(C.map_status(s["status"]), "delivered")

    def test_pathao_auth_error_honest(self):
        self._fake([("/issue-token", (401, {"message": "Invalid credentials"}))])
        r = C.create("pathao", PATHAO, {"id": 1, "name": "a", "phone": "0", "address": "b"})
        self.assertFalse(r["ok"])
        self.assertIn("Invalid credentials", r["error"])

    def test_steadfast_and_redx(self):
        f = self._fake([("/create_order", (200, {"status": 200, "consignment": {
            "consignment_id": 1424107, "tracking_code": "15BAEB8A", "status": "in_review"}})),
            ("/status_by_cid/1424107", (200, {"status": 200, "delivery_status": "delivered"})),
            ("/parcel/info/RX1", (200, {"parcel": {"tracking_id": "RX1", "status": "delivery-in-progress"}})),
            ("/parcel", (201, {"tracking_id": "RX1"}))])
        sf = {"api_key": "k", "secret_key": "s"}
        r = C.create("steadfast", sf, {"id": 9, "name": "K", "phone": "01712345678",
                                        "address": "x", "cod": "100"})
        self.assertEqual((r["ok"], r["tracking"]), (True, "15BAEB8A"))
        self.assertEqual(f.calls[0][2]["Api-Key"], "k")
        self.assertEqual(C.status("steadfast", sf, "1424107")["status"], "delivered")
        rx = {"access_token": "RT", "sandbox": "1"}
        r = C.create("redx", rx, {"id": 9, "name": "K", "phone": "01712345678", "address": "x",
                                  "cod": "100"})
        self.assertEqual(r["tracking"], "RX1")
        self.assertEqual(f.calls[-1][2]["API-ACCESS-TOKEN"], "Bearer RT")
        self.assertTrue(f.calls[-1][1].startswith(C.REDX_SANDBOX))
        self.assertEqual(C.map_status(C.status("redx", rx, "RX1")["status"]), "shipped")

    def test_no_key_never_fakes_a_booking(self):
        self.assertEqual(C.create("pathao", {}, {})["error"], "no_key")

    def test_book_and_poll_updates_customer_and_records_sale(self):
        o = Order.objects.create(user=self.user, business=self.biz, customer_name="K",
                                 customer_phone="01712345678", address="House 5",
                                 items=[{"product_id": self.p.id, "name": "Panjabi", "qty": 1,
                                         "price": "1200"}], total=Decimal("1260"),
                                 delivery_charge=Decimal("60"), status="confirmed",
                                 thread=None)
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/orders/%d/book" % o.id, {"courier": "steadfast"},
                        format="json")
        self.assertEqual(r.status_code, 409)       # no keys yet: honest
        self.assertEqual(r.data["error"], "no_key")
        r = self.c.post("/api/v1/bizagent/couriers/steadfast", {"api_key": "k", "secret_key": "s"},
                        format="json")
        self.assertTrue(r.data["couriers"]["steadfast"]["connected"])
        self._fake([("/create_order", (200, {"status": 200, "consignment": {
            "consignment_id": 55, "tracking_code": "TC55", "status": "in_review"}})),
            ("/status_by_cid/55", (200, {"status": 200, "delivery_status": "delivered"}))])
        r = self.c.post("/api/v1/bizagent/orders/%d/book" % o.id, {"courier": "steadfast"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        o.refresh_from_db()
        self.assertEqual((o.status, o.tracking, o.courier_live), ("shipped", "TC55", True))
        self.assertEqual(S.poll_couriers(), 1)
        o.refresh_from_db()
        self.assertEqual(o.status, "delivered")
        self.assertIsNotNone(o.sale_id)


# ------------------------------------------------------------------ billing
class BillingTests(Base):
    def test_plan_then_credits_then_polite_stop(self):
        a = self.agent
        a.replies_used = 1000            # starter quota used up
        a.save()
        self.user.ai_credits = 3         # exactly one ai_sales reply (3 credits)
        self.user.save()
        self.post_meta(mpayload("Panjabi dam?", "b1"))
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 0)
        self.assertEqual(self.outs()[-1].meta.get("billed"), "credits")
        self.post_meta(mpayload("Panjabi dam abar?", "b2"))
        last = self.outs()[-1]
        self.assertFalse(last.is_ai)
        self.assertEqual(last.text, BZ.out_of_replies_customer("bn"))
        # not repeated on the next message the same day
        self.post_meta(mpayload("hello?", "b3"))
        self.assertEqual(self.outs()[-1].id, last.id)

    def test_send_failure_refunds_plan_reply(self):
        self.fake.fail = True
        self.post_meta(mpayload("Panjabi dam?", "b4"))
        self.assertEqual(self.outs()[-1].status, "failed")
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.replies_used, 0)

    def test_trial_once_per_business_and_owner(self):
        self.agent.plan, self.agent.period_end = "none", None
        self.agent.save()
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/plan/trial")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["plan"], "trial")
        self.assertEqual(r.data["quota"], 100)
        r = self.c.post("/api/v1/bizagent/plan/trial")
        self.assertEqual(r.status_code, 409)

    def test_trial_profit_guard_pauses(self):
        a = self.agent
        a.plan, a.period_end, a.trial_started_at = "trial", timezone.now() + timedelta(days=7), timezone.now()
        a.save()
        with mock.patch("core.billing.guard_state", return_value={"over": True}):
            self.assertEqual(S.consume_reply(a), (None, "guard_over"))

    def test_seller_plan_margin_validation(self):
        base = pricing.DEFAULTS()
        self.assertEqual(pricing.validate_edit(base), [])
        bad = pricing.DEFAULTS()
        bad["seller_agent"]["plans"]["pro"]["price"] = 2000      # 3000 replies × ৳0.72 > 60%
        self.assertIn("seller_plan_breaks_margin", pricing.validate_edit(bad))
        rows = {r["plan"]: r for r in BZ.plan_margin_rows(pricing.normalize(base))}
        self.assertTrue(rows["starter"]["ok"])
        self.assertGreaterEqual(rows["pro"]["margin_pct"], 40)
        codes = [w["code"] for w in BZ.warnings(pricing.normalize(base))]
        self.assertIn("wa_cost_unset", codes)

    def test_whatsapp_billable_charged_once_with_margin(self):
        row = PricingConfig.objects.get_or_create(key="global")[0]
        d = pricing.normalize(row.data)
        d["seller_agent"]["wa_cost_bdt"]["marketing"] = 5.0
        row.data = d
        row.save()
        self.assertEqual(BZ.wa_charge_credits("marketing", pricing.normalize(d)), 7)  # ceil(5×1.4)
        self.user.ai_credits = 20
        self.user.save()
        st = {"object": "whatsapp_business_account", "entry": [{"changes": [{"field": "messages",
              "value": {"metadata": {"phone_number_id": WA}, "statuses": [
                  {"id": "wamid.T1", "status": "sent", "timestamp": "1", "recipient_id": "x",
                   "conversation": {"id": "CONV1", "origin": {"type": "marketing"}},
                   "pricing": {"billable": True, "pricing_model": "CBP",
                               "category": "marketing"}}]}}]}]}
        self.post_wa(st)
        st["entry"][0]["changes"][0]["value"]["statuses"][0]["id"] = "wamid.T2"
        self.post_wa(st)        # same conversation → no second charge
        self.user.refresh_from_db()
        self.assertEqual(self.user.ai_credits, 13)

    def test_seller_sku_in_payment_catalog(self):
        from core.payments import catalog
        self.assertEqual(catalog.base_price("seller_starter_monthly"), 1490)
        self.assertEqual(catalog.describe("seller_pro_monthly")["kind"], "seller")
        self.assertIsNone(catalog.base_price("seller_gold_monthly"))
        S.activate_plan_for_user(self.user, "pro")
        self.agent.refresh_from_db()
        self.assertEqual(self.agent.plan, "pro")
        self.assertEqual(S.plan_status(self.agent)["quota"], 3000)


# ------------------------------------------------------------------ comments + IG
class CommentTests(Base):
    def test_page_comment_private_and_public_reply(self):
        p = {"object": "page", "entry": [{"id": PAGE, "time": 1, "changes": [{"field": "feed",
             "value": {"item": "comment", "verb": "add", "comment_id": "POST_C1",
                       "post_id": "POST", "from": {"id": "u77", "name": "Nila"},
                       "message": "Panjabi price?"}}]}]}
        self.post_meta(p)
        bodies = [b for _, u, b in self.fake.calls]
        self.assertEqual(bodies[0]["recipient"], {"comment_id": "POST_C1"})
        self.assertIn("1200", bodies[0]["message"]["text"])
        self.assertTrue(self.fake.calls[1][1].endswith("/POST_C1/comments"))
        self.assertNotIn("1200", bodies[1]["message"])          # never a price in public

    def test_own_page_comment_skipped(self):
        p = {"object": "page", "entry": [{"id": PAGE, "changes": [{"field": "feed",
             "value": {"item": "comment", "verb": "add", "comment_id": "C2",
                       "from": {"id": PAGE}, "message": "thanks"}}]}]}
        self.post_meta(p)
        self.assertEqual(self.fake.calls, [])

    def test_instagram_dm(self):
        SellerChannel.objects.create(business=self.biz, kind="instagram", external_id=IG,
                                     status="connected", token_enc=S.enc({"token": "IGT"}))
        p = {"object": "instagram", "entry": [{"id": IG, "time": 1, "messaging": [
            {"sender": {"id": "igu"}, "recipient": {"id": IG}, "timestamp": int(timezone.now().timestamp() * 1000),
             "message": {"mid": "ig.1", "text": "Panjabi price?"}}]}]}
        self.post_meta(p)
        self.assertEqual(ChatThread.objects.get(external_user_id="igu").channel, "instagram")
        self.assertIn("/me/messages", self.fake.calls[-1][1])


# ------------------------------------------------------------------ setup API + reports
class SetupApiTests(Base):
    def test_setup_and_connect_flow(self):
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/setup")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["catalog"]["products"], 2)
        self.assertEqual(r.data["catalog"]["low_stock"][0]["name"], "Saree")
        self.assertTrue(r.data["meta_ready"]["secret"])
        self.assertNotIn("PAGE_TOKEN", json.dumps(r.data))     # tokens never returned
        r = self.c.post("/api/v1/bizagent/channels", {"kind": "messenger", "external_id": "4000000004",
                                                       "token": "NEWTOKEN"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["channel"]["display_name"], "Test Page")
        self.fake.fail = True
        r = self.c.post("/api/v1/bizagent/channels", {"kind": "whatsapp_cloud",
                                                       "external_id": "5000000005", "token": "BAD"},
                        format="json")
        self.assertEqual(r.data["channel"]["status"], "error")
        self.assertIn("not allowed", r.data["channel"]["status_detail"])
        r = self.c.post("/api/v1/bizagent/settings", {"tone": "formal", "delivery_inside": "70",
                                                       "hours": {"start": "10:00", "end": "22:00"}},
                        format="json")
        self.assertEqual(r.data["settings"]["delivery_inside"], "70.00")
        self.assertEqual(r.data["settings"]["hours"]["start"], "10:00")
        r = self.c.post("/api/v1/bizagent/settings", {"hours": {"start": "x"}}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_other_business_channel_refused(self):
        u2 = User.objects.create_user(email="other@example.invalid", password="x")
        BusinessProfile.objects.create(user=u2)
        self.c.force_authenticate(u2)
        r = self.c.post("/api/v1/bizagent/channels", {"kind": "messenger", "external_id": PAGE,
                                                       "token": "T"}, format="json")
        self.assertEqual(r.status_code, 409)
        r = self.c.get("/api/v1/bizagent/threads/%d" % 999)
        self.assertEqual(r.status_code, 404)

    def test_daily_report_and_low_stock(self):
        self.post_meta(mpayload("Panjabi dam?", "r1"))
        self.assertEqual(S.run_daily_reports(), 1)
        self.assertEqual(S.run_daily_reports(), 0)       # once per day
        self.c.force_authenticate(self.user)
        r = self.c.get("/api/v1/bizagent/reports")
        self.assertEqual(r.data["history"][0]["messages"], 1)
        self.assertEqual(S.run_low_stock(), 1)
        self.assertEqual(S.run_low_stock(), 0)           # max once a day
        rep = BZ.daily_report("en", r.data["today"])
        self.assertIn("Low stock", rep["body"])

    def test_pending_sweep_processes_left_overs(self):
        S.ingest("meta", mpayload("hello", "sw1"))
        self.assertEqual(Message.objects.count(), 0)
        self.assertEqual(S.process_pending(), 1)
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)
