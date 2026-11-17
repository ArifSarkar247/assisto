#!/usr/bin/env python3
"""circle-screenshare: find Android's screen-capture consent button.

usage: projection_tap.py <uiautomator-dump.xml>
Prints "x y <text>" (centre of the button) when the SystemUI
MediaProjection dialog is on screen, else nothing. API 33: "Start now";
API 34+: the single-app / entire-screen spinner is left on its default and
"Start" / "Share screen" / "Next" is tapped. Never taps "Cancel".
"""
import re
import sys
import xml.etree.ElementTree as ET

TEXTS = ["start now", "start", "share screen", "next"]


def centre(b):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def main():
    try:
        root = ET.parse(sys.argv[1]).getroot()
    except Exception:
        return
    nodes = [n for n in root.iter("node")
             if "systemui" in (n.get("package") or "")]
    for want in TEXTS:
        for n in nodes:
            if (n.get("text") or "").strip().lower() == want and \
                    n.get("enabled") != "false":
                c = centre(n.get("bounds"))
                if c:
                    print(f"{c[0]} {c[1]} {want}")
                    return


if __name__ == "__main__":
    main()
