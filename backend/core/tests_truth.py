"""TRUTH — owner FINAL ORDER 27 Oct (top rule): "no demo or fake data
anywhere, real licensed data sources, honest empty states, never promise what
is not built."

* Guard: known fake-data patterns may not come back into non-test backend code
  (fake courier tracking ids / payment links, made-up phone numbers, a fixed
  "ETA"), except through the explicit allow-list below (shrink only).
* Feature visibility follows the real data source (feature_flags.SOURCES):
  no dictionary dataset / no mail fetch -> hidden for users, preview for the
  owner, back by itself once the source is real. No live flag is touched.
* Endpoints: medicine records withheld while only the sample exists; Nearby
  carries the source licence; OSM queries are polite and cover every
  category the app offers; police stations come from the live layer.
"""
import re
from pathlib import Path
from unittest import mock

from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.models import User

CORE = Path(__file__).resolve().parent

BANNED = {
    r"-MOCK-|MOCK-PAY-LINK|licensed-partner\.example": "fake tracking id / payment link",
    r"\+8801[0-9]00000+\b": "made-up phone number",
    r"MOCK_ETA_MIN\s*=": "fixed fake travel time",
}
# file (relative to core/) -> reason. Shrink only.
ALLOW = {
    # Not served by any endpoint since truth (police stations now use the
    # live core.nearby layer); kept only for its pure-function snippet tests.
    "logic/nearby.py": "unserved curated sample, see logic/nearby_tests_snippets.py",
    # meetings.travel_eta is a pure mirror no view imports; the app no longer
    # shows any ETA (meet_model.travelEta -> none).
    "logic/meetings.py": "unserved pure mirror",
    # self-test channels only (TEST- ids, mock:true, courier_live False).
    "bizagent_g1_service.py": "self-test booking, never a real channel",
    # build_request() dry run to validate the SMS config; never sent/shown.
    "sms_gateway.py": "config dry-run number",
}


def _is_test(p):
    n = p.name
    return (n.startswith("tests") or n.endswith("_tests_snippets.py")
            or "test" in p.parts[-2:-1] or n.startswith("test_"))


class GuardTests(TestCase):
    def test_no_fake_data_patterns(self):
        hits = []
        for p in CORE.rglob("*.py"):
            rel = p.relative_to(CORE).as_posix()
            if _is_test(p) or "migrations/" in rel or rel in ALLOW:
                continue
            for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                code = line.split("#", 1)[0]
                for pat, why in BANNED.items():
                    if re.search(pat, code):
                        hits.append("%s:%d %s: %s" % (rel, n, why, line.strip()))
        self.assertEqual(hits, [], "fake data is back (TRUTH rule):\n" + "\n".join(hits))

    def test_allow_list_files_exist(self):
        for rel in ALLOW:
            self.assertTrue((CORE / rel).exists(), rel)


class SourceGateTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01700000091", password="pw-123456")
        self.owner = User.objects.create_superuser(name="O", phone="01700000092",
                                                   password="pw-123456")

    def tearDown(self):
        FF.invalidate()
        from core.logic import dictionary
        dictionary.reset_to_sample()

    def test_registry_keys_and_dart_mirror(self):
        self.assertLessEqual(set(FF.SOURCE_REQUIRED), set(FF.KEYS))
        self.assertLessEqual(set(FF.SOURCE_REQUIRED.values()), set(FF.SOURCES))
        src = (CORE.parents[1] / "app" / "lib" / "feature_registry.dart").read_text()
        m = re.search(r"kFeatureNeedsSource = \{([^}]*)\}", src)
        self.assertIsNotNone(m)
        self.assertEqual(set(re.findall(r"'(\w+)'", m.group(1))), set(FF.SOURCE_REQUIRED))

    def test_no_source_hidden_for_users_preview_for_owner(self):
        feats, preview = FF.resolve(self.u, play=True)
        self.assertFalse(feats["dictionary"])
        self.assertFalse(feats["ai_inbox"])
        self.assertEqual(preview, [])
        feats, preview = FF.resolve(self.owner, play=True)
        self.assertTrue(feats["dictionary"])
        self.assertIn("dictionary", preview)
        self.assertIn("ai_inbox", preview)
        # other features are untouched
        self.assertTrue(FF.resolve(self.u)[0]["money"])

    def test_real_source_brings_it_back(self):
        from core.logic import dictionary
        dictionary.load_dataset([{"en": "water", "bn": "পানি"}], "Open dataset (CC BY-SA)")
        self.assertTrue(FF.is_on("dictionary", self.u))
        self.assertFalse(FF.is_on("ai_inbox", self.u))   # still no mail fetch

    def test_broken_check_never_shows(self):
        with mock.patch.dict(FF.SOURCES, {"dictionary_dataset": lambda: 1 / 0}):
            self.assertFalse(FF.is_on("dictionary", self.u))


class EndpointTruthTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="E", phone="01700000093", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_medicine_sample_records_withheld(self):
        from core.logic import medicine_db
        self.assertTrue(medicine_db.is_sample())
        r = self.c.get("/api/v1/medicine-db/search?q=napa").json()
        self.assertEqual(r["results"], [])
        self.assertEqual(r["meta"]["sample_notice"], "")
        self.assertTrue(r["meta"]["withheld"])
        lk = self.c.get("/api/v1/medicine-db/lookup?brand=Napa").json()
        self.assertFalse(lk["available"])

    def test_nearby_carries_licence_and_source_down_is_honest(self):
        rows = [{"name": "X", "lat": 23.7, "lon": 90.4, "distance_m": 10}]
        with mock.patch("core.nearby.search", return_value=(rows, "osm")):
            r = self.c.get("/api/v1/nearby?lat=23.7&lon=90.4&type=fire")
        self.assertEqual(r.status_code, 200)
        self.assertIn("OpenStreetMap", r.json()["attribution"])
        with mock.patch("core.nearby.search", side_effect=OSError("down")):
            r = self.c.get("/api/v1/nearby?lat=23.7&lon=90.4&type=fire")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["places"], [])
        self.assertEqual(r.json()["error"], "source_down")

    def test_osm_query_covers_every_app_category_and_identifies_itself(self):
        from core import nearby
        for t in ("hospital", "pharmacy", "atm", "police", "fire", "transport",
                  "fuel", "restaurant", "mosque", "govt"):
            self.assertIn(t, nearby._OSM_FILTER, t)
            self.assertIn(t, nearby._PLACES_TYPE, t)
        self.assertIn("lifeassisto.com", nearby._UA)
        seen = {}

        def fake_get(url, timeout=20):
            seen["url"] = url
            return '{"elements": [{"center": {"lat": 23.71, "lon": 90.41}, "tags": {"name": "Fire Stn"}}]}'
        with mock.patch.object(nearby, "_get", fake_get), \
                mock.patch.object(nearby, "_LAST_OSM", [0.0]):
            out = nearby._osm(23.7, 90.4, "fire")
        self.assertIn("fire_station", seen["url"])
        self.assertIn("out%20center", seen["url"])
        self.assertEqual(out[0]["name"], "Fire Stn")      # area mapped -> center used
        self.assertIsNone(out[0]["rating"])               # never invented
