"""ai-router: Owner Admin → AI page (bn/en, provider table, settings save
validated + audited, circuit reset, 80% banner on every page)."""
from django.core.cache import cache
from django.utils import timezone

from core import ai_router as R
from core.models import AIProviderState, AIUsage, OwnerAudit
from web.tests_o2_owner_admin import OwnerBase


class AIPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()

    def test_requires_login(self):
        self.assertEqual(self.c.get("/owner/ai").status_code, 302)

    def test_page_bn_en(self):
        self.ready()
        r = self.c.get("/owner/ai?lang=en")
        self.assertContains(r, "Which model does which job")
        self.assertContains(r, "claude-opus-5-5")
        self.assertContains(r, "claude-haiku-5-5")
        self.assertContains(r, "Daily spend caps")
        r = self.c.get("/owner/ai?lang=bn")
        self.assertContains(r, "কোন কাজে কোন মডেল")

    def test_save_caps_and_model_audited(self):
        self.ready()
        r = self.post("/owner/ai", {"action": "save", "cap_anthropic": "4.5",
                                    "m_anthropic_medium": "claude-sonnet-5-5",
                                    "eff_strong": "high", "server_fallback": "on",
                                    "main_features": "chat, agent_qa"})
        self.assertEqual(r.status_code, 302)
        conf = R.cfg()
        self.assertEqual(conf["caps_usd"]["anthropic"], 4.5)
        self.assertEqual(conf["caps_usd"]["openai"], 3.0)          # untouched
        self.assertEqual(conf["models"]["anthropic_medium"], "claude-sonnet-5-5")
        self.assertEqual(conf["effort"]["strong"], "high")
        self.assertEqual(conf["main_features"], ["chat", "agent_qa"])
        self.assertTrue(OwnerAudit.objects.filter(action="ai.router", ok=True).exists())

    def test_bad_values_refused(self):
        self.ready()
        r = self.post("/owner/ai", {"action": "save", "cap_openai": "-1",
                                    "m_anthropic_strong": "claude-3-opus"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(R.cfg()["caps_usd"]["openai"], 3.0)
        self.assertTrue(OwnerAudit.objects.filter(action="ai.router", ok=False).exists())

    def test_circuit_reset(self):
        self.ready()
        AIProviderState.objects.create(slug="gemini", state="open", opened_at=timezone.now(),
                                       consecutive_failures=5)
        r = self.post("/owner/ai", {"action": "reset", "slug": "gemini"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(AIProviderState.objects.get(slug="gemini").state, "closed")
        self.assertEqual(self.post("/owner/ai", {"action": "reset", "slug": "x"}).status_code, 404)

    def test_banner_on_every_page_after_alert(self):
        self.ready()
        AIUsage.objects.create(feature="x", model="gemini-2.5-flash", provider="gemini",
                               cost_usd=2.7)
        R.check_alerts()
        r = self.c.get("/owner/pricing")
        self.assertContains(r, 'id="ai-spend-alert"')
        self.assertContains(r, "gemini 90%")
