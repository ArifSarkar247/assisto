"""Tiny server-side SVG charts (no JS, CSP-safe). Bars anchored at the
baseline, one y-axis, recessive grid, native <title> tooltips per mark.
Series colours come from CSS classes (owner.css) so text never wears them."""
from html import escape


def _nice_max(v):
    if v <= 0:
        return 1
    import math
    mag = 10 ** int(math.floor(math.log10(v)))
    for m in (1, 2, 2.5, 5, 10):
        if v <= m * mag:
            return m * mag
    return 10 * mag


def _fmt(v):
    if abs(v) >= 1000:
        return "{:,.0f}".format(v)
    return ("%.2f" % v).rstrip("0").rstrip(".") if v != int(v) else str(int(v))


def bars(labels, series, height=220, unit=""):
    """labels: [str]; series: [(name, css_class, [values])] (1-2 series,
    grouped). Returns SVG markup, or '' when there is nothing to draw."""
    if not labels or not series:
        return ""
    vals = [v for _, _, vs in series for v in vs]
    if not vals:
        return ""
    vmax = _nice_max(max(max(vals), 0))
    vmin = min(0, min(vals))
    n, k = len(labels), len(series)
    left, right, top, bottom = 56, 12, 10, 34
    slot = max(10, min(48, 900 // max(1, n)))
    width = left + right + slot * n
    ph = height - top - bottom
    span = (vmax - vmin) or 1

    def y(v):
        return top + ph * (vmax - v) / span

    out = ['<svg xmlns="http://www.w3.org/2000/svg" class="chart" viewBox="0 0 %d %d" '
           'width="%d" height="%d" role="img">' % (width, height, width, height)]
    for i in range(5):
        gv = vmin + span * i / 4
        gy = y(gv)
        out.append('<line class="grid" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>'
                   % (left, width - right, gy, gy))
        out.append('<text class="axis" x="%d" y="%.1f" text-anchor="end">%s%s</text>'
                   % (left - 6, gy + 4, escape(unit), _fmt(gv)))
    bw = max(3, (slot - 6) / k - 2)
    for j, (name, cls, vs) in enumerate(series):
        for i, v in enumerate(vs):
            x = left + slot * i + 3 + j * (bw + 2)
            y0, y1 = y(max(v, 0)), y(min(v, 0))
            h = max(0.0, y1 - y0)
            out.append('<rect class="%s" x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2">'
                       '<title>%s · %s: %s%s</title></rect>'
                       % (cls, x, y0, bw, h, escape(labels[i]), escape(name),
                          escape(unit), _fmt(v)))
    step = max(1, n // 10)
    for i in range(0, n, step):
        out.append('<text class="axis" x="%.1f" y="%d" text-anchor="middle">%s</text>'
                   % (left + slot * i + slot / 2, height - 12, escape(labels[i][-5:])))
    out.append('<line class="base" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>'
               % (left, width - right, y(0), y(0)))
    out.append("</svg>")
    return "".join(out)


def meter(pct):
    """A 0-100 horizontal meter as SVG (width via attribute, not style)."""
    p = max(0.0, min(100.0, float(pct or 0)))
    return ('<svg xmlns="http://www.w3.org/2000/svg" class="meter" viewBox="0 0 100 6" '
            'preserveAspectRatio="none" width="100%%" height="6"><rect class="track" '
            'width="100" height="6" rx="3"/><rect class="fill" width="%.1f" height="6" '
            'rx="3"/></svg>' % p)
