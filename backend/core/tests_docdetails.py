"""docdetailsfix — a vault document uploaded WITH a photo (multipart) and
type fields (`details`, JSON-encoded string) must save the details map.
Before the fix DRF's JSONField str()'d the decoded map read from form input
-> 400 {"details": ["Value must be valid JSON."]} for every photo upload
that carried any detail field."""
import json
import shutil
import tempfile

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core.models import Document, User

_MEDIA = tempfile.mkdtemp(prefix="docdetails-")


@override_settings(MEDIA_ROOT=_MEDIA)
class MultipartDetailsTests(TestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_MEDIA, ignore_errors=True)

    def setUp(self):
        self.u = User.objects.create_user(name="A", phone="01719990001", password="pw-123456x")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_photo_plus_details_saves_the_map(self):
        details = {"number": "A01234567", "note": "a;b|c=d", "issue_date": "2020-01-02"}
        r = self.c.post("/api/v1/documents/", {
            "title": "Passport", "doc_type": "passport",
            "details": json.dumps(details), "note": "kept",
            "file": SimpleUploadedFile("p.jpg", b"\xff\xd8\xff\xe0" + b"x" * 64, "image/jpeg"),
        }, format="multipart")
        self.assertEqual(r.status_code, 201, r.content)
        d = Document.objects.get(pk=r.json()["id"])
        self.assertEqual(d.details, details)
        self.assertEqual(d.note, "kept")
        self.assertTrue(d.file)

    def test_json_body_still_works(self):
        r = self.c.post("/api/v1/documents/", {"title": "NID", "doc_type": "nid",
                                               "details": {"number": "123"}}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Document.objects.get(pk=r.json()["id"]).details, {"number": "123"})
