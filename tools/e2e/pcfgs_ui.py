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


def bounds(n):
    m = re.findall(r"\d+", n.get("bounds", ""))
    return tuple(map(int, m)) if len(m) == 4 else None


def main():
    try:
        root = ET.parse(sys.argv[1]).getroot()
    except Exception:
        print("none")
        return
    nodes = list(root.iter("node"))
    titles = [bounds(n) for n in nodes if (n.get("text") or "").strip() in TITLES and bounds(n)]
    if not titles:
        print("none")
        return
    ty = (titles[0][1] + titles[0][3]) // 2
    # the Stop action of OUR row: the nearest Stop below our title
    best = None
    for n in nodes:
        t = (n.get("text") or n.get("content-desc") or "").strip()
        b = bounds(n)
        if t in STOPS and b and b[1] > ty and (best is None or b[1] < best[1]):
            best = b
    if best and best[1] - ty < 600:
        print("stop %d %d" % ((best[0] + best[2]) // 2, (best[1] + best[3]) // 2))
        return
    # collapsed: OUR row's expand chevron spans the title's height
    for n in nodes:
        b = bounds(n)
        if b and (n.get("resource-id") or "").endswith("expand_button") and b[1] <= ty <= b[3]:
            print("expand %d %d" % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2))
            return
    print("none")


if __name__ == "__main__":
    main()
