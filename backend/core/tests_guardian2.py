"""guardian2 — PART 6 TWO GUARDIANS (owner 3 Nov 18:40).

Mom set up School Mode + a kids watch for Rina. Dad is NOT in anyone's
My Circle. Checks: invite -> join -> approve -> access; no access before
approval (nor by the requester approving himself, nor by a stranger);
reject; remove -> both guardians + the child told, access gone; arrive /
leave + SOS fan out to both; SOS "<name> is responding" to the other
guardian and the child; the plan limit; SOS never blocked by this code.

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_alerts as FA
from core import guardian_links as GL
from core import kidswatch_service as KW
from core.models import (CircleMember, FamilyAlertDelivery, GuardianLink, KidsWatch,
                         SchoolPlan, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!")


def pair(a, b, rel_ab="friend", rel_ba="friend"):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                relation=rel_ab)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                relation=rel_ba, direction="incoming")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "ben": ben,
                           "data": dict(data or {})})
        return True

    def users(self):
        return {c["user"] for c in self.calls}

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]

    def clear(self):
        self.calls = []


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01711400001", "Mom")
        self.dad = mk("01711400002", "Dad")
        self.rina = mk("01711400003", "Rina")
        self.x = mk("01711400004", "Stranger")
        pair(self.mom, self.rina, "child", "mother")
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        p2 = mock.patch("core.kidswatch_views.school_on", return_value=True)
        p2.start()
        self.addCleanup(p2.stop)
        now = timezone.now()
        self.plan = SchoolPlan.objects.create(
            owner=self.mom, child_user=self.rina, child_name="Rina", watcher_ids=[],
            accepted_at=now, last_known={"lat": 23.7771234, "lng": 90.3991234,
                                         "at": now.isoformat(), "source": "phone"})
        self.watch = KidsWatch.objects.create(
            owner=self.mom, child_user=self.rina, child_name="Rina", imei="8800000977",
            state="paired", guardian_ids=[], last_lat=23.7771234, last_lng=90.3991234)

    def invite(self, by=None):
        r = cl(by or self.mom).post(V + "/guardians/invites", {"child_id": self.rina.id},
                                    format="json")
        return r

    def join(self, code, who=None):
        return cl(who or self.dad).post(V + "/guardians/join", {"code": code}, format="json")

    def act(self, who, link_id, action):
        return cl(who).post(V + "/guardians/links/%d/%s" % (link_id, action))

    def approved_dad(self):
        code = self.invite().json()["code"]
        lid = self.join(code).json()["id"]
        r = self.act(self.mom, lid, "approve")
        self.assertEqual(r.status_code, 200, r.content)
        self.spy.clear()
        return lid

    def dad_sees(self):
        return (KW.can_view_plan(self.dad, SchoolPlan.objects.get(pk=self.plan.pk)),
                KW.can_view_watch(self.dad, KidsWatch.objects.get(pk=self.watch.pk)))


class InviteApproveAccess(Base):
    def test_invite_join_approve_gives_access(self):
        r = self.invite()
        self.assertEqual(r.status_code, 201, r.content)
        d = r.json()
        self.assertEqual(len(d["code"]), GL.CODE_LEN)
        self.assertIn(d["code"], d["link"])
        self.assertEqual(d["max"], 2)
        r = self.join(d["code"].lower())          # case / spaces forgiven
        self.assertEqual(r.status_code, 201, r.content)
        lid = r.json()["id"]
        self.assertEqual(r.json()["state"], "pending")
        # Mom (existing guardian) is asked to approve, high priority
        self.assertTrue(any(c["data"].get("action") == "approve" for c in self.spy.to(self.mom)))
        r = self.act(self.mom, lid, "approve")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.dad_sees(), (True, True))
        self.assertEqual(cl(self.dad).get(V + "/school-mode/plans/%d" % self.plan.pk)
                         .status_code, 200)
        # Dad + Rina told
        self.assertTrue(self.spy.to(self.dad))
        self.assertTrue(any(c["data"].get("child_view") for c in self.spy.to(self.rina)))
        # the child's screen: Dad by name + since when
        mine = cl(self.rina).get(V + "/guardians/mine").json()
        rows = {g["name"]: g for g in mine["guardians"]}
        self.assertIn("Dad", rows)
        self.assertIn("co_guardian", {s["kind"] for s in rows["Dad"]["sources"]})
        self.assertTrue(rows["Dad"]["since"])
        self.assertTrue(rows["Mom"]["since"])
        self.assertEqual(mine["pending"], [])
        # Dad's side: Rina listed, Mom is the other guardian
        kids = cl(self.dad).get(V + "/guardians/children").json()["children"]
        rk = [k for k in kids if k["child_user_id"] == self.rina.id]
        self.assertEqual(len(rk), 1)
        self.assertIn(self.mom.id, {g["id"] for g in rk[0]["co_guardians"]})

    def test_no_access_before_approval(self):
        code = self.invite().json()["code"]
        lid = self.join(code).json()["id"]
        self.assertEqual(self.dad_sees(), (False, False))
        self.assertNotEqual(cl(self.dad).get(V + "/school-mode/plans/%d" % self.plan.pk)
                            .status_code, 200)
        # the child sees the waiting request, honestly marked as no access
        mine = cl(self.rina).get(V + "/guardians/mine").json()
        self.assertNotIn("Dad", {g["name"] for g in mine["guardians"]})
        self.assertEqual([p["name"] for p in mine["pending"]], ["Dad"])
        # nobody but an existing guardian can approve
        self.assertEqual(self.act(self.dad, lid, "approve").status_code, 404)
        self.assertEqual(self.act(self.x, lid, "approve").status_code, 404)
        self.assertEqual(self.act(self.rina, lid, "approve").status_code, 404)
        self.assertEqual(self.dad_sees(), (False, False))
        # an SOS before approval does NOT reach Dad
        FA.sos(self.rina, lat=23.7771234, lng=90.3991234, client_id="pre")
        self.assertFalse(FamilyAlertDelivery.objects.filter(recipient=self.dad).exists())

    def test_stranger_cannot_invite_and_codes_are_checked(self):
        self.assertEqual(self.invite(by=self.x).status_code, 404)
        self.assertEqual(self.invite(by=self.dad).status_code, 404)
        self.assertEqual(self.join("NOPE2345").status_code, 404)
        code = self.invite().json()["code"]
        self.assertEqual(self.join(code, who=self.rina).status_code, 400)   # the child
        GuardianLink.objects.filter(code=code).update(
            expires_at=timezone.now() - timedelta(minutes=1))
        self.assertEqual(self.join(code).status_code, 410)
        code = self.invite().json()["code"]
        self.assertEqual(self.join(code).status_code, 201)
        self.assertEqual(self.join(code, who=self.x).status_code, 409)       # used once

    def test_reject(self):
        code = self.invite().json()["code"]
        lid = self.join(code).json()["id"]
        self.spy.clear()
        r = self.act(self.mom, lid, "reject")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(GuardianLink.objects.get(pk=lid).state, "rejected")
        self.assertTrue(self.spy.to(self.dad))
        self.assertEqual(self.dad_sees(), (False, False))
        self.assertEqual(self.act(self.mom, lid, "approve").status_code, 409)

    def test_remove_notifies_both_and_child(self):
        lid = self.approved_dad()
        r = self.act(self.mom, lid, "remove")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(self.spy.to(self.mom))
        self.assertTrue(self.spy.to(self.dad))
        self.assertTrue(any(c["data"].get("child_view") for c in self.spy.to(self.rina)))
        self.assertEqual(self.dad_sees(), (False, False))
        self.assertNotIn(self.dad.id, KidsWatch.objects.get(pk=self.watch.pk).guardian_ids)
        names = {g["name"] for g in cl(self.rina).get(V + "/guardians/mine").json()["guardians"]}
        self.assertNotIn("Dad", names)

    def test_co_guardian_can_leave(self):
        lid = self.approved_dad()
        self.assertEqual(self.act(self.dad, lid, "remove").status_code, 200)
        self.assertTrue(self.spy.to(self.mom))
        self.assertEqual(self.dad_sees(), (False, False))

    def test_plan_limit(self):
        self.approved_dad()
        r = self.invite()
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["detail"], "limit")
        self.assertEqual(r.json()["max"], 2)
        with mock.patch("core.guardian_links.max_guardians", return_value=4):
            self.assertEqual(self.invite().status_code, 201)

    def test_overview_lists_requests(self):
        code = self.invite().json()["code"]
        self.join(code)
        o = cl(self.mom).get(V + "/guardians/links").json()
        self.assertEqual([x["guardian_name"] for x in o["to_approve"]], ["Dad"])
        d = cl(self.dad).get(V + "/guardians/links").json()
        self.assertEqual([x["state"] for x in d["my_requests"]], ["pending"])


class FanOut(Base):
    def test_school_alerts_reach_both(self):
        self.approved_dad()
        self.assertEqual({u.id for u in KW.plan_watchers(SchoolPlan.objects.get(pk=self.plan.pk))},
                         {self.mom.id, self.dad.id})
        KW.deliver_event(SchoolPlan.objects.get(pk=self.plan.pk),
                         {"kind": "arrived_school", "notify": "push"})
        self.assertEqual(self.spy.users(), {self.mom.id, self.dad.id})
        self.spy.clear()
        self.assertEqual({u.id for u in KW.watch_audience(KidsWatch.objects.get(pk=self.watch.pk))},
                         {self.mom.id, self.dad.id})

    def test_sos_rings_both_and_shows_responder(self):
        self.approved_dad()
        st = FA.sos(self.rina, lat=23.7771234, lng=90.3991234, client_id="s1")
        self.assertEqual(st["recipients"], 2)
        rows = {d.recipient_id: d for d in FamilyAlertDelivery.objects.filter(kind="sos")}
        self.assertEqual(set(rows), {self.mom.id, self.dad.id})
        self.assertTrue(rows[self.dad.id].with_location)
        sos_pushes = [c for c in self.spy.calls if c["kind"] == "sos"]
        self.assertEqual({c["user"] for c in sos_pushes}, {self.mom.id, self.dad.id})
        self.spy.clear()
        r = cl(self.dad).post(V + "/family/alerts/%d/responding" % rows[self.dad.id].id)
        self.assertEqual(r.status_code, 200, r.content)
        # Mom and Rina are told "Dad is responding"
        self.assertTrue(any("Dad is responding" in c["ten"] for c in self.spy.to(self.mom)))
        self.assertTrue(any("Dad is responding" in c["ten"] for c in self.spy.to(self.rina)))
        mom_rows = cl(self.mom).get(V + "/family/alerts").json()["received"]
        self.assertEqual([x["name"] for x in mom_rows[0]["responders"]], ["Dad"])
        lad = cl(self.rina).get(V + "/family/sos/ladder").json()
        self.assertEqual([x["name"] for x in lad["responders"]], ["Dad"])
        # a second tap does not ring everyone again
        self.spy.clear()
        cl(self.dad).post(V + "/family/alerts/%d/responding" % rows[self.dad.id].id)
        self.assertEqual(self.spy.calls, [])
        # nobody else can mark Dad's delivery
        self.assertEqual(cl(self.mom).post(V + "/family/alerts/%d/responding"
                                           % rows[self.dad.id].id).status_code, 404)

    def test_sos_never_blocked_by_guardian2(self):
        self.approved_dad()
        with mock.patch("core.guardian_links.sos_extra_recipients",
                        side_effect=RuntimeError("boom")):
            st = FA.sos(self.rina, lat=23.7, lng=90.4, client_id="s2")
        self.assertEqual(st["recipients"], 1)       # Mom (circle) still rang
        self.assertTrue(FamilyAlertDelivery.objects.filter(recipient=self.mom,
                                                           kind="sos").exists())

    def test_removed_guardian_gets_no_more_sos(self):
        lid = self.approved_dad()
        self.act(self.mom, lid, "remove")
        FA.sos(self.rina, lat=23.7, lng=90.4, client_id="s3")
        self.assertFalse(FamilyAlertDelivery.objects.filter(recipient=self.dad,
                                                            kind="sos").exists())
