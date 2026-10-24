"""e2e-groups — peer-assisted history re-share for GROUP chats: only active
members may write/read copies, only messages both parties received, the
FIRST copy per (message, for_user) wins (later duplicates skipped
idempotently; the original sender's copy may replace), originals untouched,
non-members / ex-members refused, ask flow + key-change fan-out.

Run: manage.py test core.tests_e2e_groups --settings=assisto_backend.settings_test
"""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.models import (CircleGroup, CircleGroupMember, CircleMessage,
                         CircleMessageCopy, E2GroupResendRequest, RtEvent,
                         User, UserPublicKey)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class GroupReshareTests(TestCase):
    def setUp(self):
        self.a = mk("01710000301", "Arif")
        self.b = mk("01710000302", "Shanto")
        self.c = mk("01710000303", "Rina")
        self.e = mk("01710000304", "Eve")
        self.ca, self.cb, self.cc, self.ce = (cl(self.a), cl(self.b),
                                              cl(self.c), cl(self.e))
        self.g = CircleGroup.objects.create(creator=self.b, name="Family")
        self.ga = CircleGroupMember.objects.create(group=self.g, member=self.a)
        self.gb = CircleGroupMember.objects.create(group=self.g, member=self.b,
                                                   role="admin")
        self.gc = CircleGroupMember.objects.create(group=self.g, member=self.c)
        for u, k, kid in ((self.a, "QUFB", "a1"), (self.b, "QkJC", "b1"),
                          (self.c, "Q0ND", "c1")):
            UserPublicKey.objects.create(user=u, public_key=k, key_id=kid)
        # B -> A, C ; C -> A, B ; A -> B, C ; and one B -> C only (A absent)
        self.m1 = self._msg(self.b, [self.ga, self.gc])
        self.m2 = self._msg(self.c, [self.ga, self.gb])
        self.m3 = self._msg(self.a, [self.gb, self.gc])
        self.m4 = self._msg(self.b, [self.gc])

    def _msg(self, sender, to):
        return CircleMessage.objects.create(
            group=self.g, sender=sender, recipient_ids=[m.id for m in to],
            ciphertext="T1JJRw==", nonce="bm9uY2Ux", sender_key_id="x",
            per_recipient={str(m.id): {"ciphertext": "T1JJRw==",
                                       "nonce": "bm9uY2Ux"} for m in to})

    def _rekey_a(self):
        r = self.ca.post(V + "/circle/keys", {"public_key": "TkVX",
                                              "key_id": "a2"}, format="json")
        self.assertTrue(r.json()["changed"])

    def _cp(self, mid, ct="Q09QWQ=="):
        return {"message_id": mid, "ciphertext": ct, "nonce": "bm9uY2Uz",
                "sender_key_id": "b1", "scheme": "x25519-xchacha-fallback-v1"}

    def _up(self, client, copies, fkid="a2", uid=None, done=True):
        return client.post(V + "/circle/groups/%d/e2/copies" % self.g.id,
                           {"for_user_id": uid or self.a.id,
                            "for_key_id": fkid, "done": done,
                            "copies": copies}, format="json")

    def _pending(self, client):
        return client.get(V + "/circle/e2/resend").json()["groups"]

    def _rows(self, client):
        r = client.get(V + "/circle/groups/%d/messages" % self.g.id)
        return r

    def test_key_change_lists_request_for_each_member(self):
        self._rekey_a()
        req = E2GroupResendRequest.objects.get(requester=self.a, group=self.g)
        self.assertTrue(req.whole)
        self.assertEqual(req.key_id, "a2")
        self.assertTrue(RtEvent.objects.filter(user=self.b,
                                               topic="e2.resend").exists())
        self.assertTrue(RtEvent.objects.filter(user=self.c,
                                               topic="e2.resend").exists())
        pb = self._pending(self.cb)
        self.assertEqual(len(pb), 1)
        self.assertEqual(pb[0]["group_id"], self.g.id)
        self.assertEqual(pb[0]["public_key"], "TkVX")
        self.assertEqual(pb[0]["member_id"], self.ga.id)
        self.assertEqual(pb[0]["my_member_id"], self.gb.id)
        # B can help with what B sent or received AND A received; never m4
        self.assertEqual(pb[0]["message_ids"],
                         sorted([self.m1.id, self.m2.id, self.m3.id]))
        pc = self._pending(self.cc)
        self.assertEqual(pc[0]["message_ids"],
                         sorted([self.m1.id, self.m2.id, self.m3.id]))
        # A never gets its own request
        self.assertEqual(self._pending(self.ca), [])

    def test_first_copy_wins_original_untouched(self):
        self._rekey_a()
        r = self._up(self.cb, [self._cp(self.m1.id), self._cp(self.m3.id)],
                     done=False)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["stored"], 2)
        # C's phone answers the same request: duplicates skipped (idempotent)
        r = self._up(self.cc, [self._cp(self.m1.id, "Q0NDQw=="),
                               self._cp(self.m3.id, "Q0NDQw==")])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["stored"], 0)
        self.assertEqual(r.json()["duplicate"], 2)
        for m in (self.m1, self.m3):
            q = CircleMessageCopy.objects.filter(message=m, for_user=self.a)
            self.assertEqual(q.count(), 1)
            self.assertEqual(q.get().by_user, self.b)
        # originals never modified
        for m in (self.m1, self.m2, self.m3):
            m.refresh_from_db()
            self.assertEqual(m.ciphertext, "T1JJRw==")
            self.assertEqual(set(m.per_recipient), set(
                str(i) for i in m.recipient_ids))
        rows = {x["id"]: x for x in self._rows(self.ca).json()["results"]}
        self.assertEqual(rows[self.m1.id]["copy"]["ciphertext"], "Q09QWQ==")
        self.assertEqual(rows[self.m1.id]["copy"]["by"], self.b.id)
        self.assertEqual(rows[self.m1.id]["ciphertext"], "T1JJRw==")
        self.assertNotIn("copy", rows[self.m2.id])
        # other members never see A's copies
        for cli in (self.cb, self.cc):
            self.assertFalse(any("copy" in x for x in
                                 self._rows(cli).json()["results"]))
        # what is still missing: only m2 -> still pending for B (C served)
        self.assertEqual(self._pending(self.cb)[0]["message_ids"],
                         [self.m2.id])
        self.assertEqual(self._pending(self.cc), [])
        # m2 arrives -> fulfilled for everyone
        r = self._up(self.cb, [self._cp(self.m2.id)])
        self.assertEqual(r.json()["fulfilled"], 1)
        self.assertEqual(self._pending(self.cb), [])
        self.assertIsNotNone(E2GroupResendRequest.objects.get(
            requester=self.a).fulfilled_at)

    def test_concurrent_duplicate_is_idempotent(self):
        self._rekey_a()
        # another member's phone won the race for m3 (sent by A itself)
        CircleMessageCopy.objects.create(message=self.m3, for_user=self.a,
                                         by_user=self.b, ciphertext="WA==",
                                         nonce="WA==", key_id="a2")
        r = self._up(self.cc, [self._cp(self.m3.id)])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["duplicate"], 1)
        cp = CircleMessageCopy.objects.get(message=self.m3, for_user=self.a)
        self.assertEqual((cp.by_user, cp.ciphertext), (self.b, "WA=="))

    def test_sender_copy_replaces_and_old_key_copy_replaced(self):
        self._rekey_a()
        # C uploads m1 (sent by B) first; B (the sender) may replace it
        self._up(self.cc, [self._cp(self.m1.id, "Q0NDQw==")], done=False)
        r = self._up(self.cb, [self._cp(self.m1.id)], done=False)
        self.assertEqual(r.json()["stored"], 1)
        cp = CircleMessageCopy.objects.get(message=self.m1, for_user=self.a)
        self.assertEqual((cp.by_user, cp.ciphertext), (self.b, "Q09QWQ=="))
        # ...but never the other way round
        r = self._up(self.cc, [self._cp(self.m1.id, "Q0NDQw==")], done=False)
        self.assertEqual(r.json()["duplicate"], 1)
        # a copy for A's OLDER key is replaced after another re-key
        self.ca.post(V + "/circle/keys", {"public_key": "TkVXMw==",
                                          "key_id": "a3"}, format="json")
        r = self._up(self.cc, [self._cp(self.m1.id, "Q0NDQw==")], fkid="a3")
        self.assertEqual(r.json()["stored"], 1)
        self.assertEqual(CircleMessageCopy.objects.filter(
            message=self.m1, for_user=self.a).count(), 1)

    def test_only_messages_both_received(self):
        self._rekey_a()
        # m4 never reached A (A's member id not in per_recipient)
        r = self._up(self.cb, [self._cp(self.m4.id)])
        self.assertEqual(r.json()["stored"], 0)
        self.assertEqual(r.json()["skipped"], 1)
        # a member who did not receive a message cannot re-share it: m4 for C
        # is fine for B, but B-for-C of m2 (C sent it, B got it) is ok, and
        # a 4th member D who joined later cannot attach a copy of m1
        d = mk("01710000305", "Dina")
        CircleGroupMember.objects.create(group=self.g, member=d)
        r = self._up(cl(d), [self._cp(self.m1.id)])
        self.assertEqual(r.json()["stored"], 0)
        self.assertFalse(CircleMessageCopy.objects.exists())
        # messages older than 90 days are out of the window
        CircleMessage.objects.filter(pk=self.m1.pk).update(
            created_at=timezone.now() - timedelta(days=91))
        r = self._up(self.cb, [self._cp(self.m1.id)])
        self.assertEqual(r.json()["stored"], 0)

    def test_non_member_refused(self):
        self._rekey_a()
        r = self._up(self.ce, [self._cp(self.m1.id)])
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self._rows(self.ce).status_code, 404)
        r = self.ce.post(V + "/circle/groups/%d/e2/resend" % self.g.id,
                         {"message_ids": [self.m1.id]}, format="json")
        self.assertEqual(r.status_code, 404)
        # a copy for a non-member target is refused too
        UserPublicKey.objects.create(user=self.e, public_key="RUVF",
                                     key_id="e1")
        r = self._up(self.cb, [self._cp(self.m1.id)], fkid="e1", uid=self.e.id)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self._pending(self.ce), [])
        self.assertFalse(CircleMessageCopy.objects.exists())

    def test_ex_member_cannot_read_new_copies(self):
        self._rekey_a()
        self.ga.status = "removed"
        self.ga.save()
        r = self._up(self.cb, [self._cp(self.m1.id)])
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self._rows(self.ca).status_code, 404)
        self.assertEqual(self._pending(self.cb), [])
        # an ex-member cannot upload either
        r = self.ca.post(V + "/circle/groups/%d/e2/copies" % self.g.id,
                         {"for_user_id": self.b.id, "for_key_id": "b1",
                          "copies": [self._cp(self.m3.id)]}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertFalse(CircleMessageCopy.objects.exists())

    def test_stale_key_and_plaintext_refused(self):
        self._rekey_a()
        r = self._up(self.cb, [self._cp(self.m1.id)], fkid="a1")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["key_id"], "a2")
        c = self._cp(self.m1.id)
        c["text"] = "hello"
        self.assertEqual(self._up(self.cb, [c]).status_code, 400)
        r = self._up(self.cb, [self._cp(self.m1.id, "not base64!")])
        self.assertEqual(r.json()["stored"], 0)
        self.assertFalse(CircleMessageCopy.objects.exists())

    def test_ask_flow(self):
        # no key change (older server / a single bad message): A asks
        r = self.ca.post(V + "/circle/groups/%d/e2/resend" % self.g.id,
                         {"message_ids": [self.m2.id, self.m4.id, 999999]},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["queued"])
        self.assertTrue(r.json()["notified"])
        req = E2GroupResendRequest.objects.get(requester=self.a)
        self.assertEqual(req.message_ids, [self.m2.id])   # m4 / 999999 dropped
        self.assertEqual(req.key_id, "a1")
        r = self.ca.post(V + "/circle/groups/%d/e2/resend" % self.g.id,
                         {"message_ids": [self.m2.id]}, format="json")
        self.assertFalse(r.json()["notified"])             # throttled
        self.assertEqual(E2GroupResendRequest.objects.count(), 1)
        self.assertEqual(self._pending(self.cb)[0]["message_ids"],
                         [self.m2.id])
        r = self._up(self.cb, [self._cp(self.m2.id)], fkid="a1")
        self.assertEqual(r.json()["stored"], 1)
        req.refresh_from_db()
        self.assertIsNotNone(req.fulfilled_at)
        self.assertTrue(RtEvent.objects.filter(user=self.a,
                                               topic="e2.copies").exists())

    def test_deleted_for_everyone_copy_hidden(self):
        CircleMessageCopy.objects.create(message=self.m1, for_user=self.a,
                                         by_user=self.b, ciphertext="WA==",
                                         nonce="WA==", key_id="a1")
        self.m1.deleted = "everyone"
        self.m1.save()
        self.assertFalse(any("copy" in x for x in
                             self._rows(self.ca).json()["results"]))

    def test_roster_carries_key_history(self):
        self._rekey_a()
        r = self.cb.get(V + "/circle/groups/%d/members" % self.g.id).json()
        row = [x for x in r["results"] if x["user_id"] == self.a.id][0]
        self.assertEqual(row["public_key"], "TkVX")
        self.assertEqual(row["key_history"], ["QUFB"])
