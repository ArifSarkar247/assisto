"""mr1 — My Circle message requests, PROVEN on the real endpoints.

A finds B by number (any format) and texts at once -> B sees a Message
request (sender name, photo, number only if A allows, latest message) ->
B's phone gets the messages (DELIVERED) but A sees READ only after B
accepts -> Accept makes both sides text AND call at once. Block / Report /
Delete, the pre-accept limit, the daily cap, B's privacy (nobody), blocks,
and ONE push per sender (collapsed per sender).
"""
from unittest import mock

from django.test import TestCase
from rest_framework.test import APIClient

from core import msgreq, push
from core.models import (CircleMember, CircleMessage, CirclePrivacy,
                         CircleReceipt, CircleReport, User)

from .tests_m3_circle import _auth, _register


def _env(text="x", cmid=""):
    return {"content_type": "text", "ciphertext": "Q0lQSEVS" + text,
            "nonce": "bm9uY2U=", "scheme": "x25519-xsalsa20poly1305",
            "sender_key_id": "k1", "client_msg_id": cmid}


class MessageRequests(TestCase):
    def setUp(self):
        self.a = _register("Amina A", "01711000001")
        self.b = _register("Owner B", "01865052200")
        self.ca, self.cb = _auth(self.a), _auth(self.b)
        p = mock.patch("core.push.safe_push", return_value=1)
        self.push = p.start()
        self.addCleanup(p.stop)
        p2 = mock.patch("core.push.is_available", return_value=True)
        p2.start()
        self.addCleanup(p2.stop)

    # ---- helpers -----------------------------------------------------------
    def _start(self, c=None, phone="+880 1865-052200"):
        return (c or self.ca).post("/api/v1/circle/message-request/start",
                                   {"phone": phone}, format="json")

    def _send(self, mid, text="x", c=None, cmid=""):
        return (c or self.ca).post("/api/v1/circle/%s/messages" % mid,
                                   _env(text, cmid), format="json")

    def _incoming(self):
        reqs = self.cb.get("/api/v1/circle/requests").json()["results"]
        return [r for r in reqs if r["direction"] == "incoming"]

    def _kinds(self):
        return [c.args[1] for c in self.push.call_args_list]

    # ---- start -------------------------------------------------------------
    def test_start_any_format_creates_request_pair(self):
        for phone in ("01865052200", "+880 1865-052200", "8801865052200",
                      "০১৮৬৫০৫২২০০"):
            r = self._start(phone=phone)
            self.assertEqual(r.status_code, 200, r.content)
            self.assertEqual(r.json()["state"], "pending")
        # idempotent: one edge per side
        self.assertEqual(CircleMember.objects.filter(
            user=self.a, peer_user=self.b).count(), 1)
        inc = CircleMember.objects.get(user=self.b, peer_user=self.a)
        self.assertEqual((inc.direction, inc.state), ("incoming", "pending"))
        m = r.json()["member"]
        self.assertEqual(m["direction"], "outgoing")
        self.assertEqual(m["request"]["limit"], 5)
        self.assertTrue(m["request"]["can_send"])

    def test_start_refusals(self):
        r = self._start(phone="12")
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "bad_phone"))
        r = self._start(phone="01999999999")
        self.assertEqual((r.status_code, r.json()["reason"]), (404, "not_found"))
        r = self._start(phone="01711000001")
        self.assertEqual(r.json()["reason"], "self")
        # B allows nobody -> refused honestly (bilingual detail)
        CirclePrivacy.objects.create(user=self.b, who_can_message="nobody")
        r = self._start()
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (403, "strangers_refused"))
        self.assertTrue(r.json()["detail"])

    def test_start_with_someone_already_connected_returns_chat(self):
        self._start()
        mb = CircleMember.objects.get(user=self.b, peer_user=self.a)
        self.cb.post("/api/v1/circle/request/%s/act" % mb.id,
                     {"event": "accept"}, format="json")
        r = self._start()
        self.assertEqual(r.json()["state"], "accepted")

    def test_recipient_starting_back_accepts(self):
        self._start()
        r = self._start(c=self.cb, phone="01711000001")
        self.assertEqual(r.json()["state"], "accepted")
        self.assertEqual(CircleMember.objects.get(
            user=self.a, peer_user=self.b).state, "accepted")

    def test_daily_cap(self):
        with mock.patch.object(msgreq, "limits", return_value=(5, 2)):
            for i in range(2):
                u = _register("P%d" % i, "0171100010%d" % i)
                r = self.ca.post("/api/v1/circle/message-request/start",
                                 {"to_user_id": u.id}, format="json")
                self.assertEqual(r.status_code, 200)
            u = _register("P9", "01711000109")
            r = self.ca.post("/api/v1/circle/message-request/start",
                             {"to_user_id": u.id}, format="json")
            self.assertEqual((r.status_code, r.json()["reason"]),
                             (429, "rate_limited"))
            # the Add-to-My-Circle request path shares the cap
            r = self.ca.post("/api/v1/circle/request",
                             {"to_user_id": u.id, "relation": "friend"},
                             format="json")
            self.assertEqual(r.status_code, 429)

    def test_limit_is_owner_editable_in_pricing_limits(self):
        from core.logic import pricing
        cfg = pricing.normalize({"limits": {"message_request_max_msgs": 3,
                                            "message_requests_per_day": 9}})
        self.assertEqual(cfg["limits"]["message_request_max_msgs"], 3)
        self.assertEqual(cfg["limits"]["message_requests_per_day"], 9)
        d = pricing.normalize({})["limits"]
        self.assertEqual((d["message_request_max_msgs"],
                          d["message_requests_per_day"]), (5, 20))

    # ---- sending before accept --------------------------------------------
    def test_send_before_accept_limit_and_dedupe(self):
        mid = self._start().json()["member"]["id"]
        for i in range(5):
            r = self._send(mid, str(i), cmid="c%d" % i)
            self.assertEqual(r.status_code, 201, r.content)
        r = self._send(mid, "6", cmid="c6")
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (403, "request_limit"))
        # an outbox retry of a stored one is a dedupe, not a refusal
        r = self._send(mid, "4", cmid="c4")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["deduped"])
        m = self.ca.get("/api/v1/circle/members")  # not a member yet
        self.assertEqual(m.json()["results"], [])

    def test_recipient_cannot_reply_before_accept(self):
        self._start()
        mb = CircleMember.objects.get(user=self.b, peer_user=self.a)
        r = self._send(mb.id, c=self.cb)
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (403, "accept_first"))

    def test_one_push_per_sender_and_silent_delivery(self):
        mid = self._start().json()["member"]["id"]
        self.push.reset_mock()
        self._send(mid, "1")
        self._send(mid, "2")
        self._send(mid, "3")
        kinds = self._kinds()
        self.assertEqual(kinds.count("message_request"), 1)
        self.assertEqual(kinds.count("msg_sync"), 3)
        self.assertNotIn("message", kinds)
        call = [c for c in self.push.call_args_list
                if c.args[1] == "message_request"][0]
        self.assertEqual(call.args[0], self.b)
        self.assertIn("Amina A", call.args[3])
        self.assertEqual(call.kwargs["data"]["sender_id"], self.a.id)
        self.assertEqual(call.kwargs["data"]["route"], "circle/requests")

    def test_push_collapse_key_is_per_sender(self):
        with mock.patch.object(push, "send_to_token", return_value=True) as st:
            self.push.stop()
            from core.models import Device
            Device.objects.create(user=self.b, push_token="bdev")
            push.push_to_user(self.b, "message_request", "t", "t",
                              data={"sender_id": 7})
            self.push.start()
        self.assertEqual(st.call_args.kwargs["collapse_key"], "msgreq-7")
        self.assertIsNotNone(st.call_args.args[2])  # a NOTIFICATION push

    # ---- recipient side ----------------------------------------------------
    def test_request_card_preview_phone_privacy(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "hello")
        inc = self._incoming()
        self.assertEqual(len(inc), 1)
        r = inc[0]
        self.assertEqual(r["display_name"], "Amina A")
        self.assertTrue(r["not_in_contacts"])
        self.assertEqual(r["phone"], "")          # A did not allow it
        self.assertEqual(r["msg_count"], 1)
        self.assertEqual(r["last"]["ciphertext"], "Q0lQSEVShello")
        self.assertIn("public_key", r["member"])
        self.a.show_phone = True
        self.a.save(update_fields=["show_phone"])
        self.assertEqual(self._incoming()[0]["phone"], "+8801711000001")

    def test_delivered_not_read_until_accept(self):
        mid = self._start().json()["member"]["id"]
        x = self._send(mid, "hi").json()["id"]
        mb = self._incoming()[0]["id"]
        # B opens the request (fetch + "seen")
        self.cb.get("/api/v1/circle/%s/messages" % mb)
        self.cb.post("/api/v1/circle/%s/seen" % mb)
        self.cb.post("/api/v1/circle/receipts", {"seen": [x]}, format="json")
        rc = CircleReceipt.objects.get(message_id=x, user=self.b)
        self.assertIsNotNone(rc.delivered_at)
        self.assertIsNone(rc.seen_at)
        st = self.ca.get("/api/v1/circle/%s/messages" % mid).json()
        self.assertEqual(st["results"][0]["status"], "delivered")
        self.assertEqual(st["edge"]["state"], "pending")
        # accept -> read on the next open; both can text + call at once
        r = self.cb.post("/api/v1/circle/request/%s/act" % mb,
                         {"event": "accept"}, format="json")
        self.assertEqual(r.json()["state"], "accepted")
        self.cb.post("/api/v1/circle/%s/seen" % mb)
        st = self.ca.get("/api/v1/circle/%s/messages" % mid).json()
        self.assertEqual(st["results"][0]["status"], "read")
        self.assertEqual(st["edge"]["state"], "accepted")
        self.assertEqual(self._send(mb, "reply", c=self.cb).status_code, 201)
        self.assertEqual(self._send(mid, "6th ok now").status_code, 201)
        r = self.ca.post("/api/v1/circle/%s/call" % mid, {"kind": "voice"},
                         format="json")
        self.assertNotEqual(r.json().get("reason"), "not_connected")
        self.assertNotEqual(r.status_code, 403)

    def test_no_call_before_accept(self):
        mid = self._start().json()["member"]["id"]
        r = self.ca.post("/api/v1/circle/%s/call" % mid, {"kind": "voice"},
                         format="json")
        self.assertFalse(r.json().get("allowed", True))

    def test_delete_is_silent(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "1")
        mb = self._incoming()[0]["id"]
        r = self.cb.post("/api/v1/circle/request/%s/msgreq" % mb,
                         {"action": "delete"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._incoming(), [])
        # the sender is not told: still "waiting", can still send (capped)
        self.push.reset_mock()
        self.assertEqual(self._send(mid, "2").status_code, 201)
        self.assertEqual(self._kinds(), [])          # nothing reaches B
        self.assertEqual(CircleMember.objects.get(pk=mid).state, "pending")

    def test_block_drops_messages(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "1")
        mb = self._incoming()[0]["id"]
        self.cb.post("/api/v1/circle/request/%s/msgreq" % mb,
                     {"action": "block"}, format="json")
        r = self._send(mid, "2")
        self.assertTrue(r.json().get("dropped"))
        self.assertEqual(CircleMessage.objects.filter(member_id=mid).count(), 1)
        self.assertIn(mb, [x["id"] for x in
                           self.cb.get("/api/v1/circle/blocked").json()["blocked"]])
        # B cannot be re-requested while blocked: A's start keeps the edge,
        # messages keep dropping; B starting a chat is refused (unblock first)
        r = self._start(c=self.cb, phone="01711000001")
        self.assertEqual(r.json()["reason"], "you_blocked")

    def test_report_files_and_blocks(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "spam")
        mb = self._incoming()[0]["id"]
        r = self.cb.post("/api/v1/circle/request/%s/msgreq" % mb,
                         {"action": "report", "reason": "spam"}, format="json")
        self.assertTrue(r.json()["reported"])
        self.assertTrue(r.json()["blocked"])
        self.assertEqual(CircleReport.objects.filter(reporter=self.b).count(), 1)

    def test_only_recipient_can_act(self):
        mid = self._start().json()["member"]["id"]
        r = self.ca.post("/api/v1/circle/request/%s/msgreq" % mid,
                         {"action": "delete"}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_sender_chat_list_shows_request_once_sent(self):
        mid = self._start().json()["member"]["id"]
        rows = self.ca.get("/api/v1/circle/chats").json()["results"]
        self.assertEqual([r for r in rows if r.get("id") == str(mid)], [])
        self._send(mid, "1")
        rows = self.ca.get("/api/v1/circle/chats").json()["results"]
        row = [r for r in rows if r.get("id") == str(mid)][0]
        self.assertEqual(row["request"], "outgoing")
        self.assertEqual(row["member"]["request"]["sent"], 1)
        # B's chat list does not show it (it lives in Message requests)
        rows = self.cb.get("/api/v1/circle/chats").json()["results"]
        self.assertEqual([r for r in rows if not r.get("is_group")], [])

    def test_they_blocked_me_is_not_revealed(self):
        mid = self._start().json()["member"]["id"]
        CircleMember.objects.filter(user=self.b, peer_user=self.a).update(
            blocked=True)
        r = self._send(mid, "1")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["dropped"])

    def test_peer_key_is_requested_for_a_pending_request(self):
        mid = self._start().json()["member"]["id"]
        r = self.ca.get("/api/v1/circle/keys/peer/%s" % mid)
        self.assertEqual(r.status_code, 200)
        self.assertIn("requested", r.json())


class StartByUserId(TestCase):
    def test_unknown_user(self):
        a = _register("Amina A", "01711000001")
        r = _auth(a).post("/api/v1/circle/message-request/start",
                          {"to_user_id": 99999}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertFalse(APIClient().post(
            "/api/v1/circle/message-request/start", {}).status_code == 200)
        self.assertTrue(User.objects.exists())
