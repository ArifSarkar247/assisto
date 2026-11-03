"""aifinal round 2 (owner 4 Nov 00:25): photo memory + one step + one
charge shown on its bubble, language everywhere, no charge when the AI did
not do the task. Fake providers only."""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from core import chat_vision_service as CVS
from core import views_chat as VC
from core.logic import chat_vision as CV
from core.models import ChatMessage, ChatSession, PhotoStudioJob


def _u(phone="+8801611000001"):
    return get_user_model().objects.create_user(name="r", phone=phone, password="pw12345!")


class PhotoMemoryTests(TestCase):
    def test_photo_turn_saved_to_chat_and_kept_in_context(self):
        u = _u()
        s = ChatSession.objects.create(user=u)
        job = PhotoStudioJob.objects.create(user=u, feature=CV.FEATURE, status="done",
                                            funding="credits", credits_charged=4,
                                            done_at=timezone.now())
        CVS._save_to_chat(u, str(s.id), job, "এটা কোন বাস?",
                          {"answer": "এটি গাজীপুরগামী বাস।", "label_text": "GAZIPUR 12"}, "bn")
        msgs = list(s.messages.order_by("id"))
        self.assertEqual([m.role for m in msgs], ["user", "assistant"])
        self.assertEqual(msgs[1].meta["credits"], 4)            # the bubble = the ledger row
        hist = VC._history_for(s)
        self.assertIn("গাজীপুরগামী", hist[-1]["content"])
        self.assertIn("GAZIPUR 12", hist[-1]["content"])        # the description, not bytes

    def test_other_users_session_is_ignored(self):
        u, other = _u(), _u("+8801611000002")
        s = ChatSession.objects.create(user=other)
        job = PhotoStudioJob.objects.create(user=u, feature=CV.FEATURE, status="done")
        CVS._save_to_chat(u, str(s.id), job, "q", {"answer": "a"}, "en")
        self.assertFalse(ChatMessage.objects.filter(session=s).exists())


class NoChargeWhenTaskFailedTests(TestCase):
    def test_detector(self):
        for t in ("Sorry, the screenshot never reached me.", "I can't see the image you sent.",
                  "I'm unable to view the attachment.", "দুঃখিত, ছবিটি পৌঁছায়নি।"):
            self.assertTrue(VC._failed_task(t), t)
        self.assertFalse(VC._failed_task("Gazipur is 35 km from Dhaka."))

    def test_task_not_done_is_refunded_and_shown(self):
        u = _u("+8801611000003")

        def fake(*a, **kw):
            kw["out_meta"]["charged"] = 2
            return ("The screenshot never reached me — please send it again.", 0.001)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake), \
                mock.patch("core.billing.credit") as credit:
            reply, meta, _ = VC._produce_reply(u, None, "what does the screenshot say?", "en", [])
        credit.assert_called_once()
        self.assertEqual(meta["credits"], 0)
        self.assertEqual(meta["refunded"], 2)
        self.assertTrue(reply)
