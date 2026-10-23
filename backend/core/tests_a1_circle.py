"""a1-circle — owner bug report (build 202): one chat-list row per person,
same-name disambiguation, "hasn't opened Assisto yet", the peer's earlier
keys for the preview decrypt, and 1:1 call events for the chat timeline.

Run: manage.py test core.tests_a1_circle --settings=assisto_backend.settings_test
"""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import a1_circle as A1
from core import e2_keys
from core.models import (CallRecord, CallSession, CircleMember, CircleMessage,
                         Device, User)

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


def msg(edge, sender, at=None):
    x = CircleMessage.objects.create(member=edge, sender=sender,
                                     ciphertext="Q1Q=", nonce="Tg==")
    if at is not None:
        CircleMessage.objects.filter(pk=x.pk).update(created_at=at)
    return x


class ChatListTests(TestCase):
    def setUp(self):
        self.me = mk("01710000001", "Owner")
        self.c = cl(self.me)

    def _rows(self):
        r = self.c.get(V + "/circle/chats")
        self.assertEqual(r.status_code, 200)
        return [x for x in r.json()["results"] if not x.get("is_group")]

    def test_two_edges_to_one_person_are_one_row(self):
        kashem = mk("01710000200", "Abul Kashem")
        ab, ba = pair(self.me, kashem)
        # a second edge of mine to the SAME account (phone-only, legacy add)
        dup = CircleMember.objects.create(user=self.me, name="Abul Kashem",
                                          phone=kashem.phone, state="accepted")
        now = timezone.now()
        msg(ab, kashem, now - timedelta(minutes=5))
        rows = self._rows()
        peers = [r["member"]["peer_user_id"] for r in rows]
        self.assertEqual(peers.count(kashem.id), 1, rows)
        self.assertEqual(len(rows), 1)
        # the survivor is the row that HAS the conversation
        self.assertIsNotNone(rows[0]["last"])
        self.assertNotEqual(rows[0]["id"], str(dup.id))

    def test_same_name_different_people_stay_two_rows_with_hint(self):
        k1 = mk("01710000200", "Abul Kashem")
        k2 = mk("01710000888", "Abul Kashem")
        e1, _ = pair(self.me, k1)
        e2, _ = pair(self.me, k2)
        Device.objects.create(user=k1, push_token="t1")
        msg(e1, k1)
        rows = self._rows()
        self.assertEqual(len(rows), 2)   # NEVER merged: different accounts
        by = {r["member"]["peer_user_id"]: r for r in rows}
        self.assertTrue(by[k1.id]["member"]["same_name"])
        self.assertEqual(by[k1.id]["member"]["phone_tail"], "200")
        self.assertEqual(by[k2.id]["member"]["phone_tail"], "888")
        self.assertTrue(by[k1.id]["peer_has_app"])
        self.assertFalse(by[k2.id]["peer_has_app"])   # never opened the app

    def test_unique_name_sends_no_phone_tail(self):
        b = mk("01710000300", "Bilal")
        pair(self.me, b)
        r = self._rows()[0]
        self.assertFalse(r["member"]["same_name"])
        self.assertNotIn("phone_tail", r["member"])

    def test_key_published_counts_as_has_app(self):
        b = mk("01710000300", "Bilal")
        pair(self.me, b)
        e2_keys.publish(b, "QkJC", "kb1")
        self.assertTrue(self._rows()[0]["peer_has_app"])

    def test_last_carries_the_peers_earlier_keys(self):
        b = mk("01710000300", "Bilal")
        ab, _ = pair(self.me, b)
        e2_keys.publish(b, "T0xE", "old1")
        msg(ab, b)
        e2_keys.publish(b, "TkVX", "new1")   # reinstall: a NEW key
        last = self._rows()[0]["last"]
        self.assertEqual(last["peer_public_key"], "TkVX")
        self.assertEqual(last["peer_key_history"],
                         [{"public_key": "T0xE", "key_id": "old1"}])

    def test_peer_key_endpoint_has_history(self):
        b = mk("01710000300", "Bilal")
        ab, _ = pair(self.me, b)
        e2_keys.publish(b, "T0xE", "old1")
        e2_keys.publish(b, "TkVX", "new1")
        e2_keys.publish(b, "TkVX", "new1")   # same key again: no new entry
        j = self.c.get(V + "/circle/keys/peer/%d" % ab.id).json()
        self.assertEqual(j["public_key"], "TkVX")
        self.assertEqual(j["history"], [{"public_key": "T0xE", "key_id": "old1"}])


class DedupeUnitTests(TestCase):
    def test_dedupe_keeps_newest_and_max_unread(self):
        rows = [
            {"id": "1", "member": {"peer_user_id": 7}, "at": "2026-10-22T10:00",
             "unread": 3, "request": None},
            {"id": "2", "member": {"peer_user_id": 7}, "at": "2026-10-22T11:00",
             "unread": 1, "request": None},
            {"id": "3", "member": {"peer_user_id": 8}, "at": None, "unread": 0},
            {"id": "g1", "is_group": True, "member": {"peer_user_id": None}},
            {"id": "4", "member": {"peer_user_id": None}, "at": None},
        ]
        out = A1.dedupe_chat_rows(rows)
        self.assertEqual([r["id"] for r in out], ["2", "3", "g1", "4"])
        self.assertEqual(out[0]["unread"], 3)

    def test_phone_tail(self):
        self.assertEqual(A1.phone_tail("+880 1710-000888"), "888")
        self.assertEqual(A1.phone_tail("12"), "")


class CallEventTests(TestCase):
    def setUp(self):
        self.a, self.b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        self.x = mk("01710000003", "Other")
        self.ab, self.ba = pair(self.a, self.b)
        pair(self.a, self.x)
        self.ca = cl(self.a)

    def rec(self, caller, callee, kind="voice", state="ended", dur=0,
            reason="", at=None):
        r = CallRecord.objects.create(caller=caller, callee=callee, kind=kind,
                                      state=state, duration_sec=dur)
        if at is not None:
            CallRecord.objects.filter(pk=r.pk).update(started_at=at)
            r.refresh_from_db()
        CallSession.objects.create(call=r, end_reason=reason)
        return r

    def events(self, edge=None):
        r = self.ca.get(V + "/circle/calls?member=%d" % (edge or self.ab).id)
        self.assertEqual(r.status_code, 200)
        return r.json()["events"]

    def test_only_this_pair_oldest_first_with_categories(self):
        t = timezone.now() - timedelta(hours=2)
        self.rec(self.b, self.a, state="missed", reason="no_answer", at=t)
        self.rec(self.a, self.b, kind="video", dur=192, reason="hangup",
                 at=t + timedelta(minutes=10))
        self.rec(self.a, self.b, state="missed", reason="no_answer",
                 at=t + timedelta(minutes=20))
        self.rec(self.b, self.a, state="declined", reason="declined",
                 at=t + timedelta(minutes=30))
        self.rec(self.a, self.x, dur=50, reason="hangup")   # someone else
        ev = self.events()
        self.assertEqual([(e["kind"], e["outgoing"], e["category"]) for e in ev], [
            ("voice", False, "missed"),
            ("video", True, "answered"),
            ("voice", True, "no_answer"),
            ("voice", False, "declined"),
        ])
        self.assertEqual(ev[1]["duration_sec"], 192)

    def test_glare_pair_is_one_event(self):
        t = timezone.now() - timedelta(minutes=30)
        self.rec(self.a, self.b, state="missed", reason="busy", at=t)
        self.rec(self.b, self.a, dur=75, reason="hangup",
                 at=t + timedelta(seconds=2))
        ev = self.events()
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["category"], "answered")
        self.assertEqual(ev[0]["duration_sec"], 75)

    def test_ringing_call_is_not_history(self):
        CallRecord.objects.create(caller=self.b, callee=self.a, state="ringing")
        self.assertEqual(self.events(), [])

    def test_foreign_edge_404(self):
        r = self.ca.get(V + "/circle/calls?member=%d" % self.ba.id)
        self.assertEqual(r.status_code, 404)

    def test_plain_history_unchanged(self):
        self.rec(self.a, self.b, dur=10, reason="hangup")
        j = self.ca.get(V + "/circle/calls").json()
        self.assertIn("calls", j)
        self.assertEqual(len(j["calls"]), 1)
