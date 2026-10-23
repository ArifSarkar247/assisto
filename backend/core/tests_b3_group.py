"""b3-group — group calls on the self-hosted LiveKit SFU + consented
recording (B5).

Covers: the minimal HS256 JWT (claims, expiry, signature), the token
endpoint's membership rules (1:1 parties being upgraded, invitees, circle
group members; outsiders / removed / full refused), everything hidden + 503
when LiveKit is not configured, the "Free calls (testing)" switch + video
plan gate, host-only mute / remove through LiveKit's RoomService (faked),
join/leave records + SFU cost metering math, the LiveKit webhook signature,
and the consent state machine (1:1 and group).
"""
import base64
import hashlib
import json
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core import views_b3_group_calls as B3
from core.logic import sfu as SFU
from core.models import (CallRecord, CircleGroup, CircleGroupMember,
                         CircleMember, GroupCallParticipant, GroupCallRoom,
                         RtEvent, SfuConfig, User)
from core.tests_b1_calls import _Live
from core.tests_c2_calls import V

LK = dict(LIVEKIT_URL="wss://api.example.test/livekit",
          LIVEKIT_HTTP_URL="http://127.0.0.1:7880",
          LIVEKIT_API_KEY="APIkeyTEST", LIVEKIT_API_SECRET="s3cret-for-tests-only",
          FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True, TURN_STATIC_SECRET="",
          CALLS_FREE_TESTING_DEFAULT=False)


def _events(user, topic):
    return [e.payload for e in RtEvent.objects.filter(user=user, topic=topic)
            .order_by("id")]


class JwtTests(TestCase):
    def test_access_token_claims(self):
        tok = SFU.access_token("K", "S", identity=7, name="Nadia", room="gc-1",
                               now_ts=1_000_000, host=True,
                               metadata={"role": "host"})
        c = SFU.jwt_decode(tok, "S", now_ts=1_000_000)
        self.assertEqual(c["iss"], "K")
        self.assertEqual(c["sub"], "7")
        self.assertEqual(c["name"], "Nadia")
        self.assertEqual(c["exp"], 1_000_000 + SFU.TOKEN_TTL_S)
        self.assertLessEqual(c["nbf"], 1_000_000)
        self.assertEqual(c["video"], {"room": "gc-1", "roomJoin": True,
                                      "canPublish": True, "canSubscribe": True,
                                      "canPublishData": True, "roomAdmin": True})
        self.assertEqual(json.loads(c["metadata"]), {"role": "host"})
        # a member gets no roomAdmin
        m = SFU.jwt_decode(SFU.access_token("K", "S", identity=8, name="B",
                                            room="gc-1", now_ts=1_000_000), "S")
        self.assertNotIn("roomAdmin", m["video"])

    def test_signature_and_expiry_are_checked(self):
        tok = SFU.access_token("K", "S", identity=1, name="", room="r",
                               now_ts=1000, ttl=60)
        with self.assertRaises(SFU.TokenError):
            SFU.jwt_decode(tok, "other-secret")
        with self.assertRaises(SFU.TokenError):
            SFU.jwt_decode(tok, "S", now_ts=1000 + 60 + 11)  # past exp + leeway
        SFU.jwt_decode(tok, "S", now_ts=1000 + 60)           # still valid
        h, p, s = tok.split(".")
        forged = json.loads(base64.urlsafe_b64decode(p + "=="))
        forged["video"]["roomAdmin"] = True
        p2 = base64.urlsafe_b64encode(json.dumps(forged).encode()).rstrip(b"=").decode()
        with self.assertRaises(SFU.TokenError):
            SFU.jwt_decode(f"{h}.{p2}.{s}", "S")
        # alg=none is refused
        none_h = base64.urlsafe_b64encode(b'{"alg":"none"}').rstrip(b"=").decode()
        with self.assertRaises(SFU.TokenError):
            SFU.jwt_decode(f"{none_h}.{p}.{s}", "S")

    def test_admin_token_and_webhook_body(self):
        c = SFU.jwt_decode(SFU.admin_token("K", "S", "gc-1", 500), "S", now_ts=500)
        self.assertTrue(c["video"]["roomAdmin"])
        self.assertEqual(c["video"]["room"], "gc-1")
        body = b'{"event":"room_started"}'
        sha = base64.b64encode(hashlib.sha256(body).digest()).decode()
        self.assertTrue(SFU.webhook_body_ok({"sha256": sha}, body))
        self.assertFalse(SFU.webhook_body_ok({"sha256": sha}, body + b" "))
        self.assertFalse(SFU.webhook_body_ok({}, body))
        self.assertEqual(SFU.http_base("wss://a.b/livekit"), "https://a.b/livekit")


class CostMathTests(TestCase):
    def test_stream_rates(self):
        self.assertEqual(SFU.stream_rates(1, 1), (0, 0))   # alone: nothing sent
        self.assertEqual(SFU.stream_rates(3, 0), (6, 0))   # 3 x 2 audio
        self.assertEqual(SFU.stream_rates(3, 2), (6, 4))   # 2 cameras x 2 viewers
        self.assertEqual(SFU.stream_rates(8, 8), (56, 56))

    def test_egress_and_bdt(self):
        a, v = SFU.tick(0, 0, 3, 3, 60)          # 3 people, all video, 1 min
        self.assertEqual((a, v), (360, 360))
        b = SFU.egress_bytes(a, v, 40, 600)
        # (360 x 40 + 360 x 600) kbit -> bytes
        self.assertAlmostEqual(b, (360 * 40 + 360 * 600) * 1000 / 8)
        self.assertAlmostEqual(SFU.bdt_for_bytes(SFU.GIB, 13.0), 13.0)
        # one person-minute of a 3-person voice call = 2 x 40 kbit/s x 60 s
        self.assertAlmostEqual(
            SFU.per_participant_minute_bdt(3, False, 40, 600, 13.0),
            (2 * 40 * 1000 / 8 * 60) / SFU.GIB * 13.0)

    def test_clamp_max(self):
        self.assertEqual(SFU.clamp_max(8), 8)
        self.assertEqual(SFU.clamp_max(1), 3)
        self.assertEqual(SFU.clamp_max(99), SFU.HARD_MAX_PARTICIPANTS)
        self.assertEqual(SFU.clamp_max("x"), SFU.DEFAULT_MAX_PARTICIPANTS)


class ConsentMachineTests(TestCase):
    def test_all_must_accept(self):
        st = SFU.consent_new(1, 1, [1, 2, 3])
        self.assertEqual(st["status"], "pending")
        self.assertFalse(SFU.consent_may_record(st))
        st = SFU.consent_accept(st, 2, [1, 2, 3])
        self.assertEqual(st["status"], "pending")
        st = SFU.consent_accept(st, 3, [1, 2, 3], "t1")
        self.assertEqual(st["status"], "recording")
        self.assertTrue(SFU.consent_may_record(st))
        self.assertEqual(st["started_at"], "t1")
        v = SFU.consent_view(st, 1)
        self.assertTrue(v["i_record"])
        self.assertFalse(SFU.consent_view(st, 2)["i_record"])

    def test_one_decline_blocks_and_is_final(self):
        st = SFU.consent_new(1, 1, [1, 2, 3])
        st = SFU.consent_accept(st, 2, [1, 2, 3])
        st = SFU.consent_decline(st, 3)
        self.assertEqual(st["status"], "declined")
        self.assertEqual(st["declined_by"], 3)
        st = SFU.consent_accept(st, 3, [1, 2, 3])
        self.assertEqual(st["status"], "declined")   # terminal

    def test_new_joiner_pauses_until_they_accept(self):
        st = SFU.consent_new(1, 1, [1, 2])
        st = SFU.consent_accept(st, 2, [1, 2])
        self.assertEqual(st["status"], "recording")
        st = SFU.consent_eval(st, [1, 2, 4])        # 4 joins
        self.assertEqual(st["status"], "paused")
        self.assertTrue(SFU.consent_view(st, 4)["i_must_answer"])
        st = SFU.consent_accept(st, 4, [1, 2, 4])
        self.assertEqual(st["status"], "recording")
        # someone leaving never stops it
        st = SFU.consent_eval(st, [1, 4])
        self.assertEqual(st["status"], "recording")

    def test_requester_alone_never_records_and_stop(self):
        st = SFU.consent_new(1, 1, [1])
        self.assertEqual(st["status"], "pending")
        st = SFU.consent_stop(SFU.consent_new(1, 1, [1, 2]), 2)
        self.assertEqual(st["status"], "stopped")


class _Group(_Live):
    def mk3(self):
        # never talk to a real LiveKit from tests (DeleteRoom on room end)
        patcher = mock.patch.object(B3, "_http_post", return_value={})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.mk()
        self.c = User.objects.create_user(name="Chompa", phone="01740000103",
                                          password="pw12345!", language="en")
        self.d = User.objects.create_user(name="Dipu", phone="01740000104",
                                          password="pw12345!", language="en")
        self.ac = CircleMember.objects.create(
            user=self.a, peer_user=self.c, name="Chompa", state="accepted",
            phone="01740000103")
        self.ad = CircleMember.objects.create(
            user=self.a, peer_user=self.d, name="Dipu", state="accepted",
            phone="01740000104")
        self.cc = APIClient()
        self.cc.force_authenticate(self.c)
        self.cd = APIClient()
        self.cd.force_authenticate(self.d)
        self.outsider = User.objects.create_user(name="Out", phone="01740000199",
                                                 password="pw12345!")
        self.co = APIClient()
        self.co.force_authenticate(self.outsider)

    def upgrade(self, invite=None):
        cid = self.live_call("voice")
        r = self.ca.post(f"{V}/circle/calls/group/start",
                         {"call_id": cid, "member_ids": invite or [self.ac.id]},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return cid, r.json()

    def ev(self, client, room, event, **extra):   # noqa: D102 (group event)
        if isinstance(room, int):
            return super().ev(client, room, event, **extra)
        r = client.post(f"{V}/circle/calls/group/{room}/event",
                        {"event": event, **extra}, format="json")
        return r


@override_settings(**{**LK, "LIVEKIT_URL": "", "LIVEKIT_API_KEY": "",
                      "LIVEKIT_API_SECRET": ""})
class NotConfiguredTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()

    def test_hidden_and_refused_when_livekit_not_installed(self):
        r = self.ca.get(f"{V}/circle/calls/group/config").json()
        self.assertFalse(r["available"])
        self.assertEqual(r["max_participants"], 0)
        cid = self.live_call("voice")
        r = self.ca.post(f"{V}/circle/calls/group/start",
                         {"call_id": cid, "member_ids": [self.ac.id]}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["code"], "sfu_unavailable")
        self.assertEqual(self.ca.post(f"{V}/circle/calls/group/x/token").status_code, 503)
        self.assertEqual(self.ca.get(f"{V}/circle/calls/group/incoming").json(),
                         {"rooms": []})
        self.assertEqual(GroupCallRoom.objects.count(), 0)


@override_settings(**LK)
class OwnerSwitchTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()

    def test_owner_switch_off_hides(self):
        self.assertTrue(self.ca.get(f"{V}/circle/calls/group/config").json()["available"])
        c = SfuConfig.load()
        c.enabled = False
        c.save()
        self.assertFalse(self.ca.get(f"{V}/circle/calls/group/config").json()["available"])

    def test_max_participants_admin_editable(self):
        self.assertEqual(self.ca.get(f"{V}/circle/calls/group/config")
                         .json()["max_participants"], 8)
        c = SfuConfig.load()
        c.max_participants = 3
        c.save()
        cid = self.live_call("voice")
        r = self.ca.post(f"{V}/circle/calls/group/start",
                         {"call_id": cid, "member_ids": [self.ac.id, self.ad.id]},
                         format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["code"], "too_many")


@override_settings(**LK)
class UpgradeAndTokenTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()

    def test_add_person_moves_both_and_rings_invitee(self):
        cid, body = self.upgrade()
        room = body["room"]
        self.assertTrue(body["is_host"])
        self.assertEqual(body["source"], "upgrade")
        # B (the other 1:1 phone) is told to move to the room
        mv = [p for p in _events(self.b, "call.signal") if p["kind"] == "sfu_move"]
        self.assertEqual(len(mv), 1)
        self.assertEqual(mv[0]["data"]["room"], room)
        self.assertEqual(mv[0]["call_id"], cid)
        # C rings (real-time queue) and sees it in incoming
        inc = _events(self.c, "call.group_incoming")
        self.assertEqual(inc[0]["room"], room)
        self.assertEqual(inc[0]["host_name"], "Amina")
        self.assertEqual([x["room"] for x in self.cc.get(
            f"{V}/circle/calls/group/incoming").json()["rooms"]], [room])
        # A's own join token came back with the start
        c = SFU.jwt_decode(body["join"]["token"], LK["LIVEKIT_API_SECRET"],
                           now_ts=timezone.now().timestamp())
        self.assertEqual(c["sub"], str(self.a.id))
        self.assertEqual(c["video"]["room"], room)
        self.assertTrue(c["video"]["roomAdmin"])
        self.assertEqual(body["join"]["url"], LK["LIVEKIT_URL"])

    def test_publish_sources_follow_the_plan(self):
        cid, body = self.upgrade()
        c = SFU.jwt_decode(body["join"]["token"], LK["LIVEKIT_API_SECRET"])
        # voice room, free plan: the SFU lets them publish the mic only
        self.assertEqual(c["video"]["canPublishSources"], ["microphone"])
        self.assertFalse(body["join"]["screen_share"])
        with override_settings(CALLS_FREE_TESTING_DEFAULT=True):
            r = self.cb.post(f"{V}/circle/calls/group/{body['room']}/token").json()
            c = SFU.jwt_decode(r["token"], LK["LIVEKIT_API_SECRET"])
            self.assertIn("screen_share", c["video"]["canPublishSources"])
            self.assertTrue(r["screen_share"])

    def test_token_only_for_members(self):
        cid, body = self.upgrade()
        room = body["room"]
        for client, ident in ((self.cb, self.b), (self.cc, self.c)):
            r = client.post(f"{V}/circle/calls/group/{room}/token")
            self.assertEqual(r.status_code, 200, r.content)
            c = SFU.jwt_decode(r.json()["token"], LK["LIVEKIT_API_SECRET"])
            self.assertEqual(c["sub"], str(ident.id))
            self.assertNotIn("roomAdmin", c["video"])
        # D was not invited, the outsider is nobody: no token
        self.assertEqual(self.cd.post(f"{V}/circle/calls/group/{room}/token").status_code, 404)
        self.assertEqual(self.co.post(f"{V}/circle/calls/group/{room}/token").status_code, 404)
        self.assertEqual(self.co.get(f"{V}/circle/calls/group/{room}").status_code, 404)

    def test_joining_ends_the_p2p_call_and_records_participants(self):
        cid, body = self.upgrade()
        room = body["room"]
        self.assertEqual(self.ev(self.ca, room, "joined").status_code, 200)
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "ended")
        self.ev(self.cb, room, "joined")
        st = self.ev(self.cc, room, "joined").json()
        self.assertEqual(st["present"], 3)
        seats = {p["user_id"]: p["state"] for p in st["participants"]}
        self.assertEqual(seats, {self.a.id: "joined", self.b.id: "joined",
                                 self.c.id: "joined"})
        # leave + rejoin while the room lives
        self.ev(self.cc, room, "left")
        self.assertEqual(self.cc.post(f"{V}/circle/calls/group/{room}/token").status_code, 200)
        self.ev(self.cc, room, "joined")
        p = GroupCallParticipant.objects.get(room__name=room, user=self.c)
        self.assertEqual(p.joins, 2)
        # everyone leaves -> the room ends; tokens refused afterwards
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, room, "left")
        self.assertEqual(GroupCallRoom.objects.get(name=room).state, "ended")
        r = self.cb.post(f"{V}/circle/calls/group/{room}/token")
        self.assertEqual(r.status_code, 410)

    def test_room_full(self):
        c = SfuConfig.load()
        c.max_participants = 3
        c.save()
        cid, body = self.upgrade()
        room = body["room"]
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, room, "joined")
        # D gets invited by A but the room already holds 3
        GroupCallParticipant.objects.create(room=GroupCallRoom.objects.get(name=room),
                                            user=self.d, invited_by=self.a)
        r = self.cd.post(f"{V}/circle/calls/group/{room}/token")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["code"], "room_full")

    def test_invite_more_people_from_inside(self):
        cid, body = self.upgrade()
        room = body["room"]
        self.ev(self.ca, room, "joined")
        r = self.ca.post(f"{V}/circle/calls/group/{room}/invite",
                         {"member_ids": [self.ad.id]}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(_events(self.d, "call.group_incoming")[0]["room"], room)
        # an invite of someone not in MY circle does nothing
        r = self.ca.post(f"{V}/circle/calls/group/{room}/invite",
                         {"user_ids": [self.outsider.id]}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_free_calls_switch_and_video_gate_on_upgrade(self):
        self.a.plan = "premium"
        self.a.plan_until = timezone.now() + timedelta(days=30)
        self.a.save()
        cid = self.live_call("video")
        self.a.plan = "free"
        self.a.plan_until = None
        self.a.save()
        r = self.ca.post(f"{V}/circle/calls/group/start",
                         {"call_id": cid, "member_ids": [self.ac.id]}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["code"], "upgrade_required")
        with override_settings(CALLS_FREE_TESTING_DEFAULT=True):
            r = self.ca.post(f"{V}/circle/calls/group/start",
                             {"call_id": cid, "member_ids": [self.ac.id]},
                             format="json")
            self.assertEqual(r.status_code, 201, r.content)
            self.assertTrue(GroupCallRoom.objects.get(name=r.json()["room"]).free_testing)


@override_settings(**LK)
class GroupChatCallTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        for u, role in ((self.a, "admin"), (self.b, "member"), (self.c, "member")):
            CircleGroupMember.objects.create(group=self.g, member=u, role=role)

    def start(self, client, kind="voice"):
        return client.post(f"{V}/circle/calls/group/start",
                           {"group_id": self.g.id, "kind": kind}, format="json")

    def test_group_voice_call_rings_every_member(self):
        r = self.start(self.ca)
        self.assertEqual(r.status_code, 201, r.content)
        room = r.json()["room"]
        self.assertEqual(r.json()["group_name"], "Family")
        for u in (self.b, self.c):
            self.assertEqual(_events(u, "call.group_incoming")[0]["room"], room)
        self.assertEqual(_events(self.d, "call.group_incoming"), [])
        # a second "call" from the same group joins the live room
        self.ev(self.ca, room, "joined")
        r2 = self.start(self.cb)
        self.assertEqual(r2.json()["room"], room)
        # D is not in the group: refused
        self.assertEqual(self.start(self.cd).status_code, 404)
        self.assertEqual(self.cd.post(f"{V}/circle/calls/group/{room}/token").status_code, 404)

    def test_group_video_needs_premium_unless_free_calls(self):
        r = self.start(self.ca, "video")
        self.assertEqual(r.status_code, 402)
        self.assertTrue(r.json()["upgrade_required"])
        with override_settings(CALLS_FREE_TESTING_DEFAULT=True):
            r = self.start(self.ca, "video")
            self.assertEqual(r.status_code, 201, r.content)
            self.assertEqual(r.json()["kind"], "video")
        self.a.plan = "premium"
        self.a.plan_until = timezone.now() + timedelta(days=30)
        self.a.save()
        GroupCallRoom.objects.update(state="ended")
        self.assertEqual(self.start(self.ca, "video").status_code, 201)

    def test_decline(self):
        room = self.start(self.ca).json()["room"]
        self.assertEqual(self.ev(self.cb, room, "decline").status_code, 200)
        self.assertEqual(GroupCallParticipant.objects.get(
            room__name=room, user=self.b).state, "declined")
        self.assertEqual(self.cb.get(f"{V}/circle/calls/group/incoming").json()["rooms"], [])


@override_settings(**LK)
class HostActionTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()
        cid, body = self.upgrade()
        self.room = body["room"]
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, self.room, "joined")

    def test_only_host_can_mute(self):
        calls = []

        def fake(url, body, token):
            calls.append((url, body, token))
            if url.endswith("ListParticipants"):
                return {"participants": [{"identity": str(self.b.id), "tracks": [
                    {"sid": "TR_mic", "source": "MICROPHONE"},     # type omitted = AUDIO
                    {"sid": "TR_cam", "type": "VIDEO"}]}]}
            return {}
        with mock.patch.object(B3, "_http_post", side_effect=fake):
            r = self.cc.post(f"{V}/circle/calls/group/{self.room}/mute",
                             {"user_id": self.b.id}, format="json")
            self.assertEqual(r.status_code, 403)
            self.assertEqual(calls, [])
            r = self.ca.post(f"{V}/circle/calls/group/{self.room}/mute",
                             {"user_id": self.b.id, "kind": "audio"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
        mute = [c for c in calls if c[0].endswith("MutePublishedTrack")]
        self.assertEqual(len(mute), 1)
        self.assertEqual(mute[0][0], "http://127.0.0.1:7880/twirp/livekit.RoomService/MutePublishedTrack")
        self.assertEqual(mute[0][1], {"room": self.room, "identity": str(self.b.id),
                                      "track_sid": "TR_mic", "muted": True})
        claims = SFU.jwt_decode(mute[0][2], LK["LIVEKIT_API_SECRET"])
        self.assertTrue(claims["video"]["roomAdmin"])
        self.assertEqual(_events(self.b, "call.group")[-1]["kind"], "muted")

    def test_mute_with_track_sid_and_sfu_down(self):
        with mock.patch.object(B3, "_http_post", side_effect=OSError("down")):
            r = self.ca.post(f"{V}/circle/calls/group/{self.room}/mute",
                             {"user_id": self.b.id, "track_sid": "TR_x"}, format="json")
        self.assertEqual(r.status_code, 502)
        self.assertEqual(r.json()["code"], "sfu_error")

    def test_only_host_can_remove_and_removed_cannot_rejoin(self):
        with mock.patch.object(B3, "_http_post", return_value={}) as hp:
            self.assertEqual(self.cb.post(f"{V}/circle/calls/group/{self.room}/remove",
                                          {"user_id": self.c.id}, format="json").status_code, 403)
            r = self.ca.post(f"{V}/circle/calls/group/{self.room}/remove",
                             {"user_id": self.c.id}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            self.assertTrue(hp.call_args[0][0].endswith("RemoveParticipant"))
        self.assertEqual(_events(self.c, "call.group")[-1]["kind"], "removed")
        r = self.cc.post(f"{V}/circle/calls/group/{self.room}/token")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["code"], "removed")


@override_settings(**LK)
class MeteringTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()

    def test_stream_seconds_accumulate_and_reach_pnl(self):
        cid, body = self.upgrade()
        name = body["room"]
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, name, "joined")
        room = GroupCallRoom.objects.get(name=name)
        # pretend the 3-person shape lasted 10 minutes
        GroupCallRoom.objects.filter(pk=room.pk).update(
            tick_at=timezone.now() - timedelta(minutes=10))
        self.ev(self.cc, name, "left")
        room.refresh_from_db()
        self.assertAlmostEqual(room.audio_stream_s, 6 * 600, delta=6 * 3)
        self.assertEqual(room.video_stream_s, 0)
        self.assertEqual(room.peak_participants, 3)
        cost = B3.sfu_cost(30)
        self.assertEqual(cost["rooms"], 1)
        want = SFU.bdt_for_bytes(SFU.egress_bytes(room.audio_stream_s, 0, 40, 600),
                                 B3.bdt_per_gb())
        self.assertAlmostEqual(cost["bdt"], round(want, 2), places=2)
        from core import turn_monitor
        rc = turn_monitor.relay_cost(30)
        self.assertEqual(rc["sfu"]["rooms"], 1)

    def test_owner_price_override(self):
        c = SfuConfig.load()
        c.egress_bdt_per_gb = 20.0
        c.save()
        self.assertEqual(B3.bdt_per_gb(), 20.0)

    def test_webhook_signed_by_livekit(self):
        cid, body = self.upgrade()
        name = body["room"]
        payload = json.dumps({"event": "participant_joined", "room": {"name": name},
                              "participant": {"identity": str(self.c.id)}}).encode()
        sha = base64.b64encode(hashlib.sha256(payload).digest()).decode()
        now = timezone.now().timestamp()
        good = SFU.jwt_encode({"iss": LK["LIVEKIT_API_KEY"], "nbf": now - 5,
                               "exp": now + 60, "sha256": sha},
                              LK["LIVEKIT_API_SECRET"])
        bad = SFU.jwt_encode({"iss": LK["LIVEKIT_API_KEY"], "sha256": sha}, "nope")
        anon = APIClient()
        r = anon.post(f"{V}/livekit/webhook", data=payload,
                      content_type="application/webhook+json",
                      HTTP_AUTHORIZATION=bad)
        self.assertEqual(r.status_code, 401)
        r = anon.post(f"{V}/livekit/webhook", data=payload,
                      content_type="application/webhook+json",
                      HTTP_AUTHORIZATION=good)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(GroupCallParticipant.objects.get(
            room__name=name, user=self.c).state, "joined")


@override_settings(**LK)
class RecordingConsentApiTests(_Group, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk3()

    def rec(self, client, room, action):
        return client.post(f"{V}/circle/calls/group/{room}/record",
                           {"action": action}, format="json")

    def test_group_all_accept_then_new_joiner_pauses(self):
        cid, body = self.upgrade(invite=[self.ac.id, self.ad.id])
        room = body["room"]
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, room, "joined")
        r = self.rec(self.ca, room, "request").json()["recording"]
        self.assertEqual(r["status"], "pending")
        prompt = _events(self.b, "call.group")[-1]
        self.assertEqual(prompt["kind"], "record")
        self.assertTrue(prompt["recording"]["i_must_answer"])
        self.rec(self.cb, room, "accept")
        st = self.rec(self.cc, room, "accept").json()["recording"]
        self.assertEqual(st["status"], "recording")
        self.assertFalse(st["i_record"])          # only the requester records
        rec_a = [e for e in _events(self.a, "call.group") if e["kind"] == "record"]
        self.assertTrue(rec_a[-1]["recording"]["i_record"])
        # D joins without having accepted -> paused for everyone
        self.ev(self.cd, room, "joined")
        self.assertEqual(GroupCallRoom.objects.get(name=room).recording["status"], "paused")
        rec_d = [e for e in _events(self.d, "call.group") if e["kind"] == "record"]
        self.assertTrue(rec_d[-1]["recording"]["i_must_answer"])
        self.rec(self.cd, room, "accept")
        self.assertEqual(GroupCallRoom.objects.get(name=room).recording["status"], "recording")

    def test_group_one_decline_blocks(self):
        cid, body = self.upgrade()
        room = body["room"]
        for cl in (self.ca, self.cb, self.cc):
            self.ev(cl, room, "joined")
        self.rec(self.ca, room, "request")
        self.rec(self.cb, room, "accept")
        st = self.rec(self.cc, room, "decline").json()["recording"]
        self.assertEqual(st["status"], "declined")
        self.assertEqual(st["declined_by"], self.c.id)
        self.assertEqual(self.rec(self.cc, room, "accept").json()["recording"]["status"],
                         "declined")
        # a fresh request is allowed after a decline
        self.assertEqual(self.rec(self.ca, room, "request").json()["recording"]["status"],
                         "pending")
        self.assertEqual(self.rec(self.ca, room, "request").status_code, 409)
        self.assertEqual(self.rec(self.ca, room, "hack").status_code, 422)

    def test_one_to_one_consent(self):
        cid = self.live_call("voice")
        r = self.ca.post(f"{V}/circle/calls/{cid}/record", {"action": "request"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["recording"]["status"], "pending")
        sig = [p for p in _events(self.b, "call.signal") if p["kind"] == "record_state"]
        self.assertTrue(sig[-1]["data"]["i_must_answer"])
        r = self.cb.post(f"{V}/circle/calls/{cid}/record", {"action": "accept"},
                         format="json")
        self.assertEqual(r.json()["recording"]["status"], "recording")
        sig = [p for p in _events(self.a, "call.signal") if p["kind"] == "record_state"]
        self.assertTrue(sig[-1]["data"]["i_record"])
        r = self.cb.post(f"{V}/circle/calls/{cid}/record", {"action": "stop"},
                         format="json")
        self.assertEqual(r.json()["recording"]["status"], "stopped")
        # outsiders can't touch it
        self.assertEqual(self.co.post(f"{V}/circle/calls/{cid}/record",
                                      {"action": "accept"}, format="json").status_code, 404)
