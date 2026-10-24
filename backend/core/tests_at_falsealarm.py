"""
at-falsealarm — the owner's own SIM was reported as a "SIM change" seconds
after switching Always-on protection on, which froze the phone for 48h and
alerted him twice. Tests for:

  * POST security/engine/false-alarm ("It was me"): PIN required (server-side,
    wrong PIN counted), clears freeze + recent theft signals, AuditLog row with
    the before-state, events marked false_alarm, engine told to re-baseline
    once, ONE all-clear to approved family and none to the owner, rate limit;
  * notify() de-duplicates recipients by user id;
  * a legacy-engine sim_change right after enabling never freezes/alerts.
"""
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core import views_antitheft as atv
from core.models import (AntiTheftEngine, AntiTheftEvent, AuditLog, CircleMember,
                         FamilyAlert, NotifEvent, ProtectedPhone, User)

URL = "/api/v1/security/engine/false-alarm"


class _Base(APITestCase):
    PIN = "2468"

    def setUp(self):
        self.owner = User.objects.create_user(
            name="Arif", phone="01710000091", password="x",
            email="fa-owner@example.com")
        self.family = User.objects.create_user(
            name="Ma", phone="01710000092", password="x",
            email="fa-family@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.family, name="Ma",
            state="accepted", direction="outgoing")
        r = self.client.post("/api/v1/security/engine/enable",
                             {"pin": self.PIN, "alert_member_ids": [self.member.id]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        # protection was switched on a while ago (outside the legacy grace)
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            enabled_at=timezone.now() - timedelta(hours=1))

    def _ingest(self, items):
        return self.client.post(
            "/api/v1/security/engine/ingest",
            {"items": items, "sent_at": timezone.now().isoformat()},
            format="json", HTTP_X_ASSISTO_ENGINE=self.token)

    def _sim_alarm(self, cid="sim-1"):
        r = self._ingest([{"id": cid, "kind": "sim_change",
                           "data": {"state": "inserted", "carrier": "GP", "v": 2}}])
        self.assertEqual(r.status_code, 200)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.frozen_until)


class FalseAlarmTests(_Base):
    def test_pin_required(self):
        self._sim_alarm()
        r = self.client.post(URL, {}, format="json")
        self.assertEqual(r.status_code, 403)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.frozen_until)

    def test_wrong_pin_counted_and_not_cleared(self):
        self._sim_alarm()
        r = self.client.post(URL, {"pin": "0000"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data.get("reason"), "bad_pin")
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.wrong_pin_count, 1)
        self.assertTrue(self.phone.frozen_until)
        self.assertFalse(AuditLog.objects.filter(
            action="antitheft.false_alarm_cleared").exists())

    def test_wrong_pin_lock_fires(self):
        self._sim_alarm()
        for _ in range(5):
            r = self.client.post(URL, {"pin": "0000"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertTrue(r.data.get("locked"))

    def test_clears_freeze_signals_audit_and_marks_events(self):
        old = (timezone.now() - timedelta(days=5)).isoformat()
        ProtectedPhone.objects.filter(pk=self.phone.pk).update(
            signals=[{"kind": "snatch", "at": old}])
        self._sim_alarm()
        r = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["cleared"], 1)
        self.phone.refresh_from_db()
        self.assertIsNone(self.phone.frozen_until)
        # the old (outside 48h) signal is kept, the recent one removed
        self.assertEqual(self.phone.signals, [{"kind": "snatch", "at": old}])
        ev = AntiTheftEvent.objects.get(phone=self.phone, kind="sim_change")
        self.assertTrue(ev.data.get("false_alarm"))
        log = AuditLog.objects.get(user=self.owner,
                                   action="antitheft.false_alarm_cleared")
        self.assertTrue(log.detail["before"]["frozen_until"])
        self.assertEqual(len(log.detail["before"]["signals"]), 2)
        self.assertEqual(log.detail["removed_signals"][0]["kind"], "sim_change")
        # state reflects it; protection can now be switched off again
        st = self.client.get("/api/v1/security/engine/state")
        self.assertFalse(st.data["frozen"])
        self.assertFalse(st.data["theft_signal"])

    def test_engine_rebaselines_once(self):
        self._sim_alarm()
        self.client.post(URL, {"pin": self.PIN}, format="json")
        r1 = self._ingest([{"id": "hb-1", "kind": "heartbeat"}])
        self.assertTrue(r1.data["config"].get("rebaseline_sim"))
        r2 = self._ingest([{"id": "hb-2", "kind": "heartbeat"}])
        self.assertNotIn("rebaseline_sim", r2.data["config"])

    def test_family_gets_one_all_clear_owner_none(self):
        self._sim_alarm()
        with mock.patch("core.push.safe_push") as sp:
            r = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["family_notified"], 1)
        users = [c.args[0].pk for c in sp.call_args_list]
        self.assertEqual(users, [self.family.pk])
        self.assertEqual(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="all_clear").count(), 1)
        self.assertFalse(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="all_clear").exists())

    def test_nothing_to_clear_is_ok_and_silent(self):
        with mock.patch("core.push.safe_push") as sp:
            r = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["cleared"], 0)
        sp.assert_not_called()

    def test_works_in_lost_mode_with_pin_only(self):
        self._sim_alarm()
        ProtectedPhone.objects.filter(pk=self.phone.pk).update(
            lost_mode=True, status="reported_stolen")
        bad = self.client.post(URL, {"pin": "1111"}, format="json")
        self.assertEqual(bad.status_code, 403)
        ok = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertEqual(ok.status_code, 200)

    def test_rate_limited(self):
        for i in range(atv.FALSE_ALARM_MAX_PER_DAY):
            AuditLog.objects.create(user=self.owner,
                                    action="antitheft.false_alarm_cleared",
                                    detail={})
        self._sim_alarm()
        r = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 429)

    def test_other_users_phone_404(self):
        other = User.objects.create_user(name="X", phone="01710000093",
                                         password="x", email="fa-x@example.com")
        p2 = ProtectedPhone.objects.create(owner=other)
        r = self.client.post(URL, {"pin": self.PIN, "phone_id": p2.id},
                             format="json")
        self.assertEqual(r.status_code, 404)

    def test_requires_auth(self):
        self.client.force_authenticate(None)
        r = self.client.post(URL, {"pin": self.PIN}, format="json")
        self.assertIn(r.status_code, (401, 403))


class NotifyDedupeTests(_Base):
    def test_owner_also_family_peer_gets_one_push(self):
        # a family member row that points back at the owner himself
        selfm = CircleMember.objects.create(
            user=self.owner, peer_user=self.owner, name="me",
            state="accepted", direction="outgoing")
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            alert_member_ids=[self.member.id, selfm.id])
        with mock.patch.object(atv, "approved_family_users",
                               return_value=[self.family, self.owner, self.family]), \
                mock.patch("core.push.safe_push") as sp:
            n = atv.notify(self.phone, "test", "t", "b", "t", "b")
        users = [c.args[0].pk for c in sp.call_args_list]
        self.assertEqual(sorted(users), sorted([self.owner.pk, self.family.pk]))
        self.assertEqual(n, 2)

    def test_family_only_skips_owner(self):
        with mock.patch.object(atv, "approved_family_users",
                               return_value=[self.owner, self.family]), \
                mock.patch("core.push.safe_push") as sp:
            atv.notify(self.phone, "all_clear", "t", "b", "t", "b",
                       family_only=True)
        self.assertEqual([c.args[0].pk for c in sp.call_args_list],
                         [self.family.pk])


class LegacyArmingSimTests(_Base):
    def test_legacy_sim_change_right_after_enable_is_ignored(self):
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            enabled_at=timezone.now() - timedelta(seconds=2))
        with mock.patch("core.push.safe_push") as sp:
            r = self._ingest([{"id": "sim-legacy", "kind": "sim_change",
                               "data": {"state": "inserted", "carrier": "GP"}}])
        self.assertEqual(r.status_code, 200)
        self.assertIn("sim-legacy", r.data["accepted"])
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.frozen_until)
        self.assertEqual(self.phone.signals or [], [])
        sp.assert_not_called()
        ev = AntiTheftEvent.objects.get(client_id="sim-legacy")
        self.assertEqual(ev.data.get("ignored"), "arming_baseline")

    def test_new_engine_sim_change_after_enable_still_alerts(self):
        AntiTheftEngine.objects.filter(phone=self.phone).update(
            enabled_at=timezone.now() - timedelta(seconds=30))
        self._sim_alarm("sim-v2")

    def test_legacy_sim_change_later_still_alerts(self):
        r = self._ingest([{"id": "sim-late", "kind": "sim_change",
                           "data": {"state": "inserted", "carrier": "Robi"}}])
        self.assertEqual(r.status_code, 200)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.frozen_until)
