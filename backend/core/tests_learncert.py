"""learncert — Assisto Learning Certificate: signed verify code, server-signed
result token, issue / dedupe / revoke, the app API (flag), the public
/verify/<code> page (minimal data, noindex, disclaimer), the PDF, and the
owner's honesty guards:
  * exam names (IELTS, TOPIK, JLPT, Goethe, DELF, DELE, HSK) only inside
    "…-style practice" wording in ANY certificate text (server, page, app
    card, ARB proposal);
  * Quran certificates never say ijazah / ইজাযাহ / Qari / ক্বারী.
"""
import json
import re
from pathlib import Path

from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import learn_cert as LC
from core.models import FeatureFlag, PaCollectionItem, User

REPO = Path(__file__).resolve().parents[2]
CARD_DART = REPO / "app" / "lib" / "screens" / "learn_cert_screen.dart"
ARB = REPO / ".phaseB" / "up_learncert_arb.json"
TEMPLATE = REPO / "backend" / "web" / "templates" / "web" / "learncert_verify.html"
EXAMS = ("IELTS", "TOPIK", "JLPT", "Goethe", "DELF", "DELE", "HSK")
QURAN_BAD = ("ijazah", "ইজাযাহ", "Qari", "ক্বারী")


def _flag(on):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=LC.FLAG).update(
        enabled_all=on, enabled_play=on, rollout_pct=100, allow_user_ids=[])
    FF.invalidate()


def _all_levels():
    for course, c in LC.COURSES.items():
        for lv in c["levels"]:
            yield course, lv


def _exam_outside_style(text):
    """Exam names present outside the allowed "-style practice" wording."""
    bad = []
    for name in EXAMS:
        for m in re.finditer(r"(?<![A-Za-z])%s(?![A-Za-z])" % name, text, re.I):
            tail = text[m.end():m.end() + 20]
            if not (tail.startswith("-style practice") or tail.startswith("-ধাঁচের অনুশীলন")):
                bad.append("%s in %r" % (name, text[max(0, m.start() - 30):m.end() + 30]))
    return bad


def _quran_bad(text):
    low = text.lower()
    return [w for w in QURAN_BAD if w.lower() in low]


class CodeTests(TestCase):
    def test_code_shape_and_roundtrip(self):
        for _ in range(50):
            c = LC.new_code()
            self.assertRegex(c, r"^ALC-[A-Z]{4}-[A-Z]{4}-[A-Z]{4}$")
            self.assertNotRegex(c, r"[0-9IO]")
            self.assertEqual(LC.normalize_code(c), c)
            self.assertEqual(LC.normalize_code(c.lower().replace("-", " ")), c)
            self.assertEqual(LC.normalize_code(c.replace("ALC-", "")), c)

    def test_tampered_or_guessed_code_fails_before_db(self):
        c = LC.new_code()
        last = c[-1]
        swapped = c[:-1] + ("A" if last != "A" else "B")
        self.assertIsNone(LC.normalize_code(swapped))
        self.assertIsNone(LC.normalize_code("ALC-AAAA-AAAA"))
        self.assertIsNone(LC.normalize_code(""))
        self.assertIsNone(LC.normalize_code("<script>"))


class IssueTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rahim Uddin", phone="01710007001", password="pw-123456")
        self.v = User.objects.create_user(name="Karim", phone="01710007002", password="pw-123456")

    def test_token_roundtrip_bound_to_user(self):
        t = LC.result_token(self.u, "lang_en", "b1", 72.4)
        self.assertEqual(LC.read_token(self.u, t), ("lang_en", "B1", 72))
        with self.assertRaises(LC.CertError):
            LC.read_token(self.v, t)
        with self.assertRaises(LC.CertError):
            LC.read_token(self.u, t[:-2] + "xx")

    def test_bad_inputs(self):
        for course, lv, sc in (("lang_xx", "B1", 1), ("lang_en", "N3", 1), ("lang_en", "B1", 101),
                               ("lang_en", "B1", -1), ("lang_en", "B1", "abc"),
                               ("quran_qaida", "nazera", None), ("quran_qaida", "ijazah", None)):
            with self.assertRaises(LC.CertError, msg=(course, lv, sc)):
                LC.issue_certificate(self.u, course, lv, sc)

    def test_name_rules(self):
        for bad in ("A", "x" * 61, "Rahim 007", "www.scam.com", "IELTS Band 9 Rahim",
                    "Qari Rahim", "Official Rahim", "<b>Rahim</b>", "রহিম ৯"):
            with self.assertRaises(LC.CertError, msg=bad):
                LC.clean_name(bad)
        self.assertEqual(LC.clean_name("  রহিম   উদ্দিন "), "রহিম উদ্দিন")
        self.assertEqual(LC.clean_name("Mary-Jane O'Neil"), "Mary-Jane O'Neil")

    def test_dedupe_raises_score_and_revoke_allows_new(self):
        a = LC.issue_certificate(self.u, "lang_ko", "l3", 60)
        b = LC.issue_certificate(self.u, "lang_ko", "L3", 75)
        self.assertEqual(a.pk, b.pk)
        b.refresh_from_db()
        self.assertEqual(b.data["score"], 75)
        LC.issue_certificate(self.u, "lang_ko", "L3", 50)
        b.refresh_from_db()
        self.assertEqual(b.data["score"], 75)          # never lowered
        LC.revoke(b)
        c = LC.issue_certificate(self.u, "lang_ko", "L3", 80)
        self.assertNotEqual(c.pk, b.pk)
        self.assertNotEqual(c.data["code"], b.data["code"])
        self.assertEqual(LC.find(b.data["code"]).pk, b.pk)

    def test_stored_in_private_collection_not_user_writable(self):
        from core.views import GENERIC_COLLECTIONS
        self.assertNotIn(LC.COLL, GENERIC_COLLECTIONS)
        r = LC.issue_certificate(self.u, "quran_qaida", "qaida")
        self.assertEqual(PaCollectionItem.objects.get(pk=r.pk).collection, LC.COLL)

    def test_level_text(self):
        self.assertEqual(LC.level_text("lang_en", "B1", "en"), "B1 · Assisto practice · estimated")
        self.assertEqual(LC.level_text("lang_en", "B1", "bn"), "B১ · Assisto অনুশীলন · আনুমানিক")
        self.assertIn("TOPIK-style practice", LC.level_text("lang_ko", "L4", "en"))
        self.assertIn("লেভেল ৪", LC.level_text("lang_ko", "L4", "bn"))
        self.assertEqual(LC.level_text("quran_qaida", "qaida", "en"), "Qaida reading practice completed")
        self.assertEqual(LC.level_text("quran_nazera", "nazera", "bn"), "নাযেরা পড়ার অনুশীলন সম্পন্ন")
        self.assertEqual(LC.level_text("quran_qaida", "qaida", "bn"), "কায়দা পড়ার অনুশীলন সম্পন্ন")


class HonestyGuardTests(TestCase):
    """Owner rule: fails if an exam name appears outside "…-style practice",
    or if a Quran certificate carries ijazah / Qari wording."""

    def setUp(self):
        self.u = User.objects.create_user(name="Rahim Uddin", phone="01710007011", password="pw-123456")

    def _texts(self):
        out = [LC.DISCLAIMER["en"], LC.DISCLAIMER["bn"]]
        for lang in ("en", "bn"):
            out += [v for v in LC.TXT[lang].values()]
        for course, c in LC.COURSES.items():
            out += [c["en"], c["bn"]]
        for course, lv in _all_levels():
            for lang in ("en", "bn"):
                out.append(LC.level_text(course, lv, lang))
        return out

    def test_guard_itself_catches_claims(self):
        self.assertTrue(_exam_outside_style("IELTS band 7.0"))
        self.assertTrue(_exam_outside_style("Official TOPIK level 3"))
        self.assertTrue(LC.forbidden_in("JLPT N2 passed"))
        self.assertFalse(_exam_outside_style("Level 3 (TOPIK-style practice)"))
        self.assertFalse(LC.forbidden_in("N4 (JLPT-ধাঁচের অনুশীলন)"))
        self.assertFalse(LC.forbidden_in("accepted, deleted, ব্যবহারকারী"))
        self.assertTrue(_quran_bad("Ijazah in recitation"))
        self.assertTrue(LC.forbidden_in("ক্বারী সাহেব"))

    def test_server_certificate_texts_are_honest(self):
        for t in self._texts():
            self.assertEqual(_exam_outside_style(t), [], t)
            self.assertEqual(LC.forbidden_in(t), [], t)

    def test_every_rendered_certificate_is_honest_and_has_disclaimer(self):
        users = {}
        for course, lv in _all_levels():
            if course not in users:   # one learner per course (daily cap 20)
                users[course] = User.objects.create_user(
                    name="Rahim Uddin", phone="0171100%04d" % len(users), password="pw-123456")
            row = LC.issue_certificate(users[course], course, lv, 70)
            d = LC.as_dict(row)
            for lang in ("bn", "en"):
                blob = " | ".join(str(v) for v in d[lang].values())
                self.assertIn(LC.DISCLAIMER[lang], blob)
                self.assertEqual(_exam_outside_style(blob), [], blob)
                if course.startswith("quran"):
                    self.assertEqual(_quran_bad(blob), [], blob)
            pdf = LC.pdf_bytes(row, "en")
            self.assertTrue(pdf.startswith(b"%PDF"))

    def test_quran_level_words_only(self):
        for lv, t in LC.QURAN_LEVEL.items():
            self.assertIn(t["en"], ("Qaida reading practice completed", "Nazera reading practice completed"))
            self.assertIn(t["bn"], ("কায়দা পড়ার অনুশীলন সম্পন্ন", "নাযেরা পড়ার অনুশীলন সম্পন্ন"))
        for course in ("quran_qaida", "quran_nazera"):
            for lang in ("en", "bn"):
                self.assertEqual(_quran_bad(LC.COURSES[course][lang]), [])

    def test_verify_template_is_honest(self):
        src = TEMPLATE.read_text(encoding="utf-8")
        self.assertEqual(_exam_outside_style(src), [])
        self.assertEqual(_quran_bad(src), [])
        from web import views_learncert as W
        for lang in ("bn", "en"):
            for v in W.TXT[lang].values():
                self.assertEqual(_exam_outside_style(v), [], v)
                self.assertEqual(_quran_bad(v), [], v)

    def test_app_card_strings_are_honest(self):
        self.assertTrue(CARD_DART.exists(), CARD_DART)
        src = CARD_DART.read_text(encoding="utf-8")
        lits = re.findall(r"'((?:[^'\\\n]|\\.)*)'", src) + re.findall(r'"((?:[^"\\\n]|\\.)*)"', src)
        for s in lits:
            self.assertEqual(_exam_outside_style(s), [], s)
            self.assertEqual(_quran_bad(s), [], s)
        self.assertTrue(ARB.exists(), ARB)
        arb = json.loads(ARB.read_text(encoding="utf-8"))
        self.assertEqual(set(arb), {"en", "bn"})
        for lang in ("en", "bn"):
            for k, v in arb[lang].items():
                if k.startswith("@"):
                    continue
                self.assertEqual(_exam_outside_style(v), [], (k, v))
                self.assertEqual(_quran_bad(v), [], (k, v))
        # the mandatory line is in the app strings, word for word
        self.assertIn(LC.DISCLAIMER["en"], arb["en"].values())
        self.assertIn(LC.DISCLAIMER["bn"], arb["bn"].values())


class ApiTests(TestCase):
    def setUp(self):
        self.addCleanup(FF.invalidate)
        self.u = User.objects.create_user(name="Rahim Uddin", phone="01710007021", password="pw-123456")
        self.v = User.objects.create_user(name="Karim", phone="01710007022", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_flag_off_refuses(self):
        _flag(False)
        r = self.c.get("/api/v1/learn/certs")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "feature_off")
        t = LC.result_token(self.u, "lang_en", "B1", 70)
        self.assertEqual(self.c.post("/api/v1/learn/certs/claim", {"token": t}, format="json").status_code, 403)

    def test_claim_list_detail_pdf_revoke(self):
        _flag(True)
        r = self.c.get("/api/v1/learn/certs")
        self.assertEqual(r.json()["items"], [])
        self.assertEqual(r.json()["default_name"], "Rahim Uddin")
        self.assertEqual(self.c.post("/api/v1/learn/certs/claim", {"token": "x"}, format="json").status_code, 400)
        t = LC.result_token(self.u, "lang_ja", "N4", 81)
        r = self.c.post("/api/v1/learn/certs/claim", {"token": t, "name": "রহিম উদ্দিন"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        cert = r.json()["cert"]
        self.assertEqual(cert["name"], "রহিম উদ্দিন")
        self.assertTrue(cert["valid"])
        self.assertTrue(cert["verify_url"].endswith("/verify/" + cert["code"]))
        self.assertIn("JLPT-style practice", cert["en"]["level"])
        r = self.c.post("/api/v1/learn/certs/claim", {"token": t}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["cert"]["id"], cert["id"])
        self.assertEqual(len(self.c.get("/api/v1/learn/certs").json()["items"]), 1)
        self.assertEqual(self.c.get("/api/v1/learn/certs/%d" % cert["id"]).status_code, 200)
        for lang in ("bn", "en"):
            r = self.c.get("/api/v1/learn/certs/%d/pdf?lang=%s" % (cert["id"], lang))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r["Content-Type"], "application/pdf")
            self.assertTrue(r.content.startswith(b"%PDF"))
        # another user cannot see / revoke it, nor claim with this token
        other = APIClient()
        other.force_authenticate(self.v)
        self.assertEqual(other.get("/api/v1/learn/certs/%d" % cert["id"]).status_code, 404)
        self.assertEqual(other.post("/api/v1/learn/certs/%d/revoke" % cert["id"]).status_code, 404)
        self.assertEqual(other.post("/api/v1/learn/certs/claim", {"token": t}, format="json").status_code, 400)
        r = self.c.post("/api/v1/learn/certs/%d/revoke" % cert["id"])
        self.assertFalse(r.json()["cert"]["valid"])

    def test_revoke_code_staff_only(self):
        row = LC.issue_certificate(self.u, "lang_en", "B2", 66)
        code = row.data["code"]
        self.assertEqual(self.c.post("/api/v1/learn/certs/revoke-code", {"code": code}, format="json").status_code, 403)
        staff = User.objects.create_user(name="Staff", phone="01710007029", password="pw-123456")
        staff.is_staff = True
        staff.save()
        s = APIClient()
        s.force_authenticate(staff)
        r = s.post("/api/v1/learn/certs/revoke-code", {"code": code.lower()}, format="json")
        self.assertEqual(r.status_code, 200)
        row.refresh_from_db()
        self.assertTrue(row.data["revoked_at"])

    def test_unauthenticated_api_refused(self):
        self.assertIn(APIClient().get("/api/v1/learn/certs").status_code, (401, 403))


class PublicPageTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rahim Uddin", phone="01710007031",
                                          email="rahim@example.com", password="pw-123456")
        self.row = LC.issue_certificate(self.u, "lang_en", "B1", 73)
        self.code = self.row.data["code"]

    def test_valid_page_minimal_data_bn_en(self):
        _flag(False)   # an issued certificate keeps verifying with the flag OFF
        for lang in ("bn", "en"):
            r = self.client.get("/verify/%s?lang=%s" % (self.code, lang))
            self.assertEqual(r.status_code, 200)
            html = r.content.decode()
            self.assertIn("Rahim Uddin", html)
            self.assertIn(LC.course_title("lang_en", lang), html)
            self.assertIn(LC.level_text("lang_en", "B1", lang), html)
            self.assertIn(LC.DISCLAIMER[lang], html)
            self.assertIn("noindex", r["X-Robots-Tag"])
            self.assertIn('content="noindex, nofollow"', html)
            self.assertEqual(r["Cache-Control"], "no-store")
            for leak in ("01710007031", "rahim@example.com", "73/100", "৭৩/১০০"):
                self.assertNotIn(leak, html)
            self.assertEqual(_exam_outside_style(html), [])
        self.assertIn("og:title", html)

    def test_lowercase_code_works_and_revoked_shows_revoked(self):
        r = self.client.get("/verify/%s?lang=en" % self.code.lower().replace("-", ""))
        self.assertEqual(r.status_code, 200)
        LC.revoke(self.row)
        r = self.client.get("/verify/%s?lang=en" % self.code)
        self.assertEqual(r.status_code, 200)
        self.assertIn("REVOKED", r.content.decode())

    def test_bad_code_and_form(self):
        r = self.client.get("/verify/ALC-AAAA-AAAA-AAAA")
        self.assertEqual(r.status_code, 404)
        self.assertIn(LC.DISCLAIMER["bn"], r.content.decode())
        r = self.client.get("/verify/")
        self.assertEqual(r.status_code, 200)
        self.assertIn('name="code"', r.content.decode())
        r = self.client.get("/verify/?code=%s&lang=en" % self.code.lower())
        self.assertEqual(r.status_code, 302)
        self.assertIn("/verify/%s" % self.code, r["Location"])
