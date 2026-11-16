#!/usr/bin/env python3
"""playvideos: find the button to tap in an Android permission dialog.

usage: tap_target.py <uiautomator-dump.xml>
Prints "x y <what>" for the best button (centre of its bounds), or nothing
when no permission dialog is on screen. Preference: "While using the app"
(location / microphone), then "Allow" (notifications). Never taps
"Only this time" or "Don't allow".
"""
import re
import sys
import xml.etree.ElementTree as ET

IDS = [
    "permission_allow_foreground_only_button",  # While using the app
    "permission_allow_button",                  # Allow
]
TEXTS = ["while using the app", "allow"]


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
    nodes = list(root.iter("node"))
    if not any("permissioncontroller" in (n.get("package") or "") for n in nodes):
        return
    for rid in IDS:
        for n in nodes:
            if (n.get("resource-id") or "").endswith(":id/" + rid) and n.get("enabled") != "false":
                c = centre(n.get("bounds"))
                if c:
                    print(c[0], c[1], rid)
                    return
    for t in TEXTS:
        for n in nodes:
            if (n.get("text") or "").strip().lower() == t:
                c = centre(n.get("bounds"))
                if c:
                    print(c[0], c[1], "text:" + t)
                    return


if __name__ == "__main__":
    main()
