"""callsB — group calls on the mesh (max 4): roster lifecycle, the cap,
only accepted My Circle contacts, the invite ring push, join from the group
chat, leave / end, per-pair signalling, the add-person rate limit, and 1:1
calls unchanged when nobody is added."""
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core.logic import call_rooms as R
from core.models import (CallRecord, CallRoom, CallRoomLink, CallRoomMember,
                         CircleGroup, CircleGroupMember, CircleMember, Device,
                         RtEvent, RtPresence, User)
from core.tests_push import _PushBase

V = "/api/v1"


class _Room:
    NAMES = ["Rahim", "Karim", "Salma", "Nadia", "Tanvir", "Mitu"]

    def mk(self, n=5):
        self.u, self.cl = [], []
        for i in range(n):
            u = User.objects.create_user(name=self.NAMES[i],
                                         phone="0174000020%d" % i,
                                         password="pw12345!", language="en")
            c = APIClient()
            c.force_authenticate(u)
            self.u.append(u)
            self.cl.append(c)
        self.edge = {}
        for i in range(n):
            for j in range(n):
                if i != j:
                    self.edge[(i, j)] = CircleMember.objects.create(
                        user=self.u[i], peer_user=self.u[j],
                        name=self.NAMES[j], state="accepted",
                        phone=self.u[j].phone)
        for u in self.u:
            self.online(u)

    def online(self, user):
        RtPresence.objects.update_or_create(user=user,
                                            defaults={"seen_at": timezone.now()})

    def call(self, i, j, kind="voice"):
        """i calls j, j answers, ICE connects -> an active 1:1 call."""
        r = self.cl[i].post(f"{V}/circle/{self.edge[(i, j)].id}/call",
                            {"kind": kind}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        cid = r.json()["call_id"]
        self.ev(j, cid, "ringing")
        self.ev(j, cid, "answer")
        self.ev(i, cid, "connected")
        return cid

    def ev(self, i, cid, event, **extra):
        r = self.cl[i].post(f"{V}/circle/calls/{cid}/event",
                            {"event": event, **extra}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def add(self, i, cid, j, status=201):
        r = self.cl[i].post(f"{V}/circle/calls/{cid}/add",
                            {"member_id": self.edge[(i, j)].id}, format="json")
        self.assertEqual(r.status_code, status, r.content)
        return r.json()

    def rt(self, i, topic=""):
        evs = RtEvent.objects.filter(user=self.u[i]).order_by("id")
        if topic:
            evs = evs.filter(topic=topic)
        return [{"topic": e.topic, "payload": e.payload} for e in evs]

    def last_roster(self, i):
        rs = self.rt(i, "call.roster")
        return rs[-1]["payload"] if rs else None

    def state_of(self, roster, i):
        return next(m["state"] for m in roster["members"]
                    if m["user_id"] == self.u[i].id)


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class GroupRoomTests(_Room, TestCase):

    def setUp(self):
        push.reset_cache()
        self.mk()

    # ---------------------------------------------------------- 1:1 unchanged
    def test_one_to_one_unchanged_when_nobody_is_added(self):
        cid = self.call(0, 1)
        self.ev(0, cid, "hangup")
        self.assertEqual(CallRoom.objects.count(), 0)
        self.assertEqual(CallRoomLink.objects.count(), 0)
        self.assertEqual(self.rt(0, "call.roster"), [])
        self.assertEqual(self.rt(1, "call.roster"), [])
        rec = CallRecord.objects.get(pk=cid)
        self.assertEqual(rec.state, "ended")
        hist = self.cl[0].get(f"{V}/circle/calls").json()["calls"]
        self.assertEqual([h["id"] for h in hist], [cid])
        r = self.cl[0].get(f"{V}/circle/calls/{cid}/room")
        self.assertEqual(r.status_code, 404)

    # ---------------------------------------------------------- roster
    def test_add_person_rings_like_a_normal_call_and_builds_the_roster(self):
        cid = self.call(0, 1)
        body = self.add(0, cid, 2)
        room = CallRoom.objects.get()
        self.assertEqual(room.base_call_id, cid)
        self.assertEqual(body["active"], 3)
        self.assertEqual(self.state_of(body, 2), "ringing")
        ring_id = body["invited"]["call_id"]
        ring = CallRecord.objects.get(pk=ring_id)
        self.assertEqual((ring.caller_id, ring.callee_id),
                         (self.u[0].id, self.u[2].id))
        self.assertEqual(ring.state, "ringing")
        self.assertEqual(ring.room_link.via, "ring")
        # the added person gets the NORMAL in-app ring (call.incoming)
        inc = self.rt(2, "call.incoming")
        self.assertEqual(inc[-1]["payload"]["call_id"], ring_id)
        self.assertEqual(self.cl[2].get(f"{V}/circle/calls/incoming")
                         .json()["calls"][0]["call_id"], ring_id)
        # everybody in the call got the roster; each sees its own links
        ra, rb = self.last_roster(0), self.last_roster(1)
        self.assertEqual({l["call_id"] for l in ra["links"]}, {cid, ring_id})
        self.assertEqual({l["call_id"] for l in rb["links"]}, {cid})
        ring_link = next(l for l in ra["links"] if l["call_id"] == ring_id)
        self.assertEqual(ring_link["role"], "caller")
        self.assertEqual(self.state_of(rb, 2), "ringing")

    def test_invitee_accepts_joins_and_gets_pair_links_to_everyone(self):
        cid = self.call(0, 1)
        ring_id = self.add(0, cid, 2)["invited"]["call_id"]
        self.ev(2, ring_id, "ringing")
        self.ev(2, ring_id, "answer")
        room = CallRoom.objects.get()
        self.assertEqual(CallRoomMember.objects.get(room=room, user=self.u[2])
                         .state, "joined")
        mesh = CallRecord.objects.filter(room_link__via="mesh")
        self.assertEqual(mesh.count(), 1)
        m = mesh.get()
        # the newer participant is the caller (= offerer) of the pair
        self.assertEqual((m.caller_id, m.callee_id), (self.u[2].id, self.u[1].id))
        self.assertEqual(m.state, "connecting")
        rc = self.last_roster(2)
        self.assertEqual(rc["joined"], 3)
        roles = {l["call_id"]: l["role"] for l in rc["links"]}
        self.assertEqual(roles, {ring_id: "callee", m.id: "caller"})
        rb = self.last_roster(1)
        self.assertIn({"call_id": m.id, "role": "callee"},
                      [{"call_id": l["call_id"], "role": l["role"]}
                       for l in rb["links"]])
        self.assertTrue(rb["low_bandwidth"])
        # mesh pair links never show in the call history
        for i in (1, 2):
            ids = [h["id"] for h in
                   self.cl[i].get(f"{V}/circle/calls").json()["calls"]]
            self.assertNotIn(m.id, ids)

    def test_signalling_is_routed_per_pair(self):
        cid = self.call(0, 1)
        ring_id = self.add(0, cid, 2)["invited"]["call_id"]
        self.ev(2, ring_id, "answer")
        m = CallRecord.objects.get(room_link__via="mesh")
        r = self.cl[2].post(f"{V}/rt/send", {"topic": "call.signal", "payload": {
            "call_id": m.id, "kind": "offer", "data": {"sdp": "v=0 C"}}},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        got_b = [e for e in self.rt(1, "call.signal")
                 if e["payload"]["call_id"] == m.id]
        self.assertEqual(len(got_b), 1)
        self.assertEqual(got_b[0]["payload"]["data"]["sdp"], "v=0 C")
        self.assertEqual([e for e in self.rt(0, "call.signal")
                          if e["payload"]["call_id"] == m.id], [])
        # an outsider can't inject into a pair it is not part of
        r = self.cl[3].post(f"{V}/rt/send", {"topic": "call.signal", "payload": {
            "call_id": m.id, "kind": "offer", "data": {"sdp": "x"}}}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_cap_of_four_is_enforced_on_the_server(self):
        cid = self.call(0, 1)
        self.add(0, cid, 2)
        body = self.add(0, cid, 3)
        self.assertEqual(body["active"], 4)
        self.assertFalse(body["can_add"])
        r = self.add(0, cid, 4, status=409)
        self.assertEqual(r["code"], "full")
        self.assertEqual(R.MAX_PARTICIPANTS, 4)
        self.assertEqual(CallRoomMember.objects.count(), 4)

    def test_only_accepted_circle_contacts_can_be_added(self):
        cid = self.call(0, 1)
        e = self.edge[(0, 2)]
        e.state = "pending"
        e.save()
        r = self.add(0, cid, 2, status=403)
        self.assertEqual(r["code"], "not_contact")
        # someone else's edge id is not mine -> not a contact
        r = self.cl[0].post(f"{V}/circle/calls/{cid}/add",
                            {"member_id": self.edge[(1, 3)].id}, format="json")
        self.assertEqual(r.status_code, 403)
        # a refused first add leaves the plain 1:1 call (no empty room)
        self.assertEqual(CallRoom.objects.count(), 0)
        # a blocked contact is refused neutrally
        e3 = self.edge[(3, 0)]
        e3.blocked = True
        e3.save()
        self.assertEqual(self.add(0, cid, 3, status=403)["code"], "blocked")

    def test_only_people_in_the_call_can_add(self):
        cid = self.call(0, 1)
        r = self.cl[2].post(f"{V}/circle/calls/{cid}/add",
                            {"member_id": self.edge[(2, 3)].id}, format="json")
        self.assertEqual(r.status_code, 404)
        # a call that is still ringing can't grow into a group
        r = self.cl[0].post(f"{V}/circle/{self.edge[(0, 3)].id}/call",
                            {"kind": "voice"}, format="json")
        ringing = r.json()["call_id"]
        self.assertEqual(self.add(0, ringing, 2, status=403)["code"],
                         "not_in_call")

    def test_add_person_is_rate_limited(self):
        cid = self.call(0, 1)
        for _ in range(R.INVITES_PER_ROOM_PER_MIN):
            ring = self.add(0, cid, 2)["invited"]["call_id"]
            self.ev(2, ring, "decline")
            self.assertEqual(self.state_of(self.last_roster(0), 2), "declined")
        r = self.add(0, cid, 2, status=429)
        self.assertEqual(r["code"], "rate_limited")

    def test_decline_keeps_the_one_to_one_call(self):
        cid = self.call(0, 1)
        ring = self.add(0, cid, 2)["invited"]["call_id"]
        self.ev(2, ring, "decline")
        room = CallRoom.objects.get()
        self.assertEqual(room.state, "live")
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "active")
        ra = self.last_roster(0)
        self.assertEqual(ra["active"], 2)
        self.assertEqual(self.state_of(ra, 2), "declined")

    def test_leave_then_end(self):
        cid = self.call(0, 1)
        ring = self.add(0, cid, 2)["invited"]["call_id"]
        self.ev(2, ring, "answer")
        room = CallRoom.objects.get()
        # B leaves: B's pair links end, the call goes on for A and C
        r = self.cl[1].post(f"{V}/circle/rooms/{room.id}/leave")
        self.assertEqual(r.status_code, 200, r.content)
        room.refresh_from_db()
        self.assertEqual(room.state, "live")
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "ended")
        mesh = CallRecord.objects.get(room_link__via="mesh")
        self.assertEqual(mesh.state, "ended")
        self.assertEqual(CallRecord.objects.get(pk=ring).state, "connecting")
        ra = self.last_roster(0)
        self.assertEqual(self.state_of(ra, 1), "left")
        self.assertEqual(ra["joined"], 2)
        # C hangs up its link with A -> nobody left to talk to -> ended
        self.ev(2, ring, "hangup")
        room.refresh_from_db()
        self.assertEqual(room.state, "ended")
        self.assertEqual(self.last_roster(0)["state"], "ended")

    def test_hanging_up_the_base_call_keeps_the_group(self):
        cid = self.call(0, 1)
        ring = self.add(0, cid, 2)["invited"]["call_id"]
        self.ev(2, ring, "answer")
        self.ev(1, cid, "hangup")   # B hangs up its call with A only
        room = CallRoom.objects.get()
        self.assertEqual(room.state, "live")
        # B still has its pair link with C -> still joined
        self.assertEqual(CallRoomMember.objects.get(room=room, user=self.u[1])
                         .state, "joined")

    def test_the_room_of_a_call_is_visible_to_its_people_only(self):
        cid = self.call(0, 1)
        self.add(0, cid, 2)
        room = CallRoom.objects.get()
        self.assertEqual(self.cl[1].get(f"{V}/circle/calls/{cid}/room")
                         .json()["room_id"], room.id)
        self.assertEqual(self.cl[3].get(f"{V}/circle/rooms/{room.id}")
                         .status_code, 404)
        self.assertEqual(self.cl[3].post(f"{V}/circle/rooms/{room.id}/join")
                         .status_code, 404)

    def test_media_state_reaches_the_roster(self):
        cid = self.call(0, 1)
        self.add(0, cid, 2)
        room = CallRoom.objects.get()
        r = self.cl[1].post(f"{V}/circle/rooms/{room.id}/media",
                            {"muted": True, "screen": True}, format="json")
        self.assertEqual(r.status_code, 200)
        m = next(x for x in self.last_roster(0)["members"]
                 if x["user_id"] == self.u[1].id)
        self.assertTrue(m["muted"])
        self.assertTrue(m["screen"])


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class GroupChatCallTests(_Room, TestCase):

    def setUp(self):
        push.reset_cache()
        self.mk()
        self.g = CircleGroup.objects.create(creator=self.u[0], name="Family")
        for i in range(4):
            CircleGroupMember.objects.create(group=self.g, member=self.u[i],
                                             role="admin" if i == 0 else "member")
        # C (2) is in the group but NOT a contact of A
        CircleMember.objects.filter(user=self.u[0], peer_user=self.u[2]).delete()

    def start(self, i=0, ids=(1,), status=201, kind="voice"):
        r = self.cl[i].post(f"{V}/circle/groups/{self.g.id}/call/start",
                            {"kind": kind,
                             "user_ids": [self.u[j].id for j in ids]},
                            format="json")
        self.assertEqual(r.status_code, status, r.content)
        return r.json()

    def test_start_from_the_group_rings_contacts_only(self):
        body = self.start(ids=(1, 2))
        outs = {int(k): v for k, v in body["outcomes"].items()}
        self.assertEqual(outs[self.u[1].id], "ok")
        self.assertEqual(outs[self.u[2].id], "not_contact")
        room = CallRoom.objects.get()
        self.assertEqual(room.group_id, self.g.id)
        self.assertEqual(self.state_of(body, 1), "ringing")
        self.assertEqual(len(self.rt(1, "call.incoming")), 1)

    def test_join_ongoing_group_call_from_the_chat(self):
        body = self.start(ids=(1,))
        ring = next(l["call_id"] for l in body["links"])
        self.ev(1, ring, "answer")
        # C sees "Join call" in the group chat
        act = self.cl[2].get(f"{V}/circle/groups/{self.g.id}/call/active").json()
        self.assertIsNotNone(act["room"])
        # A's ring list = group members who are A's accepted contacts
        rl = self.cl[0].get(f"{V}/circle/groups/{self.g.id}/call/active").json()
        self.assertEqual(rl["ringable"], [self.u[1].id, self.u[3].id])
        self.assertEqual(rl["max"], 4)
        room_id = act["room"]["room_id"]
        self.assertEqual(act["room"]["joined"], 2)
        r = self.cl[2].post(f"{V}/circle/rooms/{room_id}/join")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j["my_state"], "joined")
        self.assertIn("ice", j)
        # the joiner offers to everyone already in the call
        peers = {l["peer_user_id"]: l["role"] for l in j["links"]}
        self.assertEqual(peers, {self.u[0].id: "caller", self.u[1].id: "caller"})
        # joining again is idempotent
        r = self.cl[2].post(f"{V}/circle/rooms/{room_id}/join")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(CallRecord.objects.filter(room_link__via="mesh").count(), 2)
        # someone outside the group can't see or join it
        self.assertEqual(self.cl[4].get(
            f"{V}/circle/groups/{self.g.id}/call/active").status_code, 404)
        self.assertEqual(self.cl[4].post(
            f"{V}/circle/rooms/{room_id}/join").status_code, 404)

    def test_join_is_capped_at_four(self):
        CircleGroupMember.objects.create(group=self.g, member=self.u[4])
        body = self.start(ids=(1,))
        ring = next(l["call_id"] for l in body["links"])
        self.ev(1, ring, "answer")
        room_id = body["room_id"]
        self.assertEqual(self.cl[2].post(
            f"{V}/circle/rooms/{room_id}/join").status_code, 200)
        self.assertEqual(self.cl[3].post(
            f"{V}/circle/rooms/{room_id}/join").status_code, 200)
        r = self.cl[4].post(f"{V}/circle/rooms/{room_id}/join")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["code"], "full")

    def test_second_start_returns_the_ongoing_call(self):
        self.start(ids=(1,))
        r = self.cl[3].post(f"{V}/circle/groups/{self.g.id}/call/start",
                            {"kind": "voice", "user_ids": []}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["existing"])
        self.assertEqual(CallRoom.objects.count(), 1)

    def test_nobody_reachable_ends_the_room(self):
        body = self.start(ids=(2,), status=409)
        self.assertEqual(body["code"], "no_one")
        self.assertEqual(CallRoom.objects.get().state, "ended")
        act = self.cl[0].get(f"{V}/circle/groups/{self.g.id}/call/active").json()
        self.assertIsNone(act["room"])

    def test_no_answer_ends_a_group_call_nobody_joined(self):
        body = self.start(ids=(1,))
        ring = next(l["call_id"] for l in body["links"])
        self.ev(1, ring, "decline")
        room = CallRoom.objects.get()
        self.assertEqual(room.state, "ended")
        self.assertEqual(self.state_of(self.last_roster(0), 1), "declined")


class GroupInvitePushTests(_Room, _PushBase):
    """With FCM: the added person's phone gets the normal ring push."""

    def setUp(self):
        super().setUp()
        self.mk(3)
        Device.objects.create(user=self.u[2], push_token="cdev")

    def test_invite_sends_the_ring_push(self):
        cid = self.call(0, 1)
        self.fake.calls.clear()
        ring = self.add(0, cid, 2)["invited"]["call_id"]
        rings = [p["message"] for p in self.fake.sent_payloads()
                 if p["message"]["data"].get("kind") == "call"]
        self.assertEqual(len(rings), 1)
        self.assertEqual(rings[0]["token"], "cdev")
        self.assertEqual(str(rings[0]["data"]["call_id"]), str(ring))
        self.assertEqual(rings[0]["data"]["caller_name"], "Rahim")


class PureRuleTests(TestCase):
    def test_rules(self):
        self.assertTrue(R.has_seat(["joined", "joined", "ringing"]))
        self.assertFalse(R.has_seat(["joined"] * 4))
        self.assertTrue(R.has_seat(["joined"] * 3 + ["left", "declined"]))
        self.assertEqual(R.ring_outcome("no_answer"), "missed")
        self.assertEqual(R.ring_outcome("declined"), "declined")
        self.assertTrue(R.should_end(["joined", "declined"]))
        self.assertFalse(R.should_end(["joined", "ringing"]))
        self.assertFalse(R.should_end(["joined", "joined", "left"]))
        self.assertEqual(R.mesh_pairs(9, [1, 2, 9], {1}), [(9, 2)])
        self.assertEqual(R.join_verdict(room_live=True, my_state="ringing",
                                        allowed=True,
                                        states=["joined"] * 3 + ["ringing"]),
                         "ok")
        self.assertEqual(R.join_verdict(room_live=True, my_state="",
                                        allowed=True, states=["joined"] * 4),
                         "full")
        self.assertFalse(R.low_bandwidth(2))
        self.assertTrue(R.low_bandwidth(3))
