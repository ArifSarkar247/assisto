"""md1 — My Circle E2E media blobs, PROVEN on the real endpoints.

Upload (auth, resumable chunks, size cap, daily quota, rate limit, sha256
check) -> media message (blob must be complete + the sender's) -> only chat
participants get a 10-minute signed link -> download marks the recipient ->
retention purge (downloaded+keep days, max age, unfinished, unsent, deleted
for everyone) -> delete-for-everyone removes the blob -> the server never
holds plaintext (the stored file is exactly the uploaded ciphertext, outside
MEDIA_ROOT).

Run: manage.py test core.tests_md1_media --settings=assisto_backend.settings_test
"""
import hashlib
import io
import os
import time
from datetime import timedelta
from unittest import mock
from urllib.parse import parse_qs, urlparse

from django.conf import settings
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import circle_blobs as CB
from core.logic import circle as C
from core.models import (CircleGroup, CircleGroupMember, CircleMediaBlob,
                         CircleMember, CircleMessage, User)

V = "/api/v1"
MB = 1024 * 1024


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u=None):
    c = APIClient()
    if u is not None:
        c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


# "ciphertext" the phone would upload (random-looking, never a plaintext)
CIPHER = bytes((i * 131 + 7) % 256 for i in range(700 * 1024))


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01710000001", "Amina")
        self.b = mk("01710000002", "Bilal")
        self.c = mk("01710000003", "Chaya")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone)
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming")
        self.ca, self.cb, self.cc = cl(self.a), cl(self.b), cl(self.c)
        p = mock.patch("core.push.safe_push", return_value=1)
        p.start()
        self.addCleanup(p.stop)

    # ---- helpers -----------------------------------------------------------
    def create(self, client=None, data=CIPHER, kind="photo", size=None):
        return (client or self.ca).post(V + "/circle/media/blobs", {
            "kind": kind, "size": len(data) if size is None else size,
            "sha256": hashlib.sha256(data).hexdigest()}, format="json")

    def put(self, ref, offset, chunk, client=None):
        return (client or self.ca).put(
            "%s/circle/media/blobs/%s?offset=%d" % (V, ref, offset), chunk,
            content_type="application/octet-stream")

    def upload(self, data=CIPHER, kind="photo", client=None):
        r = self.create(client, data, kind)
        self.assertEqual(r.status_code, 201, r.content)
        ref = r.json()["ref"]
        step = 512 * 1024
        for off in range(0, len(data), step):
            r = self.put(ref, off, data[off:off + step], client)
            self.assertEqual(r.status_code, 200, r.content)
        r = (client or self.ca).post("%s/circle/media/blobs/%s/finish" % (V, ref))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["complete"])
        return ref

    def send_media(self, ref, kind="photo", client=None, edge=None, cmid="m1"):
        return (client or self.ca).post(
            "%s/circle/%d/messages" % (V, (edge or self.ab).id), {
                "content_type": kind, "blob_ref": ref,
                "ciphertext": "RU5DLURFU0M=", "nonce": "Tg==",
                "sender_key_id": "kA", "client_msg_id": cmid}, format="json")

    def url_for(self, ref, client):
        return client.get("%s/circle/media/blobs/%s/url" % (V, ref))


class UploadTests(_Base):
    def test_auth_required(self):
        r = cl().post(V + "/circle/media/blobs", {"kind": "photo", "size": 10,
                                                  "sha256": "0" * 64},
                      format="json")
        self.assertIn(r.status_code, (401, 403))
        ref = self.upload()
        self.assertIn(cl().get("%s/circle/media/blobs/%s/url" % (V, ref))
                      .status_code, (401, 403))

    def test_resumable_chunks_and_sha(self):
        r = self.create()
        ref = r.json()["ref"]
        self.assertTrue(CB.valid_ref(ref))
        self.assertEqual(self.put(ref, 0, CIPHER[:1000]).status_code, 200)
        # a retried / out-of-order chunk -> 409 with the stored offset
        r = self.put(ref, 5000, CIPHER[5000:6000])
        self.assertEqual((r.status_code, r.json()["received"]), (409, 1000))
        st = self.ca.get("%s/circle/media/blobs/%s" % (V, ref)).json()
        self.assertEqual(st["received"], 1000)
        # finish before all bytes -> refused
        r = self.ca.post("%s/circle/media/blobs/%s/finish" % (V, ref))
        self.assertEqual(r.status_code, 409)
        # resume from the server offset
        self.assertEqual(self.put(ref, 1000, CIPHER[1000:]).status_code, 200)
        r = self.ca.post("%s/circle/media/blobs/%s/finish" % (V, ref))
        self.assertTrue(r.json()["complete"])

    def test_sha_mismatch_restarts(self):
        r = self.create(data=CIPHER[:2000])
        ref = r.json()["ref"]
        bad = bytes(2000)
        self.put(ref, 0, bad)
        r = self.ca.post("%s/circle/media/blobs/%s/finish" % (V, ref))
        self.assertEqual((r.status_code, r.json()["detail"]), (409, "sha256"))
        self.assertEqual(CircleMediaBlob.objects.get(ref=ref).received, 0)

    def test_only_owner_uploads(self):
        ref = self.create().json()["ref"]
        self.assertEqual(self.put(ref, 0, b"x" * 10, client=self.cb).status_code, 404)
        self.assertEqual(self.cb.get("%s/circle/media/blobs/%s" % (V, ref))
                         .status_code, 404)

    def test_size_caps(self):
        r = self.create(size=CB.max_bytes("photo") + 1)
        self.assertEqual((r.status_code, r.json()["reason"]), (413, "too_big"))
        r = self.create(kind="video")
        self.assertEqual(r.json()["reason"], "bad_kind")
        # documents default to 25 MB
        self.assertEqual(CB.max_bytes("document"), 25 * MB + 64 * 1024)
        ref = self.create(data=CIPHER[:100]).json()["ref"]
        r = self.put(ref, 0, b"y" * (CB.CHUNK_MAX + 1))
        self.assertEqual(r.status_code, 413)
        r = self.put(ref, 0, b"y" * 200)   # over the declared size
        self.assertEqual(r.status_code, 413)

    def test_owner_editable_limits(self):
        from core.logic import pricing as P
        cfg = P.normalize({"limits": {"circle_media_doc_max_mb": 40,
                                      "circle_media_daily_mb": 999999}})
        self.assertEqual(cfg["limits"]["circle_media_doc_max_mb"], 40)
        self.assertEqual(cfg["limits"]["circle_media_daily_mb"], 5000)  # clamp
        with mock.patch("core.billing.cfg", return_value=cfg):
            self.assertEqual(CB.max_bytes("document"), 40 * MB + 64 * 1024)
            lim = self.ca.get(V + "/circle/media/limits").json()
        self.assertEqual(lim["doc_max_bytes"], 40 * MB)
        self.assertEqual(lim["kinds"], ["photo", "voice", "document"])

    def test_daily_quota_and_rate_limit(self):
        lim = dict(CB.limits(), circle_media_daily_mb=1)
        with mock.patch.object(CB, "limits", return_value=lim):
            self.assertEqual(self.create().status_code, 201)   # 700 KB
            r = self.create()
            self.assertEqual((r.status_code, r.json()["reason"]),
                             (429, "daily_quota"))
            self.assertIn("1 MB", r.json()["detail"])
        lim = dict(CB.limits(), circle_media_uploads_per_hour=5)
        with mock.patch.object(CB, "limits", return_value=lim):
            for _ in range(4):
                self.create(data=b"z" * 10)
            r = self.create(data=b"z" * 10)
            self.assertEqual((r.status_code, r.json()["reason"]),
                             (429, "rate_limit"))

    def test_no_plaintext_stored_outside_media_root(self):
        ref = self.upload()
        p = CB.path_for(ref)
        with open(p, "rb") as f:
            self.assertEqual(f.read(), CIPHER)   # exactly the ciphertext
        root = os.path.realpath(str(settings.MEDIA_ROOT))
        self.assertFalse(p.startswith(root + os.sep))
        row = CircleMediaBlob.objects.get(ref=ref)
        field_names = {f.name for f in CircleMediaBlob._meta.get_fields()}
        for forbidden in ("key", "nonce", "name", "mime", "caption",
                          "plaintext", "thumb"):
            self.assertNotIn(forbidden, field_names)
        self.assertEqual(row.sha256, hashlib.sha256(CIPHER).hexdigest())

    def test_cancel_unsent(self):
        ref = self.upload()
        r = self.ca.delete("%s/circle/media/blobs/%s" % (V, ref))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(os.path.exists(CB.path_for(ref)))


class MessageAndDownloadTests(_Base):
    def test_send_requires_complete_own_blob(self):
        r = self.send_media("f" * 32)
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "blob_missing"))
        ref = self.create().json()["ref"]   # not finished
        self.assertEqual(self.send_media(ref).json()["reason"], "blob_missing")
        # someone else's blob cannot be attached
        other = self.upload(client=self.cc)
        self.assertEqual(self.send_media(other).json()["reason"], "blob_missing")
        # the descriptor (encrypted key) is required
        ref = self.upload()
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "photo", "blob_ref": ref}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.send_media(ref)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(CircleMediaBlob.objects.get(ref=ref).recipients, [self.b.id])
        # the recipient sees blob_ref + the opaque descriptor
        rows = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id)).json()["results"]
        self.assertEqual((rows[0]["content_type"], rows[0]["blob_ref"]), ("photo", ref))

    def test_no_media_in_message_request(self):
        self.ab.state = "pending"
        self.ab.save(update_fields=["state"])
        ref = self.upload()
        r = self.send_media(ref)
        self.assertEqual((r.status_code, r.json()["reason"]),
                         (403, "media_after_accept"))

    def test_participant_only_signed_download(self):
        ref = self.upload()
        self.send_media(ref)
        # outsider: 404 (never reveals the blob exists)
        self.assertEqual(self.url_for(ref, self.cc).status_code, 404)
        r = self.url_for(ref, self.cb)
        self.assertEqual(r.status_code, 200)
        url = r.json()["url"]
        self.assertTrue(url.startswith("/api/v1/circle/media/dl/"))
        self.assertNotIn("/media/", url.replace("/circle/media/", "/"))
        dl = cl().get(url)   # signed link, no auth header
        self.assertEqual(dl.status_code, 200)
        self.assertEqual(b"".join(dl.streaming_content), CIPHER)
        self.assertIn("no-store", dl["Cache-Control"])
        b = CircleMediaBlob.objects.get(ref=ref)
        self.assertEqual(b.downloaded_by, [self.b.id])
        self.assertIsNotNone(b.all_downloaded_at)
        # tampered signature / other ref / other user -> 404
        q = parse_qs(urlparse(url).query)
        base = urlparse(url).path
        self.assertEqual(cl().get(base).status_code, 404)
        self.assertEqual(cl().get("%s?u=%s&e=%s&s=%s" % (
            base, q["u"][0], q["e"][0], "0" * 40)).status_code, 404)
        self.assertEqual(cl().get("%s?u=%d&e=%s&s=%s" % (
            base, self.c.id, q["e"][0], q["s"][0])).status_code, 404)

    def test_signed_url_expires(self):
        ref = self.upload()
        self.send_media(ref)
        past = int(time.time()) - CB.URL_TTL_S - 5
        url = CB.signed_url(ref, self.b.id, now=past)
        self.assertEqual(cl().get(url).status_code, 404)
        q = parse_qs(urlparse(url).query)
        self.assertFalse(CB.verify(ref, q["u"][0], q["e"][0], q["s"][0]))
        # a far-future expiry (forged TTL) is refused too
        far = int(time.time()) + 10 * 24 * 3600
        self.assertFalse(CB.verify(ref, self.b.id, far, CB._sig(ref, self.b.id, far)))

    def test_x_accel_in_production(self):
        ref = self.upload()
        self.send_media(ref)
        url = self.url_for(ref, self.cb).json()["url"]
        with self.settings(CIRCLE_BLOB_X_ACCEL=True):
            r = cl().get(url)
        self.assertEqual(r["X-Accel-Redirect"],
                         "/protected-circle-blobs/%s/%s.bin" % (ref[:2], ref))

    def test_group_members_only(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        gmb = CircleGroupMember.objects.create(group=g, member=self.b)
        ref = self.upload()
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), {
            "content_type": "voice", "blob_ref": ref,
            "recipient_ids": [gmb.id],
            "per_recipient": {str(gmb.id): {"ciphertext": "RA==", "nonce": "Tg=="}},
            "client_msg_id": "g1"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(CircleMediaBlob.objects.get(ref=ref).recipients, [self.b.id])
        self.assertEqual(self.url_for(ref, self.cb).status_code, 200)
        self.assertEqual(self.url_for(ref, self.cc).status_code, 404)
        gmb.status = "left"
        gmb.save(update_fields=["status"])
        self.assertEqual(self.url_for(ref, self.cb).status_code, 404)
        # a missing blob is refused in groups too
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), {
            "content_type": "photo", "blob_ref": "a" * 32,
            "recipient_ids": [gmb.id],
            "per_recipient": {str(gmb.id): {"ciphertext": "RA==", "nonce": "Tg=="}},
            "client_msg_id": "g2"}, format="json")
        self.assertEqual(r.json()["reason"], "blob_missing")

    def test_forward_reuses_blob(self):
        ref = self.upload()
        self.send_media(ref)
        # B forwards A's photo back (same blob_ref + key, no re-upload)
        r = self.send_media(ref, client=self.cb, edge=self.ba, cmid="f1")
        self.assertEqual(r.status_code, 201, r.content)
        # md2: the uploader never downloads their own file, so a forward back
        # to them does not count them (else "all downloaded" never happens).
        self.assertEqual(CircleMediaBlob.objects.get(ref=ref).recipients,
                         [self.b.id])

    def test_delete_for_everyone_removes_blob(self):
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        p = CB.path_for(ref)
        self.assertTrue(os.path.exists(p))
        r = self.ca.post("%s/circle/messages/%d/delete" % (V, mid),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertFalse(os.path.exists(p))
        self.assertEqual(self.url_for(ref, self.cb).status_code, 404)

    def test_group_delete_for_everyone_removes_blob(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        gmb = CircleGroupMember.objects.create(group=g, member=self.b)
        ref = self.upload()
        mid = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), {
            "content_type": "document", "blob_ref": ref,
            "recipient_ids": [gmb.id],
            "per_recipient": {str(gmb.id): {"ciphertext": "RA==", "nonce": "Tg=="}},
            "client_msg_id": "g1"}, format="json").json()["id"]
        r = self.ca.post("%s/circle/groups/%d/messages/%d/delete" % (V, g.id, mid),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_envelope_contract(self):
        ok, _ = C.validate_envelope({"content_type": "document", "blob_ref": "x",
                                     "recipient_ids": [1]})
        self.assertTrue(ok)
        ok, why = C.validate_envelope({"content_type": "document",
                                       "recipient_ids": [1]})
        self.assertFalse(ok)
        ok, why = C.validate_envelope({"content_type": "photo", "blob_ref": "x",
                                       "key": "SECRET", "recipient_ids": [1]})
        self.assertFalse(ok)
        ok, _ = C.validate_envelope({"content_type": "location",
                                     "ciphertext": "x", "nonce": "y",
                                     "recipient_ids": [1]})
        self.assertTrue(ok)
        # status media stays gated (chat media is a separate switch)
        self.assertFalse(C.media_available("photo"))


class RetentionTests(_Base):
    def _age(self, ref, **kw):
        CircleMediaBlob.objects.filter(ref=ref).update(**kw)

    def test_purge_rules(self):
        now = timezone.now()
        downloaded = self.upload()
        self.send_media(downloaded, cmid="d")
        self.cb.get(self.url_for(downloaded, self.cb).json()["url"])
        fresh = self.upload(data=CIPHER[:5000])
        self.send_media(fresh, cmid="f")
        old = self.upload(data=CIPHER[:6000])
        self.send_media(old, cmid="o")
        unfinished = self.create(data=CIPHER[:100]).json()["ref"]
        unsent = self.upload(data=CIPHER[:7000])
        self._age(downloaded, all_downloaded_at=now - timedelta(days=31))
        self._age(old, created_at=now - timedelta(days=91))
        self._age(unfinished, created_at=now - timedelta(hours=25))
        self._age(unsent, created_at=now - timedelta(hours=25))
        out = CB.purge(dry=True)
        self.assertEqual(CircleMediaBlob.objects.count(), 5)
        call_command("purge_l1_retention", stdout=io.StringIO())
        left = set(CircleMediaBlob.objects.values_list("ref", flat=True))
        self.assertEqual(left, {fresh})
        self.assertEqual((out["downloaded"], out["max_age"], out["unfinished"],
                          out["unsent"]), (1, 1, 1, 1))
        for ref in (downloaded, old, unfinished, unsent):
            self.assertFalse(os.path.exists(CB.path_for(ref)))
        self.assertTrue(os.path.exists(CB.path_for(fresh)))

    def test_not_all_downloaded_is_kept(self):
        ref = self.upload()
        self.send_media(ref)
        self._age(ref, created_at=timezone.now() - timedelta(days=40))
        CB.purge()
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_owner_editable_retention(self):
        ref = self.upload()
        self.send_media(ref)
        self._age(ref, created_at=timezone.now() - timedelta(days=10))
        with mock.patch.object(CB, "limits",
                               return_value=dict(CB.limits(), circle_media_max_days=7)):
            CB.purge()
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_account_deletion_removes_files(self):
        ref = self.upload()
        p = CB.path_for(ref)
        self.a.delete()
        self.assertFalse(os.path.exists(p))
