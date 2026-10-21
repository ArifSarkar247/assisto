"""c1-contacts — "Contacts on Assisto" end-to-end (owner bug).

Root causes covered:
  1. UserPhoneHash rows were never created -> match/search found nobody.
  2. Matching was "verified users only" while OTP is not live -> nobody.
  3. Exact-string phone joins (01… vs +880… vs spaces) never matched.
  4. The contract endpoint never returned the match salt the app reads, so
     the device hashed with an empty key.
Every test is a real HTTP round-trip where an endpoint exists.
"""
import importlib

from django.apps import apps as django_apps
from django.core.cache import cache
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from . import phone as P
from .models import (AdminFlagState, CircleMember, PhoneVerification, User,
                     UserPhoneHash)

OWNER_NO = "01865052200"
CANON = "+8801865052200"


def _client(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token "
                  + Token.objects.get_or_create(user=user)[0].key)
    return c


def _set_flag(fid, value):
    from .logic import admin_flags as AF
    row = AdminFlagState.objects.filter(key="global").first()
    st = AF.normalize_state(row.state if row else {})
    st[fid] = value
    AdminFlagState.objects.update_or_create(key="global", defaults={"state": st})


class CanonicalPhoneTests(TestCase):
    def test_bd_any_format(self):
        for raw in (OWNER_NO, "+8801865052200", "8801865052200",
                    "008801865052200", "+880 1865-052200", "(+880) 1865 052200",
                    "01865-052200", "018.6505.2200", "1865052200",
                    "+880 01865052200", "০১৮৬৫০৫২২০০", "+৮৮০ ১৮৬৫-০৫২২০০"):
            self.assertEqual(P.canonical_phone(raw), CANON, raw)

    def test_rejects_invalid_honestly(self):
        for raw in ("", "   ", "12345", "0186505220", "018650522001",
                    "01265052200", "abc01865052200", "+8801234", "++880",
                    "0000000000"):
            self.assertIsNone(P.canonical_phone(raw), raw)

    def test_foreign_needs_explicit_plus(self):
        self.assertEqual(P.canonical_phone("+1 (415) 555-0100"), "+14155550100")
        self.assertEqual(P.canonical_phone("0044 20 7946 0958"), "+442079460958")
        self.assertIsNone(P.canonical_phone("4155550100"))
        self.assertIsNone(P.canonical_bd("+14155550100"))

    def test_variants_cover_legacy_spellings(self):
        v = P.variants(CANON)
        for legacy in (CANON, "8801865052200", OWNER_NO, "+88001865052200"):
            self.assertIn(legacy, v)

    def test_hash_contract_matches_reference(self):
        from .logic import msg_contacts as mc
        salt = P.match_salt()
        self.assertEqual(P.hash_raw("+880 1865-052200"),
                         mc.hash_phone(mc.normalize_e164(OWNER_NO), salt))
        self.assertEqual(len(P.hash_raw(OWNER_NO)), 32)
        self.assertEqual(P.hash_raw("bad"), "")

    def test_salt_never_exposes_secret_key(self):
        from django.conf import settings
        with self.settings(SERVER_MATCH_SALT=""):
            self.assertNotEqual(P.match_salt(), settings.SECRET_KEY)
            self.assertNotIn(settings.SECRET_KEY, P.match_salt())


class PhoneHashSyncTests(TestCase):
    def test_register_creates_hash_and_phone_change_updates_it(self):
        u = User.objects.create_user(name="A", phone=OWNER_NO, password="x12345")
        u.refresh_from_db()
        self.assertEqual(u.phone, CANON)
        h = UserPhoneHash.objects.get(user=u)
        self.assertEqual(h.phone_hash, P.hash_raw(OWNER_NO))
        u.phone = "017 1100 0222"
        u.save()
        u.refresh_from_db()
        self.assertEqual(u.phone, "+8801711000222")
        self.assertEqual(UserPhoneHash.objects.get(user=u).phone_hash,
                         P.hash_raw("01711000222"))
        u.phone = None
        u.email = "a@example.com"
        u.save()
        self.assertFalse(UserPhoneHash.objects.filter(user=u).exists())

    def test_register_api_canonical_login_any_format(self):
        c = APIClient()
        r = c.post("/api/v1/auth/register",
                   {"name": "R", "phone": "+880 1711-000111",
                    "password": "Strong#Pass123"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(User.objects.get(name="R").phone, "+8801711000111")
        self.assertTrue(UserPhoneHash.objects.filter(user__name="R").exists())
        for ident in ("01711000111", "8801711000111", "০১৭১১০০০১১১"):
            r = c.post("/api/v1/auth/login",
                       {"identifier": ident, "password": "Strong#Pass123"},
                       format="json")
            self.assertEqual(r.status_code, 200, ident)
        # duplicate in another spelling is refused; invalid refused honestly
        r = c.post("/api/v1/auth/register",
                   {"phone": "01711000111", "password": "Strong#Pass123"},
                   format="json")
        self.assertEqual(r.status_code, 400)
        r = c.post("/api/v1/auth/register",
                   {"phone": "12345", "password": "Strong#Pass123"},
                   format="json")
        self.assertEqual(r.status_code, 400)

    def test_legacy_row_login_still_works(self):
        u = User.objects.create_user(name="L", phone=OWNER_NO, password="x12345")
        User.objects.filter(pk=u.pk).update(phone=OWNER_NO)  # pre-0050 row
        r = APIClient().post("/api/v1/auth/login",
                             {"identifier": "+880 1865 052200",
                              "password": "x12345"}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_profile_phone_change_canonical_and_collision(self):
        a = User.objects.create_user(name="A", phone=OWNER_NO, password="x12345")
        b = User.objects.create_user(name="B", phone="01711000333", password="x12345")
        r = _client(b).patch("/api/v1/me", {"phone": "8801711000444"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.content)
        b.refresh_from_db()
        self.assertEqual(b.phone, "+8801711000444")
        self.assertEqual(UserPhoneHash.objects.get(user=b).phone_hash,
                         P.hash_raw("01711000444"))
        r = _client(b).patch("/api/v1/me", {"phone": "+880 1865-052200"},
                             format="json")
        self.assertEqual(r.status_code, 400)
        r = _client(b).patch("/api/v1/me", {"phone": "99"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(User.objects.get(pk=a.pk).phone, CANON)


class ContactsDiscoveryTests(TestCase):
    """Two accounts: B registered as 01865052200, A searches for B."""

    def setUp(self):
        cache.clear()
        self.a = User.objects.create_user(name="Asker", phone="01711000001",
                                          password="x12345")
        self.b = User.objects.create_user(name="Owner B", phone=OWNER_NO,
                                          password="x12345")
        self.ca, self.cb = _client(self.a), _client(self.b)

    def _lookup(self, raw, client=None):
        return (client or self.ca).post("/api/v1/messenger/contacts/lookup",
                                        {"phone": raw}, format="json")

    def test_manual_search_any_format(self):
        for raw in ("+880 1865-052200", "8801865052200", OWNER_NO,
                    "০১৮৬৫০৫২২০০", "(01865) 052200"):
            r = self._lookup(raw)
            self.assertEqual(r.status_code, 200, raw)
            j = r.json()
            self.assertTrue(j["found"], raw)
            self.assertEqual(j["user"]["id"], self.b.id)
            self.assertEqual(j["user"]["name"], "Owner B")
            self.assertEqual(j["phone"], CANON)
            self.assertEqual(j["user"]["circle"]["state"], "none")

    def test_search_unknown_invalid_self(self):
        r = self._lookup("01999888777")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["found"])
        self.assertEqual(r.json()["phone"], "+8801999888777")
        r = self._lookup("12345")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "bad_phone")
        r = self._lookup("+880 1711-000001")
        self.assertTrue(r.json()["is_self"])
        self.assertFalse(r.json()["found"])

    def test_search_rate_limited(self):
        from . import billing
        cfg = billing.cfg()
        from unittest import mock
        cfg["limits"]["contact_lookups_per_hour"] = 2
        with mock.patch("core.billing.cfg", return_value=cfg):
            self.assertEqual(self._lookup(OWNER_NO).status_code, 200)
            self.assertEqual(self._lookup(OWNER_NO).status_code, 200)
            self.assertEqual(self._lookup(OWNER_NO).status_code, 429)

    def _client_hash(self, raw):
        """Hash EXACTLY like the device: contract salt + canonical number."""
        import hashlib
        import hmac
        c = self.ca.get("/api/v1/messenger/contacts/contract").json()
        self.assertTrue(c["salt"])
        self.assertEqual(c["hash_len"], 32)
        self.assertEqual(c["country_code"], "880")
        canon = P.canonical_phone(raw)
        return hmac.new(c["salt"].encode(), canon.encode(),
                        hashlib.sha256).hexdigest()[:c["hash_len"]]

    def test_contacts_match_finds_registered_user(self):
        h = self._client_hash("+880 1865-052200")
        other = self._client_hash("01999888777")  # not on Assisto
        r = self.ca.post("/api/v1/messenger/contacts/match",
                         {"hashes": [h, other], "permission_granted": True},
                         format="json")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertEqual(j["matched_count"], 1)
        self.assertEqual(j["matches"][0]["contact_hash"], h)
        self.assertEqual(j["matches"][0]["user"]["id"], self.b.id)
        self.assertEqual(j["matches"][0]["user"]["circle"]["state"], "none")
        self.assertFalse(j["stored"])
        # never the requester themself
        mine = self._client_hash("01711000001")
        r = self.ca.post("/api/v1/messenger/contacts/match",
                         {"hashes": [mine], "permission_granted": True},
                         format="json")
        self.assertEqual(r.json()["matched_count"], 0)
        # no permission -> nothing looked at
        r = self.ca.post("/api/v1/messenger/contacts/match",
                         {"hashes": [h], "permission_granted": False},
                         format="json")
        self.assertEqual(r.json()["matched_count"], 0)

    def test_flag_off_only_verified_numbers_discoverable(self):
        _set_flag("contacts_match_unverified", False)
        h = self._client_hash(OWNER_NO)
        self.assertFalse(self._lookup(OWNER_NO).json()["found"])
        r = self.ca.post("/api/v1/messenger/contacts/match",
                         {"hashes": [h], "permission_granted": True},
                         format="json")
        self.assertEqual(r.json()["matched_count"], 0)
        self.assertFalse(self.ca.get(
            "/api/v1/messenger/contacts/contract").json()["unverified_matchable"])
        # B proves the number by OTP -> discoverable again
        PhoneVerification.objects.create(user=self.b, phone=CANON)
        self.assertTrue(self._lookup("+880 1865-052200").json()["found"])
        r = self.ca.post("/api/v1/messenger/contacts/match",
                         {"hashes": [h], "permission_granted": True},
                         format="json")
        self.assertEqual(r.json()["matched_count"], 1)

    def test_flag_on_by_default_unverified_matchable(self):
        self.assertFalse(PhoneVerification.objects.filter(user=self.b).exists())
        self.assertTrue(P.allow_unverified_matching())
        self.assertTrue(self._lookup(OWNER_NO).json()["found"])

    def test_circle_request_accept_message_and_call(self):
        # A adds B by a number typed in a different format
        r = self.ca.post("/api/v1/circle/request",
                         {"phone": "+880 1865-052200", "relation": "friend"},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        a_edge = r.json()["id"]
        self.assertEqual(CircleMember.objects.get(pk=a_edge).phone, CANON)
        self.assertEqual(CircleMember.objects.get(pk=a_edge).peer_user_id,
                         self.b.id)
        # a second tap does not duplicate the request
        r = self.ca.post("/api/v1/circle/request", {"phone": OWNER_NO},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["id"], a_edge)
        self.assertEqual(self._lookup(OWNER_NO).json()["user"]["circle"]["state"],
                         "pending")
        # B sees and accepts it
        inc = CircleMember.objects.get(user=self.b, peer_user=self.a,
                                       direction="incoming")
        r = self.cb.post(f"/api/v1/circle/request/{inc.id}/act",
                         {"event": "accept"}, format="json")
        self.assertEqual(r.status_code, 200)
        # now the search/match shows Message + Call (accepted + member)
        st = self._lookup(OWNER_NO).json()["user"]["circle"]
        self.assertEqual(st["state"], "accepted")
        self.assertEqual(st["member_id"], a_edge)
        self.assertEqual(st["member"]["id"], a_edge)
        # A messages B, B receives it
        r = self.ca.post(f"/api/v1/circle/{a_edge}/messages",
                         {"content_type": "text", "ciphertext": "AAAA",
                          "nonce": "BBBB", "client_msg_id": "c1"},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        got = self.cb.get(f"/api/v1/circle/{inc.id}/messages").json()["results"]
        self.assertEqual(len(got), 1)
        # the call endpoint accepts them (voice)
        r = self.ca.post(f"/api/v1/circle/{a_edge}/call", {"kind": "voice"},
                         format="json")
        self.assertIn(r.status_code, (200, 201))
        self.assertNotEqual(r.json().get("allowed"), False, r.content)

    def test_circle_request_by_user_id_and_bad_phone(self):
        r = self.ca.post("/api/v1/circle/request",
                         {"to_user_id": self.b.id, "relation": "friend"},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(CircleMember.objects.get(pk=r.json()["id"]).phone, CANON)
        r = self.ca.post("/api/v1/circle/request", {"phone": "12"},
                         format="json")
        self.assertEqual(r.status_code, 400)
        r = self.ca.post("/api/v1/circle/request", {"phone": "01711000001"},
                         format="json")
        self.assertEqual(r.status_code, 400)  # self

    def test_invite_sms_canonical_and_invalid(self):
        r = self.ca.post("/api/v1/messenger/invite/sms",
                         {"to_number": "01999 888-777"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertIn("8801999888777", r.json().get("sms_uri", ""))
        r = self.ca.post("/api/v1/messenger/invite/sms",
                         {"to_number": "abc"}, format="json")
        self.assertEqual(r.status_code, 400)


class DataMigrationTests(TestCase):
    def _run(self):
        mod = importlib.import_module("core.migrations.0050_c1_phone_canonical")
        mod.forwards(django_apps, None)

    def test_normalises_backfills_and_reports_collisions(self):
        a = User.objects.create_user(name="A", phone="01711000901", password="x")
        b = User.objects.create_user(name="B", phone="01711000902", password="x")
        c = User.objects.create_user(name="C", phone="01711000903", password="x")
        d = User.objects.create_user(name="D", email="d@example.com", password="x")
        # simulate pre-0050 rows (bypass the signal)
        User.objects.filter(pk=a.pk).update(phone="01711000901")
        User.objects.filter(pk=b.pk).update(phone="+880 1711-000902")
        User.objects.filter(pk=c.pk).update(phone="8801711000901")  # collides w/ A
        User.objects.filter(pk=d.pk).update(phone="12-34")          # invalid
        UserPhoneHash.objects.all().delete()
        m = CircleMember.objects.create(user=b, phone="017 1100 0901",
                                        relation="friend")
        from io import StringIO
        from contextlib import redirect_stdout
        buf = StringIO()
        with redirect_stdout(buf):
            self._run()
        out = buf.getvalue()
        a.refresh_from_db(); b.refresh_from_db(); c.refresh_from_db()
        d.refresh_from_db()
        self.assertEqual(b.phone, "+8801711000902")
        # collision: both left exactly as they were, never merged/deleted
        self.assertEqual(a.phone, "01711000901")
        self.assertEqual(c.phone, "8801711000901")
        self.assertIn("COLLISION +8801711000901", out)
        self.assertIn(f"user {a.pk}", out)
        self.assertEqual(d.phone, "12-34")
        self.assertIn("invalid phone kept as-is", out)
        self.assertEqual(User.objects.filter(pk__in=[a.pk, c.pk]).count(), 2)
        # backfill only for the clean account
        self.assertEqual(UserPhoneHash.objects.get(user=b).phone_hash,
                         P.hash_raw("01711000902"))
        self.assertFalse(UserPhoneHash.objects.filter(user=a).exists())
        m.refresh_from_db()
        self.assertEqual(m.phone, "+8801711000901")
        # idempotent
        with redirect_stdout(StringIO()):
            self._run()
        self.assertEqual(UserPhoneHash.objects.filter(user=b).count(), 1)


class RebuildCommandTests(TestCase):
    def test_rebuild_after_salt_change(self):
        from io import StringIO
        from django.core.management import call_command
        u = User.objects.create_user(name="S", phone=OWNER_NO, password="x")
        with self.settings(SERVER_MATCH_SALT="rotated-salt-for-test"):
            self.assertNotEqual(UserPhoneHash.objects.get(user=u).phone_hash,
                                P.hash_raw(OWNER_NO))
            out = StringIO()
            call_command("rebuild_phone_hashes", stdout=out)
            self.assertIn("phone hashes written: 1", out.getvalue())
            self.assertEqual(UserPhoneHash.objects.get(user=u).phone_hash,
                             P.hash_raw(OWNER_NO))
