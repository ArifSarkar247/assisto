"""train-data (Train Tracker V2, part A): every official Bangladesh Railway
train is loaded — the CI completeness check. Owner: "Rangpur Express is
missing — not acceptable." These tests fail if any train of the committed
official list (data/train/br_official.json) does not reach the database."""
import datetime
import gzip
import json
from io import StringIO

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, transaction
from django.test import SimpleTestCase, TestCase

from core import train_data
from core.models import RailSegment, RailStation, RailTrain, RailTrainStop, TrainPassing


def _m(v):
    return int(v[:2]) * 60 + int(v[3:])


class OfficialDataIntegrityTests(SimpleTestCase):
    """The committed files themselves (no DB)."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.official = train_data.official()["trains"]
        cls.trains = train_data._read("br_trains.json")["trains"]
        cls.stations = {s["code"]: s for s in train_data._read("br_stations.json")["stations"]}
        cls.segs = {f["properties"]["id"] for f in train_data._read("br_segments.geojson")["features"]}

    def test_every_official_train_is_in_the_load_file(self):
        self.assertEqual([t["no"] for t in self.official], [t["no"] for t in self.trains])
        self.assertEqual(len(set(t["no"] for t in self.official)), len(self.official), "duplicate train number")
        self.assertGreaterEqual(len(self.official), 300)

    def test_rangpur_express_both_directions_in_official_list(self):
        by = {t["no"]: t for t in self.official}
        self.assertEqual(by["771"]["name_bn"], "রংপুর এক্সপ্রেস")
        self.assertEqual((by["771"]["origin"], by["771"]["destination"]), ("ঢাকা", "রংপুর"))
        self.assertEqual((by["772"]["origin"], by["772"]["destination"]), ("রংপুর", "ঢাকা"))
        self.assertEqual(by["771"]["stops"][0]["dep"], "09:10")
        self.assertEqual(by["771"]["stops"][-1]["arr"], "19:00")
        self.assertEqual(by["772"]["stops"][0]["dep"], "20:00")
        self.assertEqual(by["772"]["stops"][-1]["arr"], "06:00")
        self.assertEqual(by["771"]["off_days"], [0])   # Monday
        self.assertEqual(by["772"]["off_days"], [6])   # Sunday

    def test_every_train_has_source_and_sane_stops(self):
        for t in self.trains:
            self.assertTrue(t["source"]["url"].startswith("https://railway.gov.bd/"), t["no"])
            self.assertTrue(t["source"]["fetched"], t["no"])
            self.assertTrue(t["name_bn"] and t["name_en"], t["no"])
            self.assertIn(t["kind"], train_data.KIND_CODE, t["no"])
            self.assertIn(t["status"], ("running", "suspended", "proposed"), t["no"])
            for d in t["off_days"]:
                self.assertIn(d, range(7))
            codes = [s["station"] for s in t["stops"]]
            for c in codes:
                self.assertIn(c, self.stations, t["no"])
            self.assertEqual(len(codes), len(set(codes)), "station repeats in %s" % t["no"])
            if t["status"] == "running":
                self.assertGreaterEqual(len(t["stops"]), 2, t["no"])
                self.assertIsNone(t["stops"][0]["arr"], t["no"])
                self.assertTrue(t["stops"][0]["dep"], t["no"])
                self.assertTrue(t["stops"][-1]["arr"], t["no"])
                total, prev = 0, None
                for s in t["stops"]:
                    for f in ("arr", "dep"):
                        if s.get(f):
                            if prev is not None:
                                total += (_m(s[f]) - prev) % 1440
                            prev = _m(s[f])
                self.assertLess(total, 1440, "%s runs a day or more" % t["no"])
            kms = [s["km"] for s in t["stops"] if s.get("km") is not None]
            self.assertEqual(kms, sorted(kms), "km must grow along %s" % t["no"])

    def test_rail_segments_cover_running_trains(self):
        missing = []
        for t in self.trains:
            if t["status"] != "running":
                continue
            for a, b in zip(t["stops"], t["stops"][1:]):
                if "%s|%s" % (a["station"], b["station"]) not in self.segs:
                    missing.append("%s %s|%s" % (t["no"], a["station"], b["station"]))
        self.assertEqual(missing, [])

    def test_stations_have_coordinates_with_source(self):
        for s in self.stations.values():
            if s["district"] == "India":
                continue
            self.assertIsNotNone(s["lat"], s["code"])
            self.assertTrue(20.5 < s["lat"] < 26.7 and 88.0 < s["lng"] < 92.7, s["code"])
            self.assertTrue(s["coord_source"].startswith(("osm:", "estimated:")), s["code"])

    def test_cross_border_trains_marked_suspended(self):
        names = {t["name_bn"] for t in self.official if t["kind"] == "international"}
        self.assertEqual(names, set(train_data.CROSS_BORDER))
        for t in self.official:
            if t["kind"] == "international":
                self.assertEqual(t["status"], "suspended")
                self.assertTrue(t["bd_section_only"])
                self.assertIn("স্থগিত", t["status_note"])

    def test_offline_bundle_small_and_complete(self):
        raw, gz, ver = train_data.offline_bundle()
        self.assertLess(len(gz), 60 * 1024)
        body = json.loads(gzip.decompress(gz))
        self.assertEqual(body["ver"], ver)
        nos = {t[0] for t in body["tr"]}
        self.assertEqual(nos, {t["no"] for t in self.official})
        r = next(t for t in body["tr"] if t[0] == "771")
        self.assertEqual(r[5], 1)                       # off Monday -> bit 0
        self.assertEqual(r[6][0][2], 9 * 60 + 10)       # leaves Dhaka 09:10


class LoadIntoDatabaseTests(TestCase):
    """The CI completeness check: load, then every official train is in the DB."""

    @classmethod
    def setUpTestData(cls):
        cls.counts = train_data.load()

    def test_all_official_trains_loaded(self):
        self.assertEqual(train_data.check(), [])
        self.assertEqual(RailTrain.objects.count(), len(train_data.official_numbers()))
        self.assertEqual(set(RailTrain.objects.values_list("number", flat=True)),
                         set(train_data.official_numbers()))
        self.assertEqual(RailStation.objects.count(), self.counts["stations"])
        self.assertEqual(RailSegment.objects.count(), self.counts["segments"])

    def test_rangpur_express_both_directions_in_db(self):
        up = RailTrain.objects.get(number="771")
        down = RailTrain.objects.get(number="772")
        self.assertEqual((up.origin.name_bn, up.destination.name_bn), ("ঢাকা", "রংপুর"))
        self.assertEqual((down.origin.name_bn, down.destination.name_bn), ("রংপুর", "ঢাকা"))
        self.assertEqual(up.name_en, "Rangpur Express")
        stops = list(up.stops.select_related("station"))
        codes = [s.station.code for s in stops]
        for st in ("bogura", "gaibandha", "kaunia", "santahar"):
            self.assertIn(st, codes)
        self.assertEqual(stops[0].dep_time, datetime.time(9, 10))
        self.assertEqual(stops[-1].arr_time, datetime.time(19, 0))
        self.assertGreater(stops[-1].km_from_origin, 400)
        dstops = list(down.stops.all())
        self.assertEqual(dstops[-1].arr_time, datetime.time(6, 0))
        self.assertEqual(dstops[-1].arr_day, 1)          # arrives the next morning
        self.assertEqual(up.source_url.split("/pages/")[0], "https://railway.gov.bd")

    def test_check_fails_when_a_train_is_missing(self):
        RailTrain.objects.filter(number="772").delete()
        problems = train_data.check()
        self.assertTrue(any("772" in p for p in problems))
        with self.assertRaises(CommandError):
            call_command("load_bd_trains", "--check", stdout=StringIO())

    def test_reload_is_idempotent_and_restores(self):
        RailTrain.objects.filter(number="771").update(name_bn="x")
        train_data.load()
        self.assertEqual(RailTrain.objects.get(number="771").name_bn, "রংপুর এক্সপ্রেস")
        self.assertEqual(RailTrain.objects.count(), len(train_data.official_numbers()))
        self.assertEqual(RailTrainStop.objects.filter(train__number="771").count(),
                         len(next(t for t in train_data.official()["trains"] if t["no"] == "771")["stops"]))

    def test_withdrawn_train_is_kept_with_history(self):
        st = RailStation.objects.get(code="rangpur")
        extra = RailTrain.objects.create(number="999", name_bn="পরীক্ষা", name_en="Test", kind="local",
                                         zone="west", origin=st, destination=st,
                                         source_url="https://railway.gov.bd/")
        TrainPassing.objects.create(train=extra, service_date=datetime.date(2026, 11, 16), station=st,
                                    seq=0, weekday=0, source="checkin")
        train_data.load()
        extra.refresh_from_db()
        self.assertEqual(extra.status, "withdrawn")
        self.assertEqual(extra.passings.count(), 1)

    def test_command_loads_and_reports(self):
        out = StringIO()
        call_command("load_bd_trains", stdout=out)
        self.assertIn("771/772 OK", out.getvalue())
        out = StringIO()
        call_command("load_bd_trains", "--bundle-size", stdout=out)
        self.assertIn("gzip", out.getvalue())

    def test_passing_history_one_row_per_train_date_station(self):
        t = RailTrain.objects.get(number="771")
        st = RailStation.objects.get(code="bogura")
        day = datetime.date(2026, 11, 17)
        TrainPassing.objects.create(train=t, service_date=day, station=st, seq=7, weekday=day.weekday(),
                                    delay_min=12, source="rider_gps", confirmations=3, confidence=0.8)
        with self.assertRaises(IntegrityError), transaction.atomic():
            TrainPassing.objects.create(train=t, service_date=day, station=st, seq=7, weekday=day.weekday(),
                                        source="checkin")
