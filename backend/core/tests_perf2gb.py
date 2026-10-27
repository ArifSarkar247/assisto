"""perf2gb: the bulk seed behind .github/workflows/perf2gb.yml."""
import json
import os
import tempfile
from io import StringIO

from django.core.management import call_command
from django.test import TestCase


class SeedPerfTests(TestCase):
    def _run(self):
        d = tempfile.mkdtemp()
        call_command("seed_reality", out=os.path.join(d, "r.json"), stdout=StringIO())
        f = os.path.join(d, "p.json")
        call_command("seed_perf", out=f, stdout=StringIO())
        return json.load(open(f))

    def test_volumes_and_idempotent(self):
        a = self._run()
        self.assertGreaterEqual(a["reminders"], 500)
        self.assertEqual(a["khata_parties"], 500)
        self.assertGreaterEqual(a["customers"], 500)
        self.assertEqual(a["sales_threads"], 150)
        self.assertEqual(a.get("crm_leads"), 500, a.get("crm_error"))
        self.assertGreater(a["flags_allow_listed"], 0)
        b = self._run()  # re-run replaces the tagged rows, never doubles them
        self.assertEqual(a["reminders"], b["reminders"])
        self.assertEqual(a["transactions"], b["transactions"])
        self.assertEqual(b["khata_parties"], 500)

    def test_inbox_lists_the_seeded_chats(self):
        self._run()
        from core.models import BusinessProfile, User
        from core.bizagent_guard import inbox
        from core.phone import find_user
        biz = BusinessProfile.objects.get(user=find_user("01700000001"))
        rows, counts = inbox(biz)
        self.assertEqual(counts["all"], 150)
        self.assertTrue(User.objects.exists())

    def test_refuses_a_real_database(self):
        from django.core.management.base import CommandError
        from core.management.commands import seed_perf as SP
        from django.test import override_settings
        with override_settings(DATABASES={"default": {
                "ENGINE": "django.db.backends.postgresql", "NAME": "assisto",
                "HOST": "127.0.0.1"}}):
            with self.assertRaises(CommandError):
                SP.assert_ci_db()
