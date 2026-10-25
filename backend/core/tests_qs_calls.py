"""qs-calls (quality sweep, owner item 5) — call state transitions and
authorization edges that the c2/x1/b1 suites did not pin down.

  * pure circle_calls state machine: every legal transition, illegal events are
    no-ops, terminal states are final, durations only count answered time;
  * server call flow: only the CALLEE can answer/decline/busy, the caller
    cannot accept his own call (event or legacy /call/answer), events after the
    call ended never revive it, answer is idempotent, reconnect -> connected,
    blocked / calls-off callee is never rung, another user's member id is 404.
"""
from datetime import datetime, timedelta, timezone as dt_tz

from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import push
from core.logic import circle_calls as CC
from core.models import CallRecord, CircleMember, RtEvent, User
from core.tests_c2_calls import V, _Pair


class CircleCallsStateMachineTests(SimpleTestCase):
    T0 = datetime(2026, 10, 25, 10, 0, 0, tzinfo=dt_tz.utc)

    def test_ringing_transitions(self):
        exp = {"answer": "connecting", "decline": "declined",
               "cancel": "canceled", "timeout": "missed", "fail": "failed"}
        for ev, nxt in exp.items():
            self.assertEqual(CC.apply_call_event("ringing", ev), (nxt, True), ev)
        # a ringing call cannot be "connected"/"hangup"/"reconnect"ed directly
        for ev in ("connected", "reconnect", "hangup", "bogus", ""):
            self.assertEqual(CC.apply_call_event("ringing", ev),
                             ("ringing", False), ev)

    def test_live_transitions(self):
        self.assertEqual(CC.apply_call_event("connecting", "connected"),
                         ("active", True))
        self.assertEqual(CC.apply_call_event("connecting", "answer"),
                         ("connecting", False))
        self.assertEqual(CC.apply_call_event("active", "reconnect"),
                         ("reconnecting", True))
        self.assertEqual(CC.apply_call_event("reconnecting", "connected"),
                         ("active", True))
        self.assertEqual(CC.apply_call_event("reconnecting", "fail"),
                         ("failed", True))
        for st in ("connecting", "active", "reconnecting"):
            self.assertEqual(CC.apply_call_event(st, "hangup"), ("ended", True))
            # decline/cancel/timeout only make sense while ringing
            for ev in ("decline", "cancel", "timeout"):
                self.assertEqual(CC.apply_call_event(st, ev), (st, False))

    def test_terminal_states_are_final(self):
        for st in ("ended", "missed", "declined", "canceled", "failed"):
            self.assertTrue(CC.is_terminal(st))
            for ev in ("answer", "connected", "hangup", "fail", "reconnect",
                       "decline", "cancel", "timeout"):
                self.assertEqual(CC.apply_call_event(st, ev), (st, False))

    def test_unknown_state_treated_as_ringing(self):
        self.assertEqual(CC.apply_call_event("weird", "answer"),
                         ("connecting", True))

    def test_finalize_answered_call_counts_from_answer(self):
        r = CC.new_call_record(1, 10, 20, "voice", started_at=self.T0)
        self.assertEqual(r["state"], "ringing")
        r = CC.finalize_call(r, "answer", at=self.T0 + timedelta(seconds=10))
        self.assertEqual(r["state"], "connecting")
        ans = r["answered_at"]
        r = CC.finalize_call(r, "connected", at=self.T0 + timedelta(seconds=12))
        r = CC.finalize_call(r, "reconnect", at=self.T0 + timedelta(seconds=40))
        self.assertTrue(CC.is_connected(r["state"]))
        r = CC.finalize_call(r, "connected", at=self.T0 + timedelta(seconds=45))
        r = CC.finalize_call(r, "hangup", at=self.T0 + timedelta(seconds=70))
        self.assertEqual(r["state"], "ended")
        self.assertEqual(r["answered_at"], ans)  # never re-stamped
        self.assertEqual(r["duration_sec"], 60)
        # an event after the end changes nothing
        again = CC.finalize_call(r, "hangup", at=self.T0 + timedelta(seconds=99))
        self.assertEqual(again, r)

    def test_unanswered_outcomes_have_zero_duration(self):
        for ev, st in (("timeout", "missed"), ("decline", "declined"),
                       ("cancel", "canceled"), ("fail", "failed")):
            r = CC.new_call_record(1, 10, 20, "video", started_at=self.T0)
            r = CC.finalize_call(r, ev, at=self.T0 + timedelta(seconds=30))
            self.assertEqual(r["state"], st)
            self.assertEqual(r["duration_sec"], 0)
            self.assertIsNotNone(r["ended_at"])
            self.assertIsNone(r["answered_at"])

    def test_missed_and_callback(self):
        self.assertTrue(CC.is_missed("missed"))
        self.assertTrue(CC.is_missed("canceled"))
        self.assertFalse(CC.is_missed("declined"))
        self.assertTrue(CC.can_call_back({"state": "ended"}))
        self.assertFalse(CC.can_call_back({"state": "active"}))
        self.assertFalse(CC.can_call_back(None))

    def test_outcome_labels_by_viewer(self):
        rec = {"state": "missed", "caller_id": 1, "callee_id": 2, "kind": "voice"}
        self.assertEqual(CC.call_outcome_label(rec, 2, "en"), "Voice · Missed call")
        self.assertEqual(CC.call_outcome_label(rec, 1, "en"), "Voice · Canceled call")
        rec.update(state="declined", kind="video")
        self.assertEqual(CC.call_outcome_label(rec, 2, "en"), "Video · Declined")
        rec["state"] = "failed"
        self.assertEqual(CC.call_outcome_label(rec, 1, "en"), "Video · Call failed")
        rec["state"] = "ended"
        self.assertEqual(CC.call_outcome_label(rec, 1, "en"), "Video · Outgoing")
        self.assertEqual(CC.call_outcome_label(rec, 2, "bn"), "ভিডিও · ইনকামিং")

    def test_live_status_label_all_states(self):
        self.assertEqual(CC.live_status_label("ringing", True, "en"), "Ringing…")
        self.assertEqual(CC.live_status_label("ringing", False, "en"), "Incoming call")
        self.assertEqual(CC.live_status_label("connecting", True, "en"), "Connecting…")
        self.assertEqual(CC.live_status_label("active", True, "en"), "Connected")
        self.assertEqual(CC.live_status_label("reconnecting", True, "en"),
                         "Reconnecting…")
        self.assertEqual(CC.live_status_label("failed", True, "en"), "Call failed")
        self.assertEqual(CC.live_status_label("ended", True, "en"), "Call ended")
        self.assertEqual(CC.live_status_label("missed", False, "bn"), "কল শেষ")

    def test_duration_format(self):
        self.assertEqual(CC.format_duration(0), "0:00")
        self.assertEqual(CC.format_duration(-5), "0:00")
        self.assertEqual(CC.format_duration(65), "1:05")
        self.assertEqual(CC.format_duration(3725), "1:02:05")
        self.assertEqual(CC.format_duration(None), "0:00")

    def test_controls(self):
        v = CC.default_controls("video")
        self.assertTrue(v["camera_on"] and v["speaker_on"])
        a = CC.default_controls("voice")
        self.assertFalse(a["camera_on"] or a["speaker_on"])
        t = CC.toggle_control(a, "muted")
        self.assertTrue(t["muted"])
        self.assertFalse(a["muted"])            # input not mutated
        self.assertFalse(CC.toggle_control(a, "switch_camera")["front_camera"])
        self.assertEqual(CC.toggle_control(a, "rm -rf"), a)

    def test_ice_config_turn_only_when_ready(self):
        turn = {"urls": ["turn:t.example:3478"], "username": "u", "credential": "c"}
        self.assertEqual(len(CC.ice_config(False, turn=turn)["iceServers"]), 1)
        cfg = CC.ice_config(True, stun_urls=["stun:a", "stun:b"], turn=turn)
        self.assertEqual(len(cfg["iceServers"]), 3)
        self.assertEqual(cfg["iceServers"][-1]["credential"], "c")
        self.assertEqual(len(CC.ice_config(True, turn={"urls": []})["iceServers"]), 1)

    def test_transport_status_is_honest(self):
        s = CC.transport_status(False, False, "en")
        self.assertTrue(s["app_open_calling"])
        self.assertFalse(s["app_closed_ring"] or s["turn_relay"])
        self.assertIn("when push is enabled", s["banner"])
        s = CC.transport_status(True, True, "bn")
        self.assertTrue(s["app_closed_ring"] and s["turn_relay"])

    def test_parse_and_iso_helpers(self):
        self.assertIsNone(CC._parse("not a date"))
        self.assertIsNone(CC._parse(None))
        self.assertEqual(CC._parse("2026-10-25T10:00:00Z"), self.T0)
        naive = datetime(2026, 10, 25, 10, 0, 0)
        self.assertEqual(CC._parse(naive), self.T0)
        self.assertTrue(CC._iso(naive).endswith("+00:00"))
        self.assertIsNone(CC._iso(None))


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class CallFlowEdgeTests(_Pair, TestCase):
    def setUp(self):
        push.reset_cache()
        self.mk()
        self.online(self.b)

    def _state(self, cid):
        return CallRecord.objects.get(pk=cid).state

    def test_caller_cannot_answer_own_call(self):
        cid = self.place()["call_id"]
        self.ev(self.ca, cid, "answer")
        self.assertEqual(self._state(cid), "ringing")
        # legacy answer endpoint with the caller's own call id -> 410, no accept
        r = self.ca.post(f"{V}/circle/{self.ab.id}/call/answer",
                         {"call_id": cid}, format="json")
        self.assertEqual(r.status_code, 410)
        self.assertEqual(self._state(cid), "ringing")

    def test_only_callee_may_decline_or_busy(self):
        cid = self.place()["call_id"]
        self.ev(self.ca, cid, "decline")
        self.ev(self.ca, cid, "busy")
        self.assertEqual(self._state(cid), "ringing")
        self.ev(self.cb, cid, "decline")
        self.assertEqual(self._state(cid), "declined")

    def test_callee_busy_without_a_real_call_keeps_ringing(self):
        cid = self.place()["call_id"]
        b = self.ev(self.cb, cid, "busy")
        self.assertEqual(b["state"], "ringing")
        self.assertEqual(b["end_reason"], "")

    def test_answer_is_idempotent_and_hangup_ends_both(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        first = CallRecord.objects.get(pk=cid).answered_at
        self.ev(self.cb, cid, "answer")
        self.assertEqual(CallRecord.objects.get(pk=cid).answered_at, first)
        self.ev(self.ca, cid, "connected")
        self.assertEqual(self._state(cid), "active")
        self.ev(self.cb, cid, "reconnect")
        self.assertEqual(self._state(cid), "reconnecting")
        self.ev(self.ca, cid, "connected")
        self.assertEqual(self._state(cid), "active")
        end = self.ev(self.ca, cid, "hangup")
        self.assertEqual(end["state"], "ended")
        self.assertEqual(end["end_reason"], "hangup")
        self.assertEqual(self.cb.get(f"{V}/circle/calls/{cid}").json()["state"],
                         "ended")

    def test_events_after_end_never_revive_the_call(self):
        cid = self.place()["call_id"]
        self.ev(self.ca, cid, "cancel")
        self.assertEqual(self._state(cid), "canceled")
        for ev in ("answer", "connected", "reconnect", "hangup", "fail"):
            body = self.ev(self.cb, cid, ev)
            self.assertEqual(body["state"], "canceled", ev)
            self.assertEqual(body["end_reason"], "canceled", ev)
        r = self.cb.post(f"{V}/circle/{self.ba.id}/call/answer",
                         {"call_id": cid}, format="json")
        self.assertEqual(r.status_code, 410)
        # signalling after the end is refused too
        self.assertEqual(self.signal(self.ca, cid, "offer", {"sdp": "x"}).status_code,
                         410)

    def test_callee_hangup_while_ringing_is_a_decline(self):
        cid = self.place()["call_id"]
        body = self.ev(self.cb, cid, "hangup")
        self.assertEqual(body["end_reason"], "declined")

    def test_unknown_event_is_a_noop(self):
        cid = self.place()["call_id"]
        self.assertEqual(self.ev(self.ca, cid, "explode")["state"], "ringing")

    def test_another_users_member_id_is_404(self):
        # A must not place a call through B's circle row
        r = self.ca.post(f"{V}/circle/{self.ba.id}/call", {"kind": "voice"},
                         format="json")
        self.assertEqual(r.status_code, 404)
        r = self.ca.post(f"{V}/circle/{self.ba.id}/call/answer", {}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(CallRecord.objects.count(), 0)

    def test_blocked_callee_is_never_rung_and_block_not_revealed(self):
        CircleMember.objects.filter(pk=self.ba.pk).update(blocked=True)
        r = self.ca.post(f"{V}/circle/{self.ab.id}/call", {"kind": "voice"},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["allowed"])
        self.assertEqual(r.json()["reason"], "unavailable")
        self.assertEqual(CallRecord.objects.count(), 0)
        self.assertFalse(RtEvent.objects.filter(user=self.b,
                                                topic="call.incoming").exists())

    def test_incoming_list_only_for_the_callee(self):
        cid = self.place()["call_id"]
        inc_b = self.cb.get(f"{V}/circle/calls/incoming").json()["calls"]
        self.assertEqual([c["call_id"] for c in inc_b], [cid])
        self.assertEqual(self.ca.get(f"{V}/circle/calls/incoming").json()["calls"], [])
        stranger = User.objects.create_user(name="S", phone="01740000198",
                                            password="pw12345!")
        cs = APIClient()
        cs.force_authenticate(stranger)
        self.assertEqual(cs.get(f"{V}/circle/calls/incoming").json()["calls"], [])
        # and the stranger cannot answer it through the legacy endpoint
        self.assertEqual(self._state(cid), "ringing")

    def test_incoming_hidden_when_callee_later_blocks_caller(self):
        cid = self.place()["call_id"]
        CircleMember.objects.filter(pk=self.ba.pk).update(blocked=True)
        inc = self.cb.get(f"{V}/circle/calls/incoming").json()["calls"]
        self.assertNotIn(cid, [c["call_id"] for c in inc])

    def test_unauthenticated_is_rejected(self):
        cid = self.place()["call_id"]
        anon = APIClient()
        self.assertIn(anon.get(f"{V}/circle/calls/{cid}").status_code, (401, 403))
        self.assertIn(anon.post(f"{V}/circle/calls/{cid}/event",
                                {"event": "hangup"}, format="json").status_code,
                      (401, 403))
        self.assertEqual(self._state(cid), "ringing")
