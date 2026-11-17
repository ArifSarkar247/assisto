"""seogrow (owner order 17 Nov 00:32): feature landing pages, JSON-LD, Open
Graph / Twitter cards, the site_seo_growth_live go-live switch and the hidden
Google Play badge (site_play_badge_live).
"""
import json
import re
from html.parser import HTMLParser
from pathlib import Path

from django.test import Client, TestCase

from core.models import AdminFlagState, OwnerAudit
from web import site_landing as LP
from web.tests_o2_owner_admin import OwnerBase
from web.tests_site_v3 import Base, no_network, set_flag, set_live

ASSETS = Path(__file__).resolve().parent / "site_assets"
COMPETITORS = ("whatsapp", "messenger", "imo ", "life360", "chatgpt", "gemini", "elsa", "quran.com",
               "google maps", "tally", "hishabee", "khatabook", "telegram", "viber", "truecaller")
MEDICINE = ("medicine", "ওষুধ", "pharma", "prescription", "প্রেসক্রিপশন")
ALL_FLAGS = sorted({f for d in LP.LANDINGS.values() for f in d["flags"]}
                   | {f for d in LP.LANDINGS.values() for p in d["points"] + d["shots"] for f in p["flags"]})


def set_state(**kw):
    row, _ = AdminFlagState.objects.get_or_create(key="global")
    row.state = dict(row.state or {}, **kw)
    row.save()


class _Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.h1 = 0
        self.imgs, self.ld, self.meta, self.links, self.hrefs = [], [], {}, [], []
        self._ld = None

    def handle_starttag(self, tag, a):
        a = dict(a)
        if tag == "h1":
            self.h1 += 1
        elif tag == "img":
            self.imgs.append(a)
        elif tag == "meta":
            k = a.get("property") or a.get("name")
            if k:
                self.meta.setdefault(k, []).append(a.get("content"))
        elif tag == "link":
            self.links.append(a)
        elif tag == "a" and a.get("href"):
            self.hrefs.append(a["href"])
        elif tag == "script" and a.get("type") == "application/ld+json":
            self._ld = []

    def handle_data(self, data):
        if self._ld is not None:
            self._ld.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self._ld is not None:
            self.ld.append("".join(self._ld))
            self._ld = None


def parse(html):
    p = _Page()
    p.feed(html)
    return p


def graph(p):
    """Every JSON-LD block must parse; returns {@type: node}."""
    out = {}
    for raw in p.ld:
        data = json.loads(raw)
        for node in data.get("@graph", [data]):
            out[node["@type"]] = node
    return out


def main_part(html):
    """The page body before the shared download CTA (whose Play line is
    site-wide and not part of the landing copy)."""
    return html.split('<main id="main">', 1)[1].split('id="download"', 1)[0]


class LandingBase(Base):
    def setUp(self):
        super().setUp()
        set_state(site_play_badge_hidden=True)   # Play not live yet (the real state)
        for f in ALL_FLAGS:
            set_flag(f, True)

    def get(self, slug, lang):
        # explicit ?lang= : a bare URL redirects to the language remembered in the cookie
        return self.c.get(LP.path(slug) + "?lang=" + lang)


class LandingPageTests(LandingBase):
    def test_every_page_one_h1_unique_title_desc_real_shots(self):
        titles, descs = set(), set()
        for slug in LP.SLUGS:
            for lang in ("bn", "en"):
                r = self.get(slug, lang)
                self.assertEqual(r.status_code, 200, slug)
                html = r.content.decode()
                p = parse(html)
                self.assertEqual(p.h1, 1, (slug, lang))
                t = re.search(r"<title>(.*?)</title>", html).group(1)
                d = p.meta["description"][0]
                self.assertNotIn(t, titles)
                self.assertNotIn(d, descs)
                titles.add(t)
                descs.add(d)
                self.assertLessEqual(len(d), 200, (slug, lang))
                shots = [i for i in p.imgs if "/shots3/" in i.get("src", "")]
                self.assertTrue(shots, (slug, lang))
                for i, im in enumerate(shots):
                    self.assertTrue(im.get("width") and im.get("height"), im)
                    self.assertTrue(im.get("alt"))
                    name = im["src"].split("/site/", 1)[1].split("?", 1)[0]
                    self.assertTrue((ASSETS / name).is_file(), name)
                    if i:
                        self.assertEqual(im.get("loading"), "lazy")
                self.assertTrue(all(i.get("width") and i.get("height") for i in p.imgs if i.get("src")), slug)
                body = main_part(html).lower()
                for w in COMPETITORS + MEDICINE:
                    self.assertNotIn(w, body, (slug, lang, w))
                self.assertNotIn("coming soon", body)
                self.assertNotIn("শীঘ্রই", body)
                self.assertNotIn("aggregaterating", html.lower())
        self.assertEqual(len(titles), 2 * len(LP.SLUGS))

    def test_canonical_hreflang_og_twitter(self):
        for slug in LP.SLUGS:
            for lang in ("bn", "en"):
                p = parse(self.get(slug, lang).content.decode())
                url = "https://lifeassisto.com" + LP.path(slug) + ("?lang=en" if lang == "en" else "")
                canon = [x["href"] for x in p.links if x.get("rel") == "canonical"]
                self.assertEqual(canon, [url])
                alts = {x["hreflang"]: x["href"] for x in p.links if x.get("rel") == "alternate" and x.get("hreflang")}
                self.assertEqual(alts["bn"], "https://lifeassisto.com" + LP.path(slug))
                self.assertEqual(alts["en"], "https://lifeassisto.com" + LP.path(slug) + "?lang=en")
                self.assertEqual(p.meta["og:url"], [url])
                self.assertEqual(p.meta["og:locale"], ["bn_BD" if lang == "bn" else "en_US"])
                self.assertEqual(p.meta["og:locale:alternate"], ["en_US" if lang == "bn" else "bn_BD"])
                self.assertEqual(p.meta["twitter:card"], ["summary_large_image"])
                img = p.meta["og:image"][0]
                self.assertIn("/site/og/%s-%s.jpg?v=" % (slug, lang), img)
                self.assertEqual(p.meta["twitter:image"], [img])
                self.assertEqual(p.meta["og:image:width"], ["1200"])

    def test_og_images_are_1200x630(self):
        from PIL import Image
        for slug in LP.SLUGS:
            for lang in ("bn", "en"):
                f = ASSETS / "og" / ("%s-%s.jpg" % (slug, lang))
                with Image.open(f) as im:
                    self.assertEqual(im.size, (1200, 630), f.name)
                self.assertLess(f.stat().st_size, 200_000, f.name)
                r = self.c.get("/site/og/%s-%s.jpg" % (slug, lang))
                self.assertEqual(r.status_code, 200)

    def test_jsonld_every_block_parses(self):
        pages = [LP.path(s) for s in LP.SLUGS]
        set_live(True)
        pages += ["/", "/features", "/pricing", "/security", "/help", "/about", "/features/safety"]
        for path in pages:
            for q in ("?lang=bn", "?lang=en"):
                p = parse(self.c.get(path + q).content.decode())
                self.assertTrue(p.ld, path)
                g = graph(p)
                org, app = g["Organization"], g["SoftwareApplication"]
                self.assertEqual(org["name"], "Axon Dynamics")
                self.assertEqual(org["email"], "assistoaiagent@gmail.com")
                self.assertEqual(org["url"], "https://lifeassisto.com/")
                self.assertEqual(org["address"]["streetAddress"], "Cha-63/3, Uttar Badda, Badda")
                self.assertEqual(org["address"]["postalCode"], "1212")
                self.assertEqual(org["address"]["addressLocality"], "Dhaka")
                self.assertTrue(org["logo"]["url"].endswith("/site/icon-512.png"))
                self.assertEqual(app["operatingSystem"], "Android")
                self.assertEqual(app["offers"]["price"], "0")
                self.assertNotIn("aggregateRating", app)
                self.assertNotIn("review", app)
                self.assertNotIn("play.google.com", app["installUrl"])   # Play hidden -> /get
        for slug in LP.SLUGS:
            html = self.get(slug, "en").content.decode()
            g = graph(parse(html))
            faq = g["FAQPage"]["mainEntity"]
            self.assertEqual(len(faq), len(LP.LANDINGS[slug]["faq"]["en"]))
            self.assertEqual(html.count("<details>"), len(faq))
            crumbs = g["BreadcrumbList"]["itemListElement"]
            self.assertEqual([c["position"] for c in crumbs], [1, 2, 3])
            self.assertTrue(crumbs[-1]["item"].endswith(LP.path(slug) + "?lang=en"))

    def test_internal_links_resolve(self):
        set_live(True)
        set_state(site_seo_growth_preview=False)
        for slug in LP.SLUGS:
            p = parse(self.get(slug, "bn").content.decode())
            related = [h for h in p.hrefs if h.startswith("/features/") and h.split("/")[2] in LP.LANDINGS]
            self.assertGreaterEqual(len(set(related)), 2, slug)
            for h in set(h.split("#")[0] for h in p.hrefs if h.startswith("/") and not h.startswith("/site/")):
                self.assertLess(Client().get(h).status_code, 400, (slug, h))   # fresh client: no remembered language


class HonestyTests(LandingBase):
    def test_each_screenshot_sits_next_to_its_own_point(self):
        html = self.get("family-care", "en").content.decode()
        rows = re.findall(r'<section class="frow.*?</section>', html, re.S)
        sos = [r for r in rows if "One-tap SOS" in r]
        self.assertEqual(len(sos), 1)
        self.assertIn("emergency_hub_en_360", sos[0])
        school = [r for r in rows if "school corner" in r][0]
        self.assertIn("famcare_school_en_360", school)


    def test_page_404_when_its_app_feature_is_off(self):
        set_flag("quran", False)
        set_state(site_seo_growth_preview=False)
        self.assertEqual(self.c.get("/features/quran").status_code, 404)
        self.assertNotIn("/features/quran", self.c.get("/sitemap.xml").content.decode())
        self.assertIsNone(LP.url_for("quran", "bn"))
        self.assertEqual(LP.url_for("mess", "en"), "/features/mess?lang=en")
        # related cards never link to a missing page
        self.assertNotIn('href="/features/quran"', self.c.get("/features/language-partner").content.decode())

    def test_points_and_shots_follow_their_flags(self):
        set_flag("language_packs", False)
        html = self.get("language-partner", "en").content.decode()
        self.assertNotIn("IELTS", html)
        self.assertNotIn("lang_partner_en_360", html)     # that screen shows the IELTS card
        set_flag("language_packs", True)
        html = self.get("language-partner", "en").content.decode()
        self.assertIn("IELTS-style practice", html)
        self.assertIn("lang_partner_en_360", html)
        set_flag("quran_learn", False)
        self.assertNotIn("quran_learn_bn", self.get("quran", "bn").content.decode())

    def test_group_pages_unchanged(self):
        set_live(True)
        self.assertEqual(self.c.get("/features/cctv").status_code, 200)
        self.assertEqual(self.c.get("/features/nope").status_code, 404)


class CrawlTests(LandingBase):
    def test_no_internal_link_on_any_public_page_is_a_404(self):
        """Lead review 17 Nov: the footer must never link a landing page whose
        app feature is OFF (e.g. Quran) — crawl every internal link."""
        set_live(True)
        set_state(site_seo_growth_preview=False)
        set_flag("quran", False)
        pages = {"/", "/features", "/pricing", "/security", "/help", "/about", "/get", "/privacy", "/terms",
                 "/delete-account"} | {"/features/%s" % g for g in ("ai", "circle", "safety", "cctv", "business", "work", "daily")}
        pages |= {LP.path(s) for s in LP.live_slugs()}
        seen = {}
        for path in sorted(pages):
            for q in ("?lang=bn", "?lang=en"):
                r = Client().get(path + q)
                self.assertEqual(r.status_code, 200, path + q)
                p = parse(r.content.decode())
                for h in p.hrefs:
                    if not h.startswith("/") or h.startswith(("/site/", "/dl/", "/download/")):
                        continue
                    h = h.split("#")[0] or "/"
                    if h not in seen:
                        seen[h] = Client().get(h).status_code
                    self.assertNotEqual(seen[h], 404, (path + q, h))
        self.assertNotIn("/features/quran", seen)
        self.assertIn("/features/mess", seen)


class GoLiveSwitchTests(LandingBase):
    def test_off_by_default_noindex_not_in_sitemap_or_nav(self):
        self.assertFalse(LP.growth_live())
        set_live(True)
        for slug in LP.SLUGS:
            r = self.get(slug, "bn")
            self.assertEqual(r.status_code, 200)                       # reachable for owner review
            self.assertIn("noindex", r["X-Robots-Tag"])
            self.assertContains(r, '<meta name="robots" content="noindex, nofollow">')
        sm = self.c.get("/sitemap.xml").content.decode()
        self.assertNotIn("/features/family-care", sm)
        home = self.c.get("/").content.decode()
        self.assertNotIn('href="/features/family-care"', home)
        self.assertNotIn('href="/features/mess"', self.c.get("/features").content.decode())

    def test_on_indexable_in_sitemap_with_hreflang_and_in_nav(self):
        set_live(True)
        set_state(site_seo_growth_preview=False)
        r = self.get("mess", "bn")
        self.assertNotIn("X-Robots-Tag", r)
        self.assertContains(r, 'content="index, follow, max-image-preview:large"')
        sm = self.c.get("/sitemap.xml").content.decode()
        for slug in LP.SLUGS:
            loc = "https://lifeassisto.com/features/%s" % slug
            self.assertIn("<loc>%s</loc>" % loc, sm)
            self.assertIn('hreflang="en" href="%s?lang=en"' % loc, sm)
            self.assertIn('hreflang="bn" href="%s"' % loc, sm)
        self.assertIn('href="/features/family-care"', self.c.get("/").content.decode())
        self.assertIn('href="/features/mess?lang=en"', self.c.get("/features?lang=en").content.decode())

    def test_preview_url_always_noindex(self):
        set_state(site_seo_growth_preview=False)
        r = self.c.get("/preview/features/blood-donor")
        self.assertEqual(r.status_code, 200)
        self.assertIn("noindex", r["X-Robots-Tag"])


class PlayBadgeTests(Base):
    """Item 7: no Play badge or Play link while site_play_badge_live is OFF,
    even when the listing check says public; the APK path stays."""

    def setUp(self):
        super().setUp()
        set_state(site_play_badge_hidden=True)

    def test_hidden_by_default_even_if_listing_public(self):
        set_live(True)
        for path in ("/", "/?lang=en", "/features/safety", "/get", "/get?lang=en"):
            r = Client().get(path)
            self.assertEqual(r.status_code, 200, path)
            html = r.content.decode()
            self.assertNotIn("play.google.com", html, path)
            self.assertNotIn("google-play-badge", html, path)
        self.assertIn("Install the APK directly", self.c.get("/get?lang=en").content.decode())

    def test_no_play_wording_anywhere_while_hidden(self):
        set_live(True)
        pages = ["/", "/features", "/pricing", "/security", "/help", "/about", "/features/safety", "/get"] \
            + [LP.path(s) for s in LP.SLUGS]
        for path in pages:
            for q in ("?lang=bn", "?lang=en"):
                r = Client().get(path + q)
                if r.status_code == 404:
                    continue
                html = re.sub(r'<script type="application/ld\+json">.*?</script>', "", r.content.decode(), flags=re.S)
                body = html.split("<body", 1)[1]
                for w in ("Google Play", "Play Store", "Play থেকে", "from Play"):
                    self.assertNotIn(w, body, (path + q, w))

    def test_shown_once_the_owner_says_live(self):
        set_live(True)
        set_state(site_play_badge_hidden=False)
        html = self.c.get("/?lang=en").content.decode()
        self.assertIn('class="badge"', html)
        self.assertIn("play.google.com/store/apps/details?id=com.assisto.assisto", html)
        self.assertIn("google-play-badge-en", self.c.get("/get?lang=en").content.decode())

    def test_owner_on_but_listing_not_public_stays_hidden(self):
        from django.core.cache import cache
        cache.delete("sitev3:play_public")
        self.play_check.return_value = False
        set_live(True)
        set_state(site_play_badge_hidden=False)
        self.assertNotIn('class="badge"', self.c.get("/?lang=en").content.decode())


class OwnerSwitchTests(OwnerBase):
    def setUp(self):
        super().setUp()
        no_network(self)
        set_state(site_play_badge_hidden=True)
        self.ready()

    def test_one_tap_each_and_audited(self):
        from web import site_v3_dist as DIST
        r = self.c.get("/owner/website")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'value="seo_golive"')
        self.assertContains(r, 'value="playbadge_on"')
        self.assertEqual(self.post("/owner/website", {"action": "seo_golive"}).status_code, 302)
        self.assertTrue(LP.growth_live())
        self.assertEqual(self.post("/owner/website", {"action": "seo_hide"}).status_code, 302)
        self.assertFalse(LP.growth_live())
        self.assertEqual(self.post("/owner/website", {"action": "playbadge_on"}).status_code, 302)
        self.assertTrue(DIST.play_badge_on())
        self.assertEqual(self.post("/owner/website", {"action": "playbadge_off"}).status_code, 302)
        self.assertFalse(DIST.play_badge_on())
        self.assertEqual(OwnerAudit.objects.filter(action="flag.flip").count(), 4)
        self.assertIsNotNone(Client())
