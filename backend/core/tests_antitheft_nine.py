"""
antitheft-nine (18 Nov) — board row 11 to 9. Server half of the bugs the
emulator flows (app/integration_test/flows/antitheft_nine_flow.dart) and the
review found:

  1. SILENCED REAL THEFT: the "one alert per kind per 10 min" cooldown also
     counted grabs that were NEVER sent — a grab the owner dropped with "I'm
     OK" (Security PIN) or by unlocking with his own secure lock is stored as
     alerted + false_alarm. So for 10 minutes after any false alarm, a REAL
     snatch reached nobody. Now an alert marked false_alarm never blocks the
     next one; a really-sent alert still does (no spam).
  2. (phone side, Kotlin, guarded in app/test/antitheft_nine_guard_test.dart)
     intruder photo / instant lock / wrong-unlock threshold changed from
     another device never reached a running engine; the check-in config
     carries them (asserted here) and the engine now applies them.

Sample data only (made-up names, coordinates in central Dhaka).
"""
from datetime import timedelta

from django.utils import timezone

from core import views_antitheft as atv
from core.logic import antitheft as at
from core.models import AntiTheftEngine
from core.tests_antitheft2 import _Base, _ms
from core.tests_flag_antitheft import (SNATCH_FROM_TABLE, SNATCH_IN_HAND_RUN,
                                       _grab_data)
from core.views_at_remote import INTRUDER_CONSENT_VERSION

LAT, LNG = 23.7331, 90.4170


class _Nine(_Base):
    def _grab(self, cid, feats, at_dt):
        r = self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                           "lat": LAT, "lng": LNG, "acc": 12.0,
                           "data": _grab_data(feats, confirm="pending")}])
        self.assertEqual(r.status_code, 200, r.data)
        return r

    def _escalate_after(self, at_dt):
        return atv.escalate_due(at_dt + timedelta(seconds=at.CONFIRM_WINDOW_S + 1))

    def _family_snatch_alerts(self):
        return self._notifs(self.family, "snatch").count()


class CooldownIgnoresFalseAlarmsTests(_Nine):
    def test_im_ok_drop_does_not_silence_the_next_real_grab(self):
        t0 = timezone.now()
        self._grab("n-ok-1", SNATCH_FROM_TABLE, t0)
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(self._ev("n-ok-1").data["false_alarm"])
        # a real thief 2 minutes later: nobody answers
        t1 = t0 + timedelta(minutes=2)
        self._grab("n-ok-2", SNATCH_FROM_TABLE, t1)
        self.assertEqual(self._escalate_after(t1), 1)
        self.assertEqual(self._family_snatch_alerts(), 1)
        self.assertGreaterEqual(self._ev("n-ok-2").recipients or 0, 1)

    def test_owner_unlock_drop_does_not_silence_the_next_real_grab(self):
        t0 = timezone.now() - timedelta(seconds=5)
        self._grab("n-ou-1", SNATCH_IN_HAND_RUN, t0)
        self._ingest([{"id": "n-ou-c", "kind": "snatch_cleared",
                       "at": _ms(t0 + timedelta(seconds=4)),
                       "data": {"reason": "owner_unlock"}}])
        self.assertEqual(self._ev("n-ou-1").data["confirm"], "owner_unlock")
        t1 = timezone.now() + timedelta(minutes=1)
        self._grab("n-ou-2", SNATCH_FROM_TABLE, t1)
        self.assertEqual(self._escalate_after(t1), 1)
        self.assertEqual(self._family_snatch_alerts(), 1)

    def test_alert_cleared_after_it_was_sent_does_not_silence_the_next(self):
        t0 = timezone.now()
        self._grab("n-cl-1", SNATCH_FROM_TABLE, t0)
        self.assertEqual(self._escalate_after(t0), 1)
        self.assertEqual(self._family_snatch_alerts(), 1)
        # the owner: "It was me" (PIN) -> the sent alert is marked false
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(self._ev("n-cl-1").data.get("false_alarm"))
        t1 = t0 + timedelta(minutes=3)
        self._grab("n-cl-2", SNATCH_FROM_TABLE, t1)
        self.assertEqual(self._escalate_after(t1), 1)
        self.assertEqual(self._family_snatch_alerts(), 2)

    def test_a_really_sent_alert_still_cools_down(self):
        t0 = timezone.now()
        self._grab("n-cd-1", SNATCH_FROM_TABLE, t0)
        self.assertEqual(self._escalate_after(t0), 1)
        t1 = t0 + timedelta(minutes=3)
        self._grab("n-cd-2", SNATCH_FROM_TABLE, t1)
        self._escalate_after(t1)
        # the family is not spammed: still ONE grab alert inside 10 min
        self.assertEqual(self._family_snatch_alerts(), 1)


class CheckinCarriesSwitchesTests(_Nine):
    def test_checkin_config_carries_intruder_lock_and_threshold(self):
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "intruder_photo": True,
                              "intruder_consent": INTRUDER_CONSENT_VERSION,
                              "snatch_lock": True, "failed_unlock_threshold": 4},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        hb = self._ingest([{"id": "hb-n1", "kind": "heartbeat",
                            "at": _ms(timezone.now())}])
        cfg = hb.data["config"]
        self.assertIs(cfg["intruder_photo"], True)
        self.assertIs(cfg["snatch_lock"], True)
        self.assertEqual(cfg["failed_unlock_threshold"], 4)
        # switched OFF from another device -> the next check-in says so
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "intruder_photo": False,
                              "snatch_lock": False}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        hb = self._ingest([{"id": "hb-n2", "kind": "heartbeat",
                            "at": _ms(timezone.now())}])
        self.assertIs(hb.data["config"]["intruder_photo"], False)
        self.assertIs(hb.data["config"]["snatch_lock"], False)
        self.assertFalse(AntiTheftEngine.objects.get(pk=self.eng.pk).intruder_photo)

    def test_wrong_settings_pin_three_times_asks_for_the_photo(self):
        self.client.post("/api/v1/security/engine/settings",
                         {"pin": self.PIN, "intruder_photo": True,
                          "intruder_consent": INTRUDER_CONSENT_VERSION},
                         format="json")
        snaps = []
        for _ in range(3):
            r = self.client.post("/api/v1/security/engine/settings",
                                 {"pin": "0000", "snatch_sensitivity": "normal"},
                                 format="json")
            self.assertEqual(r.status_code, 403, r.data)
            snaps.append(r.data.get("intruder_snap"))
        self.assertEqual(snaps, [False, False, True])
        # the owner's right PIN resets the count
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "snatch_sensitivity": "normal"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.wrong_pin_count, 0)
