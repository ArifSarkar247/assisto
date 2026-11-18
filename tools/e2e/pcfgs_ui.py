#!/usr/bin/env python3
"""guardbox-play: find OUR camera notification's Stop button in a uiautomator
dump. Prints "stop X Y" | "expand X Y" (the chevron of our notification, its
actions are hidden while collapsed) | "none"."""
import re
import sys
import xml.etree.ElementTree as ET

TITLES = ("This phone is working as a camera", "এই ফোন এখন ক্যামেরা হিসেবে কাজ করছে")
STOPS = ("Stop", "STOP", "বন্ধ করুন")


def center(n):
    m = re.findall(r"\d+", n.get("bounds", ""))
    if len(m) != 4:
        return None
    x1, y1, x2, y2 = map(int, m)
    return (x1 + x2) // 2, (y1 + y2) // 2


def main():
    try:
        root = ET.parse(sys.argv[1]).getroot()
    except Exception:
        print("none")
        return
    parent = {c: p for p in root.iter() for c in p}

    def ours(n):
        # walk up to the notification row; it must hold our title
        for _ in range(12):
            n = parent.get(n)
            if n is None:
                return False
            if any((d.get("text") or "") in TITLES for d in n.iter()):
                return True
        return False

    for n in root.iter("node"):
        t = (n.get("text") or n.get("content-desc") or "").strip()
        if t in STOPS and n.get("clickable") == "true" and ours(n):
            c = center(n)
            if c:
                print("stop %d %d" % c)
                return
    for n in root.iter("node"):
        if (n.get("resource-id") or "").endswith("expand_button") and ours(n):
            c = center(n)
            if c:
                print("expand %d %d" % c)
                return
    print("none")


if __name__ == "__main__":
    main()
