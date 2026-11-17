"""gap-money — feature gap lane for Mess and Money (owner order 17 Nov 10:10).

Every gap fixed here gets a test (owner_actions/gaps/money_BN.md):
  * the mess month PDF draws Bangla through pdf_bn (shaped, real table);
  * a due reminder is never sent to someone who already paid after the close,
    and a part-payment reminds only the amount still left.
"""
from django.test import SimpleTestCase

from core.models import MessMember

from .tests_messv2 import V, _Base


class MessPdfBanglaTests(_Base):
    def _month(self):
        m = self.make_mess()
        mid = m["id"]
        self.add(mid, self.eb)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-01", "amount": 100000}, 201)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-02", "amount": 70000,
                   "data": {"kind": "wifi"}}, 201)
        return mid

    def test_open_and_closed_month_pdf_use_the_shaped_bangla_face(self):
        mid = self._month()
        r = self.cl["a"].get(V + f"/mess/v2/{mid}/report?pdf=1", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsBn", r.content)       # pdf_bn's shaped Noto Bengali
        self.clock.set(2026, 11, 30, 23)
        self.post("a", f"/mess/v2/{mid}/close", {}, 200)
        r = self.cl["b"].get(V + f"/mess/v2/{mid}/report?month=2026-11&pdf=1",
                             HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertIn(b"AssistoAsBn", r.content)

    def test_english_pdf_renders(self):
        mid = self._month()
        r = self.cl["a"].get(V + f"/mess/v2/{mid}/report?pdf=1", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsLat", r.content)

    def test_pdf_builder_lines_up_with_the_math(self):
        """The table is built from the same settlement the screen shows."""
        from core import views_mess as VM
        from core.models import Mess
        mid = self._month()
        mess = Mess.objects.get(pk=mid)
        start, end = VM._period(mess, VM._today())
        s = VM.compute_month(mess, start, end)
        self.assertTrue(s["reconciles"])
        self.assertEqual(sum(r["meal_cost"] for r in s["members"]), 100000)
        self.assertEqual(sum(r["service"] for r in s["members"]), 70000)
        for lang in ("bn", "en"):
            self.assertTrue(VM._pdf(mess, "2026-11", s, lang).startswith(b"%PDF"))


class MessRemindAfterPaymentTests(_Base):
    def test_paid_member_is_not_reminded_and_part_payment_reminds_the_rest(self):
        m = self.make_mess()
        mid = m["id"]
        self.add(mid, self.eb)
        # bazar ৳1,000 -> each of the two will pay ৳500 (both ON all month)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-01", "amount": 100000}, 201)
        self.clock.set(2026, 11, 30, 23)
        s = self.post("a", f"/mess/v2/{mid}/close", {}, 200).json()["summary"]
        dues = sorted(r["due"] for r in s["members"])
        self.assertEqual(dues, [50000, 50000])
        self.clock.set(2026, 12, 2, 10)
        self.clock.push.reset_mock()
        # B pays the whole ৳500 to the manager after the close
        self.post("b", f"/mess/v2/{mid}/entries",
                  {"kind": "deposit", "amount": 50000}, 201)
        # A pays ৳200 of ৳500
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "deposit", "amount": 20000}, 201)
        n = self.post("a", f"/mess/v2/{mid}/remind", {}, 200).json()["sent"]
        self.assertEqual(n, 1)
        args = self.clock.push.call_args[0]
        self.assertEqual(args[0], self.a)
        self.assertIn("৳300.00", args[4])               # en body: only what is left
        self.assertIn("৳৩০০.০০", args[3])               # bn body in Bangla digits
        # targeted reminder to B (fully paid) sends nothing
        bid = MessMember.objects.get(mess_id=mid, user=self.b).id
        n = self.post("a", f"/mess/v2/{mid}/remind", {"member_id": bid}, 200).json()["sent"]
        self.assertEqual(n, 0)


class ServerParserTests(SimpleTestCase):
    """Money typed in any common way is read to the exact poisha."""

    def test_khata_refuses_an_exponent_instead_of_guessing(self):
        from core.logic import business_khata as K
        self.assertEqual(K.to_poisha("1e3"), 0)           # was ৳13
        self.assertEqual(K.to_poisha("৳১,২৫০.৫০"), 125050)
        self.assertEqual(K.to_poisha("Tk 500"), 50000)

    def test_landlord_commas_and_half_up(self):
        from core.logic import landlord_tenant as LT
        self.assertEqual(LT.to_poisha("1,500"), 150000)  # was 0
        self.assertEqual(LT.to_poisha("12.345"), 1235)   # was 1234 (half-even)
        self.assertEqual(LT.to_poisha("১২০০০.৫০"), 1200050)
        self.assertEqual(LT.to_poisha("NaN"), 0)
        self.assertEqual(LT.to_poisha("bad"), 0)
