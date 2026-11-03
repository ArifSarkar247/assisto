"""aifinal PART 1 (owner 3 Nov 23:20 additions): photo follow-ups in the
same chat, no admin wording for users, never charged for a task the AI
could not do, never "I cannot see anything" when a photo exists."""
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from datetime import timedelta

from django.utils import timezone

from core import ai_chat_guard as G
from core import views_chat as VC
from core.logic import brain
from core.logic import chat_vision as CV
from core.models import PhotoStudioJob

ADMIN_WORDS = ("Integrations", "owner", "Owner", " key", "মালিক", "key ", "Claude",
               "Gemini", "OpenAI", "Anthropic", "provider")


_N = [100]


def _user(name, **kw):
    _N[0] += 1
    return get_user_model().objects.create_user(name=name, phone="+88018%08d" % _N[0],
                                                password="pw12345!", **kw)


class PhotoFollowUpTest(TestCase):
    def setUp(self):
        self.u = _user("pf1")
        self.job = PhotoStudioJob.objects.create(
            user=self.u, feature=CV.FEATURE, status="done", done_at=timezone.now(),
            options={"answer": "A red Toyota car parked by a shop."})

    def req(self, user, pk):
        return SimpleNamespace(user=user, data={"photo_job": pk}, query_params={})

    def test_own_finished_job_gives_its_text_answer(self):
        self.assertIn("red Toyota", VC._photo_context(self.req(self.u, self.job.pk)))

    def test_other_users_job_and_bad_ids_give_nothing(self):
        other = _user("pf2")
        self.assertEqual(VC._photo_context(self.req(other, self.job.pk)), "")
        self.assertEqual(VC._photo_context(self.req(self.u, "x")), "")
        self.assertEqual(VC._photo_context(self.req(self.u, 0)), "")
        PhotoStudioJob.objects.filter(pk=self.job.pk).update(
            done_at=timezone.now() - timedelta(hours=7))
        self.assertEqual(VC._photo_context(self.req(self.u, self.job.pk)), "")

    def test_follow_up_sends_photo_text_and_never_cannot_see_rule(self):
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("It is a red car.", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            reply, meta, _ = VC._produce_reply(self.u, None, "What colour is the car?", "en",
                                               [], photo="A red Toyota car parked by a shop.")
        self.assertEqual(meta["source"], "ai")
        self.assertIn("red Toyota", seen["data"])
        self.assertIn("never say you cannot see", seen["task"] + seen.get("extra_system", ""))

    def test_vision_prompt_forbids_cannot_see_opener(self):
        self.assertIn("never open with 'I cannot see anything'", CV.system_prompt("en"))


class NoAdminWordingTest(TestCase):
    def test_brain_needs_ai_line_is_friendly(self):
        for lang in ("bn", "en"):
            line = brain._l4_needs_ai(lang)
            for w in ADMIN_WORDS:
                self.assertNotIn(w, line, (lang, w))

    def test_needs_text_only_for_the_owner(self):
        st = {"ready": False, "needs": "Add a Gemini API key in Integrations.",
              "providers": [{"slug": "vision_gemini", "needs": "Gemini API key"}]}
        user = SimpleNamespace(is_superuser=False)
        out = G.friendly_needs(st, user, "en")
        self.assertEqual(out["providers"][0]["needs"], "")
        for w in ADMIN_WORDS:
            self.assertNotIn(w, out["needs"])
        self.assertIs(G.friendly_needs(st, SimpleNamespace(is_superuser=True), "en"), st)

    def test_photo_studio_provider_missing_is_friendly(self):
        from core import photo_studio_service as S
        for lang in ("bn", "en"):
            msg = S.funding_message("provider_missing", lang)
            for w in ADMIN_WORDS:
                self.assertNotIn(w, msg, (lang, w))


class NeverChargedForNothingTest(TestCase):
    def test_empty_answer_after_guard_is_refunded(self):
        u = _user("rf1")

        def fake(*a, **kw):
            kw["out_meta"]["charged"] = 3
            return ("You can buy it now — I have sent the payment.", 0.001)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake), \
                mock.patch("core.ai_guard.clean_assistant_answer", return_value=("", [])), \
                mock.patch("core.billing.credit") as credit:
            reply, meta, _ = VC._produce_reply(u, None, "Buy this", "en", [])
        credit.assert_called_once()
        self.assertEqual(credit.call_args.args[2], 3)
        self.assertEqual(meta["source"], "brain")
        self.assertEqual(meta["credits"], 0)
        self.assertTrue(reply.strip())
