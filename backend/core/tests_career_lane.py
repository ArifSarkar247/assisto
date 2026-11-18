"""career lane (board rows 28 CV builder, 29 mock interview, 32 learning
certificate) — proof for the gaps in owner_actions/gaps/career_BN.md.

* CV PDF in Bangla AND English: A4, both faces embedded, headings in the CV
  language, the copy / ATS text layer gives back the real Bangla (ActualText),
  page numbers on a multi-page CV, photo optional;
* mock interview AI feedback is charged ONCE per (question, answer, language):
  a retry / double tap returns the saved feedback with charged 0, a running
  request blocks a second charge, a failed call leaves nothing behind so the
  retry may run; the 4 core BD roles have 10 questions each;
* certificate: a real code verifies, a tampered / never-issued code does not,
  the PDF carries the verify URL (QR target) and never the phone / e-mail.
All sample data is made up.
"""
import os
import unittest
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai
from core import career_service as S
from core import feature_flags as FF
from core import learn_cert as LC
from core.logic import career_content as CC
from core.models import FeatureFlag, PaCollectionItem, User

try:
    import pypdfium2 as pdfium
except Exception:  # noqa: BLE001 — CI-only dependency (checks.yml)
    pdfium = None

V = "/api/v1"
BN_NAME = "স্ত্রী কৃষ্ণ প্রত্যেক"
BN_CV = {
    "name": BN_NAME, "headline": "জুনিয়র হিসাবরক্ষক", "phone": "01700000000",
    "email": "sample@example.com", "location": "মিরপুর, ঢাকা", "format": "govt",
    "summary": "প্রত্যেক মাসের হিসাব নির্ভুল রাখি; ক্ষুদ্র ঋণ ও ভ্যাট রিটার্নে দক্ষ।",
    "education": [{"degree": "বিবিএ (হিসাববিজ্ঞান)", "institution": "ঢাকা কলেজ", "year": "২০২২"}],
    "experience": [{"title": "হিসাব সহকারী", "org": "র‍্যাব সমবায়", "dates": "২০২২–২০২৪",
                    "bullets": "মাসে ৩০০টি ভাউচার মিলিয়ে দেখা\nভ্যাট রিটার্ন তৈরি"}],
    "skills": ["ট্যালি", "এক্সেল", "ভ্যাট", "বাংলা টাইপিং", "রিপোর্ট"],
    "personal": {"father": "করিম উদ্দিন", "nationality": "বাংলাদেশি"},
}


def _flag(key, on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def _text(pdf):
    doc = pdfium.PdfDocument(pdf)
    return "\n".join(doc[i].get_textpage().get_text_range() for i in range(len(doc)))


def _need_pdfium(test):
    return unittest.skipIf(pdfium is None and not os.environ.get("CI"),
                           "pypdfium2 is CI-only")(test)


class CvPdfLangTests(TestCase):
    def test_bangla_pdf_a4_fonts_headings(self):
        pdf = S.cv_pdf(BN_CV, "bn")
        self.assertTrue(pdf.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsBn", pdf)          # Noto Sans Bengali embedded
        self.assertIn(b"FontFile2", pdf)            # as a real embedded TrueType
        self.assertRegex(pdf, rb"/MediaBox \[ ?0 0 595\.27\d* 841\.88\d* ?\]")   # A4

    @_need_pdfium
    def test_bangla_text_layer_is_real_bangla(self):
        self.assertIsNotNone(pdfium, "CI must pip install pypdfium2")
        txt = _text(S.cv_pdf(BN_CV, "bn"))
        compact = "".join(txt.split())
        for want in (BN_NAME, "শিক্ষাগত যোগ্যতা", "কাজের অভিজ্ঞতা", "ব্যক্তিগত তথ্য",
                     "প্রত্যয়ন", "স্বাক্ষর", "র‍্যাব সমবায়", "ক্ষুদ্র ঋণ"):
            self.assertIn("".join(want.split()), compact, want)
        self.assertNotIn("Education", txt)
        self.assertIn("sample@example.com", txt)    # Latin stays plain text

    @_need_pdfium
    def test_english_headings_unchanged(self):
        self.assertIsNotNone(pdfium)
        txt = _text(S.cv_pdf(dict(BN_CV, name="Rahim Uddin", format="experienced"), "en"))
        self.assertIn("WORK EXPERIENCE", txt)
        self.assertIn("Rahim Uddin", txt)

    @_need_pdfium
    def test_multi_page_has_page_numbers_single_page_has_none(self):
        self.assertIsNotNone(pdfium)
        one = S.cv_pdf(BN_CV, "bn")
        self.assertEqual(len(pdfium.PdfDocument(one)), 1)
        self.assertNotIn("পাতা", _text(one))
        long = dict(BN_CV, experience=[
            {"title": "পদ %d" % i, "org": "প্রতিষ্ঠান", "dates": "২০২০",
             "bullets": "\n".join("দায়িত্ব নম্বর %d — প্রত্যেক মাসের হিসাব নির্ভুল রাখা" % j
                                  for j in range(10))} for i in range(8)])
        pdf = S.cv_pdf(long, "bn")
        n = len(pdfium.PdfDocument(pdf))
        self.assertGreaterEqual(n, 2)
        compact = "".join(_text(pdf).split())
        self.assertIn("পাতা১/" + LC.bn_digits(n), compact)
        en = S.cv_pdf(dict(long, name="Rahim"), "en")
        self.assertIn("Page 1 of", _text(en))

    def test_photo_optional(self):
        import base64
        import io
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (40, 48), (200, 150, 100)).save(buf, "JPEG")
        with_photo = S.cv_pdf(dict(BN_CV, photo="data:image/jpeg;base64," +
                                   base64.b64encode(buf.getvalue()).decode()), "bn")
        self.assertIn(b"/Subtype /Image", with_photo)
        self.assertNotIn(b"/Subtype /Image", S.cv_pdf(BN_CV, "bn"))

    def test_endpoint_uses_saved_cv_language(self):
        _flag(S.FLAG)
        u = User.objects.create_user(name="R", phone="01710000881", password="pw12345!")
        c = APIClient()
        c.force_authenticate(u)
        self.assertIn(c.post(V + "/cv/", dict(BN_CV, cv_lang="bn"), format="json").status_code,
                      (200, 201))
        r = c.get(V + "/career/cv/pdf")
        self.assertEqual(r.status_code, 200)
        self.assertIn("cv-bn.pdf", r["Content-Disposition"])
        r = c.get(V + "/career/cv/pdf?lang=en")
        self.assertIn("cv-en.pdf", r["Content-Disposition"])


class InterviewChargeOnceTests(TestCase):
    def setUp(self):
        _flag(S.FLAG)
        self.u = User.objects.create_user(name="I", phone="01710000882", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.calls = 0

    def _fake(self, **kw):
        self.calls += 1
        kw["out_meta"]["charged"] = 1
        return "- ভালো শুরু\n- একটা সংখ্যা যোগ করুন", 0.0

    def _ask(self, answer="আমি গ্রাহকদের সেবা দিতে চাই, আস্থা ও আর্থিক ক্যারিয়ার গড়তে চাই।", qid="bk1"):
        return self.c.post(V + "/career/interview/feedback",
                           {"qid": qid, "answer": answer, "lang": "bn", "ai": True},
                           format="json").json()

    def test_same_answer_charged_once(self):
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            a = self._ask()
            b = self._ask()
            c = self._ask("  আমি গ্রাহকদের সেবা দিতে চাই, আস্থা ও আর্থিক   ক্যারিয়ার গড়তে চাই। ")
        self.assertEqual(self.calls, 1)
        self.assertEqual(a["ai"]["charged"], 1)
        self.assertFalse(a["ai"]["cached"])
        for x in (b, c):
            self.assertTrue(x["ai"]["cached"])
            self.assertEqual(x["ai"]["charged"], 0)
            self.assertEqual(x["ai"]["text"], a["ai"]["text"])

    def test_new_answer_or_language_is_a_new_feedback(self):
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            self._ask()
            self._ask("একদম অন্য উত্তর: আমি হিসাব ভালো বুঝি।")
            self._ask(qid="bk2")
        self.assertEqual(self.calls, 3)

    def test_running_request_blocks_a_second_charge(self):
        key = S._fb_key("bk1", "x y", "bn")
        PaCollectionItem.objects.create(user=self.u, collection=S.AI_FB_COLL,
                                        data={"k": key, "state": "pending", "qid": "bk1"})
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            d = self._ask("x y")
        self.assertEqual(self.calls, 0)
        self.assertEqual(d["ai"]["reason"], "in_progress")
        self.assertEqual(d["ai"]["charged"], 0)

    def test_stale_pending_does_not_block_forever(self):
        key = S._fb_key("bk1", "x y", "bn")
        row = PaCollectionItem.objects.create(user=self.u, collection=S.AI_FB_COLL,
                                              data={"k": key, "state": "pending"})
        PaCollectionItem.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - timedelta(minutes=5))
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            d = self._ask("x y")
        self.assertEqual(self.calls, 1)
        self.assertTrue(d["ai"]["ai_used"])

    def test_failure_leaves_nothing_and_retry_runs(self):
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("queued")):
            d = self._ask()
        self.assertFalse(d["ai"]["ai_used"])
        self.assertFalse(PaCollectionItem.objects.filter(user=self.u, collection=S.AI_FB_COLL).exists())
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            d = self._ask()
        self.assertEqual(self.calls, 1)
        self.assertTrue(d["ai"]["ai_used"])

    def test_other_user_never_gets_my_feedback(self):
        with mock.patch.object(ai, "generate", side_effect=self._fake):
            self._ask()
            other = User.objects.create_user(name="O", phone="01710000883", password="pw12345!")
            self.c.force_authenticate(other)
            d = self._ask()
        self.assertEqual(self.calls, 2)
        self.assertFalse(d["ai"]["cached"])

    def test_rubric_only_never_calls_ai(self):
        with mock.patch.object(ai, "generate") as g:
            d = self.c.post(V + "/career/interview/feedback",
                            {"qid": "gv9", "answer": "জাতিসংঘের ১৭টি লক্ষ্য, ২০৩০ সালের মধ্যে দারিদ্র্য দূর করা।"},
                            format="json").json()
            g.assert_not_called()
        self.assertGreaterEqual(len(d["rubric"]["hits"]), 4)


class QuestionBankTests(TestCase):
    def test_core_bd_roles_have_ten(self):
        for rid in ("bank", "garments", "it", "govt_viva"):
            self.assertEqual(len(CC.role_questions(rid, "bn")["questions"]), 10, rid)
        self.assertGreaterEqual(sum(len(r["qs"]) for r in CC.ROLES), 64)

    def test_new_questions_score_in_both_languages(self):
        en = CC.rubric("bk10", "First I calm the customer, then block the card at once, file the "
                               "complaint, keep a record and make him aware never to share an OTP.")
        bn = CC.rubric("bk10", "প্রথমে গ্রাহককে শান্ত করি, সাথে সাথে কার্ড ব্লক করি, অভিযোগ "
                               "জমা দিই, রেকর্ড রাখি আর সচেতন করি — OTP কাউকে নয়।")
        self.assertEqual(len(en["hits"]), 5)
        self.assertEqual(len(bn["hits"]), 5)


class CertVerifyTamperTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Nadia Islam", phone="01710000884",
                                          email="nadia@example.com", password="pw-123456")
        self.row = LC.issue_certificate(self.u, "lang_en", "B1", 78, name="Nadia Islam")
        self.code = self.row.data["code"]

    def test_valid_tampered_and_unissued(self):
        ok = self.client.get("/verify/%s?lang=en" % self.code)
        self.assertEqual(ok.status_code, 200)
        self.assertIn("genuine and valid", ok.content.decode())
        body = self.code.replace("-", "")[3:]
        swap = "B" if body[0] != "B" else "C"
        for bad in ("ALC-%s%s-%s-%s" % (swap, body[1:4], body[4:8], body[8:]),   # body letter
                    self.code[:-1] + ("A" if self.code[-1] != "A" else "B"),      # check letter
                    LC.new_code()):                                               # never issued
            r = self.client.get("/verify/%s?lang=en" % bad)
            self.assertEqual(r.status_code, 404, bad)
            self.assertNotIn("Nadia Islam", r.content.decode())

    @_need_pdfium
    def test_pdf_has_verify_url_no_pii(self):
        self.assertIsNotNone(pdfium)
        txt = _text(LC.pdf_bytes(self.row, "en"))
        self.assertIn(LC.verify_url(self.code), txt)
        self.assertIn("Nadia Islam", txt)
        for leak in ("01710000884", "nadia@example.com"):
            self.assertNotIn(leak, txt)
