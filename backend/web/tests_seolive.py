"""seolive (owner orders 17 Nov: SEO live + Assisto live on Google Play):
the site_go_live command, honest landing copy vs the live feature switches,
the Play URL in JSON-LD, sitemap lastmod and the published blog set.
"""
import hashlib
import io
import json
import re
from unittest import mock

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import Client

from core.models import AdminFlagState, BlogPost
from web import blog_seed
from web import site_landing as LP
from web import site_v3_dist as DIST
from web.management.commands import site_go_live as GL
from web.tests_site_v3 import Base, set_flag, set_live

PLAY = "https://play.google.com/store/apps/details?id=com.assisto.assisto"


def set_state(**kw):
    row, _ = AdminFlagState.objects.get_or_create(key="global")
    row.state = dict(row.state or {}, **kw)
    row.save()


def run(*args):
    out = io.StringIO()
    call_command("site_go_live", *args, stdout=out)
    return out.getvalue()


def main_part(html):
    """The landing copy (before the site-wide download CTA)."""
    return html.split('<main id="main">', 1)[1].split('id="download"', 1)[0]


def app_node(html):
    for raw in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        for node in json.loads(raw).get("@graph", []):
            if node.get("@type") == "SoftwareApplication":
                return node
    return None


class GoLiveBase(Base):
    def setUp(self):
        super().setUp()
        # the real state before go-live: pages in preview, Play badge hidden
        set_state(site_seo_growth_preview=True, site_play_badge_hidden=True)
        set_live(True)


class CommandTests(GoLiveBase):
    def test_needs_a_mode(self):
        with self.assertRaises(CommandError):
            call_command("site_go_live", stdout=io.StringIO())

    def test_dry_run_writes_nothing(self):
        out = run("--dry-run")
        self.assertIn("CHANGE  feature landing pages live", out)
        self.assertIn("CHANGE  Google Play badge + links shown", out)
        for slug in GL.PASSING:
            self.assertIn("blog %s: publish" % slug, out)
        self.assertIn("nothing written", out)
        self.assertFalse(LP.growth_live())
        self.assertFalse(DIST.play_badge_on())
        self.assertEqual(BlogPost.objects.count(), 0)

    def test_apply_flips_publishes_passing_only_and_is_idempotent(self):
        out = run("--apply")
        self.assertTrue(LP.growth_live())
        self.assertTrue(DIST.play_badge_on())
        self.assertEqual(sorted(BlogPost.objects.filter(published=True).values_list("slug", flat=True)),
                         sorted(GL.PASSING))
        for slug in GL.KEPT_DRAFT:
            self.assertFalse(BlogPost.objects.get(slug=slug).published, slug)
            self.assertIn("blog %s: kept draft" % slug, out)
        self.assertTrue(all(p.published_at for p in BlogPost.objects.filter(published=True)))
        # audited through the same flag engine as Owner Admin
        audit = AdminFlagState.objects.get(key="global").audit
        self.assertEqual({a["flag"] for a in audit[:2]}, {LP.PREVIEW_FLAG, DIST.PLAY_BADGE_HIDDEN_FLAG})
        again = run("--apply")
        self.assertIn("0 change(s)", again)
        self.assertNotIn("CHANGE", again)

    def test_every_seed_slug_is_either_passing_or_kept_draft(self):
        self.assertEqual(sorted(GL.PASSING + GL.KEPT_DRAFT), sorted(a["slug"] for a in blog_seed.ARTICLES))

    def test_stale_seed_text_is_refreshed_owner_edit_is_kept(self):
        blog_seed.load()
        fam = BlogPost.objects.get(slug="family-location-sharing-safely")
        fam.body_en = "old superseded seed text\n"
        fam.save()
        mess = BlogPost.objects.get(slug="mess-bazar-meal-hisab")
        mess.body_en = mess.body_en + "\nAn owner note.\n"
        mess.save()
        stale = {"family-location-sharing-safely": {"en": hashlib.sha256(b"old superseded seed text\n").hexdigest()[:16]}}
        with mock.patch.dict(GL.STALE, stale, clear=True):
            out = run("--apply")
        self.assertIn("blog family-location-sharing-safely: refresh superseded seed text (en)", out)
        seed = {a["slug"]: a for a in blog_seed.ARTICLES}
        fam.refresh_from_db()
        self.assertEqual(fam.body_en, seed["family-location-sharing-safely"]["body_en"].strip() + "\n")
        self.assertTrue(fam.published)
        mess.refresh_from_db()
        self.assertIn("An owner note.", mess.body_en)
        self.assertTrue(mess.published)

    def test_stale_hashes_never_match_the_current_text(self):
        seed = {a["slug"]: a for a in blog_seed.ARTICLES}
        for slug, langs in GL.STALE.items():
            for lang, h in langs.items():
                self.assertNotEqual(GL._h(seed[slug]["body_" + lang].strip() + "\n"), h, (slug, lang))


class HonestCopyTests(GoLiveBase):
    """Pages advertise only what the app does today (FEATURE_SWITCHES_BN.md)."""

    def test_blood_donor_page_follows_the_real_panel_switch(self):
        set_state(site_seo_growth_preview=False)
        set_flag("blood_donor", True)       # old alias route only
        set_flag("blood_donors", False)     # the real panel, OFF live
        self.assertEqual(self.c.get("/features/blood-donor").status_code, 404)
        self.assertNotIn("/features/blood-donor", self.c.get("/sitemap.xml").content.decode())
        set_flag("blood_donors", True)
        self.assertEqual(self.c.get("/features/blood-donor?lang=en").status_code, 200)

    def test_quran_page_404_while_off(self):
        set_flag("quran", False)
        self.assertEqual(self.c.get("/features/quran").status_code, 404)

    def test_language_partner_claims_only_the_live_trainer(self):
        set_flag("language_partner", True)
        set_flag("language_packs", False)
        for lang in ("bn", "en"):
            html = main_part(self.c.get("/features/language-partner?lang=" + lang).content.decode())
            for w in ("quiz", "Quiz", "কুইজ", "IELTS"):
                self.assertNotIn(w, html, (lang, w))
        self.assertIn("Leitner", html)

    def test_business_page_hides_full_accounts_while_off(self):
        set_flag("accounting_v2", False)
        html = main_part(self.c.get("/features/business-khata?lang=en").content.decode())
        self.assertNotIn("balance sheet", html)
        self.assertNotIn("acct_home_en", html)
        self.assertNotIn("reminds the customer by itself", html)
        self.assertIn("Sales and profit reports", html)
        set_flag("accounting_v2", True)
        self.assertIn("balance sheet", self.c.get("/features/business-khata?lang=en").content.decode())

    def test_passing_articles_claim_no_off_feature(self):
        seed = {a["slug"]: a for a in blog_seed.ARTICLES}
        for slug in GL.PASSING:
            text = (seed[slug]["body_bn"] + seed[slug]["body_en"]).lower()
            for w in ("quiz", "কুইজ", "switched on", "mark places", "চিহ্নিত করে রাখুন"):
                self.assertNotIn(w, text, (slug, w))


class PlayAndSitemapTests(GoLiveBase):
    def test_play_url_in_jsonld_only_once_live(self):
        set_state(site_seo_growth_preview=False)
        html = self.c.get("/features/family-care?lang=en").content.decode()
        app = app_node(html)
        self.assertNotIn("sameAs", app)
        self.assertNotIn("play.google.com", app["installUrl"])
        run("--apply")
        for path in ("/?lang=en", "/features/family-care?lang=en", "/features/cctv-app"):
            app = app_node(Client().get(path).content.decode())
            self.assertEqual(app["sameAs"], [PLAY], path)
            self.assertEqual(app["downloadUrl"], PLAY, path)
            self.assertTrue(app["installUrl"].startswith(PLAY), path)
            self.assertNotIn("aggregateRating", app)

    def test_play_badge_on_blog_once_live(self):
        run("--apply")
        html = Client().get("/blog/safe-journey-night-travel-tips?lang=en").content.decode()
        self.assertIn(PLAY, html)
        self.assertIn("google-play-badge-en", html)

    def test_sitemap_every_public_page_with_lastmod(self):
        run("--apply")
        xml = self.c.get("/sitemap.xml").content.decode()
        urls = re.findall(r"<url>(.*?)</url>", xml, re.S)
        self.assertTrue(urls)
        for u in urls:
            self.assertRegex(u, r"<lastmod>\d{4}-\d{2}-\d{2}</lastmod>")
            self.assertEqual(u.count('hreflang="'), 3, u)
        for slug in LP.live_slugs():
            self.assertIn("/features/%s</loc>" % slug, xml)
            self.assertIn("/features/%s?lang=en</loc>" % slug, xml)
        for slug in GL.PASSING:
            self.assertIn("/blog/%s</loc>" % slug, xml)
        for slug in GL.KEPT_DRAFT:
            self.assertNotIn(slug, xml)
        self.assertIn("/blog</loc>", xml)
        self.assertIn("Sitemap: ", self.c.get("/robots.txt").content.decode())
        self.assertIn("/sitemap.xml", self.c.get("/robots.txt").content.decode())

    def test_live_landing_page_self_canonical_hreflang_indexable(self):
        run("--apply")
        for lang in ("bn", "en"):
            r = Client().get("/features/safe-journey?lang=" + lang)
            html = r.content.decode()
            self.assertNotIn("noindex", r.get("X-Robots-Tag", ""))
            self.assertNotIn('content="noindex', html)
            canon = re.search(r'<link rel="canonical" href="([^"]+)"', html).group(1)
            self.assertTrue(canon.endswith("/features/safe-journey" + ("?lang=en" if lang == "en" else "")), canon)
            for h in ("bn", "en", "x-default"):
                self.assertIn('hreflang="%s"' % h, html)
