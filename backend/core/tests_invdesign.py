"""invdesign — invoice designs by business type: suggested template, brand
settings (accent/logo/bilingual), fractional hours, per-line serial/warranty,
POS sale invoice details and the online-order delivery charge fix."""
import base64
from decimal import Decimal

from django.test import TestCase
from rest_framework.test import APITestCase

from core.logic import invoice_calc as IC
from core.models import (BusinessProfile, BusinessStaff, Order, PaCollectionItem,
                         Sale, SaleLine, User)

PNG_1PX = base64.b64encode(
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08"
    b"\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00"
    b"\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82").decode()


class DesignLogicTests(TestCase):
    def test_vat_invoice_template_and_fields(self):
        self.assertIn("vat_invoice", IC.TEMPLATES)
        self.assertEqual(IC.TEMPLATE_FIELDS["vat_invoice"], ("destination", "vehicle"))
        self.assertIn("tracking", IC.TEMPLATE_FIELDS["ecommerce"])
        self.assertIn("matter", IC.TEMPLATE_FIELDS["lawyer"])

    def test_suggest_template(self):
        self.assertEqual(IC.suggest_template("food"), "restaurant")
        self.assertEqual(IC.suggest_template("electronics"), "electronics")
        self.assertEqual(IC.suggest_template("education"), "service")
        self.assertEqual(IC.suggest_template("fashion", has_online_orders=True), "ecommerce")
        self.assertEqual(IC.suggest_template("grocery", sells_by_delivery=True), "ecommerce")
        self.assertEqual(IC.suggest_template("", vat_ready=True), "vat_invoice")
        self.assertEqual(IC.suggest_template("other"), "retail")
        self.assertEqual(IC.suggest_template(""), "retail")

    def test_accent_logo_lang_rules(self):
        s, err = IC.normalize_settings({"accent": "teal", "lang": "both", "logo": PNG_1PX})
        self.assertEqual(err, [])
        self.assertEqual((s["accent"], s["lang"], s["logo"]), ("teal", "both", PNG_1PX))
        _, err = IC.normalize_settings({"accent": "#ff0000"})
        self.assertIn("accent", err)
        _, err = IC.normalize_settings({"logo": base64.b64encode(b"GIF89a....").decode()})
        self.assertIn("logo", err)
        _, err = IC.normalize_settings({"logo": "not base64 !!"})
        self.assertIn("logo", err)
        big = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * (IC.LOGO_MAX_BYTES + 1)).decode()
        _, err = IC.normalize_settings({"logo": big})
        self.assertIn("logo", err)
        s, err = IC.normalize_settings({"logo": ""}, s)
        self.assertEqual((s["logo"], err), ("", []))

    def test_fractional_hours_and_line_details(self):
        lines = IC.clean_lines([
            {"desc": "Consulting", "qty": "1.5", "unit": 200000},
            {"desc": "Phone", "qty": 1, "unit": 2500000, "serial": " 356938035643809 ",
             "warranty_m": 12},
            {"desc": "x", "qty": 1, "unit": 1, "warranty_m": 999}])
        self.assertEqual(lines[0]["qty_c"], 150)
        self.assertEqual(IC.line_amount(lines[0]), 300000)
        self.assertNotIn("qty_c", lines[1])
        self.assertEqual((lines[1]["serial"], lines[1]["warranty_m"]), ("356938035643809", 12))
        self.assertEqual(lines[2]["warranty_m"], IC.MAX_WARRANTY_M)
        self.assertIsNone(IC.clean_lines([{"desc": "a", "qty": "abc", "unit": 1}]))
        self.assertIsNone(IC.clean_lines([{"desc": "a", "qty": 0, "unit": 1}]))
        c = IC.compute(lines[:1], vat_mode="exclusive", vat_bp=1500)
        self.assertEqual((c["subtotal"], c["vat"], c["total"]), (300000, 45000, 345000))

    def test_shipping_added_after_tax(self):
        c = IC.compute([{"qty": 1, "unit": 11500}], vat_mode="inclusive", vat_bp=1500,
                       shipping=6000)
        self.assertEqual((c["taxable"], c["vat"], c["shipping"], c["total"]),
                         (10000, 1500, 6000, 17500))
        c = IC.compute([{"qty": 1, "unit": 100}], shipping=-5)
        self.assertEqual((c["shipping"], c["total"]), (0, 100))


class DesignApiTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000711",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Gadget BD")
        self.client.force_authenticate(self.owner)

    def _sale(self, total=2500000, lines=((1, 2500000),)):
        s = Sale.objects.create(user=self.owner, business=self.biz, subtotal=total,
                                total=total, paid=total, payment_method="cash")
        for i, (q, u) in enumerate(lines):
            SaleLine.objects.create(sale=s, product_name="Item %d" % i, qty=q, unit_price=u)
        return s

    def test_suggested_template_from_business_type(self):
        PaCollectionItem.objects.create(user=self.owner, collection="mkt_profile", data={
            "business_id": self.biz.id, "answers": {"business_type": "electronics"}})
        r = self.client.get("/api/v1/business/invoice/settings")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["suggested_template"], "electronics")
        self.assertEqual(r.data["settings"]["template"], "electronics")  # not saved yet
        self.assertIn("teal", r.data["accents"])
        r = self.client.post("/api/v1/business/invoice/settings",
                             {"template": "retail", "accent": "navy", "lang": "both",
                              "logo": PNG_1PX}, format="json")
        self.assertEqual(r.status_code, 200)
        r = self.client.get("/api/v1/business/invoice/settings")
        self.assertEqual(r.data["settings"]["template"], "retail")   # owner's choice wins
        self.assertEqual(r.data["suggested_template"], "electronics")
        self.assertEqual((r.data["settings"]["accent"], r.data["settings"]["lang"]),
                         ("navy", "both"))
        r = self.client.post("/api/v1/business/invoice/settings", {"accent": "red"},
                             format="json")
        self.assertEqual(r.status_code, 400)

    def test_sale_details_print_serial_never_money(self):
        s = self._sale(total=2600000, lines=((1, 2500000), (2, 50000)))
        r = self.client.post("/api/v1/business/sales/%d/invoice/details" % s.id, {
            "template": "electronics", "extras": {"warranty": "Brand", "table": "7"},
            "lines": {"0": {"serial": "IMEI 356938035643809", "warranty_m": 12},
                      "5": {"serial": "out of range"}, "x": {"serial": "bad"}},
            "total": 1}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["template"], "electronics")
        self.assertEqual(r.data["extras"], {"warranty": "Brand"})
        self.assertEqual(r.data["lines"][0]["serial"], "IMEI 356938035643809")
        self.assertEqual(r.data["lines"][0]["warranty_m"], 12)
        self.assertNotIn("serial", r.data["lines"][1])
        self.assertEqual(r.data["calc"]["total"], 2600000)
        self.assertTrue(r.data["consistent"])
        r = self.client.get("/api/v1/business/sales/%d/invoice" % s.id)
        self.assertTrue(r.data["details_saved"])
        self.assertEqual(r.data["lines"][0]["warranty_m"], 12)
        r = self.client.post("/api/v1/business/sales/%d/invoice/details" % s.id,
                             {"template": "bogus"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_other_business_cannot_fill_details(self):
        s = self._sale()
        other = User.objects.create_user(name="O", phone="+8801999000712", password="pw123456")
        BusinessProfile.objects.create(user=other, shop_name="X")
        self.client.force_authenticate(other)
        r = self.client.post("/api/v1/business/sales/%d/invoice/details" % s.id,
                             {"lines": {"0": {"serial": "x"}}}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_staff_can_fill_details(self):
        s = self._sale()
        staff = User.objects.create_user(name="S", phone="+8801999000713", password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff)
        self.client.force_authenticate(staff)
        r = self.client.post("/api/v1/business/sales/%d/invoice/details?business=%d"
                             % (s.id, self.biz.id),
                             {"lines": {"0": {"serial": "SN-1"}}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def test_online_order_sale_includes_delivery_and_courier(self):
        # bizagent.record_sale: sale.total = items + delivery charge
        s = self._sale(total=160000, lines=((1, 100000),))
        Order.objects.create(user=self.owner, business=self.biz, sale=s,
                             customer_name="Rina", address="House 4, Uttara",
                             courier="pathao", consignment_id="PX123",
                             delivery_charge=Decimal("600.00"), total=Decimal("1600"))
        r = self.client.get("/api/v1/business/sales/%d/invoice" % s.id)
        self.assertEqual(r.data["calc"]["shipping"], 60000)
        self.assertEqual(r.data["calc"]["total"], 160000)
        self.assertTrue(r.data["consistent"])   # was False before invdesign
        self.assertEqual(r.data["extras"]["courier"], "pathao")
        self.assertEqual(r.data["extras"]["tracking"], "PX123")
        self.assertEqual(r.data["extras"]["delivery_address"], "House 4, Uttara")

    def test_manual_invoice_hours(self):
        r = self.client.post("/api/v1/business/invoices", {
            "template": "service", "buyer": {"name": "ABC Ltd"}, "by_hours": True,
            "lines": [{"desc": "Design work", "qty": "2.25", "unit": 150000}]},
            format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["lines"][0]["qty_c"], 225)
        self.assertEqual(r.data["lines"][0]["amount"], 337500)
        self.assertEqual(r.data["calc"]["total"], 337500)
        self.assertTrue(r.data["by_hours"])
