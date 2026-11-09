"""geminifix: Owner Admin shows the LAST REAL Gemini error as a red Bangla +
English line (AI levels, Integrations, AI) and the one place for Gemini
model ids is editable on AI levels."""
from core import ai_health as AH
from core import ai_levels_service as ALS
from web.tests_o2_owner_admin import OwnerBase


class GeminiHealthOwnerTests(OwnerBase):
    def test_402_red_line_on_levels_integrations_and_ai(self):
        self.ready()
        AH.mark_down("gemini", "gemini-3.6-flash", "billing", "http_402",
                     "Payment required AIzaSyFAKEFAKEFAKEFAKEFAKE1234")
        for url in ("/owner/ai-levels?lang=en", "/owner/integrations?lang=en", "/owner/ai?lang=en"):
            html = self.c.get(url).content.decode()
            self.assertIn('id="ai-health-alerts"', html, url)
            self.assertIn("Gemini: billing not enabled (HTTP 402) — enable billing in "
                          "Google AI Studio / Cloud", html, url)
            self.assertIn("বিলিং চালু নেই", html, url)
            self.assertNotIn("AIza", html, url)

    def test_404_line_names_the_retired_model(self):
        self.ready()
        AH.mark_down("gemini", "gemini-2.5-flash", "not_found", "http_404", "no longer available")
        html = self.c.get("/owner/ai-levels?lang=en").content.decode()
        self.assertIn("model gemini-2.5-flash retired", html)

    def test_no_line_when_nothing_failed(self):
        self.ready()
        self.assertNotIn('id="ai-health-alerts"', self.c.get("/owner/ai-levels").content.decode())

    def test_gemini_models_edit_in_one_place(self):
        self.ready()
        html = self.c.get("/owner/ai-levels").content.decode()
        self.assertIn('name="gemini_vision"', html)
        r = self.post("/owner/ai-levels", {"enabled": "on", "default": "normal",
                                           "free_normal": "on", "gemini_text": "gemini-3.6-flash",
                                           "gemini_voice": "gemini-3.1-flash-lite",
                                           "reason": "test"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        gm = ALS.cfg()[0]["gemini_models"]
        self.assertEqual((gm["text"], gm["vision"], gm["voice"]),
                         ("gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"))
        r = self.post("/owner/ai-levels", {"gemini_vision": "bad id!", "reason": "t"})
        self.assertEqual(r.status_code, 400)
