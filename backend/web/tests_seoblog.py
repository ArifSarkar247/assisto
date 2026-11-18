"""seoblog — website blog (owner order 17 Nov 00:32, item 6): model + Owner
Admin editor, list/article pages (Article JSON-LD, self canonical, hreflang),
sitemap only when published, the 10 seed articles (unpublished, honest)."""
import io
import json
import re
import sys
import types
from unittest import mock

from django.core.management import call_command
from django.test import Client, TestCase, override_settings
from django.utils import timezone

from core.models import BlogPost, OwnerAudit
from web import blog as B
from web import blog_seed
from web.tests_o2_owner_admin import OwnerBase
from core.testing_tmp import TempDirMixin  # a temp dir per class, never at import

SITE = "https://lifeassisto.com"


def _png():
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (120, 63), (40, 80, 200)).save(buf, "PNG")
    buf.seek(0)
    buf.name = "cover.png"
    return buf


def _jsonld(html):
    m = re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
    return json.loads(m.group(1))


def _publish(slug):
    p = BlogPost.objects.get(slug=slug)
    p.published = True
    p.published_at = timezone.now()
    p.save()
    return p


class SeedTests(TestCase):
    def test_seed_loads_ten_unpublished_and_never_overwrites(self):
        out = io.StringIO()
        call_command("seed_blog", stdout=out)
        self.assertIn("created 10", out.getvalue())
        self.assertEqual(BlogPost.objects.count(), 10)
        self.assertFalse(BlogPost.objects.filter(published=True).exists())
        p = BlogPost.objects.first()
        p.title_bn = "মালিকের সম্পাদনা"
        p.save()
        out = io.StringIO()
        call_command("seed_blog", stdout=out)
        self.assertIn("created 0, skipped 10", out.getvalue())
        p.refresh_from_db()
        self.assertEqual(p.title_bn, "মালিকের সম্পাদনা")

    def test_every_seed_article_is_complete_honest_and_links_one_feature(self):
        slugs, features = set(), []
        for a in blog_seed.ARTICLES:
            self.assertRegex(a["slug"], B.SLUG_RE)
            self.assertNotIn(a["slug"], slugs)
            slugs.add(a["slug"])
            self.assertIn(a["feature"], B.FEATURES)
            features.append(a["feature"])
            for f in ("title_bn", "title_en", "summary_bn", "summary_en", "body_bn", "body_en"):
                self.assertTrue(a[f].strip(), (a["slug"], f))
            self.assertLessEqual(len(a["summary_bn"]), 200)
            self.assertLessEqual(len(a["summary_en"]), 200)
            self.assertLessEqual(len(a["title_en"]), 120)
            self.assertRegex(a["body_bn"], "[ঀ-৿]")          # real Bangla
            for lang in ("bn", "en"):
                body = a["body_" + lang]
                self.assertNotIn("<", body.replace("<\\/", ""))           # Markdown only, no raw HTML
                html, heads = B.render_markdown(body)
                self.assertGreaterEqual(len(heads), 3)
                low = body.lower()
                # no fake social proof / superlative claims
                for bad in ("lakh users", "million users", "লাখ ব্যবহারকারী", "#1 app", "এক নম্বর অ্যাপ", "5-star", "৫ তারকা"):
                    self.assertNotIn(bad, low)
        self.assertEqual(len(slugs), 10)
        self.assertEqual(len(set(features)), 10)   # one article per feature page, no cannibalisation

    def test_quran_article_points_to_licensed_sources_and_no_ai_translation(self):
        a = [x for x in blog_seed.ARTICLES if x["feature"] == "quran"][0]
        self.assertIn("Tanzil", a["body_en"])
        self.assertIn("Islamic Foundation", a["body_en"])
        self.assertNotRegex(a["body_bn"], "[؀-ۿ]")            # no Arabic verse text in the article
        self.assertNotRegex(a["body_en"], "[؀-ۿ]")


class MarkdownTests(TestCase):
    def test_raw_html_and_bad_links_are_neutralised(self):
        html, _ = B.render_markdown("## Hi\n<script>alert(1)</script>\n[x](javascript:alert(1)) [ok](/blog) [ext](https://quran.com)")
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertNotIn("javascript:", html.replace("&lt;", ""))
        self.assertIn('<a href="/blog">ok</a>', html)
        self.assertIn('href="https://quran.com" rel="noopener"', html)

    def test_lists_tables_notes_headings(self):
        md = "## A\n- one\n- **two**\n\n1. x\n2. y\n\n> note\n\n| h1 | h2 |\n|---|---|\n| a | b |\n\n### small"
        html, heads = B.render_markdown(md)
        self.assertEqual(heads, [("s1", "A")])
        self.assertIn("<ul><li>one</li><li><strong>two</strong></li></ul>", html)
        self.assertIn("<ol><li>x</li><li>y</li></ol>", html)
        self.assertIn('<aside class="note">', html)
        self.assertIn('<th scope="col">h1</th>', html)
        self.assertNotIn("---", html)
        self.assertIn("<h3>small</h3>", html)


class PublicTests(TestCase):
    def setUp(self):
        blog_seed.load()
        self.slug = blog_seed.ARTICLES[0]["slug"]

    def test_unpublished_is_404_and_not_in_sitemap_or_list(self):
        self.assertEqual(Client().get("/blog/%s" % self.slug).status_code, 404)
        r = Client().get("/blog")
        self.assertEqual(r.status_code, 200)
        self.assertNotContains(r, self.slug)
        sm = Client().get("/sitemap.xml").content.decode()
        self.assertNotIn("/blog", sm)

    def test_empty_list_is_noindex_until_a_post_is_published(self):
        r = Client().get("/blog")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["X-Robots-Tag"], "noindex")
        self.assertContains(r, '<meta name="robots" content="noindex, follow">')
        _publish(self.slug)
        r = Client().get("/blog")
        self.assertFalse(r.has_header("X-Robots-Tag"))
        self.assertContains(r, 'content="index, follow')

    def test_published_article_seo_bn_and_en(self):
        _publish(self.slug)
        r = Client().get("/blog/%s" % self.slug)
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        url = SITE + "/blog/" + self.slug
        self.assertIn('<html lang="bn">', html)
        self.assertIn('<link rel="canonical" href="%s">' % url, html)
        self.assertIn('hreflang="en" href="%s?lang=en"' % url, html)
        self.assertIn('hreflang="x-default" href="%s"' % url, html)
        self.assertEqual(html.count("<h1"), 1)
        self.assertIn('content="index, follow', html)
        ld = _jsonld(html)
        types_ = [g["@type"] for g in ld["@graph"]]
        self.assertEqual(types_, ["Article", "BreadcrumbList"])
        art = ld["@graph"][0]
        self.assertEqual(art["inLanguage"], "bn")
        self.assertEqual(art["mainEntityOfPage"]["@id"], url)
        self.assertEqual(art["dateModified"], blog_seed.REVIEWED)
        self.assertEqual(art["publisher"]["name"], "Axon Dynamics")
        en = Client().get("/blog/%s?lang=en" % self.slug).content.decode()
        self.assertIn('<html lang="en">', en)
        self.assertIn('<link rel="canonical" href="%s?lang=en">' % url, en)
        self.assertIn(blog_seed.ARTICLES[0]["title_en"], en)
        self.assertEqual(_jsonld(en)["@graph"][0]["inLanguage"], "en")

    def test_published_list_and_sitemap(self):
        _publish(self.slug)
        r = Client().get("/blog?lang=en")
        self.assertContains(r, "/blog/%s?lang=en" % self.slug)
        ld = _jsonld(r.content.decode())
        self.assertEqual(ld["@graph"][0]["@type"], "Blog")
        sm = Client().get("/sitemap.xml").content.decode()
        self.assertIn("<loc>%s/blog</loc>" % SITE, sm)
        self.assertIn("<loc>%s/blog/%s</loc>" % (SITE, self.slug), sm)
        other = blog_seed.ARTICLES[1]["slug"]
        self.assertNotIn(other, sm)

    def test_incomplete_post_never_public_even_if_flag_set(self):
        BlogPost.objects.create(slug="half", title_bn="অর্ধেক", body_bn="লেখা", published=True)
        self.assertEqual(Client().get("/blog/half").status_code, 404)
        self.assertNotIn("half", Client().get("/sitemap.xml").content.decode())

    def test_feature_cta_follows_landing_helper(self):
        _publish(self.slug)
        fake = types.ModuleType("web.site_landing")
        fake.url_for = lambda key, lang: "/features/%s%s" % (key, "?lang=en" if lang == "en" else "")
        with mock.patch.dict(sys.modules, {"web.site_landing": fake}):
            self.assertContains(Client().get("/blog/%s" % self.slug), 'href="/features/mess"')
        fake.url_for = lambda key, lang: None          # feature switched off -> no dead link
        with mock.patch.dict(sys.modules, {"web.site_landing": fake}):
            self.assertNotContains(Client().get("/blog/%s" % self.slug), 'class="cta"')

    def test_cover_404_without_cover(self):
        _publish(self.slug)
        self.assertEqual(Client().get("/blog/%s/cover" % self.slug).status_code, 404)


class OwnerBlogTests(TempDirMixin, OwnerBase):

    def setUp(self):
        super().setUp()
        self.ready()

    def _form(self, **kw):
        d = {"slug": "test-post", "title_bn": "পরীক্ষা", "title_en": "Test", "summary_bn": "সারাংশ",
             "summary_en": "Summary", "body_bn": "## ক\nলেখা", "body_en": "## A\nText", "feature": "mess",
             "keywords": "k", "last_reviewed": "2026-11-17", "order": "5"}
        d.update(kw)
        return d

    def test_list_empty_state_and_nav(self):
        r = self.c.get("/owner/blog?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "seed_blog")
        self.assertContains(r, 'href="/owner/blog"')

    def test_create_edit_publish_cover_delete_audited(self):
        r = self.post("/owner/blog/new", self._form())
        self.assertEqual(r.status_code, 302)
        p = BlogPost.objects.get(slug="test-post")
        self.assertFalse(p.published)
        self.assertEqual(str(p.last_reviewed), "2026-11-17")
        # edit + cover upload
        r = self.post("/owner/blog/%d" % p.pk, dict(self._form(title_en="Test 2"), cover=_png()))
        self.assertEqual(r.status_code, 302)
        p.refresh_from_db()
        self.assertEqual(p.title_en, "Test 2")
        self.assertTrue(p.cover)
        # publish (one tap)
        self.post("/owner/blog/%d/toggle" % p.pk)
        p.refresh_from_db()
        self.assertTrue(p.published)
        self.assertIsNotNone(p.published_at)
        r = Client().get("/blog/test-post/cover")
        self.assertEqual(r.status_code, 302)
        self.assertIn("/api/v1/m/", r["Location"])
        self.assertContains(Client().get("/blog/test-post"), 'src="/blog/test-post/cover"')
        # delete needs the confirm tick
        self.post("/owner/blog/%d/delete" % p.pk)
        self.assertTrue(BlogPost.objects.filter(pk=p.pk).exists())
        self.post("/owner/blog/%d/delete" % p.pk, {"confirm": "on"})
        self.assertFalse(BlogPost.objects.filter(pk=p.pk).exists())
        acts = set(OwnerAudit.objects.values_list("action", flat=True))
        self.assertTrue({"blog.create", "blog.update", "blog.publish", "blog.delete"} <= acts)

    def test_validation(self):
        r = self.post("/owner/blog/new", self._form(slug="Bad Slug"))
        self.assertEqual(r.status_code, 400)
        r = self.post("/owner/blog/new", self._form(published="on", body_en=""))
        self.assertEqual(r.status_code, 400)
        self.assertFalse(BlogPost.objects.exists())
        r = self.post("/owner/blog/new", self._form(feature="nope"))
        self.assertEqual(r.status_code, 400)
        bad = io.BytesIO(b"not an image")
        bad.name = "x.png"
        r = self.post("/owner/blog/new", dict(self._form(), cover=bad))
        self.assertEqual(r.status_code, 400)   # text saved as a draft; the bad file is reported
        p = BlogPost.objects.get(slug="test-post")
        self.assertFalse(p.cover)

    def test_toggle_refuses_incomplete(self):
        p = BlogPost.objects.create(slug="half", title_bn="অর্ধেক")
        r = self.post("/owner/blog/%d/toggle" % p.pk)
        self.assertEqual(r.status_code, 302)
        p.refresh_from_db()
        self.assertFalse(p.published)
