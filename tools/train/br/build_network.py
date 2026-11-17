#!/usr/bin/env python3
"""Attach OpenStreetMap geometry to the official BR timetable.

Reads  backend/core/data/train/br_official.json  (compile_official.py)
and an OSM download directory (NOT committed; ODbL, © OpenStreetMap contributors):
  <osm>/stations.json  Overpass: railway=station|halt nodes/ways in Bangladesh (out center tags)
  <osm>/rail.json      Overpass: railway=rail|narrow_gauge ways, no service=*, (out geom)
Writes (committed, small, deterministic):
  backend/core/data/train/br_stations.json   every timetable station: names, lat/lng + source
  backend/core/data/train/br_segments.geojson one LineString per consecutive stop pair (km)
  backend/core/data/train/br_trains.json     trains + stops with station codes + km from origin

Usage: python3 tools/train/br/build_network.py --osm DIR
"""
import argparse
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DATA = os.path.join(ROOT, "backend", "core", "data", "train")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
from station_names import CANON  # noqa: E402
from build_train_data import dijkstra, erase_loops, hav, simplify  # noqa: E402

ATTRIBUTION = "© OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright)"
# stations whose OSM name is ambiguous or spelled very differently: pin the OSM element
OSM_PIN = {
    "তাঁতীবান্ধা": "node/7455967019", "আজিমনগর": "node/10925899530", "রমনাবাজার": "way/438485879",
    "মিরপুর (কুষ্টিয়া)": "node/7455839040", "কুমিরা": "way/517512359", "নরসিংদী": "way/610603355",
    "নোয়াপাড়া (হবিগঞ্জ)": "way/622008376", "নোয়াপাড়া (যশোর)": "way/534845794", "ঠাকুরাকোনা": "way/539948579",
    "লাকসাম": "way/1205403453", "নোয়াখালী": "node/2544500337", "সরারচর": "way/395729040", "গফরগাঁও": "way/541640813",
    "সাতকানিয়া": "way/1225154762", "কক্সবাজার": "node/11393830116", "মাইজদী কোর্ট": "node/2571507697",
}
SPEED_MAX, SPEED_MIN = 115.0, 8.0


def nuk(s):
    return (s or "").replace("ড়", "ড়").replace("ঢ়", "ঢ়").replace("য়", "য়")


CANON = {nuk(k): v for k, v in CANON.items()}
OSM_PIN = {nuk(k): v for k, v in OSM_PIN.items()}


def nen(s):
    s = re.sub(r"\s*(railway|rail)?\s*(station|staion|junction|juncton|halt)?\s*$", "", (s or "").lower())
    return re.sub(r"[^a-z]", "", s)


def nbn(s):
    return re.sub(r"\s*(রেলওয়ে|রেল)?\s*(স্টেশন|ষ্টেশন|জংশন)?$", "", nuk(s)).replace(" ", "")


def slug(en):
    s = re.sub(r"[^a-z0-9]+", "-", en.lower()).strip("-")
    return s


def mins(t):
    return int(t[:2]) * 60 + int(t[3:]) if t else None


def load_osm(d):
    st = json.load(open(os.path.join(d, "stations.json"), encoding="utf-8"))
    rail = json.load(open(os.path.join(d, "rail.json"), encoding="utf-8"))
    els = []
    for e in st["elements"]:
        t = e.get("tags", {})
        lat = e.get("lat") or (e.get("center") or {}).get("lat")
        lon = e.get("lon") or (e.get("center") or {}).get("lon")
        if lat is None:
            continue
        els.append({"id": "%s/%s" % (e["type"], e["id"]), "lat": lat, "lng": lon,
                    "name": t.get("name", ""), "en": t.get("name:en", ""), "bn": t.get("name:bn", "")})
    return els, rail, st["osm3s"]["timestamp_osm_base"], rail["osm3s"]["timestamp_osm_base"]


def graph(rail):
    coords, adj = {}, {}
    for w in rail["elements"]:
        ns, gs = w.get("nodes") or [], w.get("geometry") or []
        if len(ns) != len(gs) or len(ns) < 2:
            continue
        for n, g in zip(ns, gs):
            coords[n] = (g["lat"], g["lon"])
        for a, b in zip(ns, ns[1:]):
            dd = hav(coords[a], coords[b])
            adj.setdefault(a, []).append((b, dd))
            adj.setdefault(b, []).append((a, dd))
    grid = {}
    for n, c in coords.items():
        grid.setdefault((int(c[0] / 0.001), int(c[1] / 0.001)), []).append(n)
    ends = set()
    for w in rail["elements"]:
        ns = w.get("nodes") or []
        if len(ns) >= 2:
            ends.update((ns[0], ns[-1]))
    for e in ends:
        c = coords.get(e)
        if c is None:
            continue
        i, j = int(c[0] / 0.001), int(c[1] / 0.001)
        near = {x for x, _ in adj.get(e, ())}
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for n in grid.get((i + di, j + dj), ()):
                    if n != e and n not in near:
                        dd = hav(c, coords[n])
                        if dd <= 40.0:
                            adj[e].append((n, dd))
                            adj.setdefault(n, []).append((e, dd))
    return coords, adj, grid


def nearest(coords, grid, p, limit):
    best, bn = limit, None
    i, j = int(p[0] / 0.001), int(p[1] / 0.001)
    r = int(limit / 100) + 1
    for di in range(-r, r + 1):
        for dj in range(-r, r + 1):
            for n in grid.get((i + di, j + dj), ()):
                dd = hav(coords[n], p)
                if dd < best:
                    best, bn = dd, n
    return bn, best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--osm", required=True)
    a = ap.parse_args()
    official = json.load(open(os.path.join(DATA, "br_official.json"), encoding="utf-8"))
    els, rail, st_base, rail_base = load_osm(a.osm)
    byid = {e["id"]: e for e in els}
    idx = {}
    for e in els:
        for k in {nen(e["en"]), nen(e["name"]), nbn(e["bn"]), nbn(e["name"])}:
            if k:
                idx.setdefault(k, []).append(e)
    coords, adj, grid = graph(rail)
    warn = []

    used = []
    for t in official["trains"]:
        for s in t["stops"]:
            if s["st"] not in used:
                used.append(s["st"])
        for x in (t["origin"], t["destination"]):
            if x not in used:
                used.append(x)
    stations = {}
    for bn in used:
        en, osm_en, district = CANON[bn]
        e = None
        if bn in OSM_PIN:
            e = byid.get(OSM_PIN[bn])
        if e is None:
            c = idx.get(nen(osm_en or en)) or idx.get(nen(en)) or idx.get(nbn(bn))
            if c:
                e = c[0]
        rec = {"code": slug(en), "name_bn": bn, "name_en": en, "district": district,
               "lat": None, "lng": None, "coord_source": None, "osm_id": None, "node": None}
        if e is not None:
            node, dd = nearest(coords, grid, (e["lat"], e["lng"]), 1500.0)
            rec.update(lat=round(e["lat"], 6), lng=round(e["lng"], 6), osm_id=e["id"],
                       coord_source="osm:%s" % e["id"], node=node)
            if node is None and district != "India":
                warn.append("station %s (%s): OSM point >1.5 km from any track" % (bn, e["id"]))
        stations[bn] = rec

    # route every consecutive stop pair
    seg_cache = {}

    def route(a_bn, b_bn):
        k = (a_bn, b_bn)
        if k in seg_cache:
            return seg_cache[k]
        na, nb = stations[a_bn]["node"], stations[b_bn]["node"]
        res = None
        if na is not None and nb is not None:
            p = dijkstra(adj, na, nb)
            if p:
                p = erase_loops(p)
                pts = [coords[n] for n in p]
                km = sum(hav(x, y) for x, y in zip(pts, pts[1:])) / 1000.0
                res = (km, pts)
        seg_cache[k] = res
        return res

    # place stations that OSM does not have, by timetable time along the track
    for _ in range(3):
        for t in official["trains"]:
            st = t["stops"]
            for i, s in enumerate(st):
                rec = stations[s["st"]]
                if rec["node"] is not None or rec["district"] == "India":
                    continue
                pi = next((j for j in range(i - 1, -1, -1) if stations[st[j]["st"]]["node"] is not None), None)
                ni = next((j for j in range(i + 1, len(st)) if stations[st[j]["st"]]["node"] is not None), None)
                if pi is None or ni is None:
                    continue
                r = route(st[pi]["st"], st[ni]["st"])
                t0, t1, tx = mins(st[pi]["dep"]), mins(st[ni]["arr"]), mins(s["arr"] or s["dep"])
                if not r or None in (t0, t1, tx):
                    continue
                span = (t1 - t0) % 1440 or 1
                f = ((tx - t0) % 1440) / span
                km, pts = r
                target, acc = f * km * 1000.0, 0.0
                pos = pts[-1]
                for x, y in zip(pts, pts[1:]):
                    dd = hav(x, y)
                    if acc + dd >= target:
                        u = (target - acc) / dd if dd else 0
                        pos = (x[0] + (y[0] - x[0]) * u, x[1] + (y[1] - x[1]) * u)
                        break
                    acc += dd
                node, _ = nearest(coords, grid, pos, 500.0)
                rec.update(lat=round(pos[0], 6), lng=round(pos[1], 6), node=node,
                           coord_source="estimated: timetable time between %s and %s along the OSM track (no OSM station point)" % (
                               st[pi]["st"], st[ni]["st"]))
    for rec in stations.values():
        if rec["lat"] is None and rec["district"] != "India":
            warn.append("station %s: no coordinates" % rec["name_bn"])

    trains, segs = [], {}
    for t in official["trains"]:
        km, out = 0.0, []
        for i, s in enumerate(t["stops"]):
            if i:
                prev = t["stops"][i - 1]
                r = route(prev["st"], s["st"])
                if r:
                    km += r[0]
                    key = "%s|%s" % (stations[prev["st"]]["code"], stations[s["st"]]["code"])
                    segs.setdefault(key, (prev["st"], s["st"], r))
                    t0, t1 = mins(prev["dep"]), mins(s["arr"])
                    if t0 is not None and t1 is not None and t["status"] == "running":
                        dm = (t1 - t0) % 1440
                        v = r[0] / (dm / 60.0) if dm else 999
                        if v > SPEED_MAX or (v < SPEED_MIN and r[0] > 5):
                            warn.append("%s %s→%s: %.1f km in %d min = %.0f km/h" % (t["no"], prev["st"], s["st"], r[0], dm, v))
                elif t["status"] == "running" and stations[prev["st"]]["district"] != "India":
                    warn.append("%s: no track route %s→%s" % (t["no"], prev["st"], s["st"]))
                    km = None if km is None else km
            o = dict(s)
            o["station"] = stations[s["st"]]["code"]
            o["km"] = round(km, 1) if km is not None and (i == 0 or out[-1]["km"] is not None) else None
            out.append(o)
        tt = dict(t)
        tt["stops"] = out
        tt["origin_code"] = stations[t["origin"]]["code"]
        tt["destination_code"] = stations[t["destination"]]["code"]
        trains.append(tt)

    feats = []
    for key in sorted(segs):
        a_bn, b_bn, (km, pts) = segs[key]
        line = simplify(pts, 15.0)
        feats.append({"type": "Feature",
                      "properties": {"id": key, "from": stations[a_bn]["code"], "to": stations[b_bn]["code"], "km": round(km, 2)},
                      "geometry": {"type": "LineString", "coordinates": [[round(p[1], 5), round(p[0], 5)] for p in line]}})
    meta = {"osm_stations_base": st_base, "osm_rail_base": rail_base, "licence": ATTRIBUTION,
            "built_by": "tools/train/br/build_network.py", "timetable": official["_meta"]}
    st_out = sorted(({k: v for k, v in r.items() if k != "node"} for r in stations.values()), key=lambda r: r["code"])
    codes = [r["code"] for r in st_out]
    assert len(codes) == len(set(codes)), "duplicate station code"
    json.dump({"_meta": meta, "stations": st_out}, open(os.path.join(DATA, "br_stations.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    json.dump({"type": "FeatureCollection", "_meta": meta, "features": feats},
              open(os.path.join(DATA, "br_segments.geojson"), "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    json.dump({"_meta": meta, "trains": trains}, open(os.path.join(DATA, "br_trains.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    print("stations", len(st_out), "segments", len(feats), "trains", len(trains))
    print("estimated coords", sum(1 for r in st_out if (r["coord_source"] or "").startswith("estimated")))
    for w in warn:
        print("WARN:", w)


if __name__ == "__main__":
    main()
