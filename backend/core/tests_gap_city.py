"""gap-city: the CI-only made-up City Service sample (seed_reality -> the
emulator flow) really plans Farmgate -> Motijheel and the sample office,
and the guides return items with coordinates (for "Go by bus / metro")."""
from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import city_service as CS
from core.city_sample import import_sample, sample_net
from core.models import User

FARMGATE = (23.7577, 90.3897)
MOTIJHEEL = (23.7330, 90.4177)
SAMPLE_OFFICE = (23.7787, 90.3790)


class CitySampleTests(TestCase):
    def setUp(self):
        cache.clear()
        CS._NET.clear()
        CS._PKG.clear()
        CS._DIR.clear()
        self.got = import_sample()
        u = User.objects.create_user(name="Sample", phone="01799000301", password="x")
        self.c = APIClient()
        self.c.force_authenticate(u)

    def test_import_counts(self):
        self.assertEqual(self.got["stops"], len(sample_net()["stops"]["rows"]))
        self.assertEqual(self.got["routes"], 4)

    def test_plan_farmgate_motijheel_with_fares(self):
        d = self.c.get("/api/v1/city/plan?from=%s,%s&to=%s,%s&at=10:30" % (FARMGATE + MOTIJHEEL)).json()
        self.assertTrue(d["ok"])
        self.assertIn("cheapest", d["options"])
        legs = [l for o in d["options"].values() for l in o["legs"]]
        self.assertTrue(any(l["mode"] in ("metro", "bus") and l.get("fare") for l in legs))

    def test_office_has_coordinates_and_is_reachable(self):
        items = self.c.get("/api/v1/city/offices?city=dhaka").json()["items"]
        o = [i for i in items if i["id"] == "o-ci-passport"][0]
        self.assertEqual((o["lat"], o["lon"]), SAMPLE_OFFICE)
        d = self.c.get("/api/v1/city/plan?from=%s,%s&to=%s,%s" % (FARMGATE + SAMPLE_OFFICE)).json()
        self.assertTrue(d["ok"])

    def test_search_finds_the_stop_for_voice_ask(self):
        d = self.c.get("/api/v1/city/search?city=dhaka&q=Farmgate").json()
        self.assertTrue(any(s.get("lat") for s in d.get("stops", [])))

    def test_reimport_is_idempotent(self):
        again = import_sample()
        self.assertEqual(again["version"], self.got["version"])
