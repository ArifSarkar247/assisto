"""m2-reality — regression tests for the C-class bugs the reality audit found
(route_check + static sweep). Each test is a real HTTP round-trip."""
from io import StringIO

from django.core.management import call_command
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .models import CircleMember, User


def _client(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=user)[0].key)
    return c


class CircleOneToOneDeliveryTests(TestCase):
    """Before: CircleKeysView discarded the key (peer never got public_key) and
    a message lived only on the sender's edge (the peer's GET never saw it)."""

    def setUp(self):
        self.a = User.objects.create_user(name="A", phone="01811111111", password="x12345")
        self.b = User.objects.create_user(name="B", phone="01822222222", password="x12345")
        self.ca, self.cb = _client(self.a), _client(self.b)
        r = self.ca.post("/api/v1/circle/request",
                         {"phone": "01822222222", "name": "B"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.a_edge = r.json()["id"]
        inc = CircleMember.objects.get(user=self.b, peer_user=self.a)
        self.b_edge = inc.id
        r = self.cb.post(f"/api/v1/circle/request/{inc.id}/act", {"event": "accept"},
                         format="json")
        self.assertEqual(r.status_code, 200)

    def test_published_key_reaches_peer(self):
        r = self.cb.post("/api/v1/circle/keys",
                         {"public_key": "QkJCQg==", "key_id": "kb", "scheme": "x25519"},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["edges"], 1)
        rows = self.ca.get("/api/v1/circle/members").json()
        rows = rows.get("results", rows) if isinstance(rows, dict) else rows
        mine = [m for m in rows if m["id"] == self.a_edge][0]
        self.assertEqual(mine["public_key"], "QkJCQg==")

    def test_key_published_before_connecting_is_carried(self):
        c = User.objects.create_user(name="C", phone="01833333333", password="x12345")
        cc = _client(c)
        # C already has an edge pointing at them from A? No: publish first via B.
        self.cb.post("/api/v1/circle/request", {"phone": "01833333333"}, format="json")
        cc.post("/api/v1/circle/keys", {"public_key": "Q0NDQw==", "key_id": "kc"},
                format="json")
        # A connects to C later -> A's new edge already carries C's key
        r = self.ca.post("/api/v1/circle/request", {"phone": "01833333333"}, format="json")
        self.assertEqual(r.json()["public_key"], "Q0NDQw==")

    def test_peer_receives_message(self):
        r = self.ca.post(f"/api/v1/circle/{self.a_edge}/messages",
                         {"content_type": "text", "ciphertext": "AAAA", "nonce": "BBBB",
                          "client_msg_id": "m1"}, format="json")
        self.assertEqual(r.status_code, 201)
        got = self.cb.get(f"/api/v1/circle/{self.b_edge}/messages").json()["results"]
        self.assertEqual(len(got), 1)
        self.assertFalse(got[0]["mine"])
        self.assertEqual(got[0]["ciphertext"], "AAAA")
        # and the sender still sees it as theirs
        own = self.ca.get(f"/api/v1/circle/{self.a_edge}/messages").json()["results"]
        self.assertTrue(own[0]["mine"])
        # recipient can react to it
        mid = got[0]["id"]
        r = self.cb.post(f"/api/v1/circle/messages/{mid}/react", {"emoji": "x"},
                         format="json")
        self.assertNotEqual(r.status_code, 404)

    def test_stranger_cannot_read_thread(self):
        self.ca.post(f"/api/v1/circle/{self.a_edge}/messages",
                     {"content_type": "text", "ciphertext": "AAAA", "nonce": "BBBB"},
                     format="json")
        z = User.objects.create_user(name="Z", phone="01899999999", password="x12345")
        r = _client(z).get(f"/api/v1/circle/{self.b_edge}/messages")
        self.assertEqual(r.status_code, 404)


class BusinessWriteRouteTests(TestCase):
    """Before: product edit / customer save / merchant-QR save POSTed to views
    that had no POST handler (405) — the forms silently never saved."""

    def setUp(self):
        self.u = User.objects.create_user(name="Shop", phone="01844444444", password="x12345")
        self.c = _client(self.u)
        self.c.post("/api/v1/business/profiles", {"name": "S"}, format="json")

    def test_product_cost_kept_and_edit_saves(self):
        r = self.c.post("/api/v1/business/products",
                        {"name": "Rice", "price": "80", "cost_price": "70", "stock": 5},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        pid = r.json()["id"]
        from .models import Product
        self.assertEqual(float(Product.objects.get(pk=pid).cost_price), 70.0)
        r = self.c.post(f"/api/v1/business/products/{pid}",
                        {"name": "Rice 1kg", "price": "85", "stock": 9}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        p = Product.objects.get(pk=pid)
        self.assertEqual((p.name, float(p.price), p.stock), ("Rice 1kg", 85.0, 9))
        self.assertEqual(self.c.delete(f"/api/v1/business/products/{pid}").status_code, 204)

    def test_customer_save_upserts_by_phone(self):
        r = self.c.post("/api/v1/business/customers",
                        {"name": "Karim", "phone": "01855555555"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        r2 = self.c.post("/api/v1/business/customers",
                         {"name": "Karim Bhai", "phone": "01855555555"}, format="json")
        self.assertEqual(r2.json()["id"], r.json()["id"])
        rows = self.c.get("/api/v1/business/customers").json()
        self.assertTrue(any(c.get("name") == "Karim Bhai" for c in rows.get("customers", [])))

    def test_merchant_qr_save(self):
        r = self.c.post("/api/v1/business/payments/qr",
                        {"provider": "bkash", "merchant_number": "01866666666",
                         "merchant_name": "S"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        g = self.c.get("/api/v1/business/payments/qr").json()
        self.assertNotEqual(g.get("error"), "needs_setup")


class NotifReminderDoneTests(TestCase):
    def test_done_marks_reminder(self):
        u = User.objects.create_user(name="N", phone="01877777777", password="x12345")
        c = _client(u)
        rid = c.post("/api/v1/reminders/", {"title": "Pay bill"}, format="json").json()["id"]
        r = c.post(f"/api/v1/notif/reminders/reminder:{rid}/done", {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["persisted"])
        self.assertTrue(u.reminders.get(pk=rid).done)
        r = c.post("/api/v1/notif/reminders/medicine:1:am/done", {}, format="json")
        self.assertFalse(r.json()["persisted"])  # honest: not completed here


class SeedRealityTests(TestCase):
    def test_seed_runs_clean(self):
        out = StringIO()
        import tempfile, os, json
        f = os.path.join(tempfile.mkdtemp(), "seed.json")
        call_command("seed_reality", out=f, stdout=out)
        d = json.load(open(f))
        self.assertEqual(d["failed_steps"], [], d["failed_steps"])
        self.assertEqual(d["circle"]["a_state"], "accepted")
        self.assertEqual(d["circle"]["b_state"], "accepted")
