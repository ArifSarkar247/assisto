"""e-gaps (owner order E) — view-once media + disappearing really deleted.

Run: manage.py test core.tests_e_gaps --settings=assisto_backend.settings_test
"""
import os
from datetime import timedelta

from django.core.management import call_command
from django.utils import timezone

from core import circle_blobs as CB
from core.models import (ChatOrganiseState, ChatSettings, CircleGroup,
                         CircleGroupMember, CircleMediaBlob, CircleMessage,
                         MsgChatPref)
from core.tests_md1_media import CIPHER, V, _Base


class GroupOrganiseTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=self.g, member=self.a, role="admin")
        CircleGroupMember.objects.create(group=self.g, member=self.b)

    def _org(self, client, **body):
        return client.post("%s/circle/groups/%d/organise" % (V, self.g.id),
                           body, format="json")

    def _row(self, client):
        r = client.get(V + "/circle/chats")
        self.assertEqual(r.status_code, 200)
        return [x for x in r.json()["results"] if x.get("is_group")
                and x.get("group_id") == self.g.id][0]

    def test_pin_and_archive_sync_in_chat_list(self):
        r = self._org(self.ca, pinned=True)
        self.assertEqual(r.status_code, 200, r.content)
        row = self._row(self.ca)
        self.assertTrue(row["pinned"])
        self.assertTrue(row["pin_at"])
        # per user: Bilal's row is untouched
        self.assertFalse(self._row(self.cb)["pinned"])
        # archiving clears the pin
        self._org(self.ca, archived=True)
        row = self._row(self.ca)
        self.assertTrue(row["archived"])
        self.assertFalse(row["pinned"])
        self._org(self.ca, archived=False)
        self.assertFalse(self._row(self.ca)["archived"])

    def test_non_member_refused(self):
        self.assertEqual(self._org(self.cc, pinned=True).status_code, 404)

    def test_pin_cap_counts_groups_and_chats(self):
        for i in range(5):
            ChatOrganiseState.objects.create(user=self.a, chat_kind="member",
                                             chat_id=str(1000 + i), pinned=True)
        r = self._org(self.ca, pinned=True)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["code"], "pin_cap_reached")
        # and a pinned group counts against 1:1 pins
        ChatOrganiseState.objects.filter(user=self.a, chat_id="1000").delete()
        self.assertEqual(self._org(self.ca, pinned=True).status_code, 200)
        r = self.ca.post("%s/messenger/chats/%d/pin" % (V, self.ab.id),
                         {"pinned": True}, format="json")
        self.assertEqual(r.status_code, 400)


class TimerSinceTests(_Base):
    def test_settings_report_since(self):
        r = self.ca.get("%s/circle/%d/settings" % (V, self.ab.id))
        self.assertIsNone(r.json()["disappearing_since"])
        self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                     {"disappearing_sec": 604800}, format="json")
        for c, e in ((self.ca, self.ab), (self.cb, self.ba)):
            j = c.get("%s/circle/%d/settings" % (V, e.id)).json()
            self.assertEqual(j["disappearing_sec"], 604800)
            self.assertTrue(j["disappearing_since"])


class ViewOnceTests(_Base):
    def _send_vo(self, cmid="vo1"):
        ref = self.upload()
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "photo", "blob_ref": ref, "view_once": True,
            "ciphertext": "RU5DLURFU0M=", "nonce": "Tg==",
            "sender_key_id": "kA", "client_msg_id": cmid}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return ref, r.json()["id"]

    def _rows(self, client, edge):
        r = client.get("%s/circle/%d/messages" % (V, edge.id))
        self.assertEqual(r.status_code, 200)
        return {x["id"]: x for x in r.json()["results"]}

    def test_flag_stored_and_receiver_gets_ciphertext(self):
        ref, mid = self._send_vo()
        self.assertTrue(CircleMessage.objects.get(pk=mid).view_once)
        row = self._rows(self.cb, self.ba)[mid]
        self.assertTrue(row["view_once"])
        self.assertFalse(row["view_once_opened"])
        self.assertEqual(row["ciphertext"], "RU5DLURFU0M=")
        self.assertEqual(row["blob_ref"], ref)

    def test_sender_never_gets_it_back(self):
        _, mid = self._send_vo()
        row = self._rows(self.ca, self.ab)[mid]
        self.assertTrue(row["view_once"])
        self.assertEqual(row["ciphertext"], "")
        self.assertEqual(row["blob_ref"], "")

    def test_open_wipes_ciphertext_and_blob(self):
        ref, mid = self._send_vo()
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())
        r = self.cb.post("%s/circle/messages/%d/view-once-open" % (V, mid))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["state"], "opened")
        x = CircleMessage.objects.get(pk=mid)
        self.assertIsNotNone(x.view_once_opened_at)
        self.assertEqual((x.ciphertext, x.nonce, x.blob_ref), ("", "", ""))
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertFalse(os.path.exists(CB.path_for(ref)))
        # both sides now see "opened" and no ciphertext
        rb = self._rows(self.cb, self.ba)[mid]
        self.assertTrue(rb["view_once_opened"])
        self.assertEqual(rb["ciphertext"], "")
        self.assertTrue(self._rows(self.ca, self.ab)[mid]["view_once_opened"])
        # a second open is harmless
        r = self.cb.post("%s/circle/messages/%d/view-once-open" % (V, mid))
        self.assertEqual(r.json()["state"], "already")
        # and the file link is gone
        self.assertEqual(self.url_for(ref, self.cb).status_code, 404)

    def test_sender_or_stranger_cannot_open(self):
        _, mid = self._send_vo()
        r = self.ca.post("%s/circle/messages/%d/view-once-open" % (V, mid))
        self.assertEqual(r.status_code, 400)
        r = self.cc.post("%s/circle/messages/%d/view-once-open" % (V, mid))
        self.assertEqual(r.status_code, 404)
        self.assertIsNone(CircleMessage.objects.get(pk=mid).view_once_opened_at)

    def test_receiver_cannot_forward_view_once_blob(self):
        ref, _ = self._send_vo()
        r = self.cb.post("%s/circle/%d/messages" % (V, self.ba.id), {
            "content_type": "photo", "blob_ref": ref,
            "ciphertext": "RU5DLURFU0M=", "nonce": "Tg==",
            "sender_key_id": "kB", "client_msg_id": "fw1"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "blob_missing")

    def test_normal_photo_unchanged(self):
        ref = self.upload()
        r = self.send_media(ref)
        mid = r.json()["id"]
        row = self._rows(self.ca, self.ab)[mid]
        self.assertNotIn("view_once", row)
        self.assertEqual(row["blob_ref"], ref)
        r = self.cb.post("%s/circle/messages/%d/view-once-open" % (V, mid))
        self.assertEqual(r.status_code, 400)

    def test_view_once_ignored_on_text(self):
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "text", "view_once": True,
            "ciphertext": "RU5D", "nonce": "Tg==", "sender_key_id": "kA",
            "client_msg_id": "t1"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertFalse(CircleMessage.objects.get(pk=r.json()["id"]).view_once)


class DisappearingDeletedTests(_Base):
    def _timer(self, sec=86400):
        r = self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                         {"disappearing_sec": sec}, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)

    def test_mirrored_to_peer(self):
        self._timer()
        self.assertEqual(ChatSettings.objects.get(
            user=self.b, peer=self.ba).disappearing_sec, 86400)

    def test_read_deletes_expired_rows_and_blobs(self):
        self._timer()
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "text", "ciphertext": "RU5D", "nonce": "Tg==",
            "sender_key_id": "kA", "client_msg_id": "t2"}, format="json")
        tid = r.json()["id"]
        old = timezone.now() - timedelta(days=2)
        CircleMessage.objects.filter(pk__in=[mid, tid]).update(created_at=old)
        # the timer started before the messages
        MsgChatPref.objects.filter(chat_kind="member").update(
            disappearing_since=old - timedelta(minutes=1))
        r = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        ids = [x["id"] for x in r.json()["results"]]
        self.assertNotIn(mid, ids)
        self.assertFalse(CircleMessage.objects.filter(pk__in=[mid, tid]).exists())
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_fresh_messages_stay(self):
        self._timer()
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "text", "ciphertext": "RU5D", "nonce": "Tg==",
            "sender_key_id": "kA", "client_msg_id": "t3"}, format="json")
        tid = r.json()["id"]
        r = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        self.assertIn(tid, [x["id"] for x in r.json()["results"]])
        self.assertTrue(CircleMessage.objects.filter(pk=tid).exists())

    def test_purge_command_drops_blobs(self):
        self._timer()
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        old = timezone.now() - timedelta(days=2)
        CircleMessage.objects.filter(pk=mid).update(created_at=old)
        MsgChatPref.objects.filter(chat_kind="member").update(
            disappearing_since=old - timedelta(minutes=1))
        call_command("purge_disappearing")
        self.assertFalse(CircleMessage.objects.filter(pk=mid).exists())
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertTrue(len(CIPHER) > 0)
