"""pdfbn — every server PDF draws Bangla SHAPED (conjuncts, reph, ya-phala,
pre-base vowel signs), with Bangla digits and ৳, via the one shared layer
core/pdf_bn.py (reportlab + HarfBuzz).

Proof:
* unit checks — HarfBuzz is active, a conjunct shapes to fewer glyphs than
  code points, ি is reordered before its consonant, clusters / wrap never cut
  a conjunct, ৳ amounts use Bangladeshi grouping;
* GOLDEN IMAGES — each PDF type renders a fixed set of hard words
  (ক্ষ, জ্ঞ, ন্ত্র, স্ত্রী, কৃষ্ণ, প্রত্যেক, র‍্যাব, ঋণ, মাসিক হিসাব ৳১০,২৩৫.৫০)
  and page 1 is rasterised (pypdfium2, CI only) and compared with the
  reviewed PNG in core/test_goldens/pdfbn/. Re-make them after a reviewed
  layout change with PDFBN_WRITE_GOLDENS=1;
* endpoint checks — the real views embed the shaped Bangla face.
All sample data is made up.
"""
import datetime as dt
import io
import os
import pathlib
import time
import tracemalloc
import unittest
from types import SimpleNamespace

from django.test import SimpleTestCase, TestCase

from . import pdf_bn as P

HARD = "ক্ষ জ্ঞ ন্ত্র স্ত্রী কৃষ্ণ প্রত্যেক র‍্যাব ঋণ মাসিক হিসাব ৳১০,২৩৫.৫০"
GOLD = pathlib.Path(__file__).resolve().parent / "test_goldens" / "pdfbn"
SCALE = 1.5          # 893 x 1263 px for A4 portrait
PIX_TOL = 64         # grey-level difference that counts as a changed pixel
MAX_CHANGED = 0.002  # at most 0.2 % of the page may differ

try:
    import pypdfium2 as pdfium
except Exception:  # noqa: BLE001
    pdfium = None


# ---------------------------------------------------------------- fixtures

def _fixed_dt():
    return dt.datetime(2026, 11, 10, 10, 30, tzinfo=dt.timezone(dt.timedelta(hours=6)))


def render_all():
    """{type: pdf bytes} — one PDF per server PDF type, each carrying HARD."""
    from . import career_service, learn_cert, lp_service
    from .views import money_report_parts
    from .views_discover import report_pdf
    out = {}
    out["doctor_visit"] = P.report("Assisto — ডাক্তার ভিজিট সারাংশ", [
        "রোগী: " + "স্ত্রী কৃষ্ণ", "তারিখ: " + P.digits("2026-11-10", "bn")], [
        ("বর্তমান ওষুধ ও সময়সূচি", [
            ("b", "নাপা ৫০০mg: ১টি | ০৮:০০, ২০:০০ | খাওয়ার পরে"),
            ("sub", "মেনে চলা (৩০ দিন): ৯৬%"),
            ("b", HARD)]),
        ("সাম্প্রতিক প্রেসক্রিপশন", [
            ("b", "২০২৬-১১-০১ · ডা. প্রত্যেক: জ্বর ও ঋণ-চিন্তা"),
            ("sub", "· Napa Extend")])], lang="bn")
    out["data_export"] = P.report("Assisto — আমার তথ্য", ["ব্যবহারকারী: কৃষ্ণ"], [
        ("রিমাইন্ডার", [("b", "বিদ্যুৎ বিল (২০২৬-১১-১৫ ০৯:০০)"), ("b", HARD)]),
        ("নোট", [("b", "ক্ষমা ও জ্ঞান — mixed English line")]),
        ("করণীয়", [("b", "[হয়েছে] বাজার")])], lang="bn")
    rep = {"month": "2026-11", "income": 50000, "expense": 10235.5, "net": 39764.5,
           "savings_rate": 79.5,
           "by_category": [{"category": "মাসিক হিসাব — ক্ষ জ্ঞ ন্ত্র", "amount": 10235.5},
                           {"category": "র‍্যাব ঋণ (স্ত্রী)", "amount": 1023550}]}
    title, meta, sections = money_report_parts(rep, "bn")
    sections = sections + [("পরীক্ষা", [HARD])]
    out["money_report"] = P.report(title, meta, sections, lang="bn")
    out["lost_evidence"] = P.report("Assisto — হারানো / চুরি হওয়া ফোনের প্রমাণপত্র",
                                    ["তৈরি: ২০২৬-১১-১০ ১০:৩০"], [
        ("ফোনের তথ্য", [("row", "মালিক", "কৃষ্ণ প্রত্যেক"), ("row", "IMEI 1", "356938035643809"),
                        ("row", "শেষ দেখা (আনুমানিক)", "মিরপুর ১০, ঢাকা")]),
        ("ধরা পড়া ঘটনা", [("b", HARD)])], lang="bn",
        note="এই প্রমাণপত্র Assisto সার্ভারের নিজস্ব রেকর্ড থেকে তৈরি।")
    row = SimpleNamespace(data={"name": "স্ত্রী কৃষ্ণ প্রত্যেক", "course": "lang_en",
                                "level": "B1", "score": 82, "code": "PDFBN-TEST",
                                "issued_at": _fixed_dt().isoformat()},
                          created_at=_fixed_dt())
    out["learn_cert"] = learn_cert.pdf_bytes(row, "bn")
    att = SimpleNamespace(data={"variant": "academic",
                                "bands": {"listening": 7, "reading": 6.5}},
                          band=6.5, created_at=_fixed_dt())
    out["lp_cert"] = lp_service.certificate_pdf(att, "কৃষ্ণ প্রত্যেক (ক্ষ জ্ঞ)")
    out["cv"] = career_service.cv_pdf({
        "name": "স্ত্রী কৃষ্ণ", "headline": "হিসাবরক্ষক · Accountant",
        "phone": "01700-000000", "email": "sample@example.com", "location": "ঢাকা",
        "summary": HARD + " — প্রত্যেক মাসের হিসাব নির্ভুল রাখি।",
        "skills": ["ক্ষুদ্র ঋণ", "Excel"], "format": "experienced",
        "experience": [{"title": "জুনিয়র হিসাবরক্ষক", "org": "র‍্যাব সমবায়",
                        "dates": "২০২৪–২০২৬", "bullets": ["মাসিক হিসাব ৳১০,২৩৫.৫০ মিলিয়ে দেখা"]}]})
    out["discover_report"] = report_pdf({
        "card": {"title_en": HARD, "key": "pdfbn", "sponsor_name": "র‍্যাব ঋণ সেবা"},
        "from": "2026-11-01", "to": "2026-11-07",
        "rows": [{"date": "2026-11-0%d" % i, "impressions": 100 * i, "clicks": i, "ctr": i / 1.0}
                 for i in range(1, 4)],
        "totals": {"impressions": 600, "clicks": 6, "ctr": 1.0}})
    return out


def rasterise(pdf):
    """Page 1 -> greyscale PIL image."""
    page = pdfium.PdfDocument(pdf)[0]
    return page.render(scale=SCALE).to_pil().convert("L")


def page_text(pdf):
    doc = pdfium.PdfDocument(pdf)
    return "\n".join(doc[i].get_textpage().get_text_range() for i in range(len(doc)))


# ---------------------------------------------------------------- unit

class PdfBnUnitTests(SimpleTestCase):
    def test_harfbuzz_shaping_is_active(self):
        self.assertTrue(P.shaping_ok(), "pip install uharfbuzz (backend/requirements.txt)")

    def test_conjunct_and_vowel_sign_are_shaped(self):
        P.ensure_fonts()
        s, _w = P._shape1("ক্ষ", P.BN, 12, True)
        self.assertLess(len(s.__shapeData__), 3)       # one conjunct glyph, not ক + ্ + ষ
        ki, _w = P._shape1("কি", P.BN, 12, True)
        self.assertNotEqual(str(ki)[0], "ক")           # ি is drawn BEFORE ক
        plain, _w = P._shape1("ক্ষ", P.BN, 12, False)
        self.assertEqual(str(plain), "ক্ষ")

    def test_clusters_never_split_a_conjunct(self):
        self.assertEqual(P.clusters("প্রত্যেক"), ["প্র", "ত্যে", "ক"])
        self.assertEqual(P.clusters("স্ত্রী"), ["স্ত্রী"])
        self.assertEqual(P.clusters("র‍্যাব"), ["র‍্যা", "ব"])
        word = "প্রত্যেকমাসিকহিসাবক্ষজ্ঞন্ত্রস্ত্রীকৃষ্ণ"
        lines = P.wrap(word, 12, 40)
        self.assertGreater(len(lines), 1)
        self.assertEqual("".join(lines), word)
        for ln in lines:
            self.assertNotIn(ln[0], P._ATTACH)
            self.assertFalse(ln.endswith("্"))

    def test_wrap_keeps_words_and_width(self):
        text = (HARD + " ") * 6
        lines = P.wrap(text.strip(), 10, 200)
        self.assertEqual(" ".join(lines).split(), text.split())
        for ln in lines:
            self.assertLessEqual(P.width(ln, 10), 200.5)

    def test_runs_mixed_line(self):
        r = P.runs("নাপা 500mg — দিনে ২ বার")
        self.assertEqual([f for _s, f, _sh in r], [P.BN, P.LAT, P.BN])
        self.assertEqual("".join(s for s, _f, _sh in r), "নাপা 500mg — দিনে ২ বার")
        self.assertEqual([sh for _s, _f, sh in r], [True, False, True])

    def test_taka_and_digits(self):
        self.assertEqual(P.taka(10235.5, "bn"), "৳১০,২৩৫.৫০")
        self.assertEqual(P.taka(1023550.5, "en"), "৳10,23,550.50")
        self.assertEqual(P.taka(-75, "bn", 0), "-৳৭৫")
        self.assertEqual(P.taka(None, "en"), "৳0.00")
        self.assertEqual(P.digits("2026-11-10", "bn"), "২০২৬-১১-১০")
        self.assertEqual(P.digits("2026", "en"), "2026")

    def test_every_type_renders_fast_and_small(self):
        P.ensure_fonts()
        render_all()  # warm the font + shaper caches like a running worker
        tracemalloc.start()
        t0 = time.perf_counter()
        pdfs = render_all()
        secs = time.perf_counter() - t0
        peak = tracemalloc.get_traced_memory()[1]
        tracemalloc.stop()
        print("\npdfbn: %d PDFs in %.0f ms (%.0f ms each), peak %.1f MB, sizes %s" % (
            len(pdfs), secs * 1000, secs * 1000 / len(pdfs), peak / 1e6,
            {k: len(v) // 1024 for k, v in pdfs.items()}))
        self.assertEqual(len(pdfs), 8)
        for k, v in pdfs.items():
            self.assertTrue(v.startswith(b"%PDF"), k)
            self.assertLess(len(v), 400_000, k)       # fonts are subset-embedded
        self.assertLess(secs / len(pdfs), 1.5)
        self.assertLess(peak, 60e6)


# ---------------------------------------------------------------- goldens

@unittest.skipIf(pdfium is None and not os.environ.get("CI"), "pypdfium2 is CI-only")
class PdfBnGoldenTests(SimpleTestCase):
    def test_golden_images(self):
        self.assertIsNotNone(pdfium, "CI must pip install pypdfium2 (checks.yml)")
        import numpy as np
        write = os.environ.get("PDFBN_WRITE_GOLDENS") == "1"
        out_dir = pathlib.Path(os.environ.get("PDFBN_OUT") or "/tmp/pdfbn_out")
        bad = []
        for name, pdf in sorted(render_all().items()):
            img = rasterise(pdf)
            ref = GOLD / ("%s.png" % name)
            if write:
                GOLD.mkdir(parents=True, exist_ok=True)
                img.save(ref, optimize=True)
                continue
            self.assertTrue(ref.exists(), "missing golden %s" % ref)
            from PIL import Image
            want = Image.open(ref).convert("L")
            if want.size != img.size:
                bad.append("%s size %s != %s" % (name, img.size, want.size))
                continue
            diff = np.abs(np.asarray(img, dtype=np.int16) - np.asarray(want, dtype=np.int16))
            frac = float((diff > PIX_TOL).mean())
            if frac > MAX_CHANGED:
                out_dir.mkdir(parents=True, exist_ok=True)
                img.save(out_dir / ("%s.png" % name))
                bad.append("%s differs on %.3f%% of pixels (saved %s)" % (
                    name, frac * 100, out_dir / ("%s.png" % name)))
        self.assertEqual(bad, [])

    def test_text_layer_keeps_latin_and_disclaimers(self):
        pdfs = render_all()
        lp = page_text(pdfs["lp_cert"])
        self.assertIn("not an official IELTS or JLPT result", lp)
        self.assertNotIn("Official IELTS", lp)
        self.assertIn("Assisto", page_text(pdfs["money_report"]))
        self.assertIn("৳", page_text(pdfs["money_report"]))


# ---------------------------------------------------------------- endpoints

class PdfBnEndpointTests(TestCase):
    """Each real PDF endpoint embeds the shaped Bangla face for Bangla text."""

    def setUp(self):
        from django.contrib.auth import get_user_model
        from rest_framework.test import APIClient
        self.u = get_user_model().objects.create_user(
            name="কৃষ্ণ প্রত্যেক", phone="01700000917", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _bn_face(self, body):
        self.assertTrue(body.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsBn", body)

    def test_doctor_visit_pdf(self):
        from .models import Medicine
        Medicine.objects.create(user=self.u, name="ক্ষ জ্ঞ ন্ত্র", times=["08:00"])
        r = self.c.get("/api/v1/medicines/doctor-pdf?lang=bn", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self._bn_face(r.content)

    def test_data_export_pdf(self):
        r = self.c.get("/api/v1/export/pdf?lang=bn", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self._bn_face(r.content)

    def test_money_report_pdf(self):
        from .views import money_report_parts
        title, _m, sections = money_report_parts(
            {"month": "2026-11", "income": 0, "expense": 0, "net": 0, "savings_rate": 0,
             "by_category": []}, "bn")
        self.assertIn("২০২৬-১১", title)
        self.assertEqual(sections[0][1][0][2], "৳০.০০")
        self._bn_face(P.report(title, [], sections, lang="bn"))
        r = self.c.get("/api/v1/money/report.pdf", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "application/pdf")
        self._bn_face(r.content)

    def test_lost_evidence_pdf(self):
        self.c.post("/api/v1/security/heartbeat", {"lat": 23.70, "lng": 90.40, "battery": 40,
                                                   "network": "wifi"}, format="json")
        r = self.c.get("/api/v1/recovery/evidence.pdf", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        body = r.getvalue() if hasattr(r, "getvalue") else b"".join(r.streaming_content)
        self.assertEqual(r["Content-Type"], "application/pdf")
        self._bn_face(body)
