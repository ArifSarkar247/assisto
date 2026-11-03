"""nearby (owner 3 Nov 18:50): Assisto's own emergency list — import keeps
owner overrides through a refresh, area + version token (offline cache on the
phone), reports queue, sponsored never in emergency, zero Google calls."""
import gzip
import hashlib
import importlib.util
import json
import os
import tempfile
from pathlib import Path
from unittest import mock

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import nearby as NB
from core import nearby_list as NL
from core.models import BusinessProfile, NearbyDataset, NearbyPlace, NearbyReport, User

REPO = Path(__file__).resolve().parents[2]


def _blob(cc, rows):
    doc = {"country": cc, "fields": ["id", "cat", "name", "name_en", "lat", "lon", "phone"],
           "osm_timestamp": "2026-11-01T20:21:00Z", "rows": rows}
    return gzip.compress(json.dumps(doc).encode())


DMCH = ["w100", "hospital", "ঢাকা মেডিকেল কলেজ হাসপাতাল", "Dhaka Medical College Hospital",
        23.7258, 90.3979, "+880 2-55165088"]
SHAHBAG = ["n200", "police", "শাহবাগ থানা", "Shahbag Police Station", 23.7384, 90.3958, ""]
FIRE = ["n300", "fire", "সিদ্দিকবাজার ফায়ার স্টেশন", "", 23.7213, 90.4105, "102"]
FAR = ["n400", "hospital", "চট্টগ্রাম মেডিকেল", "Chittagong Medical College Hospital",
       22.3596, 91.8305, ""]


class ImportOverrideTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_superuser(name="O", phone="01700000701", password="pw-123456")
        NL.import_blob("BD", _blob("BD", [DMCH, SHAHBAG, FIRE, FAR]))

    def test_first_import(self):
        self.assertEqual(NearbyPlace.objects.filter(country="BD").count(), 4)
        ds = NearbyDataset.objects.get(key="BD")
        self.assertEqual(ds.records, 4)
        self.assertEqual(ds.osm_timestamp, "2026-11-01T20:21:00Z")
        self.assertEqual(len(ds.sha256), 64)

    def test_admin_edit_hide_survive_monthly_refresh(self):
        p = NearbyPlace.objects.get(src_id="n200")
        self.assertEqual(NL.admin_edit(p, {"phone": "01320-040000", "name_en": "Shahbag PS"},
                                       self.owner), "")
        h = NearbyPlace.objects.get(src_id="n300")
        NL.admin_hide(h, True, self.owner)
        # refresh: OSM changes the name, drops the fire station (owner hid it)
        # and drops Chittagong (no override -> deleted)
        changed = list(SHAHBAG)
        changed[2] = "শাহবাগ মডেল থানা"
        res = NL.import_rows("BD", [DMCH, changed], force=True)
        self.assertEqual(res["deleted"], 1)
        self.assertEqual(res["kept_overridden"], 1)
        p.refresh_from_db()
        self.assertEqual(p.name, "শাহবাগ মডেল থানা")           # source updated
        self.assertEqual(NL.eff(p)["phone"], "01320-040000")  # override kept
        self.assertEqual(NL.eff(p)["name_en"], "Shahbag PS")
        h.refresh_from_db()
        self.assertTrue(h.hidden and h.gone_upstream)
        self.assertFalse(NearbyPlace.objects.filter(src_id="n400").exists())
        # undo my edits -> the source shows again
        NL.admin_reset(p, self.owner)
        p.refresh_from_db()
        self.assertEqual(NL.eff(p)["phone"], "")

    def test_truncated_file_refused(self):
        rows = [["n%d" % i, "pharmacy", "Ph %d" % i, "", 23.7 + i * 1e-4, 90.4, ""] for i in range(1200)]
        NL.import_rows("BD", rows)
        with self.assertRaises(ValueError):
            NL.import_rows("BD", rows[:100])
        self.assertGreater(NearbyPlace.objects.filter(country="BD").count(), 1000)

    def test_sha_mismatch_and_wrong_country_refused(self):
        with self.assertRaises(ValueError):
            NL.import_blob("BD", _blob("BD", [DMCH]), {"sha256": "0" * 64})
        with self.assertRaises(ValueError):
            NL.import_blob("SA", _blob("BD", [DMCH]))

    def test_bad_rows_dropped(self):
        res = NL.import_rows("BD", [DMCH, SHAHBAG, FIRE, FAR,
                                    ["n9", "restaurant", "x", "", 23.7, 90.4, ""],
                                    ["n8", "hospital", "x", "", 123.7, 90.4, ""], ["bad"]])
        self.assertEqual(res["rows"], 4)


class AreaApiTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01700000702", password="pw-123456")
        self.owner = User.objects.create_superuser(name="O", phone="01700000703", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        NL.import_blob("BD", _blob("BD", [DMCH, SHAHBAG, FIRE, FAR]))

    def test_area_rows_country_and_version_token(self):
        r = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39").json()
        self.assertEqual(r["country"], "BD")
        self.assertIn("OpenStreetMap", r["attribution"])
        names = [x[3] for x in r["rows"]]
        self.assertIn("Dhaka Medical College Hospital", names)
        self.assertNotIn("Chittagong Medical College Hospital", names)   # other area
        self.assertEqual(r["fields"], NL.FIELDS)
        # the phone's cached token -> unchanged (offline cache stays valid)
        tok = r["version"]
        r2 = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39&v=" + tok).json()
        self.assertTrue(r2["unchanged"])
        self.assertNotIn("rows", r2)
        # an owner edit bumps the version -> every phone re-pulls on next open
        p = NearbyPlace.objects.get(src_id="w100")
        NL.admin_edit(p, {"phone": "10666"}, self.owner)
        r3 = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39&v=" + tok).json()
        self.assertFalse(r3["unchanged"])
        row = [x for x in r3["rows"] if x[0] == p.id][0]
        self.assertEqual(row[6], "10666")
        # hidden places leave the list
        NL.admin_hide(p, True, self.owner)
        r4 = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39").json()
        self.assertNotIn(p.id, [x[0] for x in r4["rows"]])

    def test_area_needs_location(self):
        self.assertEqual(self.c.get("/api/v1/nearby/area?lat=x").status_code, 400)
        self.assertEqual(self.c.get("/api/v1/nearby/area?lat=99&lon=1").status_code, 400)

    def test_country_switch_off_hides_it(self):
        NearbyDataset.objects.filter(key="BD").update(enabled=False)
        r = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39").json()
        self.assertEqual(r["rows"], [])
        self.assertEqual(r["country"], "")

    def test_world_country_needs_world_switch(self):
        NL.import_blob("IN", _blob("IN", [["n1", "hospital", "AIIMS", "", 28.567, 77.21, ""]]))
        r = self.c.get("/api/v1/nearby/area?lat=28.56&lon=77.2").json()
        self.assertEqual(r["rows"], [])
        NearbyDataset.objects.update_or_create(key="WORLD", defaults={"enabled": True})
        r = self.c.get("/api/v1/nearby/area?lat=28.56&lon=77.2").json()
        self.assertEqual(len(r["rows"]), 1)
        self.assertEqual(r["country"], "IN")

    def test_report_queue(self):
        p = NearbyPlace.objects.get(src_id="n200")
        r = self.c.post("/api/v1/nearby/report", {"place": p.id, "kind": "wrong_number",
                                                  "phone": "01320-040000 call", "note": "old no"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        rep = NearbyReport.objects.get()
        self.assertEqual(rep.suggested_phone, "01320-040000")
        self.assertEqual(rep.status, "open")
        # same user again -> the same open report, not a duplicate
        self.c.post("/api/v1/nearby/report", {"place": p.id, "note": "again"}, format="json")
        self.assertEqual(NearbyReport.objects.count(), 1)
        self.assertEqual(self.c.post("/api/v1/nearby/report", {"place": 999999},
                                     format="json").status_code, 404)
        # owner fixes it -> the number changes for everyone
        self.assertEqual(NL.resolve_report(rep, "fix", "", self.owner), "")
        p.refresh_from_db()
        self.assertEqual(NL.eff(p)["phone"], "01320-040000")
        rep.refresh_from_db()
        self.assertEqual(rep.status, "fixed")

    def test_report_daily_limit(self):
        p = NearbyPlace.objects.get(src_id="n200")
        for _ in range(NL.REPORTS_PER_DAY):
            NearbyReport.objects.create(place=p, user=self.u, status="fixed")
        r = self.c.post("/api/v1/nearby/report", {"place": p.id}, format="json")
        self.assertEqual(r.status_code, 429)

    def test_sponsored_flag_off_and_never_in_emergency(self):
        bu = User.objects.create_user(name="Shop", phone="01700000704", password="pw-123456")
        BusinessProfile.objects.create(user=bu, shop_name="Rahim Store")
        p, err = NL.admin_add({"category": "shop", "business_user": bu.id, "name": "Rahim Store",
                               "lat": 23.741, "lon": 90.391, "country": "BD",
                               "sponsored_days": 30}, self.owner)
        self.assertEqual(err, "")
        # a business can never be an emergency row
        _, err = NL.admin_add({"category": "hospital", "business_user": bu.id, "name": "X",
                               "lat": 23.7, "lon": 90.4}, self.owner)
        self.assertEqual(err, "bad_business")
        r = self.c.get("/api/v1/nearby/area?lat=23.74&lon=90.39").json()
        self.assertNotIn(p.id, [x[0] for x in r["rows"]])
        self.assertTrue(all(x[1] in NL.EMERGENCY for x in r["rows"]))
        # switch default OFF -> nothing
        r = self.c.get("/api/v1/nearby/sponsored?lat=23.74&lon=90.39&cat=shop").json()
        self.assertEqual(r["places"], [])
        with mock.patch.object(FF, "is_on", return_value=True):
            r = self.c.get("/api/v1/nearby/sponsored?lat=23.74&lon=90.39&cat=shop").json()
            self.assertEqual(r["places"][0]["name"], "Rahim Store")
            self.assertTrue(r["places"][0]["sponsored"])
            r = self.c.get("/api/v1/nearby/sponsored?lat=23.74&lon=90.39&cat=hospital").json()
            self.assertEqual(r["places"], [])

    def test_sponsored_flag_registered_default_off(self):
        self.assertFalse(FF.meta("nearby_sponsored")["default_on"])

    def test_legacy_nearby_uses_own_list_first(self):
        NB._CACHE.clear()
        with mock.patch.object(NB, "_osm", side_effect=AssertionError("no overpass")):
            res, src = NB.search(23.74, 90.39, "police", lang="en")
        self.assertEqual(src, "assisto")
        self.assertEqual(res[0]["name"], "Shahbag Police Station")
        self.assertEqual(NB.attribution(src), NB.OSM_ATTRIBUTION)


class ImportTickTests(TestCase):
    def _manifest(self, blob):
        return json.dumps({"countries": {"BD": {"file": "nearby_BD.json.gz",
                                                "sha256": hashlib.sha256(blob).hexdigest(),
                                                "bytes": len(blob), "records": 4}}}).encode()

    def test_tick_imports_one_then_idles(self):
        blob = _blob("BD", [DMCH, SHAHBAG, FIRE, FAR])
        urls = []

        def fake(url, limit=0, timeout=0):
            urls.append(url)
            return self._manifest(blob) if url.endswith("manifest.json") else blob
        with mock.patch.object(NL, "_fetch", side_effect=fake):
            self.assertTrue(NL.tick().startswith("imported BD"))
            self.assertEqual(NL.tick(force_check=True), "up_to_date")
            self.assertEqual(NL.tick(), "idle")          # checked < 6 h ago
        self.assertTrue(all(u.startswith(NL.DEFAULT_BASE) for u in urls))
        self.assertEqual(NearbyDataset.objects.get(key="BD").records, 4)

    def test_failed_file_not_retried_every_minute(self):
        blob = _blob("BD", [DMCH])

        def fake(url, limit=0, timeout=0):
            return self._manifest(blob) if url.endswith("manifest.json") else b"broken"
        with mock.patch.object(NL, "_fetch", side_effect=fake):
            self.assertEqual(NL.tick(), "error BD")
            self.assertEqual(NL.pending(json.loads(self._manifest(blob))), [])

    def test_manifest_down_is_quiet(self):
        with mock.patch.object(NL, "_fetch", side_effect=OSError("down")):
            self.assertEqual(NL.tick(), "manifest_error")

    def test_command_local_file(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "nearby_BD.json.gz")
        with open(p, "wb") as fh:
            fh.write(_blob("BD", [DMCH]))
        call_command("nearby_import", file=p, country="BD", stdout=open(os.devnull, "w"))
        self.assertEqual(NearbyPlace.objects.count(), 1)

    def test_fetch_never_reaches_network_in_tests(self):
        with self.assertRaises(OSError):
            NL._fetch(NL.DEFAULT_BASE + "manifest.json")


class NoGoogleTests(SimpleTestCase):
    def test_no_google_places_calls_anywhere_in_nearby(self):
        for f in ("nearby.py", "nearby_list.py", "views_nearby.py"):
            src = (REPO / "backend" / "core" / f).read_text()
            self.assertNotIn("googleapis", src, f)
            self.assertNotIn("nearbysearch", src.lower(), f)
            self.assertNotIn("google_places", src, f)
        app = (REPO / "app" / "lib" / "nearby").glob("*.dart")
        for f in app:
            self.assertNotIn("googleapis", f.read_text(), f.name)

    def test_search_never_opens_a_google_url(self):
        opened = []

        def fake_open(req, timeout=0):
            opened.append(getattr(req, "full_url", str(req)))
            raise OSError("offline")
        with mock.patch("urllib.request.urlopen", side_effect=fake_open), \
                mock.patch.object(NB, "_own", return_value=[]):
            NB._CACHE.clear()
            NB.search(23.7, 90.4, "hospital")
            NB.search(23.7, 90.4, "restaurant")
        self.assertFalse([u for u in opened if "google" in u], opened)


class ExtractScriptTests(SimpleTestCase):
    """deploy/nearby/build_extract.py (runs in GitHub Actions only)."""

    def _mod(self):
        spec = importlib.util.spec_from_file_location(
            "nearby_build_extract", REPO / "deploy" / "nearby" / "build_extract.py")
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    def test_categories_and_rows(self):
        m = self._mod()
        line = "\x1e" + json.dumps({"type": "Feature", "geometry": {
            "type": "Polygon", "coordinates": [[[90.0, 23.0], [90.002, 23.0], [90.002, 23.002],
                                                [90.0, 23.002], [90.0, 23.0]]]},
            "properties": {"@type": "way", "@id": 5, "amenity": "hospital",
                           "name": "হাসপাতাল", "name:en": "Hospital X",
                           "contact:phone": "+880 1700-000000;+880 2 1"}})
        r = m.parse_feature(line)
        self.assertEqual(r[0], "w5")
        self.assertEqual(r[1], "hospital")
        self.assertEqual(r[3], "Hospital X")
        self.assertAlmostEqual(r[4], 23.001, places=4)
        self.assertEqual(r[6], "+880 1700-000000")
        self.assertEqual(m.category({"emergency": "ambulance_station"}), "ambulance")
        self.assertEqual(m.category({"amenity": "fire_station"}), "fire")
        self.assertIsNone(m.category({"amenity": "restaurant"}))
        # an unnamed pharmacy is dropped, an unnamed police station kept
        unnamed = lambda a: json.dumps({"geometry": {"type": "Point", "coordinates": [90, 23]},  # noqa: E731
                                        "properties": {"@type": "node", "@id": 1, "amenity": a}})
        self.assertIsNone(m.parse_feature(unnamed("pharmacy")))
        self.assertEqual(m.parse_feature(unnamed("police"))[1], "police")

    def test_finalize_merges_manifest(self):
        m = self._mod()
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "rows_BD.jsonl"), "w") as fh:
            fh.write(json.dumps(DMCH) + "\n" + json.dumps(DMCH) + "\n")
        with open(os.path.join(d, "regions.jsonl"), "w") as fh:
            fh.write(json.dumps({"region": "asia/bangladesh", "osm_timestamp": "t",
                                 "countries": ["BD"]}) + "\n")
        prev = os.path.join(d, "prev.json")
        with open(prev, "w") as fh:
            json.dump({"countries": {"SA": {"file": "nearby_SA.json.gz", "records": 9,
                                            "bytes": 1, "sha256": "x"}}}, fh)
        out = os.path.join(d, "manifest.json")
        m.main(["finalize", "--out", d, "--manifest-in", prev, "--manifest-out", out])
        man = json.load(open(out))
        self.assertEqual(set(man["countries"]), {"BD", "SA"})      # SA kept
        self.assertEqual(man["countries"]["BD"]["records"], 1)     # deduped
        self.assertIn("ODbL", man["licence"])
        blob = open(os.path.join(d, "nearby_BD.json.gz"), "rb").read()
        self.assertEqual(NL.parse_file(blob, "BD")["rows"][0][0], "w100")
