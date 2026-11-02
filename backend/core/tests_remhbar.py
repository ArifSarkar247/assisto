"""remhbar (2 Nov) — Reminders & Notes launch bar, server side.

* Note sync conflict: an offline edit carries `base_updated_at`; when the
  note changed on the server after that, nothing is written (409 + the
  server copy) so the app keeps both versions. Old apps (no base) = last
  write wins, unchanged.
* Repeating family tasks: daily / weekly / monthly rule in Dhaka wall time;
  the member's reminder then fires at every occurrence (push_due_reminders).
* Recurrence engine: every-N in step with the anchor, never before it
  (pure tests live in core/logic/reminders_tests_snippets.py)."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from django.test import TestCase
from django.utils import timezone

from core import famcare as FC
from core.management.commands import push_due_reminders as PDR
from core.models import Note, Reminder
from core.tests_famcare import V, Base, cl, mk

DHAKA = ZoneInfo("Asia/Dhaka")


class NoteConflictTests(TestCase):
    def setUp(self):
        self.u = mk("01711300001", "Rina")
        self.c = cl(self.u)
        r = self.c.post(f"{V}/notes/", {"title": "Bazar", "body": "rice"},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.note = r.json()

    def _bump(self, seconds=30):
        # the other phone's edit, later on the server clock
        Note.objects.filter(pk=self.note["id"]).update(
            body="rice, dal (phone B)",
            updated_at=timezone.now() + timedelta(seconds=seconds))

    def test_newer_server_edit_is_not_overwritten(self):
        self._bump()
        r = self.c.patch(f"{V}/notes/{self.note['id']}/",
                         {"body": "rice, oil (phone A, offline)",
                          "base_updated_at": self.note["updated_at"]},
                         format="json")
        self.assertEqual(r.status_code, 409, r.content)
        j = r.json()
        self.assertTrue(j["conflict"])
        self.assertEqual(j["reason"], "conflict")
        self.assertEqual(j["server"]["body"], "rice, dal (phone B)")
        self.assertIn("both", j["detail"])
        self.assertEqual(Note.objects.get(pk=self.note["id"]).body,
                         "rice, dal (phone B)")

    def test_conflict_message_in_bangla(self):
        self._bump()
        r = cl(self.u, "bn").patch(
            f"{V}/notes/{self.note['id']}/",
            {"body": "x", "base_updated_at": self.note["updated_at"]},
            format="json")
        self.assertEqual(r.status_code, 409)
        self.assertIn("দুটো কপিই", r.json()["detail"])

    def test_same_base_saves(self):
        r = self.c.patch(f"{V}/notes/{self.note['id']}/",
                         {"body": "rice, oil",
                          "base_updated_at": self.note["updated_at"]},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Note.objects.get(pk=self.note["id"]).body, "rice, oil")
        # the stored field list is unchanged (base is not a column)
        self.assertNotIn("base_updated_at", r.json())

    def test_old_app_without_base_last_write_wins(self):
        self._bump()
        r = self.c.patch(f"{V}/notes/{self.note['id']}/", {"body": "old app"},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Note.objects.get(pk=self.note["id"]).body, "old app")

    def test_garbage_base_is_ignored_not_500(self):
        r = self.c.patch(f"{V}/notes/{self.note['id']}/",
                         {"body": "ok", "base_updated_at": "not-a-date"},
                         format="json")
        self.assertEqual(r.status_code, 200)

    def test_someone_elses_note_still_404(self):
        other = cl(mk("01711300002", "Other"))
        r = other.patch(f"{V}/notes/{self.note['id']}/",
                        {"body": "x", "base_updated_at": "2020-01-01T00:00:00Z"},
                        format="json")
        self.assertEqual(r.status_code, 404)


class RepeatingFamilyTaskTests(Base):
    def test_rule_in_dhaka_wall_time(self):
        due = datetime(2026, 11, 2, 21, 0, tzinfo=DHAKA)  # Monday 9 pm
        self.assertEqual(FC.family_repeat_rule("daily", due),
                         ("daily", {"freq": "daily", "interval": 1,
                                    "time": "21:00"}))
        rec, rule = FC.family_repeat_rule("weekly", due)
        self.assertEqual((rec, rule["weekday"], rule["time"]), ("weekly", 0, "21:00"))
        rec, rule = FC.family_repeat_rule("monthly", due)
        self.assertEqual((rec, rule["day_of_month"]), ("monthly", 2))
        # unknown / no time -> one-off
        self.assertEqual(FC.family_repeat_rule("hourly", due), ("none", {}))
        self.assertEqual(FC.family_repeat_rule("daily", None), ("none", {}))

    def test_assign_daily_task_rings_every_day(self):
        mid = self.link(self.ab)
        due = timezone.now() + timedelta(hours=2)
        r = self.ca.post(f"{V}/family/reminders",
                         {"member_id": mid, "title": "Pills",
                          "due_at": due.isoformat(), "repeat": "daily"},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["task"]["repeat"], "daily")
        rem = Reminder.objects.get(user=self.b)
        self.assertEqual(rem.recurrence, "daily")
        self.assertEqual(rem.recurrence_rule["freq"], "daily")
        # the server push fires on day 3 too (fixed clock: due + 2 days)
        fire_day3 = due + timedelta(days=2)
        hits = PDR.due_reminders(fire_day3 + timedelta(minutes=1))
        self.assertEqual([x.id for x, _ in hits], [rem.id])

    def test_repeat_without_time_is_one_off(self):
        mid = self.link(self.ab)
        r = self.ca.post(f"{V}/family/reminders",
                         {"member_id": mid, "title": "Call", "repeat": "daily"},
                         format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.json()["task"]["repeat"], "none")
        self.assertEqual(Reminder.objects.get(user=self.b).recurrence, "none")
