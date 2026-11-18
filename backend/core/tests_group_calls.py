"""group-calls — My Circle group calls (mesh, up to 8 people).

Covers the owner's test list: add a person to an audio and to a video call,
group ring from a group chat (FCM full-screen ring with the app closed),
late join, leave and the call goes on (the last two keep talking), the limit
of 8 with the Bangla message, a blocked person can never be added (either
direction, and not even by someone else in the call), and signalling for
EVERY participant pair reaches the right phone in both directions.

Push HTTP is faked (no network); TURN is off. Sample people are made up.
"""
from datetime import timedelta

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core.logic import group_call as GC
from core.models import (CallRecord, CircleGroup, CircleGroupMember,
                         CircleMember, Device, GroupCall, GroupCallMember,
                         RtEvent, RtPresence, User)
from core.tests_push import _PushBase

V = "/api/v1"
NAMES = ["Amina", "Babu", "Chaya", "Dipu", "Eti", "Fahim", "Gita", "Hasan",
         "Ira", "Jamil"]


class _Crowd:
    def mk(self, n=4, lang="en"):
        self.u, self.c = [], []
        for i in range(n):
            u = User.objects.create_user(
                name=NAMES[i], phone="0174100%04d" % i, password="pw12345!",
                language=lang)
            cl = APIClient()
            cl.force_authenticate(u)
            self.u.append(u)
            self.c.append(cl)
        # everyone is in everyone's circle (accepted both ways)
        for a in self.u:
            for b in self.u:
                if a.pk != b.pk:
                    CircleMember.objects.create(
                        user=a, peer_user=b, name=b.name, state="accepted",
                        phone=b.phone)

    def online(self, *idx):
        for i in idx:
            RtPresence.objects.update_or_create(
                user=self.u[i], defaults={"seen_at": timezone.now()})

    def edge(self, a, b):
        return CircleMember.objects.get(user=self.u[a], peer_user=self.u[b])

    def call(self, a, b, kind="voice"):
        """a -> b 1:1 call, answered and connected."""
        self.online(b)
        r = self.c[a].post(f"{V}/circle/{self.edge(a, b).id}/call",
                           {"kind": kind}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        cid = r.json()["call_id"]
        self.ev(b, cid, "ringing")
        self.ev(b, cid, "answer")
        self.ev(a, cid, "connected")
        return cid

    def ev(self, i, cid, event):
        r = self.c[i].post(f"{V}/circle/calls/{cid}/event", {"event": event},
                           format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def topics(self, i, topic):
        return [e.payload for e in RtEvent.objects.filter(
            user=self.u[i], topic=topic).order_by("id")]

    def snap(self, i, room):
        r = self.c[i].get(f"{V}/circle/group-calls/{room}")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def join(self, i, room, **body):
        return self.c[i].post(f"{V}/circle/group-calls/{room}/join", body,
                              format="json")

    def states(self, room):
        return {m.user.name: m.state for m in GroupCallMember.objects.filter(
            room_id=room).select_related("user")}

    def premium(self, i):
        u = self.u[i]
        u.plan = "premium"
        u.plan_until = timezone.now() + timedelta(days=30)
        u.save()

    def assert_all_pairs_signal(self, room, idx):
        """Every pair has exactly one live leg, and an offer / answer / ICE
        sent on it reaches ONLY the other person of that pair (both ways)."""
        legs = {}
        for i in idx:
            for leg in self.snap(i, room)["legs"]:
                legs.setdefault(leg["call_id"], set()).add(i)
        pairs = {frozenset(v) for v in legs.values()}
        want = {frozenset((a, b)) for a in idx for b in idx if a < b}
        self.assertEqual(pairs, want)
        for cid, ends in legs.items():
            a, b = sorted(ends)
            for frm, to in ((a, b), (b, a)):
                before = len(self.topics(to, "call.signal"))
                r = self.c[frm].post(f"{V}/rt/send", {
                    "topic": "call.signal", "payload": {
                        "call_id": cid, "kind": "ice",
                        "data": {"candidate": "c-%s-%s" % (frm, to)}}},
                    format="json")
                self.assertEqual(r.status_code, 201, r.content)
                got = self.topics(to, "call.signal")
                self.assertEqual(len(got), before + 1)
                self.assertEqual(got[-1]["call_id"], cid)
                for other in idx:
                    if other not in (frm, to):
                        self.assertFalse(any(
                            p["data"].get("candidate") == "c-%s-%s" % (frm, to)
                            for p in self.topics(other, "call.signal")))


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="", CALLS_FREE_TESTING_DEFAULT=False)
class GroupCallTests(_Crowd, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk(4)

    # ---- add person during a 1:1 call -------------------------------------
    def test_add_person_to_audio_call_then_every_pair_talks(self):
        cid = self.call(0, 1)
        self.online(2)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"from_call_id": cid, "user_ids": [self.u[2].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        body = r.json()
        room = body["room_id"]
        self.assertTrue(body["results"][0]["ok"])
        self.assertEqual(self.states(room),
                         {"Amina": "joined", "Babu": "joined",
                          "Chaya": "ringing"})
        self.assertEqual(CallRecord.objects.get(pk=cid).room_id, room)
        # B's phone learns its 1:1 call became a group call
        up = self.topics(1, "group.upgrade")
        self.assertEqual(up[-1], {"call_id": cid, "room_id": room})
        # C gets a NORMAL ring that names the room
        inc = self.topics(2, "call.incoming")
        self.assertEqual(inc[-1]["room_id"], room)
        self.assertEqual(inc[-1]["caller_name"], "Amina")
        # C answers from the ring -> joins, offers to B on a new leg
        r = self.join(2, room, call_id=inc[-1]["call_id"])
        self.assertEqual(r.status_code, 200, r.content)
        legs = r.json()["legs"]
        self.assertEqual(len(legs), 2)
        by_peer = {l["peer_id"]: l for l in legs}
        self.assertFalse(by_peer[self.u[0].pk]["offerer"])  # A rang C
        self.assertTrue(by_peer[self.u[1].pk]["offerer"])   # C is new
        self.assertEqual(self.topics(1, "group.leg")[-1]["peer_id"],
                         self.u[2].pk)
        self.assertEqual(set(self.states(room).values()), {"joined"})
        self.assert_all_pairs_signal(room, [0, 1, 2])
        # the extra leg is not a "call" in B's or C's history
        hist = self.c[1].get(f"{V}/circle/calls").json()["calls"]
        self.assertEqual(len(hist), 1)

    def test_add_person_to_video_needs_premium_of_the_adder(self):
        cid = self.call(0, 1, "voice")
        CallRecord.objects.filter(pk=cid).update(kind="video")
        self.online(2)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"from_call_id": cid, "user_ids": [self.u[2].pk]},
                           format="json")
        self.assertEqual(r.status_code, 402, r.content)
        self.assertEqual(r.json()["code"], "upgrade_required")
        self.premium(0)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"from_call_id": cid, "user_ids": [self.u[2].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["kind"], "video")
        ring = CallRecord.objects.get(pk=r.json()["results"][0]["call_id"])
        self.assertEqual(ring.kind, "video")
        # a FREE person can answer and join the video call
        r = self.join(2, r.json()["room_id"])
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(len(r.json()["legs"]), 2)

    def test_audio_group_call_is_free_for_everyone(self):
        self.online(1, 2)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"kind": "voice",
                            "user_ids": [self.u[1].pk, self.u[2].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(all(x["ok"] for x in r.json()["results"]))
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"kind": "video", "user_ids": [self.u[3].pk]},
                           format="json")
        self.assertEqual(r.status_code, 402, r.content)

    # ---- blocks + circle --------------------------------------------------
    def test_blocked_person_can_never_be_added(self):
        cid = self.call(0, 1)
        self.online(2, 3)
        # A blocked C
        CircleMember.objects.filter(user=self.u[0], peer_user=self.u[2]) \
            .update(blocked=True)
        # D blocked B (someone ELSE already in the call)
        CircleMember.objects.filter(user=self.u[3], peer_user=self.u[1]) \
            .update(blocked=True)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"from_call_id": cid,
                            "user_ids": [self.u[2].pk, self.u[3].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        res = {x["user_id"]: x for x in r.json()["results"]}
        self.assertFalse(res[self.u[2].pk]["ok"])
        self.assertFalse(res[self.u[3].pk]["ok"])
        self.assertEqual(res[self.u[3].pk]["code"], "unavailable")
        self.assertEqual(self.topics(2, "call.incoming"), [])
        self.assertEqual(self.topics(3, "call.incoming"), [])
        room = r.json()["room_id"]
        # the picker never lists them
        people = self.c[0].get(
            f"{V}/circle/group-calls/candidates?room={room}").json()["people"]
        ids = {p["user_id"] for p in people}
        self.assertNotIn(self.u[2].pk, ids)
        self.assertNotIn(self.u[3].pk, ids)
        # B (also in the call) can't add D either: D blocked B
        r = self.c[1].post(f"{V}/circle/group-calls/{room}/invite",
                           {"user_ids": [self.u[3].pk]}, format="json")
        self.assertFalse(r.json()["results"][0]["ok"])
        # and D can't push in by joining
        r = self.join(3, room)
        self.assertIn(r.status_code, (403, 404))

    def test_only_my_circle_can_be_added(self):
        stranger = User.objects.create_user(name="Kona", phone="01741009999",
                                            password="pw12345!")
        RtPresence.objects.create(user=stranger, seen_at=timezone.now())
        cid = self.call(0, 1)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"from_call_id": cid, "user_ids": [stranger.pk]},
                           format="json")
        self.assertEqual(r.json()["results"][0]["code"], "not_in_circle")
        self.assertFalse(CallRecord.objects.filter(callee=stranger).exists())

    # ---- leave + continue -------------------------------------------------
    def test_leave_and_the_last_two_continue(self):
        cid = self.call(0, 1)
        self.online(2)
        room = self.c[0].post(f"{V}/circle/group-calls",
                              {"from_call_id": cid,
                               "user_ids": [self.u[2].pk]},
                              format="json").json()["room_id"]
        self.join(2, room)
        # A (the host) leaves -> B and C keep their leg
        r = self.c[0].post(f"{V}/circle/group-calls/{room}/leave")
        self.assertEqual(r.json()["room_state"], "live")
        self.online(1, 2)
        snap_b = self.snap(1, room)
        self.assertEqual(len(snap_b["legs"]), 1)
        self.assertEqual(snap_b["legs"][0]["peer_id"], self.u[2].pk)
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "ended")
        self.assertEqual(self.states(room)["Amina"], "left")
        # C leaves -> only B is left -> the call ends for everyone
        r = self.c[2].post(f"{V}/circle/group-calls/{room}/leave")
        self.assertEqual(r.json()["room_state"], "ended")
        self.assertFalse(CallRecord.objects.filter(
            room_id=room, state__in=("ringing", "connecting", "active")).exists())
        self.assertTrue(self.topics(1, "group.state")[-1].get("ended"))

    def test_rejoin_after_leaving_and_repair_is_idempotent(self):
        cid = self.call(0, 1)
        self.online(2)
        room = self.c[0].post(f"{V}/circle/group-calls",
                              {"from_call_id": cid,
                               "user_ids": [self.u[2].pk]},
                              format="json").json()["room_id"]
        self.join(2, room)
        n = CallRecord.objects.filter(room_id=room).count()
        self.join(2, room)   # repair: nothing new
        self.assertEqual(CallRecord.objects.filter(room_id=room).count(), n)
        self.c[2].post(f"{V}/circle/group-calls/{room}/leave")
        r = self.join(2, room)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(len(r.json()["legs"]), 2)

    # ---- busy: a group call is "another call" ------------------------------
    def test_in_a_group_call_means_busy_for_a_1to1_call(self):
        cid = self.call(0, 1)
        self.online(2)
        room = self.c[0].post(f"{V}/circle/group-calls",
                              {"from_call_id": cid,
                               "user_ids": [self.u[2].pk]},
                              format="json").json()["room_id"]
        self.online(0, 1, 3)
        # D calls B 1:1 while B is in the group call -> busy, never rings
        r = self.c[3].post(f"{V}/circle/{self.edge(3, 1).id}/call",
                           {"kind": "voice"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["end_reason"], "busy")
        rec = CallRecord.objects.get(pk=r.json()["call_id"])
        self.assertEqual(rec.state, "missed")
        self.assertFalse(any(p.get("call_id") == rec.id
                             for p in self.topics(1, "call.incoming")))
        # a host alone while the others still ring is busy too
        self.c[1].post(f"{V}/circle/group-calls/{room}/leave")
        self.c[0].post(f"{V}/circle/group-calls/{room}/leave")
        self.online(0, 1, 2, 3)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"kind": "voice", "user_ids": [self.u[2].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        r = self.c[3].post(f"{V}/circle/{self.edge(3, 0).id}/call",
                           {"kind": "voice"}, format="json")
        self.assertEqual(r.json()["end_reason"], "busy")

    def test_ring_into_a_group_call_for_someone_in_another_is_busy(self):
        cid = self.call(0, 1)          # A and B: a 1:1 that becomes a room
        self.online(2)
        self.c[0].post(f"{V}/circle/group-calls",
                       {"from_call_id": cid, "user_ids": [self.u[2].pk]},
                       format="json")
        self.online(0, 1, 2, 3)
        # D starts their own group call and rings B (in the other call)
        r = self.c[3].post(f"{V}/circle/group-calls",
                           {"kind": "voice", "user_ids": [self.u[1].pk]},
                           format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["results"][0]["code"], "busy")

    # ---- group chat call + late join -------------------------------------
    def _group(self, n):
        g = CircleGroup.objects.create(creator=self.u[0], name="Family")
        for i in range(n):
            CircleGroupMember.objects.create(
                group=g, member=self.u[i],
                role="admin" if i == 0 else "member")
        return g

    def test_group_chat_rings_all_then_late_join_bar(self):
        g = self._group(4)
        self.online(1, 2, 3)
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"group_id": g.id, "kind": "voice"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        room = r.json()["room_id"]
        for i in (1, 2, 3):
            self.assertEqual(self.topics(i, "call.incoming")[-1]["room_id"],
                             room)
        # B answers, C declines, D doesn't answer yet
        self.join(1, room)
        ring_c = GroupCallMember.objects.get(room_id=room, user=self.u[2])
        self.ev(2, ring_c.ring_call_id, "decline")
        live = self.c[2].get(f"{V}/circle/group-calls/group/{g.id}").json()
        self.assertEqual(live["call"]["room_id"], room)
        self.assertEqual(live["call"]["joined"], 2)
        self.assertEqual(live["call"]["my_state"], "declined")
        # C changes her mind -> joins late from the bar
        r = self.join(2, room)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(len(r.json()["legs"]), 2)
        self.join(3, room)
        self.assert_all_pairs_signal(room, [0, 1, 2, 3])
        # a second tap on the group's call button joins the SAME call
        r = self.c[1].post(f"{V}/circle/group-calls",
                           {"group_id": g.id, "kind": "voice"}, format="json")
        self.assertEqual(r.json()["room_id"], room)
        # someone outside the group sees nothing
        outsider = User.objects.create_user(name="Lina", phone="01741008888",
                                            password="pw12345!")
        cl = APIClient()
        cl.force_authenticate(outsider)
        self.assertEqual(cl.get(f"{V}/circle/group-calls/group/{g.id}")
                         .status_code, 404)
        self.assertEqual(cl.post(f"{V}/circle/group-calls/{room}/join")
                         .status_code, 404)

    def test_no_live_call_bar_when_quiet(self):
        g = self._group(3)
        r = self.c[1].get(f"{V}/circle/group-calls/group/{g.id}")
        self.assertEqual(r.json(), {"call": None})


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="", CALLS_FREE_TESTING_DEFAULT=False)
class GroupLimitTests(_Crowd, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk(10, lang="bn")

    def test_limit_8_with_bangla_message(self):
        self.online(*range(10))
        ids = [u.pk for u in self.u[1:]]   # 9 people asked, 7 places
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"kind": "voice", "user_ids": ids}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        res = r.json()["results"]
        self.assertEqual(sum(1 for x in res if x["ok"]), 7)
        self.assertEqual([x["code"] for x in res if not x["ok"]],
                         ["full", "full"])
        room = r.json()["room_id"]
        self.assertEqual(r.json()["seats_taken"], 8)
        self.assertEqual(r.json()["full_message"], GC.FULL_BN)
        r = self.c[0].post(f"{V}/circle/group-calls/{room}/invite",
                           {"user_ids": [self.u[9].pk]}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["detail"], GC.FULL_BN)
        self.assertEqual(r.json()["max"], 8)


class GroupRingPushTests(_Crowd, _PushBase):
    """App CLOSED: the ring into a group call is the same high-priority FCM
    data ring as a 1:1 call (full-screen on the phone), carrying room_id."""

    def setUp(self):
        super().setUp()
        self.mk(3)
        Device.objects.create(user=self.u[1], push_token="bdev")
        Device.objects.create(user=self.u[2], push_token="cdev")

    def test_group_ring_reaches_closed_apps_by_fcm(self):
        g = CircleGroup.objects.create(creator=self.u[0], name="Family")
        for i in range(3):
            CircleGroupMember.objects.create(group=g, member=self.u[i])
        # B is NOT in A's circle: a group-chat call still rings B
        CircleMember.objects.filter(user=self.u[0], peer_user=self.u[1]) \
            .delete()
        r = self.c[0].post(f"{V}/circle/group-calls",
                           {"group_id": g.id, "kind": "voice"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        room = r.json()["room_id"]
        rings = [p["message"] for p in self.fake.sent_payloads()
                 if p["message"]["data"].get("kind") == "call"]
        self.assertEqual({m["token"] for m in rings}, {"bdev", "cdev"})
        for m in rings:
            self.assertEqual(str(m["data"]["room_id"]), str(room))
            self.assertEqual(m["android"]["priority"], "HIGH")
        self.assertEqual(GroupCall.objects.get(pk=room).state, "live")

    def test_busy_in_a_group_call_leaves_a_missed_call_notice(self):
        # A and B in a group call (joined, polling); C (has a phone) calls B
        CircleMember.objects.get_or_create(
            user=self.u[2], peer_user=self.u[1],
            defaults={"name": "Babu", "state": "accepted"})
        g = GroupCall.objects.create(host=self.u[0])
        for i in (0, 1):
            GroupCallMember.objects.create(room=g, user=self.u[i],
                                           state="joined",
                                           joined_at=timezone.now())
            RtPresence.objects.update_or_create(
                user=self.u[i], defaults={"seen_at": timezone.now()})
        edge = CircleMember.objects.get(user=self.u[2], peer_user=self.u[1])
        self.fake.calls.clear()
        r = self.c[2].post(f"{V}/circle/{edge.id}/call", {"kind": "voice"},
                           format="json")
        self.assertEqual(r.json()["end_reason"], "busy")
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertNotIn("call", kinds)          # never rang B
        missed = [p["message"] for p in self.fake.sent_payloads()
                  if p["message"]["data"]["kind"] == "missed_call"]
        self.assertEqual(len(missed), 1)
        self.assertEqual(missed[0]["data"]["reason"], "busy")
