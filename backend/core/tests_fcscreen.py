"""fcscreen (Family Care v3, owner order 9 Nov 10:50) — server rules.

* status rules: ZERO false green (shared case table with the Dart mirror);
* multi-family membership: consent-only join for adults, guardian-only for
  children, Circle peers only, leave any time, admin hand-over;
* board: stale data turns gray (e2e through the API with a moving clock),
  amber raised by another module, SOS red, alerts first;
* shared tasks: "I will do it" is first-come, everyone sees who took it;
* privacy: strangers get 404, admin site has no Family v3 model.
"""
import json
import os
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.contrib import admin
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_v3 as F3
from core.logic import family_status as FS
from core.models import (CircleMember, CirclePresence, FamilyAlert, FcFamily,
                         FcMembership, FcTask, User)

V = "/api/v1"
CASES = os.path.join(os.path.dirname(__file__), "logic", "fc_status_cases.json")


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def pair(a, b, relation="mother"):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, phone=b.phone,
                                     relation=relation, state="accepted")
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name, phone=a.phone,
                                     state="accepted", direction="incoming")
    return ab, ba


class StatusRulesTest(TestCase):
    """The same JSON drives app/test/fc_status_test.dart."""

    def test_case_table(self):
        data = json.load(open(CASES, encoding="utf-8"))
        now = FS.parse_ts(data["now"])
        for c in data["cases"]:
            got = FS.member_status(c["brain"], now, c["flags"])
            self.assertEqual(got["state"], c["state"], c["id"])
            self.assertEqual(got["reason"], c["reason"], c["id"])
            if "fresh_until" in c:
                self.assertEqual(got["fresh_until"], c["fresh_until"], c["id"])
        for c in data["lines"]:
            got = FS.family_line(c["rows"])
            self.assertEqual(got["state"], c["state"], c["id"])
            if "name" in c:
                self.assertEqual(got["name"], c["name"], c["id"])

    def test_never_green_without_last_seen_fuzz(self):
        now = datetime(2026, 11, 9, 10, tzinfo=dtz.utc)
        for battery in (None, 0, 5, 50, 100, "x"):
            for net in ("", "none", "wifi"):
                for interval in (None, 0, 60, 3600, 10 ** 9):
                    b = {"battery": battery, "net": net, "interval_s": interval}
                    self.assertNotEqual(FS.member_status(b, now)["state"], "ok", b)
                    # and an old heartbeat is never green either
                    b["last_seen"] = (now - timedelta(days=2)).isoformat()
                    self.assertNotEqual(FS.member_status(b, now)["state"], "ok", b)


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711300001", "Rina")
        self.b = mk("01711300002", "Ammu", lang="bn")
        self.c = mk("01711300003", "Rafi")
        self.x = mk("01711300004", "Stranger")
        self.ab, _ = pair(self.a, self.b)
        self.ac, _ = pair(self.a, self.c, relation="son")
        self.ca, self.cb, self.cc, self.cx = cl(self.a), cl(self.b, "bn"), cl(self.c), cl(self.x)
        p = mock.patch("core.push.safe_push", return_value=True)
        self.push = p.start()
        self.addCleanup(p.stop)

    def fam(self, client=None):
        r = (client or self.ca).get(f"{V}/family/v3/families")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def join(self, edge, who_client, fid, role="adult"):
        r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                         {"circle_member_id": edge.id, "role": role}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        mid = r.json()["membership_id"]
        if r.json()["state"] == "invited":
            r2 = who_client.post(f"{V}/family/v3/invites/{mid}/accept")
            self.assertEqual(r2.status_code, 200, r2.content)
        return mid


class MembershipTest(Base):
    def test_default_family_created_lazily(self):
        d = self.fam()
        self.assertEqual(len(d["families"]), 1)
        self.assertEqual(d["families"][0]["role"], "admin")
        self.assertEqual(self.fam()["families"][0]["id"], d["families"][0]["id"])

    def test_adult_joins_only_by_consent(self):
        fid = self.fam()["families"][0]["id"]
        r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                         {"circle_member_id": self.ab.id}, format="json")
        self.assertEqual(r.json()["state"], "invited")
        # not a member yet: no SOS recipient, not on the board, can't read it
        self.assertEqual(F3.members_of(self.a), [])
        self.assertEqual(self.cb.get(f"{V}/family/v3/families/{fid}/board").status_code, 404)
        inv = self.fam(self.cb)["invites"]
        self.assertEqual(len(inv), 1)
        self.assertEqual(inv[0]["family_id"], fid)
        self.assertTrue(self.push.called)
        r = self.cb.post(f"{V}/family/v3/invites/{inv[0]['membership_id']}/accept")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([m["user_id"] for m in F3.members_of(self.a)], [self.b.id])
        self.assertTrue(F3.shares_family(self.a, self.b))

    def test_decline_and_others_cannot_answer(self):
        fid = self.fam()["families"][0]["id"]
        mid = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                           {"circle_member_id": self.ab.id}, format="json").json()["membership_id"]
        self.assertEqual(self.cc.post(f"{V}/family/v3/invites/{mid}/accept").status_code, 404)
        self.assertEqual(self.cb.post(f"{V}/family/v3/invites/{mid}/decline").status_code, 200)
        self.assertFalse(F3.shares_family(self.a, self.b))

    def test_only_circle_peers(self):
        fid = self.fam()["families"][0]["id"]
        other = CircleMember.objects.create(user=self.x, peer_user=self.c, state="accepted")
        r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                         {"circle_member_id": other.id}, format="json")
        self.assertEqual(r.status_code, 404)
        self.ab.blocked = True
        self.ab.save()
        r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                         {"circle_member_id": self.ab.id}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_child_only_by_guardian(self):
        fid = self.fam()["families"][0]["id"]
        with mock.patch("core.guardian_links.is_guardian", return_value=False):
            r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                             {"circle_member_id": self.ac.id, "role": "child"}, format="json")
            self.assertEqual(r.status_code, 403)
        with mock.patch("core.guardian_links.is_guardian", return_value=True):
            r = self.ca.post(f"{V}/family/v3/families/{fid}/invite",
                             {"circle_member_id": self.ac.id, "role": "child"}, format="json")
        self.assertEqual(r.json()["state"], "active")
        self.assertEqual(F3.role_of(self.c, fid), "child")

    def test_multi_family_union_dedup(self):
        fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, fid)
        r = self.ca.post(f"{V}/family/v3/families", {"name": "Parents home"}, format="json")
        self.assertEqual(r.status_code, 201)
        fid2 = r.json()["family"]["id"]
        self.join(self.ab, self.cb, fid2)
        self.join(self.ac, self.cc, fid2)
        mo = {m["user_id"]: m for m in F3.members_of(self.a)}
        self.assertEqual(set(mo), {self.b.id, self.c.id})
        self.assertEqual(sorted(mo[self.b.id]["family_ids"]), sorted([fid, fid2]))
        self.assertEqual(mo[self.b.id]["phone"], self.b.phone)
        self.assertEqual(len(self.fam(self.cb)["families"]), 2)  # joined two, no extra default
        self.assertEqual(F3.family_ids_of(self.c)[-1], fid2)

    def test_family_limit(self):
        self.fam()
        for i in range(F3.MAX_FAMILIES - 1):
            self.assertEqual(self.ca.post(f"{V}/family/v3/families", {"name": "F%d" % i},
                                          format="json").status_code, 201)
        r = self.ca.post(f"{V}/family/v3/families", {"name": "one too many"}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_leave_any_time_and_admin_handover(self):
        fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, fid)
        self.assertEqual(self.ca.post(f"{V}/family/v3/families/{fid}/leave").status_code, 200)
        self.assertEqual(F3.role_of(self.b, fid), "admin")
        self.assertFalse(F3.shares_family(self.a, self.b))
        self.assertEqual(self.ca.get(f"{V}/family/v3/families/{fid}/board").status_code, 404)

    def test_remove_admin_only(self):
        fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, fid)
        self.join(self.ac, self.cc, fid)
        self.assertEqual(self.cb.post(f"{V}/family/v3/families/{fid}/remove/{self.c.id}")
                         .status_code, 403)
        self.assertEqual(self.ca.post(f"{V}/family/v3/families/{fid}/remove/{self.c.id}")
                         .status_code, 200)
        self.assertFalse(F3.shares_family(self.a, self.c))

    def test_abroad_self_only(self):
        fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, fid)
        u = f"{V}/family/v3/families/{fid}/members/{self.b.id}"
        self.assertEqual(self.ca.post(u, {"abroad_tz": "Asia/Riyadh"}, format="json")
                         .status_code, 403)
        self.assertEqual(self.cb.post(u, {"abroad_tz": "Mars/Base"}, format="json")
                         .status_code, 400)
        self.assertEqual(self.cb.post(u, {"abroad_tz": "Asia/Riyadh"}, format="json")
                         .status_code, 200)
        self.assertTrue(F3.someone_abroad(fid))
        self.assertTrue(self.fam()["families"][0]["someone_abroad"])

    def test_no_admin_registration(self):
        for m in (FcFamily, FcMembership, FcTask):
            self.assertNotIn(m, admin.site._registry)


class BoardTest(Base):
    def setUp(self):
        super().setUp()
        self.fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, self.fid)
        self.join(self.ac, self.cc, self.fid)

    def brain(self, by_user):
        def fake(viewer, member):
            return dict(by_user.get(member.id, {}))
        return mock.patch("core.family_v3._brain",
                          side_effect=lambda v, m, now: fake(v, m))

    def test_e2e_stale_data_turns_gray(self):
        """The reality path: fresh heartbeat = green; the SAME data read 3 h
        later = gray dashed card with a plain reason; line says No news."""
        t0 = timezone.now()
        CirclePresence.objects.create(user=self.b, last_seen=t0)
        CirclePresence.objects.create(user=self.c, last_seen=t0)
        with mock.patch("django.utils.timezone.now", return_value=t0 + timedelta(minutes=5)):
            d = self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()
        self.assertEqual(d["line"]["state"], "ok")
        st = {m["user_id"]: m["status"] for m in d["members"]}
        self.assertEqual(st[self.b.id]["state"], "ok")
        with mock.patch("django.utils.timezone.now",
                        return_value=t0 + timedelta(hours=3, seconds=1)):
            d = self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()
        st = {m["user_id"]: m["status"] for m in d["members"]}
        self.assertEqual(st[self.b.id]["state"], "stale")
        self.assertEqual(st[self.b.id]["reason"], "background_killed")
        self.assertEqual(d["line"]["state"], "stale")
        chips = {m["user_id"]: m["chip"] for m in d["members"]}
        self.assertEqual(chips[self.b.id]["kind"], "no_news")

    def test_no_heartbeat_never_green(self):
        d = self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()
        self.assertEqual(d["line"]["state"], "stale")
        for m in d["members"]:
            self.assertNotEqual(m["status"]["state"], "ok")

    def test_brain_reasons_and_alerts_first(self):
        now = timezone.now()
        old = (now - timedelta(hours=5)).isoformat()
        with self.brain({self.b.id: {"last_seen": old, "battery": 4},
                         self.c.id: {"last_seen": now.isoformat(), "battery": 90},
                         self.a.id: {"last_seen": now.isoformat()}}):
            d = F3.board(self.a, self.fid, now)
        self.assertEqual(d["members"][0]["user_id"], self.b.id)   # alert first
        self.assertEqual(d["members"][0]["status"]["reason"], "battery_off")
        self.assertTrue(d["members"][-1]["me"])                    # me last
        self.assertEqual(d["line"]["user_id"], self.b.id)

    def test_amber_from_other_module_and_clear(self):
        now = timezone.now()
        fresh = {"last_seen": now.isoformat(), "battery": 80}
        with self.brain({self.b.id: fresh, self.c.id: fresh}):
            self.assertEqual(F3.board(self.a, self.fid, now)["line"]["state"], "ok")
            self.assertTrue(F3.set_member_status(self.b, "amber", "watch", "fcelder"))
            d = F3.board(self.a, self.fid, now)
            self.assertEqual(d["line"]["state"], "check")
            self.assertEqual(d["line"]["reason"], "watch")
            self.assertFalse(F3.set_member_status(self.b, "green", "x", "fcelder"))
            F3.clear_member_status(self.b, "fcelder")
            self.assertEqual(F3.board(self.a, self.fid, now)["line"]["state"], "ok")
            F3.set_member_status(self.b, "amber", "no_unlock", "fcelder", ttl_s=60, now=now)
            self.assertEqual(F3.board(self.a, self.fid, now)["line"]["state"], "check")
            later = now + timedelta(minutes=2)
            self.assertEqual(F3.board(self.a, self.fid, later)["line"]["state"], "ok")

    def test_sos_fallback_is_red(self):
        now = timezone.now()
        FamilyAlert.objects.create(user=self.a, kind="sos", payload={"from_user_id": self.c.id})
        with self.brain({self.b.id: {"last_seen": now.isoformat()}}):
            d = F3.board(self.a, self.fid, now)
        self.assertEqual(d["line"]["state"], "sos")
        self.assertEqual(d["members"][0]["user_id"], self.c.id)

    def test_paused_is_not_all_ok(self):
        now = timezone.now()
        with self.brain({self.b.id: {"last_seen": now.isoformat(),
                                     "paused_until": (now + timedelta(hours=1)).isoformat()},
                         self.c.id: {"last_seen": now.isoformat()}}):
            d = F3.board(self.a, self.fid, now)
        self.assertEqual(d["line"]["state"], "stale")
        b = next(m for m in d["members"] if m["user_id"] == self.b.id)
        self.assertEqual(b["chip"]["kind"], "paused")

    def test_stranger_and_ex_member_404(self):
        self.assertEqual(self.cx.get(f"{V}/family/v3/families/{self.fid}/board").status_code, 404)
        self.assertEqual(self.cx.get(f"{V}/family/v3/members/{self.b.id}?family={self.fid}")
                         .status_code, 404)

    def test_member_page_who_can_see(self):
        r = self.cb.get(f"{V}/family/v3/members/{self.b.id}?family={self.fid}")
        self.assertEqual(r.status_code, 200, r.content)
        names = {x["user_id"] for x in r.json()["seen_by"]}
        self.assertEqual(names, {self.a.id, self.c.id})
        self.assertNotIn(self.x.id, names)


class TasksTest(Base):
    def setUp(self):
        super().setUp()
        self.fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, self.fid)
        self.join(self.ac, self.cc, self.fid)

    def test_i_will_do_it_first_come(self):
        r = self.cb.post(f"{V}/family/v3/families/{self.fid}/tasks",
                         {"title": "Medicine running out", "kind": "medicine"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        tid = r.json()["task"]["id"]
        self.assertEqual(self.cc.post(f"{V}/family/v3/tasks/{tid}/take").status_code, 200)
        self.assertEqual(self.ca.post(f"{V}/family/v3/tasks/{tid}/take").status_code, 409)
        seen = self.ca.get(f"{V}/family/v3/families/{self.fid}/tasks").json()["tasks"][0]
        self.assertEqual(seen["taken_by_name"], "Rafi")
        self.assertFalse(seen["mine"])
        self.assertEqual(self.ca.post(f"{V}/family/v3/tasks/{tid}/release").status_code, 403)
        self.assertEqual(self.cc.post(f"{V}/family/v3/tasks/{tid}/done").status_code, 200)
        seen = self.cb.get(f"{V}/family/v3/families/{self.fid}/tasks").json()["tasks"][0]
        self.assertTrue(seen["done"])
        self.assertEqual(self.cx.post(f"{V}/family/v3/tasks/{tid}/take").status_code, 404)

    def test_bill_counts_in_today(self):
        today = timezone.localdate()
        self.ca.post(f"{V}/family/v3/families/{self.fid}/tasks",
                     {"title": "DESCO bill", "kind": "bill", "due_date": today.isoformat()},
                     format="json")
        d = self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()
        self.assertEqual(d["today"]["bills_due"], 1)

    def test_title_required(self):
        r = self.ca.post(f"{V}/family/v3/families/{self.fid}/tasks", {"title": " "},
                         format="json")
        self.assertEqual(r.status_code, 400)
