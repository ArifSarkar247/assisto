#!/usr/bin/env python3
"""Final Assisto logo: open gold hands cupping a glowing cyan AI brain."""
import math, os

S = 1024
CX = S / 2
NAVY_TOP = "#0A1A3D"
NAVY_MID = "#14336E"
GOLD1 = "#FFE69A"
GOLD2 = "#E7A32E"
CYAN_CORE = "#D6FAFF"
CYAN_MID = "#5FD8F5"
CYAN_DEEP = "#1E9BD6"
CIRCUIT = "#EAFCFF"

OUT = "/home/ubuntu/assisto/logo/out"
os.makedirs(OUT, exist_ok=True)


# ---------------- brain ----------------
def brain_path(cx, cy, R, lobes=8, amp=0.06, squash=0.98):
    pts, n = [], 260
    for i in range(n + 1):
        t = 2 * math.pi * i / n
        # rounder top, slightly flatter bottom
        flat = 1.0 - 0.10 * max(0.0, math.sin(t))
        r = R * (1 + amp * math.sin(lobes * t + 1.2)) * flat
        pts.append((cx + r * math.cos(t), cy - r * squash * math.sin(t)))
    d = "M {:.1f} {:.1f} ".format(*pts[0])
    for p in pts[1:]:
        d += "L {:.1f} {:.1f} ".format(*p)
    return d + "Z"


def gyri(cx, cy, R, squash):
    p = []
    # central fissure
    p.append(f"M {cx:.0f} {cy-R*squash*0.72:.0f} "
             f"C {cx-R*0.14:.0f} {cy-R*0.25:.0f} {cx+R*0.14:.0f} {cy+R*0.2:.0f} "
             f"{cx:.0f} {cy+R*squash*0.72:.0f}")
    for s in (-1, 1):
        p.append(f"M {cx+s*R*0.22:.0f} {cy-R*0.46:.0f} "
                 f"q {s*R*0.26:.0f} {R*0.10:.0f} {s*R*0.10:.0f} {R*0.40:.0f}")
        p.append(f"M {cx+s*R*0.46:.0f} {cy-R*0.12:.0f} "
                 f"q {s*R*0.18:.0f} {R*0.12:.0f} {-s*R*0.02:.0f} {R*0.34:.0f}")
    return p


def circuit(cx, cy, R, squash, nodes):
    o = [f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="11" fill="{CIRCUIT}"/>']
    for ang, rr in nodes:
        a = math.radians(ang)
        x, y = cx + R * rr * math.cos(a), cy - R * squash * rr * math.sin(a)
        o.append(f'<line x1="{cx:.0f}" y1="{cy:.0f}" x2="{x:.0f}" y2="{y:.0f}" '
                 f'stroke="{CIRCUIT}" stroke-width="3.5" opacity="0.55"/>')
        o.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="8.5" fill="{CIRCUIT}"/>')
    return "\n".join(o)


# ---------------- hands ----------------
def palm_cup():
    """Open U-shaped cupped palm (open at the top where the brain rests)."""
    return (f"M {CX-250:.0f} 560 "
            f"C {CX-300:.0f} 770 {CX+300:.0f} 770 {CX+250:.0f} 560")


def fingers(side):
    """Three smooth fingers per side, fanning up and curling inward."""
    out = []
    for j in range(3):
        sx = CX + side * (238 - j * 52)
        sy = 548 - j * 6
        tx = CX + side * (168 - j * 78)
        ty = 436 - j * 54
        c1x, c1y = sx + side * 8, sy - 130
        c2x, c2y = tx + side * 40, ty + 72
        out.append(f"M {sx:.0f} {sy:.0f} C {c1x:.0f} {c1y:.0f} {c2x:.0f} {c2y:.0f} {tx:.0f} {ty:.0f}")
    return out


def hand_paths():
    return [palm_cup()] + fingers(-1) + fingers(1)


DEFS = f'''<defs>
  <radialGradient id="bg" cx="50%" cy="40%" r="75%">
    <stop offset="0%" stop-color="#1A3C74"/><stop offset="100%" stop-color="{NAVY_TOP}"/>
  </radialGradient>
  <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="{GOLD1}"/><stop offset="100%" stop-color="{GOLD2}"/>
  </linearGradient>
  <radialGradient id="bf" cx="50%" cy="42%" r="62%">
    <stop offset="0%" stop-color="{CYAN_CORE}"/><stop offset="55%" stop-color="{CYAN_MID}"/>
    <stop offset="100%" stop-color="{CYAN_DEEP}"/>
  </radialGradient>
  <filter id="glow" x="-70%" y="-70%" width="240%" height="240%">
    <feGaussianBlur stdDeviation="20" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="soft" x="-90%" y="-90%" width="280%" height="280%"><feGaussianBlur stdDeviation="46"/></filter>
  <clipPath id="rc"><rect width="{S}" height="{S}" rx="224" ry="224"/></clipPath>
</defs>'''


def mark(cx=CX, cy=450, R=150, sq=0.98):
    """The hands + glowing brain (no background)."""
    nodes = [(55, 0.88), (125, 0.88), (90, 0.5)]
    folds = "".join(f'<path d="{d}" fill="none" stroke="{CYAN_DEEP}" '
                    f'stroke-width="7" stroke-linecap="round" opacity="0.6"/>'
                    for d in gyri(cx, cy, R, sq))
    hands = "".join(f'<path d="{d}" fill="none" stroke="url(#gold)" '
                    f'stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/>'
                    for d in hand_paths())
    return f'''
  <ellipse cx="{cx}" cy="{cy}" rx="{R*1.35:.0f}" ry="{R*1.3:.0f}" fill="{CYAN_MID}" opacity="0.30" filter="url(#soft)"/>
  {hands}
  <g filter="url(#glow)">
    <path d="{brain_path(cx, cy, R, 8, 0.06, sq)}" fill="url(#bf)" stroke="{CYAN_CORE}" stroke-width="5"/>
    {folds}
    {circuit(cx, cy, R, sq, nodes)}
  </g>'''


def wrap(inner, clip=True):
    g = f'<g clip-path="url(#rc)">' if clip else '<g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">{DEFS}{g}{inner}</g></svg>\n')


# 1) composed icon (navy + mark), rounded square — launcher legacy + login/splash
open(f"{OUT}/final.svg", "w").write(
    wrap(f'<rect width="{S}" height="{S}" fill="url(#bg)"/>' + mark()))

# 2) adaptive background layer: full-bleed navy (no rounding, launcher masks it)
open(f"{OUT}/bg.svg", "w").write(
    wrap(f'<rect width="{S}" height="{S}" fill="url(#bg)"/>', clip=False))

# 3) adaptive foreground: transparent, mark scaled into the center safe zone (~66%)
fg_inner = f'<g transform="translate(512 512) scale(0.66) translate(-512 -500)">{mark()}</g>'
open(f"{OUT}/fg.svg", "w").write(wrap(fg_inner, clip=False))

print("wrote final.svg, bg.svg, fg.svg")
