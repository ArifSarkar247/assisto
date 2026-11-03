"""p3docs — Documents vault end-to-end layer: the server stores ONLY
ciphertext. Sealed uploads, key wraps (recovery code / trusted person),
trusted-person recovery with the 24-hour wait, time-limited encrypted share
links (/d/<token>), and famcare refusing sealed documents.
"""
import base64
import json
import os
import shutil
import tempfile
from datetime import timedelta

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import e2_keys, feature_flags as FF, vault_e2e as VE
from core.models import (AuditLog, CircleMember, Document, FeatureFlag,
                         User, VaultHelpRequest, VaultKeyWrap, VaultShareLink)

_MEDIA = tempfile.mkdtemp(prefix="p3docs-")
V = "/api/v1"
SECRET_TITLE = "PASSPORT A01234567 RAHIM"   # lives only inside the sealed box
PIN = "482173"
CODE = "ABCD-EFGH-JKMN-PQRS"


def b64(b):
    return base64.b64encode(b).decode()


def wrap(alg="pbkdf2-c20p", ct_len=48, iters=200000, **extra):
    j = {"v": 1, "alg": alg, "nonce": b64(os.urandom(12)), "ct": b64(os.urandom(ct_len))}
    if alg == "pbkdf2-c20p":
        j.update(salt=b64(os.urandom(16)), iters=iters)
    else:
        j.update(epk=b64(os.urandom(32)))
    j.update(extra)
    return b64(json.dumps(j).encode())


def sealed_file(n=300):
    return VE.FILE_MAGIC + os.urandom(n)


def sealed_box():
    return b64(VE.BOX_MAGIC + os.urandom(12 + 80))


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=VE.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


_n = [0]


def mk(name="A"):
    _n[0] += 1
    return User.objects.create_user(name=name, phone="0171%07d" % (5500000 + _n[0]),
                                    password="pw-123456x")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def pair(a, b):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                     phone=b.phone)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                phone=a.phone, direction="incoming")
    return ab


def post_sealed(c, file_bytes=None, **over):
    data = {"e2e": "true", "doc_type": "passport", "title": "",
            "details": json.dumps({"e2e": 1, "box": sealed_box()}),
            "file": SimpleUploadedFile("x.bin", file_bytes if file_bytes is not None
                                       else sealed_file(), "application/octet-stream")}
    data.update(over)
    return c.post(V + "/documents/", data, format="multipart")


@override_settings(MEDIA_ROOT=_MEDIA)
class SealedDocumentTests(TestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_MEDIA, ignore_errors=True)

    def setUp(self):
        flag(True)
        self.u = mk()
        self.c = cl(self.u)

    def test_sealed_upload_stores_exact_ciphertext_and_no_plain_metadata(self):
        blob = sealed_file(1000)
        r = post_sealed(self.c, file_bytes=blob, expiry_date="2027-01-01")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.json()["e2e"])
        d = Document.objects.get(pk=r.json()["id"])
        self.assertTrue(d.e2e)
        self.assertEqual(d.title, "")
        self.assertEqual(d.note, "")
        self.assertEqual(set(d.details), {"e2e", "box"})
        with d.file.open("rb") as fh:
            self.assertEqual(fh.read(), blob)        # byte-for-byte ciphertext
        # nothing the server holds or logs carries the real title / PIN / code
        everything = json.dumps([list(Document.objects.values()),
                                 list(AuditLog.objects.values_list("detail", flat=True))],
                                default=str)
        for secret in (SECRET_TITLE, PIN, CODE):
            self.assertNotIn(secret, everything)
        self.assertEqual(d.public_title, "পাসপোর্ট")  # server text uses the type only

    def test_plain_file_is_refused(self):
        for head in (b"\xff\xd8\xff\xe0JFIF", b"%PDF-1.7", b"\x89PNG\r\n", b"hello"):
            r = post_sealed(self.c, file_bytes=head + os.urandom(64))
            self.assertEqual(r.status_code, 400, head)
        self.assertFalse(Document.objects.exists())

    def test_plain_title_note_or_details_are_refused(self):
        self.assertEqual(post_sealed(self.c, title=SECRET_TITLE).status_code, 400)
        self.assertEqual(post_sealed(self.c, note="number A123").status_code, 400)
        r = post_sealed(self.c, details=json.dumps({"e2e": 1, "box": sealed_box(),
                                                    "number": "A01234567"}))
        self.assertEqual(r.status_code, 400)
        r = post_sealed(self.c, details=json.dumps({"number": "A01234567"}))
        self.assertEqual(r.status_code, 400)
        r = post_sealed(self.c, details=json.dumps(
            {"e2e": 1, "box": b64(json.dumps({"title": SECRET_TITLE}).encode())}))
        self.assertEqual(r.status_code, 400)          # an unsealed "box"
        self.assertFalse(Document.objects.exists())

    def test_switch_off_refuses_new_sealed_documents(self):
        flag(False)
        self.assertEqual(post_sealed(self.c).status_code, 400)

    def test_patch_keeps_it_sealed(self):
        did = post_sealed(self.c).json()["id"]
        r = self.c.patch(V + f"/documents/{did}/", {"title": SECRET_TITLE}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.c.patch(V + f"/documents/{did}/", {"e2e": False, "expiry_date": "2027-02-02",
                                                    "expiry_alerts": False}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        d = Document.objects.get(pk=did)
        self.assertTrue(d.e2e)
        self.assertEqual(str(d.expiry_date), "2027-02-02")
        r = self.c.patch(V + f"/documents/{did}/", {"details": {"number": "x"}}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_normal_documents_unchanged(self):
        r = self.c.post(V + "/documents/", {"title": "Passport", "doc_type": "passport"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        self.assertFalse(r.json()["e2e"])
        r = self.c.post(V + "/documents/", {"doc_type": "passport"}, format="json")
        self.assertEqual(r.status_code, 400)          # title still required
        self.assertIn("title", r.json())

    def test_famcare_refuses_a_sealed_document(self):
        b = mk("B")
        pair(self.u, b)
        did = post_sealed(self.c).json()["id"]
        from core import famcare as FC
        shares, err = FC.share_docs(self.u, did, [1])
        self.assertEqual(err, "e2e_doc")
        self.assertIsNone(shares)


class WrapTests(TestCase):
    def setUp(self):
        flag(True)
        self.u = mk()
        self.c = cl(self.u)

    def test_recovery_wrap_round_trip(self):
        w = wrap()
        r = self.c.put(V + "/vault/e2e/recovery", {"blob": w}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.c.get(V + "/vault/e2e/recovery").json()["blob"], w)
        r = self.c.put(V + "/vault/e2e/recovery", {"blob": wrap()}, format="json")
        self.assertEqual(VaultKeyWrap.objects.filter(user=self.u, kind="recovery").count(), 1)
        j = self.c.get(V + "/vault/e2e/state").json()
        self.assertTrue(j["recovery_wrap"])
        self.assertIs(j["server_can_read_sealed"], False)
        self.assertEqual(self.c.delete(V + "/vault/e2e/recovery").status_code, 200)
        self.assertEqual(self.c.get(V + "/vault/e2e/recovery").status_code, 404)

    def test_bare_key_pin_or_code_is_refused(self):
        bad = [
            wrap(ct_len=32),                          # a raw 32-byte key, no tag
            wrap(iters=1000),                         # weak stretch
            wrap(code=CODE),                          # the code itself inside
            wrap(dmk=b64(os.urandom(32))),
            wrap(alg="none"),
            b64(os.urandom(48)),                      # not a sealed box at all
            "",
        ]
        for b in bad:
            r = self.c.put(V + "/vault/e2e/recovery", {"blob": b}, format="json")
            self.assertEqual(r.status_code, 400, b)
        for field in ("pin", "recovery_code", "key", "dmk", "password"):
            r = self.c.put(V + "/vault/e2e/recovery", {"blob": wrap(), field: "x"}, format="json")
            self.assertEqual(r.status_code, 400, field)
        self.assertFalse(VaultKeyWrap.objects.exists())

    def test_switch_off(self):
        flag(False)
        r = self.c.put(V + "/vault/e2e/recovery", {"blob": wrap()}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_login_required(self):
        self.assertIn(APIClient().get(V + "/vault/e2e/state").status_code, (401, 403))
        self.assertIn(APIClient().get(V + "/vault/e2e/recovery").status_code, (401, 403))


class HelperTests(TestCase):
    def setUp(self):
        flag(True)
        self.a, self.b = mk("Amina"), mk("Bilal")
        self.ca, self.cb = cl(self.a), cl(self.b)
        self.edge = pair(self.a, self.b)
        e2_keys.publish(self.b, b64(os.urandom(32)), "kb", "x25519")

    def _add(self, member_id=None, blob=None):
        return self.ca.post(V + "/vault/e2e/helpers",
                            {"member_id": member_id or self.edge.id,
                             "blob": blob or wrap("x25519-c20p"), "key_id": "kb"},
                            format="json")

    def test_add_helper_needs_circle_and_key_and_sealed_box(self):
        self.assertEqual(self._add(blob=wrap()).status_code, 400)   # wrong alg
        self.assertEqual(self._add(member_id=999999).status_code, 404)
        c = mk("C")
        e = pair(self.a, c)
        self.assertEqual(self._add(member_id=e.id).status_code, 409)  # C has no key
        r = self._add()
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["helper"]["helper_user_id"], self.b.id)
        self.assertEqual(self._add().status_code, 201)               # replaces, no dup
        self.assertEqual(VaultKeyWrap.objects.filter(kind="helper").count(), 1)

    def test_recovery_needs_approval_and_24h_wait(self):
        wid = self._add().json()["helper"]["id"]
        pub = b64(os.urandom(32))
        r = self.ca.post(V + "/vault/e2e/help/request",
                         {"wrap_id": wid, "public_key": pub, "key_id": "new"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        inbox = self.cb.get(V + "/vault/e2e/help/inbox").json()["results"]
        self.assertEqual(len(inbox), 1)
        self.assertEqual(inbox[0]["requester_pub"], pub)
        rid = inbox[0]["id"]
        # a stranger can't see or approve it
        s = cl(mk("S"))
        self.assertEqual(s.get(V + "/vault/e2e/help/inbox").json()["results"], [])
        self.assertEqual(s.post(V + f"/vault/e2e/help/{rid}/approve",
                                {"blob": wrap("x25519-c20p")}, format="json").status_code, 404)
        # the helper must send a sealed box, never the key
        self.assertEqual(self.cb.post(V + f"/vault/e2e/help/{rid}/approve",
                                      {"blob": b64(os.urandom(32))}, format="json").status_code, 400)
        hb = wrap("x25519-c20p")
        r = self.cb.post(V + f"/vault/e2e/help/{rid}/approve", {"blob": hb}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        j = self.ca.get(V + "/vault/e2e/help/request").json()["request"]
        self.assertFalse(j["ready"])
        self.assertNotIn("handback", j)                # not before the 24-hour wait
        VaultHelpRequest.objects.filter(pk=rid).update(
            ready_at=timezone.now() - timedelta(minutes=1))
        j = self.ca.get(V + "/vault/e2e/help/request").json()["request"]
        self.assertTrue(j["ready"])
        self.assertEqual(j["handback"], hb)
        self.assertEqual(VaultHelpRequest.objects.get(pk=rid).state, "done")

    def test_owner_can_cancel_during_the_wait(self):
        wid = self._add().json()["helper"]["id"]
        self.ca.post(V + "/vault/e2e/help/request",
                     {"wrap_id": wid, "public_key": b64(os.urandom(32))}, format="json")
        rid = VaultHelpRequest.objects.get().id
        self.cb.post(V + f"/vault/e2e/help/{rid}/approve", {"blob": wrap("x25519-c20p")},
                     format="json")
        self.assertEqual(self.ca.post(V + "/vault/e2e/help/cancel").json()["cancelled"], 1)
        VaultHelpRequest.objects.update(ready_at=timezone.now() - timedelta(minutes=1))
        j = self.ca.get(V + "/vault/e2e/help/request").json()["request"]
        self.assertEqual(j["state"], "cancelled")
        self.assertNotIn("handback", j)
        self.assertEqual(VaultHelpRequest.objects.get().handback, "")

    def test_requests_are_rate_limited(self):
        wid = self._add().json()["helper"]["id"]
        codes = [self.ca.post(V + "/vault/e2e/help/request",
                              {"wrap_id": wid, "public_key": b64(os.urandom(32))},
                              format="json").status_code for _ in range(4)]
        self.assertEqual(codes, [201, 201, 201, 429])


@override_settings(MEDIA_ROOT=_MEDIA)
class ShareLinkTests(TestCase):
    def setUp(self):
        flag(True)
        self.u = mk()
        self.c = cl(self.u)
        self.did = post_sealed(self.c).json()["id"]

    def _share(self, blob=None, hours=24, max_opens=1, did=None, c=None):
        blob = blob if blob is not None else VE.SHARE_MAGIC + os.urandom(200)
        return (c or self.c).post(V + "/vault/share", {
            "document_id": did or self.did, "hours": hours, "max_opens": max_opens,
            "blob": SimpleUploadedFile("s.bin", blob, "application/octet-stream")},
            format="multipart")

    def test_link_serves_exact_ciphertext_once_then_deletes_it(self):
        blob = VE.SHARE_MAGIC + os.urandom(500)
        r = self._share(blob)
        self.assertEqual(r.status_code, 201, r.content)
        token = r.json()["token"]
        s = VaultShareLink.objects.get()
        self.assertNotEqual(s.token_hash, token)        # only the hash is stored
        self.assertEqual(s.token_hash, VE.token_hash(token))
        page = APIClient().get(f"/d/{token}")
        self.assertEqual(page.status_code, 200)
        self.assertEqual(page["X-Robots-Tag"], "noindex, nofollow")
        self.assertIn("no-store", page["Cache-Control"])
        self.assertEqual(VaultShareLink.objects.get().opens, 0)   # previews are free
        got = APIClient().get(f"/d/{token}/blob")
        self.assertEqual(got.status_code, 200)
        self.assertEqual(got.content, blob)
        s.refresh_from_db()
        self.assertEqual(s.opens, 1)
        self.assertFalse(s.blob)                        # ciphertext gone after last open
        again = APIClient().get(f"/d/{token}/blob")
        self.assertEqual(again.status_code, 410)
        self.assertEqual(again.json()["state"], "used")
        self.assertEqual(APIClient().get(f"/d/{token}").status_code, 410)

    def test_expiry_and_revoke(self):
        t1 = self._share(max_opens=3).json()["token"]
        VaultShareLink.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        r = APIClient().get(f"/d/{t1}/blob")
        self.assertEqual((r.status_code, r.json()["state"]), (410, "expired"))
        r2 = self._share(max_opens=3).json()
        rv = self.c.post(V + f"/vault/share/{r2['link']['id']}/revoke")
        self.assertEqual(rv.json()["link"]["state"], "revoked")
        self.assertEqual(APIClient().get(f"/d/{r2['token']}/blob").json()["state"], "revoked")
        self.assertFalse(VaultShareLink.objects.get(pk=r2["link"]["id"]).blob)
        self.assertEqual(APIClient().get("/d/not-a-real-token-xyz").status_code, 404)
        VE.purge_shares()
        self.assertFalse(any(s.blob for s in VaultShareLink.objects.all()))

    def test_refuses_plain_files_odd_limits_and_others_documents(self):
        self.assertEqual(self._share(blob=b"%PDF-1.7 hello").status_code, 400)
        self.assertEqual(self._share(blob=b"\xff\xd8\xff" + os.urandom(99)).status_code, 400)
        self.assertEqual(self._share(hours=5).status_code, 400)
        self.assertEqual(self._share(max_opens=99).status_code, 400)
        other = cl(mk("O"))
        self.assertEqual(self._share(c=other).status_code, 404)
        self.assertFalse(VaultShareLink.objects.exists())

    def test_owner_lists_links_with_open_counts(self):
        self._share(max_opens=3)
        rows = self.c.get(V + f"/vault/share?document_id={self.did}").json()["results"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["state"], rows[0]["opens"], rows[0]["max_opens"]),
                         ("open", 0, 3))
        self.assertEqual(cl(mk("X")).get(V + "/vault/share").json()["results"], [])

    def test_page_never_contains_the_key_fragment_logic_server_side(self):
        token = self._share().json()["token"]
        html = APIClient().get(f"/d/{token}").content.decode()
        self.assertIn("location.hash", html)            # key read in the browser only
        self.assertIn("default-src 'none'", APIClient().get(f"/d/{token}")["Content-Security-Policy"])
