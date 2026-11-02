"""sitev3 — website v3 behind the go-live switch (owner final website order,
3 Nov). Switch OFF = the current site; ON = v3; /preview/ is always v3 and
noindex; never medicine; OFF flags = "Coming soon" with no Auto badge; cache
headers (HTML no-cache + ETag, hashed assets immutable); bn/en switch."""
import json
import re
from pathlib import Path
from unittest import mock

from django.test import Client, TestCase

from core import feature_flags as FF
from core.models import AdminFlagState, FeatureFlag, OwnerAudit
from web import site_v3 as V3
from web import site_v3_icons as ICONS
from web import views_site3 as VS3
from web.tests_o2_owner_admin import OwnerBase

PLANS = [
    {"id": "free", "name": "Free", "price": 0, "cur": "BDT", "period": "mo", "desc": "Start",
     "benefits": ["Safety free"], "ads": True},
    {"id": "premium", "name": "Premium", "price": 299, "cur": "BDT", "period": "mo",
     "desc": "More AI", "benefits": ["No ads"], "ads": False},
]
V3_MARK = 'class="v3"'
PREVIEW_PAGES = ["/preview/", "/preview/features", "/preview/pricing", "/preview/security",
                 "/preview/help"] + ["/preview/features/%s" % g for g in V3.GROUP_IDS]
ASSETS = Path(__file__).resolve().parent / "site_assets"


def set_live(value):
    row, _ = AdminFlagState.objects.get_or_create(key="global")
    row.state = dict(row.state or {}, website_v3=value)
    row.save()


def set_flag(key, on):
    FeatureFlag.objects.update_or_create(key=key, defaults={"enabled_all": on, "enabled_play": on,
                                                            "rollout_pct": 100})
    FF.invalidate()


class Base(TestCase):
    def setUp(self):
        FF.invalidate()
        self.c = Client()
        p = mock.patch("core.plans.plans_public", return_value=PLANS)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(FF.invalidate)


class SwitchTests(Base):
    def test_switch_off_serves_the_current_site(self):
        self.assertFalse(VS3.is_live())
        for path in ("/", "/pricing", "/security", "/help", "/?lang=en"):
            r = self.c.get(path)
            self.assertEqual(r.status_code, 200, path)
            self.assertNotContains(r, V3_MARK)
        for path in ["/features"] + ["/features/%s" % g for g in V3.GROUP_IDS]:
            self.assertEqual(self.c.get(path).status_code, 404, path)
        self.assertNotIn("/features/", self.c.get("/sitemap.xml").content.decode())

    def test_switch_on_serves_v3_and_rollback_restores(self):
        set_live(True)
        for path in ["/", "/pricing", "/security", "/help", "/features"] + \
                ["/features/%s" % g for g in V3.GROUP_IDS]:
            r = self.c.get(path)
            self.assertEqual(r.status_code, 200, path)
            self.assertContains(r, V3_MARK)
            self.assertContains(r, 'content="index, follow')
            self.assertNotIn("X-Robots-Tag", r)
        sm = self.c.get("/sitemap.xml").content.decode()
        self.assertIn("/features/safety", sm)
        self.assertNotIn("/preview", sm)
        set_live(False)   # one-tap rollback
        self.assertNotContains(self.c.get("/"), V3_MARK)
        self.assertEqual(self.c.get("/features/safety").status_code, 404)

    def test_unknown_group_404(self):
        set_live(True)
        self.assertEqual(self.c.get("/features/medicine").status_code, 404)
        self.assertEqual(self.c.get("/preview/features/nope").status_code, 404)


class PreviewTests(Base):
    def test_preview_is_v3_and_noindex_in_any_switch_state(self):
        for live in (False, True):
            set_live(live)
            for path in PREVIEW_PAGES:
                r = self.c.get(path)
                self.assertEqual(r.status_code, 200, path)
                self.assertContains(r, V3_MARK)
                self.assertIn("noindex", r["X-Robots-Tag"])
                self.assertContains(r, '<meta name="robots" content="noindex, nofollow">')
                self.assertContains(r, 'class="pv"')
                # links stay inside the preview
                self.assertContains(r, 'href="/preview/features/safety')


class HonestyTests(Base):
    def _all_pages(self):
        set_live(True)
        out = []
        for lang in ("", "?lang=en"):
            for path in PREVIEW_PAGES + ["/", "/features/safety"]:
                r = self.c.get(path + lang if "?" not in path else path)
                self.assertEqual(r.status_code, 200, path)
                out.append((path + lang, r.content.decode()))
        return out

    def test_never_medicine(self):
        bad = re.compile("|".join(re.escape(w) for w in V3.MEDICINE_WORDS), re.I)
        for path, html in self._all_pages():
            self.assertIsNone(bad.search(html), "%s mentions %s" % (path, bad.search(html)))
        for name in V3.shot_names():
            self.assertIsNone(bad.search(name))

    def test_off_flag_is_coming_soon_without_auto(self):
        set_flag("safe_journey", True)
        r = self.c.get("/preview/features/safety?lang=en").content.decode()
        auto = V3.FEATURES["safety"][1]["auto"][1]
        self.assertIn(auto, r)
        set_flag("safe_journey", False)
        r = self.c.get("/preview/features/safety?lang=en").content.decode()
        self.assertNotIn(auto, r)
        art = re.search(r'<article class="card fc rv is-soon" id="journey">.*?</article>', r, re.S)
        self.assertIsNotNone(art, "journey must be a Coming soon card")
        self.assertIn("Coming soon", art.group(0))
        self.assertNotIn('class="ab"', art.group(0))
        self.assertNotIn(auto, self.c.get("/preview/?lang=en").content.decode())

    def test_registry_default_off_features_are_coming_soon(self):
        flags, _ = FF.resolve(None, play=True)
        for gid in V3.GROUP_IDS:
            for f in V3.group_features(gid, "en", flags, False):
                src = next(x for x in V3.FEATURES[gid] if x["id"] == f["id"])
                if any(not flags.get(k, False) for k in src["flags"]) or src["soon"]:
                    self.assertFalse(f["live"], f["id"])
                    self.assertIsNone(f["auto"], f["id"])
        # AI-written features stay "Coming soon" until a provider is configured
        ask = [f for f in V3.group_features("ai", "en", flags, False) if f["id"] == "ask"][0]
        self.assertFalse(ask["live"])

    def test_every_flag_is_a_real_registry_key(self):
        for gid, feats in V3.FEATURES.items():
            for f in feats:
                for k in f["flags"]:
                    self.assertTrue(FF.is_known(k), "%s: %s" % (f["id"], k))
                self.assertTrue(ICONS.known(f["icon"]), f["icon"])
                self.assertTrue(f["bn"][0] and f["en"][0] and f["bn"][1] and f["en"][1])

    def test_cctv_plans_only_as_coming_soon(self):
        r = self.c.get("/preview/pricing").content.decode()
        block = re.search(r'id="cctv-plans">.*?</article>', r, re.S).group(0)
        self.assertIn("শীঘ্রই আসছে", block)
        self.assertIn("৳৫০০", block)
        text = re.sub(r"<[^>]+>", " ", block)
        self.assertNotRegex(text, r"[0-9]")       # Bangla digits only on bn pages

    def test_every_screenshot_and_icon_exists(self):
        for name in V3.shot_names():
            for lang in ("bn", "en"):
                for w in VS3.V3_WIDTHS:
                    p = ASSETS / "shots3" / ("%s_%s_%d.webp" % (name, lang, w))
                    self.assertTrue(p.is_file(), p.name)
        for w in (400, 600, 700):
            self.assertTrue((ASSETS / ("inter-%d.woff2" % w)).is_file())

    def test_jsonld_is_valid(self):
        for path in ("/preview/", "/preview/features/business?lang=en"):
            html = self.c.get(path).content.decode()
            raw = re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S).group(1)
            self.assertIn("@graph", json.loads(raw))


class CacheTests(Base):
    def test_html_no_cache_with_etag_and_304(self):
        for path in ("/preview/", "/"):
            r = self.c.get(path)
            self.assertEqual(r["Cache-Control"], "no-cache", path)
            tag = r["ETag"]
            self.assertTrue(tag.startswith('"'))
            r2 = self.c.get(path, HTTP_IF_NONE_MATCH=tag)
            self.assertEqual(r2.status_code, 304, path)
        set_live(True)
        r = self.c.get("/features/cctv")
        self.assertEqual(r["Cache-Control"], "no-cache")
        self.assertIn("ETag", r)

    def test_assets_are_hashed_and_immutable(self):
        html = self.c.get("/preview/?lang=en").content.decode()
        urls = set(re.findall(r'(/site/[^"\s,)]+)', html))
        self.assertTrue(any("shots3/" in u for u in urls))
        for u in urls:
            self.assertRegex(u, r"\?v=[0-9a-f]{10}$", u)
            r = self.c.get(u)
            self.assertEqual(r.status_code, 200, u)
            self.assertIn("max-age=31536000", r["Cache-Control"])
            self.assertIn("immutable", r["Cache-Control"])


class LanguageTests(Base):
    def test_switch_changes_every_text_title_meta_and_shot(self):
        bn = self.c.get("/preview/features/circle").content.decode()
        en = self.c.get("/preview/features/circle?lang=en").content.decode()
        self.assertIn('<html lang="bn"', bn)
        self.assertIn('<html lang="en"', en)
        self.assertIn("<title>%s</title>" % V3.GROUP_TEXT["circle"]["bn"][2], bn)
        self.assertIn("<title>%s</title>" % V3.GROUP_TEXT["circle"]["en"][2], en)
        self.assertIn('content="bn_BD"', bn)
        self.assertIn('content="en_US"', en)
        self.assertIn("og-bn.jpg", bn)
        self.assertIn("og-en.jpg", en)
        self.assertIn("_bn_360.webp", bn)
        self.assertNotIn("_en_360.webp", bn)
        self.assertIn("_en_360.webp", en)
        self.assertNotIn("_bn_360.webp", en)
        for html in (bn, en):
            self.assertIn('hreflang="bn"', html)
            self.assertIn('hreflang="en"', html)
        # the visible English page carries no Bangla UI text and vice versa
        self.assertNotIn(V3.COPY["bn"]["nav_pricing"], en)
        self.assertNotIn(">" + V3.COPY["en"]["nav_pricing"] + "<", bn)

    def test_choice_is_remembered(self):
        r = self.c.get("/preview/?lang=en")
        self.assertEqual(r.cookies["assisto_lang"].value, "en")
        r = self.c.get("/preview/")
        self.assertEqual(r.status_code, 302)
        self.assertTrue(r["Location"].endswith("?lang=en"))
        r = self.c.get("/preview/?lang=bn")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.cookies["assisto_lang"].value, "bn")
        self.assertEqual(self.c.get("/preview/").status_code, 200)

    def test_switch_link_points_to_the_other_language(self):
        bn = self.c.get("/preview/features/safety").content.decode()
        self.assertIn('href="/preview/features/safety?lang=en"', bn)
        en = self.c.get("/preview/features/safety?lang=en").content.decode()
        self.assertIn('href="/preview/features/safety?lang=bn"', en)


class OwnerSwitchTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_go_live_and_rollback_are_one_tap_and_audited(self):
        r = self.c.get("/owner/website")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "/preview/")
        r = self.post("/owner/website", {"action": "golive"})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(VS3.is_live())
        self.assertContains(Client().get("/"), V3_MARK)
        r = self.post("/owner/website", {"action": "rollback"})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(VS3.is_live())
        self.assertNotContains(Client().get("/"), V3_MARK)
        self.assertEqual(OwnerAudit.objects.filter(action="flag.flip").count(), 2)

    def test_bad_action_refused(self):
        r = self.post("/owner/website", {"action": "explode"})
        self.assertEqual(r.status_code, 400)
        self.assertFalse(VS3.is_live())
