"""sosat — SOS triggers without opening the app (lock-screen button, power
button x5), the EXPERIMENTAL fall alert held by the server for "I'm OK", the
SOS escalation ladder (re-ring once, honest next step) — and all of it free
on every plan (core/sos_triggers.py, core/family_alerts.py,
core/logic/sos_ladder.py)."""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_alerts as FA
from core import sos_triggers as ST
from core.logic import sos_ladder as L
from core.models import (AntiTheftEvent, CircleMember, FamilyAlertDelivery,
                         User)

V = "/api/v1"
PIN = "2468"


class LadderLogicTests(SimpleTestCase):
    def test_stages_in_order(self):
        sent = [{"status": "sent", "received": False, "seen": False}]
        self.assertEqual(L.stage(sent, None), "none")
        self.assertEqual(L.stage(sent, L.LADDER_WINDOW_S + 1), "none")
        self.assertEqual(L.stage(sent, 10), "waiting")
        self.assertEqual(L.stage(sent, L.RERING_AFTER_S), "rerung")
        self.assertEqual(L.stage(sent, L.SUGGEST_999_AFTER_S), "call_999")
        seen = [dict(sent[0], seen=True)]
        self.assertEqual(L.stage(seen, L.SUGGEST_999_AFTER_S), "seen")
        self.assertEqual(L.stage(sent, 10, resolved=True), "resolved")

    def test_nobody_reachable_is_said_at_once(self):
        self.assertEqual(L.stage([], 5), "no_one")
        self.assertEqual(L.stage([{"status": "no_device"}], 5), "no_one")
        self.assertEqual(L.stage([{"status": "push_off"}], 5), "no_one")
        # a phone that acknowledged the push is reachable whatever the status
        self.assertEqual(L.stage([{"status": "failed", "received": True}], 5),
                         "waiting")

    def test_counts_and_rering_rule(self):
        rs = [{"received": True}, {"seen": True}, {}]
        self.assertEqual(L.counts(rs), {"total": 3, "received": 2, "seen": 1})
        self.assertTrue(L.needs_rering("sent", False, L.RERING_AFTER_S, False))
        self.assertFalse(L.needs_rering("sent", True, 200, False))
        self.assertFalse(L.needs_rering("sent", False, 200, True))
        self.assertFalse(L.needs_rering("sent", False, 30, False))
        self.assertFalse(L.needs_rering("held", False, 200, False))


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "bbn": bbn, "ben": ben, "data": dict(data or {})})
        return True

    def to(self, u, kind=None):
        return [c for c in self.calls if c["user"] == u.pk and
                (kind is None or c["kind"] == kind)]


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang, email="%s@sosat.test" % phone)


def pair(a, b):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                sharing={"location": False})
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming")


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01712200001", "Rina")
        self.b = mk("01712200002", "Ma", lang="bn")
        self.c = mk("01712200003", "Bhai")
        pair(self.a, self.b)
        pair(self.a, self.c)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)
        self.ca = APIClient()
        self.ca.force_authenticate(self.a)
        self.ca.post("%s/security/pin/set" % V, {"new_pin": PIN}, format="json")
        r = self.ca.post("%s/security/engine/enable" % V, {"pin": PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.token = r.data["engine_token"]
        self.spy.calls.clear()     # drop the "protection on" pushes

    def ingest(self, items):
        return self.ca.post("%s/security/engine/ingest" % V,
                            {"items": items, "sent_at": timezone.now().isoformat()},
                            format="json", HTTP_X_ASSISTO_ENGINE=self.token)

    def ev(self, cid):
        return AntiTheftEvent.objects.get(phone__owner=self.a, client_id=cid)


class LockscreenAndPowerSosTests(Base):
    def test_lockscreen_sos_rings_every_circle_member_full_screen(self):
        r = self.ingest([{"id": "ls1", "kind": "sos_lockscreen",
                          "at": timezone.now().isoformat(),
                          "lat": 23.75, "lng": 90.39}])
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("ls1", r.data["accepted"])
        for u in (self.b, self.c):
            calls = self.spy.to(u, "sos")
            self.assertEqual(len(calls), 1, u.name)
            self.assertEqual(calls[0]["data"]["source"], "sos_lockscreen")
            # SOS location goes to everyone (pressing SOS is the consent)
            self.assertEqual(calls[0]["data"]["lat"], 23.75)
        e = self.ev("ls1")
        self.assertTrue(e.alerted)
        self.assertEqual(e.recipients, 2)
        self.assertEqual(e.data["sos"], "sent")

    def test_retry_of_the_same_press_never_rings_twice(self):
        item = {"id": "pw1", "kind": "sos_power", "at": timezone.now().isoformat()}
        self.ingest([item])
        r = self.ingest([item])
        self.assertIn("pw1", r.data["duplicate"])
        self.assertEqual(len(self.spy.to(self.b, "sos")), 1)

    def test_hours_old_trigger_is_kept_but_not_rung_as_live(self):
        old = (timezone.now() - timedelta(hours=3)).isoformat()
        self.ingest([{"id": "old1", "kind": "sos_power", "at": old}])
        self.assertEqual(self.spy.to(self.b, "sos"), [])
        self.assertEqual(self.ev("old1").data["sos"], "too_late")

    def test_trigger_never_goes_through_the_generic_theft_alert(self):
        self.ingest([{"id": "ls2", "kind": "sos_lockscreen",
                      "at": timezone.now().isoformat()}])
        kinds = {c["kind"] for c in self.spy.calls}
        self.assertEqual(kinds, {"sos"})


class FallTests(Base):
    def _fall(self, cid="f1", ago_s=0, window=60, **data):
        d = {"confirm": "pending", "window_s": window}
        d.update(data)
        return self.ingest([{"id": cid, "kind": "fall",
                             "at": (timezone.now() - timedelta(seconds=ago_s)).isoformat(),
                             "lat": 23.8, "lng": 90.4, "data": d}])

    def test_fall_is_held_then_escalated_once_by_the_server(self):
        self._fall()
        self.assertEqual(self.spy.calls, [])          # nobody yet
        e = self.ev("f1")
        self.assertFalse(e.alerted)
        self.assertIsNotNone(e.escalate_at)
        later = timezone.now() + timedelta(seconds=61)
        self.assertEqual(ST.escalate_due(later), 1)
        self.assertEqual(ST.escalate_due(later), 0)    # never twice
        for u in (self.b, self.c):
            calls = self.spy.to(u, "sos")              # full-screen kind
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["data"]["alert_kind"], "fall")
            # fall opt-in consent covers location even without sharing
            self.assertEqual(calls[0]["data"]["lat"], 23.8)
        self.assertIn("may have fallen", self.spy.to(self.c)[0]["ten"])
        self.assertIn("পড়ে গেছেন", self.spy.to(self.b)[0]["tbn"])
        self.assertIn("১", self.spy.to(self.b)[0]["bbn"])   # Bangla digits
        e = self.ev("f1")
        self.assertTrue(e.alerted)
        self.assertEqual(e.data["confirm"], "timeout")

    def test_im_ok_from_the_phone_cancels(self):
        self._fall()
        self.ingest([{"id": "ok1", "kind": "fall_ok",
                      "at": timezone.now().isoformat(), "data": {"ref": "f1"}}])
        self.assertEqual(ST.escalate_due(timezone.now() + timedelta(minutes=5)), 0)
        self.assertEqual(self.spy.calls, [])
        self.assertEqual(self.ev("f1").data["confirm"], "ok")

    def test_im_ok_from_the_app_cancels(self):
        self._fall()
        r = self.ca.get("%s/family/fall/pending" % V)
        self.assertEqual(r.data["pending"]["client_id"], "f1")
        self.assertGreater(r.data["pending"]["seconds_left"], 0)
        r = self.ca.post("%s/family/fall/ok" % V, {}, format="json")
        self.assertEqual(r.data["cancelled"], 1)
        self.assertIsNone(self.ca.get("%s/family/fall/pending" % V).data["pending"])
        self.assertEqual(ST.escalate_due(timezone.now() + timedelta(minutes=5)), 0)
        self.assertEqual(self.spy.calls, [])

    def test_answered_before_upload_never_alerts(self):
        self._fall(cid="f2", confirm="ok")
        self.assertEqual(ST.escalate_due(timezone.now() + timedelta(minutes=5)), 0)
        self.assertEqual(self.spy.calls, [])

    def test_window_is_clamped_and_late_upload_escalates_at_once(self):
        self._fall(cid="f3", window=5)
        self.assertEqual(self.ev("f3").data["window_s"], ST.FALL_WINDOW_MIN_S)
        # phone was offline for 2 minutes after a 60 s window: alert now
        self._fall(cid="f4", ago_s=120, window=60)
        self.assertTrue(self.ev("f4").alerted)
        self.assertEqual(len(self.spy.to(self.b, "sos")), 1)

    def test_hours_old_fall_is_history_not_an_alarm(self):
        self._fall(cid="f5", ago_s=3 * 3600)
        self.assertEqual(self.spy.calls, [])
        self.assertEqual(self.ev("f5").data["fall"], "too_late")

    def test_cron_backstop_escalates_falls(self):
        self._fall(cid="f6", window=30)
        AntiTheftEvent.objects.filter(client_id="f6").update(
            escalate_at=timezone.now() - timedelta(seconds=1))
        call_command("antitheft_escalate", stdout=StringIO())
        self.assertEqual(len(self.spy.to(self.b, "sos")), 1)


class LadderTests(Base):
    def sos(self):
        r = self.ca.post("%s/family/sos" % V, {"source": "emergency",
                                              "client_id": "x1"}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_ladder_endpoint_walks_the_stages(self):
        self.assertEqual(self.ca.get("%s/family/sos/ladder" % V).data["stage"], "none")
        self.sos()
        r = self.ca.get("%s/family/sos/ladder" % V).data
        self.assertEqual(r["stage"], "waiting")
        self.assertEqual(r["total"], 2)
        now = timezone.now()
        self.assertEqual(FA.ladder(self.a, now + timedelta(seconds=130))["stage"],
                         "rerung")
        self.assertEqual(FA.ladder(self.a, now + timedelta(seconds=301))["stage"],
                         "call_999")
        d = FamilyAlertDelivery.objects.get(recipient=self.b, kind="sos")
        FA.mark_seen(self.b, d.id)
        r = self.ca.get("%s/family/sos/ladder" % V).data
        self.assertEqual(r["stage"], "seen")
        self.assertEqual(r["seen"], 1)
        self.ca.post("%s/family/sos/resolve" % V, {}, format="json")
        self.assertEqual(self.ca.get("%s/family/sos/ladder" % V).data["stage"],
                         "resolved")

    def test_nobody_in_circle_says_no_one(self):
        CircleMember.objects.filter(user=self.a).delete()
        self.sos()
        # no delivery rows at all -> "none" would hide the failure; the SOS
        # view already says 0 recipients, and the ladder has nothing to show
        self.assertEqual(self.ca.get("%s/family/sos/ladder" % V).data["stage"], "none")

    def test_unopened_sos_is_rung_once_more_then_never_again(self):
        self.sos()
        d = FamilyAlertDelivery.objects.get(recipient=self.c, kind="sos")
        FA.mark_seen(self.c, d.id)                # Bhai opened it
        self.spy.calls.clear()
        later = timezone.now() + timedelta(seconds=L.RERING_AFTER_S + 5)
        st = FA.sweep(later, {})
        self.assertEqual(st.get("family_rerung"), 1)
        again = self.spy.to(self.b, "sos")
        self.assertEqual(len(again), 1)
        self.assertIn("এখনো কেউ সাড়া দেননি", again[0]["tbn"])
        self.assertTrue(again[0]["data"]["rering"])
        self.assertEqual(self.spy.to(self.c), [])  # who saw it is not rung
        FA.sweep(later + timedelta(seconds=60), {})
        self.assertEqual(len(self.spy.to(self.b, "sos")), 1)

    def test_no_rering_after_im_safe_or_after_leaving_the_circle(self):
        self.sos()
        self.ca.post("%s/family/sos/resolve" % V, {}, format="json")
        self.spy.calls.clear()
        FA.sweep(timezone.now() + timedelta(seconds=200), {})
        self.assertEqual(self.spy.to(self.b, "sos"), [])
        # a fresh SOS, then Ma leaves the circle
        self.ca.post("%s/family/sos" % V, {"client_id": "x2"}, format="json")
        CircleMember.objects.filter(user=self.a, peer_user=self.b).delete()
        self.spy.calls.clear()
        FA.sweep(timezone.now() + timedelta(seconds=200), {})
        self.assertEqual(self.spy.to(self.b), [])


class SafetyFreeOnEveryPlanTests(Base):
    PLANS = ("free", "plus", "premium", "premium_pro", "business", "probashi")

    def test_triggers_fall_and_ladder_cost_nothing_on_any_plan(self):
        for i, plan in enumerate(self.PLANS):
            self.a.plan = plan
            self.a.plan_until = None if plan == "free" else (
                timezone.now() + timedelta(days=30))
            self.a.ai_credits = 0
            self.a.save()
            self.spy.calls.clear()
            r = self.ingest([
                {"id": "ls-%d" % i, "kind": "sos_lockscreen",
                 "at": timezone.now().isoformat()},
                {"id": "fa-%d" % i, "kind": "fall", "at": timezone.now().isoformat(),
                 "data": {"confirm": "pending", "window_s": 30}}])
            self.assertEqual(r.status_code, 200, (plan, r.content))
            self.assertEqual(len(self.spy.to(self.b, "sos")), 1, plan)
            ST.escalate_due(timezone.now() + timedelta(seconds=31))
            self.assertEqual(len(self.spy.to(self.b, "sos")), 2, plan)
            self.assertEqual(self.ca.get("%s/family/sos/ladder" % V).status_code,
                             200, plan)
            self.assertEqual(self.ca.post("%s/family/fall/ok" % V, {},
                                          format="json").status_code, 200, plan)
            self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, 0, plan)
