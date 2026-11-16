"""website: template helpers shared by every public page.

{% load site %}
{% site_asset "favicon.svg" %}          -> /site/favicon.svg?v=<hash>
{% site_abs_asset "og-bn.jpg" %}        -> https://lifeassisto.com/site/og-bn.jpg?v=<hash>
{% site_copy lang as C %}               -> the bn/en word bundle
{% include "web/_icons.html" %}         -> favicon + manifest + theme colour links
"""
from django import template

register = template.Library()


@register.simple_tag
def site_asset(name):
    from web.views_site import asset_url
    return asset_url(name)


@register.simple_tag
def site_abs_asset(name):
    from web.views import _site
    from web.views_site import asset_url
    return _site() + asset_url(name)


@register.simple_tag
def site_copy(lang):
    from web.site_content import COPY
    return COPY.get(lang or "bn", COPY["bn"])


@register.simple_tag
def site_url():
    from web.views import _site
    return _site()


@register.filter
def bn_num(value, lang):
    from web.site_content import bn_digits
    return bn_digits(value) if lang != "en" else value


# seo (17 Nov): self canonical + hreflang for public pages that do not build
# their own `seo` block (cv, scam, festival, made30, khata-free, get), and
# noindex for the shareable result pages (/cv/r, /scam/r). Pages that pass
# `seo` (photo, legal, classic site) or set their own robots meta are left alone.
SHARE_NOINDEX = ("/cv/r", "/scam/r")


@register.simple_tag(takes_context=True)
def auto_seo(context):
    from django.utils.html import format_html
    from web import seo as S
    request = context.get("request")
    if request is None or context.get("seo"):
        return ""
    path = request.path
    if path in SHARE_NOINDEX:
        return format_html('<meta name="robots" content="noindex, follow">')
    if path not in S.PUBLIC_PATHS:
        return ""
    u = S.urls(path, "en" if context.get("lang") == "en" else "bn")
    return format_html(
        '<link rel="canonical" href="{}">\n'
        '<link rel="alternate" hreflang="bn" href="{}">\n'
        '<link rel="alternate" hreflang="en" href="{}">\n'
        '<link rel="alternate" hreflang="x-default" href="{}">',
        u["canonical"], u["alt_bn"], u["alt_en"], u["alt_bn"])
