"""website v3 (owner final website order 3 Nov) — the new lifeassisto.com,
behind a GO-LIVE switch.

  * Switch: AdminFlagState flag "website_classic" (core.logic.admin_flags),
    default ON = classic site; v3 is "live" when it is OFF. Owner Admin → Website (/owner/website): "Go live" / "Roll
    back" — one tap each, audited. OFF = the current site (views_site) is
    served unchanged at /, /pricing, /security, /help; ON = v3 there, plus
    /features and /features/<group>.
  * Preview (always v3, any switch state): /preview/ , /preview/features/<g>,
    /preview/pricing, /preview/security, /preview/help — noindex (meta +
    X-Robots-Tag), never in the sitemap, a visible "Preview" banner.
  * Cache: HTML is `no-cache` + a strong ETag (If-None-Match → 304), so a
    deploy or a flag flip reaches every visitor on the next load; assets are
    content-hashed (?v=) with a 1-year immutable cache (views_site._serve).
  * Language: ?lang=en / ?lang=bn, remembered in the assisto_lang cookie (a
    bare URL redirects to the remembered language); hreflang on every page.
"""
import hashlib

from django.http import Http404, HttpResponse, HttpResponseNotModified
from django.template.loader import render_to_string

from . import site_content as SC
from . import site_v3 as V3
from . import site_v3_icons as ICONS
from . import views_site as OLD
from .views import _lang, _site

FLAG = "website_classic"
PREVIEW = "/preview"


def is_live():
    """v3 is live when the owner turned the classic site OFF (AdminFlagState).
    Missing row / key → classic site."""
    try:
        from core.models import AdminFlagState
        row = AdminFlagState.objects.filter(key="global").first()
        return bool(row and (row.state or {}).get(FLAG) is False)
    except Exception:  # noqa: BLE001 — DB trouble keeps the current site
        return False


# ------------------------------------------------------------- response
def _etag_response(request, html, preview):
    body = html.encode("utf-8")
    tag = '"%s"' % hashlib.sha256(body).hexdigest()[:32]
    inm = request.META.get("HTTP_IF_NONE_MATCH", "")
    if tag in [t.strip() for t in inm.split(",")]:
        resp = HttpResponseNotModified()
    else:
        resp = HttpResponse(body, content_type="text/html; charset=utf-8")
        # these public pages carry no secrets/CSRF tokens -> safe to gzip here
        # (works whatever the front proxy does; it never re-compresses)
        if "gzip" in request.META.get("HTTP_ACCEPT_ENCODING", ""):
            from django.utils.text import compress_string
            z = compress_string(body)
            if len(z) < len(body):
                resp.content = z
                resp["Content-Encoding"] = "gzip"
                resp["Content-Length"] = str(len(z))
    resp["ETag"] = tag
    resp["Cache-Control"] = "no-cache"
    if preview:
        resp["X-Robots-Tag"] = "noindex, nofollow"
    resp = OLD.remember_lang(request, resp)
    resp["Vary"] = "Cookie, Accept-Encoding"
    return resp


def html_cache(request, resp):
    """Old site, switch OFF: same short-cache rule (no-cache + ETag) so the
    day the switch flips nobody keeps a stale copy."""
    if resp.status_code == 200 and resp.get("Content-Type", "").startswith("text/html"):
        tag = '"%s"' % hashlib.sha256(resp.content).hexdigest()[:32]
        resp["ETag"] = tag
        resp["Cache-Control"] = "no-cache"
        if tag in [t.strip() for t in request.META.get("HTTP_IF_NONE_MATCH", "").split(",")]:
            nm = HttpResponseNotModified()
            nm["ETag"] = tag
            nm["Cache-Control"] = "no-cache"
            nm["Vary"] = "Cookie"
            return nm
    return resp


# ------------------------------------------------------------- context
def _urls(base, lang):
    q = "?lang=en" if lang == "en" else ""
    return {"home": (base or "") + "/" + q, "features": base + "/features" + q,
            "pricing": base + "/pricing" + q, "security": base + "/security" + q,
            "help": base + "/help" + q, "q": q, "base": base}


def _shot(name, lang, alt, eager=False):
    # sitelive: a shot not refreshed into site_assets yet is left out (icon
    # card / fewer hero slides) — never a broken image on the live site;
    # web.tests_site_v3 still fails CI until every shot is committed.
    if not name or not (OLD.ASSET_DIR / "shots3" / ("%s_%s_360.webp" % (name, lang))).is_file():
        return None
    d = {"alt": alt, "eager": eager}
    for w in V3_WIDTHS:
        d["w%d" % w] = OLD.asset_url("shots3/%s_%s_%d.webp" % (name, lang, w))
    return d


V3_WIDTHS = (360, 720)


def _slides(C, lang):
    """sitefix (owner 3 Nov 11:10): hero slides with a caption and an
    "n / total" counter (Bangla digits in bn)."""
    out = []
    for n, k in V3.HERO_SLIDES:
        s = _shot(n, lang, C["shot_alt"] + C["slide_" + k])
        if s:
            s["cap"] = C["slide_" + k]
            out.append(s)
    total = len(out)
    for i, s in enumerate(out):
        pos = "%d %s %d" % (i + 1, C["slide_of"], total)
        s["pos"] = V3.bn_digits(pos) if lang == "bn" else pos
    return out


PLACEMENTS = ("hero", "chip_download", "sticky_bar", "footer", "header", "menu")
GET_PLACES = ("hero", "sticky_bar", "footer", "menu")
HERO_SLIDES = tuple(n for n, _ in V3.HERO_SLIDES)  # order + names live in site_v3


def play_links(lang):
    """Every Play button opens the Assisto details page directly (never a
    search), tagged per placement. Android rewrites these to an intent://
    (market scheme, Play Store package) with this https URL as the browser
    fallback (base.html script)."""
    from urllib.parse import quote
    base = SC.play_url(lang)
    return {p: base + "&referrer=" + quote("utm_source=website&utm_medium=%s" % p, safe="")
            for p in PLACEMENTS}


def _chips(C, page, group, base, U, groups, play):
    home = page == "home"
    gm = {g["id"]: g for g in groups}
    rows = [("chip_home", "hero", U["home"])]
    for gid in ("ai", "circle", "safety", "cctv", "business"):
        rows.append(("chip_" + gid, "g-" + gid, gm[gid]["url"]))
    rows += [("chip_pricing", "pricing", U["pricing"]), ("chip_download", "download", play["chip_download"])]
    out = []
    for key, anchor, url in rows:
        is_play = key == "chip_download"
        href = ("#" + anchor) if (home and not is_play) else url
        if is_play and not play.get("_public"):
            href = "#download"
        on = (not home) and ((page == "group" and key == "chip_" + str(group)) or (page == "pricing" and key == "chip_pricing"))
        out.append({"label": C[key], "href": href, "spy": anchor if (home and not is_play) else "",
                    "on": on, "play": is_play})
    return out


def _menu(C, page, group, U, groups, other_url, other):
    """sitefix (owner 3 Nov 11:10): the mobile full-screen menu rows, in the
    owner's order; the current page is highlighted."""
    gm = {g["id"]: g for g in groups}
    rows = [{"label": C["chip_home"], "href": U["home"], "icon": "home", "on": page == "home"}]
    for gid in ("ai", "circle", "safety", "cctv", "business"):
        rows.append({"label": C["chip_" + gid], "href": gm[gid]["url"], "icon": gm[gid]["icon"],
                     "on": page == "group" and group == gid})
    rows += [{"label": C["nav_pricing"], "href": U["pricing"], "icon": "tag", "on": page == "pricing"},
             {"label": C["security_h"], "href": U["security"], "icon": "lock", "on": page == "security"},
             {"label": C["nav_help"], "href": U["help"], "icon": "message", "on": page == "help"},
             {"label": C["lang_name"], "href": other_url, "icon": "globe", "on": False, "lang": other}]
    return rows


def _render(request, page, preview, group=None, status=200):
    redir = OLD._remembered(request)
    if redir:
        redir["Vary"] = "Cookie"
        return redir
    lang = _lang(request)
    C = V3.COPY[lang]
    base = PREVIEW if preview else ""
    U = _urls(base, lang)
    flags, ai_ok = V3.live_flags(), V3.ai_ready()
    groups = V3.groups(lang, flags, ai_ok)
    for g in groups:
        for f in g["features"]:
            f["img"] = _shot(f["shot"], lang, C["shot_alt"] + f["title"]) if f["live"] else None
        g["url"] = base + "/features/" + g["id"] + U["q"]
    gmap = {g["id"]: g for g in groups}
    site = _site()
    path = {"home": "/", "features": "/features", "pricing": "/pricing", "security": "/security",
            "help": "/help", "group": "/features/%s" % group}[page]
    bn_url, en_url = site + path, site + path + "?lang=en"
    faq = SC.faq(lang) + [{"q": q, "a": a} for q, a in V3.EXTRA_FAQ[lang]]
    if page == "group":
        g = gmap[group]
        title, desc = g["title"], g["desc"]
        crumbs = [("Assisto", site + "/"), (C["nav_features"], site + "/features"), (g["name"], bn_url if lang == "bn" else en_url)]
    else:
        title, desc, crumbs = C["title"], C["desc"], None
        if page in ("pricing", "security", "help", "features"):
            title = {"pricing": SC.PAGES["pricing"]["title"][lang], "security": SC.PAGES["security"]["title"][lang],
                     "help": SC.PAGES["help"]["title"][lang],
                     "features": ("সব ফিচার — Assisto" if lang == "bn" else "All features — Assisto")}[page]
            desc = SC.PAGES[page]["desc"][lang] if page != "features" else C["groups_lead"]
    from . import site_v3_dist as DIST
    play = play_links(lang)
    pub = DIST.play_public()
    play["_public"] = pub
    dist = {"public": pub, "apk": DIST.apk_display(DIST.apk_info(), lang), "apk_url": DIST.apk_url()}
    monthly, yearly = OLD._plans(lang) if page in ("home", "pricing") else ([], [])
    icons = {"arrow", "play", "pause", "close", "sparkle", "chat", "store", "lock", "check", "shield", "home", "tag", "message", "globe", "camera"} | {g["icon"] for g in groups} | {i for i, *_ in C["what"]}
    for g in groups:
        icons |= {f["icon"] for f in g["features"]}
    ctx = {
        "lang": lang, "other": "bn" if lang == "en" else "en", "C": C, "U": U, "page": page,
        "preview": preview, "groups": groups, "group": gmap.get(group), "title": title, "desc": desc,
        "seo": {"canonical": en_url if lang == "en" else bn_url, "alt_bn": bn_url, "alt_en": en_url},
        "other_url": request.path + ("?lang=bn" if lang == "en" else "?lang=en"),
        "og_image": site + OLD.asset_url("og-%s.jpg" % lang), "og_url": en_url if lang == "en" else bn_url,
        "auto_strip": V3.auto_strip(groups), "faq": faq, "trust": SC.trust(lang), "tools": SC.tools(lang),
        "plans": monthly, "plans_yearly": yearly, "cctv_plan": V3.cctv_plan(lang),
        "play_url": SC.play_url(lang), "play": play,
        "dist": dist, "get": {p: {"play": play[p], "install": play[p] if dist["public"] else (dist["apk_url"] or play[p]),
                                  "place": p} for p in GET_PLACES},
        "slides": _slides(C, lang), "badge": OLD.asset_url("google-play-badge-%s.png" % lang),
        "hero": _shot("home_v2", lang, C["shot_alt"] + ("হোম স্ক্রিন" if lang == "bn" else "home screen"), eager=True),
        "sprite": ICONS.sprite(icons),
        "font_bn": OLD.asset_url("noto-sans-bengali-var.woff2"),
        "font_taka": OLD.asset_url("taka.woff2"),  # sitelive: clear ৳ (Noto's reads as "b")
        "font_in": {"w%d" % w: OLD.asset_url("inter-%d.woff2" % w) for w in (400, 600, 700)},
        "jsonld": V3.jsonld(lang, site, en_url if lang == "en" else bn_url, page,
                            faq if page in ("home", "help") else None, crumbs),
        "year": 2026,
    }
    ctx["chips"] = _chips(C, page, group, base, U, groups, ctx["play"])
    ctx["menu"] = _menu(C, page, group, U, groups, ctx["other_url"], ctx["other"])
    if page == "group":
        i = V3.GROUP_IDS.index(group)
        ctx["prev_g"] = groups[i - 1] if i > 0 else None
        ctx["next_g"] = groups[i + 1] if i + 1 < len(groups) else None
    tpl = {"home": "web/v3/home.html", "features": "web/v3/features.html", "group": "web/v3/group.html",
           "pricing": "web/v3/pricing.html", "security": "web/v3/security.html", "help": "web/v3/help.html"}[page]
    html = render_to_string(tpl, ctx, request=request)
    resp = _etag_response(request, html, preview)
    if status != 200 and resp.status_code == 200:
        resp.status_code = status
    return resp


# ----------------------------------------------------- live (switch) routes
def _switch(old_view, page):
    def view(request):
        if is_live():
            return _render(request, page, preview=False)
        return html_cache(request, old_view(request))
    view.__name__ = "v3_" + page
    return view


home = _switch(OLD.home, "home")
pricing = _switch(OLD.pricing, "pricing")
security = _switch(OLD.security, "security")
help_page = _switch(OLD.help_page, "help")


def features_index(request):
    if not is_live():
        raise Http404
    return _render(request, "features", preview=False)


def feature_group(request, gid):
    if gid not in V3.GROUP_IDS or not is_live():
        raise Http404
    return _render(request, "group", preview=False, group=gid)


# ------------------------------------------------------------ preview
def preview(request, page="home"):
    return _render(request, page, preview=True)


def preview_group(request, gid):
    if gid not in V3.GROUP_IDS:
        raise Http404
    return _render(request, "group", preview=True, group=gid)


def sitemap_extra():
    """Paths the sitemap adds once v3 is live (never the preview)."""
    if not is_live():
        return []
    return ["/features"] + ["/features/%s" % g for g in V3.GROUP_IDS]


# ------------------------------------------------------- owner switch
def flip(actor_id, value):
    """Go live (True) / roll back (False) through the audited flags engine.
    The reason is written for the owner, so each is one tap."""
    from core.views_build61 import flags_flip
    reason = "website v3 go-live (owner, Owner Admin → Website)" if value else \
        "website v3 rollback to the previous site (owner, Owner Admin → Website)"
    return flags_flip(actor_id, FLAG, not bool(value), reason)


def download_apk(request):
    """Streams settings.WEBSITE_APK_FILE (only when the owner set one and no
    public URL is configured). The latest-build APK is served by the web
    server at its /dl/ URL instead."""
    from django.conf import settings
    from django.http import FileResponse
    from . import site_v3_dist as DIST
    p = getattr(settings, "WEBSITE_APK_FILE", "")
    if not p or not DIST.apk_info():
        raise Http404
    resp = FileResponse(open(p, "rb"), as_attachment=True, filename="assisto.apk",
                        content_type="application/vnd.android.package-archive")
    resp["Cache-Control"] = "no-cache"
    return resp
