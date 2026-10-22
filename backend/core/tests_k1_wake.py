"""k1-wake — "Hey Assisto" on openWakeWord: the server only serves our own
model files (manifest-gated, licence-gated) and never asks for a key."""
import hashlib
import json
import os
import shutil
import tempfile

from rest_framework.test import APITestCase

from core.models import User


class WakeConfigTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="W", phone="01710000951", password="pw")
        self.dir = tempfile.mkdtemp(prefix="k1wake")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def _install(self, cleared=True, roles=("mel", "embed", "wake"), thresholds=None):
        files = []
        for r in roles:
            name = f"assisto_{r}.onnx"
            data = (r * 50).encode()
            with open(os.path.join(self.dir, name), "wb") as f:
                f.write(data)
            files.append({"role": r, "name": name, "sha256": hashlib.sha256(data).hexdigest(),
                          "size": len(data)})
        m = {"version": "2026.10.1", "engine": "openwakeword", "licence_cleared": cleared,
             "frames": 16, "files": files,
             "thresholds": thresholds or {"low": 0.8, "normal": 0.6, "high": 0.4}}
        with open(os.path.join(self.dir, "manifest.json"), "w") as f:
            json.dump(m, f)
        return m

    def _cfg(self):
        self.client.force_authenticate(self.u)
        with self.settings(WAKEWORD_DIR=self.dir):
            return self.client.get("/api/v1/voice/config").data["wake"]

    def test_pending_without_manifest(self):
        w = self._cfg()
        self.assertFalse(w["available"])
        self.assertEqual(w["reason"], "model_pending")
        self.assertEqual(w["engine"], "openwakeword")
        self.assertEqual(w["files"], [])

    def test_available_with_manifest(self):
        self._install()
        w = self._cfg()
        self.assertTrue(w["available"])
        self.assertEqual([f["role"] for f in w["files"]], ["mel", "embed", "wake"])
        self.assertTrue(w["files"][2]["url"].endswith("/api/v1/voice/wake-model/assisto_wake.onnx"))
        self.assertEqual(len(w["files"][0]["sha256"]), 64)
        self.assertAlmostEqual(w["thresholds"]["normal"], 0.6)
        self.assertIn("Hey Assisto", w["phrases"])

    def test_licence_not_cleared_is_not_served(self):
        self._install(cleared=False)
        w = self._cfg()
        self.assertFalse(w["available"])
        self.assertEqual(w["reason"], "licence_pending")
        with self.settings(WAKEWORD_DIR=self.dir):
            r = self.client.get("/api/v1/voice/wake-model/assisto_wake.onnx")
        self.assertEqual(r.status_code, 404)

    def test_incomplete_manifest_is_pending(self):
        self._install(roles=("mel", "wake"))
        self.assertEqual(self._cfg()["reason"], "model_pending")

    def test_bad_hash_rejected(self):
        m = self._install()
        m["files"][0]["sha256"] = "nothex"
        with open(os.path.join(self.dir, "manifest.json"), "w") as f:
            json.dump(m, f)
        self.assertFalse(self._cfg()["available"])

    def test_thresholds_clamped(self):
        self._install(thresholds={"low": 5, "normal": "x", "high": -1})
        th = self._cfg()["thresholds"]
        self.assertEqual(th["low"], 0.99)
        self.assertEqual(th["normal"], 0.5)  # default kept on bad value
        self.assertEqual(th["high"], 0.01)

    def test_file_download_public_and_whitelisted(self):
        self._install()
        with self.settings(WAKEWORD_DIR=self.dir):
            r = self.client.get("/api/v1/voice/wake-model/assisto_embed.onnx")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(b"".join(r.streaming_content), b"embed" * 50)
            self.assertEqual(self.client.get("/api/v1/voice/wake-model/manifest.json").status_code, 404)
            self.assertEqual(self.client.get("/api/v1/voice/wake-model/..%2Fsettings.onnx").status_code, 404)
            self.assertEqual(self.client.get("/api/v1/voice/wake-model/other.onnx").status_code, 404)

    def test_no_key_fields_anywhere(self):
        self._install()
        w = self._cfg()
        for k in ("access_key", "keyword_url", "keyword_urls"):
            self.assertNotIn(k, w)
