"""callmoney — AFTER CALL NOTE backend: words -> validated drafts, never writes."""
import json
from unittest import mock

from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import callnote_views as CN
from core.models import Loan, Note, Reminder, Transaction, User

V = "/api/v1"


def mk(phone, lang="en"):
    return User.objects.create_user(name="Rina", phone=phone, password="pw12345!", language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


GOOD = json.dumps({"items": [
    {"kind": "due", "title": "Rahim will pay", "amount": "500", "person": "Rahim",
     "direction": "they_owe", "due_date": "2026-11-05"},
    {"kind": "reminder", "title": "Call Rahim about the rent", "due_at": "2026-11-05T16:00"},
    {"kind": "note", "title": "Shop opens at 10"},
]})


class ParseItemsTests(SimpleTestCase):
    def test_good_items(self):
        items = CN.parse_items("Here you go:\n" + GOOD)
        self.assertEqual([i["kind"] for i in items], ["due", "reminder", "note"])
        self.assertEqual(items[0]["amount"], 500)
        self.assertEqual(items[0]["direction"], "they_owe")
        self.assertEqual(items[0]["due_date"], "2026-11-05")
        self.assertEqual(items[1]["due_at"], "2026-11-05T16:00")
        self.assertFalse(items[1]["date_only"])

    def test_garbage_and_invented_fields_are_dropped(self):
        self.assertEqual(CN.parse_items("sorry, I can't"), [])
        self.assertEqual(CN.parse_items("{not json"), [])
        bad = json.dumps({"items": [
            {"kind": "due", "amount": -5, "person": "X"},          # no real amount
            {"kind": "call_record", "title": "record it"},          # unknown kind
            {"kind": "reminder", "title": ""},                      # empty title
            {"kind": "due", "amount": 300, "direction": "steal"},   # bad direction
            {"kind": "reminder", "title": "x", "due_at": "tomorrowish"},
        ]})
        items = CN.parse_items(bad)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0]["amount"], 300)
        self.assertIsNone(items[0]["direction"])
        self.assertIsNone(items[1]["due_at"])

    def test_at_most_three(self):
        many = json.dumps({"items": [{"kind": "note", "title": f"n{i}"} for i in range(9)]})
        self.assertEqual(len(CN.parse_items(many)), 3)

    def test_prompt_never_mentions_recording(self):
        self.assertNotIn("record", CN.TASK.lower())


class UnderstandViewTests(TestCase):
    def setUp(self):
        self.u = mk("01711400001")
        self.c = cl(self.u)

    def _counts(self):
        return (Reminder.objects.count(), Note.objects.count(), Loan.objects.count(),
                Transaction.objects.count())

    def test_needs_login_and_text(self):
        self.assertIn(APIClient().post(f"{V}/callnote/understand", {"text": "x"},
                                       format="json").status_code, (401, 403))
        r = self.c.post(f"{V}/callnote/understand", {"text": "  "}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_ai_drafts_are_returned_and_nothing_is_written(self):
        before = self._counts()
        with mock.patch("core.ai.generate", return_value=(GOOD, 0.001)) as g:
            r = self.c.post(f"{V}/callnote/understand",
                            {"text": "Rahim kal 500 taka debe, 4tay call korbo"}, format="json")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d["ok"])
        self.assertEqual(len(d["items"]), 3)
        self.assertEqual(self._counts(), before)       # confirm-before-write: server never saves
        kw = g.call_args.kwargs
        self.assertEqual(kw["tier"], "cheap")           # shared router, user's credit rules
        self.assertIs(kw["user"], self.u)
        self.assertTrue(kw["pii"])

    def test_no_key_is_honest(self):
        from core import ai
        with mock.patch("core.ai.generate", side_effect=ai.AIUnavailable("no_key")):
            r = self.c.post(f"{V}/callnote/understand", {"text": "milk"}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["reason"], "no_key")
        with mock.patch("core.ai.generate", side_effect=ai.AIUnavailable("credits")):
            r = self.c.post(f"{V}/callnote/understand", {"text": "milk"}, format="json")
        self.assertEqual(r.status_code, 402)

    def test_unusable_answer_refunds(self):
        def fake(*a, **kw):
            kw["out_meta"]["charged"] = 1
            return ("I am not sure", 0.001)
        with mock.patch("core.ai.generate", side_effect=fake), \
                mock.patch("core.billing.credit") as credit:
            r = self.c.post(f"{V}/callnote/understand", {"text": "hmm"}, format="json")
        d = r.json()
        self.assertFalse(d["ok"])
        self.assertEqual(d["reason"], "unclear")
        self.assertEqual(d["refunded"], 1)
        credit.assert_called_once()
        self.assertEqual(credit.call_args.args[2], 1)
