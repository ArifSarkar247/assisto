"""sjtrain (Safe Journey V2, 9 Nov) — every station a train PASSES, in order.

The timetable (Bangla Wikipedia) lists only the stops; the metro-style train
screen also shows the stations in between (passed = grey). We take the OSM
stations/halts already bundled for the offline alarm
(app/assets/train/stations_bd.json, ODbL) and keep those within LINE_M of the
train's own rail path, ordered by distance along it. Timetable stops are
always kept (flag "stop": true). Pure / offline / deterministic.

Usage:  python3 tools/train/build_line_stations.py
Writes: backend/core/data/train/line_stations_bd.json
"""
import json
import math
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_ST = os.path.join(ROOT, "app", "assets", "train", "stations_bd.json")
SRC_TT = os.path.join(ROOT, "backend", "core", "data", "train", "timetable_bd.json")
OUT = os.path.join(ROOT, "backend", "core", "data", "train", "line_stations_bd.json")

LINE_M = 250.0      # an OSM station this close to the train's path is ON it
MERGE_M = 600.0     # two stations closer than this along the path = one (keep the stop)
END_SKIP_M = 600.0  # a non-stop station this close to either end is the terminal itself

_BN_SUF = re.compile(r"\s*(রেলওয়ে|রেল)?\s*(স্টেশন|ষ্টেশন)?$")
_EN_SUF = re.compile(r"\s*(Railway|Rail)?\s*Station$", re.I)
_BN_TAIL = {unicodedata.normalize("NFC", w) for w in
            ("রেলওয়ে", "রেলওয়ে", "রেল", "স্টেশন", "ষ্টেশন", "স্টেশান", "রেলস্টেশন")}
_ROADLIKE = re.compile(r"\b(hwy|highway|road|rd)\b", re.I)


def hav(a, b):
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def seg_project(p, a, b):
    k = 111320.0
    c = math.cos(math.radians(p[0]))
    ax, ay = (a[1] - p[1]) * k * c, (a[0] - p[0]) * k
    bx, by = (b[1] - p[1]) * k * c, (b[0] - p[0]) * k
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L))
    return math.hypot(ax + t * dx, ay + t * dy), t


def project(path, cum, p):
    best, ch = math.inf, 0.0
    for i, (a, b) in enumerate(zip(path, path[1:])):
        if not (min(a[0], b[0]) - 0.01 <= p[0] <= max(a[0], b[0]) + 0.01 and
                min(a[1], b[1]) - 0.01 <= p[1] <= max(a[1], b[1]) + 0.01):
            continue
        d, t = seg_project(p, a, b)
        if d < best:
            best, ch = d, cum[i] + t * (cum[i + 1] - cum[i])
    return ch, best


def clean(bn, en):
    """Names as people say them: no "Railway Station" tails, no ", district"
    address tails (some OSM names are full addresses)."""
    bn = (bn or "").split(",")[0].strip()
    en = (en or "").split(",")[0].strip()
    if _ROADLIKE.search(en):
        en = ""
    def bn_tail(x):
        words = unicodedata.normalize("NFC", x).split()
        while len(words) > 1 and words[-1] in _BN_TAIL:
            words.pop()
        return " ".join(words)

    bn = bn_tail(bn)
    en = bn_tail(re.sub(r"\s*\b(Railway|Rail)\s+Station\b", "", en, flags=re.I))
    if not bn and re.search(r"[\u0980-\u09ff]", en):
        bn, en = en, ""          # a Bangla name sitting in the English field
    return bn, _EN_SUF.sub("", en).strip()


BN_MAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "station_names_bn.json")


def main():
    with open(BN_MAP, encoding="utf-8") as fh:
        bn_map = {k: v for k, v in json.load(fh).items() if not k.startswith("_")}
    with open(SRC_ST, encoding="utf-8") as fh:
        osm = json.load(fh)["stations"]
    with open(SRC_TT, encoding="utf-8") as fh:
        tt = json.load(fh)
    out = {}
    for t in tt["trains"]:
        path = [tuple(p) for p in t["path"]]
        cum = [0.0]
        for a, b in zip(path, path[1:]):
            cum.append(cum[-1] + hav(a, b))
        length = cum[-1]
        rows = []
        for s in t["stops"]:
            st = tt["stations"][s["st"]]
            bn, en = clean(st.get("bn"), st.get("en"))
            rows.append({"id": s["st"], "bn": bn, "en": en, "km": round(float(s["km"]), 2),
                         "lat": st["lat"], "lng": st["lng"], "stop": True})
        for s in osm:
            ch, off = project(path, cum, (s["lat"], s["lng"]))
            if off > LINE_M or ch < END_SKIP_M or ch > length - END_SKIP_M:
                continue
            bn, en = clean(s.get("bn"), s.get("en"))
            if not (bn or en):
                continue
            bn_src = "osm" if bn else ("assisto" if en in bn_map else "")
            bn = bn or bn_map.get(en, "")
            rows.append({"id": "o" + str(s["id"]), "bn": bn, "en": en, "bn_src": bn_src,
                         "km": round(ch / 1000.0, 2), "lat": s["lat"], "lng": s["lng"],
                         "stop": False})
        stop_names = {(r["bn"], r["en"]) for r in rows if r["stop"]}
        stop_names = {x for pair in stop_names for x in pair if x}
        rows = [r for r in rows if r["stop"] or not (r["bn"] in stop_names or r["en"] in stop_names)]
        rows.sort(key=lambda r: (r["km"], not r["stop"]))
        kept = []
        for r in rows:
            if kept and (r["km"] - kept[-1]["km"]) * 1000.0 < MERGE_M:
                if r["stop"] and not kept[-1]["stop"]:
                    kept[-1] = r
                continue
            kept.append(r)
        out[t["no"]] = kept
    meta = {"source": "OpenStreetMap stations/halts within %d m of each train's rail path "
                      "(app/assets/train/stations_bd.json) + the timetable stops" % LINE_M,
            "licence": "ODbL 1.0 — © OpenStreetMap contributors "
                       "(https://www.openstreetmap.org/copyright); timetable stops: "
                       "Bangla Wikipedia, CC BY-SA 4.0",
            "built_by": "tools/train/build_line_stations.py",
            "bn_names": "bn_src=assisto: Bangla spelling written by Assisto for an "
                        "English-only OSM name (tools/train/station_names_bn.json; "
                        "owner may correct)",
            "note": "stop=false = the train passes (may not halt); times between "
                    "stops are interpolated by distance (estimate)."}
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump({"_meta": meta, "trains": out}, fh, ensure_ascii=False, separators=(",", ":"))
    n = sum(len(v) for v in out.values())
    print("trains %d, line stations %d (avg %.1f)" % (len(out), n, n / max(1, len(out))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
