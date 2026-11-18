"""proof-ledger (18 Nov) — the offline cashbox row is booked exactly once,
and the SERVER money parsers read "Tk. 500" / "৫০০/-" like the app does.

Before: a cashbox cash-in/out had no client_id at all — a phone that lost the
answer and tried again booked the money twice, so the app could not keep a
row offline safely. And core.logic.business_khata.to_poisha("Tk. 500") was 50
poisha (".500"), "500/-" was 0 — the app's b326 P0 bug, still on the server.
"""
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import business_khata as K
from core.logic import business_selling as S
from core.models import BusinessProfile, CashEntry, User

CB = "/api/v1/business/cashbox"


def today():
    return timezone.localdate().isoformat()


class ServerMoneyParserTests(TestCase):
    def test_khata_to_poisha_reads_bangladeshi_money_text(self):
        cases = {
            "Tk. 500": 50000, "Tk.500": 50000, "tk 500": 50000, "Tk500": 50000,
            "500tk": 50000, "BDT 1,250.50": 125050, "৳১,২৫০": 125000,
            "৫০০ টাকা": 50000, "৫০০/-": 50000, "500/=": 50000, "500": 50000,
            "12.345": 1235,
        }
        for raw, want in cases.items():
            self.assertEqual(K.to_poisha(raw), want, raw)
        # still refused / unchanged
        self.assertEqual(K.to_poisha("1e3"), 0)
        self.assertEqual(K.to_poisha(500), 500)          # ints are poisha
        self.assertEqual(K.to_poisha(""), 0)

    def test_pos_taka_to_poisha_reads_tk_dot(self):
        for raw, want in {"Tk. 500": 50000, "Tk.500": 50000, "৳1,234.50": 123450,
                          "500/-": 50000, "500 টাকা": 50000, "TK 20": 2000}.items():
            self.assertEqual(S.taka_to_poisha(raw), want, raw)

    def test_cash_entry_refuses_minus_and_zero(self):
        with self.assertRaises(ValueError):
            K.cash_entry("in", "-500")
        with self.assertRaises(ValueError):
            K.cash_entry("in", "Tk. 0")
        self.assertEqual(K.cash_entry("in", "Tk. 500")["amount"], 50000)


class CashboxOfflineReplayTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000811",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Proof Store")
        self.client.force_authenticate(self.owner)

    def _post(self, **body):
        b = {"business_id": self.biz.id, "kind": "in", "amount": 50000, "note": "sale"}
        b.update(body)
        return self.client.post("%s/%s/entries" % (CB, today()), b, format="json")

    def test_same_client_id_is_booked_once(self):
        r1 = self._post(client_id="cb-proof-0001")
        self.assertEqual(r1.status_code, 201, r1.data)
        self.assertFalse(r1.data["duplicate"])
        # the answer was lost: the phone replays the same row
        r2 = self._post(client_id="cb-proof-0001")
        self.assertEqual(r2.status_code, 200, r2.data)
        self.assertTrue(r2.data["duplicate"])
        self.assertEqual(r2.data["entry_id"], r1.data["entry_id"])
        self.assertEqual(CashEntry.objects.filter(day__business=self.biz).count(), 1)
        self.assertEqual(r2.data["expected_poisha"], r1.data["expected_poisha"])
        # the marker is never shown as a reference; the id is echoed
        row = [e for e in r2.data["entries"] if e["id"] == r1.data["entry_id"]][0]
        self.assertEqual(row["ref"], "")
        self.assertEqual(row["client_id"], "cb-proof-0001")

    def test_two_rows_two_client_ids(self):
        self._post(client_id="cb-proof-a001", amount=50000)
        self._post(client_id="cb-proof-b002", kind="out", amount=12500)
        r = self.client.get("%s/%s?business_id=%d" % (CB, today(), self.biz.id))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data["entries"]), 2)
        self.assertEqual(CashEntry.objects.filter(day__business=self.biz).count(), 2)

    def test_replay_on_a_later_day_url_still_once(self):
        # synced after midnight: the app keeps the SAVE day in the URL, but a
        # replay of an already-booked id never makes a second row anywhere
        self._post(client_id="cb-proof-c003")
        r = self.client.post("%s/%s/entries" % (CB, "2030-01-02"),
                             {"business_id": self.biz.id, "kind": "in", "amount": 50000,
                              "client_id": "cb-proof-c003"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["duplicate"])
        self.assertEqual(r.data["day"], today())
        self.assertEqual(CashEntry.objects.filter(day__business=self.biz).count(), 1)

    def test_no_or_bad_client_id_keeps_the_old_behaviour(self):
        self.assertEqual(self._post().status_code, 201)
        self.assertEqual(self._post(client_id="x").status_code, 201)   # too short
        self.assertEqual(CashEntry.objects.filter(day__business=self.biz).count(), 2)

    def test_another_shop_cannot_collide(self):
        self._post(client_id="cb-proof-d004")
        other = User.objects.create_user(name="Other", phone="+8801999000812",
                                         password="pw123456")
        ob = BusinessProfile.objects.create(user=other, shop_name="Other Store")
        self.client.force_authenticate(other)
        r = self.client.post("%s/%s/entries" % (CB, today()),
                             {"business_id": ob.id, "kind": "in", "amount": 100,
                              "client_id": "cb-proof-d004"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(CashEntry.objects.filter(day__business=ob).count(), 1)
        self.assertEqual(CashEntry.objects.filter(day__business=self.biz).count(), 1)
