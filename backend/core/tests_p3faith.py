"""p3faith — Ramadan tracker (owner PART 3, 3 Nov 2026).

Pure: Islamic Foundation Bangladesh (IFB) convention — 18 deg dawn, Hanafi
asr, sehri 3 min before Subh-e-Sadiq, iftar 3 min after sunset — checked
against IFB's PUBLISHED Dhaka figures for 19 Feb 2026 (sehri 05:12, iftar
17:58, bdnews24 Jan 2026); 64 districts; month table; tabular Hijri gives
an APPROXIMATE Ramadan within 1 day of the real BD starts.
API: district / GPS / method, districts list, month table, bad input.
"""
from datetime import date

from django.test import SimpleTestCase
from rest_framework.test import APITestCase

from core.logic import ramadan as R
from core.models import User


def _m(hhmm):
    h, m = map(int, hhmm.split(":"))
    return h * 60 + m


class IfbMethodTests(SimpleTestCase):
    def test_precaution_minutes(self):
        t = R.ifb_times(date(2026, 3, 1), 23.81, 90.41)
        self.assertEqual(t["method"], "ifb")
        self.assertEqual(t["asr_convention"], R.ASR_HANAFI)
        self.assertEqual(_m(t["fajr"]) - _m(t["sehri_end"]), 3)
        self.assertEqual(_m(t["iftar"]) - _m(t["maghrib"]), 3)

    def test_dhaka_matches_ifb_published_2026(self):
        # IFB published (Dhaka, 1st Ramadan 1447 = 19 Feb 2026): 05:12 / 17:58
        t = R.ifb_times(date(2026, 2, 19), 23.81, 90.41)
        self.assertLessEqual(abs(_m(t["sehri_end"]) - _m("05:12")), 3, t)
        self.assertLessEqual(abs(_m(t["iftar"]) - _m("17:58")), 3, t)

    def test_karachi_default_unchanged(self):
        # the old default (raw astronomical) is untouched for old callers
        t = R.prayer_times(date(2026, 2, 19), 23.81, 90.41)
        self.assertEqual(t["sehri_end"], t["fajr"])
        self.assertEqual(t["iftar"], t["maghrib"])

    def test_west_iftar_later_than_east(self):
        d = date(2027, 2, 10)
        syl = R.district_month("sylhet", d, 1)["days"][0]
        sat = R.district_month("satkhira", d, 1)["days"][0]
        self.assertLess(_m(syl["iftar"]), _m(sat["iftar"]))


class DistrictTests(SimpleTestCase):
    def test_sixty_four_districts_bilingual(self):
        rows = R.districts("bn")
        self.assertEqual(len(rows), 64)
        self.assertEqual(len({r["code"] for r in rows}), 64)
        for r in rows:
            self.assertTrue(r["bn"] and r["en"])

    def test_month_table(self):
        tbl = R.district_month("dhaka", date(2027, 2, 8), 30)
        self.assertEqual(len(tbl["days"]), 30)
        self.assertEqual(tbl["days"][0]["date"], "2027-02-08")
        self.assertEqual(tbl["days"][-1]["date"], "2027-03-09")
        # February -> March: sehri gets earlier, iftar later
        self.assertLess(_m(tbl["days"][-1]["sehri_end"]),
                        _m(tbl["days"][0]["sehri_end"]))
        self.assertGreater(_m(tbl["days"][-1]["iftar"]),
                           _m(tbl["days"][0]["iftar"]))

    def test_unknown_district_and_clamp(self):
        self.assertIsNone(R.district_month("atlantis", date(2027, 2, 8)))
        self.assertEqual(len(R.district_month("dhaka", date(2027, 2, 8), 99)["days"]),
                         R.MONTH_MAX_DAYS)
        self.assertEqual(len(R.district_month("dhaka", date(2027, 2, 8), "x")["days"]),
                         30)

    def test_nearest_district(self):
        self.assertEqual(R.nearest_district_code(24.90, 91.86), "sylhet")
        self.assertEqual(R.nearest_district_code(23.80, 90.41), "dhaka")


class HijriTests(SimpleTestCase):
    def test_real_bd_starts_within_one_day(self):
        # Bangladesh 1st Ramadan (moon-sighting committee): 1446 = 2 Mar 2025,
        # 1447 = 19 Feb 2026. The arithmetic calendar is only approximate.
        for today, real in ((date(2025, 1, 1), date(2025, 3, 2)),
                            (date(2025, 12, 1), date(2026, 2, 19))):
            a = R.approx_next_ramadan(today)
            self.assertTrue(a["approximate"])
            self.assertLessEqual(abs((date.fromisoformat(a["start"]) - real).days), 1, a)

    def test_next_after_ramadan_rolls_over(self):
        a = R.approx_next_ramadan(date(2026, 11, 3))
        self.assertEqual(a["hijri_year"], 1448)
        self.assertFalse(a["in_ramadan"])
        self.assertGreater(date.fromisoformat(a["start"]), date(2026, 11, 3))
        n = (date.fromisoformat(a["end"]) - date.fromisoformat(a["start"])).days + 1
        self.assertIn(n, (29, 30))

    def test_during_ramadan(self):
        a = R.approx_next_ramadan(date(2026, 3, 1))
        self.assertTrue(a["in_ramadan"])
        self.assertEqual(a["hijri_year"], 1447)


class RamadanApiTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="R", phone="01830009001",
                                          password="x123456")
        self.client.force_authenticate(self.u)

    def test_times_by_district_default_ifb(self):
        r = self.client.get("/api/v1/ramadan/times?district=sylhet")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["method"], "ifb")
        self.assertEqual(r.json()["district"], "sylhet")
        self.assertEqual(r.json()["source"]["sehri_precaution_min"], 3)
        self.assertTrue(r.json()["approx_ramadan"]["approximate"])

    def test_times_by_gps_reports_nearest_district(self):
        r = self.client.get("/api/v1/ramadan/times?lat=22.36&lon=91.78")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["district"], "chattogram")
        k = self.client.get("/api/v1/ramadan/times?lat=23.8&lon=90.4&method=karachi")
        self.assertEqual(k.json()["sehri_end"], k.json()["fajr"])

    def test_bad_input(self):
        self.assertEqual(self.client.get("/api/v1/ramadan/times").status_code, 400)
        self.assertEqual(
            self.client.get("/api/v1/ramadan/times?district=nowhere").status_code, 400)
        self.assertEqual(
            self.client.get("/api/v1/ramadan/month?district=nowhere").status_code, 400)
        self.assertEqual(
            self.client.get("/api/v1/ramadan/month?district=dhaka&start=x").status_code, 400)

    def test_districts_and_month(self):
        d = self.client.get("/api/v1/ramadan/districts")
        self.assertEqual(d.status_code, 200)
        self.assertEqual(len(d.json()["districts"]), 64)
        m = self.client.get("/api/v1/ramadan/month?district=dhaka&start=2027-02-08&days=30")
        self.assertEqual(m.status_code, 200)
        self.assertEqual(len(m.json()["days"]), 30)
        self.assertEqual(m.json()["name_bn"], "ঢাকা")
        dflt = self.client.get("/api/v1/ramadan/month?district=dhaka")
        self.assertEqual(dflt.json()["days"][0]["date"],
                         dflt.json()["approx_ramadan"]["start"])
