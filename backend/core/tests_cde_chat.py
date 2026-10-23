"""cde-chat (order 6 D + E) — shared chat theme + nicknames, PROVEN on the
real endpoints: one row per chat seen by BOTH sides, Free vs Premium themes,
nickname set / change / remove for me or the other person, groups, cleaning,
and the nickname reaching the member payload, the notification pull title,
group envelopes and the push / call names.

Run: manage.py test core.tests_cde_chat --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import chat_decor, push
from core.models import (ChatDecor, CircleGroup, CircleGroupMember,
                         CircleMember, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


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
        self.ca, self.cb, self.cc = (self.cl(self.a), self.cl(self.b),
                                     self.cl(self.c))

    def cl(self, u):
        c = APIClient()
        c.force_authenticate(u)
        c.credentials(HTTP_ACCEPT_LANGUAGE="en")
        return c

    def premium(self, u):
        u.plan = "premium"
        u.plan_until = timezone.now() + timedelta(days=30)
        u.save()

    def mpost(self, client, edge, body):
        return client.post("%s/circle/decor/member/%d" % (V, edge.id), body,
                           format="json")

    def mget(self, client, edge):
        return client.get("%s/circle/decor/member/%d" % (V, edge.id))


class ThemeTests(_Base):
    def test_free_theme_shared_by_both_sides(self):
        r = self.mpost(self.ca, self.ab, {"theme": "love"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["theme"]["id"], "love")
        self.assertTrue(r.json()["theme"]["by_me"])
        self.assertGreater(r.json()["at_ms"], 0)
        # ONE row for the pair; B reads the same theme from HIS edge
        self.assertEqual(ChatDecor.objects.count(), 1)
        g = self.mget(self.cb, self.ba).json()
        self.assertEqual(g["theme"]["id"], "love")
        self.assertFalse(g["theme"]["by_me"])
        self.assertEqual(g["theme"]["at_ms"], r.json()["at_ms"])
        # B changes it back -> A sees classic
        self.mpost(self.cb, self.ba, {"theme": "classic"})
        self.assertEqual(self.mget(self.ca, self.ab).json()["theme"]["id"], "classic")

    def test_premium_theme_gated(self):
        r = self.mpost(self.ca, self.ab, {"theme": "midnight"})
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["reason"], "premium_required")
        self.assertTrue(r.json()["detail"])
        for locked in ("custom", "ai", "eid"):
            self.assertEqual(self.mpost(self.ca, self.ab, {"theme": locked}).status_code, 402)
        self.premium(self.a)
        r = self.mpost(self.ca, self.ab, {"theme": "midnight"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["premium"])
        # the free peer still SEES the premium theme (only setting is gated)
        self.assertEqual(self.mget(self.cb, self.ba).json()["theme"]["id"], "midnight")
        self.assertFalse(self.mget(self.cb, self.ba).json()["premium"])

    def test_unknown_theme_and_strangers(self):
        r = self.mpost(self.ca, self.ab, {"theme": "neon"})
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "unknown_theme"))
        # C has no edge with this id -> 404, never a peek at the row
        self.assertEqual(self.mget(self.cc, self.ab).status_code, 404)
        self.assertEqual(self.mpost(self.cc, self.ab, {"theme": "love"}).status_code, 404)

    def test_pending_request_cannot_decorate(self):
        self.ab.state = "pending"
        self.ab.save()
        r = self.mpost(self.ca, self.ab, {"theme": "love"})
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "not_accepted"))

    def test_member_payload_carries_theme(self):
        self.mpost(self.ca, self.ab, {"theme": "sunset"})
        from core.views_module5 import _member_dict
        self.assertEqual(_member_dict(self.ba)["chat_theme"], "sunset")


class NicknameTests(_Base):
    def test_set_for_peer_and_self_both_sides_see(self):
        r = self.mpost(self.ca, self.ab, {"nick": {"who": "peer", "name": "Bhaiya"}})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["nick_peer"], "Bhaiya")
        self.mpost(self.ca, self.ab, {"nick": {"who": "me", "name": "Apu"}})
        g = self.mget(self.cb, self.ba).json()
        # mirrored: what A calls B is B's "me" nickname on B's side
        self.assertEqual(g["nick_me"], "Bhaiya")
        self.assertEqual(g["nick_peer"], "Apu")
        self.assertGreater(g["nick_at"]["me"], 0)
        # B changes his own nickname -> A sees the change
        self.mpost(self.cb, self.ba, {"nick": {"who": "me", "name": "Bilu"}})
        self.assertEqual(self.mget(self.ca, self.ab).json()["nick_peer"], "Bilu")

    def test_remove(self):
        self.mpost(self.ca, self.ab, {"nick": {"who": "peer", "name": "Bhaiya"}})
        r = self.mpost(self.cb, self.ba, {"nick": {"who": "me", "name": ""}})
        self.assertEqual(r.json()["nick_me"], "")
        self.assertEqual(self.mget(self.ca, self.ab).json()["nick_peer"], "")

    def test_cleaning(self):
        dirty = "  Bha⁣iya\n\t ‮X  " + "y" * 80
        r = self.mpost(self.ca, self.ab, {"nick": {"who": "peer", "name": dirty}})
        n = r.json()["nick_peer"]
        self.assertTrue(n.startswith("Bhaiya X"))
        self.assertNotIn("⁣", n)
        self.assertNotIn("‮", n)
        self.assertLessEqual(len(n), chat_decor.NICK_MAX)
        # Bangla joiners survive
        bn = "র‍্য"
        self.assertEqual(chat_decor.clean_nick(bn), bn)

    def test_bad_target(self):
        r = self.mpost(self.ca, self.ab, {"nick": {"who": "them", "name": "x"}})
        self.assertEqual(r.status_code, 400)
        r = self.mpost(self.ca, self.ab, {"nothing": 1})
        self.assertEqual(r.status_code, 400)

    def test_nickname_in_payloads_and_pull_title(self):
        self.mpost(self.cb, self.ba, {"nick": {"who": "peer", "name": "Ammu"}})
        from core.views_module5 import _member_dict
        d = _member_dict(self.ba)
        self.assertEqual(d["nickname"], "Ammu")
        self.assertEqual(d["name"], "Amina")  # the real name stays
        self.assertEqual(_member_dict(self.ab)["my_nickname"], "Ammu")
        # B's notification pull for a message from A shows the nickname
        r = self.ca.post("%s/circle/%d/messages" % (V, self.ab.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": "n1"},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        p = self.cb.post(V + "/circle/notify/pull",
                         {"chat_kind": "member", "chat_id": self.ba.id},
                         format="json").json()
        self.assertEqual(p["chat"]["title"], "Ammu")
        self.assertEqual(p["messages"][-1]["sender_name"], "Ammu")

    def test_push_and_call_use_nickname(self):
        self.mpost(self.cb, self.ba, {"nick": {"who": "peer", "name": "Ammu"}})
        self.assertEqual(push.seen_name(self.b, self.a), "Ammu")
        self.assertEqual(push.seen_name(self.c, self.a), "Amina")
        with mock.patch("core.push.is_available", return_value=True), \
                mock.patch("core.push.safe_push", return_value=1) as sp:
            call = mock.Mock(id=9, kind="voice")
            push.hook_call_placed(self.a, self.ab, call)
            self.assertEqual(sp.call_args.kwargs["data"]["caller_name"], "Ammu")
            self.assertIn("Ammu", sp.call_args.args[3])


class GroupTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        for u, role in ((self.a, "admin"), (self.b, "member")):
            CircleGroupMember.objects.create(group=self.g, member=u, role=role)

    def gpost(self, client, body):
        return client.post("%s/circle/decor/group/%d" % (V, self.g.id), body,
                           format="json")

    def test_group_theme_and_nicknames(self):
        r = self.gpost(self.cb, {"theme": "calm"})
        self.assertEqual(r.status_code, 200, r.content)
        r = self.gpost(self.cb, {"nick": {"user_id": self.a.id, "name": "Boss"}})
        self.assertEqual(r.json()["nicknames"], {str(self.a.id): "Boss"})
        g = self.ca.get("%s/circle/decor/group/%d" % (V, self.g.id)).json()
        self.assertEqual(g["theme"]["id"], "calm")
        self.assertEqual(g["nicknames"][str(self.a.id)], "Boss")
        self.assertEqual(push.seen_name(self.b, self.a, group=self.g), "Boss")
        # remove
        self.gpost(self.ca, {"nick": {"user_id": self.a.id, "name": ""}})
        g = self.cb.get("%s/circle/decor/group/%d" % (V, self.g.id)).json()
        self.assertEqual(g["nicknames"], {})

    def test_group_access_and_targets(self):
        self.assertEqual(self.gpost(self.cc, {"theme": "love"}).status_code, 404)
        r = self.gpost(self.ca, {"nick": {"user_id": self.c.id, "name": "x"}})
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "bad_target"))
        self.assertEqual(self.gpost(self.ca, {"theme": "roses"}).status_code, 402)
