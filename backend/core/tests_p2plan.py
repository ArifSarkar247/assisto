"""p2plan (owner PART 2, 3 Nov): Task manager (subtasks, recurring, Bangla
quick-add, My Circle shared lists with assign/done pushes), Cost & time
estimator templates (owner rates with source + date, never invented prices),
AI daily planner (template plan + optional AI advice, flag ai_daily_planner)."""
from datetime import date, datetime, timedelta
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.logic import day_planner as DP
from core.logic import estimate_templates as ET
from core.logic import pricing
from core.logic import task_manager as TM
from core.models import CircleMember, FeatureFlag, PaCollectionItem, User, WorldAdminValue

V = "/api/v1"
NOW = datetime(2026, 11, 3, 9, 0)   # Tuesday, local naive


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!", language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def pair(a, b):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, phone=b.phone,
                                     relation="friend", state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming")
    return ab


def flag(key, on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "data": dict(data or {})})
        return True

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]


# ================================================================ pure logic

class TaskLogicTests(SimpleTestCase):
    def test_normalize_keeps_new_fields_safely(self):
        t = TM.normalize_task({"title": "x", "parent_id": "7", "repeat": "weekly",
                               "est_min": 9999, "assignee_uid": "bad"})
        self.assertEqual((t["parent_id"], t["repeat"], t["est_min"], t["assignee_uid"]),
                         (7, "weekly", TM.MAX_EST_MIN, None))
        t = TM.normalize_task({"title": "x", "repeat": "yearly", "parent_id": 0})
        self.assertEqual((t["repeat"], t["parent_id"], t["est_min"]), ("", None, 0))

    def test_validate_repeat(self):
        self.assertIn("bad_repeat", TM.validate_task({"title": "x", "repeat": "hourly"}))
        self.assertIn("repeat_needs_due", TM.validate_task({"title": "x", "repeat": "daily"}))
        self.assertEqual(TM.validate_task({"title": "x", "repeat": "daily", "due": "2026-11-03T09:00"}), [])

    def test_next_due_daily_weekly_monthly_clamped(self):
        self.assertEqual(TM.next_due("2026-11-03T09:00", "daily"), "2026-11-04T09:00")
        self.assertEqual(TM.next_due("2026-11-03T09:00", "weekly"), "2026-11-10T09:00")
        self.assertEqual(TM.next_due("2026-01-31T08:30", "monthly"), "2026-02-28T08:30")
        self.assertEqual(TM.next_due("2026-12-15T08:00", "monthly"), "2027-01-15T08:00")
        self.assertEqual(TM.next_due("2026-11-03T09:00", ""), "")
        self.assertEqual(TM.next_due("", "daily"), "")

    def test_spawn_next_rolls_past_now_and_skips_subtasks(self):
        late = {"title": "Bazar", "repeat": "daily", "due": "2026-10-30T08:00", "status": "done", "id": 4}
        nxt = TM.spawn_next(late, NOW)
        self.assertEqual(nxt["due"], "2026-11-04T08:00")   # rolled past now, not overdue
        self.assertEqual((nxt["status"], nxt["progress"]), ("todo", 0))
        self.assertNotIn("id", nxt)
        self.assertIsNone(TM.spawn_next({"title": "x", "due": "2026-11-03T08:00"}, NOW))
        self.assertIsNone(TM.spawn_next({"title": "x", "repeat": "daily", "due": "2026-11-03T08:00",
                                         "parent_id": 3}, NOW))

    def test_subtask_rollup(self):
        tasks = [{"id": 1, "title": "Paint"}, {"id": 2, "title": "a", "parent_id": 1, "status": "done"},
                 {"id": 3, "title": "b", "parent_id": 1}, {"id": 4, "title": "c", "parent_id": 1}]
        r = TM.subtask_rollup(tasks)
        self.assertEqual(r[1], {"total": 3, "done": 1, "percent": 33})
        self.assertEqual([t["id"] for t in TM.top_level(tasks)], [1])
        self.assertEqual(len(TM.subtasks_of(tasks, 1)), 3)

    def test_voice_priority_words(self):
        self.assertEqual(TM.voice_priority("কাল বিল দিতে হবে, জরুরি"), ("urgent", "কাল বিল দিতে হবে"))
        self.assertEqual(TM.voice_priority("খুব জরুরি ওষুধ কেনা")[0], "urgent")
        self.assertEqual(TM.voice_priority("Call bank important")[0], "high")
        self.assertEqual(TM.voice_priority("বাজার করা"), ("normal", "বাজার করা"))


class PlannerLogicTests(SimpleTestCase):
    def test_empty_day_is_honest(self):
        p = DP.build(NOW)
        self.assertTrue(p["empty"])
        self.assertEqual(p["blocks"], [])
        self.assertEqual(p["window"], {"start": "08:00", "end": "22:00"})

    def test_fixed_items_then_tasks_in_priority_order(self):
        meetings = [{"id": 1, "title": "Bank", "start": "2026-11-03T10:00", "duration_min": 60},
                    {"id": 2, "title": "Tomorrow", "start": "2026-11-04T10:00"}]
        rems = [{"id": 5, "title": "Medicine", "due_at": datetime(2026, 11, 3, 9, 30)}]
        tasks = [{"id": 10, "title": "Low later", "priority": "low", "due": "2026-11-20"},
                 {"id": 11, "title": "Normal today", "due": "2026-11-03T18:00", "est_min": 45},
                 {"id": 12, "title": "Urgent", "priority": "urgent", "est_min": 15},
                 {"id": 13, "title": "Overdue", "due": "2026-11-01T09:00"},
                 {"id": 14, "title": "Done", "status": "done", "due": "2026-11-03T10:00"}]
        p = DP.build(NOW, meetings=meetings, reminders=rems, tasks=tasks)
        got = [(b["start"], b["kind"], b["title"]) for b in p["blocks"]]
        self.assertEqual(got, [("09:00", "task", "Overdue"), ("09:30", "reminder", "Medicine"),
                               ("09:45", "task", "Urgent"), ("10:00", "meeting", "Bank"),
                               ("11:00", "task", "Normal today")])
        self.assertTrue(p["blocks"][0]["overdue"])
        self.assertEqual(p["counts"]["tasks_planned"], 3)
        self.assertNotIn("Low later", [b["title"] for b in p["blocks"]])

    def test_prayer_blocks_are_protected_and_optional(self):
        times = {"fajr": "05:00", "dhuhr": "12:00", "asr": "15:30", "maghrib": "17:20", "isha": "18:40"}
        tasks = [{"id": 1, "title": "Long", "priority": "urgent", "est_min": 180}]
        p = DP.build(NOW.replace(hour=11), prefs={"prayer": True}, tasks=tasks, prayer_times=times)
        kinds = [(b["start"], b["kind"]) for b in p["blocks"]]
        self.assertIn(("12:00", "prayer"), kinds)
        task = next(b for b in p["blocks"] if b["kind"] == "task")
        self.assertEqual(task["start"], "12:20")      # not over Dhuhr
        dh = next(b for b in p["blocks"] if b.get("src", {}).get("id") == "dhuhr")
        self.assertEqual(dh["title_bn"], "যোহর")
        off = DP.build(NOW.replace(hour=11), prefs={"prayer": False}, tasks=tasks, prayer_times=times)
        self.assertFalse([b for b in off["blocks"] if b["kind"] == "prayer"])

    def test_unscheduled_when_day_is_full_and_tips_bangla_digits(self):
        tasks = [{"id": i, "title": "Task " + chr(65 + i), "priority": "urgent", "est_min": 120}
                 for i in range(10)]
        p = DP.build(NOW.replace(hour=18), prefs={"day_start": "08:00", "day_end": "22:00"}, tasks=tasks)
        self.assertEqual(p["counts"]["tasks_planned"], 2)
        self.assertEqual(len(p["unscheduled"]), 8)
        bn = " ".join(t["bn"] for t in p["tips"])
        self.assertIn("৮টি কাজ আজ আঁটছে না", bn)
        self.assertFalse(any(ch.isdigit() and ch in "0123456789" for ch in bn))

    def test_meeting_clash_flagged_and_bad_prefs_fall_back(self):
        m = [{"id": 1, "title": "A", "start": "2026-11-03T10:00", "duration_min": 60},
             {"id": 2, "title": "B", "start": "2026-11-03T10:30", "duration_min": 30}]
        p = DP.build(NOW, prefs={"day_start": "23:00", "day_end": "07:00"}, meetings=m)
        self.assertEqual(p["window"], {"start": "08:00", "end": "22:00"})
        self.assertTrue(all(b["clash"] for b in p["blocks"]))

    def test_ai_data_has_no_ids(self):
        p = DP.build(NOW, tasks=[{"id": 987654, "title": "Pay rent", "priority": "urgent"}])
        self.assertIn("Pay rent", DP.ai_data(p))
        self.assertNotIn("987654", DP.ai_data(p))


class EstimateLogicTests(SimpleTestCase):
    def test_five_bd_templates(self):
        self.assertEqual(set(ET.ids()), {"home", "event", "travel", "business", "tutor"})
        for t in ET.catalog("bn"):
            self.assertTrue(t["questions"])

    def test_no_invented_prices(self):
        r = ET.compute("home", {"paint_sqft": 1200, "tile_sqft": 0, "points": 6})
        self.assertTrue(r["estimate"])
        self.assertTrue(all(l["unit_cost"] is None and l["rate_src"]["kind"] == "none" for l in r["lines"]))
        ids = [l["id"] for l in r["lines"]]
        self.assertEqual(ids, ["paint", "putty", "wiring", "cleanup"])   # 0 sq ft tiles dropped
        self.assertEqual(r["lines"][0]["qty"], 1200)
        self.assertEqual(r["missing_rates"], 4)

    def test_owner_rate_needs_source_and_date(self):
        k = ET.rate_key("home", "paint", "c")
        r = ET.compute("home", {"paint_sqft": 100}, {k: {"value": 30, "source": "", "date": "2023-02-23"}})
        self.assertIsNone(r["lines"][0]["unit_cost"])
        r = ET.compute("home", {"paint_sqft": 100},
                       {k: {"value": 30, "source": "PWD SoR 2022 rev. Feb 2023", "date": "2023-02-23"}})
        self.assertEqual(r["lines"][0]["unit_cost"], 30.0)
        self.assertEqual(r["lines"][0]["rate_src"]["kind"], "owner")

    def test_quantities_derive_from_answers(self):
        r = ET.compute("travel", {"people": 3, "nights": 2, "rooms": 2}, lang="en")
        q = {l["id"]: l["qty"] for l in r["lines"]}
        self.assertEqual(q, {"tickets": 6, "hotel": 4, "food": 9, "local": 3, "entry": 3})
        r = ET.compute("business", {"advance": 0, "runway": 0, "staff": 0})
        self.assertEqual({l["id"] for l in r["lines"]}, {"licence", "fitout", "sign", "stock"})
        self.assertEqual(ET.clean_inputs("event", {"guests": "-5", "cards": "abc", "hours": "4"}),
                         {"guests": 0, "cards": 0, "hours": 4})

    def test_rate_keys_fit_the_store(self):
        keys = [k[0] for k in ET.rate_keys()]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(all(len(k) <= 40 for k in keys))

    def test_polish_price_keeps_margin(self):
        d = pricing.DEFAULTS()
        row = d["action_costs"]["day_plan_polish"]
        self.assertGreaterEqual(row["credits"], pricing.recompute_from_provider_cost("day_plan_polish", d))
        self.assertGreaterEqual(row["credits"], pricing.action_credit_floor("day_plan_polish", d))
        self.assertEqual(pricing.validate_edit(d), [])


# ================================================================ API

class Base(TestCase):
    def setUp(self):
        cache.clear()
        flag("task_manager")
        flag("cost_estimator")
        self.a = mk("01711300001", "Rina")
        self.b = mk("01711300002", "Karim", lang="bn")
        self.x = mk("01711300003", "Stranger")
        self.ab = pair(self.a, self.b)
        self.ca, self.cb, self.cx = cl(self.a), cl(self.b, "bn"), cl(self.x)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)
        self.proj = PaCollectionItem.objects.create(user=self.a, collection="tasks_projects",
                                                    data={"name": "Paint the flat"})

    def share(self):
        r = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/share", {"circle_ids": [self.ab.id]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()


class ParseApiTests(Base):
    def test_bangla_voice_phrase(self):
        r = self.cb.post(f"{V}/tasks/parse", {"text": "প্রতি শুক্রবার সকালে বাজার করা জরুরি"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertEqual(d["priority"], "urgent")
        self.assertEqual(d["repeat"], "weekly")
        self.assertTrue(d["due"])
        self.assertIn("বাজার", d["title"])
        self.assertNotIn("জরুরি", d["title"])

    def test_empty_refused(self):
        self.assertEqual(self.ca.post(f"{V}/tasks/parse", {"text": " "}, format="json").status_code, 400)


class SharedListApiTests(Base):
    def test_share_only_with_accepted_circle(self):
        pending = CircleMember.objects.create(user=self.a, peer_user=self.x, name="X", state="pending")
        r = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/share",
                         {"circle_ids": [self.ab.id, pending.id]}, format="json")
        d = r.json()
        self.assertEqual([p["uid"] for p in d["people"]], [self.a.id, self.b.id])
        self.assertEqual(d["skipped"][0]["reason"], "not_in_circle")
        self.assertEqual(len(self.spy.to(self.b)), 1)
        self.assertEqual(self.spy.to(self.b)[0]["data"]["route"], "tasks")
        # idempotent
        self.share()
        self.assertEqual(PaCollectionItem.objects.filter(user=self.b, collection="tasks_sharedin").count(), 1)

    def test_stranger_and_member_limits(self):
        self.assertEqual(self.cx.get(f"{V}/tasks/lists/{self.proj.id}").status_code, 404)
        self.share()
        self.assertEqual(self.cb.post(f"{V}/tasks/lists/{self.proj.id}/share",
                                      {"circle_ids": [1]}, format="json").status_code, 403)
        lists = self.cb.get(f"{V}/tasks/shared").json()["lists"]
        self.assertEqual([l["id"] for l in lists], [self.proj.id])
        self.assertEqual(lists[0]["role"], "member")

    def test_assign_and_done_notify(self):
        self.share()
        self.spy.calls.clear()
        r = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/tasks",
                         {"title": "Buy paint", "assignee_uid": self.b.id}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        tid = r.json()["id"]
        self.assertEqual(len(self.spy.to(self.b)), 1)           # assigned -> Karim
        self.assertIn("gave you a task", self.spy.to(self.b)[0]["ten"])
        r = self.cb.patch(f"{V}/tasks/lists/{self.proj.id}/tasks/{tid}", {"status": "done"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["progress"], 100)
        self.assertEqual(r.json()["done_by"], self.b.id)
        owner_pushes = self.spy.to(self.a)
        self.assertEqual(len(owner_pushes), 1)
        self.assertIn("finished a task", owner_pushes[0]["ten"])
        # stored in the OWNER's collection (one source of truth)
        self.assertTrue(PaCollectionItem.objects.filter(pk=tid, user=self.a).exists())

    def test_assignee_must_be_on_list(self):
        self.share()
        r = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/tasks",
                         {"title": "x", "assignee_uid": self.x.id}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_recurring_done_spawns_next(self):
        self.share()
        r = self.cb.post(f"{V}/tasks/lists/{self.proj.id}/tasks",
                         {"title": "Bazar", "repeat": "weekly", "due": "2030-01-04T09:00"}, format="json")
        tid = r.json()["id"]
        r = self.ca.patch(f"{V}/tasks/lists/{self.proj.id}/tasks/{tid}", {"status": "done"}, format="json")
        self.assertEqual(r.json()["spawned"]["due"], "2030-01-11T09:00")
        self.assertEqual(r.json()["spawned"]["status"], "todo")

    def test_member_delete_rules_and_leave(self):
        self.share()
        t = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/tasks", {"title": "Owner's"}, format="json").json()
        sub = self.ca.post(f"{V}/tasks/lists/{self.proj.id}/tasks",
                           {"title": "step", "parent_id": t["id"]}, format="json").json()
        self.assertEqual(self.cb.delete(f"{V}/tasks/lists/{self.proj.id}/tasks/{t['id']}").status_code, 403)
        self.assertEqual(self.ca.delete(f"{V}/tasks/lists/{self.proj.id}/tasks/{t['id']}").status_code, 204)
        self.assertFalse(PaCollectionItem.objects.filter(pk=sub["id"]).exists())   # subtask went too
        # member cannot remove the owner; can leave
        self.assertEqual(self.cb.post(f"{V}/tasks/lists/{self.proj.id}/unshare",
                                      {"uid": self.a.id}, format="json").status_code, 403)
        self.assertEqual(self.cb.post(f"{V}/tasks/lists/{self.proj.id}/unshare", {}, format="json").status_code, 200)
        self.assertEqual(self.cb.get(f"{V}/tasks/lists/{self.proj.id}").status_code, 404)
        self.assertEqual(self.cb.get(f"{V}/tasks/shared").json()["lists"], [])


class EstimateApiTests(Base):
    def test_templates_and_compute_with_owner_rate(self):
        r = self.ca.get(f"{V}/estimate/templates")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["templates"]), 5)
        WorldAdminValue.objects.create(key=ET.rate_key("home", "paint", "c"), value=28,
                                       note="PWD Schedule of Rates 2022 (rev. Feb 2023)",
                                       effective_date=date(2023, 2, 23))
        r = self.ca.post(f"{V}/estimate/templates/home", {"inputs": {"paint_sqft": 500}}, format="json")
        line = r.json()["lines"][0]
        self.assertEqual((line["id"], line["unit_cost"], line["rate_src"]["kind"]), ("paint", 28.0, "owner"))
        self.assertIn("PWD", line["rate_src"]["source"])
        self.assertEqual(self.ca.post(f"{V}/estimate/templates/nope", {}, format="json").status_code, 404)

    def test_set_rate_refuses_without_source(self):
        from core import views_p2plan as P
        with self.assertRaises(ValueError):
            P.set_estimate_rate(self.a, ET.rate_key("home", "paint", "c"), 30, "", date(2023, 1, 1))
        with self.assertRaises(ValueError):
            P.set_estimate_rate(self.a, "est:fake:x:c", 30, "src", date(2023, 1, 1))
        P.set_estimate_rate(self.a, ET.rate_key("home", "paint", "c"), 30, "PWD", date(2023, 1, 1))
        P.set_estimate_rate(self.a, ET.rate_key("home", "paint", "c"), None, "", None)
        self.assertIsNone(WorldAdminValue.objects.get(key=ET.rate_key("home", "paint", "c")).value)


class PlannerApiTests(Base):
    def test_flag_off_by_default(self):
        r = self.ca.get(f"{V}/planner/today")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["error"], "feature_off")

    def test_plan_reads_own_and_assigned_tasks_and_prefs(self):
        flag("ai_daily_planner")
        self.share()
        self.ca.post(f"{V}/tasks/lists/{self.proj.id}/tasks",
                     {"title": "Karim's urgent", "priority": "urgent", "assignee_uid": self.b.id}, format="json")
        PaCollectionItem.objects.create(user=self.b, collection="tasks_items",
                                        data={"title": "Own urgent", "priority": "urgent"})
        r = self.cb.post(f"{V}/planner/prefs", {"day_start": "00:00", "day_end": "23:55", "prayer": True},
                         format="json")
        self.assertEqual(r.json()["prayer"], True)
        d = self.cb.get(f"{V}/planner/today").json()
        titles = [b["title"] for b in d["blocks"] if b["kind"] == "task"] + \
                 [u["title"] for u in d["unscheduled"]]
        self.assertIn("Own urgent", titles)
        self.assertIn("Karim's urgent", titles)
        self.assertTrue(d["prefs"]["prayer"])
        self.assertEqual(d["polish_credits"], 2)
        # the owner's plan does not carry the task assigned to Karim
        mine = self.ca.get(f"{V}/planner/today").json()
        mine_titles = [b["title"] for b in mine["blocks"]] + [u["title"] for u in mine["unscheduled"]]
        self.assertNotIn("Karim's urgent", mine_titles)

    def test_polish_without_key_is_honest(self):
        from core import ai
        flag("ai_daily_planner")
        PaCollectionItem.objects.create(user=self.a, collection="tasks_items",
                                        data={"title": "Pay rent", "priority": "urgent"})
        with mock.patch("core.ai.generate", side_effect=ai.AIUnavailable("no_key")):
            r = self.ca.post(f"{V}/planner/today/polish", {}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["reason"], "no_key")
        with mock.patch("core.ai.generate", return_value=("- Start with rent\n- Rest at 1 pm", 0.001)):
            r = self.ca.post(f"{V}/planner/today/polish", {}, format="json")
        self.assertEqual(r.json()["advice"], ["Start with rent", "Rest at 1 pm"])

    def test_polish_refuses_empty_day(self):
        flag("ai_daily_planner")
        self.assertEqual(self.cx.post(f"{V}/planner/today/polish", {}, format="json").status_code, 400)


class OwnerRatesPageTests(TestCase):
    def test_route_registered(self):
        from django.urls import resolve
        self.assertEqual(resolve("/owner/estimate-rates").func.__name__, "estimate_rates")
