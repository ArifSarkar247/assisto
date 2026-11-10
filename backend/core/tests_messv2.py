"""messv2 — Mess and bachelor V2 (owner order 10 Nov 01:20, Part 2 A–L).

The owner's E2E scenario on test accounts: create a mess with a name, add 3
members from My Circle, the group appears, meals + bazar + Wi-Fi 700 entered
from DIFFERENT accounts, month close math checked to the poisha. Plus: circle-
only adds, roles, cut-off, multi-day off, closed months immutable, edit
history, idempotent offline re-sends, receipt photo (signed media), group card,
group sync, V1 import (rows kept), reports, turn reminders, Premium limits.
"""
import base64
import datetime as dt
import io
import shutil
import tempfile
from unittest import mock

from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import views_mess as VM
from core.logic import mess_v2 as M
from core.models import (CircleGroup, CircleGroupMember, CircleMember, Mess,
                         MessEditLog, MessEntry, MessMember, MessMonth,
                         PaCollectionItem, User)

V = "/api/v1"
TZ = timezone.get_default_timezone()


def _user(name, phone):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def _edge(a, b):
    return CircleMember.objects.create(user=a, peer_user=b, name=b.name, phone=b.phone,
                                       state="accepted", relation="friend")


def _at(y, m, d, h=10, mi=0):
    return timezone.make_aware(dt.datetime(y, m, d, h, mi), TZ)


class _Clock:
    """Patch the mess clock (Dhaka) for one test."""

    def __init__(self, tc):
        self.tc = tc
        self.now = _at(2026, 11, 1)
        p1 = mock.patch.object(VM, "_today", side_effect=lambda: self.now.date())
        p2 = mock.patch.object(VM, "_now_local", side_effect=lambda: self.now)
        p3 = mock.patch.object(VM, "_premium", side_effect=lambda u: False)
        p4 = mock.patch.object(VM, "_push")
        self.push = p4.start()
        for p in (p1, p2, p3):
            p.start()
        for p in (p1, p2, p3, p4):
            tc.addCleanup(p.stop)

    def set(self, *a):
        self.now = _at(*a)


class _Base(TestCase):
    def setUp(self):
        self.media = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.media, True)
        ov = override_settings(MEDIA_ROOT=self.media, FCM_SERVICE_ACCOUNT_FILE="")
        ov.enable()
        self.addCleanup(ov.disable)
        self.clock = _Clock(self)
        self.a = _user("Amin", "01740000301")
        self.b = _user("Babu", "01740000302")
        self.c = _user("Chaya", "01740000303")
        self.d = _user("Dipu", "01740000304")
        self.x = _user("Stranger", "01740000309")
        self.eb, self.ec, self.ed = _edge(self.a, self.b), _edge(self.a, self.c), _edge(self.a, self.d)
        self.cl = {}
        for k in "abcdx":
            c = APIClient()
            c.force_authenticate(getattr(self, k))
            self.cl[k] = c

    def post(self, who, path, body=None, code=None):
        r = self.cl[who].post(V + path, body or {}, format="json")
        if code is not None:
            self.assertEqual(r.status_code, code, r.content)
        return r

    def get(self, who, path, code=200):
        r = self.cl[who].get(V + path)
        self.assertEqual(r.status_code, code, r.content)
        return r.json()

    def make_mess(self, **kw):
        body = {"name": "Rampura Mess", "address": "Rampura, Dhaka", **kw}
        return self.post("a", "/mess/v2", body, 201).json()

    def add(self, mid, edge, code=201):
        return self.post("a", f"/mess/v2/{mid}/members", {"circle_member_id": edge.id}, code)

    def member_id(self, mid, user):
        return MessMember.objects.get(mess_id=mid, user=user).id


class CreateAndMembersTests(_Base):
    def test_name_required_and_full_title_kept(self):
        r = self.post("a", "/mess/v2", {"name": "   "}, 400)
        self.assertEqual(r.json()["code"], "name_required")
        m = self.make_mess(month_start_day=5)
        self.assertEqual(m["name"], "Rampura Mess")
        self.assertEqual(m["month_start_day"], 5)
        self.assertTrue(m["is_admin"] and m["i_am_manager"] and m["can_manage"])
        self.assertIsNone(m["group_id"])              # no group before members

    def test_free_runs_one_mess_premium_several(self):
        self.make_mess()
        r = self.post("a", "/mess/v2", {"name": "Second"}, 402)
        self.assertEqual(r.json()["code"], "premium_needed")
        with mock.patch.object(VM, "_premium", return_value=True):
            self.post("a", "/mess/v2", {"name": "Second"}, 201)

    def test_create_is_idempotent_by_client_id(self):
        a = self.post("a", "/mess/v2", {"name": "M", "client_id": "c-1"}, 201).json()
        b = self.post("a", "/mess/v2", {"name": "M", "client_id": "c-1"}, 200).json()
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(Mess.objects.count(), 1)

    def test_only_my_circle_people_and_group_auto_created(self):
        m = self.make_mess()
        # a stranger's edge id (not mine) is refused
        other = _edge(self.x, self.b)
        r = self.add(m["id"], other, 403)
        self.assertEqual(r.json()["code"], "not_in_circle")
        # a pending edge is refused too
        pend = CircleMember.objects.create(user=self.a, peer_user=self.x, name="X",
                                           phone=self.x.phone, state="pending")
        self.add(m["id"], pend, 403)
        r = self.add(m["id"], self.eb).json()
        gid = r["group_id"]
        g = CircleGroup.objects.get(pk=gid)
        self.assertEqual(g.name, "Rampura Mess")
        roster = {(x.member_id, x.role) for x in CircleGroupMember.objects.filter(
            group=g, status="active")}
        self.assertEqual(roster, {(self.a.id, "admin"), (self.b.id, "member")})
        self.assertEqual(Mess.objects.get(pk=m["id"]).group_id, gid)
        # B now sees the group in the normal My Circle groups list
        groups = self.get("b", "/circle/groups")["results"]
        self.assertIn(gid, [x["id"] for x in groups])
        # re-adding is harmless
        self.assertTrue(self.add(m["id"], self.eb, 200).json()["already"])
        # circle-pick marks who is already in
        pick = self.get("a", f"/mess/v2/{m['id']}/circle-pick")["results"]
        flags = {p["user_id"]: p["in_mess"] for p in pick}
        self.assertTrue(flags[self.b.id])
        self.assertFalse(flags[self.c.id])

    def test_only_admin_adds_and_member_sees_403(self):
        m = self.make_mess()
        self.add(m["id"], self.eb)
        eb2 = _edge(self.b, self.c)
        r = self.post("b", f"/mess/v2/{m['id']}/members", {"circle_member_id": eb2.id}, 403)
        self.assertEqual(r.json()["code"], "not_admin")
        self.get("x", f"/mess/v2/{m['id']}", 404)      # strangers see nothing

    def test_remove_member_syncs_group_and_last_admin_protected(self):
        m = self.make_mess()
        self.add(m["id"], self.eb)
        g = CircleGroup.objects.get(pk=Mess.objects.get(pk=m["id"]).group_id)
        bid = self.member_id(m["id"], self.b)
        self.post("a", f"/mess/v2/{m['id']}/members/{bid}", {"action": "remove"}, 200)
        self.assertEqual(CircleGroupMember.objects.get(group=g, member=self.b).status, "removed")
        aid = self.member_id(m["id"], self.a)
        r = self.post("a", f"/mess/v2/{m['id']}/members/{aid}", {"action": "remove_admin"}, 409)
        self.assertEqual(r.json()["code"], "last_admin")
        # re-add brings B back into the group
        self.add(m["id"], self.eb)
        self.assertEqual(CircleGroupMember.objects.get(group=g, member=self.b).status, "active")

    def test_roles_admin_and_rotating_manager(self):
        m = self.make_mess()
        self.add(m["id"], self.eb)
        self.add(m["id"], self.ec)
        bid, cid = self.member_id(m["id"], self.b), self.member_id(m["id"], self.c)
        self.post("a", f"/mess/v2/{m['id']}/members/{bid}", {"action": "make_manager"}, 200)
        self.assertEqual(list(MessMember.objects.filter(mess_id=m["id"], is_manager=True)
                              .values_list("id", flat=True)), [bid])
        self.post("a", f"/mess/v2/{m['id']}/members/{cid}", {"action": "make_manager"}, 200)
        self.assertEqual(list(MessMember.objects.filter(mess_id=m["id"], is_manager=True)
                              .values_list("id", flat=True)), [cid])
        self.post("a", f"/mess/v2/{m['id']}/members/{bid}", {"action": "make_admin"}, 200)
        g = Mess.objects.get(pk=m["id"]).group
        self.assertEqual(CircleGroupMember.objects.get(group=g, member=self.b).role, "admin")

    def test_rename_updates_group_name_admin_only(self):
        m = self.make_mess()
        self.add(m["id"], self.eb)
        self.post("b", f"/mess/v2/{m['id']}/edit", {"name": "X"}, 403)
        self.post("a", f"/mess/v2/{m['id']}/edit",
                  {"name": "Rampura Bachelor Mess", "breakfast_milli": 1000}, 200)
        mess = Mess.objects.get(pk=m["id"])
        self.assertEqual(mess.group.name, "Rampura Bachelor Mess")
        self.assertEqual(mess.breakfast_milli, 1000)
        self.assertTrue(MessEditLog.objects.filter(mess=mess, action="mess.edit").exists())


class MealsTests(_Base):
    def setUp(self):
        super().setUp()
        self.m = self.make_mess()
        self.add(self.m["id"], self.eb)
        self.mid = self.m["id"]

    def test_own_meals_until_cutoff_then_manager_corrects(self):
        # 1 Nov 10:00 -> B may change 2 Nov (cut-off 1 Nov 22:00)
        self.post("b", f"/mess/v2/{self.mid}/meals", {"date": "2026-11-02", "b": 0}, 200)
        self.clock.set(2026, 11, 1, 22, 30)
        r = self.post("b", f"/mess/v2/{self.mid}/meals", {"date": "2026-11-02", "b": 1}, 409)
        self.assertEqual(r.json()["code"], "cutoff")
        # B can't touch someone else's meals
        aid = self.member_id(self.mid, self.a)
        self.post("b", f"/mess/v2/{self.mid}/meals",
                  {"date": "2026-11-05", "member_id": aid, "l": 0}, 403)
        # the manager (A) corrects B's day after the cut-off -> history row
        bid = self.member_id(self.mid, self.b)
        self.post("a", f"/mess/v2/{self.mid}/meals",
                  {"date": "2026-11-02", "member_id": bid, "b": 1, "gl": 1}, 200)
        row = MessEntry.objects.get(kind="meal", member_id=bid, date=dt.date(2026, 11, 2))
        self.assertEqual(row.data["gl"], 1)
        log = MessEditLog.objects.filter(action="meal.set", entry_id=row.id).first()
        self.assertEqual(log.actor_id, self.a.id)
        self.assertEqual(log.before["b"], 0)

    def test_multi_day_off_and_back_on(self):
        r = self.post("b", f"/mess/v2/{self.mid}/meals/off",
                      {"from": "2026-11-10", "to": "2026-11-19"}, 200).json()
        self.assertEqual(r["days"], 10)
        self.assertEqual(MessEntry.objects.filter(kind="meal", data__l=0).count(), 10)
        self.post("b", f"/mess/v2/{self.mid}/meals/off",
                  {"from": "2026-11-15", "to": "2026-11-19", "on": True}, 200)
        self.assertEqual(MessEntry.objects.filter(kind="meal", data__l=0).count(), 5)
        self.post("b", f"/mess/v2/{self.mid}/meals/off",
                  {"from": "2026-11-01", "to": "2027-03-01"}, 400)

    def test_detail_shows_my_days_default_on(self):
        j = self.get("b", f"/mess/v2/{self.mid}")
        day = next(d for d in j["my_days"] if d["date"] == "2026-11-03")
        self.assertEqual((day["b"], day["l"], day["d"], day["set"]), (1, 1, 1, False))
        self.assertTrue(day["can_edit"])
        today = next(d for d in j["my_days"] if d["date"] == "2026-11-01")
        self.assertFalse(today["can_edit"])                 # past the cut-off


class E2EOwnerScenarioTests(_Base):
    """Owner E2E: name -> 3 members from My Circle -> group -> meals, bazar
    and Wi-Fi 700 from different accounts -> month close math to the poisha."""

    def test_full_month(self):
        m = self.make_mess()
        mid = m["id"]
        for e in (self.eb, self.ec, self.ed):
            self.add(mid, e)
        g = Mess.objects.get(pk=mid).group
        self.assertEqual(CircleGroupMember.objects.filter(group=g, status="active").count(), 4)
        # pinned card: today 4 x 2.5 meals, nobody has set tomorrow yet
        card = self.get("c", f"/mess/v2/by-group/{g.id}")["card"]
        self.assertEqual(card["meals_today"], "10")
        self.assertEqual(len(card["not_set_tomorrow"]), 4)
        ids = {k: self.member_id(mid, getattr(self, k)) for k in "abcd"}
        # seats: A has the big room (2 shares) for rent
        self.post("a", f"/mess/v2/{mid}/members/{ids['a']}", {"action": "seat_share", "value": 2}, 200)
        # meals from each own phone
        self.post("b", f"/mess/v2/{mid}/meals", {"date": "2026-11-05", "b": 0}, 200)
        self.post("d", f"/mess/v2/{mid}/meals/off", {"from": "2026-11-10", "to": "2026-11-19"}, 200)
        self.post("c", f"/mess/v2/{mid}/meals", {"date": "2026-11-02"}, 200)   # confirms tomorrow
        card = self.get("a", f"/mess/v2/by-group/{g.id}")["card"]
        self.assertEqual(len(card["not_set_tomorrow"]), 3)
        # bazar from different accounts (+ receipt photo from B)
        buf = io.BytesIO()
        from PIL import Image
        Image.new("RGB", (8, 8), (200, 10, 10)).save(buf, "PNG")
        png = base64.b64encode(buf.getvalue()).decode()
        r = self.post("b", f"/mess/v2/{mid}/entries",
                      {"kind": "bazar", "date": "2026-11-01", "amount": 500000,
                       "data": {"items": "rice, oil"}, "photo_b64": png,
                       "client_id": "b-bz-1"}, 201).json()
        self.assertTrue(r["entry"]["photo_url"].startswith("/api/v1/m/"))
        # offline re-send of the same entry is not counted twice
        self.post("b", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-01", "amount": 500000,
                   "client_id": "b-bz-1"}, 200)
        self.post("c", f"/mess/v2/{mid}/entries", {"kind": "bazar", "date": "2026-11-08",
                                                   "amount": 323500}, 201)
        self.post("a", f"/mess/v2/{mid}/entries", {"kind": "bazar", "date": "2026-11-15",
                                                   "amount": 200000}, 201)
        # service charges: members can't, manager can; Wi-Fi 700 equal, rent by seat
        self.post("b", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "amount": 70000, "data": {"kind": "wifi"}}, 403)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-03", "amount": 70000,
                   "data": {"kind": "wifi"}}, 201)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-03", "amount": 1200000,
                   "data": {"kind": "rent", "split": "seat"}}, 201)
        # deposits (A's is the optional month-start advance)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "deposit", "date": "2026-11-01", "amount": 300000,
                   "data": {"advance": True}}, 201)
        for k, amt in (("b", 300000), ("c", 300000), ("d", 200000)):
            self.post(k, f"/mess/v2/{mid}/entries",
                      {"kind": "deposit", "date": "2026-11-02", "amount": amt}, 201)
        # nobody can close before the last day
        self.clock.set(2026, 11, 20)
        self.post("a", f"/mess/v2/{mid}/close", {}, 409)
        self.clock.set(2026, 11, 30, 23)
        self.post("b", f"/mess/v2/{mid}/close", {}, 403)          # not manager
        r = self.post("a", f"/mess/v2/{mid}/close", {}, 200).json()
        s = r["summary"]
        self.assertEqual(s["meals_total_milli"], 274500)          # 75+74.5+75+50
        self.assertEqual(s["bazar_total"], 1023500)
        self.assertTrue(s["reconciles"])
        rows = {x["id"]: x for x in s["members"]}
        # meal cost = largest remainder, sums exactly to the bazar
        self.assertEqual([rows[ids[k]]["meal_cost"] for k in "abcd"],
                         [279645, 277780, 279645, 186430])
        self.assertEqual([rows[ids[k]]["service"] for k in "abcd"],
                         [17500 + 480000, 17500 + 240000, 17500 + 240000, 17500 + 240000])
        self.assertEqual([rows[ids[k]]["due"] for k in "abcd"],
                         [477145, 235280, 237145, 243930])
        self.assertTrue(all(rows[ids[k]]["state"] == "will_pay" for k in "abcd"))
        self.assertIn("Rampura Mess", r["report"])
        # every member got their number inside Assisto (free push)
        self.assertGreaterEqual(self.clock.push.call_count, 4)
        # closed month is immutable for everyone, the manager included
        self.post("b", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-15", "amount": 100}, 409)
        eid = MessEntry.objects.filter(kind="bazar").first().id
        self.post("a", f"/mess/v2/{mid}/entries/{eid}", {"action": "delete"}, 409)
        self.post("a", f"/mess/v2/{mid}/meals",
                  {"date": "2026-11-20", "member_id": ids["b"], "b": 0}, 409)
        self.post("a", f"/mess/v2/{mid}/close", {"month": "2026-11"}, 409)
        # carry forward into December
        self.clock.set(2026, 12, 1, 9)
        dec = self.get("a", f"/mess/v2/{mid}")
        self.assertEqual(dec["month"]["key"], "2026-12")
        carry = {x["id"]: x["carry_in"] for x in dec["summary"]["members"]}
        self.assertEqual(carry[ids["a"]], -477145)
        self.assertEqual(self.get("b", f"/mess/v2/{mid}?month=2026-11")["month"]["closed"], True)
        # due reminders, free, inside Assisto
        n = self.post("a", f"/mess/v2/{mid}/remind", {}, 200).json()["sent"]
        self.assertEqual(n, 4)
        # PDF + text report
        r = self.cl["a"].get(V + f"/mess/v2/{mid}/report?month=2026-11&pdf=1")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        t = self.get("b", f"/mess/v2/{mid}/report?month=2026-11")
        self.assertIn("Rampura Mess", t["text"])
        # history is visible to every member
        h = self.get("d", f"/mess/v2/{mid}/history")["results"]
        self.assertTrue(any(x["action"] == "month.close" for x in h))


class TrustAndEntriesTests(_Base):
    def setUp(self):
        super().setUp()
        self.m = self.make_mess()
        self.add(self.m["id"], self.eb)
        self.add(self.m["id"], self.ec)
        self.mid = self.m["id"]

    def test_author_or_manager_edits_with_history(self):
        e = self.post("b", f"/mess/v2/{self.mid}/entries",
                      {"kind": "bazar", "amount": 10000}, 201).json()["entry"]
        self.post("c", f"/mess/v2/{self.mid}/entries/{e['id']}",
                  {"action": "update", "amount": 1}, 403)
        self.post("b", f"/mess/v2/{self.mid}/entries/{e['id']}",
                  {"action": "update", "amount": 12000}, 200)
        self.post("a", f"/mess/v2/{self.mid}/entries/{e['id']}", {"action": "delete"}, 200)
        acts = list(MessEditLog.objects.filter(entry_id=e["id"]).values_list("action", flat=True))
        self.assertEqual(sorted(acts), ["bazar.add", "bazar.delete", "bazar.edit"])
        j = self.get("c", f"/mess/v2/{self.mid}")
        self.assertEqual(j["entries"], [])

    def test_bad_amount_and_bad_photo_are_clear_errors(self):
        r = self.post("b", f"/mess/v2/{self.mid}/entries", {"kind": "bazar", "amount": "abc"}, 400)
        self.assertEqual(r.json()["code"], "bad_amount")
        r = self.post("b", f"/mess/v2/{self.mid}/entries",
                      {"kind": "bazar", "amount": 100, "photo_b64": "bm90IGFuIGltYWdl"}, 400)
        self.assertEqual(r.json()["code"], "bad_photo")
        self.assertFalse(MessEntry.objects.filter(kind="bazar").exists())

    def test_turn_reminder_night_before_once(self):
        cid = self.member_id(self.mid, self.c)
        self.post("a", f"/mess/v2/{self.mid}/entries",
                  {"kind": "turn", "date": "2026-11-04", "member_id": cid}, 201)
        self.assertEqual(VM.turn_reminders(now=_at(2026, 11, 3, 19)), 0)
        self.assertEqual(VM.turn_reminders(now=_at(2026, 11, 3, 20, 5)), 1)
        self.assertEqual(VM.turn_reminders(now=_at(2026, 11, 3, 21)), 0)

    def test_close_mess_keeps_group_removes_card(self):
        gid = Mess.objects.get(pk=self.mid).group_id
        self.assertIsNotNone(self.get("b", f"/mess/v2/by-group/{gid}")["card"])
        self.post("b", f"/mess/v2/{self.mid}/close-mess", {}, 403)
        self.post("a", f"/mess/v2/{self.mid}/close-mess", {}, 200)
        self.assertIsNone(self.get("b", f"/mess/v2/by-group/{gid}")["card"])
        self.assertTrue(CircleGroup.objects.filter(pk=gid).exists())

    def test_free_old_month_report_is_premium(self):
        MessMonth.objects.create(mess_id=self.mid, key="2026-09", start=dt.date(2026, 9, 1),
                                 end=dt.date(2026, 9, 30), counted_until=dt.date(2026, 9, 30),
                                 summary={"members": [], "bazar_total": 0,
                                          "meals_total_milli": 0, "meal_rate_display": "৳0.00"})
        MessMonth.objects.create(mess_id=self.mid, key="2026-10", start=dt.date(2026, 10, 1),
                                 end=dt.date(2026, 10, 31), counted_until=dt.date(2026, 10, 31),
                                 summary={"members": [], "bazar_total": 0,
                                          "meals_total_milli": 0, "meal_rate_display": "৳0.00"})
        self.get("a", f"/mess/v2/{self.mid}/report?month=2026-10")
        self.get("a", f"/mess/v2/{self.mid}/report?month=2026-09", 402)
        self.assertFalse(self.get("a", f"/mess/v2/{self.mid}?month=2026-09")["month"]["full"])
        with mock.patch.object(VM, "_premium", return_value=True):
            self.get("a", f"/mess/v2/{self.mid}/report?month=2026-09")


class LegacyImportTests(_Base):
    def test_v1_rows_imported_and_kept(self):
        for col, data in (("mess/members", {"name": "Amin"}), ("mess/members", {"name": "Rafiq"}),
                          ("mess/bazar", {"title": "Rice", "amount": "1500"}),
                          ("mess/deposits", {"member": 0, "amount": "2000"}),
                          ("mess/charges", {"member": "common", "title": "Gas", "amount": "900"})):
            PaCollectionItem.objects.create(user=self.a, collection=col, data=data)
        self.assertTrue(self.get("a", "/mess/v2")["legacy_available"])
        r = self.post("a", "/mess/v2/import-legacy", {"name": "Old Mess"}, 201).json()
        mess = Mess.objects.get(pk=r["mess_id"])
        self.assertEqual(r["entries"], 3)
        self.assertEqual(MessMember.objects.filter(mess=mess, user=None).count(), 1)  # Rafiq
        self.assertEqual(PaCollectionItem.objects.filter(user=self.a).count(), 5)    # backup kept
        self.assertIn("mess/bazar", mess.legacy["snapshot"])
        self.assertTrue(self.post("a", "/mess/v2/import-legacy", {}, 200).json()["already"])
        self.assertFalse(self.get("a", "/mess/v2")["legacy_available"])
        # link the V1 name to a real My Circle person
        rafiq = MessMember.objects.get(mess=mess, user=None)
        self.post("a", f"/mess/v2/{mess.id}/members",
                  {"circle_member_id": self.eb.id, "link_member_id": rafiq.id}, 201)
        rafiq.refresh_from_db()
        self.assertEqual(rafiq.user_id, self.b.id)


class PureMathTests(SimpleTestCase):
    def test_period_with_start_day(self):
        self.assertEqual(M.period_for(dt.date(2026, 11, 3), 5),
                         (dt.date(2026, 10, 5), dt.date(2026, 11, 4)))
        self.assertEqual(M.period_for(dt.date(2026, 12, 31), 1),
                         (dt.date(2026, 12, 1), dt.date(2026, 12, 31)))
        self.assertEqual(M.period_for(dt.date(2027, 1, 2), 10),
                         (dt.date(2026, 12, 10), dt.date(2027, 1, 9)))

    def test_day_values_owner_examples(self):
        self.assertEqual(M.day_milli({"b": 1, "l": 1, "d": 1}), 2500)
        self.assertEqual(M.day_milli({"b": 1, "l": 1, "d": 0}), 1500)
        self.assertEqual(M.day_milli({"b": 0, "l": 1, "d": 0}), 1000)
        self.assertEqual(M.day_milli({"b": 0, "l": 0, "d": 0}), 0)
        self.assertEqual(M.day_milli({"b": 1, "l": 1, "d": 1}, breakfast=1000), 3000)
        self.assertEqual(M.day_milli({"b": 1, "l": 1, "d": 1, "gd": 2}), 4500)

    def test_split_exact(self):
        s = M.split_weighted(70000, {1: 1, 2: 1, 3: 1})
        self.assertEqual(sum(s.values()), 70000)
        self.assertEqual(sorted(s.values()), [23333, 23333, 23334])

    def test_cutoff(self):
        self.assertTrue(M.can_member_edit_day(dt.date(2026, 11, 2), dt.datetime(2026, 11, 1, 21, 59)))
        self.assertFalse(M.can_member_edit_day(dt.date(2026, 11, 2), dt.datetime(2026, 11, 1, 22, 0)))

    def test_rate_excludes_service(self):
        s = M.settle([{"id": 1, "name": "A"}, {"id": 2, "name": "B"}], {1: 30000, 2: 30000},
                     [{"amount": 600000}], [{"amount": 70000, "kind": "wifi"}], [])
        self.assertEqual(s["meal_rate"], 10000.0)               # ৳100 per meal
        self.assertEqual([r["due"] for r in s["members"]], [335000, 335000])

    def test_report_bn_digits(self):
        s = M.settle([{"id": 1, "name": "A"}], {1: 2500}, [{"amount": 100}], [], [])
        self.assertNotRegex(M.report_text("M", "2026-11", s, "bn"), r"[0-9]")
