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
    "dhaka": {"bbox": [23.58, 90.18, 24.06, 90.62], "core": [23.69, 90.33, 23.90, 90.46]},
    "chattogram": {"bbox": [22.20, 91.70, 22.45, 91.95], "core": [22.28, 91.76, 22.42, 91.88]},
}
MODE_OF = {"bus": "bus", "minibus": "bus", "trolleybus": "bus", "share_taxi": "leguna",
           "ferry": "water", "subway": "metro", "light_rail": "metro", "monorail": "metro",
           "train": "rail"}
STOP_ROLE = re.compile(r"^(stop|platform)(_entry_only|_exit_only)?(:\d+)?$")
PLACE_KINDS = ("suburb", "neighbourhood", "quarter", "locality", "village", "hamlet", "square",
               "town", "city", "borough", "city_block", "isolated_dwelling")
ROAD_KINDS = ("trunk", "primary", "secondary", "tertiary", "trunk_link", "primary_link", "motorway")
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


def publishers(srcs):
    """citycov: distinct publishers (web sites) among a route's sources."""
    out = set()
    for x in srcs or ():
        if x.get("snippet"):
            continue          # seen only in a search snippet: not counted
        host = re.sub(r"^https?://(www\.|m\.|en\.|bn\.)?", "", str(x.get("url") or "")).split("/")[0].lower()
        if host:
            out.add(host)
    return out


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
            rels[r.id] = {"tags": {tg.k: tg.v for tg in t}, "members": mem}
            for typ, ref, _role in mem:
                if typ == "w":
                    need_ways.add(ref)
                elif typ == "n":
                    need_nodes.add(ref)

    R().apply_file(pbf)
    nodes, ways, stopn, poi, entr, elev, places, stations, dirs = {}, {}, {}, [], [], [], [], [], []
    steps = []           # citydata2: (lat0, lon0, lat1, lon1, escalator?) of highway=steps ways

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
            if is_entrance(t):
                entr.append({"id": n.id, "lat": lat, "lon": lon, "ref": t.get("ref", ""),
                             "name": t.get("name", ""), "name_bn": t.get("name:bn", ""),
                             "wheelchair": t.get("wheelchair", ""), "level": t.get("level", "")})
            if t.get("highway") == "elevator" or t.get("railway") == "elevator":
                elev.append((lat, lon))
            if t.get("place") in PLACE_KINDS and name:
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
            stp = t.get("highway") == "steps" or t.get("highway") == "elevator"
            plc = bool(t.get("name") and (t.get("place") in PLACE_KINDS or t.get("highway") in ROAD_KINDS
                                          or t.get("bridge") == "yes" and t.get("highway")))
            if not (want or named_poi or dk or stp or plc):
                return
            try:
                pts = [(nd.location.lat, nd.location.lon) for nd in w.nodes if nd.location.valid()]
            except Exception:
                return
            if not pts:
                return
            if want:
                ways[w.id] = {"pts": pts, "ends": (w.nodes[0].ref, w.nodes[-1].ref)}
            if stp and len(pts) >= 2:
                if t.get("highway") == "elevator":
                    elev.append((pts[0][0], pts[0][1]))
                else:
                    steps.append((pts[0][0], pts[0][1], pts[-1][0], pts[-1][1],
                                  bool(t.get("conveying")) and t.get("conveying") != "no"))
            if plc:
                # citydata2: named places mapped as areas + named main roads /
                # bridges ("Ring Road", "300 Feet", "Rampura Bridge"): a few
                # points along the way, so the path matcher can pick the right one.
                step = max(1, len(pts) // 4)
                for (la, lo) in (pts[::step] if t.get("highway") else
                                 [(sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))]):
                    places.append({"id": w.id, "lat": la, "lon": lo, "name": t.get("name"),
                                   "name_bn": t.get("name:bn", ""), "name_en": t.get("name:en", ""),
                                   "road": bool(t.get("highway"))})
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
            "entr": entr, "elev": elev, "places": places, "stations": stations, "dirs": dirs,
            "steps": steps}


def is_entrance(t):
    """Metro / station entrance node in OSM (several tagging styles)."""
    if t.get("railway") in ("subway_entrance", "train_station_entrance"):
        return True
    if t.get("entrance") and (t.get("railway") or t.get("public_transport") or t.get("subway")
                              or t.get("station") or t.get("train")):
        return True
    return False


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


COMPASS_EN = {"N": "North", "S": "South", "E": "East", "W": "West"}
COMPASS_BN = {"N": "উত্তর", "S": "দক্ষিণ", "E": "পূর্ব", "W": "পশ্চিম"}
# what a passenger asks for at an exit, most useful first; street furniture never
NEAR_TOP = {"hospital", "clinic", "university", "college", "school", "marketplace", "mall",
            "supermarket", "department_store", "bank", "police", "place_of_worship", "townhall",
            "government", "courthouse", "bus_station", "cinema", "park", "stadium", "library",
            "post_office", "fuel", "pharmacy", "hotel", "museum"}
NEAR_SKIP = {"bench", "waste_basket", "parking_entrance", "vending_machine", "atm", "toilets",
             "bicycle_parking", "parking", "yes", "construction", "drinking_water", "shelter"}


def axis(lat0, lon0, lat1, lon1):
    """Unit vector (east, north) along the metro line in local metres."""
    dx = (lon1 - lon0) * 111320.0 * math.cos(math.radians(lat0))
    dy = (lat1 - lat0) * 110540.0
    n = math.hypot(dx, dy) or 1.0
    return dx / n, dy / n


def side_of(ax, lat0, lon0, lat, lon):
    """+1 = left of the line direction, -1 = right."""
    px = (lon - lon0) * 111320.0 * math.cos(math.radians(lat0))
    py = (lat - lat0) * 110540.0
    return 1 if ax[0] * py - ax[1] * px >= 0 else -1


def offset(lat0, lon0, ax, side, m):
    """Point m metres to the left (+1) / right (-1) of the line."""
    nx, ny = -ax[1] * side, ax[0] * side
    return (lat0 + ny * m / 110540.0, lon0 + nx * m / (111320.0 * math.cos(math.radians(lat0))))


def cluster(pts, r):
    out = []
    for p in pts:
        for c in out:
            if hav(c[0][0], c[0][1], p[0], p[1]) < r:
                c.append(p)
                break
        else:
            out.append([p])
    return out


def near_pois(grid, lat, lon, r, keep=None, limit=8):
    """[name, name_bn, category, metres] — landmarks first, then the rest."""
    seen, top, rest = set(), [], []
    for d, p in grid.near(lat, lon, r):
        if p[4] in NEAR_SKIP or not p[2] or p[2].lower() in seen:
            continue
        low = p[2].lower()
        if "metro station" in low or "metro rail" in low or "মেট্রো" in p[2]:
            continue                      # the station itself is not "near the exit"
        if keep and not keep(p[0], p[1]):
            continue
        seen.add(p[2].lower())
        (top if p[4] in NEAR_TOP else rest).append([p[2], p[3], p[4], int(d)])
    return (top + rest)[:limit]


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
        """Name -> candidate points: OSM bus stops (best), metro stations,
        named places/junctions, then named POIs (markets, colleges, cinema
        halls...), plus the curated alias list (public spelling -> OSM)."""
        g, gb = defaultdict(list), defaultdict(list)

        def add(prio, lat, lon, sid, names, name_en, name_bn):
            c = (prio, lat, lon, sid, name_en, name_bn)
            for nm in set(n for n in names if n):
                g[norm(nm)].append(c)
            if name_bn:
                gb[norm_bn(name_bn)].append(c)

        for nid, s in self.osm["stopn"].items():
            add(0, s["lat"], s["lon"], "n%d" % nid, (s["name"], s.get("name_en")),
                s["name_en"] or s["name"], s["name_bn"])
        for s in self.stops:
            if s["kind"] == "metro":
                add(1, s["lat"], s["lon"], s["id"], (s["name"],), s["name"], s["name_bn"])
        for p in self.osm["places"]:
            add(4 if p.get("road") else 2, p["lat"], p["lon"],
                "p%d:%.4f,%.4f" % (p["id"], p["lat"], p["lon"]), (p["name"], p.get("name_en")),
                p["name_en"] or p["name"], p["name_bn"])
        for lat, lon, name, name_bn, _cat in self.osm["poi"]:
            add(3, lat, lon, "q%.5f,%.5f" % (lat, lon), (name,), name, name_bn)
        # citydata2: coordinates of the listed place names from Wikipedia's
        # public API (crawl_public.py) — for suburbs OSM names differently
        for nm, w in (self.public.get("wiki_places") or {}).items():
            add(3, w["lat"], w["lon"], "w%.5f,%.5f" % (w["lat"], w["lon"]), (nm, w.get("title", "")),
                nm, "")
        bb = self.cfg["bbox"]
        inb = lambda c: bb[0] <= c[1] <= bb[2] and bb[1] <= c[2] <= bb[3]
        self.gz = {k: [c for c in v if inb(c)] for k, v in g.items()}
        self.gzb = {k: [c for c in v if inb(c)] for k, v in gb.items()}
        self.gz = {k: v for k, v in self.gz.items() if v}
        self.gkeys = sorted(self.gz)
        self.alias = {norm(k): [norm(x) for x in v]
                      for k, v in (self.seeds.get("aliases") or {}).items() if not k.startswith("_")}
        self.gfirst = defaultdict(list)
        for k in self.gkeys:
            self.gfirst[k[:2]].append(k)
        self.fuzzy_hits = {}

    def candidates(self, en, bn):
        import bisect
        import difflib
        n = norm(en)
        out = list(self.gz.get(n, [])) + list(self.gzb.get(norm_bn(bn), []))
        names = [n] + self.alias.get(n, [])
        # "Savar (Bus Stand)" -> also try "savar"; "Mirpur-1" -> "mirpur 1"
        if "(" in (en or ""):
            names.append(norm(re.sub(r"\(.*?\)", " ", en)))
            names += [norm(x) for x in re.findall(r"\(([^()]+)\)", en)]
        for a in names[1:]:
            out += self.gz.get(a, [])
        if not out:
            for a in [x for x in names if x]:
                i = bisect.bisect_left(self.gkeys, a + " ")
                for k in self.gkeys[i:i + 12]:
                    if not k.startswith(a + " "):
                        break
                    out += self.gz[k]
                out += self.gz.get(a.replace(" ", ""), [])
        if not out and len(n) >= 5:
            # spelling variants (Purobi/Purabi, Baipayl/Baipail): close names
            # only, lower priority; the path matcher still has to agree.
            for a in [x for x in names if len(x) >= 5]:
                for k in difflib.get_close_matches(a, self.gfirst.get(a[:2], ()), n=3, cutoff=0.84):
                    out += [(c[0] + 1,) + tuple(c[1:]) for c in self.gz[k]]
                    self.fuzzy_hits[a] = k
        out = [c for c in out]
        # best few per priority, dedup by id
        seen, res = set(), []
        for c in sorted(out, key=lambda c: c[0]):
            if c[3] not in seen:
                seen.add(c[3])
                res.append(c)
        return res[:15]

    def match_sequence(self, stops):
        """Viterbi over each listed stop's candidates: the chain with the
        least travel (km) + 2.5 km per skipped stop + a small penalty for
        weaker name sources. Fixes wrong homonyms far away."""
        # citydata2: a skipped stop costs as much as ~14 km of travel, so far
        # suburban stops (Savar, Hemayetpur, Gazipur) are no longer dropped;
        # distance still decides between same-name places.
        SKIP, MAXD, PER_KM = 5.0, 16000.0, 0.35
        states = []          # per stop: list of (cost, cand, back)
        for i, (en, bn) in enumerate(stops):
            row = []
            for c in self.candidates(en, bn):
                best = (i * SKIP + c[0] * 0.3, None)
                for j in range(max(0, i - 4), i):
                    for k, (cost, d, _b) in enumerate(states[j]):
                        dist = hav(d[1], d[2], c[1], c[2])
                        if dist > MAXD or d[3] == c[3]:
                            continue
                        v = cost + dist / 1000.0 * PER_KM + (i - j - 1) * SKIP + c[0] * 0.3
                        if v < best[0]:
                            best = (v, (j, k))
                row.append((best[0], c, best[1]))
            states.append(row)
        end, n = None, len(stops)
        for i, row in enumerate(states):
            for k, (cost, c, b) in enumerate(row):
                v = cost + (n - 1 - i) * SKIP
                if end is None or v < end[0]:
                    end = (v, (i, k))
        if end is None:
            return [], [en or bn for en, bn in stops]
        path, cur = [], end[1]
        while cur is not None:
            i, k = cur
            path.append((i, states[i][k][1]))
            cur = states[i][k][2]
        path.reverse()
        got = {i for i, _c in path}
        miss = [(stops[i][0] or stops[i][1]) for i in range(n) if i not in got]
        return path, miss

    def public_routes(self):
        self.gazetteer()
        self.second = {"crawled": len(self.public.get("bus_routes_2", [])), "agreed": 0, "new": 0,
                       "unmatched": 0}
        for pr in self.public.get("bus_routes", []):
            self.add_public(pr)
        # citydata2: a second, separately published route list. A route both
        # lists agree on (same company, mostly the same stops) -> Verified.
        for pr in self.public.get("bus_routes_2", []):
            pts = self.match_public(pr, log=False)
            if pts is None:
                self.second["unmatched"] += 1
                continue
            hit = self.agreeing_route(pr, pts)
            if hit:
                self.second["agreed"] += 1
                src = {"s": pr["source"], "url": pr["source_url"], "date": pr["fetched"]}
                for r in self.routes:
                    if r.get("_grp") == hit and src not in r["src"]:
                        r["src"] = r["src"] + [src]
                        r["_v"] = True
            else:
                self.second["new"] += 1
                self.add_public(pr, pts)
        for pr in (self.seeds.get("women") or {}).get("routes", []):
            self.add_public(dict(pr, counters=[]), women=True)
        # citycov: leguna (human hauler) and BRTC / Dhaka Nagar Paribahan
        # routes from news, BRTC lists and Wikipedia (seed/dhaka_leguna_brtc.json,
        # each with its source links). Verified only when 2+ independent
        # publishers (different sites) list the same route; else Reported.
        self.extra_routes = defaultdict(int)
        for pr in (self.seeds.get("leguna_brtc") or {}).get("routes", []):
            srcs = pr.get("sources") or []
            if not srcs or not pr.get("stops"):
                continue
            pr = dict(pr, counters=[], source=srcs[0]["s"], source_url=srcs[0]["url"],
                      fetched=srcs[0].get("date", ""))
            n0 = len(self.routes)
            self.add_public(pr, mode=pr.get("mode") or "bus")
            if len(self.routes) > n0:
                self.extra_routes[pr.get("mode") or "bus"] += 1
                if len(publishers(srcs)) >= 2:
                    for r in self.routes[n0:]:
                        r["_v"] = True
                    self.extra_routes["verified"] += 1

    def match_public(self, pr, log=True):
        path, miss = self.match_sequence(pr["stops"])
        pts = []
        for i, m in path:
            en, bn = pr["stops"][i]
            if pts and pts[-1][3] == m[3]:
                continue
            pts.append((m[1], m[2], en or m[4], m[3], bn or m[5], ""))
        if len(pts) < 3 or len(pts) < 0.5 * len(pr["stops"]):
            if log:
                self.gaps["public_route_unmatched"].append(
                    {"company": pr["company"], "url": pr["source_url"], "missing": miss[:12],
                     "matched": len(pts), "listed": len(pr["stops"])})
            return None
        if miss and log:
            self.gaps["public_stop_unmatched"].append({"company": pr["company"], "missing": miss[:12]})
        return pts

    def agreeing_route(self, pr, pts):
        """Group id of an already listed route of the same company whose
        stops mostly agree (>= 60 % of the shorter list within 400 m, and 3+
        stops) — i.e. the two public lists describe the same route."""
        ck = company_key(pr["company"])
        if not ck:
            return None
        best = None
        for r in self.routes:
            if not r["id"].startswith("pub-") or not r["id"].endswith("-a") or not r.get("_ck"):
                continue
            if ck != r["_ck"] and not (len(ck) >= 4 and len(r["_ck"]) >= 4 and (ck in r["_ck"] or r["_ck"] in ck)):
                continue
            rs = [self.stops[i] for i in r["stops"]]
            shared = sum(1 for p in pts if any(hav(p[0], p[1], q["lat"], q["lon"]) < 400 for q in rs))
            frac = shared / float(min(len(pts), len(rs)))
            if shared >= 3 and frac >= 0.6 and (best is None or frac > best[0]):
                best = (frac, r["_grp"])
        return best[1] if best else None

    def densify(self, pts):
        """citydata2: OSM bus stops lying on the straight run between two
        listed stops (<= 45 m off the line, not at the ends) are stops the
        bus passes too. They keep OSM as their only source (Reported)."""
        out = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            d = hav(a[0], a[1], b[0], b[1])
            if 250 <= d <= 4000:
                mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
                kx = 111320.0 * math.cos(math.radians(a[0]))
                bx, by = (b[1] - a[1]) * kx, (b[0] - a[0]) * 110540.0
                seg2 = bx * bx + by * by
                found = []
                for _dd, nid in self.sgrid.near(mid[0], mid[1], d / 2 + 60):
                    st = self.osm["stopn"][nid]
                    nm = st.get("name_en") or st.get("name")
                    if not nm:
                        continue
                    px, py = (st["lon"] - a[1]) * kx, (st["lat"] - a[0]) * 110540.0
                    t = (px * bx + py * by) / seg2
                    off = abs(px * by - py * bx) / math.sqrt(seg2)
                    if 0.0 < t < 1.0 and off <= 45 and t * math.sqrt(seg2) > 150 and (1 - t) * math.sqrt(seg2) > 150:
                        found.append((t, st["lat"], st["lon"], nm, "n%d" % nid, st.get("name_bn", "")))
                found.sort()
                last = a
                for t, la, lo, nm, sid, nb in found:
                    if hav(last[0], last[1], la, lo) < 150 or sid in (a[3], b[3]):
                        continue
                    out.append((la, lo, nm, sid, nb, "dense"))
                    last = (la, lo)
            out.append(b)
        return out

    def add_public(self, pr, pts=None, women=False, mode="bus"):
        if pts is None:
            pts = self.match_public(pr)
            if pts is None:
                return
        pts = self.densify(pts)
        self.dense = getattr(self, "dense", 0) + sum(1 for p in pts if p[5] == "dense")
        km, acc = [0.0], 0.0
        for i in range(1, len(pts)):
            acc += hav(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]) * 1.25 / 1000.0
            km.append(acc)
        base = re.sub(r"[^a-z0-9]+", "-", pr["company"].lower()).strip("-")[:32] + "-" + \
            hashlib.sha1((pr["source_url"] + "|" + "|".join(e or b for e, b in pr["stops"])).encode()).hexdigest()[:6]
        grp = ("women-" if women else "leg-" if mode == "leguna" else "pub-") + base
        if any(r.get("_grp") == grp for r in self.routes):
            return
        for direction, seq, kk in (("a", pts, km), ("b", pts[::-1], [km[-1] - x for x in km[::-1]])):
            idx = []
            for p in seq:
                sid = p[3] if p[3][0] in "nm" else "s" + hashlib.sha1(p[3].encode()).hexdigest()[:10]
                i = self.stop(sid, p[2], p[4], p[0], p[1], mode, "osm" if p[5] == "dense" else "public")
                if p[3].startswith("n") and p[5] != "dense":   # an OSM bus-stop node: 2nd source
                    self.stops[i]["src"].add("osm")
                idx.append(i)
            src = [{"s": s_["s"], "url": s_["url"], "date": s_["date"]} for s_ in pr.get("sources", [])] or \
                [{"s": pr["source"], "url": pr["source_url"], "date": pr["fetched"]}]
            r = {
                "id": "%s-%s" % (grp, direction), "mode": mode, "name": pr["company"],
                "name_bn": pr.get("company_bn", ""), "ref": pr.get("ref", ""), "op": pr.get("op") or pr["company"],
                "from": seq[0][2], "to": seq[-1][2], "src": src,
                "stops": idx, "km": [round(x, 3) for x in kk], "_ck": company_key(pr["company"]),
                "_grp": grp, "counters": [c[0] or c[1] for c in pr.get("counters") or []][:20],
            }
            if women:
                r.update({"women_only": True, "hw": pr.get("hw", 40), "hours": pr.get("hours", ""),
                          "note": pr.get("note", "")})
                if len({x["url"] for x in src}) >= 2:
                    r["_v"] = True
            self.routes.append(r)

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
        self.metro_idx = idx          # gates() runs after all bus routes exist (main)

    def gates(self):
        """citydata2: exits for EVERY MRT-6 station.
        1. entrances mapped in OSM (railway=subway_entrance / entrance=*),
        2. else the ground landings of mapped stairs / escalators (OSM
           highway=steps, conveying=*) grouped per side of the line,
        3. else one exit per side of the road: every MRT-6 station is built
           over the road with stairs, escalators and lifts down to the
           footpaths (Prothom Alo, bdnews24 28 Dec 2022, TBS) — position is
           derived from the line, so it stays "Reported" with basis
           "side_rule" until someone confirms the gate number on site."""
        eg = Grid()
        for e in self.osm["entr"]:
            eg.add(e["lat"], e["lon"], e)
        sg = Grid()
        for st in self.osm.get("steps", ()):
            sg.add((st[0] + st[2]) / 2, (st[1] + st[3]) / 2, st)
        self.pg = Grid(0.003)
        for p in self.osm["poi"]:
            self.pg.add(p[0], p[1], p)
        self.gate_list = []
        self.gate_basis = defaultdict(int)
        n = len(self.metro_idx)
        for k, si in enumerate(self.metro_idx):
            s = self.stops[si]
            a_ = self.stops[self.metro_idx[max(0, k - 1)]]
            b_ = self.stops[self.metro_idx[min(n - 1, k + 1)]]
            ax = axis(a_["lat"], a_["lon"], b_["lat"], b_["lon"])
            got = {+1: 0, -1: 0}
            for d, e in eg.near(s["lat"], s["lon"], 250):
                side = side_of(ax, s["lat"], s["lon"], e["lat"], e["lon"])
                got[side] += 1
                self.add_gate(si, e["ref"] or e["name"], e["name"], e["name_bn"], e["lat"], e["lon"], side,
                              any(hav(e["lat"], e["lon"], la, lo) < 40 for la, lo in self.osm["elev"]) or None,
                              None, e["wheelchair"] or None, "osm",
                              "https://www.openstreetmap.org/node/%d" % e["id"])
            # landings of stairs / escalators within 120 m, per side
            land = []
            for d, st in sg.near(s["lat"], s["lon"], 140):
                d0 = hav(s["lat"], s["lon"], st[0], st[1])
                d1 = hav(s["lat"], s["lon"], st[2], st[3])
                la, lo = (st[0], st[1]) if d0 > d1 else (st[2], st[3])
                if 8 <= max(d0, d1) <= 140:
                    land.append((la, lo, st[4]))
            for side in (+1, -1):
                if got[side]:
                    continue
                pts = [p for p in land if side_of(ax, s["lat"], s["lon"], p[0], p[1]) == side]
                for cl in cluster(pts, 45):
                    la = sum(p[0] for p in cl) / len(cl)
                    lo = sum(p[1] for p in cl) / len(cl)
                    got[side] += 1
                    self.add_gate(si, "", "", "", la, lo, side,
                                  any(hav(la, lo, x, y) < 45 for x, y in self.osm["elev"]) or None,
                                  any(p[2] for p in cl) or None, None, "osm_steps",
                                  "https://www.openstreetmap.org/#map=19/%.5f/%.5f" % (la, lo))
            for side in (+1, -1):
                if got[side]:
                    continue
                la, lo = offset(s["lat"], s["lon"], ax, side, 28.0)
                self.add_gate(si, "", "", "", la, lo, side, None, None, None, "side_rule", "")
            if not any(e for _d, e in eg.near(s["lat"], s["lon"], 250)):
                self.gaps["metro_gates_not_mapped"].append(s["name"])

    def add_gate(self, si, ref, name, name_bn, lat, lon, side, lift, escalator, wheelchair, basis, src):
        s = self.stops[si]
        compass = E.bearing_side(s["lat"], s["lon"], lat, lon)
        if not name:
            name = "%s side exit" % COMPASS_EN[compass]
            name_bn = "%s পাশের বের হওয়ার পথ" % COMPASS_BN[compass]
        near = near_pois(self.pg, lat, lon, 260, lambda la, lo: side_of(
            self._ax_cache(si), s["lat"], s["lon"], la, lo) == side)
        stands = []
        for d, nid in self.sgrid.near(lat, lon, 350):
            st = self.osm["stopn"][nid]
            if "n%d" % nid in self.stop_ix and side_of(self._ax_cache(si), s["lat"], s["lon"],
                                                         st["lat"], st["lon"]) == side:
                stands.append(self.stop_ix["n%d" % nid])
            if len(stands) >= 5:
                break
        self.gate_basis[basis] += 1
        self.gate_list.append({
            "st": si, "ref": ref, "name": name, "name_bn": name_bn,
            "lat": round(lat, 6), "lon": round(lon, 6), "side": compass,
            "near": near, "stands": stands, "lift": lift, "escalator": escalator,
            "wheelchair": wheelchair, "status": "reported", "basis": basis, "src": src,
        })

    def _ax_cache(self, si):
        c = getattr(self, "_axc", None)
        if c is None:
            c = self._axc = {}
        if si not in c:
            k = self.metro_idx.index(si)
            n = len(self.metro_idx)
            a_ = self.stops[self.metro_idx[max(0, k - 1)]]
            b_ = self.stops[self.metro_idx[min(n - 1, k + 1)]]
            c[si] = axis(a_["lat"], a_["lon"], b_["lat"], b_["lon"])
        return c[si]

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
                           {"s": "dmtcl", "url": "https://dmtcl.gov.bd/"},
                           {"s": "dhakabusroute.com", "licence": "public web page (facts only)",
                            "url": "https://www.dhakabusroute.com/"},
                           {"s": "news (BRTC pink bus routes)",
                            "url": "https://thereport.live/metropolitan/new-pink-bus-service-for-women-starts-today-check-the-routes/41332"}],
               "stops": {"cols": ["id", "name", "name_bn", "lat", "lon", "kind", "st", "code"], "rows": rows},
               "routes": routes, "gates": gates}
        if self.seeds.get("metro") and self.city == "dhaka":
            net["metro"] = {k: self.seeds["metro"].get(k) for k in ("line", "service", "recharge", "facilities")}
        return net

    def coverage_osm(self):
        """Same grid, but every OSM bus stop counts (even ones no known
        route serves yet) — shows how much trip learning can still add."""
        rows = [[0, 0, 0, s["lat"], s["lon"]] for s in self.osm["stopn"].values()
                if s["t"].get("highway") == "bus_stop" or s["t"].get("public_transport") == "platform"]
        return self.coverage({"stops": {"rows": rows}})[0]

    def coverage_built(self, net):
        """Coverage over BUILT-UP 1-km cells only (a cell with a named
        neighbourhood / place, or 5+ named shops, offices, schools...): the
        river, airport, cantonment and wetland cells have nobody to serve."""
        c = self.cfg["core"]
        step_lat, step_lon = 0.009, 0.0098
        dens = defaultdict(int)
        for p in self.osm["poi"]:
            dens[(int((p[0] - c[0]) // step_lat), int((p[1] - c[1]) // step_lon))] += 1
        for p in self.osm["places"]:
            if not p.get("road"):
                dens[(int((p["lat"] - c[0]) // step_lat), int((p["lon"] - c[1]) // step_lon))] += 5
        g = Grid()
        for row in net["stops"]["rows"]:
            g.add(row[3], row[4], 1)
        tot = hit = 0
        ny = int(round((c[2] - c[0]) / step_lat))
        nx = int(round((c[3] - c[1]) / step_lon))
        empty = []
        for a in range(ny):
            for b in range(nx):
                if dens.get((a, b), 0) < 5:
                    continue
                lat = c[0] + (a + 0.5) * step_lat
                lon = c[1] + (b + 0.5) * step_lon
                tot += 1
                if g.near(lat, lon, 700):
                    hit += 1
                else:
                    empty.append([round(lat, 4), round(lon, 4), dens[(a, b)]])
        empty.sort(key=lambda e: -e[2])
        self.built_cells = sorted(k for k, v in dens.items() if v >= 5 and 0 <= k[0] < ny and 0 <= k[1] < nx)
        return round(100.0 * hit / max(1, tot), 1), tot, empty[:40]

    def coverage_both(self, net):
        """citycov: the headline stop measure again (shared engine code, must
        equal coverage()) + the separate corridor measure, all and built-up."""
        pts = [(r[3], r[4]) for r in net["stops"]["rows"]]
        segs = []
        for r in net["routes"]:
            if r["mode"] in ("metro", "rail") or r.get("women_only"):
                continue
            for a, b in zip(r["stops"], r["stops"][1:]):
                ra, rb = net["stops"]["rows"][a], net["stops"]["rows"][b]
                segs.append((ra[3], ra[4], rb[3], rb[4]))
        path = E.corridor_points(segs)
        core = self.cfg["core"]
        allc = E.coverage(core, pts, path)
        built = E.coverage(core, pts, path, set(map(tuple, getattr(self, "built_cells", []))))
        return allc, built

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
    rick = sum(1 for x in out if "rickshaw" in (x["fastest"]["modes"] or []))
    return {"pass": ok, "total": len(trips), "fastest_with_rickshaw": rick, "p50_ms": ms[len(ms) // 2] if ms else 0,
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
        seeds["aliases"] = json.load(open(os.path.join(sd, "dhaka_aliases.json")))
        seeds["women"] = json.load(open(os.path.join(sd, "dhaka_women_buses.json")))
        lb = os.path.join(sd, "dhaka_leguna_brtc.json")
        if os.path.exists(lb):
            seeds["leguna_brtc"] = json.load(open(lb))
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
    if getattr(b, "metro_idx", None):
        b.gates()
    content = hashlib.sha256(json.dumps([b.routes, [dict(s, src=sorted(s["src"])) for s in b.stops]],
                                        sort_keys=True, default=str).encode()).hexdigest()[:12]
    version = time.strftime("%Y%m%d", time.gmtime()) + "-" + content
    net = b.network(version, a.osm_timestamp)
    cov, cells = b.coverage(net)
    built = b.coverage_built(net)
    both_all, both_built = b.coverage_both(net)
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
              "cross_matched": getattr(b, "cross", 0),
              # citydata2
              "bus_routes": sum(1 for r in net["routes"] if r["mode"] == "bus"),
              "verified_bus_routes": sum(1 for r in net["routes"] if r["mode"] == "bus" and r["st"] == "v"),
              "verified_bus_pct": round(100.0 * sum(1 for r in net["routes"] if r["mode"] == "bus" and r["st"] == "v")
                                        / max(1, sum(1 for r in net["routes"] if r["mode"] == "bus")), 1),
              "second_source": getattr(b, "second", {}),
              "women_routes": sum(1 for r in net["routes"] if r.get("women_only")),
              "stops_added_on_path": getattr(b, "dense", 0),
              "stations_with_gates": len({g["st"] for g in net["gates"]}),
              "gates_by_basis": dict(getattr(b, "gate_basis", {})),
              "coverage_all_osm_stops_pct": b.coverage_osm(),
              "coverage_built_pct": built[0], "coverage_built_cells": built[1],
              "wiki_places": len(public.get("wiki_places") or {}),
              "fuzzy_names": len(getattr(b, "fuzzy_hits", {})),
              "brta_hotlines_found": (public.get("texts", {}).get("brta_home") or {}).get("hotlines", []),
              # citycov: the separate corridor measure (never the headline)
              "coverage_corridor_pct": both_all["corridor_pct"],
              "coverage_built_corridor_pct": both_built["corridor_pct"],
              "coverage_check_same": both_all["stops_pct"] == cov and both_built["stops_pct"] == built[0],
              "leguna_routes": sum(1 for r in net["routes"] if r["mode"] == "leguna"),
              "extra_public_routes": dict(getattr(b, "extra_routes", {}))}
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
              "crawl_errors": public.get("errors", [])[:30],
              "crawl_debug": public.get("debug", {}),
              "built_cells_without_stop": built[2],
              "built_cells": [list(k) for k in getattr(b, "built_cells", [])],
              "fuzzy": dict(list(getattr(b, "fuzzy_hits", {}).items())[:80])}
    top = os.path.join(sd, "top50_%s.json" % a.city)
    if os.path.exists(top):
        report["top50"] = measure(net, json.load(open(top))["trips"])
    with open(os.path.join(a.out, "report_%s.json" % a.city), "w") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
    print(json.dumps({k: report[k] for k in ("counts", "bytes", "gap_counts", "directory")}, ensure_ascii=False))
    if "top50" in report:
        t = report["top50"]
        print("TOP50 %d/%d pass, p50 %d ms, p95 %d ms, max %d ms, fastest with rickshaw %d" % (
            t["pass"], t["total"], t["p50_ms"], t["p95_ms"], t["max_ms"], t["fastest_with_rickshaw"]))
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
