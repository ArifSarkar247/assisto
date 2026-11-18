"""circle-chat (18 Nov, board row 2): real bugs found while proving My Circle
chat end to end.

1. A 20 MB video download cut by the network started again from byte 0:
   the signed blob download now honours `Range: bytes=N-` (206 +
   Content-Range), 416 for a wrong range, the whole file for no/odd ranges.
2. A group message sealed with a STALE roster (offline queue, failed roster
   refresh) kept a copy for a member who had been REMOVED. Membership rows
   are reused on re-add, so that copy opened for them later. The server now
   drops copies / recipient ids that are not active members, before the
   first copy is lifted to the top level; an edit only re-seals to members
   who got the original and are still in the group.

Run: manage.py test core.tests_circle_chat --settings=assisto_backend.settings_test
"""
import base64

from core.models import CircleGroup, CircleGroupMember, CircleMessage
from core.tests_md1_media import CIPHER, V, _Base, cl, mk
from core.views_md1_media import parse_range


class RangeParseTests(_Base):
    def test_parse(self):
        self.assertIsNone(parse_range("", 100))
        self.assertIsNone(parse_range("items=0-5", 100))
        self.assertIsNone(parse_range("bytes=0-5,10-20", 100))   # multi: whole
        self.assertEqual(parse_range("bytes=10-", 100), (10, 99))
        self.assertEqual(parse_range("bytes=10-19", 100), (10, 19))
        self.assertEqual(parse_range("bytes=90-500", 100), (90, 99))
        self.assertEqual(parse_range("bytes=-10", 100), (90, 99))
        self.assertEqual(parse_range("bytes=100-", 100), "bad")
        self.assertEqual(parse_range("bytes=20-10", 100), "bad")
        self.assertIsNone(parse_range("bytes=x-", 100))


class ResumableDownloadTests(_Base):
    def _url(self):
        ref = self.upload()
        self.send_media(ref)
        r = self.cb.get("%s/circle/media/blobs/%s/url" % (V, ref))
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["url"]

    def test_resume_from_the_cut(self):
        url = self._url()
        cut = 300 * 1024
        full = cl().get(url)
        self.assertEqual(full.status_code, 200)
        self.assertEqual(full["Accept-Ranges"], "bytes")
        r = cl().get(url, HTTP_RANGE="bytes=%d-" % cut)
        self.assertEqual(r.status_code, 206)
        self.assertEqual(r["Content-Range"],
                         "bytes %d-%d/%d" % (cut, len(CIPHER) - 1, len(CIPHER)))
        self.assertEqual(int(r["Content-Length"]), len(CIPHER) - cut)
        body = b"".join(r.streaming_content)
        self.assertEqual(CIPHER[:cut] + body, CIPHER)
        self.assertIn("no-store", r["Cache-Control"])

    def test_bad_range_is_416_never_a_wrong_file(self):
        url = self._url()
        r = cl().get(url, HTTP_RANGE="bytes=%d-" % len(CIPHER))
        self.assertEqual(r.status_code, 416)
        self.assertEqual(r["Content-Range"], "bytes */%d" % len(CIPHER))

    def test_range_still_needs_the_signature(self):
        url = self._url()
        base = url.split("?")[0]
        self.assertEqual(cl().get(base, HTTP_RANGE="bytes=10-").status_code, 404)


class StaleRosterTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        self.gma = CircleGroupMember.objects.create(group=self.g, member=self.a,
                                                    role="admin")
        self.gmb = CircleGroupMember.objects.create(group=self.g, member=self.b)
        self.gmc = CircleGroupMember.objects.create(group=self.g, member=self.c)

    def p(self, tail):
        return "%s/circle/groups/%d/%s" % (V, self.g.id, tail)

    def send(self, cmid, ids, client=None):
        pr = {str(i): {"ciphertext": base64.b64encode(b"ct-%d" % i).decode(),
                       "nonce": "Tg=="} for i in ids}
        return (client or self.ca).post(self.p("messages"), {
            "recipient_ids": list(ids), "per_recipient": pr,
            "client_msg_id": cmid}, format="json")

    def remove_c(self):
        r = self.ca.post(self.p("members/%d/remove" % self.gmc.id))
        self.assertIn(r.status_code, (200, 204), r.content)
        self.gmc.refresh_from_db()
        self.assertNotEqual(self.gmc.status, "active")

    def test_removed_member_copy_is_dropped(self):
        self.remove_c()
        # A's phone still had C in its cached roster
        r = self.send("s1", [self.gmb.id, self.gmc.id])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json().get("dropped_recipients"), 1)
        x = CircleMessage.objects.get(pk=r.json()["id"])
        self.assertEqual(set(x.per_recipient), {str(self.gmb.id)})
        self.assertEqual([str(i) for i in x.recipient_ids], [str(self.gmb.id)])
        # the lifted top-level copy is B's, never C's
        self.assertEqual(x.ciphertext, x.per_recipient[str(self.gmb.id)]["ciphertext"])
        # C cannot read the group at all while removed
        self.assertEqual(self.cc.get(self.p("messages")).status_code, 404)

    def test_stale_copy_is_gone_even_after_readd(self):
        self.remove_c()
        mid = self.send("s2", [self.gmb.id, self.gmc.id]).json()["id"]
        # C is added back: the SAME membership row is reused
        CircleGroupMember.objects.filter(pk=self.gmc.id).update(status="active")
        rows = {m["id"]: m for m in self.cc.get(self.p("messages")).json()["results"]}
        self.assertNotIn(str(self.gmc.id), rows[mid]["per_recipient"] or {})

    def test_only_removed_recipients_is_409(self):
        self.remove_c()
        r = self.send("s3", [self.gmc.id])
        self.assertEqual(r.status_code, 409, r.content)
        self.assertEqual(r.json()["reason"], "members_changed")
        self.assertFalse(CircleMessage.objects.filter(client_msg_id="s3").exists())

    def test_normal_send_untouched(self):
        r = self.send("s4", [self.gmb.id, self.gmc.id])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertNotIn("dropped_recipients", r.json())
        x = CircleMessage.objects.get(pk=r.json()["id"])
        self.assertEqual(set(x.per_recipient), {str(self.gmb.id), str(self.gmc.id)})

    def test_edit_never_reaches_a_removed_or_newer_member(self):
        mid = self.send("s5", [self.gmb.id, self.gmc.id]).json()["id"]
        self.remove_c()
        d = CircleGroupMember.objects.create(
            group=self.g, member=mk("01710000009", "Dina"))
        new = {str(i): {"ciphertext": "TkVX", "nonce": "Tg=="}
               for i in (self.gmb.id, self.gmc.id, d.id)}
        r = self.ca.post(self.p("messages/%d/edit" % mid),
                         {"per_recipient": new}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual(set(x.per_recipient), {str(self.gmb.id)})
        # nobody left who got the original -> 409, message untouched
        self.ca.post(self.p("members/%d/remove" % self.gmb.id))
        r = self.ca.post(self.p("messages/%d/edit" % mid),
                         {"per_recipient": new}, format="json")
        self.assertEqual(r.status_code, 409, r.content)
