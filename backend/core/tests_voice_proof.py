"""voice-proof (18 Nov): "open CCTV" from chat / voice (bn + en) resolves to
the app's CCTV route, and the speech-to-text endpoint can point at an
OpenAI-compatible server (self-hosted Whisper / Groq; the CI proof's local
Whisper) without ever sending audio to a plain-http remote host."""
from django.test import SimpleTestCase

from core import bizagent_media as BM
from core import screen_synonyms as SS

OPENAI = "https://api.openai.com/v1/audio/transcriptions"


class CctvSynonymTests(SimpleTestCase):
    def test_open_cctv_bn_en(self):
        for text in ("open cctv", "show my security cameras", "open the shop camera",
                     "সিসিটিভি খোলো", "সিসি ক্যামেরা দেখাও", "দোকানের ক্যামেরা খোলো"):
            self.assertEqual(SS.resolve(text), "watchman", text)

    def test_others_unchanged(self):
        self.assertEqual(SS.resolve("open voice assistant"), "voice_assistant")
        self.assertEqual(SS.resolve("আমার হিসাব দেখাও"), "money")
        self.assertEqual(SS.resolve("show my docs"), "documents")


class SttUrlTests(SimpleTestCase):
    def test_default_openai(self):
        self.assertEqual(BM.stt_url({}), OPENAI)
        self.assertEqual(BM.stt_url({"base_url": ""}), OPENAI)
        self.assertEqual(BM.stt_url(None), OPENAI)

    def test_https_compatible_server(self):
        self.assertEqual(BM.stt_url({"base_url": "https://api.groq.com/openai/v1/"}),
                         "https://api.groq.com/openai/v1/audio/transcriptions")

    def test_plain_http_only_on_this_machine(self):
        self.assertEqual(BM.stt_url({"base_url": "http://127.0.0.1:9077/v1"}),
                         "http://127.0.0.1:9077/v1/audio/transcriptions")
        self.assertEqual(BM.stt_url({"base_url": "http://localhost:9077/v1"}),
                         "http://localhost:9077/v1/audio/transcriptions")
        # audio must never go over plain http to another host
        self.assertEqual(BM.stt_url({"base_url": "http://example.com/v1"}), OPENAI)
        self.assertEqual(BM.stt_url({"base_url": "ftp://127.0.0.1/v1"}), OPENAI)
        self.assertEqual(BM.stt_url({"base_url": "https://user:pw@example.com/v1"}), OPENAI)
        self.assertEqual(BM.stt_url({"base_url": "https://example.com/v1?x=1"}), OPENAI)
        self.assertEqual(BM.stt_url({"base_url": "not a url"}), OPENAI)
