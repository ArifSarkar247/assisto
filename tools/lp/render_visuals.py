#!/usr/bin/env python3
"""Render bundle visuals (Writing Task 1 charts, Listening maps) to SVG. Stdlib only.

    python3 tools/lp/render_visuals.py --out out/visuals [bundle.json ...]

File names: <bundle>-W1.svg (Writing Task 1), <bundle>-L<first question>.svg (Listening map).
CI converts them to PNG with rsvg-convert for lpcore (img/). Black on white, exam style, large text.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
from xml.sax.saxutils import escape

W, H = 900, 560
FONT = 'font-family="DejaVu Sans, Arial, sans-serif"'
DASH = ["", "8,5", "2,4", "12,4,2,4", "4,4"]
GREYS = ["#111", "#555", "#888", "#bbb", "#333", "#777"]
HATCH = ["#222", "#666", "#999", "#ccc", "#444", "#aaa"]


def t(x, y, s, size=16, anchor="middle", weight="normal", rot=None):
    tr = f' transform="rotate({rot} {x} {y})"' if rot else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" text-anchor="{anchor}" '
            f'font-weight="{weight}" {FONT}{tr}>{escape(str(s))}</text>')


def nice_max(v):
    if v <= 0:
        return 1
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if m * e >= v:
            return m * e
    return 10 * e


def axes_chart(v):
    kind = v["kind"]
    cats, series = v["categories"], v["series"]
    x0, y0, x1, y1 = 90, 70, W - 200, H - 80
    vmax = nice_max(max(max(s["values"]) for s in series))
    out = [t(W / 2, 35, v.get("title", ""), 19, weight="bold")]
    for i in range(6):
        val = vmax * i / 5
        y = y1 - (y1 - y0) * i / 5
        out.append(f'<line x1="{x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}" stroke="#ddd"/>')
        lab = f"{val:g}" if val == int(val) else f"{val:.1f}"
        out.append(t(x0 - 8, y + 5, lab, 14, "end"))
    out.append(f'<line x1="{x0}" y1="{y1}" x2="{x1}" y2="{y1}" stroke="#000"/>')
    out.append(f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{y1}" stroke="#000"/>')
    n = len(cats)
    step = (x1 - x0) / n
    for i, c in enumerate(cats):
        out.append(t(x0 + step * (i + 0.5), y1 + 22, c, 14))
    if v.get("x_label"):
        out.append(t((x0 + x1) / 2, H - 25, v["x_label"], 15))
    if v.get("y_label"):
        out.append(t(28, (y0 + y1) / 2, v["y_label"], 15, rot=-90))
    for si, s in enumerate(series):
        if kind == "line":
            pts = [(x0 + step * (i + 0.5), y1 - (y1 - y0) * val / vmax) for i, val in enumerate(s["values"])]
            d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
            out.append(f'<polyline points="{d}" fill="none" stroke="{GREYS[si % 6]}" stroke-width="3" '
                       f'stroke-dasharray="{DASH[si % 5]}"/>')
            for x, y in pts:
                out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{GREYS[si % 6]}"/>')
        else:
            bw = step * 0.8 / len(series)
            for i, val in enumerate(s["values"]):
                x = x0 + step * i + step * 0.1 + bw * si
                h = (y1 - y0) * val / vmax
                out.append(f'<rect x="{x:.1f}" y="{y1 - h:.1f}" width="{bw:.1f}" height="{h:.1f}" '
                           f'fill="{HATCH[si % 6]}" stroke="#000" stroke-width="0.6"/>')
        ly = y0 + 10 + si * 28
        if kind == "line":
            out.append(f'<line x1="{x1 + 20}" y1="{ly}" x2="{x1 + 55}" y2="{ly}" stroke="{GREYS[si % 6]}" '
                       f'stroke-width="3" stroke-dasharray="{DASH[si % 5]}"/>')
        else:
            out.append(f'<rect x="{x1 + 20}" y="{ly - 9}" width="30" height="16" fill="{HATCH[si % 6]}" stroke="#000"/>')
        out.append(t(x1 + 62, ly + 5, s["name"], 14, "start"))
    if v.get("unit"):
        out.append(t(x0, y0 - 14, v["unit"], 13, "start"))
    return out


def pie(v):
    charts = v["charts"]
    out = [t(W / 2, 35, v.get("title", ""), 19, weight="bold")]
    n = len(charts)
    r = min(150, (W - 60) / n / 2 - 20)
    for ci, ch in enumerate(charts):
        cx = (W / n) * (ci + 0.5)
        cy = 250
        a0 = -math.pi / 2
        for si, s in enumerate(ch["slices"]):
            a1 = a0 + 2 * math.pi * s["value"] / 100
            large = 1 if a1 - a0 > math.pi else 0
            p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
            p1 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
            out.append(f'<path d="M{cx:.1f},{cy:.1f} L{p0[0]:.1f},{p0[1]:.1f} A{r:.1f},{r:.1f} 0 {large} 1 '
                       f'{p1[0]:.1f},{p1[1]:.1f} Z" fill="{HATCH[si % 6]}" stroke="#fff" stroke-width="2"/>')
            am = (a0 + a1) / 2
            out.append(t(cx + r * 0.65 * math.cos(am), cy + r * 0.65 * math.sin(am) + 5,
                         f"{s['value']:g}%", 13, weight="bold"))
            a0 = a1
        out.append(t(cx, cy + r + 30, ch.get("label", ""), 16, weight="bold"))
    names = [s["name"] for s in charts[0]["slices"]]
    for si, nm in enumerate(names):
        x = 60 + (si % 3) * 270
        y = H - 70 + (si // 3) * 26
        out.append(f'<rect x="{x}" y="{y - 12}" width="18" height="14" fill="{HATCH[si % 6]}"/>')
        out.append(t(x + 26, y, nm, 14, "start"))
    return out


def table(v):
    cols, rows = v["columns"], v["rows"]
    out = [t(W / 2, 35, v.get("title", ""), 19, weight="bold")]
    cw = (W - 80) / len(cols)
    rh = min(44, (H - 100) / (len(rows) + 1))
    for j, c in enumerate(cols):
        out.append(f'<rect x="{40 + j * cw:.1f}" y="60" width="{cw:.1f}" height="{rh:.1f}" fill="#e6e6e6" stroke="#000"/>')
        out.append(t(40 + j * cw + cw / 2, 60 + rh / 2 + 5, c, 14, weight="bold"))
    for i, r in enumerate(rows):
        y = 60 + rh * (i + 1)
        for j, c in enumerate(r):
            out.append(f'<rect x="{40 + j * cw:.1f}" y="{y:.1f}" width="{cw:.1f}" height="{rh:.1f}" fill="#fff" stroke="#000"/>')
            out.append(t(40 + j * cw + cw / 2, y + rh / 2 + 5, c, 14))
    return out


def process(v):
    steps = v["steps"]
    out = [t(W / 2, 35, v.get("title", ""), 19, weight="bold")]
    per_row = 4
    bw, bh = 180, 70
    for i, s in enumerate(steps):
        row, col = divmod(i, per_row)
        if row % 2:
            col = per_row - 1 - col
        x = 40 + col * 215
        y = 80 + row * 130
        out.append(f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" rx="10" fill="#f4f4f4" stroke="#000"/>')
        words = s.split()
        lines, cur = [], ""
        for w in words:
            if len(cur) + len(w) > 20:
                lines.append(cur)
                cur = w
            else:
                cur = (cur + " " + w).strip()
        lines.append(cur)
        for k, ln in enumerate(lines[:3]):
            out.append(t(x + bw / 2, y + 26 + k * 18, ln, 13))
        out.append(t(x + 14, y + 16, str(i + 1), 12, weight="bold"))
    return out


def map_one(m, ox, oy, scale, title=None):
    out = []
    if title:
        out.append(t(ox + m.get("width", 100) * scale / 2, oy - 10, title, 16, weight="bold"))
    out.append(f'<rect x="{ox}" y="{oy}" width="{m.get("width", 100) * scale:.1f}" '
               f'height="{m.get("height", 70) * scale:.1f}" fill="#fff" stroke="#000" stroke-width="2"/>')
    for a in m.get("areas", []):
        out.append(f'<rect x="{ox + a["x"] * scale:.1f}" y="{oy + a["y"] * scale:.1f}" '
                   f'width="{a["w"] * scale:.1f}" height="{a["h"] * scale:.1f}" fill="#efefef" stroke="#333"/>')
        out.append(t(ox + (a["x"] + a["w"] / 2) * scale, oy + (a["y"] + a["h"] / 2) * scale + 5,
                     a["name"], 13))
    for lb in m.get("labels", []):
        cx, cy = ox + lb["x"] * scale, oy + lb["y"] * scale
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="13" fill="#fff" stroke="#000" stroke-width="2"/>')
        out.append(t(cx, cy + 5, lb["key"], 14, weight="bold"))
    if m.get("compass"):
        cx, cy = ox + m.get("width", 100) * scale - 25, oy + 35
        out.append(f'<path d="M{cx},{cy - 22} L{cx - 8},{cy} L{cx + 8},{cy} Z" fill="#000"/>')
        out.append(t(cx, cy + 18, "N", 14, weight="bold"))
    return out


def map_v(v):
    out = [t(W / 2, 30, v.get("title", ""), 19, weight="bold")]
    maps = v.get("maps", [v])
    n = len(maps)
    for i, m in enumerate(maps):
        scale = min((W - 40 * (n + 1)) / n / m.get("width", 100), (H - 110) / m.get("height", 70))
        out += map_one(m, 40 + i * ((W - 40) / n), 70, scale, m.get("label"))
    return out


def svg(v):
    k = v["kind"]
    body = {"line": axes_chart, "bar": axes_chart, "pie": pie, "table": table,
            "process": process, "map": map_v}[k](v)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
            f'<rect width="{W}" height="{H}" fill="#fff"/>' + "".join(body) + "</svg>")


def visuals(b):
    for tk in b.get("writing", {}).get("tasks", []) if isinstance(b.get("writing"), dict) else []:
        if isinstance(tk.get("visual"), dict):
            yield f"{b['bundle_id']}-W{tk['task']}", tk["visual"]
    for p in b.get("listening", {}).get("parts", []) if isinstance(b.get("listening"), dict) else []:
        for g in p.get("groups", []):
            if isinstance(g.get("visual"), dict):
                yield f"{b['bundle_id']}-L{g['range'][0]}", g["visual"]
    for p in b.get("reading", {}).get("parts", []) if isinstance(b.get("reading"), dict) else []:
        for g in p.get("groups", []):
            if isinstance(g.get("visual"), dict):
                yield f"{b['bundle_id']}-R{g['range'][0]}", g["visual"]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("bundles", nargs="*")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    here = os.path.dirname(os.path.abspath(__file__))
    paths = a.bundles or sorted(glob.glob(os.path.join(here, "content", "*", "ielts-*-[0-9][0-9][0-9].json")))
    os.makedirs(a.out, exist_ok=True)
    n = 0
    for p in paths:
        b = json.load(open(p, encoding="utf-8"))
        for name, v in visuals(b):
            with open(os.path.join(a.out, name + ".svg"), "w", encoding="utf-8") as f:
                f.write(svg(v))
            n += 1
    print(f"{n} visuals rendered")


if __name__ == "__main__":
    main()
