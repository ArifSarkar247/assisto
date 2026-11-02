"""chipbuy (owner 2 Nov): small 4G GPS tracker chip for a school bag / shoe
on the EXISTING vehicle tracker server, shown on the child card.

  * pairing: IMEI + pairing window like a vehicle, NEVER charged (owner with
    0 credits pairs), never refused later for unpaid months, max 5;
  * decoding through the real GT06 decoder (doc-style packets built by
    tracker.protocols.gt06 and parsed back) -> vehicle_service.ingest ->
    last location + battery percent (voltage level / volts);
  * low battery alert in CHILD wording to owner + guardian only, route
    kids_watch (never the vehicle screen), quiet hours in-app;
  * School Mode fed by the chip: left home / reached school (same state
    machine as a watch);
  * guardian-only access: stranger 404, the CHILD sees only "on + who sees"
    (no location, no history, 404 on detail/history), a guardian who left
    the Circle loses access at once;
  * chips never appear in the vehicle list; flag OFF -> 403.
"""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from core import chip_service as CS
from core import vehicle_service as VS
from core.models import (CircleMember, NotifEvent, SchoolEvent, SchoolPlan,
                         VehiclePosition, VehicleTracker)
from core.tests_kidswatch import (CFG, HOME, SCHOOL, L, Spy, _east, cl, flag, mk,
                                  pair_circle)
from tracker.protocols import gt06

V = "/api/v1"


def luhn_imei(body14):
    total = 0
    for i, ch in enumerate(body14):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return body14 + str((10 - total % 10) % 10)


IMEI = luhn_imei("86592005123456")
IMEI2 = luhn_imei("86592005123457")


def fix_from_wire(at, lat, lng, serial=1, speed=3):
    """A GT06 location frame as the chip sends it, decoded by OUR decoder."""
    p = gt06.parse_frame(gt06.gps_packet(at, lat, lng, speed, 90, serial))
    return p["fix"]


def status_from_wire(level, serial=9):
    p = gt06.parse_frame(gt06.status_packet(serial, voltage_level=level))
    st = p["status"]
    out = {"ignition": st["ignition"], "relay_cut": st["relay_cut"],
           "voltage_level": p.get("voltage_level")}
    if st.get("alarm"):
        out["alarms"] = [st["alarm"]]
    return out


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        flag(True)
        self.owner = mk("01711300001", "Abba", credits=0)      # NO credits on purpose
        self.mom = mk("01711300002", "Ammu")
        self.child = mk("01711300003", "Rina")
        self.x = mk("01711300004", "Stranger")
        pair_circle(self.owner, self.mom)
        pair_circle(self.owner, self.child)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        self.c = cl(self.owner)

    def pair(self, imei=IMEI, **kw):
        body = {"imei": imei, "child_name": "Rina", "protocol": "gt06",
                "guardian_ids": [self.mom.id, self.x.id], "child_user_id": self.child.id}
        body.update(kw)
        r = self.c.post(V + "/kids-watch/chips", body, format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        return VehicleTracker.objects.get(pk=r.data["chip"]["id"])

    def connect(self, t, now=None):
        tid, why = VS.on_device_connect(t.imei, "gt06", remote="t", now=now)
        t.refresh_from_db()
        return tid, why


class PairingTests(_Base):
    def test_pair_free_and_connect_without_credits(self):
        t = self.pair()
        self.assertEqual((t.kind, t.state, t.child_name), ("chip", "pending", "Rina"))
        self.assertFalse(t.night_ignition_alert)
        self.assertEqual(t.moving_interval_s, CS.MOVING_INTERVAL_S)
        # only the accepted Circle peer becomes a guardian (stranger dropped)
        self.assertEqual([u.id for u in CS.guardian_users(t)], [self.mom.id])
        tid, why = self.connect(t)
        self.assertEqual((tid, why, t.state), (t.id, "newly_paired", "paired"))
        self.assertIsNone(t.billed_until)                    # never charged
        self.owner.refresh_from_db()
        self.assertEqual(int(self.owner.ai_credits or 0), 0)
        tid, why = self.connect(t, timezone.now() + timedelta(days=90))
        self.assertEqual(why, "paired")                       # never refused as unpaid

    def test_child_is_told_who_can_see(self):
        self.pair()
        n = NotifEvent.objects.filter(user=self.child).first()
        self.assertIsNotNone(n)
        self.assertIn("Ammu", n.body_en)
        self.assertIn("Abba", n.body_en)

    def test_refusals(self):
        r = self.c.post(V + "/kids-watch/chips", {"imei": "123", "child_name": "R"},
                        format="json")
        self.assertEqual(r.data["reason"], "bad_imei")
        r = self.c.post(V + "/kids-watch/chips", {"imei": IMEI, "child_name": ""},
                        format="json")
        self.assertEqual(r.data["reason"], "name_required")
        r = self.c.post(V + "/kids-watch/chips", {"imei": IMEI, "child_name": "R",
                                                  "child_user_id": self.x.id}, format="json")
        self.assertEqual(r.data["reason"], "child_not_in_circle")
        self.pair()
        r = cl(self.mom).post(V + "/kids-watch/chips", {"imei": IMEI, "child_name": "R"},
                              format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "imei_taken"))
        VehicleTracker.objects.create(owner=self.owner, imei=IMEI2)       # a car tracker
        r = self.c.post(V + "/kids-watch/chips", {"imei": IMEI2, "child_name": "R"},
                        format="json")
        self.assertEqual(r.data["reason"], "imei_is_vehicle")

    def test_limit_five(self):
        for i in range(CS.MAX_CHIPS_PER_USER):
            self.pair(luhn_imei("8659200600000%d" % i))
        r = self.c.post(V + "/kids-watch/chips", {"imei": luhn_imei("86592006000009"),
                                                  "child_name": "R"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "limit"))

    def test_flag_off(self):
        flag(False)
        self.assertEqual(self.c.get(V + "/kids-watch/chips").status_code, 403)

    def test_not_in_vehicle_list(self):
        self.pair()
        VehicleTracker.objects.create(owner=self.owner, imei=IMEI2, name="Car")
        r = self.c.get(V + "/vehicle/trackers")
        self.assertEqual([x["name"] for x in r.data["trackers"]], ["Car"])
        r = self.c.get(V + "/kids-watch/chips")
        self.assertEqual([x["child_name"] for x in r.data["chips"]], ["Rina"])
        # the paid vehicle pairing can never take over a chip
        r = self.c.post(V + "/vehicle/trackers", {"imei": IMEI}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "imei_is_chip"))


class IngestTests(_Base):
    def test_gt06_location_battery_and_low_alert(self):
        t = self.pair()
        self.connect(t)
        now = timezone.now()
        f = fix_from_wire(now - timedelta(seconds=30), *HOME)
        VS.ingest({t.id: {"fixes": [f], "status": status_from_wire(5)}}, now=now)
        t.refresh_from_db()
        self.assertAlmostEqual(t.last_lat, HOME[0], places=4)
        self.assertEqual(t.battery_pct, CS.GT06_LEVEL_PCT[5])
        self.assertEqual(VehiclePosition.objects.filter(tracker=t).count(), 1)
        # level 2 = low-battery alarm on GT06 -> one alert to owner + guardian
        with mock.patch("core.logic.vehicle_tracking.in_quiet", return_value=False):
            VS.ingest({t.id: {"fixes": [], "status": status_from_wire(2, 10)}},
                      now=now + timedelta(minutes=1))
        t.refresh_from_db()
        self.assertEqual(t.battery_pct, CS.GT06_LEVEL_PCT[2])
        got = [c for c in self.spy.calls if "battery" in c["ten"]]
        self.assertEqual(sorted(c["user"] for c in got), sorted([self.owner.id, self.mom.id]))
        self.assertTrue(all(c["data"]["route"] == "kids_watch" for c in got))
        self.assertIn("Rina", got[0]["ten"])
        self.assertNotIn("engine", got[0]["ben"].lower())
        # the child only ever gets the "chip is on + who sees" notice; the
        # stranger gets nothing
        self.assertFalse([c for c in self.spy.calls if c["user"] == self.x.id])
        self.assertEqual([c["data"].get("event") for c in self.spy.calls
                          if c["user"] == self.child.id], ["chip_on"])

    def test_battery_from_volts(self):
        self.assertEqual(CS.battery_pct(None, 4.2), 100)
        self.assertEqual(CS.battery_pct(None, 3.4), 0)
        self.assertEqual(CS.battery_pct(None, 3.8), 50)
        self.assertIsNone(CS.battery_pct(None, None))
        self.assertIsNone(CS.battery_pct(None, 0))
        self.assertEqual(CS.battery_pct(1, 4.1), 5)        # level wins when sent

    def test_school_mode_fed_by_chip(self):
        t = self.pair()
        self.connect(t)
        r = self.c.post(V + "/school-mode/plans", dict(CFG, chip_id=t.id), format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["plan"]["mode"], "chip")
        plan = SchoolPlan.objects.get(pk=r.data["plan"]["id"])
        self.assertEqual(plan.watcher_ids, [self.mom.id])
        self.assertEqual(plan.child_user_id, self.child.id)
        n = 1
        for at, pos in ((L(1, 7, 0), HOME), (L(1, 7, 20), _east(*HOME, 400)),
                        (L(1, 7, 21), _east(*HOME, 420)), (L(1, 7, 45), SCHOOL)):
            VS.ingest({t.id: {"fixes": [fix_from_wire(at, *pos, serial=n)]}},
                      now=at + timedelta(seconds=20))
            n += 1
        kinds = list(SchoolEvent.objects.filter(plan=plan).order_by("at")
                     .values_list("kind", flat=True))
        self.assertEqual(kinds, ["left_home", "arrived_school"])
        mom_texts = [c["ten"] for c in self.spy.to(self.mom)]
        self.assertTrue(any("reached school" in s for s in mom_texts), mom_texts)
        # a second plan on the same chip is refused
        r = self.c.post(V + "/school-mode/plans", dict(CFG, chip_id=t.id), format="json")
        self.assertEqual(r.status_code, 409)

    def test_history_pruned_after_48h(self):
        t = self.pair()
        now = timezone.now()
        VehiclePosition.objects.create(tracker=t, at=now - timedelta(hours=49),
                                       lat=1, lng=2)
        VehiclePosition.objects.create(tracker=t, at=now - timedelta(hours=1), lat=1, lng=2)
        self.assertEqual(CS.prune(now), 1)


class AccessTests(_Base):
    def test_guardian_only(self):
        t = self.pair()
        VS.ingest({t.id: {"fixes": [fix_from_wire(timezone.now(), *HOME)]}})
        for who, code in ((self.owner, 200), (self.mom, 200), (self.child, 404),
                          (self.x, 404)):
            self.assertEqual(cl(who).get(V + "/kids-watch/chips/%d" % t.id).status_code,
                             code, who.name)
            self.assertEqual(cl(who).get(V + "/kids-watch/chips/%d/history" % t.id)
                             .status_code, code, who.name)
        pts = cl(self.mom).get(V + "/kids-watch/chips/%d/history" % t.id).data["points"]
        self.assertEqual(len(pts), 1)
        # the guardian cannot manage
        self.assertEqual(cl(self.mom).delete(V + "/kids-watch/chips/%d" % t.id).status_code,
                         403)

    def test_child_sees_on_and_who_but_no_location(self):
        t = self.pair()
        VS.ingest({t.id: {"fixes": [fix_from_wire(timezone.now(), *HOME)]}})
        r = cl(self.child).get(V + "/kids-watch/chips")
        self.assertEqual(r.data["chips"], [])
        worn = r.data["worn"]
        self.assertEqual(len(worn), 1)
        self.assertEqual(sorted(worn[0]["watchers"]), ["Abba", "Ammu"])
        self.assertNotIn("live", worn[0])
        self.assertNotIn("lat", str(worn[0]))

    def test_guardian_who_left_circle_loses_access(self):
        t = self.pair()
        CircleMember.objects.filter(user=self.owner, peer_user=self.mom).update(blocked=True)
        self.assertEqual(cl(self.mom).get(V + "/kids-watch/chips/%d" % t.id).status_code,
                         404)
        self.assertEqual(CS.viewers(t), [self.owner])

    def test_patch_guardians_and_delete(self):
        t = self.pair()
        r = self.c.patch(V + "/kids-watch/chips/%d" % t.id, {"guardian_ids": []},
                         format="json")
        self.assertEqual(r.data["chip"]["guardians"], [])
        self.assertEqual(cl(self.mom).get(V + "/kids-watch/chips/%d" % t.id).status_code,
                         404)
        self.assertEqual(self.c.delete(V + "/kids-watch/chips/%d" % t.id).status_code, 200)
        self.assertFalse(VehicleTracker.objects.filter(pk=t.id).exists())


class NoAsalifyCallsTests(TestCase):
    def test_backend_never_talks_to_asalify(self):
        """'Where to buy' is an app-side outbound link only: no server code
        may call, fetch or embed the shop (asalifymart)."""
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]
        files = [p for d in ("core", "web", "crm", "tracker", "assisto_backend")
                 for p in (root / d).rglob("*.py")]
        hits = [str(p) for p in files
                if "asalifymart" in p.read_text(encoding="utf-8", errors="ignore").lower()
                and p.name != "tests_chipbuy.py"]
        self.assertEqual(hits, [])
