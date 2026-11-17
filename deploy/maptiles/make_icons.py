"""Write Assisto's own map icons (CC0, drawn here, no third-party art) as SVG for spreet.

    python make_icons.py OUT_DIR   -> OUT_DIR/light/*.svg, OUT_DIR/night/*.svg
Each icon: 17x17 px disc in a category colour + a white pictogram made only of paths
(no <text>, so it renders the same without system fonts).
"""
import os
import sys

# name: (category, pictogram path in a 17x17 box)
ICONS = {
    "metro": ("transit", "M4.5 12V5h1.6l2.4 3.6L10.4 5H12v7h-1.5V7.6L8 11.2 5.9 7.6V12z"),
    "rail": ("transit", "M5 4h7a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zm0 2v2.5h7V6zm1 4.2a.8.8 0 1 0 0 1.6.8.8 0 0 0 0-1.6zm5 0a.8.8 0 1 0 0 1.6.8.8 0 0 0 0-1.6zM5 12.5h1.6L5.8 14H4.4zm5.4 0H12l.6 1.5h-1.4z"),
    "bus": ("transit", "M5 3.5h7a1.5 1.5 0 0 1 1.5 1.5v7.5h-1v1.2h-1.6v-1.2H6.1v1.2H4.5v-1.2h-1V5A1.5 1.5 0 0 1 5 3.5zm0 2v3.2h7V5.5zm.7 4.7a.8.8 0 1 0 0 1.6.8.8 0 0 0 0-1.6zm5.6 0a.8.8 0 1 0 0 1.6.8.8 0 0 0 0-1.6z"),
    "ferry": ("transit", "M7.7 3.5h1.6v2H12v3.3l1.6.6-1.4 3.1H4.8L3.4 9.4 5 8.8V5.5h2.7zM6.3 6.8v1.5l2.2-.8 2.2.8V6.8zM3.5 13.4c1 .7 2 .7 3 0 1 .7 2 .7 3 0 1 .7 2 .7 3 0l.6.9c-1.2.8-2.4.8-3.6.2-1.2.6-2.4.6-3.6 0-1.2.6-2.4.6-3.6-.2z"),
    "airport": ("transit", "M8.5 2.8c.6 0 1 .5 1 1.1v3.4l4.2 2.5v1.4L9.5 9.9v2.4l1.4 1v1.1l-2.4-.7-2.4.7v-1.1l1.4-1V9.9l-4.2 1.3V9.8l4.2-2.5V3.9c0-.6.4-1.1 1-1.1z"),
    "hospital": ("health", "M7 3.5h3v3.5h3.5v3H10v3.5H7V10H3.5V7H7z"),
    "pharmacy": ("health", "M10.6 3.6a2.6 2.6 0 0 1 3.7 3.7l-6.9 6.9a2.6 2.6 0 0 1-3.7-3.7zm-3.4 3.4L5 9.2a1.2 1.2 0 0 0 1.7 1.7l2.2-2.2z"),
    "police": ("safety", "M8.5 2.8l5 1.9v3.6c0 3-2.1 5.4-5 6.4-2.9-1-5-3.4-5-6.4V4.7zm0 2.4-1 2.1-2.2.3 1.6 1.6-.4 2.2 2-1.1 2 1.1-.4-2.2 1.6-1.6-2.2-.3z"),
    "fire_station": ("safety", "M8.6 2.8c.4 2 2.8 3.2 2.8 6.3a3 3 0 0 1-.8 2.1c.1-1.5-.6-2.5-1.7-3.3.1 1.4-.5 2.4-1.5 3-.6-.4-.9-1.1-.8-1.9-.9.8-1.3 1.7-1 3a3.9 3.9 0 0 1-2.5-3.7c0-3 3.6-4 5.5-5.5zM4.5 13h8v1.3h-8z"),
    "mosque": ("worship", "M8.5 3.2c.3 1 2.6 2 2.6 4.1H5.9c0-2.1 2.3-3.1 2.6-4.1zM5.5 8.2h6v5.3H9.6v-2.3a1.1 1.1 0 0 0-2.2 0v2.3H5.5zM3 6.3h1.2v7.2H3zm9.8 0H14v7.2h-1.2z"),
    "temple": ("worship", "M8.5 2.8l1.2 2.4h-.5l1.6 2.6H10l2 3H11v2.7H6v-2.7H5l2-3h-.8l1.6-2.6h-.5z"),
    "church": ("worship", "M8 2.8h1v1.4h1.3v1H9v1.6l3 2.2v4.5H5V9l3-2.2V5.2H6.7v-1H8z"),
    "school": ("education", "M8.5 3.5 15 6.6l-6.5 3.1L2 6.6zm-4 4.4 4 1.9 4-1.9v2.9c0 1.2-1.8 2.2-4 2.2s-4-1-4-2.2zm9.4-.8h.8v4h-.8z"),
    "university": ("education", "M8.5 3 14 5.5v1H3v-1zM4 7.3h1.4v4.4H4zm2.8 0h1.4v4.4H6.8zm2.8 0H11v4.4H9.6zm2.8 0h.6v4.4h-1.4V7.3zM3 12.4h11v1.4H3z"),
    "park": ("park", "M8.5 2.8a3.6 3.6 0 0 1 3.5 4.4 3 3 0 0 1-1.6 5.3H9.2v1.8H7.8v-1.8H6.6A3 3 0 0 1 5 7.2a3.6 3.6 0 0 1 3.5-4.4z"),
    "fuel": ("service", "M4.5 3.5h5.5a.8.8 0 0 1 .8.8v3.5h.5a1.2 1.2 0 0 1 1.2 1.2v2.6a.5.5 0 0 0 1 0V7l-1.3-1.3.8-.8 1.5 1.5c.2.2.3.5.3.8v4.4a1.7 1.7 0 0 1-3.4 0V9.3h-.6v4.2H3.7V4.3a.8.8 0 0 1 .8-.8zm.8 1.4v2.6h4V4.9z"),
    "bank": ("service", "M8.5 2.8l5.5 2.8v1.1H3V5.6zM4 7.5h1.5v4.3H4zm2.8 0h1.4v4.3H6.8zm2.8 0H11v4.3H9.6zm2.7 0h1.4v4.3h-1.4zM3 12.4h11v1.6H3z"),
    "atm": ("service", "M3.3 5h10.4c.5 0 .8.4.8.8v5.6c0 .5-.3.8-.8.8H3.3c-.5 0-.8-.3-.8-.8V5.8c0-.4.3-.8.8-.8zm0 1.5V8h10.4V6.5zm1 3.6v.9h3v-.9z"),
    "market": ("service", "M3.5 4h10l.8 3.2c0 1-.8 1.6-1.7 1.6-.8 0-1.4-.5-1.6-1.2-.2.7-.9 1.2-1.7 1.2s-1.5-.5-1.7-1.2c-.2.7-.9 1.2-1.6 1.2-.9 0-1.7-.6-1.7-1.6zm.6 5.6h1.2v2.9h6.4V9.6h1.2v4.1H4.1z"),
    "dot": ("other", "M8.5 5.5a3 3 0 1 1 0 6 3 3 0 0 1 0-6z"),
}

PALETTE = {
    # category: (light disc, night disc)
    "transit": ("#2563EB", "#3B82F6"),
    "health": ("#DC2626", "#EF4444"),
    "safety": ("#1E3A8A", "#4F6FD8"),
    "worship": ("#047857", "#10B981"),
    "education": ("#7C3AED", "#8B5CF6"),
    "park": ("#15803D", "#22C55E"),
    "service": ("#B45309", "#D97706"),
    "other": ("#475569", "#64748B"),
}

TEMPLATE = ('<svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 17 17">'
            '<circle cx="8.5" cy="8.5" r="8" fill="{bg}" stroke="{ring}" stroke-width="1"/>'
            '<path d="{d}" fill="{fg}" fill-rule="evenodd"/></svg>')


def main(out):
    for theme, i, ring in (("light", 0, "#FFFFFF"), ("night", 1, "#0B1220")):
        d = os.path.join(out, theme)
        os.makedirs(d, exist_ok=True)
        for name, (cat, path) in ICONS.items():
            with open(os.path.join(d, name + ".svg"), "w") as f:
                f.write(TEMPLATE.format(bg=PALETTE[cat][i], ring=ring, fg="#FFFFFF", d=path))
    print("icons", len(ICONS))


if __name__ == "__main__":
    main(sys.argv[1])
