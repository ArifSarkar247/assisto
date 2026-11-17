"""bizai2 — the owner's daily summary: real sales / khata numbers, who to
chase, stock-out forecast from sales speed, measured outcomes, one push per
shop per day, owner-only, off switch, never for an idle shop."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core import bizai_daily as BD
from core.models import (BusinessProfile, BusinessStaff, KhataEntry, KhataParty, NotifEvent,
                         PaCollectionItem, Product, ProductVariant, Sale, SaleLine, User)

API = "/api/v1/bizai/daily"


class DailySummaryTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Rahim", phone="01710000901",
                                              password="pw-123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.now = timezone.now()
        rice = Product.objects.create(user=self.owner, business=self.biz, name="Chal 5kg",
                                      price=500, stock=2)
        self.rice = ProductVariant.objects.create(product=rice, vkey="__base__", stock=2)
        oil = Product.objects.create(user=self.owner, business=self.biz, name="Tel 1L",
                                     price=200, stock=100)
        self.oil = ProductVariant.objects.create(product=oil, vkey="__base__", stock=100)
        self.sale(50000, "cash", 0, [(self.rice, 1)])
        self.sale(30000, "bkash", 0, [(self.rice, 1), (self.oil, 1)])
        self.sale(10000, "cash", 5, [(self.rice, 12)])           # speed: 14 in 14 days
        self.sale(40000, "cash", 7, [])                          # same weekday last week
        self.karim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712000001")
        self.entry(self.karim, "gave", 100000, 15)
        self.selim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Selim", phone="01712000002")
        self.entry(self.selim, "gave", 50000, 0)
        self.entry(self.selim, "got", 20000, 0)
        self.oc = APIClient()
        self.oc.force_authenticate(self.owner)

    def sale(self, total, method, days_ago, lines):
        s = Sale.objects.create(user=self.owner, business=self.biz, total=total,
                                payment_method=method)
        Sale.objects.filter(pk=s.pk).update(created_at=self.now - timedelta(days=days_ago))
        for v, q in lines:
            SaleLine.objects.create(sale=s, product=v.product, variant=v,
                                    product_name=v.product.name, qty=q)
        return s

    def entry(self, party, d, amount, days_ago):
        KhataEntry.objects.create(party=party, direction=d, amount_poisha=amount,
                                  at=self.now - timedelta(days=days_ago), note="PRIVATE")

    def test_summary_numbers_are_real_and_bangla(self):
        r = self.oc.get(API, HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        text = " ".join(r.data["lines"])
        self.assertIn("আজ বিক্রি: ২টি, মোট ৳৮০০.০০", text)
        self.assertIn("ক্যাশ ৳৫০০.০০", text)          # gap-bizai: never "নগদ" (= Nagad too)
        self.assertIn("বিকাশ ৳৩০০.০০", text)
        self.assertIn("১০০% বেশি", text)                     # 800 vs 400 last week
        self.assertIn("আজ খাতায় বাকি আদায়: ৳২০০.০০", text)
        self.assertIn("মোট পাওনা: ৳১,৩০০.০০".replace(",", ""), text.replace(",", ""))
        self.assertEqual([c["name"] for c in r.data["chase"]], ["Karim", "Selim"])
        self.assertIn("১৫ দিন ধরে বাকি", r.data["chase"][0]["line"])
        st = r.data["stock"]
        self.assertEqual([x["name"] for x in st], ["Chal 5kg"])   # oil lasts long
        self.assertEqual((st[0]["days_left"], st[0]["reorder"]), (2, 5))
        self.assertIn("প্রায় ২ দিনে শেষ হবে", st[0]["line"])
        self.assertIn("Chal 5kg", r.data["next"])
        self.assertTrue(r.data["enabled"])
        self.assertNotIn("PRIVATE", str(r.data))               # khata notes never shown
        self.assertNotIn("01712000001", str(r.data))           # no phone numbers
        en = self.oc.get(API, HTTP_ACCEPT_LANGUAGE="en").data
        self.assertIn("Sales today: 2, total ৳800.00.", en["lines"])
        self.assertIn("runs out in about 2 days", en["stock"][0]["line"])

    def test_out_of_stock_seller_comes_first(self):
        ProductVariant.objects.filter(pk=self.rice.pk).update(stock=0)
        st = BD.stock_forecast(self.biz, timezone.now())
        self.assertEqual((st[0]["name"], st[0]["days_left"], st[0]["reorder"]),
                         ("Chal 5kg", 0, 7))
        self.assertIn("শেষ হয়ে গেছে", BD.summary(self.biz, "bn")["stock"][0]["line"])

    def test_outcome_of_reminders_is_measured(self):
        from core.models import TagadaSend
        TagadaSend.objects.create(business=self.biz, party=self.selim, phone_key="p:1",
                                  day=self.now.date(), channel="whatsapp",
                                  created_at=self.now - timedelta(days=1))
        out = " ".join(BD.summary(self.biz, "bn")["outcomes"])
        self.assertIn("তাগাদার পরে আদায়: ৳২০০", out)

    @mock.patch("core.push.push_to_user_async", return_value=True)
    def test_cron_once_per_day_with_push_and_feed_row(self, push):
        self.assertEqual(BD.run_daily(), 1)
        self.assertEqual(BD.run_daily(), 0)                     # idempotent per day
        self.assertEqual(push.call_count, 1)
        self.assertEqual(push.call_args.args[1], "shop_alert")
        self.assertEqual(push.call_args.kwargs["data"]["route"], "business/daily")
        ev = NotifEvent.objects.get(user=self.owner, type="business")
        self.assertEqual(ev.route, "business/daily")
        row = PaCollectionItem.objects.get(collection=BD.COL)
        self.assertEqual(row.data["business_id"], self.biz.pk)
        self.assertIn("lines", row.data["bn"])

    @mock.patch("core.push.push_to_user_async", return_value=True)
    def test_off_switch_and_idle_shop(self, push):
        r = self.oc.post(API, {"on": False}, format="json")
        self.assertEqual((r.status_code, r.data["enabled"]), (200, False))
        self.assertEqual(BD.run_daily(), 0)
        self.assertEqual(self.oc.post(API, {"on": "x"}, format="json").status_code, 400)
        self.oc.post(API, {"on": True}, format="json")
        idle = User.objects.create_user(name="Idle", phone="01710000902", password="pw-123456")
        BusinessProfile.objects.create(user=idle, shop_name="Idle Shop")
        self.assertEqual(BD.run_daily(), 1)                     # only the active shop
        self.assertFalse(NotifEvent.objects.filter(user=idle).exists())

    def test_staff_cannot_see_the_owner_summary(self):
        staff = User.objects.create_user(name="S", phone="01710000903", password="pw-123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="cashier",
                                     active=True)
        sc = APIClient()
        sc.force_authenticate(staff)
        self.assertEqual(sc.get(API + "?business=%d" % self.biz.pk).status_code, 403)

    def test_no_sales_day_never_invents(self):
        Sale.objects.all().delete()
        KhataEntry.objects.all().delete()
        d = BD.summary(self.biz, "bn")
        self.assertTrue(d["empty"])
        self.assertIn("কোনো বিক্রি লেখা হয়নি", d["lines"][0])
        self.assertEqual((d["chase"], d["stock"]), ([], []))
