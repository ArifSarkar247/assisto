#!/usr/bin/env python3
"""train — build the bundled Bangladesh rail data (run by hand, NOT at app
build time; the output files are committed so the server and the phone work
offline and never call a third party at run time).

Sources (both openly licensed, both cited inside every output file):
  * rail lines + stations: OpenStreetMap via the Overpass API
    (© OpenStreetMap contributors, ODbL 1.0 — https://www.openstreetmap.org/copyright).
    The app shows this attribution on every train map and in the alarm.
  * intercity train list + per-train schedule tables + stop lists:
    Bangla Wikipedia ("বাংলাদেশের যাত্রীবাহী ট্রেনের তালিকা" and each train's
    article), CC BY-SA 4.0. Each train keeps the article revision id and the
    article's own note on which Bangladesh Railway timetable edition it copies.
    Bangladesh Railway (railway.gov.bd) publishes no machine-readable
    timetable (its "সকল ট্রেনের সময়সূচি" page had no timetable body on
    2026-11-02), so EVERY train is written with "approved": false — the owner
    checks the times against the official printed timetable and flips it.

Outputs:
  backend/core/data/train/rail_bd.json        simplified rail network (validation)
  backend/core/data/train/timetable_bd.json   trains, stops, route path
  app/assets/train/stations_bd.json           stations for the offline alarm

Usage:  python3 tools/train/build_train_data.py [--cache DIR]
(--cache keeps the downloads so a re-run is offline.)
"""
import argparse
import heapq
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

UA = "AssistoTrainData/1.0 (lifeassisto.com; one-off data build)"
OVERPASS = "https://overpass-api.de/api/interpreter"
BNWIKI = "https://bn.wikipedia.org/w/api.php"
LIST_PAGE = "বাংলাদেশের যাত্রীবাহী ট্রেনের তালিকা"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

Q_RAIL = ('[out:json][timeout:180];area["ISO3166-1"="BD"][admin_level=2]->.bd;'
          '(way["railway"~"^(rail|narrow_gauge)$"]["service"!~"."](area.bd););out geom;')
Q_STATIONS = ('[out:json][timeout:120];area["ISO3166-1"="BD"][admin_level=2]->.bd;'
              '(node["railway"~"^(station|halt)$"](area.bd););out;')

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
WEEKDAYS = {"সোমবার": 0, "মঙ্গলবার": 1, "বুধবার": 2, "বৃহস্পতিবার": 3,
            "শুক্রবার": 4, "শনিবার": 5, "রবিবার": 6}
# Plain-text terminal names in schedule tables -> station article title.
ALIAS = {
    "ঢাকা": "কমলাপুর রেলওয়ে স্টেশন", "কমলাপুর": "কমলাপুর রেলওয়ে স্টেশন",
    "চট্টগ্রাম": "চট্টগ্রাম রেলওয়ে স্টেশন",
}
# Station articles WITHOUT coordinates: matched to the OSM station by its
# English name (a translation of the Bangla name, not invented data).
BN_EN = {
    "খুলনা": "Khulna", "কুড়িগ্রাম": "Kurigram", "গোবরা": "Gobra", "চাঁদপুর": "Chandpur",
    "চিলাহাটি": "Chilahati", "ঢালারচর": "Dhalarchar", "দেওয়ানগঞ্জ": "Dewanganj",
    "দেওয়ানগঞ্জ বাজার": "Dewanganj Bazar", "পঞ্চগড়": "Panchagarh", "বুড়িমারী": "Burimari",
    "বেনাপোল": "Benapole", "মোহনগঞ্জ": "Mohanganj", "লালমনিরহাট": "Lalmonirhat",
    "সান্তাহার": "Santahar", "তারাকান্দি": "Tarakandi",
    # terminals whose article coordinates sit closer to a neighbouring station
    "চট্টগ্রাম": "Chattogram Railway Station", "কমলাপুর": "Kamalapur Railway Station",
}


def station_title(name):
    name = re.sub(r"\{\{rws\|([^}|]+)[^}]*\}\}", r"\1", name).strip()
    if name in ALIAS:
        return ALIAS[name]
    if name.endswith("রেলওয়ে স্টেশন"):
        return name
    return name + " রেলওয়ে স্টেশন"


# ------------------------------------------------------------ fetching
def _get(url, data=None, cache=None, key=None):
    if cache and key:
        p = os.path.join(cache, key)
        if os.path.exists(p):
            with open(p, "rb") as fh:
                return fh.read()
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                body = r.read()
            time.sleep(1.5)   # be polite: one request at a time, paced
            break
        except Exception as e:
            if attempt == 4:
                raise
            time.sleep(60 if getattr(e, "code", 0) == 429 else 5)
    if cache and key:
        with open(os.path.join(cache, key), "wb") as fh:
            fh.write(body)
    return body


def overpass(q, cache, key):
    data = urllib.parse.urlencode({"data": q}).encode()
    return json.loads(_get(OVERPASS, data, cache, key))


def wiki(params, cache, key):
    params = dict(params, format="json", formatversion="2")
    url = BNWIKI + "?" + urllib.parse.urlencode(params)
    return json.loads(_get(url, None, cache, key))


def _safe(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s.encode("unicode_escape").decode())[:150]


# ------------------------------------------------------------ geometry
def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = (math.sin((la2 - la1) / 2) ** 2 +
         math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(h)))


def _perp(p, a, b):
    k = 111320.0
    c = math.cos(math.radians(p[0]))
    ax, ay = (a[1] - p[1]) * k * c, (a[0] - p[0]) * k
    bx, by = (b[1] - p[1]) * k * c, (b[0] - p[0]) * k
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L))
    x, y = ax + t * dx, ay + t * dy
    return math.hypot(x, y)


def simplify(pts, tol):
    """Douglas-Peucker (iterative)."""
    if len(pts) < 3:
        return list(pts)
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        best, idx = 0.0, -1
        for k in range(i + 1, j):
            d = _perp(pts[k], pts[i], pts[j])
            if d > best:
                best, idx = d, k
        if best > tol and idx > 0:
            keep[idx] = True
            stack += [(i, idx), (idx, j)]
    return [p for p, k in zip(pts, keep) if k]


def r5(p):
    return [round(p[0], 5), round(p[1], 5)]


# ------------------------------------------------------------ OSM graph
def build_graph(rail):
    coords, adj = {}, {}
    for w in rail["elements"]:
        ns, gs = w.get("nodes") or [], w.get("geometry") or []
        if len(ns) != len(gs) or len(ns) < 2:
            continue
        for n, g in zip(ns, gs):
            coords[n] = (g["lat"], g["lon"])
        for a, b in zip(ns, ns[1:]):
            d = hav(coords[a], coords[b])
            adj.setdefault(a, []).append((b, d))
            adj.setdefault(b, []).append((a, d))
    # OSM ways sometimes stop a few metres short of the line they join (no
    # shared node): bridge each way END to any node of another way within
    # 40 m, so the network is routable across those gaps.
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
        near = {x for _, x in adj.get(e, ())}
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for n in grid.get((i + di, j + dj), ()):
                    if n == e or n in near:
                        continue
                    d = hav(c, coords[n])
                    if d <= 40.0:
                        adj[e].append((n, d))
                        adj.setdefault(n, []).append((e, d))
    return coords, adj


def erase_loops(path):
    """Remove out-and-back spurs: a node seen again cuts the loop."""
    out, seen = [], {}
    for n in path:
        if n in seen:
            k = seen[n]
            for m in out[k + 1:]:
                seen.pop(m, None)
            out = out[:k + 1]
        else:
            seen[n] = len(out)
            out.append(n)
    return out


def nearest_node(coords, p, limit=3000.0):
    best, bn = limit, None
    for n, c in coords.items():
        if abs(c[0] - p[0]) > 0.05 or abs(c[1] - p[1]) > 0.05:
            continue
        d = hav(c, p)
        if d < best:
            best, bn = d, n
    return bn


def dijkstra(adj, a, b):
    dist, prev = {a: 0.0}, {}
    pq = [(0.0, a)]
    while pq:
        d, u = heapq.heappop(pq)
        if u == b:
            break
        if d > dist.get(u, 1e18):
            continue
        for v, w in adj.get(u, ()):
            nd = d + w
            if nd < dist.get(v, 1e18):
                dist[v], prev[v] = nd, u
                heapq.heappush(pq, (nd, v))
    if b not in dist:
        return None
    path = [b]
    while path[-1] != a:
        path.append(prev[path[-1]])
    return path[::-1]


# ------------------------------------------------------------ Wikipedia
def parse_list(wikitext):
    i = wikitext.find("== আন্তঃনগর ট্রেন ==")
    j = wikitext.find("\n==", i + 10)
    sec = wikitext[i:j]
    out = []
    for row in sec.split("|-"):
        m = re.search(r"([০-৯]{3,4})\s*/\s*([০-৯]{3,4})", row)
        lk = re.search(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", row)
        if m and lk and "রেলওয়ে স্টেশন" not in lk.group(1):
            out.append({"pair": (m.group(1).translate(BN_DIGITS),
                                 m.group(2).translate(BN_DIGITS)),
                        "title": lk.group(1).strip()})
    return out


def _cell(s):
    s = re.sub(r"<ref[^>]*/>|<ref.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"\[\[([^\]|]+\|)?([^\]]+)\]\]", r"\2", s)
    s = re.sub(r"^[^|]*\|(?!\|)", "", s) if "rowspan" in s else s
    return re.sub(r"\s+", " ", s).strip()


def parse_article(wt):
    """-> (schedule rows, stop titles, timetable note)"""
    rows, stops, note = [], [], ""
    m = re.search(r"==\s*সময়সূচী\s*==(.*?)(?=\n==[^=])", wt, flags=re.S)
    if m:
        body = m.group(1)
        nm = re.search(r"নিম্নোক্ত সময়সূচী[^।\n]*।", body)
        note = re.sub(r"<ref.*?</ref>|\[\[|\]\]", "", nm.group(0)) if nm else ""
        tbl = re.search(r"\{\|(.*?)\|\}", body, flags=re.S)
        if tbl:
            last_off = None
            for chunk in tbl.group(1).split("|-")[1:]:
                cells = [_cell(c) for c in re.split(r"\n\|", "\n" + chunk.strip())[1:]]
                cells = [c for c in cells if c != ""]
                if len(cells) < 5:
                    continue
                no = cells[0].translate(BN_DIGITS)
                dep, arr = cells[2].translate(BN_DIGITS), cells[4].translate(BN_DIGITS)
                if not (re.fullmatch(r"\d{3,4}", no) and re.fullmatch(r"\d{1,2}:\d{2}", dep)
                        and re.fullmatch(r"\d{1,2}:\d{2}", arr)):
                    continue
                off = cells[5] if len(cells) > 5 else last_off
                last_off = off
                rows.append({"no": no, "from": cells[1], "dep": dep.zfill(5),
                             "to": cells[3], "arr": arr.zfill(5), "off": off or ""})
    s = re.search(r"==\s*যাত্রাবিরতি\s*==(.*?)(?=\n==[^=])", wt, flags=re.S)
    if s:
        for line in s.group(1).splitlines():
            lk = re.search(r"^\s*\*\s*\[\[([^\]|]+)", line)
            if lk:
                stops.append(lk.group(1).strip())
    return rows, stops, note


def off_days(text):
    return sorted({d for k, d in WEEKDAYS.items() if k in (text or "")})


# ------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default="")
    a = ap.parse_args()
    cache = a.cache or None
    if cache:
        os.makedirs(cache, exist_ok=True)

    rail = overpass(Q_RAIL, cache, "osm_rail.json")
    st_raw = overpass(Q_STATIONS, cache, "osm_stations.json")
    osm_date = rail.get("osm3s", {}).get("timestamp_osm_base", "")
    coords, adj = build_graph(rail)

    # ---- rail network (validation): simplified 20 m, 5-decimals
    lines = []
    for w in rail["elements"]:
        g = [(p["lat"], p["lon"]) for p in w.get("geometry") or []]
        if len(g) >= 2:
            lines.append([r5(p) for p in simplify(g, 20.0)])
    meta = {
        "source": "OpenStreetMap (Overpass API), railway=rail|narrow_gauge without service=*, Bangladesh",
        "licence": "ODbL 1.0 — © OpenStreetMap contributors (https://www.openstreetmap.org/copyright)",
        "osm_base": osm_date,
        "built": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "built_by": "tools/train/build_train_data.py",
    }
    os.makedirs(os.path.join(ROOT, "backend/core/data/train"), exist_ok=True)
    with open(os.path.join(ROOT, "backend/core/data/train/rail_bd.json"), "w") as fh:
        json.dump({"_meta": dict(meta, simplify_m=20), "lines": lines}, fh,
                  separators=(",", ":"))

    # ---- OSM stations
    osm_st = []
    for e in st_raw["elements"]:
        t = e.get("tags", {})
        en = t.get("name:en") or t.get("name") or ""
        if not en:
            continue
        osm_st.append({"osm": e["id"], "en": en, "bn": t.get("name:bn", ""),
                       "lat": round(e["lat"], 6), "lng": round(e["lon"], 6)})

    # ---- Wikipedia trains
    lst = wiki({"action": "parse", "page": LIST_PAGE, "prop": "wikitext|revid"},
               cache, "wiki_list.json")["parse"]
    trains_meta = parse_list(lst["wikitext"])
    stn_titles, arts = set(), {}
    for tm in trains_meta:
        try:
            r = wiki({"action": "parse", "page": tm["title"], "prop": "wikitext|revid",
                      "redirects": "1"}, cache, "wiki_" + _safe(tm["title"]) + ".json")["parse"]
        except Exception:
            continue
        rows, stops, note = parse_article(r["wikitext"])
        if not rows:
            continue
        arts[tm["title"]] = (r.get("revid"), rows, stops, note)
        stn_titles.update(stops)
        for row in rows:
            for nm in (row["from"], row["to"]):
                stn_titles.add(station_title(nm))

    # station article coordinates + English label (batches of 10: URL length)
    geo = {}
    tl = sorted(stn_titles)
    for i in range(0, len(tl), 10):
        batch = tl[i:i + 10]
        r = wiki({"action": "query", "titles": "|".join(batch), "redirects": "1",
                  "prop": "coordinates|langlinks", "lllang": "en", "lllimit": "max"},
                 cache, "wiki_geo_%03d.json" % i)
        redir = {x["from"]: x["to"] for x in r["query"].get("redirects", [])}
        pages = {p["title"]: p for p in r["query"].get("pages", [])}
        for t in batch:
            p = pages.get(redir.get(t, t)) or {}
            c = (p.get("coordinates") or [None])[0]
            en = ((p.get("langlinks") or [{}])[0].get("title") or "")
            geo[t] = (c["lat"], c["lon"], en) if c else (None, None, en)

    stations, trains = {}, []

    def by_name(title, en_hint):
        bn = re.sub(r"\s*(জংশন\s*)?রেলওয়ে স্টেশন$", "", title).strip()
        key = (BN_EN.get(bn) or re.sub(r"\s*(junction\s*)?railway station$", "",
                                       en_hint or "", flags=re.I)).strip().lower()
        if not key:
            return None
        hits = [s for s in osm_st if s["en"].lower().startswith(key)]
        hits.sort(key=lambda s: ("junction" not in s["en"].lower(), len(s["en"])))
        return (hits[0]["lat"], hits[0]["lng"], hits[0]["en"]) if hits else None

    def station_id(title):
        g = geo.get(title)
        bn0 = re.sub(r"\s*(জংশন\s*)?রেলওয়ে স্টেশন$", "", title).strip()
        if bn0 in BN_EN:
            g = by_name(title, "") or g
        if not g or g[0] is None:
            g = by_name(title, g[2] if g else "")
        if not g:
            return None
        node = nearest_node(coords, (g[0], g[1]))
        if node is None:
            return None
        bn = re.sub(r"\s*(জংশন\s*)?রেলওয়ে স্টেশন$", "", title).strip()
        best, en = 1500.0, ""
        for s in osm_st:
            d = hav((s["lat"], s["lng"]), (g[0], g[1]))
            if d < best:
                best, en = d, s["en"]
        en = en or re.sub(r"\s*railway station$", "", g[2], flags=re.I)
        sid = "n%d" % node
        stations.setdefault(sid, {"bn": bn, "en": en, "lat": round(coords[node][0], 6),
                                  "lng": round(coords[node][1], 6), "node": node})
        return sid

    skipped = []
    for title, (revid, rows, stops, note) in arts.items():
        mids = [x for x in (station_id(s) for s in stops) if x]
        for row in rows:
            first = station_id(station_title(row["from"]))
            last = station_id(station_title(row["to"]))
            if not first or not last or first == last:
                skipped.append((row["no"], "station_unresolved"))
                continue
            # the article's stop list is written for ONE direction: flip it
            # when it starts nearer this row's destination
            inner = [x for x in mids if x not in (first, last)]
            if inner:
                f, l = stations[first], stations[last]
                s0 = stations[inner[0]]
                if hav((s0["lat"], s0["lng"]), (l["lat"], l["lng"])) < \
                        hav((s0["lat"], s0["lng"]), (f["lat"], f["lng"])):
                    inner = inner[::-1]
            # route THROUGH the stops (so e.g. Padma-bridge trains follow the
            # bridge line); a stop that cannot be routed is dropped
            seq, path_nodes = [first], [stations[first]["node"]]
            for nxt in inner + [last]:
                seg = dijkstra(adj, path_nodes[-1], stations[nxt]["node"])
                if not seg:
                    if nxt == last:
                        path_nodes = None
                        break
                    continue
                path_nodes += seg[1:]
                seq.append(nxt)
            if path_nodes:
                path_nodes = erase_loops(path_nodes)
                keep = set(path_nodes)
                seq = [x for x in seq if stations[x]["node"] in keep]
            if not path_nodes or len(path_nodes) < 2:
                skipped.append((row["no"], "no_path"))
                continue
            pts = [coords[n] for n in path_nodes]
            cum = [0.0]
            for p, q in zip(pts, pts[1:]):
                cum.append(cum[-1] + hav(p, q))
            # km of each stop = first time the path reaches its node
            first_idx = {}
            for i, n in enumerate(path_nodes):
                first_idx.setdefault(n, i)
            stop_rows = [{"st": x, "km": round(cum[first_idx[stations[x]["node"]]] / 1000.0, 2)}
                         for x in dict.fromkeys(seq)]
            # sanity: the published times must give a believable average
            # speed for this distance; else the row is a typo -> left out
            dh, dm = map(int, row["dep"].split(":"))
            ah, am = map(int, row["arr"].split(":"))
            mins = (ah * 60 + am) - (dh * 60 + dm)
            mins += 1440 if mins <= 0 else 0
            kmh = (cum[-1] / 1000.0) / (mins / 60.0)
            straight = hav(pts[0], pts[-1])
            if not (18.0 <= kmh <= 65.0) or cum[-1] > 1.65 * straight + 20000:
                skipped.append((row["no"], "implausible_%dkmh" % kmh))
                continue
            trains.append({
                "no": row["no"], "name_bn": title, "from": first, "to": last,
                "dep": row["dep"], "arr": row["arr"], "off_days": off_days(row["off"]),
                "stops": stop_rows,
                "path": [r5(p) for p in simplify(pts, 30.0)],
                "km": round(cum[-1] / 1000.0, 1),
                "approved": False,
                "source": {"wiki_title": title, "wiki_revid": revid,
                           "timetable_note": note.strip()},
            })
    for s in stations.values():
        s.pop("node", None)
    tmeta = {
        "trains_source": "Bangla Wikipedia train articles (schedule + stop list), CC BY-SA 4.0",
        "trains_list_revid": lst.get("revid"),
        "geometry": meta["licence"], "osm_base": osm_date, "built": meta["built"],
        "built_by": meta["built_by"],
        "approval": ("Every train is approved:false until the owner checks it against "
                     "the official Bangladesh Railway timetable; the app labels all "
                     "times 'estimate' anyway and says 'timetable not yet checked'."),
        "skipped": sorted(set("%s:%s" % k for k in skipped)),
        "stop_times": "Only origin departure / destination arrival are published; "
                      "intermediate times are interpolated by rail distance (estimate).",
    }
    with open(os.path.join(ROOT, "backend/core/data/train/timetable_bd.json"), "w") as fh:
        json.dump({"_meta": tmeta, "stations": stations,
                   "trains": sorted(trains, key=lambda t: int(t["no"]))},
                  fh, ensure_ascii=False, separators=(",", ":"))

    # ---- app asset: every OSM station + the timetable stations' Bangla names
    app_st = {}
    for s in osm_st:
        app_st[s["osm"]] = {"en": s["en"], "bn": s["bn"], "lat": s["lat"], "lng": s["lng"]}
    for sid, s in stations.items():
        hit = None
        for k, v in app_st.items():
            if hav((v["lat"], v["lng"]), (s["lat"], s["lng"])) < 1500 and v["en"] == s["en"]:
                hit = k
                break
        if hit is not None:
            if not app_st[hit]["bn"]:
                app_st[hit]["bn"] = s["bn"]
        else:
            app_st[sid] = {"en": s["en"], "bn": s["bn"], "lat": s["lat"], "lng": s["lng"]}
    os.makedirs(os.path.join(ROOT, "app/assets/train"), exist_ok=True)
    with open(os.path.join(ROOT, "app/assets/train/stations_bd.json"), "w") as fh:
        json.dump({"_meta": {"source": "OpenStreetMap railway=station|halt, Bangladesh; "
                                       "Bangla names from Bangla Wikipedia where OSM has none",
                             "licence": meta["licence"], "osm_base": osm_date,
                             "built": meta["built"]},
                   "stations": [dict(v, id=str(k)) for k, v in app_st.items()]},
                  fh, ensure_ascii=False, separators=(",", ":"))
    print("lines=%d trains=%d stations=%d app_stations=%d" % (
        len(lines), len(trains), len(stations), len(app_st)), file=sys.stderr)


if __name__ == "__main__":
    main()
