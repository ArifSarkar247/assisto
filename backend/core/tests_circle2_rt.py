"""circle2 — rt/events efficiency + call relay reliability.

* An EMPTY poll (the common case: nothing new, no live call) no longer runs
  the "newest seq" query nor the CallRecord sweep query; the numbers are
  printed so CI logs carry the before/after measurement.
* A call placed after a cached "no live call" is still swept / seen on the
  very next poll (post_save forgets the cache).
* A filtered poll still returns the true newest seq.
* The signal budget counts only THIS call's two parties (index-scoped).
* calls_sweep also prunes every user's old real-time rows (phones that stopped
  polling used to keep theirs forever).

No push / network: FCM settings are blank (PUSH_SYNC) like tests_c2_calls.
"""
from datetime import timedelta
from io import StringIO

from django.core.cache import cache
from django.core.management import call_command
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from core import views_c2_calls as C2
from core.models import CallRecord, RtEvent, User
from core.tests_c2_calls import V, _Pair


def _sqls(ctx):
    return [q["sql"] for q in ctx.captured_queries]


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class RtEmptyPollTests(_Pair, TestCase):
    def setUp(self):
        cache.clear()
        self.mk()

    def test_empty_poll_skips_latest_and_sweep_queries(self):
        first = self.events(self.ca, after=0)          # warms presence + nolive
        self.assertEqual(first["events"], [])
        with CaptureQueriesContext(connection) as ctx:
            body = self.events(self.ca, after=first["seq"])
        sqls = _sqls(ctx)
        self.assertEqual(body["events"], [])
        self.assertEqual(body["seq"], first["seq"])
        call_q = [s for s in sqls if "core_callrecord" in s]
        desc_q = [s for s in sqls if "core_rtevent" in s and "DESC" in s.upper()]
        print("circle2 measure: empty rt/events poll = %d queries "
              "(callrecord=%d, newest-seq=%d)" % (len(sqls), len(call_q), len(desc_q)))
        self.assertEqual(call_q, [], "no live call -> no CallRecord query")
        self.assertEqual(desc_q, [], "unfiltered empty poll -> no newest-seq query")
        rt_q = [s for s in sqls if "core_rtevent" in s]
        self.assertEqual(len(rt_q), 1, sqls)

    def test_new_events_seq_is_last_row(self):
        a = C2.rt_publish(self.a, "typing.update", {"chat": "member:1"})
        b = C2.rt_publish(self.a, "presence.update", {"chat": "member:1"})
        body = self.events(self.ca, after=0)
        self.assertEqual([e["seq"] for e in body["events"]], [a, b])
        self.assertEqual(body["seq"], b)
        again = self.events(self.ca, after=b)
        self.assertEqual(again["events"], [])
        self.assertEqual(again["seq"], b)

    def test_filtered_poll_still_reports_true_newest_seq(self):
        C2.rt_publish(self.a, "call.state", {"call_id": 1})
        last = C2.rt_publish(self.a, "typing.update", {"chat": "member:1"})
        body = self.events(self.ca, after=0, topics="call")
        self.assertEqual(len(body["events"]), 1)
        self.assertEqual(body["seq"], last, "phone may skip past other topics")

    def test_call_placed_after_cached_nolive_is_swept_next_poll(self):
        self.online(self.b)
        self.events(self.ca)        # A: no live call -> remembered
        self.events(self.cb)        # B too
        self.assertIsNotNone(cache.get(C2._nolive_key(self.a.pk)))
        placed = self.place()       # CallRecord saved -> forgotten
        self.assertIsNone(cache.get(C2._nolive_key(self.a.pk)))
        self.assertIsNone(cache.get(C2._nolive_key(self.b.pk)))
        cid = placed["call_id"]
        # ring window long gone: the next poll's sweep must end it
        rec = CallRecord.objects.get(pk=cid)
        rec.started_at = timezone.now() - timedelta(seconds=120)
        rec.save()
        self.events(self.ca)
        rec.refresh_from_db()
        self.assertNotIn(rec.state, ("ringing", "connecting", "active",
                                     "reconnecting"))

    def test_live_call_marks_seen_every_poll(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        sess = CallRecord.objects.get(pk=cid).session
        sess.caller_seen_at = timezone.now() - timedelta(seconds=10)
        sess.save()
        self.events(self.ca)
        sess.refresh_from_db()
        self.assertGreater(sess.caller_seen_at,
                           timezone.now() - timedelta(seconds=3))
        self.assertIsNone(cache.get(C2._nolive_key(self.a.pk)),
                          "a user in a live call is never cached as idle")


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class RtSignalBudgetTests(_Pair, TestCase):
    def setUp(self):
        cache.clear()
        self.mk()

    def test_signal_count_is_scoped_to_the_two_parties(self):
        self.online(self.b)
        cid = self.place()["call_id"]
        with CaptureQueriesContext(connection) as ctx:
            r = self.signal(self.ca, cid, "ice", {"candidate": "c1"})
        self.assertEqual(r.status_code, 201, r.content)
        counts = [s for s in _sqls(ctx)
                  if "COUNT" in s.upper() and "core_rtevent" in s]
        self.assertTrue(counts, _sqls(ctx))
        self.assertIn("user_id", counts[0])
        # the relayed candidate reached B
        ev = [e for e in self.events(self.cb)["events"]
              if e["topic"] == "call.signal"]
        self.assertTrue(any(e["payload"].get("kind") == "ice" for e in ev))


class RtPruneTests(TestCase):
    def test_prune_events_deletes_old_rows_of_every_user(self):
        u1 = User.objects.create_user(name="P1", phone="01740000901",
                                      password="pw12345!")
        u2 = User.objects.create_user(name="P2", phone="01740000902",
                                      password="pw12345!")
        old = timezone.now() - timedelta(seconds=C2.RT_RETAIN_S + 60)
        for u in (u1, u2):
            e = RtEvent.objects.create(user=u, topic="badges.update", payload={})
            RtEvent.objects.filter(pk=e.pk).update(created_at=old)
        keep = RtEvent.objects.create(user=u1, topic="typing.update", payload={})
        self.assertEqual(C2.prune_events(), 2)
        self.assertEqual(list(RtEvent.objects.values_list("pk", flat=True)),
                         [keep.pk])

    def test_calls_sweep_command_prunes(self):
        u = User.objects.create_user(name="P3", phone="01740000903",
                                     password="pw12345!")
        e = RtEvent.objects.create(user=u, topic="badges.update", payload={})
        RtEvent.objects.filter(pk=e.pk).update(
            created_at=timezone.now() - timedelta(hours=2))
        out = StringIO()
        call_command("calls_sweep", stdout=out)
        self.assertFalse(RtEvent.objects.filter(pk=e.pk).exists())
        self.assertIn("pruned 1", out.getvalue())
