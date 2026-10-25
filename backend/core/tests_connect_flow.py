"""connect-flow — My Circle CONNECT FLOW (owner order 25 Oct), on the real
endpoints with two (or three) accounts:

  * 3 TEXT messages before accept, the 4th refused; no media / links /
    forwards before accept (server-enforced, every refusal says why);
  * daily caps per sender AND per recipient;
  * no receipts, presence or typing reach the sender before accept;
  * accept -> connected_at on BOTH rows (system line), the chat tops BOTH
    chat lists, ONE "X accepted your request — say hi" push opening the chat;
  * decline is never revealed; report goes to moderation;
  * a phone-number invite: the invitee registers -> the request is in their
    Requests box -> accept -> the chat appears for both, same line + push.
"""
from unittest import mock

from django.test import TestCase

from core import connect_flow, msgreq
from core.models import (CircleMember, CircleMessage, CircleReceipt,
                         ModerationReport, User)

from .tests_m3_circle import _auth, _register


def _env(text="x", cmid="", **extra):
    e = {"content_type": "text", "ciphertext": "Q0lQSEVS" + text,
         "nonce": "bm9uY2U=", "scheme": "x25519-xsalsa20poly1305",
         "sender_key_id": "k1", "client_msg_id": cmid}
    e.update(extra)
    return e


class _Base(TestCase):
    def setUp(self):
        self.a = _register("Amina A", "01711000001")
        self.b = _register("Owner B", "01711000777")
        self.ca, self.cb = _auth(self.a), _auth(self.b)
        p = mock.patch("core.push.safe_push", return_value=1)
        self.push = p.start()
        self.addCleanup(p.stop)
        p2 = mock.patch("core.push.is_available", return_value=True)
        p2.start()
        self.addCleanup(p2.stop)

    def _start(self, c=None, **body):
        body = body or {"phone": "01711000777"}
        return (c or self.ca).post("/api/v1/circle/message-request/start",
                                   body, format="json")

    def _send(self, mid, text="x", c=None, cmid="", **extra):
        return (c or self.ca).post("/api/v1/circle/%s/messages" % mid,
                                   _env(text, cmid, **extra), format="json")

    def _inc_id(self):
        return CircleMember.objects.get(user=self.b, peer_user=self.a).id

    def _accept(self, mb, c=None):
        return (c or self.cb).post("/api/v1/circle/request/%s/act" % mb,
                                   {"event": "accept"}, format="json")

    def _accepted_pushes(self):
        return [c for c in self.push.call_args_list
                if c.args[1] == "message_request"
                and (c.kwargs.get("data") or {}).get("event") == "accepted"]


class PreAcceptRules(_Base):
    def test_three_texts_then_the_fourth_is_refused(self):
        mid = self._start().json()["member"]["id"]
        for i in range(3):
            self.assertEqual(self._send(mid, str(i)).status_code, 201)
        r = self._send(mid, "4")
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (403, "request_limit"))
        self.assertTrue(r.json()["detail"])
        self.assertEqual(CircleMessage.objects.filter(member_id=mid).count(), 3)

    def test_no_media_links_voice_or_forwards_before_accept(self):
        mid = self._start().json()["member"]["id"]
        for extra, reason in (
                ({"content_type": "voice", "blob_ref": "b1"},
                 "media_after_accept"),
                ({"content_type": "photo", "blob_ref": "b1"},
                 "media_after_accept"),
                ({"content_type": "location"}, "text_only"),
                ({"forwarded": True, "forward_hops": 1}, "text_only"),
                ({"has_link": True}, "no_links"),
                ({"link_preview": {"ciphertext": "eA==", "nonce": "bg=="}},
                 "no_links")):
            r = self._send(mid, "x", **extra)
            self.assertEqual(r.status_code, 403, (extra, r.content))
            self.assertEqual(r.json()["reason"], reason, extra)
        # none of the refusals used the 3-message budget
        self.assertEqual(CircleMessage.objects.filter(member_id=mid).count(), 0)
        self.assertEqual(self._send(mid, "plain").status_code, 201)
        # after accept a link is a normal message again
        self._accept(self._inc_id())
        self.assertEqual(self._send(mid, "l", has_link=True).status_code, 201)

    def test_link_rule_matches_the_app(self):
        for t in ("http://x.y", "see https://a.b/c", "WWW.example.com"):
            self.assertTrue(connect_flow.has_link(t), t)
        for t in ("hello", "আমি আসছি", "w w w", "httpx"):
            self.assertFalse(connect_flow.has_link(t), t)

    def test_daily_cap_per_sender(self):
        with mock.patch.object(msgreq, "limits", return_value=(3, 1)):
            u = _register("P1", "01711000101")
            self.assertEqual(self._start(to_user_id=u.id).status_code, 200)
            r = self._start()
            self.assertEqual((r.status_code, r.json()["reason"]),
                             (429, "rate_limited"))

    def test_daily_cap_per_recipient(self):
        with mock.patch.object(connect_flow, "per_recipient_limit",
                               return_value=2):
            for i in range(2):
                u = _register("S%d" % i, "0171100020%d" % i)
                r = self._start(c=_auth(u))
                self.assertEqual(r.status_code, 200, r.content)
            r = self._start()   # a 3rd stranger the same day
            self.assertEqual((r.status_code, r.json()["reason"]),
                             (429, "recipient_busy"))
            r = self.ca.post("/api/v1/circle/request",
                             {"to_user_id": self.b.id, "relation": "friend"},
                             format="json")
            self.assertEqual(r.status_code, 429)
        d = __import__("core.logic.pricing", fromlist=["x"]).normalize({})
        self.assertEqual(d["limits"]["message_requests_per_recipient_day"], 50)
        self.assertEqual(d["limits"]["message_request_max_msgs"], 3)


class NoLeakBeforeAccept(_Base):
    def test_no_receipts_presence_or_typing(self):
        mid = self._start().json()["member"]["id"]
        x = self._send(mid, "hi").json()["id"]
        mb = self._inc_id()
        # B's phone fetches, opens, acks, syncs — nothing reaches A
        self.cb.get("/api/v1/circle/%s/messages" % mb)
        self.cb.post("/api/v1/circle/%s/seen" % mb)
        self.cb.post("/api/v1/circle/receipts",
                     {"delivered": [x], "seen": [x]}, format="json")
        self.cb.post("/api/v1/circle/receipts/sync")
        self.cb.get("/api/v1/circle/requests")
        self.assertFalse(CircleReceipt.objects.filter(message_id=x).exists())
        msg = CircleMessage.objects.get(pk=x)
        self.assertNotIn(self.b.id, msg.delivered_to or [])
        self.assertNotIn(self.b.id, msg.read_by or [])
        row = self.ca.get("/api/v1/circle/%s/messages" % mid).json()
        self.assertEqual(row["results"][0]["status"], "sent")
        # presence / typing: B online + typing in the request chat
        from core import views_c3_msg as C3
        with mock.patch("core.views_c2_calls.rt_publish") as rt:
            self.cb.get("/api/v1/circle/rt/state?online=1")
            C3.set_typing(self.b, "member", mb, "typing")
            C3.set_typing(self.a, "member", mid, "typing")
        to_a = [c for c in rt.call_args_list if c.args[0] == self.a]
        to_b = [c for c in rt.call_args_list if c.args[0] == self.b]
        self.assertEqual((to_a, to_b), ([], []))
        st = self.ca.get("/api/v1/circle/rt/state").json()
        self.assertNotIn("member:%s" % mid, st["chats"])
        # after accept the receipts flow again
        self._accept(mb)
        self.cb.post("/api/v1/circle/%s/seen" % mb)
        row = self.ca.get("/api/v1/circle/%s/messages" % mid).json()
        self.assertEqual(row["results"][0]["status"], "read")

    def test_decline_is_never_revealed(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "1")
        mb = self._inc_id()
        self.push.reset_mock()
        r = self.cb.post("/api/v1/circle/request/%s/act" % mb,
                         {"event": "decline"}, format="json")
        self.assertEqual(r.status_code, 200)
        me = self.ca.get("/api/v1/circle/%s/messages" % mid).json()["edge"]
        self.assertEqual(me["state"], "pending")
        self.assertIsNone(me["connected_at"])
        # still "waiting"; more texts are accepted up to the cap, nothing
        # reaches B, then the cap stops A (no "declined" anywhere)
        self.assertEqual(self._send(mid, "2").status_code, 201)
        self.assertEqual(self._send(mid, "3").status_code, 201)
        self.assertEqual(self._send(mid, "4").json()["reason"], "request_limit")
        self.assertEqual(self.push.call_args_list, [])
        self.assertNotIn("declin", str(self.ca.get(
            "/api/v1/circle/requests").json()))

    def test_report_goes_to_moderation(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "spam")
        r = self.cb.post("/api/v1/circle/request/%s/msgreq" % self._inc_id(),
                         {"action": "report", "reason": "spam"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(ModerationReport.objects.filter(
            reporter=self.b, target_id=str(self.a.id)).exists())
        self.assertTrue(self._send(mid, "x").json().get("dropped"))


class AcceptConnects(_Base):
    def test_accept_line_push_ordering_and_normal_chat(self):
        mid = self._start().json()["member"]["id"]
        self._send(mid, "one")
        self._send(mid, "two")
        mb = self._inc_id()
        # LATER both get a newer message from C (C's chat would be on top)
        c = _register("Carol C", "01711000003")
        cc = _auth(c)
        for me, cl in ((self.a, self.ca), (self.b, self.cb)):
            r = cc.post("/api/v1/circle/message-request/start",
                        {"to_user_id": me.id}, format="json")
            cm = CircleMember.objects.get(user=me, peer_user=c)
            self._accept(cm.id, c=cl)
            self.assertEqual(self._send(r.json()["member"]["id"], "newer",
                                        c=cc).status_code, 201)
        self.push.reset_mock()
        r = self._accept(mb)
        self.assertEqual(r.json()["state"], "accepted")
        self.assertIsNotNone(r.json()["connected_at"])
        ea = CircleMember.objects.get(pk=mid)
        eb = CircleMember.objects.get(pk=mb)
        self.assertEqual((ea.state, eb.state), ("accepted", "accepted"))
        self.assertIsNotNone(ea.connected_at)
        self.assertEqual(ea.connected_at, eb.connected_at)
        # ONE push to A: "B accepted your request — say hi", opens THE chat
        pushes = self._accepted_pushes()
        self.assertEqual(len(pushes), 1)
        p = pushes[0]
        self.assertEqual(p.args[0], self.a)
        self.assertIn("Owner B", p.args[3])
        self.assertIn("say hi", p.args[3])
        self.assertIn("হাই", p.args[2])
        self.assertEqual(p.kwargs["data"]["chat_id"], mid)
        self.assertEqual(p.kwargs["data"]["chat_kind"], "member")
        self.assertEqual(p.kwargs["data"]["route"], "circle/chat")
        # the chat is on TOP of both lists (above the newer Carol chat)
        top_a = [r for r in self.ca.get("/api/v1/circle/chats").json()["results"]]
        top_b = [r for r in self.cb.get("/api/v1/circle/chats").json()["results"]]
        self.assertEqual(top_a[0]["id"], str(mid))
        self.assertEqual(top_b[0]["id"], str(mb))
        self.assertIsNotNone(top_b[0]["connected_at"])
        self.assertIsNone(top_a[0]["request"])
        # both chat payloads carry the line's timestamp; the pending
        # messages are a normal conversation now (no re-send)
        ga = self.ca.get("/api/v1/circle/%s/messages" % mid).json()
        gb = self.cb.get("/api/v1/circle/%s/messages" % mb).json()
        self.assertIsNotNone(ga["edge"]["connected_at"])
        self.assertEqual(gb["edge"]["state"], "accepted")
        self.assertEqual(len(gb["results"]), 2)
        self.assertEqual(self._send(mb, "hi back", c=self.cb).status_code, 201)
        for i in range(4):   # no cap any more
            self.assertEqual(self._send(mid, "m%d" % i).status_code, 201)
        members = self.ca.get("/api/v1/circle/members").json()["results"]
        self.assertTrue([m for m in members if m["id"] == mid
                         and m["connected_at"]])

    def test_mutual_start_connects_and_pushes(self):
        self._start()
        self.push.reset_mock()
        r = self._start(c=self.cb, phone="01711000001")
        self.assertEqual(r.json()["state"], "accepted")
        self.assertIsNotNone(r.json()["member"]["connected_at"])
        self.assertEqual([p.args[0] for p in self._accepted_pushes()], [self.a])

    def test_accept_push_respects_message_notifications_off(self):
        self._start()
        with mock.patch("core.push._m1_notif", return_value={"messages": False}):
            self.push.reset_mock()
            self._accept(self._inc_id())
        self.assertEqual(self._accepted_pushes(), [])
        self.assertIsNotNone(CircleMember.objects.get(
            user=self.a, peer_user=self.b).connected_at)


class PhoneInviteJoin(TestCase):
    def setUp(self):
        self.a = _register("Amina A", "01711000001")
        self.ca = _auth(self.a)
        p = mock.patch("core.push.safe_push", return_value=1)
        self.push = p.start()
        self.addCleanup(p.stop)

    def test_invitee_joins_accepts_and_both_get_the_chat(self):
        r = self.ca.post("/api/v1/circle/request",
                         {"phone": "০১৯১২ ৩৪৫৬৭৮", "relation": "family",
                          "name": "Brother"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        mid = r.json()["id"]
        self.assertIsNone(CircleMember.objects.get(pk=mid).peer_user_id)
        # the invited number joins Assisto
        b = _register("Bilal B", "+880 1912-345678")
        cb = _auth(b)
        self.assertEqual(CircleMember.objects.get(pk=mid).peer_user_id, b.id)
        inc = [x for x in cb.get("/api/v1/circle/requests").json()["results"]
               if x["direction"] == "incoming"]
        self.assertEqual(len(inc), 1)
        self.assertEqual(inc[0]["display_name"], "Amina A")
        r = cb.post("/api/v1/circle/request/%s/act" % inc[0]["id"],
                    {"event": "accept"}, format="json")
        self.assertEqual(r.json()["state"], "accepted")
        ea = CircleMember.objects.get(pk=mid)
        self.assertEqual(ea.state, "accepted")
        self.assertIsNotNone(ea.connected_at)
        # the chat appears for BOTH (no message needed) with the line stamp
        ra = self.ca.get("/api/v1/circle/chats").json()["results"]
        rb = cb.get("/api/v1/circle/chats").json()["results"]
        self.assertEqual(ra[0]["id"], str(mid))
        self.assertEqual(rb[0]["id"], str(inc[0]["id"]))
        self.assertIsNotNone(ra[0]["connected_at"])
        self.assertEqual(ra[0]["at"], ra[0]["connected_at"])
        pushes = [c for c in self.push.call_args_list
                  if (c.kwargs.get("data") or {}).get("event") == "accepted"]
        self.assertEqual([p.args[0] for p in pushes], [self.a])

    def test_join_without_invite_changes_nothing(self):
        b = _register("Bilal B", "01912345678")
        self.assertFalse(CircleMember.objects.filter(user=b).exists())
        self.assertEqual(connect_flow.link_phone_invites(b), 0)
        self.assertEqual(User.objects.filter(pk=b.id).count(), 1)
