"""calls95 — call RING DELIVERY >= 95 % (overall and per brand), and proof.

  * stats: caller cancels within 4 s are NOT attempts (shown apart); a late
    ack (after the call ended) is a miss; miss causes; app-version rows;
    target line; 7 / 30 days
  * daily snapshot rows + trend
  * dead token fallback: newest phone first, dead token dropped, the live
    phone still rings; no live phone -> push_error cause
  * token rotation: register(replace_token) drops the install's old row
  * caller: Calling until the phone confirms delivery, then Ringing
  * app version stamped at placement, refined by the native ack

Run: manage.py test core.tests_calls95 --settings=assisto_backend.settings_test
"""
import json
from datetime import timedelta

from django.utils import timezone

from core import call_ack as A
from core.models import (CallDeliveryDaily, CallHealthEvent, CallRecord,
                         CallSession, Device)
from core.tests_ring_everywhere import _RingBase, _ring_payloads

V = "/api/v1"


class _Calls95(_RingBase):
    def finish(self, cid, after_s=10, how="cancel"):
        """End a call as if it rang `after_s` seconds."""
        self.age(cid, after_s)
        self.ev(self.ca, cid, how)

    def sess(self, cid):
        return CallSession.objects.get(call_id=cid)


class StatsExclusionTests(_Calls95):
    def test_early_caller_cancel_is_shown_apart_not_in_rate(self):
        Device.objects.filter(user=self.b).update(
            brand="realme", model="RMX3195", sdk_int=33,
            app_version="1.0.244+10244")
        c1 = self.place()["call_id"]               # hung up at once
        self.ev(self.ca, c1, "cancel")
        c2 = self.place()["call_id"]               # delivered
        self.ack(c2, "delivered", brand="realme", model="RMX3195", sdk=33)
        self.finish(c2)
        c3 = self.place()["call_id"]               # rang 10 s, never acked
        self.finish(c3)
        st = A.delivery_stats()
        self.assertEqual(st["early_cancels"], 1)
        self.assertEqual((st["attempts"], st["delivered"], st["pct"]), (2, 1, 50))
        self.assertTrue(st["below"])
        self.assertEqual(st["target"], 95)
        self.assertEqual(st["brands_below"], ["realme"])
        b = st["brands"][0]
        self.assertEqual((b["brand"], b["problem"], b["below"]),
                         ("realme", True, True))
        self.assertEqual(st["causes"], [{"cause": "offline", "count": 1}])

    def test_ack_after_the_call_ended_is_a_miss(self):
        cid = self.place()["call_id"]
        self.finish(cid)
        self.ack(cid, "delivered")       # the push only arrived now
        st = A.delivery_stats()
        self.assertEqual((st["attempts"], st["delivered"]), (1, 0))
        self.assertEqual(st["causes"], [{"cause": "late_ack", "count": 1}])

    def test_old_build_and_woke_late_causes(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.222+10222")
        c1 = self.place()["call_id"]
        self.finish(c1)
        Device.objects.filter(user=self.b).update(app_version="1.0.244+10244")
        c2 = self.place()["call_id"]
        self.finish(c2)
        CallSession.objects.filter(call_id=c2).update(
            callee_seen_at=timezone.now() + timedelta(seconds=60))
        causes = {c["cause"]: c["count"] for c in A.delivery_stats()["causes"]}
        self.assertEqual(causes, {"old_build": 1, "woke_late": 1})
        apps = {a["app"]: (a["attempts"], a["native_ack"])
                for a in A.delivery_stats()["apps"]}
        # the version AT CALL TIME (stamped at placement), not today's
        self.assertEqual(apps, {"1.0.222+10222": (1, False),
                                "1.0.244+10244": (1, True)})

    def test_live_unacked_call_not_judged_and_30_day_window(self):
        self.place()
        self.assertEqual(A.delivery_stats()["attempts"], 0)
        cid = CallRecord.objects.latest("id").id
        self.finish(cid)
        CallRecord.objects.filter(pk=cid).update(
            started_at=timezone.now() - timedelta(days=12))
        self.assertEqual(A.delivery_stats(24 * 7)["attempts"], 0)
        st = A.delivery_stats(24 * 30)
        self.assertEqual((st["attempts"], st["days"]), (1, 30))


class AppVersionStampTests(_Calls95):
    def test_placement_stamps_then_ack_refines(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.240+10240")
        cid = self.place()["call_id"]
        self.assertEqual(self.sess(cid).callee_app, "1.0.240+10240")
        self.ack(cid, "delivered", app="1.0.244+10244")
        self.assertEqual(self.sess(cid).callee_app, "1.0.244+10244")
        self.assertEqual(A.app_build("1.0.244+10244"), 10244)
        self.assertEqual(A.app_build(""), 0)
        self.assertEqual(A.clean_app({"app": " 1.0 +x\n"}), "1.0+x")


class CallerPhaseTests(_Calls95):
    def test_calling_until_delivered_then_ringing_pushed_to_caller(self):
        cid = self.place()["call_id"]
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual((st["phase"], st["delivered"]), ("calling", False))
        self.ack(cid, "delivered")
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual((st["phase"], st["delivered"]), ("ringing", True))
        # the caller got the flip over the real-time queue (no extra poll)
        evs = self.events(self.ca, topics="call")["events"]
        self.assertIn("ringing", [e["payload"].get("phase") for e in evs
                                  if e["topic"] == "call.state"])
        # delivered -> no more resends
        self.push_age(cid, 10)
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(len(_ring_payloads(self.fake)), 1)


class _PerTokenFCM:
    """Wraps FakeFCM: tokens in `dead` answer 404 UNREGISTERED."""
    def __init__(self, inner, dead):
        self.inner, self.dead = inner, set(dead)
        self.order = []

    def __call__(self, url, body, headers):
        from core import push
        if url != push.TOKEN_URI:
            tok = json.loads(body.decode())["message"]["token"]
            self.order.append(tok)
            if tok in self.dead:
                return 404, {"error": {"status": "NOT_FOUND", "details": [
                    {"errorCode": "UNREGISTERED"}]}}
        return self.inner(url, body, headers)


class DeadTokenFallbackTests(_Calls95):
    def _wrap(self, dead):
        from unittest import mock
        from core import push
        w = _PerTokenFCM(self.fake, dead)
        p = mock.patch.object(push, "_http_post", w)
        p.start()
        self.addCleanup(p.stop)
        return w

    def test_newest_phone_first_dead_token_dropped_live_one_rings(self):
        old = timezone.now() - timedelta(days=3)
        Device.objects.filter(user=self.b, push_token="bdev").update(last_seen=old)
        Device.objects.filter(user=self.b, push_token="bdev").update(last_seen=old)
        Device.objects.create(user=self.b, push_token="bnew")
        w = self._wrap({"bdev"})
        cid = self.place()["call_id"]
        self.assertEqual(w.order[:2], ["bnew", "bdev"])
        self.assertFalse(Device.objects.filter(push_token="bdev").exists())
        s = self.sess(cid)
        self.assertTrue(s.push_sent)
        self.assertIsNotNone(s.fcm_sent_at)
        # the resend goes only to the live phone
        self.push_age(cid, A.RESEND_SCHEDULE_S[0])
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(w.order[2:], ["bnew"])

    def test_every_token_dead_logs_push_error_cause(self):
        self._wrap({"bdev"})
        self.online(self.b)                 # reachable by the in-app poll
        cid = self.place()["call_id"]
        self.assertTrue(CallHealthEvent.objects.filter(
            call_id=cid, step="push", code="send_fail").exists())
        # judged as push_error if it had counted as a push attempt
        CallSession.objects.filter(call_id=cid).update(push_sent=True)
        self.finish(cid)
        causes = {c["cause"] for c in A.delivery_stats()["causes"]}
        self.assertEqual(causes, {"push_error"})


class TokenRotationTests(_Calls95):
    def test_replace_token_drops_the_installs_old_row(self):
        r = self.cb.post(f"{V}/devices/register",
                         {"push_token": "bdev2", "replace_token": "bdev",
                          "app_version": "1.0.244+10244"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        toks = set(Device.objects.filter(user=self.b)
                   .values_list("push_token", flat=True))
        self.assertEqual(toks, {"bdev2"})

    def test_replace_token_never_touches_another_account(self):
        Device.objects.create(user=self.a, push_token="a-tok")
        self.cb.post(f"{V}/devices/register",
                     {"push_token": "bdev2", "replace_token": "a-tok"},
                     format="json")
        self.assertTrue(Device.objects.filter(user=self.a,
                                              push_token="a-tok").exists())

    def test_same_token_again_is_kept(self):
        self.cb.post(f"{V}/devices/register",
                     {"push_token": "bdev", "replace_token": "bdev"},
                     format="json")
        self.assertTrue(Device.objects.filter(user=self.b,
                                              push_token="bdev").exists())


class DailySnapshotTests(_Calls95):
    def test_snapshot_rows_and_trend(self):
        c1 = self.place()["call_id"]
        self.ack(c1, "ringing", brand="vivo", model="Y21", sdk=31)
        self.finish(c1)
        c2 = self.place()["call_id"]
        self.finish(c2)
        c3 = self.place()["call_id"]
        self.ev(self.ca, c3, "cancel")              # early: apart
        n = A.snapshot_days(3)
        self.assertGreaterEqual(n, 1)
        row = CallDeliveryDaily.objects.get(date=timezone.localdate())
        self.assertEqual((row.attempts, row.delivered, row.early_cancels),
                         (2, 1, 1))
        self.assertEqual(row.by_brand["vivo"], [1, 1])
        self.assertEqual(row.causes, {"offline": 1})
        # idempotent; today is re-written, no duplicates
        A.snapshot_days(3)
        self.assertEqual(CallDeliveryDaily.objects.count(), 1)
        tr = A.trend(30)
        self.assertEqual(len(tr), 1)
        self.assertEqual((tr[0]["pct"], tr[0]["below"]), (50, True))

    def test_management_command(self):
        from io import StringIO
        from django.core.management import call_command
        out = StringIO()
        call_command("calls_delivery_snapshot", "--days", "2", stdout=out)
        self.assertIn("calls_delivery_snapshot", out.getvalue())


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerCalls95PanelTests(OwnerBase):
    def test_target_period_switch_and_trend(self):
        self.ready()
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, "Goal: at least 95% overall and for every brand.")
        self.assertContains(r, "Last 30 days")
        r = self.c.get("/owner/calls?lang=en&rd=30")
        self.assertContains(r, "Ring delivery by phone (last 30 days)")
        r = self.c.get("/owner/calls?lang=bn&rd=30")
        self.assertContains(r, "ফোন অনুযায়ী রিং পৌঁছানো (গত ৩০ দিন)")
        self.assertContains(r, "লক্ষ্য: মোট এবং প্রতিটি ব্র্যান্ডে কমপক্ষে ৯৫%")
