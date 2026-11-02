"""photobar (2 Nov): Photo Studio launch bar — Bangladesh ID / passport / visa
photo presets carry exact pixels that match their print size, a source and a
verification level; the old unsourced 40x50 mm passport size is gone; the
one-tap "Passport (BD)" template prompt uses the same size; the config API
serves the presets to the app (which shows "check with the office")."""
from django.test import SimpleTestCase
from rest_framework.test import APITestCase

from core import photo_studio_service as S
from core.logic import photo_studio as PS
from core.models import User


class IdPresetTests(SimpleTestCase):
    def test_print_presets_pixels_match_mm_at_300dpi(self):
        for pid, p in PS.BD_PHOTO_SIZES.items():
            if p["w_mm"] is None:
                continue
            self.assertEqual(p["dpi"], 300, pid)
            self.assertEqual(p["px_w"], PS.mm_to_px(p["w_mm"]), pid)
            self.assertEqual(p["px_h"], PS.mm_to_px(p["h_mm"]), pid)

    def test_mm_to_px(self):
        self.assertEqual(PS.mm_to_px(45), 531)
        self.assertEqual(PS.mm_to_px(55), 650)
        self.assertEqual(PS.mm_to_px(25.4), 300)

    def test_every_preset_is_sourced_honestly(self):
        for pid, p in PS.BD_PHOTO_SIZES.items():
            self.assertIn(p["verified"], PS.ID_VERIFIED, pid)
            self.assertTrue(p["note"], pid)
            if p["verified"] != "common_practice":
                self.assertTrue(p["source"].startswith("https://"), pid)
            self.assertIn(p["fmt"], ("png", "jpg"), pid)
            if p["fmt"] == "jpg":
                self.assertGreater(p["max_kb"], 0, pid)  # portal upload limit
            self.assertEqual(p["bg"], "#FFFFFF", pid)

    def test_passport_is_45x55_not_the_old_unsourced_40x50(self):
        p = PS.BD_PHOTO_SIZES["passport_bd"]
        self.assertEqual((p["w_mm"], p["h_mm"]), (45, 55))
        self.assertIn("e-passport needs no photo", p["note"])

    def test_job_preset_is_the_teletalk_upload(self):
        p = PS.BD_PHOTO_SIZES["job_bd"]
        self.assertEqual((p["px_w"], p["px_h"], p["max_kb"], p["fmt"]), (300, 300, 100, "jpg"))
        self.assertIsNone(p["w_mm"])

    def test_template_prompts_use_the_preset_sizes(self):
        self.assertIn("45x55 mm", S.template_prompt("passport_bd"))
        self.assertIn("35x45 mm", S.template_prompt("visa_bd"))
        self.assertNotIn("40x50", S.template_prompt("passport_bd"))


class IdPresetApiTests(APITestCase):
    def test_config_serves_the_presets(self):
        u = User.objects.create_user(name="F", phone="01710000951", password="pw")
        self.client.force_authenticate(u)
        j = self.client.get("/api/v1/photo-studio/config").json()
        sizes = j["bd_sizes"]
        self.assertEqual(set(sizes), set(PS.BD_PHOTO_SIZES))
        self.assertEqual(sizes["passport_bd"]["px_w"], 531)
        self.assertEqual(sizes["visa_india"]["max_kb"], 1000)
