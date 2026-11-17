"""
flag-antitheft (17 Nov) — fewer false "sudden grab" alerts.

Live read-only finding (counts only): 10 grab alerts, ALL from one phone,
all in the evening (15-22 h), none charging / face-down, the owner answered
"Are you OK?" in 0 of 10 (every one timed out), and none was followed by a
SIM change, lost mode or any theft sign -> almost surely false alarms. The
engine logged NO motion numbers then, so the server could not judge them.

Covers:
  1. the "Are you OK?" window is 10-20 s (owner: 15 s);
  2. the server re-checks a v3 grab's motion numbers with the owner's
     CURRENT sensitivity (pure grab_motion_check, anonymised + synthetic
     feature vectors) and the legacy live shape is never judged;
  3. ingest: an irregular (rickshaw-like) grab is stored, never alerts,
     never freezes; a real grab-and-run is held and escalates;
  4. the owner unlocking with the phone's own secure lock inside the window
     drops the held grab (also when grab + unlock arrive late together);
     after an alert already went out the family gets the "false alarm"
     update;
  5. the sensitivity setting: PIN-gated, validated, sent to the engine.
"""
from datetime import timedelta

from django.utils import timezone

from core import views_antitheft as atv
from core.logic import antitheft as at
from core.models import AntiTheftEngine, AntiTheftEvent
from core.tests_antitheft2 import _Base, _ms

# --- anonymised feature vectors -------------------------------------------
# The shape the live engine sent for the 10 unverified grabs (values are the
# common ones; no ids, no location, no Wi-Fi hash).
LIVE_LEGACY = {"hour": 21, "locked": False, "confirm": "timeout",
               "charging": False, "face_down_still": False}

# v3 vectors from the synthetic traces (app/test/fixtures/sensor_traces/fa_*,
# numbers as the detector reports them; synthetic, not recordings).
RICKSHAW_IN_USE = {"v": 3, "profile": "day", "sens": "normal", "in_use": True,
                   "peak": 32.0, "moving": 0.89, "thirds": [0.83, 0.93, 0.92],
                   "rhythm": 0.12, "step_hz": 1.52, "mean": 9.4}
JOGGING_IN_HAND = {"v": 3, "profile": "day", "sens": "normal", "in_use": True,
                   "peak": 28.0, "moving": 0.69, "thirds": [0.74, 0.69, 0.64],
                   "rhythm": 0.36, "step_hz": 1.92, "mean": 9.1}
SNATCH_IN_HAND_RUN = {"v": 3, "profile": "day", "sens": "normal",
                      "in_use": True, "peak": 38.0, "moving": 0.73,
                      "thirds": [0.71, 0.72, 0.75], "rhythm": 0.72,
                      "step_hz": 2.78, "mean": 9.8}
SNATCH_FROM_TABLE = {"v": 3, "profile": "night", "sens": "normal",
                     "in_use": False, "peak": 40.0, "moving": 0.71,
                     "thirds": [0.75, 0.69, 0.69], "rhythm": 0.89,
                     "step_hz": 2.94, "mean": 10.1}
SHORT_BURST = {"v": 3, "profile": "day", "sens": "normal", "in_use": False,
               "peak": 30.0, "moving": 0.62, "thirds": [0.95, 0.6, 0.3],
               "rhythm": 0.7, "step_hz": 2.5, "mean": 7.0}


def _grab_data(features, **extra):
    d = {"hour": 19, "locked": False, "charging": False,
         "face_down_still": False, "screen_on": True}
    d.update(features)
    d.update(extra)
    return d


class WindowTests(_Base):
    def test_confirm_window_is_ten_to_twenty_seconds(self):
        self.assertGreaterEqual(at.CONFIRM_WINDOW_S, 10)
        self.assertLessEqual(at.CONFIRM_WINDOW_S, 20)
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertEqual(st["grab_confirm_window_s"], at.CONFIRM_WINDOW_S)
        self.assertEqual(st["snatch_sensitivity"], "normal")


class MotionCheckTests(_Base):
    def test_legacy_live_shape_is_not_judged(self):
        # honest: the 10 live grabs carried no motion numbers
        for s in at.SNATCH_SENSITIVITIES:
            self.assertIsNone(at.grab_motion_check(LIVE_LEGACY, s))
        self.assertIsNone(at.grab_suppression(LIVE_LEGACY, None))

    def test_irregular_motion_is_not_a_snatch(self):
        for s in at.SNATCH_SENSITIVITIES:
            self.assertIn(at.grab_motion_check(RICKSHAW_IN_USE, s),
                          ("weak_rhythm", "in_hand_low"))

    def test_jogging_only_counts_on_high(self):
        self.assertEqual(at.grab_motion_check(JOGGING_IN_HAND, "normal"),
                         "weak_rhythm")
        self.assertIsNone(at.grab_motion_check(JOGGING_IN_HAND, "high"))

    def test_real_grab_and_run_passes(self):
        for s in ("normal", "high"):
            self.assertIsNone(at.grab_motion_check(SNATCH_IN_HAND_RUN, s))
        for s in at.SNATCH_SENSITIVITIES:
            self.assertIsNone(at.grab_motion_check(SNATCH_FROM_TABLE, s))

    def test_low_ignores_grabs_from_the_hand(self):
        self.assertEqual(at.grab_motion_check(SNATCH_IN_HAND_RUN, "low"),
                         "in_hand_low")

    def test_motion_that_settles_is_not_sustained(self):
        self.assertEqual(at.grab_motion_check(SHORT_BURST, "normal"),
                         "not_sustained")

    def test_bad_values_never_crash(self):
        for d in ({"v": "x"}, {"v": 3, "rhythm": "?", "thirds": ["a", 1, 2]},
                  {"v": 3, "thirds": [1]}, None, []):
            at.grab_motion_check(d, "normal")
        self.assertIsNone(at.clean_sensitivity("max"))
        self.assertEqual(at.clean_sensitivity(" LOW "), "low")


class IngestTests(_Base):
    def _grab(self, cid, data, at_dt=None):
        at_dt = at_dt or timezone.now()
        return self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                              "data": data}])

    def test_rickshaw_grab_is_stored_silently(self):
        r = self._grab("fa-r", _grab_data(RICKSHAW_IN_USE, confirm="pending"))
        self.assertEqual(r.status_code, 200, r.data)
        ev = self._ev("fa-r")
        self.assertEqual(ev.data["suppressed"], "weak_rhythm")
        self.assertTrue(ev.alerted)
        self.assertIsNone(ev.escalate_at)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 0)
        self.phone.refresh_from_db()
        self.assertIsNone(self.phone.frozen_until)

    def test_real_grab_is_held_then_escalates(self):
        self._grab("fa-s", _grab_data(SNATCH_IN_HAND_RUN, confirm="pending"))
        ev = self._ev("fa-s")
        self.assertFalse(ev.alerted)
        self.assertIsNotNone(ev.escalate_at)
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 1)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)

    def test_low_sensitivity_on_server_drops_in_hand_grab(self):
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(
            snatch_sensitivity="low")
        self._grab("fa-low", _grab_data(SNATCH_IN_HAND_RUN, confirm="pending"))
        self.assertEqual(self._ev("fa-low").data["suppressed"], "in_hand_low")
        self.assertEqual(self._notifs(self.family, "snatch").count(), 0)


class OwnerUnlockTests(_Base):
    def _pending(self, cid, at_dt):
        return self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                              "data": _grab_data(SNATCH_IN_HAND_RUN,
                                                 confirm="pending")}])

    def _clear(self, cid, at_dt):
        return self._ingest([{"id": cid, "kind": "snatch_cleared",
                              "at": _ms(at_dt),
                              "data": {"reason": "owner_unlock"}}])

    def test_unlock_in_window_drops_the_held_grab(self):
        t0 = timezone.now() - timedelta(seconds=5)
        self._pending("ou-g", t0)
        self._clear("ou-c", t0 + timedelta(seconds=4))
        ev = self._ev("ou-g")
        self.assertTrue(ev.alerted)
        self.assertIsNone(ev.escalate_at)
        self.assertTrue(ev.data["false_alarm"])
        self.assertEqual(ev.data["confirm"], "owner_unlock")
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 0)
        self.assertEqual(self._notifs(self.family).count(), 0)
        self.assertEqual(self._ev("ou-c").data["silent"], "held_grab_dropped")
        self.phone.refresh_from_db()
        self.assertIsNone(self.phone.frozen_until)

    def test_late_grab_and_unlock_together_alert_nobody(self):
        t0 = timezone.now() - timedelta(minutes=5)
        r = self._ingest([
            {"id": "ou-lg", "kind": "snatch", "at": _ms(t0),
             "data": _grab_data(SNATCH_IN_HAND_RUN, confirm="pending")},
            {"id": "ou-lc", "kind": "snatch_cleared",
             "at": _ms(t0 + timedelta(seconds=6)),
             "data": {"reason": "owner_unlock"}},
        ])
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self._ev("ou-lg").data["suppressed"], "owner_unlock")
        self.assertEqual(self._ev("ou-lc").data["silent"], "no_grab_was_sent")
        self.assertEqual(self._notifs(self.family).count(), 0)

    def test_unlock_after_escalation_sends_the_all_clear_update(self):
        t0 = timezone.now() - timedelta(seconds=5)
        self._pending("ou-eg", t0)
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 1)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        self._clear("ou-ec", timezone.now())
        self.assertEqual(self._notifs(self.family, "snatch_cleared").count(), 1)

    def test_other_clear_reasons_keep_old_behaviour(self):
        t0 = timezone.now() - timedelta(seconds=5)
        self._pending("ou-og", t0)
        self._ingest([{"id": "ou-oc", "kind": "snatch_cleared",
                       "at": _ms(t0 + timedelta(seconds=3)), "data": {}}])
        self.assertFalse(self._ev("ou-og").alerted)   # still held


class SensitivitySettingTests(_Base):
    def _set(self, value, pin=None):
        return self.client.post("/api/v1/security/engine/settings",
                                {"pin": pin or self.PIN,
                                 "snatch_sensitivity": value}, format="json")

    def test_set_low_reaches_state_and_engine_config(self):
        r = self._set("low")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["config"]["snatch_sensitivity"], "low")
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.snatch_sensitivity, "low")
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertEqual(st["snatch_sensitivity"], "low")

    def test_bad_value_and_wrong_pin_change_nothing(self):
        self.assertEqual(self._set("max").status_code, 400)
        self.assertEqual(self._set("low", pin="0000").status_code, 403)
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.snatch_sensitivity, "normal")

    def test_events_never_carry_location_in_features(self):
        # the motion numbers are numbers only: no lat/lng inside data
        self._ingest([{"id": "fs-1", "kind": "snatch",
                       "at": _ms(timezone.now()),
                       "data": _grab_data(SNATCH_FROM_TABLE)}])
        d = AntiTheftEvent.objects.get(client_id="fs-1").data
        self.assertNotIn("lat", d)
        self.assertNotIn("lng", d)
