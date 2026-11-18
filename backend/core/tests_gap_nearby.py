"""gap-nearby (18 Nov): Nearby phone-number source per row, the CI-only
nearby sample, and City Service station-to-station metro fares (official
chart online AND in the offline package, station km along the line)."""
import gzip
import json

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import city_service as CS
from core import nearby_list as NL
from core.citytransit import fares as F
from core.city_sample import import_sample as city_sample
from core.models import NearbyPlace, User
from core.nearby_sample import import_sample as nearby_sample

FARMGATE = (23.7577, 90.3897)


class NearbyPhoneSourceTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01799000401", password="pw-123456")
        self.owner = User.objects.create_superuser(name="O", phone="01799000402", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        nearby_sample()

    def _rows(self):
        r = self.c.get("/api/v1/nearby/area?lat=%s&lon=%s" % FARMGATE).json()
        self.assertEqual(r["fields"][-1], "phone_src")
        return {x[0]: x for x in r["rows"]}

    def test_sample_loads_with_unnamed_place_and_sourced_number(self):
        rows = self._rows()
        self.assertEqual(len(rows), 5)
        police = NearbyPlace.objects.get(src_id="s-p1")
        self.assertEqual(rows[police.id][6], "999")
        self.assertEqual(rows[police.id][8], "osm")       # the source's own number
        h3 = NearbyPlace.objects.get(src_id="s-h3")
        self.assertEqual(rows[h3.id][2:4], ["", ""])      # the app labels it, never invents
        self.assertEqual(rows[h3.id][8], "")              # no number -> no number source

    def test_owner_corrected_number_says_admin(self):
        p = NearbyPlace.objects.get(src_id="s-h1")
        NL.admin_edit(p, {"phone": "10666"}, self.owner)
        row = self._rows()[p.id]
        self.assertEqual((row[6], row[7], row[8]), ("10666", "osm", "admin"))

    def test_sample_reimport_is_idempotent(self):
        nearby_sample()
        self.assertEqual(NearbyPlace.objects.filter(src_id__startswith="s-").count(), 5)


class MetroPairFareTests(TestCase):
    def setUp(self):
        cache.clear()
        CS._NET.clear()
        CS._PKG.clear()
        city_sample()
        u = User.objects.create_user(name="M", phone="01799000403", password="x")
        self.c = APIClient()
        self.c.force_authenticate(u)

    def test_official_chart_pair(self):
        # DTCA chart (fares.METRO_CHART): Uttara North <-> Agargaon = Tk 60
        f = F.metro(0, "UTN", "AGA")
        self.assertEqual((f["low"], f["basis"], f["card"]), (60, "chart", 54))
        self.assertEqual(F.metro(0, "AGA", "UTN")["low"], 60)   # either direction

    def test_metro_info_has_chart_and_station_km_in_line_order(self):
        m = CS.metro_info("dhaka")
        chart = {(x["a"], x["b"]): x["tk"] for x in m["fare"]["chart"]}
        self.assertEqual(chart[("AGA", "UTN")], 60)
        st = m["stations"]
        self.assertEqual([s["code"] for s in st][:2], ["UTN", "AGA"])
        kms = [s["km"] for s in st]
        self.assertEqual(kms[0], 0)
        self.assertEqual(kms, sorted(kms))
        self.assertTrue(all(k >= 0 for k in kms))

    def test_offline_package_carries_the_chart(self):
        _, gz = CS.package("dhaka")
        doc = json.loads(gzip.decompress(gz))
        chart = doc["rates"]["metro"]["chart"]
        self.assertIn({"a": "AGA", "b": "UTN", "tk": 60}, chart)
        # the rate rule still travels with it (pairs not on the chart)
        self.assertEqual(doc["rates"]["metro"]["per_km"], 5.0)

    def test_metro_endpoint_returns_km(self):
        d = self.c.get("/api/v1/city/metro?city=dhaka").json()
        self.assertIn("km", d["stations"][1])
