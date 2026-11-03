"""viewonce (owner My Circle order 3 Nov 16:30, parts F + G) — PROVEN on the
real endpoints:

F  media limits: owner defaults (video 3 min / 25 MB / 720p, files 100 MB,
   30 photos at once, voice 15 min), owner-editable + bounded, published to
   the phone, enforced by the server with Bangla + English messages.
G  view once: photo / video / voice, 1:1 and groups; the server claims the
   open (second open REFUSED), hands out the one link, deletes the server
   copy after everyone opened or after 14 days; never in a notification /
   chat-list envelope; the minute job runs it (no new cron line).

Run: manage.py test core.tests_viewonce --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.utils import timezone

from core import circle_blobs as CB
from core import e_gaps
from core import ops_health as H
from core.logic import pricing as P
from core.models import (CircleGroup, CircleGroupMember, CircleMediaBlob,
                         CircleMessage)
from core.tests_md1_media import MB, V, _Base, cl, mk


class MediaLimitsTests(_Base):
    def test_owner_defaults_published(self):
        lim = self.ca.get(V + "/circle/media/limits").json()
        self.assertEqual(lim["video_max_bytes"], 25 * MB)
        self.assertEqual(lim["doc_max_bytes"], 100 * MB)
        self.assertEqual(lim["video_max_seconds"], 180)
        self.assertEqual(lim["video_height"], 720)
        self.assertEqual(lim["voice_max_seconds"], 900)
        self.assertEqual(lim["photos_per_send"], 30)
        self.assertEqual(lim["view_once_days"], 14)

    def test_owner_editable_and_bounded(self):
        cfg = P.normalize({"limits": {"circle_media_video_max_seconds": 60,
                                      "circle_media_photos_per_send": 999,
                                      "circle_media_view_once_days": 0,
                                      "circle_media_doc_max_mb": 5000}})
        lim = cfg["limits"]
        self.assertEqual(lim["circle_media_video_max_seconds"], 60)
        self.assertEqual(lim["circle_media_photos_per_send"], 100)   # clamp
        self.assertEqual(lim["circle_media_view_once_days"], 1)
        self.assertEqual(lim["circle_media_doc_max_mb"], 200)
        with mock.patch("core.billing.cfg", return_value=cfg):
            j = self.ca.get(V + "/circle/media/limits").json()
        self.assertEqual(j["video_max_seconds"], 60)
        self.assertEqual(j["photos_per_send"], 100)

    def _create(self, kind, size=1000, client=None, **extra):
        body = {"kind": kind, "size": size, "sha256": "0" * 64}
        body.update(extra)
        return (client or self.ca).post(V + "/circle/media/blobs", body,
                                        format="json")

    def test_video_over_3_minutes_refused_bn_en(self):
        r = self._create("video", duration_ms=181_000 + 2_500)
        self.assertEqual((r.status_code, r.json()["reason"]), (413, "too_long"))
        self.assertIn("3 min", r.json()["detail"])
        bn = cl(self.a)
        bn.credentials(HTTP_ACCEPT_LANGUAGE="bn")
        r = self._create("video", client=bn, duration_ms=200_000)
        self.assertIn("৩ মিনিট", r.json()["detail"])
        # exactly 3 min (+ rounding) is fine
        self.assertEqual(self._create("video", duration_ms=180_400).status_code, 201)

    def test_trim_threshold_voice_15_minutes(self):
        self.assertEqual(self._create("voice", duration_ms=900_000).status_code, 201)
        r = self._create("voice", duration_ms=903_000)
        self.assertEqual(r.json()["reason"], "too_long")
        self.assertEqual(CB.max_seconds("voice"), 900)
        self.assertIsNone(CB.duration_check("document", 10 ** 9))

    def test_size_caps_video_25_file_100(self):
        r = self._create("video", size=26 * MB)
        self.assertEqual((r.status_code, r.json()["reason"]), (413, "too_big"))
        self.assertIn("25 MB", r.json()["detail"])
        self.assertEqual(self._create("video", size=25 * MB).status_code, 201)
        lim = dict(CB.limits(), circle_media_daily_mb=5000)
        with mock.patch.object(CB, "limits", return_value=lim):
            self.assertEqual(self._create("document", size=100 * MB).status_code, 201)
            r = self._create("document", size=101 * MB)
        self.assertEqual(r.json()["reason"], "too_big")

    def test_photos_at_once_cap(self):
        lim = dict(CB.limits(), circle_media_photos_per_send=3)
        with mock.patch.object(CB, "limits", return_value=lim):
            for _ in range(3):
                self.assertEqual(self._create("photo").status_code, 201)
            r = self._create("photo")
            self.assertEqual((r.status_code, r.json()["reason"]), (429, "too_many"))
            # documents are not "photos at once"
            self.assertEqual(self._create("document").status_code, 201)

    def test_admin_labels_bn_en(self):
        from web.owner import i18n as OI
        for k in ("circle_media_video_max_seconds", "circle_media_photos_per_send",
                  "circle_media_view_once_days", "circle_media_voice_max_seconds"):
            self.assertIn("pf_" + k, OI.EN)
            self.assertIn("pf_" + k, OI.BN)


class _VoBase(_Base):
    def send_vo(self, kind="photo", cmid="vo1"):
        ref = self.upload(kind=kind)
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": kind, "blob_ref": ref, "view_once": True,
            "ciphertext": "RU5DLURFU0M=", "nonce": "Tg==",
            "sender_key_id": "kA", "client_msg_id": cmid}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return ref, r.json()["id"]

    def open_(self, client, mid, want_url=True):
        return client.post("%s/circle/messages/%d/view-once-open" % (V, mid),
                           {"want_url": want_url} if want_url else {},
                           format="json")

    def rows(self, client, edge):
        r = client.get("%s/circle/%d/messages" % (V, edge.id))
        return {x["id"]: x for x in r.json()["results"]}


class ViewOnceOneToOneTests(_VoBase):
    def test_opens_only_once_server_refuses_second(self):
        ref, mid = self.send_vo()
        r = self.open_(self.cb, mid)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("/circle/media/dl/%s" % ref, r.json()["url"])
        self.assertTrue(r.json()["opened_at"])
        # the second open is REFUSED by the server (not only the phone)
        r = self.open_(self.cb, mid)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "already_opened")
        self.assertIn("already opened", r.json()["detail"])
        # nor can the link be asked for again
        self.assertEqual(self.url_for(ref, self.cb).status_code, 404)
        # the descriptor (file key) is gone from the server
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual((x.ciphertext, x.nonce), ("", ""))
        self.assertEqual(self.rows(self.cb, self.ba)[mid]["ciphertext"], "")

    def test_video_and_voice_can_be_view_once(self):
        for kind in ("video", "voice"):
            _, mid = self.send_vo(kind=kind, cmid="vo-" + kind)
            self.assertTrue(CircleMessage.objects.get(pk=mid).view_once, kind)
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "content_type": "document", "blob_ref": self.upload(kind="document"),
            "view_once": True, "ciphertext": "RU5D", "nonce": "Tg==",
            "sender_key_id": "kA", "client_msg_id": "doc"}, format="json")
        self.assertFalse(CircleMessage.objects.get(pk=r.json()["id"]).view_once)

    def test_sender_sees_opened_with_time(self):
        _, mid = self.send_vo()
        row = self.rows(self.ca, self.ab)[mid]
        self.assertFalse(row["view_once_opened"])
        self.open_(self.cb, mid)
        row = self.rows(self.ca, self.ab)[mid]
        self.assertTrue(row["view_once_opened"])
        self.assertTrue(row["view_once_opened_at"])
        self.assertEqual(row["ciphertext"], "")

    def test_legacy_url_first_counts_as_the_open(self):
        ref, mid = self.send_vo()
        self.assertEqual(self.url_for(ref, self.cb).status_code, 200)
        self.assertEqual(self.url_for(ref, self.cb).status_code, 404)
        # the old build's ack afterwards stays harmless
        r = self.open_(self.cb, mid, want_url=False)
        self.assertEqual(r.json()["state"], "already")
        # and the sender never gets the file
        self.assertEqual(self.url_for(ref, self.ca).status_code, 404)

    def test_deleted_after_open_by_minute_job(self):
        ref, mid = self.send_vo()
        self.open_(self.cb, mid)
        # the one link may still finish: kept during the grace window
        self.assertEqual(e_gaps.purge_view_once()["opened"], 0)
        self.assertTrue(CircleMediaBlob.objects.filter(ref=ref).exists())
        later = timezone.now() + timedelta(seconds=e_gaps.URL_GRACE_S + 60)
        self.assertEqual(e_gaps.purge_view_once(now=later)["opened"], 1)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertEqual(CircleMessage.objects.get(pk=mid).blob_ref, "")
        # idempotent
        self.assertEqual(e_gaps.purge_view_once(now=later), {"opened": 0, "expired": 0})

    def test_deleted_after_14_days_unopened(self):
        ref, mid = self.send_vo()
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(days=13, hours=23))
        self.assertEqual(e_gaps.purge_view_once()["expired"], 0)
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(days=14, minutes=1))
        self.assertEqual(e_gaps.purge_view_once()["expired"], 1)
        x = CircleMessage.objects.get(pk=mid)
        self.assertIsNotNone(x.view_once_expired_at)
        self.assertEqual((x.ciphertext, x.blob_ref), ("", ""))
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        r = self.open_(self.cb, mid)
        self.assertEqual((r.status_code, r.json()["reason"]), (410, "expired"))
        self.assertTrue(self.rows(self.cb, self.ba)[mid]["view_once_expired"])

    def test_minute_job_runs_it_no_new_cron_line(self):
        self.assertIn("view_once_purge", H.MINUTE_JOB_NAMES)
        self.assertEqual(H.JOB_BY_NAME["view_once_purge"].via, "minute_jobs")
        ref, mid = self.send_vo()
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(days=15))
        call_command("view_once_purge", stdout=StringIO())
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_no_preview_in_notification_or_chat_list(self):
        _, mid = self.send_vo()
        r = self.cb.post(V + "/circle/notify/pull",
                         {"kind": "member", "chat_id": self.ba.id}, format="json")
        if r.status_code == 200:
            for m in r.json().get("messages", []):
                if m.get("id") == mid:
                    self.assertTrue(m["view_once"])
                    self.assertEqual(m["ciphertext"], "")
        chats = self.cb.get(V + "/circle/chats").json()
        rows = chats.get("results", chats) if isinstance(chats, dict) else chats
        lasts = [c.get("last") for c in rows if isinstance(c, dict)
                 and isinstance(c.get("last"), dict) and c["last"].get("id") == mid]
        self.assertTrue(lasts)
        for last in lasts:
            self.assertTrue(last["view_once"])
            self.assertEqual(last["ciphertext"], "")

    def test_envelope_hook_strips_descriptor(self):
        _, mid = self.send_vo()
        from core.views_c3_msg import envelope_for
        env = envelope_for(self.b, CircleMessage.objects.get(pk=mid), {})
        self.assertTrue(env["view_once"])
        self.assertEqual((env["ciphertext"], env["nonce"]), ("", ""))


class ViewOnceGroupTests(_VoBase):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=self.g, member=self.a, role="admin")
        self.gmb = CircleGroupMember.objects.create(group=self.g, member=self.b)
        self.gmc = CircleGroupMember.objects.create(group=self.g, member=self.c)

    def send_group_vo(self):
        ref = self.upload()
        r = self.ca.post("%s/circle/groups/%d/messages" % (V, self.g.id), {
            "content_type": "photo", "blob_ref": ref, "view_once": True,
            "recipient_ids": [self.gmb.id, self.gmc.id],
            "per_recipient": {
                str(self.gmb.id): {"ciphertext": "QkI=", "nonce": "Tg=="},
                str(self.gmc.id): {"ciphertext": "Q0M=", "nonce": "Tg=="}},
            "client_msg_id": "gvo"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return ref, r.json()["id"]

    def grows(self, client):
        r = client.get("%s/circle/groups/%d/messages" % (V, self.g.id))
        self.assertEqual(r.status_code, 200, r.content)
        return {x["id"]: x for x in r.json()["results"]}

    def test_each_member_opens_once(self):
        ref, mid = self.send_group_vo()
        self.assertTrue(CircleMessage.objects.get(pk=mid).view_once)
        # each member only gets their OWN sealed entry, no top-level copy
        rb = self.grows(self.cb)[mid]
        self.assertEqual(rb["ciphertext"], "")
        self.assertEqual(rb["per_recipient"][str(self.gmb.id)]["ciphertext"], "QkI=")
        self.assertEqual(rb["per_recipient"][str(self.gmc.id)], {})
        self.assertEqual(self.open_(self.cb, mid).status_code, 200)
        self.assertEqual(self.open_(self.cb, mid).status_code, 409)
        rb = self.grows(self.cb)[mid]
        self.assertTrue(rb["view_once_opened"])
        self.assertEqual(rb["per_recipient"][str(self.gmb.id)], {})
        # Chaya has not opened yet: still can, once
        rc = self.grows(self.cc)[mid]
        self.assertFalse(rc["view_once_opened"])
        self.assertEqual(rc["per_recipient"][str(self.gmc.id)]["ciphertext"], "Q0M=")
        sa = self.grows(self.ca)[mid]
        self.assertEqual((sa["view_once_open_count"], sa["view_once_total"]), (1, 2))
        self.assertFalse(sa["view_once_opened"])
        # partially opened: the blob stays for Chaya
        later = timezone.now() + timedelta(hours=1)
        self.assertEqual(e_gaps.purge_view_once(now=later)["opened"], 0)
        self.assertEqual(self.open_(self.cc, mid).status_code, 200)
        sa = self.grows(self.ca)[mid]
        self.assertTrue(sa["view_once_opened"])
        self.assertTrue(sa["view_once_opened_at"])
        # all opened -> deleted after the grace window
        self.assertEqual(e_gaps.purge_view_once(now=later)["opened"], 1)
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_sender_and_outsider_cannot_open(self):
        _, mid = self.send_group_vo()
        self.assertEqual(self.open_(self.ca, mid).status_code, 400)
        d = mk("01710000009", "Dina")
        self.assertEqual(self.open_(cl(d), mid).status_code, 404)
        # a member who joined later was never sent it
        CircleGroupMember.objects.create(group=self.g, member=d)
        r = self.open_(cl(d), mid)
        self.assertEqual(r.json()["reason"], "not_recipient")

    def test_group_never_in_preview(self):
        _, mid = self.send_group_vo()
        from core.views_c3_msg import envelope_for
        env = envelope_for(self.b, CircleMessage.objects.get(pk=mid), {})
        self.assertTrue(env["view_once"])
        self.assertEqual(env["ciphertext"], "")
