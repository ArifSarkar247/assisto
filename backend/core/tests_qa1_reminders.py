"""qa1 — found by the reality audit (run 39849437970, flow 08_reminders):
a one-off reminder from the app's natural-language quick add / voice sends
`"recurrence_rule": null` (and the edit form `"link": null`). Both are
JSONField(default=dict) on the model, so DRF answered 400 "This field may not
be null." — the reminder never reached the server and the offline queue
retried it forever. The API now treats null as "none" ({}).
"""
from rest_framework.test import APITestCase

from .models import Reminder, User


class ReminderNullJsonTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            name="QA", phone="01700000077", password="secret123")
        self.client.force_authenticate(user=self.user)

    def test_null_recurrence_rule_and_link_are_accepted(self):
        r = self.client.post("/api/v1/reminders/", {
            "title": "Call Ammu", "notes": "", "due_at": "2026-10-23T03:00:00Z",
            "recurrence": "none", "recurrence_rule": None, "date_only": False,
            "done": False, "source": "nlp", "link": None,
        }, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        rem = Reminder.objects.get(user=self.user)
        self.assertEqual(rem.recurrence_rule, {})
        self.assertEqual(rem.link, {})

    def test_real_rule_still_saved(self):
        rule = {"freq": "weekly", "interval": 1, "weekdays": [5]}
        r = self.client.post("/api/v1/reminders/", {
            "title": "Jumma", "recurrence": "weekly", "recurrence_rule": rule,
        }, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Reminder.objects.get(user=self.user).recurrence_rule, rule)

    def test_update_with_null_rule(self):
        rem = Reminder.objects.create(user=self.user, title="x")
        r = self.client.patch(f"/api/v1/reminders/{rem.id}/",
                              {"recurrence_rule": None}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        rem.refresh_from_db()
        self.assertEqual(rem.recurrence_rule, {})
