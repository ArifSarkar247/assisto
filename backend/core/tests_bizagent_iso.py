"""bizagent-iso (P0): channel isolation for the Business AI Agent.

A business can connect a Messenger page / IG account / WhatsApp number ONLY
when the token proves it owns that id; nothing is saved on a mismatch or a
Graph error; inbound goes only to a connected + enabled channel; disconnect
unsubscribes the page; status / echo lookups never touch another shop's
messages; a squatter's unverified claim is replaced by the verified owner;
unsigned / wrongly signed webhooks are refused."""
from unittest import mock

from core import bizagent_graph as G
from core.models import (BizWebhookEvent, BusinessProfile, ChatThread, Message,
                         SellerChannel, User)
from core.tests_p1_bizagent import (APP_SECRET, IG, PAGE, WA, Base, mpayload,  # noqa: F401
                                    setUpModule, tearDownModule, wapayload)

CH_URL = "/api/v1/bizagent/channels"


def wa_status(wamid, status, pnid=WA):
    return {"object": "whatsapp_business_account", "entry": [{"id": "WABA", "changes": [
        {"field": "messages", "value": {
            "messaging_product": "whatsapp", "metadata": {"phone_number_id": pnid},
            "statuses": [{"id": wamid, "status": status, "timestamp": "1700000000",
                          "recipient_id": "8801000000000"}]}}]}]}


def echo(mid, page=PAGE, psid="u9"):
    return {"object": "page", "entry": [{"id": page, "messaging": [
        {"sender": {"id": page}, "recipient": {"id": psid}, "timestamp": 1,
         "message": {"mid": mid, "text": "owner reply", "is_echo": True, "app_id": 999}}]}]}


class IsoBase(Base):
    def other_biz(self, email="other@example.invalid"):
        u = User.objects.create_user(email=email, password="x")
        return u, BusinessProfile.objects.create(user=u, shop_name="Other Shop")

    def connect(self, kind, ext, token="TOK"):
        self.c.force_authenticate(self.user)
        return self.c.post(CH_URL, {"kind": kind, "external_id": ext, "token": token},
                           format="json")


class ConnectOwnershipTests(IsoBase):
    def test_messenger_wrong_id_is_422_and_no_row(self):
        self.fake.me_id = "4000000004"                 # the token's real page
        r = self.connect("messenger", "4000000099")    # someone else's page
        self.assertEqual((r.status_code, r.data["error"]), (422, "not_owner"))
        self.assertFalse(SellerChannel.objects.filter(external_id="4000000099").exists())
        self.assertFalse(any(u.endswith("/subscribed_apps") for _, u, _ in self.fake.calls))

    def test_messenger_graph_error_is_422_and_no_row(self):
        self.fake.fail = True
        r = self.connect("messenger", "4000000004")
        self.assertEqual((r.status_code, r.data["error"]), (422, "token_invalid"))
        self.assertFalse(SellerChannel.objects.filter(external_id="4000000004").exists())

    def test_messenger_right_id_connects(self):
        self.fake.me_id = "4000000004"
        r = self.connect("messenger", "4000000004")
        self.assertEqual(r.status_code, 201, r.data)
        ch = SellerChannel.objects.get(external_id="4000000004")
        self.assertEqual((ch.business_id, ch.status), (self.biz.id, "connected"))

    def test_instagram_ownership(self):
        self.fake.ig_id = "3000000077"
        r = self.connect("instagram", "3000000088")
        self.assertEqual((r.status_code, r.data["error"]), (422, "not_owner"))
        self.assertFalse(SellerChannel.objects.filter(kind="instagram").exists())
        r = self.connect("instagram", "3000000077")
        self.assertEqual(r.status_code, 201, r.data)

    def test_whatsapp_number_mismatch_is_422(self):
        wrong = {"ok": True, "status": 200, "error": "", "id": "",
                 "json": {"id": "5000000001", "verified_name": "Other"}}
        with mock.patch.object(G, "whatsapp_number_info", return_value=wrong):
            r = self.connect("whatsapp_cloud", "5000000005")
        self.assertEqual((r.status_code, r.data["error"]), (422, "not_owner"))
        self.assertFalse(SellerChannel.objects.filter(external_id="5000000005").exists())

    def test_taken_id_hidden_from_unverified_prober(self):
        u2, _ = self.other_biz()
        self.c.force_authenticate(u2)
        self.fake.me_id = "4000000004"                 # u2's token does not own PAGE
        r = self.c.post(CH_URL, {"kind": "messenger", "external_id": PAGE, "token": "T"},
                        format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "not_owner"))
        self.assertNotIn("Rupa", str(r.data))
        self.assertEqual(SellerChannel.objects.get(external_id=PAGE).business_id, self.biz.id)

    def test_squatter_replaced_by_verified_owner(self):
        _, squat_biz = self.other_biz()
        squat = SellerChannel.objects.create(business=squat_biz, kind="messenger",
                                             external_id="4000000009", status="error")
        ChatThread.objects.create(user=squat_biz.user, business=squat_biz, seller_channel=squat,
                                  external_user_id="x1", channel="messenger")
        self.fake.me_id = "4000000009"
        r = self.connect("messenger", "4000000009")
        self.assertEqual(r.status_code, 201, r.data)
        ch = SellerChannel.objects.get(kind="messenger", external_id="4000000009")
        self.assertEqual((ch.business_id, ch.status), (self.biz.id, "connected"))
        # the squatter's old chat stays theirs but is no longer on the channel
        t = ChatThread.objects.get(external_user_id="x1")
        self.assertEqual((t.business_id, t.seller_channel_id), (squat_biz.id, None))

    def test_connected_other_business_still_409(self):
        u2, _ = self.other_biz()
        self.c.force_authenticate(u2)
        r = self.c.post(CH_URL, {"kind": "messenger", "external_id": PAGE, "token": "T"},
                        format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "channel_taken"))


class RoutingTests(IsoBase):
    def test_pending_error_disabled_rows_get_no_inbound(self):
        _, b2 = self.other_biz()
        for i, (st, on) in enumerate((("pending", True), ("error", True), ("disabled", True),
                                      ("connected", False))):
            ext = "70000000%02d" % i
            SellerChannel.objects.create(business=b2, kind="messenger", external_id=ext,
                                         status=st, enabled=on)
            self.post_meta(mpayload("my phone 01700000000", "iso.m%d" % i, page=ext))
        self.assertFalse(ChatThread.objects.filter(business=b2).exists())
        self.assertFalse(Message.objects.filter(thread__business=b2).exists())
        self.assertEqual(BizWebhookEvent.objects.filter(error="no_channel").count(), 4)

    def test_connected_channel_still_gets_inbound(self):
        self.post_meta(mpayload("hello", "iso.ok"))
        self.assertTrue(Message.objects.filter(thread__seller_channel=self.ch,
                                               external_id="iso.ok").exists())


class DeleteTests(IsoBase):
    def test_delete_unsubscribes_page(self):
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/channels/%d/delete" % self.ch.pk)
        self.assertEqual(r.status_code, 200)
        self.assertIn(("DELETE", "%s/%s/subscribed_apps" % (G.base_url(), PAGE)),
                      [(m, u) for m, u, _ in self.fake.calls])
        self.assertFalse(SellerChannel.objects.filter(pk=self.ch.pk).exists())

    def test_delete_still_works_when_unsubscribe_fails(self):
        self.fake.fail = True
        self.c.force_authenticate(self.user)
        r = self.c.post("/api/v1/bizagent/channels/%d/delete" % self.ch.pk)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(SellerChannel.objects.filter(pk=self.ch.pk).exists())


class CrossBusinessTests(IsoBase):
    def setUp(self):
        super().setUp()
        _, self.b2 = self.other_biz()
        self.ch2 = SellerChannel.objects.create(business=self.b2, kind="whatsapp_cloud",
                                                external_id="6000000006", status="connected")
        self.t2 = ChatThread.objects.create(user=self.b2.user, business=self.b2,
                                            seller_channel=self.ch2, external_user_id="88017",
                                            channel="whatsapp_cloud")
        self.m2 = Message.objects.create(thread=self.t2, direction="out", text="theirs",
                                         external_id="wamid.SHARED", status="sent")

    def test_status_cannot_touch_other_channel_message(self):
        self.post_wa(wa_status("wamid.SHARED", "failed"))        # arrives on OUR number
        self.m2.refresh_from_db()
        self.assertEqual((self.m2.status, self.m2.send_error), ("sent", ""))

    def test_status_updates_own_message(self):
        t = ChatThread.objects.create(user=self.user, business=self.biz, seller_channel=self.wa,
                                      external_user_id="88019", channel="whatsapp_cloud")
        m = Message.objects.create(thread=t, direction="out", text="ours",
                                   external_id="wamid.OWN", status="sent")
        self.post_wa(wa_status("wamid.OWN", "delivered"))
        m.refresh_from_db()
        self.assertEqual(m.status, "delivered")

    def test_echo_dedupe_is_per_channel(self):
        Message.objects.create(thread=self.t2, direction="out", text="theirs",
                               external_id="m.SHAREDECHO", status="sent")
        self.post_meta(echo("m.SHAREDECHO"))
        self.assertTrue(Message.objects.filter(thread__seller_channel=self.ch,
                                               external_id="m.SHAREDECHO").exists())
        self.assertEqual(Message.objects.filter(thread=self.t2).count(), 2)


class SignatureTests(IsoBase):
    def test_meta_and_whatsapp_need_a_valid_signature(self):
        for path, payload in (("/api/v1/bizagent/webhook/meta", mpayload("hi", "sig.m1")),
                              ("/api/v1/bizagent/webhook/whatsapp",
                               wapayload("hi", "wamid.SIG1"))):
            r = self.post_meta(payload, secret="wrong-secret", path=path)
            self.assertEqual(r.status_code, 403)
            r = self.c.post(path, data=b'{"object": "page"}', content_type="application/json")
            self.assertEqual(r.status_code, 403)
        self.assertEqual(BizWebhookEvent.objects.count(), 0)
        self.assertEqual(self.post_meta(mpayload("hi", "sig.m2")).status_code, 200)
        self.assertEqual(self.post_wa(wapayload("hi", "wamid.SIG2")).status_code, 200)
        self.assertEqual(BizWebhookEvent.objects.count(), 2)
