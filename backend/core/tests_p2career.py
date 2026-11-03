"""p2career — CV Builder (formats, ATS check, PDF, signed print page, AI
polish via the router), Job Hunter legal sources (Greenhouse / Lever / RSS via
safe_fetch, Careerjet seam, honest per-source report, saved-search
collections, deadline reminders) and the role-based mock interview (rubric
without a key, AI feedback within the cap). Flag career_plus."""
import json
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai
from core import career_service as S
from core import feature_flags as FF
from core.logic import career_content as CC
from core.models import FeatureFlag, PaCollectionItem, Reminder, User

V = "/api/v1"
PUB = lambda host, port, *a: [(2, 1, 6, "", ("93.184.216.34", port))]  # noqa: E731


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


CV = {"name": "Rahim Uddin", "headline": "Junior Accountant", "phone": "01711000000",
      "email": "rahim@example.com", "location": "Dhaka",
      "summary": "Commerce graduate with two years of hands-on accounts work in a busy "
                 "trading firm and solid Tally skills.",
      "education": [{"degree": "BBA (Accounting)", "institution": "Dhaka College", "year": "2022"}],
      "experience": [{"title": "Accounts Assistant", "org": "ABC Traders", "dates": "2022-2024",
                      "bullets": "Reconciled 300 vouchers a month\nPrepared VAT returns"}],
      "skills": ["Tally", "Excel", "VAT", "Bangla typing", "Reporting"],
      "personal": {"father": "Karim Uddin", "dob": "01-01-2000", "nationality": "Bangladeshi"}}


class ContentTests(SimpleTestCase):
    def test_formats_order_sections(self):
        cv = CC.normalize_cv(dict(CV, format="govt"))
        heads = [b["heading"] for b in CC.cv_blocks(cv, "bn")]
        self.assertEqual(heads[0], "ক্যারিয়ার উদ্দেশ্য")
        self.assertIn("ব্যক্তিগত তথ্য", heads)
        self.assertEqual(heads[-1], "প্রত্যয়ন")
        exp = CC.cv_blocks(CC.normalize_cv(dict(CV, format="experienced")), "en")
        self.assertEqual([b["heading"] for b in exp][:2], ["Professional Summary", "Work Experience"])
        fresher = CC.cv_blocks(CC.normalize_cv(CV), "en")
        self.assertNotIn("Personal Information", [b["heading"] for b in fresher])

    def test_normalize_is_bounded_and_safe(self):
        cv = CC.normalize_cv({"name": "x" * 999, "format": "evil", "skills": ["a"] * 99,
                              "experience": "not a list"})
        self.assertEqual(len(cv["name"]), 120)
        self.assertEqual(cv["format"], "fresher")
        self.assertEqual(cv["experience"], [])
        self.assertEqual(CC.normalize_cv(None)["name"], "")

    def test_ats_check(self):
        good = CC.ats_check(CC.normalize_cv(dict(CV, format="experienced")))
        self.assertEqual(good["score"], 100)
        bad = CC.ats_check(CC.normalize_cv({"name": "R", "format": "experienced"}))
        failed = {c["id"] for c in bad["checks"] if not c["ok"]}
        self.assertTrue({"phone", "email", "experience", "skills"} <= failed)
        # Bangla digits in the phone count
        bn = CC.ats_check(CC.normalize_cv({"phone": "০১৭১১০০০০০০"}))
        self.assertTrue(next(c for c in bn["checks"] if c["id"] == "phone")["ok"])

    def test_role_bank_complete_bilingual(self):
        self.assertGreaterEqual(len(CC.ROLES), 8)
        ids = set()
        for r in CC.ROLES:
            self.assertGreaterEqual(len(r["qs"]), 6, r["id"])
            for q in r["qs"]:
                self.assertNotIn(q["id"], ids)
                ids.add(q["id"])
                self.assertRegex(q["bn"], r"[ঀ-৿]")
                self.assertTrue(q["en"].isascii(), q["id"])
                self.assertEqual(len(q["keys"]) % 2, 0, q["id"])
                self.assertTrue(q["outline"]["bn"] and q["outline"]["en"])
        self.assertIsNone(CC.role_questions("nope", "bn"))
        self.assertEqual(len(CC.role_questions("bank", "en")["questions"]), 6)

    def test_rubric_scores_and_tips(self):
        empty = CC.rubric("bk3", "")
        self.assertEqual(empty["score"], 0)
        weak = CC.rubric("bk3", "I will um like actually basically help")
        self.assertIn("longer", weak["tips"])
        strong = CC.rubric("bk3", (
            "First I listen carefully and stay calm, then I apologise for the trouble. "
            "For example, last year a customer was charged twice; I found the solution "
            "within 2 hours, reversed the fee, and I made a follow up call the next day. "
            "As a result he kept his account and later opened a savings scheme with us."))
        self.assertGreater(strong["score"], weak["score"])
        self.assertGreaterEqual(strong["score"], 80)
        self.assertTrue(strong["has_example"])
        self.assertIn("keep_going", strong["tips"])
        # Bangla answer counts the Bangla partner keyword once
        bn = CC.rubric("bk3", "আমি শান্ত থেকে মন দিয়ে শুনি, তারপর সমাধান দিই।")
        self.assertEqual(len(bn["hits"]), 3)
        self.assertIsNone(CC.rubric("zz9", "x"))


class FlagOffTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="C0", phone="01710000700", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_off_refuses_everything_but_status(self):
        flag(False)
        self.assertEqual(self.c.get(V + "/career/status").json()["enabled"], False)
        for path in ("/career/cv/prefill", "/career/jobs/search?q=x", "/career/interview/roles"):
            self.assertEqual(self.c.get(V + path).status_code, 403, path)
        self.assertEqual(self.c.post(V + "/career/interview/feedback",
                                     {"qid": "bk1", "answer": "x"}, format="json").status_code, 403)

    def test_default_is_off(self):
        FF.ensure_seeded()
        FF.invalidate()
        self.assertFalse(S.flag_on(self.u))


class CvTests(TestCase):
    def setUp(self):
        flag(True)
        self.u = User.objects.create_user(name="Rahim", phone="01710000701",
                                          email="r@example.com", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def tearDown(self):
        FF.invalidate()

    def _save(self, **extra):
        return self.c.post(V + "/cv/", dict(CV, **extra), format="json")

    def test_prefill_from_profile(self):
        d = self.c.get(V + "/career/cv/prefill").json()
        self.u.refresh_from_db()
        self.assertEqual(d, {"name": "Rahim", "phone": self.u.phone, "email": self.u.email})
        self.assertTrue(d["phone"] and d["email"])

    def test_no_cv_is_honest_404(self):
        self.assertEqual(self.c.get(V + "/career/cv/pdf").status_code, 404)
        self.assertEqual(self.c.post(V + "/career/cv/print-link", {}, format="json").status_code, 404)

    def test_pdf_is_real_pdf_with_text(self):
        self.assertIn(self._save(format="experienced").status_code, (200, 201))
        r = self.c.get(V + "/career/cv/pdf?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "application/pdf")
        self.assertTrue(r.content.startswith(b"%PDF"))
        # bangla goes through the print page (correct conjuncts)
        bn = self.c.get(V + "/career/cv/pdf?lang=bn")
        self.assertEqual(bn.status_code, 400)
        self.assertTrue(bn.json()["use_print"])

    def test_pdf_with_photo_and_bad_photo(self):
        import base64
        import io
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (40, 48), (200, 150, 100)).save(buf, "JPEG")
        good = "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
        self.assertIsNotNone(S.photo_bytes({"photo": good}))
        self.assertIsNone(S.photo_bytes({"photo": "data:image/png;base64,bm90IGFuIGltYWdl"}))
        self.assertIsNone(S.photo_bytes({"photo": "https://evil.example/x.png"}))
        self._save(photo=good)
        r = self.c.get(V + "/career/cv/pdf")
        self.assertEqual(r.status_code, 200)

    def test_print_link_signed_escaped_and_expires(self):
        self._save(name="<script>alert(1)</script>", format="govt")
        d = self.c.post(V + "/career/cv/print-link", {"lang": "bn"}, format="json").json()
        self.assertIn("/api/v1/career/cv/print/", d["url"])
        anon = APIClient()
        r = anon.get(V + d["path"])
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertNotIn("<script>alert", body)
        self.assertIn("&lt;script&gt;", body)
        self.assertIn("প্রত্যয়ন", body)
        self.assertEqual(r["X-Robots-Tag"], "noindex, nofollow")
        self.assertEqual(anon.get(V + "/career/cv/print/forged").status_code, 410)
        with mock.patch.object(S, "PRINT_TTL_S", -1):
            self.assertEqual(anon.get(V + d["path"]).status_code, 410)
        flag(False)
        self.assertEqual(anon.get(V + d["path"]).status_code, 410)

    def test_ats_endpoint(self):
        self._save(format="experienced")
        self.assertEqual(self.c.get(V + "/career/cv/ats").json()["score"], 100)

    def test_patch_keeps_extras(self):
        row = self._save().json()
        self.c.patch(V + "/cv/%s/" % row["id"], {"name": "New"}, format="json")
        self.assertEqual(S.cv_row(self.u)["personal"]["father"], "Karim Uddin")

    def test_polish_no_key_is_honest(self):
        self._save()
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("no_key")):
            d = self.c.post(V + "/career/cv/polish", {"lang": "bn"}, format="json").json()
        self.assertFalse(d["ai_used"])
        self.assertEqual(d["reason"], "no_key")
        self.assertIn("AI", d["message"])

    def test_polish_uses_router_and_keeps_shape(self):
        self._save()
        seen = {}

        def fake(**kw):
            seen.update(kw)
            return json.dumps({"summary": "Detail-minded accountant.",
                               "experience": [{"bullets": ["Reconciled 300 vouchers monthly"]}]}), 0.0

        with mock.patch.object(ai, "generate", side_effect=fake):
            d = self.c.post(V + "/career/cv/polish", {"lang": "en"}, format="json").json()
        self.assertTrue(d["ai_used"])
        self.assertEqual(d["experience"][0]["bullets"], ["Reconciled 300 vouchers monthly"])
        self.assertEqual(seen["feature"], "career.cv_polish")
        self.assertIs(seen["user"], self.u)
        self.assertTrue(seen["pii"])
        self.assertIn("never add", seen["task"])

    def test_polish_rejects_changed_shape(self):
        self._save()
        with mock.patch.object(ai, "generate", return_value=(json.dumps(
                {"summary": "x", "experience": [{"bullets": ["a"]}, {"bullets": ["invented"]}]}), 0.0)):
            d = self.c.post(V + "/career/cv/polish", {"lang": "en"}, format="json").json()
        self.assertFalse(d["ai_used"])

    def test_polish_daily_cap(self):
        self._save()
        with mock.patch.object(S, "_ai_calls_today", return_value=S.AI_POLISH_DAILY_CAP):
            d = self.c.post(V + "/career/cv/polish", {}, format="json").json()
        self.assertEqual(d["reason"], "cap")


GH = json.dumps({"jobs": [
    {"title": "Accountant", "absolute_url": "https://boards.greenhouse.io/acme/jobs/1",
     "location": {"name": "Dhaka"}, "updated_at": "2026-11-01T00:00:00Z"},
    {"title": "Driver", "absolute_url": "https://boards.greenhouse.io/acme/jobs/2",
     "location": {"name": "Chattogram"}},
    {"title": "Bad", "absolute_url": "javascript:alert(1)"}]}).encode()
LV = json.dumps([{"text": "Senior Accountant", "hostedUrl": "https://jobs.lever.co/beta/9",
                  "categories": {"location": "Dhaka"}, "createdAt": 1762000000000},
                 "junk"]).encode()
RSS = (b"<?xml version='1.0'?><rss><channel><item><title>Accounts Officer</title>"
       b"<link>https://careers.example.com/1</link></item></channel></rss>")


def opener_for(mapping):
    def op(url, method):
        for frag, body in mapping.items():
            if frag in url:
                return 200, {"content-type": "application/json"}, body
        return 404, {}, b""
    return op


class JobsTests(TestCase):
    def setUp(self):
        flag(True)
        self.u = User.objects.create_user(name="J", phone="01710000702", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.net = {"opener": opener_for({"greenhouse": GH, "lever": LV, "feed": RSS}),
                    "resolver": PUB}

    def tearDown(self):
        FF.invalidate()

    def test_source_validation(self):
        self.assertEqual(S.source_url("greenhouse", "acme"),
                         "https://boards-api.greenhouse.io/v1/boards/acme/jobs")
        self.assertIn("api.lever.co/v0/postings/beta", S.source_url("lever", "beta"))
        self.assertIsNone(S.source_url("link", "https://acme.com/careers"))
        for kind, val in (("greenhouse", "../x"), ("rss", "http://insecure.com/f"),
                          ("rss", "file:///etc/passwd"), ("scrape", "x")):
            with self.assertRaises(ValueError):
                S.source_url(kind, val)
        r = self.c.post(V + "/career/jobs/sources/test", {"kind": "rss", "value": "ftp://x"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_private_hosts_blocked(self):
        priv = {"opener": opener_for({"": RSS}),
                "resolver": lambda h, p, *a: [(2, 1, 6, "", ("10.0.0.5", p))]}
        with self.assertRaises(Exception):
            S.fetch_source({"kind": "rss", "value": "https://intranet.example.com/feed"}, net=priv)

    def test_parsers(self):
        gh = S.parse_greenhouse(json.loads(GH), "Acme")
        self.assertEqual([j["title"] for j in gh], ["Accountant", "Driver"])
        lv = S.parse_lever(json.loads(LV), "Beta")
        self.assertEqual(lv[0]["posted"][:4], "2025")
        self.assertEqual(S.parse_greenhouse("x"), [])
        self.assertEqual(S.parse_lever({"x": 1}), [])

    def test_search_labels_every_source_and_reports_failures(self):
        for kind, val, label in (("greenhouse", "acme", "Acme"), ("lever", "beta", "Beta"),
                                 ("rss", "https://careers.example.com/feed", "Example"),
                                 ("link", "https://bdjobs.com", "Bdjobs"),
                                 ("greenhouse", "gone", "Gone")):
            PaCollectionItem.objects.create(user=self.u, collection="career/sources",
                                            data={"kind": kind, "value": val, "label": label})
        net = {"opener": opener_for({"boards/acme": GH, "lever": LV, "feed": RSS}), "resolver": PUB}
        out = S.search(self.u, "accountant", "", net=net)
        titles = {(j["title"], j["source"]) for j in out["jobs"]}
        self.assertIn(("Accountant", "Acme"), titles)
        self.assertIn(("Senior Accountant", "Beta"), titles)
        self.assertNotIn("Driver", {j["title"] for j in out["jobs"]})
        rep = {r["label"]: r for r in out["sources"]}
        self.assertFalse(rep["Careerjet"]["ok"])
        self.assertEqual(rep["Careerjet"]["error"], "not_connected")
        self.assertFalse(rep["Gone"]["ok"])
        self.assertNotIn("Bdjobs", rep)          # a plain link is never read
        loc = S.search(self.u, "accountant", "dhaka", net=net)
        self.assertTrue(all("Dhaka" in j["location"] for j in loc["jobs"]))

    def test_careerjet_seam_when_connected(self):
        from core import world_service as WS
        with mock.patch.object(WS, "careerjet_ready", return_value=True), \
                mock.patch.object(WS, "_careerjet_query", return_value=[
                    {"id": "1", "title": "Bank Officer", "company": "X Bank",
                     "url": "https://www.careerjet.com.bd/job/1"}]):
            out = S.search(self.u, "bank officer zz-unique")
        self.assertEqual(out["jobs"][0]["source"], "Careerjet")
        self.assertTrue(out["sources"][0]["ok"])

    def test_source_test_endpoint_honest_failure(self):
        with mock.patch.object(S, "fetch_source", side_effect=ValueError("HTTP 404")):
            r = self.c.post(V + "/career/jobs/sources/test",
                            {"kind": "greenhouse", "value": "acme"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["ok"])
        with mock.patch.object(S, "fetch_source", return_value=[{"title": "Accountant"}]):
            ok = self.c.post(V + "/career/jobs/sources/test",
                             {"kind": "greenhouse", "value": "acme"}, format="json").json()
        self.assertEqual((ok["ok"], ok["count"], ok["sample"]), (True, 1, ["Accountant"]))
        link = self.c.post(V + "/career/jobs/sources/test",
                           {"kind": "link", "value": "https://acme.com/careers"}, format="json").json()
        self.assertTrue(link["link_only"])

    def test_saved_search_collection_roundtrip(self):
        r = self.c.post(V + "/career/searches/", {"q": "accountant", "loc": "Dhaka"}, format="json")
        self.assertIn(r.status_code, (200, 201))
        self.assertEqual(self.c.get(V + "/career/searches/").json()[0]["q"], "accountant")

    def test_deadline_reminders(self):
        d = (timezone.localdate() + timedelta(days=10)).isoformat()
        r = self.c.post(V + "/career/jobs/deadline",
                        {"title": "Accountant at Acme", "deadline": d, "ref": "job:5"}, format="json")
        self.assertEqual(len(r.json()["reminders"]), 2)
        rows = Reminder.objects.filter(user=self.u, link__type="career_deadline")
        self.assertEqual(rows.count(), 2)
        self.assertTrue(all("Accountant at Acme" in x.title for x in rows))
        # re-setting replaces, never duplicates
        self.c.post(V + "/career/jobs/deadline",
                    {"title": "Accountant at Acme", "deadline": d, "ref": "job:5"}, format="json")
        self.assertEqual(Reminder.objects.filter(user=self.u, link__type="career_deadline").count(), 2)
        # tomorrow: only the day-of reminder is still in the future
        t = (timezone.localdate() + timedelta(days=1)).isoformat()
        self.assertEqual(len(self.c.post(V + "/career/jobs/deadline",
                                         {"title": "X", "deadline": t, "ref": "job:6"},
                                         format="json").json()["reminders"]), 1)
        # clearing removes
        self.c.post(V + "/career/jobs/deadline", {"title": "X", "deadline": "", "ref": "job:5"}, format="json")
        self.assertFalse(Reminder.objects.filter(user=self.u, link__ref="job:5").exists())
        self.assertEqual(self.c.post(V + "/career/jobs/deadline",
                                     {"title": "X", "deadline": "31-31-2026", "ref": "a"},
                                     format="json").status_code, 400)

    def test_status_lists_honest_portals(self):
        d = self.c.get(V + "/career/status").json()
        self.assertTrue(d["enabled"])
        self.assertFalse(d["careerjet_ready"])
        ids = {p["id"]: p for p in d["portals"]}
        self.assertFalse(ids["bdjobs"]["feed"])
        self.assertFalse(ids["bpsc"]["feed"])
        self.assertTrue(d["feeds_note"])
        self.assertTrue(d["safety"])


class InterviewTests(TestCase):
    def setUp(self):
        flag(True)
        self.u = User.objects.create_user(name="I", phone="01710000703", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def tearDown(self):
        FF.invalidate()

    def test_roles_and_questions(self):
        roles = self.c.get(V + "/career/interview/roles?lang=bn").json()["roles"]
        self.assertGreaterEqual(len(roles), 8)
        q = self.c.get(V + "/career/interview/roles/govt_viva?lang=bn").json()
        self.assertRegex(q["questions"][0]["text"], r"[ঀ-৿]")
        self.assertEqual(self.c.get(V + "/career/interview/roles/nope").status_code, 404)

    def test_rubric_without_key(self):
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("no_key")):
            d = self.c.post(V + "/career/interview/feedback",
                            {"qid": "it2", "answer": "I reproduce it, read the log, fix and test.",
                             "lang": "en", "ai": True}, format="json").json()
        self.assertGreater(d["rubric"]["score"], 0)
        self.assertFalse(d["ai"]["ai_used"])
        self.assertEqual(d["ai"]["reason"], "no_key")

    def test_ai_feedback_via_router(self):
        seen = {}

        def fake(**kw):
            seen.update(kw)
            return "- Clear steps\n- Add a number", 0.0

        with mock.patch.object(ai, "generate", side_effect=fake):
            d = self.c.post(V + "/career/interview/feedback",
                            {"qid": "bk1", "answer": "আমি গ্রাহকদের সেবা দিতে চাই", "lang": "bn",
                             "ai": True}, format="json").json()
        self.assertTrue(d["ai"]["ai_used"])
        self.assertIn("Clear steps", d["ai"]["text"])
        self.assertEqual(seen["feature"], "career.interview")
        self.assertEqual(seen["tier"], "cheap")
        self.assertIn("Bangla", seen["task"])

    def test_ai_not_called_unless_asked_and_capped(self):
        with mock.patch.object(ai, "generate") as g:
            d = self.c.post(V + "/career/interview/feedback",
                            {"qid": "bk1", "answer": "x"}, format="json").json()
            g.assert_not_called()
        self.assertIsNone(d["ai"])
        with mock.patch.object(S, "_ai_calls_today", return_value=S.AI_INTERVIEW_DAILY_CAP), \
                mock.patch.object(ai, "generate") as g:
            d = self.c.post(V + "/career/interview/feedback",
                            {"qid": "bk1", "answer": "x", "ai": True}, format="json").json()
            g.assert_not_called()
        self.assertEqual(d["ai"]["reason"], "cap")
        self.assertEqual(self.c.post(V + "/career/interview/feedback",
                                     {"qid": "zz", "answer": "x"}, format="json").status_code, 404)
