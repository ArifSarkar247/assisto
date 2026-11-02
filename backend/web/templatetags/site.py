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
