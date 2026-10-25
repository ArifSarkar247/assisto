"""p2-photo: on-device AI model route — manifest validation, licence gate
(never served when not cleared), only manifest-listed names, HTTP Range for
resumable downloads (206 / 416 / suffix / If-Range), and the Photo Studio config
carrying ai_model + is_owner (prompt section hidden without a key)."""
import hashlib
import json
import os
import shutil
import tempfile

from django.test import SimpleTestCase, override_settings
from rest_framework.test import APITestCase

from core import photo_models as PM
from core.models import User

BLOB = bytes(range(256)) * 40  # 10240 bytes, recognisable content
NAME = "realesr_general_x4v3_t144.onnx"


def _write(d, *, cleared=True, size=None, sha=None, name=NAME, kind="upscale", extra=None):
    with open(os.path.join(d, name), "wb") as f:
        f.write(BLOB)
    m = {"version": "2026.10.1", "kind": kind, "model": "realesr-general-x4v3",
         "licence": "BSD-3-Clause", "licence_cleared": cleared, "scale": 4, "tile": 144,
         "pad": 8, "files": [{"role": "upscale", "name": name,
                              "sha256": sha or hashlib.sha256(BLOB).hexdigest(),
                              "size": len(BLOB) if size is None else size}]}
    m.update(extra or {})
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(m, f)


class _Dir:
    def setUp(self):
        super().setUp()
        self.d = tempfile.mkdtemp()
        self._o = override_settings(PHOTO_MODEL_DIR=self.d)
        self._o.enable()
        # these tests cover the Real-ESRGAN-ALLOWED world (photo-final flag;
        # the default-off world is in tests_photo_final.RealEsrganFlagTests)
        from unittest import mock as _m
        from core import photo_models as _PM
        _p = _m.patch.object(_PM, "realesrgan_allowed", return_value=True)
        _p.start()
        self.addCleanup(_p.stop)

    def tearDown(self):
        self._o.disable()
        shutil.rmtree(self.d, ignore_errors=True)
        super().tearDown()


class ManifestTests(_Dir, SimpleTestCase):
    def test_missing_manifest_is_model_pending(self):
        self.assertIsNone(PM.load_manifest())
        c = PM.client_manifest()
        self.assertFalse(c["available"])
        self.assertEqual(c["reason"], "model_pending")
        self.assertEqual(c["files"], [])

    def test_valid_manifest(self):
        _write(self.d)
        c = PM.client_manifest()
        self.assertTrue(c["available"])
        self.assertEqual(c["files"][0]["sha256"], hashlib.sha256(BLOB).hexdigest())
        self.assertEqual(c["files"][0]["size"], len(BLOB))
        self.assertEqual(c["files"][0]["url"], "/api/v1/photo-studio/model/" + NAME)
        self.assertEqual((c["scale"], c["tile"], c["pad"]), (4, 144, 8))

    def test_not_cleared_never_lists_files(self):
        _write(self.d, cleared=False)
        c = PM.client_manifest()
        self.assertFalse(c["available"])
        self.assertEqual(c["reason"], "licence_pending")
        self.assertEqual(c["files"], [])

    def test_cleared_must_be_literal_true(self):
        _write(self.d, cleared="yes")
        self.assertEqual(PM.client_manifest()["reason"], "licence_pending")

    def test_invalid_entries_rejected(self):
        for kw in ({"size": 5}, {"sha": "abc"}, {"name": "../x.onnx"}, {"kind": "wake"}):
            shutil.rmtree(self.d)
            os.makedirs(self.d)
            try:
                _write(self.d, **kw)
            except OSError:
                continue  # unwritable traversal name: nothing to serve anyway
            self.assertIsNone(PM.load_manifest(), kw)

    def test_listed_file_missing(self):
        _write(self.d)
        os.remove(os.path.join(self.d, NAME))
        self.assertIsNone(PM.load_manifest())

    def test_parse_range(self):
        self.assertIsNone(PM.parse_range("", 100))
        self.assertEqual(PM.parse_range("bytes=0-9", 100), (0, 9))
        self.assertEqual(PM.parse_range("bytes=90-", 100), (90, 99))
        self.assertEqual(PM.parse_range("bytes=90-500", 100), (90, 99))
        self.assertEqual(PM.parse_range("bytes=-10", 100), (90, 99))
        self.assertEqual(PM.parse_range("bytes=-500", 100), (0, 99))
        self.assertEqual(PM.parse_range("bytes=100-", 100), "unsatisfiable")
        self.assertEqual(PM.parse_range("bytes=9-3", 100), "unsatisfiable")
        self.assertEqual(PM.parse_range("bytes=-0", 100), "unsatisfiable")
        self.assertIsNone(PM.parse_range("bytes=0-1,5-6", 100))  # multi: whole file
        self.assertIsNone(PM.parse_range("items=0-1", 100))


class ModelRouteTests(_Dir, APITestCase):
    url = "/api/v1/photo-studio/model/" + NAME

    def _body(self, r):
        return b"".join(r.streaming_content) if hasattr(r, "streaming_content") else r.content

    def test_full_download_public(self):
        _write(self.d)
        r = self.client.get(self.url)  # no login: open model, no user data
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._body(r), BLOB)
        self.assertEqual(r["Accept-Ranges"], "bytes")
        self.assertEqual(r["Content-Length"], str(len(BLOB)))
        self.assertEqual(r["ETag"], '"%s"' % hashlib.sha256(BLOB).hexdigest())

    def test_range_resume(self):
        _write(self.d)
        r = self.client.get(self.url, HTTP_RANGE="bytes=4000-")
        self.assertEqual(r.status_code, 206)
        self.assertEqual(self._body(r), BLOB[4000:])
        self.assertEqual(r["Content-Range"], "bytes 4000-%d/%d" % (len(BLOB) - 1, len(BLOB)))
        self.assertEqual(r["Content-Length"], str(len(BLOB) - 4000))
        r = self.client.get(self.url, HTTP_RANGE="bytes=10-19")
        self.assertEqual(self._body(r), BLOB[10:20])
        # resumed halves == the whole file
        a = self._body(self.client.get(self.url, HTTP_RANGE="bytes=0-5119"))
        b = self._body(self.client.get(self.url, HTTP_RANGE="bytes=5120-"))
        self.assertEqual(hashlib.sha256(a + b).hexdigest(), hashlib.sha256(BLOB).hexdigest())

    def test_range_unsatisfiable(self):
        _write(self.d)
        r = self.client.get(self.url, HTTP_RANGE="bytes=%d-" % len(BLOB))
        self.assertEqual(r.status_code, 416)
        self.assertEqual(r["Content-Range"], "bytes */%d" % len(BLOB))

    def test_if_range_other_version_gets_whole_file(self):
        _write(self.d)
        r = self.client.get(self.url, HTTP_RANGE="bytes=100-", HTTP_IF_RANGE='"deadbeef"')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._body(r), BLOB)
        etag = '"%s"' % hashlib.sha256(BLOB).hexdigest()
        r = self.client.get(self.url, HTTP_RANGE="bytes=100-", HTTP_IF_RANGE=etag)
        self.assertEqual(r.status_code, 206)

    def test_head(self):
        _write(self.d)
        r = self.client.head(self.url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Length"], str(len(BLOB)))

    def test_not_cleared_is_404(self):
        _write(self.d, cleared=False)
        self.assertEqual(self.client.get(self.url).status_code, 404)

    def test_unlisted_name_is_404(self):
        _write(self.d)
        with open(os.path.join(self.d, "other.onnx"), "wb") as f:
            f.write(b"x")
        self.assertEqual(self.client.get("/api/v1/photo-studio/model/other.onnx").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/photo-studio/model/manifest.json").status_code, 404)

    def test_no_model_is_404(self):
        self.assertEqual(self.client.get(self.url).status_code, 404)

    def test_manifest_route_needs_login_and_gives_absolute_urls(self):
        _write(self.d)
        self.assertIn(self.client.get("/api/v1/photo-studio/model").status_code, (401, 403))
        u = User.objects.create_user(name="M", phone="01710000951", password="pw")
        self.client.force_authenticate(u)
        r = self.client.get("/api/v1/photo-studio/model")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["available"])
        self.assertTrue(r.data["files"][0]["url"].startswith("http"))
        self.assertTrue(r.data["files"][0]["url"].endswith("/api/v1/photo-studio/model/" + NAME))


class ConfigTests(_Dir, APITestCase):
    def test_config_carries_model_and_owner_flag(self):
        u = User.objects.create_user(name="U", phone="01710000952", password="pw")
        self.client.force_authenticate(u)
        r = self.client.get("/api/v1/photo-studio/config")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["is_owner"])
        self.assertFalse(r.data["ai_model"]["available"])
        self.assertEqual(r.data["ai_model"]["reason"], "model_pending")
        # no provider connected in tests -> the app hides the prompt section
        self.assertFalse(r.data["providers"]["ready"])
        _write(self.d)
        o = User.objects.create_user(name="O", phone="01710000953", password="pw")
        o.is_superuser = True
        o.is_staff = True
        o.save()
        self.client.force_authenticate(o)
        r = self.client.get("/api/v1/photo-studio/config")
        self.assertTrue(r.data["is_owner"])
        self.assertTrue(r.data["ai_model"]["available"])
        self.assertEqual(len(r.data["ai_model"]["files"]), 1)
