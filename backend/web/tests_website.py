"""website (owner order 2 Nov): lifeassisto.com — every route answers, every
public page has a real title + the logo favicon set + an OG share image, no
surveillance wording, language memory, live pricing, app-ads.txt and the
delete-account page keep working."""
import json
import re
from html.parser import HTMLParser
from unittest import mock

from django.template.loader import render_to_string
from django.test import Client, RequestFactory, TestCase, override_settings

from web import site_content as SC
from web import views_site as VS

# Every pre-existing public URL must keep answering (status < 400).
OLD_ROUTES = ["/", "/get", "/khata-free", "/cv", "/scam", "/photo", "/festival",
              "/made30", "/privacy", "/terms", "/refund-policy", "/delete-account",
              "/sitemap.xml", "/robots.txt", "/premium", "/.well-known/assetlinks.json"]
NEW_ROUTES = ["/pricing", "/security", "/help", "/site.webmanifest", "/favicon.ico",
              "/apple-touch-icon.png", "/site/favicon.svg", "/site/og-bn.jpg",
              "/site/noto-sans-bengali-var.woff2", "/site/shots/home_v2_bn_300.avif"]
# Public HTML pages that must carry title + favicons + og:image.
HTML_PAGES = ["/", "/pricing", "/security", "/help", "/get", "/khata-free", "/cv",
              "/scam", "/photo", "/festival", "/made30", "/privacy", "/terms",
              "/refund-policy", "/delete-account"]
MARKETING = ["/", "/pricing", "/security", "/help"]
GENERIC_TITLES = {"assisto", "home", "untitled", ""}
SURVEILLANCE = re.compile(r"watching|i am watching|i'm watching|নজর রাখছি|আমি দেখছি|নজরে রাখছি", re.I)

PLANS = [
    {"id": "free", "name": "Free", "price": 0, "cur": "BDT", "period": "mo", "desc": "Start",
     "benefits": ["Safety free"], "ads": True},
    {"id": "business", "name": "Business", "price": 1234, "cur": "BDT", "period": "mo",
     "desc": "Shops", "benefits": ["CRM"], "ads": False},
    {"id": "annual", "name": "Annual", "price": 4490, "cur": "BDT", "period": "yr",
     "desc": "Year", "benefits": [], "ads": False},
]


def _title(html):
    m = re.search(r"<title>(.*?)</title>", html, re.S)
    return (m.group(1).strip() if m else "")


class _Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs, self.srcs = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "a" and a.get("href"):
            self.hrefs.append(a["href"])
        if tag in ("img", "source", "link") and (a.get("src") or a.get("href") or a.get("srcset")):
            self.srcs.append(a.get("src") or a.get("href") or a.get("srcset").split(" ")[0])


@mock.patch("core.plans.plans_public", return_value=PLANS)
class RoutesTests(TestCase):
    """Each request is a fresh visitor (no remembered-language cookie)."""

    class _Fresh:
        def get(self, url, *a, **k):
            return Client().get(url, *a, **k)

    def setUp(self):
        self.c = self._Fresh()

    def test_every_old_and_new_route_answers(self, _p):
        for url in OLD_ROUTES + NEW_ROUTES:
            for q in ("", "?lang=en"):
                r = self.c.get(url + q)
                self.assertLess(r.status_code, 400, url + q)

    def test_every_page_has_real_title_favicons_og_and_no_watching(self, _p):
        titles = {}
        for url in HTML_PAGES:
            for lang, q in (("bn", ""), ("en", "?lang=en")):
                r = self.c.get(url + q)
                self.assertEqual(r.status_code, 200, url + q)
                html = r.content.decode()
                t = _title(html)
                self.assertNotIn(t.lower(), GENERIC_TITLES, url + q)
                self.assertGreater(len(t), 10, url + q)
                self.assertIn("Assisto", t, url + q)
                self.assertNotRegex(t, SURVEILLANCE, url + q)
                self.assertIn('<html lang="%s">' % lang, html, url + q)
                for needle in ('rel="icon"', "favicon.svg", "favicon.ico", 'rel="apple-touch-icon"',
                               'property="og:image"', 'name="twitter:card"', 'name="theme-color"'):
                    self.assertIn(needle, html, "%s missing on %s" % (needle, url + q))
                self.assertNotIn("fonts.googleapis.com", html, url + q)   # self-hosted font
                if url in MARKETING:
                    titles[(url, lang)] = t
                    self.assertNotRegex(html, SURVEILLANCE, url + q)
        # unique per page and per language; Bangla title on Bangla pages
        self.assertEqual(len(set(titles.values())), len(titles))
        self.assertRegex(titles[("/", "bn")], "[ঀ-৿]")
        self.assertNotRegex(titles[("/", "en")], "[ঀ-৿]")

    def test_marketing_seo(self, _p):
        for url in MARKETING:
            html = self.c.get(url).content.decode()
            self.assertIn('<link rel="canonical" href="https://lifeassisto.com%s">' % url, html)
            self.assertIn('hreflang="en" href="https://lifeassisto.com%s?lang=en"' % url, html)
            self.assertIn('hreflang="x-default"', html)
            self.assertIn('name="description"', html)
            ld = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S).group(1))
            types = {g["@type"] for g in ld["@graph"]}
            self.assertTrue({"Organization", "SoftwareApplication"} <= types)
            self.assertNotIn("aggregateRating", json.dumps(ld))      # no invented rating
            self.assertNotIn("ratingValue", json.dumps(ld))
            en = self.c.get(url + "?lang=en").content.decode()
            self.assertIn('<link rel="canonical" href="https://lifeassisto.com%s?lang=en">' % url, en)

    def test_internal_links_and_assets_resolve(self, _p):
        for q in ("", "?lang=en"):
            p = _Links()
            p.feed(self.c.get("/" + q).content.decode())
            internal = {h.split("#")[0] for h in p.hrefs if h.startswith("/")}
            internal |= {s.split("#")[0] for s in p.srcs if s.startswith("/")}
            self.assertGreater(len(internal), 15)
            for h in sorted(internal):
                self.assertLess(self.c.get(h or "/").status_code, 400, h)
            play = [h for h in p.hrefs if "play.google.com" in h]
            self.assertTrue(play and all("id=com.assisto.assisto" in h for h in play))
            self.assertIn("mailto:assistoaiagent@gmail.com", p.hrefs)

    def test_only_the_company_email_is_published(self, _p):
        for url in MARKETING + ["/get"]:
            for q in ("", "?lang=en"):
                html = self.c.get(url + q).content.decode()
                emails = set(re.findall(r"[\w.+-]+@[\w-]+\.[\w.]+", html))
                self.assertLessEqual(emails, {"assistoaiagent@gmail.com"}, url + q)
                self.assertIn("AXON Dynamic", html)

    def test_claims_match_truth_list(self, _p):
        en = self.c.get("/security?lang=en").content.decode()
        self.assertIn("recoverable, not end-to-end", en)       # vault is never called E2E
        self.assertIn("Calls are encrypted", en)                # calls: "encrypted", not E2E
        home_en = self.c.get("/?lang=en").content.decode().lower()
        for banned in ("medicine", "doctor", "hey assisto", "wipe your phone", "reviews",
                       "million users", "downloads", "★"):
            self.assertNotIn(banned, home_en)
        home_bn = self.c.get("/").content.decode()
        for banned in ("ওষুধ", "ডাক্তার"):
            self.assertNotIn(banned, home_bn)
        self.assertIn("৯৯৯", home_bn)                            # not an emergency service

    def test_bangla_pages_have_no_english_phrases(self, _p):
        # launchsweep: Bangla copy says এন্ড-টু-এন্ড, never English words
        # mixed into a Bangla sentence (brand/tech names like SOS, AI are ok).
        for url in MARKETING:
            html = self.c.get(url).content.decode()
            body = re.sub(r"<(script|style)\b.*?</\1>|<[^>]+>", " ", html, flags=re.S)
            for banned in ("end-to-end", "End-to-end", "encrypted", "free forever"):
                self.assertNotIn(banned, body, url)


class PricingTests(TestCase):
    def test_prices_come_from_the_live_catalogue(self):
        with mock.patch("core.plans.plans_public", return_value=PLANS) as m:
            bn = self.client.get("/pricing").content.decode()
            en = self.client.get("/pricing?lang=en").content.decode()
        m.assert_any_call("bn")
        m.assert_any_call("en")
        self.assertIn("৳১,২৩৪", bn)
        self.assertIn("৳1,234", en)
        self.assertIn("৳4,490", en)          # yearly shown as a note
        self.assertIn("Google Play", en)

    def test_pricing_failure_never_breaks_the_page(self):
        with mock.patch("core.plans.plans_public", side_effect=RuntimeError("db down")):
            r = self.client.get("/?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, SC.COPY["en"]["pricing_empty"])

    def test_no_hard_coded_prices_in_templates_or_copy(self):
        import pathlib
        root = pathlib.Path(VS.__file__).parent
        texts = [(root / "site_content.py").read_text()]
        texts += [p.read_text() for p in (root / "templates/web").glob("site_*.html")]
        texts += [p.read_text() for p in (root / "templates/web").glob("_sec_*.html")]
        for t in texts:
            self.assertNotRegex(t, r"৳\s?[0-9০-৯]")


@mock.patch("core.plans.plans_public", return_value=PLANS)
class LanguageMemoryTests(TestCase):
    def test_choice_is_remembered(self, _p):
        c = Client()
        r = c.get("/?lang=en")
        self.assertEqual(r.cookies[VS.LANG_COOKIE].value, "en")
        r = c.get("/")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r["Location"], "/?lang=en")
        r = c.get("/pricing")
        self.assertEqual(r["Location"], "/pricing?lang=en")
        c.get("/?lang=bn")
        self.assertEqual(c.get("/").status_code, 200)

    def test_crawler_without_cookie_gets_bangla(self, _p):
        r = Client().get("/")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, '<html lang="bn">')
        self.assertIn("Cookie", r["Vary"])


class AssetTests(TestCase):
    def test_types_and_caching(self):
        r = self.client.get(VS.asset_url("favicon.svg"))
        self.assertEqual(r["Content-Type"], "image/svg+xml")
        self.assertIn("immutable", r["Cache-Control"])
        r = self.client.get("/site/shots/home_v2_en_600.webp")
        self.assertEqual(r["Content-Type"], "image/webp")
        self.assertNotIn("immutable", r["Cache-Control"])
        self.assertEqual(self.client.get("/favicon.ico")["Content-Type"], "image/x-icon")
        self.assertEqual(self.client.get("/site/noto-sans-bengali-var.woff2")["Content-Type"], "font/woff2")

    def test_no_path_escape(self):
        for bad in ("/site/../views.py", "/site/..%2fviews.py", "/site/views.py",
                    "/site/shots/../../settings.py", "/site/nope.png", "/site/a/b/c.png"):
            self.assertEqual(self.client.get(bad).status_code, 404, bad)

    def test_every_screenshot_referenced_exists(self):
        for lang in ("bn", "en"):
            for f in SC.features(lang):
                for n in filter(None, (f["shot"], f["shot2"])):
                    for w in (300, 600):
                        for ext in ("avif", "webp"):
                            self.assertTrue((VS.ASSET_DIR / "shots" / ("%s_%s_%d.%s" % (n, lang, w, ext))).is_file())

    def test_manifest(self):
        m = json.loads(self.client.get("/site.webmanifest").content)
        self.assertEqual(m["theme_color"], SC.THEME_COLOR)
        sizes = {i["sizes"] for i in m["icons"]}
        self.assertEqual(sizes, {"192x192", "512x512"})
        for i in m["icons"]:
            self.assertEqual(self.client.get(i["src"]).status_code, 200)
        self.assertEqual(self.client.get("/site.webmanifest")["Content-Type"], "application/manifest+json")


class LegalAndAdsTests(TestCase):
    def test_app_ads_txt_still_served_from_owner_admin_data(self):
        with mock.patch("core.integrations.get", return_value={"publisher_id": "pub-1234567890123456"}):
            r = self.client.get("/app-ads.txt")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "text/plain; charset=utf-8")
        self.assertIn("google.com, pub-1234567890123456, DIRECT, f08c47fec0942fa0", r.content.decode())
        with mock.patch("core.integrations.get", return_value={}), override_settings(ADMOB_PUBLISHER_ID=""):
            self.assertEqual(self.client.get("/app-ads.txt").status_code, 404)

    def test_delete_account_page_and_form(self):
        for q in ("", "?lang=en"):
            r = self.client.get("/delete-account" + q)
            self.assertEqual(r.status_code, 200)
            self.assertContains(r, 'action="/delete-account')
            self.assertContains(r, 'property="og:image"')
        r = self.client.post("/delete-account?lang=en", {"contact": ""})
        self.assertEqual(r.status_code, 400)

    def test_sitemap_and_robots(self):
        sm = self.client.get("/sitemap.xml").content.decode()
        for p in ("/pricing", "/security", "/help", "/khata-free", "/delete-account"):
            self.assertIn("https://lifeassisto.com%s</loc>" % p, sm)
        rb = self.client.get("/robots.txt").content.decode()
        self.assertIn("Sitemap: https://lifeassisto.com/sitemap.xml", rb)
        self.assertIn("Disallow: /owner/", rb)


class StandalonePagesTests(TestCase):
    """Pages that do not extend web/base.html still get the logo favicon set."""

    def _render(self, tpl, ctx):
        req = RequestFactory().get("/x")
        return render_to_string(tpl, ctx, request=req)

    def test_safe_journey_vehicle_and_phone_pages(self):
        for tpl, ctx in (("web/safe_journey.html", {"T": {"title": "Live journey", "brand": "Assisto Safe Journey"}, "lang": "en"}),
                         ("web/vehicle_live.html", {"T": {"title": "Vehicle live location"}, "lang": "en"}),
                         ("web/at_watch.html", {"owner": "Rahim", "en": True, "lang": "en"})):
            html = self._render(tpl, ctx)
            t = _title(html)
            self.assertIn("Assisto", t, tpl)
            self.assertNotRegex(t, SURVEILLANCE, tpl)
            for needle in ("favicon.svg", 'rel="apple-touch-icon"', 'property="og:image"', 'name="theme-color"'):
                self.assertIn(needle, html, "%s on %s" % (needle, tpl))

    def test_owner_admin_title_favicon_noindex(self):
        r = self.client.get("/owner/login")
        if r.status_code == 200:
            html = r.content.decode()
            self.assertIn("favicon.svg", html)
            self.assertIn("noindex", html)
            self.assertIn("Assisto", _title(html))
            self.assertNotIn("og:image", html)            # private panel: no share card
