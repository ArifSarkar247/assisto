"""citydata (owner 9 Nov 11:45): Owner Admin -> City data (corrections review,
live reports, data/coverage/top-50, fares + complaint number, learned
findings; audited; bn/en)."""
from core import city_service as CS
from core.models import CityCorrection, CityDataset, CityLearned, CityLiveReport, OwnerAudit, User
from core.tests_city import blob
from web.tests_o2_owner_admin import OwnerBase


class CityOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        CS._NET.clear()
        CS._PKG.clear()
        CS.import_city("dhaka", blob(), b"", {"top50": {"pass": 41, "total": 50, "p95_ms": 120,
                                                        "trips": [{"trip": "A -> B", "pass": False,
                                                                   "why": "no route"}]},
                                              "gap_counts": {"metro_gates_not_mapped": 3}})
        self.user = User.objects.create_user(name="R", phone="01788000171", password="x")
        self.ready()

    def test_pages_render_bn_en(self):
        for tab in ("fixes", "live", "data", "coverage", "fares", "learned"):
            r = self.c.get("/owner/city?tab=%s&lang=en" % tab)
            self.assertEqual(r.status_code, 200, tab)
        r = self.c.get("/owner/city?tab=data&lang=en")
        self.assertContains(r, "41/50")
        self.assertContains(r, "A -&gt; B")
        self.assertContains(r, "metro_gates_not_mapped")
        r = self.c.get("/owner/city?tab=data&lang=bn")
        self.assertContains(r, "শহরের তথ্য")
        r = self.c.get("/owner/city?tab=fares&lang=en")
        self.assertContains(r, "brta.gov.bd")
        self.assertContains(r, "333")
        r = self.c.get("/owner/city?tab=coverage&lang=en")
        self.assertContains(r, "Motijheel")

    def test_review_correction_changes_data(self):
        c, _ = CS.correction(self.user, "dhaka", {"target": "route", "target_id": "busB-a",
                                                  "kind": "wrong_name", "text": "name is Gulshan Chaka 2"})
        r = self.c.get("/owner/city?tab=fixes&lang=en")
        self.assertContains(r, "name is Gulshan Chaka 2")
        v0 = CityDataset.objects.get(city="dhaka").ov_version
        r = self.post("/owner/city/fix/%d" % c.pk, {"decision": "accept", "action": "edit_route",
                                                    "id": "busB-a", "name": "Gulshan Chaka 2"})
        self.assertIn("m=saved", r["Location"])
        c.refresh_from_db()
        self.assertEqual(c.status, "accepted")
        self.assertGreater(CityDataset.objects.get(city="dhaka").ov_version, v0)
        self.assertEqual(CS.route_detail("dhaka", "busB-a")["name"], "Gulshan Chaka 2")
        c2, _ = CS.correction(self.user, "dhaka", {"kind": "other", "text": "spam"})
        self.post("/owner/city/fix/%d" % c2.pk, {"decision": "reject"})
        c2.refresh_from_db()
        self.assertEqual(c2.status, "rejected")
        self.assertTrue(OwnerAudit.objects.filter(action="city_fix.accept").exists())

    def test_rates_complaint_live_learned_dataset(self):
        r = self.post("/owner/city/change", {"city": "dhaka", "action": "rate", "mode": "bus",
                                             "v_per_km_high": "2.80", "checked": "2026-11-10",
                                             "back": "/owner/city?tab=fares"})
        self.assertIn("m=saved", r["Location"])
        nw = CS.network("dhaka")[0]
        self.assertEqual((nw.rates["bus"]["per_km_high"], nw.rates["bus"]["checked"]), (2.8, "2026-11-10"))
        self.post("/owner/city/change", {"city": "dhaka", "action": "complaint", "number": "16xxx"})
        self.assertEqual(CS.complaint(CityDataset.objects.get(city="dhaka").overrides)["number"], "16xxx")
        lr, _ = CS.live_report(self.user, "road_closed", 23.75, 90.39)
        self.post("/owner/city/live/%d" % lr.pk, {"action": "hide"})
        self.assertTrue(CityLiveReport.objects.get(pk=lr.pk).hidden)
        l = CityLearned.objects.create(city="dhaka", kind="stop", key="new:23.75:90.39", trips=1)
        self.post("/owner/city/learned/%d" % l.pk, {"action": "reject"})
        self.assertEqual(CityLearned.objects.get(pk=l.pk).status, "rejected")
        self.post("/owner/city/dataset", {"city": "dhaka", "action": "off"})
        self.assertIsNone(CS.network("dhaka"))
        self.post("/owner/city/dataset", {"city": "dhaka", "action": "on"})
        self.assertIsNotNone(CS.network("dhaka"))
        self.assertIn("m=invalid", self.post("/owner/city/change", {"city": "mars", "action": "rate"})["Location"])
        self.assertTrue(OwnerAudit.objects.filter(action="city_change.rate").exists())
