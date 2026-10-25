"""qs-antitheft (quality sweep, owner item 5) — owner-vs-family recipients and
authorization edges on the anti-theft endpoints.

Bugs pinned here (fixed in the same commit):
  * security/lost-phone let a contact the owner had BLOCKED (state accepted,
    blocked=True) read the lost phone's location trail; a blocked / no longer
    accepted family approver passed too;
  * the legacy security alerts (_notify_owner_and_circle: lost mode on,
    evidence captured, wrong-PIN lock) wrote in-app alerts + emails to BLOCKED
    contacts (push already skipped them);
  * a non-numeric ?phone_id= on lost-phone / engine/timeline was a 500.
"""
from datetime import timedelta
from unittest import mock

from django.core import mail
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import override_settings
from django.utils import timezone

from core.models import (AntiTheftEngine, AntiTheftEvent, CapturedEvent,
                         CircleMember, NotifEvent, PhoneHeartbeat, ProtectedPhone,
                         User)
from core.tests_b6_antitheft import _Base, _jpeg

LOST = "/api/v1/security/lost-phone"


@override_settings(EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend")
class LostPhoneScopeTests(_Base):
    def setUp(self):
        super().setUp()
        self.phone.armed = True
        self.phone.lost_mode = True
        self.phone.lost_since = timezone.now()
        self.phone.save()

    def _get_as(self, user, q=None):
        self.client.force_authenticate(user)
        return self.client.get(LOST + ("?phone_id=%s" % (q if q is not None
                                                           else self.phone.id)))

    def test_accepted_family_reads_while_lost(self):
        r = self._get_as(self.family)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["viewer"], "circle")

    def test_blocked_contact_cannot_read_location(self):
        CircleMember.objects.filter(pk=self.member.pk).update(blocked=True)
        r = self._get_as(self.family)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "forbidden")

    def test_pending_or_declined_contact_cannot_read(self):
        for st in ("pending", "declined"):
            CircleMember.objects.filter(pk=self.member.pk).update(state=st)
            self.assertEqual(self._get_as(self.family).status_code, 403, st)

    def test_approver_must_still_be_an_accepted_unblocked_member(self):
        self.phone.family_approver = self.member
        self.phone.save()
        self.assertEqual(self._get_as(self.family).status_code, 200)
        CircleMember.objects.filter(pk=self.member.pk).update(blocked=True)
        self.assertEqual(self._get_as(self.family).status_code, 403)
        CircleMember.objects.filter(pk=self.member.pk).update(
            blocked=False, state="declined")
        self.assertEqual(self._get_as(self.family).status_code, 403)

    def test_family_not_active_is_403(self):
        ProtectedPhone.objects.filter(pk=self.phone.pk).update(lost_mode=False)
        r = self._get_as(self.family)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "not_active")

    def test_stranger_and_bad_ids(self):
        self.assertEqual(self._get_as(self.stranger).status_code, 403)
        self.assertEqual(self._get_as(self.family, q=999999).status_code, 404)
        self.assertEqual(self._get_as(self.family, q="abc").status_code, 404)

    def test_owner_always_and_payload_is_honest(self):
        r = self._get_as(self.owner)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["viewer"], "owner")
        self.assertIsNone(r.data["last_location"])     # never fabricated
        self.assertIsNone(r.data["sim_change"])

    def test_lost_mode_alert_skips_blocked_contact(self):
        blocked = User.objects.create_user(
            name="Ex", phone="01710000009", password="x", email="ex@example.com")
        CircleMember.objects.create(user=self.owner, peer_user=blocked, name="Ex",
                                    state="accepted", blocked=True)
        self.client.force_authenticate(self.owner)
        mail.outbox = []
        r = self.client.post("/api/v1/security/lost-mode", {"on": True},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(NotifEvent.objects.filter(user=blocked).exists())
        self.assertTrue(NotifEvent.objects.filter(user=self.family).exists())
        sent_to = [a for m in mail.outbox for a in m.to]
        self.assertNotIn("ex@example.com", sent_to)
        self.assertIn("b6family@example.com", sent_to)

    def test_blocked_contact_not_offered_as_approver_candidate(self):
        CircleMember.objects.filter(pk=self.member.pk).update(blocked=True)
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/security/state")
        self.assertEqual(r.status_code, 200)
        ids = [c["id"] for c in r.data.get("candidates", [])]
        self.assertNotIn(self.member.id, ids)


class LegacyLostEndpointsTests(_Base):
    def test_lost_mode_second_on_keeps_original_since(self):
        r1 = self.client.post("/api/v1/security/lost-mode", {"on": "true"},
                              format="json")
        self.assertEqual(r1.status_code, 200)
        since = r1.data["lost_since"]
        r2 = self.client.post("/api/v1/security/lost-mode",
                              {"on": True, "message": "x" * 3000}, format="json")
        self.assertEqual(r2.data["lost_since"], since)
        self.phone.refresh_from_db()
        self.assertEqual(len(self.phone.lost_message), 2000)

    def test_lost_mode_off_is_never_direct(self):
        self.client.post("/api/v1/security/lost-mode", {"on": True}, format="json")
        for off in (False, "false", "0", ""):
            r = self.client.post("/api/v1/security/lost-mode", {"on": off},
                                 format="json")
            self.assertEqual(r.status_code, 409)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.lost_mode)

    def test_heartbeat_ignores_garbage_coordinates(self):
        self.client.post("/api/v1/security/heartbeat", {"lat": 23.7, "lng": 90.4},
                         format="json")
        r = self.client.post("/api/v1/security/heartbeat",
                             {"lat": "abc", "lng": "", "battery": "x"},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.phone.refresh_from_db()
        self.assertEqual((self.phone.last_lat, self.phone.last_lng), (23.7, 90.4))
        self.assertEqual(PhoneHeartbeat.objects.filter(phone=self.phone).count(), 2)

    def test_events_validation(self):
        u = "/api/v1/security/events"
        self.assertEqual(self.client.post(u, {"events": "nope"},
                                          format="json").status_code, 400)
        r = self.client.post(u, {"events": [{"kind": "bogus"}]}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "no_valid_events")
        self.assertEqual(CapturedEvent.objects.count(), 0)

    def test_airplane_guard_freezes_failed_unlock_does_not(self):
        u = "/api/v1/security/events"
        r = self.client.post(u, {"events": [{"kind": "failed_unlock",
                                             "data": {"count": 2}}]},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["frozen"])
        r = self.client.post(u, {"events": [{"kind": "airplane_guard",
                                             "at": "not-a-date"}]},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["frozen"])

    def test_photo_upload_and_owner_only_stream(self):
        u = "/api/v1/security/events"
        bad = self.client.post(u, {"kind": "bogus",
                                   "file": SimpleUploadedFile("a.jpg", _jpeg())},
                               format="multipart")
        self.assertEqual(bad.status_code, 400)
        ok = self.client.post(u, {"kind": "intruder_photo", "data": "{bad json",
                                  "file": SimpleUploadedFile("a.jpg", _jpeg(),
                                                             "image/jpeg")},
                              format="multipart")
        self.assertEqual(ok.status_code, 200, ok.data)
        ev = CapturedEvent.objects.get(phone=self.phone, kind="intruder_photo")
        self.assertEqual(ev.data, {})
        url = "/api/v1/security/event/%d/photo" % ev.id
        self.assertEqual(self.client.get(url).status_code, 200)
        for other in (self.family, self.stranger):
            self.client.force_authenticate(other)
            self.assertEqual(self.client.get(url).status_code, 404)


class EngineAuthTests(_Base):
    def test_ingest_needs_a_live_token(self):
        self._enable()
        r = self.client.post("/api/v1/security/engine/ingest", {"items": []},
                             format="json")     # no header at all
        self.assertEqual(r.status_code, 401)
        self.assertTrue(r.data["stop"])
        for hdr in ("x" * 201, "wrong-token"):
            r = self._ingest([{"id": "h1", "kind": "heartbeat"}], token=hdr)
            self.assertEqual(r.status_code, 401)
            self.assertTrue(r.data["stop"])
        # a rotated token stops working
        old = self.token
        self._enable()
        self.assertEqual(self._ingest([], token=old).status_code, 401)
        self.assertEqual(self._ingest([]).status_code, 200)
        # items must be a list
        r = self.client.post("/api/v1/security/engine/ingest", {"items": "x"},
                             format="json", HTTP_X_ASSISTO_ENGINE=self.token)
        self.assertEqual(r.status_code, 400)

    def test_disabled_engine_token_is_revoked(self):
        self._enable()
        AntiTheftEngine.objects.filter(phone=self.phone).update(enabled=False)
        self.assertEqual(self._ingest([]).status_code, 401)

    def test_settings_need_pin_and_only_own_accepted_members(self):
        self._enable()
        url = "/api/v1/security/engine/settings"
        self.assertEqual(self.client.post(url, {"pin": "0000"},
                                          format="json").status_code, 403)
        other_owner_member = CircleMember.objects.create(
            user=self.stranger, peer_user=self.family, name="x", state="accepted")
        blocked = CircleMember.objects.create(
            user=self.owner, peer_user=self.stranger, name="s", state="accepted",
            blocked=True)
        r = self.client.post(url, {"pin": self.PIN, "failed_unlock_threshold": 999,
                                   "snatch_lock": "false",
                                   "alert_member_ids": [self.member.id,
                                                        other_owner_member.id,
                                                        blocked.id, "zz"]},
                             format="json")
        self.assertEqual(r.status_code, 200)
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        self.assertEqual(eng.alert_member_ids, [self.member.id])
        self.assertFalse(eng.snatch_lock)
        from core.logic import antitheft as at
        self.assertEqual(eng.failed_unlock_threshold, at.THRESHOLD_MAX)

    def test_disable_when_already_off_is_noop_without_pin(self):
        r = self.client.post("/api/v1/security/engine/disable", {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["enabled"])

    def test_false_alarm_is_owner_only(self):
        self._enable()
        self.client.force_authenticate(self.family)
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": self.PIN, "phone_id": self.phone.id},
                             format="json")
        self.assertEqual(r.status_code, 404)


class EngineRecipientTests(_Base):
    def test_snatch_alerts_family_never_owner(self):
        self._enable()
        NotifEvent.objects.all().delete()
        self._ingest([{"id": "s1", "kind": "snatch"}])
        self.assertTrue(NotifEvent.objects.filter(user=self.family,
                                                  type="security").exists())
        self.assertFalse(NotifEvent.objects.filter(user=self.owner).exists())
        self.assertFalse(NotifEvent.objects.filter(user=self.stranger).exists())

    def test_blocking_family_after_approval_stops_alerts_and_access(self):
        self._enable()
        CircleMember.objects.filter(pk=self.member.pk).update(blocked=True)
        NotifEvent.objects.all().delete()
        self._ingest([{"id": "s2", "kind": "snatch"}])
        self.assertFalse(NotifEvent.objects.filter(user=self.family).exists())
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline?phone_id=%d"
                            % self.phone.id)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.client.get("/api/v1/security/engine/watching")
                         .data["watching"], [])

    def test_timeline_bad_phone_id_is_404(self):
        self._enable()
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline?phone_id=abc")
        self.assertEqual(r.status_code, 404)

    def test_family_timeline_view_is_family(self):
        self._enable()
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline?phone_id=%d"
                            % self.phone.id)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["viewer"], "family")

    def test_photo_link_dies_when_family_access_removed(self):
        self._enable(intruder_photo=True)
        ev = AntiTheftEvent.objects.create(phone=self.phone, client_id="p1",
                                           kind="intruder_photo",
                                           at=timezone.now())
        from core.logic import antitheft as at
        from django.core.files.base import ContentFile
        ev.photo.save("p1.bin", ContentFile(at.encrypt_photo(_jpeg())))
        self.client.force_authenticate(self.family)
        link = self.client.get("/api/v1/security/engine/event/%d/photo-link"
                               % ev.id)
        self.assertEqual(link.status_code, 200)
        path = "/api/v1" + link.data["url"]
        from rest_framework.test import APIClient
        anon = APIClient()
        self.assertEqual(anon.get(path).status_code, 200)
        CircleMember.objects.filter(pk=self.member.pk).update(state="declined")
        self.assertEqual(anon.get(path).status_code, 404)
        # tampered signature is 404 too
        self.assertEqual(anon.get(path.replace("s=", "s=0")).status_code, 404)

    def test_owner_only_kind_goes_to_owner_alone(self):
        self._enable()
        from core.logic import antitheft as at
        if "test" not in at.OWNER_ONLY_KINDS or "test" not in at.EVENT_KINDS:
            self.skipTest("no owner-only test kind")
        NotifEvent.objects.all().delete()
        self._ingest([{"id": "t1", "kind": "test"}])
        self.assertTrue(NotifEvent.objects.filter(user=self.owner).exists())
        self.assertFalse(NotifEvent.objects.filter(user=self.family).exists())
