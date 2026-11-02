"""pssec: Personal Secretary (PS) Today brief — pure logic + /ps/today API +
the Agent Core morning-brief hook. Flag ps_secretary (OFF by default)."""
from datetime import datetime, timedelta, timezone as dtz

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import ps_service as S
from core.logic import ps_brief as PB
from core.models import FeatureFlag, PaCollectionItem, Reminder, User

V = "/api/v1"
DHAKA = dtz(timedelta(hours=6))
NOW = datetime(2026, 11, 3, 9, 0)          # local naive (Dhaka) — Tuesday


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def slot(i, h, m=0, title="Meeting", dur=60, **kw):
    d = {"id": i, "title": title, "start": NOW.replace(hour=h, minute=m).isoformat(),
         "duration_min": dur}
    d.update(kw)
    return d


def fu(i, due_local, status="waiting", who="Karim", title="Quote"):
    due_utc = due_local.replace(tzinfo=DHAKA).astimezone(dtz.utc)
    return {"id": i, "title": title, "counterpart": who, "status": status,
            "due_at": due_utc.isoformat().replace("+00:00", "Z")}


class PureBriefTests(SimpleTestCase):
    def test_empty_is_honest(self):
        b = PB.build([], [], [], NOW, tz=DHAKA)
        self.assertTrue(b["empty"])
        self.assertEqual(b["sections"], [])
        self.assertIsNone(b["next"])
        self.assertFalse(b["ai_used"])

    def test_meetings_today_only_ordered_with_people_and_source(self):
        slots = [slot(2, 16, title="Board", people=["Rahim", "Karim"], circle_ids=[7, "x"]),
                 slot(1, 11, title="Bank"),
                 {"id": 3, "title": "Tomorrow", "start": (NOW + timedelta(days=1)).isoformat()},
                 slot(4, 12, title="Cancelled", status="cancelled")]
        b = PB.build(slots, [], [], NOW, tz=DHAKA)
        sec = b["sections"][0]
        self.assertEqual(sec["key"], "meetings")
        self.assertEqual([l["src"]["id"] for l in sec["lines"]], [1, 2])
        board = sec["lines"][1]
        self.assertIn("বিকেল ৪:০০", board["bn"])
        self.assertIn("4:00 pm", board["en"])
        self.assertIn("Rahim, Karim", board["bn"])
        self.assertEqual(board["circle_ids"], [7])     # junk ids dropped
        b2 = PB.build([slot(9, 10, circle_people=[{"id": "3", "name": "Rahim"}, {"id": "z"}, "bad"])],
                      [], [], NOW, tz=DHAKA)
        self.assertEqual(b2["sections"][0]["lines"][0]["circle"], [{"id": 3, "name": "Rahim"}])
        self.assertEqual(b["counts"]["meetings"], 2)

    def test_clash_minutes_are_real(self):
        b = PB.build([slot(1, 10, dur=60), slot(2, 10, 30, dur=60)], [], [], NOW, tz=DHAKA)
        lines = b["sections"][0]["lines"]
        self.assertTrue(all(l["clash"] for l in lines))
        self.assertIn("৩০ মিনিট", lines[0]["bn"])
        self.assertIn("30 min", lines[1]["en"])

    def test_next_up_countdown_and_in_progress(self):
        b = PB.build([slot(1, 10, 30)], [], [], NOW, tz=DHAKA)
        self.assertIn("১ ঘণ্টা ৩০ মিনিট", b["next"]["bn"])
        self.assertEqual(b["next"]["src"], {"kind": "schedule", "id": 1})
        b = PB.build([slot(1, 8, 30)], [], [], NOW, tz=DHAKA)
        self.assertTrue(b["next"]["en"].startswith("Now:"))

    def test_followups_overdue_today_soon_and_far(self):
        fus = [fu(1, NOW - timedelta(days=2)),                    # overdue 2 days
               fu(2, NOW.replace(hour=18), who="Lawyer"),         # today later
               fu(3, NOW.replace(hour=8)),                        # today, already past
               fu(4, NOW + timedelta(days=1), status="replied"),  # tomorrow, your move
               fu(5, NOW + timedelta(days=9)),                    # too far
               fu(6, NOW - timedelta(days=1), status="done")]     # closed
        b = PB.build([], fus, [], NOW, tz=DHAKA)
        lines = b["sections"][0]["lines"]
        self.assertEqual([l["src"]["id"] for l in lines], [1, 3, 2, 4])
        self.assertEqual([l["state"] for l in lines], ["overdue", "overdue", "today", "soon"])
        self.assertIn("২ দিন পেরিয়েছে", lines[0]["bn"])
        self.assertIn("আজকের সময় পেরিয়েছে", lines[1]["bn"])
        self.assertIn("কাল", lines[3]["bn"])
        self.assertIn("your move", lines[3]["en"])
        self.assertEqual(b["counts"]["overdue"], 2)

    def test_followup_day_uses_user_timezone_not_utc(self):
        # due 01:00 Dhaka on 4 Nov == 19:00 UTC on 3 Nov: must read "tomorrow".
        f = fu(1, datetime(2026, 11, 4, 1, 0))
        b = PB.build([], [f], [], NOW, tz=DHAKA)
        self.assertEqual(b["sections"][0]["lines"][0]["state"], "soon")

    def test_reminders_today_only(self):
        rems = [{"id": 1, "title": "Pills", "due_at": NOW.replace(hour=21)},
                {"id": 2, "title": "Old", "due_at": NOW - timedelta(days=1)}]
        b = PB.build([], [], rems, NOW, tz=DHAKA)
        self.assertEqual([l["src"]["id"] for l in b["sections"][0]["lines"]], [1])
        self.assertIn("রাত ৯:০০", b["sections"][0]["lines"][0]["bn"])

    def test_proactive_lines(self):
        out = PB.proactive_lines([slot(1, 11, title="Bank")], [fu(1, NOW - timedelta(days=1))],
                                 NOW, DHAKA)
        self.assertEqual(len(out), 2)
        self.assertIn("১টি মিটিং", out[0]["bn"])
        self.assertIn("Karim", out[1]["en"])


class TodayApiTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="PS One", phone="01710000901", password="pw12345!")
        self.other = User.objects.create_user(name="PS Two", phone="01710000902", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _local_today(self, h):
        return timezone.localtime().replace(hour=h, minute=0, second=0, microsecond=0)

    def test_flag_off_refuses(self):
        flag(False)
        r = self.c.get(V + "/ps/today")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["error"], "feature_off")

    def test_today_reads_only_own_rows(self):
        flag(True)
        start = self._local_today(23).replace(tzinfo=None).isoformat()
        PaCollectionItem.objects.create(user=self.u, collection="schedule",
                                        data={"title": "Mine", "start": start,
                                              "people": ["Rahim"], "circle_ids": [5]})
        PaCollectionItem.objects.create(user=self.other, collection="schedule",
                                        data={"title": "NotMine", "start": start})
        due = (timezone.now() - timedelta(days=1)).isoformat()
        PaCollectionItem.objects.create(user=self.u, collection="followups",
                                        data={"title": "Quote", "counterpart": "Karim",
                                              "status": "waiting", "due_at": due})
        Reminder.objects.create(user=self.u, title="Pills", due_at=self._local_today(23))
        r = self.c.get(V + "/ps/today")
        self.assertEqual(r.status_code, 200, r.content)
        b = r.json()
        keys = [s["key"] for s in b["sections"]]
        self.assertEqual(keys[:3], ["meetings", "followups", "reminders"])
        text = str(b)
        self.assertIn("Mine", text)
        self.assertNotIn("NotMine", text)
        self.assertEqual(b["sections"][0]["lines"][0]["circle_ids"], [5])
        self.assertEqual(b["counts"]["overdue"], 1)
        self.assertFalse(b["ai_used"])

    def test_empty_day(self):
        flag(True)
        b = self.c.get(V + "/ps/today").json()
        self.assertTrue(b["empty"])

    def test_morning_brief_ps_section_only_when_flag_on(self):
        from core.agentcore import proactive as PR
        start = self._local_today(23).replace(tzinfo=None).isoformat()
        PaCollectionItem.objects.create(user=self.u, collection="schedule",
                                        data={"title": "Bank", "start": start})
        flag(False)
        b = PR.build_brief(self.u, "brief_morning", timezone.now())
        self.assertNotIn("ps", [s["key"] for s in b["sections"]])
        flag(True)
        b = PR.build_brief(self.u, "brief_morning", timezone.now())
        ps = [s for s in b["sections"] if s["key"] == "ps"]
        self.assertEqual(len(ps), 1)
        self.assertIn("Bank", ps[0]["lines"][0]["en"])
        b = PR.build_brief(self.u, "brief_evening", timezone.now())
        self.assertNotIn("ps", [s["key"] for s in b["sections"]])


class PaItemPatchMergeTests(TestCase):
    """pssec bug fix: PATCH on a PA collection row must not wipe its fields."""
    def setUp(self):
        self.u = User.objects.create_user(name="PS Three", phone="01710000903", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_patch_status_keeps_title_and_counterpart(self):
        r = self.c.post(V + "/pa/followups/", {"title": "Quote", "counterpart": "Karim",
                                               "status": "waiting"}, format="json")
        rid = r.json()["id"]
        r = self.c.patch(V + "/pa/followups/%d/" % rid, {"status": "done"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        row = self.c.get(V + "/pa/followups/%d/" % rid).json()
        self.assertEqual(row["title"], "Quote")
        self.assertEqual(row["counterpart"], "Karim")
        self.assertEqual(row["status"], "done")

    def test_put_still_replaces(self):
        r = self.c.post(V + "/pa_schedule/", {"title": "A", "note": "x"}, format="json")
        rid = r.json()["id"]
        self.c.put(V + "/pa_schedule/%d/" % rid, {"title": "B"}, format="json")
        row = self.c.get(V + "/pa_schedule/%d/" % rid).json()
        self.assertEqual(row, {"id": rid, "title": "B"})
