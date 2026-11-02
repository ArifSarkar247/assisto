"""testkit (owner 2 Nov): before the owner tries real devices, every device's
SETUP flow must end in a clear success or an honest, recoverable failure -
never a silent hang. For tracker (car), tracker chip and kids watch:

  * pair (pending, fresh window) -> device connects -> success;
  * window passes -> device refused as 'expired' (state shows it) ->
    ONE owner tap reopens the window (repair / pair again) -> the SAME device
    now connects (nothing lost, nobody charged twice);
  * an unknown id is refused and never creates anything.
"""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import kidswatch_service as KW
from core import vehicle_service as VS
from core import tests_chipbuy as CB
from core import tests_kidswatch as KT
from core.models import KidsWatch, VehicleTracker
from core.tests_v1_vehicle import IMEI_C, _Setup

V = "/api/v1"


def _past():
    return timezone.now() - timedelta(minutes=1)


class CarTrackerSetupEnds(_Setup, APITestCase):
    def test_success_expiry_repair_and_unknown(self):
        r = self.client.post(V + "/vehicle/trackers", {"imei": IMEI_C, "name": "Hiace",
                                                       "protocol": "gt06"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["tracker"]["state"], "pending")
        self.assertIsNotNone(r.data["tracker"]["pair_expires_at"])      # app shows the timer
        tid = r.data["tracker"]["id"]
        # the window passes: refused honestly, and the app can see 'expired'
        VehicleTracker.objects.filter(pk=tid).update(pair_expires_at=_past())
        self.assertEqual(VS.on_device_connect(IMEI_C, "gt06", remote="t"), (None, "expired"))
        r = self.client.get(V + "/vehicle/trackers/%d" % tid)
        self.assertEqual(r.data["state"], "expired")
        # one tap (the app's "Try again" posts the same pair request) reopens it
        r = self.client.post(V + "/vehicle/trackers", {"imei": IMEI_C, "name": "Hiace",
                                                       "protocol": "gt06"}, format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        self.assertEqual((r.data["tracker"]["id"], r.data["tracker"]["state"]),
                         (tid, "pending"))
        self.assertEqual(VS.on_device_connect(IMEI_C, "gt06", remote="t"),
                         (tid, "newly_paired"))
        self.assertEqual(VehicleTracker.objects.filter(imei=IMEI_C).count(), 1)
        # a device nobody paired is refused and creates nothing
        n = VehicleTracker.objects.count()
        self.assertEqual(VS.on_device_connect("359339077009999", "gt06", remote="t"),
                         (None, "unknown"))
        self.assertEqual(VehicleTracker.objects.count(), n)

    def test_no_credits_is_an_honest_402_not_a_silent_pending(self):
        if VS.month_credits() <= 0:
            self.skipTest("tracker is free in this config")
        self.owner.ai_credits = 0
        self.owner.save()
        r = self.client.post(V + "/vehicle/trackers", {"imei": IMEI_C, "name": "X"},
                             format="json")
        self.assertEqual(r.status_code, 402, r.data)
        self.assertFalse(VehicleTracker.objects.filter(imei=IMEI_C).exists())


class ChipSetupEnds(CB._Base):
    def test_expiry_then_one_tap_repair_then_success(self):
        t = self.pair()
        VehicleTracker.objects.filter(pk=t.pk).update(pair_expires_at=_past())
        self.assertEqual(self.connect(t)[1], "expired")
        r = self.c.post(V + "/kids-watch/chips/%d/repair" % t.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["chip"]["state"], "pending")
        tid, why = self.connect(t)
        self.assertEqual((tid, why, t.state), (t.id, "newly_paired", "paired"))

    def test_unknown_chip_refused(self):
        self.assertEqual(VS.on_device_connect(CB.IMEI2, "gt06", remote="t"), (None, "unknown"))

    def test_a_stranger_cannot_reopen_my_chips_window(self):
        t = self.pair()
        r = KT.cl(self.x).post(V + "/kids-watch/chips/%d/repair" % t.id)
        self.assertEqual(r.status_code, 404)


class WatchSetupEnds(KT._Base):
    def test_expiry_then_one_tap_repair_then_success(self):
        w = self.pair_watch()
        KidsWatch.objects.filter(pk=w.pk).update(pair_expires_at=_past())
        self.assertEqual(KW.on_watch_connect("8800000015", "3G")[1], "expired")
        r = self.c.post(V + "/kids-watch/watches/%d/repair" % w.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["watch"]["state"], "pending")
        wid, why, _tz = KW.on_watch_connect("8800000015", "3G")
        self.assertEqual((wid, why), (w.id, "newly_paired"))

    def test_unknown_code_refused_and_stranger_cannot_repair(self):
        w = self.pair_watch()
        self.assertEqual(KW.on_watch_connect("8800000077", "3G")[1], "unknown")
        r = KT.cl(self.x).post(V + "/kids-watch/watches/%d/repair" % w.id)
        self.assertEqual(r.status_code, 404)
