"""a3-voice — Part 3 Assisto Voice backend: wake-word config is key-gated,
voice routes resolve, and a reminder that mentions "call" stays a reminder."""
from unittest import mock

from rest_framework.test import APITestCase

from core import agent, screen_synonyms
from core.models import Reminder, User


class VoiceConfigTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="V", phone="01710000901", password="pw")

    def test_requires_login(self):
        r = self.client.get("/api/v1/voice/config")
        self.assertIn(r.status_code, (401, 403))

    def test_off_until_key_set(self):
        self.client.force_authenticate(self.u)
        r = self.client.get("/api/v1/voice/config")
        self.assertEqual(r.status_code, 200)
        w = r.data["wake"]
        self.assertFalse(w["available"])
        self.assertEqual(w["access_key"], "")
        self.assertEqual(w["keyword_url"], "")

    def test_available_when_integration_working(self):
        self.client.force_authenticate(self.u)
        cfg = {"access_key": "fake-key-123", "keyword_url": "https://example.com/hey.ppn",
               "sensitivity": "0.7"}
        with mock.patch("core.integrations.is_enabled", return_value=True), \
                mock.patch("core.integrations.get", return_value=cfg):
            w = self.client.get("/api/v1/voice/config").data["wake"]
        self.assertTrue(w["available"])
        self.assertEqual(w["keyword_url"], "https://example.com/hey.ppn")
        self.assertAlmostEqual(w["sensitivity"], 0.7)

    def test_http_keyword_url_rejected(self):
        self.client.force_authenticate(self.u)
        cfg = {"access_key": "k", "keyword_url": "http://insecure/hey.ppn"}
        with mock.patch("core.integrations.is_enabled", return_value=True), \
                mock.patch("core.integrations.get", return_value=cfg):
            w = self.client.get("/api/v1/voice/config").data["wake"]
        self.assertFalse(w["available"])
        self.assertEqual(w["access_key"], "")

    def test_registry_has_picovoice(self):
        from core import integrations
        self.assertIn("picovoice", integrations.REGISTRY)
        ok, _ = integrations.test_picovoice({"access_key": "", "keyword_url": "https://x"})
        self.assertFalse(ok)


class VoiceRoutingTests(APITestCase):
    def test_screen_synonyms(self):
        self.assertEqual(screen_synonyms.resolve("open voice assistant"), "voice_assistant")
        self.assertEqual(screen_synonyms.resolve("set default assistant"), "voice_settings")

    def test_reminder_with_call_word_is_reminder(self):
        p = agent.parse("remind me to call mum tomorrow", "en")
        self.assertEqual(p["intent"], "reminder")
        p = agent.parse("কাল আম্মুকে ফোন করতে মনে করিয়ে দিও", "bn")
        self.assertEqual(p["intent"], "reminder")

    def test_plain_call_still_call(self):
        self.assertEqual(agent.parse("আম্মুকে কল দাও", "bn")["intent"], "call")

    def test_agent_creates_reminder_row(self):
        u = User.objects.create_user(name="R", phone="01710000902", password="pw")
        self.client.force_authenticate(u)
        r = self.client.post("/api/v1/agent", {"text": "remind me to call mum tomorrow"},
                             format="json")
        self.assertEqual(r.data["intent"], "reminder")
        self.assertTrue(Reminder.objects.filter(user=u).exists())
