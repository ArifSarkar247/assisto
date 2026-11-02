"""playaudit2 (8 Nov all-features Play launch):

  * /.well-known/assetlinks.json reads the Play APP SIGNING key SHA-256 from
    Owner Admin -> Integrations -> "Android App Links" (never hard-coded),
    keeps the legacy ANDROID_CERT_SHA256 (website APK key) too, drops junk;
  * Play UGC policy: a train-chat report reaches the owner's moderation queue
    (Owner Admin -> Channel reports, kind "person") with the reported text;
    "Remove" hides that person's train-chat messages; audited.
"""
import os
from datetime import date
from unittest import mock

from django.test import TestCase, override_settings

from core import integrations as I
from core import train_service as TS
from core.models import (ModerationItem, ModerationReport, OwnerAudit,
                         TrainChatMember, TrainChatMessage, User)
from web.tests_o2_owner_admin import OwnerBase

FP_PLAY = ":".join(["AB"] * 32)
FP_WEB = ":".join(["0C"] * 32)


class AppLinkFingerprintTests(TestCase):
    def test_normalise(self):
        bare = "ab" * 32
        self.assertEqual(I.app_link_fingerprints(bare), [FP_PLAY])
        self.assertEqual(I.app_link_fingerprints(" %s , %s,%s,junk " % (FP_PLAY.lower(), FP_WEB, FP_PLAY)),
                         [FP_PLAY, FP_WEB])
        self.assertEqual(I.app_link_fingerprints(""), [])
        self.assertEqual(I.app_link_fingerprints("AB:CD"), [])

    def test_owner_test_button(self):
        self.assertTrue(I.test_android_app_links({"sha256_fingerprints": FP_PLAY})[0])
        self.assertFalse(I.test_android_app_links({"sha256_fingerprints": "nope"})[0])
        self.assertFalse(I.test_android_app_links({"sha256_fingerprints": FP_PLAY + ",nope"})[0])
        self.assertIn("android_app_links", I.REGISTRY)
        f = I.REGISTRY["android_app_links"]["fields"][0]
        self.assertEqual(f["key"], "sha256_fingerprints")
        self.assertFalse(f["secret"])  # a public value, shown back to the owner


class AssetLinksFromOwnerAdminTests(TestCase):
    def _get(self):
        r = self.client.get("/.well-known/assetlinks.json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "application/json")
        return r.json()

    @override_settings(ANDROID_CERT_SHA256="")
    def test_empty_until_owner_pastes(self):
        os.environ.pop("ANDROID_CERT_SHA256", None)
        self.assertEqual(self._get(), [])

    @override_settings(ANDROID_CERT_SHA256="")
    def test_play_signing_key_from_integrations(self):
        os.environ.pop("ANDROID_CERT_SHA256", None)
        I.save("android_app_links", {"sha256_fingerprints": FP_PLAY.lower()})
        j = self._get()
        self.assertEqual(j[0]["relation"], ["delegate_permission/common.handle_all_urls"])
        self.assertEqual(j[0]["target"]["package_name"], "com.assisto.assisto")
        self.assertEqual(j[0]["target"]["sha256_cert_fingerprints"], [FP_PLAY])

    def test_both_keys_and_no_duplicates(self):
        I.save("android_app_links", {"sha256_fingerprints": FP_PLAY + "," + FP_WEB})
        with override_settings(ANDROID_CERT_SHA256=FP_WEB):
            j = self._get()
        self.assertEqual(j[0]["target"]["sha256_cert_fingerprints"], [FP_PLAY, FP_WEB])

    @override_settings(ANDROID_CERT_SHA256="")
    def test_store_error_never_500(self):
        os.environ.pop("ANDROID_CERT_SHA256", None)
        with mock.patch("core.integrations.get", side_effect=RuntimeError("no fernet")):
            self.assertEqual(self._get(), [])


def _room_msg(user, text="buy cheap tickets 017..."):
    from datetime import timedelta
    from django.utils import timezone
    ends = timezone.now() + timedelta(hours=6)
    m = TrainChatMember.objects.create(
        user=user, train_no="701", service_date=date(2026, 11, 2), nickname="নীল",
        ends_at=ends)
    return TrainChatMessage.objects.create(member=m, train_no="701",
                                           service_date=date(2026, 11, 2), text=text,
                                           ends_at=ends)


class TrainReportQueueTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.spammer = User.objects.create_user(name="Spammer", phone="01788100001", password="x")
        self.rep1 = User.objects.create_user(name="R1", phone="01788100002", password="x")
        self.rep2 = User.objects.create_user(name="R2", phone="01788100003", password="x")
        self.msg = _room_msg(self.spammer)

    def test_report_opens_one_person_item(self):
        self.assertEqual(TS.report(self.rep1, self.msg, "other"), "ok")
        self.assertEqual(TS.report(self.rep2, self.msg, "spam"), "ok")
        items = ModerationItem.objects.filter(target_kind="person",
                                              target_id=str(self.spammer.pk))
        self.assertEqual(items.count(), 1)
        it = items.get()
        self.assertEqual(it.report_count, 2)
        self.assertEqual(sorted(it.categories), ["other", "spam"])
        r = ModerationReport.objects.filter(target_kind="person").first()
        self.assertEqual(r.snapshot_source, "train_chat")
        self.assertIn("buy cheap", r.snapshot[0]["text"])
        self.assertTrue(r.valid)

    def test_queue_failure_never_breaks_the_report(self):
        with mock.patch("core.models.ModerationItem.objects.create",
                        side_effect=RuntimeError("db hiccup")):
            self.assertEqual(TS.report(self.rep1, self.msg, "other"), "ok")
        self.assertEqual(self.msg.__class__.objects.get(pk=self.msg.pk).reporters, [self.rep1.pk])

    def test_owner_sees_and_removes(self):
        TS.report(self.rep1, self.msg, "harassment")
        it = ModerationItem.objects.get(target_kind="person")
        self.ready()
        r = self.c.get("/owner/channel-reports?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Spammer")
        self.assertContains(r, "buy cheap")
        self.assertContains(r, "/owner/users/%d" % self.spammer.pk)
        r = self.post("/owner/channel-reports/%d/act" % it.pk, {"action": "remove"})
        self.assertEqual(r.status_code, 302)
        self.msg.refresh_from_db()
        self.assertTrue(self.msg.hidden)
        it.refresh_from_db()
        self.assertEqual(it.queue_state, "resolved")
        self.assertTrue(OwnerAudit.objects.filter(action="channel_report.remove").exists())


class MinorNoAdsTests(TestCase):
    """Play Families / ads: a parent-declared child account gets no ads."""

    def setUp(self):
        from rest_framework.test import APIClient
        self.kid = User.objects.create_user(name="Kid", phone="01788200001", password="x")
        self.dad = User.objects.create_user(name="Dad", phone="01788200002", password="x")
        for u in (self.kid, self.dad):
            u.plan = "free"
            u.trial_until = None
            u.save()
        self.api = APIClient()

    def _cfg(self, u):
        self.api.force_authenticate(u)
        r = self.api.get("/api/v1/ads/config")
        self.assertEqual(r.status_code, 200)
        return r.data

    def test_child_by_kid_audio_birth_year(self):
        from django.utils import timezone
        from core.guardianship import is_known_minor
        from core.models import KidAudioConsent
        self.assertTrue(self._cfg(self.kid)["ads_enabled"])
        KidAudioConsent.objects.create(guardian=self.dad, child=self.kid,
                                       birth_year=timezone.now().year - 12)
        self.assertTrue(is_known_minor(self.kid))
        d = self._cfg(self.kid)
        self.assertFalse(d["ads_enabled"])
        self.assertEqual(d["ads_off_reason"], "minor")
        self.assertEqual(d["plan"], "free")
        # the parent still has normal (Free) ads
        self.assertFalse(is_known_minor(self.dad))
        self.assertTrue(self._cfg(self.dad)["ads_enabled"])

    def test_adult_birth_year_is_not_a_minor(self):
        from django.utils import timezone
        from core.guardianship import is_known_minor
        from core.models import KidAudioConsent
        KidAudioConsent.objects.create(guardian=self.dad, child=self.kid,
                                       birth_year=timezone.now().year - 30)
        self.assertFalse(is_known_minor(self.kid))

    def test_errors_never_block(self):
        from core.guardianship import is_known_minor
        with mock.patch("core.models.KidAudioConsent.objects.filter",
                        side_effect=RuntimeError("x")):
            self.assertFalse(is_known_minor(self.kid))
