"""m3-circle — My Circle "works like WhatsApp", PROVEN end to end.

Two accounts registered through the REAL /auth/register endpoint (B as
01865052200). Every step below is a real HTTP round trip:

  A finds B by "+880 1865-052200" -> sends a request -> B sees it at the top
  (incoming, accept/decline) -> B "adds A back" typing A's number in another
  format (8801…) which IS accepting -> both are connected -> E2E envelopes
  both ways -> voice call: create -> ring push payload (FCM mocked, data-only)
  -> callee answers -> hang up -> video call the same way -> call history.

Plus: chat commands "circle" / "my circle" / "add someone" (+ Bangla) carry
route "circle_add" (root cause of the owner's "no match"), invite links use
the live base + /i/<token> page, and QR / share-link redeem.
"""
import json
import os
import tempfile
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import push
from core.models import CallRecord, CircleInvite, CircleMember, Device, User

from .tests_push import SA, FakeFCM

PASSWORD = "Strong#Pass123"
OWNER_NO = "01865052200"


def _auth(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token "
                  + Token.objects.get_or_create(user=user)[0].key,
                  HTTP_ACCEPT_LANGUAGE="en")
    return c


def _register(name, phone):
    r = APIClient().post("/api/v1/auth/register",
                         {"name": name, "phone": phone, "password": PASSWORD},
                         format="json")
    assert r.status_code == 201, r.content
    u = User.objects.get(name=name)
    u.trial_until = timezone.now() + timedelta(days=30)  # video is plan-gated
    u.save(update_fields=["trial_until"])
    return u


class TwoPhoneEndToEnd(TestCase):
    """The owner's two-phone test, on the real endpoints."""

    def setUp(self):
        push.reset_cache()
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(SA, self.tmp)
        self.tmp.close()
        self.fake = FakeFCM()
        p1 = override_settings(FCM_SERVICE_ACCOUNT_FILE=self.tmp.name,
                               PUSH_SYNC=True)
        p1.enable()
        self.addCleanup(p1.disable)
        p2 = mock.patch.object(push, "_http_post", self.fake)
        p2.start()
        self.addCleanup(p2.stop)
        self.addCleanup(os.unlink, self.tmp.name)
        self.addCleanup(push.reset_cache)
        self.a = _register("Amina A", "01711000001")
        self.b = _register("Owner B", OWNER_NO)
        Device.objects.create(user=self.a, push_token="adev")
        Device.objects.create(user=self.b, push_token="bdev")
        self.ca, self.cb = _auth(self.a), _auth(self.b)

    def _members(self, c):
        r = c.get("/api/v1/circle/members")
        self.assertEqual(r.status_code, 200)
        return r.json()["results"]

    def test_add_accept_message_voice_video(self):
        a, b, ca, cb = self.a, self.b, self.ca, self.cb
        self.assertEqual(b.phone, "+8801865052200")

        # 1. A: My Circle -> + -> Add to My Circle -> types "+880 1865-052200"
        r = ca.post("/api/v1/messenger/contacts/lookup",
                    {"phone": "+880 1865-052200"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d["found"])
        self.assertEqual(d["user"]["id"], b.id)
        self.assertEqual(d["user"]["circle"]["state"], "none")

        # 2. relation = friend -> Send request
        r = ca.post("/api/v1/circle/request",
                    {"to_user_id": b.id, "relation": "friend"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["state"], "pending")
        # sending twice never duplicates
        r2 = ca.post("/api/v1/circle/request",
                     {"phone": "01865052200", "relation": "friend"}, format="json")
        self.assertEqual(r2.status_code, 200)
        self.assertEqual(r2.json()["id"], r.json()["id"])

        # 3. B: the request is at the TOP of My Circle (incoming, accept/decline)
        reqs = cb.get("/api/v1/circle/requests").json()["results"]
        inc = [x for x in reqs if x["direction"] == "incoming"]
        self.assertEqual(len(inc), 1)
        self.assertIn("accept", inc[0]["actions"])
        self.assertIn("decline", inc[0]["actions"])
        self.assertEqual(inc[0]["display_name"], "Amina A")
        # A sees it as "sent" (cancel only)
        out = [x for x in ca.get("/api/v1/circle/requests").json()["results"]
               if x["direction"] == "outgoing"]
        self.assertEqual(len(out), 1)
        self.assertNotIn("accept", out[0]["actions"])

        # 4. B adds A back typing A's number in ANOTHER format -> accepted
        r = cb.post("/api/v1/messenger/contacts/lookup",
                    {"phone": "8801711000001"}, format="json")
        self.assertEqual(r.json()["user"]["circle"]["state"], "incoming")
        r = cb.post("/api/v1/circle/request",
                    {"to_user_id": a.id, "relation": "colleague"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["state"], "accepted")
        self.assertEqual(r.json()["relation"], "colleague")
        self.assertEqual(cb.get("/api/v1/circle/requests").json()["results"], [])
        self.assertEqual(ca.get("/api/v1/circle/requests").json()["results"], [])
        ma, mb = self._members(ca), self._members(cb)
        self.assertEqual([m["name"] for m in ma], ["Owner B"])
        self.assertEqual([m["name"] for m in mb], ["Amina A"])
        # exactly one edge per side, no duplicates
        self.assertEqual(CircleMember.objects.filter(user=a, peer_user=b).count(), 1)
        self.assertEqual(CircleMember.objects.filter(user=b, peer_user=a).count(), 1)
        ab, ba = ma[0]["id"], mb[0]["id"]

        # 5. both publish public keys; each side gets the other's key
        ca.post("/api/v1/circle/keys", {"public_key": "QUFB", "key_id": "ka",
                                        "scheme": "x25519-xsalsa20"}, format="json")
        cb.post("/api/v1/circle/keys", {"public_key": "QkJC", "key_id": "kb",
                                        "scheme": "x25519-xsalsa20"}, format="json")
        self.assertEqual(self._members(ca)[0]["public_key"], "QkJC")
        self.assertEqual(self._members(cb)[0]["public_key"], "QUFB")

        # 6. messages both ways (ciphertext-only envelopes) + message push
        self.fake.calls.clear()
        r = ca.post(f"/api/v1/circle/{ab}/messages",
                    {"ciphertext": "QS10by1C", "nonce": "bjE=",
                     "scheme": "x25519-xsalsa20", "client_msg_id": "m-a1"},
                    format="json")
        self.assertEqual(r.status_code, 201, r.content)
        msg_push = [p["message"] for p in self.fake.sent_payloads()]
        self.assertEqual(msg_push[0]["token"], "bdev")
        self.assertEqual(msg_push[0]["data"]["kind"], "message")
        got_b = cb.get(f"/api/v1/circle/{ba}/messages").json()["results"]
        self.assertEqual([(m["ciphertext"], m["mine"]) for m in got_b],
                         [("QS10by1C", False)])
        r = cb.post(f"/api/v1/circle/{ba}/messages",
                    {"ciphertext": "Qi10by1B", "nonce": "bjI=",
                     "scheme": "x25519-xsalsa20", "client_msg_id": "m-b1"},
                    format="json")
        self.assertEqual(r.status_code, 201, r.content)
        got_a = ca.get(f"/api/v1/circle/{ab}/messages").json()["results"]
        self.assertEqual(sorted((m["ciphertext"], m["mine"]) for m in got_a),
                         sorted([("Qi10by1B", False), ("QS10by1C", True)]))

        # 7. calls: voice then video — create -> ring push -> answer -> hang up
        for kind in ("voice", "video"):
            self.fake.calls.clear()
            r = ca.post(f"/api/v1/circle/{ab}/call", {"kind": kind}, format="json")
            self.assertEqual(r.status_code, 201, r.content)
            body = r.json()
            self.assertTrue(body["allowed"])
            self.assertEqual(body["kind"], kind)
            self.assertIn("ice", body)
            call_id = body["call_id"]
            ring = self.fake.sent_payloads()[0]["message"]
            self.assertEqual(ring["token"], "bdev")
            self.assertNotIn("notification", ring)  # data-only ring
            self.assertEqual(ring["data"]["kind"], "call")
            self.assertEqual(ring["data"]["call_id"], str(call_id))
            self.assertEqual(ring["data"]["caller_name"], "Amina A")
            self.assertEqual(ring["data"]["video"], "true" if kind == "video" else "false")
            self.assertEqual(ring["data"]["chat_id"], str(ba))
            rec = CallRecord.objects.get(pk=call_id)
            self.assertEqual((rec.caller_id, rec.callee_id, rec.state),
                             (a.id, b.id, "ringing"))
            # B (callee) answers from the incoming-call screen
            r = cb.post(f"/api/v1/circle/{ba}/call/answer", {"kind": kind},
                        format="json")
            self.assertEqual(r.status_code, 201, r.content)
            r = cb.post(f"/api/v1/circle/calls/{call_id}/event",
                        {"event": "answer"}, format="json")
            self.assertEqual(r.json()["state"], "connecting")
            r = ca.post(f"/api/v1/circle/calls/{call_id}/event",
                        {"event": "connected"}, format="json")
            self.assertEqual(r.json()["state"], "active")
            r = ca.post(f"/api/v1/circle/calls/{call_id}/event",
                        {"event": "hangup"}, format="json")
            self.assertEqual(r.json()["state"], "ended")
            rec.refresh_from_db()
            self.assertIsNotNone(rec.ended_at)
            self.assertIsNotNone(rec.answered_at)
        hist = ca.get("/api/v1/circle/calls")
        self.assertEqual(hist.status_code, 200)

    def test_decline_shows_nothing_and_cancel_before_answer_stops_ring(self):
        a, b, ca, cb = self.a, self.b, self.ca, self.cb
        ca.post("/api/v1/circle/request", {"phone": "০১৮৬৫০৫২২০০",
                                           "relation": "friend"}, format="json")
        inc = cb.get("/api/v1/circle/requests").json()["results"][0]
        r = cb.post(f"/api/v1/circle/request/{inc['id']}/act",
                    {"event": "decline"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._members(ca), [])
        self.assertEqual(self._members(cb), [])
        # A's outgoing row converged to declined (no ghost "Sent")
        self.assertEqual(ca.get("/api/v1/circle/requests").json()["results"], [])


class AddEdgeCases(TestCase):
    def setUp(self):
        self.a = User.objects.create_user(name="A", phone="01711000101", password="x")
        self.b = User.objects.create_user(name="B", phone=OWNER_NO, password="x")
        self.ca, self.cb = _auth(self.a), _auth(self.b)

    def test_not_on_assisto_is_honest(self):
        r = self.ca.post("/api/v1/messenger/contacts/lookup",
                         {"phone": "01999 888 777"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["found"])
        self.assertEqual(r.json()["phone"], "+8801999888777")

    def test_invalid_and_self(self):
        r = self.ca.post("/api/v1/messenger/contacts/lookup", {"phone": "12345"},
                         format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "bad_phone")
        r = self.ca.post("/api/v1/messenger/contacts/lookup",
                         {"phone": "+8801711000101"}, format="json")
        self.assertTrue(r.json()["is_self"])
        r = self.ca.post("/api/v1/circle/request", {"phone": "01711-000101",
                                                    "relation": "friend"},
                         format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "self_request")

    def test_adding_an_accepted_contact_again_returns_the_edge(self):
        self.ca.post("/api/v1/circle/request", {"to_user_id": self.b.id,
                                                "relation": "friend"}, format="json")
        inc = CircleMember.objects.get(user=self.b, direction="incoming")
        self.cb.post(f"/api/v1/circle/request/{inc.id}/act", {"event": "accept"},
                     format="json")
        r = self.cb.post("/api/v1/circle/request", {"phone": "01711000101",
                                                    "relation": "friend"},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["id"], inc.id)
        self.assertEqual(CircleMember.objects.filter(user=self.b).count(), 1)
        self.assertEqual(CircleMember.objects.filter(user=self.a).count(), 1)


class InviteLinkAndRedeem(TestCase):
    def setUp(self):
        self.a = User.objects.create_user(name="Inviter", phone="01711000201", password="x")
        self.b = User.objects.create_user(name="Joiner", phone="01711000202", password="x")
        self.ca, self.cb = _auth(self.a), _auth(self.b)

    @override_settings(ASSISTO_BASE_URL="https://lifeassisto.com")
    def test_share_link_uses_live_base_and_redeems_once(self):
        r = self.ca.post("/api/v1/messenger/invite/share-link",
                         {"relation": "friend"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        url = r.json()["link"]
        self.assertIn(url, r.json()["share_text"])
        self.assertTrue(url.startswith("https://lifeassisto.com/i/"), url)
        self.assertNotIn("asalify", json.dumps(r.json()))
        # the page behind the link exists (no login)
        page = APIClient().get(url.replace("https://lifeassisto.com", ""))
        self.assertEqual(page.status_code, 200)
        self.assertIn("Inviter", page.content.decode())
        # B pastes the link in My Circle -> connected both ways
        r = self.cb.post("/api/v1/circle/invite/redeem", {"link": url}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["member"]["state"], "accepted")
        self.assertEqual(r.json()["inviter"]["name"], "Inviter")
        self.assertTrue(CircleMember.objects.filter(
            user=self.a, peer_user=self.b, state="accepted").exists())
        self.assertTrue(CircleMember.objects.filter(
            user=self.b, peer_user=self.a, state="accepted").exists())
        # re-redeeming by the same person is idempotent, a third person is refused
        r = self.cb.post("/api/v1/circle/invite/redeem", {"link": url}, format="json")
        self.assertEqual(r.status_code, 200)
        c = User.objects.create_user(name="C", phone="01711000203", password="x")
        r = _auth(c).post("/api/v1/circle/invite/redeem", {"link": url}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "used")

    @override_settings(ASSISTO_BASE_URL="https://lifeassisto.com")
    def test_qr_invite_token_and_errors(self):
        r = self.ca.get("/api/v1/circle/invite?relation=colleague")
        self.assertTrue(r.json()["link"].startswith("https://lifeassisto.com/i/"))
        tok = r.json()["token"]
        # own invite
        r = self.ca.post("/api/v1/circle/invite/redeem", {"token": tok}, format="json")
        self.assertEqual(r.json()["reason"], "self_invite")
        # tampered
        r = self.cb.post("/api/v1/circle/invite/redeem", {"token": tok + "x"},
                         format="json")
        self.assertEqual(r.json()["reason"], "bad_token")
        r = self.cb.post("/api/v1/circle/invite/redeem", {"token": ""}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.cb.post("/api/v1/circle/invite/redeem", {"token": tok}, format="json")
        self.assertEqual(r.status_code, 200)
        mine = CircleMember.objects.get(user=self.b, peer_user=self.a)
        self.assertEqual(mine.relation, "colleague")
        self.assertTrue(CircleInvite.objects.get(token=tok).used)


class ChatCommandsOpenCircleAdd(TestCase):
    """Root cause of "circle -> no match": a bare command is intent
    'ambiguous', and the agent dropped the route for ambiguous text."""

    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01711000301", password="x")
        self.c = _auth(self.u)

    def test_commands_route_to_circle_add(self):
        for text in ("circle", "my circle", "My Circle!", "open my circle",
                     "add someone", "add to my circle", "সার্কেল",
                     "আমার সার্কেল", "কাউকে যোগ করুন", "সার্কেলে যোগ করো"):
            for lang in ("en", "bn"):
                r = self.c.post("/api/v1/agent", {"text": text, "lang": lang},
                                format="json", HTTP_ACCEPT_LANGUAGE=lang)
                self.assertEqual(r.status_code, 200)
                self.assertEqual(r.json()["route"], "circle_add", (text, lang))

    def test_questions_still_answered_in_chat(self):
        r = self.c.post("/api/v1/agent", {"text": "what is a circle of fifths?"},
                        format="json")
        self.assertNotEqual(r.json()["route"], "circle_add")
        from core import screen_synonyms as S
        self.assertIsNone(S.resolve_command("what is a circle of fifths"))
        self.assertIsNone(S.resolve_command("help"))


class SeedRealityHasTheSecondPhone(TestCase):
    def test_seed_users(self):
        from core.management.commands import seed_reality as SR
        self.assertEqual(SR.USERS["c"]["phone"], OWNER_NO)
