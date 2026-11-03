"""aifinal PART 7 (owner 3 Nov 23:25): Photo Studio edit-by-instruction uses
the saved main Gemini / OpenAI keys (the real cause of "no place to type"),
quick chips exist, face lock stays on every generative template."""
from unittest import mock

from django.test import TestCase

from core import photo_studio_service as S


def _ints(enabled, keys):
    return (mock.patch("core.integrations.is_enabled", side_effect=lambda s: s in enabled),
            mock.patch("core.integrations.get", side_effect=lambda s: {"api_key": keys.get(s, "")}))


class PhotoMainKeyTests(TestCase):
    def test_gemini_main_key_makes_prompt_edits_ready(self):
        a, b = _ints({"gemini"}, {"gemini": "g-key"})
        with a, b:
            st = S.providers_state("en")
            slug, conf, cost = S._active_provider()
        self.assertTrue(st["ready"])
        self.assertEqual(slug, "photo_gemini")
        self.assertEqual(conf["api_key"], "g-key")
        self.assertGreater(cost, 0)

    def test_openai_only_if_its_key_exists(self):
        a, b = _ints({"openai"}, {"openai": "o-key"})
        with a, b:
            self.assertEqual(S._active_provider()[0], "photo_openai")
        a, b = _ints(set(), {})
        with a, b:
            self.assertFalse(S.providers_state("en")["ready"])

    def test_own_photo_entry_wins(self):
        a, b = _ints({"photo_gemini", "gemini"}, {"photo_gemini": "own", "gemini": "main"})
        with a, b:
            self.assertEqual(S._active_provider()[1]["api_key"], "own")


class QuickChipTests(TestCase):
    def test_owner_chips_are_templates(self):
        ids = {t["id"] for t in S.templates("en")}
        for i in ("bg_remove_white", "white_bg", "passport_bd", "visa_bd", "form_photo_bd",
                  "bright_clean", "product_shop", "facebook_product"):
            self.assertIn(i, ids)
        bn = {t["id"]: t["label"] for t in S.templates("bn")}
        self.assertEqual(bn["white_bg"], "সাদা ব্যাকগ্রাউন্ড")

    def test_template_prompts_pass_the_safety_check_with_face_lock(self):
        from core.logic import photo_studio as PS
        for t in S.templates("en"):
            if t["feature"] == "prompt_edit":
                v = PS.classify(t["prompt"], [], feature="prompt_edit")
                self.assertTrue(v["allowed"], (t["id"], v["reason"]))

    def test_sexual_and_face_swap_edits_refused(self):
        from core.logic import photo_studio as PS
        self.assertFalse(PS.classify("make her nude", [], feature="prompt_edit")["allowed"])
