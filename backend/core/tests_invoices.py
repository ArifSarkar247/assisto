"""invoices — VAT/SD math, settings rules, sale + manual invoice API, the
signed QR token and the public /r/<token> check page."""
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import invoice_calc as IC
from core.models import (BusinessProfile, BusinessStaff, Customer, Sale,
                         SaleLine, User)


class VatMathTests(TestCase):
    def test_exclusive_standard_rate(self):
        c = IC.compute([{"qty": 2, "unit": 10000}], vat_mode="exclusive", vat_bp=1500)
        self.assertEqual((c["subtotal"], c["taxable"], c["vat"], c["total"]),
                         (20000, 20000, 3000, 23000))

    def test_inclusive_splits_without_growing_total(self):
        c = IC.compute([{"qty": 1, "unit": 11500}], vat_mode="inclusive", vat_bp=1500)
        self.assertEqual((c["taxable"], c["vat"], c["total"]), (10000, 1500, 11500))

    def test_inclusive_rounding_always_sums_to_gross(self):
        for gross in (1, 99, 10000, 12345, 999999, 7777777):
            c = IC.compute([{"qty": 1, "unit": gross}], vat_mode="inclusive",
                           vat_bp=1500, sd_bp=1000)
            self.assertEqual(c["taxable"] + c["sd"] + c["vat"], gross)
            self.assertEqual(c["total"], gross)
        c = IC.compute([{"qty": 1, "unit": 10000}], vat_mode="inclusive", vat_bp=1500)
        self.assertEqual((c["taxable"], c["vat"]), (8696, 1304))

    def test_sd_then_vat_on_value_plus_sd(self):
        c = IC.compute([{"qty": 1, "unit": 10000}], vat_mode="exclusive",
                       vat_bp=1500, sd_bp=1000)
        self.assertEqual((c["sd"], c["vat"], c["total"]), (1000, 1650, 12650))
        back = IC.compute([{"qty": 1, "unit": 12650}], vat_mode="inclusive",
                          vat_bp=1500, sd_bp=1000)
        self.assertEqual((back["taxable"], back["sd"], back["vat"]), (10000, 1000, 1650))

    def test_discount_and_service_charge(self):
        c = IC.compute([{"qty": 1, "unit": 10000}], vat_mode="exclusive",
                       vat_bp=1500, discount=1000, service_bp=1000)
        self.assertEqual((c["service"], c["taxable"], c["vat"], c["total"]),
                         (900, 9900, 1485, 11385))

    def test_none_has_no_tax_and_clamps_discount(self):
        c = IC.compute([{"qty": 3, "unit": 500}], vat_mode="none", vat_bp=1500,
                       discount=99999)
        self.assertEqual((c["discount"], c["vat"], c["vat_bp"], c["total"]),
                         (1500, 0, 0, 0))


class SettingsRuleTests(TestCase):
    def test_only_standard_rate_prefilled_and_caps(self):
        s = IC.default_settings("Dokan")
        self.assertEqual(s["vat_bp"], 1500)
        s2, err = IC.normalize_settings({"vat_bp": 9000, "sd_bp": -5}, s)
        self.assertEqual((s2["vat_bp"], s2["sd_bp"]), (1500, 0))
        self.assertEqual(err, [])

    def test_vat_needs_bin_and_bin_format(self):
        _, err = IC.normalize_settings({"vat_mode": "exclusive"})
        self.assertIn("bin_required", err)
        _, err = IC.normalize_settings({"vat_mode": "inclusive", "bin": "12345"})
        self.assertIn("bin", err)
        s, err = IC.normalize_settings({"vat_mode": "inclusive",
                                        "bin": "000123456-0101"})
        self.assertEqual(err, [])
        s, err = IC.normalize_settings({"bin": "1234567890123"})
        self.assertEqual(err, [])

    def test_payment_link_https_only_and_template(self):
        _, err = IC.normalize_settings({"payment_link": "http://x.y"})
        self.assertIn("payment_link", err)
        _, err = IC.normalize_settings({"template": "casino"})
        self.assertIn("template", err)
        self.assertEqual(len(IC.TEMPLATES), 9)

    def test_token_roundtrip_and_tamper(self):
        t = IC.token_for("s", 42)
        self.assertEqual(IC.parse_token(t), ("s", 42))
        self.assertIsNone(IC.parse_token(t.replace("s42", "s43")))
        self.assertIsNone(IC.parse_token("garbage"))
        self.assertEqual(IC.number("SV", 7), "SV-0007")


class InvoiceApiTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000611",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Cafe Dhaka")
        self.client.force_authenticate(self.owner)

    def _sale(self, total=23000, discount=0, voided=False):
        cust = Customer.objects.create(user=self.owner, business=self.biz,
                                       name="Karim", phone="01711000000",
                                       address="Mirpur 10")
        s = Sale.objects.create(user=self.owner, business=self.biz, customer=cust,
                                subtotal=total + discount, discount=discount,
                                total=total, paid=total, payment_method="cash",
                                voided_at=timezone.now() if voided else None)
        SaleLine.objects.create(sale=s, product_name="Latte", qty=1,
                                unit_price=total + discount)
        return s

    def test_settings_default_then_save_and_staff_cannot_edit(self):
        r = self.client.get("/api/v1/business/invoice/settings")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["saved"])
        self.assertEqual(r.data["settings"]["name"], "Cafe Dhaka")
        r = self.client.put("/api/v1/business/invoice/settings",
                            {"vat_mode": "inclusive"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertIn("bin_required", r.data["fields"])
        r = self.client.put("/api/v1/business/invoice/settings",
                            {"vat_mode": "inclusive", "bin": "0001234560101",
                             "template": "cafe", "address": "Dhanmondi"},
                            format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["settings"]["template"], "cafe")
        staff = User.objects.create_user(name="S", phone="+8801999000612",
                                         password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff)
        self.client.force_authenticate(staff)
        r = self.client.get("/api/v1/business/invoice/settings?business=%d" % self.biz.id)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["can_edit"])
        r = self.client.put("/api/v1/business/invoice/settings?business=%d" % self.biz.id,
                            {"footer": "x"}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_sale_invoice_plain_then_vat_inclusive_equals_charged(self):
        s = self._sale(total=11500)
        r = self.client.get("/api/v1/business/sales/%d/invoice" % s.id)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["number"], "S-0001")
        self.assertEqual(r.data["calc"]["vat"], 0)
        self.assertEqual(r.data["buyer"]["name"], "Karim")
        self.assertTrue(r.data["verify_url"].startswith("http"))
        self.assertIn("/r/s%d." % s.id, r.data["verify_url"])
        self.client.put("/api/v1/business/invoice/settings",
                        {"vat_mode": "exclusive", "bin": "000123456-0101"},
                        format="json")
        r = self.client.get("/api/v1/business/sales/%d/invoice" % s.id)
        # a POS sale was charged already: VAT is shown INSIDE the total
        self.assertEqual(r.data["calc"]["vat_mode"], "inclusive")
        self.assertEqual((r.data["calc"]["taxable"], r.data["calc"]["vat"],
                          r.data["calc"]["total"]), (10000, 1500, 11500))
        self.assertTrue(r.data["consistent"])
        lst = self.client.get("/api/v1/business/invoices/sales").data["items"]
        self.assertEqual([i["id"] for i in lst], [s.id])
        self.assertEqual(lst[0]["buyer"], "Karim")

    def test_other_users_sale_is_404(self):
        other = User.objects.create_user(name="O", phone="+8801999000613",
                                         password="pw123456")
        ob = BusinessProfile.objects.create(user=other, shop_name="X")
        s = Sale.objects.create(user=other, business=ob, total=100, paid=100)
        r = self.client.get("/api/v1/business/sales/%d/invoice" % s.id)
        self.assertEqual(r.status_code, 404)

    def test_manual_invoice_flow(self):
        self.client.put("/api/v1/business/invoice/settings",
                        {"vat_mode": "exclusive", "bin": "1234567890123",
                         "template": "lawyer"}, format="json")
        r = self.client.post("/api/v1/business/invoices", {
            "buyer": {"name": "ABC Ltd", "bin": "123"},
            "lines": [{"desc": "Consultation", "qty": 2, "unit": 500000}]},
            format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["error"], "buyer_bin")
        r = self.client.post("/api/v1/business/invoices", {"buyer": {"name": "A"},
                                                            "lines": []}, format="json")
        self.assertEqual(r.data["error"], "lines")
        r = self.client.post("/api/v1/business/invoices", {
            "buyer": {"name": "ABC Ltd"}, "extras": {"case_ref": "CR-12", "bogus": "x"},
            "lines": [{"desc": "Consultation", "qty": 2, "unit": 500000}],
            "paid": 100000}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["number"], "SV-0001")
        self.assertEqual(r.data["extras"], {"case_ref": "CR-12"})
        self.assertEqual((r.data["calc"]["vat"], r.data["calc"]["total"]),
                         (150000, 1150000))
        self.assertEqual(r.data["due"], 1050000)
        iid = r.data["id"]
        r2 = self.client.post("/api/v1/business/invoices", {
            "buyer": {"name": "B"}, "no_vat": True,
            "lines": [{"desc": "Filing", "qty": 1, "unit": 100000}]}, format="json")
        self.assertEqual(r2.data["number"], "SV-0002")
        self.assertEqual(r2.data["calc"]["vat"], 0)
        lst = self.client.get("/api/v1/business/invoices").data["items"]
        self.assertEqual([i["number"] for i in lst], ["SV-0002", "SV-0001"])
        self.assertEqual(self.client.get("/api/v1/business/invoices/%d" % iid)
                         .data["number"], "SV-0001")
        r = self.client.post("/api/v1/business/invoices/%d/cancel" % iid, {}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.client.post("/api/v1/business/invoices/%d/cancel" % iid,
                             {"reason": "wrong client"}, format="json")
        self.assertTrue(r.data["cancelled"])

    def test_public_check_page(self):
        s = self._sale(total=11500)
        url = IC.verify_path("s", s.id)
        self.client.force_authenticate(None)
        r = self.client.get(url)
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertIn("S-০০০১", body)
        self.assertIn("৳১১৫", body)
        self.assertNotIn("Karim", body)       # buyer never shown publicly
        self.assertEqual(r["X-Robots-Tag"], "noindex, nofollow")
        r = self.client.get(url + "?lang=en")
        self.assertIn("S-0001", r.content.decode())
        r = self.client.get("/r/s%d.forged" % s.id)
        self.assertEqual(r.status_code, 404)
        s.voided_at = timezone.now()
        s.save()
        r = self.client.get(url + "?lang=en")
        self.assertIn("CANCELLED", r.content.decode())
