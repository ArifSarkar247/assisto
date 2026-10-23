"""b1-calls — mid-call voice <-> video (request / accept / decline / off),
renegotiation + media-state signals, the video plan gate for an upgrade (and
the "Free calls (testing)" switch), reconnect grace, and the reality-run
39946885424 regression (a VIDEO call whose callee joined with the camera off
must still be confirmed connected by the server).

Push is faked (no network); TURN is off.
"""
from datetime import timedelta

from django.test import TestCase, override_settings
from django.utils import timezone

from core import push
from core.logic import call_signal as CS
from core.models import CallRecord, RtEvent
from core.tests_c2_calls import V, _Pair


def _signals_for(user, kind=None):
    rows = RtEvent.objects.filter(user=user, topic="call.signal").order_by("id")
    out = [r.payload for r in rows]
    return [p for p in out if kind is None or p.get("kind") == kind]


class _Live(_Pair):
    def live_call(self, kind="voice"):
        """A -> B call, answered and ICE-connected (server phase connected)."""
        self.online(self.b)
        cid = self.place(kind)["call_id"]
        self.ev(self.cb, cid, "ringing")
        self.assertEqual(self.ev(self.cb, cid, "answer")["phase"], "accepted")
        self.ev(self.ca, cid, "connected")
        self.assertEqual(self.ca.get(f"{V}/circle/calls/{cid}").json()["phase"],
                         "connected")
        return cid


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="", CALLS_FREE_TESTING_DEFAULT=False)
class VideoUpgradeTests(_Live, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk()

    def _premium(self, u):
        u.plan = "premium"
        u.plan_until = timezone.now() + timedelta(days=30)
        u.save()

    def test_new_kinds_are_valid_signals(self):
        for k in ("video_request", "video_accept", "video_decline",
                  "video_cancel", "video_off", "reneg_offer", "reneg_answer",
                  "reneg_request", "restart_request", "media"):
            self.assertEqual(CS.validate_signal(k, 10, 0), "ok", k)
        self.assertEqual(CS.validate_signal("video_hack", 10, 0), "bad_kind")

    def test_premium_caller_upgrades_voice_to_video_and_back(self):
        self._premium(self.a)
        cid = self.live_call("voice")
        r = self.signal(self.ca, cid, "video_request", {})
        self.assertEqual(r.status_code, 201, r.content)
        req = _signals_for(self.b, "video_request")
        self.assertEqual(len(req), 1)
        self.assertEqual(req[0]["from"], "caller")
        # B (free) may ACCEPT — the gate is on the person asking
        r = self.signal(self.cb, cid, "video_accept", {})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(_signals_for(self.a, "video_accept")[0]["from"],
                         "callee")
        # the record is a video call now (history + P&L cost per kind)
        self.assertEqual(CallRecord.objects.get(pk=cid).kind, "video")
        hist = self.ca.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertEqual(hist["kind"], "video")
        # renegotiation passes through (caller offers, callee answers)
        r = self.signal(self.ca, cid, "reneg_offer",
                        {"type": "offer", "sdp": "v=0 video"})
        self.assertEqual(r.status_code, 201, r.content)
        r = self.signal(self.cb, cid, "reneg_answer",
                        {"type": "answer", "sdp": "v=0 video-ans"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(_signals_for(self.b, "reneg_offer")[0]["data"]["sdp"],
                         "v=0 video")
        # either side switches back to voice instantly
        r = self.signal(self.cb, cid, "video_off", {})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(_signals_for(self.a, "video_off")), 1)
        # the call itself never dropped
        self.assertEqual(self.ca.get(f"{V}/circle/calls/{cid}").json()["phase"],
                         "connected")

    def test_free_user_request_is_gated_402_and_never_relayed(self):
        cid = self.live_call("voice")
        r = self.signal(self.cb, cid, "video_request", {})
        self.assertEqual(r.status_code, 402, r.content)
        body = r.json()
        self.assertEqual(body["code"], "upgrade_required")
        self.assertTrue(body["upgrade_required"])
        self.assertIn("title", body["prompt"])
        self.assertEqual(_signals_for(self.a, "video_request"), [])
        # the voice call goes on
        self.assertEqual(self.cb.get(f"{V}/circle/calls/{cid}").json()["phase"],
                         "connected")
        self.assertEqual(CallRecord.objects.get(pk=cid).kind, "voice")

    @override_settings(CALLS_FREE_TESTING_DEFAULT=True)
    def test_free_calls_testing_switch_lifts_the_upgrade_gate(self):
        cid = self.live_call("voice")
        r = self.signal(self.cb, cid, "video_request", {})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(_signals_for(self.a, "video_request")), 1)

    def test_decline_cancel_and_media_state_relay(self):
        self._premium(self.a)
        cid = self.live_call("voice")
        self.assertEqual(self.signal(self.ca, cid, "video_request", {})
                         .status_code, 201)
        r = self.signal(self.cb, cid, "video_decline", {"reason": "declined"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(_signals_for(self.a, "video_decline")[0]["data"],
                         {"reason": "declined"})
        self.assertEqual(CallRecord.objects.get(pk=cid).kind, "voice")
        self.assertEqual(self.signal(self.ca, cid, "video_cancel", {})
                         .status_code, 201)
        # media state: mic + camera + mode reach the other phone
        r = self.signal(self.cb, cid, "media",
                        {"camera": False, "mic": False, "video": False})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(_signals_for(self.a, "media")[-1]["data"],
                         {"camera": False, "mic": False, "video": False})

    def test_signals_after_the_call_ended_are_refused(self):
        self._premium(self.a)
        cid = self.live_call("voice")
        self.ev(self.ca, cid, "hangup")
        r = self.signal(self.ca, cid, "video_request", {})
        self.assertEqual(r.status_code, 410, r.content)

    def test_restart_request_from_callee_reaches_caller(self):
        cid = self.live_call("voice")
        self.ev(self.cb, cid, "reconnect")
        r = self.signal(self.cb, cid, "restart_request", {})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(_signals_for(self.a, "restart_request")), 1)


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="", CALLS_FREE_TESTING_DEFAULT=True)
class ReconnectGraceTests(_Live, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk()

    def test_pure_rule_reconnecting_gets_longer_grace(self):
        now = timezone.now()
        t = now - timedelta(seconds=CS.HEARTBEAT_S + 5)
        args = dict(started_at=now - timedelta(seconds=120),
                    caller_seen=now, callee_seen=t,
                    connected_at=now - timedelta(seconds=100))
        self.assertEqual(CS.sweep_decision("active", now, **args), "lost")
        self.assertIsNone(CS.sweep_decision("reconnecting", now, **args))
        args["callee_seen"] = now - timedelta(seconds=CS.RECONNECT_GRACE_S + 1)
        self.assertEqual(CS.sweep_decision("reconnecting", now, **args), "lost")

    def test_reconnecting_call_survives_a_short_signalling_gap(self):
        cid = self.live_call("voice")
        self.ev(self.ca, cid, "reconnect")
        rec = CallRecord.objects.get(pk=cid)
        s = rec.session
        s.callee_seen_at = timezone.now() - timedelta(seconds=CS.HEARTBEAT_S + 5)
        s.save()
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["phase"], "reconnecting", st)
        # B's network is back (it polls again), media back -> connected
        self.events(self.cb)
        self.ev(self.ca, cid, "connected")
        self.assertEqual(self.ca.get(f"{V}/circle/calls/{cid}").json()["phase"],
                         "connected")


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="", CALLS_FREE_TESTING_DEFAULT=True)
class VideoCallCameraOffRegressionTests(_Live, TestCase):
    """reality run 39946885424 (18_circle_real_call, step "A accepts -> video
    call connects"): the callee's camera refused on the emulator, the app
    ended the whole call with `fail` before it ever answered the offer, so
    the server never saw `connected`. The app now joins with the camera OFF
    (WebRtcCallMedia falls back to audio, signals media camera:false); this
    is the server half: such a video call is accepted, relays the answer +
    the camera-off state and is confirmed connected."""

    def setUp(self):
        push.reset_cache()
        self.mk()

    def test_video_call_with_callee_camera_off_is_confirmed_connected(self):
        self.online(self.b)
        body = self.place("video")
        cid = body["call_id"]
        self.assertEqual(body["kind"], "video")
        self.assertEqual(self.signal(self.ca, cid, "offer",
                                     {"type": "offer", "sdp": "v=0 A"})
                         .status_code, 201)
        self.ev(self.cb, cid, "ringing")
        self.assertEqual(self.ev(self.cb, cid, "answer")["phase"], "accepted")
        # callee: answer + its camera-off state (no `fail`)
        self.assertEqual(self.signal(self.cb, cid, "answer",
                                     {"type": "answer", "sdp": "v=0 B"})
                         .status_code, 201)
        self.assertEqual(self.signal(self.cb, cid, "media",
                                     {"camera": False, "mic": True,
                                      "video": True}).status_code, 201)
        # the CALLER reaches ICE connected and reports it
        st = self.ev(self.ca, cid, "connected")
        self.assertEqual(st["phase"], "connected", st)
        self.assertEqual(self.cb.get(f"{V}/circle/calls/{cid}").json()["phase"],
                         "connected")
        rec = CallRecord.objects.get(pk=cid)
        self.assertEqual((rec.kind, rec.state), ("video", "active"))
        self.assertIsNotNone(rec.session.connected_at)
        self.assertEqual(_signals_for(self.a, "media")[-1]["data"]["camera"],
                         False)

    def test_old_behaviour_fail_before_answer_ends_the_call(self):
        """What the run saw: `fail` right after accept ends it as failed —
        the server reports it honestly (never a fake connect)."""
        self.online(self.b)
        cid = self.place("video")["call_id"]
        self.ev(self.cb, cid, "ringing")
        self.ev(self.cb, cid, "answer")
        self.ev(self.cb, cid, "fail")
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["phase"], "ended")
        self.assertEqual(st["end_reason"], "failed")
