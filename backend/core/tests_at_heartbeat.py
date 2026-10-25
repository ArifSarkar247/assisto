"""
at-heartbeat (owner 24 Oct) — "Arif's phone stopped checking in" while he was
using it, shown twice (Security + Family).

Covers: the smarter went-dark threshold (several missed check-ins + floor +
grace, longer for a battery-optimised phone, any engine delivery counts as
"seen"), the device owner NEVER getting a went-dark alert about his own phone,
ONE in-app record per person per anti-theft alert (no FamilyAlert twin), and
auto-resolve + one family-only "back online" line when check-ins resume.
"""
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.utils import timezone
from rest_framework.test import APITestCase

from core import views_antitheft as atv
from core.logic import antitheft as at
from core.models import (AntiTheftEngine, AntiTheftEvent, CircleMember,
                         FamilyAlert, NotifEvent, ProtectedPhone, User)
from core.views_lost import _went_dark_since


class ThresholdLogicTests(APITestCase):
    def test_needs_several_missed_checkins_plus_grace(self):
        # 15-min engine: 4 missed (60) + 10 grace
        self.assertEqual(at.went_dark_threshold_min(15), 70)
        # 10-min (charging): the 45-min floor wins, + grace
        self.assertEqual(at.went_dark_threshold_min(10), 55)
        # 5-min (lost mode): floor + grace
        self.assertEqual(at.went_dark_threshold_min(5), 55)
        # 60-min (critical battery): 4 hours + grace
        self.assertEqual(at.went_dark_threshold_min(60), 250)

    def test_unknown_interval_uses_normal(self):
        self.assertEqual(at.went_dark_threshold_min(None), 70)
        self.assertEqual(at.went_dark_threshold_min("x"), 70)
        self.assertEqual(at.went_dark_threshold_min(0), 70)

    def test_battery_optimised_waits_longer(self):
        self.assertEqual(at.went_dark_threshold_min(10, True), 100)
        self.assertEqual(at.went_dark_threshold_min(15, True), 100)
        self.assertEqual(at.went_dark_threshold_min(30, True), 190)
        self.assertGreater(at.went_dark_threshold_min(15, True),
                           at.went_dark_threshold_min(15, False))

    def test_interval_is_capped(self):
        self.assertEqual(at.went_dark_threshold_min(10_000),
                         at.HEARTBEAT_INTERVAL_MAX * at.WENT_DARK_MISSED
                         + at.WENT_DARK_GRACE_MIN)

    def test_battery_optimised_only_when_reported_true(self):
        self.assertTrue(at.battery_optimised({"batteryOptimised": True}))
        self.assertFalse(at.battery_optimised({"batteryOptimised": False}))
        self.assertFalse(at.battery_optimised({}))
        self.assertFalse(at.battery_optimised(None))
        self.assertFalse(at.battery_optimised({"batteryOptimised": "yes"}))

    def test_reported_interval(self):
        self.assertEqual(at.reported_interval({"interval": 30}), 30)
        self.assertIsNone(at.reported_interval({"interval": 0}))
        self.assertIsNone(at.reported_interval({}))
        # older engines: estimate from the battery they sent
        self.assertEqual(at.reported_interval({"battery": 20}), at.INTERVAL_LOW)
        self.assertEqual(at.reported_interval({"battery": 80, "charging": True}),
                         at.INTERVAL_CHARGING)
        self.assertEqual(at.reported_interval({"interval": 999, "battery": 90}),
                         at.INTERVAL_NORMAL)

    def test_last_seen_at(self):
        a = timezone.now()
        b = a - timedelta(hours=1)
        self.assertEqual(at.last_seen_at(b, a), a)
        self.assertEqual(at.last_seen_at(None, b), b)
        self.assertIsNone(at.last_seen_at(None, None))


class _Base(APITestCase):
    PIN = "2468"

    def setUp(self):
        self.owner = User.objects.create_user(
            name="Arif", phone="01710000101", password="x",
            email="athb-owner@example.com")
        self.family = User.objects.create_user(
            name="Ma", phone="01710000102", password="x",
            email="athb-family@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.family, name="Ma",
            state="accepted", direction="outgoing")
        r = self.client.post("/api/v1/security/engine/enable",
                             {"pin": self.PIN,
                              "alert_member_ids": [self.member.id]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        self.eng = AntiTheftEngine.objects.get(phone=self.phone)

    def _ingest(self, items, **extra):
        body = {"items": items, "sent_at": timezone.now().isoformat()}
        body.update(extra)
        return self.client.post("/api/v1/security/engine/ingest", body,
                                format="json", HTTP_X_ASSISTO_ENGINE=self.token)

    def _silent_for(self, minutes, interval=15):
        then = timezone.now() - timedelta(minutes=minutes)
        ProtectedPhone.objects.filter(pk=self.phone.pk).update(
            last_heartbeat_at=then, heartbeat_interval_min=interval,
            went_dark_alerted=False)
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(last_ingest_at=then)
        self.phone.refresh_from_db()

    def _went_dark_rows(self, user):
        return NotifEvent.objects.filter(user=user,
                                         meta__antitheft_kind="went_dark")


class WentDarkThresholdTests(_Base):
    def test_three_missed_checkins_is_not_dark(self):
        # the old rule (3 x 10 min) fired after ~31 min: Arif's false alarm
        self._silent_for(35, interval=10)
        self.assertIsNone(_went_dark_since(self.phone))
        self._silent_for(50, interval=15)
        self.assertIsNone(_went_dark_since(self.phone))

    def test_long_silence_is_dark(self):
        self._silent_for(75, interval=15)
        self.assertIsNotNone(_went_dark_since(self.phone))

    def test_recent_ingest_counts_as_seen(self):
        self._silent_for(300, interval=15)
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            last_ingest_at=timezone.now() - timedelta(minutes=5))
        self.phone.refresh_from_db()
        self.assertIsNone(_went_dark_since(self.phone))

    def test_battery_optimised_phone_gets_longer_grace(self):
        self._silent_for(80, interval=15)
        self.assertIsNotNone(_went_dark_since(self.phone))
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            capabilities={"batteryOptimised": True})
        self.phone.refresh_from_db()
        self.assertIsNone(_went_dark_since(self.phone))

    def test_ingest_learns_interval_and_merges_capabilities(self):
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            capabilities={"canCamera": True, "sdk": 33})
        r = self._ingest([{"id": "hb-iv", "kind": "heartbeat", "battery": 25,
                           "interval": 30}],
                         capabilities={"batteryOptimised": True})
        self.assertEqual(r.status_code, 200)
        self.phone.refresh_from_db()
        self.eng.refresh_from_db()
        self.assertEqual(self.phone.heartbeat_interval_min, 30)
        self.assertEqual(self.eng.capabilities.get("canCamera"), True)
        self.assertEqual(self.eng.capabilities.get("batteryOptimised"), True)

    def test_ingest_estimates_interval_for_old_engines(self):
        self._ingest([{"id": "hb-old", "kind": "heartbeat", "battery": 12}])
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.heartbeat_interval_min, at.INTERVAL_CRITICAL)


class OwnerNeverToldTests(_Base):
    def test_went_dark_goes_to_family_only(self):
        self._silent_for(120)
        with mock.patch("core.push.safe_push") as sp:
            call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)
        self.assertEqual(self._went_dark_rows(self.family).count(), 1)
        self.assertFalse(self._went_dark_rows(self.owner).exists())
        self.assertFalse(FamilyAlert.objects.filter(
            user=self.owner, payload__antitheft_kind="went_dark").exists())
        pushed = [c.args[0].pk for c in sp.call_args_list]
        self.assertEqual(pushed, [self.family.pk])

    def test_owner_who_is_also_family_peer_still_not_told(self):
        # the owner's own account linked as an approved alert member
        self_link = CircleMember.objects.create(
            user=self.owner, peer_user=self.owner, name="me",
            state="accepted", direction="outgoing")
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            alert_member_ids=[self.member.id, self_link.id])
        self._silent_for(120)
        call_command("check_went_dark")
        self.assertFalse(self._went_dark_rows(self.owner).exists())

    def test_engine_error_never_falls_back_to_owner_alert(self):
        self._silent_for(120)
        with mock.patch.object(at, "went_dark_text", side_effect=RuntimeError):
            call_command("check_went_dark")
        self.assertFalse(NotifEvent.objects.filter(user=self.owner).filter(
            meta__has_key="went_dark_at").exists())
        self.assertFalse(FamilyAlert.objects.filter(
            user=self.owner, payload__has_key="went_dark_at").exists())

    def test_alerts_poll_for_owner_has_no_went_dark(self):
        self._silent_for(120)
        call_command("check_went_dark")
        r = self.client.get("/api/v1/alerts")
        self.assertEqual(r.status_code, 200)
        alerts = r.data if isinstance(r.data, list) else r.data.get("alerts", [])
        self.assertFalse(any("checking in" in (a.get("title") or "") or
                             "তথ্য আসছে না" in (a.get("title") or "")
                             for a in alerts))


class OneRecordPerPersonTests(_Base):
    def test_snatch_alert_is_one_notif_event_no_family_alert(self):
        before = FamilyAlert.objects.filter(kind="antitheft").count()
        with mock.patch("core.push.safe_push") as sp:
            self._ingest([{"id": "sn-1", "kind": "snatch"}])
        # owner 25 Oct: the owner never gets alerts about his own phone
        self.assertEqual(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="snatch").count(), 0)
        self.assertEqual(NotifEvent.objects.filter(
            user=self.family, meta__antitheft_kind="snatch").count(), 1)
        self.assertEqual(FamilyAlert.objects.filter(kind="antitheft").count(),
                         before)
        pushed = sorted(c.args[0].pk for c in sp.call_args_list)
        self.assertEqual(pushed, [self.family.pk])

    def test_notif_feed_shows_the_alert_once(self):
        self._ingest([{"id": "sn-2", "kind": "snatch"}])
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/notif/feed")
        self.assertEqual(r.status_code, 200)
        snatch = [i for i in r.data["items"]
                  if (i.get("meta") or {}).get("antitheft_kind") == "snatch"
                  or "snatch" in str(i.get("id", ""))]
        self.assertEqual(len(snatch), 1)
        # and no Family-category twin of it
        self.assertFalse(any(str(i.get("id", "")).startswith("familyalert:")
                             for i in r.data["items"]))

    def test_alerts_poll_still_surfaces_it_once(self):
        self._ingest([{"id": "sn-3", "kind": "snatch"}])
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/alerts")
        alerts = r.data if isinstance(r.data, list) else r.data.get("alerts", [])
        at_rows = [a for a in alerts if a.get("type") == "antitheft"
                   and a.get("kind") == "snatch"]
        self.assertEqual(len(at_rows), 1)
        # seen in the notification centre -> gone from the poll
        n = NotifEvent.objects.get(user=self.family, meta__antitheft_kind="snatch")
        self.client.post("/api/v1/notif/notif:%d/seen" % n.id)
        r2 = self.client.get("/api/v1/alerts")
        alerts2 = r2.data if isinstance(r2.data, list) else r2.data.get("alerts", [])
        self.assertFalse([a for a in alerts2 if a.get("type") == "antitheft"
                          and a.get("kind") == "snatch"])


class AutoResolveTests(_Base):
    def _go_dark(self):
        self._silent_for(120)
        call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)

    def test_checkin_resolves_and_sends_one_back_online(self):
        self._go_dark()
        with mock.patch("core.push.safe_push") as sp:
            self._ingest([{"id": "hb-back", "kind": "heartbeat"}])
            self._ingest([{"id": "hb-back2", "kind": "heartbeat"}])
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.went_dark_alerted)
        n = self._went_dark_rows(self.family).get()
        self.assertTrue(n.seen)
        self.assertTrue(n.meta.get("resolved_at"))
        ev = AntiTheftEvent.objects.get(phone=self.phone, kind="went_dark")
        self.assertTrue((ev.data or {}).get("resolved_at"))
        online = NotifEvent.objects.filter(meta__antitheft_kind="online")
        self.assertEqual(online.filter(user=self.family).count(), 1)
        self.assertFalse(online.filter(user=self.owner).exists())
        self.assertEqual([c.args[0].pk for c in sp.call_args_list],
                         [self.family.pk])

    def test_older_went_dark_alerts_also_resolved(self):
        # an older, never-closed alert (and a legacy FamilyAlert twin)
        old = NotifEvent.objects.create(
            user=self.family, type="security", title_en="old", body_en="old",
            meta={"phone_id": self.phone.id, "antitheft_kind": "went_dark"})
        legacy = FamilyAlert.objects.create(
            user=self.family, kind="antitheft", title="old", body="old",
            payload={"phone_id": self.phone.id, "antitheft_kind": "went_dark"})
        self._go_dark()
        # opening a new went-dark closes the older one first
        old.refresh_from_db()
        self.assertTrue(old.meta.get("resolved_at"))
        self._ingest([{"id": "hb-r", "kind": "heartbeat"}])
        for n in self._went_dark_rows(self.family):
            self.assertTrue(n.seen)
            self.assertTrue(n.meta.get("resolved_at"))
        legacy.refresh_from_db()
        self.assertTrue(legacy.dismissed)

    def test_resolved_went_dark_leaves_alerts_poll(self):
        self._go_dark()
        self.client.force_authenticate(self.family)
        a1 = self.client.get("/api/v1/alerts").data
        a1 = a1 if isinstance(a1, list) else a1.get("alerts", [])
        self.assertEqual(len([a for a in a1 if a.get("kind") == "went_dark"]), 1)
        self._ingest([{"id": "hb-x", "kind": "heartbeat"}])
        a2 = self.client.get("/api/v1/alerts").data
        a2 = a2 if isinstance(a2, list) else a2.get("alerts", [])
        kinds = [a.get("kind") for a in a2 if a.get("type") == "antitheft"]
        # the went-dark alert is gone; exactly one back-online line remains
        self.assertNotIn("went_dark", kinds)
        self.assertEqual(kinds.count("online"), 1)

    def test_resolve_is_idempotent(self):
        self._go_dark()
        self.assertGreaterEqual(atv.resolve_went_dark(self.phone), 1)
        self.assertEqual(atv.resolve_went_dark(self.phone), 0)


class OwnDeviceNotInOwnUrgentCard(APITestCase):
    """owner 24 Oct: 'Assisto has not heard from the phone' showed in the
    owner's own home urgent card while he was using that phone."""

    def test_own_device_alerts_excluded_family_still_sees(self):
        from core.models import User, NotifEvent, FamilyAlert
        from core.views import _build_alerts
        from django.utils import timezone
        owner = User.objects.create_user(phone="01710000801", password="x", name="O", email="own-o@example.com")
        fam = User.objects.create_user(phone="01710000802", password="x", name="F", email="own-f@example.com")
        meta = {"antitheft_kind": "went_dark", "owner_id": owner.id, "phone_id": 1}
        for u in (owner, fam):
            NotifEvent.objects.create(user=u, type="security", title_en="dark", title_bn="dark",
                                      body_en="not heard", body_bn="not heard", meta=meta,
                                      at=timezone.now())
        FamilyAlert.objects.create(user=owner, kind="antitheft", title="dark", body="x",
                                   severity="high", payload=meta)
        self.assertFalse([a for a in _build_alerts(owner, "en") if a.get("type") == "antitheft"])
        self.assertTrue([a for a in _build_alerts(fam, "en") if a.get("type") == "antitheft"])
