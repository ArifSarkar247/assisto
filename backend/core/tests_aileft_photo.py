"""aileft (owner 3 Nov 23:25 PART 7): Photo Studio safety gaps, NID size,
no charge when the face changed, "Add to business catalog"."""
import io

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import billing
from core import photo_studio_service as S
from core.logic import photo_studio as PS
from core.models import BusinessProfile, PhotoStudioJob, Product

_PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00"
        b"\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05\xfe\x02\xfe\xa7"
        b"\x9a\xa0\xa0\x00\x00\x00\x00IEND\xaeB`\x82")


def _u(phone, name="Rina"):
    return get_user_model().objects.create_user(name=name, phone=phone, password="pw12345!")


class SafetyGapTests(SimpleTestCase):
    def reason(self, prompt, **kw):
        return PS.classify(prompt, **kw)["reason"]

    def test_undressing_synonyms(self):
        for p in ("strip her", "make her swimsuit", "x-ray the dress", "remove her saree",
                  "transparent dress", "half naked", "শাড়ি খুলে দাও", "অর্ধনগ্ন করো"):
            self.assertEqual(self.reason(p), "sexual", p)

    def test_face_swap_onto_another_person(self):
        for p in ("head swap with my friend", "put my face on his body",
                  "her face on another person", "faceswap", "মুখ বসাও ওর ছবিতে",
                  "replace her face with mine"):
            self.assertEqual(self.reason(p), "fake_scene", p)

    def test_fake_id_documents(self):
        for p in ("make a fake passport", "fake NID for me", "create an id card with my photo",
                  "ভুয়া পাসপোর্ট বানাও", "জাল আইডি"):
            self.assertEqual(self.reason(p), "document_fraud", p)

    def test_harmful_edits_of_minors(self):
        for p in ("add bruises", "make him look injured", "give him a cigarette",
                  "add a gun", "রক্ত দাও"):
            self.assertEqual(self.reason(p, child_in_photo=True), "child_harm", p)
        self.assertEqual(self.reason("make my son sexy"), "sexual")

    def test_normal_edits_still_pass(self):
        for p in ("remove background", "white background for my passport photo",
                  "make the sky blue", "brighter and clean", "Eid outfit for my son",
                  "product photo for Facebook", "make me into a cartoon"):
            self.assertEqual(self.reason(p), "ok", p)

    def test_refusal_messages_exist(self):
        self.assertIn("child", S.refusal_message("child_harm", "en"))
        self.assertTrue(S.refusal_message("child_harm", "bn"))


class NidSizeTests(SimpleTestCase):
    def test_nid_is_the_sourced_passport_size(self):
        p = PS.BD_PHOTO_SIZES["nid_bd"]
        self.assertEqual((p["w_mm"], p["h_mm"], p["px_w"], p["px_h"]), (45, 55, 531, 650))
        self.assertEqual(p["bg"], "#FFFFFF")
        self.assertTrue(p["source"].startswith("https://bhclondon.org.uk/nid"))
        self.assertIn("registration office", p["note"])


class FaceChangedRefundTests(TestCase):
    def test_face_check_rejection_refunds_once_and_blocks_export(self):
        u = _u("+8801411000301")
        billing.credit(u, "topup", 30, note="pack:test")
        res = billing.charge(u, "photo_generate", exact=6, note="photo")
        self.assertTrue(res["ok"])
        u.refresh_from_db()
        before = u.ai_credits
        j = PhotoStudioJob.objects.create(user=u, feature="prompt_edit", status="done",
                                          funding="credits", credits_charged=6)
        c = APIClient()
        c.force_authenticate(u)
        r = c.post(f"/api/v1/photo-studio/jobs/{j.pk}/report",
                   {"reason": "face_changed", "note": "auto:identity_check"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.json()["refunded"], 6)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, before + 6)
        j.refresh_from_db()
        self.assertEqual(j.status, "failed")
        # twice = nothing more
        c.post(f"/api/v1/photo-studio/jobs/{j.pk}/report",
               {"reason": "face_changed", "note": "auto:identity_check"}, format="json")
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, before + 6)
        # export is refused now
        code, _ = S.unlock(u, j, "save", "en")
        self.assertNotEqual(code, 200)

    def test_a_user_report_does_not_refund(self):
        u = _u("+8801411000302")
        j = PhotoStudioJob.objects.create(user=u, feature="prompt_edit", status="done",
                                          funding="credits", credits_charged=6)
        code, body = S.report_ai_image(u, j, "face_changed", "my nose looks odd", "en")
        self.assertEqual(code, 201)
        self.assertNotIn("refunded", body)
        j.refresh_from_db()
        self.assertEqual(j.status, "done")


class CatalogPhotoTests(TestCase):
    def setUp(self):
        self.u = _u("+8801411000310")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _img(self):
        return SimpleUploadedFile("p.png", _PNG, content_type="image/png")

    def test_no_shop_means_no_catalog_and_none_is_created(self):
        r = self.c.get("/api/v1/business/products/photo")
        self.assertEqual(r.json(), {"has_catalog": False, "products": []})
        self.assertFalse(BusinessProfile.objects.filter(user=self.u).exists())
        r = self.c.post("/api/v1/business/products/photo", {"photo": self._img(), "name": "x"},
                        format="multipart")
        self.assertEqual(r.status_code, 404)

    def test_new_product_with_the_photo(self):
        BusinessProfile.objects.create(user=self.u, shop_name="Rina Store")
        self.assertTrue(self.c.get("/api/v1/business/products/photo").json()["has_catalog"])
        r = self.c.post("/api/v1/business/products/photo",
                        {"photo": self._img(), "name": "Blue saree", "price": "1450"},
                        format="multipart")
        self.assertEqual(r.status_code, 201, r.content[:300])
        p = Product.objects.get(user=self.u)
        self.assertEqual(p.name, "Blue saree")
        self.assertTrue(p.photo)
        self.assertTrue(r.json()["product"]["photo"])

    def test_photo_on_an_existing_product_only_my_own(self):
        prof = BusinessProfile.objects.create(user=self.u, shop_name="Rina Store")
        p = Product.objects.create(user=self.u, business=prof, name="Tea", price=10)
        r = self.c.post("/api/v1/business/products/photo",
                        {"photo": self._img(), "product_id": p.pk}, format="multipart")
        self.assertEqual(r.status_code, 200)
        other = _u("+8801411000311")
        oprof = BusinessProfile.objects.create(user=other, shop_name="X")
        op = Product.objects.create(user=other, business=oprof, name="Theirs", price=1)
        r = self.c.post("/api/v1/business/products/photo",
                        {"photo": self._img(), "product_id": op.pk}, format="multipart")
        self.assertEqual(r.status_code, 404)
        op.refresh_from_db()
        self.assertFalse(op.photo)

    def test_not_an_image_is_refused(self):
        BusinessProfile.objects.create(user=self.u, shop_name="Rina Store")
        bad = SimpleUploadedFile("p.png", b"hello world!!", content_type="image/png")
        r = self.c.post("/api/v1/business/products/photo", {"photo": bad, "name": "x"},
                        format="multipart")
        self.assertEqual(r.json()["code"], "not_image")
