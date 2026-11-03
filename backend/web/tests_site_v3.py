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
    row.state = dict(row.state or {}, website_classic=not value)
    row.save()


def set_flag(key, on):
    FeatureFlag.objects.update_or_create(key=key, defaults={"enabled_all": on, "enabled_play": on,
                                                            "rollout_pct": 100})
    FF.invalidate()


def no_network(test, public=True):
    """The Play listing check never touches the network in tests."""
    from django.core.cache import cache
    cache.delete("sitev3:play_public")
    p = mock.patch("web.site_v3_dist.fetch_play_status", return_value=public)
    test.play_check = p.start()
    test.addCleanup(p.stop)
    test.addCleanup(cache.delete, "sitev3:play_public")


class Base(TestCase):
    def setUp(self):
        FF.invalidate()
        no_network(self)
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

    def test_bn_site_shots_guarded_by_launch_bn_sweep(self):
        """sitelive: the bn sweep (app/test/launch_bn_sweep_test.dart) reads
        site_shot_sources.json; it must list exactly the site's shots, and a
        shot on the sweep's failure list must block the refresh."""
        import importlib.util
        root = Path(__file__).resolve().parents[2]
        src = json.loads((root / "backend" / "web" / "site_shot_sources.json").read_text())
        self.assertEqual(src["names"], V3.shot_names(),
                         "run: python tools/website/site_shots.py --sources")
        sweep = (root / "app" / "test" / "launch_bn_sweep_test.dart").read_text()
        self.assertIn("site_shot_sources.json", sweep)
        self.assertIn("launch_bn_sweep_failures.json", sweep)
        spec = importlib.util.spec_from_file_location("site_shots", root / "tools" / "website" / "site_shots.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        name = V3.shot_names()[0]
        self.assertEqual(mod.blocked(V3.shot_names(), {name: ['digit: "12:30"'], "not_on_site": ["x"]}), [name])
        self.assertEqual(mod.blocked(V3.shot_names(), {}), [])
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(mod.sweep_failures(d))           # no list = no proof
            self.assertEqual(mod.refresh(d), 1)
            for shard, fails in (("shots-0", {}), ("shots-1", {name: ['digit: "5"']})):
                Path(d, shard).mkdir()
                Path(d, shard, mod.FAILS).write_text(json.dumps({"failures": fails}))
            self.assertEqual(mod.refresh(d), 1)                  # a site shot failed in bn
            self.assertEqual(list(mod.sweep_failures(d)), [name])

    def test_bubbles_channels_brief_show_real_screenshots(self):
        shots = {f["id"]: f["shot"] for f in V3.FEATURES["ai"] + V3.FEATURES["circle"]}
        self.assertEqual(shots["brief"], "daily_brief")
        self.assertEqual(shots["bubbles"], "bbl2_install_day_on")
        self.assertEqual(shots["channels"], "chx_channel")
        set_flag("my_circle", True)
        set_flag("daily_brief", True)
        for lang in ("bn", "en"):
            html = self.c.get("/preview/features/circle?lang=%s" % lang).content.decode()
            for n in ("chx_channel",):
                self.assertIn("shots3/%s_%s_360.webp" % (n, lang), html)
            html = self.c.get("/preview/features/ai?lang=%s" % lang).content.decode()
            self.assertIn("shots3/daily_brief_%s_360.webp" % lang, html)

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

    def test_html_is_gzipped_when_accepted(self):
        import gzip
        plain = self.c.get("/preview/?lang=en")
        z = self.c.get("/preview/?lang=en", HTTP_ACCEPT_ENCODING="gzip, br")
        self.assertEqual(z["Content-Encoding"], "gzip")
        self.assertIn("Accept-Encoding", z["Vary"])
        self.assertEqual(gzip.decompress(z.content), plain.content)
        self.assertEqual(z["ETag"], plain["ETag"])

    def test_assets_are_hashed_and_immutable(self):
        html = self.c.get("/preview/?lang=en").content.decode()
        html = re.sub(r'<script type="application/ld\+json">.*?</script>', "", html, flags=re.S)
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


class NavigationAndPlayTests(Base):
    def test_play_buttons_open_our_details_page_with_placement_referrer(self):
        wf = (Path(__file__).resolve().parents[2] / ".github" / "workflows" / "android.yml").read_text()
        m = re.search(r"flutter create --project-name (\S+) --org (\S+)", wf)
        self.assertIsNotNone(m)
        application_id = "%s.%s" % (m.group(2), m.group(1))
        self.assertNotRegex(wf, r"applicationId\s*=?\s*['\"]")   # no override elsewhere
        from web import site_content as SC
        self.assertEqual(SC.PLAY_ID, application_id)
        html = self.c.get("/preview/?lang=en").content.decode()
        self.assertNotIn("/store/search", html)
        for place in ("hero", "chip_download", "sticky_bar", "footer"):
            self.assertIn("store/apps/details?id=%s&amp;hl=en&amp;referrer=utm_source%%3Dwebsite%%26utm_medium%%3D%s"
                          % (application_id, place), html, place)
        self.assertIn("intent://details?id=", html)          # Android rewrite
        self.assertIn("S.browser_fallback_url=", html)
        self.assertIn("package=com.android.vending", html)

    def test_chips_menu_bottom_bar_back_to_top(self):
        html = self.c.get("/preview/?lang=en").content.decode()
        chips = re.search(r'<nav class="chips".*?</nav>', html, re.S).group(0)
        labels = re.findall(r">([^<>]+)</a>", chips)
        self.assertEqual(labels, ["Home", "AI Assistant", "My Circle", "Safety", "CCTV", "Business", "Pricing", "Download"])
        for anchor in ("#hero", "#g-ai", "#g-circle", "#g-safety", "#g-cctv", "#g-business", "#pricing"):
            self.assertIn('href="%s"' % anchor, chips)
            self.assertIn('id="%s"' % anchor[1:], html)
        menu = re.search(r'<nav class="mm-p".*?</nav>', html, re.S).group(0)
        for g in V3.GROUP_IDS:
            self.assertIn("/preview/features/%s" % g, menu)
        for x in ("/preview/pricing", "/preview/security", "/preview/help", "?lang=bn", "details?id="):
            self.assertIn(x, menu)
        self.assertIn('class="pbar"', html)
        self.assertIn('class="totop" href="#top"', html)
        # on a group page the chips open pages and mark the current one
        g = self.c.get("/preview/features/cctv?lang=en").content.decode()
        chips = re.search(r'<nav class="chips".*?</nav>', g, re.S).group(0)
        self.assertIn('href="/preview/features/ai?lang=en"', chips)
        self.assertRegex(chips, r'href="/preview/features/cctv\?lang=en" class="on" aria-current="page"')

    def test_hero_plays_real_screens_in_the_chosen_language(self):
        for lang, other in (("bn", "en"), ("en", "bn")):
            html = self.c.get("/preview/?lang=%s" % lang).content.decode()
            hero = re.search(r'data-rot>.*?class="rot-btn"', html, re.S).group(0)
            for n in VS3.HERO_SLIDES:
                self.assertIn("shots3/%s_%s_360.webp" % (n, lang), hero)
                self.assertNotIn("shots3/%s_%s_" % (n, other), hero)
            self.assertIn('class="rot-btn"', hero)        # pause control (WCAG 2.2.2)


class HeroOrder3NovTests(Base):
    """owner HERO + FIXES 3 Nov 03:30: exact hero text, 9 real slides in order,
    the taka-sign font on every page, sticky Install bar after the hero."""

    def test_hero_text_exact(self):
        en = self.c.get("/preview/?lang=en").content.decode()
        h1 = re.sub(r"<[^>]+>", "", re.search(r'<h1 id="hero-h">(.*?)</h1>', en, re.S).group(1))
        self.assertEqual(" ".join(h1.split()),
                         "Assisto: Chat, calls, AI assistant, safety and business, in one super app.")
        self.assertIn('<p class="slogan">Many apps. One Assisto.</p>', en)
        self.assertIn("Chat and call your people, share live location and SOS with family, watch your CCTV, "
                      "run your shop&#x27;s accounts and invoices. Assisto&#x27;s AI reminds, alerts and keeps "
                      "your books in order.", en)
        self.assertIn("Does the work by itself", en)          # the chip above stays
        bn = self.c.get("/preview/?lang=bn").content.decode()
        h1 = re.sub(r"<[^>]+>", "", re.search(r'<h1 id="hero-h">(.*?)</h1>', bn, re.S).group(1)).strip()
        self.assertTrue(h1.startswith("Assisto: "), h1)
        self.assertIn("সুপার অ্যাপ", h1)
        self.assertIn('<p class="slogan">অনেক অ্যাপ নয়, একটাই Assisto।</p>', bn)

    def test_hero_slides_owner_order(self):
        self.assertEqual([n for n, _ in V3.HERO_SLIDES],
                         ["c3_chat", "callpip_pip_window", "gj_live_banner", "emergency_hub", "wm_alerts",
                          "acct_home", "inv_paper_80", "chat", "dest_alarm"])
        for lang in ("bn", "en"):
            html = self.c.get("/preview/?lang=%s" % lang).content.decode()
            hero = re.search(r'data-rot>.*?class="rot-btn"', html, re.S).group(0)
            pos = [hero.find("shots3/%s_%s_360.webp" % (n, lang)) for n, _ in V3.HERO_SLIDES]
            self.assertNotIn(-1, pos)
            self.assertEqual(pos, sorted(pos))
            self.assertEqual(hero.count('fetchpriority="high"'), 1)   # only slide 1 loads eagerly
        for n, _ in V3.HERO_SLIDES:
            self.assertIn(n, V3.shot_names())

    def test_taka_font_on_every_page(self):
        self.assertTrue((ASSETS / "taka.woff2").is_file())
        self.assertIn("SIL Open Font License", (ASSETS / "OFL-HindSiliguri.txt").read_text())
        for path in PREVIEW_PAGES + ["/", "/pricing?lang=en", "/delete-account", "/privacy"]:
            html = self.c.get(path).content.decode()
            self.assertRegex(html, r'font-family:"Taka3"[^}]*taka\.woff2[^}]*unicode-range:U\+09F3', path)
            self.assertRegex(html, r'--font:"Taka3",', path)

    def test_sticky_bar_waits_for_hero_install(self):
        html = self.c.get("/preview/?lang=bn").content.decode()
        self.assertIn('.js .pbar:not(.show){transform:translateY(110%);visibility:hidden}', html)
        self.assertIn('document.querySelector("#hero .install")', html)
        self.assertRegex(html, r"prefers-reduced-motion:reduce\)\{\.pbar,")
        self.assertIn('class="btn install"', re.search(r'id="hero".*?</section>', html, re.S).group(0))


class InstallAndApkTests(Base):
    def _apk(self, tmp):
        import hashlib
        import os
        p = os.path.join(tmp, "assisto-part7-build321.apk")
        with open(p, "wb") as f:
            f.write(b"PK\x03\x04 fake apk bytes for the website test" * 1000)
        return p, hashlib.sha256(open(p, "rb").read()).hexdigest()

    def test_not_public_says_coming_soon_and_offers_the_apk(self):
        import tempfile
        from django.core.cache import cache
        from django.test import override_settings
        cache.delete("sitev3:play_public")
        self.play_check.return_value = False
        with tempfile.TemporaryDirectory() as tmp:
            p, sha = self._apk(tmp)
            with override_settings(WEBSITE_APK_FILE=p, WEBSITE_APK_URL=""):
                html = self.c.get("/preview/?lang=en").content.decode()
                self.assertIn("Coming soon to Play Store", html)
                self.assertNotIn('class="badge"', html)            # no Play badge until public
                self.assertIn('class="btn install" href="/download/apk"', html)
                self.assertIn("Download APK directly", html)
                self.assertIn(sha, html)                             # full SHA-256 in the download section
                self.assertIn(sha[:12], html)
                self.assertIn("1.0.321", html)
                r = self.c.get("/download/apk")
                self.assertEqual(r.status_code, 200)
                self.assertEqual(r["Content-Type"], "application/vnd.android.package-archive")
                import hashlib
                self.assertEqual(hashlib.sha256(b"".join(r.streaming_content)).hexdigest(), sha)
                bn = self.c.get("/preview/?lang=bn").content.decode()
                self.assertIn("শীঘ্রই Play Store-এ আসছে", bn)
                self.assertIn("১.০.৩২১", bn)                       # Bangla digits

    def test_public_listing_shows_badge_and_install_to_play(self):
        html = self.c.get("/preview/?lang=en").content.decode()
        self.assertNotIn("Coming soon to Play Store", html)
        hero = re.search(r'<div class="get get-hero">.*?</div>', html, re.S).group(0)
        self.assertIn('class="badge"', hero)
        self.assertIn("Install now", hero)
        self.assertEqual(hero.count("utm_medium%3Dhero"), 2)       # badge + Install, same Play page
        self.assertEqual(self.c.get("/download/apk").status_code, 404)   # no owner APK set

    def test_play_check_is_cached_and_owner_can_override(self):
        from web import site_v3_dist as DIST
        self.c.get("/preview/")
        self.c.get("/preview/?lang=bn")
        self.assertEqual(self.play_check.call_count, 1)             # cached ~1 h
        row, _ = AdminFlagState.objects.get_or_create(key="global")
        row.state = dict(row.state or {}, website_play_auto=False, website_play_public=False)
        row.save()
        self.assertFalse(DIST.play_public())
        self.assertIn("Coming soon to Play Store", self.c.get("/preview/?lang=en").content.decode())

    def test_screenshots_never_cropped_by_css(self):
        css = (Path(__file__).resolve().parent / "templates" / "web" / "v3" / "_css.html").read_text()
        self.assertNotIn("object-fit:cover", css)
        html = self.c.get("/preview/features/business?lang=en").content.decode()
        self.assertIn("data-zoom", html)
        self.assertIn('<dialog class="zv" id="zv"', html)


class OwnerSwitchTests(OwnerBase):
    def setUp(self):
        super().setUp()
        no_network(self)
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

    def test_play_listing_override(self):
        from web import site_v3_dist as DIST
        self.assertEqual(DIST.play_mode(), "auto")
        self.assertEqual(self.post("/owner/website", {"action": "play_hidden"}).status_code, 302)
        self.assertEqual(DIST.play_mode(), "hidden")
        self.assertFalse(DIST.play_public())
        self.assertEqual(self.post("/owner/website", {"action": "play_public"}).status_code, 302)
        self.assertTrue(DIST.play_public())
        self.assertEqual(self.post("/owner/website", {"action": "play_auto"}).status_code, 302)
        self.assertEqual(DIST.play_mode(), "auto")

    def test_bad_action_refused(self):
        r = self.post("/owner/website", {"action": "explode"})
        self.assertEqual(r.status_code, 400)
        self.assertFalse(VS3.is_live())
