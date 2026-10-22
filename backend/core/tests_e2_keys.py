"""e2-keys — per-user key directory, backfill migration, LIVE key reads in
every payload, silent key_request on a keyless peer, accept never dead-ends,
chat paging, and the owner's scenario (fresh B accepts and never opens My
Circle -> A can call at once and text: queued, delivered after B's
background publish).

Run: manage.py test core.tests_e2_keys --settings=assisto_backend.settings_test
"""
import importlib
from unittest import mock

from django.apps import apps as django_apps
from django.test import TestCase
from rest_framework.test import APIClient

from core import e2_keys
from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CircleReceipt, ConnectionRequest,
                         E2KeyRequest, RtEvent, User, UserPublicKey)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def pair(a, b, keys=True):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name,
                                     state="accepted", phone=b.phone)
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name,
                                     state="accepted", phone=a.phone,
                                     direction="incoming")
    return ab, ba


def _rows(j):
    return j.get("results", j) if isinstance(j, dict) else j


class KeyDirectoryTests(TestCase):
    def setUp(self):
        self.a, self.b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        self.ca, self.cb = cl(self.a), cl(self.b)

    def test_publish_without_any_edge_is_kept(self):
        # The old bug: no edge pointed at B yet -> the key was DISCARDED.
        r = self.cb.post(V + "/circle/keys", {"public_key": "QkJC", "key_id": "kb",
                                              "scheme": "x25519"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["published"])
        row = UserPublicKey.objects.get(user=self.b)
        self.assertEqual((row.public_key, row.key_id), ("QkJC", "kb"))
        # Connecting later: A sees it live.
        ab, _ = pair(self.a, self.b)
        mine = [m for m in _rows(self.ca.get(V + "/circle/members").json())
                if m["id"] == ab.id][0]
        self.assertEqual(mine["public_key"], "QkJC")
        # and nothing was copied onto the edge
        self.assertEqual(CircleMember.objects.get(pk=ab.id).public_key, "")

    def test_private_key_refused(self):
        r = self.cb.post(V + "/circle/keys", {"public_key": "QkJC",
                                              "private_key": "x"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertFalse(UserPublicKey.objects.exists())

    def test_republish_same_key_is_not_a_change(self):
        ab, _ = pair(self.a, self.b)
        self.cb.post(V + "/circle/keys", {"public_key": "QkJC", "key_id": "kb"},
                     format="json")
        n = RtEvent.objects.filter(user=self.a, topic="key.published").count()
        self.assertEqual(n, 1)   # first publish -> contacts told
        r = self.cb.post(V + "/circle/keys", {"public_key": "QkJC", "key_id": "kb"},
                         format="json").json()
        self.assertFalse(r["changed"])
        self.assertEqual(RtEvent.objects.filter(
            user=self.a, topic="key.published").count(), 1)

    def test_key_change_marks_changed_and_tells_contacts(self):
        ab, _ = pair(self.a, self.b)
        self.cb.post(V + "/circle/keys", {"public_key": "QkJC", "key_id": "kb1"},
                     format="json")
        r = self.cb.post(V + "/circle/keys", {"public_key": "TkVX", "key_id": "kb2"},
                         format="json").json()
        self.assertTrue(r["changed"])
        row = UserPublicKey.objects.get(user=self.b)
        self.assertEqual(row.previous_key_id, "kb1")
        self.assertIsNotNone(row.changed_at)
        ev = RtEvent.objects.filter(user=self.a, topic="key.published") \
            .order_by("-id").first()
        self.assertEqual(ev.payload["chat"], "member:%d" % ab.id)
        self.assertTrue(ev.payload["changed"])
        m = [x for x in _rows(self.ca.get(V + "/circle/members").json())
             if x["id"] == ab.id][0]
        self.assertEqual(m["public_key"], "TkVX")
        self.assertTrue(m["key_changed_at"])


class BackfillMigrationTests(TestCase):
    def test_backfill_newest_edge_wins_and_is_idempotent(self):
        a, b, c = (mk("01710000001", "A"), mk("01710000002", "B"),
                   mk("01710000003", "C"))
        CircleMember.objects.create(user=a, peer_user=b, public_key="OLD",
                                    key_id="k1", state="accepted")
        CircleMember.objects.create(user=c, peer_user=b, public_key="NEW",
                                    key_id="k2", state="accepted")
        CircleMember.objects.create(user=b, peer_user=a, public_key="",
                                    state="accepted")
        CircleMember.objects.create(user=b, peer_user=c, public_key="KC",
                                    state="accepted")
        UserPublicKey.objects.create(user=c, public_key="ALREADY")
        mig = importlib.import_module("core.migrations.0057_e2_keys")
        mig.backfill(django_apps, None)
        mig.backfill(django_apps, None)   # idempotent
        self.assertEqual(UserPublicKey.objects.get(user=b).public_key, "NEW")
        self.assertEqual(UserPublicKey.objects.get(user=b).key_id, "k2")
        self.assertFalse(UserPublicKey.objects.filter(user=a).exists())
        self.assertEqual(UserPublicKey.objects.get(user=c).public_key, "ALREADY")
        self.assertEqual(UserPublicKey.objects.count(), 2)


class LiveReadTests(TestCase):
    """Every payload that carries a peer key reads the directory LIVE."""

    def setUp(self):
        self.a, self.b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        self.c = mk("01710000003", "Chaya")
        # stale key on the edge must be IGNORED
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, public_key="STALE")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming")
        e2_keys.publish(self.b, "pkB", "kB", "x25519")
        e2_keys.publish(self.a, "pkA", "kA", "x25519")
        self.ca, self.cb = cl(self.a), cl(self.b)
        self.x = CircleMessage.objects.create(
            member=self.ba, sender=self.b, ciphertext="Q1Q=", nonce="Tg==",
            recipient_ids=[self.ba.id])

    def test_members_and_contact_info(self):
        m = [x for x in _rows(self.ca.get(V + "/circle/members").json())
             if x["id"] == self.ab.id][0]
        self.assertEqual(m["public_key"], "pkB")
        info = self.ca.get(V + "/circle/%d/info" % self.ab.id).json()
        self.assertEqual(info["encryption"]["public_key"], "pkB")
        self.assertTrue(info["encryption"]["fingerprint"])

    def test_chat_list_and_notify_pull(self):
        rows = _rows(self.ca.get(V + "/circle/chats").json())
        row = [r for r in rows if str(r.get("id")) == str(self.ab.id)][0]
        self.assertEqual(row["last"]["peer_public_key"], "pkB")
        self.assertEqual(row["member"]["public_key"], "pkB")
        r = self.ca.post(V + "/circle/notify/pull", {
            "chat_kind": "member", "chat_id": self.ab.id}, format="json").json()
        self.assertEqual(r["chat"]["peer_public_key"], "pkB")
        self.assertEqual(r["messages"][0]["peer_public_key"], "pkB")

    def test_peer_key_endpoint_and_live_change(self):
        r = self.ca.get(V + "/circle/keys/peer/%d" % self.ab.id).json()
        self.assertEqual((r["public_key"], r["key_id"]), ("pkB", "kB"))
        e2_keys.publish(self.b, "pkB2", "kB2", "x25519")
        r = self.ca.get(V + "/circle/keys/peer/%d" % self.ab.id).json()
        self.assertEqual(r["public_key"], "pkB2")
        self.assertTrue(r["changed_at"])
        self.assertEqual(self.cb.get(V + "/circle/keys/peer/999999").status_code,
                         404)

    def test_group_roster_and_user_keys(self):
        g = CircleGroup.objects.create(name="Fam", creator=self.a)
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.b)
        CircleGroupMember.objects.create(group=g, member=self.c)
        e2_keys.publish(self.c, "pkC", "kC")
        ros = _rows(self.ca.get(V + "/circle/groups/%d/members" % g.id).json())
        by = {r["user_id"]: r for r in ros}
        self.assertEqual(by[self.b.id]["public_key"], "pkB")
        self.assertEqual(by[self.c.id]["public_key"], "pkC")  # no A->C edge
        ks = self.ca.get(V + "/circle/keys/users?ids=%d,%d,424242" % (
            self.b.id, self.c.id)).json()["results"]
        self.assertEqual(ks[str(self.c.id)]["public_key"], "pkC")
        self.assertNotIn("424242", ks)
        # a keyless group co-member is asked silently (user_id form)
        d = mk("01710000004", "Dina")
        CircleGroupMember.objects.create(group=g, member=d)
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            r = self.ca.post(V + "/circle/keys/request", {"user_id": d.id},
                             format="json").json()
        self.assertTrue(r["queued"])
        self.assertEqual(sp.call_args.args[:2], (d, "key_request"))
        stranger = mk("01710000005", "Esha")
        r = self.ca.post(V + "/circle/keys/request", {"user_id": stranger.id},
                         format="json")
        self.assertEqual(r.status_code, 404)


class KeyRequestTests(TestCase):
    def setUp(self):
        self.a, self.b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        self.ab, self.ba = pair(self.a, self.b)
        e2_keys.publish(self.a, "pkA", "kA")
        self.ca, self.cb = cl(self.a), cl(self.b)

    def test_send_to_keyless_peer_queues_silent_key_request(self):
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            r = self.ca.get(V + "/circle/keys/peer/%d" % self.ab.id).json()
        self.assertEqual(r["public_key"], "")
        self.assertTrue(r["requested"])
        sp.assert_called_once()
        args, kw = sp.call_args
        self.assertEqual(args[0], self.b)
        self.assertEqual(args[1], "key_request")
        self.assertEqual(args[2:4], ("", ""))   # silent: no title
        self.assertEqual(kw["data"]["requester_id"], self.a.id)
        # throttled: an immediate second ask sends nothing more
        with mock.patch("core.push.safe_push") as sp2:
            r = self.ca.post(V + "/circle/keys/request",
                             {"member_id": self.ab.id}, format="json").json()
        self.assertFalse(r["queued"])
        sp2.assert_not_called()
        self.assertEqual(E2KeyRequest.objects.get(
            requester=self.a, target=self.b).push_count, 1)

    def test_key_request_push_is_data_only_and_silent(self):
        from core import push
        self.assertIn("key_request", push.DATA_ONLY_KINDS)
        self.assertIn("key_ready", push.DATA_ONLY_KINDS)
        self.assertIn("key_request", push.CHANNELS)

    def test_publish_fulfils_request_and_wakes_requester(self):
        with mock.patch("core.push.safe_push", return_value=True):
            self.ca.get(V + "/circle/keys/peer/%d" % self.ab.id)
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            self.cb.post(V + "/circle/keys", {"public_key": "pkB", "key_id": "kB"},
                         format="json")
        kinds = [c.args[1] for c in sp.call_args_list]
        self.assertIn("key_ready", kinds)
        ready = [c for c in sp.call_args_list if c.args[1] == "key_ready"][0]
        self.assertEqual(ready.args[0], self.a)
        self.assertEqual(ready.kwargs["data"]["chat_id"], self.ab.id)
        self.assertIsNotNone(E2KeyRequest.objects.get(
            requester=self.a, target=self.b).fulfilled_at)
        ev = RtEvent.objects.filter(user=self.a, topic="key.published").last()
        self.assertEqual(ev.payload["chat"], "member:%d" % self.ab.id)

    def test_no_request_when_peer_has_key(self):
        e2_keys.publish(self.b, "pkB", "kB")
        with mock.patch("core.push.safe_push") as sp:
            r = self.ca.get(V + "/circle/keys/peer/%d" % self.ab.id).json()
        self.assertFalse(r["requested"])
        sp.assert_not_called()


class AcceptNeverDeadEndsTests(TestCase):
    def test_messenger_accept_requests_missing_keys(self):
        a, b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        e2_keys.publish(a, "pkA", "kA")
        ca, cb = cl(a), cl(b)
        cr = ca.post(V + "/messenger/request", {"target_id": b.id,
                                                "relation": "friend"},
                     format="json")
        self.assertEqual(cr.status_code, 201, cr.content)
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            r = cb.post(V + "/messenger/request/%d/act" % cr.json()["id"],
                        {"event": "accept"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        # B (never published) was asked silently; A already had a key.
        calls = [(c.args[0], c.args[1]) for c in sp.call_args_list]
        self.assertIn((b, "key_request"), calls)
        self.assertNotIn((a, "key_request"), calls)
        # B's chat already carries A's key (live), no edge copy needed.
        ba = CircleMember.objects.get(user=b, peer_user=a)
        m = [x for x in _rows(cb.get(V + "/circle/members").json())
             if x["id"] == ba.id][0]
        self.assertEqual(m["public_key"], "pkA")

    def test_circle_request_accept_requests_missing_keys(self):
        a, b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        ca, cb = cl(a), cl(b)
        ca.post(V + "/circle/request", {"phone": b.phone}, format="json")
        inc = CircleMember.objects.get(user=b, peer_user=a)
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            cb.post(V + "/circle/request/%d/act" % inc.id, {"event": "accept"},
                    format="json")
        targets = sorted(c.args[0].id for c in sp.call_args_list
                         if c.args[1] == "key_request")
        self.assertEqual(targets, sorted([a.id, b.id]))


class OwnerScenarioTests(TestCase):
    """Fresh B accepts and closes the app without opening My Circle.
    A texts and calls B right away -> B receives both."""

    def test_fresh_accept_then_call_and_text(self):
        a, b = mk("01710000001", "Owner"), mk("01710000002", "Abul Kashem")
        ca, cb = cl(a), cl(b)
        ca.post(V + "/circle/keys", {"public_key": "pkA", "key_id": "kA"},
                format="json")
        cr = ca.post(V + "/messenger/request", {"target_id": b.id,
                                                "relation": "friend"},
                     format="json").json()
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            cb.post(V + "/messenger/request/%d/act" % cr["id"],
                    {"event": "accept"}, format="json")
        self.assertIn("key_request", [c.args[1] for c in sp.call_args_list])
        ab = CircleMember.objects.get(user=a, peer_user=b)
        # 1) A calls immediately — no key needed for a call.
        r = ca.post(V + "/circle/%d/call" % ab.id, {"kind": "voice"},
                    format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        self.assertNotEqual(r.json().get("reason"), "key_missing")
        self.assertNotEqual(r.json().get("allowed"), False, r.json())
        # 2) A opens the chat: B has no key yet -> A's app queues the text in
        #    its outbox; the server asked B silently (throttled, already sent).
        k = ca.get(V + "/circle/keys/peer/%d" % ab.id).json()
        self.assertEqual(k["public_key"], "")
        self.assertTrue(k.get("pending"))
        # 3) B's phone gets the silent key_request push -> its background
        #    isolate publishes (no UI). A is woken (rt event + key_ready).
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            cb.post(V + "/circle/keys", {"public_key": "pkB", "key_id": "kB"},
                    format="json")
        self.assertIn((a, "key_ready"),
                      [(c.args[0], c.args[1]) for c in sp.call_args_list])
        self.assertTrue(RtEvent.objects.filter(user=a,
                                               topic="key.published").exists())
        # 4) A's outbox re-fetches the key, encrypts, sends.
        k = ca.get(V + "/circle/keys/peer/%d" % ab.id).json()
        self.assertEqual(k["public_key"], "pkB")
        r = ca.post(V + "/circle/%d/messages" % ab.id, {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": "ob-1"},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        # a retried flush is deduped (outbox may flush twice across isolates)
        r2 = ca.post(V + "/circle/%d/messages" % ab.id, {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": "ob-1"},
            format="json")
        self.assertTrue(r2.json().get("deduped"))
        # 5) B receives it.
        ba = CircleMember.objects.get(user=b, peer_user=a)
        got = cb.get(V + "/circle/%d/messages" % ba.id).json()["results"]
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["ciphertext"], "Q1Q=")
        self.assertEqual(e2_keys.pairs_missing_key(), [])


class PagingTests(TestCase):
    def setUp(self):
        self.a, self.b = mk("01710000001", "Amina"), mk("01710000002", "Bilal")
        self.ab, self.ba = pair(self.a, self.b)
        self.ca = cl(self.a)
        self.ids = []
        for i in range(30):
            sender, edge = ((self.b, self.ba) if i % 2 else (self.a, self.ab))
            x = CircleMessage.objects.create(member=edge, sender=sender,
                                             ciphertext="Q1Q=", nonce="Tg==")
            self.ids.append(x)

    def _seen_all(self):
        for x in self.ids:
            if x.sender_id == self.b.id:
                CircleReceipt.objects.create(message=x, user=self.a,
                                             seen_at=x.created_at)

    def test_no_params_is_backward_compatible(self):
        j = self.ca.get(V + "/circle/%d/messages" % self.ab.id).json()
        self.assertEqual(len(j["results"]), 30)
        self.assertNotIn("has_more", j)

    def test_newest_page_then_older(self):
        self._seen_all()
        j = self.ca.get(V + "/circle/%d/messages?limit=10" % self.ab.id).json()
        self.assertEqual([r["id"] for r in j["results"]],
                         [x.id for x in self.ids[-10:]])
        self.assertTrue(j["has_more"])
        self.assertEqual(j["unread_count"], 0)
        old = self.ca.get(V + "/circle/%d/messages?limit=10&before=%d" % (
            self.ab.id, self.ids[-10].id)).json()
        self.assertEqual([r["id"] for r in old["results"]],
                         [x.id for x in self.ids[-20:-10]])
        last = self.ca.get(V + "/circle/%d/messages?limit=10&before=%d" % (
            self.ab.id, self.ids[-20].id)).json()
        self.assertFalse(last["has_more"])

    def test_page_extends_to_first_unread(self):
        # every incoming message from index 9 on is unread (11 of them)
        for x in self.ids[:9]:
            if x.sender_id == self.b.id:
                CircleReceipt.objects.create(message=x, user=self.a,
                                             seen_at=x.created_at)
        j = self.ca.get(V + "/circle/%d/messages?limit=5" % self.ab.id).json()
        self.assertEqual(j["results"][0]["id"], self.ids[9].id)
        self.assertEqual(j["unread_count"], 11)
        self.assertTrue(j["results"][0]["unseen"])
        mine = [r for r in j["results"] if r["mine"]]
        self.assertTrue(all("unseen" not in r for r in mine))

    def test_group_paging(self):
        g = CircleGroup.objects.create(name="G", creator=self.a)
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.b)
        for _ in range(12):
            CircleMessage.objects.create(group=g, sender=self.b,
                                         ciphertext="Q1Q=", nonce="Tg==")
        j = self.ca.get(V + "/circle/groups/%d/messages?limit=4" % g.id).json()
        # all 12 unread -> the page opens at the first unread
        self.assertEqual(len(j["results"]), 12)
        self.assertEqual(j["unread_count"], 12)
        self.assertFalse(j["has_more"])


class AuditTests(TestCase):
    def test_pairs_missing_key_counts_accepted_edges_only(self):
        a, b = mk("01710000001", "A"), mk("01710000002", "B")
        ab, ba = pair(a, b)
        self.assertEqual(len(e2_keys.pairs_missing_key()), 2)
        e2_keys.publish(b, "pkB")
        self.assertEqual(e2_keys.pairs_missing_key(), [(ba.id, b.id, a.id)])
        ConnectionRequest  # imported for the scenario tests above
