"""blood (owner 2 Nov): Owner Admin -> Blood donors (request queue: hide /
restore / remove + ban, audit; slip queue: approve / reject deletes the
photo; bn/en; owner only)."""
import base64
import io
import os
import shutil
import tempfile
from datetime import timedelta

from django.test import override_settings
from django.utils import timezone

from core import blood_panel as BP
from core.models import (BloodDonor, BloodEvent, BloodReport, BloodRequest, BloodVerification,
                         OwnerAudit, User)
from web.tests_o2_owner_admin import OwnerBase, SClient

_TMP = tempfile.mkdtemp(prefix="blood-owner-media-")


def _jpeg_b64():
    from PIL import Image
    out = io.BytesIO()
    Image.new("RGB", (20, 20), (10, 10, 200)).save(out, "JPEG")
    return base64.b64encode(out.getvalue()).decode()


@override_settings(MEDIA_ROOT=_TMP)
class BloodOwnerTests(OwnerBase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_TMP, ignore_errors=True)

    def setUp(self):
        super().setUp()
        self.req_user = User.objects.create_user(name="Requester", phone="01788000001", password="x")
        self.rep = User.objects.create_user(name="Rep", phone="01788000002", password="x")
        self.donor = User.objects.create_user(name="Donor", phone="01788000003", password="x")
        self.r = BloodRequest.objects.create(
            requester=self.req_user, blood_group="AB-", units=2, hospital="Dhaka Medical",
            area_text="Shahbag", district="dhaka", needed_by=timezone.now() + timedelta(hours=4),
            expires_at=timezone.now() + timedelta(hours=10), state="hidden", hidden_from="active")
        BloodReport.objects.create(request=self.r, reporter=self.rep, reason="selling", note="asks money")
        BloodDonor.objects.create(user=self.donor, enabled=True, consent_at=timezone.now(),
                                  consent_version=1, blood_group="O+", district="dhaka")
        self.ready()

    def test_queue_lists_hidden_with_reports(self):
        r = self.c.get("/owner/blood?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Dhaka Medical")
        self.assertContains(r, "asks money")
        r = self.c.get("/owner/blood?lang=bn&status=bogus")
        self.assertContains(r, "রক্তদাতা")

    def test_restore_and_remove_ban_audited(self):
        r = self.post("/owner/blood/%d/act" % self.r.pk, {"action": "restore"})
        self.assertEqual(r.status_code, 302)
        self.r.refresh_from_db()
        self.assertEqual(self.r.state, "active")
        self.post("/owner/blood/%d/act" % self.r.pk, {"action": "remove_ban"})
        self.r.refresh_from_db()
        self.assertEqual(self.r.state, "removed")
        self.assertTrue(BloodEvent.objects.filter(kind="poster_banned", actor=self.req_user).exists())
        self.assertTrue(OwnerAudit.objects.filter(action="blood_request.remove_ban").exists())
        r = self.post("/owner/blood/%d/act" % self.r.pk, {"action": "bogus"})
        self.assertIn("m=invalid", r["Location"])
        self.assertEqual(self.post("/owner/blood/99999/act", {"action": "hide"}).status_code, 404)

    def test_slip_queue_approve_deletes_photo(self):
        v, err = BP.submit_slip(self.donor, _jpeg_b64())
        self.assertIsNone(err)
        path = v.photo.path
        r = self.c.get("/owner/blood?status=slips&lang=en")
        self.assertContains(r, "Slip photo")
        r = self.post("/owner/blood/slip/%d" % v.pk, {"action": "approve"})
        self.assertEqual(r.status_code, 302)
        v.refresh_from_db()
        self.assertEqual(v.state, "approved")
        self.assertFalse(os.path.exists(path))
        self.assertTrue(BloodDonor.objects.get(user=self.donor).verified_at)
        self.assertTrue(OwnerAudit.objects.filter(action="blood_slip.approve").exists())
        r = self.post("/owner/blood/slip/%d" % v.pk, {"action": "reject"})
        self.assertIn("m=invalid", r["Location"])

    def test_requires_owner(self):
        r = SClient().get("/owner/blood")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
