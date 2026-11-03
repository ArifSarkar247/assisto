"""ailang (owner 3 Nov 23:15, PART 1 a + c): the AI replies in the language of
the user's latest message, and never opens with "I don't have your data"."""
from unittest import mock

from django.test import TestCase

from core import ai_prompt as AP


class ReplyLangTest(TestCase):
    def test_bengali_script_is_bangla_even_in_english_app(self):
        self.assertEqual(AP.reply_lang("আজ আবহাওয়া কেমন?", "en"), "bn")

    def test_romanized_bangla_is_bangla(self):
        self.assertEqual(AP.reply_lang("ami kemon achi bolo to", "en"), "bn")
        self.assertEqual(AP.reply_lang("taka koto lagbe", "en"), "bn")

    def test_english_is_english_even_in_bangla_app(self):
        self.assertEqual(AP.reply_lang("What is the weather today?", "bn"), "en")
        self.assertEqual(AP.reply_lang("How do I add a reminder for my mother?", "bn"), "en")

    def test_no_words_falls_back_to_app_language(self):
        self.assertEqual(AP.reply_lang("123 ???", "bn"), "bn")
        self.assertEqual(AP.reply_lang("👍", "en"), "en")

    def test_system_prompt_has_language_and_direct_answer_rules(self):
        s = AP.system_prompt()
        self.assertIn("language of the user's latest message", s)
        self.assertIn("never open by saying you don't have", s)


class ChatUsesMessageLanguageTest(TestCase):
    def test_chat_task_follows_message_language(self):
        from core import views_chat as VC
        from core.i18n import pick
        bn_task = pick(AP.reply_lang("আমার আজকের কাজ কী?", "en"), *VC.CHAT_TASK)
        en_task = pick(AP.reply_lang("What are my tasks today?", "bn"), *VC.CHAT_TASK)
        self.assertIn("বাংলায়", bn_task)
        self.assertIn("Reply in English", en_task)


class VisionUsesMainKeysTest(TestCase):
    """PART 1a/b (23:20): vision uses the saved Anthropic/Gemini keys; users
    never see admin wording."""

    def _keys(self, enabled):
        def is_enabled(s):
            return s in enabled

        def get(s):
            return {"api_key": "test-not-a-real-key"} if s in enabled else {}
        return (mock.patch("core.integrations.is_enabled", side_effect=is_enabled),
                mock.patch("core.integrations.get", side_effect=get))

    def test_main_anthropic_and_gemini_keys_make_vision_ready_claude_first(self):
        from core import chat_vision_service as CVS
        p1, p2 = self._keys({"anthropic", "gemini"})
        with p1, p2:
            st = CVS.providers_state("en")
            self.assertTrue(st["ready"])
            self.assertEqual(st["active"], "vision_claude")
            self.assertEqual(CVS._fallbacks("vision_claude"), ["vision_gemini"])
            slug, conf, cost = CVS._active()
        self.assertEqual(conf["api_key"], "test-not-a-real-key")
        self.assertGreater(cost, 0)

    def test_gemini_only_is_ready(self):
        from core import chat_vision_service as CVS
        p1, p2 = self._keys({"gemini"})
        with p1, p2:
            self.assertEqual(CVS.providers_state("en")["active"], "vision_gemini")

    def test_never_falls_back_to_a_costlier_provider(self):
        from core import chat_vision_service as CVS
        p1, p2 = self._keys({"anthropic", "gemini", "openai"})
        with p1, p2:
            self.assertNotIn("vision_claude", CVS._fallbacks("vision_gemini"))

    def test_user_message_has_no_admin_wording(self):
        from core import chat_vision_service as CVS
        for lang in ("bn", "en"):
            m = CVS.funding_message("provider_missing", lang)
            for w in ("Integrations", "owner", "key", "মালিক", "key যোগ"):
                self.assertNotIn(w, m)
