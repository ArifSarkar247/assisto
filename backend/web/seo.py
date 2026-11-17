"""seo (owner order 17 Nov 00:14) — one place for what Google may index.

* ONE canonical host: settings.WEB_PUBLIC_SITE (https://lifeassisto.com).
  www/http -> 301 is done in nginx; here every public page gets a SELF
  canonical (bn = bare path, en = ?lang=en) + hreflang bn/en/x-default.
* PUBLIC_PATHS is the sitemap (plus the v3 /features pages once live);
  private / token / owner / checkout pages are never listed and keep noindex.
* Other hosts that reach the same Django site (api.lifeassisto.com,
  track.lifeassisto.com, ...) answer web pages with X-Robots-Tag noindex so
  they never show up as duplicates. /api/, /dl/, /m/ and /.well-known/ are
  never touched (app traffic and downloads).
"""
from django.conf import settings

# Every public marketing / legal / free-tool page. Order = sitemap order.
PUBLIC_PATHS = ["/", "/features", "/pricing", "/security", "/help", "/about",
                "/khata-free", "/cv", "/scam", "/photo", "/festival", "/made30", "/get",
                "/privacy", "/terms", "/refund-policy", "/delete-account"]

# seolive (17 Nov): <lastmod> for every non-blog sitemap URL — the date of the
# last real content release of the marketing / landing / legal pages. Bump it
# when their copy changes (blog articles carry their own dates).
SITE_LASTMOD = "2026-11-17"

# Pages that must keep noindex (documented for the owner + checked by tests).
PRIVATE_PREFIXES = ("/owner/", "/preview/", "/premium", "/pay/", "/b/", "/i/", "/ch/", "/cm/",
                    "/j/", "/r/", "/q/", "/qp/", "/kh/", "/verify/", "/d/", "/v/", "/pc/", "/e/",
                    "/shop/", "/c/", "/p/", "/rsvp/", "/w/", "/photo/app", "/cv/r", "/scam/r")

APP_PREFIXES = ("/api/", "/dl/", "/m/", "/.well-known/")


def site():
    return getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")


def canonical_host():
    return site().split("://", 1)[-1].split("/", 1)[0].lower()


def urls(path, lang):
    """{canonical, alt_bn, alt_en} for one public path in one language."""
    bn_url = site() + path
    en_url = bn_url + "?lang=en"
    return {"canonical": en_url if lang == "en" else bn_url, "alt_bn": bn_url, "alt_en": en_url}


def is_duplicate_host(host):
    """True for any other *.lifeassisto.com host serving this site
    (api., track., ...). The canonical host, localhost and test hosts -> False."""
    h = (host or "").split(":", 1)[0].lower().rstrip(".")
    canon = canonical_host()
    return bool(h) and h != canon and h.endswith("." + canon.removeprefix("www."))


class DuplicateHostNoindexMiddleware:
    """X-Robots-Tag noindex on web pages served from a non-canonical host."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        resp = self.get_response(request)
        try:
            if (not request.path.startswith(APP_PREFIXES)
                    and is_duplicate_host(request.META.get("HTTP_HOST", ""))):
                resp["X-Robots-Tag"] = "noindex, nofollow"
        except Exception:  # noqa: BLE001 — never break a response for SEO
            pass
        return resp
