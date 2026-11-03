"""Owner AI chat rebuild (4 Nov 01:02 + 01:05): one path (no regex parser),
actions only as model proposals confirmed by the user, profile in context,
one-tap clean-up. Fake providers only."""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from core import ai_tools as AT
from core import views_chat as VC
from core.models import Reminder, Transaction


def _u(phone="+8801411000001", name="Arif Hossain"):
    return get_user_model().objects.create_user(name=name, phone=phone, password="pw12345!")


class ProposalTests(TestCase):
    def test_extract_strips_the_line_and_validates(self):
        r, p = AT.extract('ঠিক আছে।\nACTION: {"type": "reminder", "title": "গ্যাসের ট্যাবলেট", '
                          '"due": "2026-11-05T09:00"}')
        self.assertEqual(r, "ঠিক আছে।")
        self.assertEqual(p["type"], "reminder")
        self.assertIsNone(AT.extract('x\nACTION: {"type": "transfer_money", "amount": 5}')[1])
        self.assertIsNone(AT.extract('x\nACTION: {"type": "expense", "amount": -9}')[1])

    def test_nothing_is_written_until_yes(self):
        u = _u()
        card = AT.propose(u, {"type": "reminder", "title": "gas tablet",
                              "due": "2026-11-05T09:00:00+06:00"}, "en")
        self.assertEqual(card["type"], "confirm_action")
        self.assertFalse(Reminder.objects.filter(user=u).exists())
        code, body = AT.confirm(u, card["pending_id"], True)
        self.assertEqual(code, 200)
        r = Reminder.objects.get(user=u)
        self.assertEqual((r.title, r.source), ("gas tablet", "ai"))
        self.assertEqual(AT.confirm(u, card["pending_id"], True)[0], 404)     # once only

    def test_no_writes_nothing(self):
        u = _u("+8801411000002")
        card = AT.propose(u, {"type": "expense", "amount": "9.00", "category": ""}, "en")
        AT.confirm(u, card["pending_id"], False)
        self.assertFalse(Transaction.objects.filter(user=u).exists())

    def test_profile_name_change_and_profile_line(self):
        u = _u("+8801411000003", name="")
        card = AT.propose(u, {"type": "profile_name", "name": "Arif"}, "bn")
        AT.confirm(u, card["pending_id"], True)
        u.refresh_from_db()
        self.assertEqual(u.name, "Arif")
        line = AT.profile_line(u)
        self.assertIn("first name: Arif", line)
        self.assertNotIn(u.phone, line)


class OnePathTests(TestCase):
    def test_gas_tablet_reminder_never_becomes_an_expense(self):
        u = _u("+8801411000010")
        c = APIClient()
        c.force_authenticate(u)
        fake = ('ঠিক আছে, কাল সকাল ৯টায় মনে করিয়ে দেব।\nACTION: {"type": "reminder", '
                '"title": "গ্যাসের ট্যাবলেট খাওয়া", "due": "2026-11-05T09:00"}')
        with mock.patch("core.ai.available", return_value=True), \
                mock.patch("core.ai.generate", return_value=(fake, 0.0)), \
                mock.patch("core.billing.charge",
                           return_value={"ok": True, "charged": 4, "balance": 10}):
            r = c.post("/api/v1/agent", {"text": "কাল সকাল ৯টায় গ্যাসের ট্যাবলেট খাওয়ার কথা মনে করিয়ে দিও"},
                       format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        b = r.json()
        self.assertNotIn("Logged", b["reply"])
        self.assertNotIn("ACTION", b["reply"])
        self.assertFalse(Transaction.objects.filter(user=u).exists())
        self.assertFalse(Reminder.objects.filter(user=u).exists())   # not before Yes
        self.assertEqual([x["type"] for x in b["cards"]], ["confirm_action"])

    def test_statement_goes_to_the_model(self):
        u = _u("+8801411000011")
        c = APIClient()
        c.force_authenticate(u)
        seen = {}

        def gen(*a, **kw):
            seen.update(kw)
            return ("আপনার সাথে পরিচিত হয়ে ভালো লাগল, আরিফ!", 0.0)
        with mock.patch("core.ai.available", return_value=True), \
                mock.patch("core.ai.generate", side_effect=gen), \
                mock.patch("core.billing.charge",
                           return_value={"ok": True, "charged": 4, "balance": 10}):
            r = c.post("/api/v1/agent", {"text": "amar nam Arif"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(seen)                                   # the model answered
        self.assertIn("first name: Arif", seen["data"])         # profile every turn
        self.assertNotIn("owner", r.json()["reply"])


class CleanUpTests(TestCase):
    def test_lists_and_deletes_only_ai_entries(self):
        from core.models import Account
        u = _u("+8801411000020")
        acc = Account.objects.create(user=u, name="cash", acc_type="cash")
        from django.utils import timezone
        Transaction.objects.create(user=u, account=acc, kind="expense", amount=9,
                                   date=timezone.localdate(), source="ai")
        Transaction.objects.create(user=u, account=acc, kind="expense", amount=500,
                                   date=timezone.localdate(), source="manual")
        self.assertEqual(len(AT.agent_entries(u)), 1)
        c = APIClient()
        c.force_authenticate(u)
        r = c.post("/api/v1/agent/ai-entries", {"items": "all"}, format="json")
        self.assertEqual(r.json()["deleted"], 1)
        self.assertEqual(Transaction.objects.filter(user=u).count(), 1)
