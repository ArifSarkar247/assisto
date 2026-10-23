"""ty1 — the two reality My Circle flows replayed against the server, the
way the CI emulator drives it: the `seed_reality` accounts, REAL token auth
(no force_authenticate), only the HTTP endpoints the phones call.

  19_circle_ticks: B posts typing.set -> A's next rt/events poll carries
      typing.update with A's OWN chat key ("member:<A's edge id>") ->
      "stop" clears it; B is shown online.
  18_circle_real_call: A's app polls rt/events (= reachable) -> B video-calls
      A -> call.incoming is queued for A at once. If A's phone never says
      "ringing" the call ends "offline" after OFFLINE_ACK_S — which is
      exactly what B saw on the emulator: the server path worked, the app
      under test never ran its real-time loop (harness gap + startup safe
      mode, fixed in the app by ty1). With the ack the call keeps ringing.

Run: manage.py test core.tests_ty1_circle_live --settings=assisto_backend.settings_test
"""
import json
import os
import tempfile
from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import push
from core.logic import call_signal as CS
from core.management.commands import seed_reality as SR
from core.models import CallRecord

V = "/api/v1"


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class RealityCircleLiveTests(TestCase):
    def setUp(self):
        push.reset_cache()
        f = os.path.join(tempfile.mkdtemp(), "seed.json")
        call_command("seed_reality", out=f, stdout=StringIO())
        self.seed = json.load(open(f))
        from core.phone import find_user
        self.ua = find_user(SR.USERS["a"]["phone"])
        self.ub = find_user(SR.USERS["b"]["phone"])
        self.A, self.B = self._client(self.ua), self._client(self.ub)
        self.edge_a = self.seed["circle"]["a_member_id"]  # A's chat id for B
        self.edge_b = self.seed["circle"]["b_member_id"]  # B's chat id for A

    def _client(self, user):
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get(user=user).key,
                      HTTP_ACCEPT_LANGUAGE="en")
        return c

    def poll(self, c, after):
        r = c.get(f"{V}/rt/events?after={after}&online=1")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def send(self, c, topic, payload):
        r = c.post(f"{V}/rt/send", {"topic": topic, "payload": payload},
                   format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_seed_is_an_accepted_pair(self):
        self.assertEqual(self.seed["failed_steps"], [])
        self.assertEqual((self.seed["circle"]["a_state"],
                          self.seed["circle"]["b_state"]), ("accepted", "accepted"))

    def test_19_typing_reaches_a_with_a_chat_key_then_clears(self):
        for c in (self.A, self.B):
            r = c.post(f"{V}/circle/privacy", {
                "visibility": {"last_seen": "everyone", "active_status": "everyone"},
                "read_receipts": True, "typing": True}, format="json")
            self.assertLess(r.status_code, 300, r.content)
        # A's chat screen is open: its loop learned the current seq
        seq = self.poll(self.A, 0)["seq"]
        self.send(self.B, "typing.set", {"chat_kind": "member",
                                         "chat_id": self.edge_b, "state": "typing"})
        got = self.poll(self.A, seq)
        typing = [e for e in got["events"] if e["topic"] == "typing.update"]
        self.assertEqual(len(typing), 1, got)
        self.assertEqual(typing[0]["payload"]["chat"], "member:%d" % self.edge_a)
        self.assertEqual(typing[0]["payload"]["activity"], "typing")
        self.assertGreaterEqual(typing[0]["payload"]["ttl_s"], 5,
                                "outlives the app's 2.5-5 s poll")
        pres = [e for e in got["events"] if e["topic"] == "presence.update"]
        self.assertTrue(pres and pres[-1]["payload"]["online"], got)
        seq = got["seq"]
        self.send(self.B, "typing.set", {"chat_kind": "member",
                                         "chat_id": self.edge_b, "state": "stop"})
        got = self.poll(self.A, seq)
        typing = [e for e in got["events"] if e["topic"] == "typing.update"]
        self.assertEqual(typing[-1]["payload"]["activity"], "")
        snap = self.A.get(f"{V}/circle/rt/state").json()["chats"]
        self.assertEqual(snap["member:%d" % self.edge_a]["activity"], "")
        self.assertTrue(snap["member:%d" % self.edge_a]["online"])

    def _video_call_b_to_a(self):
        r = self.B.post(f"{V}/circle/{self.edge_b}/call", {"kind": "video"},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()

    def test_18_incoming_is_queued_for_a_foreground_app_without_fcm(self):
        seq = self.poll(self.A, 0)["seq"]  # A's app is open (presence)
        body = self._video_call_b_to_a()
        self.assertEqual(body["phase"], "calling", body)
        got = self.poll(self.A, seq)
        inc = [e for e in got["events"] if e["topic"] == "call.incoming"]
        self.assertEqual(len(inc), 1, got)
        self.assertEqual(inc[0]["payload"]["call_id"], body["call_id"])
        self.assertEqual(inc[0]["payload"]["chat_id"], self.edge_a)
        self.assertTrue(inc[0]["payload"]["video"] is True
                        or inc[0]["payload"].get("kind") == "video", inc[0])
        # the app's in-app ring acks -> B sees "ringing" and it keeps ringing
        r = self.A.post(f"{V}/circle/calls/{body['call_id']}/event",
                        {"event": "ringing"}, format="json")
        self.assertEqual(r.json()["phase"], "ringing", r.content)
        rec = CallRecord.objects.get(pk=body["call_id"])
        CallRecord.objects.filter(pk=rec.pk).update(
            started_at=timezone.now() - timedelta(seconds=CS.OFFLINE_ACK_S + 3))
        st = self.B.get(f"{V}/circle/calls/{body['call_id']}").json()
        self.assertEqual(st["phase"], "ringing", st)

    def test_18_no_ring_ack_ends_offline_like_the_emulator_run(self):
        self.poll(self.A, 0)
        body = self._video_call_b_to_a()
        CallRecord.objects.filter(pk=body["call_id"]).update(
            started_at=timezone.now() - timedelta(seconds=CS.OFFLINE_ACK_S + 3))
        st = self.B.get(f"{V}/circle/calls/{body['call_id']}").json()
        self.assertEqual((st["phase"], st["end_reason"]), ("ended", "offline"))

    def test_18_app_never_polled_is_offline_at_once(self):
        # no FCM device and no recent poll: the server says so honestly
        body = self._video_call_b_to_a()
        self.assertEqual((body["phase"], body.get("end_reason")),
                         ("ended", "offline"))
