"""lpfinish — the repo's ORIGINAL Language Partner content goes live with ONE
command (`manage.py lp_seed`): 3 IELTS mocks (Academic + General), the 7
language tracks (Japanese JLPT N5 + JFT-Basic, Korean EPS-TOPIK, German A1,
Chinese HSK 1, French A1, work Arabic) and Life English / vocabulary. Every
item must pass lpcore's automatic checks (ai_checked = shown with the beta
label); answer keys never reach the phone; listening without recorded audio
carries phone-TTS lines; the paid-section path (pay=credits) opens a track
test too. Test users only — never the owner account."""
import io
from unittest import mock

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import lp_service as LS
from core.logic import lp_checks as CK
from core.logic import lp_seed as SD
from core.management.commands.lp_seed import repo_root
from core.models import LpItem, User

V = "/api/v1"
TRACKS = ("jlpt_n5", "jft_basic", "eps_topik", "de_a1", "hsk1", "fr_a1", "ar_work")


def _content():
    import os
    return os.path.join(repo_root(), "tools", "lp", "content")


class SeedFilesTests(SimpleTestCase):
    def test_every_ielts_file_passes_the_checks(self):
        items = SD.ielts_items(_content())
        keys = sorted(i["key"] for i in items)
        self.assertGreaterEqual(len(keys), 3, keys)
        self.assertIn("ielts-gt-001", keys)
        for it in items:
            d = it["data"]
            res = CK.check_item("mock", d, "")
            self.assertTrue(res["ok"], (it["key"], res["failures"][:5]))
            for s in CK.SECTIONS:
                self.assertEqual(CK.section_failures(s, d[s], ""), [], (it["key"], s))
            for p in d["listening"]["parts"]:
                self.assertTrue(CK.tts_lines(p), (it["key"], p["n"]))
                self.assertIn(p["tts_lang"], ("en-GB", "en-US", "en-AU"))
            self.assertFalse(CK.copyright_failures(CK.text_of(d)), it["key"])

    def test_every_track_has_syllabus_lessons_and_a_test(self):
        items = SD.track_items(_content())
        for t in TRACKS:
            kinds = {i["kind"] for i in items if i["track"] == t or
                     t in ((i["data"].get("tracks") or []) if i["kind"] == "lesson" else [])}
            self.assertEqual(kinds, {"syllabus", "lesson", "mock"}, t)
        for i in items:
            if i["kind"] == "mock":
                for s in i["data"]["sections"]:
                    if s.get("kind") == "listening":
                        for p in s["parts"]:
                            for q in p["questions"]:
                                self.assertTrue(q.get("tts") or p.get("tts"), (i["key"], q["n"]))

    def test_option_letter_ids(self):
        self.assertEqual(CK.opt_id("B. in the garden"), "b")
        self.assertEqual(CK.opt_id({"id": "C", "text": "x"}), "c")
        self.assertEqual(CK.opt_id("ka"), "ka")


@mock.patch("core.lp_service.flag_on", return_value=True)
class SeedLiveTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        out = io.StringIO()
        call_command("lp_seed", stdout=out)          # raises if anything is not live
        cls.seed_out = out.getvalue()

    def setUp(self):
        self.u = User.objects.create_user(name="Learner LP", phone="+8801711009901", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_seed_is_idempotent(self, _f):
        n = LpItem.objects.count()
        out = io.StringIO()
        call_command("lp_seed", stdout=out)
        self.assertEqual(LpItem.objects.count(), n)
        self.assertIn('"new": 0', out.getvalue())

    def test_ielts_lists_are_real(self, _f):
        for kind in ("academic", "general"):
            r = self.c.get(V + "/lp/mocks?kind=" + kind).json()
            self.assertTrue(r["mocks"], kind)
            self.assertEqual(r["mocks"][0]["sections"], ["listening", "reading", "writing", "speaking"])
            self.assertTrue(r["mocks"][0]["beta"])

    def test_listening_section_has_phone_tts_and_no_keys(self, _f):
        r = self.c.get(V + "/lp/mocks/ielts-ac-001?section=listening")
        self.assertEqual(r.status_code, 200, r.content[:200])
        body = r.json()
        part = body["listening"]["parts"][0]
        self.assertIsNone(part["audio_url"])
        self.assertTrue(part["tts"]["lines"])
        raw = r.content.decode()
        for hidden in ('"answer"', '"explain_bn"', '"transcript"'):
            self.assertNotIn(hidden, raw)
        # marking the free section works and gives a practice band
        m = self.c.post(V + "/lp/mocks/ielts-ac-001/mark", {"section": "listening", "answers": {"1": "x"}},
                        format="json").json()
        self.assertEqual(m["total"], 40)
        self.assertIn("band", m)

    def test_every_track_opens_and_marks(self, _f):
        with mock.patch.object(LS, "is_premium", return_value=True):
            for t in TRACKS:
                lst = self.c.get(V + "/lp/mocks?kind=" + t).json()["mocks"]
                self.assertTrue(lst, t)
                syl = self.c.get(V + "/lp/content/syllabus?track=" + t).json()["items"]
                self.assertEqual(len(syl), 1, t)
                les = self.c.get(V + "/lp/content/lesson?track=" + t).json()["items"]
                self.assertGreaterEqual(len(les), 5, t)
                m = lst[0]
                sec = m["sections"][0]
                r = self.c.get(V + "/lp/mocks/%s?section=%s" % (m["id"], sec))
                self.assertEqual(r.status_code, 200, (t, r.content[:200]))
                raw = r.content.decode()
                self.assertNotIn('"answer"', raw)
                self.assertNotIn('"script"', raw)
                qs = [q for s in r.json()["sections"] for p in s.get("parts") or [] for q in p["questions"]]
                if qs:
                    mk = self.c.post(V + "/lp/mocks/%s/mark" % m["id"],
                                     {"section": sec, "answers": {str(qs[0]["n"]): "A"}}, format="json").json()
                    self.assertEqual(mk["total"], len(qs), t)

    def test_track_listening_has_tts(self, _f):
        with mock.patch.object(LS, "is_premium", return_value=True):
            r = self.c.get(V + "/lp/mocks/jlpt-n5-001?section=listening").json()
        q = r["sections"][0]["parts"][0]["questions"][0]
        self.assertEqual(q["tts"]["lang"], "ja-JP")
        self.assertTrue(q["tts"]["lines"])

    def test_week_used_then_open_with_credits(self, _f):
        r = self.c.get(V + "/lp/mocks/eps-topik-001?section=reading")
        self.assertEqual(r.status_code, 200)
        r = self.c.get(V + "/lp/mocks/de-a1-001?section=" +
                       LS.section_ids(LS.live_item("de-a1-001", "mock"))[0])
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["reason"], "week_used")
        self.assertEqual(r.json()["unlock_credits"], LS.SECTION_UNLOCK_CREDITS)
        with mock.patch.object(LS, "pay_section", return_value=(True, "")) as pay:
            r = self.c.get(V + "/lp/mocks/de-a1-001?section=%s&pay=credits" %
                           LS.section_ids(LS.live_item("de-a1-001", "mock"))[0])
        self.assertEqual(r.status_code, 200)
        pay.assert_called_once()

    def test_life_and_vocab_seeded(self, _f):
        self.assertTrue(self.c.get(V + "/lp/content/life").json()["items"])
        self.assertTrue(self.c.get(V + "/lp/content/vocab").json()["items"])
