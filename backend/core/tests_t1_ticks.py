"""t1-ticks — legacy (pre-receipts) messages, server-side DELIVERED on every
hand-off (fetch / chat list / FCM accepted), and the My Circle minimum-version
gate (admin-editable min, app/latest, peer build banner data).

Run: manage.py test core.tests_t1_ticks --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import billing
from core import views_t1_ticks as T1
from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CircleReceipt, Device, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


class _Base(TestCase):
    def setUp(self):
        T1.reset_epoch_cache()
        self.a = mk("01710000001", "Amina")
        self.b = mk("01710000002", "Bilal")
        self.c = mk("01710000003", "Chaya")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, public_key="pkB", key_id="kB")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming", public_key="pkA")
        self.ca, self.cb, self.cc = (self.cl(self.a), self.cl(self.b),
                                     self.cl(self.c))

    def cl(self, u):
        c = APIClient()
        c.force_authenticate(u)
        c.credentials(HTTP_ACCEPT_LANGUAGE="en")
        return c

    def send(self, client, edge, cmid):
        r = client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": cmid},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def msgs(self, client, edge):
        return client.get("%s/circle/%d/messages" % (V, edge.id)).json()["results"]

    def row(self, client, edge, mid):
        return next(m for m in self.msgs(client, edge) if m["id"] == mid)

    def group(self):
        g = CircleGroup.objects.create(name="Fam", creator=self.a)
        gms = {}
        for u, role in ((self.a, "admin"), (self.b, "member"),
                        (self.c, "member")):
            gms[u.id] = CircleGroupMember.objects.create(
                group=g, member=u, role=role, status="active")
        return g, gms


class LegacyTests(_Base):
    def test_epoch_from_migration_record(self):
        e = T1.receipts_epoch()
        self.assertIsNotNone(e)             # test DB applied 0055 at setup
        self.assertLessEqual(e, timezone.now())

    def test_legacy_message_flag_tick_and_info(self):
        mid = self.send(self.ca, self.ab, "old")
        # pretend it was sent a week before receipts existed
        CircleMessage.objects.filter(pk=mid).update(
            created_at=T1.receipts_epoch() - timedelta(days=7))
        # B's device later syncs + opens the chat (rows written NOW)
        self.cb.post(V + "/circle/receipts/sync")
        self.cb.post("%s/circle/%d/seen" % (V, self.ba.id))
        r = self.row(self.ca, self.ab, mid)
        self.assertTrue(r["receipts_legacy"])
        self.assertEqual(r["status"], "sent")      # one neutral tick
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertTrue(info["receipts_legacy"])
        self.assertEqual(info["status"], "sent")
        self.assertIsNone(info["recipients"][0]["delivered_at"])
        self.assertIsNone(info["recipients"][0]["seen_at"])

    def test_new_message_not_legacy(self):
        mid = self.send(self.ca, self.ab, "new")
        r = self.row(self.ca, self.ab, mid)
        self.assertNotIn("receipts_legacy", r)
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertFalse(info["receipts_legacy"])

    def test_forced_epoch_setting(self):
        mid = self.send(self.ca, self.ab, "x")
        with override_settings(CIRCLE_RECEIPTS_EPOCH=(
                timezone.now() + timedelta(hours=1)).isoformat()):
            self.assertTrue(self.row(self.ca, self.ab, mid)["receipts_legacy"])
        with override_settings(CIRCLE_RECEIPTS_EPOCH=None):
            T1.reset_epoch_cache()
            self.assertNotIn("receipts_legacy", self.row(self.ca, self.ab, mid))


class DeliveredOnFetchTests(_Base):
    def test_fetch_marks_delivered_not_seen(self):
        mid = self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.row(self.ca, self.ab, mid)["status"], "sent")
        self.msgs(self.cb, self.ba)                 # B's device fetches (any build)
        self.assertEqual(self.row(self.ca, self.ab, mid)["status"], "delivered")
        rc = CircleReceipt.objects.get(message_id=mid, user=self.b)
        self.assertIsNotNone(rc.delivered_at)
        self.assertIsNone(rc.seen_at)               # seen stays client-driven
        info = self.ca.get("%s/circle/messages/%d/info" % (V, mid)).json()
        self.assertIsNotNone(info["recipients"][0]["delivered_at"])
        self.assertIsNone(info["recipients"][0]["seen_at"])

    def test_sender_fetch_never_delivers(self):
        mid = self.send(self.ca, self.ab, "m1")
        self.msgs(self.ca, self.ab)
        self.assertFalse(CircleReceipt.objects.filter(message_id=mid).exists())

    def test_repeat_poll_writes_nothing(self):
        self.send(self.ca, self.ab, "m1")
        self.msgs(self.cb, self.ba)
        with mock.patch("core.views_c3_msg.mark") as m:
            self.msgs(self.cb, self.ba)
            m.assert_not_called()

    def test_chat_list_delivers_last(self):
        mid = self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.cb.get(V + "/circle/chats").status_code, 200)
        self.assertEqual(self.row(self.ca, self.ab, mid)["status"], "delivered")

    def test_group_fetch_delivers_per_member(self):
        g, gms = self.group()
        x = CircleMessage.objects.create(
            group=g, sender=self.a, content_type="text", ciphertext="",
            nonce="", recipient_ids=[gms[self.b.id].id, gms[self.c.id].id],
            per_recipient={str(gms[self.b.id].id): {"ciphertext": "Q", "nonce": "N"},
                           str(gms[self.c.id].id): {"ciphertext": "Q", "nonce": "N"}})
        url = "%s/circle/groups/%d/messages" % (V, g.id)
        st = lambda: next(m for m in self.ca.get(url).json()["results"]
                          if m["id"] == x.id)["status"]
        self.assertEqual(st(), "sent")
        self.cb.get(url)
        self.assertEqual(st(), "sent")               # C hasn't got it yet
        self.cc.get(url)
        self.assertEqual(st(), "delivered")

    @override_settings(PUSH_SYNC=True)
    def test_fcm_accepted_marks_delivered(self):
        from core import push
        Device.objects.create(user=self.b, push_token="tokB",
                              app_version="1.0.150+150")
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", return_value=True):
            mid = self.send(self.ca, self.ab, "m1")
        self.assertTrue(CircleReceipt.objects.filter(
            message_id=mid, user=self.b, delivered_at__isnull=False,
            seen_at__isnull=True).exists())

    @override_settings(PUSH_SYNC=True)
    def test_fcm_rejected_no_delivered(self):
        from core import push
        Device.objects.create(user=self.b, push_token="tokB")
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", return_value=False):
            mid = self.send(self.ca, self.ab, "m1")
        self.assertFalse(CircleReceipt.objects.filter(message_id=mid).exists())

    def test_fcm_switch_off(self):
        mid = self.send(self.ca, self.ab, "m1")
        with override_settings(CIRCLE_FCM_MARKS_DELIVERED=False):
            self.assertEqual(T1.on_fcm_accepted(self.b, mid), 0)
        self.assertEqual(T1.on_fcm_accepted(self.c, mid), 0)   # not theirs
        self.assertEqual(T1.on_fcm_accepted(self.a, mid), 0)   # own message
        self.assertEqual(T1.on_fcm_accepted(self.b, mid), 1)


class MinVersionTests(_Base):
    def test_build_of(self):
        self.assertEqual(T1.build_of("1.0.183+183"), 183)
        self.assertEqual(T1.build_of("183"), 183)
        self.assertEqual(T1.build_of("1.0.145"), 145)
        self.assertIsNone(T1.build_of(""))
        self.assertIsNone(T1.build_of("abc"))

    def test_app_latest_has_min_version_admin_editable(self):
        r = self.client.get(V + "/app/latest").json()
        self.assertEqual(r["my_circle_min_version"], 183)
        row = billing.get_config()
        data = dict(row.data)
        data.setdefault("limits", {})
        data["limits"] = dict(data["limits"], my_circle_min_version=190)
        row.data = data
        row.save()
        self.assertEqual(self.client.get(V + "/app/latest").json()
                         ["my_circle_min_version"], 190)

    def test_device_register_records_user_version(self):
        r = self.cb.post(V + "/devices/register",
                         {"push_token": "tokB", "app_version": "1.0.150+150"},
                         format="json")
        self.assertIn(r.status_code, (200, 201))
        self.b.refresh_from_db()
        self.assertEqual(self.b.app_version, "1.0.150+150")

    def test_gate_1to1_peer_outdated_and_me(self):
        Device.objects.create(user=self.b, push_token="tokB",
                              app_version="1.0.150+150")
        r = self.ca.get(V + "/circle/t1/gate",
                        {"kind": "member", "id": self.ab.id, "build": "183"})
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual(d["min_version"], 183)
        self.assertFalse(d["me_outdated"])
        self.assertEqual(d["peer_build"], 150)
        self.assertEqual(d["peers_outdated"][0]["name"], "Bilal")
        self.a.refresh_from_db()
        self.assertEqual(self.a.app_version, "183")      # my build recorded
        # B updates -> banner gone; B on an old build sees me_outdated
        d = self.cb.get(V + "/circle/t1/gate", {"kind": "member",
                                                "id": self.ba.id,
                                                "build": "182"}).json()
        self.assertTrue(d["me_outdated"])
        self.assertEqual(d["peer_build"], 183)
        self.assertEqual(d["peers_outdated"], [])

    def test_gate_unknown_peer_not_flagged_and_access(self):
        d = self.ca.get(V + "/circle/t1/gate",
                        {"kind": "member", "id": self.ab.id}).json()
        self.assertIsNone(d["peer_build"])
        self.assertEqual(d["peers_outdated"], [])
        self.assertEqual(self.cc.get(V + "/circle/t1/gate", {
            "kind": "member", "id": self.ab.id}).status_code, 404)

    def test_gate_group(self):
        g, _ = self.group()
        User.objects.filter(pk=self.c.pk).update(app_version="1.0.170+170")
        User.objects.filter(pk=self.b.pk).update(app_version="1.0.183+183")
        d = self.ca.get(V + "/circle/t1/gate",
                        {"kind": "group", "id": g.id, "build": "184"}).json()
        self.assertEqual(d["peers_outdated_count"], 1)
        self.assertEqual(d["peers_outdated"][0]["name"], "Chaya")
        u = mk("01710000009", "Zed")
        self.assertEqual(self.cl(u).get(V + "/circle/t1/gate", {
            "kind": "group", "id": g.id}).status_code, 404)
