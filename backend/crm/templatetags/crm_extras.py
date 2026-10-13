"""Small template helpers for the CRM web UI."""
from django import template
from django.urls import resolve

register = template.Library()


@register.simple_tag
def active(request, name):
    """Return 'on' when the current URL resolves to the named view (for nav
    highlighting). Safe on any error."""
    try:
        return "on" if resolve(request.path_info).url_name == name else ""
    except Exception:
        return ""


@register.filter
def money(v):
    """Format a number as ৳ with thousands separators, 0 decimals."""
    try:
        return "৳{:,.0f}".format(float(v or 0))
    except (ValueError, TypeError):
        return "৳0"


@register.filter
def get(d, key):
    """Dict lookup by variable key in templates."""
    try:
        return d.get(key)
    except Exception:
        return None
