"""seo (owner order 17 Nov 00:14) — Search Console fix for lifeassisto.com.

Crawl every URL in /sitemap.xml like Googlebot (fresh client, no cookie):
200, exactly one SELF canonical, no noindex (meta or header), hreflang
bn/en/x-default pair. Private pages keep noindex and stay out of the sitemap.
Google verification tags stay. Web pages on api./track. hosts are noindex;
/api/, /dl/, /m/ never touched. /about is a real page in bn + en."""
import re
from pathlib import Path
from urllib.parse import urlsplit

from django.http import HttpResponse
from django.test import Client, RequestFactory, override_settings

from web import seo as S
from web.tests_site_v3 import Base, set_live

LOC = re.compile(r"<loc>([^<]+)</loc>")
VERIFY = '<meta name="google-site-verification" content="iw1F-H9KhnjCYuwZ5nA-cmDZbrrLRpu7scUk98S1OKQ" />'
REPO = Path(__file__).resolve().parents[2]


def _get(url):
    sp = urlsplit(url.replace("&amp;", "&"))
    return Client().get(sp.path + ("?" + sp.query if sp.query else ""))


class SitemapCrawlTests(Base):
    def setUp(self):
        super().setUp()
        set_live(True)

    def locs(self):
        r = Client().get("/sitemap.xml")
        self.assertEqual(r.status_code, 200)
        return r.content.decode(), LOC.findall(r.content.decode())

    def test_every_sitemap_url_is_indexable_with_self_canonical_and_hreflang(self):
        body, locs = self.locs()
        self.assertGreaterEqual(len(locs), 2 * len(S.PUBLIC_PATHS))
        for loc in locs:
            loc = loc.replace("&amp;", "&")
            r = _get(loc)
            self.assertEqual(r.status_code, 200, loc)
            html = r.content.decode()
            canon = re.findall(r'<link rel="canonical" href="([^"]+)"', html)
            self.assertEqual(canon, [loc], loc)
            self.assertNotIn("noindex", r.get("X-Robots-Tag", ""), loc)
            for m in re.findall(r'<meta name="robots" content="([^"]+)"', html):
                self.assertNotIn("noindex", m, loc)
            bn = loc.split("?")[0]
            self.assertIn('hreflang="bn" href="%s"' % bn, html, loc)
            self.assertIn('hreflang="en" href="%s?lang=en"' % bn, html, loc)
            self.assertIn('hreflang="x-default" href="%s"' % bn, html, loc)
            self.assertIn('<html lang="%s"' % ("en" if loc.endswith("lang=en") else "bn"), html, loc)

    def test_sitemap_has_every_public_page_in_both_languages_with_x_default(self):
        body, locs = self.locs()
        site = S.site()
        for p in S.PUBLIC_PATHS + ["/features/%s" % g for g in ("ai", "circle", "safety")]:
            self.assertIn(site + p, locs, p)
            self.assertIn(site + p + "?lang=en", locs, p)
        self.assertIn('hreflang="x-default"', body)
        self.assertEqual(len(locs), len(set(locs)))

    def test_sitemap_excludes_private_pages(self):
        _, locs = self.locs()
        for loc in locs:
            path = urlsplit(loc).path
            self.assertFalse(path.startswith(S.PRIVATE_PREFIXES), loc)
            self.assertTrue(loc.startswith(S.site() + "/"), loc)


class PrivatePagesTests(Base):
    def test_private_pages_keep_noindex(self):
        for path in ("/preview/", "/preview/pricing", "/preview/privacy", "/premium"):
            r = Client().get(path)
            if r.status_code != 200:
                continue
            html = r.content.decode()
            self.assertTrue("noindex" in r.get("X-Robots-Tag", "") or
                            re.search(r'<meta name="robots" content="[^"]*noindex', html), path)

    def test_owner_login_noindex_and_robots_txt(self):
        r = Client().get("/owner/login")
        if r.status_code == 200:
            self.assertIn("noindex", r.content.decode())
        rb = Client().get("/robots.txt").content.decode()
        self.assertIn("Disallow: /owner/", rb)
        self.assertIn("Sitemap: %s/sitemap.xml" % S.site(), rb)
        self.assertNotIn("Disallow: /\n", rb)

    def test_share_result_pages_are_noindex(self):
        from django.template import Context, Template
        req = RequestFactory().get("/cv/r")
        out = Template("{% load site %}{% auto_seo %}").render(Context({"request": req}))
        self.assertIn("noindex", out)


class VerificationTests(Base):
    def test_google_verification_tags_and_file_untouched(self):
        set_live(True)
        self.assertIn(VERIFY, Client().get("/").content.decode())        # v3 base
        self.assertIn(VERIFY, Client().get("/cv").content.decode())      # classic base
        self.assertTrue((REPO / "googlece9fd85bfb550cfb.html").is_file())

    def test_meta_domain_verification_in_server_html(self):
        # owner 17 Nov: Meta Business domain verification, server-rendered in
        # <head> (not injected by JS) and kept permanently
        set_live(True)
        tag = '<meta name="facebook-domain-verification" content="655cdrm8fbyj23oulqpx16ku6njzbi" />'
        for path in ("/", "/cv", "/about"):
            html = Client().get(path).content.decode()
            self.assertIn(tag, html.split("</head>")[0], path)


class LegalNameTests(Base):
    def test_licensed_name_and_address_everywhere(self):
        # owner 17 Nov (trade licence): exact legal name + address; the old
        # name/address must appear nowhere on the public pages
        set_live(True)
        for path in ("/", "/about", "/privacy", "/terms", "/delete-account", "/cv"):
            r = Client().get(path)
            if r.status_code != 200:
                continue
            html = r.content.decode()
            self.assertNotIn("AXON Dynamic", html, path)
            self.assertNotIn("Cha-63 Uttar", html, path)
            self.assertNotIn("Cha-63, Uttar", html, path)
        about = Client().get("/about").content.decode()
        self.assertIn("Axon Dynamics", about)
        self.assertIn("Cha-63/3, Uttar Badda, Badda, Dhaka 1212, Bangladesh", Client().get("/").content.decode())


class LicensedFactsTests(Base):
    def test_old_env_override_cannot_bring_back_old_name(self):
        import os
        from unittest import mock
        from web import legal_content as L
        with mock.patch.dict(os.environ, {"LEGAL_ENTITY_NAME": "AXON Dynamic",
                                          "LEGAL_ADDRESS": "Cha-63, Uttar Badda, Dhaka 1212, Bangladesh"}):
            self.assertEqual(L._fact("LEGAL_ENTITY_NAME", "en"), "Axon Dynamics")
            self.assertEqual(L._fact("LEGAL_ADDRESS", "bn"), "Cha-63/3, Uttar Badda, Badda, Dhaka 1212, Bangladesh")
            set_live(True)
            for path in ("/privacy", "/terms", "/delete-account"):
                html = Client().get(path).content.decode()
                self.assertNotIn("AXON Dynamic", html, path)
                self.assertNotIn("Cha-63, Uttar", html, path)


class AboutPageTests(Base):
    def test_about_bn_and_en(self):
        set_live(True)
        for q, h1, lang in (("", "Assisto সম্পর্কে", "bn"), ("?lang=en", "About Assisto", "en")):
            r = Client().get("/about" + q)
            self.assertEqual(r.status_code, 200)
            html = r.content.decode()
            self.assertIn(h1, html)
            self.assertIn('<html lang="%s"' % lang, html)
            self.assertIn("Axon Dynamics", html)
            self.assertNotIn("noindex", html)
        self.assertIn('href="/about"', Client().get("/").content.decode())   # footer link

    def test_about_works_with_classic_switch_too(self):
        set_live(False)
        self.assertEqual(Client().get("/about").status_code, 200)


def _ok(request):
    return HttpResponse("ok")


@override_settings(WEB_PUBLIC_SITE="https://lifeassisto.com")
class DuplicateHostTests(Base):
    def run_mw(self, host, path):
        req = RequestFactory().get(path, HTTP_HOST=host)
        return S.DuplicateHostNoindexMiddleware(_ok)(req)

    def test_api_and_track_web_pages_are_noindex(self):
        for host in ("api.lifeassisto.com", "track.lifeassisto.com", "api.lifeassisto.com:443"):
            for path in ("/", "/pricing", "/privacy", "/features/ai"):
                self.assertEqual(self.run_mw(host, path).get("X-Robots-Tag"), "noindex, nofollow", host + path)

    def test_app_paths_and_canonical_host_untouched(self):
        for host in ("api.lifeassisto.com", "track.lifeassisto.com"):
            for path in ("/api/v1/me", "/dl/assisto.apk", "/m/abc", "/.well-known/assetlinks.json"):
                self.assertIsNone(self.run_mw(host, path).get("X-Robots-Tag"), host + path)
        for host in ("lifeassisto.com", "testserver", "localhost", "127.0.0.1:8700"):
            self.assertIsNone(self.run_mw(host, "/").get("X-Robots-Tag"), host)

    @override_settings(ALLOWED_HOSTS=["*"])
    def test_full_stack_on_api_host(self):
        set_live(True)
        r = Client().get("/", HTTP_HOST="api.lifeassisto.com")
        self.assertEqual(r.get("X-Robots-Tag"), "noindex, nofollow")
        r = Client().get("/", HTTP_HOST="lifeassisto.com")
        self.assertNotIn("noindex", r.get("X-Robots-Tag", ""))
