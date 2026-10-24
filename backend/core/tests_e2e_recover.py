"""e2e-recover — PIN-sealed key-ring backup (auth proof, wrong-PIN counting,
lockout, blob never released without proof, ciphertext only) and
peer-assisted history resend (replacement copies: only the two parties of
the chat may write/read, the original ciphertext stays untouched; resend
request flow; key-change fan-out).

Run: manage.py test core.tests_e2e_recover --settings=assisto_backend.settings_test
"""
import base64
import os
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.models import (AuditLog, CircleMember, CircleMessage,
                         CircleMessageCopy, E2KeyBackup, E2ResendRequest,
                         RtEvent, User, UserPublicKey)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def pair(a, b):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name,
                                     state="accepted", phone=b.phone)
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name,
                                     state="accepted", phone=a.phone,
                                     direction="incoming")
    return ab, ba


def b64(n):
    return base64.b64encode(os.urandom(n)).decode()


def backup_body(auth, **kw):
    d = {"salt": b64(16), "kdf": {"alg": "scrypt", "n": 32768, "r": 8, "p": 1},
         "auth_key": auth, "blob": b64(200), "nonce": b64(12),
         "key_ids": ["k1", "k0"], "current_key_id": "k1"}
    d.update(kw)
    return d


class KeyBackupTests(TestCase):
    def setUp(self):
        self.u = mk("01710000101", "Arif")
        self.c = cl(self.u)
        self.auth = b64(32)

    def _save(self, auth=None, **kw):
        return self.c.post(V + "/e2/backup", backup_body(auth or self.auth, **kw),
                           format="json")

    def test_meta_never_contains_blob_or_hash(self):
        self.assertFalse(self.c.get(V + "/e2/backup").json()["exists"])
        self.assertEqual(self._save().status_code, 200)
        j = self.c.get(V + "/e2/backup").json()
        self.assertTrue(j["exists"])
        s = j["slots"][0]
        self.assertEqual(s["kdf"]["n"], 32768)
        self.assertNotIn("blob", s)
        self.assertNotIn("auth_hash", s)
        self.assertNotIn(self.auth, str(j))
        # server stores a hash, not the auth key
        row = E2KeyBackup.objects.get(user=self.u)
        self.assertNotEqual(row.auth_hash, self.auth)
        self.assertNotIn(self.auth, row.auth_hash)

    def test_open_requires_correct_proof(self):
        blob = b64(300)
        self._save(blob=blob)
        bad = self.c.post(V + "/e2/backup/open",
                          {"proofs": [{"slot": 0, "auth_key": b64(32)}]},
                          format="json")
        self.assertEqual(bad.status_code, 403)
        self.assertNotIn(blob, str(bad.json()))
        self.assertEqual(bad.json()["attempts_left"], 4)
        ok = self.c.post(V + "/e2/backup/open",
                         {"proofs": [{"slot": 0, "auth_key": self.auth}]},
                         format="json")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["slots"][0]["blob"], blob)
        self.assertEqual(E2KeyBackup.objects.get(user=self.u).wrong_total, 0)
        self.assertTrue(AuditLog.objects.filter(
            user=self.u, action="e2.backup.restored").exists())

    def test_five_wrong_per_hour_then_blocked(self):
        self._save()
        for i in range(5):
            r = self.c.post(V + "/e2/backup/open",
                            {"proofs": [{"slot": 0, "auth_key": b64(32)}]},
                            format="json")
            self.assertEqual(r.status_code, 403, i)
        # even the RIGHT pin is refused now (no oracle while blocked)
        r = self.c.post(V + "/e2/backup/open",
                        {"proofs": [{"slot": 0, "auth_key": self.auth}]},
                        format="json")
        self.assertEqual(r.status_code, 429)
        self.assertNotIn("slots", r.json())
        self.assertEqual(AuditLog.objects.filter(
            user=self.u, action="e2.backup.wrong_pin").count(), 5)
        # an hour later: allowed again
        row = E2KeyBackup.objects.get(user=self.u)
        row.window_start = timezone.now() - timedelta(hours=1, minutes=1)
        row.save()
        r = self.c.post(V + "/e2/backup/open",
                        {"proofs": [{"slot": 0, "auth_key": self.auth}]},
                        format="json")
        self.assertEqual(r.status_code, 200)

    def test_lock_24h_after_ten_in_a_row(self):
        self._save()
        row = E2KeyBackup.objects.get(user=self.u)
        row.wrong_total = 9
        row.save()
        r = self.c.post(V + "/e2/backup/open",
                        {"proofs": [{"slot": 0, "auth_key": b64(32)}]},
                        format="json")
        self.assertEqual(r.status_code, 403)
        row.refresh_from_db()
        self.assertIsNotNone(row.locked_until)
        self.assertGreater(row.locked_until, timezone.now() + timedelta(hours=23))
        self.assertTrue(AuditLog.objects.filter(
            user=self.u, action="e2.backup.locked").exists())
        r = self.c.post(V + "/e2/backup/open",
                        {"proofs": [{"slot": 0, "auth_key": self.auth}]},
                        format="json")
        self.assertEqual(r.status_code, 429)

    def test_plaintext_or_pin_refused(self):
        for f in ("pin", "private_key", "plaintext"):
            r = self._save(**{f: "1234"})
            self.assertEqual(r.status_code, 400, f)
        self.assertFalse(E2KeyBackup.objects.exists())

    def test_weak_kdf_refused(self):
        r = self._save(kdf={"alg": "scrypt", "n": 1024, "r": 8, "p": 1})
        self.assertEqual(r.status_code, 400)
        r = self._save(kdf={"alg": "pbkdf2", "n": 32768, "r": 8, "p": 1})
        self.assertEqual(r.status_code, 400)

    def test_different_pin_archives_old_ring(self):
        old_blob = b64(300)
        self._save(blob=old_blob)
        other = b64(32)
        r = self._save(auth=other)
        self.assertTrue(r.json()["archived"])
        meta = self.c.get(V + "/e2/backup").json()
        self.assertEqual([s["slot"] for s in meta["slots"]], [0, 1])
        # old ring still opens with the OLD proof (slot 1)
        r = self.c.post(V + "/e2/backup/open",
                        {"proofs": [{"slot": 0, "auth_key": self.auth},
                                    {"slot": 1, "auth_key": self.auth}]},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([s["blob"] for s in r.json()["slots"]], [old_blob])
        # same pin again = in-place refresh, no new archive entry
        r = self._save(auth=other)
        self.assertFalse(r.json()["archived"])

    def test_only_own_backup(self):
        self._save()
        other = cl(mk("01710000102", "Eve"))
        self.assertFalse(other.get(V + "/e2/backup").json()["exists"])
        r = other.post(V + "/e2/backup/open",
                       {"proofs": [{"slot": 0, "auth_key": self.auth}]},
                       format="json")
        self.assertEqual(r.status_code, 404)


class HistoryResendTests(TestCase):
    def setUp(self):
        self.a = mk("01710000201", "Arif")
        self.b = mk("01710000202", "Shanto")
        self.e = mk("01710000203", "Eve")
        self.ab, self.ba = pair(self.a, self.b)
        self.ca, self.cb, self.ce = cl(self.a), cl(self.b), cl(self.e)
        UserPublicKey.objects.create(user=self.a, public_key="QUFB", key_id="a1")
        UserPublicKey.objects.create(user=self.b, public_key="QkJC", key_id="b1")
        self.m1 = CircleMessage.objects.create(
            member=self.ab, sender=self.a, recipient_ids=[self.ab.id],
            ciphertext="T1JJRzE=", nonce="bm9uY2Ux", sender_key_id="a0")
        self.m2 = CircleMessage.objects.create(
            member=self.ba, sender=self.b, recipient_ids=[self.ba.id],
            ciphertext="T1JJRzI=", nonce="bm9uY2Uy", sender_key_id="b1")

    def _rekey_a(self):
        r = self.ca.post(V + "/circle/keys", {"public_key": "TkVX",
                                              "key_id": "a2"}, format="json")
        self.assertTrue(r.json()["changed"])

    def _copy(self, mid, ct="Q09QWQ=="):
        return {"message_id": mid, "ciphertext": ct, "nonce": "bm9uY2Uz",
                "sender_key_id": "b1", "scheme": "x25519-xchacha-fallback-v1"}

    def test_key_change_creates_request_for_peer(self):
        self._rekey_a()
        req = E2ResendRequest.objects.get(requester=self.a, target=self.b)
        self.assertTrue(req.whole)
        self.assertEqual(req.key_id, "a2")
        self.assertTrue(RtEvent.objects.filter(user=self.b,
                                               topic="e2.resend").exists())
        j = self.cb.get(V + "/circle/e2/resend").json()["results"]
        self.assertEqual(len(j), 1)
        self.assertEqual(j[0]["chat_id"], self.ba.id)
        self.assertEqual(j[0]["public_key"], "TkVX")
        self.assertEqual(j[0]["key_id"], "a2")

    def test_old_key_change_synthesised(self):
        # a change made BEFORE this feature (no request row) still shows up
        UserPublicKey.objects.filter(user=self.a).update(
            changed_at=timezone.now() - timedelta(days=1), key_id="a2")
        j = self.cb.get(V + "/circle/e2/resend").json()["results"]
        self.assertEqual([r["user_id"] for r in j], [self.a.id])

    def test_copies_upload_and_read_original_untouched(self):
        self._rekey_a()
        r = self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                         {"for_key_id": "a2", "done": True,
                          "copies": [self._copy(self.m1.id),
                                     self._copy(self.m2.id, "Q09QWTI=")]},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["stored"], 2)
        self.assertEqual(r.json()["fulfilled"], 1)
        self.m1.refresh_from_db()
        self.m2.refresh_from_db()
        self.assertEqual(self.m1.ciphertext, "T1JJRzE=")   # untouched
        self.assertEqual(self.m2.ciphertext, "T1JJRzI=")
        rows = self.ca.get(V + "/circle/%d/messages" % self.ab.id).json()
        rows = rows.get("results", rows)
        by = {x["id"]: x for x in rows}
        self.assertEqual(by[self.m1.id]["ciphertext"], "T1JJRzE=")
        self.assertEqual(by[self.m1.id]["copy"]["ciphertext"], "Q09QWQ==")
        self.assertEqual(by[self.m2.id]["copy"]["key_id"], "a2")
        # B (the uploader) never gets A's copies in B's own view
        rows_b = self.cb.get(V + "/circle/%d/messages" % self.ba.id).json()
        rows_b = rows_b.get("results", rows_b)
        self.assertFalse(any("copy" in x for x in rows_b))
        # request fulfilled -> nothing pending for B
        self.assertEqual(self.cb.get(V + "/circle/e2/resend").json()["results"],
                         [])
        # idempotent re-upload: still one copy per (message, for_user)
        self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                     {"for_key_id": "a2", "copies": [self._copy(self.m1.id)]},
                     format="json")
        self.assertEqual(CircleMessageCopy.objects.filter(
            message=self.m1, for_user=self.a).count(), 1)

    def test_stale_key_refused(self):
        self._rekey_a()
        r = self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                         {"for_key_id": "a1",
                          "copies": [self._copy(self.m1.id)]}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["key_id"], "a2")
        self.assertFalse(CircleMessageCopy.objects.exists())

    def test_outsider_cannot_write_or_read(self):
        self._rekey_a()
        # Eve has no edge for this chat -> 404 on B's edge id
        r = self.ce.post(V + "/circle/%d/e2/copies" % self.ba.id,
                         {"for_key_id": "a2",
                          "copies": [self._copy(self.m1.id)]}, format="json")
        self.assertEqual(r.status_code, 404)
        # Eve with her OWN edge to A cannot attach copies to A<->B messages
        ea, ae = pair(self.e, self.a)
        r = self.ce.post(V + "/circle/%d/e2/copies" % ea.id,
                         {"for_key_id": "a2",
                          "copies": [self._copy(self.m1.id)]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["stored"], 0)
        self.assertFalse(CircleMessageCopy.objects.exists())
        # and Eve never sees A<->B copies
        CircleMessageCopy.objects.create(message=self.m1, for_user=self.a,
                                         by_user=self.b, ciphertext="WA==",
                                         nonce="WA==", key_id="a2")
        r = self.ce.get(V + "/circle/%d/messages" % ea.id).json()
        self.assertNotIn("WA==", str(r))

    def test_copy_plaintext_refused(self):
        self._rekey_a()
        c = self._copy(self.m1.id)
        c["text"] = "hello"
        r = self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                         {"for_key_id": "a2", "copies": [c]}, format="json")
        self.assertEqual(r.status_code, 400)
        c = self._copy(self.m1.id, ct="not base64 at all!")
        r = self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                         {"for_key_id": "a2", "copies": [c]}, format="json")
        self.assertEqual(r.json()["stored"], 0)

    def test_deleted_for_everyone_copy_hidden(self):
        CircleMessageCopy.objects.create(message=self.m1, for_user=self.a,
                                         by_user=self.b, ciphertext="WA==",
                                         nonce="WA==", key_id="a1")
        self.m1.deleted = "everyone"
        self.m1.save()
        rows = self.ca.get(V + "/circle/%d/messages" % self.ab.id).json()
        rows = rows.get("results", rows)
        self.assertFalse(any("copy" in x for x in rows))

    def test_resend_ask_flow(self):
        r = self.ca.post(V + "/circle/%d/e2/resend" % self.ab.id,
                         {"message_ids": [self.m2.id, self.m1.id, 999999]},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["queued"])
        req = E2ResendRequest.objects.get(requester=self.a, target=self.b)
        self.assertEqual(sorted(req.message_ids),
                         sorted([self.m1.id, self.m2.id]))  # 999999 dropped
        self.assertEqual(req.key_id, "a1")
        self.assertTrue(r.json()["notified"])
        # a second ask within a minute merges and does not re-notify
        r = self.ca.post(V + "/circle/%d/e2/resend" % self.ab.id,
                         {"message_ids": [self.m1.id]}, format="json")
        self.assertFalse(r.json()["notified"])
        self.assertEqual(E2ResendRequest.objects.count(), 1)
        j = self.cb.get(V + "/circle/e2/resend").json()["results"]
        self.assertEqual(sorted(j[0]["message_ids"]),
                         sorted([self.m1.id, self.m2.id]))
        # B serves -> done -> A's request fulfilled
        self.cb.post(V + "/circle/%d/e2/copies" % self.ba.id,
                     {"for_key_id": "a1", "done": True,
                      "copies": [self._copy(self.m1.id)]}, format="json")
        req.refresh_from_db()
        self.assertIsNotNone(req.fulfilled_at)

    def test_resend_ask_other_chat_ids_ignored(self):
        ea, ae = pair(self.e, self.a)
        other = CircleMessage.objects.create(
            member=ea, sender=self.e, recipient_ids=[ea.id],
            ciphertext="WA==", nonce="WA==")
        r = self.ca.post(V + "/circle/%d/e2/resend" % self.ab.id,
                         {"message_ids": [other.id]}, format="json")
        self.assertFalse(r.json()["queued"])
        self.assertFalse(E2ResendRequest.objects.exists())
