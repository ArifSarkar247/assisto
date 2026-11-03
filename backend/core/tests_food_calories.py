"""p2food: food photo -> calories. Cited table (FCT Bangladesh 2013 + USDA
FNDDS), never-invented numbers, log math, vision purpose 'food' (dish ids
only), the flag-gated /food/table endpoint and the food/log collection."""
import re
from pathlib import Path
from unittest import mock

from django.test import SimpleTestCase

from core import feature_flags as FF
from core import vision_providers as VP
from core.tests_healthfit import medical_claims
from core.logic import chat_vision as CV
from core.logic import food_calories as FC
from core.logic.food_table_data import ROWS
from core.models import FeatureFlag, PhotoStudioJob
from core.tests_h1_home import _VBase

ROOT = Path(__file__).resolve().parents[2]


def _flag(on):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key="food_calories").update(enabled_all=on)
    FF.invalidate()


class TableTests(SimpleTestCase):
    def test_every_number_is_cited(self):
        self.assertGreaterEqual(len(ROWS), 45)
        ids = [r["id"] for r in ROWS]
        self.assertEqual(len(ids), len(set(ids)))
        for r in ROWS:
            if r["per100"]["kcal"] is None:
                self.assertEqual(r["src"], "none", r["id"])
                self.assertTrue(all(v is None for v in r["per100"].values()), r["id"])
                continue
            self.assertIn(r["src"], ("fct", "usda"), r["id"])
            if r["src"] == "fct":
                self.assertRegex(r["code"], r"^\d\d_\d{4}$", r["id"])
            else:
                self.assertRegex(r["code"], r"^\d{7}$", r["id"])
            self.assertTrue(r["src_name"], r["id"])
            self.assertTrue(r["portions"], r["id"])
            for p in r["portions"]:
                self.assertGreater(p["g"], 0, r["id"])
                self.assertTrue(p["basis"] == "home" or re.match(r"^usda:\d{7}$", p["basis"]))

    def test_spot_values_match_the_sources(self):
        # FCT 2013 UserDB_Main_table / FNDDS 2024-10-31 (checked by hand 3 Nov)
        self.assertEqual(FC.dish("bhat")["code"], "01_0041")
        self.assertEqual(FC.dish("bhat")["per100"]["kcal"], 111)
        self.assertEqual(FC.dish("khichuri")["per100"]["kcal"], 163)
        self.assertEqual(FC.dish("dudh_cha")["per100"]["kcal"], 41)
        self.assertEqual(FC.dish("biriyani")["code"], "2706490")
        self.assertEqual(FC.dish("biriyani")["per100"]["kcal"], 145)
        self.assertEqual(FC.dish("singara")["per100"]["kcal"], 310)

    def test_uncited_dishes_never_get_a_number(self):
        for did in ("fuchka", "chotpoti", "pitha", "rosogolla", "jilapi", "haleem"):
            self.assertIsNone(FC.nutrients(did, 100), did)
            row = FC.client_row(FC.dish(did), "bn")
            self.assertFalse(row["has_value"])
            self.assertEqual(row["source"], "")
            self.assertIn("বানাই না", row["note"])

    def test_nutrients_scale_and_bounds(self):
        n = FC.nutrients("bhat", 316)
        self.assertEqual(n["kcal"], round(111 * 3.16))
        self.assertAlmostEqual(n["carb"], round(24.81 * 3.16, 1))
        self.assertIsNone(FC.nutrients("bhat", 0))
        self.assertIsNone(FC.nutrients("bhat", "x"))
        self.assertIsNone(FC.nutrients("bhat", FC.MAX_GRAMS + 1))
        self.assertIsNone(FC.nutrients("nope", 100))

    def test_client_table_shape_and_labels(self):
        t = FC.table("bn")
        bhat = next(d for d in t["dishes"] if d["id"] == "bhat")
        self.assertEqual(bhat["source"], "FCT বাংলাদেশ ২০১৩ · 01_0041")
        self.assertEqual(bhat["name"], "ভাত (সাদা)")
        self.assertIn("চিকিৎসা-পরামর্শ নয়", t["disclaimer"])
        self.assertIn("INFS", t["sources"]["fct"]["cite"])
        self.assertIn("Public domain", t["sources"]["usda"]["cite"])
        en = FC.table("en")
        self.assertIn("not medical advice", en["disclaimer"])
        biri = next(d for d in en["dishes"] if d["id"] == "biriyani")
        self.assertIn("foreign recipe", biri["note"])

    def test_hints_are_general_info_no_medical_claims(self):
        for lang in ("bn", "en"):
            t = FC.table(lang)
            blob = " ".join([t["disclaimer"]] + [h["text"] for h in t["hints"]] +
                            [d["note"] for d in t["dishes"]])
            self.assertEqual(medical_claims(blob), [], lang)
            for h in t["hints"]:
                self.assertTrue(h["src"])


class LogMathTests(SimpleTestCase):
    E = [
        {"date": "2026-11-03", "dish": "bhat", "kcal": 351, "protein": 6.6, "fat": 0.3, "carb": 78.4, "fibre": 3.1},
        {"date": "2026-11-03", "dish": "fuchka", "kcal": None},
        {"date": "2026-11-03", "dish": "pitha", "kcal": 150, "self": True},
        {"date": "2026-11-02", "dish": "dal", "kcal": 348},
        {"date": "2026-11-03", "dish": "x", "kcal": True},       # junk -> unknown
        "garbage",
    ]

    def test_day_totals_counts_unknown_separately(self):
        d = FC.day_totals(self.E, "2026-11-03")
        self.assertEqual(d["kcal"], 501)
        self.assertEqual(d["count"], 4)
        self.assertEqual(d["unknown"], 2)
        self.assertEqual(d["protein"], 6.6)

    def test_week_series(self):
        days = ["2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31",
                "2026-11-01", "2026-11-02", "2026-11-03"]
        w = FC.week(self.E, days)
        self.assertEqual([x["kcal"] for x in w], [0, 0, 0, 0, 0, 348, 501])
        self.assertEqual(w[-1]["unknown"], 2)

    def test_goal(self):
        self.assertIsNone(FC.clean_goal(100))
        self.assertIsNone(FC.clean_goal("abc"))
        self.assertEqual(FC.clean_goal("1800"), 1800)
        g = FC.goal_state(2100, 1800)
        self.assertEqual((g["left"], g["over"], g["ratio"]), (0, 300, 1.0))
        self.assertEqual(FC.goal_state(500, None)["goal"], FC.GOAL_DEFAULT)


class VisionPurposeTests(SimpleTestCase):
    def test_food_purpose_prompt(self):
        self.assertIn("food", CV.PURPOSES)
        p = CV.system_prompt("bn", "food")
        self.assertIn("bhat (Rice (white, boiled))", p)
        self.assertIn("Do NOT give calorie", p)
        a = CV.add_purpose_note("Rice and dal.", "food", "en")
        self.assertIn("not medical advice", a)

    def test_parse_dishes_keeps_only_known_ids(self):
        raw = ('```json\n{"kind":"food","answer":"Rice and dal","dishes":['
               '{"id":"bhat","confidence":"high","kcal":999},{"id":"BHAT"},'
               '{"id":"pizza","confidence":"high"},{"id":"dal","confidence":"weird"},'
               '"singara"]}\n```')
        self.assertEqual(FC.parse_dishes(raw), [
            {"id": "bhat", "confidence": "high"}, {"id": "dal", "confidence": "low"},
            {"id": "singara", "confidence": "low"}])
        self.assertEqual(FC.parse_dishes("no json"), [])
        self.assertEqual(FC.parse_dishes('{"dishes": "bhat"}'), [])
        many = '{"dishes":[%s]}' % ",".join('{"id":"%s"}' % r["id"] for r in ROWS[:10])
        self.assertEqual(len(FC.parse_dishes(many)), 6)


class FoodApiTests(_VBase):
    def test_table_flag_off_then_on(self):
        self.as_(self.free)
        _flag(False)
        r = self.client.get("/api/v1/food/table", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["error"], "feature_off")
        _flag(True)
        r = self.client.get("/api/v1/food/table", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertFalse(j["photo_ready"])          # no vision key -> manual pick
        self.assertGreaterEqual(len(j["dishes"]), 45)
        self.vision()
        self.assertTrue(self.client.get("/api/v1/food/table").json()["photo_ready"])

    def test_food_log_collection(self):
        self.as_(self.free)
        r = self.client.post("/api/v1/food/log/", {"date": "2026-11-03", "dish": "bhat",
                                                   "grams": 316, "kcal": 351}, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        rows = self.client.get("/api/v1/food/log/").json()
        self.assertEqual(rows[0]["dish"], "bhat")

    def test_photo_answer_stores_dish_ids_only(self):
        self.vision()
        self.as_(self.prem)
        r = self.create()
        jid = r.json()["job"]["id"]
        reply = ('{"kind":"food","label_text":"","answer":"Rice, dal and fish curry.",'
                 '"dishes":[{"id":"bhat","confidence":"high"},{"id":"dal","confidence":"medium"},'
                 '{"id":"burger","confidence":"high"}]}')
        with mock.patch.object(VP, "ask", return_value=reply) as ask:
            r = self.answer(jid, question="What food is this?", purpose="food")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("Do NOT give calorie", ask.call_args.kwargs["system"])
        job = r.json()["job"]
        self.assertEqual([d["id"] for d in job["dishes"]], ["bhat", "dal"])
        self.assertIn("not medical advice", job["answer"])
        row = PhotoStudioJob.objects.get(pk=jid)
        self.assertEqual(row.options["dishes"][0]["id"], "bhat")

    def test_other_purposes_have_no_dishes_key(self):
        self.vision()
        self.as_(self.prem)
        jid = self.create().json()["job"]["id"]
        with mock.patch.object(VP, "ask", return_value='{"kind":"plant","answer":"Tulsi."}'):
            r = self.answer(jid, question="what plant")
        self.assertNotIn("dishes", r.json()["job"])


class GeneratorTests(SimpleTestCase):
    def test_generated_file_header_and_script_exist(self):
        src = (ROOT / "backend" / "core" / "logic" / "food_table_data.py").read_text()
        self.assertIn("GENERATED by backend/core/food_table_gen.py", src)
        self.assertTrue((ROOT / "backend" / "core" / "food_table_gen.py").exists())
