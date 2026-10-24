"""
b6-antitheft — tests for the native Lost/Stolen engine backend.

Covers: enable/disable with the Security PIN, engine-token ingestion (batch,
store-and-forward with original timestamps, ordering, dedupe), theft-signal
freeze, family alerts firing, privacy (non-approved users get 404 on timeline
and photo), went-dark + back-online wiring, and intruder-photo encryption +
owner/family-only signed links.
"""
import io
import json
from datetime import timedelta

from django.test import override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import antitheft as at
from core.models import (AntiTheftEngine, AntiTheftEvent, CircleMember,
                         FamilyAlert, NotifEvent, PhoneHeartbeat, ProtectedPhone, User)


def _jpeg(nbytes=64):
    return b"\xff\xd8\xff\xe0" + b"\x00" * nbytes + b"\xff\xd9"


class _Base(APITestCase):
    PIN = "2468"

    def setUp(self):
        self.owner = User.objects.create_user(
            name="মালিক", phone="01710000001", password="x",
            email="b6owner@example.com")
        self.family = User.objects.create_user(
            name="বাবা", phone="01710000002", password="x",
            email="b6family@example.com")
        self.stranger = User.objects.create_user(
            name="অন্য", phone="01710000003", password="x",
            email="b6stranger@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.phone.imei1 = "351111111111111"
        self.phone.model_name = "Realme 9i"
        self.phone.save()
        # family is an accepted circle member AND the approved alert member
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.family, name="বাবা",
            state="accepted", direction="outgoing")

    def _enable(self, **extra):
        body = {"pin": self.PIN, "alert_member_ids": [self.member.id]}
        body.update(extra)
        r = self.client.post("/api/v1/security/engine/enable", body,
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        return r

    def _ingest(self, items, sent_at=None, token=None):
        return self.client.post(
            "/api/v1/security/engine/ingest",
            {"items": items, "sent_at": sent_at or timezone.now().isoformat()},
            format="json", HTTP_X_ASSISTO_ENGINE=token or self.token)


class EnableDisableTests(_Base):
    def test_enable_requires_pin(self):
        r = self.client.post("/api/v1/security/engine/enable",
                             {"pin": "0000"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertFalse(
            AntiTheftEngine.objects.filter(phone=self.phone, enabled=True).exists())

    def test_enable_returns_token_once_and_alerts(self):
        self._enable()
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        self.assertTrue(eng.enabled)
        self.assertEqual(eng.token_hash, at.hash_token(self.token))
        # owner + approved family both get a "protection on" alert
        self.assertTrue(NotifEvent.objects.filter(
            user=self.owner, meta__has_key="antitheft_kind").exists())
        self.assertTrue(NotifEvent.objects.filter(
            user=self.family, meta__has_key="antitheft_kind").exists())

    def test_enable_rotates_token(self):
        self._enable()
        first = self.token
        self._enable()
        self.assertNotEqual(first, self.token)
        # the old token no longer ingests
        r = self._ingest([{"id": "h1", "kind": "heartbeat"}], token=first)
        self.assertEqual(r.status_code, 401)

    def test_disable_requires_pin_and_clears_token(self):
        self._enable()
        tok = self.token
        bad = self.client.post("/api/v1/security/engine/disable",
                               {"pin": "0000"}, format="json")
        self.assertEqual(bad.status_code, 403)
        ok = self.client.post("/api/v1/security/engine/disable",
                              {"pin": self.PIN}, format="json")
        self.assertEqual(ok.status_code, 200)
        self.assertFalse(AntiTheftEngine.objects.get(phone=self.phone).enabled)
        r = self._ingest([{"id": "h1", "kind": "heartbeat"}], token=tok)
        self.assertEqual(r.status_code, 401)

    def test_disable_blocked_while_frozen(self):
        self._enable()
        self.phone.frozen_until = timezone.now() + timedelta(hours=1)
        self.phone.save()
        r = self.client.post("/api/v1/security/engine/disable",
                             {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 423)
        self.assertTrue(AntiTheftEngine.objects.get(phone=self.phone).enabled)


class IngestionTests(_Base):
    def setUp(self):
        super().setUp()
        self._enable()

    def test_heartbeat_updates_location_and_dedupes(self):
        hb = {"id": "hb-1", "kind": "heartbeat", "lat": 23.78, "lng": 90.41,
              "battery": 70, "network": "wifi"}
        r1 = self._ingest([hb])
        self.assertEqual(r1.status_code, 200)
        self.assertEqual(r1.data["accepted"], ["hb-1"])
        r2 = self._ingest([hb])  # same client id → duplicate, not stored twice
        self.assertEqual(r2.data["duplicate"], ["hb-1"])
        self.assertEqual(PhoneHeartbeat.objects.filter(phone=self.phone).count(), 1)
        self.phone.refresh_from_db()
        self.assertAlmostEqual(self.phone.last_lat, 23.78)

    def test_events_stored_in_time_order(self):
        now = timezone.now()
        older = (now - timedelta(minutes=30)).isoformat()
        newer = (now - timedelta(minutes=5)).isoformat()
        # delivered newest-first, but must be stored/replayed oldest-first
        self._ingest([
            {"id": "e-new", "kind": "low_battery", "at": newer, "battery": 9},
            {"id": "e-old", "kind": "boot", "at": older},
        ])
        evs = list(AntiTheftEvent.objects.filter(phone=self.phone).order_by("at"))
        self.assertEqual([e.client_id for e in evs], ["e-old", "e-new"])

    def test_late_delivery_flagged_with_original_time(self):
        happened = (timezone.now() - timedelta(hours=3)).isoformat()
        self._ingest([{"id": "late-1", "kind": "offline", "at": happened,
                       "data": {"reason": "airplane"}}])
        ev = AntiTheftEvent.objects.get(client_id="late-1")
        self.assertTrue(ev.late)
        self.assertLess(ev.at, ev.received_at)

    def test_clock_skew_corrected(self):
        # device clock is 1h behind; sent_at reveals the offset
        dev_now = timezone.now() - timedelta(hours=1)
        self._ingest([{"id": "sk-1", "kind": "boot",
                       "at": dev_now.isoformat()}],
                     sent_at=dev_now.isoformat())
        ev = AntiTheftEvent.objects.get(client_id="sk-1")
        # corrected back to ~ server now (within a couple of minutes)
        self.assertLess(abs((timezone.now() - ev.at).total_seconds()), 180)

    def test_too_old_rejected(self):
        ancient = (timezone.now() - timedelta(days=90)).isoformat()
        r = self._ingest([{"id": "anc", "kind": "boot", "at": ancient}])
        self.assertEqual([x["id"] for x in r.data["rejected"]], ["anc"])
        self.assertFalse(AntiTheftEvent.objects.filter(client_id="anc").exists())

    def test_bad_kind_rejected(self):
        r = self._ingest([{"id": "b", "kind": "nope"}])
        self.assertEqual(r.data["rejected"][0]["reason"], "bad_kind")

    def test_snatch_freezes_and_alerts_family(self):
        self._ingest([{"id": "sn-1", "kind": "snatch", "lat": 23.8, "lng": 90.4,
                       "data": {"locked": True}}])
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.frozen_until and
                        self.phone.frozen_until > timezone.now())
        self.assertTrue(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="snatch").exists())

    def test_sim_change_alert_is_honest_about_number(self):
        self._ingest([{"id": "sim-1", "kind": "sim_change",
                       "data": {"state": "inserted", "carrier": "Robi", "v": 2}}])
        fa = NotifEvent.objects.filter(user=self.owner,
                                        meta__antitheft_kind="sim_change").first()
        self.assertIsNotNone(fa)
        # owner lang is bn → honest Bangla line that the number is not readable
        self.assertIn("নতুন নম্বর পড়তে দেয় না", fa.body_bn)

    def test_failed_unlock_below_threshold_does_not_alert(self):
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.failed_unlock_threshold = 3
        eng.save()
        self._ingest([{"id": "fu-1", "kind": "failed_unlock",
                       "data": {"count": 2}}])
        self.assertFalse(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="failed_unlock").exists())
        self._ingest([{"id": "fu-2", "kind": "failed_unlock",
                       "data": {"count": 4}}])
        self.assertTrue(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="failed_unlock").exists())

    def test_alert_cooldown_dedupes_flapping(self):
        for i in range(3):
            self._ingest([{"id": "snf-%d" % i, "kind": "snatch"}])
        n = NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="snatch").count()
        self.assertEqual(n, 1)   # cooldown collapses the burst to one

    def test_back_online_alert_after_dark(self):
        self.phone.went_dark_alerted = True
        self.phone.save()
        self._ingest([{"id": "hb-back", "kind": "heartbeat",
                       "lat": 23.7, "lng": 90.4}])
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.went_dark_alerted)
        # owner 24 Oct: the device owner never gets went-dark / back-online
        # alerts about his own phone (only approved family members do)
        self.assertFalse(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="online").exists())

    def test_old_fix_does_not_overwrite_newer_location(self):
        now = timezone.now()
        self._ingest([{"id": "hb-new", "kind": "heartbeat", "lat": 10.0,
                       "lng": 10.0, "at": now.isoformat()}])
        self._ingest([{"id": "hb-old", "kind": "heartbeat", "lat": 20.0,
                       "lng": 20.0, "at": (now - timedelta(hours=2)).isoformat()}])
        self.phone.refresh_from_db()
        self.assertAlmostEqual(self.phone.last_lat, 10.0)


class PrivacyTests(_Base):
    def setUp(self):
        super().setUp()
        self._enable()
        self._ingest([{"id": "ev-1", "kind": "boot"}])

    def test_owner_sees_timeline(self):
        r = self.client.get("/api/v1/security/engine/timeline")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["viewer"], "owner")
        self.assertTrue(len(r.data["events"]) >= 1)

    def test_approved_family_sees_timeline(self):
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline",
                            {"phone_id": self.phone.id})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["viewer"], "family")

    def test_stranger_gets_404(self):
        self.client.force_authenticate(self.stranger)
        r = self.client.get("/api/v1/security/engine/timeline",
                            {"phone_id": self.phone.id})
        self.assertEqual(r.status_code, 404)

    def test_unapproved_circle_member_gets_404(self):
        # family is removed from the approved list → no longer a viewer
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.alert_member_ids = []
        eng.save()
        self.phone.family_approver = None
        self.phone.save()
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline",
                            {"phone_id": self.phone.id})
        self.assertEqual(r.status_code, 404)

    def test_watching_lists_phone_for_family(self):
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/watching")
        self.assertEqual(r.status_code, 200)
        ids = [w["phone_id"] for w in r.data["watching"]]
        self.assertIn(self.phone.id, ids)


class IntruderPhotoTests(_Base):
    def setUp(self):
        super().setUp()
        self._enable(intruder_photo=True)

    def test_intruder_photo_is_opt_in(self):
        # a fresh engine has the intruder photo OFF; photos are refused
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.intruder_photo = False
        eng.save()
        r = self._post_photo()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "intruder_photo_off")
        self.assertFalse(AntiTheftEvent.objects.filter(kind="intruder_photo").exists())
        self.assertFalse(AntiTheftEngine._meta.get_field("intruder_photo").default)

    def _post_photo(self, token=None):
        f = io.BytesIO(_jpeg())
        f.name = "x.jpg"
        return self.client.post(
            "/api/v1/security/engine/photo",
            {"file": f, "id": "ph-1", "data": json.dumps({"count": 4})},
            format="multipart", HTTP_X_ASSISTO_ENGINE=token or self.token)

    def test_photo_stored_encrypted(self):
        r = self._post_photo()
        self.assertEqual(r.status_code, 200, r.data)
        ev = AntiTheftEvent.objects.get(kind="intruder_photo")
        raw = ev.photo.open("rb").read()
        self.assertNotIn(b"\xff\xd8\xff", raw)   # ciphertext, not raw jpeg
        self.assertEqual(at.decrypt_photo(raw)[:3], b"\xff\xd8\xff")

    def test_non_jpeg_rejected(self):
        f = io.BytesIO(b"not a jpeg")
        f.name = "x.jpg"
        r = self.client.post("/api/v1/security/engine/photo",
                             {"file": f, "id": "bad"}, format="multipart",
                             HTTP_X_ASSISTO_ENGINE=self.token)
        self.assertEqual(r.status_code, 400)

    def test_owner_photo_link_decrypts(self):
        self._post_photo()
        ev = AntiTheftEvent.objects.get(kind="intruder_photo")
        link = self.client.get(
            "/api/v1/security/engine/event/%d/photo-link" % ev.id)
        self.assertEqual(link.status_code, 200)
        url = link.data["url"].replace("/security/", "/api/v1/security/")
        img = self.client.get(url)
        self.assertEqual(img.status_code, 200)
        self.assertEqual(img["Content-Type"], "image/jpeg")
        self.assertEqual(img.content[:3], b"\xff\xd8\xff")

    def test_stranger_cannot_get_photo_link(self):
        self._post_photo()
        ev = AntiTheftEvent.objects.get(kind="intruder_photo")
        self.client.force_authenticate(self.stranger)
        r = self.client.get(
            "/api/v1/security/engine/event/%d/photo-link" % ev.id)
        self.assertEqual(r.status_code, 404)

    def test_photo_bytes_reject_tampered_viewer(self):
        self._post_photo()
        ev = AntiTheftEvent.objects.get(kind="intruder_photo")
        link = self.client.get(
            "/api/v1/security/engine/event/%d/photo-link" % ev.id)
        url = link.data["url"]
        # swap the viewer id to the stranger → signature no longer matches
        tampered = url.replace("v=%d" % self.owner.id, "v=%d" % self.stranger.id)
        tampered = tampered.replace("/security/", "/api/v1/security/")
        self.client.logout()
        self.assertEqual(self.client.get(tampered).status_code, 404)


class WentDarkWiringTests(_Base):
    def test_went_dark_for_engine_phone_alerts_approved_only(self):
        # an extra accepted circle member who is NOT approved for alerts
        other = User.objects.create_user(name="x", phone="01710000009", password="x")
        CircleMember.objects.create(user=self.owner, peer_user=other, name="x",
                                    state="accepted", direction="outgoing")
        self._enable()
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.armed)   # engine alone is enough
        self.phone.heartbeat_interval_min = 10
        self.phone.last_heartbeat_at = timezone.now() - timedelta(hours=2)
        self.phone.went_dark_alerted = False
        self.phone.save()
        from django.core.management import call_command
        call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)
        self.assertTrue(AntiTheftEvent.objects.filter(phone=self.phone,
                                                      kind="went_dark").exists())
        self.assertTrue(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="went_dark").exists())
        self.assertFalse(NotifEvent.objects.filter(
            user=other, meta__antitheft_kind="went_dark").exists())

    def test_check_went_dark_uses_engine_heartbeats(self):
        self._enable()
        self.phone.armed = True
        self.phone.heartbeat_interval_min = 10
        self.phone.last_heartbeat_at = timezone.now() - timedelta(hours=2)
        self.phone.last_lat, self.phone.last_lng = 23.8, 90.4
        self.phone.went_dark_alerted = False
        self.phone.save()
        from django.core.management import call_command
        call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)


class LogicTests(APITestCase):
    def test_heartbeat_interval_battery_aware(self):
        self.assertEqual(at.heartbeat_interval_min(80, True, False), at.INTERVAL_CHARGING)
        self.assertEqual(at.heartbeat_interval_min(10, False, False), at.INTERVAL_CRITICAL)
        self.assertEqual(at.heartbeat_interval_min(25, False, False), at.INTERVAL_LOW)
        self.assertEqual(at.heartbeat_interval_min(90, False, True), at.INTERVAL_LOST)
        # critical battery wins even in lost mode
        self.assertEqual(at.heartbeat_interval_min(5, False, True), at.INTERVAL_CRITICAL)

    def test_encrypt_roundtrip(self):
        data = b"\xff\xd8\xff" + b"hello" * 100
        self.assertEqual(at.decrypt_photo(at.encrypt_photo(data)), data)

    def test_valid_latlng(self):
        self.assertTrue(at.valid_latlng(23.0, 90.0))
        self.assertFalse(at.valid_latlng(200.0, 90.0))
        self.assertFalse(at.valid_latlng(None, 90.0))
