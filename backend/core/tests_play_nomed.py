"""play-nomed — the Google Play build (header X-Assisto-Flavour: play) never
gets medicine schedules from chat (a plain reminder instead) and never gets
medicine suggestions. The website APK (no header) is unchanged."""
from rest_framework.test import APITestCase

from core import agent
from core.models import Medicine, Reminder, User

PLAY = {"HTTP_X_ASSISTO_FLAVOUR": "play", "HTTP_ACCEPT_LANGUAGE": "en"}
APK = {"HTTP_ACCEPT_LANGUAGE": "en"}


class PlaySafeParseTests(APITestCase):
    def test_medicine_becomes_reminder(self):
        p = agent.parse("take medicine at 9pm", "en")
        self.assertEqual(p["intent"], "medicine")
        q = agent.play_safe(p, "take medicine at 9pm", "en")
        self.assertEqual(q["intent"], "reminder")
        self.assertEqual(q["title"], "take medicine at 9pm")
        self.assertEqual(q["due"], p["due"])

    def test_other_intents_unchanged(self):
        p = {"intent": "expense", "amount": "50"}
        self.assertIs(agent.play_safe(p, "50 tea", "en"), p)


class PlayAgentViewTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="P", phone="01710000951", password="pw")
        self.client.force_authenticate(self.u)

    def test_play_creates_reminder_not_medicine(self):
        r = self.client.post("/api/v1/agent", {"text": "take medicine at 9pm"},
                             format="json", **PLAY)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Medicine.objects.filter(user=self.u).count(), 0)
        self.assertEqual(Reminder.objects.filter(user=self.u).count(), 1)
        self.assertNotIn("medicine", [c.get("type") for c in r.data["cards"]])

    def test_website_apk_still_creates_medicine(self):
        r = self.client.post("/api/v1/agent", {"text": "take medicine at 9pm"},
                             format="json", **APK)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Medicine.objects.filter(user=self.u).count(), 1)


class PlaySuggestionTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="S", phone="01710000952", password="pw")
        self.client.force_authenticate(self.u)

    def _keys(self, headers):
        r = self.client.get("/api/v1/home/suggestions?lang=en&refresh=1", **headers)
        self.assertEqual(r.status_code, 200)
        return [p["key"] for p in r.data["prompts"]]

    def test_play_never_suggests_medicine(self):
        keys = self._keys(PLAY)
        self.assertTrue(keys)
        self.assertFalse([k for k in keys if "medicine" in k])

    def test_website_new_user_gets_medicine_onboarding(self):
        self.assertIn("onboard_medicine", self._keys(APK))
