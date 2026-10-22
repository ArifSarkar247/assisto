"""x1-calls — the build-183 call fixes (owner order A1, 22 Oct).

Root cause reproduced here: the phone POSTed /circle/<id>/call TWICE (chat
screen "gate check" + the call screen's own place), the second record was
ended "busy" by the server (caller saw Busy, callee got Missed rows) and the
callee answered a call the caller's screen was not on (stuck "Connecting…").
"""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone

from core.logic import call_signal as CS
from core.logic import rtc as RTC
from core.models import CallRecord, CallSession, CircleMember, RtEvent, User
from core.tests_c2_calls import V, _Pair
from core import views_c2_calls as C2


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class X1PlaceTests(_Pair, TestCase):
    def setUp(self):
        self.mk()
        self.online(self.b)

    def _place(self, client, member, key=None, kind="voice"):
        body = {"kind": kind}
        if key:
            body["client_call_id"] = key
        r = client.post(f"{V}/circle/{member.id}/call", body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()

    # ---- A1-a: the double POST ---------------------------------------------
    def test_same_key_twice_is_one_call(self):
        a = self._place(self.ca, self.ab, key="k-1")
        b = self._place(self.ca, self.ab, key="k-1")
        self.assertEqual(a["call_id"], b["call_id"])
        self.assertTrue(b["deduped"])
        self.assertEqual(CallRecord.objects.count(), 1)
        self.assertEqual(b["phase"], "calling")
        self.assertEqual(b["end_reason"], "")

    def test_double_post_without_key_is_deduped_never_busy(self):
        a = self._place(self.ca, self.ab)
        b = self._place(self.ca, self.ab)
        self.assertEqual(a["call_id"], b["call_id"])
        self.assertEqual(CallRecord.objects.count(), 1)
        self.assertNotEqual(b["end_reason"], "busy")
        # the callee was rung ONCE and got no missed-call rows
        inc = RtEvent.objects.filter(user=self.b, topic="call.incoming").count()
        self.assertEqual(inc, 1)
        self.assertFalse(CallSession.objects.filter(missed_notified=True).exists())

    def test_key_reused_after_dedupe_window_still_same_call(self):
        a = self._place(self.ca, self.ab, key="k-2")
        CallRecord.objects.filter(pk=a["call_id"]).update(
            started_at=timezone.now() - timedelta(seconds=CS.DEDUPE_WINDOW_S + 5))
        b = self._place(self.ca, self.ab, key="k-2")
        self.assertEqual(a["call_id"], b["call_id"])

    def test_new_tap_after_end_is_a_new_call(self):
        a = self._place(self.ca, self.ab, key="k-3")
        self.ev(self.ca, a["call_id"], "cancel")
        b = self._place(self.ca, self.ab, key="k-4")
        self.assertNotEqual(a["call_id"], b["call_id"])
        self.assertEqual(b["phase"], "calling")

    def test_old_live_call_to_same_person_is_superseded(self):
        a = self._place(self.ca, self.ab, key="k-5")
        CallRecord.objects.filter(pk=a["call_id"]).update(
            started_at=timezone.now() - timedelta(seconds=CS.DEDUPE_WINDOW_S + 1))
        CallSession.objects.filter(call_id=a["call_id"]).update(
            ringing_at=timezone.now(), caller_seen_at=timezone.now())
        b = self._place(self.ca, self.ab, key="k-6")
        self.assertNotEqual(a["call_id"], b["call_id"])
        self.assertEqual(CallRecord.objects.get(pk=a["call_id"]).state, "canceled")
        self.assertNotEqual(b["end_reason"], "busy")

    # ---- A1-f: glare ----------------------------------------------------------
    def test_glare_merges_into_one_call(self):
        self.online(self.a)
        a = self._place(self.ca, self.ab, key="a-1")
        b = self._place(self.cb, self.ba, key="b-1")
        self.assertEqual(a["call_id"], b["call_id"])
        self.assertTrue(b["merged"])
        self.assertEqual(b["role"], "callee")
        self.assertEqual(b["side"], "callee")
        self.assertEqual(b["phase"], "accepted")
        self.assertEqual(CallRecord.objects.count(), 1)
        self.assertEqual(CallRecord.objects.get().state, "connecting")
        # the first caller hears "accepted" (never busy)
        st = self.ca.get(f"{V}/circle/calls/{a['call_id']}").json()
        self.assertEqual(st["phase"], "accepted")

    # ---- A1-f: busy only when truly active ------------------------------------
    def _third(self):
        c = User.objects.create_user(name="Chompa", phone="01740000103",
                                     password="pw12345!")
        CircleMember.objects.create(user=c, peer_user=self.b, name="Babu",
                                    state="accepted", phone="01740000102")
        return c

    def _bc_call(self, c, state, connected=True, seen_ago=0):
        rec = CallRecord.objects.create(caller=self.b, callee=c, state=state)
        seen = timezone.now() - timedelta(seconds=seen_ago)
        CallSession.objects.create(
            call=rec, connected_at=timezone.now() if connected else None,
            caller_seen_at=seen, callee_seen_at=seen,
            ringing_at=timezone.now())
        return rec

    def test_busy_only_when_media_connected_and_heartbeat_fresh(self):
        c = self._third()
        self._bc_call(c, "active", connected=True)
        body = self._place(self.ca, self.ab)
        self.assertEqual(body["end_reason"], "busy")

    def test_not_busy_when_other_call_only_ringing_or_connecting(self):
        c = self._third()
        for st in ("ringing", "connecting"):
            other = self._bc_call(c, st, connected=False)
            body = self._place(self.ca, self.ab)
            self.assertNotEqual(body["end_reason"], "busy", st)
            self.ev(self.ca, body["call_id"], "cancel")
            other.delete()

    def test_not_busy_when_other_call_heartbeat_stale(self):
        c = self._third()
        other = self._bc_call(c, "active", connected=True,
                              seen_ago=CS.HEARTBEAT_S + 5)
        body = self._place(self.ca, self.ab)
        self.assertNotEqual(body["end_reason"], "busy")
        # ... and the dead call itself was swept on this event
        self.assertEqual(CallRecord.objects.get(pk=other.pk).state, "ended")
        self.assertEqual(CallSession.objects.get(call=other).end_reason, "lost")


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class X1SweepTests(_Pair, TestCase):
    def setUp(self):
        self.mk()
        self.online(self.b)

    def _ended_event(self, client, cid):
        evs = self.events(client, topics="call.state")["events"]
        mine = [e["payload"] for e in evs if e["payload"]["call_id"] == cid]
        return mine[-1] if mine else {}

    def test_ringing_max_45s(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "ringing")
        CallRecord.objects.filter(pk=cid).update(
            started_at=timezone.now() - timedelta(seconds=CS.RING_TIMEOUT_S + 1))
        CallSession.objects.filter(call_id=cid).update(caller_seen_at=timezone.now())
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "no_answer")

    def test_connect_timeout_20s_fails_both_sides(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        self.assertEqual(CS.CONNECT_TIMEOUT_S, 20)
        CallRecord.objects.filter(pk=cid).update(
            answered_at=timezone.now() - timedelta(seconds=21))
        CallSession.objects.filter(call_id=cid).update(
            caller_seen_at=timezone.now(), callee_seen_at=timezone.now())
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual((st["phase"], st["end_reason"]), ("ended", "failed"))
        self.assertEqual(self._ended_event(self.cb, cid)["end_reason"], "failed")
        self.assertEqual(self._ended_event(self.cb, cid)["side"], "callee")

    def test_client_fail_event_ends_both(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        self.ev(self.cb, cid, "fail")
        self.assertEqual(self._ended_event(self.ca, cid)["end_reason"], "failed")

    def test_no_heartbeat_15s(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        self.ev(self.ca, cid, "connected")
        CallSession.objects.filter(call_id=cid).update(
            callee_seen_at=timezone.now() - timedelta(seconds=CS.HEARTBEAT_S + 1))
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "lost")

    def test_caller_silent_while_ringing_cancels(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "ringing")
        CallSession.objects.filter(call_id=cid).update(
            caller_seen_at=timezone.now() - timedelta(seconds=CS.HEARTBEAT_S + 1))
        st = self.cb.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "canceled")

    def test_sweep_command_and_sweep_all(self):
        cid = self.place()["call_id"]
        CallRecord.objects.filter(pk=cid).update(
            started_at=timezone.now() - timedelta(seconds=CS.OFFLINE_ACK_S + 2))
        out = StringIO()
        call_command("calls_sweep", stdout=out)
        self.assertIn("offline=1", out.getvalue())
        self.assertFalse(CS.is_live(CallRecord.objects.get(pk=cid).state))

    def test_cleanup_stale_dry_run_then_apply(self):
        old = CallRecord.objects.create(caller=self.a, callee=self.b,
                                        state="active")
        CallRecord.objects.filter(pk=old.pk).update(
            started_at=timezone.now() - timedelta(hours=5))
        CallSession.objects.create(call=old, connected_at=timezone.now(),
                                   caller_seen_at=timezone.now(),
                                   callee_seen_at=timezone.now())
        out = StringIO()
        call_command("calls_cleanup_stale", stdout=out)
        self.assertIn("DRY RUN", out.getvalue())
        self.assertIn("#%d" % old.pk, out.getvalue())
        self.assertEqual(CallRecord.objects.get(pk=old.pk).state, "active")
        with mock.patch.object(C2, "hook_missed_call") as missed:
            call_command("calls_cleanup_stale", "--apply", stdout=StringIO())
            missed.assert_not_called()
        self.assertEqual(CallRecord.objects.get(pk=old.pk).state, "ended")

    def test_rt_events_call_id_filter(self):
        c1 = self.place()["call_id"]
        self.signal(self.ca, c1, "offer", {"type": "offer", "sdp": "v=0"})
        self.ev(self.ca, c1, "cancel")
        c2 = self.place()["call_id"]
        self.signal(self.ca, c2, "offer", {"type": "offer", "sdp": "v=0 2"})
        r = self.cb.get(f"{V}/rt/events?after=0&topics=call.signal&call_id={c2}")
        evs = r.json()["events"]
        self.assertEqual({e["payload"]["call_id"] for e in evs}, {c2})


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class X1HistoryTests(_Pair, TestCase):
    def setUp(self):
        self.mk()
        self.online(self.b)

    def test_call_log_groups_repeats(self):
        for _ in range(3):
            cid = self.place()["call_id"]
            self.ev(self.ca, cid, "cancel")
        # then one answered call
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "answer")
        self.ev(self.ca, cid, "connected")
        self.ev(self.ca, cid, "hangup")
        r = self.cb.get(f"{V}/circle/calls").json()
        self.assertEqual(len(r["calls"]), 4)
        g = r["groups"]
        self.assertEqual([x["count"] for x in g], [1, 3])
        self.assertEqual(g[1]["name"], "Amina")
        self.assertEqual(len(g[1]["ids"]), 3)
        self.assertIn("photo_url", g[0])
        self.assertEqual(g[0]["peer_id"], self.a.id)

    def test_missed_streak(self):
        for _ in range(4):
            cid = self.place()["call_id"]
            self.ev(self.ca, cid, "cancel")
        rec = CallRecord.objects.get(pk=cid)
        self.assertEqual(C2.missed_streak(rec), 4)

    def test_group_history_pure(self):
        rows = [
            {"id": 5, "peer_key": 1, "outgoing": False, "category": "missed", "day": "d"},
            {"id": 4, "peer_key": 1, "outgoing": False, "category": "missed", "day": "d"},
            {"id": 3, "peer_key": 2, "outgoing": False, "category": "missed", "day": "d"},
            {"id": 2, "peer_key": 1, "outgoing": False, "category": "missed", "day": "d"},
        ]
        g = CS.group_history(rows)
        self.assertEqual([(x["count"], x["ids"]) for x in g],
                         [(2, [5, 4]), (1, [3]), (1, [2])])


class X1PureTests(TestCase):
    def test_truly_active(self):
        now = timezone.now()
        old = now - timedelta(seconds=CS.HEARTBEAT_S + 1)
        self.assertTrue(CS.is_truly_active("active", now, now, now, now))
        self.assertFalse(CS.is_truly_active("connecting", now, now, now, now))
        self.assertFalse(CS.is_truly_active("active", now, None, now, now))
        self.assertFalse(CS.is_truly_active("active", now, now, old, now))
        self.assertFalse(CS.is_truly_active("ringing", now, now, now, now))

    def test_timeouts_match_owner_order(self):
        self.assertEqual((CS.RING_TIMEOUT_S, CS.CONNECT_TIMEOUT_S, CS.HEARTBEAT_S),
                         (45, 20, 15))

    def test_turn_tls_offered_only_when_configured(self):
        creds = RTC.turn_credentials("s", 1, 1000)
        plain = RTC.ice_servers("turn.example.com", 3478, creds)
        self.assertFalse(any("turns:" in u for u in plain[1]["urls"]))
        tls = RTC.ice_servers("turn.example.com", 3478, creds, tls_port=5349)
        self.assertEqual(tls[1]["urls"], [
            "turn:turn.example.com:3478?transport=udp",
            "turn:turn.example.com:3478?transport=tcp",
            "turns:turn.example.com:5349?transport=tcp",  # LAST
        ])

    @override_settings(TURN_STATIC_SECRET="fake-ci-secret",
                       TURN_HOST="turn.example.test", TURN_PORT=3478,
                       TURN_TLS_PORT=5349, FCM_SERVICE_ACCOUNT_FILE="")
    def test_phones_get_turns_last_in_call_ice_and_rtc_turn(self):
        u = User.objects.create_user(name="T", phone="01740000151",
                                     password="pw12345!")
        urls = C2.ice_for(u)["iceServers"][1]["urls"]
        self.assertEqual(urls[-1], "turns:turn.example.test:5349?transport=tcp")
        self.assertTrue(urls[0].endswith("3478?transport=udp"))
        from rest_framework.test import APIClient
        c = APIClient()
        c.force_authenticate(u)
        with mock.patch("core.views_build61._mem_available_mb", return_value=4000), \
                mock.patch("os.getloadavg", return_value=(0.1, 0.1, 0.1)):
            r = c.get(f"{V}/rtc/turn").json()
        self.assertEqual(r["ice_servers"][1]["urls"][-1],
                         "turns:turn.example.test:5349?transport=tcp")
