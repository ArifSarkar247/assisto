"""agent-eval (gap-aichat2): the money-tool CONTRACT of the real chat prompt.

CI never calls a real model, and the e2e fake always emits the ACTION line —
so live 10338 could miss the confirm card without any CI signal. This eval
checks the contract the REAL model works under:
  * the instruction the product sends (chat_task_text with a user) carries
    the ACTION rule with the money example and the MUST;
  * for every unambiguous money-log phrasing (bn / en / Banglish / Bangla
    digits), the product turns a model answer WITHOUT the ACTION line into
    the same expense / income proposal (finish_reply = the live
    post-processing), and keeps the model's own line when it has one;
  * questions, reminders, loans and mixed messages never get one."""
from django.contrib.auth import get_user_model
from django.test import TestCase

from core import ai_tools as AT
from core import views_chat as VC
from core.tests_gap_aichat2 import NEGATIVE, POSITIVE

# what real models answer when they skip the tool line (recorded shapes)
_NO_LINE_REPLIES = (
    "ঠিক আছে, খরচটা লিখে রাখার জন্য নিচে নিশ্চিত করুন।",
    "Sure — please confirm below to save it.",
    "**হিসাব:** আপনার খরচটি নোট করা যায়। নিচের বোতামে হ্যাঁ চাপুন।",
)


class MoneyActionContractEval(TestCase):
    def test_prompt_carries_the_money_tool_rule(self):
        u = get_user_model().objects.create_user(name="e", phone="+8801311992001",
                                                  password="pw12345!")
        for lang in ("bn", "en"):
            t = VC.chat_task_text(lang, u)
            self.assertIn("ACTION:", t)
            self.assertIn("চায়ে ৫০ টাকা খরচ লিখে রাখো", t)
            self.assertIn("MUST end with ONE line", t)

    def test_every_money_log_gets_a_proposal_even_without_the_line(self):
        passed = 0
        for text, kind, amount in POSITIVE:
            for model in _NO_LINE_REPLIES:
                _r, prop, _c, _n = VC.finish_reply(model, text, "bn")
                ok = prop is not None and prop["type"] == kind \
                    and prop["amount"].split(".")[0] == amount
                self.assertTrue(ok, (text, model, prop))
                passed += ok
        self.assertEqual(passed, len(POSITIVE) * len(_NO_LINE_REPLIES))

    def test_model_line_is_kept_when_present(self):
        model = 'নিশ্চিত করুন।\nACTION: {"type": "expense", "amount": 75, "category": "নাস্তা"}'
        _r, prop, _c, _n = VC.finish_reply(model, "নাস্তায় ৭৫ টাকা খরচ লিখে রাখো", "bn")
        self.assertEqual(prop["amount"], "75.00")
        self.assertNotIn("safety_net", prop)
        self.assertNotIn("ACTION", _r)

    def test_no_proposal_for_non_logs(self):
        for text in NEGATIVE:
            _r, prop, _c, _n = VC.finish_reply("উত্তর।", text, "bn")
            self.assertIsNone(prop, text)
            self.assertIsNone(AT.money_safety_net(text), text)
