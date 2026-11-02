"""website (owner order 2 Nov): lifeassisto.com marketing pages + site assets.

* /                 home (hero, features with real app screenshots, trust,
                    pricing from the live plan catalogue, free tools, FAQ)
* /pricing /security /help   their own SEO pages (same content blocks)
* /site/<file>      self-hosted assets (font, logo, screenshots, badges) with
                    long immutable caching; URLs carry ?v=<content hash>.
                    Served by Django on purpose: deploys do not run
                    collectstatic, and nginx proxies every path here.
* /favicon.ico /apple-touch-icon.png /site.webmanifest  at the root where
                    browsers and crawlers look for them.

Strictly one language per page (?lang=en, default Bangla) like the rest of
backend/web. A visitor's explicit choice is remembered in a cookie; a bare
URL then redirects to the remembered language (crawlers never carry the
cookie, so the canonical Bangla URL always serves Bangla to them).
"""
import hashlib
import json
import re
from pathlib import Path

from django.http import Http404, HttpResponse, HttpResponseRedirect
from django.shortcuts import render

from . import site_content as SC
from .views import _ctx, _lang, _site

ASSET_DIR = Path(__file__).resolve().parent / "site_assets"
_ASSET_RE = re.compile(r"^(?:shots/)?[a-z0-9][a-z0-9_\-]*\.(png|webp|avif|svg|ico|woff2|jpg|txt)$")
_TYPES = {"png": "image/png", "webp": "image/webp", "avif": "image/avif",
          "svg": "image/svg+xml", "ico": "image/x-icon", "woff2": "font/woff2",
          "jpg": "image/jpeg", "txt": "text/plain; charset=utf-8"}
_VER = {}
LANG_COOKIE = "assisto_lang"
PLAY_ID = "com.assisto.assisto"


def asset_version(name):
    v = _VER.get(name)
    if v is None:
        try:
            v = hashlib.sha256((ASSET_DIR / name).read_bytes()).hexdigest()[:10]
        except OSError:
            v = "0"
        _VER[name] = v
    return v


def asset_url(name):
    return "/site/%s?v=%s" % (name, asset_version(name))


def _serve(name, max_age=31536000, immutable=True):
    if not _ASSET_RE.match(name or "") or ".." in name:
        raise Http404
    p = ASSET_DIR / name
    if not p.is_file():
        raise Http404
    resp = HttpResponse(p.read_bytes(), content_type=_TYPES[name.rsplit(".", 1)[1]])
    resp["Cache-Control"] = "public, max-age=%d%s" % (max_age, ", immutable" if immutable else "")
    resp["X-Content-Type-Options"] = "nosniff"
    if name.endswith(".woff2"):
        resp["Access-Control-Allow-Origin"] = "*"
    return resp


def site_asset(request, name):
    # versioned URLs (?v=<hash>) are immutable; bare ones (screenshots in
    # srcset) get a week so a re-generated image shows up without a rename.
    if request.GET.get("v"):
        return _serve(name)
    return _serve(name, max_age=604800, immutable=False)


def favicon_ico(request):
    return _serve("favicon.ico", max_age=86400, immutable=False)


def apple_touch_icon(request):
    return _serve("apple-touch-icon.png", max_age=86400, immutable=False)


def webmanifest(request):
    lang = _lang(request)
    body = {
        "name": "Assisto",
        "short_name": "Assisto",
        "description": SC.COPY[lang]["meta_desc"],
        "lang": lang,
        "start_url": "/" + ("?lang=en" if lang == "en" else ""),
        "scope": "/",
        "display": "standalone",
        "background_color": "#ffffff",
        "theme_color": SC.THEME_COLOR,
        "icons": [
            {"src": asset_url("icon-192.png"), "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
            {"src": asset_url("icon-512.png"), "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
        ],
        "related_applications": [{"platform": "play", "id": PLAY_ID,
                                  "url": SC.play_url(lang)}],
    }
    resp = HttpResponse(json.dumps(body, ensure_ascii=False), content_type="application/manifest+json")
    resp["Cache-Control"] = "public, max-age=86400"
    return resp


# ------------------------------------------------------------------ pages
def _remembered(request):
    """Bare URL + remembered English choice -> the English URL (302)."""
    if "lang" in request.GET:
        return None
    if request.COOKIES.get(LANG_COOKIE) == "en":
        q = request.GET.copy()
        q["lang"] = "en"
        return HttpResponseRedirect(request.path + "?" + q.urlencode())
    return None


def remember_lang(request, resp):
    v = request.GET.get("lang")
    if v in ("bn", "en"):
        resp.set_cookie(LANG_COOKIE, v, max_age=365 * 86400, samesite="Lax",
                        secure=request.is_secure(), httponly=False)
    resp["Vary"] = "Cookie"
    return resp


def _plans(lang):
    """Live plan catalogue (Owner Admin pricing) — never hard-coded prices."""
    try:
        from core import plans
        rows = plans.plans_public(lang)
    except Exception:  # noqa: BLE001  (pricing must never break the home page)
        rows = []
    monthly, yearly = [], []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or r.get("price") is None:
            continue
        item = {
            "id": r.get("id"), "name": r.get("name"), "desc": r.get("desc"),
            "benefits": list(r.get("benefits") or [])[:5], "ads": r.get("ads"),
            "price": SC.money(r.get("price"), r.get("cur") or "BDT", lang),
            "free": not r.get("price"), "period": r.get("period"),
        }
        (yearly if r.get("period") == "yr" else monthly).append((r.get("price") or 0, item))
    monthly.sort(key=lambda t: t[0])
    return [i for _, i in monthly], [i for _, i in yearly]


def _page(request, template, page, status=200):
    redir = _remembered(request)
    if redir:
        redir["Vary"] = "Cookie"
        return redir
    lang = _lang(request)
    C = SC.COPY[lang]
    path = SC.PAGES[page]["path"]
    site = _site()
    bn_url = site + path
    en_url = site + path + ("&" if "?" in path else "?") + "lang=en"
    monthly, yearly = _plans(lang) if page in ("home", "pricing") else ([], [])
    ctx = _ctx(
        request, C=C, page=page, P=SC.PAGES[page], page_title=SC.PAGES[page]["title"][lang],
        page_desc=SC.PAGES[page]["desc"][lang],
        seo={"canonical": en_url if lang == "en" else bn_url, "alt_bn": bn_url, "alt_en": en_url},
        features=SC.features(lang), faq=SC.faq(lang), trust=SC.trust(lang), tools=SC.tools(lang),
        plans=monthly, plans_yearly=yearly, play_url=SC.play_url(lang),
        badge=asset_url("google-play-badge-%s.png" % lang),
        jsonld=SC.jsonld(lang, site, en_url if lang == "en" else bn_url, page),
        hero_shot="home_v2",
    )
    resp = render(request, template, ctx, status=status)
    resp["Cache-Control"] = "public, max-age=300"
    return remember_lang(request, resp)


def home(request):
    return _page(request, "web/site_home.html", "home")


def pricing(request):
    return _page(request, "web/site_pricing.html", "pricing")


def security(request):
    return _page(request, "web/site_security.html", "security")


def help_page(request):
    return _page(request, "web/site_help.html", "help")
