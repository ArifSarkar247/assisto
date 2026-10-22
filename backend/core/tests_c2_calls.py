"""c2-calls — real call signalling, state machine, outcomes, call log, missed
call push, TURN credentials and the shared real-time event queue.

Push HTTP is always faked (no network); the RSA key is generated per run.
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core.logic import call_signal as CS
from core.logic import rtc as RTC
from core.models import (CallRecord, CallSession, CircleMember, Device,
                         RtEvent, RtPresence, User)
from core.tests_push import _PushBase

V = "/api/v1"


class _Pair:
    def mk(self, lang="en"):
        self.a = User.objects.create_user(name="Amina", phone="01740000101",
                                          password="pw12345!", language=lang)
        self.b = User.objects.create_user(name="Babu", phone="01740000102",
                                          password="pw12345!", language=lang)
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Babu", state="accepted",
            phone="01740000102")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            direction="incoming", phone="01740000101")
        self.ca = APIClient()
        self.ca.force_authenticate(self.a)
        self.cb = APIClient()
        self.cb.force_authenticate(self.b)

    def online(self, user):
        RtPresence.objects.update_or_create(user=user,
                                            defaults={"seen_at": timezone.now()})

    def place(self, kind="voice"):
        r = self.ca.post(f"{V}/circle/{self.ab.id}/call", {"kind": kind},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()

    def ev(self, client, cid, event, **extra):
        r = client.post(f"{V}/circle/calls/{cid}/event",
                        {"event": event, **extra}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def events(self, client, after=0, topics=""):
        q = f"?after={after}" + (f"&topics={topics}" if topics else "")
        r = client.get(f"{V}/rt/events{q}")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def signal(self, client, cid, kind, data):
        return client.post(f"{V}/rt/send", {"topic": "call.signal", "payload": {
            "call_id": cid, "kind": kind, "data": data}}, format="json")

    def age(self, cid, seconds, ringing=None):
        """Shift a call's clocks into the past (lazy timeouts)."""
        rec = CallRecord.objects.get(pk=cid)
        past = timezone.now() - timedelta(seconds=seconds)
        CallRecord.objects.filter(pk=cid).update(started_at=past)
        s = rec.session
        if ringing is not None:
            s.ringing_at = timezone.now() - timedelta(seconds=ringing)
        s.caller_seen_at = timezone.now()
        s.save()


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class SignallingNoPushTests(_Pair, TestCase):
    """CI-like: no FCM. The callee is reachable only while its app polls."""

    def setUp(self):
        push.reset_cache()
        self.mk()

    def test_offline_when_callee_never_polled(self):
        body = self.place()
        self.assertEqual(body["phase"], "ended")
        self.assertEqual(body["end_reason"], "offline")
        rec = CallRecord.objects.get(pk=body["call_id"])
        self.assertEqual(rec.state, "missed")
        hist = self.ca.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertEqual(hist["end_reason"], "offline")
        self.assertIn("Offline", hist["outcome"])
        hist_b = self.cb.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertIn("Missed call", hist_b["outcome"])

    def test_full_call_both_directions_signals_and_states(self):
        self.events(self.cb)  # B's app is open -> presence
        body = self.place("voice")
        cid = body["call_id"]
        self.assertEqual(body["phase"], "calling")  # not ringing yet
        self.assertTrue(body["ice"]["iceServers"])
        self.assertFalse(body["ice"]["turn"])
        # B gets call.incoming over the real-time queue instantly
        evb = self.events(self.cb)
        inc = [e for e in evb["events"] if e["topic"] == "call.incoming"]
        self.assertEqual(len(inc), 1)
        self.assertEqual(inc[0]["payload"]["call_id"], cid)
        self.assertEqual(inc[0]["payload"]["chat_id"], self.ba.id)
        self.assertEqual(inc[0]["payload"]["caller_name"], "Amina")
        self.assertEqual(self.cb.get(f"{V}/circle/calls/incoming").json()
                         ["calls"][0]["call_id"], cid)
        seq_b = evb["seq"]
        # A posts the offer before B answers (pre-negotiation)
        r = self.signal(self.ca, cid, "offer", {"type": "offer", "sdp": "v=0 A"})
        self.assertEqual(r.status_code, 201, r.content)
        # B's phone reports it is ringing -> A sees "ringing"
        self.assertEqual(self.ev(self.cb, cid, "ringing")["phase"], "ringing")
        eva = self.events(self.ca, topics="call.")
        st = [e for e in eva["events"] if e["topic"] == "call.state"]
        self.assertEqual(st[-1]["payload"]["phase"], "ringing")
        self.assertEqual(st[-1]["payload"]["side"], "caller")
        seq_a = eva["seq"]
        # B accepts -> accepted (+ ICE for B)
        acc = self.ev(self.cb, cid, "answer")
        self.assertEqual(acc["phase"], "accepted")
        self.assertIn("iceServers", acc["ice"])
        # B reads the offer, answers, trickles ICE
        evb = self.events(self.cb, after=seq_b)
        offers = [e for e in evb["events"] if e["topic"] == "call.signal"]
        self.assertEqual(offers[0]["payload"]["kind"], "offer")
        self.assertEqual(offers[0]["payload"]["data"]["sdp"], "v=0 A")
        self.assertEqual(offers[0]["payload"]["from"], "caller")
        self.assertEqual(self.signal(self.cb, cid, "answer",
                                     {"type": "answer", "sdp": "v=0 B"}).status_code, 201)
        self.assertEqual(self.signal(self.cb, cid, "ice", {
            "candidate": "candidate:1 1 udp 1 10.0.0.2 5000 typ host",
            "sdpMid": "0", "sdpMLineIndex": 0}).status_code, 201)
        eva = self.events(self.ca, after=seq_a)
        kinds = [e["payload"].get("kind") for e in eva["events"]
                 if e["topic"] == "call.signal"]
        self.assertEqual(kinds, ["answer", "ice"])
        # the caller never receives its own signals
        self.assertFalse(any(e["payload"].get("from") == "caller"
                             for e in eva["events"] if e["topic"] == "call.signal"))
        states = [e["payload"]["phase"] for e in eva["events"]
                  if e["topic"] == "call.state"]
        self.assertIn("accepted", states)
        # ICE connected on both sides
        self.assertEqual(self.ev(self.ca, cid, "connected", relayed=True)["phase"],
                         "connected")
        self.assertEqual(self.ev(self.cb, cid, "connected")["phase"], "connected")
        self.assertTrue(CallSession.objects.get(call_id=cid).relayed)
        # network blip -> reconnecting -> connected (ICE restart signals pass)
        self.assertEqual(self.ev(self.ca, cid, "reconnect")["phase"], "reconnecting")
        self.assertEqual(self.signal(self.ca, cid, "restart_offer",
                                     {"type": "offer", "sdp": "v=0 R"}).status_code, 201)
        self.assertEqual(self.ev(self.ca, cid, "connected")["phase"], "connected")
        # talk time counts from ICE connected
        CallSession.objects.filter(call_id=cid).update(
            connected_at=timezone.now() - timedelta(seconds=65))
        end = self.ev(self.cb, cid, "hangup")
        self.assertEqual((end["phase"], end["end_reason"], end["ended_by"]),
                         ("ended", "hangup", "callee"))
        rec = CallRecord.objects.get(pk=cid)
        self.assertEqual(rec.state, "ended")
        self.assertGreaterEqual(rec.duration_sec, 64)
        # signalling after the end is refused honestly
        r = self.signal(self.ca, cid, "ice", {"candidate": "x"})
        self.assertEqual(r.status_code, 410)
        self.assertEqual(r.json()["code"], "call_ended")
        # call log on both sides, with duration
        ha = self.ca.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertEqual((ha["kind"], ha["state"], ha["outgoing"]),
                         ("voice", "ended", True))
        self.assertTrue(ha["duration"])
        hb = self.cb.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertFalse(hb["outgoing"])

    def test_video_call_reverse_direction_and_free_callee_may_answer(self):
        # B (free) receives a video call from premium A: answering is allowed
        self.a.plan = "premium"
        self.a.plan_until = timezone.now() + timedelta(days=30)
        self.a.save()
        self.online(self.b)
        body = self.place("video")
        self.assertEqual(body["kind"], "video")
        r = self.cb.post(f"{V}/circle/{self.ba.id}/call/answer", {"kind": "video"},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["call_id"], body["call_id"])
        self.assertEqual(r.json()["phase"], "accepted")
        self.assertEqual(CallRecord.objects.count(), 1)  # no second record
        self.ev(self.ca, body["call_id"], "hangup")
        # now B calls A (voice) — the other direction
        self.online(self.a)
        r = self.cb.post(f"{V}/circle/{self.ba.id}/call", {"kind": "voice"},
                         format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.json()["phase"], "calling")
        cid = r.json()["call_id"]
        self.ev(self.ca, cid, "ringing")
        self.assertEqual(self.ev(self.ca, cid, "answer")["phase"], "accepted")

    def test_declined(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "ringing")
        d = self.ev(self.cb, cid, "decline")
        self.assertEqual((d["phase"], d["end_reason"]), ("ended", "declined"))
        self.assertEqual(self.ca.get(f"{V}/circle/calls/{cid}").json()["end_reason"],
                         "declined")
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "declined")
        # the caller cannot "decline" its own call
        self.online(self.b)
        cid2 = self.place()["call_id"]
        self.assertEqual(self.ev(self.ca, cid2, "decline")["phase"], "calling")

    def test_busy_when_callee_in_another_call(self):
        c = User.objects.create_user(name="Chompa", phone="01740000103",
                                     password="pw12345!")
        CircleMember.objects.create(user=c, peer_user=self.b, name="Babu",
                                    state="accepted", phone="01740000102")
        cb_edge = CircleMember.objects.create(user=self.b, peer_user=c,
                                              name="Chompa", state="accepted")
        self.online(c)
        r = self.cb.post(f"{V}/circle/{cb_edge.id}/call", {"kind": "voice"},
                         format="json")
        other = r.json()["call_id"]
        self.assertEqual(r.json()["phase"], "calling")
        body = self.place()
        self.assertEqual(body["end_reason"], "busy")
        self.assertEqual(CallRecord.objects.get(pk=body["call_id"]).state, "missed")
        # callee may also press "busy" on a ringing call
        CallRecord.objects.filter(pk=other).update(state="ended")
        self.online(self.b)
        cid = self.place()["call_id"]
        self.assertEqual(self.ev(self.cb, cid, "busy")["end_reason"], "busy")

    def test_no_answer_after_ringing_timeout(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "ringing")
        self.age(cid, CS.RING_TIMEOUT_S + 5, ringing=CS.RING_TIMEOUT_S + 2)
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual((st["phase"], st["end_reason"]), ("ended", "no_answer"))
        h = self.ca.get(f"{V}/circle/calls").json()["calls"][0]
        self.assertIn("No answer", h["outcome"])

    def test_offline_when_phone_never_acks_ring(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.age(cid, CS.OFFLINE_ACK_S + 3)
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "offline")

    def test_caller_cancel_before_answer(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "ringing")
        c = self.ev(self.ca, cid, "cancel")
        self.assertEqual(c["end_reason"], "canceled")
        evb = self.events(self.cb, topics="call.state")
        self.assertEqual(evb["events"][-1]["payload"]["end_reason"], "canceled")
        self.assertEqual(evb["events"][-1]["payload"]["side"], "callee")

    def test_lost_when_a_phone_stops_polling(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        self.ev(self.ca, cid, "connected")
        CallSession.objects.filter(call_id=cid).update(
            callee_seen_at=timezone.now() - timedelta(seconds=CS.STALE_S + 5))
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "lost")

    def test_accepted_but_never_connected_fails(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        CallRecord.objects.filter(pk=cid).update(
            answered_at=timezone.now() - timedelta(seconds=CS.CONNECT_TIMEOUT_S + 5))
        CallSession.objects.filter(call_id=cid).update(
            caller_seen_at=timezone.now(), callee_seen_at=timezone.now())
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "failed")

    def test_media_failure_is_failed_not_connected(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        f = self.ev(self.ca, cid, "fail")
        self.assertEqual((f["phase"], f["end_reason"]), ("ended", "failed"))
        self.assertIsNone(f["connected_at"])
        self.assertEqual(CallRecord.objects.get(pk=cid).duration_sec, 0)

    def test_signal_validation_and_privacy(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        r = self.signal(self.ca, cid, "evil", {})
        self.assertEqual(r.status_code, 422)
        r = self.signal(self.ca, cid, "offer", {"sdp": "x" * (CS.MAX_SIGNAL_BYTES + 10)})
        self.assertIn(r.status_code, (413, 422))
        stranger = User.objects.create_user(name="X", phone="01740000199",
                                            password="pw12345!")
        cs = APIClient()
        cs.force_authenticate(stranger)
        self.assertEqual(self.signal(cs, cid, "offer", {"sdp": "x"}).status_code, 404)
        self.assertEqual(cs.get(f"{V}/circle/calls/{cid}").status_code, 404)
        self.assertEqual(cs.post(f"{V}/circle/calls/{cid}/event",
                                 {"event": "hangup"}, format="json").status_code, 404)
        # events are per-recipient: the stranger sees nothing
        self.assertEqual(self.events(cs)["events"], [])
        r = self.ca.post(f"{V}/rt/send", {"topic": "nope.x", "payload": {}},
                         format="json")
        self.assertEqual(r.status_code, 422)

    def test_rt_events_sequence_filter_and_prune(self):
        from core.views_c2_calls import rt_publish
        s1 = rt_publish(self.a, "typing.update", {"chat": 1})
        s2 = rt_publish(self.a, "call.state", {"x": 1})
        out = self.events(self.ca)
        self.assertEqual([e["seq"] for e in out["events"]], [s1, s2])
        self.assertEqual(out["seq"], s2)
        self.assertEqual(self.events(self.ca, after=s1)["events"][0]["seq"], s2)
        self.assertEqual([e["topic"] for e in
                          self.events(self.ca, topics="typing")["events"]],
                         ["typing.update"])
        self.assertTrue(RtPresence.objects.filter(user=self.a).exists())
        RtEvent.objects.filter(pk=s1).update(
            created_at=timezone.now() - timedelta(seconds=900))
        self.events(self.ca)
        self.assertFalse(RtEvent.objects.filter(pk=s1).exists())

    def test_producer_registry_for_other_topics(self):
        from core import views_c2_calls as C2
        seen = []
        C2.register_producer("typing.", lambda req, t, p: (seen.append(t) or
                                                           ({"ok": True}, 200)))
        try:
            r = self.ca.post(f"{V}/rt/send", {"topic": "typing.start",
                                              "payload": {"chat_id": 1}},
                             format="json")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(seen, ["typing.start"])
        finally:
            C2.RT_PRODUCERS.pop("typing.", None)


class SignallingPushTests(_Pair, _PushBase):
    """With FCM: ring push, cancel push, missed-call push."""

    def setUp(self):
        super().setUp()
        self.mk()
        Device.objects.create(user=self.b, push_token="bdev")

    def test_ring_then_missed_call_push_on_no_answer(self):
        body = self.place()
        self.assertEqual(body["phase"], "calling")  # reachable by FCM
        ring = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(ring["data"]["kind"], "call")
        self.fake.calls.clear()
        cid = body["call_id"]
        self.ev(self.cb, cid, "ringing")
        self.age(cid, CS.RING_TIMEOUT_S + 5, ringing=CS.RING_TIMEOUT_S + 2)
        self.ca.get(f"{V}/circle/calls/{cid}")
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertEqual(kinds, ["call_cancel", "missed_call"])
        missed = self.fake.sent_payloads()[1]["message"]
        self.assertNotIn("notification", missed)  # app draws it quietly
        self.assertEqual(missed["data"]["reason"], "no_answer")
        self.assertEqual(missed["data"]["caller_name"], "Amina")
        self.assertEqual(missed["data"]["channel"], "missed_calls")
        self.assertEqual(missed["android"]["ttl"], "86400s")
        # once only
        self.fake.calls.clear()
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(self.fake.sent_payloads(), [])

    def test_answer_stops_ring_on_other_devices_no_missed(self):
        cid = self.place()["call_id"]
        self.fake.calls.clear()
        self.ev(self.cb, cid, "answer")
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertEqual(kinds, ["call_cancel"])
        self.ev(self.ca, cid, "connected")
        self.fake.calls.clear()
        self.ev(self.ca, cid, "hangup")
        self.assertEqual(self.fake.sent_payloads(), [])  # not missed, no ring

    def test_declined_is_not_a_missed_call(self):
        cid = self.place()["call_id"]
        self.fake.calls.clear()
        self.ev(self.cb, cid, "decline")
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertEqual(kinds, ["call_cancel"])


class TurnCredentialTests(TestCase):
    def test_turn_rest_credentials(self):
        c = RTC.turn_credentials("s3cret-test", 7, 1000, ttl=600)
        self.assertEqual(c["username"], "1600:7")
        self.assertEqual(c["expiry"], 1600)
        import base64
        import hashlib
        import hmac
        want = base64.b64encode(hmac.new(b"s3cret-test", b"1600:7",
                                         hashlib.sha1).digest()).decode()
        self.assertEqual(c["credential"], want)

    @override_settings(TURN_STATIC_SECRET="fake-ci-secret",
                       TURN_HOST="turn.example.test", TURN_PORT=3478,
                       FCM_SERVICE_ACCOUNT_FILE="")
    def test_call_ice_includes_turn_when_configured(self):
        push.reset_cache()
        u = User.objects.create_user(name="T", phone="01740000150",
                                     password="pw12345!")
        from core.views_c2_calls import ice_for
        ice = ice_for(u)
        self.assertTrue(ice["turn"])
        urls = [x for s in ice["iceServers"] for x in s["urls"]]
        self.assertIn("turn:turn.example.test:3478?transport=udp", urls)
        self.assertIn("turn:turn.example.test:3478?transport=tcp", urls)
        turn = [s for s in ice["iceServers"] if "username" in s][0]
        self.assertTrue(turn["username"].endswith(":%d" % u.id))
        self.assertGreater(int(turn["username"].split(":")[0]),
                           int(timezone.now().timestamp()))


class PureLogicTests(TestCase):
    def test_phase_and_reasons(self):
        self.assertEqual(CS.phase("ringing"), "calling")
        self.assertEqual(CS.phase("ringing", timezone.now()), "ringing")
        self.assertEqual(CS.phase("connecting"), "accepted")
        self.assertEqual(CS.phase("active"), "connected")
        self.assertEqual(CS.phase("missed"), "ended")
        self.assertEqual(CS.end_reason_for_event("ringing", "hangup", True), "canceled")
        self.assertEqual(CS.end_reason_for_event("ringing", "hangup", False), "declined")
        self.assertEqual(CS.end_reason_for_event("active", "hangup", False), "hangup")
        self.assertIsNone(CS.end_reason_for_event("active", "decline", False))
        for r in CS.END_REASONS:
            self.assertIn(CS.state_for_reason(r), CC_STATES)

    def test_sweep(self):
        now = timezone.now()
        old = now - timedelta(seconds=100)
        self.assertEqual(CS.sweep_decision("ringing", now, old), "offline")
        self.assertEqual(CS.sweep_decision("ringing", now, old, ringing_at=old),
                         "no_answer")
        self.assertIsNone(CS.sweep_decision("ringing", now, now, ringing_at=now,
                                            caller_seen=now))
        self.assertEqual(CS.sweep_decision("connecting", now, old, answered_at=old),
                         "failed")
        self.assertEqual(CS.sweep_decision("active", now, old, answered_at=old,
                                           caller_seen=now, callee_seen=old), "lost")
        self.assertIsNone(CS.sweep_decision("ended", now, old))


CC_STATES = {"ended", "missed", "declined", "canceled", "failed"}
