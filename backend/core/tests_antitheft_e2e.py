"""
antitheft-e2e (17 Nov) — server half of the emulator E2E
(app/integration_test/flows/antitheft_e2e_flow.dart). Bugs it found:

  1. PRIVACY: a trusted contact's timeline listed EVERY event of the phone,
     including a grab still held for "Are you OK?", a grab the owner dropped
     by unlocking with his own secure lock / "I'm OK", and grabs the rules
     suppressed — each with where the phone was. The family was "never told"
     but could still read it. Now the family sees only what reached them.
  2. PRIVACY: a grab that was never sent kept its location. Now a dropped /
     suppressed grab keeps its motion numbers only (no lat/lng/accuracy).
  3. (phone side, Kotlin) the owner's sensitivity reached a running engine
     only from the open app on that phone; the ingest config now carries it
     and the engine applies it (guarded in app/test/antitheft_e2e_guard_test).

Sample data only (made-up names, coordinates in central Dhaka).
"""
from datetime import timedelta

from django.utils import timezone

from core import views_antitheft as atv
from core.logic import antitheft as at
from core.models import AntiTheftEngine
from core.tests_antitheft2 import _Base, _ms
from core.tests_flag_antitheft import (RICKSHAW_IN_USE, SNATCH_FROM_TABLE,
                                       SNATCH_IN_HAND_RUN, _grab_data)

LAT, LNG = 23.7331, 90.4170

# what a grab event may carry (motion numbers + the facts the server re-checks)
MOTION_KEYS = {"v", "profile", "sens", "in_use", "peak", "moving", "thirds",
               "rhythm", "step_hz", "mean"}
FACT_KEYS = {"locked", "charging", "face_down_still", "hour", "wifi",
             "screen_on", "confirm", "acc", "fix_at"}


class _E2E(_Base):
    def _grab(self, cid, feats, at_dt=None, **extra):
        at_dt = at_dt or timezone.now()
        return self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                              "lat": LAT, "lng": LNG, "acc": 12.0,
                              "data": _grab_data(feats, confirm="pending",
                                                 **extra)}])

    def _family_timeline(self):
        self.client.force_authenticate(self.family)
        r = self.client.get("/api/v1/security/engine/timeline?phone_id=%d"
                            % self.phone.id)
        self.client.force_authenticate(self.owner)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["viewer"], "family")
        return r.data["events"]

    def _grabs_family_sees(self):
        return [e for e in self._family_timeline()
                if e["kind"] in ("snatch", "snatch_cleared")]

    def _owner_timeline(self):
        r = self.client.get("/api/v1/security/engine/timeline")
        self.assertEqual(r.data["viewer"], "owner")
        return r.data["events"]


class HeldGrabPrivacyTests(_E2E):
    def test_held_grab_is_hidden_from_family_until_sent(self):
        self._grab("e2e-held", SNATCH_FROM_TABLE)
        self.assertEqual([e for e in self._family_timeline()
                          if e["kind"] == "snatch"], [])
        mine = [e for e in self._owner_timeline() if e["kind"] == "snatch"]
        self.assertEqual(len(mine), 1)
        self.assertTrue(mine[0]["held"])
        # no answer in the window -> sent, now the family sees it WITH location
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 1)
        fam = [e for e in self._family_timeline() if e["kind"] == "snatch"]
        self.assertEqual(len(fam), 1)
        self.assertEqual((fam[0]["lat"], fam[0]["lng"]), (LAT, LNG))
        self.assertGreaterEqual(fam[0]["recipients"], 1)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)

    def test_owner_unlock_drop_leaves_no_location_and_family_never_sees(self):
        t0 = timezone.now() - timedelta(seconds=5)
        self._grab("e2e-ou", SNATCH_IN_HAND_RUN, at_dt=t0)
        self._ingest([{"id": "e2e-ou-c", "kind": "snatch_cleared",
                       "at": _ms(t0 + timedelta(seconds=4)),
                       "data": {"reason": "owner_unlock"}}])
        ev = self._ev("e2e-ou")
        self.assertEqual(ev.data["confirm"], "owner_unlock")
        self.assertIsNone(ev.lat)
        self.assertIsNone(ev.lng)
        self.assertIsNone(ev.accuracy_m)
        self.assertEqual(ev.data["peak"], SNATCH_IN_HAND_RUN["peak"])  # motion kept
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 0)
        self.assertEqual(self._notifs(self.family).count(), 0)
        self.assertEqual(self._grabs_family_sees(), [])

    def test_im_ok_with_pin_drops_location_too(self):
        self._grab("e2e-ok", SNATCH_FROM_TABLE)
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        ev = self._ev("e2e-ok")
        self.assertTrue(ev.data["false_alarm"])
        self.assertIsNone(ev.lat)
        self.assertEqual(self._grabs_family_sees(), [])

    def test_suppressed_grab_keeps_motion_only(self):
        self._grab("e2e-rk", RICKSHAW_IN_USE)
        ev = self._ev("e2e-rk")
        self.assertEqual(ev.data["suppressed"], "weak_rhythm")
        self.assertIsNone(ev.lat)
        self.assertIsNone(ev.fix_at)
        self.assertEqual(self._grabs_family_sees(), [])
        self.assertEqual(self._notifs(self.family).count(), 0)

    def test_grab_payload_is_motion_numbers_and_facts_only(self):
        self._grab("e2e-keys", SNATCH_FROM_TABLE)
        keys = set(self._ev("e2e-keys").data)
        self.assertTrue(keys <= MOTION_KEYS | FACT_KEYS, keys - MOTION_KEYS - FACT_KEYS)
        for banned in ("lat", "lng", "audio", "photo", "address", "ssid"):
            self.assertNotIn(banned, keys)


class SensitivityReachesEngineTests(_E2E):
    def test_every_checkin_carries_the_current_sensitivity(self):
        for value in ("low", "high", "normal"):
            r = self.client.post("/api/v1/security/engine/settings",
                                 {"pin": self.PIN, "snatch_sensitivity": value},
                                 format="json")
            self.assertEqual(r.status_code, 200, r.data)
            hb = self._ingest([{"id": "hb-%s" % value, "kind": "heartbeat",
                                "at": _ms(timezone.now())}])
            self.assertEqual(hb.data["config"]["snatch_sensitivity"], value)

    def test_borderline_numbers_alert_on_high_only(self):
        # the borderline trace's grab: weak peak, real run (rhythm 0.4 sits
        # between high's 0.35 and normal's 0.5 bar on the server)
        border = dict(SNATCH_IN_HAND_RUN, peak=24.0, rhythm=0.4, sens="high")
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            snatch_sensitivity="normal")
        self._grab("e2e-bn", border)
        self.assertEqual(self._ev("e2e-bn").data["suppressed"], "weak_rhythm")
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            snatch_sensitivity="high")
        self._grab("e2e-bh", border, at_dt=timezone.now() + timedelta(seconds=1))
        ev = self._ev("e2e-bh")
        self.assertNotIn("suppressed", ev.data)
        self.assertIsNotNone(ev.escalate_at)
