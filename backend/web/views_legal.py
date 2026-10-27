"""l1-launch — /privacy, /terms, /delete-account, /app-ads.txt, /sitemap.xml.

Plain server-rendered pages (no JS), strictly one language per page
(?lang=en, default Bangla) like the rest of backend/web, with canonical +
hreflang tags and NO noindex (Play and AdMob reviewers must be able to reach
and index them).
"""
import os
import re

from django.conf import settings
from django.http import HttpResponse
from django.shortcuts import render
from django.views.decorators.http import require_http_methods

from . import legal_content as LC
from . import legal_deletion as LD
from .views import _ctx, _ip_hash, _lang, _site


def _seo(path, lang):
    site = _site()
    bn_url = site + path
    en_url = site + path + "?lang=en"
    return {"canonical": en_url if lang == "en" else bn_url,
            "alt_bn": bn_url, "alt_en": en_url}


def _page(request, key, extra=None, status=200):
    lang = _lang(request)
    meta = LC.PAGES[key]
    i = 0 if lang == "bn" else 1
    ctx = _ctx(request, page_key=key, page_title=meta["title"][i],
               page_desc=meta["desc"][i], sections=LC.render_sections(key, lang),
               updated=LC.LAST_UPDATED, seo=_seo(meta["path"], lang),
               self_path=meta["path"])
    ctx.update(extra or {})
    resp = render(request, "web/legal_page.html", ctx, status=status)
    resp["Cache-Control"] = "public, max-age=600" if request.method == "GET" and status == 200 else "no-store"
    return resp


def privacy(request):
    return _page(request, "privacy")


def terms(request):
    return _page(request, "terms")


def refund_policy(request):          # billing-v2 rule M
    return _page(request, "refund")


@require_http_methods(["GET", "POST"])
def delete_account(request):
    lang = _lang(request)
    if request.method == "GET":
        return _page(request, "deletion", {"form": {}, "errors": {}})
    h = _ip_hash(request)
    if not LD.rate_ok(h):
        return render(request, "web/limited.html", {"lang": lang}, status=429)
    ok, errors, _ticket = LD.submit(request.POST, ip_hash=h, lang=lang)
    if not ok:
        form = {k: request.POST.get(k, "") for k in ("contact", "name", "reason")}
        return _page(request, "deletion", {"form": form, "errors": errors}, status=400)
    # Same answer whether or not an account exists (no probing).
    return _page(request, "deletion", {"sent": True})


# ---------------------------------------------------------------- app-ads.txt
# IAB app-ads.txt line for AdMob. f08c47fec0942fa0 is Google's public TAG id.
_PUB_RE = re.compile(r"(?:ca-app-)?(pub-\d{16})")
APP_ADS_LINE = "google.com, {pub}, DIRECT, f08c47fec0942fa0"


def admob_publisher_id():
    """pub-XXXXXXXXXXXXXXXX or ''. Order: ADMOB_PUBLISHER_ID (settings/env) ->
    the owner panel's AdMob integration (`publisher_id`, else derived from
    the saved REAL App ID ca-app-pub-XXXXXXXXXXXXXXXX~NNNN). Google's public
    test publisher is never served."""
    cands = [getattr(settings, "ADMOB_PUBLISHER_ID", "") or os.getenv("ADMOB_PUBLISHER_ID", "")]
    try:
        from core import integrations
        cfg = integrations.get("admob") or {}
        cands += [cfg.get("publisher_id", ""), cfg.get("app_id", "")]
    except Exception:
        pass
    for raw in cands:
        m = _PUB_RE.search(str(raw or "").strip())
        if m and m.group(1) != "pub-3940256099942544":   # Google's sample/test publisher
            return m.group(1)
    # admob (owner 25 Oct): Assisto's own AdMob account (the App ID in the
    # APK manifest belongs to it), so the file is never empty.
    from core.logic.ads import OWNER_PUBLISHER
    return OWNER_PUBLISHER


def app_ads_txt(request):
    pub = admob_publisher_id()
    if pub:
        body = ("# app-ads.txt for lifeassisto.com (Assisto)\n"
                + APP_ADS_LINE.format(pub=pub) + "\n")
    else:
        # Honest placeholder: comment lines only = a valid file that
        # authorises no seller. AdMob shows "not verified" until the owner
        # sets the publisher id; ads still serve meanwhile.
        body = ("# app-ads.txt for lifeassisto.com (Assisto)\n"
                "# AdMob publisher ID not configured yet.\n")
    resp = HttpResponse(body, content_type="text/plain; charset=utf-8")
    resp["Cache-Control"] = "public, max-age=3600"
    return resp


# ---------------------------------------------------------------- sitemap
SITEMAP_PATHS = ["/", "/cv", "/scam", "/photo", "/festival", "/made30", "/get",
                 "/privacy", "/terms", "/delete-account", "/refund-policy"]


def sitemap_xml(request):
    site = _site()
    rows = []
    for p in SITEMAP_PATHS:
        bn = site + p
        en = site + p + "?lang=en"
        for loc in (bn, en):
            rows.append(
                "  <url><loc>%s</loc>"
                "<xhtml:link rel=\"alternate\" hreflang=\"bn\" href=\"%s\"/>"
                "<xhtml:link rel=\"alternate\" hreflang=\"en\" href=\"%s\"/></url>"
                % (loc.replace("&", "&amp;"), bn, en.replace("&", "&amp;")))
    body = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
            'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(rows) + "\n</urlset>\n")
    return HttpResponse(body, content_type="application/xml; charset=utf-8")
