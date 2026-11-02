"""theftalerts (owner 2 Nov) — the three theft alerts for a lost/stolen phone:

  * wrong unlock (count + location) and the in-app intruder photo — the photo
    now rides IN the push (per-recipient signed, expiring https link);
  * SIM change (unchanged detection, wider recipients);
  * protection turn-off (device-admin onDisableRequested / onDisabled — the
    step Android needs before an uninstall; Play forbids blocking it).

Recipients: trusted contacts (as before) + an OWNER COPY for the owner's other
devices (data-only, names the protected phone's device hash so that phone
drops it) + the owner's nominee(s) when he switched that on (view-only).
Also: retention prune for phones that never check in again.
"""
import io
import json
from datetime import timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import override_settings
from django.utils import timezone

from core import own_device, push
from core.logic import antitheft as at
from core.models import (AntiTheftEngine, AntiTheftEvent, Nominee, NotifEvent,
                         User)
from core.tests_b6_antitheft import _Base, _jpeg
from core.views_antitheft import can_view, nominee_users, prune_expired

DEV = "a1b2c3d4e5f60718293a4b5c6d7e8f90"


class PureLogicTests(_Base):
    def test_push_photo_url_https_only(self):
        p = {"v": 7, "e": 1999999999, "s": "abc"}
        self.assertEqual(
            at.push_photo_url("https://lifeassisto.com/", 12, p),
            "https://lifeassisto.com/api/v1/security/engine/event/12/photo"
            "?v=7&e=1999999999&s=abc")
        self.assertIsNone(at.push_photo_url("http://127.0.0.1:8700", 12, p))
        self.assertIsNone(at.push_photo_url("", 12, p))
        self.assertIsNone(at.push_photo_url("https://x.test", 12, {"v": 1}))

    def test_push_link_ttl_is_longer_but_still_verifies(self):
        now = 1_000_000
        p = at.photo_link_params(5, 9, now_ts=now, ttl_s=at.PUSH_PHOTO_LINK_TTL_S)
        self.assertEqual(p["e"], now + at.PUSH_PHOTO_LINK_TTL_S)
        self.assertTrue(at.verify_photo_link(5, 9, p["e"], p["s"], now_ts=now + 3600))
        self.assertFalse(at.verify_photo_link(5, 10, p["e"], p["s"], now_ts=now))
        self.assertFalse(at.verify_photo_link(
            5, 9, p["e"], p["s"], now_ts=now + at.PUSH_PHOTO_LINK_TTL_S + 1))

    def test_src_dev_prefix(self):
        h = own_device.device_hash(DEV)
        self.assertEqual(at.src_dev(h), h[:16])
        self.assertEqual(at.src_dev(""), "")
        self.assertEqual(at.src_dev("abc"), "")

    def test_admin_off_text_bn_en(self):
        now = timezone.now()
        te, be, tb, bb = at.alert_text("admin_off", "Rina", now,
                                       {"state": "requested"}, None, None, None,
                                       False, now)
        self.assertIn("turned off", te)
        self.assertIn("uninstalled", be)
        self.assertIn("বন্ধ করার পাতা", bb)
        te, be, tb, bb = at.alert_text("admin_off", "Rina", now,
                                       {"state": "disabled"}, None, None, None,
                                       False, now)
        self.assertIn("turned off Assisto", be)
        self.assertIn("বন্ধ করেছে", bb)

    def test_in_app_intruder_text_is_not_a_screen_unlock(self):
        now = timezone.now()
        te, be, tb, bb = at.alert_text("intruder_photo", "Rina", now,
                                       {"source": "in_app_wrong_pin"}, None,
                                       None, None, False, now)
        self.assertIn("Security PIN", be)
        self.assertNotIn("screen-unlock", be)
        self.assertIn("সিকিউরিটি পিন", bb)

    def test_admin_off_is_an_engine_kind(self):
        self.assertIn("admin_off", at.EVENT_KINDS)
        self.assertIn("admin_off", at.OWNER_COPY_KINDS)
        self.assertNotIn("snatch", at.OWNER_COPY_KINDS)


class BuildMessageImageTests(_Base):
    def test_image_only_for_https(self):
        m = push.build_message("t", {"a": 1}, {"title": "x", "body": "y",
                                              "image": "https://h/p.jpg"})
        self.assertEqual(m["message"]["notification"]["image"], "https://h/p.jpg")
        m = push.build_message("t", {"a": 1}, {"title": "x", "body": "y",
                                              "image": "http://h/p.jpg"})
        self.assertNotIn("image", m["message"]["notification"])
        m = push.build_message("t", {"a": 1}, {"title": "x", "body": "y"})
        self.assertNotIn("image", m["message"]["notification"])


class _Armed(_Base):
    def setUp(self):
        super().setUp()
        self._enable()
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            device_hash=own_device.device_hash(DEV))
        NotifEvent.objects.all().delete()


class AdminOffTests(_Armed):
    def test_admin_off_alerts_family_and_owner_copy(self):
        with mock.patch.object(push, "safe_push") as sp:
            r = self._ingest([{"id": "adm-1", "kind": "admin_off",
                               "data": {"state": "requested"}}])
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(AntiTheftEvent.objects.filter(
            phone=self.phone, kind="admin_off").exists())
        self.assertTrue(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="admin_off").exists())
        own = NotifEvent.objects.get(user=self.owner,
                                     meta__antitheft_kind="admin_off")
        self.assertTrue(own.meta["owner_copy"])
        self.assertEqual(own.meta["src_dev"], own_device.device_hash(DEV)[:16])
        calls = {c.args[0].pk: c for c in sp.call_args_list}
        self.assertIn(self.family.pk, calls)
        oc = calls[self.owner.pk]
        self.assertTrue(oc.kwargs["data_only"])
        self.assertEqual(oc.kwargs["data"]["owner_copy"], "1")
        self.assertEqual(oc.kwargs["data"]["src_dev"],
                         own_device.device_hash(DEV)[:16])
        self.assertFalse(calls[self.family.pk].kwargs.get("data_only", False))

    def test_requested_then_disabled_is_one_alert(self):
        self._ingest([{"id": "adm-1", "kind": "admin_off",
                       "data": {"state": "requested"}}])
        self._ingest([{"id": "adm-2", "kind": "admin_off",
                       "data": {"state": "disabled"}}])
        self.assertEqual(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="admin_off").count(), 1)

    def test_snatch_still_never_reaches_owner(self):
        self._ingest([{"id": "sn-1", "kind": "snatch"}])
        self.assertFalse(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="snatch").exists())

    def test_failed_unlock_owner_copy_only_past_threshold(self):
        self._ingest([{"id": "fu-1", "kind": "failed_unlock",
                       "data": {"count": 1}}])
        self.assertFalse(NotifEvent.objects.filter(user=self.owner).exists())
        self._ingest([{"id": "fu-2", "kind": "failed_unlock",
                       "data": {"count": 5}}])
        self.assertTrue(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="failed_unlock",
            meta__owner_copy=True).exists())

    def test_owner_copy_never_in_the_owner_urgent_card(self):
        from core.views_antitheft import alert_rows_for
        self._ingest([{"id": "adm-1", "kind": "admin_off",
                       "data": {"state": "requested"}}])
        self.assertEqual(alert_rows_for(self.owner), [])


class NomineeTests(_Armed):
    def setUp(self):
        super().setUp()
        self.nom_user = User.objects.create_user(
            name="ভাই", phone="01710000009", password="x",
            email="ta-nominee@example.com")
        Nominee.objects.create(user=self.owner, name="ভাই",
                               contact="+8801710000009")
        Nominee.objects.create(user=self.owner, name="No app",
                               contact="01999999999")

    def _switch(self, on):
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "alert_nominee": on},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def test_off_by_default_nominee_gets_nothing(self):
        self.assertFalse(AntiTheftEngine._meta.get_field("alert_nominee").default)
        self._ingest([{"id": "sim-1", "kind": "sim_change",
                       "data": {"state": "inserted", "v": 2}}])
        self.assertFalse(NotifEvent.objects.filter(user=self.nom_user).exists())
        self.assertFalse(can_view(self.phone, self.nom_user))

    def test_on_nominee_gets_theft_alerts_and_may_view(self):
        self._switch(True)
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertTrue(st["alert_nominee"])
        self.assertEqual(st["nominees_saved"], 2)
        self.assertEqual(st["nominees_reachable"], 1)
        self.assertEqual([u.pk for u in nominee_users(self.phone)],
                         [self.nom_user.pk])
        self._ingest([{"id": "sim-1", "kind": "sim_change",
                       "data": {"state": "inserted", "v": 2}}])
        n = NotifEvent.objects.get(user=self.nom_user,
                                   meta__antitheft_kind="sim_change")
        self.assertEqual(n.route, "security/watch-phone")
        self.assertTrue(can_view(self.phone, self.nom_user))

    def test_nominee_never_gets_non_theft_kinds(self):
        self._switch(True)
        self._ingest([{"id": "sn-1", "kind": "snatch"},
                      {"id": "lb-1", "kind": "low_battery", "battery": 9}])
        self.assertFalse(NotifEvent.objects.filter(user=self.nom_user).exists())

    def test_nominee_has_no_remote_switch_role(self):
        from core.views_at_remote import role_for
        self._switch(True)
        self.assertIsNone(role_for(self.phone, self.nom_user))

    def test_watching_lists_phone_view_only_for_nominee(self):
        self._switch(True)
        self.client.force_authenticate(self.nom_user)
        rows = self.client.get("/api/v1/security/engine/watching").data["watching"]
        self.assertEqual([r["phone_id"] for r in rows], [self.phone.id])
        self.assertFalse(rows[0]["can_command"])
        self.client.force_authenticate(self.family)
        rows = self.client.get("/api/v1/security/engine/watching").data["watching"]
        self.assertTrue(rows[0]["can_command"])
        self.client.force_authenticate(self.owner)

    def test_switch_off_again_stops_view(self):
        self._switch(True)
        self._switch(False)
        self.assertFalse(can_view(self.phone, self.nom_user))


@override_settings(ASSISTO_BASE_URL="https://assisto.example")
class PhotoPushTests(_Base):
    def setUp(self):
        super().setUp()
        self._enable(intruder_photo=True, intruder_consent=1)
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            device_hash=own_device.device_hash(DEV))

    def _post_photo(self):
        f = io.BytesIO(_jpeg())
        f.name = "x.jpg"
        return self.client.post(
            "/api/v1/security/engine/photo",
            {"file": f, "id": "ph-ta",
             "data": json.dumps({"source": "in_app_wrong_pin"})},
            format="multipart", HTTP_X_ASSISTO_ENGINE=self.token)

    def test_photo_rides_in_the_push_and_link_works_for_that_recipient(self):
        with mock.patch.object(push, "safe_push") as sp:
            r = self._post_photo()
        self.assertEqual(r.status_code, 200, r.data)
        calls = {c.args[0].pk: c for c in sp.call_args_list}
        fam = calls[self.family.pk]
        url = fam.kwargs["image"]
        self.assertTrue(url.startswith(
            "https://assisto.example/api/v1/security/engine/event/"))
        self.assertEqual(fam.kwargs["data"]["photo_url"], url)
        # the owner copy carries its OWN link (bound to the owner)
        own_url = calls[self.owner.pk].kwargs["data"]["photo_url"]
        self.assertNotEqual(own_url, url)
        # the family's link streams the decrypted JPEG ...
        path = url.split("https://assisto.example/api/v1", 1)[1]
        self.client.force_authenticate(None)
        resp = self.client.get("/api/v1" + path)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.content[:3], b"\xff\xd8\xff")
        # ... a tampered viewer id is 404
        bad = path.replace("v=%d" % self.family.pk, "v=%d" % self.stranger.pk)
        self.assertEqual(self.client.get("/api/v1" + bad).status_code, 404)

    @override_settings(ASSISTO_BASE_URL="http://127.0.0.1:8700")
    def test_no_https_base_means_text_only_push(self):
        with mock.patch.object(push, "safe_push") as sp:
            self._post_photo()
        fam = [c for c in sp.call_args_list if c.args[0].pk == self.family.pk][0]
        self.assertIsNone(fam.kwargs.get("image"))
        self.assertNotIn("photo_url", fam.kwargs["data"])

    def test_photo_alert_wording_names_the_security_pin(self):
        self._post_photo()
        n = NotifEvent.objects.get(user=self.family,
                                   meta__antitheft_kind="intruder_photo")
        self.assertIn("Security PIN", n.body_en)


class RetentionTests(_Armed):
    def test_prune_expired_removes_old_events_and_photos(self):
        old = AntiTheftEvent.objects.create(
            phone=self.phone, client_id="old-1", kind="intruder_photo",
            at=timezone.now() - timedelta(days=at.EVENT_RETENTION_DAYS + 1))
        old.photo.save("old.enc", ContentFile(at.encrypt_photo(_jpeg())), save=True)
        name = old.photo.name
        storage = old.photo.storage
        fresh = AntiTheftEvent.objects.create(
            phone=self.phone, client_id="new-1", kind="sim_change",
            at=timezone.now())
        self.assertGreaterEqual(prune_expired(), 1)
        self.assertFalse(AntiTheftEvent.objects.filter(pk=old.pk).exists())
        self.assertTrue(AntiTheftEvent.objects.filter(pk=fresh.pk).exists())
        self.assertFalse(storage.exists(name))
