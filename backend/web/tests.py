"""Scenario tests for the 4 free web tools (logic + views, bn/en)."""
import io

from django.test import TestCase, Client
from PIL import Image

from web.logic import cv as cvlogic
from web.logic import scam as scamlogic
from web.logic import cards as cardlogic
from web.logic import photo as photologic
from web.logic import made30 as made30logic


# ---------------- W1: CV scoring ----------------
class CVScoreTests(TestCase):
    STRONG = (
        "Professional Summary: Results-driven marketer.\n"
        "Experience: Managed a team of 10. Increased sales 30%. Led 5 campaigns.\n"
        "Education: BSc in Marketing.\n"
        "Skills: Excel, SQL, Digital Marketing, Facebook Ads.\n"
        "Contact: arif@example.com, 01712345678, linkedin.com/in/arif\n"
        "- Built pipelines\n- Delivered results\n- Improved retention 20%"
    ) * 2

    def test_strong_cv_scores_high(self):
        r = cvlogic.score_cv(self.STRONG, lang="en")
        self.assertGreaterEqual(r["score"], 70)
        self.assertEqual(r["lang"], "en")
        self.assertTrue(r["keywords_found"])  # BD job-market keywords found

    def test_empty_cv_scores_low(self):
        r = cvlogic.score_cv("", lang="en")
        self.assertLess(r["score"], 40)
        self.assertEqual(r["word_count"], 0)

    def test_always_five_tips(self):
        r = cvlogic.score_cv("short", lang="en")
        self.assertEqual(len(r["tips"]), 5)

    def test_red_flag_unprofessional_email_penalised(self):
        txt = "Experience: did stuff. Contact: cool_babu420@gmail.com 01712345678"
        r = cvlogic.score_cv(txt, lang="en")
        self.assertGreater(r["penalty"], 0)
        self.assertTrue(r["red_flags"])

    def test_bangla_labels(self):
        r = cvlogic.score_cv("অভিজ্ঞতা: দল পরিচালনা করেছি।", lang="bn")
        self.assertEqual(r["breakdown"][0][0], "যোগাযোগ (ইমেইল+ফোন)")

    def test_score_bounded(self):
        for t in ["", "a", self.STRONG, self.STRONG * 10]:
            r = cvlogic.score_cv(t)
            self.assertTrue(0 <= r["score"] <= 100)


# ---------------- W2: scam detection ----------------
class ScamCheckTests(TestCase):
    def test_otp_phishing_is_scam(self):
        r = scamlogic.check_message("আপনার OTP কোডটি দিন, না হলে একাউন্ট বন্ধ হবে", lang="bn")
        self.assertEqual(r["verdict"], "scam")

    def test_prize_scam(self):
        r = scamlogic.check_message("Congratulations! You won a prize of 50000 taka. Send a fee now.", lang="en")
        self.assertEqual(r["verdict"], "scam")

    def test_bkash_refund_scam(self):
        r = scamlogic.check_message("ভুলে আপনার নম্বরে টাকা চলে গেছে, দয়া করে ফিরিয়ে দিন। বিকাশ ০১৭১২৩৪৫৬৭৮", lang="bn")
        self.assertIn(r["verdict"], ("scam", "suspicious"))

    def test_job_scam(self):
        r = scamlogic.check_message("ঘরে বসে আয় করুন! চাকরির জন্য আগে রেজিস্ট্রেশন ফি দিন।", lang="bn")
        self.assertIn(r["verdict"], ("scam", "suspicious"))

    def test_loan_scam(self):
        r = scamlogic.check_message("Instant loan, no documents needed! Apply now.", lang="en")
        self.assertIn(r["verdict"], ("scam", "suspicious"))

    def test_lookalike_link_flagged(self):
        r = scamlogic.check_message("Verify here: http://bkash-login.xyz/update", lang="en")
        self.assertEqual(r["verdict"], "scam")

    def test_benign_is_safe(self):
        r = scamlogic.check_message("আগামীকাল বিকেলে চা খেতে আসবে?", lang="bn")
        self.assertEqual(r["verdict"], "safe")

    def test_report_and_disclaimer_present(self):
        r = scamlogic.check_message("hello", lang="en")
        self.assertIn("999", r["report"])
        self.assertTrue(r["disclaimer"])

    def test_score_bounded(self):
        r = scamlogic.check_message("OTP PIN prize send money urgent bkash 01712345678 http://x.tk lottery loan", lang="en")
        self.assertTrue(0 <= r["score"] <= 100)


# ---------------- W3: photo sizing ----------------
def _make_img(w, h):
    img = Image.new("RGB", (w, h), (120, 120, 120))
    buf = io.BytesIO()
    img.save(buf, "JPEG")
    return buf.getvalue()


class PhotoTests(TestCase):
    def test_bd_passport_exact_size(self):
        out, label = photologic.make_photo(_make_img(1000, 1000), "bd_passport")
        im = Image.open(io.BytesIO(out))
        self.assertEqual(im.size, (413, 531))
        self.assertIn("35", label)

    def test_square_preset(self):
        out, _ = photologic.make_photo(_make_img(800, 1200), "us_visa")
        self.assertEqual(Image.open(io.BytesIO(out)).size, (600, 600))

    def test_all_presets_produce_valid_jpeg(self):
        src = _make_img(900, 1100)
        for key, p in photologic.PRESETS.items():
            out, _ = photologic.make_photo(src, key)
            im = Image.open(io.BytesIO(out))
            self.assertEqual(im.size, (p[2], p[3]))

    def test_print_sheet_is_valid(self):
        out, _ = photologic.make_photo(_make_img(600, 800), "bd_passport")
        sheet = photologic.print_sheet(out)
        self.assertEqual(Image.open(io.BytesIO(sheet)).size, (1200, 1800))

    def test_bg_note_present_both_langs(self):
        self.assertIn("key", photologic.BG_NOTE["en"])
        self.assertTrue(photologic.BG_NOTE["bn"])


# ---------------- W4: cards (festival + share) ----------------
class CardTests(TestCase):
    def test_festival_card_png(self):
        png = cardlogic.festival_card("eid", name="Arif", message="Best wishes", lang="en")
        self.assertTrue(png[:8].startswith(b"\x89PNG"))

    def test_all_festivals_render(self):
        for key in cardlogic.FESTIVALS:
            png = cardlogic.festival_card(key, name="X", lang="bn")
            self.assertTrue(png[:4] == b"\x89PNG"[:4])
            png2 = cardlogic.festival_card(key, lang="en")
            self.assertTrue(png2[:4] == b"\x89PNG"[:4])

    def test_festival_count(self):
        self.assertGreaterEqual(len(cardlogic.FESTIVALS), 8)

    def test_cv_card_both_langs(self):
        for lang in ("bn", "en"):
            png = cardlogic.cv_card(82, lang=lang)
            self.assertEqual(png[1:4], b"PNG")

    def test_scam_card_story(self):
        png = cardlogic.scam_card("Scam", "⚠️", story=True, lang="en")
        im = Image.open(io.BytesIO(png))
        self.assertEqual(im.size, (1080, 1920))


# ---------------- W5: Made in 30 seconds (instant shop poster) ----------------
class Made30Tests(TestCase):
    def test_parse_items_basic(self):
        items = made30logic.parse_items("Tea - 10 Tk\nSamosa - 15")
        self.assertEqual(items[0][0], "Tea")
        self.assertEqual(len(items), 2)

    def test_parse_items_multiple_separators(self):
        items = made30logic.parse_items("Tea : 10\nCoffee = 50\nCake | 120")
        self.assertEqual(len(items), 3)
        self.assertEqual(items[1][0], "Coffee")

    def test_parse_items_price_optional(self):
        items = made30logic.parse_items("Just a product name")
        self.assertEqual(items, [("Just a product name", "")])

    def test_parse_items_capped(self):
        items = made30logic.parse_items("\n".join(f"item{i} - {i}" for i in range(50)))
        self.assertLessEqual(len(items), made30logic.MAX_ITEMS)

    def test_parse_items_skips_blank(self):
        self.assertEqual(made30logic.parse_items("\n\n   \n"), [])

    def test_poster_png_both_langs(self):
        items = [("চা", "১০৳"), ("Coffee", "50")]
        for lang in ("bn", "en"):
            png = made30logic.poster_card("Arif Tea Stall", tagline="Fresh daily",
                                          items=items, phone="01712345678",
                                          theme="ocean", lang=lang)
            self.assertEqual(png[1:4], b"PNG")

    def test_poster_all_themes_render(self):
        for key in made30logic.THEMES:
            png = made30logic.poster_card("Shop", items=[("x", "1")], theme=key)
            self.assertEqual(png[:4][1:4], b"PNG")

    def test_poster_story_size(self):
        png = made30logic.poster_card("Shop", story=True)
        im = Image.open(io.BytesIO(png))
        self.assertEqual(im.size, (1080, 1920))

    def test_poster_no_items_still_renders(self):
        png = made30logic.poster_card("Open Shop", theme="royal", lang="bn")
        self.assertEqual(png[1:4], b"PNG")


# ---------------- Views: smoke (bn/en) ----------------
class ViewTests(TestCase):
    def setUp(self):
        self.c = Client()

    def test_landing_both_langs(self):
        self.assertEqual(self.c.get("/").status_code, 200)
        r = self.c.get("/?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Free tools")

    def test_all_pages_en(self):
        for url in ["/cv?lang=en", "/scam?lang=en", "/photo?lang=en",
                    "/festival?lang=en", "/made30?lang=en", "/get?lang=en"]:
            self.assertEqual(self.c.get(url).status_code, 200, url)

    def test_photo_en_has_bg_note(self):
        r = self.c.get("/photo?lang=en")
        self.assertContains(r, "image-AI key")  # honest key-gated state

    def test_cv_post_bn(self):
        r = self.c.post("/cv", {"cv_text": "Experience: managed a team. Skills: Excel"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "100")

    def test_cv_post_en(self):
        r = self.c.post("/cv?lang=en", {"cv_text": "Experience: managed. Education: BSc"})
        self.assertEqual(r.status_code, 200)

    def test_scam_post(self):
        r = self.c.post("/scam", {"message": "আপনি লটারি জিতেছেন, PIN দিন"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "প্রতারণা")

    def test_photo_get_lists_presets(self):
        r = self.c.get("/photo")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "NID")

    def test_festival_post(self):
        r = self.c.post("/festival", {"festival": "eid", "name": "Arif"})
        self.assertEqual(r.status_code, 200)

    def test_cv_card_endpoint(self):
        r = self.c.get("/cv/card.png?s=75")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "image/png")

    def test_festival_card_endpoint(self):
        r = self.c.get("/festival/card.png?f=victory&name=X&lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "image/png")

    def test_scam_card_endpoint(self):
        r = self.c.get("/scam/card.png?v=scam&lang=en")
        self.assertEqual(r.status_code, 200)

    def test_made30_post_bn(self):
        r = self.c.post("/made30", {"shop": "আরিফ টি স্টল",
                                    "items": "চা - ১০৳\nকফি - ৫০৳", "theme": "fresh"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "/made30/card.png")

    def test_made30_post_en(self):
        r = self.c.post("/made30?lang=en", {"shop": "Arif Tea Stall",
                                            "items": "Tea - 10", "theme": "ocean"})
        self.assertEqual(r.status_code, 200)

    def test_made30_empty_shop_errors(self):
        r = self.c.post("/made30?lang=en", {"shop": "", "items": "Tea - 10"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "shop / page name")

    def test_made30_card_endpoint(self):
        r = self.c.get("/made30/card.png?shop=Shop&i=Tea|10&theme=sunset&lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "image/png")
