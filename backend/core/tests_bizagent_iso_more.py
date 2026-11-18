"""bizagent-iso3 (owner: proof that shop A can never see or use shop B's
data anywhere) — the 4 isolation items the audit found uncovered:
 (3) a comment on ANOTHER shop's post, (4) photo matching across shops,
 (9) staff access (A's staff can't touch B; A's staff limited to A and to
     what staff may do), (10) the website chat key (A's key can't read or
     write B's chats).
Made-up sample data only."""
import json

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from rest_framework.test import APIClient

from core import bizagent_g1_service as G1S
from core import bizagent_media as M
from core import bizagent_service as S
from core.models import (BizProductSig, BusinessStaff, ChatThread, Message, SellerChannel,
                         User)
from core.tests_bizagent_iso_scope import (B_CUST, B_MSG, B_PRICE, B_PRODUCT,  # noqa: F401
                                           TwoShops, setUpModule, tearDownModule)
from core.tests_g1_bizagent import _png
from core.tests_p1_bizagent import PAGE, mpayload
from core.testing_tmp import TempDirMixin  # a temp dir per class, never at import

B_PAGE = "8800000008"
V = "/api/v1/bizagent/"


def comment(page, cid, post_id, text, frm="u55"):
    return {"object": "page", "entry": [{"id": page, "time": 1, "changes": [{"field": "feed",
            "value": {"item": "comment", "verb": "add", "comment_id": cid,
                      "post_id": post_id, "from": {"id": frm, "name": "Nila"},
                      "message": text}}]}]}


# ============================================================ (3) comments
class CommentIsolationTests(TwoShops):
    def setUp(self):
        super().setUp()
        from core.tests_salesbar import set_meta_access
        set_meta_access(comments_fb=True, comments_ig=True)

    def test_comment_on_b_page_never_reaches_a(self):
        self.post_meta(comment(B_PAGE, "B_C1", "post_b", "dam koto?"))
        self.assertFalse(ChatThread.objects.filter(business=self.biz,
                                                   external_user_id__startswith="comment:")
                         .exists())
        t = ChatThread.objects.get(external_user_id="comment:u55")
        self.assertEqual(t.business_id, self.b2.id)

    def test_comment_on_a_page_naming_b_post_uses_only_a_catalog(self):
        # A's page, but the post id is B's linked post: B's product / price
        # must never be used for A's reply
        self.post_meta(comment(PAGE, "A_C1", "post_b", "dam koto? price?"))
        sent = json.dumps([b for _, _, b in self.fake.calls], ensure_ascii=False)
        for m in (B_PRODUCT, B_PRICE):
            self.assertNotIn(m, sent)
        t = ChatThread.objects.get(external_user_id="comment:u55")
        self.assertEqual(t.business_id, self.biz.id)
        self.assertClean([m.text for m in t.messages.filter(direction="out")], "A reply")
        self.assertIsNone(G1S.post_product(self.biz, S.catalog_for(self.biz), "post_b"))

    def test_post_link_to_b_product_is_refused(self):
        r = self.c.post(V + "post-links", {"post_id": "123_456", "product_id": self.p2b.pk},
                        format="json")
        self.assertEqual(r.status_code, 404)
        self.assertFalse(self.biz.biz_post_links.exists())


# ============================================================ (4) photos
class PhotoIsolationTests(TempDirMixin, TwoShops):

    def setUp(self):
        super().setUp()
        self.p2b.photo = SimpleUploadedFile("b.png", _png((200, 30, 30)), "image/png")
        self.p2b.save()
        self.p.photo = SimpleUploadedFile("a.png", _png((30, 160, 60), "stripes"), "image/png")
        self.p.save()

    def test_b_photo_never_matches_for_a(self):
        b_photo = _png((200, 30, 30))
        a_ids = {p.id for p, _ in M.product_sigs(self.biz)}
        self.assertNotIn(self.p2b.id, a_ids)
        self.assertNotIn(self.p2b.id, [pid for _, pid in M.visual_matches(self.biz, b_photo)])
        # B itself does match its own photo (the test can fail)
        self.assertEqual(M.visual_matches(self.b2, b_photo)[0][1], self.p2b.id)
        # A's matching never created / touched B's cached signature
        self.assertEqual(set(BizProductSig.objects.filter(product__business=self.biz)
                             .values_list("product_id", flat=True)) & {self.p2b.id}, set())


# ============================================================ (9) staff
class StaffIsolationTests(TwoShops):
    def setUp(self):
        super().setUp()
        self.post_meta(mpayload("Panjabi dam koto?", "st.1"))      # A has a chat
        self.staff = User.objects.create_user(email="staffa@example.invalid", password="x")
        self.mem = BusinessStaff.objects.create(business=self.biz, member=self.staff,
                                                role="staff")
        self.s = APIClient()
        self.s.force_authenticate(self.staff)

    def q(self, biz):
        return "?business=%d" % biz.id

    def test_staff_of_a_sees_only_a(self):
        r = self.s.get(V + "threads" + self.q(self.biz))
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data)
        self.assertClean(r.data, "staff threads")
        r = self.s.get(V + "inbox" + self.q(self.biz) + "&q=" + B_CUST[:6])
        self.assertClean(r.data, "staff inbox search")

    def test_staff_of_a_cannot_open_b(self):
        for path in ("threads", "inbox", "approvals", "faqs"):
            r = self.s.get(V + path + self.q(self.b2))
            self.assertEqual(r.status_code, 403, path)
            self.assertClean(r.data, path)
        # B's ids through A's business → 404, never B's data
        r = self.s.get(V + "threads/%d" % self.t_b.pk + self.q(self.biz))
        self.assertEqual(r.status_code, 404)
        r = self.s.post(V + "threads/%d/send" % self.t_b.pk + self.q(self.biz),
                        {"text": "hi"}, format="json")
        self.assertEqual(r.status_code, 404)
        r = self.s.post(V + "approvals/%d/approve" % self.m_b.pk + self.q(self.biz), {},
                        format="json")
        self.assertEqual(r.status_code, 404)
        self.m_b.refresh_from_db()
        self.assertEqual(self.m_b.status, "pending_approval")
        self.assertFalse(Message.objects.filter(thread=self.t_b, text="hi").exists())

    def test_staff_cannot_do_owner_only_things(self):
        for path, body in (("channels", {"kind": "messenger", "external_id": "123",
                                         "token": "t"}),
                           ("settings", {"tone": "formal"}),
                           ("faqs", {"question": "q??", "answer": "aa"})):
            r = self.s.post(V + path + self.q(self.biz), body, format="json")
            self.assertEqual(r.status_code, 403, path)
        self.assertEqual(self.s.get(V + "unknown" + self.q(self.biz)).status_code, 403)
        self.assertEqual(self.s.get(V + "audit" + self.q(self.biz)).status_code, 403)

    def test_removed_staff_loses_access(self):
        self.mem.active = False
        self.mem.save()
        self.assertEqual(self.s.get(V + "threads" + self.q(self.biz)).status_code, 403)

    def test_staff_without_business_param_sees_neither_shop(self):
        r = self.s.get(V + "threads")
        self.assertLess(r.status_code, 500)
        self.assertClean(r.data, "staff own")
        self.assertNotIn("Panjabi dam koto", json.dumps(r.data, ensure_ascii=False))


# ============================================================ (10) widget key
class WidgetIsolationTests(TwoShops):
    VIS = "visitor_shared_123456"

    def setUp(self):
        super().setUp()
        self.ka = self._enable(self.biz, "https://a.example")
        self.kb = self._enable(self.b2, "https://b.example")
        chb = G1S.widget_channel(self.b2)
        tb = ChatThread.objects.create(user=self.u2, business=self.b2, seller_channel=chb,
                                       external_user_id=self.VIS, channel="website",
                                       customer_name=B_CUST)
        Message.objects.create(thread=tb, direction="out", text=B_MSG, status="sent")
        Message.objects.create(thread=tb, direction="in", text=B_MSG, status="received")
        self.tb = tb
        self.w = APIClient()

    def _enable(self, biz, origin):
        a = S.agent_for(biz)
        G1S.ensure_widget_key(a)
        a.widget_enabled = True
        a.widget_origins = origin
        a.save()
        return a.widget_key

    def test_a_key_cannot_read_b_chat_even_with_same_visitor(self):
        r = self.w.get(V + "widget/%s/messages?visitor=%s" % (self.ka, self.VIS),
                       HTTP_ORIGIN="https://a.example")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["messages"], [])
        self.assertClean(r.json(), "widget read")

    def test_a_key_writes_only_into_a(self):
        n_b = self.tb.messages.count()
        r = self.w.post(V + "widget/%s/send" % self.ka,
                        json.dumps({"visitor": self.VIS, "text": "Panjabi dam koto?"}),
                        content_type="application/json", HTTP_ORIGIN="https://a.example")
        self.assertEqual(r.status_code, 200)
        self.assertClean(r.json(), "widget send")
        self.assertEqual(self.tb.messages.count(), n_b)            # B's chat untouched
        ta = ChatThread.objects.get(business=self.biz, channel="website",
                                    external_user_id=self.VIS)
        self.assertNotEqual(ta.pk, self.tb.pk)

    def test_b_key_from_a_site_and_unknown_key_refused(self):
        r = self.w.get(V + "widget/%s/messages?visitor=%s" % (self.kb, self.VIS),
                       HTTP_ORIGIN="https://a.example")
        self.assertEqual(r.status_code, 403)
        self.assertNotIn(B_MSG, r.content.decode())
        r = self.w.get(V + "widget/w_not_a_real_key/messages?visitor=" + self.VIS,
                       HTTP_ORIGIN="https://a.example")
        self.assertEqual(r.status_code, 404)

    def test_website_channel_lookup_is_owner_scoped(self):
        # a website row carrying A's id but owned by B (should never exist) is
        # never handed to A
        SellerChannel.objects.filter(business=self.biz, kind="website").delete()
        SellerChannel.objects.create(business=self.b2, kind="website",
                                     external_id="web%d" % self.biz.pk, status="connected")
        self.assertIsNone(G1S.widget_channel(self.biz))
        r = self.w.get(V + "widget/%s/messages?visitor=%s" % (self.ka, self.VIS),
                       HTTP_ORIGIN="https://a.example")
        self.assertEqual(r.status_code, 404)
