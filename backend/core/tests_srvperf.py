"""srvperf — server p95 regressions (owner order D: p95 < 300 ms).

  * the 1:1 conversation lookup is `member_id IN (...)` (index) and returns
    EXACTLY the rows the old OR-over-JOIN filter returned (mirror edges,
    phone-matched reverse edge, self edges, other people's chats excluded);
  * POST circle/receipts/sync does a CONSTANT number of queries however many
    chats the user has, and one bulk UPDATE instead of one save per message;
  * hot endpoints stay under a query ceiling (seeded heavy user);
  * rt/events prunes old events at most once a minute per user, not on
    every 0.5-5 s poll.

Run: manage.py test core.tests_srvperf --settings=assisto_backend.settings_test
"""
from datetime import timedelta

from django.db import connection
from django.db.models import Q
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient

from core import perf_seed as S
from core.models import (CircleGroupMember, CircleMember, CircleMessage,
                         CircleReceipt, RtEvent, User)
from core.views_m1_messenger import (conversation_edge_ids,
                                     conversation_edge_map, conversation_rows,
                                     reverse_edge)

V = "/api/v1"


def old_conversation_ids(edge):
    """The pre-srvperf filter, verbatim (reference for equivalence)."""
    q = Q(member=edge)
    if getattr(edge, "peer_user_id", None):
        q |= Q(member__user_id=edge.peer_user_id,
               member__peer_user_id=edge.user_id)
    rev = reverse_edge(edge)
    if rev is not None:
        q |= Q(member=rev)
    return set(CircleMessage.objects.filter(q, group=None)
               .values_list("id", flat=True))


def client(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def nq(fn):
    with CaptureQueriesContext(connection) as q:
        r = fn()
    return r, len(q)


class ConversationRowsEquivalence(TestCase):
    def test_same_rows_as_the_old_filter(self):
        a = User.objects.create_user(name="A", phone="01711111101", password="x")
        b = User.objects.create_user(name="B", phone="01711111102", password="x")
        c = User.objects.create_user(name="C", phone="01711111103", password="x")
        d = User.objects.create_user(name="D", phone="01711111104", password="x")
        ab = CircleMember.objects.create(user=a, peer_user=b, state="accepted",
                                         phone=b.phone)
        ba = CircleMember.objects.create(user=b, peer_user=a, state="accepted",
                                         phone=a.phone, direction="incoming")
        # phone-matched reverse edge (no peer_user on the c->a side)
        ac = CircleMember.objects.create(user=a, peer_user=c, state="accepted",
                                         phone=c.phone)
        ca = CircleMember.objects.create(user=c, state="accepted",
                                         phone=a.phone)
        # a phone-only edge a->d (no account link) and an unrelated chat
        ad = CircleMember.objects.create(user=a, state="pending",
                                         phone=d.phone)
        bc = CircleMember.objects.create(user=b, peer_user=c, state="accepted",
                                         phone=c.phone)
        for e, s in ((ab, a), (ba, b), (ac, a), (ca, c), (ad, a), (bc, b),
                     (ab, a), (ca, c)):
            CircleMessage.objects.create(member=e, sender=s, ciphertext="x")
        for e in (ab, ba, ac, ca, ad, bc):
            new = set(conversation_rows(e).values_list("id", flat=True))
            self.assertEqual(new, old_conversation_ids(e), e)
        # batched map == per-edge ids
        mine = list(CircleMember.objects.filter(user=a))
        emap = conversation_edge_map(a, mine)
        for e in mine:
            self.assertEqual(emap[e.id], conversation_edge_ids(e))
        self.assertEqual(emap[ab.id], {ab.id, ba.id})
        self.assertEqual(emap[ac.id], {ac.id, ca.id})


class ReceiptsSyncScales(TestCase):
    def _world(self, peers, msgs=6):
        us = S.make_users(peers + 1)
        users = [u for u, _ in us]
        S.seed_world(users, peers=peers, msgs=msgs, groups=2, group_size=4,
                     group_msgs=8, reminders=1, txns=1)
        return users[0]

    def _reset(self):
        CircleReceipt.objects.all().delete()
        User.objects.all().delete()

    def test_queries_do_not_grow_with_messages(self):
        """4x the messages per chat: the same queries (bulk receipts + one
        bulk UPDATE; was one save() per message)."""
        me = self._world(8, msgs=4)
        _, few = nq(lambda: client(me).post(V + "/circle/receipts/sync"))
        self._reset()
        me = self._world(8, msgs=16)
        r, many = nq(lambda: client(me).post(V + "/circle/receipts/sync"))
        self.assertEqual(r.status_code, 200)
        self.assertLessEqual(many, few + 4, (few, many))

    def test_chats_cost_only_their_realtime_event(self):
        """4x the chats: no per-chat lookups any more — only the one
        `receipt.update` event per chat to its sender (insert + savepoint)."""
        me = self._world(4)
        _, small = nq(lambda: client(me).post(V + "/circle/receipts/sync"))
        self._reset()
        me = self._world(16)
        r, big = nq(lambda: client(me).post(V + "/circle/receipts/sync"))
        self.assertEqual(r.status_code, 200)
        self.assertGreater(r.json()["updated"], 40)
        self.assertLessEqual(big, small + 4 * 12 + 8, (small, big))

    def test_steady_state_sync_is_constant(self):
        me = self._world(4)
        c = client(me)
        c.post(V + "/circle/receipts/sync")
        _, small = nq(lambda: c.post(V + "/circle/receipts/sync"))
        self._reset()
        me = self._world(16)
        c = client(me)
        c.post(V + "/circle/receipts/sync")
        _, big = nq(lambda: c.post(V + "/circle/receipts/sync"))
        self.assertLessEqual(big, small + 1, (small, big))
        self.assertLessEqual(big, 8)

    def test_marks_every_incoming_message_delivered(self):
        me = self._world(6)
        r = client(me).post(V + "/circle/receipts/sync")
        self.assertEqual(r.status_code, 200)
        edge_ids = set()
        for v in conversation_edge_map(
                me, CircleMember.objects.filter(user=me)).values():
            edge_ids |= v
        incoming = CircleMessage.objects.filter(
            member_id__in=edge_ids, group=None).exclude(sender=me)
        gids = CircleGroupMember.objects.filter(member=me).values_list(
            "group_id", flat=True)
        incoming_g = CircleMessage.objects.filter(group_id__in=gids).exclude(
            sender=me)
        n = incoming.count() + incoming_g.count()
        self.assertEqual(r.json()["updated"], n)
        self.assertEqual(CircleReceipt.objects.filter(
            user=me, delivered_at__isnull=False).count(), n)
        for x in list(incoming) + list(incoming_g):
            self.assertIn(me.id, x.delivered_to)
        # idempotent: a second sync changes nothing
        self.assertEqual(client(me).post(
            V + "/circle/receipts/sync").json()["updated"], 0)


class HotEndpointCeilings(TestCase):
    """Query ceilings for the endpoints the app polls (seeded heavy user:
    12 chats x 10 messages, 3 groups). Ceilings are deliberately a little
    above today's count — a regression that adds a per-chat or per-message
    query blows straight through them."""

    @classmethod
    def setUpTestData(cls):
        us = S.make_users(13)
        cls.users = [u for u, _ in us]
        S.seed_world(cls.users, peers=12, msgs=10, groups=3, group_size=5,
                     group_msgs=10)
        cls.me = cls.users[0]

    CEIL = {
        ("get", "/circle/calls/incoming"): 8,
        ("get", "/rt/events?after=0&online=1"): 16,
        ("get", "/health"): 2,
        ("post", "/circle/receipts/sync"): 30,
        ("post", "/devices/register"): 18,
    }

    def test_ceilings(self):
        c = client(self.me)
        c.post(V + "/circle/receipts/sync")   # steady state first
        for (m, path), ceil in self.CEIL.items():
            body = ({"push_token": "tok-srvperf", "platform": "android",
                     "app_version": "1.0.255"} if "devices" in path else {})
            r, n = nq(lambda: getattr(c, m)(V + path, body, format="json")
                      if m == "post" else c.get(V + path))
            self.assertLess(r.status_code, 300, path)
            self.assertLessEqual(n, ceil, "%s %s: %d queries" % (m, path, n))

    def test_badges_and_chat_list_do_not_grow_per_message(self):
        c = client(self.me)
        c.post(V + "/circle/receipts/sync")
        _, b1 = nq(lambda: c.get(V + "/home/badges"))
        _, l1 = nq(lambda: c.get(V + "/circle/chats"))
        # 5 more messages in every chat: same query count
        rows = []
        for e in CircleMember.objects.filter(user=self.me):
            for k in range(5):
                rows.append(CircleMessage(member=e, sender_id=e.peer_user_id,
                                          ciphertext="x"))
        CircleMessage.objects.bulk_create(rows)
        _, b2 = nq(lambda: c.get(V + "/home/badges"))
        r, l2 = nq(lambda: c.get(V + "/circle/chats"))
        self.assertEqual(r.status_code, 200)
        self.assertLessEqual(b2, b1 + 2, (b1, b2))
        # the chat list marks the new messages delivered (bulk, constant)
        self.assertLessEqual(l2, l1 + 8, (l1, l2))


class RtPrune(TestCase):
    def test_prune_runs_at_most_once_a_minute(self):
        from django.core.cache import cache
        from core import views_c2_calls as C2
        cache.clear()
        u = User.objects.create_user(name="P", phone="01711111199", password="x")
        old = RtEvent.objects.create(user=u, topic="x", payload={})
        RtEvent.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - timedelta(seconds=C2.RT_RETAIN_S + 60))
        c = client(u)
        c.get(V + "/rt/events?after=0")
        self.assertFalse(RtEvent.objects.filter(pk=old.pk).exists())
        old2 = RtEvent.objects.create(user=u, topic="x", payload={})
        RtEvent.objects.filter(pk=old2.pk).update(
            created_at=timezone.now() - timedelta(seconds=C2.RT_RETAIN_S + 60))
        c.get(V + "/rt/events?after=0")
        # inside the minute: no DELETE issued (the row stays until the next)
        self.assertTrue(RtEvent.objects.filter(pk=old2.pk).exists())


class StatusesAllEquivalence(TestCase):
    def test_batched_statuses_equal_per_sender_statuses(self):
        from core import views_c3_msg as C3
        us = S.make_users(6)
        users = [u for u, _ in us]
        S.seed_world(users, peers=4, msgs=4, groups=1, group_size=4,
                     group_msgs=6, reminders=0, txns=0)
        client(users[0]).post(V + "/circle/receipts/sync")
        client(users[1]).post(V + "/circle/receipts/sync")
        msgs = list(CircleMessage.objects.all())
        allst = C3._statuses_all(msgs)
        for u in users:
            for mid, st in C3.statuses(msgs, u).items():
                self.assertEqual(allst[mid], st, (u.id, mid))
