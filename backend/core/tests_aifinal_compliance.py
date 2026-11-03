"""aifinal PART 6: AI-generated label, general information only, the
consult-a-professional line on legal / medical / financial topics, safe AI
mode for under-18 and child accounts. Fake providers only."""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase

from core import ai_compliance as AC
from core import views_chat as VC


def _u(phone="+8801911000001"):
    return get_user_model().objects.create_user(name="p", phone=phone, password="pw12345!")


class ComplianceTests(TestCase):
    def test_topics_bn_and_en(self):
        self.assertEqual(AC.topic_of("What dose of paracetamol for fever?"), "medical")
        self.assertEqual(AC.topic_of("জমির মামলা কিভাবে করব?"), "legal")
        self.assertEqual(AC.topic_of("Should I invest in the share market?"), "financial")
        self.assertEqual(AC.topic_of("What is the capital of France?"), "")

    def test_line_added_once(self):
        r, t = AC.add_professional_line("Rest and drink water.", "I have a fever", "en")
        self.assertIn("consult a doctor", r)
        r2, _ = AC.add_professional_line(r, "I have a fever", "en")
        self.assertEqual(r2.count("consult a doctor"), 1)
        r3, _ = AC.add_professional_line("উত্তর", "সঞ্চয়পত্রে বিনিয়োগ করব?", "bn")
        self.assertIn("আর্থিক পরামর্শদাতা", r3)

    def _chat(self, user, text):
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("Some general answer.", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            reply, meta, _ = VC._produce_reply(user, None, text, "en", [])
        return reply, meta, seen

    def test_chat_answer_is_labelled_and_general_only(self):
        reply, meta, seen = self._chat(_u(), "My landlord wants to evict me, what law applies?")
        self.assertTrue(meta["ai_generated"])
        self.assertEqual(meta["pro_topic"], "legal")
        self.assertIn("consult a lawyer", reply)
        self.assertIn("general information only", seen["task"])
        self.assertNotIn("safe_mode", meta)

    def test_safe_mode_for_child_accounts(self):
        with mock.patch("core.safe_plans.is_child_account", return_value=True):
            reply, meta, seen = self._chat(_u("+8801911000002"), "tell me a story")
        self.assertTrue(meta["safe_mode"])
        self.assertIn("SAFE MODE", seen["task"])

    def test_minor_check_fails_closed(self):
        with mock.patch("core.safe_plans.is_child_account", side_effect=RuntimeError("db")):
            self.assertTrue(AC.is_minor(_u("+8801911000003")))
        self.assertFalse(AC.is_minor(None))
