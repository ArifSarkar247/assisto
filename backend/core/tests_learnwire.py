"""learnwire — wires the Assisto learning certificate into Language Partner and
Learn-to-read-Quran, and closes the p2lang framework gaps langmulti found:

  * placement / mock responses carry a signed certificate offer
    (HSK1-6 -> H1-6 "HSK-style practice"; Arabic W1-W3 -> "Work Arabic level n",
    never an official exam level);
  * POST /learn/quran/complete records a FULL stage set (Qaida 1-7, Nazera 8-9)
    and returns the token; wording only "... reading practice completed";
  * pack scenarios beyond the 5 defaults (Arabic salary/rights, German
    immigration office), writing `checks`, character counting for zh/ja.
"""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import learn_cert as LC
from core.logic import langpacks as LP

User = get_user_model()
V = "/api/v1"


def _user(n):
    return User.objects.create_user(name="Karim Mia", phone="+88017120000%02d" % n,
                                    password="pw12345!")


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


class LevelMapTests(SimpleTestCase):
    def test_pack_levels_map_to_certificate_levels(self):
        self.assertEqual(LC.pack_level("zh", "HSK1"), ("lang_zh", "H1"))
        self.assertEqual(LC.pack_level("zh", "HSK6"), ("lang_zh", "H6"))
        self.assertEqual(LC.pack_level("ar", "W2"), ("lang_ar", "W2"))
        self.assertEqual(LC.pack_level("de", "B1"), ("lang_de", "B1"))
        self.assertEqual(LC.pack_level("ko", "1"), ("lang_ko", "L1"))
        self.assertEqual(LC.pack_level("ko", "6"), ("lang_ko", "L6"))
        self.assertIsNone(LC.pack_level("ko", "0"))           # Hangul starter: no certificate
        self.assertEqual(LC.pack_level("ja", "N5"), ("lang_ja", "N5"))
        self.assertEqual(LC.pack_level("ja", "N1"), ("lang_ja", "N1"))
        self.assertIsNone(LC.pack_level("ja", "kana"))        # kana starter: no certificate
        self.assertIsNone(LC.pack_level("zh", "HSK9"))
        self.assertIsNone(LC.pack_level("xx", "A1"))

    def test_every_pack_level_has_a_certificate_level(self):
        for code in LP.CODES:
            p = LP.load(code)
            if p is None:
                continue
            for lv in p["levels"]:
                with self.subTest(code=code, level=lv["id"]):
                    if (code, lv["id"]) in (("ko", "0"), ("ja", "kana")):
                        self.assertIsNone(LC.pack_level(code, lv["id"]))
                    else:
                        self.assertIsNotNone(LC.pack_level(code, lv["id"]))

    def test_work_arabic_wording_is_never_an_official_level(self):
        for lv in ("W1", "W2", "W3"):
            en = LC.level_text("lang_ar", lv, "en")
            bn = LC.level_text("lang_ar", lv, "bn")
            self.assertTrue(en.startswith("Work Arabic level %s · " % lv[1]), en)
            self.assertIn("estimated", en)
            self.assertTrue(bn.startswith("কাজের আরবি লেভেল %s" % LC.bn_digits(lv[1])), bn)
            self.assertFalse(any(ch.isascii() and ch.isdigit() for ch in bn), bn)
            for t in (en, bn):
                self.assertEqual(LC.forbidden_in(t), [], t)
                self.assertNotRegex(t, r"(?i)official|certified|band")

    def test_hsk_levels_only_as_style_practice(self):
        en = LC.level_text("lang_zh", "H3", "en")
        self.assertIn("Level 3 (HSK-style practice)", en)
        self.assertEqual(LC.forbidden_in(en), [])

    def test_quran_wording(self):
        self.assertEqual(LC.QURAN_LEVEL["qaida"]["en"], "Qaida reading practice completed")
        self.assertEqual(LC.QURAN_LEVEL["nazera"]["en"], "Nazera reading practice completed")
        for v in LC.QURAN_LEVEL.values():
            for t in v.values():
                self.assertEqual(LC.forbidden_in(t), [], t)
                self.assertNotRegex(t, r"(?i)ijaz|qari|score|\d")


class FrameworkGapTests(SimpleTestCase):
    def test_extra_scenarios_validate_and_keep_defaults(self):
        ar = LP.load("ar")
        de = LP.load("de")
        self.assertIn("salary_rights", [s["id"] for s in ar["scenarios"]])
        self.assertIn("immigration_office", [s["id"] for s in de["scenarios"]])
        for p in (ar, de):
            self.assertTrue(set(LP.SCENARIO_IDS) <= {s["id"] for s in p["scenarios"]})

    def test_validator_rejects_bad_or_repeated_scenario_ids(self):
        import copy
        p = copy.deepcopy(LP.load("de"))
        p["scenarios"].append(dict(p["scenarios"][0]))   # repeated id
        with self.assertRaises(LP.PackError):
            LP.validate(p)
        p = copy.deepcopy(LP.load("de"))
        p["scenarios"][0]["id"] = "Bad Id!"
        with self.assertRaises(LP.PackError):
            LP.validate(p)

    def test_chinese_writing_counts_characters_not_spaces(self):
        self.assertEqual(LP.count_units("zh", "我是学生。"), 4)
        self.assertEqual(LP.count_units("zh", "我 是 学 生"), 4)
        self.assertEqual(LP.count_units("ja", "わたしは がくせい です"), 10)
        self.assertEqual(LP.count_units("de", "Ich bin heute krank."), 4)
        self.assertEqual(LP.count_unit("zh"), "chars")
        self.assertEqual(LP.count_unit("ar"), "words")

    def test_mock_open_rows_carry_checks_and_unit(self):
        zh = LP.load("zh")
        m = zh["mock"][0]
        pr = next(p for s in m["sections"] for p in s.get("prompts") or [])
        g = LP.grade_mock(zh, m["id"], {}, {pr["id"]: "我在工厂工作，因为我想学习。"})
        row = next(o for o in g["open"] if o["id"] == pr["id"])
        self.assertEqual(row["unit"], "chars")
        self.assertGreater(row["words"], 5)
        self.assertEqual(len(row["checks"]), len(pr["checks"]))
        self.assertTrue(all(c["ok"] for c in row["checks"]), row["checks"])
        empty = LP.grade_mock(zh, m["id"], {}, {})
        row = next(o for o in empty["open"] if o["id"] == pr["id"])
        self.assertFalse(any(c["ok"] for c in row["checks"]))

    def test_jft_style_mock_is_section_by_section(self):
        import copy
        ja = LP.load("ja")
        jft = LP.mock_test(ja, "jft_style_1")
        self.assertTrue(jft["no_back"])
        self.assertLessEqual(sum(s["minutes"] for s in jft["sections"]), jft["minutes"])
        bad = copy.deepcopy(ja)
        LP.mock_test(bad, "jft_style_1")["sections"][0].pop("minutes")
        with self.assertRaises(LP.PackError):
            LP.validate(bad)

    def test_extras_tiles_are_known_ids_in_both_languages(self):
        import copy
        for code in ("ko", "ja"):
            ids = [e["id"] for e in LP.load(code)["extras"]]
            self.assertEqual(ids, ["work_path", "listening"], code)
            for e in LP.load(code)["extras"]:
                if e["id"] == "listening":   # phone voice is never sold as exam audio
                    self.assertIn("not exam audio", e["en"])
                    self.assertIn("পরীক্ষার অডিও নয়", e["bn"])
        bad = copy.deepcopy(LP.load("ko"))
        bad["extras"].append({"id": "casino", "en": "x", "bn": "য"})
        with self.assertRaises(LP.PackError):
            LP.validate(bad)

    def test_checks_are_case_insensitive(self):
        out = LP.run_checks([{"any": ["krank"], "en": "ill", "bn": "অসুস্থ"}], "Ich bin KRANK")
        self.assertEqual(out, [{"en": "ill", "bn": "অসুস্থ", "ok": True}])


@mock.patch("core.learn_views.flag_on", return_value=True)
class LanguageCertOfferTests(TestCase):
    def setUp(self):
        self.u = _user(1)
        self.c = _client(self.u)

    def _place(self, lang, all_right=True):
        qs = LP.load(lang)["placement"]["questions"]
        ans = {q["id"]: q["answer"] for q in qs} if all_right else {qs[0]["id"]: qs[0]["answer"]}
        return self.c.post(V + "/learn/%s/placement" % lang, {"answers": ans}, format="json").json()

    def test_chinese_placement_offer_maps_hsk(self, _f):
        j = self._place("zh")
        self.assertEqual(j["level"], "HSK6")
        self.assertEqual(j["cert"]["course"], "lang_zh")
        self.assertEqual(j["cert"]["level"], "H6")
        self.assertEqual(LC.read_token(self.u, j["cert"]["token"]), ("lang_zh", "H6", j["score_pct"]))

    def test_arabic_offer_is_work_arabic(self, _f):
        j = self._place("ar", all_right=False)
        self.assertEqual(j["cert"]["level"], "W1")
        with mock.patch("core.views_learncert.flag_on", return_value=True):
            r = self.c.post(V + "/learn/certs/claim", {"token": j["cert"]["token"]}, format="json")
        self.assertEqual(r.status_code, 201)
        card = r.json()["cert"]
        self.assertTrue(card["en"]["level"].startswith("Work Arabic level 1"))
        self.assertIn("not an official qualification", card["en"]["disclaimer"])

    def test_mock_offer(self, _f):
        de = LP.load("de")
        m = de["mock"][0]
        ans = {q["id"]: q["answer"] for s in m["sections"] for q in s.get("questions") or []}
        j = self.c.post(V + "/learn/de/mock", {"mock_id": m["id"], "answers": ans}, format="json").json()
        self.assertEqual(j["cert"]["course"], "lang_de")
        self.assertEqual(j["cert"]["level"], j["level"])
        self.assertEqual(j["cert"]["score"], j["score_pct"])

    def test_korean_and_japanese_offers(self, _f):
        j = self._place("ko")
        self.assertEqual(j["level"], "6")
        self.assertEqual((j["cert"]["course"], j["cert"]["level"]), ("lang_ko", "L6"))
        low = self._place("ko", all_right=False)
        self.assertEqual(low["level"], "0")
        self.assertIsNone(low["cert"])                        # Hangul starter: no certificate
        ja = self._place("ja")
        self.assertEqual((ja["cert"]["course"], ja["cert"]["level"]), ("lang_ja", "N1"))
        self.assertIsNone(self._place("ja", all_right=False)["cert"])
        self.assertIn("JLPT-style practice", LC.level_text("lang_ja", "N1", "en"))

    def test_token_is_bound_to_the_learner(self, _f):
        j = self._place("zh")
        other = _user(2)
        with self.assertRaises(LC.CertError):
            LC.read_token(other, j["cert"]["token"])


class QuranCompleteTests(TestCase):
    def setUp(self):
        self.u = _user(3)
        self.c = _client(self.u)
        p = mock.patch("core.views_learncert.flag_on", return_value=True)
        p.start()
        self.addCleanup(p.stop)

    def _post(self, body):
        return self.c.post(V + "/learn/quran/complete", body, format="json")

    def test_flag_off_403(self):
        with mock.patch("core.views_learncert.flag_on", return_value=False):
            self.assertEqual(self._post({"course": "quran_qaida", "stages": [1]}).status_code, 403)

    def test_full_qaida_set_gives_token_and_honest_card(self):
        r = self._post({"course": "quran_qaida", "stages": [7, 6, 5, 4, 3, 2, 1],
                        "completed_on": "2026-11-02"})
        self.assertEqual(r.status_code, 200)
        cert = r.json()["cert"]
        self.assertEqual((cert["course"], cert["level"], cert["score"]), ("quran_qaida", "qaida", None))
        self.assertEqual(cert["completed_on"], "2026-11-02")
        claim = self.c.post(V + "/learn/certs/claim", {"token": cert["token"]}, format="json")
        self.assertEqual(claim.status_code, 201)
        card = claim.json()["cert"]
        self.assertEqual(card["en"]["level"], "Qaida reading practice completed")
        self.assertEqual(card["bn"]["level"], "কায়দা পড়ার অনুশীলন সম্পন্ন")
        self.assertEqual(card["en"]["score"], "")      # never a score claim
        blob = " ".join(str(v) for v in card["en"].values()) + " ".join(str(v) for v in card["bn"].values())
        self.assertEqual(LC.forbidden_in(blob), [])

    def test_nazera_needs_stages_8_and_9(self):
        self.assertEqual(self._post({"course": "quran_nazera", "stages": [8]}).json()["reason"], "bad_stages")
        self.assertEqual(self._post({"course": "quran_nazera", "stages": [1, 2, 3, 4, 5, 6, 7]})
                         .json()["reason"], "bad_stages")
        r = self._post({"course": "quran_nazera", "stages": [8, 9]})
        self.assertEqual(r.json()["cert"]["level"], "nazera")

    def test_incomplete_or_bad_input_refused(self):
        self.assertEqual(self._post({"course": "quran_qaida", "stages": [1, 2, 3]}).status_code, 400)
        self.assertEqual(self._post({"course": "quran_qaida", "stages": "1-7"}).status_code, 400)
        self.assertEqual(self._post({"course": "quran_qaida", "stages": ["x"]}).status_code, 400)
        self.assertEqual(self._post({"course": "lang_en", "stages": [1]}).json()["reason"], "bad_course")

    def test_first_completion_date_kept(self):
        self._post({"course": "quran_qaida", "stages": list(range(1, 8)), "completed_on": "2026-11-01"})
        r = self._post({"course": "quran_qaida", "stages": list(range(1, 8)), "completed_on": "2026-11-03"})
        self.assertEqual(r.json()["cert"]["completed_on"], "2026-11-01")
        from core.models import PaCollectionItem
        self.assertEqual(PaCollectionItem.objects.filter(user=self.u, collection=LC.QURAN_DONE).count(), 1)
