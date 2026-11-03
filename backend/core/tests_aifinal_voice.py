"""aifinal round 2 item 1: server speech-to-text in Bangla script, never
romanized, never charged when it fails. Fake provider only."""
import base64
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase

from core import voice_transcribe as VT
from core.models import AIUsage

WAV = base64.b64encode(b"RIFF" + b"\0" * 8000).decode()


def _u():
    return get_user_model().objects.create_user(name="v", phone="+8801511000001",
                                                password="pw12345!")


class TranscribeTests(TestCase):
    def setUp(self):
        self.u = _u()
        self.charge = mock.patch("core.billing.charge", return_value={
            "ok": True, "charged": 1, "balance": 9, "spend_ref": "sp:1"})
        self.credit = mock.patch("core.billing.credit")
        self.charge.start()
        self.cr = self.credit.start()

    def tearDown(self):
        self.charge.stop()
        self.credit.stop()

    def test_bangla_script_comes_back(self):
        code, body = VT.transcribe(self.u, {"audio_b64": WAV, "lang": "bn"},
                                   call=lambda *a: ("ঢাকা থেকে গাজীপুর সিটি", 100, 10))
        self.assertEqual(code, 200)
        self.assertEqual(body["text"], "ঢাকা থেকে গাজীপুর সিটি")
        self.cr.assert_not_called()
        self.assertTrue(AIUsage.objects.get(feature="voice.transcribe").ok)

    def test_romanized_result_is_a_failure_and_refunded(self):
        code, body = VT.transcribe(self.u, {"audio_b64": WAV, "lang": "bn"},
                                   call=lambda *a: ("Dhaka theke Ghazipur City", 100, 10))
        self.assertEqual(code, 502)
        self.assertEqual(body["refunded"], 1)
        self.cr.assert_called_once()
        row = AIUsage.objects.get(feature="voice.transcribe")
        self.assertEqual((row.ok, row.refunded, row.error_kind), (False, 1, "romanized"))

    def test_provider_error_refunded(self):
        def boom(*a):
            raise RuntimeError("down")
        code, body = VT.transcribe(self.u, {"audio_b64": WAV, "lang": "bn"}, call=boom)
        self.assertEqual(code, 502)
        self.cr.assert_called_once()

    def test_bad_audio(self):
        self.assertEqual(VT.transcribe(self.u, {"audio_b64": ""}, call=lambda *a: ("x", 1, 1))[0], 400)
        big = base64.b64encode(b"0" * (VT.MAX_BYTES + 1)).decode()
        self.assertEqual(VT.transcribe(self.u, {"audio_b64": big}, call=lambda *a: ("x", 1, 1))[0], 413)
