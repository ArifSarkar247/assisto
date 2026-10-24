"""mc-media2 — location / live location / contact card / video, PROVEN on the
real endpoints (server holds ciphertext only).

Run: manage.py test core.tests_mc_media2 --settings=assisto_backend.settings_test
"""
import hashlib
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import circle_blobs as CB
from core.logic import circle as C
from core.logic import circle_groups as G
from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, User)
from core import views_mc_media2 as MC2

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


class _Base(TestCase):
    def setUp(self):
        cache.clear()
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

    def send(self, ct="location", client=None, edge=None, cipher="Q1RYVA==",
             cmid="s1", **extra):
        body = {"content_type": ct, "ciphertext": cipher, "nonce": "Tg==",
                "sender_key_id": "kA", "client_msg_id": cmid}
        body.update(extra)
        return (client or self.ca).post(
            "%s/circle/%d/messages" % (V, (edge or self.ab).id), body,
            format="json")

    def live(self, mid, body, client=None):
        cache.clear()   # the soft per-message gap is tested on its own
        return (client or self.ca).post("%s/circle/live/%d" % (V, mid), body,
                                        format="json")


class ContentTypeTests(_Base):
    def test_validator_knows_share_types(self):
        self.assertIn("contact", C.CONTENT_TYPES)
        self.assertIn("location", C.CONTENT_TYPES)
        ok, _ = C.validate_envelope({"content_type": "contact",
                                     "ciphertext": "QQ==", "nonce": "Tg==",
                                     "recipient_ids": [1]})
        self.assertTrue(ok)
        # inline only: no blob, ciphertext required, small
        ok, why = C.validate_envelope({"content_type": "location",
                                       "ciphertext": "QQ==", "nonce": "Tg==",
                                       "blob_ref": "a" * 32, "recipient_ids": [1]})
        self.assertFalse(ok)
        ok, why = C.validate_envelope({"content_type": "contact",
                                       "recipient_ids": [1]})
        self.assertEqual((ok, why), (False, "missing ciphertext"))
        ok, why = C.validate_envelope({
            "content_type": "location", "ciphertext": "Q" * (C.SHARE_CT_MAX + 1),
            "nonce": "Tg==", "recipient_ids": [1]})
        self.assertEqual((ok, why), (False, "ciphertext too large"))
        ok, why = C.validate_envelope({"content_type": "gif",
                                       "ciphertext": "QQ==", "nonce": "Tg==",
                                       "recipient_ids": [1]})
        self.assertEqual((ok, why), (False, "unknown content_type"))

    def test_send_location_and_contact_1to1(self):
        for ct in ("location", "contact"):
            r = self.send(ct, cmid="c-" + ct)
            self.assertEqual(r.status_code, 201, r.content)
            x = CircleMessage.objects.get(pk=r.json()["id"])
            self.assertEqual((x.content_type, x.ciphertext, x.blob_ref),
                             (ct, "Q1RYVA==", ""))
        rows = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id)).json()
        kinds = [m["content_type"] for m in rows["results"]]
        self.assertEqual(kinds, ["location", "contact"])

    def test_plaintext_fields_refused(self):
        r = self.send("location", text="23.81,90.41")
        self.assertEqual(r.status_code, 400)
        r = self.send("contact", body="Rahim 01711")
        self.assertEqual(r.status_code, 400)

    def test_size_cap_on_send(self):
        r = self.send("contact", cipher="Q" * (C.SHARE_CT_MAX + 1))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(CircleMessage.objects.count(), 0)

    def test_group_share_size_cap(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        gmb = CircleGroupMember.objects.create(group=g, member=self.b)
        base = {"content_type": "location", "recipient_ids": [gmb.id],
                "client_msg_id": "g1"}
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), dict(
            base, per_recipient={str(gmb.id): {"ciphertext": "Q" * 9000,
                                               "nonce": "Tg=="}}),
            format="json")
        self.assertEqual(r.status_code, 400)
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), dict(
            base, per_recipient={str(gmb.id): {"ciphertext": "QQ==",
                                               "nonce": "Tg=="}}),
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(G.validate_group_envelope({
            "content_type": "contact", "group_id": g.id, "recipient_ids": [1],
            "ciphertext": "QQ==", "nonce": "Tg==",
            "per_recipient": {"1": {"ciphertext": "QQ==", "nonce": "Tg=="}}})[0],
            True)

    def test_share_needs_accepted_chat(self):
        # a message REQUEST (pending edge) carries text only
        d = mk("01710000004", "Dina")
        pend = CircleMember.objects.create(user=self.a, peer_user=d, name="Dina",
                                           state="pending", phone=d.phone)
        r = self.send("location", edge=pend, cmid="p1")
        self.assertIn(r.status_code, (400, 403))
        self.assertFalse(CircleMessage.objects.filter(
            content_type="location", member=pend).exists())


class LiveLocationTests(_Base):
    def test_sender_updates_in_place(self):
        mid = self.send().json()["id"]
        r = self.live(mid, {"ciphertext": "TkVXMQ==", "nonce": "Tjk="})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertGreater(r.json()["max_left_s"], 8 * 3600)
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual((x.ciphertext, x.nonce), ("TkVXMQ==", "Tjk="))
        self.assertIsNone(x.edited_at)          # no "edited" label
        self.assertEqual(CircleMessage.objects.count(), 1)   # no new rows
        # the receiver reads the newest ciphertext on the next poll
        rows = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id)).json()
        self.assertEqual(rows["results"][0]["ciphertext"], "TkVXMQ==")

    def test_only_sender_only_location(self):
        mid = self.send().json()["id"]
        r = self.live(mid, {"ciphertext": "QQ==", "nonce": "Tg=="}, client=self.cb)
        self.assertEqual(r.status_code, 404)
        r = self.live(mid, {"ciphertext": "QQ==", "nonce": "Tg=="}, client=self.cc)
        self.assertEqual(r.status_code, 404)
        tid = self.send("contact", cmid="t1").json()["id"]
        r = self.live(tid, {"ciphertext": "QQ==", "nonce": "Tg=="})
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "not_live"))
        self.assertEqual(self.live(999999, {"ciphertext": "QQ==", "nonce": "Tg=="})
                         .status_code, 404)

    def test_expiry_deleted_and_blocked(self):
        mid = self.send().json()["id"]
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(seconds=MC2.LIVE_MAX_S + 5))
        r = self.live(mid, {"ciphertext": "QQ==", "nonce": "Tg=="})
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "expired"))
        mid2 = self.send(cmid="s2").json()["id"]
        CircleMessage.objects.filter(pk=mid2).update(deleted="everyone")
        r = self.live(mid2, {"ciphertext": "QQ==", "nonce": "Tg=="})
        self.assertEqual(r.status_code, 403)
        mid3 = self.send(cmid="s3").json()["id"]
        CircleMember.objects.filter(pk=self.ab.pk).update(state="declined")
        r = self.live(mid3, {"ciphertext": "QQ==", "nonce": "Tg=="})
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "not_allowed"))

    def test_ciphertext_only_and_size(self):
        mid = self.send().json()["id"]
        r = self.live(mid, {"ciphertext": "QQ==", "nonce": "Tg==",
                            "plaintext": "23.8,90.4"})
        self.assertEqual(r.status_code, 400)
        r = self.live(mid, {"ciphertext": "Q" * (C.SHARE_CT_MAX + 1),
                            "nonce": "Tg=="})
        self.assertEqual(r.status_code, 400)
        r = self.live(mid, {"nonce": "Tg=="})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(CircleMessage.objects.get(pk=mid).ciphertext, "Q1RYVA==")

    def test_too_fast(self):
        mid = self.send().json()["id"]
        cache.clear()
        u = "%s/circle/live/%d" % (V, mid)
        body = {"ciphertext": "QQ==", "nonce": "Tg=="}
        self.assertEqual(self.ca.post(u, body, format="json").status_code, 200)
        self.assertEqual(self.ca.post(u, body, format="json").status_code, 429)

    def test_group_live(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        me = CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        gmb = CircleGroupMember.objects.create(group=g, member=self.b)
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, g.id), {
            "content_type": "location", "recipient_ids": [gmb.id],
            "per_recipient": {str(gmb.id): {"ciphertext": "QQ==", "nonce": "Tg=="}},
            "client_msg_id": "g1"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        mid = r.json()["id"]
        r = self.live(mid, {"per_recipient": {
            str(gmb.id): {"ciphertext": "TkVX", "nonce": "Tjk="}},
            "recipient_ids": [gmb.id]})
        self.assertEqual(r.status_code, 200, r.content)
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual(x.per_recipient[str(gmb.id)]["ciphertext"], "TkVX")
        self.assertEqual(x.ciphertext, "TkVX")
        # a 1:1-shaped body is refused for a group message
        r = self.live(mid, {"ciphertext": "QQ==", "nonce": "Tg=="})
        self.assertEqual(r.status_code, 400)
        r = self.live(mid, {"per_recipient": {
            "abc": {"ciphertext": "QQ==", "nonce": "Tg=="}}})
        self.assertEqual(r.status_code, 400)
        # a sender who left the group can no longer update
        me.status = "left"
        me.save(update_fields=["status"])
        r = self.live(mid, {"per_recipient": {
            str(gmb.id): {"ciphertext": "QQ==", "nonce": "Tg=="}}})
        self.assertEqual(r.status_code, 404)


class VideoTests(_Base):
    def test_video_is_a_chat_kind_with_own_cap(self):
        self.assertIn("video", CB.CHAT_MEDIA_KINDS)
        self.assertEqual(CB.max_bytes("video"), 32 * MB + 64 * 1024)
        lim = self.ca.get(V + "/circle/media/limits").json()
        self.assertEqual(lim["video_max_bytes"], 32 * MB)
        self.assertIn("video", lim["kinds"])
        r = self.ca.post(V + "/circle/media/blobs", {
            "kind": "video", "size": 33 * MB, "sha256": "0" * 64},
            format="json")
        self.assertEqual(r.json()["reason"], "too_big")

    def test_owner_editable_video_cap(self):
        from core.logic import pricing as P
        cfg = P.normalize({"limits": {"circle_media_video_max_mb": 500}})
        self.assertEqual(cfg["limits"]["circle_media_video_max_mb"], 100)

    def test_video_message_end_to_end(self):
        data = bytes((i * 31 + 3) % 256 for i in range(600 * 1024))
        r = self.ca.post(V + "/circle/media/blobs", {
            "kind": "video", "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        ref = r.json()["ref"]
        for off in range(0, len(data), 512 * 1024):
            self.ca.put("%s/circle/media/blobs/%s?offset=%d" % (V, ref, off),
                        data[off:off + 512 * 1024],
                        content_type="application/octet-stream")
        self.assertTrue(self.ca.post("%s/circle/media/blobs/%s/finish" % (V, ref))
                        .json()["complete"])
        r = self.send("video", blob_ref=ref, cmid="v1")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.cb.get("%s/circle/media/blobs/%s/url" % (V, ref))
                         .status_code, 200)
