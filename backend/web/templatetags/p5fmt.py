"""p5-growth: number display for the owner funnel — Bangla digits in the bn
page, '—' for "not measurable yet" (None)."""
from django import template

register = template.Library()

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


@register.filter
def bnd(value, lang="bn"):
    if value is None or value == "":
        return "—"
    if isinstance(value, float):
        s = ("%.2f" % value).rstrip("0").rstrip(".") if value % 1 else "%d" % value
    else:
        s = str(value)
    return s.translate(_BN) if lang == "bn" else s
