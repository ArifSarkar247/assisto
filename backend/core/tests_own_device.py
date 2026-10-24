"""
own-device (owner 24 Oct) — "Assisto has not heard from the phone since..."
about the owner's OWN phone while he was using it.

Covers: the engine remembers the app's X-Device-Id (hash only) at enable and
on ingest; any token-authenticated API request FROM that phone resolves a
went-dark latch (alerts resolved, latch cleared, last-seen bumped); requests
from another device / the web / with junk ids never do; the negative cache
keeps it at most one query; antitheft /alerts rows carry owner_id for the
app's urgent-card guard.
"""
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from core import own_device
from core.models import (AntiTheftEngine, CircleMember, NotifEvent,
                         ProtectedPhone, User)

DEV = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
OTHER = "ffffeeeeddddccccbbbbaaaa99998888"


class OwnDeviceTests(APITestCase):
    PIN = "2468"

    def setUp(self):
        own_device.forget_cache()
        self.owner = User.objects.create_user(
            name="Arif", phone="01710000201", password="x",
            email="owndev-owner@example.com")
        self.family = User.objects.create_user(
            name="Ma", phone="01710000202", password="x",
            email="owndev-family@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.family, name="Ma",
            state="accepted", direction="outgoing")
        r = self.client.post("/api/v1/security/engine/enable",
                             {"pin": self.PIN,
                              "alert_member_ids": [self.member.id]},
                             format="json", HTTP_X_DEVICE_ID=DEV)
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        self.eng = AntiTheftEngine.objects.get(phone=self.phone)
        self.client.force_authenticate(None)
        self.api_token = Token.objects.get_or_create(user=self.owner)[0].key

    def _auth_get(self, path, device=None, user_token=None):
        extra = {"HTTP_AUTHORIZATION": "Token " + (user_token or self.api_token)}
        if device is not None:
            extra["HTTP_X_DEVICE_ID"] = device
        return self.client.get(path, **extra)

    def _go_dark(self):
        then = timezone.now() - timedelta(minutes=120)
        ProtectedPhone.objects.filter(pk=self.phone.pk).update(
            last_heartbeat_at=then, heartbeat_interval_min=15,
            went_dark_alerted=False)
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(last_ingest_at=then)
        with mock.patch("core.push.safe_push"):
            call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)
        own_device.forget_cache()

    def _family_went_dark(self):
        return NotifEvent.objects.get(user=self.family,
                                      meta__antitheft_kind="went_dark")

    # --- remembering the id ---------------------------------------------

    def test_enable_stores_hash_not_raw(self):
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.device_hash, own_device.device_hash(DEV))
        self.assertNotIn(DEV, self.eng.device_hash)
        self.assertEqual(len(self.eng.device_hash), 64)

    def test_ingest_updates_hash(self):
        r = self.client.post(
            "/api/v1/security/engine/ingest",
            {"items": [{"id": "hb1", "kind": "heartbeat"}],
             "sent_at": timezone.now().isoformat()},
            format="json", HTTP_X_ASSISTO_ENGINE=self.token,
            HTTP_X_DEVICE_ID=OTHER)
        self.assertEqual(r.status_code, 200)
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.device_hash, own_device.device_hash(OTHER))

    def test_ingest_without_header_keeps_hash(self):
        self.client.post(
            "/api/v1/security/engine/ingest",
            {"items": [{"id": "hb2", "kind": "heartbeat"}],
             "sent_at": timezone.now().isoformat()},
            format="json", HTTP_X_ASSISTO_ENGINE=self.token)
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.device_hash, own_device.device_hash(DEV))

    def test_junk_ids_ignored(self):
        self.assertEqual(own_device.device_hash(""), "")
        self.assertEqual(own_device.device_hash("short"), "")
        self.assertEqual(own_device.device_hash("bad id with spaces!!"), "")
        self.assertEqual(own_device.device_hash("x" * 200), "")

    # --- resolving from the phone itself ---------------------------------

    def test_request_from_own_phone_resolves_went_dark(self):
        self._go_dark()
        r = self._auth_get("/api/v1/alerts", device=DEV)
        self.assertEqual(r.status_code, 200)
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.went_dark_alerted)
        self.assertGreater(self.phone.last_heartbeat_at,
                           timezone.now() - timedelta(minutes=1))
        n = self._family_went_dark()
        self.assertTrue(n.seen)
        self.assertTrue(n.meta.get("resolved_at"))
        # and the went-dark job does not re-alert on the same stale gap
        with mock.patch("core.push.safe_push"):
            call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.went_dark_alerted)

    def test_request_from_other_device_does_not_resolve(self):
        self._go_dark()
        self._auth_get("/api/v1/alerts", device=OTHER)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)
        self.assertFalse(self._family_went_dark().seen)

    def test_web_request_without_header_does_not_resolve(self):
        self._go_dark()
        self._auth_get("/api/v1/alerts")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)

    def test_other_user_with_same_device_id_does_not_resolve(self):
        self._go_dark()
        tok = Token.objects.get_or_create(user=self.family)[0].key
        self._auth_get("/api/v1/alerts", device=DEV, user_token=tok)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)

    def test_bad_token_never_resolves(self):
        self._go_dark()
        r = self._auth_get("/api/v1/alerts", device=DEV, user_token="nope")
        self.assertEqual(r.status_code, 401)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)

    def test_no_latch_is_one_query_then_cached(self):
        req = mock.Mock()
        req.META = {own_device.HEADER: DEV}
        with self.assertNumQueries(1):
            self.assertIsNone(own_device.touch(req, self.owner))
        with self.assertNumQueries(0):
            self.assertIsNone(own_device.touch(req, self.owner))
        with self.assertNumQueries(0):
            self.assertIsNone(own_device.touch(mock.Mock(META={}), self.owner))

    def test_touch_never_raises(self):
        req = mock.Mock()
        req.META = {own_device.HEADER: DEV}
        with mock.patch("core.models.ProtectedPhone.objects.filter",
                        side_effect=RuntimeError("db down")):
            self.assertIsNone(own_device.touch(req, self.owner))
        self.assertIsNone(own_device.touch(None, None))

    # --- urgent-card guard field ------------------------------------------

    def test_family_alert_rows_carry_owner_id(self):
        self._go_dark()
        tok = Token.objects.get_or_create(user=self.family)[0].key
        r = self._auth_get("/api/v1/alerts", user_token=tok)
        alerts = r.data if isinstance(r.data, list) else r.data.get("alerts", [])
        rows = [a for a in alerts if a.get("type") == "antitheft"]
        self.assertTrue(rows)
        self.assertTrue(all(a.get("owner_id") == self.owner.id for a in rows))
        # the owner's own poll has none of them
        r2 = self._auth_get("/api/v1/alerts")
        alerts2 = r2.data if isinstance(r2.data, list) else r2.data.get("alerts", [])
        self.assertFalse([a for a in alerts2 if a.get("type") == "antitheft"])
