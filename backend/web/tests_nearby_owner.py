"""nearby (owner 3 Nov 18:50): Owner Admin -> Nearby list (search, add,
edit, hide, report queue, datasets / world switch; audited; bn/en)."""
import gzip
import json

from core import nearby_list as NL
from core.models import NearbyDataset, NearbyPlace, NearbyReport, OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase


def _blob(rows):
    return gzip.compress(json.dumps({"country": "BD", "fields": ["id", "cat", "name", "name_en",
                                                                 "lat", "lon", "phone"],
                                     "rows": rows}).encode())


class NearbyOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        NL.import_blob("BD", _blob([
            ["w1", "hospital", "ঢাকা মেডিকেল", "Dhaka Medical College Hospital", 23.7258, 90.3979, ""],
            ["n2", "police", "শাহবাগ থানা", "Shahbag Police Station", 23.7384, 90.3958, "999"]]))
        self.user = User.objects.create_user(name="R", phone="01788000071", password="x")
        self.ready()

    def test_page_search_and_source(self):
        r = self.c.get("/owner/nearby?lang=en&q=Dhaka")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Dhaka Medical College Hospital")
        self.assertContains(r, "openstreetmap.org/way/1")
        self.assertNotContains(r, "Shahbag Police Station")
        r = self.c.get("/owner/nearby?lang=bn&tab=datasets")
        self.assertContains(r, "কাছেপিঠের তালিকা")
        self.assertContains(r, "<b>BD</b>")

    def test_edit_hide_add_audited_and_survive_refresh(self):
        p = NearbyPlace.objects.get(src_id="w1")
        v0 = NearbyDataset.objects.get(key="BD").version
        r = self.post("/owner/nearby/%d" % p.pk, {"action": "save", "name": "ঢাকা মেডিকেল",
                                                  "name_en": "DMCH", "phone": "+880 2-55165088",
                                                  "lat": "23.7258", "lon": "90.3979"})
        self.assertEqual(r.status_code, 302)
        self.assertGreater(NearbyDataset.objects.get(key="BD").version, v0)
        self.post("/owner/nearby/%d" % NearbyPlace.objects.get(src_id="n2").pk, {"action": "hide"})
        NL.import_rows("BD", [["w1", "hospital", "ঢাকা মেডিকেল কলেজ", "Dhaka Medical College Hospital",
                               23.7258, 90.3979, ""],
                              ["n2", "police", "শাহবাগ থানা", "Shahbag Police Station", 23.7384,
                               90.3958, "999"]])
        p.refresh_from_db()
        self.assertEqual(NL.eff(p)["name_en"], "DMCH")
        self.assertEqual(NL.eff(p)["phone"], "+880 2-55165088")
        self.assertTrue(NearbyPlace.objects.get(src_id="n2").hidden)
        r = self.post("/owner/nearby/add", {"category": "ambulance", "name": "Ambulance Point",
                                            "lat": "23.75", "lon": "90.39", "country": "BD",
                                            "phone": "01700000000"})
        self.assertIn("m=saved", r["Location"])
        self.assertTrue(NearbyPlace.objects.filter(source="admin", name="Ambulance Point").exists())
        self.assertIn("m=invalid", self.post("/owner/nearby/add", {"category": "restaurant",
                                                                   "name": "x", "lat": "1",
                                                                   "lon": "1"})["Location"])
        self.assertTrue(OwnerAudit.objects.filter(action="nearby_place.save").exists())
        self.assertTrue(OwnerAudit.objects.filter(action="nearby_place.add").exists())
        self.assertEqual(self.post("/owner/nearby/999999", {"action": "hide"}).status_code, 404)

    def test_report_queue_fix(self):
        p = NearbyPlace.objects.get(src_id="w1")
        rep, _ = NL.report(self.user, p.pk, phone="01711-111111", note="number off")
        r = self.c.get("/owner/nearby?tab=reports&lang=en")
        self.assertContains(r, "number off")
        self.assertContains(r, "01711-111111")
        self.post("/owner/nearby/report/%d" % rep.pk, {"action": "fix", "phone": "01711-111111"})
        rep.refresh_from_db()
        p.refresh_from_db()
        self.assertEqual(rep.status, "fixed")
        self.assertEqual(NL.eff(p)["phone"], "01711-111111")
        self.assertFalse(NearbyReport.objects.filter(status="open").exists())

    def test_world_switch(self):
        self.assertFalse(NL.world_on())
        self.post("/owner/nearby/dataset", {"key": "WORLD", "on": "1"})
        self.assertTrue(NL.world_on())
        self.post("/owner/nearby/dataset", {"key": "BD", "on": "0"})
        self.assertIn("BD", NL.disabled_countries())
        self.assertIn("m=invalid", self.post("/owner/nearby/dataset", {"key": "../x"})["Location"])
