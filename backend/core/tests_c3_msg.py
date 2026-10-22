"""c3-msg — ticks (sent → delivered → read), group per-member receipts,
read-receipt privacy (reciprocal), chat-list rows (last envelope + tick +
groups + never empty), the UNREAD BADGE regression (10 → open → 0), mark
unread, notification pull (5-message window, delivered ack, no plaintext),
presence + typing visibility.

Run: manage.py test core.tests_c3_msg --settings=assisto_backend.settings_test
"""
import json
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CirclePresence, CirclePrivacy,
                         CircleReceipt, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01710000001", "Amina")
        self.b = mk("01710000002", "Bilal")
        self.c = mk("01710000003", "Chaya")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, public_key="pkB", key_id="kB")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming", public_key="pkA")
        # e2-keys: keys live in the per-user directory (edge columns unused)
        from .models import UserPublicKey
        UserPublicKey.objects.create(user=self.b, public_key="pkB", key_id="kB")
        UserPublicKey.objects.create(user=self.a, public_key="pkA")
        self.ca, self.cb, self.cc = (self.cl(self.a), self.cl(self.b),
                                     self.cl(self.c))

    def cl(self, u):
        c = APIClient()
        c.force_authenticate(u)
        c.credentials(HTTP_ACCEPT_LANGUAGE="en")
        return c

    def send(self, client, edge, cmid):
        r = client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": cmid},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def msgs(self, client, edge):
        return client.get("%s/circle/%d/messages" % (V, edge.id)).json()["results"]

    def status_of(self, client, edge, mid):
        return next(m for m in self.msgs(client, edge) if m["id"] == mid)["status"]


class TickTests(_Base):
    def test_sent_delivered_read_1to1(self):
        mid = self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "sent")
        # B's device pulls it for the notification -> delivered
        r = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "delivered")
        # B opens the chat -> read (blue)
        self.assertEqual(self.cb.post(
            "%s/circle/%d/seen" % (V, self.ba.id)).status_code, 200)
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "read")
        # the recipient never sees a status on messages that aren't theirs
        self.assertNotIn("status", self.msgs(self.cb, self.ba)[0])

    def test_batch_ack_and_access(self):
        mid = self.send(self.ca, self.ab, "m1")
        # a stranger can't ack it
        r = self.cc.post(V + "/circle/receipts", {"delivered": [mid]},
                         format="json")
        self.assertEqual(r.json()["accepted"], [])
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "sent")
        # the sender acking their own message changes nothing
        self.ca.post(V + "/circle/receipts", {"seen": [mid]}, format="json")
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "sent")
        r = self.cb.post(V + "/circle/receipts", {"delivered": [mid]},
                         format="json")
        self.assertEqual(r.json()["accepted"], [mid])
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "delivered")
        self.cb.post(V + "/circle/receipts", {"seen": [mid]}, format="json")
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "read")
        # idempotent
        self.cb.post(V + "/circle/receipts", {"seen": [mid]}, format="json")
        self.assertEqual(CircleReceipt.objects.filter(message_id=mid).count(), 1)

    def test_sync_marks_everything_delivered(self):
        m1 = self.send(self.ca, self.ab, "m1")
        m2 = self.send(self.ca, self.ab, "m2")
        r = self.cb.post(V + "/circle/receipts/sync")
        self.assertEqual(r.json()["updated"], 2)
        for m in (m1, m2):
            self.assertEqual(self.status_of(self.ca, self.ab, m), "delivered")
        self.assertEqual(self.cb.post(V + "/circle/receipts/sync")
                         .json()["updated"], 0)

    def test_read_receipts_off_is_reciprocal(self):
        mid = self.send(self.ca, self.ab, "m1")
        CirclePrivacy.objects.create(user=self.b, read_receipts=False)
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        # B turned receipts off: A only gets delivered
        self.assertEqual(self.status_of(self.ca, self.ab, mid), "delivered")
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertIsNone(info["recipients"][0]["seen_at"])
        self.assertTrue(info["recipients"][0]["seen_hidden"])
        self.assertIsNotNone(info["recipients"][0]["delivered_at"])
        # reciprocal: B (receipts off) can't see A's read of B's message
        mb = self.send(self.cb, self.ba, "b1")
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertEqual(self.status_of(self.cb, self.ba, mb), "delivered")

    def test_info_only_for_sender(self):
        mid = self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.cb.get("%s/circle/messages/%d/info" % (V, mid))
                         .status_code, 404)
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertEqual(info["status"], "sent")
        self.assertEqual(info["recipients"][0]["name"], "Bilal")
        self.assertIsNone(info["recipients"][0]["delivered_at"])


class GroupTickTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        self.gma = CircleGroupMember.objects.create(group=self.g, member=self.a,
                                                    role="admin")
        self.gmb = CircleGroupMember.objects.create(group=self.g, member=self.b)
        self.gmc = CircleGroupMember.objects.create(group=self.g, member=self.c)
        # A has an edge to C too (keys are per-edge)
        CircleMember.objects.create(user=self.a, peer_user=self.c, name="Chaya",
                                    state="accepted", phone=self.c.phone,
                                    public_key="pkC")
        from .models import UserPublicKey
        UserPublicKey.objects.create(user=self.c, public_key="pkC")

    def gsend(self):
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, self.g.id), {
            "recipient_ids": [self.gmb.id, self.gmc.id],
            "per_recipient": {str(self.gmb.id): {"ciphertext": "QkI=", "nonce": "Tg=="},
                              str(self.gmc.id): {"ciphertext": "Q0M=", "nonce": "Tg=="}},
            "client_msg_id": "g1"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def gstatus(self, mid):
        rows = self.ca.get("%s/circle/groups/%d/messages" % (V, self.g.id)).json()["results"]
        return next(m for m in rows if m["id"] == mid)["status"]

    def test_group_per_member(self):
        mid = self.gsend()
        self.assertEqual(self.gstatus(mid), "sent")
        self.cb.post("%s/circle/groups/%d/seen" % (V, self.g.id))
        # only B so far -> still sent (C has not received)
        self.assertEqual(self.gstatus(mid), "sent")
        self.cc.post(V + "/circle/receipts/sync")
        self.assertEqual(self.gstatus(mid), "delivered")
        self.cc.post("%s/circle/groups/%d/seen" % (V, self.g.id))
        self.assertEqual(self.gstatus(mid), "read")
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertTrue(info["group"])
        self.assertEqual(sorted(r["name"] for r in info["recipients"]),
                         ["Bilal", "Chaya"])
        self.assertTrue(all(r["seen_at"] for r in info["recipients"]))

    def test_group_in_chat_list_with_my_blob(self):
        mid = self.gsend()
        rows = self.cb.get(V + "/circle/chats").json()["results"]
        g = next(r for r in rows if r.get("is_group"))
        self.assertEqual(g["kind"], "group")
        self.assertEqual(g["group"]["name"], "Family")
        self.assertEqual(g["unread"], 1)
        self.assertEqual(g["last"]["id"], mid)
        self.assertEqual(g["last"]["ciphertext"], "QkI=")   # B's own blob
        self.assertEqual(g["last"]["sender_name"], "Amina")
        self.assertEqual(g["last"]["peer_public_key"], "pkA")
        # the sender's row: one recipient's blob + that recipient's key (ECDH
        # is symmetric) and the tick
        ga = next(r for r in self.ca.get(V + "/circle/chats").json()["results"]
                  if r.get("is_group"))
        self.assertTrue(ga["last"]["mine"])
        self.assertIn(ga["last"]["peer_public_key"], ("pkB", "pkC"))
        self.assertEqual(ga["last"]["status"], "sent")
        # pull for B: group window from B's view
        r = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "group", "chat_id": self.g.id},
                         format="json").json()
        self.assertTrue(r["chat"]["is_group"])
        self.assertEqual(r["messages"][0]["ciphertext"], "QkI=")


class ChatListAndBadgeTests(_Base):
    def test_last_envelope_present_so_never_no_messages(self):
        """ROOT CAUSE of "No messages yet": the row's last_text is always ''
        (E2E — the server has no plaintext); the app must decrypt `last`. The
        row carries everything needed to do that on the device."""
        mid = self.send(self.ca, self.ab, "m1")
        row = self.cb.get(V + "/circle/chats").json()["results"][0]
        self.assertEqual(row["last_text"], "")
        self.assertEqual(row["last"]["id"], mid)
        self.assertEqual(row["last"]["ciphertext"], "Q1Q=")
        self.assertEqual(row["last"]["peer_public_key"], "pkA")
        self.assertFalse(row["last"]["mine"])
        self.assertNotIn("status", row["last"])
        arow = self.ca.get(V + "/circle/chats").json()["results"][0]
        # x2-ticks: B's chat-list fetch is a delivered ack (✓✓)
        self.assertEqual(arow["last"]["status"], "delivered")

    def test_unread_badge_regression_10_then_open_is_0(self):
        """Owner bug: open a chat, read everything -> list still said 10."""
        ids = [self.send(self.ca, self.ab, "m%d" % i) for i in range(10)]
        row = self.cb.get(V + "/circle/chats").json()["results"][0]
        self.assertEqual(row["unread"], 10)
        # the app's open-chat call (and the legacy read endpoint) both clear it
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        row = self.cb.get(V + "/circle/chats").json()["results"][0]
        self.assertEqual(row["unread"], 0)
        # sender side sees read
        self.assertEqual(self.status_of(self.ca, self.ab, ids[-1]), "read")
        # the legacy endpoint used to filter member_id=pk (B's edge) and never
        # touched A's rows on A's edge — now it marks the conversation
        self.send(self.ca, self.ab, "m-x")
        self.assertEqual(self.cb.get(V + "/circle/chats").json()["results"][0]
                         ["unread"], 1)
        r = self.cb.post("%s/messenger/chats/%d/read" % (V, self.ba.id))
        self.assertEqual(r.json()["marked"], 1)
        self.assertEqual(self.cb.get(V + "/circle/chats").json()["results"][0]
                         ["unread"], 0)

    def test_mark_unread_then_read(self):
        self.send(self.ca, self.ab, "m1")
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        self.cb.post(V + "/circle/chats/unread",
                     {"chat_kind": "member", "chat_id": self.ba.id,
                      "unread": True}, format="json")
        row = self.cb.get(V + "/circle/chats").json()["results"][0]
        self.assertTrue(row["marked_unread"])
        self.assertEqual(row["unread"], 0)
        self.cb.post(V + "/circle/chats/unread",
                     {"chat_kind": "member", "chat_id": self.ba.id,
                      "unread": False}, format="json")
        self.assertFalse(self.cb.get(V + "/circle/chats").json()["results"][0]
                         ["marked_unread"])


class NotifyPullTests(_Base):
    def test_window_is_last_five_unseen_and_acks(self):
        for i in range(7):
            self.send(self.ca, self.ab, "m%d" % i)
        r = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id,
                          "limit": 5}, format="json").json()
        self.assertEqual(len(r["messages"]), 5)
        self.assertEqual(r["unseen"], 7)
        self.assertEqual(r["chat"]["title"], "Amina")
        self.assertEqual(r["chat"]["peer_public_key"], "pkA")
        # ciphertext only; no plaintext field anywhere
        blob = json.dumps(r)
        self.assertNotIn("plaintext", blob)
        for m in r["messages"]:
            self.assertFalse({"text", "body", "plaintext"} & set(m))
        # ordering oldest -> newest
        ids = [m["id"] for m in r["messages"]]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(CircleReceipt.objects.filter(
            user=self.b, delivered_at__isnull=False).count(), 7)
        # after opening the chat the window is empty (cancel the notification)
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        r = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id},
                         format="json").json()
        self.assertEqual(r["messages"], [])

    def test_my_inline_reply_appears_in_window(self):
        self.send(self.ca, self.ab, "a1")
        self.send(self.cb, self.ba, "b-reply")
        r = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id},
                         format="json").json()
        self.assertEqual([m["mine"] for m in r["messages"]], [False, True])

    def test_reply_to_persists(self):
        orig = self.send(self.ca, self.ab, "a1")
        r = self.cb.post("%s/circle/%d/messages" % (V, self.ba.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": "b1",
            "reply_to": orig}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        rows = self.msgs(self.ca, self.ab)
        self.assertEqual(next(m for m in rows if m["id"] == r.json()["id"])
                         ["reply_to"], orig)

    def test_pull_foreign_chat_404(self):
        r = self.cc.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id},
                         format="json")
        self.assertEqual(r.status_code, 404)


class PresenceTypingTests(_Base):
    def state(self, c, key):
        return c.get(V + "/circle/rt/state").json()["chats"].get(key)

    # mc-int: presence/typing ride the shared queue (rt/send producers).
    def presence(self, c, st):
        r = c.post(V + "/rt/send", {"topic": "presence.set",
                                    "payload": {"state": st}}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r

    def typing(self, c, payload):
        return c.post(V + "/rt/send", {"topic": "typing.set",
                                       "payload": payload}, format="json")

    def test_online_last_seen_and_typing(self):
        # default policy (family) hides from a "friend"; open it to My Circle
        for u in (self.a, self.b):
            CirclePrivacy.objects.create(user=u, visibility={
                "last_seen": "everyone", "active_status": "everyone"})
        self.presence(self.cb, "online")
        s = self.state(self.ca, "member:%d" % self.ab.id)
        self.assertTrue(s["online"])
        self.assertIsNotNone(s["last_seen"])
        self.assertEqual(s["activity"], "")
        self.typing(self.cb, {"chat_kind": "member",
                              "chat_id": self.ba.id,
                              "state": "typing"})
        self.assertEqual(self.state(self.ca, "member:%d" % self.ab.id)
                         ["activity"], "typing")
        self.typing(self.cb, {"chat_kind": "member",
                              "chat_id": self.ba.id,
                              "state": "recording"})
        self.assertEqual(self.state(self.ca, "member:%d" % self.ab.id)
                         ["activity"], "recording")
        # expiry
        CirclePresence.objects.filter(user=self.b).update(
            activity_until=timezone.now() - timedelta(seconds=1),
            online_until=timezone.now() - timedelta(seconds=1))
        s = self.state(self.ca, "member:%d" % self.ab.id)
        self.assertEqual(s["activity"], "")
        self.assertFalse(s["online"])
        # away
        self.presence(self.cb, "away")
        self.assertFalse(self.state(self.ca, "member:%d" % self.ab.id)["online"])

    def test_privacy_nobody_and_reciprocal(self):
        CirclePrivacy.objects.create(user=self.b, visibility={
            "last_seen": "nobody", "active_status": "nobody"})
        CirclePrivacy.objects.create(user=self.a, visibility={
            "last_seen": "everyone", "active_status": "everyone"})
        self.presence(self.cb, "online")
        s = self.state(self.ca, "member:%d" % self.ab.id)
        self.assertIsNone(s["online"])
        self.assertIsNone(s["last_seen"])
        # reciprocal: B hid theirs, so B can't see A's either
        self.presence(self.ca, "online")
        s = self.state(self.cb, "member:%d" % self.ba.id)
        self.assertIsNone(s["online"])
        self.assertIsNone(s["last_seen"])

    def test_typing_off_is_reciprocal(self):
        CirclePrivacy.objects.create(user=self.a, typing=False)
        self.typing(self.cb, {"chat_kind": "member",
                              "chat_id": self.ba.id})
        self.assertEqual(self.state(self.ca, "member:%d" % self.ab.id)
                         ["activity"], "")

    def test_group_typing_names_who(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        for u in (self.a, self.b):
            CircleGroupMember.objects.create(group=g, member=u)
        self.typing(self.cb, {"chat_kind": "group",
                              "chat_id": g.id})
        s = self.state(self.ca, "group:%d" % g.id)
        self.assertEqual((s["activity"], s["who"]), ("typing", "Bilal"))
        # not shown to the typer themself
        self.assertIsNone(self.state(self.cb, "group:%d" % g.id))
        # strangers can't post typing into a group they aren't in
        self.assertEqual(self.typing(self.cc, {"chat_kind": "group",
                                               "chat_id": g.id}).status_code,
                         404)

    # ---- mc-int: live updates over the ONE shared queue (rt/events) ----
    def events(self, c, topics=""):
        q = "?after=0" + ("&topics=" + topics if topics else "")
        return [e for e in c.get(V + "/rt/events" + q).json()["events"]]

    def test_typing_update_pushed_to_peer_with_their_chat_key(self):
        self.typing(self.cb, {"chat_kind": "member", "chat_id": self.ba.id,
                              "state": "typing"})
        evs = self.events(self.ca, topics="typing")
        self.assertEqual(len(evs), 1)
        self.assertEqual(evs[0]["payload"]["chat"], "member:%d" % self.ab.id)
        self.assertEqual(evs[0]["payload"]["activity"], "typing")
        self.typing(self.cb, {"chat_kind": "member", "chat_id": self.ba.id,
                              "state": "stop"})
        evs = self.events(self.ca, topics="typing")
        self.assertEqual(evs[-1]["payload"]["activity"], "")
        # the typer gets nothing about themself
        self.assertEqual(self.events(self.cb, topics="typing"), [])

    def test_typing_update_respects_reciprocal_off_and_block(self):
        CirclePrivacy.objects.create(user=self.a, typing=False)
        self.typing(self.cb, {"chat_kind": "member", "chat_id": self.ba.id})
        self.assertEqual(self.events(self.ca, topics="typing"), [])
        CirclePrivacy.objects.filter(user=self.a).update(typing=True)
        CircleMember.objects.filter(pk=self.ab.pk).update(blocked=True)
        self.typing(self.cb, {"chat_kind": "member", "chat_id": self.ba.id})
        self.assertEqual(self.events(self.ca, topics="typing"), [])

    def test_group_typing_update_to_members_only(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        for u in (self.a, self.b, self.c):
            CircleGroupMember.objects.create(group=g, member=u)
        self.typing(self.cb, {"chat_kind": "group", "chat_id": g.id,
                              "state": "recording"})
        for c in (self.ca, self.cc):
            p = self.events(c, topics="typing")[0]["payload"]
            self.assertEqual((p["chat"], p["activity"], p["who"]),
                             ("group:%d" % g.id, "recording", "Bilal"))
        self.assertEqual(self.events(self.cb, topics="typing"), [])

    def test_poll_is_heartbeat_and_flip_fans_out_presence(self):
        for u in (self.a, self.b):
            CirclePrivacy.objects.create(user=u, visibility={
                "last_seen": "everyone", "active_status": "everyone"})
        # a poll WITHOUT online=1 (app open, My Circle not on screen): no
        # heartbeat, nothing fanned out
        self.cb.get(V + "/rt/events?after=0")
        self.assertEqual(self.events(self.ca, topics="presence"), [])
        self.cb.get(V + "/rt/events?after=0&online=1")
        evs = self.events(self.ca, topics="presence")
        self.assertEqual(len(evs), 1)
        p = evs[0]["payload"]
        self.assertEqual(p["chat"], "member:%d" % self.ab.id)
        self.assertTrue(p["online"])
        self.assertIsNotNone(p["until"])
        # still fresh: further polls neither write nor fan out (battery/DB)
        before = CirclePresence.objects.get(user=self.b).last_seen
        self.cb.get(V + "/rt/events?after=0&online=1")
        self.assertEqual(CirclePresence.objects.get(user=self.b).last_seen,
                         before)
        self.assertEqual(len(self.events(self.ca, topics="presence")), 1)
        # away flips it back
        self.presence(self.cb, "away")
        evs = self.events(self.ca, topics="presence")
        self.assertEqual(len(evs), 2)
        self.assertFalse(evs[-1]["payload"]["online"])
        self.assertIsNotNone(evs[-1]["payload"]["last_seen"])

    def test_presence_hidden_by_privacy_is_not_sent(self):
        CirclePrivacy.objects.create(user=self.b, visibility={
            "last_seen": "nobody", "active_status": "nobody"})
        self.presence(self.cb, "online")
        self.assertEqual(self.events(self.ca, topics="presence"), [])

    def test_bad_topics_on_shared_send(self):
        r = self.ca.post(V + "/rt/send", {"topic": "typing.zzz",
                                          "payload": {}}, format="json")
        self.assertEqual(r.status_code, 422)
        r = self.ca.post(V + "/rt/send", {"topic": "presence.zzz",
                                          "payload": {}}, format="json")
        self.assertEqual(r.status_code, 422)

