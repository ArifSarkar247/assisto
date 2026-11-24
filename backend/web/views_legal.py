"""l1-launch — /privacy, /terms, /delete-account, /app-ads.txt, /sitemap.xml.

Plain server-rendered pages (no JS), strictly one language per page
(?lang=en, default Bangla) like the rest of backend/web, with canonical +
hreflang tags and NO noindex (Play and AdMob reviewers must be able to reach
and index them).
"""
import os
import re

from django.conf import settings
from django.http import HttpResponse, HttpResponseNotFound
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
               updated=meta.get("updated", LC.LAST_UPDATED), seo=_seo(meta["path"], lang),
               self_path=meta["path"])
    ctx.update(extra or {})
    resp = render(request, "web/legal_page.html", ctx, status=status)
    resp["Cache-Control"] = "public, max-age=600" if request.method == "GET" and status == 200 else "no-store"
    return resp


# privacyupd (owner Play decision 7, 9 Nov): the updated policy goes live only
# when the owner turns AdminFlagState "privacy_classic" OFF (Owner Admin → Website);
# until then it is served only at /preview/privacy (noindex, never in the sitemap).
PRIVACY_V2_FLAG = "privacy_classic"   # ON = classic text; OFF = v2 live
PRIVACY_PREVIEW = "/preview/privacy"


def privacy_v2_live():
    """Missing row / key / DB trouble -> the current policy (never the preview)."""
    try:
        from core.models import AdminFlagState
        row = AdminFlagState.objects.filter(key="global").first()
        return bool(row and (row.state or {}).get(PRIVACY_V2_FLAG) is False)
    except Exception:  # noqa: BLE001 — DB trouble keeps the current policy
        return False


def privacy(request):
    return _page(request, "privacy_v2" if privacy_v2_live() else "privacy")


def privacy_preview(request):
    resp = _page(request, "privacy_v2", extra={"preview": True, "self_path": PRIVACY_PREVIEW})
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Cache-Control"] = "no-store"
    return resp


def privacy_flip(actor_id, value):
    """Go live (True) / roll back (False) through the audited flags engine."""
    from core.views_build61 import flags_flip
    reason = ("privacy policy v2 go-live (owner, Owner Admin → Website)" if value else
              "privacy policy v2 rollback to the previous text (owner, Owner Admin → Website)")
    return flags_flip(actor_id, PRIVACY_V2_FLAG, not bool(value), reason)


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
    """pub-XXXXXXXXXXXXXXXX or ''. admobump (owner 2 Nov): ONLY from stored
    config, never from git. Order: Owner Admin -> Integrations -> Google
    AdMob `publisher_id` -> derived from the REAL App ID saved there
    (ca-app-pub-XXXXXXXXXXXXXXXX~NNNN) -> ADMOB_PUBLISHER_ID (server env /
    settings). Google's public test publisher is never served."""
    cands = []
    try:
        from core import integrations
        cfg = integrations.get("admob") or {}
        cands += [cfg.get("publisher_id", ""), cfg.get("app_id", "")]
    except Exception:
        pass
    cands.append(getattr(settings, "ADMOB_PUBLISHER_ID", "") or os.getenv("ADMOB_PUBLISHER_ID", ""))
    for raw in cands:
        m = _PUB_RE.search(str(raw or "").strip())
        if m and m.group(1) != "pub-3940256099942544":   # Google's sample/test publisher
            return m.group(1)
    return ""


_APP_ADS_RE = None


def app_ads_extra_lines():
    """Valid app-ads.txt records from the admob integration's
    `app_ads_extra` (max 20): `domain, account id, DIRECT|RESELLER[, cert]`.
    Anything else (comments, junk, Google's own test publisher) is dropped."""
    import re
    global _APP_ADS_RE
    if _APP_ADS_RE is None:
        _APP_ADS_RE = re.compile(
            r"^[a-z0-9.-]+\.[a-z]{2,}\s*,\s*[A-Za-z0-9._-]{3,64}\s*,\s*(DIRECT|RESELLER)"
            r"(\s*,\s*[A-Za-z0-9]{6,32})?$", re.I)
    try:
        from core import integrations
        raw = str((integrations.get("admob") or {}).get("app_ads_extra") or "")
    except Exception:
        return []
    out = []
    for line in re.split(r"[\r\n;]+", raw):
        line = line.strip()
        if _APP_ADS_RE.match(line) and "3940256099942544" not in line and line not in out:
            out.append(line)
    return out[:20]


# owner 24 Nov: HalalAdz on the public website. lifeassisto.com/ads.txt had no
# other lines (404 before), so this is the whole file.
ADS_TXT_LINES = ("halaladz.com, pub-12, DIRECT",)


def ads_txt(request):
    resp = HttpResponse("\n".join(ADS_TXT_LINES) + "\n", content_type="text/plain; charset=utf-8")
    resp["Cache-Control"] = "public, max-age=600"
    return resp


def app_ads_txt(request):
    """lifeassisto.com/app-ads.txt (nginx proxies every path to Django).
    text/plain, short cache. No publisher id stored -> 404 (not an empty
    file), so AdMob reports "not found" instead of a silently empty list."""
    pub = admob_publisher_id()
    if not pub:
        resp = HttpResponseNotFound("app-ads.txt: AdMob publisher ID not configured\n",
                                    content_type="text/plain; charset=utf-8")
        resp["Cache-Control"] = "no-store"
        return resp
    body = ("# app-ads.txt for lifeassisto.com (Assisto)\n"
            + APP_ADS_LINE.format(pub=pub) + "\n")
    # adcontrol (owner 10 Nov part F): the mediation partners' lines the
    # owner pasted (Owner Admin -> Integrations -> Google AdMob)
    extra = app_ads_extra_lines()
    if extra:
        body += "# mediation partners (AdMob bidding)\n" + "\n".join(extra) + "\n"
    resp = HttpResponse(body, content_type="text/plain; charset=utf-8")
    # short: a publisher id changed in Owner Admin shows within 10 minutes
    resp["Cache-Control"] = "public, max-age=600"
    return resp


# ---------------------------------------------------------------- sitemap
# seo (17 Nov): one public-page list for sitemap + canonical (web/seo.py);
# /features* only once v3 is live (sitemap_extra).
from .seo import PUBLIC_PATHS
SITEMAP_PATHS = [p for p in PUBLIC_PATHS if not p.startswith("/features")]


def sitemap_xml(request):
    site = _site()
    rows = []
    from .views_site3 import sitemap_extra   # sitev3: only once v3 is live
    from .blog import sitemap_paths as blog_paths   # seoblog: published posts only
    from .blog import sitemap_lastmod
    from .seo import SITE_LASTMOD
    mods = sitemap_lastmod()   # seolive: every URL carries <lastmod>
    for p in SITEMAP_PATHS + sitemap_extra() + blog_paths():
        bn = site + p
        en = site + p + "?lang=en"
        mod = mods[p].isoformat() if p in mods else SITE_LASTMOD
        for loc in (bn, en):
            rows.append(
                "  <url><loc>%s</loc><lastmod>%s</lastmod>"
                "<xhtml:link rel=\"alternate\" hreflang=\"bn\" href=\"%s\"/>"
                "<xhtml:link rel=\"alternate\" hreflang=\"en\" href=\"%s\"/>"
                "<xhtml:link rel=\"alternate\" hreflang=\"x-default\" href=\"%s\"/></url>"
                % (loc.replace("&", "&amp;"), mod, bn, en.replace("&", "&amp;"), bn))
    body = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
            'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(rows) + "\n</urlset>\n")
    return HttpResponse(body, content_type="application/xml; charset=utf-8")
