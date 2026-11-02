"""bizbar — Business khata + CRM launch bar (2 Nov).

Daily cash close: the cashbox screen read keys the server never sent (it
always showed ৳0 and no rows) and an added row blanked it. These tests pin the
ONE contract the app reads, the auto lines (POS cash, dues collected, supplier
paid, expenses), the carried opening and the honest re-count."""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import business_khata as K
from core.models import (BusinessProfile, BusinessStaff, CashboxDay, Expense,
                         KhataEntry, KhataParty, Sale, User)

CB = "/api/v1/business/cashbox"


def today():
    return timezone.localdate().isoformat()


class CashClosePureTests(TestCase):
    def test_view_math_and_lines(self):
        v = K.cashbox_close_view(
            500000, [{"id": 1, "kind": "in", "amount": 10000, "at": "a"},
                     {"id": 2, "kind": "out", "amount": 2500, "at": "b"}],
            auto={"cash_sales": 300000, "cash_sales_count": 4,
                  "dues_collected": 50000, "dues_collected_count": 1,
                  "supplier_paid": 100000, "supplier_paid_count": 1})
        # 5000 + 100 + 3000 + 500 - 25 - 1000 = 7575 taka
        self.assertEqual(v["expected_poisha"], 757500)
        self.assertEqual(v["expected_display"]["bn"], "৳৭৫৭৫.০০")
        keys = [l["key"] for l in v["auto_lines"]]
        # in-lines always shown; expenses (0) hidden
        self.assertEqual(keys, ["cash_sales", "dues_collected", "supplier_paid"])
        self.assertFalse(v["reconciled"])
        self.assertNotIn("variance_poisha", v)
        self.assertEqual([e["id"] for e in v["entries"]], [2, 1])   # newest first

    def test_variance_states(self):
        v = K.cashbox_close_view(10000, [], counted=9000, reconciled_at="x")
        self.assertTrue(v["reconciled"])
        self.assertEqual(v["variance_poisha"], -1000)
        self.assertEqual(v["variance_state"], "shortage")
        self.assertIn("কম আছে", v["variance_status"]["bn"])
        v = K.cashbox_close_view(10000, [], counted=10000, reconciled_at="x")
        self.assertEqual(v["variance_state"], "balanced")

    def test_share_text_bangla(self):
        v = K.cashbox_close_view(10000, [], auto={"cash_sales": 20000},
                                 counted=30000, reconciled_at="x")
        txt = K.cashbox_share_text(v, "2026-11-02", "Rahim Store", "bn")
        self.assertIn("২ নভে ২০২৬", txt)
        self.assertIn("ড্রয়ারে থাকার কথা: ৳৩০০.০০", txt)
        self.assertIn("মিলে গেছে", txt)
        en = K.cashbox_share_text(v, "2026-11-02", "", "en")
        self.assertIn("Should be in the drawer: ৳300.00", en)


class CashCloseApiTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000211",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.client.force_authenticate(self.owner)

    def sale(self, method, total, paid, change=0, voided=False):
        return Sale.objects.create(
            user=self.owner, business=self.biz, total=total, paid=paid,
            change=change, due=max(0, total - paid) if method == "due" else 0,
            payment_method=method,
            voided_at=timezone.now() if voided else None)

    def test_get_has_every_key_the_app_reads(self):
        r = self.client.get("%s/%s" % (CB, today()), HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        for k in ("expected_display", "opening_display", "total_in_display",
                  "total_out_display", "manual_in_display", "manual_out_display",
                  "entries", "auto_lines", "reconciled", "share_text"):
            self.assertIn(k, r.data)
        self.assertEqual(r.data["expected_display"]["bn"], "৳০.০০")

    def test_auto_lines_from_pos_khata_expenses(self):
        self.sale("cash", 50000, 60000, change=10000)    # 500 in drawer
        self.sale("due", 30000, 10000)                   # 100 paid now
        self.sale("bkash", 70000, 70000)                 # not drawer cash
        self.sale("cash", 90000, 90000, voided=True)     # voided: never
        cust = KhataParty.objects.create(business=self.biz, book="customer", name="K")
        sup = KhataParty.objects.create(business=self.biz, book="supplier", name="S")
        now = timezone.now()
        KhataEntry.objects.create(party=cust, direction="got", amount_poisha=20000, at=now)
        KhataEntry.objects.create(party=cust, direction="gave", amount_poisha=99900, at=now)
        KhataEntry.objects.create(party=sup, direction="gave", amount_poisha=15000, at=now)
        KhataEntry.objects.create(party=cust, direction="got", amount_poisha=77700,
                                  at=now - timedelta(days=3))     # another day
        Expense.objects.create(user=self.owner, business=self.biz, amount=5000,
                               date=timezone.localdate())
        r = self.client.get("%s/%s" % (CB, today()))
        lines = {l["key"]: l for l in r.data["auto_lines"]}
        self.assertEqual(lines["cash_sales"]["amount"], 60000)
        self.assertEqual(lines["cash_sales"]["count"], 2)
        self.assertEqual(lines["dues_collected"]["amount"], 20000)
        self.assertEqual(lines["supplier_paid"]["amount"], 15000)
        self.assertEqual(lines["expenses"]["amount"], 5000)
        self.assertEqual(r.data["expected_poisha"], 60000 + 20000 - 15000 - 5000)

    def test_entry_returns_full_payload_not_just_an_id(self):
        r = self.client.post("%s/%s/entries" % (CB, today()),
                             {"kind": "in", "amount": 12500, "note": "owner"},
                             format="json")
        self.assertEqual(r.status_code, 201)
        self.assertIn("entry_id", r.data)
        self.assertEqual(r.data["expected_poisha"], 12500)
        self.assertEqual(r.data["entries"][0]["amount_display"]["en"], "৳125.00")

    def test_carry_opening_and_recount(self):
        y = (timezone.localdate() - timedelta(days=1))
        CashboxDay.objects.create(business=self.biz, day=y, opening_poisha=0,
                                  counted_poisha=300000, reconciled_at=timezone.now())
        r = self.client.get("%s/%s" % (CB, today()))
        self.assertEqual(r.data["opening_poisha"], 300000)
        self.assertTrue(r.data["opening_carried"])
        # first write keeps the carried opening on the new row
        self.client.post("%s/%s/entries" % (CB, today()),
                         {"kind": "out", "amount": 10000}, format="json")
        r = self.client.post("%s/%s/reconcile" % (CB, today()), {"counted": 280000},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["reconciled"])
        self.assertEqual(r.data["variance_poisha"], -10000)
        self.assertEqual(r.data["variance_state"], "shortage")
        # re-count after a forgotten cash-out: now balanced
        self.client.post("%s/%s/entries" % (CB, today()),
                         {"kind": "out", "amount": 10000}, format="json")
        r = self.client.post("%s/%s/reconcile" % (CB, today()), {"counted": 280000},
                             format="json")
        self.assertEqual(r.data["variance_state"], "balanced")
        r = self.client.get("%s/%s" % (CB, today()))
        self.assertTrue(r.data["reconciled"])
        self.assertIn("counted_display", r.data)

    def test_bad_day_and_bad_amounts(self):
        self.assertEqual(self.client.get(CB + "/2026-13-40").status_code, 400)
        r = self.client.post("%s/%s/reconcile" % (CB, today()), {"counted": "x-1"},
                             format="json")
        self.assertIn(r.status_code, (200, 422))
        r = self.client.post("%s/%s/opening" % (CB, today()), {"opening": -5},
                             format="json")
        self.assertEqual(r.status_code, 422)

    def test_staff_sees_the_same_drawer(self):
        staff = User.objects.create_user(name="Staff", phone="+8801999000212",
                                         password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        self.sale("cash", 10000, 10000)
        self.client.force_authenticate(staff)
        r = self.client.get("%s/%s?business_id=%d" % (CB, today(), self.biz.id))
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["expected_poisha"], 10000)

    def test_other_shop_cannot_read(self):
        other = User.objects.create_user(name="O", phone="+8801999000213",
                                         password="pw123456")
        self.sale("cash", 10000, 10000)
        self.client.force_authenticate(other)
        r = self.client.get("%s/%s?business_id=%d" % (CB, today(), self.biz.id))
        self.assertNotEqual(r.data.get("expected_poisha"), 10000)


# =========================================================== POS integrity
B = "/api/v1/business"


class PosIntegrityTests(APITestCase):
    def setUp(self):
        from core.models import Product, ProductVariant
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000311",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Dokan")
        self.client.force_authenticate(self.owner)
        self.soap = self._prod("Soap", 100, 80, 60, 10)
        self.rice = self._prod("Rice", 70, 65, 50, 4)

    def _prod(self, name, sell, minimum, cost, stock):
        r = self.client.post(B + "/products", {"name": name, "price": str(sell),
                                               "min_price": str(minimum),
                                               "cost_price": str(cost),
                                               "stock": stock}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["id"]

    def _add(self, pid, qty=1, cart=None):
        r = self.client.post(B + "/cart/add", {"cart": cart or {}, "product": pid,
                                               "qty": qty}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return r.data["cart"]

    def _stock(self, pid):
        from core.models import ProductVariant
        return ProductVariant.objects.get(product_id=pid).stock

    def test_cart_carries_totals(self):
        cart = self._add(self.soap, 2)
        cart = self._add(self.rice, 1, cart)
        self.assertEqual(cart["subtotal"], 2 * 10000 + 7000)
        self.assertEqual(cart["total"], 27000)
        self.assertEqual(cart["item_count"], 3)

    def test_sale_decrements_the_right_product(self):
        cart = self._add(self.rice, 3)       # rice is the SECOND base product
        r = self.client.post(B + "/sales/checkout", {"cart": cart,
                                                     "payment_method": "cash"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self._stock(self.rice), 1)
        self.assertEqual(self._stock(self.soap), 10)          # untouched
        low = r.data["low_stock"]
        self.assertTrue(low[0]["low_stock"])
        self.assertEqual(low[0]["product_name"], "Rice")

    def test_tampered_cart_cannot_sell_below_min(self):
        cart = self._add(self.soap, 1)
        cart["lines"][0]["unit_price"] = 100       # ৳1
        cart["lines"][0]["min_price"] = 0          # phone lies about the floor
        r = self.client.post(B + "/sales/checkout", {"cart": cart,
                                                     "payment_method": "cash"},
                             format="json")
        self.assertEqual(r.status_code, 422)
        self.assertEqual(r.data["error"], "below_min")

    def test_cannot_oversell_and_set_price_reads_unit_price(self):
        cart = self._add(self.rice, 4)
        cart["lines"][0]["qty"] = 9
        r = self.client.post(B + "/sales/checkout", {"cart": cart,
                                                     "payment_method": "cash"},
                             format="json")
        self.assertEqual(r.status_code, 422)
        cart = self._add(self.soap, 1)
        lid = cart["lines"][0]["id"]
        r = self.client.post(B + "/cart/line/%d/price" % lid,
                             {"cart": cart, "unit_price": "90"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["cart"]["total"], 9000)
        r = self.client.post(B + "/cart/line/%d/price" % lid,
                             {"cart": cart, "unit_price": "50"}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_staff_sells_from_the_shop_catalog_without_seeing_cost(self):
        staff = User.objects.create_user(name="Staff", phone="+8801999000312",
                                         password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        self.client.force_authenticate(staff)
        r = self.client.get(B + "/products?business=%d" % self.biz.id)
        self.assertEqual(len(r.data["products"]), 2)
        self.assertNotIn("cost_price", r.data["products"][0])
        r = self.client.post(B + "/cart/add", {"business": self.biz.id,
                                               "product": self.soap, "qty": 1},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        line = r.data["cart"]["lines"][0]
        self.assertNotIn("cost_price", line)
        self.assertNotIn("min_price", line)
        # the redacted cart still checks out (prices re-read from the DB)
        r = self.client.post(B + "/sales/checkout",
                             {"business": self.biz.id, "cart": r.data["cart"],
                              "payment_method": "cash"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertNotIn("profit", r.data)
        self.client.force_authenticate(self.owner)
        rep = self.client.get(B + "/reports?period=daily")
        self.assertEqual(rep.data["sales"], 10000)            # staff sale counted
        self.assertEqual(rep.data["profit"], 10000 - 6000)

    def test_edit_shows_in_list_and_till(self):
        r = self.client.post(B + "/products/%d" % self.soap,
                             {"name": "Soap", "price": "120", "stock": 7},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        rows = {p["id"]: p for p in self.client.get(B + "/products").data["products"]}
        self.assertEqual(rows[self.soap]["price"], 12000)
        self.assertEqual(rows[self.soap]["stock"], 7)
        cart = self._add(self.soap, 1)
        self.assertEqual(cart["total"], 12000)

    def test_low_stock_list(self):
        r = self.client.get(B + "/products?low=1")
        self.assertEqual([p["name"] for p in r.data["products"]], [])
        cart = self._add(self.rice, 2)
        self.client.post(B + "/sales/checkout", {"cart": cart, "payment_method": "cash"},
                         format="json")
        r = self.client.get(B + "/products?low=1")
        self.assertEqual([p["name"] for p in r.data["products"]], ["Rice"])
        self.assertEqual(r.data["low_stock_count"], 1)

    def test_due_sale_needs_a_customer_and_lands_on_their_page(self):
        cart = self._add(self.soap, 1)
        r = self.client.post(B + "/sales/checkout", {"cart": cart,
                                                     "payment_method": "due"},
                             format="json")
        self.assertEqual(r.status_code, 422)
        self.assertEqual(r.data.get("error"), "due_needs_customer")
        r = self.client.post(B + "/sales/checkout",
                             {"cart": cart, "payment_method": "due",
                              "customer_name": "Karim", "customer_phone": "01712345678"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        p = KhataParty.objects.get(business=self.biz, book="customer")
        self.assertEqual(p.name, "Karim")
        rows = self.client.get(B + "/customers").data["customers"]
        self.assertEqual(rows[0]["dues_poisha"], 10000)
        self.assertEqual(len(self.client.get(B + "/customers?q=৩৪৫৬৭৮").data["customers"]), 1)

    def test_old_cart_without_product_ids_is_stale_not_wrong(self):
        cart = self._add(self.soap, 1)
        cart["lines"][0].pop("product_id")
        r = self.client.post(B + "/sales/checkout", {"cart": cart,
                                                     "payment_method": "cash"},
                             format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.data.get("error"), "cart_stale")


class BusinessIdParamTests(APITestCase):
    def test_business_id_param_is_honoured_for_staff(self):
        owner = User.objects.create_user(name="O", phone="+8801999000411", password="pw123456")
        biz = BusinessProfile.objects.create(user=owner, shop_name="S")
        staff = User.objects.create_user(name="T", phone="+8801999000412", password="pw123456")
        BusinessStaff.objects.create(business=biz, member=staff, role="staff")
        self.client.force_authenticate(staff)
        r = self.client.post("%s/%s/entries" % (CB, today()),
                             {"business_id": biz.id, "kind": "in", "amount": 500},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(CashboxDay.objects.get().business_id, biz.id)
        self.assertFalse(BusinessProfile.objects.filter(user=staff).exists())


class OfflinePartyTests(APITestCase):
    """A party added with no internet is replayed with its client_id; the
    server must answer with the SAME party, never a twin."""
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000511",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="S")
        self.client.force_authenticate(self.owner)

    def post(self, **kw):
        return self.client.post("/api/v1/business/khata/parties",
                                dict({"book": "customer"}, **kw), format="json")

    def test_replay_with_client_id_returns_the_same_party(self):
        a = self.post(name="Rahim", client_id="kx-abc123-offline1")
        b = self.post(name="Rahim", client_id="kx-abc123-offline1")
        self.assertEqual(a.status_code, 201)
        self.assertEqual(b.status_code, 200)
        self.assertEqual(a.data["id"], b.data["id"])
        self.assertTrue(b.data["existing"])
        self.assertEqual(KhataParty.objects.filter(business=self.biz).count(), 1)

    def test_same_phone_is_the_same_person_any_spelling(self):
        a = self.post(name="Karim", phone="01712345678")
        b = self.post(name="Karim bhai", phone="+880 1712-345678")
        self.assertEqual(a.data["id"], b.data["id"])

    def test_two_namesakes_without_phone_are_two_parties(self):
        a = self.post(name="Rahim", client_id="kx-one-000001")
        b = self.post(name="Rahim", client_id="kx-two-000002")
        self.assertNotEqual(a.data["id"], b.data["id"])
        # the marker never leaks into the app's rows
        rows = self.client.get("/api/v1/business/khata/parties?book=customer").data["parties"]
        self.assertFalse(any("cid:" in str(r) for r in rows))


class KhataExportTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000611",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="S")
        self.client.force_authenticate(self.owner)

    def test_whole_khata_as_csv_bangla_and_safe(self):
        c = KhataParty.objects.create(business=self.biz, book="customer",
                                      name="Karim", phone="01712345678")
        s = KhataParty.objects.create(business=self.biz, book="supplier", name="Mill")
        now = timezone.now()
        KhataEntry.objects.create(party=c, direction="gave", amount_poisha=150000,
                                  note="=HYPERLINK(1)", at=now)
        KhataEntry.objects.create(party=c, direction="got", amount_poisha=50000, at=now)
        KhataEntry.objects.create(party=s, direction="got", amount_poisha=90000, at=now)
        r = self.client.get("/api/v1/business/khata/export", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertEqual((r.data["parties"], r.data["entries"]), (2, 3))
        csv = r.data["csv"]
        self.assertIn("গ্রাহক,Karim,01712345678,,1000.00", csv)
        self.assertIn("সাপ্লায়ার,Mill", csv)
        self.assertIn("'=HYPERLINK(1)", csv)          # never a live formula
        self.assertTrue(r.data["filename"].endswith(".csv"))

    def test_staff_cannot_export(self):
        staff = User.objects.create_user(name="T", phone="+8801999000612", password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff")
        self.client.force_authenticate(staff)
        r = self.client.get("/api/v1/business/khata/export?business=%d" % self.biz.id)
        self.assertEqual(r.status_code, 403)


class StaffTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000711",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="S")
        self.client.force_authenticate(self.owner)

    def test_add_list_remove_staff_and_staff_sees_the_shop(self):
        r = self.client.post("/api/v1/business/staff", {"phone": "01999000799"},
                             format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.data.get("error"), "staff_not_on_assisto")
        staff = User.objects.create_user(name="Rafiq", phone="+8801999000712",
                                         password="pw123456")
        r = self.client.post("/api/v1/business/staff", {"phone": "০১৯৯৯০০০৭১২"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertNotIn("712", r.data["phone_masked"][:-3])     # masked
        sid = r.data["id"]
        self.assertEqual(len(self.client.get("/api/v1/business/staff").data["staff"]), 1)
        # the staff phone now lists the shop with role staff
        self.client.force_authenticate(staff)
        rows = self.client.get("/api/v1/business/profiles").data["businesses"]
        self.assertTrue(any(b["id"] == self.biz.id and b["role"] == "staff" for b in rows))
        self.assertEqual(self.client.get("/api/v1/business/staff?business=%d" % self.biz.id)
                         .status_code, 403)                    # staff can't manage staff
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.post("/api/v1/business/staff/%d/remove" % sid)
                         .status_code, 200)
        self.client.force_authenticate(staff)
        r = self.client.get("/api/v1/business/cashbox/%s?business=%d" % (today(), self.biz.id))
        self.assertEqual(r.status_code, 403)                   # access gone

    def test_owner_cannot_add_self(self):
        r = self.client.post("/api/v1/business/staff", {"phone": "01999000711"},
                             format="json")
        self.assertEqual(r.status_code, 422)
