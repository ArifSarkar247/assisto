"""p3guides (owner PART 3): Service guide, Probashi corner, Student corner.

* /guides now serves the ADVANCED guide (docs checklist, fees, office, time,
  categories) + official facts (last-checked date, official sources, published
  fee table or the official fee page). It used to send names + steps only.
* Honesty: a fee NUMBER only with fee_status=published + a basis; every URL is
  an official host; no invented exam/scholarship dates.
* official-info/<probashi|student>: helplines, WEWB welfare, remittance
  benchmarks / official education links; 404 for unknown sections.
* remit_cost: World Bank style fee + FX margin arithmetic.
* Flag official_corners: default OFF, registered + audited.
"""
import re
from urllib.parse import urlparse

from django.test import SimpleTestCase
from rest_framework.test import APITestCase

from core import feature_flags as FF
from core.logic import govt_guide as GG
from core.logic import official_info as OI
from core.models import User

_DIGIT = re.compile(r"\d")


def _official(url):
    host = urlparse(url).netloc.lower()
    return url.startswith("https://") and any(
        host == h or host.endswith(h) for h in OI.OFFICIAL_HOST_SUFFIXES)


class FactsTests(SimpleTestCase):
    def test_every_url_is_official_https(self):
        bad = [u for u in OI.all_urls() if not _official(u)]
        self.assertEqual(bad, [])

    def test_fee_numbers_only_when_published_with_basis(self):
        for key, f in OI.GUIDE_FACTS.items():
            if f["fee_status"] == "published":
                self.assertTrue(f.get("fee_basis"), key)
                self.assertTrue(f.get("fees"), key)
                self.assertTrue(f.get("fee_page"), key)
            else:
                self.assertEqual(f["fee_status"], "official_page", key)
                self.assertFalse(f.get("fees"), key)  # never a guessed number
                self.assertTrue(f.get("fee_page"), key)

    def test_facts_cover_every_guide_service(self):
        keys = {s["key"] for s in GG.SERVICES}
        self.assertLessEqual(set(OI.GUIDE_FACTS), keys)
        # owner's list: NID, passport, birth, driving, TIN, trade, land, e-namjari
        for k in ("nid", "epassport", "birth", "driving", "tin", "trade_license", "porcha", "emutation"):
            self.assertIn(k, OI.GUIDE_FACTS, k)

    def test_emutation_total_matches_parts(self):
        rows = OI.GUIDE_FACTS["emutation"]["fees"]
        en = [r[1][1] for r in rows]
        nums = [int(x.replace("Tk ", "").replace(",", "")) for x in en]
        self.assertEqual(sum(nums[:-1]), nums[-1])
        self.assertEqual(nums[-1], 1170)

    def test_bangla_amounts_use_bangla_digits(self):
        for f in OI.GUIDE_FACTS.values():
            for _label, amount in f.get("fees", []):
                self.assertIsNone(_DIGIT.search(amount[0]), amount[0])
        for w in OI.PROBASHI["welfare"]:
            self.assertIsNone(_DIGIT.search(w["amount"][0]), w["amount"][0])
        for h in OI.PROBASHI["helplines"]:
            self.assertIsNone(_DIGIT.search(h["display"][0]), h["display"][0])

    def test_localized_guide_carries_official_block(self):
        for lang in ("bn", "en"):
            d = GG.localized(lang)
            self.assertEqual(d["checked"], OI.CHECKED)
            self.assertTrue(d["categories"])
            for s in d["services"]:
                o = s["official"]
                self.assertEqual(o["checked"], OI.CHECKED, s["key"])
                self.assertIn(o["fee_status"], ("published", "official_page"))
                self.assertTrue(s["docs"], s["key"])
        self.assertTrue(GG.has_no_invented_fees())

    def test_remit_cost_math(self):
        r = OI.remit_cost(500, 15, 32.10, 32.50)
        self.assertAlmostEqual(r["cost_pct"], 4.23, places=2)
        self.assertEqual(r["home_amount"], 16050.0)
        self.assertEqual(r["incentive"], 401.25)
        self.assertTrue(r["above_sdg"])
        cheap = OI.remit_cost(1000, 0, 32.45, 32.50)
        self.assertFalse(cheap["above_sdg"])
        for bad in ((0, 1, 1, 1), (100, -1, 1, 1), (100, 1, 0, 1), ("x", 1, 1, 1)):
            self.assertIsNone(OI.remit_cost(*bad), bad)

    def test_no_invented_dates_in_student_section(self):
        blob = str(OI.STUDENT)
        self.assertIsNone(re.search(r"20\d\d-\d\d-\d\d", blob))

    def test_flag_registered_off(self):
        self.assertIn("official_corners", FF.KEYS)
        self.assertFalse(FF.meta("official_corners")["default_on"])


class ApiTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="P3", phone="01700009333", password="pw")
        self.client.force_authenticate(self.u)

    def test_guides_endpoint_is_advanced_payload(self):
        j = self.client.get("/api/v1/guides", HTTP_ACCEPT_LANGUAGE="bn").json()
        self.assertEqual(j["version"], "2.1")
        keys = {s["key"] for s in j["services"]}
        self.assertIn("emutation", keys)
        emu = next(s for s in j["services"] if s["key"] == "emutation")
        self.assertEqual(emu["official"]["fee_status"], "published")
        self.assertTrue(emu["docs"])
        pas = next(s for s in j["services"] if s["key"] == "epassport")
        self.assertEqual(pas["official"]["fees"], [])
        self.assertIn("epassport.gov.bd", pas["official"]["fee_page"])

    def test_official_info_sections(self):
        p = self.client.get("/api/v1/official-info/probashi", HTTP_ACCEPT_LANGUAGE="en").json()
        self.assertEqual(p["checked"], OI.CHECKED)
        self.assertEqual(p["helplines"][0]["dial"], "16135")
        self.assertEqual(p["remit"]["incentive_pct"], 2.5)
        self.assertEqual(p["remit"]["sdg_target_pct"], 3.0)
        s = self.client.get("/api/v1/official-info/student", HTTP_ACCEPT_LANGUAGE="bn").json()
        self.assertEqual([g["id"] for g in s["groups"]], ["scholarship", "board_exams", "admission"])
        self.assertEqual(self.client.get("/api/v1/official-info/nope").status_code, 404)

    def test_official_info_needs_login(self):
        self.client.force_authenticate(None)
        self.assertIn(self.client.get("/api/v1/official-info/probashi").status_code, (401, 403))
