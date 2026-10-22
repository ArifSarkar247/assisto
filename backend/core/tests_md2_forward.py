"""md2 — forwarding E2E media into GROUPS (and group -> 1:1, group -> group),
PROVEN on the real endpoints.

A forward is a NEW message carrying the SAME blob_ref (the per-recipient E2E
envelope holds the same key/nonce/sha descriptor — no re-upload). So:
  * members of EVERY chat the blob was forwarded into can open it; someone
    outside all of them still gets a 404;
  * only someone who can already open the blob may forward it;
  * retention counts every chat: "all downloaded" needs every recipient of
    every copy; delete-for-everyone of one copy never removes a blob another
    chat still shows; the last copy going removes it at once;
  * the group copy keeps the "Forwarded" metadata;
  * my own rows carry client_msg_id (the phone swaps its bubble in place);
  * a received media message's ticks follow the text rules (fetch =
    delivered, seen = read).

Run: manage.py test core.tests_md2_forward --settings=assisto_backend.settings_test
"""
import os
from datetime import timedelta

from django.utils import timezone

from core import circle_blobs as CB
from core.models import (CircleGroup, CircleGroupMember, CircleMediaBlob,
                         CircleMember, CircleMessage, CircleReceipt)
from core.tests_md1_media import V, _Base, cl, mk


class _Fwd(_Base):
    def setUp(self):
        super().setUp()
        self.d = mk("01710000004", "Dipu")
        self.cd = cl(self.d)
        # B <-> C are in each other's circle too (group -> 1:1 forward)
        self.bc = CircleMember.objects.create(
            user=self.b, peer_user=self.c, name="Chaya", state="accepted",
            phone=self.c.phone)
        self.cb_edge = CircleMember.objects.create(
            user=self.c, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, direction="incoming")

    def group(self, name, admin, *members):
        g = CircleGroup.objects.create(creator=admin, name=name)
        rows = {admin.id: CircleGroupMember.objects.create(
            group=g, member=admin, role="admin")}
        for u in members:
            rows[u.id] = CircleGroupMember.objects.create(group=g, member=u)
        return g, rows

    def send_group(self, client, g, rows, sender, ref, kind="photo",
                   cmid="g1", forwarded=False, hops=0):
        others = [r for uid, r in rows.items() if uid != sender.id]
        body = {
            "content_type": kind, "blob_ref": ref,
            "recipient_ids": [r.id for r in others],
            "per_recipient": {str(r.id): {"ciphertext": "RA==", "nonce": "Tg=="}
                              for r in others},
            "client_msg_id": cmid}
        if forwarded:
            body.update({"forwarded": True, "forward_hops": hops})
        return client.post("%s/circle/groups/%d/messages" % (V, g.id), body,
                           format="json")

    def blob(self, ref):
        return CircleMediaBlob.objects.get(ref=ref)


class ForwardIntoGroupTests(_Fwd):
    def test_one_to_one_into_group_same_blob(self):
        ref = self.upload()
        self.assertEqual(self.send_media(ref).status_code, 201)
        g, rows = self.group("Friends", self.b, self.c)
        n_blobs = CircleMediaBlob.objects.count()
        r = self.send_group(self.cb, g, rows, self.b, ref, cmid="fw1",
                            forwarded=True, hops=1)
        self.assertEqual(r.status_code, 201, r.content)
        # no re-upload: still ONE blob, now linked to both chats
        self.assertEqual(CircleMediaBlob.objects.count(), n_blobs)
        self.assertEqual(CircleMessage.objects.filter(blob_ref=ref).count(), 2)
        self.assertEqual(sorted(self.blob(ref).recipients),
                         sorted([self.b.id, self.c.id]))
        # C (group only) can open it; D (in no chat) cannot
        self.assertEqual(self.url_for(ref, self.cc).status_code, 200)
        self.assertEqual(self.url_for(ref, self.cd).status_code, 404)
        # the group copy is labelled Forwarded
        rows_c = self.cc.get("%s/circle/groups/%d/messages" % (V, g.id)).json()
        row = rows_c["results"][-1]
        self.assertEqual((row["forwarded"], row["forward_hops"],
                          row["blob_ref"]), (True, 1, ref))

    def test_group_to_group_and_group_to_one_to_one(self):
        g1, r1 = self.group("Family", self.a, self.b)
        ref = self.upload()
        self.assertEqual(self.send_group(self.ca, g1, r1, self.a, ref,
                                         kind="document").status_code, 201)
        g2, r2 = self.group("Work", self.b, self.d)
        r = self.send_group(self.cb, g2, r2, self.b, ref, kind="document",
                            cmid="fw-g2", forwarded=True, hops=1)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.url_for(ref, self.cd).status_code, 200)
        self.assertEqual(self.url_for(ref, self.cc).status_code, 404)
        # group -> 1:1 (B forwards to C)
        r = self.send_media(ref, kind="document", client=self.cb,
                            edge=self.bc, cmid="fw-1to1")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.url_for(ref, self.cc).status_code, 200)
        self.assertEqual(sorted(self.blob(ref).recipients),
                         sorted([self.b.id, self.c.id, self.d.id]))

    def test_forwarder_must_already_have_access(self):
        ref = self.upload()
        self.send_media(ref)                     # A -> B only
        g, rows = self.group("Strangers", self.c, self.d)
        r = self.send_group(self.cc, g, rows, self.c, ref, cmid="steal",
                            forwarded=True, hops=1)
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (400, "blob_missing"))
        self.assertEqual(self.url_for(ref, self.cd).status_code, 404)
        # a member who LEFT the group cannot forward its media any more
        g1, r1 = self.group("Family", self.a, self.c)
        ref2 = self.upload(data=b"\x01" * 5000)
        self.send_group(self.ca, g1, r1, self.a, ref2, cmid="g-left")
        r1[self.c.id].status = "left"
        r1[self.c.id].save(update_fields=["status"])
        r = self.send_media(ref2, client=self.cc, edge=self.cb_edge,
                            cmid="left-fwd")
        self.assertEqual(r.json()["reason"], "blob_missing")

    def test_bad_forward_hops_refused(self):
        ref = self.upload()
        self.send_media(ref)
        g, rows = self.group("Friends", self.b, self.c)
        body = {"content_type": "photo", "blob_ref": ref,
                "recipient_ids": [rows[self.c.id].id],
                "per_recipient": {str(rows[self.c.id].id):
                                  {"ciphertext": "RA==", "nonce": "Tg=="}},
                "forwarded": True, "forward_hops": "many"}
        r = self.cb.post("%s/circle/groups/%d/messages" % (V, g.id), body,
                         format="json")
        self.assertEqual(r.status_code, 400)


class ForwardRetentionTests(_Fwd):
    def _forwarded_into_group(self):
        ref = self.upload()
        mid1 = self.send_media(ref).json()["id"]          # A -> B
        g, rows = self.group("Friends", self.b, self.c)
        mid2 = self.send_group(self.cb, g, rows, self.b, ref, cmid="fw1",
                               forwarded=True, hops=1).json()["id"]
        return ref, mid1, g, mid2

    def test_delete_one_copy_keeps_blob_for_the_other_chat(self):
        ref, mid1, g, mid2 = self._forwarded_into_group()
        r = self.ca.post("%s/circle/messages/%d/delete" % (V, mid1),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertTrue(os.path.exists(CB.path_for(ref)))
        self.assertEqual(self.url_for(ref, self.cc).status_code, 200)
        # B still opens it through the group copy (the 1:1 copy is gone)
        self.assertEqual(self.url_for(ref, self.cb).status_code, 200)
        # the LAST copy going removes the blob + file at once
        r = self.cb.post("%s/circle/groups/%d/messages/%d/delete"
                         % (V, g.id, mid2), {"scope": "everyone"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertFalse(os.path.exists(CB.path_for(ref)))

    def test_purge_counts_every_chat(self):
        ref, mid1, g, mid2 = self._forwarded_into_group()
        now = timezone.now()
        # B downloaded, C (group) not yet -> not "all downloaded"
        self.cb.get(self.url_for(ref, self.cb).json()["url"])
        self.assertIsNone(self.blob(ref).all_downloaded_at)
        CircleMediaBlob.objects.filter(ref=ref).update(
            created_at=now - timedelta(days=40))
        CB.purge()
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())
        # one copy tombstoned (older than a day): the other keeps it
        CircleMessage.objects.filter(pk=mid1).update(deleted="everyone")
        CB.purge()
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())
        # C downloads -> everyone of every chat has it -> keep_days rule
        self.cc.get(self.url_for(ref, self.cc).json()["url"])
        b = self.blob(ref)
        self.assertIsNotNone(b.all_downloaded_at)
        CircleMediaBlob.objects.filter(ref=ref).update(
            all_downloaded_at=now - timedelta(days=31))
        out = CB.purge()
        self.assertEqual(out["downloaded"], 1)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_every_copy_deleted_is_purged(self):
        ref, mid1, g, mid2 = self._forwarded_into_group()
        CircleMessage.objects.filter(blob_ref=ref).update(deleted="everyone")
        CircleMediaBlob.objects.filter(ref=ref).update(
            created_at=timezone.now() - timedelta(hours=25))
        out = CB.purge()
        self.assertEqual(out["deleted_msgs"], 1)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_new_recipient_resets_all_downloaded(self):
        ref = self.upload()
        self.send_media(ref)
        self.cb.get(self.url_for(ref, self.cb).json()["url"])
        self.assertIsNotNone(self.blob(ref).all_downloaded_at)
        g, rows = self.group("Friends", self.b, self.c)
        self.send_group(self.cb, g, rows, self.b, ref, cmid="fw1",
                        forwarded=True, hops=1)
        # C has not downloaded yet: the keep_days clock must not run
        self.assertIsNone(self.blob(ref).all_downloaded_at)


class ReconcileAndTicksTests(_Fwd):
    def test_client_msg_id_only_on_my_rows(self):
        ref = self.upload()
        self.send_media(ref, cmid="local-123")
        mine = self.ca.get("%s/circle/%d/messages" % (V, self.ab.id)).json()
        theirs = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id)).json()
        self.assertEqual(mine["results"][-1]["client_msg_id"], "local-123")
        self.assertEqual(theirs["results"][-1]["client_msg_id"], "")
        g, rows = self.group("Friends", self.a, self.b)
        self.send_group(self.ca, g, rows, self.a, ref, cmid="local-g")
        mine = self.ca.get("%s/circle/groups/%d/messages" % (V, g.id)).json()
        theirs = self.cb.get("%s/circle/groups/%d/messages" % (V, g.id)).json()
        self.assertEqual(mine["results"][-1]["client_msg_id"], "local-g")
        self.assertEqual(theirs["results"][-1]["client_msg_id"], "")

    def test_media_ticks_follow_text_rules(self):
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        row = self.ca.get("%s/circle/%d/messages" % (V, self.ab.id)).json()[
            "results"][-1]
        self.assertEqual(row["status"], "sent")
        # the recipient's fetch = delivered (not read)
        self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        rc = CircleReceipt.objects.get(message_id=mid, user=self.b)
        self.assertIsNotNone(rc.delivered_at)
        self.assertIsNone(rc.seen_at)
        row = self.ca.get("%s/circle/%d/messages" % (V, self.ab.id)).json()[
            "results"][-1]
        self.assertEqual(row["status"], "delivered")
        # opening the chat (seen) = read (blue), downloading is not needed
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        row = self.ca.get("%s/circle/%d/messages" % (V, self.ab.id)).json()[
            "results"][-1]
        self.assertEqual(row["status"], "read")
