"""adminboards: Owner Admin Vision checklist + Quality board pages, parsed live
from owner_actions/*.md (real files + synthetic files), auth/audit, and the
board_summary management command."""
import io
import json
import os
import tempfile
import time
from pathlib import Path

from django.core.management import call_command
from django.test import SimpleTestCase, override_settings

from core.models import AdminStaffRole, OwnerAudit, OwnerSession, User
from web.owner import boards as B
from web.owner import security as S
from web.tests_o2_owner_admin import OwnerBase, SClient

QUALITY_MD = """# board
**তারিখ:** ৯ Nov ২০২৬ · **মোট ফিচার:** 3

| # | ফিচার | সেরা অ্যাপ (অভ্যন্তরীণ) | ১ | ২ | ৩ | ৪ | ৫ | ৬ | সর্বমোট | কী বাকি |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | AI চ্যাট | ChatGPT | 9 | 9 | 9 | 10 | 9 | 9 | **9** | কিছু না |
| ২ | **CCTV** | Hik | ২ | 5 | 5 | 6 | 4 | 6 | **২** | আসল `ক্যামেরা` প্রমাণ |
| 3 | রিমাইন্ডার | Keep | 4 | 7 | 7 | 7 | 5 | 7 | **4** | দুই-ফোন প্রমাণ |
"""

VISION_MD = """# চেকলিস্ট
**তারিখ:** ৯ Nov ২০২৬ (০২:৩০ BD)।

## গুরুত্ব ১ — লঞ্চ-জরুরি

| # | ফিচার | অবস্থা | কী বাকি (এক লাইন) | পরিকল্পনা (এক লাইন) | ৮ Nov-এ ওয়ার্ল্ড ক্লাস? | মালিকের জিনিস |
|---|---|---|---|---|---|---|
| ১ | **কলের পরে নোট** ⭐লঞ্চ-জরুরি — SIM কল শেষে | ❌ তৈরি হয়নি | সব | তৈরি | না | Play ঘোষণা |
| ২ | **Hey Assisto** | 🟡 আংশিক | ফোন প্রমাণ | টেস্ট | আংশিক | — |

## গুরুত্ব ৩ — পরে

| # | ফিচার | অবস্থা | কী বাকি (এক লাইন) | পরিকল্পনা (এক লাইন) | ৮ Nov-এ ওয়ার্ল্ড ক্লাস? | মালিকের জিনিস |
|---|---|---|---|---|---|---|
| ৬২ | **লিংকড ডিভাইস** | ✅ কাজ করে | কিছু না | — | হ্যাঁ | ২ ডিভাইস |
"""


def _write(d, name, text):
    p = Path(d) / name
    p.write_text(text, encoding="utf-8")
    return p


# ============================================================ real files
class RealFilesParserTests(SimpleTestCase):
    """The parser on the real owner_actions files of this checkout."""
    def setUp(self):
        B.clear_cache()

    def test_quality_board_real(self):
        q = B.quality()
        self.assertIsNotNone(q, "owner_actions/QUALITY_BOARD_BN.md missing")
        self.assertGreaterEqual(q["total"], 50)
        ns = [r["n"] for r in q["rows"]]
        self.assertEqual(len(ns), len(set(ns)), "duplicate row numbers")
        for r in q["rows"]:
            self.assertIsNotNone(r["total"], r)
            self.assertTrue(0 <= r["total"] <= 10, r)
            self.assertEqual(len(r["scores"]), 6)
            self.assertTrue(r["feature"])
            self.assertNotIn("**", r["feature"])
            self.assertEqual(r["ready"], r["total"] >= 9)
        self.assertEqual(q["passed"] + q["below"], q["total"])
        for r in q["rows"]:
            if not r["ready"]:
                self.assertTrue(r["missing"], "below-9 row without 'what is missing': %s" % r["n"])

    def test_vision_checklist_real(self):
        v = B.vision()
        self.assertIsNotNone(v, "owner_actions/OWNER_VISION_CHECKLIST_BN.md missing")
        self.assertGreaterEqual(v["total"], 50)
        self.assertEqual(sum(v["counts"].values()), v["total"])
        imps = {i["importance"] for i in v["items"]}
        self.assertTrue(imps <= {1, 2, 3}, imps)
        self.assertIn(1, imps)
        self.assertTrue(any(i["launch_critical"] for i in v["items"]))
        known = [i for i in v["items"] if i["status"] != B.STATUS_UNKNOWN]
        self.assertGreaterEqual(len(known), v["total"] - 2)
        for i in v["items"]:
            self.assertTrue(i["feature"])
            self.assertTrue(i["title"])
        self.assertTrue(v["date"])


# ============================================================ synthetic
class SyntheticParserTests(SimpleTestCase):
    def setUp(self):
        B.clear_cache()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ov = override_settings(OWNER_BOARDS_DIR=self.tmp.name)
        self.ov.enable()
        self.addCleanup(self.ov.disable)
        self.addCleanup(B.clear_cache)

    def test_quality_bangla_digits_and_markup(self):
        _write(self.tmp.name, B.QUALITY_FILE, QUALITY_MD)
        q = B.quality()
        self.assertEqual((q["total"], q["passed"], q["below"]), (3, 1, 2))
        r2 = [r for r in q["rows"] if r["n"] == 2][0]
        self.assertEqual(r2["total"], 2)
        self.assertEqual(r2["scores"][0], 2)
        self.assertEqual(r2["feature"], "CCTV")
        self.assertEqual(r2["missing"], "আসল ক্যামেরা প্রমাণ")
        self.assertEqual(q["date"], "৯ Nov ২০২৬")

    def test_vision_sections_status_importance(self):
        _write(self.tmp.name, B.VISION_FILE, VISION_MD)
        v = B.vision()
        self.assertEqual(v["total"], 3)
        self.assertEqual(v["counts"], {"done": 1, "partial": 1, "missing": 1, "unknown": 0})
        by = {i["n"]: i for i in v["items"]}
        self.assertEqual(by[1]["importance"], 1)
        self.assertEqual(by[62]["importance"], 3)
        self.assertEqual(by[1]["title"], "কলের পরে নোট")
        self.assertEqual(by[1]["owner_items"], "Play ঘোষণা")
        self.assertEqual(by[62]["status"], B.STATUS_DONE)

    def test_cache_follows_file_change(self):
        p = _write(self.tmp.name, B.QUALITY_FILE, QUALITY_MD)
        self.assertEqual(B.quality()["passed"], 1)
        self.assertIs(B.quality(), B.quality())          # cached between requests
        p.write_text(QUALITY_MD.replace("**4** |", "**9** |").replace("| 4 | 7 | 7 | 7 | 5 | 7 |",
                                                                      "| 9 | 9 | 9 | 9 | 9 | 9 |"),
                     encoding="utf-8")
        st = p.stat()
        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000_000))
        self.assertEqual(B.quality()["passed"], 2)        # STATUS update shows at once

    def test_missing_files(self):
        self.assertIsNone(B.quality())
        self.assertIsNone(B.vision())
        self.assertEqual(B.summary(), {})

    def test_command_board_summary(self):
        _write(self.tmp.name, B.QUALITY_FILE, QUALITY_MD)
        _write(self.tmp.name, B.VISION_FILE, VISION_MD)
        out = io.StringIO()
        call_command("board_summary", "--below9", stdout=out)
        txt = out.getvalue()
        self.assertIn("Quality board: 1 / 3 features at >= 9 (below 9: 2)", txt)
        self.assertIn("Vision checklist: 3 items: done 1 · partial 1 · not built 1", txt)
        self.assertLess(txt.index("#2 CCTV"), txt.index("#3 রিমাইন্ডার"))   # weakest first
        out = io.StringIO()
        call_command("board_summary", "--json", stdout=out)
        d = json.loads(out.getvalue())
        self.assertEqual(d["quality"]["passed"], 1)
        self.assertEqual(d["vision"]["launch_critical_total"], 2)


# ============================================================ pages
class BoardsPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        B.clear_cache()
        self.ready()

    def test_quality_page_real_file(self):
        r = self.c.get("/owner/quality?lang=en")
        self.assertEqual(r.status_code, 200)
        q = B.quality()
        self.assertContains(r, "%d / %d" % (q["passed"], q["total"]))
        self.assertContains(r, "Features at 9 or more")
        self.assertTrue(OwnerAudit.objects.filter(action="boards.view", target="quality:all",
                                                  actor=self.owner).exists())

    def test_vision_page_real_file_bn(self):
        r = self.c.get("/owner/vision?lang=bn")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "ভিশন চেকলিস্ট")
        self.assertContains(r, "আপনার কাছ থেকে লাগবে")

    def test_filters_and_below9_list(self):
        with tempfile.TemporaryDirectory() as d, override_settings(OWNER_BOARDS_DIR=d):
            B.clear_cache()
            _write(d, B.QUALITY_FILE, QUALITY_MD)
            _write(d, B.VISION_FILE, VISION_MD)
            r = self.c.get("/owner/quality?lang=en&view=below9")
            body = r.content.decode()
            self.assertIn("Below 9 — what is missing", body)
            self.assertNotIn("#1 AI চ্যাট", body)
            self.assertLess(body.index("#2 CCTV"), body.index("#3 রিমাইন্ডার"))
            self.assertIn("1 / 3", body)
            r = self.c.get("/owner/quality?lang=en&q=keep")
            self.assertContains(r, "রিমাইন্ডার")
            self.assertNotContains(r, "ChatGPT")
            r = self.c.get("/owner/vision?lang=en&status=missing")
            self.assertContains(r, "কলের পরে নোট")
            self.assertNotContains(r, "লিংকড ডিভাইস")
            r = self.c.get("/owner/vision?lang=en&imp=3")
            self.assertContains(r, "লিংকড ডিভাইস")
            self.assertNotContains(r, "Hey Assisto")
            r = self.c.get("/owner/vision?lang=en&owner=1")
            self.assertNotContains(r, "Hey Assisto")       # "—" = nothing needed
            r = self.c.get("/owner/vision?lang=en&q=Hey&status=bogus&imp=9")
            self.assertContains(r, "Hey Assisto")
            r = self.c.get("/owner/vision?lang=en&q=zzzz")
            self.assertContains(r, "Nothing matches")
        B.clear_cache()

    def test_missing_file_is_empty_state_not_500(self):
        with tempfile.TemporaryDirectory() as d, override_settings(OWNER_BOARDS_DIR=d):
            B.clear_cache()
            for url in ("/owner/vision?lang=en", "/owner/quality?lang=en"):
                r = self.c.get(url)
                self.assertEqual(r.status_code, 200)
                self.assertContains(r, "The file is not on this server yet")
        B.clear_cache()

    def test_post_not_allowed(self):
        self.assertEqual(self.post("/owner/quality", {}).status_code, 405)


class BoardsAuthTests(OwnerBase):
    def test_anonymous_redirects(self):
        for url in ("/owner/vision", "/owner/quality"):
            r = SClient().get(url)
            self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))

    def test_staff_role_is_refused_and_audited(self):
        pw = "staff-pass-123"
        s = User.objects.create_user(name="Staff", phone="01710002091", password=pw)
        AdminStaffRole.objects.create(user=s, role="readonly", granted_by=self.owner)
        c = SClient()
        c.post("/owner/login", {"phone": "01710002091", "password": pw})
        c.get("/owner/enrol")
        sess = OwnerSession.objects.get(key_hash=S.sha256(c.cookies[S.COOKIE].value))
        secret = S.decrypt(sess.pending_secret_enc)
        self.assertEqual(c.post("/owner/enrol", {"code": S.totp(secret),
                                                 "_ot": sess.csrf}).status_code, 200)
        for url in ("/owner/vision", "/owner/quality"):
            self.assertEqual(c.get(url).status_code, 403, url)
        self.assertTrue(OwnerAudit.objects.filter(action="staff.denied", actor=s).exists())
        self.assertFalse(OwnerAudit.objects.filter(action="boards.view", actor=s).exists())
