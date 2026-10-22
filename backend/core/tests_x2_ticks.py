"""x2-ticks — WhatsApp-standard ticks end to end on the server.

  * delivered the moment the recipient's PHONE has it: the FCM background
    isolate acks with its stored token (POST circle/receipts, Token auth), an
    open app acks on the realtime `msg.new` event, any fetch acks too;
  * every receipt change reaches the SENDER at once as a realtime
    `receipt.update` event keyed by the sender's own chat id;
  * read ONLY via seen (open + visible chat), never by a fetch / pull;
  * reciprocal read-receipt privacy: a hidden read is never sent; Message
    info says honestly that receipts are off;
  * ROOT CAUSE of the stuck ✓: the sender's OWN chat mute suppressed the
    push to the recipient; a muted recipient now gets a SILENT delivery ping.

Run: manage.py test core.tests_x2_ticks --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import push
from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CirclePrivacy, CircleReceipt, RtEvent,
                         User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def token_client(u):
    """Exactly what the background isolate does: no session, just the stored
    DRF token in the Authorization header."""
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " +
                  Token.objects.get_or_create(user=u)[0].key,
                  HTTP_ACCEPT_LANGUAGE="en")
    return c


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01720000001", "Owner")
        self.b = mk("01720000002", "Shanto")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Shanto", state="accepted",
            phone=self.b.phone, public_key="pkB", key_id="kB")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Owner", state="accepted",
            phone=self.a.phone, direction="incoming", public_key="pkA")
        self.ca, self.cb = token_client(self.a), token_client(self.b)

    def send(self, client=None, edge=None, cmid="m1"):
        client, edge = client or self.ca, edge or self.ab
        r = client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": cmid},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def events(self, user, topic):
        return [e.payload for e in
                RtEvent.objects.filter(user=user, topic=topic).order_by("id")]

    def last_receipt(self, user=None):
        ev = self.events(user or self.a, "receipt.update")
        return ev[-1] if ev else None


class BackgroundAckTests(_Base):
    def test_background_isolate_ack_with_stored_token(self):
        mid = self.send()
        self.assertIsNone(self.last_receipt())
        r = self.cb.post(V + "/circle/receipts", {"delivered": [mid]},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["accepted"], [mid])
        rc = CircleReceipt.objects.get(message_id=mid, user=self.b)
        self.assertIsNotNone(rc.delivered_at)
        self.assertIsNone(rc.seen_at)
        ev = self.last_receipt()
        self.assertEqual(ev, {"chat": "member:%d" % self.ab.id,
                              "statuses": {str(mid): "delivered"}})

    def test_ack_requires_auth(self):
        mid = self.send()
        r = APIClient().post(V + "/circle/receipts", {"delivered": [mid]},
                             format="json")
        self.assertIn(r.status_code, (401, 403))
        self.assertFalse(CircleReceipt.objects.filter(message_id=mid).exists())

    def test_ack_is_idempotent_no_event_spam(self):
        mid = self.send()
        for _ in range(3):
            self.cb.post(V + "/circle/receipts", {"delivered": [mid]},
                         format="json")
        self.assertEqual(len(self.events(self.a, "receipt.update")), 1)

    def test_offline_queue_flush_batch(self):
        ids = [self.send(cmid="q%d" % i) for i in range(3)]
        self.cb.post(V + "/circle/receipts", {"delivered": ids}, format="json")
        ev = self.last_receipt()
        self.assertEqual(set(ev["statuses"]), {str(i) for i in ids})
        self.assertEqual(set(ev["statuses"].values()), {"delivered"})

    def test_stranger_cannot_ack(self):
        c = mk("01720000003", "Stranger")
        mid = self.send()
        token_client(c).post(V + "/circle/receipts", {"delivered": [mid]},
                             format="json")
        self.assertIsNone(self.last_receipt())


class ReadOnlyViaSeenTests(_Base):
    def test_fetch_is_delivered_not_read(self):
        mid = self.send()
        r = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        self.assertEqual(r.status_code, 200)
        rc = CircleReceipt.objects.get(message_id=mid, user=self.b)
        self.assertIsNotNone(rc.delivered_at)
        self.assertIsNone(rc.seen_at)
        self.assertEqual(self.last_receipt()["statuses"][str(mid)], "delivered")
        # a second poll changes nothing and sends nothing
        self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        self.assertEqual(len(self.events(self.a, "receipt.update")), 1)

    def test_notify_pull_is_delivered_not_read(self):
        mid = self.send()
        self.cb.post(V + "/circle/notify/pull",
                     {"chat_kind": "member", "chat_id": self.ba.id},
                     format="json")
        self.assertEqual(self.last_receipt()["statuses"][str(mid)], "delivered")

    def test_seen_is_read_event(self):
        mid = self.send()
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        self.assertEqual(self.last_receipt()["statuses"][str(mid)], "read")

    def test_chat_list_fetch_acks_delivered(self):
        mid = self.send()
        self.assertEqual(self.cb.get(V + "/circle/chats").status_code, 200)
        self.assertEqual(self.last_receipt()["statuses"][str(mid)], "delivered")
        self.assertIsNone(CircleReceipt.objects.get(
            message_id=mid, user=self.b).seen_at)

    def test_sender_fetch_never_acks(self):
        mid = self.send()
        self.ca.get("%s/circle/%d/messages" % (V, self.ab.id))
        self.assertFalse(CircleReceipt.objects.filter(message_id=mid).exists())


class PrivacyTests(_Base):
    def test_receipts_off_event_says_delivered(self):
        CirclePrivacy.objects.create(user=self.b, read_receipts=False)
        mid = self.send()
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        evs = self.events(self.a, "receipt.update")
        self.assertTrue(evs)
        self.assertTrue(all(e["statuses"][str(mid)] != "read" for e in evs))
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertTrue(info["recipients"][0]["receipts_off"])
        self.assertTrue(info["my_read_receipts"])
        self.assertIsNone(info["recipients"][0]["seen_at"])

    def test_my_receipts_off_is_reciprocal_and_honest(self):
        CirclePrivacy.objects.create(user=self.a, read_receipts=False)
        mid = self.send()
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertFalse(info["my_read_receipts"])
        self.assertTrue(info["recipients"][0]["receipts_off"])
        self.assertEqual(info["status"], "delivered")

    def test_info_has_real_times(self):
        mid = self.send()
        self.cb.post(V + "/circle/receipts", {"delivered": [mid]},
                     format="json")
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        row = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()[
            "recipients"][0]
        self.assertFalse(row["receipts_off"])
        self.assertTrue(row["delivered_at"] <= row["seen_at"])


class PushRootCauseTests(_Base):
    """The owner's 13:42 message: the SENDER's chat mute blocked the push."""

    def _send_capturing(self, **kw):
        calls = []
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "safe_push",
                                  side_effect=lambda *a, **k: calls.append(
                                      (a, k)) or True):
            mid = self.send(**kw)
        return mid, calls

    def test_sender_muted_this_chat_still_pushes_recipient(self):
        for until in (timezone.now() - timedelta(days=3),
                      timezone.now() + timedelta(days=3)):
            self.ab.muted_until = until
            self.ab.save(update_fields=["muted_until"])
            _, calls = self._send_capturing(cmid="mu%s" % until.day)
            self.assertEqual(len(calls), 1)
            (user, kind), data = calls[0][0][:2], calls[0][1]["data"]
            self.assertEqual(user, self.b)
            self.assertEqual(kind, "message")
            self.assertEqual(data["chat_id"], self.ba.id)
            self.assertTrue(calls[0][1]["high_priority"])

    def test_recipient_muted_gets_silent_delivery_ping(self):
        self.ba.muted_until = timezone.now() + timedelta(days=1)
        self.ba.save(update_fields=["muted_until"])
        mid, calls = self._send_capturing()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0][1], "msg_sync")
        d = calls[0][1]["data"]
        self.assertEqual((d["message_id"], d["silent"]), (mid, "1"))
        self.assertIn("msg_sync", push.DATA_ONLY_KINDS)
        self.assertIn("msg_sync", push.KINDS)

    def test_msg_sync_payload_is_data_only_without_text(self):
        sent = []
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token",
                                  side_effect=lambda *a, **k: sent.append(
                                      (a, k)) or True):
            from core.models import Device
            Device.objects.create(user=self.b, push_token="tok-b")
            push.push_to_user(self.b, "msg_sync", "", "", "", "",
                              data={"message_id": 1, "silent": "1"})
        (tok, data, notif), kw = sent[0][0][:3], sent[0][1]
        self.assertIsNone(notif)
        self.assertEqual(kw["priority"], "high")
        self.assertEqual(data["kind"], "msg_sync")
        self.assertEqual(data["body"], "")

    def test_open_app_gets_msg_new_realtime(self):
        mid = self.send()
        ev = self.events(self.b, "msg.new")
        self.assertEqual(ev, [{"chat": "member:%d" % self.ba.id,
                               "message_id": mid}])
        self.assertEqual(self.events(self.a, "msg.new"), [])


class GroupTests(_Base):
    def setUp(self):
        super().setUp()
        self.c = mk("01720000004", "Chaya")
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        self.gm = {u.id: CircleGroupMember.objects.create(
            group=self.g, member=u, status="active",
            role="admin" if u == self.a else "member")
            for u in (self.a, self.b, self.c)}

    def gsend(self):
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, self.g.id), {
            "content_type": "text", "client_msg_id": "g1",
            "recipient_ids": [self.gm[self.b.id].id, self.gm[self.c.id].id],
            "per_recipient": {str(self.gm[self.b.id].id): {
                "ciphertext": "Q1Q=", "nonce": "Tg=="},
                str(self.gm[self.c.id].id): {
                "ciphertext": "Q1Q=", "nonce": "Tg=="}}}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def test_group_delivered_when_all_members_ack(self):
        mid = self.gsend()
        self.assertEqual(self.events(self.b, "msg.new")[0]["chat"],
                         "group:%d" % self.g.id)
        self.cb.post(V + "/circle/receipts", {"delivered": [mid]},
                     format="json")
        self.assertEqual(self.last_receipt(),
                         {"chat": "group:%d" % self.g.id,
                          "statuses": {str(mid): "sent"}})
        token_client(self.c).post(V + "/circle/receipts",
                                  {"delivered": [mid]}, format="json")
        self.assertEqual(self.last_receipt()["statuses"][str(mid)],
                         "delivered")


class PhotoVersionTests(TestCase):
    def test_stable_across_signed_url_rotation(self):
        from core.views_module5 import x2_photo_v
        a = x2_photo_v("/api/v1/m/avatars/u3_ab.jpg?e=100&s=x")
        b = x2_photo_v("/api/v1/m/avatars/u3_ab.jpg?e=7300&s=y")
        c = x2_photo_v("/api/v1/m/avatars/u3_cd.jpg?e=7300&s=y")
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertEqual(x2_photo_v(""), "")

    def test_member_dict_and_pull_carry_photo_v(self):
        a, b = mk("01720000011", "A"), mk("01720000012", "B")
        b.photo_link = "https://example.com/b.jpg"
        b.save(update_fields=["photo_link"])
        ab = CircleMember.objects.create(user=a, peer_user=b, name="B",
                                         state="accepted", phone=b.phone)
        CircleMember.objects.create(user=b, peer_user=a, name="A",
                                    state="accepted", phone=a.phone)
        c = token_client(a)
        rows = c.get(V + "/circle/chats").json()["results"]
        m = next(r for r in rows if str(r["id"]) == str(ab.id))["member"]
        self.assertEqual(m["photo"], "https://example.com/b.jpg")
        self.assertTrue(m["photo_v"])
        pull = c.post(V + "/circle/notify/pull",
                      {"chat_kind": "member", "chat_id": ab.id},
                      format="json").json()
        self.assertEqual(pull["chat"]["photo_v"], m["photo_v"])
