#!/usr/bin/env python3
"""citydata (owner 9 Nov 11:45): build Assisto's own city transit dataset.

GitHub Actions ONLY (.github/workflows/transit_data.yml) — never on the
server. Inputs: a small per-city OpenStreetMap extract (osmium extract -b of
the Geofabrik Bangladesh file), the curated seeds in deploy/transit/seed/ and
the polite public crawl (crawl_public.py -> public_<city>.json).

Outputs in --out:
  transit_<city>.json.gz   compact network the server imports + the phone
                           caches (stops / routes / metro gates; columns)
  gtfs_<city>.zip          the same data as GTFS (frequency-based) for anyone
                           to inspect; ODbL attribution in feed_info.txt
  directory_<city>.json.gz terminals, ghats, city offices (OSM + seeds)
  report_<city>.json       counts, coverage %, cross-match + gaps, top-50
Status per item: "v" (Verified) when 2+ independent sources agree (OSM,
public route pages, Wikipedia, DMTCL, owner), else "r" (Reported).
"""
import argparse
import csv
import gzip
import hashlib
import io
import json
import math
import os
import re
import sys
import time
import zipfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "backend", "core"))
from citytransit import engine as E  # noqa: E402

ATTRIBUTION = "© OpenStreetMap contributors (ODbL 1.0)"
CITIES = {
    "dhaka": {"bbox": [23.66, 90.30, 23.95, 90.52], "core": [23.69, 90.33, 23.90, 90.46]},
    "chattogram": {"bbox": [22.20, 91.70, 22.45, 91.95], "core": [22.28, 91.76, 22.42, 91.88]},
}
MODE_OF = {"bus": "bus", "minibus": "bus", "trolleybus": "bus", "share_taxi": "leguna",
           "ferry": "water", "subway": "metro", "light_rail": "metro", "monorail": "metro",
           "train": "rail"}
STOP_ROLE = re.compile(r"^(stop|platform)(_entry_only|_exit_only)?(:\d+)?$")
POI_KEYS = ("amenity", "shop", "office", "tourism", "healthcare", "leisure", "building")
SYN = [(r"\bbazaar\b", "bazar"), (r"\bsharani\b", "sarani"), (r"\bshahbagh\b", "shahbag"),
       (r"\bkawran\b", "karwan"), (r"\bgulisthan\b", "gulistan"), (r"\bmohakhal\b", "mohakhali"),
       (r"\bmotijhil\b", "motijheel"), (r"\bjatrabar\b", "jatrabari"), (r"\bcentre\b", "center"),
       (r"\bno\.?\s*", ""), (r"\bsec(tor)?\b", "sector"), (r"\bmor(e|h)?\b|\bmoor\b", ""),
       (r"\bbus (stand|stop|stoppage|counter|terminal)\b", ""), (r"\b(stand|stoppage)\b", ""),
       (r"\bchattar|chottor|chattor\b", ""), (r"\bcircle\b", ""), (r"\bgate\b", "gate"),
       (r"\bmetro (rail )?station\b", ""), (r"\bstation\b", "")]


def norm(s):
    s = (s or "").lower()
    s = re.sub(r"[‐-―\-_/,.'’()\[\]:]+", " ", s)
    for a, b in SYN:
        s = re.sub(a, b, s)
    s = re.sub(r"(\D)(\d)", r"\1 \2", s)
    return re.sub(r"\s+", " ", s).strip()


def norm_bn(s):
    s = (s or "").strip()
    s = re.sub(r"[\s\-–(),।.]+", " ", s)
    for w in ("বাস স্ট্যান্ড", "বাসস্ট্যান্ড", "স্ট্যান্ড", "মোড়", "চত্বর", "স্টেশন"):
        s = s.replace(w, " ")
    return re.sub(r"\s+", " ", s).strip()


def company_key(s):
    s = norm(s)
    s = re.sub(r"\b(paribahan|poribahan|transport|transportation|bus|service|services|ltd|"
               r"limited|express|plus|route|deluxe|special)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def hav(a, b, c, d):
    return E.hav(a, b, c, d)


# ------------------------------------------------------------------ OSM read
def read_osm(pbf):
    import osmium

    rels = {}
    need_ways, need_nodes = set(), set()

    class R(osmium.SimpleHandler):
        def relation(self, r):
            t = r.tags
            if t.get("type") != "route" or t.get("route") not in MODE_OF:
                return
            mem = [(m.type, m.ref, m.role) for m in r.members]
            rels[r.id] = {"tags": dict(t), "members": mem}
            for typ, ref, _role in mem:
                if typ == "w":
                    need_ways.add(ref)
                elif typ == "n":
                    need_nodes.add(ref)

    R().apply_file(pbf)
    nodes, ways, stopn, poi, entr, elev, places, stations, dirs = {}, {}, {}, [], [], [], [], [], []

    def dir_kind(t):
        if t.get("amenity") == "bus_station" or t.get("public_transport") == "station" and t.get("bus") == "yes":
            return "terminal"
        if t.get("amenity") == "ferry_terminal" or t.get("ferry") == "yes" and t.get("public_transport"):
            return "ghat"
        n = (t.get("name") or "").lower()
        if any(k in n for k in ("passport", "brta", "deputy commissioner", "collectorate",
                                "land office", "city corporation", "nagar bhaban", "ac land")):
            return "office"
        return None

    class N(osmium.SimpleHandler):
        def node(self, n):
            t = n.tags
            if n.id in need_nodes:
                nodes[n.id] = (n.location.lat, n.location.lon)
            if not len(t):
                return
            lat, lon = n.location.lat, n.location.lon
            name = t.get("name") or t.get("name:en") or ""
            stoplike = (t.get("highway") == "bus_stop" or t.get("public_transport") in
                        ("platform", "stop_position", "station") or
                        t.get("railway") in ("station", "halt", "stop") or
                        t.get("amenity") in ("bus_station", "ferry_terminal"))
            if stoplike:
                stopn[n.id] = {"lat": lat, "lon": lon, "name": name, "name_bn": t.get("name:bn", ""),
                               "name_en": t.get("name:en", ""), "t": {k: t.get(k) for k in (
                                   "highway", "public_transport", "railway", "station",
                                   "subway", "network", "amenity", "bus", "ferry")}}
            if t.get("railway") == "station" or t.get("station") == "subway":
                stations.append({"id": n.id, "lat": lat, "lon": lon, "name": name,
                                 "name_en": t.get("name:en", ""), "name_bn": t.get("name:bn", "")})
            if t.get("railway") == "subway_entrance" or (t.get("entrance") and t.get("railway")):
                entr.append({"id": n.id, "lat": lat, "lon": lon, "ref": t.get("ref", ""),
                             "name": t.get("name", ""), "name_bn": t.get("name:bn", ""),
                             "wheelchair": t.get("wheelchair", ""), "level": t.get("level", "")})
            if t.get("highway") == "elevator":
                elev.append((lat, lon))
            if t.get("place") in ("suburb", "neighbourhood", "quarter", "locality", "village",
                                  "hamlet", "square") and name:
                places.append({"id": n.id, "lat": lat, "lon": lon, "name": name,
                               "name_bn": t.get("name:bn", ""), "name_en": t.get("name:en", "")})
            if name and any(k in t for k in POI_KEYS[:-1]):
                cat = next(t.get(k) for k in POI_KEYS[:-1] if k in t)
                poi.append((lat, lon, name, t.get("name:bn", ""), cat))
            dk = dir_kind(t)
            if dk and name:
                dirs.append(_dir_item(dk, "n%d" % n.id, lat, lon, t))
            if t.get("junction") and name or t.get("highway") == "traffic_signals" and name:
                places.append({"id": n.id, "lat": lat, "lon": lon, "name": name,
                               "name_bn": t.get("name:bn", ""), "name_en": t.get("name:en", "")})

        def way(self, w):
            t = w.tags
            want = w.id in need_ways
            named_poi = (t.get("name") and any(k in t for k in POI_KEYS[:-1]))
            dk = dir_kind(t) if t.get("name") else None
            if not (want or named_poi or dk):
                return
            try:
                pts = [(nd.location.lat, nd.location.lon) for nd in w.nodes if nd.location.valid()]
            except Exception:
                return
            if not pts:
                return
            if want:
                ways[w.id] = {"pts": pts, "ends": (w.nodes[0].ref, w.nodes[-1].ref)}
            if named_poi or dk:
                lat = sum(p[0] for p in pts) / len(pts)
                lon = sum(p[1] for p in pts) / len(pts)
                if named_poi:
                    cat = next(t.get(k) for k in POI_KEYS[:-1] if k in t)
                    poi.append((lat, lon, t.get("name"), t.get("name:bn", ""), cat))
                if dk:
                    dirs.append(_dir_item(dk, "w%d" % w.id, lat, lon, t))

    N().apply_file(pbf, locations=True, idx="flex_mem")
    return {"rels": rels, "nodes": nodes, "ways": ways, "stopn": stopn, "poi": poi,
            "entr": entr, "elev": elev, "places": places, "stations": stations, "dirs": dirs}


def _dir_item(kind, oid, lat, lon, t):
    return {"id": "osm:" + oid, "kind": kind, "name": t.get("name:en") or t.get("name", ""),
            "name_bn": t.get("name:bn", ""), "lat": round(lat, 6), "lon": round(lon, 6),
            "address": " ".join(x for x in (t.get("addr:housenumber", ""), t.get("addr:street", ""),
                                             t.get("addr:city", "")) if x),
            "hours": t.get("opening_hours", ""), "phone": t.get("phone", "") or t.get("contact:phone", ""),
            "operator": t.get("operator", ""), "status": "r",
            "sources": [{"s": "osm", "url": "https://www.openstreetmap.org/%s/%s" % (
                "node" if oid[0] == "n" else "way", oid[1:])}]}


# ------------------------------------------------------------------ helpers
class Grid:
    def __init__(self, cell=0.004):
        self.cell, self.g = cell, defaultdict(list)

    def add(self, lat, lon, item):
        self.g[(int(lat // self.cell), int(lon // self.cell))].append((lat, lon, item))

    def near(self, lat, lon, r_m):
        n = int(math.ceil(r_m / (self.cell * 111000))) + 1
        a0, b0 = int(lat // self.cell), int(lon // self.cell)
        out = []
        for a in range(a0 - n, a0 + n + 1):
            for b in range(b0 - n, b0 + n + 1):
                for la, lo, it in self.g.get((a, b), ()):
                    d = hav(lat, lon, la, lo)
                    if d <= r_m:
                        out.append((d, it))
        out.sort(key=lambda x: x[0])
        return out


def chain_ways(members, ways):
    """Ordered polyline from a route relation's way members (each way is
    flipped to continue from the end of the previous one)."""
    seq = []
    for typ, ref, role in members:
        if typ != "w" or ref not in ways or STOP_ROLE.match(role or ""):
            continue
        pts = list(ways[ref]["pts"])
        if seq:
            last = seq[-1]
            if hav(last[0], last[1], pts[-1][0], pts[-1][1]) < hav(last[0], last[1], pts[0][0], pts[0][1]):
                pts.reverse()
            seq.extend(pts[1:])
        else:
            seq.extend(pts)
    return seq


def project(poly, cum, lat, lon):
    """(distance along polyline in km, offset m) — coarse: nearest vertex."""
    best, bi = 1e18, 0
    for i, (a, b) in enumerate(poly):
        d = (a - lat) ** 2 + ((b - lon) * 0.92) ** 2
        if d < best:
            best, bi = d, i
    return cum[bi], hav(lat, lon, poly[bi][0], poly[bi][1])


def cumulative(poly):
    c, acc = [0.0], 0.0
    for i in range(1, len(poly)):
        acc += hav(poly[i - 1][0], poly[i - 1][1], poly[i][0], poly[i][1]) / 1000.0
        c.append(acc)
    return c


# ------------------------------------------------------------------ build
class Builder:
    def __init__(self, city, osm, public, seeds):
        self.city, self.osm, self.public, self.seeds = city, osm, public, seeds
        self.cfg = CITIES[city]
        self.stops, self.stop_ix = [], {}
        self.routes = []
        self.gaps = defaultdict(list)
        self.sgrid = Grid()
        for nid, s in osm["stopn"].items():
            if s["t"].get("highway") == "bus_stop" or s["t"].get("public_transport") in ("platform", "stop_position"):
                self.sgrid.add(s["lat"], s["lon"], nid)

    def stop(self, sid, name, name_bn, lat, lon, kind, src, code=""):
        i = self.stop_ix.get(sid)
        if i is None:
            i = len(self.stops)
            self.stop_ix[sid] = i
            self.stops.append({"id": sid, "name": name, "name_bn": name_bn, "lat": round(lat, 6),
                               "lon": round(lon, 6), "kind": kind, "src": set([src]), "code": code})
        else:
            s = self.stops[i]
            s["src"].add(src)
            if not s["name"] and name:
                s["name"] = name
            if not s["name_bn"] and name_bn:
                s["name_bn"] = name_bn
        return i

    # ---------------------------------------------------------- OSM routes
    def osm_routes(self):
        osm = self.osm
        for rid, r in osm["rels"].items():
            t = r["tags"]
            mode = MODE_OF[t["route"]]
            if mode in ("metro", "rail"):
                continue
            stops = []
            for typ, ref, role in r["members"]:
                if typ != "n" or not STOP_ROLE.match(role or ""):
                    continue
                ll = osm["nodes"].get(ref)
                if not ll:
                    continue
                info = osm["stopn"].get(ref, {})
                if stops and hav(stops[-1][1], stops[-1][2], ll[0], ll[1]) < 80:
                    continue      # stop_position + platform pair
                stops.append((ref, ll[0], ll[1], info.get("name_en") or info.get("name", ""),
                              info.get("name_bn", "")))
            poly = chain_ways(r["members"], osm["ways"])
            if len(stops) < 2 and len(poly) > 1:
                cum = cumulative(poly)
                seen = {}
                for k in range(0, len(poly)):
                    for d, nid in self.sgrid.near(poly[k][0], poly[k][1], 35):
                        if nid not in seen:
                            seen[nid] = cum[k]
                order = sorted(seen.items(), key=lambda x: x[1])
                stops = []
                for nid, _km in order:
                    s = osm["stopn"][nid]
                    if stops and hav(stops[-1][1], stops[-1][2], s["lat"], s["lon"]) < 120:
                        continue
                    stops.append((nid, s["lat"], s["lon"], s.get("name_en") or s["name"], s["name_bn"]))
            name = t.get("name:en") or t.get("name") or ""
            if len(stops) < 2:
                self.gaps["osm_route_without_stops"].append({"id": rid, "name": name})
                continue
            if poly and len(poly) > 1:
                cum = cumulative(poly)
                km = [project(poly, cum, s[1], s[2])[0] for s in stops]
                if any(km[i] < km[i - 1] for i in range(1, len(km))):
                    km = None
            else:
                km = None
            if km is None:
                km, acc = [0.0], 0.0
                for i in range(1, len(stops)):
                    acc += hav(stops[i - 1][1], stops[i - 1][2], stops[i][1], stops[i][2]) * 1.2 / 1000.0
                    km.append(acc)
            idx = [self.stop("n%d" % s[0], s[3], s[4], s[1], s[2], mode, "osm") for s in stops]
            self.routes.append({
                "id": "osm%d" % rid, "mode": mode, "name": name, "name_bn": t.get("name:bn", ""),
                "ref": t.get("ref", ""), "op": t.get("operator", "") or t.get("network", ""),
                "from": t.get("from", ""), "to": t.get("to", ""),
                "src": [{"s": "osm", "url": "https://www.openstreetmap.org/relation/%d" % rid}],
                "stops": idx, "km": [round(x, 3) for x in km], "_ck": company_key(
                    " ".join([t.get("operator", ""), t.get("name", ""), t.get("name:en", "")])),
            })

    # ------------------------------------------------------ public lists
    def gazetteer(self):
        g, gb = defaultdict(list), defaultdict(list)
        for nid, s in self.osm["stopn"].items():
            for nm in {s["name"], s.get("name_en", "")}:
                if nm:
                    g[norm(nm)].append((0, s["lat"], s["lon"], "n%d" % nid, s["name_en"] or s["name"], s["name_bn"]))
            if s["name_bn"]:
                gb[norm_bn(s["name_bn"])].append((0, s["lat"], s["lon"], "n%d" % nid, s["name_en"] or s["name"], s["name_bn"]))
        for p in self.osm["places"]:
            for nm in {p["name"], p.get("name_en", "")}:
                if nm:
                    g[norm(nm)].append((2, p["lat"], p["lon"], "p%d" % p["id"], p["name_en"] or p["name"], p["name_bn"]))
            if p["name_bn"]:
                gb[norm_bn(p["name_bn"])].append((2, p["lat"], p["lon"], "p%d" % p["id"], p["name_en"] or p["name"], p["name_bn"]))
        bb = self.cfg["bbox"]
        inb = lambda c: bb[0] <= c[1] <= bb[2] and bb[1] <= c[2] <= bb[3]
        self.gz = {k: [c for c in v if inb(c)] for k, v in g.items()}
        self.gzb = {k: [c for c in v if inb(c)] for k, v in gb.items()}

    def match(self, en, bn, prev):
        cands = list(self.gz.get(norm(en), [])) + list(self.gzb.get(norm_bn(bn), []))
        if not cands and en:
            n = norm(en)
            for k in (n.split(" ")[0] + " " + " ".join(n.split(" ")[1:2])).strip(), n.replace(" ", ""):
                cands = list(self.gz.get(k, []))
                if cands:
                    break
        if not cands:
            return None
        if prev:
            cands = [c for c in cands if hav(prev[0], prev[1], c[1], c[2]) < 9000] or []
            if not cands:
                return None
            return min(cands, key=lambda c: (hav(prev[0], prev[1], c[1], c[2]) + c[0] * 150))
        return min(cands, key=lambda c: c[0])

    def public_routes(self):
        self.gazetteer()
        for pr in self.public.get("bus_routes", []):
            pts, prev, miss = [], None, []
            for en, bn in pr["stops"]:
                m = self.match(en, bn, prev)
                if not m:
                    miss.append(en or bn)
                    continue
                if pts and pts[-1][3] == m[3]:
                    continue
                pts.append((m[1], m[2], en or m[4], m[3], bn or m[5]))
                prev = (m[1], m[2])
            if len(pts) < 3 or len(pts) < 0.5 * len(pr["stops"]):
                self.gaps["public_route_unmatched"].append(
                    {"company": pr["company"], "url": pr["source_url"], "missing": miss[:12],
                     "matched": len(pts), "listed": len(pr["stops"])})
                continue
            if miss:
                self.gaps["public_stop_unmatched"].append({"company": pr["company"], "missing": miss[:12]})
            km, acc = [0.0], 0.0
            for i in range(1, len(pts)):
                acc += hav(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]) * 1.25 / 1000.0
                km.append(acc)
            base = re.sub(r"[^a-z0-9]+", "-", pr["company"].lower()).strip("-")[:40]
            for direction, seq, kk in (("a", pts, km), ("b", pts[::-1], [km[-1] - x for x in km[::-1]])):
                idx = [self.stop(p[3], p[2], p[4], p[0], p[1], "bus", "public") for p in seq]
                for i, p in zip(idx, seq):
                    if p[3].startswith("n"):          # an OSM bus-stop node: 2nd source
                        self.stops[i]["src"].add("osm")
                self.routes.append({
                    "id": "pub-%s-%s" % (base, direction), "mode": "bus", "name": pr["company"],
                    "name_bn": pr.get("company_bn", ""), "ref": "", "op": pr["company"],
                    "from": seq[0][2], "to": seq[-1][2],
                    "src": [{"s": pr["source"], "url": pr["source_url"], "date": pr["fetched"]}],
                    "stops": idx, "km": [round(x, 3) for x in kk], "_ck": company_key(pr["company"]),
                    "counters": [c[0] or c[1] for c in pr.get("counters") or []][:20],
                })

    def cross_match(self):
        """OSM relation + public page for the same company sharing 3+ stops
        within 300 m -> both Verified (2 independent sources)."""
        osm_r = [r for r in self.routes if r["id"].startswith("osm")]
        pub_r = [r for r in self.routes if r["id"].startswith("pub")]
        self.cross = 0
        for p in pub_r:
            if not p["_ck"]:
                continue
            for o in osm_r:
                if not o["_ck"] or (p["_ck"] not in o["_ck"] and o["_ck"] not in p["_ck"]):
                    continue
                shared = 0
                for si in p["stops"]:
                    a = self.stops[si]
                    if any(hav(a["lat"], a["lon"], self.stops[sj]["lat"], self.stops[sj]["lon"]) < 300
                           for sj in o["stops"]):
                        shared += 1
                if shared >= 3:
                    p["_v"] = o["_v"] = True
                    p["src"] = p["src"] + [s for s in o["src"] if s not in p["src"]]
                    o["src"] = o["src"] + [s for s in p["src"] if s not in o["src"]]
                    self.cross += 1

    # ------------------------------------------------------------ metro
    def metro(self):
        seed = self.seeds.get("metro")
        if not seed or self.city != "dhaka":
            return
        wiki = (self.public.get("texts", {}).get("wikipedia_mrt6", {}).get("text") or "").lower()
        dm = (self.public.get("texts", {}).get("dmtcl_home", {}).get("text") or "").lower()
        idx, km = [], []
        cand = [s for s in self.osm["stations"]]
        for code, en, bn in seed["stations"]:
            names = [norm(en)] + [norm(a) for a in seed.get("aliases", {}).get(code, [])]
            best = None
            for s in cand:
                nn = {norm(s["name"]), norm(s["name_en"])}
                if nn & set(names) or (s["name_bn"] and norm_bn(s["name_bn"]) == norm_bn(bn)):
                    if best is None or "metro" in (s["name"] + s["name_en"]).lower():
                        best = s
            srcs = {"seed"}
            if best:
                srcs.add("osm")
            if norm(en) in norm(wiki) or any(a in wiki for a in seed.get("aliases", {}).get(code, [])):
                srcs.add("wikipedia")
            if en.lower() in dm:
                srcs.add("dmtcl")
            if not best:
                self.gaps["metro_station_not_in_osm"].append(en)
                continue
            i = self.stop("mrt6-" + code, en, bn, best["lat"], best["lon"], "metro", "osm", code)
            self.stops[i]["src"] |= srcs
            self.stops[i]["_osm"] = best["id"]
            idx.append(i)
        if len(idx) < 2:
            return
        raw = [0.0]
        for a, b in zip(idx, idx[1:]):
            raw.append(raw[-1] + hav(self.stops[a]["lat"], self.stops[a]["lon"],
                                     self.stops[b]["lat"], self.stops[b]["lon"]) / 1000.0)
        scale = seed["line"]["km_total"] / raw[-1] if raw[-1] > 0 and len(idx) == len(seed["stations"]) else 1.0
        km = [round(x * scale, 3) for x in raw]
        svc = seed.get("service", {})
        for direction, seq, kk in (("a", idx, km), ("b", idx[::-1], [km[-1] - x for x in km[::-1]])):
            self.routes.append({
                "id": "mrt6-" + direction, "mode": "metro", "name": seed["line"]["name"],
                "name_bn": seed["line"]["name_bn"], "ref": "MRT-6", "op": seed["line"]["operator"],
                "from": self.stops[seq[0]]["name"], "to": self.stops[seq[-1]]["name"],
                "src": [{"s": "dmtcl/wikipedia", "url": s["url"], "date": s["date"]}
                        for s in seed["line"]["sources"]],
                "stops": seq, "km": kk, "_ck": "", "_v": True,
                "hw": svc.get("headway_peak_min", 10), "spd": 38.0, "dwell": 30,
            })
        self.metro_idx = idx
        self.gates()

    def gates(self):
        eg = Grid()
        for e in self.osm["entr"]:
            eg.add(e["lat"], e["lon"], e)
        pg = Grid(0.003)
        for p in self.osm["poi"]:
            pg.add(p[0], p[1], p)
        self.gate_list = []
        for si in self.metro_idx:
            s = self.stops[si]
            ents = [e for d, e in eg.near(s["lat"], s["lon"], 250)]
            if not ents:
                self.gaps["metro_gates_not_mapped"].append(s["name"])
            for e in ents:
                near = []
                for d, p in pg.near(e["lat"], e["lon"], 220):
                    if p[4] in ("bench", "waste_basket", "parking_entrance", "vending_machine", "atm") and d > 80:
                        continue
                    near.append([p[2], p[3], p[4], int(d)])
                    if len(near) >= 8:
                        break
                stands = []
                for d, nid in self.sgrid.near(e["lat"], e["lon"], 300):
                    if "n%d" % nid in self.stop_ix:
                        stands.append(self.stop_ix["n%d" % nid])
                    if len(stands) >= 5:
                        break
                lift = any(hav(e["lat"], e["lon"], a, b) < 40 for a, b in self.osm["elev"]) or None
                ref = e["ref"] or e["name"]
                self.gate_list.append({
                    "st": si, "ref": ref, "name": e["name"], "name_bn": e["name_bn"],
                    "lat": round(e["lat"], 6), "lon": round(e["lon"], 6),
                    "side": E.bearing_side(s["lat"], s["lon"], e["lat"], e["lon"]),
                    "near": near, "stands": stands, "lift": lift,
                    "wheelchair": e["wheelchair"] or None, "status": "reported",
                    "src": "https://www.openstreetmap.org/node/%d" % e["id"],
                })

    def finish_gates(self):
        stop_routes = defaultdict(set)
        for ri, r in enumerate(self.routes):
            for si in r["stops"]:
                stop_routes[si].add(ri)
        for g in getattr(self, "gate_list", []):
            rs = set()
            for si in g["stands"]:
                rs |= {ri for ri in stop_routes[si] if self.routes[ri]["mode"] != "metro"}
            g["routes"] = sorted(rs)[:30]

    # ------------------------------------------------------------ output
    def network(self, version, osm_ts):
        stop_routes = defaultdict(int)
        for r in self.routes:
            for si in r["stops"]:
                stop_routes[si] += 1
        keep = [i for i in range(len(self.stops)) if stop_routes[i]]
        remap = {old: new for new, old in enumerate(keep)}
        rows = []
        for old in keep:
            s = self.stops[old]
            srcs = {x for x in s["src"] if x != "seed"}
            st = "v" if len(srcs) >= 2 else "r"
            rows.append([s["id"], s["name"], s["name_bn"], s["lat"], s["lon"], s["kind"], st, s["code"]])
        routes = []
        for r in self.routes:
            rr = {k: v for k, v in r.items() if not k.startswith("_")}
            rr["stops"] = [remap[i] for i in r["stops"]]
            rr["st"] = "v" if r.get("_v") else "r"
            routes.append(rr)
        self.finish_gates()
        gates = []
        for g in getattr(self, "gate_list", []):
            g = dict(g)
            g["st"] = remap[g["st"]]
            g["stands"] = [remap[i] for i in g["stands"] if i in remap]
            gates.append(g)
        bb = self.cfg["bbox"]
        net = {"fmt": 1, "city": self.city, "version": version, "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "osm_timestamp": osm_ts, "attribution": ATTRIBUTION,
               "copyright_url": "https://www.openstreetmap.org/copyright",
               "bbox": bb,
               "sources": [{"s": "osm", "licence": "ODbL 1.0", "url": "https://www.openstreetmap.org/copyright"},
                           {"s": "dhakabusservice.com", "licence": "public web page (facts only)",
                            "url": "https://dhakabusservice.com/dhaka-local-bus-routes/"},
                           {"s": "wikipedia", "licence": "CC BY-SA 4.0",
                            "url": "https://en.wikipedia.org/wiki/MRT_Line_6_(Dhaka_Metro_Rail)"},
                           {"s": "dmtcl", "url": "https://dmtc.org.bd/"}],
               "stops": {"cols": ["id", "name", "name_bn", "lat", "lon", "kind", "st", "code"], "rows": rows},
               "routes": routes, "gates": gates}
        if self.seeds.get("metro") and self.city == "dhaka":
            net["metro"] = {k: self.seeds["metro"].get(k) for k in ("line", "service", "recharge")}
        return net

    def coverage(self, net):
        c = self.cfg["core"]
        g = Grid()
        for row in net["stops"]["rows"]:
            g.add(row[3], row[4], 1)
        step_lat, step_lon = 0.009, 0.0098      # ~1 km
        tot = hit = 0
        lat = c[0] + step_lat / 2
        while lat < c[2]:
            lon = c[1] + step_lon / 2
            while lon < c[3]:
                tot += 1
                if g.near(lat, lon, 700):
                    hit += 1
                lon += step_lon
            lat += step_lat
        return round(100.0 * hit / max(1, tot), 1), tot


# ------------------------------------------------------------------ GTFS
def write_gtfs(net, path):
    z = zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED)

    def put(name, header, rows):
        b = io.StringIO()
        w = csv.writer(b)
        w.writerow(header)
        w.writerows(rows)
        z.writestr(name, b.getvalue())

    put("agency.txt", ["agency_id", "agency_name", "agency_url", "agency_timezone"],
        [["assisto", "Assisto city data (community + public sources)", "https://lifeassisto.com", "Asia/Dhaka"]])
    put("feed_info.txt", ["feed_publisher_name", "feed_publisher_url", "feed_lang", "feed_version"],
        [["Assisto — " + ATTRIBUTION, "https://lifeassisto.com", "en", net["version"]]])
    put("stops.txt", ["stop_id", "stop_name", "stop_lat", "stop_lon", "stop_code"],
        [[r[0], r[1] or r[2], r[3], r[4], r[7]] for r in net["stops"]["rows"]])
    rtype = {"metro": 1, "bus": 3, "leguna": 3, "water": 4}
    put("routes.txt", ["route_id", "agency_id", "route_short_name", "route_long_name", "route_type"],
        [[r["id"], "assisto", r.get("ref", ""), r["name"], rtype.get(r["mode"], 3)] for r in net["routes"]])
    put("calendar.txt", ["service_id", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                         "sunday", "start_date", "end_date"], [["daily", 1, 1, 1, 1, 1, 1, 1, "20260101", "20271231"]])
    put("trips.txt", ["route_id", "service_id", "trip_id"], [[r["id"], "daily", r["id"] + "-t"] for r in net["routes"]])
    st_rows, fr = [], []
    ids = [r[0] for r in net["stops"]["rows"]]
    for r in net["routes"]:
        hw, spd, dwell = E.DEFAULTS.get(r["mode"], E.DEFAULTS["bus"])
        spd, hw, dwell = r.get("spd", spd), r.get("hw", hw), r.get("dwell", dwell)
        t = 0.0
        for k, si in enumerate(r["stops"]):
            if k:
                t += (r["km"][k] - r["km"][k - 1]) * 3600.0 / spd + dwell
            hh = "%02d:%02d:%02d" % (int(t // 3600), int(t % 3600 // 60), int(t % 60))
            st_rows.append([r["id"] + "-t", hh, hh, ids[si], k + 1, round(r["km"][k], 3)])
        fr.append([r["id"] + "-t", "06:00:00", "23:00:00", int(hw * 60)])
    put("stop_times.txt", ["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence",
                           "shape_dist_traveled"], st_rows)
    put("frequencies.txt", ["trip_id", "start_time", "end_time", "headway_secs"], fr)
    z.close()


# ------------------------------------------------------------------ measure
def sensible(ans, crow_km):
    if not ans.get("ok"):
        return False, "no route"
    opts = ans["options"]
    best = opts.get("fastest")
    if not best:
        return False, "no option"
    if any(o["fare"]["high"] <= 0 for o in opts.values() if any(
            l["mode"] in E.MODES for l in o["legs"])):
        return False, "missing fare"
    if crow_km >= 3 and not any(l["mode"] in E.MODES for l in best["legs"]):
        return False, "no transit leg"
    if best["walk_m"] > 2500:
        return False, "walk %d m" % best["walk_m"]
    limit = 25 + crow_km * 9          # Dhaka: very generous upper bound (min)
    if best["minutes"] > limit:
        return False, "too slow %d min" % best["minutes"]
    return True, ""


def measure(net, trips):
    nw = E.Network(net)
    out, ok, ms = [], 0, []
    for t in trips:
        (a, b), (c, d) = t["from_ll"], t["to_ll"]
        crow = E.hav(a, b, c, d) / 1000.0
        ans = nw.plan(a, b, c, d, minute=10 * 60 + 30, deadline_s=5.0)
        good, why = sensible(ans, crow)
        ok += good
        ms.append(ans["ms"])
        f = (ans["options"].get("fastest") or {})
        ch = (ans["options"].get("cheapest") or {})
        out.append({"trip": "%s -> %s" % (t["from"], t["to"]), "pass": good, "why": why,
                    "fastest": {"min": f.get("minutes"), "fare": f.get("fare"), "modes": f.get("modes")},
                    "cheapest": {"min": ch.get("minutes"), "fare": ch.get("fare"), "modes": ch.get("modes")},
                    "ms": ans["ms"]})
    ms.sort()
    return {"pass": ok, "total": len(trips), "p50_ms": ms[len(ms) // 2] if ms else 0,
            "p95_ms": ms[int(len(ms) * 0.95) - 1] if ms else 0, "max_ms": ms[-1] if ms else 0,
            "trips": out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--city", required=True)
    ap.add_argument("--pbf", required=True)
    ap.add_argument("--public", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--osm-timestamp", default="")
    a = ap.parse_args()
    seeds = {}
    sd = os.path.join(HERE, "seed")
    if a.city == "dhaka":
        seeds["metro"] = json.load(open(os.path.join(sd, "dhaka_metro.json")))
    public = json.load(open(a.public)) if a.public and os.path.exists(a.public) else {}
    t0 = time.time()
    osm = read_osm(a.pbf)
    print("osm read %.1fs: %d route rels, %d stop nodes, %d entrances, %d poi, %d places" % (
        time.time() - t0, len(osm["rels"]), len(osm["stopn"]), len(osm["entr"]), len(osm["poi"]),
        len(osm["places"])))
    b = Builder(a.city, osm, public, seeds)
    b.osm_routes()
    b.metro()
    b.public_routes()
    b.cross_match()
    content = hashlib.sha256(json.dumps([b.routes, [dict(s, src=sorted(s["src"])) for s in b.stops]],
                                        sort_keys=True, default=str).encode()).hexdigest()[:12]
    version = time.strftime("%Y%m%d", time.gmtime()) + "-" + content
    net = b.network(version, a.osm_timestamp)
    cov, cells = b.coverage(net)
    modes = defaultdict(int)
    for r in net["routes"]:
        modes[r["mode"]] += 1
    bus_names = {(r["name"] or r["ref"]) for r in net["routes"] if r["mode"] == "bus"}
    counts = {"routes": len(net["routes"]), "bus_routes_named": len(bus_names),
              "by_mode": dict(modes), "stops": len(net["stops"]["rows"]),
              "stations": sum(1 for r in net["stops"]["rows"] if r[5] == "metro"),
              "gates": len(net["gates"]),
              "verified_routes": sum(1 for r in net["routes"] if r["st"] == "v"),
              "verified_stops": sum(1 for r in net["stops"]["rows"] if r[6] == "v"),
              "coverage_pct": cov, "coverage_cells_1km": cells,
              "osm_route_relations": len(osm["rels"]),
              "public_routes_crawled": len(public.get("bus_routes", [])),
              "cross_matched": getattr(b, "cross", 0)}
    net["counts"] = counts
    os.makedirs(a.out, exist_ok=True)
    blob = gzip.compress(json.dumps(net, ensure_ascii=False, separators=(",", ":")).encode(), 9)
    with open(os.path.join(a.out, "transit_%s.json.gz" % a.city), "wb") as fh:
        fh.write(blob)
    write_gtfs(net, os.path.join(a.out, "gtfs_%s.zip" % a.city))
    dirs = {"city": a.city, "attribution": ATTRIBUTION, "items": osm["dirs"]}
    seed_dir = os.path.join(sd, "directory_%s.json" % a.city)
    if os.path.exists(seed_dir):
        dirs["items"] = merge_directory(json.load(open(seed_dir))["items"], osm["dirs"])
    with open(os.path.join(a.out, "directory_%s.json.gz" % a.city), "wb") as fh:
        fh.write(gzip.compress(json.dumps(dirs, ensure_ascii=False).encode(), 9))
    report = {"city": a.city, "version": version, "counts": counts, "bytes": len(blob),
              "gaps": {k: v[:60] for k, v in b.gaps.items()},
              "gap_counts": {k: len(v) for k, v in b.gaps.items()},
              "directory": {k: sum(1 for i in dirs["items"] if i["kind"] == k)
                            for k in ("terminal", "ghat", "office")},
              "crawl_errors": public.get("errors", [])[:30]}
    top = os.path.join(sd, "top50_%s.json" % a.city)
    if os.path.exists(top):
        report["top50"] = measure(net, json.load(open(top))["trips"])
    with open(os.path.join(a.out, "report_%s.json" % a.city), "w") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
    print(json.dumps({k: report[k] for k in ("counts", "bytes", "gap_counts", "directory")}, ensure_ascii=False))
    if "top50" in report:
        t = report["top50"]
        print("TOP50 %d/%d pass, p50 %d ms, p95 %d ms, max %d ms" % (t["pass"], t["total"], t["p50_ms"],
                                                                     t["p95_ms"], t["max_ms"]))
        for x in t["trips"]:
            print(" ", "PASS" if x["pass"] else "FAIL", x["trip"], x["why"], x["fastest"]["min"],
                  (x["fastest"]["fare"] or {}).get("high"), x["fastest"]["modes"])


def merge_directory(seed_items, osm_items):
    """Seed (public documents) + OSM: same kind within 400 m and similar
    name -> one item with both sources -> Verified."""
    out = [dict(i) for i in seed_items]
    for o in osm_items:
        hit = None
        for s in out:
            if s["kind"] == o["kind"] and s.get("lat") and hav(s["lat"], s["lon"], o["lat"], o["lon"]) < 400:
                a, b = norm(s["name"]), norm(o["name"])
                if a and b and (a in b or b in a or a.split(" ")[0] == b.split(" ")[0]):
                    hit = s
                    break
        if hit:
            hit["sources"] = hit.get("sources", []) + o["sources"]
            hit["status"] = "v"
            for k in ("hours", "phone", "address"):
                if not hit.get(k) and o.get(k):
                    hit[k] = o[k]
        else:
            out.append(o)
    for s in out:
        if len({x.get("s") for x in s.get("sources", [])}) >= 2:
            s["status"] = "v"
    return out


if __name__ == "__main__":
    main()
