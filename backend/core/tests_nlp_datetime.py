"""Django wiring for the pure-python Bangla date/time parser self-tests
(core/logic/reminders_tests_snippets.py incl. the shared Python<->Dart golden
fixtures, and voice_commands_tests_snippets.py), plus end-to-end checks that the
chat expense path stores past-tense dates in the past."""
import importlib
from datetime import timedelta
from decimal import Decimal

from django.utils import timezone
from rest_framework.test import APITestCase
from django.test import SimpleTestCase

from core.models import User, Transaction


def _make(module_path, class_name):
    mod = importlib.import_module(module_path)
    fns = {n: getattr(mod, n) for n in dir(mod)
           if n.startswith("test_") and callable(getattr(mod, n))}

    def _wrap(fn):
        def method(self):
            fn()
        return method
    return type(class_name, (SimpleTestCase,),
                {f"test_{n}": _wrap(f) for n, f in fns.items()})


RemindersParserSnippetTests = _make("core.logic.reminders_tests_snippets",
                                    "RemindersParserSnippetTests")
VoiceCommandsSnippetTests = _make("core.logic.voice_commands_tests_snippets",
                                  "VoiceCommandsSnippetTests")


class AgentExpenseDateTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            name="পরীক্ষা", phone="01700000077", password="secret123")
        self.client.force_authenticate(user=self.user)

    def _post(self, text):
        return self.client.post("/api/v1/agent", {"text": text}, format="json")

    def test_past_tense_kal_expense_is_yesterday(self):
        r = self._post("কাল ৫০০ টাকা খরচ করেছি")
        self.assertEqual(r.status_code, 200)
        t = Transaction.objects.get(user=self.user)
        self.assertEqual(t.amount, Decimal("500"))
        self.assertEqual(t.date, timezone.localdate() - timedelta(days=1))

    def test_gotokal_expense_is_yesterday(self):
        self._post("গতকাল ২০০ টাকা খরচ রিকশা")
        t = Transaction.objects.get(user=self.user)
        self.assertEqual(t.date, timezone.localdate() - timedelta(days=1))

    def test_plain_expense_is_today(self):
        self._post("৫০০ টাকা খরচ খাবার")
        t = Transaction.objects.get(user=self.user)
        self.assertEqual(t.date, timezone.localdate())

    def test_sokal_reminder_is_not_tomorrow(self):
        # regression: "সকাল" contains "কাল" but must not push the reminder a day
        from core import agent
        p = agent._time("সকাল ১১টা")
        k = agent._time("কাল সকাল ১১টা")
        self.assertIsNotNone(p)
        self.assertEqual((k - p).days, 1)
