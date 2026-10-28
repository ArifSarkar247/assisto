"""crm100 — one customer history page, shop quote → accept page, send from
CRM. History: aggregation over every source + own-data-only permissions +
paging + 500-customer query budget. Quotes: catalog-only prices, the
seller's floor, signed-token security, expiry, accept → ONE order
(idempotent, stock, payment status), decline, rate limit, bn/en, noindex.
Send: links logged as "opened" (never "sent"), Assisto SMS credits shown
first + charged + STOP / quiet hours / caps, owner-only, own customers only,
bulk = per-customer cards. SMS + push are mocked at their seams."""
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.models import (BusinessProfile, BusinessStaff, ChatThread, Customer,
                         KhataEntry, KhataParty, Message as ChatMessage, Order, Product,
                         ProductVariant, Sale, SmsLog, User)
from core.tests_smsotp import alpha_ok, connect, set_cfg

from . import customer360 as C
from . import shop_quote as SQ
from .models import (Activity, CrmMember, CrmOrg, CustomerMessage, Deal, Lead, Pipeline,
                     ShopQuote, Stage)

A = "/api/v1/crm"
_n = [0]


def _phone():
    _n[0] += 1
    return "+88019%08d" % (31000000 + _n[0])


class _World(APITestCase):
    def setUp(self):
        cache.clear()
        self.owner = User.objects.create_user(name="Owner", phone=_phone(), password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.client.force_authenticate(self.owner)
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712-345678")
        self.org = CrmOrg.objects.create(name="Rahim CRM", owner=self.owner)
        CrmMember.objects.create(org=self.org, user=self.owner, role=CrmMember.OWNER)
        self.saree = Product.objects.create(user=self.owner, business=self.biz,
                                            name="Red saree", price=Decimal("1500"),
                                            min_price=Decimal("1200"), stock=5)

    def entry(self, poisha, direction="gave", party=None, at=None):
        return KhataEntry.objects.create(party=party or self.party, direction=direction,
                                         amount_poisha=poisha, at=at or timezone.now())


# ====================================================================== history
class HistoryTests(_World):
    def _seed_everything(self):
        self.entry(150000)
        self.entry(65000, "got")
        cust = Customer.objects.create(user=self.owner, business=self.biz, name="Karim",
                                       phone="+8801712345678", phone_key="01712345678")
        Sale.objects.create(user=self.owner, business=self.biz, customer=cust,
                            total=50000, paid=30000, due=20000, payment_method="due")
        Order.objects.create(user=self.owner, business=self.biz, customer_name="Karim",
                             customer_phone="8801712345678", total=Decimal("2500"),
                             status="returned", payment="cod", items=[{"name": "Saree"}])
        Order.objects.create(user=self.owner, business=self.biz, customer_name="Karim",
                             customer_phone="01712345678", total=Decimal("1800"),
                             status="confirmed", payment="cod",
                             payment_status="pending_verification")
        th = ChatThread.objects.create(user=self.owner, business=self.biz,
                                       customer_phone="01712345678", channel="messenger",
                                       last_message_at=timezone.now())
        ChatMessage.objects.create(thread=th, direction="in", text="লাল শাড়ি আছে?")
        lead = Lead.objects.create(org=self.org, name="Karim", phone="01712345678")
        pipe = Pipeline.objects.create(org=self.org, name="Sales", is_default=True)
        st = Stage.objects.create(pipeline=pipe, name="New", order=0)
        Deal.objects.create(org=self.org, title="Eid order", lead=lead, pipeline=pipe,
                            stage=st, value=Decimal("5000"))
        Activity.objects.create(org=self.org, lead=lead, kind="task", subject="Call back")
        Activity.objects.create(org=self.org, lead=lead, kind="note", body="likes red")
        return lead

    def test_one_page_has_every_source_and_honest_summary(self):
        lead = self._seed_everything()
        r = self.client.get(A + "/customers/history/?phone=01712345678")
        self.assertEqual(r.status_code, 200, r.data)
        s = r.data["summary"]
        self.assertEqual(s["khata_due_poisha"], 85000)
        self.assertEqual(s["orders_count"], 2)
        self.assertEqual(s["orders_returned"], 1)
        self.assertEqual(s["orders_open"], 1)
        self.assertEqual(s["orders_cod_to_collect_poisha"], 180000)
        self.assertEqual(s["orders_payment_to_check"], 1)
        self.assertEqual((s["sales_count"], s["sales_due_poisha"]), (1, 20000))
        self.assertEqual(s["chats_count"], 1)
        self.assertEqual(s["deals_open"], 1)
        self.assertEqual(s["tasks_open"], 1)
        self.assertEqual([l["id"] for l in s["leads"]], [lead.id])
        self.assertEqual(s["name"], "Karim")
        kinds = {i["kind"] for i in r.data["items"]}
        self.assertTrue({"khata", "sale", "order", "chat", "lead", "deal", "activity"} <= kinds)
        chat = next(i for i in r.data["items"] if i["kind"] == "chat")
        self.assertEqual(chat["last_text"], "লাল শাড়ি আছে?")
        ats = [i["at"] for i in r.data["items"]]
        self.assertEqual(ats, sorted(ats, reverse=True))

    def test_same_person_any_phone_format_and_any_anchor(self):
        self._seed_everything()
        for q in ("phone=%2B8801712345678", "phone=01712-345678", "party=%d" % self.party.pk):
            r = self.client.get(A + "/customers/history/?" + q)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.data["summary"]["orders_count"], 2, q)

    def test_party_without_phone_is_still_shown_alone(self):
        p = KhataParty.objects.create(business=self.biz, book="customer", name="No phone")
        self.entry(1000, party=p)
        r = self.client.get(A + "/customers/history/?party=%d" % p.pk)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["summary"]["khata_due_poisha"], 1000)
        self.assertEqual(r.data["summary"]["orders_count"], 0)

    def test_empty_customer_honest(self):
        r = self.client.get(A + "/customers/history/?phone=01811111111")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["items"], [])
        self.assertEqual(r.data["summary"]["sources"], [])
        self.assertIsNone(r.data["next_before"])

    def test_other_shop_data_never_leaks(self):
        self._seed_everything()
        other = User.objects.create_user(name="Other", phone=_phone(), password="pw123456")
        ob = BusinessProfile.objects.create(user=other, shop_name="Other shop")
        op = KhataParty.objects.create(business=ob, book="customer", name="Karim",
                                       phone="01712345678")
        KhataEntry.objects.create(party=op, direction="gave", amount_poisha=999900,
                                  at=timezone.now())
        Order.objects.create(user=other, business=ob, customer_phone="01712345678",
                             total=Decimal("99"))
        r = self.client.get(A + "/customers/history/?phone=01712345678")
        self.assertEqual(r.data["summary"]["khata_due_poisha"], 85000)
        self.assertEqual(r.data["summary"]["orders_count"], 2)
        # the other shop sees only its own
        c = APIClient()
        c.force_authenticate(other)
        r2 = c.get(A + "/customers/history/?phone=01712345678")
        self.assertEqual(r2.data["summary"]["khata_due_poisha"], 999900)
        self.assertEqual(r2.data["summary"]["leads"], [])
        # a party / lead id of another shop is a 404, never data
        self.assertEqual(c.get(A + "/customers/history/?party=%d" % self.party.pk)
                         .status_code, 404)
        lead = Lead.objects.filter(org=self.org).first()
        self.assertEqual(c.get(A + "/customers/history/?lead=%d" % lead.pk).status_code, 404)
        # ?business= of a shop you don't belong to is refused
        self.assertEqual(c.get(A + "/customers/history/?phone=017&business=%d" % self.biz.pk)
                         .status_code, 403)

    def test_staff_sees_customer_book_not_suppliers(self):
        self._seed_everything()
        staff = User.objects.create_user(name="Staff", phone=_phone(), password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        sup = KhataParty.objects.create(business=self.biz, book="supplier", name="Supplier",
                                        phone="01712345678")
        KhataEntry.objects.create(party=sup, direction="got", amount_poisha=777700,
                                  at=timezone.now())
        c = APIClient()
        c.force_authenticate(staff)
        r = c.get(A + "/customers/history/?phone=01712345678&business=%d" % self.biz.pk)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["summary"]["khata_due_poisha"], 85000)
        self.assertEqual(r.data["summary"]["role"], "staff")
        self.assertEqual(r.data["summary"]["leads"], [])          # not a CRM member
        self.assertNotIn("profit", str(r.data))

    def test_cursor_paging_no_gaps_no_repeats(self):
        base = timezone.now() - timedelta(days=30)
        for i in range(25):
            self.entry(100 + i, at=base + timedelta(hours=i))
        seen, before = [], ""
        for _ in range(10):
            r = self.client.get(A + "/customers/history/?party=%d&limit=10%s"
                                % (self.party.pk, before))
            seen += [i["id"] for i in r.data["items"]]
            if not r.data["next_before"]:
                break
            before = "&before=" + r.data["next_before"].replace("+", "%2B")
        self.assertEqual(len(seen), 25)
        self.assertEqual(len(set(seen)), 25)

    def test_kinds_filter(self):
        self._seed_everything()
        r = self.client.get(A + "/customers/history/?phone=01712345678&kinds=order")
        self.assertEqual({i["kind"] for i in r.data["items"]}, {"order"})

    def test_500_customers_list_and_history_stay_cheap(self):
        parties = [KhataParty(business=self.biz, book="customer", name="C%d" % i,
                              phone="0171%07d" % (2000000 + i)) for i in range(520)]
        KhataParty.objects.bulk_create(parties)
        ids = list(KhataParty.objects.filter(business=self.biz).values_list("id", flat=True))
        KhataEntry.objects.bulk_create([KhataEntry(party_id=i, direction="gave",
                                                   amount_poisha=1000, at=timezone.now())
                                        for i in ids])
        with CaptureQueriesContext(connection) as ctx:
            r = self.client.get(A + "/customers/?limit=50")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["total"], 521)
        self.assertEqual(len(r.data["results"]), 50)
        self.assertLess(len(ctx.captured_queries), 25)
        with CaptureQueriesContext(connection) as ctx:
            r = self.client.get(A + "/customers/history/?phone=01712000007")
        self.assertEqual(r.status_code, 200)
        self.assertLess(len(ctx.captured_queries), 40)

    def test_directory_merges_one_row_per_person_and_searches(self):
        self._seed_everything()
        r = self.client.get(A + "/customers/")
        rows = [x for x in r.data["results"] if x["phone_key"] == "01712345678"]
        self.assertEqual(len(rows), 1)
        self.assertTrue({"khata", "order", "chat", "crm", "sale"} <= set(rows[0]["sources"]))
        self.assertEqual(rows[0]["due_poisha"], 85000)
        r = self.client.get(A + "/customers/?q=karim")
        self.assertEqual(r.data["total"], 1)
        from urllib.parse import quote
        r = self.client.get(A + "/customers/?q=" + quote("০১৭১২৩৪"))
        self.assertEqual(r.data["total"], 1)                    # Bangla digits search
        r = self.client.get(A + "/customers/?only=due")
        self.assertEqual(r.data["total"], 1)

    def test_crm_only_user_without_shop_is_fine_and_creates_no_shop(self):
        u = User.objects.create_user(name="Sales", phone=_phone(), password="pw123456")
        CrmMember.objects.create(org=self.org, user=u, role=CrmMember.SALES)
        Lead.objects.create(org=self.org, name="Lead X", phone="01911111111")
        c = APIClient()
        c.force_authenticate(u)
        r = c.get(A + "/customers/")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["has_business"])
        self.assertEqual(r.data["total"], 1)
        r = c.get(A + "/customers/history/?phone=01911111111")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(BusinessProfile.objects.filter(user=u).exists())

    def test_login_required(self):
        self.assertIn(APIClient().get(A + "/customers/").status_code, (401, 403))


# ====================================================================== quotes
class QuoteBuildTests(_World):
    def _post(self, **kw):
        body = {"customer_name": "Karim", "customer_phone": "01712345678",
                "items": [{"product_id": self.saree.pk, "qty": 2}], "valid_days": 3}
        body.update(kw)
        return self.client.post(A + "/shop-quotes/", body, format="json")

    def test_prices_come_from_catalog_never_the_client(self):
        r = self._post(items=[{"product_id": self.saree.pk, "qty": 2, "price": "1"}])
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["subtotal_poisha"], 300000)
        self.assertEqual(r.data["total_poisha"], 300000)
        self.assertTrue(r.data["url"].startswith("http"))
        self.assertIn("/q/", r.data["url"])

    def test_floor_line_and_discount(self):
        r = self._post(items=[{"product_id": self.saree.pk, "qty": 1, "unit_price": "1100"}])
        self.assertEqual((r.status_code, r.data["error"]), (400, "below_min"))
        r = self._post(discount="700")          # floor 2400, subtotal 3000 → max 600
        self.assertEqual((r.status_code, r.data["error"]), (400, "discount_too_big"))
        self.assertEqual(r.data["max_poisha"], 60000)
        r = self._post(discount="600", delivery="60")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["total_poisha"], 300000 - 60000 + 6000)

    def test_staff_never_sees_the_floor(self):
        staff = User.objects.create_user(name="Staff", phone=_phone(), password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        c = APIClient()
        c.force_authenticate(staff)
        r = c.post(A + "/shop-quotes/", {"business": self.biz.pk, "items": [
            {"product_id": self.saree.pk, "qty": 2}], "discount": "700"}, format="json")
        self.assertEqual(r.data["error"], "discount_too_big")
        self.assertNotIn("max_poisha", r.data)
        cat = c.get(A + "/shop-quotes/catalog/?business=%d" % self.biz.pk)
        self.assertNotIn("min_poisha", str(cat.data))
        own = self.client.get(A + "/shop-quotes/catalog/")
        self.assertIn("min_poisha", str(own.data))

    def test_other_shops_product_refused(self):
        other = User.objects.create_user(name="O", phone=_phone(), password="pw123456")
        p = Product.objects.create(user=other, name="X", price=Decimal("10"))
        r = self._post(items=[{"product_id": p.pk, "qty": 1}])
        self.assertEqual(r.data["error"], "unknown_product")

    def test_validity_and_payment_bounds(self):
        self.assertEqual(self._post(valid_days=0).data["error"], "bad_validity")
        self.assertEqual(self._post(valid_days=31).data["error"], "bad_validity")
        self.assertEqual(self._post(payment="crypto").data["error"], "bad_payment")
        self.assertEqual(self._post(items=[]).data["error"], "no_items")

    def test_variant_price_and_stock_warning(self):
        ProductVariant.objects.create(product=self.saree, vkey="m|red", size="M",
                                      colour="Red", sell_price=Decimal("1600"),
                                      min_price=Decimal("1300"), stock=1)
        r = self._post(items=[{"product_id": self.saree.pk, "variant": "m|red", "qty": 2}])
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["subtotal_poisha"], 320000)
        self.assertEqual(r.data["warnings"][0]["code"], "low_stock")
        self.assertEqual(self._post(items=[{"product_id": self.saree.pk, "variant": "zz",
                                            "qty": 1}]).data["error"], "unknown_variant")

    def test_bangla_error_text(self):
        r = self.client.post(A + "/shop-quotes/", {"items": []}, format="json",
                             HTTP_ACCEPT_LANGUAGE="bn")
        self.assertIn("পণ্য", r.data["detail"])
        r = self.client.post(A + "/shop-quotes/", {"items": []}, format="json",
                             HTTP_ACCEPT_LANGUAGE="en")
        self.assertIn("product", r.data["detail"])

    def test_plans_v2_free_cannot_create_but_can_read(self):
        from core.tests_plans_v2 import flag
        flag(on=True)
        r = self._post()
        self.assertEqual(r.status_code, 402)
        self.assertEqual(self.client.get(A + "/shop-quotes/").status_code, 200)
        flag(on=False)
        self.assertEqual(self._post().status_code, 201)

    def test_no_business_is_honest(self):
        u = User.objects.create_user(name="N", phone=_phone(), password="pw123456")
        c = APIClient()
        c.force_authenticate(u)
        r = c.post(A + "/shop-quotes/", {"items": [{"product_id": 1, "qty": 1}]}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "no_business"))


class QuoteTokenTests(_World):
    def setUp(self):
        super().setUp()
        self.q, _ = SQ.build(self.biz, self.owner, {
            "customer_name": "Karim", "customer_phone": "01712345678", "lang": "bn",
            "items": [{"product_id": self.saree.pk, "qty": 2}], "valid_days": 2,
            "payment": "cod"})
        self.path = SQ.public_path(self.q)
        self.c = APIClient(enforce_csrf_checks=False)

    def test_page_bn_en_noindex_and_viewed(self):
        r = self.c.get(self.path)
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("দামের প্রস্তাব", html)
        self.assertIn("৳৩,০০০", html)                 # Bangla digits + grouping
        self.assertIn("noindex", r["X-Robots-Tag"])
        self.assertIn('name="robots" content="noindex', html)
        self.assertEqual(r["Cache-Control"], "no-store")
        self.assertNotIn("১,২০০", html)               # the floor never shows
        self.assertNotIn("1,200", html)
        self.q.refresh_from_db()
        self.assertEqual(self.q.state, "viewed")
        en = self.c.get(self.path + "?lang=en").content.decode()
        self.assertIn("Price quote", en)
        self.assertIn("৳3,000", en)
        self.assertNotIn("দামের প্রস্তাব", en)

    def test_forged_edited_and_guessed_links_are_404(self):
        nonce, sig = SQ.token_for(self.q.nonce).split(".", 1)
        for bad in ("/q/" + nonce, "/q/%s.%s" % (nonce, sig[:-2] + "xx"),
                    "/q/%s.%s" % (SQ.new_nonce(), sig), "/q/x"):
            self.assertEqual(self.c.get(bad).status_code, 404, bad)
        self.assertIsNone(SQ.nonce_from("abc"))

    def test_accept_creates_one_order_with_stock_and_cod(self):
        with mock.patch("core.push.push_to_user_async") as push:
            r = self.c.post(self.path, {"action": "accept", "name": "Karim Mia",
                                        "address": "Mirpur 10"})
        self.assertEqual(r.status_code, 302)
        self.q.refresh_from_db()
        self.assertEqual(self.q.state, "accepted")
        o = self.q.order
        self.assertEqual((o.total, o.payment, o.payment_status, o.status, o.channel),
                         (Decimal("3000"), "cod", "", "new", "quote"))
        self.assertEqual(o.address, "Mirpur 10")
        self.assertEqual(o.items[0]["qty"], 2)
        self.saree.refresh_from_db()
        self.assertEqual(self.saree.stock, 3)
        self.assertTrue(push.called)
        self.assertEqual(push.call_args[0][1], "shop_alert")
        # idempotent: a double tap / replay never makes a second order
        self.c.post(self.path, {"action": "accept", "name": "Karim", "address": "x"})
        self.assertEqual(SQ.accept(self.q).pk, o.pk)
        self.assertEqual(Order.objects.filter(channel="quote").count(), 1)
        self.saree.refresh_from_db()
        self.assertEqual(self.saree.stock, 3)
        # the page now shows the order, no form
        html = self.c.get(self.path).content.decode()
        self.assertNotIn('name="action" value="accept"', html)
        # the customer appears in the shop's customer list
        self.assertTrue(Customer.objects.filter(user=self.owner, phone_key="01712345678")
                        .exists())

    def test_address_required_for_cod(self):
        r = self.c.post(self.path, {"action": "accept", "name": "K", "address": ""})
        self.assertEqual(r.status_code, 400)
        self.q.refresh_from_db()
        self.assertEqual(self.q.state, "issued")

    def test_out_of_stock_makes_no_order_and_keeps_quote_open(self):
        Product.objects.filter(pk=self.saree.pk).update(stock=1)
        r = self.c.post(self.path, {"action": "accept", "address": "Mirpur"})
        self.assertEqual(r.status_code, 400)
        self.assertIn("Red saree", r.content.decode())
        self.assertFalse(Order.objects.filter(channel="quote").exists())
        self.saree.refresh_from_db()
        self.assertEqual(self.saree.stock, 1)
        self.q.refresh_from_db()
        self.assertIn(self.q.state, ("issued", "viewed"))

    def test_expired_is_honest_and_cannot_accept(self):
        ShopQuote.objects.filter(pk=self.q.pk).update(
            valid_until=timezone.now() - timedelta(minutes=1))
        html = self.c.get(self.path).content.decode()
        self.assertIn("মেয়াদ শেষ", html)
        self.assertNotIn('value="accept"', html)
        self.c.post(self.path, {"action": "accept", "address": "x"})
        self.assertFalse(Order.objects.exists())
        self.q.refresh_from_db()
        self.assertEqual(self.q.state, "expired")
        # the seller extends → open again
        r = self.client.post(A + "/shop-quotes/%d/extend/" % self.q.pk, {"days": 2},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertIn(r.data["state"], ("issued", "viewed"))

    def test_decline_then_no_accept(self):
        with mock.patch("core.push.push_to_user_async"):
            self.c.post(self.path, {"action": "decline", "reason": "দাম বেশি"})
        self.q.refresh_from_db()
        self.assertEqual((self.q.state, self.q.decline_reason), ("declined", "দাম বেশি"))
        with self.assertRaises(SQ.QuoteError):
            SQ.accept(self.q)
        self.assertFalse(Order.objects.exists())

    def test_revoked_cannot_accept(self):
        r = self.client.post(A + "/shop-quotes/%d/revoke/" % self.q.pk, {}, format="json")
        self.assertEqual(r.data["state"], "revoked")
        self.c.post(self.path, {"action": "accept", "address": "x"})
        self.assertFalse(Order.objects.exists())
        self.assertIn("তুলে নিয়েছে", self.c.get(self.path).content.decode())

    def test_paid_and_bkash_payment_status(self):
        q2, _ = SQ.build(self.biz, self.owner, {"items": [{"product_id": self.saree.pk,
                                                            "qty": 1}], "payment": "paid"})
        with mock.patch("core.push.push_to_user_async"):
            o = SQ.accept(q2, name="A")
        self.assertEqual((o.payment, o.payment_status), ("paid", "verified"))
        q3, _ = SQ.build(self.biz, self.owner, {"items": [{"product_id": self.saree.pk,
                                                            "qty": 1}], "payment": "bkash"})
        with mock.patch("core.push.push_to_user_async"):
            o = SQ.accept(q3, address="x")
        self.assertEqual((o.payment, o.payment_status), ("bkash", ""))

    def test_rate_limited(self):
        for _ in range(8):
            self.c.post(self.path, {"action": "accept", "address": ""})
        r = self.c.post(self.path, {"action": "accept", "address": "x"})
        self.assertEqual(r.status_code, 429)
        self.assertFalse(Order.objects.exists())

    def test_seller_list_and_other_shop_cannot_touch(self):
        r = self.client.get(A + "/shop-quotes/?phone=01712345678")
        self.assertEqual(len(r.data["results"]), 1)
        other = User.objects.create_user(name="O", phone=_phone(), password="pw123456")
        BusinessProfile.objects.create(user=other)
        c = APIClient()
        c.force_authenticate(other)
        self.assertEqual(c.get(A + "/shop-quotes/%d/" % self.q.pk).status_code, 404)
        self.assertEqual(c.post(A + "/shop-quotes/%d/revoke/" % self.q.pk).status_code, 404)

    def test_quote_shows_in_customer_history(self):
        r = self.client.get(A + "/customers/history/?phone=01712345678")
        self.assertIn("quote", {i["kind"] for i in r.data["items"]})
        self.assertEqual(r.data["summary"]["quotes_open"], 1)


# ====================================================================== send
@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class SendTests(_World):
    def setUp(self):
        super().setUp()
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})

    def _credits(self):
        return User.objects.get(pk=self.owner.pk).ai_credits

    def test_preview_links_and_cost_first(self, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        r = self.client.post(A + "/send/preview", {"party": self.party.pk,
                                                   "text": "ঈদের নতুন শাড়ি এসেছে"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["wa_url"].startswith("https://wa.me/8801712345678?text="))
        self.assertTrue(r.data["sms_uri"].startswith("sms:+8801712345678"))
        sms = r.data["sms"]
        self.assertTrue(sms["available"])
        self.assertGreaterEqual(sms["credits"], 1)
        self.assertIn("Rahim Store", sms["text"])          # who it is from
        self.assertIn("STOP", sms["text"])                 # how to stop
        self.assertFalse(SmsLog.objects.exists())          # nothing sent on preview

    def test_link_logged_as_opened_never_sent(self, _q):
        lead = Lead.objects.create(org=self.org, name="Karim", phone="01712345678")
        r = self.client.post(A + "/send/log", {"phone": "01712345678",
                                               "channel": "whatsapp_link", "text": "hi",
                                               "lead": lead.pk}, format="json")
        self.assertEqual(r.data["status"], "opened")
        m = CustomerMessage.objects.get()
        self.assertEqual((m.status, m.channel, m.business_id, m.lead_id),
                         ("opened", "whatsapp_link", self.biz.pk, lead.pk))
        self.assertTrue(Activity.objects.filter(lead=lead, kind="whatsapp").exists())
        h = self.client.get(A + "/customers/history/?phone=01712345678")
        self.assertIn("message", {i["kind"] for i in h.data["items"]})
        bad = self.client.post(A + "/send/log", {"phone": "01712345678", "channel": "fax",
                                                 "text": "x"}, format="json")
        self.assertEqual(bad.status_code, 400)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_assisto_sms_charged_logged_and_capped(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        pv = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "hello"},
                              format="json").data["sms"]
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "hello",
                                               "credits": pv["credits"]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self._credits(), 10 - pv["credits"])
        row = SmsLog.objects.get()
        self.assertEqual((row.purpose, row.business_id, row.status), ("crm", self.biz.pk, "sent"))
        self.assertEqual(CustomerMessage.objects.get().status, "sent")
        # 1 per customer per day
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "again"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "phone_daily_cap"))
        self.assertEqual(CustomerMessage.objects.filter(status="blocked").count(), 1)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_price_changed_refused_before_charging(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "hello",
                                               "credits": 99}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "price_changed"))
        self.assertEqual(http.call_count, 0)
        self.assertEqual(self._credits(), 10)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_zero_credits_stop_and_strangers(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "x"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (402, "insufficient_credits"))
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        from core.logic import msg_guard as MG
        MG.record_opt_out(self.biz.pk, "01712345678")
        pv = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "x"},
                              format="json").data["sms"]
        self.assertEqual((pv["available"], pv["blocked"]), (False, "opted_out"))
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "x"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "opted_out"))
        r = self.client.post(A + "/send/sms", {"phone": "01899999999", "text": "x"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "not_your_customer"))
        self.assertEqual(http.call_count, 0)

    def test_quiet_hours_shown_before(self, q):
        q.return_value = True
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        pv = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "x"},
                              format="json").data["sms"]
        self.assertEqual(pv["blocked"], "quiet_hours")
        self.assertTrue(pv["retry_at"])

    def test_staff_cannot_spend_owner_credits(self, _q):
        staff = User.objects.create_user(name="S", phone=_phone(), password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        c = APIClient()
        c.force_authenticate(staff)
        r = c.post(A + "/send/sms", {"business": self.biz.pk, "party": self.party.pk,
                                     "text": "x"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "owner_only"))
        pv = c.post(A + "/send/preview", {"business": self.biz.pk, "party": self.party.pk,
                                          "text": "x"}, format="json").data
        self.assertEqual(pv["sms"]["blocked"], "owner_only")
        self.assertTrue(pv["wa_url"])                       # free paths still work

    def test_no_gateway_is_honest(self, _q):
        from core.models import Integration
        Integration.objects.filter(slug="sms_alpha").update(status="not_set")
        pv = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "x"},
                              format="json").data["sms"]
        self.assertEqual(pv["blocked"], "sms_not_configured")
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "x"},
                             format="json")
        self.assertEqual(r.status_code, 503)

    def test_bulk_is_one_card_per_customer_and_sends_nothing(self, _q):
        p2 = KhataParty.objects.create(business=self.biz, book="customer", name="Rahela",
                                       phone="01811111111")
        r = self.client.post(A + "/send/bulk", {
            "targets": [{"party": self.party.pk}, {"party": p2.pk},
                        {"phone": "01712345678"}, {"party": 999999}],
            "text": "{name} ভাই, নতুন মাল এসেছে"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        cards = r.data["cards"]
        self.assertEqual([c["name"] for c in cards], ["Karim", "Rahela"])
        self.assertTrue(cards[0]["text"].startswith("Karim ভাই"))
        self.assertTrue(cards[1]["text"].startswith("Rahela ভাই"))
        self.assertNotEqual(cards[0]["wa_url"], cards[1]["wa_url"])
        self.assertEqual({s["reason"] for s in r.data["skipped"]}, {"duplicate", "not_found"})
        self.assertFalse(SmsLog.objects.exists())
        self.assertFalse(CustomerMessage.objects.exists())


class PureTests(TestCase):
    def test_phone_key_and_fill(self):
        self.assertEqual(C.phone_key("+880 1712-345678"), "01712345678")
        self.assertEqual(C.phone_key("০১৭১২৩৪৫৬৭৮"), "01712345678")
        self.assertEqual(C.phone_key("12"), "")
        from . import send_paths as SP
        self.assertEqual(SP.fill("{name} ভাই", "Karim"), "Karim ভাই")
        self.assertEqual(SP.fill("Hi {name}, sale", ""), "Hi, sale")

    def test_token_roundtrip(self):
        n = SQ.new_nonce()
        self.assertEqual(SQ.nonce_from(SQ.token_for(n)), n)
        self.assertIsNone(SQ.nonce_from(SQ.token_for(n) + "x"))


# ====================================================== B2B proposal accept page
class ProposalAcceptTests(_World):
    def setUp(self):
        super().setUp()
        from .models import Proposal
        self.lead = Lead.objects.create(org=self.org, name="Karim", company="Karim Garments")
        self.prop = Proposal.objects.create(
            lead=self.lead, title="HRM + Payroll", status="sent", valid_days=7,
            line_items=[{"sku": "HRM", "label": "HRM module", "qty": 1,
                         "unit_price": 50000.0, "amount": 50000.0}],
            subtotal=Decimal("50000"), total=Decimal("50000"))
        self.c = APIClient()

    def _link(self):
        r = self.client.get(A + "/proposals/%d/acceptance_link/" % self.prop.pk)
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def test_token_is_random_and_legacy_guessable_one_is_rotated(self):
        from . import logic_quote as lq
        from .models import QuoteAcceptance
        legacy = lq.make_acceptance_token(quote_id=self.prop.id, version=self.prop.version,
                                          salt=str(self.org.id))
        QuoteAcceptance.objects.create(proposal=self.prop, token=legacy)
        d = self._link()
        self.assertNotEqual(d["token"], legacy)
        self.assertTrue(d["url"].endswith("/qp/" + d["token"]))
        self.assertEqual(self.c.get("/qp/" + legacy).status_code, 404)
        self.assertEqual(self.c.get("/api/v1/crm/accept/%s/" % legacy).status_code, 404)
        self.assertEqual(self._link()["token"], d["token"])        # stable after rotation

    def test_web_page_accept_once_and_seller_pushed(self):
        tok = self._link()["token"]
        r = self.c.get("/qp/" + tok)
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("প্রপোজাল", html)
        self.assertIn("HRM module", html)
        self.assertIn("৳৫০,০০০", html)
        self.assertIn("noindex", r["X-Robots-Tag"])
        with mock.patch("core.push.push_to_user_async") as push:
            self.c.post("/qp/" + tok, {"action": "accept"})
            self.c.post("/qp/" + tok, {"action": "decline"})      # too late: decided
        self.prop.refresh_from_db()
        self.assertEqual(self.prop.status, "accepted")
        self.assertEqual(push.call_count, 1)
        self.assertNotIn('value="accept"', self.c.get("/qp/" + tok).content.decode())

    def test_expired_proposal_cannot_be_accepted_page_or_api(self):
        from .models import Proposal
        tok = self._link()["token"]
        Proposal.objects.filter(pk=self.prop.pk).update(
            created_at=timezone.now() - timedelta(days=30))
        r = self.c.post("/api/v1/crm/accept/%s/" % tok, {"action": "accept"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.c.post("/qp/" + tok, {"action": "accept"})
        self.prop.refresh_from_db()
        self.assertEqual(self.prop.status, "sent")
        self.assertIn("মেয়াদ শেষ", self.c.get("/qp/" + tok).content.decode())

    def test_public_api_is_rate_limited(self):
        codes = [self.c.get("/api/v1/crm/accept/nope/").status_code for _ in range(32)]
        self.assertEqual(codes[0], 404)
        self.assertEqual(codes[-1], 429)
