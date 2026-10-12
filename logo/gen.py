#!/usr/bin/env python3
"""Generate 3 Assisto logo options (open palm holding a glowing AI brain)."""
import math, os

S = 1024
CX = S / 2

# ---------- palette ----------
NAVY_TOP = "#0A1A3D"
NAVY_BOT = "#14336E"
GOLD1 = "#FFE08A"
GOLD2 = "#E7A32E"
CYAN_CORE = "#AEF2FF"
CYAN_MID = "#58D7F5"
CYAN_DEEP = "#1E9BD6"
CIRCUIT = "#DAF8FF"


def brain_path(cx, cy, R, lobes=9, amp=0.12, squash=0.86, rot=0.0):
    """Lumpy closed path (brain-like) via radius modulated by a sine."""
    pts = []
    n = 240
    for i in range(n + 1):
        t = 2 * math.pi * i / n
        r = R * (1 + amp * math.sin(lobes * t + rot) + 0.04 * math.sin(2 * t))
        x = cx + r * math.cos(t)
        y = cy + r * squash * math.sin(t)
        pts.append((x, y))
    d = "M {:.1f} {:.1f} ".format(*pts[0])
    for p in pts[1:]:
        d += "L {:.1f} {:.1f} ".format(*p)
    return d + "Z"


def gyri(cx, cy, R, squash=0.86):
    """A few internal curved lines suggesting brain folds + a center crease."""
    paths = []
    # center crease
    paths.append(
        f"M {cx:.0f} {cy-R*squash*0.82:.0f} "
        f"C {cx-R*0.12:.0f} {cy-R*0.2:.0f} {cx+R*0.12:.0f} {cy+R*0.2:.0f} "
        f"{cx:.0f} {cy+R*squash*0.8:.0f}"
    )
    # side folds
    for s in (-1, 1):
        paths.append(
            f"M {cx+s*R*0.28:.0f} {cy-R*0.42:.0f} "
            f"q {s*R*0.22:.0f} {R*0.12:.0f} {s*R*0.04:.0f} {R*0.42:.0f}"
        )
        paths.append(
            f"M {cx+s*R*0.5:.0f} {cy-R*0.05:.0f} "
            f"q {s*R*0.16:.0f} {R*0.14:.0f} {-s*R*0.04:.0f} {R*0.34:.0f}"
        )
    return paths


def circuit(cx, cy, R, squash, nodes):
    """Small glowing nodes + thin lines to centre (subtle circuitry)."""
    out = []
    for ang_deg, rr in nodes:
        a = math.radians(ang_deg)
        x = cx + R * rr * math.cos(a)
        y = cy + R * squash * rr * math.sin(a)
        out.append(
            f'<line x1="{cx:.0f}" y1="{cy:.0f}" x2="{x:.0f}" y2="{y:.0f}" '
            f'stroke="{CIRCUIT}" stroke-width="3.5" opacity="0.5"/>'
        )
        out.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="9" fill="{CIRCUIT}"/>')
    out.append(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="12" fill="{CIRCUIT}"/>')
    return "\n".join(out)


def cupped_hand(cx, baseY, width, fingers=5, spread=1.0, curl=1.0, lift=1.0):
    """Gold cupped palm: a bowl + fanned, inward-curving fingers (round strokes)."""
    half = width / 2
    # bowl (lower palm) — a smile curve
    bowl = (
        f"M {cx-half:.0f} {baseY-70:.0f} "
        f"C {cx-half*0.7:.0f} {baseY+120:.0f} {cx+half*0.7:.0f} {baseY+120:.0f} "
        f"{cx+half:.0f} {baseY-70:.0f}"
    )
    strokes = [bowl]
    # fingers fan from the rim, curving inward at the tips
    for i in range(fingers):
        f = (i - (fingers - 1) / 2) / max(1, (fingers - 1) / 2)  # -1..1
        rx = cx + f * half * 0.92 * spread
        ry = baseY - 60 - abs(f) * 20  # rim slightly higher at edges
        tipx = cx + f * half * 0.55        # curl inward
        tipy = baseY - (250 + (1 - abs(f)) * 60) * lift
        cx1 = rx + f * 20
        cy1 = ry - 120
        cx2 = tipx + f * 30 * curl
        cy2 = tipy + 60
        strokes.append(
            f"M {rx:.0f} {ry:.0f} C {cx1:.0f} {cy1:.0f} {cx2:.0f} {cy2:.0f} {tipx:.0f} {tipy:.0f}"
        )
    # thumb (short, to the left)
    strokes.append(
        f"M {cx-half*0.95:.0f} {baseY-40:.0f} C {cx-half*1.15:.0f} {baseY-120:.0f} "
        f"{cx-half*0.8:.0f} {baseY-200:.0f} {cx-half*0.45:.0f} {baseY-210:.0f}"
    )
    return strokes


def svg_header(bg_variant=0):
    if bg_variant == 2:
        bg = f'''<radialGradient id="bg" cx="50%" cy="38%" r="75%">
      <stop offset="0%" stop-color="#17386F"/>
      <stop offset="100%" stop-color="{NAVY_TOP}"/>
    </radialGradient>'''
    else:
        bg = f'''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{NAVY_TOP}"/>
      <stop offset="100%" stop-color="{NAVY_BOT}"/>
    </linearGradient>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    {bg}
    <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{GOLD1}"/>
      <stop offset="100%" stop-color="{GOLD2}"/>
    </linearGradient>
    <radialGradient id="brainfill" cx="50%" cy="42%" r="60%">
      <stop offset="0%" stop-color="{CYAN_CORE}"/>
      <stop offset="55%" stop-color="{CYAN_MID}"/>
      <stop offset="100%" stop-color="{CYAN_DEEP}"/>
    </radialGradient>
    <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="22" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="softglow" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="40"/>
    </filter>
  </defs>
'''


def compose(fg, bg_variant=0, rounded=True):
    clip = ''
    body = svg_header(bg_variant)
    if rounded:
        body += f'  <clipPath id="rc"><rect x="0" y="0" width="{S}" height="{S}" rx="224" ry="224"/></clipPath>\n'
        body += '  <g clip-path="url(#rc)">\n'
    body += f'    <rect x="0" y="0" width="{S}" height="{S}" fill="url(#bg)"/>\n'
    body += fg
    if rounded:
        body += '  </g>\n'
    body += '</svg>\n'
    return body


def brain_group(cx, cy, R, lobes, amp, squash, nodes, rot=0.0):
    folds = "".join(
        f'<path d="{d}" fill="none" stroke="{CYAN_DEEP}" stroke-width="7" '
        f'stroke-linecap="round" opacity="0.65"/>' for d in gyri(cx, cy, R, squash)
    )
    bp = brain_path(cx, cy, R, lobes, amp, squash, rot)
    return f'''
    <g filter="url(#glow)">
      <ellipse cx="{cx}" cy="{cy}" rx="{R*1.25:.0f}" ry="{R*squash*1.25:.0f}" fill="{CYAN_MID}" opacity="0.28" filter="url(#softglow)"/>
      <path d="{bp}" fill="url(#brainfill)" stroke="{CYAN_CORE}" stroke-width="6"/>
      {folds}
      {circuit(cx, cy, R, squash, nodes)}
    </g>'''


def hand_group(strokes, w=34):
    s = "".join(
        f'<path d="{d}" fill="none" stroke="url(#gold)" stroke-width="{w}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>' for d in strokes
    )
    # soft gold under-glow
    return f'<g>{s}</g>'


os.makedirs("/home/ubuntu/assisto/logo/out", exist_ok=True)


def write(name, svg):
    p = f"/home/ubuntu/assisto/logo/out/{name}.svg"
    open(p, "w").write(svg)
    return p


# ---------- Option A: symmetric, centered palm, brain orb above ----------
a_hand = cupped_hand(CX, 720, 520, fingers=5, spread=1.0, curl=1.0, lift=1.0)
a_brain = brain_group(CX, 430, 150, lobes=9, amp=0.13, squash=0.9,
                      nodes=[(35,0.9),(145,0.88),(90,0.95),(-30,0.85),(210,0.86),(330,0.8)])
write("optA", compose(hand_group(a_hand) + a_brain, bg_variant=0))

# ---------- Option B: dynamic, tilted single palm lifting brain ----------
b_hand = cupped_hand(CX-20, 740, 470, fingers=4, spread=1.15, curl=1.4, lift=1.15)
b_brain = brain_group(CX+40, 410, 140, lobes=8, amp=0.16, squash=0.82, rot=0.5,
                      nodes=[(20,0.95),(70,0.88),(120,0.92),(160,0.85),(300,0.9),(240,0.8)])
write("optB", compose(hand_group(b_hand, w=30) + b_brain, bg_variant=1))

# ---------- Option C: minimal, bold, best when tiny ----------
c_hand = cupped_hand(CX, 700, 540, fingers=3, spread=0.9, curl=0.7, lift=0.8)
c_brain = brain_group(CX, 440, 158, lobes=7, amp=0.10, squash=0.95,
                      nodes=[(50,0.9),(130,0.9),(-50,0.86),(230,0.86)])
write("optC", compose(hand_group(c_hand, w=42) + c_brain, bg_variant=2))

print("wrote optA/optB/optC svg")
