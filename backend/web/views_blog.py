"""seoblog: public /blog list, /blog/<slug> article, /blog/<slug>/cover.

Strictly one language per URL (bn = bare path, en = ?lang=en), self
canonical + hreflang bn/en/x-default, Article/Blog + BreadcrumbList JSON-LD,
HTML no-cache + ETag (same rule as the v3 site). Unpublished = 404.
"""
from django.http import Http404, HttpResponseRedirect
from django.template.loader import render_to_string

from . import blog as B
from . import views_site as OLD
from .views import _lang, _site
from .views_site3 import _etag_response

L = {
    "bn": {"html_lang": "bn", "blog": "ব্লগ", "home": "হোম", "features": "ফিচার",
           "index_title": "Assisto ব্লগ — বাংলায় কাজের গাইড",
           "index_desc": "পরিবারের নিরাপত্তা, মেস ও দোকানের হিসাব, সিসিটিভি, IELTS, মেট্রো রেল, রাতে নিরাপদ যাত্রা — বাংলাদেশের জন্য বাংলায় সহজ কাজের গাইড।",
           "index_h1": "Assisto ব্লগ", "index_lead": "রোজকার কাজের সহজ গাইড — বাংলাদেশের মানুষের জন্য, সোজা বাংলায়।",
           "read": "পড়ুন", "reviewed": "সর্বশেষ যাচাই", "contents": "এই লেখায়",
           "try": "Assisto-তে চেষ্টা করুন", "try_lead": "এই লেখার কাজটা Assisto অ্যাপে আরও সহজে করা যায়:",
           "all": "সব লেখা", "lang_other": "English", "skip": "মূল লেখায় যান",
           "empty": "শিগগিরই নতুন লেখা আসছে।", "privacy": "গোপনীয়তা", "terms": "শর্তাবলি",
           "about": "আমাদের সম্পর্কে", "help": "সাহায্য", "get": "অ্যাপ নিন",
           "disclaimer": "এই লেখা সাধারণ তথ্যের জন্য; চিকিৎসা, আইন বা আর্থিক সিদ্ধান্তের আগে যোগ্য পেশাদার বা সরকারি উৎসে যাচাই করুন।"},
    "en": {"html_lang": "en", "blog": "Blog", "home": "Home", "features": "Features",
           "index_title": "Assisto Blog — practical guides for Bangladesh",
           "index_desc": "Family safety, mess and shop accounts, CCTV, IELTS, Dhaka metro, safe night travel — practical how-to guides for people in Bangladesh.",
           "index_h1": "Assisto Blog", "index_lead": "Practical everyday guides for people in Bangladesh, in plain words.",
           "read": "Read", "reviewed": "Last reviewed", "contents": "In this article",
           "try": "Try it in Assisto", "try_lead": "Assisto makes the job in this article easier:",
           "all": "All articles", "lang_other": "বাংলা", "skip": "Skip to the article",
           "empty": "New articles are coming soon.", "privacy": "Privacy", "terms": "Terms",
           "about": "About", "help": "Help", "get": "Get the app",
           "disclaimer": "This article is general information; check with a qualified professional or an official source before medical, legal or money decisions."},
}


def _base_ctx(request, lang, path):
    site = _site()
    bn_url, en_url = site + path, site + path + "?lang=en"
    q = "?lang=en" if lang == "en" else ""
    return {
        "lang": lang, "T": L[lang], "q": q, "site": site,
        "seo": {"canonical": en_url if lang == "en" else bn_url, "alt_bn": bn_url, "alt_en": en_url},
        "other_url": path + ("?lang=bn" if lang == "en" else "?lang=en"),
        "og_image": site + OLD.asset_url("og-%s.jpg" % lang),
        "font_bn": OLD.asset_url("noto-sans-bengali-var.woff2"),
        "year": 2026,
        "play": _play(lang),
    }


def _play(lang):
    """seolive: the Google Play badge + link once the app is live on Play
    (same rule as the rest of the site: owner said live AND listing public)."""
    try:
        from . import site_content as SC
        from . import site_v3 as V3
        from . import site_v3_dist as DIST
        if not DIST.play_shown():
            return None
        return {"url": SC.play_url(lang), "badge": OLD.asset_url("google-play-badge-%s.png" % lang),
                "alt": V3.COPY[lang]["cta_play"]}
    except Exception:  # noqa: BLE001 — a blog page never breaks on the Play check
        return None


def blog_index(request):
    redir = OLD._remembered(request)
    if redir:
        return redir
    lang = _lang(request)
    posts = B.published()
    ctx = _base_ctx(request, lang, "/blog")
    T = ctx["T"]
    ctx.update({
        "title": T["index_title"], "desc": T["index_desc"],
        "posts": [{"href": "/blog/%s%s" % (p.slug, ctx["q"]), "title": B.text(p, "title", lang),
                   "summary": B.text(p, "summary", lang),
                   "reviewed": B.date_label(p.last_reviewed, lang),
                   "feature": B.feature_link(p.feature, lang)} for p in posts],
        "jsonld": B.jsonld_index(posts, lang, ctx["site"], ctx["seo"]["canonical"]),
        "og_type": "website",
        # no published post yet -> an empty list must not be indexed
        "noindex": not posts,
    })
    html = render_to_string("web/blog/index.html", ctx, request=request)
    resp = _etag_response(request, html, preview=False)
    if not posts:
        resp["X-Robots-Tag"] = "noindex"
    return resp


def blog_article(request, slug):
    p = B.get_published(slug)
    if p is None:
        raise Http404
    redir = OLD._remembered(request)
    if redir:
        return redir
    lang = _lang(request)
    path = "/blog/%s" % p.slug
    ctx = _base_ctx(request, lang, path)
    body, heads = B.render_markdown(B.text(p, "body", lang))
    cover = B.cover_path(p)
    image = (ctx["site"] + cover) if cover else ctx["og_image"]
    others = [o for o in B.published() if o.pk != p.pk][:3]
    ctx.update({
        "title": B.text(p, "title", lang) + " — Assisto", "h1": B.text(p, "title", lang),
        "desc": B.text(p, "summary", lang), "body": body, "heads": heads if len(heads) >= 3 else [],
        "cover": cover, "cover_alt": B.text(p, "cover_alt", lang) or B.text(p, "title", lang),
        "og_image": image, "og_type": "article",
        "reviewed": B.date_label(p.last_reviewed, lang),
        "reviewed_iso": p.last_reviewed.isoformat() if p.last_reviewed else "",
        "feature": B.feature_link(p.feature, lang),
        "others": [{"href": "/blog/%s%s" % (o.slug, ctx["q"]), "title": B.text(o, "title", lang)} for o in others],
        "jsonld": B.jsonld_article(p, lang, ctx["site"], ctx["seo"]["canonical"], image),
    })
    html = render_to_string("web/blog/article.html", ctx, request=request)
    return _etag_response(request, html, preview=False)


def blog_cover(request, slug):
    """A stable public URL for a published post's cover (pages, og:image,
    JSON-LD) -> 302 to the short-lived signed media link."""
    p = B.get_published(slug)
    if p is None or not p.cover:
        raise Http404
    from core.media_sign import signed_url
    resp = HttpResponseRedirect(signed_url(p.cover.name))
    resp["Cache-Control"] = "public, max-age=1800"
    return resp
